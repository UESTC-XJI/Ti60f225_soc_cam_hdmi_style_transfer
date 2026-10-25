`timescale 1ns/1ps
module style_system_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,start=0,coef_we=0;reg [7:0] coef_addr=0;reg [4:0] coef_word=0;reg [31:0] coef_data=0;
  reg [31:0] source_address=32'h05140000,result_address=32'h05940000;
  reg [9:0] frame_width=640,frame_height=48;
  wire busy,done,error;wire [4:0] layer_index;wire [31:0] cycles;
  wire [31:0] stat_read_cycles,stat_compute_cycles;
  wire [31:0] stat_prefetch_starts,stat_prefetch_completions,stat_overlap_cycles;
  wire [31:0] araddr,awaddr;wire [7:0] arlen,awlen;wire arvalid,awvalid,rready,wlast,wvalid,bready;
  wire [127:0] wdata;wire [15:0] wstrb;
  reg read_active=0,write_active=0,rhold=0,bvalid=0;
  reg [31:0] read_addr,write_addr;reg [7:0] read_len,write_len,read_beat,write_beat;
  reg [31:0] rng=32'h2a851bd7;reg [127:0] mem[0:1310719],golden[0:7679];
  function integer address_index;
    input [31:0] address;
    begin
      if(address>=32'h05000000 && address<32'h05800000) address_index=(address-32'h05000000)>>4;
      else if(address>=32'h05800000 && address<32'h06000000) address_index=524288+((address-32'h05800000)>>4);
      else if(address>=32'h06000000 && address<32'h06400000) address_index=1048576+((address-32'h06000000)>>4);
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
  assign busy=dut.accelerator.pending;assign done=dut.accelerator.job_done;assign error=dut.accelerator.job_error;
  assign cycles=dut.accelerator.last_cycles;assign layer_index=dut.accelerator.network.layer_index;
  assign stat_prefetch_starts=dut.accelerator.prefetch_starts_snapshot;
  assign stat_prefetch_completions=dut.accelerator.prefetch_completions_snapshot;
  assign stat_overlap_cycles=dut.accelerator.overlap_cycles_snapshot;
  reg pix_clk=0;always #6.734 pix_clk=~pix_clk;
  reg rgb_vs=0,rgb_de=0;reg [47:0] rgb_data=0;
  wire [31:0] pixel,resized_frames;wire hs,vs,de,underflow,capture_fault;
  wire [5:0] awid,arid;reg [5:0] bid=0,rid=0;wire [2:0] awsize,arsize;wire [1:0] awburst,arburst;
  style_video_system #(.DISPLAY_BUFFER(1'b1),.ADAPTIVE_READ(1'b0)) dut(.*);
  integer display_pixels=0,underflows=0,capture_beats=0;
  integer ph,pv;
  always @(posedge pix_clk)if(rst_n)begin
    ph=dut.display.h;pv=dut.display.v;#1;
    if(pv>=145&&pv<625&&ph>=260&&ph<1540)begin
      display_pixels=display_pixels+1;
      if(underflow)underflows=underflows+1;
      else if(pixel!==(ph<900 ? 32'h00221100:32'h00332211))$fatal(1,"immutable display pair corrupted");
    end
  end
  initial begin
    wait(dut.accelerator.pending);
    @(negedge cnn_clk);rgb_vs=1;repeat(4)@(negedge cnn_clk);rgb_vs=0;repeat(3)@(negedge cnn_clk);
    for(integer yy=0;yy<1080;yy=yy+1)begin
      for(integer xx=0;xx<960;xx=xx+1)begin rgb_de=1;rgb_data=48'h030201030201;@(negedge cnn_clk);end
      rgb_de=0;repeat(40)@(negedge cnn_clk);
    end
  end
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
  defparam dut.accelerator.network.COEFF_FILE="reports/style_demo/accel/zero_coeff.hex";
  reg [4:0] previous_layer=31;
  integer n=0,i,b,read_transactions=0,write_transactions=0;string ifile,efile;
  initial begin
    if(!$value$plusargs("input=%s",ifile)||!$value$plusargs("expected=%s",efile))$fatal(1,"args");
    read_addr=source_address;write_addr=result_address;
    for(i=0;i<76800;i=i+1)begin
      mem[i]=128'h00221100002211000022110000221100;
      mem[524288+i]=128'h00332211003322110033221100332211;
    end
    $readmemh(ifile,mem,81920,89599);$readmemh(efile,golden,0,7679);
    repeat(4) @(negedge clk);rst_n=1;
    // Seed a prior complete display pair before the first display request.
    dut.store.display_valid=1;dut.store.display_slot=0;dut.store.ownership[0]=5;
    dut.store.infer_active=1;dut.store.infer_slot=1;dut.store.ownership[1]=3;
    
    for(cr=0;cr<256;cr=cr+1)for(cw=0;cw<24;cw=cw+1)begin
      write_apb(8'h28,(cr<<8)|cw,0);write_apb(8'h2c,cpu_coeff[cr*24+cw],0);
    end
    repeat(12)@(negedge clk);
    if(!dut.accelerator.coeff_idle||dut.accelerator.issued!=6144)$fatal(1,"coefficient CDC acknowledgement");
    write_apb(8'h28,24,1);
    write_apb(8'h10,32'hfffffff0,0);write_apb(8'h04,1,1);
    write_apb(8'h10,32'h05140000,0);write_apb(8'h14,32'h05940000,0);
    write_apb(8'h18,32'h00170020,0);write_apb(8'h04,1,1);
    write_apb(8'h18,32'h00180021,0);write_apb(8'h04,1,1);
    write_apb(8'h18,32'h00300280,0);write_apb(8'h0c,1,0);write_apb(8'h04,17,0);
    write_apb(8'h10,32'h05140000,1);
    wait(done);@(negedge clk);
    if(error)$fatal(1,"accelerator error");
    @(posedge clk);@(negedge clk);
    if(!irq||dut.accelerator.source_cfg!=32'h05140000)$fatal(1,"IRQ or rejected write changed config");
    if(dut.accelerator.read_cycles_snapshot>cycles||dut.accelerator.compute_cycles_snapshot>cycles)$fatal(1,"phase snapshot outside job");
    if(!error&&(dut.accelerator.read_cycles_snapshot==0||dut.accelerator.compute_cycles_snapshot==0))$fatal(1,"missing phase snapshot");
    @(negedge clk);psel=1;penable=1;pwrite=0;paddr=8'ha8;
    @(posedge clk);#1;if(prdata!==dut.accelerator.read_cycles_snapshot)$fatal(1,"APB read phase decode");
    @(negedge clk);paddr=8'hac;
    @(posedge clk);#1;if(prdata!==dut.accelerator.compute_cycles_snapshot)$fatal(1,"APB compute phase decode");
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
    for(i=0;i<7680;i=i+1) if(mem[606208+i]!==golden[i]) $fatal(1,"output beat %0d got=%h expected=%h",i,mem[606208+i],golden[i]);
    if(capture_fault||underflows||display_pixels<100000||capture_beats!=76800||dut.store.captured!=1)$fatal(1,"concurrent system coverage/fault cap=%0d pix=%0d underflow=%0d",capture_beats,display_pixels,underflows);
    for(i=0;i<76800;i=i+1)if(mem[163840+i]!==128'h00030201000302010003020100030201)$fatal(1,"camera frame beat %0d corrupted",i);
    write_apb(8'h54,1,0);
    for(i=0;i<12;i=i+1)begin
      @(negedge clk);psel=1;penable=1;pwrite=0;paddr=8'h58+i*4;
      @(posedge clk);#1;
      $display("PROFILE %0d %0d",i,prdata);
      if(prdata!==dut.profiler.counters[i])$fatal(1,"profile APB decode");
      @(negedge clk);psel=0;penable=0;
    end
    $display("PHASE read_cycles=%0d compute_cycles=%0d",dut.accelerator.read_cycles_snapshot,dut.accelerator.compute_cycles_snapshot);
    $display("SYSTEM display_pixels=%0d capture_beats=%0d underflows=%0d",display_pixels,capture_beats,underflows);
    $display("PASS style_accel all 6144 APB coefficients+CDC+IRQ integrated 640x48 exact RGB + active 720p display + camera capture, AXI random stalls cycles=%0d reads=%0d writes=%0d",cycles,read_transactions,write_transactions);$finish;
  end

  // ---- injected by tools/trace_ddr_read.py ----
  integer trace_fd=0,trace_cycle=0,trace_code=-1,trace_new,trace_layer=-1;
  string trace_file;
  initial if($value$plusargs("trace=%s",trace_file))begin
    trace_fd=$fopen(trace_file,"w");if(!trace_fd)$fatal(1,"cannot open trace file");
  end
  wire [2:0] trace_phase=!dut.bridge.rd_busy ? 3'd0 : arvalid ? 3'd1 : !rvalid ? 3'd2 : rready ? 3'd3 : 3'd4;
  always @(posedge clk) if(rst_n) trace_cycle<=trace_cycle+1;
  always @(negedge clk) if(trace_fd&&rst_n) begin
    trace_new={22'b0,dut.accelerator.network.busy,dut.accelerator.network.core_busy,
      (dut.accelerator.network.state==4||dut.accelerator.network.state==6),
      dut.display_read_urgent,(dut.v_arvalid&&!dut.v_arready),(dut.c_arvalid&&!dut.c_arready),
      dut.bridge.rd_owner,trace_phase};
    if(trace_new!=trace_code)begin $fwrite(trace_fd,"C %0d %0d\n",trace_cycle,trace_new);trace_code=trace_new;end
    if(arvalid&&arready)$fwrite(trace_fd,"A %0d %0d %0d\n",trace_cycle,dut.bridge.rd_owner,arlen);
    if(rvalid&&rready&&rlast)$fwrite(trace_fd,"E %0d\n",trace_cycle);
    if(trace_cycle%32==0)$fwrite(trace_fd,"L %0d %0d\n",trace_cycle,dut.display.pixel_level);
    if(dut.accelerator.network.layer_index!=trace_layer)begin
      trace_layer=dut.accelerator.network.layer_index;$fwrite(trace_fd,"N %0d %0d\n",trace_cycle,trace_layer);
    end
  end
  final if(trace_fd)$fclose(trace_fd);
  // ---- end of injected recorder ----
  always @(posedge clk) begin
    rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
    if(!rst_n) begin read_active<=0;write_active<=0;rhold<=0;bvalid<=0;end
    else begin
      n=n+1;
      if(dut.accelerator.network.busy&&dut.accelerator.network.layer_index!=previous_layer)begin
        previous_layer<=dut.accelerator.network.layer_index;
        $display("NETWORK layer=%0d total_cycles=%0d",dut.accelerator.network.layer_index,dut.accelerator.network.cycles);
        $fflush();
      end
      if(arvalid&&arready) begin
        if(araddr[3:0]!=0 || arlen>31 || (araddr[11:0]+((arlen+1)*16))>4096)$fatal(1,"AR protocol");
        rid<=arid;read_active<=1;read_addr<=araddr;read_len<=arlen;read_beat<=0;rhold<=0;read_transactions=read_transactions+1;
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
        bid<=awid;write_active<=1;write_addr<=awaddr;write_len<=awlen;write_beat<=0;write_transactions=write_transactions+1;
      end
      if(wvalid&&wready) begin
        if(write_addr>=32'h05280000&&write_addr<32'h053c0000)capture_beats=capture_beats+1;
        if(wlast!=(write_beat==write_len))$fatal(1,"WLAST");
        if(wstrb==16'hffff)mem[address_index(write_addr)]<=wdata;
        else for(b=0;b<16;b=b+1)if(wstrb[b])mem[address_index(write_addr)][b*8+:8]<=wdata[b*8+:8];
        write_addr<=write_addr+16;write_beat<=write_beat+1'b1;
        if(wlast)begin write_active<=0;bvalid<=1;end
      end
      if(bvalid&&bready)bvalid<=0;
      if(n>20000000)$fatal(1,"timeout layer=%0d state=%0d DMA=%0d/%0d",layer_index,dut.accelerator.network.state,dut.accelerator.network.dma.rs,dut.accelerator.network.dma.ws);
    end
  end
endmodule
