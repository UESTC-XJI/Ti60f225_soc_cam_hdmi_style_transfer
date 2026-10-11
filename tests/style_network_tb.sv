`timescale 1ns/1ps
module style_network_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,start=0,coef_we=0;reg [7:0] coef_addr=0;reg [4:0] coef_word=0;reg [31:0] coef_data=0;
  reg [31:0] source_address=32'h05000000,result_address=32'h05800000;
  reg [9:0] frame_width=32,frame_height=24;
  wire busy,done,error;wire [4:0] layer_index;wire [31:0] cycles;
  wire [31:0] araddr,awaddr;wire [7:0] arlen,awlen;wire arvalid,awvalid,rready,wlast,wvalid,bready;
  wire [127:0] wdata;wire [15:0] wstrb;
  reg read_active=0,write_active=0,rhold=0,bvalid=0;
  reg [31:0] read_addr,write_addr;reg [7:0] read_len,write_len,read_beat,write_beat;
  reg [31:0] rng=32'h2a851bd7;reg [127:0] mem[0:24575],golden[0:191];
  function integer address_index;
    input [31:0] address;
    begin
      if(address>=32'h05000000 && address<32'h05010000) address_index=(address-32'h05000000)>>4;
      else if(address>=32'h05800000 && address<32'h05810000) address_index=4096+((address-32'h05800000)>>4);
      else if(address>=32'h06000000 && address<32'h06010000) address_index=8192+((address-32'h06000000)>>4);
      else if(address>=32'h060a0000 && address<32'h060b0000) address_index=12288+((address-32'h060a0000)>>4);
      else if(address>=32'h06120000 && address<32'h06130000) address_index=16384+((address-32'h06120000)>>4);
      else if(address>=32'h06200000 && address<32'h06210000) address_index=20480+((address-32'h06200000)>>4);
      else begin address_index=0;$fatal(1,"illegal DDR address %h",address);end
    end
  endfunction
  wire arready=!read_active && rng[0];wire awready=!write_active&&!bvalid&&rng[1];
  wire rvalid=read_active&&rhold;wire rlast=read_beat==read_len;
  reg [127:0] rdata=0;wire [1:0] rresp=0,bresp=0;
  wire wready=write_active&&(rng[2]||rng[3]);
  style_network dut(.*);
  integer n=0,i,b,read_transactions=0,write_transactions=0;string ifile,efile;
  initial begin
    if(!$value$plusargs("input=%s",ifile)||!$value$plusargs("expected=%s",efile))$fatal(1,"args");
    read_addr=source_address;write_addr=result_address;
    $readmemh(ifile,mem,0,191);$readmemh(efile,golden,0,191);
    repeat(4) @(negedge clk);rst_n=1;start=1;@(negedge clk);start=0;
    wait(done);@(negedge clk);
    if(error)$fatal(1,"accelerator error");
    for(i=0;i<192;i=i+1) if(mem[4096+i]!==golden[i]) $fatal(1,"output beat %0d got=%h expected=%h",i,mem[4096+i],golden[i]);
    $display("PASS style_network 32x24 full graph exact RGB, AXI random stalls cycles=%0d reads=%0d writes=%0d",cycles,read_transactions,write_transactions);$finish;
  end
  always @(posedge clk) begin
    rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
    if(!rst_n) begin read_active<=0;write_active<=0;rhold<=0;bvalid<=0;end
    else begin
      n=n+1;
      if(arvalid&&arready) begin
        if(araddr[3:0]!=0 || arlen>31 || (araddr[11:0]+((arlen+1)*16))>4096)$fatal(1,"AR protocol");
        read_active<=1;read_addr<=araddr;read_len<=arlen;read_beat<=0;rhold<=0;read_transactions=read_transactions+1;
      end
      if(read_active&&!rhold) begin
        rdata<=mem[address_index(read_addr)];rhold<=rng[4]||rng[5];
      end
      if(rvalid&&rready) begin
        rhold<=0;read_addr<=read_addr+16;read_beat<=read_beat+1'b1;
        if(rlast) read_active<=0;
      end
      if(awvalid&&awready) begin
        if(awaddr[3:0]!=0 || awlen>31 || (awaddr[11:0]+((awlen+1)*16))>4096)$fatal(1,"AW protocol");
        write_active<=1;write_addr<=awaddr;write_len<=awlen;write_beat<=0;write_transactions=write_transactions+1;
      end
      if(wvalid&&wready) begin
        if(wlast!=(write_beat==write_len))$fatal(1,"WLAST");
        if(wstrb==16'hffff)mem[address_index(write_addr)]<=wdata;
        else for(b=0;b<16;b=b+1)if(wstrb[b])mem[address_index(write_addr)][b*8+:8]<=wdata[b*8+:8];
        write_addr<=write_addr+16;write_beat<=write_beat+1'b1;
        if(wlast)begin write_active<=0;bvalid<=1;end
      end
      if(bvalid&&bready)bvalid<=0;
      if(n>2000000)$fatal(1,"timeout layer=%0d state=%0d DMA=%0d/%0d",layer_index,dut.state,dut.dma.rs,dut.dma.ws);
    end
  end
endmodule
