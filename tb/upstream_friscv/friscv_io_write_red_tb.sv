`timescale 1ns/1ps
module friscv_io_write_red_tb;
  logic clk = 0;
  always #5 clk = ~clk;
  logic resetn = 0;
  logic awvalid = 0, wvalid = 0, bready = 0;
  wire awready, wready, bvalid;
  wire [1:0] bresp;
  wire [7:0] bid;
  wire arready, rvalid;
  wire [1:0] rresp;
  wire [127:0] rdata;
  wire [7:0] rid;
  wire [31:0] gpio_out;
  wire uart_tx, uart_rts, sw_irq, timer_irq;

  friscv_io_subsystem #(.ADDRW(32), .DATAW(128), .IDW(8), .XLEN(32)) dut (
    .aclk(clk), .aresetn(resetn), .srst(1'b0), .rtc(1'b0),
    .slv_awvalid(awvalid), .slv_awready(awready), .slv_awaddr(32'h0),
    .slv_awprot(3'b0), .slv_awid(8'h5a),
    .slv_wvalid(wvalid), .slv_wready(wready),
    .slv_wdata(128'h00000000000000000000000012345678),
    .slv_wstrb(16'h000f), .slv_bvalid(bvalid), .slv_bready(bready),
    .slv_bresp(bresp), .slv_bid(bid),
    .slv_arvalid(1'b0), .slv_arready(arready), .slv_araddr(32'h0),
    .slv_arprot(3'b0), .slv_arid(8'h0), .slv_rvalid(rvalid),
    .slv_rready(1'b0), .slv_rresp(rresp), .slv_rdata(rdata), .slv_rid(rid),
    .gpio_in(32'h0), .gpio_out(gpio_out),
    .uart_rx(1'b1), .uart_tx(uart_tx), .uart_rts(uart_rts),
    .uart_cts(1'b0), .sw_irq(sw_irq), .timer_irq(timer_irq)
  );

  initial begin
    repeat (4) @(negedge clk);
    resetn = 1;
    @(negedge clk);
    awvalid = 1;
    wvalid = 1;
    do @(posedge clk); while (!(awvalid && awready && wvalid && wready));
    $display("FRISCV_IO_AW_W_HANDSHAKE id=%h", 8'h5a);
    @(negedge clk);
    awvalid = 0;
    wvalid = 0;
    repeat (30) begin
      @(posedge clk);
      if (bvalid) begin
        if (bid !== 8'h5a || bresp !== 2'b00)
          $fatal(1, "FRISCV_IO_BAD_B_RESPONSE id=%h resp=%h", bid, bresp);
        if (gpio_out !== 32'h12345678)
          $fatal(1, "FRISCV_IO_GPIO_WRITE_NOT_OBSERVED value=%h", gpio_out);
        repeat (3) begin
          @(posedge clk);
          if (!bvalid || bid !== 8'h5a || bresp !== 2'b00)
            $fatal(1, "FRISCV_IO_STALLED_B_RESPONSE_CHANGED");
        end
        @(negedge clk);
        bready = 1;
        @(posedge clk);
        @(negedge clk);
        bready = 0;
        repeat (2) @(posedge clk);
        if (bvalid)
          $fatal(1, "FRISCV_IO_DUPLICATE_B_RESPONSE");
        $display("FRISCV_IO_SAME_CYCLE_WRITE_B_RESPONDED id=%h resp=%h", bid, bresp);
        $finish;
      end
    end
    $display("FRISCV_IO_GPIO_AFTER_WRITE=%h", gpio_out);
    if (gpio_out !== 32'h12345678)
      $fatal(1, "FRISCV_IO_GPIO_WRITE_NOT_OBSERVED");
    $fatal(1, "FRISCV_IO_SAME_CYCLE_WRITE_MISSING_B");
  end
endmodule
