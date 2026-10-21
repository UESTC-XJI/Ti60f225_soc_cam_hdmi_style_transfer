// Executes the complete 23-layer graph in DDR, retaining residual inputs.
// Fixed feature allocation is generated with the same graph as the integer oracle.
module style_network #(
  parameter COEFF_FILE="rtl/style/model/coeff.hex", PROGRAM_FILE="rtl/style/model/program.hex",
  parameter integer BURST_MAX=240,
  parameter integer PAD_PITCH=0
)(
  input wire clk,rst_n,start,
  input wire [31:0] source_address,result_address,
  input wire [9:0] frame_width,frame_height,
  input wire coef_we,input wire [7:0] coef_addr,input wire [4:0] coef_word,input wire [31:0] coef_data,
  output reg busy,done,error,output reg [4:0] layer_index,output reg [31:0] cycles,
  output reg [31:0] stat_read_cycles,stat_compute_cycles,
  output reg [31:0] stat_prefetch_starts,stat_prefetch_completions,stat_overlap_cycles,
  output wire [31:0] araddr,output wire [7:0] arlen,output wire arvalid,input wire arready,
  input wire [127:0] rdata,input wire [1:0] rresp,input wire rlast,rvalid,output wire rready,
  output wire [31:0] awaddr,output wire [7:0] awlen,output wire awvalid,input wire awready,
  output wire [127:0] wdata,output wire [15:0] wstrb,output wire wlast,wvalid,input wire wready,
  input wire [1:0] bresp,input wire bvalid,output wire bready
);
  reg [159:0] descriptor;
  `include "model/program.vh"
  wire [4:0] ci=descriptor[4:0],co=descriptor[9:5];
  wire kernel3=descriptor[10],dw=descriptor[11],stride2=descriptor[12],up2=descriptor[13],residual=descriptor[14],relu=descriptor[15];
  wire [9:0] iw=frame_width>>descriptor[17:16],ih=frame_height>>descriptor[17:16];
  wire [9:0] ow=frame_width>>descriptor[19:18],oh=frame_height>>descriptor[19:18];
  wire [7:0] weight_base=descriptor[27:20],norm_base=descriptor[35:28];
  wire [31:0] src=layer_index==0 ? source_address:descriptor[67:36];
  wire [31:0] dst=layer_index==22 ? result_address:descriptor[99:68];
  wire [31:0] skipaddr=descriptor[131:100];
  // Align each row pitch up to a 4 KiB boundary so a row never straddles the
  // AXI 4 KiB burst limit; this lets one long burst read a whole row instead of
  // two.  PAD_PITCH=0 restores the compact (unaligned) layout.
  wire [15:0] raw_in_pitch=iw*(ci==3 ? 4:ci), raw_out_pitch=ow*(co==3 ? 4:co);
  wire [15:0] input_pitch  = PAD_PITCH ? ((raw_in_pitch  + 16'd4095) & 16'hf000) : raw_in_pitch;
  wire [15:0] output_pitch = PAD_PITCH ? ((raw_out_pitch + 16'd4095) & 16'hf000) : raw_out_pitch;
  reg [3:0] state;localparam IDLE=0,DESC=1,SETUP=2,MAP=3,READWAIT=4,SKIP=5,SKIPWAIT=6,RUN=7,WAITROW=8,NEXTROW=9;
  reg [9:0] y,load_x,miss_y;reg [1:0] ky,next_bank,load_bank;
  reg [5:0] row_select;reg [2:0] row_present,cache_valid;reg [9:0] cache_y[0:2];
  reg rd_start,wr_start,core_start,load_skip,core_finished,write_finished;
  // Pointwise, non-residual layers only: the active center row stays immutable
  // while an unused existing bank receives the next row. No extra line RAM.
  reg prefetch_active,prefetch_finished,prefetch_error;
  reg [31:0] rd_address,wr_address;reg [9:0] rd_pixels,wr_pixels;reg [4:0] rd_channels,wr_channels;
  wire rd_busy,rd_done,rd_error,rd_valid,wr_busy,wr_done,wr_error,wr_ready;
  wire [191:0] rd_pixel,core_pixel;wire core_busy,core_done,core_valid;wire [9:0] core_x;wire [31:0] row_cycles;
  style_axi_rows #(.BURST_MAX(BURST_MAX)) dma(.*,.rd_ready(1'b1),.wr_valid(core_valid),.wr_pixel(core_pixel));
  style_row_core #(.COEFF_FILE(COEFF_FILE)) core(
    .clk(clk),.rst_n(rst_n),.row_we(rd_valid&&!load_skip),.row_bank(load_bank),.row_x(load_x),.row_data(rd_pixel),
    .skip_we(rd_valid&&load_skip),.skip_x(load_x),.skip_data(rd_pixel),.coef_we(coef_we&&!busy),
    .coef_addr(coef_addr),.coef_word(coef_word),.coef_data(coef_data),.start(core_start),
    .input_width(iw),.output_width(ow),.input_channels(ci),.output_channels(co),
    .kernel3(kernel3),.depthwise(dw),.stride2(stride2),.upsample2(up2),.use_residual(residual),.do_relu(relu),
    .row_select(row_select),.row_present(row_present),.weight_base(weight_base),.norm_base(norm_base),
    .busy(core_busy),.done(core_done),.out_valid(core_valid),.out_ready(wr_ready),.out_data(core_pixel),.out_x(core_x),.cycles(row_cycles));
  reg signed [12:0] virtual_y,physical_y;reg hit;reg [1:0] hit_bank;
  integer i;
  always @* begin
    virtual_y=$signed({3'b0,y})*(stride2 ? 2:1)+(kernel3 ? $signed({11'b0,ky})-1:0);
    physical_y=up2 ? virtual_y>>>1:virtual_y;
    hit=0;hit_bank=0;
    for(i=0;i<3;i=i+1) if(cache_valid[i] && cache_y[i]==physical_y) begin hit=1;hit_bank=i;end
  end
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      state<=IDLE;busy<=0;done<=0;error<=0;layer_index<=0;cycles<=0;descriptor<=0;
      stat_read_cycles<=0;stat_compute_cycles<=0;
      stat_prefetch_starts<=0;stat_prefetch_completions<=0;stat_overlap_cycles<=0;
      rd_start<=0;wr_start<=0;core_start<=0;load_skip<=0;core_finished<=0;write_finished<=0;
      prefetch_active<=0;prefetch_finished<=0;prefetch_error<=0;
      y<=0;ky<=0;next_bank<=0;load_bank<=0;load_x<=0;miss_y<=0;row_select<=0;row_present<=0;cache_valid<=0;
      rd_address<=0;wr_address<=0;rd_pixels<=0;wr_pixels<=0;rd_channels<=0;wr_channels<=0;
    end else begin
      done<=0;rd_start<=0;wr_start<=0;core_start<=0;
      if(busy) cycles<=cycles+1'b1;
      if(busy&&(state==READWAIT||state==SKIPWAIT))stat_read_cycles<=stat_read_cycles+1'b1;
      if(busy&&core_busy)stat_compute_cycles<=stat_compute_cycles+1'b1;
      if(busy&&rd_valid&&core_busy)stat_overlap_cycles<=stat_overlap_cycles+1'b1;
      if(rd_valid) load_x<=load_x+1'b1;
      if(core_done) core_finished<=1;
      if(wr_done) write_finished<=1;
      if(prefetch_active && rd_done) begin
        prefetch_finished<=1;
        if(rd_error) prefetch_error<=1;
        else begin
          cache_valid[load_bank]<=1;cache_y[load_bank]<=miss_y;
          next_bank<=load_bank==2 ? 0:load_bank+1'b1;
        end
      end
      case(state)
        IDLE:if(start) begin busy<=1;error<=0;cycles<=0;stat_read_cycles<=0;stat_compute_cycles<=0;stat_prefetch_starts<=0;stat_prefetch_completions<=0;stat_overlap_cycles<=0;layer_index<=0;state<=DESC;end
        DESC:begin descriptor<=descriptor_word(layer_index);state<=SETUP;end
        SETUP:begin y<=0;ky<=0;next_bank<=0;cache_valid<=0;row_present<=0;row_select<=0;prefetch_active<=0;prefetch_finished<=0;prefetch_error<=0;state<=MAP;end
        MAP:begin
          if(ky==3) begin ky<=0;state<=residual ? SKIP:RUN;end
          else if((!kernel3 && ky!=1) || virtual_y<0 || virtual_y>=(up2 ? ih*2:ih)) begin
            row_present[ky]<=0;row_select[ky*2+:2]<=0;ky<=ky+1'b1;
          end else if(hit) begin
            row_present[ky]<=1;row_select[ky*2+:2]<=hit_bank;ky<=ky+1'b1;
          end else begin
            miss_y<=physical_y[9:0];load_bank<=next_bank;load_x<=0;load_skip<=0;
            rd_address<=src+physical_y*input_pitch;rd_pixels<=iw;rd_channels<=ci;rd_start<=1;state<=READWAIT;
          end
        end
        READWAIT:if(rd_done) begin
          if(rd_error) begin error<=1;busy<=0;done<=1;state<=IDLE;end
          else begin
            cache_valid[load_bank]<=1;cache_y[load_bank]<=miss_y;
            next_bank<=load_bank==2 ? 0:load_bank+1'b1;
            row_present[ky]<=1;row_select[ky*2+:2]<=load_bank;ky<=ky+1'b1;state<=MAP;
          end
        end
        SKIP:begin
          rd_address<=skipaddr+y*output_pitch;rd_pixels<=ow;rd_channels<=co;load_skip<=1;load_x<=0;rd_start<=1;state<=SKIPWAIT;
        end
        SKIPWAIT:if(rd_done) begin
          if(rd_error) begin error<=1;busy<=0;done<=1;state<=IDLE;end
          else state<=RUN;
        end
        RUN:if(!wr_busy && !core_busy) begin
          wr_address<=dst+y*output_pitch;wr_pixels<=ow;wr_channels<=co;wr_start<=1;core_start<=1;
          prefetch_active<=0;prefetch_finished<=0;prefetch_error<=0;
          if(!kernel3 && !residual && !stride2 && !up2 && y+1<oh && !rd_busy) begin
            // At most one next row is prefetched. The current row_select is
            // unchanged until core/write and this read have all completed.
            load_bank<=row_select[3:2]==0 ? 1:0;
            miss_y<=y+1'b1;load_x<=0;load_skip<=0;
            rd_address<=rd_address+input_pitch;rd_pixels<=iw;rd_channels<=ci;
            rd_start<=1;prefetch_active<=1;stat_prefetch_starts<=stat_prefetch_starts+1'b1;
          end
          core_finished<=0;write_finished<=0;state<=WAITROW;
        end
        WAITROW:if((core_finished||core_done)&&(write_finished||wr_done)&&(!prefetch_active||prefetch_finished||rd_done)) begin
          prefetch_active<=0;
          if(wr_error||prefetch_error||(prefetch_active&&rd_done&&rd_error)) begin error<=1;busy<=0;done<=1;state<=IDLE;end
          else state<=NEXTROW;
        end
        NEXTROW:if(y==oh-1) begin
          if(layer_index==22) begin busy<=0;done<=1;state<=IDLE;end
          else begin layer_index<=layer_index+1'b1;state<=DESC;end
        end else begin y<=y+1'b1;ky<=0;state<=MAP;end
      endcase
      if(busy&&prefetch_active&&rd_done)stat_prefetch_completions<=stat_prefetch_completions+1'b1;
    end
  end
endmodule
