// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module soc_upstream_xbar_tb;
    logic clk;
    logic rst = 1'b1;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    p2_axil_if s_axi[4]();
    p2_axil_if m_axi[4]();
    p2_upstream_axil_fabric dut (.clk(clk), .rst(rst), .s_axi(s_axi), .m_axi(m_axi));

    logic [3:0] drv_awvalid, drv_wvalid, drv_bready;
    logic [3:0] drv_arvalid, drv_rready;
    logic [31:0] drv_awaddr[4], drv_araddr[4];
    logic [2:0] drv_awprot[4], drv_arprot[4];
    logic [7:0] drv_awid[4], drv_arid[4];
    logic [127:0] drv_wdata[4];
    logic [15:0] drv_wstrb[4];
    wire logic [3:0] got_awready, got_wready, got_bvalid;
    wire logic [3:0] got_arready, got_rvalid;
    wire logic [1:0] got_bresp[4], got_rresp[4];
    wire logic [7:0] got_bid[4], got_rid[4];
    wire logic [127:0] got_rdata[4];

    logic [3:0] allow_aw, allow_w, allow_ar;
    logic [1:0] write_resp[4], read_resp[4];
    int target_aw_count[4], target_w_count[4], target_ar_count[4];
    wire logic [31:0] last_awaddr[4], last_araddr[4];
    wire logic [127:0] last_wdata[4];
    wire logic [15:0] last_wstrb[4];

    for (genvar i = 0; i < 4; i++) begin : gen_driver
        assign s_axi[i].awvalid = drv_awvalid[i];
        assign s_axi[i].awaddr = drv_awaddr[i];
        assign s_axi[i].awprot = drv_awprot[i];
        assign s_axi[i].awid = drv_awid[i];
        assign s_axi[i].wvalid = drv_wvalid[i];
        assign s_axi[i].wdata = drv_wdata[i];
        assign s_axi[i].wstrb = drv_wstrb[i];
        assign s_axi[i].bready = drv_bready[i];
        assign s_axi[i].arvalid = drv_arvalid[i];
        assign s_axi[i].araddr = drv_araddr[i];
        assign s_axi[i].arprot = drv_arprot[i];
        assign s_axi[i].arid = drv_arid[i];
        assign s_axi[i].rready = drv_rready[i];
        assign got_awready[i] = s_axi[i].awready;
        assign got_wready[i] = s_axi[i].wready;
        assign got_bvalid[i] = s_axi[i].bvalid;
        assign got_bresp[i] = s_axi[i].bresp;
        assign got_bid[i] = s_axi[i].bid;
        assign got_arready[i] = s_axi[i].arready;
        assign got_rvalid[i] = s_axi[i].rvalid;
        assign got_rdata[i] = s_axi[i].rdata;
        assign got_rresp[i] = s_axi[i].rresp;
        assign got_rid[i] = s_axi[i].rid;
    end

    for (genvar t = 0; t < 4; t++) begin : gen_target
        soc_fabric_target_model #(.INDEX(t)) model (
            .clk(clk), .rst(rst),
            .allow_aw(allow_aw[t]), .allow_w(allow_w[t]),
            .allow_ar(allow_ar[t]),
            .write_resp(write_resp[t]), .read_resp(read_resp[t]),
            .bus(m_axi[t]),
            .aw_count(target_aw_count[t]), .w_count(target_w_count[t]),
            .ar_count(target_ar_count[t]),
            .last_awaddr(last_awaddr[t]), .last_araddr(last_araddr[t]),
            .last_wdata(last_wdata[t]), .last_wstrb(last_wstrb[t])
        );
    end

    // The attributed FRISCV IO slave requires an AW handshake before WVALID.
    // This compatibility rule is specific to output 1, regardless of the
    // arrival order of AW and W at the fabric's initiator ports.
    always @(posedge clk) begin
        if (!rst && m_axi[1].wvalid &&
            target_aw_count[1] == target_w_count[1])
            $fatal(1, "FRISCV IO received W before AW handshake");
    end

    function automatic logic [127:0] expected_data(
        input int target, input logic [31:0] addr
    );
        logic [31:0] forwarded;
        forwarded = (target == 1) ? addr - 32'h0010_0000 : addr;
        return {32'(target), forwarded, ~forwarded, 32'h1234_5678};
    endfunction

    task automatic send_aw(input logic [1:0] src, input logic [31:0] addr,
                           input logic [7:0] id);
        @(negedge clk);
        drv_awaddr[src] = addr;
        drv_awid[src] = id;
        drv_awvalid[src] = 1'b1;
        do @(posedge clk); while (!got_awready[src]);
        @(negedge clk);
        drv_awvalid[src] = 1'b0;
    endtask

    task automatic send_w(input logic [1:0] src, input logic [127:0] data,
                          input logic [15:0] strb);
        @(negedge clk);
        drv_wdata[src] = data;
        drv_wstrb[src] = strb;
        drv_wvalid[src] = 1'b1;
        do @(posedge clk); while (!got_wready[src]);
        @(negedge clk);
        drv_wvalid[src] = 1'b0;
    endtask

    task automatic send_ar(input logic [1:0] src, input logic [31:0] addr,
                           input logic [7:0] id);
        @(negedge clk);
        drv_araddr[src] = addr;
        drv_arid[src] = id;
        drv_arvalid[src] = 1'b1;
        do @(posedge clk); while (!got_arready[src]);
        @(negedge clk);
        drv_arvalid[src] = 1'b0;
    endtask

    task automatic expect_b(input logic [1:0] src, input logic [7:0] id,
                            input logic [1:0] resp, input int stall_cycles);
        do @(negedge clk); while (!got_bvalid[src]);
        for (int n = 0; n < stall_cycles; n++) begin
            if (!got_bvalid[src] || got_bid[src] !== id ||
                got_bresp[src] !== resp) $fatal(1, "B changed under stall src=%0d", src);
            @(negedge clk);
        end
        if (got_bid[src] !== id || got_bresp[src] !== resp)
            $fatal(1, "B mismatch src=%0d got id=%h resp=%h", src,
                   got_bid[src], got_bresp[src]);
        drv_bready[src] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        drv_bready[src] = 1'b0;
    endtask

    task automatic expect_r(input logic [1:0] src, input logic [7:0] id,
                            input logic [1:0] resp,
                            input logic [127:0] data,
                            input int stall_cycles);
        do @(negedge clk); while (!got_rvalid[src]);
        for (int n = 0; n < stall_cycles; n++) begin
            if (!got_rvalid[src] || got_rid[src] !== id ||
                got_rresp[src] !== resp || got_rdata[src] !== data)
                $fatal(1, "R changed under stall src=%0d", src);
            @(negedge clk);
        end
        if (got_rid[src] !== id || got_rresp[src] !== resp ||
            got_rdata[src] !== data)
            $fatal(1, "R mismatch src=%0d id=%h resp=%h", src,
                   got_rid[src], got_rresp[src]);
        drv_rready[src] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        drv_rready[src] = 1'b0;
    endtask

    task automatic read_case(input logic [1:0] src, input logic [31:0] addr,
                             input logic [7:0] id, input int target,
                             input int stall_cycles);
        send_ar(src, addr, id);
        expect_r(src, id, 2'b00, expected_data(target, addr), stall_cycles);
    endtask

    task automatic write_case(input logic [1:0] src, input logic [31:0] addr,
                              input logic [7:0] id, input int target,
                              input logic [127:0] data,
                              input logic [15:0] strb,
                              input int stall_cycles);
        fork
            send_aw(src, addr, id);
            send_w(src, data, strb);
        join
        expect_b(src, id, 2'b00, stall_cycles);
        if (last_wdata[target] !== data || last_wstrb[target] !== strb)
            $fatal(1, "W payload changed target=%0d", target);
    endtask

    initial begin : run_tests
        int counts_before;
        int fair_ar_before;
        int fair_aw_before;
        drv_awvalid = '0;
        drv_wvalid = '0;
        drv_bready = '0;
        drv_arvalid = '0;
        drv_rready = '0;
        allow_aw = '1;
        allow_w = '1;
        allow_ar = '1;
        for (int i = 0; i < 4; i++) begin
            drv_awaddr[i] = '0;
            drv_araddr[i] = '0;
            drv_awprot[i] = '0;
            drv_arprot[i] = '0;
            drv_awid[i] = '0;
            drv_arid[i] = '0;
            drv_wdata[i] = '0;
            drv_wstrb[i] = '0;
        end
        for (int t = 0; t < 4; t++) begin
            write_resp[t] = 2'b00;
            read_resp[t] = 2'b00;
        end
        repeat (4) @(negedge clk);
        rst = 1'b0;

        // All legal read routes, including the IO offset and absolute MMIO.
        read_case(0, 32'h0000_0040, 8'h80, 0, 2);
        read_case(1, 32'h0000_0080, 8'h10, 0, 0);
        read_case(1, 32'h0010_0010, 8'h11, 1, 1);
        if (last_araddr[1] !== 32'h10) $fatal(1, "IO base was not removed");
        read_case(1, 32'h0010_0044, 8'h12, 2, 0);
        if (last_araddr[2] !== 32'h0010_0044) $fatal(1, "DMA address changed");
        read_case(1, 32'h0010_0088, 8'h13, 3, 0);
        read_case(2, 32'h000c_0000, 8'h20, 0, 1);

        // Both independent write channels reach every legal destination.
        write_case(1, 32'h0000_0100, 8'h14, 0, 128'h1234, 16'h000f, 2);
        write_case(1, 32'h0010_0004, 8'h15, 1, 128'h5678, 16'h00f0, 0);
        if (last_awaddr[1] !== 32'h4) $fatal(1, "IO write offset wrong");
        write_case(1, 32'h0010_0048, 8'h16, 2, 128'h9abc, 16'h0f00, 0);
        write_case(1, 32'h0010_008c, 8'h17, 3, 128'hdef0, 16'hf000, 0);
        write_case(2, 32'h000c_1000, 8'h20, 0, 128'h55aa, 16'hffff, 1);

        // W before AW, then AW before W; destination stalls each half.
        counts_before = target_aw_count[0];
        allow_aw[0] = 1'b0;
        send_w(2, 128'hfeed_face, 16'h00ff);
        repeat (3) @(negedge clk);
        send_aw(2, 32'h0000_0200, 8'h20);
        repeat (3) @(negedge clk);
        if (target_aw_count[0] != counts_before ||
            got_bvalid[2]) $fatal(1, "write completed before AW target accept");
        allow_aw[0] = 1'b1;
        expect_b(2, 8'h20, 2'b00, 0);

        counts_before = target_w_count[0];
        allow_w[0] = 1'b0;
        send_aw(1, 32'h0000_0240, 8'h18);
        repeat (3) @(negedge clk);
        send_w(1, 128'hbabe, 16'h0f00);
        repeat (3) @(negedge clk);
        if (target_w_count[0] != counts_before || got_bvalid[1])
            $fatal(1, "write completed before W target accept");
        allow_w[0] = 1'b1;
        expect_b(1, 8'h18, 2'b00, 0);

        // A stalled RAM request cannot block another target.
        allow_ar[0] = 1'b0;
        send_ar(0, 32'h0000_0300, 8'h81);
        repeat (2) @(negedge clk);
        read_case(1, 32'h0010_0020, 8'h19, 1, 0);
        allow_ar[0] = 1'b1;
        expect_r(0, 8'h81, 2'b00,
                 expected_data(0, 32'h0000_0300), 0);

        // Three sources contend for RAM reads. Every source must complete.
        fork
            read_case(0, 32'h0000_0400, 8'h82, 0, 0);
            read_case(1, 32'h0000_0440, 8'h1a, 0, 0);
            read_case(2, 32'h0000_0480, 8'h20, 0, 0);
        join

        // Repeated, fully queued contention: every round holds three RAM
        // reads and two RAM writes at the target until all sources are
        // pending. Each source must receive its own response within the
        // bounded service window, even while both directions are active.
        for (int round = 0; round < 8; round++) begin
            fair_ar_before = target_ar_count[0];
            fair_aw_before = target_aw_count[0];
            allow_ar[0] = 1'b0;
            allow_aw[0] = 1'b0;
            allow_w[0] = 1'b0;
            fork
                send_ar(0, 32'h0000_1000 + 32'(round * 16),
                        8'(8'h80 + round));
                send_ar(1, 32'h0000_2000 + 32'(round * 16),
                        8'(8'h10 + round));
                send_ar(2, 32'h0000_3000 + 32'(round * 16),
                        8'h20);
                send_aw(1, 32'h0000_4000 + 32'(round * 16),
                        8'(8'h18 + round));
                send_w(1, 128'h1111_0000 + 128'(round), 16'h00ff);
                send_aw(2, 32'h0000_5000 + 32'(round * 16),
                        8'h20);
                send_w(2, 128'h2222_0000 + 128'(round), 16'hff00);
            join
            repeat (2) @(negedge clk);
            if (target_ar_count[0] != fair_ar_before ||
                target_aw_count[0] != fair_aw_before)
                $fatal(1, "RAM advanced while contention was gated");
            allow_ar[0] = 1'b1;
            allow_aw[0] = 1'b1;
            allow_w[0] = 1'b1;
            fork : bounded_fairness_round
                begin
                    fork
                        expect_r(0, 8'(8'h80 + round), 2'b00,
                                 expected_data(0, 32'h0000_1000 + 32'(round * 16)), 0);
                        expect_r(1, 8'(8'h10 + round), 2'b00,
                                 expected_data(0, 32'h0000_2000 + 32'(round * 16)), 0);
                        expect_r(2, 8'h20, 2'b00,
                                 expected_data(0, 32'h0000_3000 + 32'(round * 16)), 0);
                        expect_b(1, 8'(8'h18 + round), 2'b00, 0);
                        expect_b(2, 8'h20, 2'b00, 0);
                    join
                end
                begin
                    repeat (120) @(posedge clk);
                    $fatal(1, "same-target fairness round %0d starved", round);
                end
            join_any
            disable bounded_fairness_round;
            if (target_ar_count[0] != fair_ar_before + 3 ||
                target_aw_count[0] != fair_aw_before + 2)
                $fatal(1, "same-target fairness round %0d lost a request", round);
        end

        // Error responses are held and invalid routes never reach targets.
        read_resp[2] = 2'b10;
        send_ar(1, 32'h0010_004c, 8'h1b);
        expect_r(1, 8'h1b, 2'b10,
                 expected_data(2, 32'h0010_004c), 2);
        read_resp[2] = 2'b00;
        write_resp[3] = 2'b10;
        fork
            send_aw(1, 32'h0010_0090, 8'h1c);
            send_w(1, 128'h1234_1234, 16'hf000);
        join
        expect_b(1, 8'h1c, 2'b10, 2);
        write_resp[3] = 2'b00;

        counts_before = target_ar_count[0] + target_ar_count[1] +
                        target_ar_count[2] + target_ar_count[3];
        send_ar(0, 32'h0010_0000, 8'h83);
        expect_r(0, 8'h83, 2'b11, '0, 1);
        send_ar(2, 32'h0010_0040, 8'h20);
        expect_r(2, 8'h20, 2'b11, '0, 0);
        send_ar(1, 32'h0010_00c0, 8'h1e);
        expect_r(1, 8'h1e, 2'b11, '0, 0);
        if (counts_before != target_ar_count[0] + target_ar_count[1] +
                             target_ar_count[2] + target_ar_count[3])
            $fatal(1, "invalid read reached target");

        counts_before = target_aw_count[0] + target_aw_count[1] +
                        target_aw_count[2] + target_aw_count[3];
        fork
            send_aw(0, 32'h0010_0000, 8'h84);
            send_w(0, 128'hbad, 16'hffff);
        join
        expect_b(0, 8'h84, 2'b11, 1);
        fork
            send_aw(2, 32'h0010_0080, 8'h20);
            send_w(2, 128'hbad, 16'hffff);
        join
        expect_b(2, 8'h20, 2'b11, 0);
        if (counts_before != target_aw_count[0] + target_aw_count[1] +
                             target_aw_count[2] + target_aw_count[3])
            $fatal(1, "invalid write reached target");

        // Reset cancels a half-written transaction and does not leak a B.
        send_aw(1, 32'h0000_0600, 8'h1d);
        @(negedge clk);
        rst = 1'b1;
        repeat (2) @(negedge clk);
        if (got_bvalid != '0 || got_rvalid != '0)
            $fatal(1, "response survived reset");
        rst = 1'b0;
        write_case(1, 32'h0000_0604, 8'h1f, 0,
                   128'hdead_beef, 16'hf000, 0);

        $display("P2_UPSTREAM_XBAR_PASS");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "fabric test watchdog");
    end
endmodule

`default_nettype wire
