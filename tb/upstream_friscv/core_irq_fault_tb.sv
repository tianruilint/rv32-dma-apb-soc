// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns/1ps

// Execute real CSR setup, a faulting memory instruction, a synchronous handler,
// MRET, the deferred external interrupt handler, and the resumed main program.
// The instruction words are fixed RV32IM/Zicsr assembly, not forced CPU state.
module core_irq_fault_tb;
    parameter integer PIPELINE = 0;
    parameter integer FIRST_SCENARIO = 0;
    parameter integer SCENARIOS = 24;
    bit clk = 0;
    always #5 clk = !clk;
    logic rst_n = 0, ext_irq = 0;
    logic iarvalid, iarready, irvalid = 0, irready;
    logic [31:0] iaraddr;
    logic [7:0] iarid, irid = 0;
    logic [127:0] irdata = 0;
    logic darvalid, darready, drvalid = 0, drready;
    logic [31:0] daraddr;
    logic [7:0] darid, drid = 0;
    logic [1:0] drresp = 0;
    logic [127:0] drdata = 0;
    logic dawvalid, dawready, dwvalid, dwready, dbvalid = 0, dbready;
    logic [31:0] dawaddr;
    logic [7:0] dawid, dbid = 0;
    logic [127:0] dwdata;
    logic [15:0] dwstrb;
    logic [1:0] fault_resp = 2;
    bit store_case = 0, vector_case = 0, aw_seen = 0, w_seen = 0;
    integer read_delay = 0, write_delay = 0, irq_advance = 0;

    assign iarready = !irvalid;
    assign darready = !drvalid && read_delay == 0;
    assign dawready = !aw_seen && !dbvalid;
    assign dwready = !w_seen && !dbvalid;

    friscv_rv32i_core #(
        .AXI_IMEM_W(128), .AXI_DMEM_W(128), .CACHE_EN(1),
        .ICACHE_DEPTH(16), .DCACHE_DEPTH(16), .M_EXTENSION(1),
        .IO_MAP_NB(1), .IO_MAP(64'hffffffff_ffffffff),
        .PROCESSING_BUS_PIPELINE(PIPELINE)
    ) dut (
        .aclk(clk), .aresetn(rst_n), .srst(1'b0),
        .ext_irq(ext_irq), .sw_irq(1'b0), .timer_irq(1'b0), .status(), .dbg_regs(),
        .imem_arvalid(iarvalid), .imem_arready(iarready), .imem_araddr(iaraddr),
        .imem_arprot(), .imem_arid(iarid), .imem_rvalid(irvalid),
        .imem_rready(irready), .imem_rid(irid), .imem_rresp(2'b0), .imem_rdata(irdata),
        .dmem_awvalid(dawvalid), .dmem_awready(dawready), .dmem_awaddr(dawaddr),
        .dmem_awprot(), .dmem_awid(dawid), .dmem_wvalid(dwvalid),
        .dmem_wready(dwready), .dmem_wdata(dwdata), .dmem_wstrb(dwstrb),
        .dmem_bvalid(dbvalid), .dmem_bready(dbready), .dmem_bid(dbid), .dmem_bresp(fault_resp),
        .dmem_arvalid(darvalid), .dmem_arready(darready), .dmem_araddr(daraddr),
        .dmem_arprot(), .dmem_arid(darid), .dmem_rvalid(drvalid),
        .dmem_rready(drready), .dmem_rid(drid), .dmem_rresp(drresp), .dmem_rdata(drdata)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            irvalid <= 0; irdata <= 0; irid <= 0;
            drvalid <= 0; drid <= 0; drresp <= 0; drdata <= 0;
            dbvalid <= 0; dbid <= 0; aw_seen <= 0; w_seen <= 0;
            read_delay <= 0; write_delay <= 0; ext_irq <= 0;
        end else begin
            if (irvalid && irready) irvalid <= 0;
            if (iarvalid && iarready) begin
                irvalid <= 1;
                irid <= iarid;
                case (iaraddr[31:4])
                    // mtvec=0x100/0x101; x2=0x00100000; x3=0x55.
                    0: irdata <= {32'h05500193, 32'h00100137, 32'h30509073,
                                  vector_case ? 32'h10100093 : 32'h10000093};
                    // mie.MEIE=1, mstatus.MIE=1 before the memory instruction.
                    1: irdata <= 128'h30046073_30421073_80020213_00001237;
                    // Fault at PC 0x20. The resumed main program sets x11=0x77.
                    2: irdata <= {32'h0000006f, 32'h07700593, 32'h06600313,
                                  store_case ? 32'h02312023 : 32'h02012283};
                    // Direct trap entry: read mcause, route IRQ/synchronous fault.
                    16: irdata <= 128'h00000013_0380006f_06044e63_34202473;
                    // Vectored MEI entry at 0x100+4*11=0x12c jumps to IRQ handler.
                    18: irdata <= 128'h0540006f_00000013_00000013_00000013;
                    // Synchronous handler: x9++, mepc+=4, MRET.
                    20: irdata <= 128'h34139073_00438393_341023f3_00148493;
                    21: irdata <= 128'h00000013_00000013_00000013_30200073;
                    // IRQ handler: x10++, MRET to main program.
                    24: irdata <= 128'h00000013_00000013_30200073_00150513;
                    default: irdata <= {4{32'h00000013}};
                endcase
            end
            if (darvalid && darready) begin
                if (daraddr !== 32'h00100020) $fatal(1, "IRQ_FAULT_UNEXPECTED_READ");
                drid <= darid;
                read_delay <= 8;
                drresp <= fault_resp;
                drdata <= {4{32'hdeadbeef}};
            end
            if (read_delay > 0) begin
                read_delay <= read_delay - 1;
                if (read_delay == irq_advance + 1) ext_irq <= 1;
                if (read_delay == 1) drvalid <= 1;
            end
            if (drvalid && drready) drvalid <= 0;
            if (dawvalid && dawready) begin
                if (dawaddr !== 32'h00100020) $fatal(1, "IRQ_FAULT_UNEXPECTED_WRITE");
                aw_seen <= 1;
                dbid <= dawid;
            end
            if (dwvalid && dwready) w_seen <= 1;
            if (aw_seen && w_seen && !dbvalid && write_delay == 0) write_delay <= 8;
            if (write_delay > 0) begin
                write_delay <= write_delay - 1;
                if (write_delay == irq_advance + 1) ext_irq <= 1;
                if (write_delay == 1) dbvalid <= 1;
            end
            if (dbvalid && dbready) begin
                dbvalid <= 0;
                aw_seen <= 0;
                w_seen <= 0;
            end
            // Model the external source acknowledging its serviced interrupt.
            if (dut.csrs.mcause == 32'h8000000b && dut.csrs.mstatus[3] == 0)
                ext_irq <= 0;
        end
    end

    initial begin
        integer start_scenario;
        start_scenario = FIRST_SCENARIO;
        if ($value$plusargs("scenario=%d", start_scenario)) begin
            if (SCENARIOS != 1 || start_scenario < 0 || start_scenario >= 24)
                $fatal(1, "IRQ_FAULT_INVALID_SINGLE_SCENARIO");
        end
        for (integer scenario = start_scenario; scenario < start_scenario + SCENARIOS; scenario++) begin
            @(negedge clk);
            rst_n = 0;
            store_case = ((scenario / 3) % 4) >= 2;
            vector_case = scenario >= 12;
            fault_resp = ((scenario / 3) % 2) != 0 ? 2'b11 : 2'b10;
            irq_advance = (scenario % 3) * 3;
            repeat (4) @(negedge clk);
            rst_n = 1;
            begin : wait_recovery
                bit first_trap, irq_trap, sync_mret, pending_seen;
                bit sync_redirect, irq_redirect, previous_mie;
                first_trap = 0;
                irq_trap = 0;
                sync_mret = 0;
                pending_seen = 0;
                sync_redirect = 0;
                irq_redirect = 0;
                previous_mie = 1;
                for (integer cyc = 0; cyc < 2000; cyc++) begin
                    @(negedge clk);
                    // The external cache-fill address is 16-byte aligned. Check
                    // the retired redirect PC itself to distinguish 0x100/0x12c.
                    if (dut.control.mcause_wr && dut.control.mcause == (store_case ? 32'd7 : 32'd5)) begin
                        if (dut.control.pc_reg !== 32'h100) $fatal(1, "IRQ_FAULT_SYNC_VECTOR_WRONG");
                        sync_redirect = 1;
                    end
                    if (dut.control.mcause_wr && dut.control.mcause == 32'h8000000b) begin
                        if (dut.control.pc_reg !== (vector_case ? 32'h12c : 32'h100))
                            $fatal(1, "IRQ_FAULT_INTERRUPT_VECTOR_WRONG");
                        irq_redirect = 1;
                    end
                    if (dut.csrs.mip[11] === 1) pending_seen = 1;
                    if (!first_trap && dut.csrs.mcause != 0 && dut.csrs.mstatus[3] == 0) begin
                        if (!sync_redirect || dut.csrs.mcause !== (store_case ? 32'd7 : 32'd5) ||
                            dut.csrs.mepc !== 32'h20 || dut.csrs.mtval !== 32'h00100020)
                            $fatal(1, "IRQ_OVERRIDES_OLDER_FAULT pipeline=%0d store=%0d vector=%0d irq_advance=%0d resp=%h cause=%h mepc=%h mtval=%h",
                                   PIPELINE, store_case, vector_case, irq_advance, fault_resp,
                                   dut.csrs.mcause, dut.csrs.mepc, dut.csrs.mtval);
                        if (dut.isa_registers.regs[5] !== 0 || dut.isa_registers.regs[6] !== 0)
                            $fatal(1, "IRQ_FAULT_YOUNGER_RETIRED");
                        first_trap = 1;
                        $display("IRQ_FAULT_FIRST_SYNC_PASS pipeline=%0d store=%0d vector=%0d irq_advance=%0d mepc=%h mtval=%h",
                                 PIPELINE, store_case, vector_case, irq_advance, dut.csrs.mepc, dut.csrs.mtval);
                    end
                    if (first_trap && !previous_mie && dut.csrs.mstatus[3]) sync_mret = 1;
                    if (first_trap && pending_seen && !sync_mret && dut.csrs.mip[11] !== 1)
                        $fatal(1, "IRQ_FAULT_PENDING_LOST pipeline=%0d store=%0d vector=%0d irq_advance=%0d cause=%h",
                               PIPELINE, store_case, vector_case, irq_advance, dut.csrs.mcause);
                    if (first_trap && dut.csrs.mcause == 32'h8000000b && dut.csrs.mstatus[3] == 0) begin
                        if (!sync_mret || !pending_seen || !irq_redirect || dut.isa_registers.regs[9] !== 1 ||
                            dut.csrs.mtval !== 0 || dut.csrs.mepc < 32'h24 || dut.csrs.mepc > 32'h2c)
                            $fatal(1, "IRQ_FAULT_INTERRUPT_BEFORE_SYNC_MRET mepc=%h sync_count=%h", dut.csrs.mepc, dut.isa_registers.regs[9]);
                        irq_trap = 1;
                    end
                    previous_mie = dut.csrs.mstatus[3];
                    if (irq_trap && dut.isa_registers.regs[11] == 32'h77 &&
                        dut.isa_registers.regs[10] == 1 && dut.csrs.mstatus[3]) begin
                        repeat (20) @(negedge clk);
                        if (dut.isa_registers.regs[5] !== 0 || dut.isa_registers.regs[6] !== 32'h66 ||
                            dut.isa_registers.regs[9] !== 1 || dut.isa_registers.regs[10] !== 1 ||
                            dut.csrs.mip[11] !== 0 || ext_irq !== 0)
                            $fatal(1, "IRQ_FAULT_RECOVERY_FAILED");
                        $display("IRQ_FAULT_CASE_PASS pipeline=%0d store=%0d vector=%0d irq_advance=%0d resp=%h first_mepc=00000020 first_mtval=00100020 sync_isr=1 irq_isr=1 mret_resume=1",
                                 PIPELINE, store_case, vector_case, irq_advance, fault_resp);
                        disable wait_recovery;
                    end
                end
                $fatal(1, "IRQ_FAULT_TIMEOUT pipeline=%0d store=%0d vector=%0d irq_advance=%0d cause=%h sync_count=%h irq_count=%h",
                       PIPELINE, store_case, vector_case, irq_advance, dut.csrs.mcause,
                       dut.isa_registers.regs[9], dut.isa_registers.regs[10]);
            end
        end
        $display("CORE_IRQ_FAULT_PASS cases=%0d pipeline=%0d synchronous_first irq_retained MRET_interrupt_resume", SCENARIOS, PIPELINE);
        $finish;
    end
endmodule
