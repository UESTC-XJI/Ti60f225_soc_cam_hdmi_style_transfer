`timescale 1ns/1ps
module qse_ui_tb;
 reg clk=0,rst_n=0,frame=0; reg [3:0] pins=4'b1100;
 wire osd_enable,compare_enable; wire [1:0] selection;
 always #5 clk=~clk;
 qse_ui_control #(.DEBOUNCE_CYCLES(4)) dut(.clk(clk),.rst_n(rst_n),.frame_start(frame),.io_sw2(pins[3]),.io_sw1(pins[2]),.io_key1(pins[1]),.io_key0(pins[0]),.*);
 task ticks(input integer n); repeat(n)begin @(posedge clk);#1;end endtask
 task commit; begin @(negedge clk);frame=1;ticks(1);@(negedge clk);frame=0;end endtask
 initial begin
 ticks(2);@(negedge clk);rst_n=1;ticks(10);
 if(!osd_enable||!compare_enable||selection!=0)$fatal(1,"defaults");
 @(negedge clk);pins[0]=1;ticks(1);@(negedge clk);pins[0]=0;ticks(10);commit();
 if(!osd_enable)$fatal(1,"bounce toggled");
 @(negedge clk);pins[0]=1;ticks(10);
 if(!osd_enable)$fatal(1,"midframe toggle");commit();
 if(osd_enable)$fatal(1,"key0 missing");ticks(20);commit();if(osd_enable)$fatal(1,"held repeats");
 @(negedge clk);pins[0]=0;ticks(10);pins[0]=1;ticks(10);commit();if(!osd_enable)$fatal(1,"second press");
 pins[1]=1;ticks(10);commit();if(compare_enable)$fatal(1,"key1 missing");
 pins[1]=0;ticks(10);pins[1]=1;ticks(10);commit();if(!compare_enable)$fatal(1,"key1 second press");
 // Alternating non-idle Gray candidates must never count as stable.
 @(negedge clk);pins[3:2]=2'b10;ticks(3);pins[3:2]=2'b00;ticks(3);pins[3:2]=2'b10;ticks(3);commit();
 if(selection!=0)$fatal(1,"unstable Gray candidates accepted");
 pins[3:2]=2'b11;ticks(10);commit();
 // Normalized Gray code 00,01,11,10 -> selections 0,1,2,3.
 pins[3:2]=2'b10;ticks(10);commit();if(selection!=1)$fatal(1,"gray1");
 pins[3:2]=2'b00;ticks(10);commit();if(selection!=2)$fatal(1,"gray2");
 pins[3:2]=2'b01;ticks(10);commit();if(selection!=3)$fatal(1,"gray3");
 $display("PASS QSE UI defaults, bounce rejection, hold, repeated presses, frame commit, Gray decode");$finish;
 end
endmodule
