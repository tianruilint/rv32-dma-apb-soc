// SPDX-License-Identifier: CERN-OHL-S-2.0
// Directed positive and negative checks for the simulation-only protocol monitor.
`timescale 1ns/1ps
module soc_protocol_checker_test;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;
    p2_axil_if bus();
    soc_protocol_checker #(.NAME("directed")) monitor(clk, rst, bus);
    int scenario;

    task automatic step(
        input bit aw = 0, input logic [7:0] aid = 0,
        input bit w = 0, input bit b = 0, input logic [7:0] bid = 0,
        input bit ar = 0, input logic [7:0] rid_request = 0,
        input bit r = 0, input logic [7:0] rid_response = 0
    );
        bus.awvalid = aw; bus.awid = aid;
        bus.wvalid = w; bus.bvalid = b; bus.bid = bid;
        bus.arvalid = ar; bus.arid = rid_request;
        bus.rvalid = r; bus.rid = rid_response;
        @(negedge clk);
    endtask

    task automatic drain;
`ifdef CHECK_PROTOCOL_DRAIN
        monitor.check_drained();
`endif
    endtask

    initial begin
        if (!$value$plusargs("CASE=%d", scenario)) scenario = 0;
        bus.awvalid=0; bus.awid=0; bus.awaddr=32'h100; bus.awprot=0;
        bus.wvalid=0; bus.wdata=128'h1234; bus.wstrb=16'hffff;
        bus.bvalid=0; bus.bid=0; bus.bresp=0;
        bus.arvalid=0; bus.arid=0; bus.araddr=32'h200; bus.arprot=0;
        bus.rvalid=0; bus.rid=0; bus.rdata=128'habcd; bus.rresp=0;
        bus.awready=1; bus.wready=1; bus.bready=1;
        bus.arready=1; bus.rready=1;
        repeat (2) @(negedge clk);
        rst = 0;
        case (scenario)
            0: begin // AW first, W first, simultaneous response, response reordering.
                step(1, 1, 0);
                step(1, 2, 1);
                step(0, 0, 1, 1, 1);
                step(0, 0, 0, 1, 2);
                step(0, 0, 0, 0, 0, 1, 3, 1, 3);
                step(0, 0, 1);
                step(1, 4, 0, 1, 4);
                step(1, 5, 1);
                step(1, 6, 1);
                step(0, 0, 0, 1, 6);
                step(0, 0, 0, 1, 5);
                step(); drain();
            end
            1: begin // Illegal: W #1 belongs to AW #1, yet response uses ID #2.
                step(1, 1, 0);
                step(1, 2, 1);
                step(0, 0, 0, 1, 2);
                step(0, 0, 1, 1, 1);
                step(); drain();
            end
            2: begin // Unsolicited B must always fail.
                step(0, 0, 0, 1, 7);
            end
            3: begin // Duplicate read response must always fail.
                step(0, 0, 0, 0, 0, 1, 8);
                step(0, 0, 0, 0, 0, 0, 0, 1, 8);
                step(0, 0, 0, 0, 0, 0, 0, 1, 8);
            end
            4: begin // Only an explicitly quiesced boundary may require completion.
                step(0, 0, 0, 0, 0, 1, 9);
                step(); drain();
            end
            5: begin // Accepted AW whose W never arrived at a quiesced boundary.
                step(1, 10, 0);
                step(); drain();
            end
            6: begin // Legal live endpoint: an in-flight CPU read is not an error.
                step(0, 0, 0, 0, 0, 1, 11);
                step();
            end
            7: begin // Reset cancels previous accepted requests and pairing queues.
                step(1, 12, 0, 0, 0, 1, 13);
                rst = 1; step(); rst = 0;
                step(0, 0, 1);
                step(1, 14, 0, 1, 14);
                step(); drain();
            end
            8: begin // W can be accepted before AW.
                step(0, 0, 1);
                step(1, 15, 0);
                step(0, 0, 0, 1, 15);
                step(); drain();
            end
            9: begin // Existing SVA must reject changing W under backpressure.
                bus.wready = 0;
                step(0, 0, 1);
                bus.wdata = 128'h5555;
                step(0, 0, 1);
            end
            10: begin // Duplicate B after a completed pair.
                step(1, 16, 1);
                step(0, 0, 0, 1, 16);
                step(0, 0, 0, 1, 16);
            end
            11: begin // Same ID multiple writes remain legal and counted.
                step(1, 17, 1);
                step(1, 17, 1);
                step(0, 0, 0, 1, 17);
                step(0, 0, 0, 1, 17);
                step(); drain();
            end
            12: begin // W waiting without an address at a quiesced boundary.
                step(0, 0, 1);
                step(); drain();
            end
            13: begin // A matched AW/W pair whose B is missing at a drained boundary.
                step(1, 18, 1);
                step(); drain();
            end
            default: $fatal(1, "Unknown case %0d", scenario);
        endcase
        $display("CHECKER_CASE_END case=%0d", scenario);
        $finish;
    end
endmodule
