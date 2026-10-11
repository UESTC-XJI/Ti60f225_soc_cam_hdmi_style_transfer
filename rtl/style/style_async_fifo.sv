// Gray-pointer CDC FIFO with synchronous RAM prefetch and an elastic output.
module style_async_fifo #(parameter WIDTH=40,LOG_DEPTH=4)(
  input wire reset_n,wclk,rclk,
  input wire in_valid,output wire in_ready,input wire [WIDTH-1:0] in_data,
  output reg out_valid,input wire out_ready,output reg [WIDTH-1:0] out_data
);
  reg [LOG_DEPTH:0] wp,rp,wg,rg;
  (* async_reg="true" *) reg [LOG_DEPTH:0] rg1,rg2,wg1,wg2;
  (* async_reg="true" *) reg [1:0] wrst,rrst;
  always @(posedge wclk or negedge reset_n) if(!reset_n)wrst<=0;else wrst<={wrst[0],1'b1};
  always @(posedge rclk or negedge reset_n) if(!reset_n)rrst<=0;else rrst<={rrst[0],1'b1};
  wire full=wg=={~rg2[LOG_DEPTH:LOG_DEPTH-1],rg2[LOG_DEPTH-2:0]};
  wire empty=rg==wg2;
  assign in_ready=wrst[1]&&!full;
  wire [LOG_DEPTH:0] wn=wp+1'b1,rn=rp+1'b1;
  wire [WIDTH-1:0] read_word;
  generate if(LOG_DEPTH==4 && WIDTH<=45)begin:small_storage
    wire [(1<<LOG_DEPTH)*WIDTH-1:0] flat;
    genvar entry;
    for(entry=0;entry<(1<<LOG_DEPTH);entry=entry+1)begin:words
      reg [WIDTH-1:0] value;
      always @(posedge wclk)if(in_valid&&in_ready&&wp[LOG_DEPTH-1:0]==entry)value<=in_data;
      assign flat[entry*WIDTH+:WIDTH]=value;
    end
    assign read_word=flat[rp[LOG_DEPTH-1:0]*WIDTH+:WIDTH];
  end else begin:ram_storage
    (* syn_ramstyle="block_ram" *) reg [WIDTH-1:0] mem[0:(1<<LOG_DEPTH)-1];
    always @(posedge wclk)if(in_valid&&in_ready)mem[wp[LOG_DEPTH-1:0]]<=in_data;
    assign read_word=mem[rp[LOG_DEPTH-1:0]];
  end endgenerate
  always @(posedge wclk or negedge reset_n) begin
    if(!reset_n) begin wp<=0;wg<=0;rg1<=0;rg2<=0;end
    else if(!wrst[1]) begin wp<=0;wg<=0;rg1<=0;rg2<=0;end
    else begin
      rg1<=rg;rg2<=rg1;
      if(in_valid&&in_ready)begin wp<=wn;wg<=(wn>>1)^wn;end
    end
  end
  always @(posedge rclk or negedge reset_n) begin
    if(!reset_n) begin rp<=0;rg<=0;wg1<=0;wg2<=0;out_valid<=0;out_data<=0;end
    else if(!rrst[1]) begin rp<=0;rg<=0;wg1<=0;wg2<=0;out_valid<=0;end
    else begin
      wg1<=wg;wg2<=wg1;
      if(!out_valid||out_ready) begin
        out_valid<=!empty;
        if(!empty)begin out_data<=read_word;rp<=rn;rg<=(rn>>1)^rn;end
      end
    end
  end
endmodule
