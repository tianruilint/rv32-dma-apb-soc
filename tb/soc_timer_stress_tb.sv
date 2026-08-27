// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// An external-pin scoreboard computes timer behavior from accepted APB
// transactions and elapsed clocks. It does not inspect DUT state.
module timer_stress_case #(
    parameter int WAITS = 0,
    parameter int CASE_ID = 0
) (output bit finished = 0);
    localparam logic [31:0] BASE = 32'h0010_0080;
    bit clk = 0;
    always #5 clk = ~clk;
    bit rst = 1;
    logic [31:0] addr = 0, wdata = 0;
    logic select = 0, access_phase = 0, write = 0;
    logic [3:0] strb = 0;
    wire ready, error, irq;
    wire [31:0] rdata;
    p2_apb_timer #(.BASE_ADDR(BASE), .WAIT_CYCLES(WAITS)) dut (
        .clk(clk), .rst(rst), .paddr(addr), .psel(select),
        .penable(access_phase), .pwrite(write), .pwdata(wdata),
        .pstrb(strb), .pready(ready), .prdata(rdata), .pslverr(error), .irq(irq)
    );

    bit ref_enable = 0, ref_periodic = 0, ref_irq_en = 0, ref_pending = 0;
    logic [31:0] ref_period = 0, ref_count = 0;
    int ref_wait = 0;
    int checks = 0, completions = 0, bad_accesses = 0;
    int expiration_clear_collisions = 0, reset_aborts = 0;
    logic [31:0] rng;
    int seed;
    function automatic logic [31:0] random_word();
        rng = rng ^ (rng << 13);
        rng = rng ^ (rng >> 17);
        rng = rng ^ (rng << 5);
        return rng;
    endfunction

    // The model uses an integer wait counter, independent byte updates, and
    // software-like clock accounting. Protocol checks operate only on pins.
    always @(posedge clk) begin : scoreboard
        bit accepted, legal, control_change, period_change, expired, clear;
        logic [31:0] expected_read;
        bit was_enabled;
        if (rst) begin
            ref_enable = 0;
            ref_periodic = 0;
            ref_irq_en = 0;
            ref_pending = 0;
            ref_period = 0;
            ref_count = 0;
            ref_wait = 0;
        end else begin
            assert (ready == (ref_wait == 0))
                else $fatal(1, "timer wait mismatch case=%0d wait=%0d", CASE_ID, ref_wait);
            accepted = select && access_phase && ref_wait == 0;
            legal = addr == BASE || addr == BASE+4 || addr == BASE+12 ||
                    (!write && addr == BASE+8);
            assert (error == (accepted && !legal))
                else $fatal(1, "timer error decode addr=%h write=%b", addr, write);
            expected_read = 0;
            if (select && !write) begin
                case (addr)
                    BASE: expected_read = {29'd0, ref_irq_en, ref_periodic, ref_enable};
                    BASE+4: expected_read = ref_period;
                    BASE+8: expected_read = ref_count;
                    BASE+12: expected_read = {30'd0,
                        (ref_enable && ref_period != 0 && ref_count != 0), ref_pending};
                    default: expected_read = 0;
                endcase
            end
            assert (rdata == expected_read)
                else $fatal(1, "timer read mismatch case=%0d addr=%h actual=%h ref=%h",
                            CASE_ID, addr, rdata, expected_read);
            control_change = accepted && write && addr == BASE && strb[0];
            period_change = accepted && write && addr == BASE+4 && strb != 0;
            clear = accepted && write && addr == BASE+12 && strb[0] && wdata[0];
            expired = ref_enable && ref_period != 0 && ref_count == 1 &&
                      !control_change && !period_change;
            was_enabled = ref_enable;
            if (!control_change && !period_change && ref_enable && ref_count != 0 && ref_period != 0) begin
                ref_count = ref_count - 1;
                if (ref_count == 0) begin
                    if (ref_periodic) ref_count = ref_period;
                    else ref_enable = 0;
                end
            end
            if (control_change) begin
                ref_enable = wdata[0];
                ref_periodic = wdata[1];
                ref_irq_en = wdata[2];
                if (!ref_enable) ref_count = 0;
                else if (!was_enabled) ref_count = ref_period;
            end
            if (period_change) begin
                for (int byte_idx = 0; byte_idx < 4; byte_idx++)
                    if (strb[byte_idx]) ref_period[8*byte_idx +: 8] = wdata[8*byte_idx +: 8];
                if (was_enabled) ref_count = ref_period;
            end
            if (clear) ref_pending = 0;
            if (expired) ref_pending = 1;
            if (expired && clear) expiration_clear_collisions++;
            if (accepted) begin
                completions++;
                if (!legal) bad_accesses++;
            end
            if (select && !access_phase) ref_wait = WAITS;
            else if (select && access_phase && ref_wait != 0) ref_wait--;
        end
        #1;
        assert (irq == (ref_pending && ref_irq_en))
            else $fatal(1, "timer IRQ mismatch case=%0d", CASE_ID);
        checks++;
    end

    task automatic apb(input bit wr, input logic [31:0] a,
                       input logic [31:0] d, input logic [3:0] bytes);
        int waited;
        @(negedge clk);
        addr = a; wdata = d; strb = bytes; write = wr;
        select = 1; access_phase = 0;
        @(negedge clk);
        access_phase = 1;
        waited = 0;
        do begin
            @(posedge clk);
            if (!ready) waited++;
        end while (!ready);
        assert (waited == WAITS) else $fatal(1, "wrong number of APB waits");
        @(negedge clk);
        select = 0; access_phase = 0;
    endtask

    task automatic reset_case;
        @(negedge clk);
        rst = 1; select = 0; access_phase = 0;
        repeat (2) @(negedge clk);
        rst = 0;
    endtask

    initial begin : stimulus
        logic [31:0] choice, a, d;
        bit wr;
        logic [3:0] bytes;
        if (!$value$plusargs("SEED=%d", seed)) seed = 20260925;
        rng = 32'(seed) ^ (32'h9e3779b9 * (32'(CASE_ID)+1));
        if (rng == 0) rng = 1;
        reset_case();
        // Every byte enable, including zero, is checked against the byte model.
        for (int mask = 0; mask < 16; mask++) begin
            apb(1, BASE+4, random_word(), 4'(mask));
            apb(0, BASE+4, 0, 0);
        end
        apb(1, BASE+4, 0, 15);
        apb(1, BASE, 7, 1);
        repeat (8) @(negedge clk);
        apb(0, BASE+8, 0, 0);
        apb(0, BASE+12, 0, 0);
        assert (!irq) else $fatal(1, "zero period generated interrupt");

        // Period=1 produces an event on the exact STATUS clear completion.
        apb(1, BASE+4, 1, 15);
        apb(1, BASE+12, 1, 1);
        assert (irq) else $fatal(1, "W1C incorrectly won against new event");
        apb(1, BASE, 0, 1);
        apb(1, BASE+12, 1, 1);
        assert (!irq) else $fatal(1, "W1C did not clear pending after disable");
        apb(1, BASE+4, 1, 15);
        apb(1, BASE, 5, 1);
        repeat (8) @(negedge clk);
        apb(0, BASE, 0, 0);
        apb(0, BASE+8, 0, 0);
        assert (irq) else $fatal(1, "one-shot did not assert IRQ");

        // Reset during SETUP (and during a wait, when configured) must abort.
        @(negedge clk);
        select = 1; access_phase = 0; addr = BASE+4; write = 1;
        wdata = 32'hbad0_bad0; strb = 15;
        @(negedge clk);
        if (WAITS != 0) access_phase = 1;
        rst = 1;
        @(negedge clk);
        select = 0; access_phase = 0;
        rst = 0; reset_aborts++;
        apb(0, BASE+4, 0, 0);

        for (int transaction = 0; transaction < 400; transaction++) begin
            choice = random_word();
            case (choice % 8)
                0: a = BASE;
                1: a = BASE+4;
                2: a = BASE+8;
                3: a = BASE+12;
                4: a = BASE+16;
                5: a = BASE+1;
                6: a = BASE-4;
                default: a = 32'hffff_fffc;
            endcase
            wr = choice[4];
            bytes = choice[11:8];
            d = (a == BASE+4 && choice[16]) ? (random_word() % 7) : random_word();
            apb(wr, a, d, bytes);
            // Pin reads compare count and control even after invalid writes.
            apb(0, BASE+8, 0, 0);
            if (transaction % 47 == 0) reset_case();
        end
        assert (expiration_clear_collisions > 0 && bad_accesses > 0 && reset_aborts > 0)
            else $fatal(1, "timer directed coverage missing");
        $display("TIMER_CASE_PASS seed=%0d waits=%0d checks=%0d transfers=%0d errors=%0d w1c_event_collisions=%0d reset_aborts=%0d",
                 seed, WAITS, checks, completions, bad_accesses, expiration_clear_collisions, reset_aborts);
        finished = 1;
    end
endmodule

module soc_timer_stress_tb;
    wire [2:0] done;
    timer_stress_case #(.WAITS(0), .CASE_ID(0)) t0(.finished(done[0]));
    timer_stress_case #(.WAITS(1), .CASE_ID(1)) t1(.finished(done[1]));
    timer_stress_case #(.WAITS(3), .CASE_ID(2)) t3(.finished(done[2]));
    initial begin
        wait (&done);
        $display("IP_TIMER_STRESS_PASS cases=3");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "timer global timeout");
    end
endmodule
`default_nettype wire
