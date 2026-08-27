// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns/1ps
`include "friscv_h.sv"
module friscv_memfy_fault_tb;
  reg aclk=0;
  always #5 aclk=~aclk;
  reg aresetn=0, srst=0, memfy_valid=0;
  reg [`INST_BUS_W-1:0] memfy_instbus=0;
  wire memfy_ready, memfy_pending_read, memfy_pending_write;
  wire [31:0] memfy_regs_sts;
  wire [3:0] memfy_fenceinfo;
  wire [`PROC_EXP_W-1:0] memfy_exceptions;
  wire [4:0] memfy_rs1_addr, memfy_rs2_addr, memfy_rd_addr;
  reg [31:0] memfy_rs1_val=0, memfy_rs2_val=32'h12345678;
  wire memfy_rd_wr;
  wire [31:0] memfy_rd_val;
  wire [3:0] memfy_rd_strb;
  wire [31:0] mpu_addr;
  reg [3:0] mpu_allow=4'hf;
  wire awvalid,wvalid,bready,arvalid,rready;
  reg awready=1,wready=1,bvalid=0,arready=1,rvalid=0;
  wire [31:0] awaddr,araddr,wdata;
  wire [2:0] awprot,arprot;
  wire [3:0] awcache,arcache,wstrb;
  wire [7:0] awid,arid;
  reg [7:0] bid=8'h20,rid=8'h20;
  reg [1:0] bresp=0,rresp=0;
  reg [31:0] rdata=32'h89abcdef;
  friscv_memfy dut(.*);
  integer checks=0;
  task check(input bit condition, input string message);
    if (!condition) $fatal(1,"MEMFY_FAULT_FAIL %s",message);
    checks++;
  endtask
  task issue(input bit store, input [31:0] reqpc, input [31:0] address, input [4:0] rd);
    @(negedge aclk);
    memfy_instbus='0;
    memfy_instbus[`OPCODE+:`OPCODE_W]=store ? `STORE : `LOAD;
    memfy_instbus[`FUNCT3+:`FUNCT3_W]=store ? `SW : `LW;
    memfy_instbus[`RD+:`RD_W]=rd;
    memfy_instbus[`PC+:`PC_W]=reqpc;
    memfy_instbus[`INST+:`INST_W]=store ? 32'h0020a023 : 32'h0000a283;
    memfy_instbus[`PRIV+:`PRIV_W]=`MMODE;
    memfy_rs1_val=address;
    memfy_valid=1;
    while(!memfy_ready) @(negedge aclk);
    @(posedge aclk);
    @(negedge aclk);
    memfy_valid=0;
    memfy_instbus='0;
    memfy_rs1_val=32'hdead0000;
    repeat(2) @(negedge aclk);
  endtask
  task read_response(input [1:0] response, input [31:0] reqpc, input [31:0] address, input [4:0] rd);
    @(negedge aclk);
    rresp=response; rvalid=1;
    #1;
    if(response[1]) begin
      check(memfy_exceptions[`LAF]===1'b1,"error response raises LOAD access fault");
      check(memfy_rd_wr===1'b0,"failed LOAD must not write rd");
      check(memfy_exceptions[`EXP_PC+:`EXP_PC_W]===reqpc,"fault PC belongs to original request");
      check(memfy_exceptions[`EXP_ADDR+:`EXP_ADDR_W]===address,"fault address belongs to original request");
      check(memfy_exceptions[`EXP_INST+:`EXP_INST_W]===32'h0000a283,"original LOAD instruction retained");
    end else begin
      check(memfy_exceptions[`LAF]===1'b0,"successful LOAD has no access fault");
      check(memfy_rd_wr===1'b1 && memfy_rd_addr===rd && memfy_rd_val===rdata,"successful LOAD writes expected rd/data");
    end
    @(posedge aclk); @(negedge aclk); rvalid=0;
    #1;
    check(memfy_regs_sts[rd]===1'b1,"rd reservation released even for failed LOAD");
  endtask
  task write_response(input [1:0] response, input [31:0] reqpc, input [31:0] address);
    @(negedge aclk); bresp=response; bvalid=1; #1;
    check(memfy_exceptions[`SAF]===response[1],"STORE response maps to access fault");
    if(response[1]) begin
      check(memfy_exceptions[`EXP_PC+:`EXP_PC_W]===reqpc,"STORE fault original PC");
      check(memfy_exceptions[`EXP_ADDR+:`EXP_ADDR_W]===address,"STORE fault original address");
    end
    @(posedge aclk); @(negedge aclk); bvalid=0;
  endtask
  initial begin
    repeat(3) @(negedge aclk); aresetn=1;
    repeat(2) @(negedge aclk);
    issue(0,32'h104,32'h200,5);
    read_response(2,32'h104,32'h200,5);
    check(!memfy_pending_read,"faulted LOAD releases pending counter");
    issue(0,32'h108,32'h204,6);
    read_response(3,32'h108,32'h204,6);
    issue(0,32'h10c,32'h208,7);
    issue(0,32'h110,32'h20c,8);
    read_response(0,32'h10c,32'h208,7);
    read_response(2,32'h110,32'h20c,8);
    check(!memfy_pending_read,"queued LOADs retire all slots");
    issue(1,32'h114,32'h210,0);
    write_response(2,32'h114,32'h210);
    check(!memfy_pending_write,"faulted STORE releases pending counter");
    issue(1,32'h118,32'h214,0);
    issue(1,32'h11c,32'h218,0);
    write_response(0,32'h118,32'h214);
    write_response(3,32'h11c,32'h218);
    check(!memfy_pending_write,"queued STOREs retire all slots");
    // MPU-denied access must not allocate an orphan response metadata slot.
    @(negedge aclk); mpu_allow=0;
    issue(0,32'h120,32'h21c,9);
    @(negedge aclk); mpu_allow=4'hf;
    issue(0,32'h124,32'h220,10);
    read_response(2,32'h124,32'h220,10);
    check(!memfy_pending_read,"denied LOAD did not leave an outstanding slot");
    $display("MEMFY_FAULT_PASS checks=%0d",checks);
    $finish;
  end
  initial begin #20000; $fatal(1,"MEMFY_FAULT_TIMEOUT"); end
endmodule
