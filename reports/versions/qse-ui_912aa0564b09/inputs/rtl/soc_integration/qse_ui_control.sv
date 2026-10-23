// Pixel-domain UI. Stable 20 ms contacts; publish only at frame boundary.
module qse_ui_control #(parameter integer DEBOUNCE_CYCLES=1485000)(
 input wire clk,rst_n,frame_start,
 input wire io_sw1,io_sw2,io_key0,io_key1,
 output reg osd_enable,compare_enable,output reg [1:0] selection
);
 wire [3:0] gpio;
 qse_gpio_sync sync_inputs(.clk(clk),.rst_n(rst_n),.io_sw1(io_sw1),.io_sw2(io_sw2),.io_key0(io_key0),.io_key1(io_key1),.gpio_read(gpio));
 localparam integer CW=DEBOUNCE_CYCLES<2 ? 1:$clog2(DEBOUNCE_CYCLES);
 reg [CW-1:0] count0,count1,counts;
 reg key0,key1;reg [1:0] switches,switch_candidate;
 reg pending_osd,pending_compare;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   count0<=0;count1<=0;counts<=0;key0<=0;key1<=0;switches<=0;switch_candidate<=0;
   pending_osd<=1;pending_compare<=1;osd_enable<=1;compare_enable<=1;selection<=0;
  end else begin
   if(gpio[0]==key0)count0<=0;
   else if(count0==DEBOUNCE_CYCLES-1)begin count0<=0;key0<=gpio[0];if(gpio[0])pending_osd<=!pending_osd;end
   else count0<=count0+1'b1;
   if(gpio[1]==key1)count1<=0;
   else if(count1==DEBOUNCE_CYCLES-1)begin count1<=0;key1<=gpio[1];if(gpio[1])pending_compare<=!pending_compare;end
   else count1<=count1+1'b1;
   if(gpio[3:2]!=switch_candidate)begin switch_candidate<=gpio[3:2];counts<=0;end
   else if(gpio[3:2]==switches)counts<=0;
   else if(counts==DEBOUNCE_CYCLES-1)begin counts<=0;switches<=gpio[3:2];end
   else counts<=counts+1'b1;
   if(frame_start)begin
    osd_enable<=pending_osd;compare_enable<=pending_compare;
    selection<={switches[1],switches[1]^switches[0]};
   end
  end
 end
endmodule
