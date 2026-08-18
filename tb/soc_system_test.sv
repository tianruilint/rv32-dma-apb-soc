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
    int cpu_ram_reads_during_dma = 0;
    int timer_reads = 0;
    int timer_writes = 0;
    string uart_capture = "";
    bit uart_marker_seen = 0;

    always @(posedge clk) begin
        if (!rst) begin
            if (ram_bus.arvalid && ram_bus.arready) begin
                if (ram_bus.arid == 8'h20) dma_reads <= dma_reads + 1;
                if (ram_bus.arid != 8'h20 && dma_reads > 0 && dma_writes < 16)
                    cpu_ram_reads_during_dma <= cpu_ram_reads_during_dma + 1;
                if (ram_bus.arid != 8'h20 &&
                    ram_bus.araddr >= DST && ram_bus.araddr < DST + 256 &&
                    dma_writes == 16)
                    cpu_dst_reads_after_dma <= cpu_dst_reads_after_dma + 1;
            end
            if (ram_bus.awvalid && ram_bus.awready) begin
                if (ram_bus.awid == 8'h20) dma_writes <= dma_writes + 1;
                if (ram_bus.awid != 8'h20 &&
                    ram_bus.awaddr >= SRC && ram_bus.awaddr < SRC + 256)
                    cpu_src_writes <= cpu_src_writes + 1;
            end
            if (dut.target[3].awvalid && dut.target[3].awready)
                timer_writes <= timer_writes + 1;
            if (dut.target[3].arvalid && dut.target[3].arready)
                timer_reads <= timer_reads + 1;
        end
    end

    // Pinned FRISCV UART uses CLKDIV=4, giving 50 ns per serial bit at the
    // 10 ns SoC clock. Decode the actual output pin, including the stop bit.
    always @(negedge uart_tx) begin : decode_uart
        logic [7:0] ch;
        if (!rst) begin
            #25;
            if (uart_tx !== 1'b0) $fatal(1, "UART start bit invalid");
            for (int bit_idx = 0; bit_idx < 8; bit_idx++) begin
                #50;
                ch[bit_idx] = uart_tx;
            end
            #50;
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
            if (ram.mem[RESULT >> 4][31:0] == PASS && uart_marker_seen)
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
        if (cpu_ram_reads_during_dma == 0)
            $fatal(1, "CPU and DMA RAM requests did not interleave");
        if (timer_writes < 3 || timer_reads < 4)
            $fatal(1, "CPU/APB timer traffic missing reads/writes=%0d/%0d",
                   timer_reads, timer_writes);
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
        $finish;
    end
endmodule

`default_nettype wire
