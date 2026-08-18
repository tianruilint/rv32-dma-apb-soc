// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// P2-owned SoC integration. The FRISCV CPU/IO are attributed third-party IP.
// The external RAM interface allows a simulation model or a future memory IP.
module p2_soc_top (
    input  wire logic        clk,
    input  wire logic        rst,
    input  wire logic        rtc,
    input  wire logic        uart_rx,
    input  wire logic        uart_cts,
    input  wire logic [31:0] gpio_in,
    output      logic        uart_tx,
    output      logic        uart_rts,
    output      logic [31:0] gpio_out,
    output      logic [7:0]  cpu_status,
    output      logic        dma_irq,
    output      logic        timer_irq_out,
    p2_axil_if.master         m_ram
);
    localparam logic [127:0] UNCACHED_MAP =
        128'h000C1FFF_000C0000_001000FF_00100000;

    p2_axil_if #(.ADDR_W(32), .DATA_W(128), .ID_W(8)) initiator[4]();
    p2_axil_if #(.ADDR_W(32), .DATA_W(128), .ID_W(8)) target[4]();

    wire logic io_sw_irq;
    wire logic io_timer_irq;
    wire logic [31:0] apb_paddr;
    wire logic apb_psel, apb_penable, apb_pwrite;
    wire logic [31:0] apb_pwdata, apb_prdata;
    wire logic [3:0] apb_pstrb;
    wire logic apb_pready, apb_pslverr;

    // FRISCV exposes a read-only instruction master. Its unused write inputs
    // are held idle rather than left floating at the interconnect.
    assign initiator[0].awvalid = 1'b0;
    assign initiator[0].awaddr = '0;
    assign initiator[0].awprot = '0;
    assign initiator[0].awid = '0;
    assign initiator[0].wvalid = 1'b0;
    assign initiator[0].wdata = '0;
    assign initiator[0].wstrb = '0;
    assign initiator[0].bready = 1'b1;

    // The fourth upstream crossbar source is reserved and inactive.
    assign initiator[3].awvalid = 1'b0;
    assign initiator[3].awaddr = '0;
    assign initiator[3].awprot = '0;
    assign initiator[3].awid = '0;
    assign initiator[3].wvalid = 1'b0;
    assign initiator[3].wdata = '0;
    assign initiator[3].wstrb = '0;
    assign initiator[3].bready = 1'b1;
    assign initiator[3].arvalid = 1'b0;
    assign initiator[3].araddr = '0;
    assign initiator[3].arprot = '0;
    assign initiator[3].arid = '0;
    assign initiator[3].rready = 1'b1;

    friscv_rv32i_core #(
        .ILEN(32),
        .XLEN(32),
        .BOOT_ADDR(32'h0001_0000),
        .INST_OSTDREQ_NUM(8),
        .DATA_OSTDREQ_NUM(8),
        .M_EXTENSION(1),
        .PROCESSING_BUS_PIPELINE(1),
        .AXI_ADDR_W(32),
        .AXI_ID_W(8),
        .AXI_IMEM_W(128),
        .AXI_DMEM_W(128),
        .AXI_IMEM_MASK(8'h80),
        .AXI_DMEM_MASK(8'h10),
        .CACHE_EN(1),
        .ICACHE_BLOCK_W(128),
        .DCACHE_BLOCK_W(128),
        .IO_MAP_NB(2),
        .IO_MAP(UNCACHED_MAP)
    ) cpu (
        .aclk(clk), .aresetn(~rst), .srst(rst),
        .ext_irq(dma_irq | timer_irq_out),
        .sw_irq(io_sw_irq), .timer_irq(io_timer_irq),
        .status(cpu_status), .dbg_regs(),
        .imem_arvalid(initiator[0].arvalid),
        .imem_arready(initiator[0].arready),
        .imem_araddr(initiator[0].araddr),
        .imem_arprot(initiator[0].arprot),
        .imem_arid(initiator[0].arid),
        .imem_rvalid(initiator[0].rvalid),
        .imem_rready(initiator[0].rready),
        .imem_rid(initiator[0].rid),
        .imem_rresp(initiator[0].rresp),
        .imem_rdata(initiator[0].rdata),
        .dmem_awvalid(initiator[1].awvalid),
        .dmem_awready(initiator[1].awready),
        .dmem_awaddr(initiator[1].awaddr),
        .dmem_awprot(initiator[1].awprot),
        .dmem_awid(initiator[1].awid),
        .dmem_wvalid(initiator[1].wvalid),
        .dmem_wready(initiator[1].wready),
        .dmem_wdata(initiator[1].wdata),
        .dmem_wstrb(initiator[1].wstrb),
        .dmem_bvalid(initiator[1].bvalid),
        .dmem_bready(initiator[1].bready),
        .dmem_bid(initiator[1].bid),
        .dmem_bresp(initiator[1].bresp),
        .dmem_arvalid(initiator[1].arvalid),
        .dmem_arready(initiator[1].arready),
        .dmem_araddr(initiator[1].araddr),
        .dmem_arprot(initiator[1].arprot),
        .dmem_arid(initiator[1].arid),
        .dmem_rvalid(initiator[1].rvalid),
        .dmem_rready(initiator[1].rready),
        .dmem_rid(initiator[1].rid),
        .dmem_rresp(initiator[1].rresp),
        .dmem_rdata(initiator[1].rdata)
    );

    p2_upstream_axil_fabric fabric (
        .clk(clk), .rst(rst), .s_axi(initiator), .m_axi(target)
    );

    p2_dma dma (
        .clk(clk), .rst(rst), .s_ctrl(target[2]),
        .m_mem(initiator[2]), .irq(dma_irq)
    );

    p2_axil_apb_bridge bridge (
        .clk(clk), .rst(rst), .s_axi(target[3]),
        .paddr(apb_paddr), .psel(apb_psel), .penable(apb_penable),
        .pwrite(apb_pwrite), .pwdata(apb_pwdata), .pstrb(apb_pstrb),
        .pready(apb_pready), .prdata(apb_prdata), .pslverr(apb_pslverr)
    );

    p2_apb_timer #(.BASE_ADDR(32'h0010_0080)) timer (
        .clk(clk), .rst(rst),
        .paddr(apb_paddr), .psel(apb_psel), .penable(apb_penable),
        .pwrite(apb_pwrite), .pwdata(apb_pwdata), .pstrb(apb_pstrb),
        .pready(apb_pready), .prdata(apb_prdata), .pslverr(apb_pslverr),
        .irq(timer_irq_out)
    );

    friscv_io_subsystem #(
        .ADDRW(32), .DATAW(128), .IDW(8), .XLEN(32)
    ) upstream_io (
        .aclk(clk), .aresetn(~rst), .srst(rst), .rtc(rtc),
        .slv_awvalid(target[1].awvalid), .slv_awready(target[1].awready),
        .slv_awaddr(target[1].awaddr), .slv_awprot(target[1].awprot),
        .slv_awid(target[1].awid),
        .slv_wvalid(target[1].wvalid), .slv_wready(target[1].wready),
        .slv_wdata(target[1].wdata), .slv_wstrb(target[1].wstrb),
        .slv_bvalid(target[1].bvalid), .slv_bready(target[1].bready),
        .slv_bresp(target[1].bresp), .slv_bid(target[1].bid),
        .slv_arvalid(target[1].arvalid), .slv_arready(target[1].arready),
        .slv_araddr(target[1].araddr), .slv_arprot(target[1].arprot),
        .slv_arid(target[1].arid),
        .slv_rvalid(target[1].rvalid), .slv_rready(target[1].rready),
        .slv_rresp(target[1].rresp), .slv_rdata(target[1].rdata),
        .slv_rid(target[1].rid),
        .gpio_in(gpio_in), .gpio_out(gpio_out),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .uart_rts(uart_rts), .uart_cts(uart_cts),
        .sw_irq(io_sw_irq), .timer_irq(io_timer_irq)
    );

    // External RAM target, retaining the full absolute address.
    assign m_ram.awvalid = target[0].awvalid;
    assign m_ram.awaddr  = target[0].awaddr;
    assign m_ram.awprot  = target[0].awprot;
    assign m_ram.awid    = target[0].awid;
    assign target[0].awready = m_ram.awready;
    assign m_ram.wvalid  = target[0].wvalid;
    assign m_ram.wdata   = target[0].wdata;
    assign m_ram.wstrb   = target[0].wstrb;
    assign target[0].wready = m_ram.wready;
    assign target[0].bvalid = m_ram.bvalid;
    assign target[0].bresp  = m_ram.bresp;
    assign target[0].bid    = m_ram.bid;
    assign m_ram.bready  = target[0].bready;
    assign m_ram.arvalid = target[0].arvalid;
    assign m_ram.araddr  = target[0].araddr;
    assign m_ram.arprot  = target[0].arprot;
    assign m_ram.arid    = target[0].arid;
    assign target[0].arready = m_ram.arready;
    assign target[0].rvalid = m_ram.rvalid;
    assign target[0].rdata  = m_ram.rdata;
    assign target[0].rresp  = m_ram.rresp;
    assign target[0].rid    = m_ram.rid;
    assign m_ram.rready  = target[0].rready;
endmodule

`default_nettype wire
