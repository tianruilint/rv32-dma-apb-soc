// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns/1ps
`include "friscv_h.sv"
module masked_irq_priority_tb;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0;
    wire arvalid,rready;
    wire [31:0] araddr;
    wire [7:0] arid;
    reg rvalid=0;
    reg [7:0] rid=0;
    reg [`CSR_SB_W-1:0] csr_sb='0;
    wire [`CTRL_SB_W-1:0] ctrl_sb;
    friscv_control #(.OSTDREQ_NUM(0),.BOOT_ADDR(32'h200)) dut (
        .aclk(clk), .aresetn(rst_n), .srst(1'b0), .cache_ready(1'b1),
        .status(), .pc_val(), .flush_reqs(), .flush_blocks(), .flush_ack(1'b1),
        .arvalid(arvalid), .arready(1'b1), .araddr(araddr), .arprot(), .arid(arid),
        .rvalid(rvalid), .rready(rready), .rid(rid), .rresp(2'b10), .rdata(32'h00000013),
        .proc_valid(), .proc_ready(1'b1), .proc_instbus(), .proc_fenceinfo(4'b0),
        .proc_exceptions({`PROC_EXP_W{1'b0}}), .proc_busy(1'b0),
        .csr_en(), .csr_ready(1'b1), .csr_instbus(),
        .ctrl_rs1_addr(), .ctrl_rs1_val(32'b0), .ctrl_rs2_addr(), .ctrl_rs2_val(32'b0),
        .ctrl_rd_wr(), .ctrl_rd_addr(), .ctrl_rd_val(),
        .mpu_addr(), .mpu_allow(4'h7), .csr_sb(csr_sb), .ctrl_sb(ctrl_sb)
    );
    always @(posedge clk) begin
        if (!rst_n) begin rvalid<=0;rid<=0; end
        else if (arvalid) begin rvalid<=1;rid<=arid; end
        else if (rready) rvalid<=0;
    end
    initial begin
        // Timer interrupt is locally enabled and pending, but global MIE is off.
        csr_sb[`CSR_SB_MTIE]=1;
        csr_sb[`CSR_SB_MTIP]=1;
        csr_sb[`CSR_SB_MIE]=0;
        csr_sb[`CSR_SB_MTVEC+:32]=32'h100;
        repeat(4) @(negedge clk);
        rst_n=1;
        for(integer cycle=0;cycle<100;cycle++) begin
            @(negedge clk);
            if(dut.mcause_wr) begin
                if(dut.mcause !== 32'h1)
                    $fatal(1,"MASKED_IRQ_PRIORITY_FAIL expected=00000001 got=%h",dut.mcause);
                if(dut.mepc !== 32'h200 || dut.mtval !== 32'h200)
                    $fatal(1,"MASKED_IRQ_ADDRESS_FAIL mepc=%h mtval=%h",dut.mepc,dut.mtval);
                $display("MASKED_IRQ_PRIORITY_PASS MIE=0 MTIP=1 MTIE=1 mcause=1 mepc=mtval=0x200");
                $finish;
            end
        end
        $fatal(1,"MASKED_IRQ_PRIORITY_TIMEOUT");
    end
endmodule
