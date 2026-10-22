`timescale 1ns/1ps
module style_accel_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,start=0,coef_we=0;reg [7:0] coef_addr=0;reg [4:0] coef_word=0;reg [31:0] coef_data=0;
  reg [31:0] source_address=32'h05000000,result_address=32'h05800000;
  reg [9:0] frame_width=32,frame_height=24;
  wire busy,done,error;wire [4:0] layer_index;wire [31:0] cycles;
  wire [31:0] stat_read_cycles,stat_compute_cycles;
  wire [31:0] stat_prefetch_starts,stat_prefetch_completions,stat_overlap_cycles;
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
  reg cnn_clk=0;always #3.367 cnn_clk=~cnn_clk;
  reg psel=0,penable=0,pwrite=0;reg [7:0] paddr=0;reg [31:0] pwdata=0;
  wire [31:0] prdata,last_cycles;wire pready,pslverr,irq,stream_enable,auto_ready,job_done,job_error;
  reg auto_start=0;reg [31:0] auto_source=0,auto_result=0;
  assign busy=dut.pending;assign done=job_done;assign error=job_error;
  assign cycles=last_cycles;assign layer_index=dut.network.layer_index;
  assign stat_prefetch_starts=dut.prefetch_starts_snapshot;
  assign stat_prefetch_completions=dut.prefetch_completions_snapshot;
  assign stat_overlap_cycles=dut.overlap_cycles_snapshot;
  style_accel dut(.*);
  task write_apb(input [7:0] address,input [31:0] value,input reject);
    begin
      @(negedge clk);psel=1;penable=0;pwrite=1;paddr=address;pwdata=value;
      @(negedge clk);penable=1;
      while(!pready)@(negedge clk);
      @(posedge clk);if(pslverr!==reject)$fatal(1,"APB reject addr=%h got=%b",address,pslverr);
      @(negedge clk);psel=0;penable=0;pwrite=0;
    end
  endtask
  reg [31:0] cpu_coeff[0:6143];integer cr,cw;
  initial $readmemh("reports/style_demo/accel/coeff32.hex",cpu_coeff);
  defparam dut.network.COEFF_FILE="reports/style_demo/accel/zero_coeff.hex";
  integer n=0,i,b,read_transactions=0,write_transactions=0;string ifile,efile;
  initial begin
    if(!$value$plusargs("input=%s",ifile)||!$value$plusargs("expected=%s",efile))$fatal(1,"args");
    read_addr=source_address;write_addr=result_address;
    $readmemh(ifile,mem,0,191);$readmemh(efile,golden,0,191);
    repeat(4) @(negedge clk);rst_n=1;
    for(cr=0;cr<256;cr=cr+1)for(cw=0;cw<24;cw=cw+1)begin
      write_apb(8'h28,(cr<<8)|cw,0);write_apb(8'h2c,cpu_coeff[cr*24+cw],0);
    end
    repeat(12)@(negedge clk);
    if(!dut.coeff_idle||dut.issued!=6144)$fatal(1,"coefficient CDC acknowledgement");
    write_apb(8'h28,24,1);
    write_apb(8'h10,32'hfffffff0,0);write_apb(8'h04,1,1);
    write_apb(8'h10,32'h05000000,0);
    write_apb(8'h18,32'h00170020,0);write_apb(8'h04,1,1);
    write_apb(8'h18,32'h00180021,0);write_apb(8'h04,1,1);
    write_apb(8'h18,32'h00180020,0);write_apb(8'h0c,1,0);write_apb(8'h04,1,0);
    write_apb(8'h10,32'h05140000,1);
    wait(done);@(negedge clk);
    if(error)$fatal(1,"accelerator error");
    @(posedge clk);@(negedge clk);
    if(!irq||dut.source_cfg!=32'h05000000)$fatal(1,"IRQ or rejected write changed config");
    if(dut.read_cycles_snapshot>cycles||dut.compute_cycles_snapshot>cycles)$fatal(1,"phase snapshot outside job");
    if(!error&&(dut.read_cycles_snapshot==0||dut.compute_cycles_snapshot==0))$fatal(1,"missing phase snapshot");
    @(negedge clk);psel=1;penable=1;pwrite=0;paddr=8'ha8;
    @(posedge clk);#1;if(prdata!==dut.read_cycles_snapshot)$fatal(1,"APB read phase decode");
    @(negedge clk);paddr=8'hac;
    @(posedge clk);#1;if(prdata!==dut.compute_cycles_snapshot)$fatal(1,"APB compute phase decode");
    @(negedge clk);paddr=8'hb0;
    @(posedge clk);#1;if(prdata!==stat_prefetch_starts || prdata==0)$fatal(1,"APB prefetch starts");
    @(negedge clk);paddr=8'hb4;
    @(posedge clk);#1;if(prdata!==stat_prefetch_completions || prdata!==stat_prefetch_starts)$fatal(1,"APB prefetch completions");
    @(negedge clk);paddr=8'hb8;
    @(posedge clk);#1;if(prdata!==stat_overlap_cycles || prdata==0)$fatal(1,"APB overlap pixels");
    @(negedge clk);psel=0;penable=0;
    write_apb(8'h08,2,0);if(irq)$fatal(1,"IRQ W1C");
    if(stat_prefetch_starts==0 || stat_prefetch_starts!==stat_prefetch_completions)$fatal(1,"prefetch counters mismatch");
    if(stat_overlap_cycles==0)$fatal(1,"missing overlap telemetry");
    $display("TELEMETRY starts=%0d completions=%0d overlap_pixels=%0d",stat_prefetch_starts,stat_prefetch_completions,stat_overlap_cycles);
    for(i=0;i<192;i=i+1) if(mem[4096+i]!==golden[i]) $fatal(1,"output beat %0d got=%h expected=%h",i,mem[4096+i],golden[i]);
    $display("PASS style_accel all 6144 APB coefficients+CDC+IRQ 32x24 full graph exact RGB, AXI random stalls cycles=%0d reads=%0d writes=%0d",cycles,read_transactions,write_transactions);$finish;
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
      if(n>2000000)$fatal(1,"timeout layer=%0d state=%0d DMA=%0d/%0d",layer_index,dut.network.state,dut.network.dma.rs,dut.network.dma.ws);
    end
  end
endmodule
