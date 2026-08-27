// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns/1ps
module core_fetch_fault_tb #(parameter bit CACHE_MODE = 1);
    localparam BUS_W = CACHE_MODE ? 128 : 32;
    bit clk = 0;
    always #5 clk = !clk;
    logic rst_n = 0;
    logic arvalid, arready, rvalid = 0, rready;
    logic [31:0] araddr;
    logic [2:0] arprot;
    logic [7:0] arid, rid = 0;
    logic [BUS_W-1:0] rdata = 0;
    logic [1:0] rresp = 0;
    logic [1:0] fault_resp = 2;
    logic fault_enabled = 1;
    logic [1023:0] debug_regs;
    logic [7:0] status;
    int error_responses = 0;
    assign arready = !rvalid;
    friscv_rv32i_core #(.AXI_IMEM_W(BUS_W), .AXI_DMEM_W(BUS_W),
        .CACHE_EN(CACHE_MODE), .ICACHE_DEPTH(16), .DCACHE_DEPTH(16), .M_EXTENSION(1)) dut (
        .aclk(clk), .aresetn(rst_n), .srst(1'b0),
        .ext_irq(1'b0), .sw_irq(1'b0), .timer_irq(1'b0),
        .status(status), .dbg_regs(debug_regs),
        .imem_arvalid(arvalid), .imem_arready(arready), .imem_araddr(araddr), .imem_arprot(arprot), .imem_arid(arid),
        .imem_rvalid(rvalid), .imem_rready(rready), .imem_rid(rid), .imem_rresp(rresp), .imem_rdata(rdata),
        .dmem_awvalid(), .dmem_awready(1'b1), .dmem_awaddr(), .dmem_awprot(), .dmem_awid(),
        .dmem_wvalid(), .dmem_wready(1'b1), .dmem_wdata(), .dmem_wstrb(),
        .dmem_bvalid(1'b0), .dmem_bready(), .dmem_bid(8'b0), .dmem_bresp(2'b0),
        .dmem_arvalid(), .dmem_arready(1'b1), .dmem_araddr(), .dmem_arprot(), .dmem_arid(),
        .dmem_rvalid(1'b0), .dmem_rready(), .dmem_rid(8'b0), .dmem_rresp(2'b0), .dmem_rdata(BUS_W'(0))
    );
    always @(posedge clk) begin
        if (!rst_n) begin
            rvalid <= 0; rresp <= 0; rdata <= 0; rid <= 0; error_responses <= 0;
        end else begin
            if (rvalid && rready) rvalid <= 0;
            if (arvalid && arready) begin
                rvalid <= 1; rid <= arid; rresp <= 0;
                case (araddr[31:4])
                    // addi x1,0,0x100; csrw mtvec,x1; addi x2,0,0; jalr 0,x2,0x200
                    28'h0000000: rdata <= BUS_W'(128'h20010067_00000113_30509073_10000093 >> (CACHE_MODE ? 0 : int'(araddr[3:2])*32));
                    // Returning retries the faulting PC after the test removes the error.
                    28'h0000010: rdata <= BUS_W'({4{32'h30200073}});
                    // If an error response is ignored, this instruction corrupts x5.
                    28'h0000020: begin
                        rdata <= BUS_W'({4{32'h00100293}});
                        rresp <= fault_enabled ? fault_resp : 2'b00;
                        if (fault_enabled) error_responses <= error_responses + 1;
                    end
                    default: rdata <= BUS_W'({4{32'h00000013}});
                endcase
            end
        end
    end
    initial begin
        for (int scenario=0; scenario<2; scenario++) begin
            @(negedge clk); rst_n = 0; fault_enabled = 1; fault_resp = scenario==0 ? 2'b10 : 2'b11;
            repeat (4) @(negedge clk);
            rst_n = 1;
            begin : wait_trap
                for (int cyc=0; cyc<4000; cyc++) begin
                    @(negedge clk);
                    if (dut.csrs.mcause == 32'd1) begin
                        if (dut.csrs.mepc !== 32'h200 || dut.csrs.mtval !== 32'h200)
                            $fatal(1,"FETCH_TRAP_ADDRESS_FAIL mepc=%h mtval=%h",dut.csrs.mepc,dut.csrs.mtval);
                        if (dut.isa_registers.regs[5] !== 0)
                            $fatal(1,"FETCH_ERROR_RETIRED x5=%h",dut.isa_registers.regs[5]);
                        if (error_responses == 0) $fatal(1,"NO_ERROR_INJECTED");
                        $display("FETCH_FAULT_CASE_PASS resp=%h mcause=%h mepc=%h mtval=%h x5=%h",fault_resp,dut.csrs.mcause,dut.csrs.mepc,dut.csrs.mtval,dut.isa_registers.regs[5]);
                        fault_enabled = 0;
                        disable wait_trap;
                    end
                end
                $fatal(1,"FETCH_FAULT_NOT_TRAPPED resp=%h mcause=%h x5=%h",fault_resp,dut.csrs.mcause,dut.isa_registers.regs[5]);
            end
            begin : wait_recovery
                for (int cyc=0; cyc<1000; cyc++) begin
                    @(negedge clk);
                    if (dut.isa_registers.regs[5] == 1) begin
                        $display("FETCH_FAULT_RECOVERY_PASS cache=%0d resp=%h mret_refetched_valid_instruction",CACHE_MODE,fault_resp);
                        disable wait_recovery;
                    end
                end
                $fatal(1,"FETCH_FAULT_RECOVERY_FAILED cache=%0d resp=%h",CACHE_MODE,fault_resp);
            end
        end
        $display("CORE_FETCH_FAULT_PASS cache=%0d SLVERR_DECERR precise_mepc_mtval no_bad_retirement", CACHE_MODE);
        $finish;
    end
endmodule
