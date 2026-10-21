// Six paired raw/result slots. A slot is immutable while NN or display owns it.
// Finite queue exhaustion is counted; throughput below capture is never hidden.
// PAD_PITCH=1 strides each captured row up to a 4 KiB boundary so style_network
// (with its matching PAD_PITCH) can read a whole row in a single AXI burst.
// PAD_PITCH=0 keeps the compact contiguous layout (original behaviour).
module style_frame_store # (parameter FRAME_PIXELS=307200,
                            parameter FRAME_WIDTH=640,
                            parameter PAD_PITCH=0)(
  input wire clk,rst_n,
  input wire cap_valid,output wire cap_ready,input wire [33:0] cap_packet,
  input wire stream_enable,nn_ready,nn_done,nn_error,
  output reg nn_start,output reg [31:0] nn_source,nn_result,
  input wire display_frame_event,display_safe,
  output reg [2:0] display_slot,output reg display_valid,
  output reg [31:0] captured,dropped,inferred,infer_errors,display_frame_id,
  output reg [31:0] awaddr,output wire [7:0] awlen,output wire awvalid,input wire awready,
  output wire [127:0] wdata,output wire [15:0] wstrb,output wire wlast,wvalid,input wire wready,
  input wire [1:0] bresp,input wire bvalid,output wire bready
);
  localparam FREE=0,CAPTURE=1,READY=2,INFER=3,COMPLETE=4,DISPLAY=5;
  // One AXI write burst is 32 beats x 16 B = 512 B.  A row is FRAME_WIDTH*4 B.
  localparam integer ROW_BLOCKS = (FRAME_WIDTH*4 + 511) / 512;      // 5 for 640
  localparam integer RAW_PITCH  = FRAME_WIDTH*4;                    // 2560 for 640
  localparam integer PAD_STRIDE = PAD_PITCH ? ((RAW_PITCH + 4095) & ~4095) : RAW_PITCH;
  // Step applied after each 512 B block: normally 512, but the last block of a
  // row jumps to the next padded row start.
  reg [15:0] blk_in_row;
  wire row_last_block = (blk_in_row == ROW_BLOCKS-1);
  wire [31:0] PAD_STEP = (PAD_PITCH && row_last_block)
                       ? (PAD_STRIDE - (ROW_BLOCKS-1)*512) : 32'd512;
  reg [2:0] ownership[0:5];reg [31:0] frame_ids[0:5];
  reg [2:0] cap_slot,infer_slot;reg cap_active,frame_bad,frame_final,infer_active,display_pending;
  reg [18:0] cap_pixels;reg [20:0] cap_offset;
  reg [1:0] pack_index;reg [4:0] fill_index,send_index;
  (* syn_ramstyle="block_ram" *) reg [127:0] burst_buffer[0:31];
  reg [127:0] pack,send_word,pack_next;
  reg [2:0] state;localparam COLLECT=0,ADDR=1,PREFETCH=2,SEND=3,RESP=4;
  function [31:0] raw_base;
    input [2:0] slot;
    begin case(slot)
      0:raw_base=32'h05000000;1:raw_base=32'h05140000;2:raw_base=32'h05280000;
      3:raw_base=32'h053c0000;4:raw_base=32'h05500000;default:raw_base=32'h05640000;
    endcase end
  endfunction
  reg free_found;reg [2:0] free_slot;
  reg [2:0] ready_queue[0:5];reg [2:0] ready_head,ready_tail;reg [3:0] ready_count;
  reg [2:0] latest_slot;reg latest_valid;
  wire ready_found=ready_count!=0;
  wire [2:0] ready_slot=ready_queue[ready_head],complete_slot=latest_slot;
  wire complete_found=latest_valid&&ownership[latest_slot]==COMPLETE;
  wire pop_ready=stream_enable&&nn_ready&&!infer_active&&ready_found;
  wire push_ready=state==RESP&&bvalid&&bready&&frame_final&&!frame_bad&&bresp==0;
  integer i;
  always @* begin
    free_found=0;free_slot=0;
    for(i=0;i<6;i=i+1)begin
      if(ownership[i]==FREE&&!free_found)begin free_found=1;free_slot=i;end
    end
    pack_next=pack;pack_next[pack_index*32+:32]=cap_packet[31:0];
  end
  assign cap_ready=state==COLLECT;
  assign awvalid=state==ADDR;assign awlen=31;
  assign wdata=send_word;assign wstrb=16'hffff;assign wvalid=state==SEND;assign wlast=send_index==31;
  assign bready=state==RESP;
  integer s;
  wire [4:0] burst_read_address=state==PREFETCH ? 5'd0:send_index+5'd1;
  always @(posedge clk)begin
    if(state==COLLECT&&cap_valid&&cap_ready&&cap_active&&!cap_packet[33]&&pack_index==3&&(!cap_packet[32]||cap_pixels==FRAME_PIXELS-1))
      burst_buffer[fill_index]<=pack_next;
    if(state==PREFETCH || (wvalid&&wready&&!wlast))send_word<=burst_buffer[burst_read_address];
  end
  always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
      state<=COLLECT;cap_active<=0;cap_slot<=0;infer_slot<=0;infer_active<=0;frame_bad<=0;frame_final<=0;
      cap_pixels<=0;cap_offset<=0;blk_in_row<=0;pack_index<=0;fill_index<=0;send_index<=0;pack<=0;awaddr<=0;
      nn_start<=0;nn_source<=0;nn_result<=0;display_slot<=0;display_valid<=0;display_pending<=0;
      captured<=0;dropped<=0;inferred<=0;infer_errors<=0;display_frame_id<=0;
      ready_head<=0;ready_tail<=0;ready_count<=0;latest_slot<=0;latest_valid<=0;
      for(s=0;s<6;s=s+1)begin ownership[s]<=FREE;frame_ids[s]<=0;end
    end else begin
      nn_start<=0;
      // Capture commits enter FIFO order; a single inference job completes in
      // that order, so latest completion needs no cascade of 32-bit compares.
      case({push_ready,pop_ready})
        2'b10:ready_count<=ready_count+1'b1;
        2'b01:ready_count<=ready_count-1'b1;
        default:begin end
      endcase
      if(push_ready)begin ready_queue[ready_tail]<=cap_slot;ready_tail<=ready_tail==5 ? 0:ready_tail+1'b1;end
      if(pop_ready)ready_head<=ready_head==5 ? 0:ready_head+1'b1;
      if(display_frame_event)display_pending<=1;
      if(display_pending&&display_safe)begin
        display_pending<=0;
        if(complete_found)begin
          if(display_valid)ownership[display_slot]<=FREE;
          for(s=0;s<6;s=s+1)if(ownership[s]==COMPLETE&&s!=complete_slot)ownership[s]<=FREE;
          ownership[complete_slot]<=DISPLAY;display_slot<=complete_slot;display_valid<=1;display_frame_id<=frame_ids[complete_slot];
          latest_valid<=0;
        end
      end
      if(pop_ready)begin
        nn_start<=1;nn_source<=raw_base(ready_slot);nn_result<=raw_base(ready_slot)+32'h00800000;
        ownership[ready_slot]<=INFER;infer_slot<=ready_slot;infer_active<=1;
      end
      if(nn_done&&infer_active)begin
        infer_active<=0;
        if(nn_error)begin ownership[infer_slot]<=FREE;infer_errors<=infer_errors+1'b1;end
        else begin ownership[infer_slot]<=COMPLETE;inferred<=inferred+1'b1;latest_slot<=infer_slot;latest_valid<=1;end
      end
      case(state)
        COLLECT:if(cap_valid&&cap_ready)begin
          if(cap_packet[33])begin
            if(cap_active)begin ownership[cap_slot]<=FREE;dropped<=dropped+1'b1;end
            cap_active<=free_found;cap_slot<=free_slot;cap_pixels<=1;cap_offset<=0;blk_in_row<=0;pack_index<=1;fill_index<=0;
            pack[31:0]<=cap_packet[31:0];frame_bad<=0;frame_final<=0;
            if(free_found)ownership[free_slot]<=CAPTURE;
            else dropped<=dropped+1'b1;
          end else if(cap_active)begin
            if(cap_packet[32]&&cap_pixels!=FRAME_PIXELS-1)begin
              ownership[cap_slot]<=FREE;cap_active<=0;dropped<=dropped+1'b1;pack_index<=0;fill_index<=0;
            end else begin
              pack<=pack_next;cap_pixels<=cap_pixels+1'b1;pack_index<=pack_index+1'b1;
              if(pack_index==3)begin
                fill_index<=fill_index+1'b1;
                if(fill_index==31)begin awaddr<=raw_base(cap_slot)+cap_offset;frame_final<=cap_packet[32];state<=ADDR;end
              end
            end
          end
        end
        ADDR:if(awvalid&&awready)state<=PREFETCH;
        PREFETCH:begin send_index<=0;state<=SEND;end
        SEND:if(wvalid&&wready)begin if(wlast)state<=RESP;else send_index<=send_index+1'b1;end
        RESP:if(bvalid&&bready)begin
          if(bresp!=0)frame_bad<=1;
          // A captured row is FRAME_WIDTH*4 bytes = ROW_BLOCKS x 512 B.
          // With PAD_PITCH the row start advances to the next 4 KiB boundary.
          cap_offset<=cap_offset+PAD_STEP;
          blk_in_row<=row_last_block ? 16'd0 : blk_in_row+16'd1;
          state<=COLLECT;
          if(frame_final)begin
            cap_active<=0;
            if(frame_bad||bresp!=0)begin ownership[cap_slot]<=FREE;dropped<=dropped+1'b1;end
            else begin ownership[cap_slot]<=READY;frame_ids[cap_slot]<=captured;captured<=captured+1'b1;end
          end
        end
      endcase
    end
  end
endmodule
