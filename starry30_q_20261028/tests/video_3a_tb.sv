`timescale 1ns/1ps
module video_3a_tb #(parameter integer W=128,H=64);
  reg pc=0,cc=0,dc=0,rst=0;
  always #5 pc=~pc;always #3.5 cc=~cc;always #11 dc=~dc;
  reg psel=0,penable=0,pwrite=0;reg [15:0] paddr=0;reg [31:0] pwdata=0;
  wire [31:0] prdata;wire pready,pslverr;
  reg vs=0,de=0,dvs=0;reg [15:0] raw=0;
  wire rv,rd;wire [47:0] rgb;wire [15:0] gr,gg,gb;
  reg cfault=0;wire [31:0] tone,lift;wire [2:0] histctl;
  video_apb_ctrl #(.FRAME_WIDTH(W),.FRAME_HEIGHT(H),.MIN_SAMPLES(2)) dut(
    .pclk(pc),.preset_n(rst),.psel(psel),.penable(penable),.pwrite(pwrite),.paddr(paddr),.pwdata(pwdata),
    .prdata(prdata),.pready(pready),.pslverr(pslverr),
    .i_ack_toggle(1'b0),.i_active_page(1'b0),.i_busy(1'b0),
    .i_frame_count(16'd60),.i_capture_fps(16'd12),.i_display_fps(16'd60),
    .i_drop_count(16'd0),.i_error_count(16'd0),.i_raw_fps(16'd12),
    .capture_clk(cc),.display_clk(dc),.raw_vs(vs),.raw_de(de),.raw_data(raw),
    .rgb_vs(rv),.rgb_de(rd),.rgb_data(rgb),.display_vs(dvs),.capture_fault(cfault),.resize_fault(1'b0),
    .raw_event(1'b0),.drop_count32(32'd0),.axi_errors32(32'd7),.underflows32(32'd0),
    .resize_frames32(32'd1),.display_frames32(32'd2),.csi_errors(7'd0),.reset_status(5'h1f),
    .display_stats_valid(1'b0),.display_mean(8'd0),.display_strength(8'd0),.display_at_max(1'b0),
    .gain_r(gr),.gain_g(gg),.gain_b(gb),.display_tone(tone),.display_lift(lift),.display_hist(histctl));
  debayer_top_2to1 camera(.in_pclk(cc),.in_rstn(rst),.raw_vs_i(vs),.raw_hs_i(de),.raw_de_i(de),
    .raw_valid_i(de),.raw_datax4_i(raw),.r_gain(gr),.g_gain(gg),.b_gain(gb),
    .rgb_vs_o(rv),.rgb_de_o(rd),.rgb_datax2_o(rgb));
  task write(input [15:0] addr,input [31:0] data,input bit error_expected=0);
    begin
      @(negedge pc);paddr=addr;pwdata=data;pwrite=1;psel=1;penable=0;
      @(negedge pc);penable=1;#1;
      if(pslverr!==error_expected)$fatal(1,"write %h err=%b expected=%b",addr,pslverr,error_expected);
      @(negedge pc);psel=0;penable=0;pwrite=0;
    end
  endtask
  // Back-to-back APB transfers: keep PSEL asserted, omit the idle cycle.
  task indexed_read(input [5:0] index,output [31:0] data);
    begin
      @(negedge pc);paddr='h118;pwdata=index;pwrite=1;psel=1;penable=0;
      @(negedge pc);penable=1;
      @(negedge pc);paddr='h11c;pwrite=0;penable=0;
      @(negedge pc);penable=1;#1;data=prdata;
      if(!pready||pslverr)$fatal(1,"continuous APB histogram read failed");
      @(negedge pc);psel=0;penable=0;
    end
  endtask
  task read(input [15:0] addr,output [31:0] data,input bit error_expected=0);
    begin
      @(negedge pc);paddr=addr;pwrite=0;psel=1;penable=0;
      @(negedge pc);penable=1;#1;data=prdata;
      if(pslverr!==error_expected)$fatal(1,"read %h err=%b expected=%b",addr,pslverr,error_expected);
      @(negedge pc);psel=0;penable=0;
    end
  endtask
  task expect_reg(input [15:0] addr,input [31:0] expected);
    reg [31:0] value;begin read(addr,value);if(value!==expected)$fatal(1,"reg %h=%h expected=%h",addr,value,expected);end
  endtask
  // Independent reference from actual RAW and Debayer output coordinates.
  integer x=0,y=0,sum=0,ns=0,hot=0,reference_bins[0:63];
  integer ref_sum,ref_ns,ref_hot,ref_bins[0:63],ref_r,ref_g,ref_b,ref_n;
  integer rr,rg,rb,rn,yy0,yy1,j;
  reg pv=0,pd=0;
  always @(posedge cc) if(rst) begin
    if(pv&&!rv) begin
      x=0;y=0;sum=0;ns=0;hot=0;for(j=0;j<64;j=j+1)reference_bins[j]=0;
    end
    if(rd&&!rv&&x%8==0&&y%8==0) begin
      yy0=(int'(rgb[7:0])+2*int'(rgb[15:8])+int'(rgb[23:16]))/4;
      yy1=(int'(rgb[31:24])+2*int'(rgb[39:32])+int'(rgb[47:40]))/4;
      sum=sum+yy0+yy1;ns=ns+2;reference_bins[yy0/4]++;reference_bins[yy1/4]++;
      if(rgb[7:0]>=232||rgb[15:8]>=232||rgb[23:16]>=232)hot++;
      if(rgb[31:24]>=232||rgb[39:32]>=232||rgb[47:40]>=232)hot++;
    end
    if(pd&&!rd)y++;
    if(!rd)x=0;else x++;
    if(rv&&!pv&&ns!=0) begin
      ref_sum=sum;ref_ns=ns;ref_hot=hot;for(j=0;j<64;j=j+1)ref_bins[j]=reference_bins[j];
    end
    pv=rv;pd=rd;
  end
  // Each cell uses B,Gr on even row; Gb,R on odd. Vary columns and rows.
  task frame(input integer mode,input integer shorten=0);
    integer fx,fy,b,g0,g1,r;
    begin
      rr=0;rg=0;rb=0;rn=0;
      @(negedge cc);vs=1;de=0;repeat(20)@(negedge cc);vs=0;repeat(10)@(negedge cc);
      for(fy=0;fy<H;fy++) begin
        for(fx=0;fx<(shorten&&fy==7?W/2-1:W/2);fx++) begin
          b=mode==2?0:40+(fx%7);g0=80+(fy/8)%9;g1=88+(fy/8)%9;r=mode==1?240:60+(fx%5);
          if(mode==3)begin b=80;g0=80;g1=80;r=80;end
          if(mode==4)begin b=50;g0=75;g1=75;r=100;end
          raw=fy%2?{8'(r),8'(g1)}:{8'(g0),8'(b)};de=1;
          if(fx%8==0&&fy%8==1&&b>=8&&b<248&&r>=8&&r<248)begin
            rr+=r;rg+=g0+g1;rb+=b;rn++;
          end
          @(negedge cc);
        end
        de=0;repeat(12)@(negedge cc);
      end
      vs=1;repeat(40)@(negedge cc);
      ref_r=rr;ref_g=rg;ref_b=rb;ref_n=rn;
      repeat(20)@(negedge pc);
      if(W==1920)$display("1080p frame %0d complete: AE=%0d AWB=%0d",mode,ref_ns,ref_n);
    end
  endtask
  reg overlap_check=0;integer overlap_packets=0;
  always @(posedge pc)if(overlap_check&&dut.stats_arrived)begin
    if(dut.stats_received[10*32+:32]!==32'(overlap_packets))
      $fatal(1,"new RAW header mislabeled previous RGB tail: packet %0d cfg %0d",overlap_packets,dut.stats_received[10*32+:32]);
    overlap_packets++;
  end
  task adjacent_frames;
    integer nf,fx,fy;
    begin
      for(nf=0;nf<2;nf++)begin
        @(negedge cc);vs=1;de=0;@(negedge cc);vs=0;repeat(10)@(negedge cc);
        for(fy=0;fy<H;fy++)begin
          for(fx=0;fx<W/2;fx++)begin de=1;raw=16'h5050;@(negedge cc);end
          de=0;repeat(12)@(negedge cc);
        end
        vs=1;@(negedge cc);
      end
      repeat(40)@(negedge cc);repeat(20)@(negedge pc);
    end
  endtask
  integer k,total_bin;reg [31:0] value,seq,oldframe,hframe,meta_sum;
  initial begin
    #100;rst=1;repeat(10)@(negedge pc);
    expect_reg(0,32'h4f534431);expect_reg('h034,'h10000);expect_reg('h038,'h1ff);
    expect_reg('h060,'h168);expect_reg('h064,256);expect_reg('h068,'h1a9);expect_reg('h028,0);
    read('h0d0,value);if(value&1)$fatal(1,"valid before first frame");
    write('h050,1);expect_reg('h054,1);write('h050,1,1);
    // In-flight payload stays locked when shadow values change.
    write('h040,256);write('h044,256);write('h048,256);
    expect_reg('h060,'h168);
    frame(0);expect_reg('h058,1);expect_reg('h060,'h168);expect_reg('h0dc,1);
    expect_reg('h0c4,ref_sum);expect_reg('h0e4,ref_ns);expect_reg('h0e8,ref_hot);
    expect_reg('h180,ref_r);expect_reg('h184,ref_g);expect_reg('h188,ref_b);expect_reg('h18c,ref_n);
    write('h050,1);write('h108,1);write('h108,1,1);read('h11c,value,1);
    frame(1);expect_reg('h058,2);expect_reg('h060,256);expect_reg('h0dc,2);
    expect_reg('h0c4,ref_sum);expect_reg('h0e8,ref_hot);
    // Allow all 78 individually handshaken words to arrive.
    repeat(1500)@(negedge pc);read('h10c,value);if((value&3)!=2)$fatal(1,"hist not locked %h",value);
    total_bin=0;
    for(k=0;k<64;k++) begin
      write('h118,k);read('h11c,value);if(value!=ref_bins[k])$fatal(1,"bin %d got %d expected %d",k,value,ref_bins[k]);
      total_bin+=value;
    end
    if(total_bin!=ref_ns)$fatal(1,"bin sum mismatch");
    for(k=63;k>=0;k--)begin
      indexed_read(k,value);
      if(value!==ref_bins[k])$fatal(1,"continuous INDEX/DATA bin %0d got %0d expected %0d",k,value,ref_bins[k]);
    end
    if(W==1920)begin
      if(ref_ns!=32400||ref_n!=16200)$fatal(1,"1080p sample density mismatch");
      $display("PASS full 1920x1080 gain/Debayer/unified stats: two frames, 32400 AE pixels, 16200 RAW cells, exact 64 bins, CFG tag/apply");$finish;
    end
    write('h128,0);read('h12c,meta_sum);if(meta_sum!=ref_sum)$fatal(1,"frozen sum");
    read('h110,hframe);read('h0c0,seq);
    frame(2);expect_reg('h18c,0);read('h0d0,value);if((value&17)!=1)$fatal(1,"AWB invalid must retain AE validity");
    expect_reg('h110,hframe);write('h128,0);expect_reg('h12c,meta_sum);
    read('h0c0,value);if(value!=seq+1)$fatal(1,"live stats stalled while hist locked");
    write('h118,64,1);write('h128,14,1);read('h1034,value,1);write('h034,1,1);write('h041,1,1);
    write('h108,2);write('h108,1);frame(2);repeat(1500)@(negedge pc);
    write('h128,8);read('h12c,value);if((value&17)!=1)$fatal(1,"hist must accept AE valid / AWB invalid frame");
    write('h108,2);
    read('h0c0,seq);frame(0,1);expect_reg('h0c0,seq);
    cfault=1;frame(0);expect_reg('h0c0,seq);cfault=0;
    write('h190,32'h00080800);write('h050,1,1);write('h190,32'h00f80800);
    write('h194,255);write('h050,1,1);write('h194,512);
    write('h080,3,1);write('h04c,'h00112201);write('h100,5);write('h050,2);
    repeat(30)@(negedge dc);if(tone!='h00202001)$fatal(1,"display applied before frame");
    dvs=1;repeat(20)@(negedge dc);expect_reg('h05c,1);expect_reg('h06c,'h00112201);expect_reg('h104,5);
    expect_reg('h148,7);
    // Neutral filter includes exact max/min endpoint; one Q8 LSB below rejects.
    write('h190,32'h00f80801);write('h194,512);write('h050,1);frame(4);expect_reg('h18c,ref_n);
    write('h194,511);write('h050,1);frame(4);expect_reg('h18c,0);
    frame(3);expect_reg('h18c,ref_n);
    // Source backpressure preserves the in-flight packet and reports overrun.
    read('h0c0,seq);force dut.stats_ready=0;frame(3);frame(3);expect_reg('h0c0,seq);
    read('h0d0,value);if(!(value&8))$fatal(1,"source overrun not reported");
    release dut.stats_ready;repeat(50)@(negedge pc);expect_reg('h0c0,seq+1);
    // Sequence zero after wrap still contains a valid full snapshot.
    @(negedge pc);dut.stats_seq=32'hffffffff;frame(3);expect_reg('h0c0,0);
    read('h0d0,value);if(!(value&1))$fatal(1,"valid incorrectly tied to nonzero seq");
    write('h108,1);@(negedge pc);rst=0;repeat(12)@(negedge pc);rst=1;repeat(20)@(negedge pc);
    expect_reg('h10c,'h100);expect_reg('h0c0,0);expect_reg('h054,0);expect_reg('h060,'h168);
    frame(0);expect_reg('h0c0,1);expect_reg('h0dc,0);
    overlap_check=1;
    fork
      adjacent_frames();
      begin wait(!vs);repeat(100)@(negedge cc);write('h040,300);write('h050,1);end
    join
    overlap_check=0;
    if(overlap_packets!=2)$fatal(1,"short VS overlap lost a full statistics frame");
    expect_reg('h0c0,3);expect_reg('h0dc,1);
    $display("PASS unified APB + real gain/Debayer: coherent AE/AWB, RAW phase, frame tags, 64 bins/frozen META, faults, CDC apply, no aliases");$finish;
  end
  initial begin #1000000000;$fatal(1,"timeout");end
endmodule
