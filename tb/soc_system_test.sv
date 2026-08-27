// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// End-to-end firmware test. This RAM is a simulation model, not an ASIC SRAM.
module soc_system_test;
    localparam logic [31:0] SRC = 32'h000c_0000;
    localparam logic [31:0] DST = 32'h000c_1000;
    localparam logic [31:0] RESULT = 32'h000c_1f00;
    localparam logic [31:0] PASS = 32'h600d_600d;
    localparam int MAX_CYCLES = 500_000;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;
    logic rtc = 1'b0;
    always #500 rtc = ~rtc;
    wire logic uart_tx, uart_rts, dma_irq, timer_irq;
    wire logic [31:0] gpio_out;
    wire logic [7:0] cpu_status;
    wire logic [31:0] ram_reads, ram_writes;
    p2_axil_if #(.ADDR_W(32), .DATA_W(128), .ID_W(8)) ram_bus();

    p2_soc_top dut (
        .clk(clk), .rst(rst), .rtc(rtc), .uart_rx(1'b1), .uart_cts(1'b1),
        .gpio_in(32'b0), .uart_tx(uart_tx), .uart_rts(uart_rts),
        .gpio_out(gpio_out), .cpu_status(cpu_status), .dma_irq(dma_irq),
        .timer_irq_out(timer_irq), .m_ram(ram_bus)
    );
    soc_ram_model ram (
        .clk(clk), .rst(rst), .s_axi(ram_bus),
        .read_accepts(ram_reads), .write_accepts(ram_writes)
    );

    int dma_reads = 0;
    int dma_writes = 0;
    int cpu_dst_reads_after_dma = 0;
    int cpu_src_writes = 0;
    logic [63:0] cpu_source_words = '0;
    logic [63:0] cpu_dest_words = '0;
    int cpu_ram_reads_during_dma = 0;
    int cpu_foreground_reads_during_dma = 0;
    int timer_reads = 0;
    int timer_writes = 0;
    string uart_capture = "";
    bit uart_marker_seen = 0;
    bit reset_requested = 0;
    bit reset_completed = 0;
    bit timer_irq_seen = 0;
    bit dma_irq_seen = 0;
    int trace_fd = 0;
    int trace_cycle = 0;
    string trace_path, vcd_path;

    initial begin
        if ($value$plusargs("TRACE_CSV=%s", trace_path)) begin
            trace_fd = $fopen(trace_path, "w");
            if (trace_fd == 0) $fatal(1, "Cannot open trace %s", trace_path);
            $fwrite(trace_fd, "cycle,rst,ram_arvalid,ram_arready,ram_arid,ram_araddr,ram_rvalid,ram_rready,ram_rid,ram_awvalid,ram_awready,ram_awid,ram_awaddr,ram_wvalid,ram_wready,ram_bvalid,ram_bready,ram_bid,apb_psel,apb_penable,apb_pready,apb_pwrite,apb_paddr,apb_pwdata,apb_prdata,dma_irq,timer_irq,uart_tx,dma_reads,dma_writes,result\n");
        end
        if ($value$plusargs("VCD=%s", vcd_path)) begin
            $dumpfile(vcd_path);
            $dumpvars(1, soc_system_test);
        end
    end

    // One system reset during an accepted DMA transfer, followed by a full
    // firmware reboot and the same end-to-end checks.
    initial begin : restart_test
        if ($test$plusargs("RESET_DURING_DMA")) begin
            reset_requested = 1;
            wait (dma_reads > 0 && dma_writes < 16);
            @(negedge clk);
            rst = 1;
            $display("SOC_RESET_DURING_DMA cycle=%0d", trace_cycle);
            repeat (12) @(negedge clk);
            rst = 0;
            reset_completed = 1;
        end
    end

    always @(posedge clk) begin
        trace_cycle <= trace_cycle + 1;
        if (trace_fd != 0)
            $fwrite(trace_fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                trace_cycle, rst, ram_bus.arvalid, ram_bus.arready, ram_bus.arid,
                ram_bus.araddr, ram_bus.rvalid, ram_bus.rready, ram_bus.rid,
                ram_bus.awvalid, ram_bus.awready, ram_bus.awid, ram_bus.awaddr,
                ram_bus.wvalid, ram_bus.wready, ram_bus.bvalid, ram_bus.bready,
                ram_bus.bid, dut.apb_psel, dut.apb_penable, dut.apb_pready,
                dut.apb_pwrite, dut.apb_paddr, dut.apb_pwdata, dut.apb_prdata,
                dma_irq, timer_irq, uart_tx, dma_reads, dma_writes,
                ram.mem[RESULT >> 4][31:0]);
        if (rst) begin
            dma_reads <= 0; dma_writes <= 0;
            cpu_dst_reads_after_dma <= 0; cpu_src_writes <= 0;
            cpu_source_words <= '0; cpu_dest_words <= '0;
            cpu_ram_reads_during_dma <= 0;
            cpu_foreground_reads_during_dma <= 0;
            timer_reads <= 0; timer_writes <= 0;
            timer_irq_seen <= 0; dma_irq_seen <= 0;
        end else begin
            if (timer_irq) timer_irq_seen <= 1;
            if (dma_irq) dma_irq_seen <= 1;
            if (ram_bus.arvalid && ram_bus.arready) begin
                if (ram_bus.arid == 8'h20) dma_reads <= dma_reads + 1;
                if ((ram_bus.arid & 8'hf0) == 8'h10 && dma_reads > 0 && dma_writes < 16)
                    cpu_ram_reads_during_dma <= cpu_ram_reads_during_dma + 1;
                if ((ram_bus.arid & 8'hf0) == 8'h10 && ram_bus.araddr == 32'h000c_1f20 &&
                    dma_reads > 0 && dma_writes < 16)
                    cpu_foreground_reads_during_dma <= cpu_foreground_reads_during_dma + 1;
                if ((ram_bus.arid & 8'hf0) == 8'h10 &&
                    ram_bus.araddr >= DST && ram_bus.araddr < DST + 256 &&
                    dma_writes == 16) begin
                    cpu_dst_reads_after_dma <= cpu_dst_reads_after_dma + 1;
                    cpu_dest_words[6'((ram_bus.araddr - DST) >> 2)] <= 1'b1;
                end
            end
            if (ram_bus.awvalid && ram_bus.awready) begin
                if (ram_bus.awid == 8'h20) dma_writes <= dma_writes + 1;
                if ((ram_bus.awid & 8'hf0) == 8'h10 &&
                    ram_bus.awaddr >= SRC && ram_bus.awaddr < SRC + 256) begin
                    cpu_src_writes <= cpu_src_writes + 1;
                    cpu_source_words[6'((ram_bus.awaddr - SRC) >> 2)] <= 1'b1;
                end
            end
            if (dut.target[3].awvalid && dut.target[3].awready)
                timer_writes <= timer_writes + 1;
            if (dut.target[3].arvalid && dut.target[3].arready)
                timer_reads <= timer_reads + 1;
        end
    end

    always @(posedge rst) begin
        uart_capture = "";
        uart_marker_seen = 0;
    end

    // Pinned FRISCV UART uses CLKDIV=4, giving 50 ns per serial bit at the
    // 10 ns SoC clock. Decode the actual output pin, including the stop bit.
    always @(negedge uart_tx) begin : decode_uart
        logic [7:0] ch;
        if (!rst) begin
            #25;
            if (rst) disable decode_uart;
            if (uart_tx !== 1'b0) $fatal(1, "UART start bit invalid");
            for (int bit_idx = 0; bit_idx < 8; bit_idx++) begin
                #50;
                if (rst) disable decode_uart;
                ch[bit_idx] = uart_tx;
            end
            #50;
            if (rst) disable decode_uart;
            if (uart_tx !== 1'b1) $fatal(1, "UART stop bit invalid");
            uart_capture = {uart_capture, ch};
            $display("SOC_UART_CHAR %c", ch);
            if (uart_capture == "P2_DMA_PASS\n") uart_marker_seen = 1;
        end
    end

    initial begin : run_test
        int cycles;
        repeat (12) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (cycles = 0; cycles < MAX_CYCLES; cycles++) begin
            @(negedge clk);
            if (!rst && (!reset_requested || reset_completed) &&
                ram.mem[RESULT >> 4][31:0] == PASS && uart_marker_seen)
                break;
            if (ram.mem[RESULT >> 4][31:16] == 16'hbad0)
                $fatal(1, "SOC firmware failure code %08x; UART=%s",
                       ram.mem[RESULT >> 4][31:0], uart_capture);
        end
        if (cycles == MAX_CYCLES)
            $fatal(1, "SOC timeout result=%08x UART=%s DMA R/W=%0d/%0d",
                   ram.mem[RESULT >> 4][31:0], uart_capture,
                   dma_reads, dma_writes);
        if (dma_reads != 16 || dma_writes != 16)
            $fatal(1, "DMA transfer count mismatch R/W=%0d/%0d",
                   dma_reads, dma_writes);
        if (cpu_dst_reads_after_dma < 64 || cpu_src_writes < 64)
            $fatal(1, "CPU buffer bus evidence below 64 words src writes=%0d dst reads=%0d",
                   cpu_src_writes, cpu_dst_reads_after_dma);
        if (!(&cpu_source_words) || !(&cpu_dest_words))
            $fatal(1, "CPU did not access all 64 distinct buffer words: source=%016x dest=%016x",
                   cpu_source_words, cpu_dest_words);
        if (cpu_ram_reads_during_dma == 0)
            $fatal(1, "CPU and DMA RAM requests did not interleave");
        if (cpu_foreground_reads_during_dma == 0)
            $fatal(1, "No foreground CPU data read while DMA was active");
        if (timer_writes < 3 || timer_reads < 4)
            $fatal(1, "CPU/APB timer traffic missing reads/writes=%0d/%0d",
                   timer_reads, timer_writes);
        if ($test$plusargs("IRQ_MODE")) begin
            if (!timer_irq_seen || !dma_irq_seen || timer_irq || dma_irq ||
                ram.mem[32'h000c_1f10 >> 4][31:0] != 1 ||
                ram.mem[32'h000c_1f10 >> 4][63:32] != 1 ||
                ram.mem[32'h000c_1f10 >> 4][95:64] != 32'h8000_000b)
                $fatal(1, "CPU IRQ handler evidence mismatch timer=%0d DMA=%0d cause=%08x",
                    ram.mem[32'h000c_1f10 >> 4][31:0],
                    ram.mem[32'h000c_1f10 >> 4][63:32],
                    ram.mem[32'h000c_1f10 >> 4][95:64]);
            $display("SOC_IRQ_PASS timer=1 DMA=1 mcause=8000000b IRQs cleared");
        end
        for (int i = 0; i < 64; i++) begin
            logic [31:0] expected;
            logic [31:0] actual_src, actual_dst;
            expected = 32'hc001_0000 ^ (32'(i) * 32'h0102_0305);
            actual_src = ram.mem[(SRC >> 4) + (i >> 2)][(i % 4) * 32 +: 32];
            actual_dst = ram.mem[(DST >> 4) + (i >> 2)][(i % 4) * 32 +: 32];
            if (actual_src !== expected || actual_dst !== expected)
                $fatal(1, "RAM copy mismatch word=%0d expected=%08x src=%08x dst=%08x",
                       i, expected, actual_src, actual_dst);
        end
        if (ram.mem[32'h000c_0100 >> 4][31:0] != 32'ha11c_e001 ||
            ram.mem[32'h000c_0ffc >> 4][127:96] != 32'hbeef_1002 ||
            ram.mem[32'h000c_1100 >> 4][31:0] != 32'hc0de_2003 ||
            ram.mem[32'h000c_1ffc >> 4][127:96] != 32'hd00d_3004)
            $fatal(1, "RAM guard word changed");
        $display("SOC_SYSTEM_PASS cycles=%0d DMA R/W=%0d/%0d RAM R/W=%0d/%0d timer R/W=%0d/%0d CPU source writes=%0d post-DMA dest reads=%0d CPU RAM reads during DMA=%0d UART=%s",
                 cycles, dma_reads, dma_writes, ram_reads, ram_writes,
                 timer_reads, timer_writes,
                 cpu_src_writes, cpu_dst_reads_after_dma,
                 cpu_ram_reads_during_dma, uart_capture);
        $display("SOC_FOREGROUND_PASS uncached CPU reads during DMA=%0d", cpu_foreground_reads_during_dma);
        // Keep the sampled trace through the final UART stop bit so the
        // independent offline decoder can verify the complete last frame.
        repeat (4) @(negedge clk);
        if (trace_fd != 0) $fclose(trace_fd);
        $finish;
    end
endmodule

`default_nettype wire
