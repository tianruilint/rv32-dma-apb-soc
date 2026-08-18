// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// P2-owned, single-transaction AXI4-Lite to 32-bit APB bridge.
// The connected AXI interface is 128 bits wide with 8-bit IDs. Each APB
// access targets one naturally aligned 32-bit word at the absolute AXI address.
module p2_axil_apb_bridge (
    input  wire logic        clk,
    input  wire logic        rst,
    p2_axil_if.slave        s_axi,
    output wire logic [31:0] paddr,
    output wire logic        psel,
    output wire logic        penable,
    output wire logic        pwrite,
    output wire logic [31:0] pwdata,
    output wire logic [3:0]  pstrb,
    input  wire logic        pready,
    input  wire logic [31:0] prdata,
    input  wire logic        pslverr
);
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_APB_SETUP,
        ST_APB_ACCESS,
        ST_B_RESP,
        ST_R_RESP
    } state_t;

    state_t state;
    logic have_aw, have_w, have_ar;
    logic prefer_write;
    logic [31:0] awaddr_q, araddr_q;
    logic [7:0] awid_q, arid_q;
    logic [127:0] wdata_q;
    logic [15:0] wstrb_q;

    logic apb_write_q;
    logic [31:0] apb_addr_q, apb_wdata_q;
    logic [3:0] apb_strb_q;
    logic [1:0] bresp_q, rresp_q;
    logic [7:0] bid_q, rid_q;
    logic [127:0] rdata_q;

    wire logic write_ready = have_aw && have_w;
    wire logic write_bad = (awaddr_q[1:0] != 2'b00) ||
        ((wstrb_q & ~(16'h000f << {awaddr_q[3:2], 2'b00})) != 16'b0);
    wire logic read_bad = (araddr_q[1:0] != 2'b00);

    assign s_axi.awready = (state == ST_IDLE) && !have_aw;
    assign s_axi.wready  = (state == ST_IDLE) && !have_w;
    assign s_axi.arready = (state == ST_IDLE) && !have_ar;
    assign s_axi.bvalid = (state == ST_B_RESP);
    assign s_axi.bresp = bresp_q;
    assign s_axi.bid = bid_q;
    assign s_axi.rvalid = (state == ST_R_RESP);
    assign s_axi.rresp = rresp_q;
    assign s_axi.rid = rid_q;
    assign s_axi.rdata = rdata_q;

    assign paddr = apb_addr_q;
    assign psel = (state == ST_APB_SETUP) || (state == ST_APB_ACCESS);
    assign penable = (state == ST_APB_ACCESS);
    assign pwrite = apb_write_q;
    assign pwdata = apb_wdata_q;
    assign pstrb = apb_strb_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;
            have_aw <= 1'b0;
            have_w <= 1'b0;
            have_ar <= 1'b0;
            prefer_write <= 1'b1;
            awaddr_q <= 32'b0;
            araddr_q <= 32'b0;
            awid_q <= 8'b0;
            arid_q <= 8'b0;
            wdata_q <= 128'b0;
            wstrb_q <= 16'b0;
            apb_write_q <= 1'b0;
            apb_addr_q <= 32'b0;
            apb_wdata_q <= 32'b0;
            apb_strb_q <= 4'b0;
            bresp_q <= 2'b00;
            rresp_q <= 2'b00;
            bid_q <= 8'b0;
            rid_q <= 8'b0;
            rdata_q <= 128'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    // AW, W, and AR can arrive in any order. Arbitration uses
                    // only already buffered requests; simultaneous arrivals
                    // become eligible on the following clock.
                    if (s_axi.awvalid && s_axi.awready) begin
                        have_aw <= 1'b1;
                        awaddr_q <= s_axi.awaddr;
                        awid_q <= s_axi.awid;
                    end
                    if (s_axi.wvalid && s_axi.wready) begin
                        have_w <= 1'b1;
                        wdata_q <= s_axi.wdata;
                        wstrb_q <= s_axi.wstrb;
                    end
                    if (s_axi.arvalid && s_axi.arready) begin
                        have_ar <= 1'b1;
                        araddr_q <= s_axi.araddr;
                        arid_q <= s_axi.arid;
                    end

                    if (write_ready && (!have_ar || prefer_write)) begin
                        have_aw <= 1'b0;
                        have_w <= 1'b0;
                        prefer_write <= 1'b0;
                        bid_q <= awid_q;
                        apb_write_q <= 1'b1;
                        apb_addr_q <= awaddr_q;
                        apb_wdata_q <= wdata_q[32*awaddr_q[3:2] +: 32];
                        apb_strb_q <= wstrb_q[4*awaddr_q[3:2] +: 4];
                        if (write_bad) begin
                            bresp_q <= 2'b10;
                            state <= ST_B_RESP;
                        end else begin
                            state <= ST_APB_SETUP;
                        end
                    end else if (have_ar) begin
                        have_ar <= 1'b0;
                        prefer_write <= 1'b1;
                        rid_q <= arid_q;
                        apb_write_q <= 1'b0;
                        apb_addr_q <= araddr_q;
                        apb_wdata_q <= 32'b0;
                        apb_strb_q <= 4'b0;
                        if (read_bad) begin
                            rresp_q <= 2'b10;
                            rdata_q <= 128'b0;
                            state <= ST_R_RESP;
                        end else begin
                            state <= ST_APB_SETUP;
                        end
                    end
                end
                ST_APB_SETUP: state <= ST_APB_ACCESS;
                ST_APB_ACCESS: begin
                    if (pready) begin
                        if (apb_write_q) begin
                            bresp_q <= pslverr ? 2'b10 : 2'b00;
                            state <= ST_B_RESP;
                        end else begin
                            rresp_q <= pslverr ? 2'b10 : 2'b00;
                            rdata_q <= pslverr ? 128'b0 : {4{prdata}};
                            state <= ST_R_RESP;
                        end
                    end
                end
                ST_B_RESP: if (s_axi.bready) state <= ST_IDLE;
                ST_R_RESP: if (s_axi.rready) state <= ST_IDLE;
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
