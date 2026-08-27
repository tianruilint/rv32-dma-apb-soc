// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// Simulation-only protocol monitor. No DUT state is used to predict responses.
module soc_protocol_checker #(
    parameter string NAME = "bus"
)(
    input logic clk, rst,
    p2_axil_if bus
);
    int unsigned read_ids[256];
    int unsigned write_ids[256];
    int unsigned write_data;
    int unsigned ar_count, aw_count, b_count, r_count;
    int unsigned aw_stalls, w_stalls, ar_stalls, b_stalls, r_stalls;

    assert property (@(posedge clk) disable iff (rst)
        bus.awvalid && !bus.awready |=> bus.awvalid &&
        $stable({bus.awaddr,bus.awid,bus.awprot}))
        else $fatal(1, "%s AW changed under backpressure", NAME);
    assert property (@(posedge clk) disable iff (rst)
        bus.wvalid && !bus.wready |=> bus.wvalid &&
        $stable({bus.wdata,bus.wstrb}))
        else $fatal(1, "%s W changed under backpressure", NAME);
    assert property (@(posedge clk) disable iff (rst)
        bus.arvalid && !bus.arready |=> bus.arvalid &&
        $stable({bus.araddr,bus.arid,bus.arprot}))
        else $fatal(1, "%s AR changed under backpressure", NAME);
    assert property (@(posedge clk) disable iff (rst)
        bus.bvalid && !bus.bready |=> bus.bvalid &&
        $stable({bus.bid,bus.bresp}))
        else $fatal(1, "%s B changed under backpressure", NAME);
    assert property (@(posedge clk) disable iff (rst)
        bus.rvalid && !bus.rready |=> bus.rvalid &&
        $stable({bus.rid,bus.rdata,bus.rresp}))
        else $fatal(1, "%s R changed under backpressure", NAME);

    // Blocking updates are intentional in this testbench scoreboard: accept
    // this cycle's requests before checking zero-latency responses.
    /* verilator lint_off BLKSEQ */
    always @(posedge clk) begin
        if (rst) begin
            foreach (read_ids[i]) begin read_ids[i] = 0; write_ids[i] = 0; end
            write_data = 0;
            ar_count = 0; aw_count = 0; b_count = 0; r_count = 0;
            aw_stalls = 0; w_stalls = 0; ar_stalls = 0;
            b_stalls = 0; r_stalls = 0;
        end else begin
            if (bus.arvalid && bus.arready) begin
                read_ids[bus.arid]++; ar_count++;
            end
            if (bus.awvalid && bus.awready) begin
                write_ids[bus.awid]++; aw_count++;
            end
            if (bus.wvalid && bus.wready) write_data++;
            if (bus.rvalid) begin
                if (read_ids[bus.rid] == 0)
                    $fatal(1, "%s unsolicited R id=%02x", NAME, bus.rid);
                if (bus.rready) begin read_ids[bus.rid]--; r_count++; end
            end
            if (bus.bvalid) begin
                if (write_ids[bus.bid] == 0 || write_data == 0)
                    $fatal(1, "%s unsolicited B id=%02x", NAME, bus.bid);
                if (bus.bready) begin
                    write_ids[bus.bid]--; write_data--; b_count++;
                end
            end
            if (bus.awvalid && !bus.awready) aw_stalls++;
            if (bus.wvalid && !bus.wready) w_stalls++;
            if (bus.arvalid && !bus.arready) ar_stalls++;
            if (bus.bvalid && !bus.bready) b_stalls++;
            if (bus.rvalid && !bus.rready) r_stalls++;
        end
    end
    /* verilator lint_on BLKSEQ */
    final $display("PROTOCOL_COUNTS %s AR/R=%0d/%0d AW/B=%0d/%0d stalls AW/W/AR/B/R=%0d/%0d/%0d/%0d/%0d",
        NAME, ar_count, r_count, aw_count, b_count,
        aw_stalls, w_stalls, ar_stalls, b_stalls, r_stalls);
endmodule
`default_nettype wire
