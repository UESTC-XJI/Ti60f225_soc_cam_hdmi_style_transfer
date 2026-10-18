`timescale 1ns/1ps
module sapphire_i2c_ack_tb;
  reg clk=0,reset=1;
  always #5 clk=~clk;
  reg valid=0,write_cmd=0;
  reg [7:0] addr=0;
  reg [31:0] data=0;
  wire ready,rsp_valid;
  wire [31:0] rsp_data;
  wire sda_out,scl_out;
  reg slave_low=0;
  wire sda=sda_out&&!slave_low;
  wire scl=scl_out;
  BmbI2cCtrl dut(
    .io_ctrl_cmd_valid(valid),.io_ctrl_cmd_ready(ready),
    .io_ctrl_cmd_payload_last(1'b1),.io_ctrl_cmd_payload_fragment_opcode(write_cmd),
    .io_ctrl_cmd_payload_fragment_address(addr),.io_ctrl_cmd_payload_fragment_length(2'd0),
    .io_ctrl_cmd_payload_fragment_data(data),.io_ctrl_cmd_payload_fragment_context(4'd0),
    .io_ctrl_rsp_valid(rsp_valid),.io_ctrl_rsp_ready(1'b1),.io_ctrl_rsp_payload_last(),
    .io_ctrl_rsp_payload_fragment_opcode(),.io_ctrl_rsp_payload_fragment_data(rsp_data),
    .io_ctrl_rsp_payload_fragment_context(),.io_i2c_sda_write(sda_out),.io_i2c_sda_read(sda),
    .io_i2c_scl_write(scl_out),.io_i2c_scl_read(scl),.io_interrupt(),
    .io_systemClk(clk),.systemCd_logic_outputReset(reset));

  // SC431HAI address 0x30, with the two ID bytes; repeated START retains pointer.
  reg [15:0] pointer=0;
  reg [7:0] rxbyte=0,txbyte=0;
  integer phase=0,stage=0,bitno=0,ackstep=0,nextphase=1,txbit=7;
  always @(negedge sda) if(scl===1'b1&&!slave_low) begin
    phase=1;stage=0;bitno=0;rxbyte=0;
  end
  always @(posedge sda) if(scl===1'b1&&!slave_low) phase=0;
  always @(posedge scl) begin
    if(phase==1) begin
      rxbyte={rxbyte[6:0],sda};bitno=bitno+1;
      if(bitno==8) begin
        nextphase=1;
        case(stage)
          0:begin
            if(rxbyte[7:1]!=7'h30)$fatal(1,"Wrong slave address %h",rxbyte);
            if(rxbyte[0])begin nextphase=3;txbyte=pointer==16'h3107 ? 8'hcd : 8'h6b;end
            else stage=1;
          end
          1:begin pointer[15:8]=rxbyte;stage=2;end
          2:begin pointer[7:0]=rxbyte;stage=3;end
          default:;
        endcase
        bitno=0;phase=2;ackstep=0;
      end
    end else if(phase==2)ackstep=2;
    else if(phase==3)begin if(txbit==0)phase=4;else txbit=txbit-1;end
    else if(phase==4)begin
      if(sda!==1'b1)$fatal(1,"Read must finish with master NACK");
      phase=0;
    end
  end
  always @(negedge scl) begin
    if(phase==2) begin
      if(ackstep==0)begin slave_low=1;ackstep=1;end
      else if(ackstep==2)begin
        slave_low=0;phase=nextphase;
        if(phase==3)begin txbit=7;slave_low=!txbyte[7];end
      end
    end else if(phase==3)slave_low=!txbyte[txbit];
    else slave_low=0;
  end

  task access(input bit wr,input [7:0] a,input [31:0] d,output [31:0] r);
    begin
      @(negedge clk);valid=1;write_cmd=wr;addr=a;data=d;
      do @(posedge clk);while(!ready);
      @(negedge clk);valid=0;
      while(!rsp_valid)@(negedge clk);
      r=rsp_data;
      @(negedge clk);
    end
  endtask
  reg [31:0] ignored;
  task wr(input [7:0] a,input [31:0] d);begin access(1,a,d,ignored);end endtask
  task rd(input [7:0] a,output [31:0] d);begin access(0,a,0,d);end endtask
  task wait_clear(input [7:0] a,input [31:0] mask);
    reg [31:0] value;
    integer attempts;
    begin
      value=mask;attempts=0;
      while((value&mask)!=0&&attempts<10000)begin rd(a,value);attempts=attempts+1;end
      if(value&mask)$fatal(1,"Wait timed out: address %h value %h",a,value);
    end
  endtask
  task start_bus;begin wr('h40,'h210);wait_clear('h40,'h10);end endtask
  task stop_bus;begin wr('h40,'h420);wait_clear('h40,'h21);end endtask
  task send_checked(input [7:0] byte_value);
    reg [31:0] ack;
    begin
      rd('h0c,ack); // Drain READ-to-clear before enabling the next listener.
      wr('h0c,'h200);wr('h00,'hb00|byte_value);wr('h04,'h301);
      wait_clear('h04,'h100);rd('h0c,ack);
      if((ack&'h101)!='h100)$fatal(1,"Slave did not ACK: %h",ack);
    end
  endtask
  task id_address(input [7:0] lo);
    begin start_bus();send_checked('h60);send_checked('h31);send_checked(lo);
      start_bus();send_checked('h61);end
  endtask
  reg [31:0] value;
  initial begin
    repeat(10)@(negedge clk);reset=0;repeat(20)@(negedge clk);
    wr('h28,3);wr('h2c,100000);wr('h30,4);
    wr('h50,40);wr('h54,40);wr('h58,80);

    // Old firmware listens during its own final NACK, then leaves it unread.
    id_address('h07);wr('h00,'hbff);wr('h04,'h301);wait_clear('h04,'h100);
    rd('h08,value);if(value[7:0]!='hcd)$fatal(1,"ID high mismatch %h",value);
    stop_bus();wr('h0c,'h200);
    if(!dut.bridge_rxAck_valid)$fatal(1,"LISTEN unexpectedly cleared stale ACK");
    start_bus();wr('h00,'hb60);wr('h04,'h301);
    repeat(2000)@(negedge clk);
    rd('h04,value);if(!(value&'h100))$fatal(1,"Stale ACK did not stall TX_ACK");
    rd('h0c,value);if((value&'h101)!='h101)$fatal(1,"Master NACK not retained %h",value);
    wait_clear('h04,'h100);rd('h0c,value);
    if((value&'h101)!='h100)$fatal(1,"Slave ACK did not resume after drain %h",value);
    $display("PASS native Sapphire: STOP/LISTEN preserve ACK VALID; stale master NACK stalls TX_ACK; read drains and resumes");
    send_checked('h31);send_checked('h08);start_bus();send_checked('h61);
    wr('h0c,0);wr('h00,'hbff);wr('h04,'h301);wait_clear('h04,'h100);
    rd('h08,value);if(value[7:0]!='h6b)$fatal(1,"ID low mismatch %h",value);
    stop_bus();rd('h0c,value);
    if(value&'h100)$fatal(1,"Disabled listener retained final master NACK");

    id_address('h07);wr('h0c,0);wr('h00,'hbff);wr('h04,'h301);wait_clear('h04,'h100);
    rd('h08,value);if(value[7:0]!='hcd)$fatal(1,"Repeated ID read mismatch");
    stop_bus();
    $display("PASS native Sapphire: fixed repeated register reads complete without stale ACK backpressure");

    wr('h40,'h420);rd('h40,value);
    if((value&'h21)!='h20)$fatal(1,"Expected idle STOP pending without BUSY, got %h",value);
    wr('h40,'h40);wait_clear('h40,'h41);
    wr('h40,'h880);wait_clear('h40,'h81);rd('h40,value);
    if(value&'h8f1)$fatal(1,"RECOVER failed to finish its own STOP %h",value);
    rd('h44,value);if((value&6)!=6)$fatal(1,"Recovery did not release lines %h",value);
    $display("PASS native Sapphire: idle STOP stays pending; RECOVER already sends STOP and releases bus");
    $finish;
  end
  initial begin #10000000;$fatal(1,"Global timeout");end
endmodule
