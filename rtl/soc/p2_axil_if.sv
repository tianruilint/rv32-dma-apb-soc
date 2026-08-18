// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// P2-owned AXI4-Lite-style interface. IDs are carried for the FRISCV core.
interface p2_axil_if #(
    parameter int ADDR_W = 32,
    parameter int DATA_W = 128,
    parameter int ID_W = 8
);
    logic awvalid, awready;
    logic [ADDR_W-1:0] awaddr;
    logic [2:0] awprot;
    logic [ID_W-1:0] awid;
    logic wvalid, wready;
    logic [DATA_W-1:0] wdata;
    logic [DATA_W/8-1:0] wstrb;
    logic bvalid, bready;
    logic [1:0] bresp;
    logic [ID_W-1:0] bid;
    logic arvalid, arready;
    logic [ADDR_W-1:0] araddr;
    logic [2:0] arprot;
    logic [ID_W-1:0] arid;
    logic rvalid, rready;
    logic [DATA_W-1:0] rdata;
    logic [1:0] rresp;
    logic [ID_W-1:0] rid;

    modport master (
        output awvalid, awaddr, awprot, awid, wvalid, wdata, wstrb,
               bready, arvalid, araddr, arprot, arid, rready,
        input  awready, wready, bvalid, bresp, bid, arready,
               rvalid, rdata, rresp, rid
    );

    modport slave (
        input  awvalid, awaddr, awprot, awid, wvalid, wdata, wstrb,
               bready, arvalid, araddr, arprot, arid, rready,
        output awready, wready, bvalid, bresp, bid, arready,
               rvalid, rdata, rresp, rid
    );
endinterface

`default_nettype wire
