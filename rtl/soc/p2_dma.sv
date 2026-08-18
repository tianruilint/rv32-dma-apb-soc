// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// P2-owned, single-beat AXI4-Lite memory-copy engine.
// The fabric routes the CPU-visible 0x00100040..0x0010007f window here.
// The low six address bits therefore work with either absolute or rebased
// addresses. One 32-bit register is selected by AW/ARADDR[5:2]; a CPU word
// write uses the corresponding WDATA/WSTRB lane of the 128-bit bus. Read
// values are repeated in all four lanes for FRISCV's word-load path.
//
// CTRL[0] START is write-one pulse; CTRL[1] IRQ_EN is read/write.
// STATUS[0] BUSY is read-only; [1] DONE, [2] ERROR, [3] IRQ_PENDING,
// and [4] START_REJECT are sticky, write-one-to-clear bits. IRQ_PENDING
// records completion or a transfer/configuration error even while IRQ_EN=0;
// irq is IRQ_EN && IRQ_PENDING. A busy START returns SLVERR, sets
// START_REJECT, and leaves the active transfer and IRQ_EN alone. Software may clear
// STATUS while busy; a hardware event on that clock has priority. A valid
// idle START clears all sticky bits. Reset cancels any in-flight transfer.
module p2_dma (
    input  wire clk,
    input  wire rst,
    p2_axil_if.slave  s_ctrl,
    p2_axil_if.master m_mem,
    output wire irq
);
    localparam logic [1:0] RESP_OKAY = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;
    localparam logic [7:0] DMA_ID = 8'h20;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_READ_ADDR,
        ST_READ_RESP,
        ST_WRITE_SEND,
        ST_WRITE_RESP
    } state_t;

    state_t state_q;
    logic [31:0] src_q, dst_q, len_q, offset_q;
    logic [127:0] beat_q;
    logic busy_q, done_q, error_q, irq_pending_q, start_reject_q;
    logic irq_en_q;
    logic write_aw_seen_q, write_w_seen_q;
    logic [31:0] write_addr_q;
    logic [7:0] write_id_q;
    logic [127:0] write_data_q;
    logic [15:0] write_strb_q;
    logic bvalid_q, rvalid_q;
    logic [1:0] bresp_q, rresp_q;
    logic [7:0] bid_q, rid_q;
    logic [127:0] rdata_q;
    logic mem_aw_seen_q, mem_w_seen_q;

    wire [32:0] src_end = {1'b0, src_q} + {1'b0, len_q};
    wire [32:0] dst_end = {1'b0, dst_q} + {1'b0, len_q};
    wire cfg_valid = len_q != 32'd0 && len_q <= 32'd4096 &&
                     len_q[3:0] == 4'd0 && src_q[3:0] == 4'd0 &&
                     dst_q[3:0] == 4'd0 && src_end <= 33'h000100000 &&
                     dst_end <= 33'h000100000 &&
                     (src_end <= {1'b0, dst_q} ||
                      dst_end <= {1'b0, src_q});

    function automatic logic [31:0] merge_word(
        input logic [31:0] old_word,
        input logic [31:0] new_word,
        input logic [3:0]  byte_en
    );
        logic [31:0] result;
        result = old_word;
        for (int i = 0; i < 4; i++) begin
            if (byte_en[i]) result[i*8 +: 8] = new_word[i*8 +: 8];
        end
        return result;
    endfunction

    wire [1:0] write_lane = write_addr_q[3:2];
    wire [31:0] write_word = write_data_q[write_lane*32 +: 32];
    wire [3:0] write_bytes = write_strb_q[write_lane*4 +: 4];
    wire [15:0] selected_strobes = 16'h000f << (write_lane*4);
    wire wrong_lane_strobe = |(write_strb_q & ~selected_strobes);
    wire write_window_valid = write_addr_q[31:6] == 26'd0 ||
                              write_addr_q[31:6] == 26'(32'h00100040 >> 6);
    wire read_window_valid = s_ctrl.araddr[31:6] == 26'd0 ||
                             s_ctrl.araddr[31:6] == 26'(32'h00100040 >> 6);

    assign irq = irq_en_q && irq_pending_q;

    assign s_ctrl.awready = !rst && !write_aw_seen_q && !bvalid_q;
    assign s_ctrl.wready  = !rst && !write_w_seen_q && !bvalid_q;
    assign s_ctrl.bvalid  = bvalid_q;
    assign s_ctrl.bresp   = bresp_q;
    assign s_ctrl.bid     = bid_q;
    assign s_ctrl.arready = !rst && !rvalid_q;
    assign s_ctrl.rvalid  = rvalid_q;
    assign s_ctrl.rdata   = rdata_q;
    assign s_ctrl.rresp   = rresp_q;
    assign s_ctrl.rid     = rid_q;

    assign m_mem.arvalid = !rst && state_q == ST_READ_ADDR;
    assign m_mem.araddr  = src_q + offset_q;
    assign m_mem.arprot  = 3'b000;
    assign m_mem.arid    = DMA_ID;
    assign m_mem.rready  = !rst && state_q == ST_READ_RESP;
    assign m_mem.awvalid = !rst && state_q == ST_WRITE_SEND && !mem_aw_seen_q;
    assign m_mem.awaddr  = dst_q + offset_q;
    assign m_mem.awprot  = 3'b000;
    assign m_mem.awid    = DMA_ID;
    assign m_mem.wvalid  = !rst && state_q == ST_WRITE_SEND && !mem_w_seen_q;
    assign m_mem.wdata   = beat_q;
    assign m_mem.wstrb   = 16'hffff;
    assign m_mem.bready  = !rst && state_q == ST_WRITE_RESP;

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= ST_IDLE;
            src_q <= 32'd0;
            dst_q <= 32'd0;
            len_q <= 32'd0;
            offset_q <= 32'd0;
            beat_q <= 128'd0;
            busy_q <= 1'b0;
            done_q <= 1'b0;
            error_q <= 1'b0;
            irq_pending_q <= 1'b0;
            start_reject_q <= 1'b0;
            irq_en_q <= 1'b0;
            write_aw_seen_q <= 1'b0;
            write_w_seen_q <= 1'b0;
            write_addr_q <= 32'd0;
            write_id_q <= 8'd0;
            write_data_q <= 128'd0;
            write_strb_q <= 16'd0;
            bvalid_q <= 1'b0;
            bresp_q <= RESP_OKAY;
            bid_q <= 8'd0;
            rvalid_q <= 1'b0;
            rresp_q <= RESP_OKAY;
            rid_q <= 8'd0;
            rdata_q <= 128'd0;
            mem_aw_seen_q <= 1'b0;
            mem_w_seen_q <= 1'b0;
        end else begin
            if (s_ctrl.awvalid && s_ctrl.awready) begin
                write_aw_seen_q <= 1'b1;
                write_addr_q <= s_ctrl.awaddr;
                write_id_q <= s_ctrl.awid;
            end
            if (s_ctrl.wvalid && s_ctrl.wready) begin
                write_w_seen_q <= 1'b1;
                write_data_q <= s_ctrl.wdata;
                write_strb_q <= s_ctrl.wstrb;
            end
            if (bvalid_q && s_ctrl.bready) bvalid_q <= 1'b0;

            if (write_aw_seen_q && write_w_seen_q && !bvalid_q) begin
                write_aw_seen_q <= 1'b0;
                write_w_seen_q <= 1'b0;
                bid_q <= write_id_q;
                bvalid_q <= 1'b1;
                bresp_q <= RESP_OKAY;
                if (!write_window_valid || write_addr_q[1:0] != 2'b00 ||
                    wrong_lane_strobe) begin
                    bresp_q <= RESP_SLVERR;
                end else begin
                    case (write_addr_q[5:2])
                        4'd0: if (busy_q) bresp_q <= RESP_SLVERR;
                              else src_q <= merge_word(src_q, write_word, write_bytes);
                        4'd1: if (busy_q) bresp_q <= RESP_SLVERR;
                              else dst_q <= merge_word(dst_q, write_word, write_bytes);
                        4'd2: if (busy_q) bresp_q <= RESP_SLVERR;
                              else len_q <= merge_word(len_q, write_word, write_bytes);
                        4'd3: begin
                            if (write_bytes[0]) begin
                                // A rejected START must not accidentally
                                // disable the IRQ setting of the active job.
                                if (!write_word[0] || !busy_q)
                                    irq_en_q <= write_word[1];
                                if (write_word[0]) begin
                                    if (busy_q) begin
                                        start_reject_q <= 1'b1;
                                        bresp_q <= RESP_SLVERR;
                                    end else if (cfg_valid) begin
                                        busy_q <= 1'b1;
                                        done_q <= 1'b0;
                                        error_q <= 1'b0;
                                        irq_pending_q <= 1'b0;
                                        start_reject_q <= 1'b0;
                                        offset_q <= 32'd0;
                                        state_q <= ST_READ_ADDR;
                                    end else begin
                                        done_q <= 1'b0;
                                        error_q <= 1'b1;
                                        irq_pending_q <= 1'b1;
                                        start_reject_q <= 1'b0;
                                        bresp_q <= RESP_SLVERR;
                                    end
                                end
                            end
                        end
                        4'd4: if (write_bytes[0]) begin
                            if (write_word[1]) done_q <= 1'b0;
                            if (write_word[2]) error_q <= 1'b0;
                            if (write_word[3]) irq_pending_q <= 1'b0;
                            if (write_word[4]) start_reject_q <= 1'b0;
                        end
                        default: bresp_q <= RESP_SLVERR;
                    endcase
                end
            end

            if (rvalid_q && s_ctrl.rready) rvalid_q <= 1'b0;
            if (s_ctrl.arvalid && s_ctrl.arready) begin
                rid_q <= s_ctrl.arid;
                rvalid_q <= 1'b1;
                rresp_q <= RESP_OKAY;
                case (s_ctrl.araddr[5:2])
                    4'd0: rdata_q <= {4{src_q}};
                    4'd1: rdata_q <= {4{dst_q}};
                    4'd2: rdata_q <= {4{len_q}};
                    4'd3: rdata_q <= {4{{30'd0, irq_en_q, 1'b0}}};
                    4'd4: rdata_q <= {4{{27'd0, start_reject_q,
                                        irq_pending_q, error_q, done_q, busy_q}}};
                    default: begin
                        rdata_q <= 128'd0;
                        rresp_q <= RESP_SLVERR;
                    end
                endcase
                if (!read_window_valid || s_ctrl.araddr[1:0] != 2'b00) begin
                    rdata_q <= 128'd0;
                    rresp_q <= RESP_SLVERR;
                end
            end

            case (state_q)
                ST_IDLE: ;
                ST_READ_ADDR: if (m_mem.arvalid && m_mem.arready)
                    state_q <= ST_READ_RESP;
                ST_READ_RESP: if (m_mem.rvalid && m_mem.rready) begin
                    if (m_mem.rresp != RESP_OKAY || m_mem.rid != DMA_ID) begin
                        state_q <= ST_IDLE;
                        busy_q <= 1'b0;
                        error_q <= 1'b1;
                        irq_pending_q <= 1'b1;
                    end else begin
                        beat_q <= m_mem.rdata;
                        mem_aw_seen_q <= 1'b0;
                        mem_w_seen_q <= 1'b0;
                        state_q <= ST_WRITE_SEND;
                    end
                end
                ST_WRITE_SEND: begin
                    if (m_mem.awvalid && m_mem.awready) mem_aw_seen_q <= 1'b1;
                    if (m_mem.wvalid && m_mem.wready) mem_w_seen_q <= 1'b1;
                    if ((mem_aw_seen_q || (m_mem.awvalid && m_mem.awready)) &&
                        (mem_w_seen_q || (m_mem.wvalid && m_mem.wready)))
                        state_q <= ST_WRITE_RESP;
                end
                ST_WRITE_RESP: if (m_mem.bvalid && m_mem.bready) begin
                    if (m_mem.bresp != RESP_OKAY || m_mem.bid != DMA_ID) begin
                        state_q <= ST_IDLE;
                        busy_q <= 1'b0;
                        error_q <= 1'b1;
                        irq_pending_q <= 1'b1;
                    end else if (offset_q + 32'd16 == len_q) begin
                        state_q <= ST_IDLE;
                        busy_q <= 1'b0;
                        done_q <= 1'b1;
                        irq_pending_q <= 1'b1;
                    end else begin
                        offset_q <= offset_q + 32'd16;
                        state_q <= ST_READ_ADDR;
                    end
                end
                default: state_q <= ST_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
