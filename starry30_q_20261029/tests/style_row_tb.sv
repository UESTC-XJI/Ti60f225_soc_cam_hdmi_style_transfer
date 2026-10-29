`timescale 1ns/1ps
module style_row_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,row_we=0,skip_we=0,coef_we=0,start=0;
  reg [1:0] row_bank=0;reg [9:0] row_x=0,skip_x=0;
  reg [191:0] row_data=0,skip_data=0;reg [7:0] coef_addr=0;reg [4:0] coef_word=0;reg [31:0] coef_data=0;
  reg [9:0] input_width=0,output_width=0;reg [4:0] input_channels=0,output_channels=0;
  reg kernel3=0,depthwise=0,stride2=0,upsample2=0,use_residual=0,do_relu=0;
  reg [5:0] row_select=6'b100100;reg [2:0] row_present=0;reg [7:0] weight_base=0,norm_base=0;
  wire busy,done,out_valid;reg out_ready=0;wire [191:0] out_data;wire [9:0] out_x;wire [31:0] cycles;
  style_row_core #(.MAX_WIDTH(32),.COEFF_FILE("rtl/style/model/coeff.hex")) dut(.*);
  reg [191:0] inputs[0:39999],expectations[0:9999];reg [63:0] commands[0:999];
  integer ncommands,job,idx=0,eidx=0,n=0,b,c,totalcycles=0;reg [31:0] rng=32'h7598ab11;
  integer packet_received=0;string ifile,efile,cfile;
  initial begin
    if(!$value$plusargs("input=%s",ifile) || !$value$plusargs("expected=%s",efile) || !$value$plusargs("commands=%s",cfile) || !$value$plusargs("jobs=%d",ncommands)) $fatal(1,"args");
    $readmemh(ifile,inputs);$readmemh(efile,expectations);$readmemh(cfile,commands,0,ncommands-1);
    repeat(3) @(negedge clk);rst_n=1;
    for(job=0;job<ncommands;job=job+1) begin
      @(negedge clk);
      {norm_base,weight_base,row_present,do_relu,use_residual,upsample2,stride2,depthwise,kernel3,output_channels,input_channels,output_width,input_width}=commands[job];
      for(b=0;b<3;b=b+1) begin
        for(c=0;c<input_width;c=c+1) begin
          row_we=1;row_bank=b;row_x=c;row_data=inputs[idx];idx=idx+1;@(negedge clk);
        end
      end
      row_we=0;
      for(c=0;c<output_width;c=c+1) begin
        skip_we=1;skip_x=c;skip_data=inputs[idx];idx=idx+1;@(negedge clk);
      end
      skip_we=0;packet_received=0;start=1;@(negedge clk);start=0;
      while(!done) @(negedge clk);
      if(packet_received!=output_width) $fatal(1,"row count %0d/%0d",packet_received,output_width);
      totalcycles=totalcycles+cycles;
    end
    $display("PASS style_row whole graph rows=%0d pixels=%0d compute_cycles=%0d randomized stalls",ncommands,eidx,totalcycles);$finish;
  end
  always @(negedge clk) begin
    rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};out_ready=rng[0]||rng[1];
  end
  always @(posedge clk) if(rst_n) begin
    n=n+1;
    if(out_valid&&out_ready) begin
      // Variable part selects are avoided: mask compares only valid channels.
      if(out_x!==packet_received || ((out_data^expectations[eidx]) & ((192'b1<<(output_channels*8))-1))!==0)
        $fatal(1,"row=%0d x=%0d got=%h expected=%h",job,out_x,out_data,expectations[eidx]);
      eidx=eidx+1;packet_received=packet_received+1;
    end
    if(n>2000000) $fatal(1,"timeout row=%0d state=%0d",job,dut.state);
  end
endmodule
