`include "../defines.v"
// Exact area resize, 3 input pixels/rows -> 2 output pixels/rows.
// Input: two adjacent RGB888 pixels, first pixel in bits [23:0].
// Horizontal sums remain 10-bit; divide only once after vertical weighting.
// Output: pairs of padded RGB888 (0x00BBGGRR), first pixel in [63:32].
module rgb_area_resize_3to2 #(parameter SOURCE_WIDTH=`CFG_RESIZE_RGB_AREA_RESIZE_3TO2_V_PARAMETER_SOURCE_WIDTH,SOURCE_HEIGHT=`CFG_RESIZE_RGB_AREA_RESIZE_3TO2_V_PARAMETER_SOURCE_HEIGHT)(
 input clk,rst_n,i_vs,i_de,
 input [`CFG_BITS_48-1:0] i_rgb,
 output reg o_vs,o_valid,
 output reg [`CFG_BITS_64-1:0] o_data,
 output reg fault,
 output reg [`CFG_BITS_32-1:0] completed_frames
);
 localparam OUT_W=`CFG_RESIZE_RGB_AREA_RESIZE_3TO2_V_LOCALPARAM_OUT_W;
 localparam BANK_DEPTH=`CFG_RESIZE_RGB_AREA_RESIZE_3TO2_V_LOCALPARAM_BANK_DEPTH;
 localparam BA=`CFG_RESIZE_RGB_AREA_RESIZE_3TO2_V_LOCALPARAM_BA;
 reg vs_d,de_d;
 reg [`CFG_BITS_2-1:0] phase_x,phase_y;
 reg [`CFG_BITS_12-1:0] in_pairs,in_rows,h_index;
 reg frame_started;
 reg [`CFG_BITS_24-1:0] previous;
 wire fs=vs_d && !i_vs;
 reg [`CFG_BITS_2-1:0] hx_next;
 reg [`CFG_BITS_24-1:0] previous_next;
 reg [`CFG_BITS_2-1:0] hc;
 reg [`CFG_BITS_30-1:0] h0,h1,hs;
 reg [`CFG_BITS_24-1:0] pix;
 integer j,c;
 reg [`CFG_BITS_10-1:0] a,b;
 always @(*) begin
   hx_next=phase_x;previous_next=previous;hc=0;h0=0;h1=0;hs=0;pix=0;a=0;b=0;
   for(j=0;j<2;j=j+1) begin
     pix=i_rgb[j*24+:24];
     if(hx_next!=0) begin
       for(c=0;c<3;c=c+1) begin
         a={2'b0,previous_next[c*8+:8]};b={2'b0,pix[c*8+:8]};
         hs[c*10+:10]=(hx_next==1) ? ((a<<1)+b) : (a+(b<<1));
       end
       if(hc==0) h0=hs;else h1=hs;
       hc=hc+1'b1;
     end
     previous_next=pix;
     hx_next=(hx_next==2) ? 0 : hx_next+1'b1;
   end
 end
 // Each beat produces at most two adjacent horizontal outputs: one per bank.
 wire en0=i_de && !fault && ((hc>0 && !h_index[0]) || hc==2);
 wire en1=i_de && !fault && ((hc>0 && h_index[0]) || hc==2);
 wire [`CFG_RESIZE_RGB_AREA_RESIZE_3TO2_V_RANGE_1] addr0=h_index[BA:1]+h_index[0];
 wire [`CFG_RESIZE_RGB_AREA_RESIZE_3TO2_V_RANGE_2] addr1=h_index[BA:1];
 wire [`CFG_BITS_30-1:0] now0=h_index[0] ? h1 : h0;
 wire [`CFG_BITS_30-1:0] now1=h_index[0] ? h0 : h1;
 (* syn_ramstyle="block_ram" *) reg [`CFG_BITS_30-1:0] line0[`CFG_RESIZE_RGB_AREA_RESIZE_3TO2_V_RANGE_3];
 (* syn_ramstyle="block_ram" *) reg [`CFG_BITS_30-1:0] line1[`CFG_RESIZE_RGB_AREA_RESIZE_3TO2_V_RANGE_4];
 reg [`CFG_BITS_30-1:0] prev0,prev1;
 always @(posedge clk) begin
   if(en0) begin prev0<=line0[addr0];line0[addr0]<=now0;end
   if(en1) begin prev1<=line1[addr1];line1[addr1]<=now1;end
 end
 reg [`CFG_BITS_30-1:0] cur0,cur1;
 reg [`CFG_BITS_2-1:0] count1,yp1;
 reg odd1;
 reg v1,v2;
 reg [`CFG_BITS_36-1:0] sum0,sum1;
 reg [`CFG_BITS_2-1:0] count2;
 reg odd2;
 function [`CFG_BITS_36-1:0] vertical;
   input [`CFG_BITS_30-1:0] prev,cur;input [`CFG_BITS_2-1:0] yp;
   integer k;reg [`CFG_BITS_12-1:0] a12,b12;
   begin
     for(k=0;k<3;k=k+1) begin
       a12={2'b0,prev[k*10+:10]};b12={2'b0,cur[k*10+:10]};
       vertical[k*12+:12]=(yp==1) ? ((a12<<1)+b12) : (a12+(b12<<1));
     end
   end
 endfunction
 // Four short compare/subtract stages divide by 9 without DSPs.
 wire [`CFG_BITS_24-1:0] color0,color1;
 genvar channel;
 generate for(channel=0;channel<3;channel=channel+1) begin: div_channels
   resize_div9 d0(.clk(clk),.n(sum0[channel*12+:12]),.q(color0[channel*8+:8]));
   resize_div9 d1(.clk(clk),.n(sum1[channel*12+:12]),.q(color1[channel*8+:8]));
 end endgenerate
 reg [`CFG_BITS_4-1:0] divide_valid,divide_odd;
 reg [`CFG_BITS_2-1:0] divide_count[`CFG_RANGE_0_3];
 integer stage;
 reg [`CFG_BITS_32-1:0] spare;
 reg spare_valid;
 reg [`CFG_BITS_32-1:0] first_color,second_color;
 reg [`CFG_BITS_4-1:0] vs_pipe;
 always @(*) begin
   first_color={8'b0,divide_odd[3] ? color1 : color0};
   second_color={8'b0,divide_odd[3] ? color0 : color1};
 end
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin
     vs_d<=0;de_d<=0;phase_x<=0;phase_y<=0;previous<=0;
     in_pairs<=0;in_rows<=0;h_index<=0;frame_started<=0;fault<=0;completed_frames<=0;
     cur0<=0;cur1<=0;count1<=0;yp1<=0;odd1<=0;v1<=0;
     sum0<=0;sum1<=0;count2<=0;odd2<=0;v2<=0;
     divide_valid<=0;divide_odd<=0;
     for(stage=0;stage<4;stage=stage+1) divide_count[stage]<=0;
     spare<=0;spare_valid<=0;o_data<=0;o_valid<=0;o_vs<=0;vs_pipe<=0;
   end else begin
     vs_d<=i_vs;de_d<=i_de;vs_pipe<={vs_pipe[2:0],i_vs};o_vs<=vs_pipe[3];
     o_valid<=0;
     v1<=i_de && phase_y!=0 && frame_started && !fault;
     cur0<=now0;cur1<=now1;count1<=hc;yp1<=phase_y;odd1<=h_index[0];
     v2<=v1;sum0<=vertical(prev0,cur0,yp1);sum1<=vertical(prev1,cur1,yp1);
     count2<=count1;odd2<=odd1;
     divide_valid<={divide_valid[2:0],v2};divide_odd<={divide_odd[2:0],odd2};
     divide_count[0]<=count2;
     for(stage=1;stage<4;stage=stage+1) divide_count[stage]<=divide_count[stage-1];
     if(fs) begin
       if(frame_started && in_rows!=SOURCE_HEIGHT) fault<=1;
       phase_x<=0;phase_y<=0;in_pairs<=0;in_rows<=0;h_index<=0;previous<=0;frame_started<=1;
       if(spare_valid) fault<=1;
     end else if(i_de && frame_started) begin
       previous<=previous_next;phase_x<=hx_next;h_index<=h_index+hc;in_pairs<=in_pairs+1'b1;
       if(in_pairs>=SOURCE_WIDTH/2 || in_rows>=SOURCE_HEIGHT) fault<=1;
     end else if(de_d && !i_de && frame_started) begin
       if(in_pairs!=SOURCE_WIDTH/2 || h_index!=OUT_W) fault<=1;
       if(in_rows==SOURCE_HEIGHT-1 && in_pairs==SOURCE_WIDTH/2 && h_index==OUT_W && !fault) begin completed_frames<=completed_frames+1'b1;frame_started<=0;end
       in_rows<=in_rows+1'b1;in_pairs<=0;h_index<=0;phase_x<=0;
       phase_y<=phase_y==2 ? 0 : phase_y+1'b1;
     end
     if(divide_valid[3] && !fault) begin
       if(spare_valid) begin
         o_data<={spare,first_color};o_valid<=1;
         if(divide_count[3]==2) begin spare<=second_color;spare_valid<=1;end
         else spare_valid<=0;
       end else if(divide_count[3]==2) begin o_data<={first_color,second_color};o_valid<=1;end
       else begin spare<=first_color;spare_valid<=1;end
     end
   end
 end
endmodule

// Valid input n <= 9*255. Adding 4 implements nearest-integer rounding.
module resize_div9(input clk,input [`CFG_BITS_12-1:0] n,output wire [`CFG_BITS_8-1:0] q);
 reg [`CFG_BITS_20-1:0] state[`CFG_RANGE_0_3]; // {quotient, remainder}; validity is carried by caller.
 function [`CFG_BITS_20-1:0] step;
   input [`CFG_BITS_20-1:0] value;input integer high_bit;
   reg [`CFG_BITS_12-1:0] remn,threshold;reg [`CFG_BITS_8-1:0] quotient;integer k;
   begin
     remn=value[11:0];quotient=value[19:12];
     for(k=high_bit;k>high_bit-2;k=k-1) begin
       threshold=12'd9<<k;
       if(remn>=threshold) begin remn=remn-threshold;quotient[k]=1;end
     end
     step={quotient,remn};
   end
 endfunction
 always @(posedge clk) begin
   state[0]<=step({8'b0,n+12'd4},7);
   state[1]<=step(state[0],5);
   state[2]<=step(state[1],3);
   state[3]<=step(state[2],1);
 end
 assign q=state[3][19:12];
endmodule
