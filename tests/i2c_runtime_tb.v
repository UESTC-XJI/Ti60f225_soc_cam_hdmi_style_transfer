`timescale 1ns/1ps
// Open-drain bit-level sensor model; uses the real controller and I2C core.
module i2c_runtime_tb;
  reg clk=0,rst=0,mwr=0,mrd=0,ae_mode=0,en=0,sv=0,fs=0;
  reg[15:0] ma=0;reg[7:0] md=0;
  wire cfg,wd,rd,we,re;wire[7:0] result;
  wire aw,ar,ready,limit,fault;wire[15:0] aa,exp,vts;wire[7:0] ad,mean;
  wire sclo,sdao,scloe,sdaoe;tri1 scl,sda;
  reg slave_low=0,nack=0;
  assign scl=scloe?1'bz:sclo;
  assign sda=sdaoe?1'bz:sdao;
  assign sda=slave_low?1'b0:1'bz;
  always #5 clk=~clk;
  i2c_master_ctrl_top #(.RUNTIME_ENABLE(1),.CLK_DIV(2)) bus(
    .clk(clk),.rst_n(rst),.scl_pad_i(scl),.scl_pad_o(sclo),.scl_padoen_o(scloe),
    .sda_pad_i(sda),.sda_pad_o(sdao),.sda_padoen_o(sdaoe),
    .runtime_wr_en(ae_mode?aw:mwr),.runtime_rd_en(ae_mode?ar:mrd),
    .runtime_addr(ae_mode?aa:ma),.runtime_data(ae_mode?ad:md),
    .config_done(cfg),.runtime_wr_done(wd),.runtime_rd_done(rd),
    .runtime_wr_error(we),.runtime_rd_error(re),.runtime_read_data(result));
  sc431hai_auto_exposure #(.WAIT_FRAMES(1),.TIMEOUT_CYCLES(20000)) ae(
    .clk(clk),.rst_n(rst),.i_config_done(cfg && ae_mode),.i_enable(en),.i_sensor_frame_start(fs),
    .i_stats_valid(sv),.i_highlights(1'b0),.i_mean(8'd40),.i_target(8'd96),
    .o_wr_en(aw),.o_rd_en(ar),.o_addr(aa),.o_data(ad),.i_wr_done(wd),.i_rd_done(rd),
    .i_wr_error(we),.i_rd_error(re),.i_read_data(result),.o_exposure(exp),.o_vts(vts),
    .o_mean(mean),.o_ready(ready),.o_at_limit(limit),.o_error(fault),
    .i_high_protect(1'b0),.i_high_permille(10'd0),.i_high_limit(8'd10));
  reg[7:0] mem[0:65535];reg[15:0] pointer=0;
  reg[7:0] rxbyte=0,txbyte=0;
  integer phase=0,bitno=0,stage=0,ackstep=0,nextphase=1,txbit=7,starts=0,stops=0;
  // phase: 0 idle, 1 receive, 2 slave ACK, 3 transmit, 4 master ACK.
  always @(negedge sda) if(scl===1'b1 && !slave_low) begin
    phase=1;stage=0;bitno=0;rxbyte=0;starts=starts+1;
  end
  always @(posedge sda) if(scl===1'b1 && !slave_low) begin phase=0;stops=stops+1;end
  always @(posedge scl) begin
    if(phase==1) begin
      rxbyte={rxbyte[6:0],sda};bitno=bitno+1;
      if(bitno==8) begin
        nextphase=1;
        case(stage)
          0:begin
            if(rxbyte[7:1]!=7'h30) $fatal(1,"I2C wrong sensor address %h",rxbyte);
            if(rxbyte[0]) begin nextphase=3;txbyte=mem[pointer];end
            else stage=1;
          end
          1:begin pointer[15:8]=rxbyte;stage=2;end
          2:begin pointer[7:0]=rxbyte;stage=3;end
          3:begin if(!nack) mem[pointer]=rxbyte;pointer=pointer+1;end
        endcase
        bitno=0;phase=2;ackstep=0;
      end
    end else if(phase==2) ackstep=2;
    else if(phase==3) begin
      if(txbit==0) phase=4;else txbit=txbit-1;
    end else if(phase==4) begin
      if(sda!==1'b1) $fatal(1,"Expected master NACK on final read byte");
      phase=0;
    end
  end
  always @(negedge scl) begin
    if(phase==2) begin
      if(ackstep==0) begin slave_low=!nack;ackstep=1;end
      else if(ackstep==2) begin
        slave_low=0;phase=nextphase;
        if(phase==3) begin txbit=7;slave_low=!txbyte[7];end
      end
    end else if(phase==3) slave_low=!txbyte[txbit];
    else if(phase==4 || phase==0) slave_low=0;
  end
  task write_reg(input[15:0] a,input[7:0] d,input integer expected_error);
    begin
      @(negedge clk);ma=a;md=d;mwr=1;@(negedge clk);mwr=0;
      wait(wd);#2;if(we!==expected_error[0]) $fatal(1,"I2C write error status addr %h",a);
      repeat(3) @(negedge clk);
    end
  endtask
  task read_reg(input[15:0] a,input[7:0] d,input integer expected_error);
    begin
      @(negedge clk);ma=a;mrd=1;@(negedge clk);mrd=0;
      wait(rd);#2;
      if(re!==expected_error[0] || (!expected_error && result!==d))
        $fatal(1,"I2C read %h got %h error %b expected %h error %d",a,result,re,d,expected_error);
      repeat(3) @(negedge clk);
    end
  endtask
  integer i;
  initial begin
    for(i=0;i<65536;i=i+1) mem[i]=0;
    mem['h320e]='h85;mem['h320f]='hdc; // Reserved bit 7 must be ignored by AE.
    repeat(5) @(negedge clk);rst=1;
    wait(cfg);repeat(4) @(negedge clk);
    read_reg('h3e08,'h83,0);read_reg('h3e09,'h20,0);
    read_reg('h320e,'h85,0);read_reg('h320f,'hdc,0);
    read_reg('h3e00,'h01,0);read_reg('h3e01,'hbb,0);read_reg('h3e02,'hf0,0);
    write_reg('h3e00,'ha0,0);write_reg('h3e01,'h32,0);write_reg('h3e02,'h05,0);
    read_reg('h3e00,'ha0,0);read_reg('h3e01,'h32,0);read_reg('h3e02,'h05,0);
    nack=1;write_reg('h1234,'h67,1);read_reg('h320e,0,1);
    nack=0;read_reg('h320f,'hdc,0);write_reg('h1234,'h89,0);read_reg('h1234,'h89,0);
    ae_mode=1;wait(ready || fault);#2;
    if(fault || exp!=800 || vts!=1500) $fatal(1,"AE real bus boot");
    repeat(4) @(negedge clk);en=1;sv=1;@(negedge clk);sv=0;
    wait(ae.state==5);@(negedge clk);fs=1;@(negedge clk);fs=0;
    wait(exp==900 || fault);#2;
    if(fault || mem['h3812]!='h30 || mem['h3e00]!='ha0 || mem['h3e01]!='h38 || mem['h3e02]!='h45)
      $fatal(1,"AE real bus group hold result");
    $display("PASS I2C: 165-entry init, 6.160x analog gain readback, repeated starts, read/write/NACK, AE group update (%0d starts, %0d stops)",starts,stops);$finish;
  end
  initial begin #20000000;$fatal(1,"I2C watchdog phase %0d bus cfg %b wrstate %0d rdstate %0d",phase,cfg,bus.u_i2c_ctrl.wr_state,bus.u_i2c_ctrl.rd_state);end
endmodule
