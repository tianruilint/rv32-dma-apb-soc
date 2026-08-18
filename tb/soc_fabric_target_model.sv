// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module soc_fabric_target_model #(
    parameter int INDEX = 0
)(
    input  wire logic clk,
    input  wire logic rst,
    input  wire logic allow_aw,
    input  wire logic allow_w,
    input  wire logic allow_ar,
    input  wire logic [1:0] write_resp,
    input  wire logic [1:0] read_resp,
    p2_axil_if.slave bus,
    output int aw_count,
    output int w_count,
    output int ar_count,
    output logic [31:0] last_awaddr,
    output logic [31:0] last_araddr,
    output logic [127:0] last_wdata,
    output logic [15:0] last_wstrb
);

logic aw_seen, w_seen, bvalid_q, rvalid_q;
logic [7:0] aw_id_q, bid_q, rid_q;
logic [1:0] bresp_q, rresp_q;
logic [127:0] rdata_q;
wire logic aw_fire = bus.awvalid && bus.awready;
wire logic w_fire = bus.wvalid && bus.wready;
wire logic ar_fire = bus.arvalid && bus.arready;

function automatic logic [127:0] reply_data(input logic [31:0] addr);
    return {32'(INDEX), addr, ~addr, 32'h1234_5678};
endfunction

assign bus.awready = !rst && allow_aw && !aw_seen && !bvalid_q;
assign bus.wready = !rst && allow_w && !w_seen && !bvalid_q;
assign bus.bvalid = !rst && bvalid_q;
assign bus.bresp = bresp_q;
assign bus.bid = bid_q;
assign bus.arready = !rst && allow_ar && !rvalid_q;
assign bus.rvalid = !rst && rvalid_q;
assign bus.rresp = rresp_q;
assign bus.rdata = rdata_q;
assign bus.rid = rid_q;

always_ff @(posedge clk) begin
    if (rst) begin
        aw_seen <= 1'b0;
        w_seen <= 1'b0;
        bvalid_q <= 1'b0;
        rvalid_q <= 1'b0;
        aw_id_q <= '0;
        bid_q <= '0;
        rid_q <= '0;
        bresp_q <= '0;
        rresp_q <= '0;
        rdata_q <= '0;
        aw_count <= 0;
        w_count <= 0;
        ar_count <= 0;
        last_awaddr <= '0;
        last_araddr <= '0;
        last_wdata <= '0;
        last_wstrb <= '0;
    end else begin
        if (aw_fire) begin
            aw_seen <= 1'b1;
            aw_id_q <= bus.awid;
            last_awaddr <= bus.awaddr;
            aw_count <= aw_count + 1;
        end
        if (w_fire) begin
            w_seen <= 1'b1;
            last_wdata <= bus.wdata;
            last_wstrb <= bus.wstrb;
            w_count <= w_count + 1;
        end
        if (!bvalid_q && (aw_seen || aw_fire) && (w_seen || w_fire)) begin
            bvalid_q <= 1'b1;
            bresp_q <= write_resp;
            bid_q <= aw_fire ? bus.awid : aw_id_q;
        end
        if (bus.bvalid && bus.bready) begin
            bvalid_q <= 1'b0;
            aw_seen <= 1'b0;
            w_seen <= 1'b0;
        end
        if (ar_fire) begin
            rvalid_q <= 1'b1;
            rresp_q <= read_resp;
            rid_q <= bus.arid;
            rdata_q <= reply_data(bus.araddr);
            last_araddr <= bus.araddr;
            ar_count <= ar_count + 1;
        end
        if (bus.rvalid && bus.rready) rvalid_q <= 1'b0;
    end
end

endmodule


`default_nettype wire
