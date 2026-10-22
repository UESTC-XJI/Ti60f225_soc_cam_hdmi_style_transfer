// Reusable row convolution core. Only three input rows and one residual row
// reside on chip; the layer DMA provides cache row mappings and zero borders.
module style_row_core #(
  parameter integer MAX_WIDTH=640,
  parameter COEFF_FILE="rtl/style/model/coeff.hex"
)(
  input wire clk,rst_n,
  input wire row_we,input wire [1:0] row_bank,input wire [9:0] row_x,input wire [191:0] row_data,
  input wire skip_we,input wire [9:0] skip_x,input wire [191:0] skip_data,
  input wire coef_we,input wire [7:0] coef_addr,input wire [4:0] coef_word,input wire [31:0] coef_data,
  input wire start,
  input wire [9:0] input_width,output_width,
  input wire [4:0] input_channels,output_channels,
  input wire kernel3,depthwise,stride2,upsample2,use_residual,do_relu,
  input wire [5:0] row_select,input wire [2:0] row_present,
  input wire [7:0] weight_base,norm_base,
  output reg busy,done,
  output reg out_valid,input wire out_ready,output reg [191:0] out_data,
  output reg [9:0] out_x,
  output reg [31:0] cycles
);
  (* syn_ramstyle="block_ram" *) reg [63:0] row0lo[0:MAX_WIDTH-1],row1lo[0:MAX_WIDTH-1],row2lo[0:MAX_WIDTH-1];
  (* syn_ramstyle="block_ram" *) reg [127:0] row0hi[0:MAX_WIDTH/2-1],row1hi[0:MAX_WIDTH/2-1],row2hi[0:MAX_WIDTH/2-1];
  (* syn_ramstyle="block_ram" *) reg [191:0] skip[0:MAX_WIDTH/4-1];
  reg [191:0] read0,read1,read2,skip_read;
  reg [191:0] patch[0:8],patch_skip;
  reg [9:0] x;reg [1:0] column,co_group,red_group;
  reg [2:0] red_groups,co_groups;
  reg [2:0] state;
  localparam IDLE=0,FETCH=1,LATCH=2,ISSUE=3,DRAIN=4,NORM=5;
  wire advance=!out_valid || out_ready;
  reg [1:0] column_d;reg fetch_valid,fetch_present;
  reg signed [12:0] virtual_x,physical_x;reg [9:0] read_x;
  always @* begin
    virtual_x=$signed({3'b0,x})*(stride2 ? 2:1)+(kernel3 ? $signed({11'b0,column})-1:0);
    physical_x=upsample2 ? virtual_x>>>1:virtual_x;
    read_x=physical_x[9:0];
  end
  always @(posedge clk) begin
    if(row_we) case(row_bank)
      0:begin row0lo[row_x]<=row_data[63:0];if(row_x<MAX_WIDTH/2)row0hi[row_x]<=row_data[191:64];end
      1:begin row1lo[row_x]<=row_data[63:0];if(row_x<MAX_WIDTH/2)row1hi[row_x]<=row_data[191:64];end
      2:begin row2lo[row_x]<=row_data[63:0];if(row_x<MAX_WIDTH/2)row2hi[row_x]<=row_data[191:64];end
    endcase
    if(skip_we) skip[skip_x]<=skip_data;
    if(advance && state==FETCH) begin
      read0[63:0]<=row0lo[read_x];read1[63:0]<=row1lo[read_x];read2[63:0]<=row2lo[read_x];
      read0[191:64]<=row0hi[read_x];read1[191:64]<=row1hi[read_x];read2[191:64]<=row2hi[read_x];
      skip_read<=skip[x];
    end
  end
  function [191:0] choose_row;
    input [1:0] sel;input present;
    begin
      if(!present || !fetch_present) choose_row=0;
      else case(sel) 0:choose_row=read0;1:choose_row=read1;default:choose_row=read2;endcase
    end
  endfunction
  // Packed coefficients occupy 24 independent 32-bit dual-port RAM banks.
  // Weight and BN reads share the storage. Programming is permitted only idle.
  wire [767:0] weight_word;
  reg [511:0] norm_word;reg norm_read;
  reg [511:0] norm_cache1,norm_cache2;
  wire [7:0] waddr=weight_base+co_group*red_groups+red_group;
  wire [7:0] naddr=norm_base+co_group;
  wire read_normal=state==FETCH||state==NORM;
  wire [7:0] coefficient_address=read_normal ? naddr:waddr;
  genvar bank;
  generate for(bank=0;bank<24;bank=bank+1) begin: coefficients
    (* syn_ramstyle="block_ram" *) reg [31:0] mem[0:255];reg [31:0] wr;
    reg [767:0] initial_coeff[0:255];
    integer a;
    initial begin
      $readmemh(COEFF_FILE,initial_coeff);
      for(a=0;a<256;a=a+1) mem[a]=initial_coeff[a][bank*32+:32];
    end
    always @(posedge clk) begin
      if(coef_we && !busy && coef_word==bank) mem[coef_addr]<=coef_data;
      else if(advance) wr<=mem[coefficient_address];
    end
    assign weight_word[bank*32+:32]=wr;
  end endgenerate
  always @(posedge clk) if(advance)begin
    norm_read<=read_normal;
    if(norm_read)norm_word<=weight_word[511:0];
  end
  wire [767:0] activation_word;reg [767:0] activation_pipe;
  reg first_pipe,last_pipe,valid_pipe;reg [15:0] tag_pipe;reg [63:0] skip_pipe;
  reg [127:0] multipliers;reg [255:0] biases;reg [63:0] shifts;
  wire [511:0] active_norm=(tag_pipe[11:2]==0 || tag_pipe[1:0]==0) ? norm_word:
    tag_pipe[1:0]==1 ? norm_cache1:norm_cache2;
  // Cache groups 1/2 after their first pixel; group 0 is prefetched by FETCH.
  always @(posedge clk)if(advance&&valid_pipe&&first_pipe&&tag_pipe[11:2]==0)begin
    if(tag_pipe[1:0]==1)norm_cache1<=norm_word;
    if(tag_pipe[1:0]==2)norm_cache2<=norm_word;
  end
  integer lane,ky;
  wire [191:0] point_pixel=(!row_present[1]||!fetch_present) ? 192'b0:
    row_select[3:2]==0 ? read0:row_select[3:2]==1 ? read1:read2;
  // Static RGB reduction wiring and one shared PW slice avoid a dynamic
  // patch/channel crossbar replicated across all 96 multipliers.
  wire [95:0] rgb_terms=red_group==0 ?
    {patch[2][15:8],patch[1][15:8],patch[0][15:8],patch[8][7:0],patch[7][7:0],patch[6][7:0],patch[5][7:0],patch[4][7:0],patch[3][7:0],patch[2][7:0],patch[1][7:0],patch[0][7:0]}:
    red_group==1 ?
    {patch[5][23:16],patch[4][23:16],patch[3][23:16],patch[2][23:16],patch[1][23:16],patch[0][23:16],patch[8][15:8],patch[7][15:8],patch[6][15:8],patch[5][15:8],patch[4][15:8],patch[3][15:8]}:
    {72'b0,patch[8][23:16],patch[7][23:16],patch[6][23:16]};
  wire [95:0] pw_slice=point_pixel>>(red_group*96);
  wire [95:0] pw_terms=input_channels==8 ? {32'b0,pw_slice[63:0]}:pw_slice;
  genvar ac_lane,ac_tap;
  generate for(ac_tap=0;ac_tap<12;ac_tap=ac_tap+1)begin: activation_taps
    wire [63:0] dw_slice;
    if(ac_tap<9)assign dw_slice=patch[ac_tap]>>(co_group*64);
    else assign dw_slice=0;
    for(ac_lane=0;ac_lane<8;ac_lane=ac_lane+1)begin: output_lanes
      assign activation_word[(ac_lane*12+ac_tap)*8+:8]=depthwise ?
        (co_group*8+ac_lane<input_channels ? dw_slice[ac_lane*8+:8]:8'b0):
        kernel3 ? rgb_terms[ac_tap*8+:8]:pw_terms[ac_tap*8+:8];
    end
  end endgenerate
  always @* begin
    multipliers=0;biases=0;shifts=0;
    for(lane=0;lane<8;lane=lane+1) begin
      multipliers[lane*16+:16]=active_norm[lane*64+:16];
      shifts[lane*8+:8]=active_norm[lane*64+16+:8];
      biases[lane*32+:32]=active_norm[lane*64+32+:32];
    end
  end
  wire mac_ready,mac_valid;wire [63:0] mac_result,mac_skip;wire [15:0] mac_tag;
  // At most 27 nonzero terms: abs(acc)<=27*128*128=442368 < 2^19.
  // For every signed16 M/signed32 B, abs(acc*M+B)<2^35; 36 bits are exact.
  style_mac8x12 #(.ACC_WIDTH(20),.AFFINE_WIDTH(36)) mac(.clk(clk),.rst_n(rst_n),.in_valid(valid_pipe && advance),.in_ready(mac_ready),
    .first(first_pipe),.last(last_pipe),.activations(activation_pipe),.weights(weight_word),
    .multipliers(multipliers),.biases(biases),.shifts(shifts),.relu(do_relu),.in_tag(tag_pipe),.in_skip(skip_pipe),
    .out_valid(mac_valid),.out_ready(advance),.result(mac_result),.out_skip(mac_skip),.out_tag(mac_tag));
  reg [191:0] assembled;
  reg signed [8:0] residual_sum;reg [7:0] v;
  reg [191:0] assembled_next;
  integer qlane;
  always @* begin
    assembled_next=assembled;
    for(qlane=0;qlane<8;qlane=qlane+1) begin
      v=mac_result[qlane*8+:8];
      // A non-resize PW layer adds the original block input at the same x.
      residual_sum=$signed(v)+$signed(mac_skip[qlane*8+:8]);
      if(use_residual) v=residual_sum<0 ? 0 : residual_sum>127 ? 127 : residual_sum[7:0];
      assembled_next[(mac_tag[1:0]*8+qlane)*8+:8]=v;
    end
  end
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      busy<=0;done<=0;out_valid<=0;out_data<=0;out_x<=0;cycles<=0;
      state<=IDLE;x<=0;column<=0;column_d<=0;co_group<=0;red_group<=0;
      valid_pipe<=0;fetch_valid<=0;fetch_present<=0;assembled<=0;red_groups<=1;co_groups<=1;
    end else begin
      done<=0;
      if(busy) cycles<=cycles+1'b1;
      if(out_valid && out_ready) begin
        out_valid<=0;
        if(out_x==output_width-1) begin busy<=0;done<=1;state<=IDLE;end
      end
      if(start && !busy) begin
        busy<=1;cycles<=0;x<=0;column<=kernel3 ? 0:1;co_group<=0;red_group<=0;state<=FETCH;
        co_groups<=(output_channels+7)>>3;
        red_groups<=depthwise ? 1:kernel3 ? 3:(input_channels+11)/12;
      end else if(advance && mac_ready) begin
        valid_pipe<=state==ISSUE;
        if(state==ISSUE) begin
          activation_pipe<=activation_word;first_pipe<=red_group==0;last_pipe<=red_group==red_groups-1;
          tag_pipe<={4'b0,x,co_group};
          skip_pipe<=kernel3 ? patch_skip[co_group*64+:64]:skip_read[co_group*64+:64];
          if(red_group==red_groups-1) begin
            red_group<=0;
            if(co_group==co_groups-1) begin
              co_group<=0;
              if(x==output_width-1) state<=DRAIN;
              else begin
                x<=x+1'b1;column<=kernel3 ? (stride2 ? 1:2):1;state<=FETCH;
                if(kernel3) for(ky=0;ky<3;ky=ky+1) begin
                  patch[ky*3]<=stride2 ? patch[ky*3+2]:patch[ky*3+1];
                  if(!stride2) patch[ky*3+1]<=patch[ky*3+2];
                end
              end
            end else begin co_group<=co_group+1'b1;state<=x==0 ? NORM:ISSUE;end
          end else red_group<=red_group+1'b1;
        end
        fetch_valid<=state==FETCH;
        if(state==FETCH) begin
          column_d<=column;
          fetch_present<=virtual_x>=0 && virtual_x<(upsample2 ? input_width*2:input_width);
          if(!kernel3)state<=ISSUE;
          else if(column==2) state<=LATCH;
          else column<=column+1'b1;
        end
        if(fetch_valid) begin
          patch_skip<=skip_read;
          patch[column_d]<=choose_row(row_select[1:0],row_present[0]);
          patch[3+column_d]<=choose_row(row_select[3:2],row_present[1]);
          patch[6+column_d]<=choose_row(row_select[5:4],row_present[2]);
        end
        if(state==LATCH) state<=ISSUE;
        if(state==NORM) state<=ISSUE;
      end
      if(mac_valid && advance) begin
        assembled<=assembled_next;
        if(mac_tag[1:0]==co_groups-1) begin out_valid<=1;out_data<=assembled_next;out_x<=mac_tag[11:2];end
      end
    end
  end
endmodule
