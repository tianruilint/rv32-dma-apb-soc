// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module soc_bridge_test;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;
    p2_axil_if #(.ADDR_W(32), .DATA_W(128), .ID_W(8)) axi();
    wire logic [31:0] paddr;
    wire logic psel, penable, pwrite;
    wire logic [31:0] pwdata;
    wire logic [3:0] pstrb;
    logic pready = 1'b0;
    logic [31:0] prdata = 32'b0;
    logic pslverr = 1'b0;
    int apb_completions = 0;
    int seed = 20260925;
    logic [31:0] rng = 32'hcafe1234;
    logic [31:0] reference_words [0:31];
    function automatic logic [31:0] random_word();
        rng = rng ^ (rng << 13);
        rng = rng ^ (rng >> 17);
        rng = rng ^ (rng << 5);
        return rng;
    endfunction

    p2_axil_apb_bridge dut (
        .clk(clk), .rst(rst), .s_axi(axi),
        .paddr(paddr), .psel(psel), .penable(penable),
        .pwrite(pwrite), .pwdata(pwdata), .pstrb(pstrb),
        .pready(pready), .prdata(prdata), .pslverr(pslverr)
    );

    always @(posedge clk) begin
        if (!rst && psel && penable && pready) apb_completions <= apb_completions + 1;
    end

    task automatic step(input int n);
        repeat (n) @(negedge clk);
    endtask

    task automatic send_aw(input logic [31:0] addr, input logic [7:0] id);
        @(negedge clk);
        axi.awaddr = addr;
        axi.awid = id;
        axi.awvalid = 1'b1;
        while (!axi.awready) @(negedge clk);
        @(negedge clk);
        axi.awvalid = 1'b0;
    endtask

    task automatic send_w(input logic [127:0] data, input logic [15:0] strb);
        @(negedge clk);
        axi.wdata = data;
        axi.wstrb = strb;
        axi.wvalid = 1'b1;
        while (!axi.wready) @(negedge clk);
        @(negedge clk);
        axi.wvalid = 1'b0;
    endtask

    task automatic send_ar(input logic [31:0] addr, input logic [7:0] id);
        @(negedge clk);
        axi.araddr = addr;
        axi.arid = id;
        axi.arvalid = 1'b1;
        while (!axi.arready) @(negedge clk);
        @(negedge clk);
        axi.arvalid = 1'b0;
    endtask

    task automatic wait_setup(input bit is_write, input logic [31:0] addr);
        int guard = 0;
        while (!psel) begin
            @(negedge clk);
            guard++;
            if (guard > 30) $fatal(1, "APB setup timeout");
        end
        if (penable || pwrite != is_write || paddr != addr)
            $fatal(1, "wrong APB setup: write=%b addr=%h", pwrite, paddr);
        @(negedge clk);
        if (!psel || !penable || pwrite != is_write || paddr != addr)
            $fatal(1, "wrong APB access entry");
    endtask

    task automatic complete_apb(input int waits);
        logic [31:0] addr_hold, data_hold;
        logic [3:0] strb_hold;
        logic write_hold;
        addr_hold = paddr;
        data_hold = pwdata;
        strb_hold = pstrb;
        write_hold = pwrite;
        for (int i = 0; i < waits; i++) begin
            @(negedge clk);
            if (!psel || !penable || paddr != addr_hold ||
                pwdata != data_hold || pstrb != strb_hold || pwrite != write_hold)
                $fatal(1, "APB changed during wait");
        end
        pready = 1'b1;
        @(negedge clk);
        pready = 1'b0;
        if (psel) $fatal(1, "APB select held after completion");
    endtask

    task automatic check_b(input logic [7:0] id, input logic [1:0] resp,
                           input int stalls = 3);
        int guard = 0;
        while (!axi.bvalid) begin
            @(negedge clk);
            guard++;
            if (guard > 30) $fatal(1, "B timeout");
        end
        for (int i = 0; i <= stalls; i++) begin
            if (!axi.bvalid || axi.bid != id || axi.bresp != resp)
                $fatal(1, "B changed under backpressure");
            @(negedge clk);
        end
        axi.bready = 1'b1;
        @(negedge clk);
        axi.bready = 1'b0;
        if (axi.bvalid) $fatal(1, "B remained valid after handshake");
    endtask

    task automatic check_r(input logic [7:0] id, input logic [1:0] resp,
                           input logic [127:0] data, input int stalls = 3);
        int guard = 0;
        while (!axi.rvalid) begin
            @(negedge clk);
            guard++;
            if (guard > 30) $fatal(1, "R timeout");
        end
        for (int i = 0; i <= stalls; i++) begin
            if (!axi.rvalid || axi.rid != id || axi.rresp != resp || axi.rdata != data)
                $fatal(1, "R changed under backpressure");
            @(negedge clk);
        end
        axi.rready = 1'b1;
        @(negedge clk);
        axi.rready = 1'b0;
        if (axi.rvalid) $fatal(1, "R remained valid after handshake");
    endtask

    initial begin
        if ($value$plusargs("SEED=%d", seed)) begin end
        rng = 32'(seed) ^ 32'h71ad3529;
        if (rng == 0) rng = 1;
        axi.awvalid = 0; axi.awaddr = 0; axi.awprot = 0; axi.awid = 0;
        axi.wvalid = 0; axi.wdata = 0; axi.wstrb = 0; axi.bready = 0;
        axi.arvalid = 0; axi.araddr = 0; axi.arprot = 0; axi.arid = 0;
        axi.rready = 0;
        step(3);
        rst = 1'b0;
        step(2);

        // AW precedes W. Address lane 2 chooses bits 95:64 and strobes 11:8.
        send_aw(32'h0010_0048, 8'hA1);
        step(2);
        send_w(128'h0000_0000_DEAD_BEEF_0000_0000_0000_0000, 16'h0F00);
        wait_setup(1'b1, 32'h0010_0048);
        if (pwdata != 32'hDEAD_BEEF || pstrb != 4'hF)
            $fatal(1, "wrong 128-to-32 write lane");
        complete_apb(3);
        check_b(8'hA1, 2'b00);
        if (apb_completions != 1) $fatal(1, "write APB count");

        // W precedes AW; APB error maps to AXI SLVERR.
        send_w(128'h0000_0000_0000_0000_0000_0000_1234_5678, 16'h000F);
        step(2);
        send_aw(32'h0010_0040, 8'hB2);
        wait_setup(1'b1, 32'h0010_0040);
        if (pwdata != 32'h1234_5678) $fatal(1, "W-first data lost");
        pslverr = 1'b1;
        complete_apb(0);
        check_b(8'hB2, 2'b10);
        pslverr = 1'b0;

        // APB read word is repeated over the 128-bit AXI response; stalls hold it.
        prdata = 32'hC0DE_1234;
        send_ar(32'h0010_0054, 8'hC3);
        wait_setup(1'b0, 32'h0010_0054);
        complete_apb(2);
        check_r(8'hC3, 2'b00, {4{32'hC0DE_1234}});

        // Invalid strobe and misaligned read produce no APB side effect.
        send_aw(32'h0010_0048, 8'hD4);
        send_w(128'b0, 16'h000F);
        check_b(8'hD4, 2'b10);
        if (psel || apb_completions != 3) $fatal(1, "invalid write reached APB");
        send_ar(32'h0010_0041, 8'hE5);
        check_r(8'hE5, 2'b10, 128'b0);
        if (psel || apb_completions != 3) $fatal(1, "invalid read reached APB");

        // A synchronous reset cancels an APB transfer before completion.
        send_aw(32'h0010_0044, 8'hF6);
        send_w(128'h0000_0000_0000_0000_ABCD_0000_0000_0000, 16'h00F0);
        wait_setup(1'b1, 32'h0010_0044);
        rst = 1'b1;
        step(1);
        if (psel || axi.bvalid || axi.rvalid || apb_completions != 3)
            $fatal(1, "reset did not cancel APB transfer");
        rst = 1'b0;
        step(2);

        // Simultaneous buffered read/write: reset priority gives the write first.
        fork
            send_aw(32'h0010_0040, 8'h11);
            send_w(128'h0000_0000_0000_0000_0000_0000_0000_00AA, 16'h000F);
            send_ar(32'h0010_0044, 8'h22);
        join
        wait_setup(1'b1, 32'h0010_0040);
        complete_apb(0);
        check_b(8'h11, 2'b00);
        wait_setup(1'b0, 32'h0010_0044);
        complete_apb(0);
        check_r(8'h22, 2'b00, {4{32'hC0DE_1234}});
        if (apb_completions != 5) $fatal(1, "read/write arbitration lost request");

        // Read errors clear RDATA; lane 3 writes use the uppermost 32 bits.
        send_ar(32'h0010_005C, 8'h33);
        wait_setup(1'b0, 32'h0010_005C);
        pslverr = 1'b1;
        complete_apb(1);
        check_r(8'h33, 2'b10, 128'b0);
        pslverr = 1'b0;
        send_aw(32'h0010_004C, 8'h44);
        send_w(128'h55AA_33CC_0000_0000_0000_0000_0000_0000, 16'hF000);
        wait_setup(1'b1, 32'h0010_004C);
        if (pwdata != 32'h55AA_33CC || pstrb != 4'hF)
            $fatal(1, "wrong upper write lane");
        complete_apb(0);
        check_b(8'h44, 2'b00);

        // After a write, simultaneous requests choose the read first.
        fork
            send_aw(32'h0010_0040, 8'h55);
            send_w(128'h0000_0000_0000_0000_0000_0000_0000_00BB, 16'h000F);
            send_ar(32'h0010_0044, 8'h66);
        join
        wait_setup(1'b0, 32'h0010_0044);
        complete_apb(0);
        check_r(8'h66, 2'b00, {4{32'hC0DE_1234}});
        wait_setup(1'b1, 32'h0010_0040);
        complete_apb(0);
        check_b(8'h55, 2'b00);
        if (apb_completions != 9) $fatal(1, "round-robin arbitration lost request");

        $display("SOC_BRIDGE_PASS: lanes, AW/W skew, APB waits/errors, B/R stalls, reset, round-robin");
        if ($test$plusargs("STRESS")) begin
            for (int idx = 0; idx < 32; idx++) reference_words[idx] = random_word();
            for (int transaction = 0; transaction < 160; transaction++) begin
                logic [31:0] address, data, choice;
                logic [127:0] full_data;
                logic [15:0] strobes;
                logic [3:0] bytes;
                logic [7:0] id;
                int idx, lane, aw_delay, w_delay, before_count;
                bit bad_alignment, bad_lane, slave_error;
                choice = random_word();
                idx = int'(choice[4:0]);
                lane = idx % 4;
                bytes = choice[11:8];
                id = choice[23:16];
                bad_alignment = transaction % 11 == 0;
                bad_lane = transaction % 13 == 0;
                slave_error = transaction % 7 == 0;
                address = 32'h00100080 + 32'(idx*4) + (bad_alignment ? 1 : 0);
                data = random_word();
                full_data = {random_word(), random_word(), random_word(), random_word()};
                full_data[lane*32 +: 32] = data;
                strobes = 16'(bytes) << (lane*4);
                if (bad_lane) strobes = strobes | (16'h1 << (((lane+1)%4)*4));
                aw_delay = int'(random_word()%8);
                w_delay = int'(random_word()%8);
                before_count = apb_completions;
                fork
                    begin step(aw_delay); send_aw(address, id); end
                    begin step(w_delay); send_w(full_data, strobes); end
                join
                if (bad_alignment || bad_lane) begin
                    check_b(id, 2, int'(random_word()%8));
                    if (apb_completions != before_count || psel)
                        $fatal(1, "random malformed write caused APB side effect");
                end else begin
                    wait_setup(1, address);
                    if (pwdata != data || pstrb != bytes)
                        $fatal(1, "random lane/strobe mismatch lane=%0d", lane);
                    pslverr = slave_error;
                    complete_apb(int'(random_word()%8));
                    check_b(id, slave_error ? 2 : 0, int'(random_word()%8));
                    pslverr = 0;
                    if (!slave_error)
                        for (int byte_idx = 0; byte_idx < 4; byte_idx++)
                            if (bytes[byte_idx]) reference_words[idx][8*byte_idx +: 8] = data[8*byte_idx +: 8];
                end
                // Re-read the selected independent target word, including the
                // cases whose writes were rejected or whose byte enable was 0.
                address = 32'h00100080 + 32'(idx*4);
                prdata = reference_words[idx];
                send_ar(address, id ^ 8'hff);
                wait_setup(0, address);
                if (pstrb != 0) $fatal(1, "read APB strobes are not zero");
                complete_apb(int'(random_word()%8));
                check_r(id ^ 8'hff, 0, {4{reference_words[idx]}}, int'(random_word()%8));
            end
            $display("IP_BRIDGE_STRESS_PASS seed=%0d random_write_read_pairs=160", seed);
        end
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "global timeout");
    end
endmodule

`default_nettype wire
