// One maximum AXI burst plus an elastic output register. Only RGB bytes are
// stored: the XBGR padding byte is not displayed. RRESP/RLAST stay with data.
// Synchronous RAM read avoids a wide asynchronous read mux.
module style_display_beats(
  input wire clk,rst_n,in_valid,output wire in_ready,
  input wire [127:0] in_data,input wire [1:0] in_resp,input wire in_last,
  output reg out_valid,input wire out_ready,output wire [127:0] out_data,
  output wire [1:0] out_resp,output wire out_last
);
  (* syn_ramstyle="block_ram" *) reg [98:0] memory[0:31];
  reg [4:0] wp,rp;reg [5:0] count;reg [98:0] word;
  wire push=in_valid&&in_ready;
  wire fetch=(!out_valid||out_ready)&&count!=0;
  assign in_ready=count<32;
  assign {out_last,out_resp}=word[98:96];
  assign out_data={8'b0,word[95:72],8'b0,word[71:48],8'b0,word[47:24],8'b0,word[23:0]};
  always @(posedge clk)begin
    if(push)memory[wp]<={in_last,in_resp,in_data[119:96],in_data[87:64],in_data[55:32],in_data[23:0]};
    if(fetch)word<=memory[rp];
  end
  always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin wp<=0;rp<=0;count<=0;out_valid<=0;end
    else begin
      if(push)wp<=wp+1'b1;
      if(fetch)rp<=rp+1'b1;
      case({push,fetch})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:begin end endcase
      if(!out_valid||out_ready)out_valid<=fetch;
    end
  end
endmodule
