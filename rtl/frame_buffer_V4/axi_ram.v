`include "../defines.v"
`timescale 1ns / 1ps

module axi_ram #
(
    // Width of data bus in bits
    parameter DATA_WIDTH = `CFG_FRAME_BUFFER_V4_AXI_RAM_V_PARAMETER_DATA_WIDTH,
    // Width of address bus in bits
    parameter ADDR_WIDTH = `CFG_FRAME_BUFFER_V4_AXI_RAM_V_PARAMETER_ADDR_WIDTH,
    // Width of wstrb (width of data bus in words)
    parameter STRB_WIDTH = `CFG_FRAME_BUFFER_V4_AXI_RAM_V_PARAMETER_STRB_WIDTH,
    // Width of ID signal
    parameter ID_WIDTH = `CFG_FRAME_BUFFER_V4_AXI_RAM_V_PARAMETER_ID_WIDTH,
    // Extra pipeline register on output
    parameter PIPELINE_OUTPUT = `CFG_FRAME_BUFFER_V4_AXI_RAM_V_PARAMETER_PIPELINE_OUTPUT
)
(
    input  wire                   clk,
    input  wire                   rst,

    input  wire [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_1]    s_axi_awid,
    input  wire [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_2]  s_axi_awaddr,
    input  wire [`CFG_BITS_8-1:0]             s_axi_awlen,
    input  wire [`CFG_BITS_3-1:0]             s_axi_awsize,
    input  wire [`CFG_BITS_2-1:0]             s_axi_awburst,
    input  wire                   s_axi_awlock,
    input  wire [`CFG_BITS_4-1:0]             s_axi_awcache,
    input  wire [`CFG_BITS_3-1:0]             s_axi_awprot,
    input  wire                   s_axi_awvalid,
    output wire                   s_axi_awready,
    input  wire [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_3]  s_axi_wdata,
    input  wire [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_4]  s_axi_wstrb,
    input  wire                   s_axi_wlast,
    input  wire                   s_axi_wvalid,
    output wire                   s_axi_wready,
    output wire [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_5]    s_axi_bid,
    output wire [`CFG_BITS_2-1:0]             s_axi_bresp,
    output wire                   s_axi_bvalid,
    input  wire                   s_axi_bready,
    input  wire [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_6]    s_axi_arid,
    input  wire [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_7]  s_axi_araddr,
    input  wire [`CFG_BITS_8-1:0]             s_axi_arlen,
    input  wire [`CFG_BITS_3-1:0]             s_axi_arsize,
    input  wire [`CFG_BITS_2-1:0]             s_axi_arburst,
    input  wire                   s_axi_arlock,
    input  wire [`CFG_BITS_4-1:0]             s_axi_arcache,
    input  wire [`CFG_BITS_3-1:0]             s_axi_arprot,
    input  wire                   s_axi_arvalid,
    output wire                   s_axi_arready,
    output wire [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_8]    s_axi_rid,
    output wire [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_9]  s_axi_rdata,
    output wire [`CFG_BITS_2-1:0]             s_axi_rresp,
    output wire                   s_axi_rlast,
    output wire                   s_axi_rvalid,
    input  wire                   s_axi_rready
);

parameter VALID_ADDR_WIDTH = `CFG_FRAME_BUFFER_V4_AXI_RAM_V_PARAMETER_VALID_ADDR_WIDTH;
parameter WORD_WIDTH = `CFG_FRAME_BUFFER_V4_AXI_RAM_V_PARAMETER_WORD_WIDTH;
parameter WORD_SIZE = `CFG_FRAME_BUFFER_V4_AXI_RAM_V_PARAMETER_WORD_SIZE;

// bus width assertions
initial begin
    if (WORD_SIZE * STRB_WIDTH != DATA_WIDTH) begin
        $error("Error: AXI data width not evenly divisble (instance %m)");
        $finish;
    end

    if (2**$clog2(WORD_WIDTH) != WORD_WIDTH) begin
        $error("Error: AXI word width must be even power of two (instance %m)");
        $finish;
    end
end

localparam [`CFG_BITS_1-1:0]
    READ_STATE_IDLE = `CFG_FRAME_BUFFER_V4_AXI_RAM_V_LOCALPARAM_READ_STATE_IDLE,
    READ_STATE_BURST = `CFG_FRAME_BUFFER_V4_AXI_RAM_V_LOCALPARAM_READ_STATE_BURST;

reg [`CFG_BITS_1-1:0] read_state_reg = READ_STATE_IDLE, read_state_next;

localparam [`CFG_BITS_2-1:0]
    WRITE_STATE_IDLE = `CFG_FRAME_BUFFER_V4_AXI_RAM_V_LOCALPARAM_WRITE_STATE_IDLE,
    WRITE_STATE_BURST = `CFG_FRAME_BUFFER_V4_AXI_RAM_V_LOCALPARAM_WRITE_STATE_BURST,
    WRITE_STATE_RESP = `CFG_FRAME_BUFFER_V4_AXI_RAM_V_LOCALPARAM_WRITE_STATE_RESP;

reg [`CFG_BITS_2-1:0] write_state_reg = WRITE_STATE_IDLE, write_state_next;

reg mem_wr_en;
reg mem_rd_en;

reg [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_10] read_id_reg = {ID_WIDTH{1'b0}}, read_id_next;
reg [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_11] read_addr_reg = {ADDR_WIDTH{1'b0}}, read_addr_next;
reg [`CFG_BITS_8-1:0] read_count_reg = 8'd0, read_count_next;
reg [`CFG_BITS_3-1:0] read_size_reg = 3'd0, read_size_next;
reg [`CFG_BITS_2-1:0] read_burst_reg = 2'd0, read_burst_next;
reg [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_12] write_id_reg = {ID_WIDTH{1'b0}}, write_id_next;
reg [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_13] write_addr_reg = {ADDR_WIDTH{1'b0}}, write_addr_next;
reg [`CFG_BITS_8-1:0] write_count_reg = 8'd0, write_count_next;
reg [`CFG_BITS_3-1:0] write_size_reg = 3'd0, write_size_next;
reg [`CFG_BITS_2-1:0] write_burst_reg = 2'd0, write_burst_next;

reg s_axi_awready_reg = 1'b0, s_axi_awready_next;
reg s_axi_wready_reg = 1'b0, s_axi_wready_next;
reg [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_14] s_axi_bid_reg = {ID_WIDTH{1'b0}}, s_axi_bid_next;
reg s_axi_bvalid_reg = 1'b0, s_axi_bvalid_next;
reg s_axi_arready_reg = 1'b0, s_axi_arready_next;
reg [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_15] s_axi_rid_reg = {ID_WIDTH{1'b0}}, s_axi_rid_next;
wire [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_16] s_axi_rdata_reg;
reg s_axi_rlast_reg = 1'b0, s_axi_rlast_next;
reg s_axi_rvalid_reg = 1'b0, s_axi_rvalid_next;
reg [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_17] s_axi_rid_pipe_reg = {ID_WIDTH{1'b0}};
reg [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_18] s_axi_rdata_pipe_reg = {DATA_WIDTH{1'b0}};
reg s_axi_rlast_pipe_reg = 1'b0;
reg s_axi_rvalid_pipe_reg = 1'b0;

wire [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_19] s_axi_awaddr_valid = s_axi_awaddr >> (ADDR_WIDTH - VALID_ADDR_WIDTH);
wire [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_20] s_axi_araddr_valid = s_axi_araddr >> (ADDR_WIDTH - VALID_ADDR_WIDTH);
wire [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_21] read_addr_valid = read_addr_reg >> (ADDR_WIDTH - VALID_ADDR_WIDTH);
wire [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_22] write_addr_valid = write_addr_reg >> (ADDR_WIDTH - VALID_ADDR_WIDTH);

assign s_axi_awready = s_axi_awready_reg;
assign s_axi_wready = s_axi_wready_reg;
assign s_axi_bid = s_axi_bid_reg;
assign s_axi_bresp = 2'b00;
assign s_axi_bvalid = s_axi_bvalid_reg;
assign s_axi_arready = s_axi_arready_reg;
assign s_axi_rid = PIPELINE_OUTPUT ? s_axi_rid_pipe_reg : s_axi_rid_reg;
assign s_axi_rdata = PIPELINE_OUTPUT ? s_axi_rdata_pipe_reg : s_axi_rdata_reg;
assign s_axi_rresp = 2'b00;
assign s_axi_rlast = PIPELINE_OUTPUT ? s_axi_rlast_pipe_reg : s_axi_rlast_reg;
assign s_axi_rvalid = PIPELINE_OUTPUT ? s_axi_rvalid_pipe_reg : s_axi_rvalid_reg;

always @* begin
    write_state_next = WRITE_STATE_IDLE;

    mem_wr_en = 1'b0;

    write_id_next = write_id_reg;
    write_addr_next = write_addr_reg;
    write_count_next = write_count_reg;
    write_size_next = write_size_reg;
    write_burst_next = write_burst_reg;

    s_axi_awready_next = 1'b0;
    s_axi_wready_next = 1'b0;
    s_axi_bid_next = s_axi_bid_reg;
    s_axi_bvalid_next = s_axi_bvalid_reg && !s_axi_bready;

    case (write_state_reg)
        WRITE_STATE_IDLE: begin
            s_axi_awready_next = 1'b1;

            if (s_axi_awready && s_axi_awvalid) begin
                write_id_next = s_axi_awid;
                write_addr_next = s_axi_awaddr;
                write_count_next = s_axi_awlen;
                write_size_next = s_axi_awsize < $clog2(STRB_WIDTH) ? s_axi_awsize : $clog2(STRB_WIDTH);
                write_burst_next = s_axi_awburst;

                s_axi_awready_next = 1'b0;
                s_axi_wready_next = 1'b1;
                write_state_next = WRITE_STATE_BURST;
            end else begin
                write_state_next = WRITE_STATE_IDLE;
            end
        end
        WRITE_STATE_BURST: begin
            s_axi_wready_next = 1'b1;

            if (s_axi_wready && s_axi_wvalid) begin
                mem_wr_en = 1'b1;
                if (write_burst_reg != 2'b00) begin
                    write_addr_next = write_addr_reg + (1 << write_size_reg);
                end
                write_count_next = write_count_reg - 1;
                if (write_count_reg > 0) begin
                    write_state_next = WRITE_STATE_BURST;
                end else begin
                    s_axi_wready_next = 1'b0;
                    if (s_axi_bready || !s_axi_bvalid) begin
                        s_axi_bid_next = write_id_reg;
                        s_axi_bvalid_next = 1'b1;
                        s_axi_awready_next = 1'b1;
                        write_state_next = WRITE_STATE_IDLE;
                    end else begin
                        write_state_next = WRITE_STATE_RESP;
                    end
                end
            end else begin
                write_state_next = WRITE_STATE_BURST;
            end
        end
        WRITE_STATE_RESP: begin
            if (s_axi_bready || !s_axi_bvalid) begin
                s_axi_bid_next = write_id_reg;
                s_axi_bvalid_next = 1'b1;
                s_axi_awready_next = 1'b1;
                write_state_next = WRITE_STATE_IDLE;
            end else begin
                write_state_next = WRITE_STATE_RESP;
            end
        end
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        write_state_reg <= WRITE_STATE_IDLE;
        s_axi_awready_reg <= 1'b0;
        s_axi_wready_reg <= 1'b0;
        s_axi_bvalid_reg <= 1'b0;
    end else begin
        write_state_reg <= write_state_next;
        s_axi_awready_reg <= s_axi_awready_next;
        s_axi_wready_reg <= s_axi_wready_next;
        s_axi_bvalid_reg <= s_axi_bvalid_next;
    end

    write_id_reg <= write_id_next;
    write_addr_reg <= write_addr_next;
    write_count_reg <= write_count_next;
    write_size_reg <= write_size_next;
    write_burst_reg <= write_burst_next;

    s_axi_bid_reg <= s_axi_bid_next;

end

always @* begin
    read_state_next = READ_STATE_IDLE;

    mem_rd_en = 1'b0;

    s_axi_rid_next = s_axi_rid_reg;
    s_axi_rlast_next = s_axi_rlast_reg;
    s_axi_rvalid_next = s_axi_rvalid_reg && !(s_axi_rready || (PIPELINE_OUTPUT && !s_axi_rvalid_pipe_reg));

    read_id_next = read_id_reg;
    read_addr_next = read_addr_reg;
    read_count_next = read_count_reg;
    read_size_next = read_size_reg;
    read_burst_next = read_burst_reg;

    s_axi_arready_next = 1'b0;

    case (read_state_reg)
        READ_STATE_IDLE: begin
            s_axi_arready_next = 1'b1;

            if (s_axi_arready && s_axi_arvalid) begin
                read_id_next = s_axi_arid;
                read_addr_next = s_axi_araddr;
                read_count_next = s_axi_arlen;
                read_size_next = s_axi_arsize < $clog2(STRB_WIDTH) ? s_axi_arsize : $clog2(STRB_WIDTH);
                read_burst_next = s_axi_arburst;

                s_axi_arready_next = 1'b0;
                read_state_next = READ_STATE_BURST;
            end else begin
                read_state_next = READ_STATE_IDLE;
            end
        end
        READ_STATE_BURST: begin
            if (s_axi_rready || (PIPELINE_OUTPUT && !s_axi_rvalid_pipe_reg) || !s_axi_rvalid_reg) begin
                mem_rd_en = 1'b1;
                s_axi_rvalid_next = 1'b1;
                s_axi_rid_next = read_id_reg;
                s_axi_rlast_next = read_count_reg == 0;
                if (read_burst_reg != 2'b00) begin
                    read_addr_next = read_addr_reg + (1 << read_size_reg);
                end
                read_count_next = read_count_reg - 1;
                if (read_count_reg > 0) begin
                    read_state_next = READ_STATE_BURST;
                end else begin
                    s_axi_arready_next = 1'b1;
                    read_state_next = READ_STATE_IDLE;
                end
            end else begin
                read_state_next = READ_STATE_BURST;
            end
        end
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        read_state_reg <= READ_STATE_IDLE;
        s_axi_arready_reg <= 1'b0;
        s_axi_rvalid_reg <= 1'b0;
        s_axi_rvalid_pipe_reg <= 1'b0;
    end else begin
        read_state_reg <= read_state_next;
        s_axi_arready_reg <= s_axi_arready_next;
        s_axi_rvalid_reg <= s_axi_rvalid_next;

        if (!s_axi_rvalid_pipe_reg || s_axi_rready) begin
            s_axi_rvalid_pipe_reg <= s_axi_rvalid_reg;
        end
    end

    read_id_reg <= read_id_next;
    read_addr_reg <= read_addr_next;
    read_count_reg <= read_count_next;
    read_size_reg <= read_size_next;
    read_burst_reg <= read_burst_next;

    s_axi_rid_reg <= s_axi_rid_next;
    s_axi_rlast_reg <= s_axi_rlast_next;

    if (!s_axi_rvalid_pipe_reg || s_axi_rready) begin
        s_axi_rid_pipe_reg <= s_axi_rid_reg;
        s_axi_rdata_pipe_reg <= s_axi_rdata_reg;
        s_axi_rlast_pipe_reg <= s_axi_rlast_reg;
    end
end

generate
genvar i;
for(i = 0; i < WORD_WIDTH; i = i + 1) begin:RAM_GEN
    mem_u#(
        .ADDR_WIDTH                 (`CFG_FRAME_BUFFER_V4_AXI_RAM_V_INST_MEM_U_INST_ADDR_WIDTH           )
    )
    mem_u_inst
    (
        .clk                        (clk                        ),
        .wen                        (mem_wr_en&&s_axi_wstrb[i]  ),
        .waddr                      (write_addr_valid           ),
        .wdata                      (s_axi_wdata[WORD_SIZE*i +: WORD_SIZE]),
        .ren                        (mem_rd_en                  ),
        .raddr                      (read_addr_valid            ),
        .rdata                      (s_axi_rdata_reg[WORD_SIZE*i +: WORD_SIZE])
    );
end
endgenerate

endmodule

module mem_u#(
    parameter ADDR_WIDTH = `CFG_FRAME_BUFFER_V4_AXI_RAM_V_PARAMETER_ADDR_WIDTH_2
)
(
input                           clk,
input                           wen,
input           [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_23]waddr,
input           [`CFG_BITS_8-1:0]           wdata,
input                           ren,
input           [`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_24]raddr,
output  reg     [`CFG_BITS_8-1:0]           rdata
);
// (* RAM_STYLE="BLOCK" *)
reg [`CFG_BITS_8-1:0] mem[`CFG_FRAME_BUFFER_V4_AXI_RAM_V_RANGE_25];

always @(posedge clk) begin
    if(wen)  
        mem[waddr] <= wdata;
end

always @(posedge clk) begin
    if(ren)  
        rdata <= mem[raddr];
end

endmodule
