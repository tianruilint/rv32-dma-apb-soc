// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns/1ps
module core_data_fault_tb;
    parameter integer PIPELINE = 0;
    bit clk=0;
    always #5 clk=!clk;
    logic rst_n=0;
    logic iarvalid,iarready,irvalid=0,irready;
    logic [31:0] iaraddr;
    logic [7:0] iarid,irid=0;
    logic [127:0] irdata=0;
    logic darvalid,darready,drvalid=0,drready;
    logic [31:0] daraddr;
    logic [7:0] darid,drid=0;
    logic [1:0] drresp=0;
    logic [127:0] drdata=0;
    logic dawvalid,dawready,dwvalid,dwready,dbvalid=0,dbready;
    logic [31:0] dawaddr;
    logic [7:0] dawid,dbid=0;
    logic [127:0] dwdata;
    logic [15:0] dwstrb;
    logic [1:0] fault_resp=2;
    bit store_case=0;
    bit cache_hit_case=0;
    integer younger_kind=0;
    logic [31:0] younger_instruction;
    always_comb begin
        case(younger_kind)
            1: younger_instruction=32'h0040036f; // JAL x6,+4
            2: younger_instruction=32'h00100073; // EBREAK
            3: younger_instruction=32'h0000100f; // FENCE.I
            4: younger_instruction=32'h00000073; // ECALL
            default: younger_instruction=32'h06600313; // ADDI x6,0,0x66
        endcase
    end
    bit aw_seen=0,w_seen=0;
    integer read_delay=0,write_delay=0,error_responses=0;
    assign iarready=!irvalid;
    assign darready=!drvalid && read_delay==0;
    assign dawready=!aw_seen && !dbvalid;
    assign dwready=!w_seen && !dbvalid;
    friscv_rv32i_core #(.AXI_IMEM_W(128),.AXI_DMEM_W(128),
        .CACHE_EN(1),.ICACHE_DEPTH(16),.DCACHE_DEPTH(16),.M_EXTENSION(1),
        .PROCESSING_BUS_PIPELINE(PIPELINE)) dut(
        .aclk(clk),.aresetn(rst_n),.srst(1'b0),
        .ext_irq(1'b0),.sw_irq(1'b0),.timer_irq(1'b0),.status(),.dbg_regs(),
        .imem_arvalid(iarvalid),.imem_arready(iarready),.imem_araddr(iaraddr),.imem_arprot(),.imem_arid(iarid),
        .imem_rvalid(irvalid),.imem_rready(irready),.imem_rid(irid),.imem_rresp(2'b0),.imem_rdata(irdata),
        .dmem_awvalid(dawvalid),.dmem_awready(dawready),.dmem_awaddr(dawaddr),.dmem_awprot(),.dmem_awid(dawid),
        .dmem_wvalid(dwvalid),.dmem_wready(dwready),.dmem_wdata(dwdata),.dmem_wstrb(dwstrb),
        .dmem_bvalid(dbvalid),.dmem_bready(dbready),.dmem_bid(dbid),.dmem_bresp(fault_resp),
        .dmem_arvalid(darvalid),.dmem_arready(darready),.dmem_araddr(daraddr),.dmem_arprot(),.dmem_arid(darid),
        .dmem_rvalid(drvalid),.dmem_rready(drready),.dmem_rid(drid),.dmem_rresp(drresp),.dmem_rdata(drdata)
    );
    always @(posedge clk) begin
        if(!rst_n) begin
            irvalid<=0;irdata<=0;irid<=0;drvalid<=0;drid<=0;drresp<=0;drdata<=0;
            dbvalid<=0;dbid<=0;aw_seen<=0;w_seen<=0;
            read_delay<=0;write_delay<=0;error_responses<=0;
        end else begin
            if(irvalid&&irready) irvalid<=0;
            if(iarvalid&&iarready) begin
                irvalid<=1;irid<=iarid;
                case(iaraddr[31:4])
                    0: irdata<=128'h05500193_00100137_30509073_10000093;
                    1: irdata<=cache_hit_case ?
                               {32'h00128393,younger_instruction,32'h02312023,32'h02012503} :
                               {32'h0000006f,32'h00128393,younger_instruction,
                                store_case ? 32'h02312023 : 32'h02012283};
                    // Handler retries the same address after the injected fault
                    // is cleared, then raises x12 as a completion marker.
                    16: irdata<=128'h00000013_0000006f_00100613_02012583;
                    default: irdata<={4{32'h00000013}};
                endcase
            end
            if(darvalid&&darready) begin
                if(daraddr!==32'h00100020) $fatal(1,"UNEXPECTED_DATA_READ %h",daraddr);
                drid<=darid;read_delay<=8;
                drresp<=(!store_case && error_responses==0) ? fault_resp : 2'b00;
                drdata<=(!store_case && error_responses==0) ? {4{32'hdeadbeef}} : {4{32'h12345678}};
            end
            if(read_delay>0) begin
                read_delay<=read_delay-1;
                if(read_delay==1) drvalid<=1;
            end
            if(drvalid&&drready) begin
                drvalid<=0;
                if(drresp[1]) error_responses<=error_responses+1;
            end
            if(dawvalid&&dawready) begin
                if(dawaddr!==32'h00100020) $fatal(1,"UNEXPECTED_DATA_WRITE %h",dawaddr);
                aw_seen<=1;dbid<=dawid;
            end
            if(dwvalid&&dwready) w_seen<=1;
            if(aw_seen&&w_seen&&!dbvalid&&write_delay==0) write_delay<=8;
            if(write_delay>0) begin
                write_delay<=write_delay-1;
                if(write_delay==1) dbvalid<=1;
            end
            if(dbvalid&&dbready) begin
                dbvalid<=0;aw_seen<=0;w_seen<=0;error_responses<=error_responses+1;
            end
        end
    end
    initial begin
        for(integer scenario=0;scenario<30;scenario++) begin
            @(negedge clk);rst_n=0;store_case=(scenario%6)>=2;cache_hit_case=(scenario%6)>=4;
            younger_kind=scenario/6;
            fault_resp=scenario[0]?2'b11:2'b10;
            repeat(4) @(negedge clk);rst_n=1;
            begin : wait_trap
                for(integer cyc=0;cyc<4000;cyc++) begin
                    @(negedge clk);
                    if(dut.csrs.mcause==(store_case?32'd7:32'd5) && dut.isa_registers.regs[12]===32'd1) begin
                        if(dut.csrs.mepc!==(cache_hit_case?32'h14:32'h10) || dut.csrs.mtval!==32'h00100020)
                            $fatal(1,"DATA_FAULT_ADDRESS_FAIL mepc=%h mtval=%h",dut.csrs.mepc,dut.csrs.mtval);
                        repeat(8) @(negedge clk);
                        if(dut.isa_registers.regs[5]!==0 || dut.isa_registers.regs[6]!==0 || dut.isa_registers.regs[7]!==0)
                            $fatal(1,"DATA_FAULT_YOUNGER_RETIRED x5=%h x6=%h x7=%h",dut.isa_registers.regs[5],dut.isa_registers.regs[6],dut.isa_registers.regs[7]);
                        if(error_responses!=1) $fatal(1,"DATA_ERROR_RESPONSE_COUNT %0d",error_responses);
                        if(dut.isa_registers.regs[11]!==32'h12345678)
                            $fatal(1,"DATA_FAULT_CACHE_POLLUTED retry=%h",dut.isa_registers.regs[11]);
                        if(cache_hit_case && dut.isa_registers.regs[10]!==32'h12345678)
                            $fatal(1,"DATA_FAULT_PREFILL_FAILED value=%h",dut.isa_registers.regs[10]);
                        $display("DATA_FAULT_CASE_PASS store=%0d cache_hit=%0d younger_kind=%0d resp=%h mcause=%h mepc=%h mtval=%h retry=%h younger_regs=0",store_case,cache_hit_case,younger_kind,fault_resp,dut.csrs.mcause,dut.csrs.mepc,dut.csrs.mtval,dut.isa_registers.regs[11]);
                        disable wait_trap;
                    end
                end
                $fatal(1,"DATA_FAULT_NOT_TRAPPED store=%0d resp=%h mcause=%h x5=%h x6=%h",store_case,fault_resp,dut.csrs.mcause,dut.isa_registers.regs[5],dut.isa_registers.regs[6]);
            end
        end
        $display("CORE_DATA_FAULT_PASS cases=30 pipeline=%0d cache_enabled SLVERR_DECERR exact_mepc_mtval younger_ALU_JAL_EBREAK_FENCEI_ECALL retry_cache_clean",PIPELINE);
        $finish;
    end
endmodule
