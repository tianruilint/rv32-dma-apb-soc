// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module soc_dma_tb;
    localparam logic [31:0] BASE = 32'h00100040;
    localparam logic [31:0] SRC = 32'h000c0000;
    localparam logic [31:0] DST = 32'h000c1000;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;
    wire irq;
    p2_axil_if ctrl();
    p2_axil_if mem_bus();
    p2_dma dut (.clk(clk), .rst(rst), .s_ctrl(ctrl), .m_mem(mem_bus), .irq(irq));

    logic [127:0] ram [0:65535];
    int cycle_q = 0;
    int mem_mode = 0;
    int read_latency = 1;
    int write_latency = 1;
    int ar_count = 0, aw_count = 0, w_count = 0, b_count = 0;
    int first_aw_cycle = -1, first_w_cycle = -1;
    logic [31:0] stall_rng = 32'h1234abcd;
    logic [31:0] data_rng = 32'hcafe1234;
    int seed = 20260925;
    bit stress = 0;
    bit hold_b = 0;
    int completion_clear_collisions = 0;
    bit check_collision = 0;
    bit inject_r_error = 0, inject_b_error = 0;
    bit inject_r_badid = 0, inject_b_badid = 0;
    bit rd_pending = 0, rd_valid = 0;
    int rd_wait = 0;
    logic [127:0] rd_data = 0;
    logic [1:0] rd_resp = 0;
    logic [7:0] rd_id = 0;
    bit wr_aw_seen = 0, wr_w_seen = 0, wr_valid = 0;
    int wr_wait = 0;
    logic [31:0] wr_addr = 0;
    logic [7:0] wr_id = 0, wr_resp_id = 0;
    logic [127:0] wr_data = 0;
    logic [15:0] wr_strb = 0;
    logic [1:0] wr_resp = 0;
    bit held_ar = 0, held_aw = 0, held_w = 0;
    logic [31:0] held_araddr = 0, held_awaddr = 0;
    logic [7:0] held_arid = 0, held_awid = 0;
    logic [127:0] held_wdata = 0;
    logic [15:0] held_wstrb = 0;

    assign mem_bus.arready = !rst && !rd_pending && !rd_valid &&
                             (mem_mode != 3 || cycle_q % 3 == 0) &&
                             (mem_mode != 4 || stall_rng[0]) && mem_mode != 5;
    assign mem_bus.rvalid = rd_valid;
    assign mem_bus.rdata = rd_data;
    assign mem_bus.rresp = rd_resp;
    assign mem_bus.rid = rd_id;
    assign mem_bus.awready = !rst && !wr_aw_seen && !wr_valid && wr_wait == 0 &&
                             (mem_mode != 1 || cycle_q % 5 == 0) &&
                             (mem_mode != 3 || cycle_q % 3 == 1) &&
                             (mem_mode != 4 || stall_rng[3]) && mem_mode != 6;
    assign mem_bus.wready = !rst && !wr_w_seen && !wr_valid && wr_wait == 0 &&
                            (mem_mode != 2 || cycle_q % 5 == 0) &&
                            (mem_mode != 3 || cycle_q % 3 == 2) &&
                            (mem_mode != 4 || stall_rng[7]) && mem_mode != 7;
    assign mem_bus.bvalid = wr_valid && !hold_b;
    assign mem_bus.bresp = wr_resp;
    assign mem_bus.bid = wr_resp_id;

    // This is a stimulus model: configuration knobs are also set by tests.
    always @(posedge clk) begin
        if (rst) begin
            cycle_q <= 0;
            rd_pending <= 0;
            rd_valid <= 0;
            rd_wait <= 0;
            wr_aw_seen <= 0;
            wr_w_seen <= 0;
            wr_valid <= 0;
            wr_wait <= 0;
            held_ar <= 0;
            held_aw <= 0;
            held_w <= 0;
        end else begin
            cycle_q <= cycle_q + 1;
            // Hierarchy is used only to confirm this directed stimulus reached
            // the exact simultaneous W1C/completion edge, never as an oracle.
            if (check_collision && mem_bus.bvalid && mem_bus.bready &&
                dut.write_aw_seen_q && dut.write_w_seen_q && !dut.bvalid_q)
                completion_clear_collisions <= completion_clear_collisions + 1;
            stall_rng <= {stall_rng[30:0], stall_rng[31] ^ stall_rng[21] ^ stall_rng[1] ^ stall_rng[0]};
            if (held_ar)
                assert (mem_bus.arvalid && mem_bus.araddr == held_araddr &&
                        mem_bus.arid == held_arid)
                    else $fatal(1, "stalled DMA AR payload changed");
            if (held_aw)
                assert (mem_bus.awvalid && mem_bus.awaddr == held_awaddr &&
                        mem_bus.awid == held_awid)
                    else $fatal(1, "stalled DMA AW payload changed");
            if (held_w)
                assert (mem_bus.wvalid && mem_bus.wdata == held_wdata &&
                        mem_bus.wstrb == held_wstrb)
                    else $fatal(1, "stalled DMA W payload changed");
            held_ar <= mem_bus.arvalid && !mem_bus.arready;
            held_aw <= mem_bus.awvalid && !mem_bus.awready;
            held_w <= mem_bus.wvalid && !mem_bus.wready;
            if (mem_bus.arvalid && !mem_bus.arready) begin
                held_araddr <= mem_bus.araddr;
                held_arid <= mem_bus.arid;
            end
            if (mem_bus.awvalid && !mem_bus.awready) begin
                held_awaddr <= mem_bus.awaddr;
                held_awid <= mem_bus.awid;
            end
            if (mem_bus.wvalid && !mem_bus.wready) begin
                held_wdata <= mem_bus.wdata;
                held_wstrb <= mem_bus.wstrb;
            end
            if (mem_bus.arvalid && mem_bus.arready) begin
                assert (mem_bus.arid == 8'h20 && mem_bus.araddr[3:0] == 0)
                    else $fatal(1, "DMA read address/ID invalid");
                ar_count <= ar_count + 1;
                rd_data <= ram[mem_bus.araddr[19:4]];
                rd_resp <= inject_r_error ? 2'b10 : 2'b00;
                rd_id <= inject_r_badid ? 8'h21 : mem_bus.arid;
                inject_r_error <= 0;
                inject_r_badid <= 0;
                rd_pending <= 1;
                rd_wait <= mem_mode == 4 ? int'(stall_rng[12:10]) : read_latency;
            end
            if (rd_pending) begin
                if (rd_wait == 0) begin
                    rd_pending <= 0;
                    rd_valid <= 1;
                end else rd_wait <= rd_wait - 1;
            end
            if (rd_valid && mem_bus.rready) rd_valid <= 0;

            if (mem_bus.awvalid && mem_bus.awready) begin
                assert (mem_bus.awid == 8'h20 && mem_bus.awaddr[3:0] == 0)
                    else $fatal(1, "DMA write address/ID invalid");
                wr_addr <= mem_bus.awaddr;
                wr_id <= mem_bus.awid;
                wr_aw_seen <= 1;
                aw_count <= aw_count + 1;
                if (first_aw_cycle < 0) first_aw_cycle <= cycle_q;
            end
            if (mem_bus.wvalid && mem_bus.wready) begin
                assert (mem_bus.wstrb == 16'hffff)
                    else $fatal(1, "DMA write strobe invalid");
                wr_data <= mem_bus.wdata;
                wr_strb <= mem_bus.wstrb;
                wr_w_seen <= 1;
                w_count <= w_count + 1;
                if (first_w_cycle < 0) first_w_cycle <= cycle_q;
            end
            if (wr_aw_seen && wr_w_seen && !wr_valid && wr_wait == 0) begin
                assert (wr_strb == 16'hffff) else $fatal(1, "write strobe lost");
                wr_aw_seen <= 0;
                wr_w_seen <= 0;
                wr_resp <= inject_b_error ? 2'b10 : 2'b00;
                wr_resp_id <= inject_b_badid ? 8'h21 : wr_id;
                inject_b_error <= 0;
                inject_b_badid <= 0;
                if (!inject_b_error && !inject_b_badid) ram[wr_addr[19:4]] <= wr_data;
                wr_wait <= mem_mode == 4 ? int'(stall_rng[18:16]) : write_latency;
                // A zero-latency slave still owes exactly one B response. The
                // old model only raised BVALID in the positive countdown path.
                if ((mem_mode == 4 ? int'(stall_rng[18:16]) : write_latency) == 0)
                    wr_valid <= 1;
            end
            if (wr_wait > 0) begin
                wr_wait <= wr_wait - 1;
                if (wr_wait == 1) wr_valid <= 1;
            end
            if (mem_bus.bvalid && mem_bus.bready) begin
                wr_valid <= 0;
                b_count <= b_count + 1;
            end
        end
    end

    task automatic ctrl_write(
        input logic [31:0] addr,
        input logic [31:0] value,
        input logic [3:0] byte_en,
        input int aw_delay,
        input int w_delay,
        input int response_stall,
        input logic [1:0] expected_resp,
        input bit raw_strobe = 0,
        input logic [15:0] supplied_strobes = 0
    );
        bit aw_done, w_done, got_b;
        logic [127:0] full_data;
        logic [15:0] full_strb;
        int beat;
        beat = int'(addr[3:2]);
        full_data = 128'h01234567_89abcdef_fedcba98_76543210;
        full_data[beat*32 +: 32] = value;
        full_strb = 16'(byte_en) << (beat*4);
        if (raw_strobe) full_strb = supplied_strobes;
        aw_done = 0;
        w_done = 0;
        got_b = 0;
        @(negedge clk);
        ctrl.awaddr = addr;
        ctrl.awprot = 0;
        ctrl.awid = 8'h51;
        ctrl.wdata = full_data;
        ctrl.wstrb = full_strb;
        ctrl.awvalid = (aw_delay == 0);
        ctrl.wvalid = (w_delay == 0);
        ctrl.bready = 0;
        for (int tick = 0; tick < 100; tick++) begin
            @(posedge clk);
            if (ctrl.awvalid && ctrl.awready) aw_done = 1;
            if (ctrl.wvalid && ctrl.wready) w_done = 1;
            @(negedge clk);
            if (aw_done) ctrl.awvalid = 0;
            else if (tick + 1 >= aw_delay) ctrl.awvalid = 1;
            if (w_done) ctrl.wvalid = 0;
            else if (tick + 1 >= w_delay) ctrl.wvalid = 1;
            if (aw_done && w_done) break;
        end
        assert (aw_done && w_done) else $fatal(1, "control AW/W timeout");
        for (int tick = 0; tick < 100; tick++) begin
            @(posedge clk);
            if (ctrl.bvalid) begin
                assert (ctrl.bresp == expected_resp && ctrl.bid == 8'h51)
                    else $fatal(1, "control B mismatch addr=%h resp=%h", addr, ctrl.bresp);
                got_b = 1;
                break;
            end
        end
        assert (got_b) else $fatal(1, "control B timeout");
        repeat (response_stall) begin
            @(posedge clk);
            assert (ctrl.bvalid && ctrl.bresp == expected_resp && ctrl.bid == 8'h51)
                else $fatal(1, "control B not stable under stall");
        end
        @(negedge clk);
        ctrl.bready = 1;
        @(posedge clk);
        @(negedge clk);
        ctrl.bready = 0;
    endtask

    task automatic ctrl_read(input logic [31:0] addr,
                             input int response_stall,
                             input logic [1:0] expected_resp,
                             output logic [31:0] value);
        bit accepted, got_r;
        logic [127:0] sampled;
        accepted = 0;
        got_r = 0;
        @(negedge clk);
        ctrl.araddr = addr;
        ctrl.arprot = 0;
        ctrl.arid = 8'h52;
        ctrl.arvalid = 1;
        ctrl.rready = 0;
        for (int tick = 0; tick < 100; tick++) begin
            @(posedge clk);
            if (ctrl.arready) begin accepted = 1; break; end
        end
        assert (accepted) else $fatal(1, "control AR timeout");
        @(negedge clk);
        ctrl.arvalid = 0;
        for (int tick = 0; tick < 100; tick++) begin
            @(posedge clk);
            if (ctrl.rvalid) begin
                assert (ctrl.rresp == expected_resp && ctrl.rid == 8'h52)
                    else $fatal(1, "control R mismatch addr=%h resp=%h", addr, ctrl.rresp);
                sampled = ctrl.rdata;
                got_r = 1;
                break;
            end
        end
        assert (got_r) else $fatal(1, "control R timeout");
        for (int tick = 0; tick < response_stall; tick++) begin
            @(posedge clk);
            assert (ctrl.rvalid && ctrl.rdata == sampled && ctrl.rid == 8'h52)
                else $fatal(1, "control R not stable under stall");
        end
        if (expected_resp == 0) begin
            assert (sampled[31:0] == sampled[63:32] &&
                    sampled[31:0] == sampled[95:64] &&
                    sampled[31:0] == sampled[127:96])
                else $fatal(1, "register read lanes differ");
        end
        value = sampled[31:0];
        @(negedge clk);
        ctrl.rready = 1;
        @(posedge clk);
        @(negedge clk);
        ctrl.rready = 0;
    endtask

    task automatic program_copy(input logic [31:0] src,
                                input logic [31:0] dst,
                                input logic [31:0] bytes);
        ctrl_write(BASE+0, src, 4'hf, 2, 0, 2, 0);
        ctrl_write(BASE+4, dst, 4'hf, 0, 2, 0, 0);
        ctrl_write(BASE+8, bytes, 4'hf, 0, 0, 0, 0);
    endtask

    task automatic await_terminal(output logic [31:0] status);
        bit reached;
        reached = 0;
        for (int poll = 0; poll < 10000; poll++) begin
            ctrl_read(BASE+16, 0, 0, status);
            if (status[1] || status[2]) begin reached = 1; break; end
        end
        assert (reached) else $fatal(1, "DMA terminal status timeout");
    endtask

    task automatic clear_status;
        ctrl_write(BASE+16, 32'h0000001e, 4'h1, 0, 0, 0, 0);
    endtask

    task automatic reset_dut;
        @(negedge clk);
        rst = 1;
        ctrl.awvalid = 0;
        ctrl.wvalid = 0;
        ctrl.arvalid = 0;
        ctrl.bready = 0;
        ctrl.rready = 0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 0;
    endtask

    logic [31:0] status, value;
    int before_reads, before_writes;
    logic [127:0] golden [0:255];
    function automatic logic [31:0] random_word();
        data_rng = data_rng ^ (data_rng << 13);
        data_rng = data_rng ^ (data_rng >> 17);
        data_rng = data_rng ^ (data_rng << 5);
        return data_rng;
    endfunction

    task automatic stress_copy(input int bytes, input logic [31:0] source,
                               input logic [31:0] destination);
        logic [127:0] guard;
        logic [31:0] terminal_status;
        int reads_before, writes_before;
        guard = 128'hb5a5cafefeeddeed123456789abcdef0;
        ram[(destination >> 4)-1] = guard;
        if (destination + 32'(bytes) < 32'h00100000)
            ram[(destination >> 4)+(bytes/16)] = guard;
        for (int beat = 0; beat < bytes/16; beat++) begin
            golden[beat] = {random_word(), random_word(), random_word(), random_word()};
            ram[(source >> 4)+beat] = golden[beat];
            ram[(destination >> 4)+beat] = ~golden[beat];
        end
        reads_before = ar_count; writes_before = aw_count;
        program_copy(source, destination, 32'(bytes));
        ctrl_write(BASE+12, 1, 1, int'(random_word()%7), int'(random_word()%7), 4, 0);
        await_terminal(terminal_status);
        assert (terminal_status == 10 && !irq)
            else $fatal(1, "masked completion IRQ/status=%h irq=%b", terminal_status, irq);
        assert (ar_count-reads_before == bytes/16 && aw_count-writes_before == bytes/16)
            else $fatal(1, "wrong transfer counts in stress copy");
        for (int beat = 0; beat < bytes/16; beat++) begin
            assert (ram[(destination >> 4)+beat] == golden[beat] &&
                    ram[(source >> 4)+beat] == golden[beat])
                else $fatal(1, "random copy mismatch byte_length=%0d beat=%0d", bytes, beat);
        end
        assert (ram[(destination >> 4)-1] == guard)
            else $fatal(1, "DMA overwrote guard");
        if (destination + 32'(bytes) < 32'h00100000)
            assert (ram[(destination >> 4)+(bytes/16)] == guard)
                else $fatal(1, "DMA overwrote trailing guard");
        // Pending must remember completion while masked and assert when enabled.
        ctrl_write(BASE+12, 2, 1, 0, 0, 0, 0);
        assert (irq) else $fatal(1, "enabling IRQ lost masked pending completion");
        clear_status();
        assert (!irq) else $fatal(1, "IRQ remained after W1C");
    endtask
    initial begin
        if ($value$plusargs("SEED=%d", seed)) begin end
        stress = $test$plusargs("STRESS");
        stall_rng = 32'(seed) ^ 32'h19e74921;
        data_rng = 32'(seed) ^ 32'hb8d973e5;
        if (stall_rng == 0) stall_rng = 1;
        if (data_rng == 0) data_rng = 1;
        ctrl.awvalid = 0;
        ctrl.awaddr = 0;
        ctrl.awprot = 0;
        ctrl.awid = 0;
        ctrl.wvalid = 0;
        ctrl.wdata = 0;
        ctrl.wstrb = 0;
        ctrl.bready = 0;
        ctrl.arvalid = 0;
        ctrl.araddr = 0;
        ctrl.arprot = 0;
        ctrl.arid = 0;
        ctrl.rready = 0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 0;

        // 256 bytes, four register lanes, control response stalls, IRQ W1C.
        for (int i = 0; i < 16; i++) begin
            ram[(SRC >> 4)+i] = {32'(i+4),32'(i+3),32'(i+2),32'(i+1)};
            ram[(DST >> 4)+i] = 128'hdeadbeef;
        end
        program_copy(SRC, DST, 256);
        ctrl_read(BASE+0, 2, 0, value);
        assert (value == SRC) else $fatal(1, "SRC register mismatch");
        ctrl_read(BASE+4, 0, 0, value);
        assert (value == DST) else $fatal(1, "DST register mismatch");
        ctrl_read(BASE+8, 0, 0, value);
        assert (value == 256) else $fatal(1, "LEN register mismatch");
        ctrl_write(BASE+12, 32'h3, 4'h1, 0, 0, 3, 0);
        await_terminal(status);
        assert (status[4:0] == 5'b01010 && irq)
            else $fatal(1, "DMA success status=%h irq=%b", status, irq);
        for (int i = 0; i < 16; i++) begin
            assert (ram[(DST >> 4)+i] == ram[(SRC >> 4)+i])
                else $fatal(1, "copy mismatch beat %0d", i);
        end
        assert (ar_count == 16 && aw_count == 16 && w_count == 16 && b_count == 16)
            else $fatal(1, "copy event counts %0d/%0d/%0d/%0d",
                        ar_count, aw_count, w_count, b_count);
        clear_status();
        ctrl_read(BASE+16, 0, 0, status);
        assert (status == 0 && !irq) else $fatal(1, "W1C failed");
        $display("PASS dma_256b_lanes_stalls_irq_w1c");

        // Slow AW and then slow W prove independent write-channel progress.
        for (int mode = 1; mode <= 2; mode++) begin
            mem_mode = mode;
            first_aw_cycle = -1;
            first_w_cycle = -1;
            ram[DST >> 4] = 0;
            program_copy(SRC, DST, 16);
            ctrl_write(BASE+12, 32'h1, 4'h1, 0, 0, 0, 0);
            await_terminal(status);
            assert (status[1] && ram[DST >> 4] == ram[SRC >> 4])
                else $fatal(1, "skew copy mode %0d", mode);
            assert (first_aw_cycle != first_w_cycle)
                else $fatal(1, "AW/W skew not exercised mode %0d", mode);
            clear_status();
        end
        mem_mode = 0;
        $display("PASS dma_aw_w_skew");

        // Invalid configuration is rejected before a memory request.
        before_reads = ar_count;
        before_writes = aw_count;
        program_copy(SRC, DST, 15);
        ctrl_write(BASE+12, 32'h1, 4'h1, 0, 0, 0, 2);
        ctrl_read(BASE+16, 0, 0, status);
        assert (status[2] && status[3] && !status[0] &&
                ar_count == before_reads && aw_count == before_writes)
            else $fatal(1, "invalid length accepted status=%h", status);
        clear_status();
        program_copy(SRC, SRC+16, 32);
        ctrl_write(BASE+12, 32'h1, 4'h1, 0, 0, 0, 2);
        ctrl_read(BASE+16, 0, 0, status);
        assert (status[2]) else $fatal(1, "overlap accepted");
        clear_status();
        program_copy(SRC, DST, 0);
        ctrl_write(BASE+12, 32'h1, 4'h1, 0, 0, 0, 2);
        ctrl_read(BASE+16, 0, 0, status);
        assert (status[2]) else $fatal(1, "zero length accepted");
        clear_status();
        program_copy(SRC, DST, 4112);
        ctrl_write(BASE+12, 32'h1, 4'h1, 0, 0, 0, 2);
        ctrl_read(BASE+16, 0, 0, status);
        assert (status[2]) else $fatal(1, "over-limit length accepted");
        clear_status();
        program_copy(SRC+4, DST, 16);
        ctrl_write(BASE+12, 32'h1, 4'h1, 0, 0, 0, 2);
        ctrl_read(BASE+16, 0, 0, status);
        assert (status[2]) else $fatal(1, "unaligned source accepted");
        clear_status();
        program_copy(32'h000ffff0, DST, 32);
        ctrl_write(BASE+12, 32'h1, 4'h1, 0, 0, 0, 2);
        ctrl_read(BASE+16, 0, 0, status);
        assert (status[2]) else $fatal(1, "out-of-range accepted");
        clear_status();
        $display("PASS dma_invalid_length_overlap_range");

        // Each transfer is single-beat; a sequence may straddle 4 KiB.
        ram[32'h000c0ff0 >> 4] = 128'h1234;
        ram[32'h000c1000 >> 4] = 128'h5678;
        ram[32'h000c2000 >> 4] = 0;
        ram[32'h000c2010 >> 4] = 0;
        program_copy(32'h000c0ff0, 32'h000c2000, 32);
        ctrl_write(BASE+12, 32'h1, 4'h1, 0, 0, 0, 0);
        await_terminal(status);
        assert (status[1] && ram[32'h000c2000 >> 4] == 128'h1234 &&
                ram[32'h000c2010 >> 4] == 128'h5678)
            else $fatal(1, "4 KiB crossing copy failed");
        clear_status();
        $display("PASS dma_4k_sequence_crossing");

        // A busy START is rejected without replacing the active copy.
        mem_mode = 3;
        read_latency = 4;
        write_latency = 4;
        program_copy(SRC, DST, 256);
        ctrl_write(BASE+12, 32'h3, 4'h1, 0, 0, 0, 0);
        ctrl_write(BASE+12, 32'h1, 4'h1, 0, 0, 0, 2);
        ctrl_read(BASE+12, 0, 0, value);
        assert (value[1]) else $fatal(1, "busy START changed IRQ_EN");
        ctrl_read(BASE+16, 0, 0, status);
        assert (status[0] && status[4]) else $fatal(1, "busy START status=%h", status);
        await_terminal(status);
        assert (status[1] && status[4] && !status[2] && irq)
            else $fatal(1, "busy START corrupted transfer status=%h", status);
        clear_status();
        mem_mode = 0;
        read_latency = 1;
        write_latency = 1;
        $display("PASS dma_busy_start");

        // RRESP/BRESP and returned-ID errors terminate without further beats.
        for (int failure = 0; failure < 4; failure++) begin
            program_copy(SRC, DST, 32);
            if (failure == 0) inject_r_error = 1;
            if (failure == 1) inject_b_error = 1;
            if (failure == 2) inject_r_badid = 1;
            if (failure == 3) inject_b_badid = 1;
            before_reads = ar_count;
            ctrl_write(BASE+12, 32'h1, 4'h1, 0, 0, 0, 0);
            await_terminal(status);
            assert (status[2] && !status[1] && ar_count == before_reads+1)
                else $fatal(1, "error handling failure=%0d status=%h", failure, status);
            inject_r_error = 0;
            inject_b_error = 0;
            inject_r_badid = 0;
            inject_b_badid = 0;
            clear_status();
        end
        $display("PASS dma_resp_and_id_errors");

        // Partial-byte write and register-write rejection during activity.
        ctrl_write(BASE+8, 32'h00000100, 4'b0010, 0, 0, 0, 0);
        ctrl_read(BASE+8, 0, 0, value);
        assert (value == 32'h00000120) else $fatal(1, "byte strobe merge %h", value);
        program_copy(SRC, DST, 256);
        mem_mode = 3;
        ctrl_write(BASE+12, 32'h1, 4'h1, 0, 0, 0, 0);
        ctrl_write(BASE+0, SRC+16, 4'hf, 0, 0, 0, 2);
        await_terminal(status);
        mem_mode = 0;
        clear_status();
        $display("PASS dma_byte_strobe_and_busy_register_protection");

        // Synchronous reset aborts and clears state even with work in flight.
        mem_mode = 3;
        read_latency = 6;
        program_copy(SRC, DST, 256);
        ctrl_write(BASE+12, 32'h1, 4'h1, 0, 0, 0, 0);
        ctrl_read(BASE+16, 0, 0, status);
        assert (status[0]) else $fatal(1, "reset case did not start");
        reset_dut();
        ctrl_read(BASE+16, 0, 0, status);
        assert (status == 0 && !irq && !mem_bus.arvalid && !mem_bus.awvalid)
            else $fatal(1, "reset did not abort status=%h", status);
        $display("PASS dma_reset_abort");
        $display("PASS soc_dma_tb 8 groups");
        if (stress) begin
            read_latency = 0;
            write_latency = 0;
            mem_mode = 0;
            // Zero additional slave latency is legal and must not deadlock.
            stress_copy(16, 32'h00001000, 32'h00003000);
            $display("PASS dma_zero_additional_response_latency");
            mem_mode = 4;
            stress_copy(4096, 32'h00040000, 32'h00050000);
            stress_copy(16, 32'h000ffff0, 32'h00001000);
            stress_copy(16, 32'h00001000, 32'h000ffff0);
            for (int run = 0; run < 24; run++)
                stress_copy(16*int'((random_word()%256)+1), 32'h00060000, 32'h00070000);
            $display("PASS dma_random_copy_count=27 max_bytes=4096 boundary=1MiB");

            // Reject holes, out-of-window aliases, misalignment, and wrong lanes.
            before_reads = ar_count;
            ctrl_write(BASE+20, 1, 15, 0, 3, 3, 2);
            ctrl_read(BASE+20, 3, 2, value);
            ctrl_write(BASE+64, 1, 15, 3, 0, 3, 2);
            ctrl_read(BASE+64, 3, 2, value);
            ctrl_write(BASE+1, 1, 15, 0, 0, 3, 2);
            ctrl_read(BASE+1, 3, 2, value);
            ctrl_write(BASE, 1, 15, 0, 0, 3, 2, 1, 16'hfff0);
            assert (ar_count == before_reads) else $fatal(1, "bad register request caused DMA request");
            ctrl_read(BASE, 0, 0, value);
            for (int mask = 0; mask < 16; mask++) begin
                logic [31:0] written, expected;
                written = random_word();
                expected = value;
                for (int byte_idx = 0; byte_idx < 4; byte_idx++)
                    if (mask[byte_idx]) expected[byte_idx*8 +: 8] = written[byte_idx*8 +: 8];
                ctrl_write(BASE, written, 4'(mask), int'(random_word()%5), int'(random_word()%5), 4, 0);
                ctrl_read(BASE, 4, 0, value);
                assert (value == expected) else $fatal(1, "DMA all-byte-mask check failed mask=%h", mask);
            end
            $display("PASS dma_illegal_registers_all_byte_masks");
            mem_mode = 0;
            read_latency = 0;
            write_latency = 0;
            hold_b = 1;
            program_copy(SRC, DST, 16);
            ctrl_write(BASE+12, 3, 1, 0, 0, 0, 0);
            wait (wr_valid && mem_bus.bready);
            check_collision = 1;
            fork
                ctrl_write(BASE+16, 32'h1e, 1, 0, 0, 0, 0);
                begin
                    do @(posedge clk); while (!(ctrl.awvalid && ctrl.awready && ctrl.wvalid && ctrl.wready));
                    @(negedge clk);
                    hold_b = 0;
                end
            join
            check_collision = 0;
            ctrl_read(BASE+16, 0, 0, status);
            assert (status == 10 && irq && completion_clear_collisions == 1)
                else $fatal(1, "DMA W1C/completion race status=%h irq=%b collisions=%0d",
                            status, irq, completion_clear_collisions);
            clear_status();
            $display("PASS dma_w1c_completion_same_cycle collisions=1");

            // Reset the complete bus domain with AR stalled, AW stalled after
            // W, W stalled after AW, a pending R, and a pending B respectively.
            for (int phase = 0; phase < 5; phase++) begin
                mem_mode = phase < 3 ? phase+5 : 0;
                read_latency = phase == 3 ? 100 : 0;
                hold_b = phase == 4;
                program_copy(SRC, DST, 16);
                ctrl_write(BASE+12, 3, 1, 0, 0, 0, 0);
                case (phase)
                    0: wait(mem_bus.arvalid && !mem_bus.arready);
                    1: wait(mem_bus.awvalid && !mem_bus.awready && wr_w_seen);
                    2: wait(mem_bus.wvalid && !mem_bus.wready && wr_aw_seen);
                    3: wait(rd_pending && mem_bus.rready);
                    4: wait(wr_valid && mem_bus.bready);
                    default: $fatal(1, "invalid reset phase");
                endcase
                reset_dut();
                hold_b = 0;
                ctrl_read(BASE+16, 2, 0, status);
                assert (status == 0 && !irq && !mem_bus.arvalid && !mem_bus.awvalid && !mem_bus.wvalid)
                    else $fatal(1, "DMA reset phase=%0d left request/status", phase);
            end
            mem_mode = 0;
            read_latency = 0;
            stress_copy(16, SRC, DST);
            $display("PASS dma_reset_each_memory_phase phases=5 recovery_copy=1");
            $display("IP_DMA_STRESS_PASS seed=%0d random_jobs=27", seed);
        end
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1, "global timeout");
    end
endmodule

`default_nettype wire
