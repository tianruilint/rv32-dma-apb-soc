// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// P2-owned 32-bit APB timer.  All state changes on the rising edge of clk.
module p2_apb_timer #(
    parameter logic [31:0] BASE_ADDR = 32'h0000_2000,
    parameter int unsigned WAIT_CYCLES = 0
)(
    input  wire logic clk,
    input  wire logic rst,
    input  wire logic [31:0] paddr,
    input  wire logic psel,
    input  wire logic penable,
    input  wire logic pwrite,
    input  wire logic [31:0] pwdata,
    input  wire logic [3:0] pstrb,
    output wire logic pready,
    output      logic [31:0] prdata,
    output wire logic pslverr,
    output wire logic irq
);

localparam int WAIT_W = WAIT_CYCLES < 1 ? 1 : $clog2(WAIT_CYCLES+1);

logic enable_reg;
logic periodic_reg;
logic irq_enable_reg;
logic [31:0] period_reg;
logic [31:0] count_reg;
logic pending_reg;
logic [WAIT_W-1:0] wait_reg;

logic enable_next, periodic_next, irq_enable_next, pending_next;
logic [31:0] period_next, count_next;
logic [31:0] period_merged;
logic event_now, clear_pending;
logic transfer, write_ctrl, write_period, write_status, config_write;
logic valid_read, valid_write;

assign pready = wait_reg == 0;
assign transfer = psel && penable && pready;
assign write_ctrl = transfer && pwrite && paddr == BASE_ADDR;
assign write_period = transfer && pwrite && paddr == BASE_ADDR+32'd4;
assign write_status = transfer && pwrite && paddr == BASE_ADDR+32'd12;
assign config_write = (write_ctrl && pstrb[0]) || (write_period && |pstrb);
assign valid_read = paddr == BASE_ADDR || paddr == BASE_ADDR+32'd4 ||
                    paddr == BASE_ADDR+32'd8 || paddr == BASE_ADDR+32'd12;
assign valid_write = paddr == BASE_ADDR || paddr == BASE_ADDR+32'd4 ||
                     paddr == BASE_ADDR+32'd12;
assign pslverr = transfer && (pwrite ? !valid_write : !valid_read);
assign irq = pending_reg && irq_enable_reg;

always_comb begin
    prdata = '0;
    if (psel && !pwrite) begin
        case (paddr)
            BASE_ADDR:          prdata = {29'd0, irq_enable_reg, periodic_reg, enable_reg};
            BASE_ADDR+32'd4:    prdata = period_reg;
            BASE_ADDR+32'd8:    prdata = count_reg;
            BASE_ADDR+32'd12:   prdata = {30'd0, (enable_reg && period_reg != 0 && count_reg != 0), pending_reg};
            default:            prdata = '0;
        endcase
    end
end

always_comb begin
    period_merged = period_reg;
    for (int i = 0; i < 4; i++) begin
        if (pstrb[i]) period_merged[8*i +: 8] = pwdata[8*i +: 8];
    end

    enable_next = enable_reg;
    periodic_next = periodic_reg;
    irq_enable_next = irq_enable_reg;
    period_next = period_reg;
    count_next = count_reg;
    pending_next = pending_reg;
    event_now = 1'b0;
    clear_pending = write_status && pstrb[0] && pwdata[0];

    // Configuration writes take precedence over this edge's countdown.
    if (!config_write && enable_reg && period_reg != 0 && count_reg != 0) begin
        if (count_reg == 1) begin
            event_now = 1'b1;
            if (periodic_reg) begin
                count_next = period_reg;
            end else begin
                enable_next = 1'b0;
                count_next = '0;
            end
        end else begin
            count_next = count_reg - 32'd1;
        end
    end

    if (write_ctrl && pstrb[0]) begin
        enable_next = pwdata[0];
        periodic_next = pwdata[1];
        irq_enable_next = pwdata[2];
        if (!pwdata[0]) count_next = '0;
        else if (!enable_reg) count_next = period_reg;
    end

    if (write_period && |pstrb) begin
        period_next = period_merged;
        if (enable_reg) count_next = period_merged;
    end

    // A new expiration wins over a simultaneous W1C clear.
    pending_next = (pending_reg && !clear_pending) || event_now;
end

always_ff @(posedge clk) begin
    if (rst) begin
        wait_reg <= '0;
        enable_reg <= 1'b0;
        periodic_reg <= 1'b0;
        irq_enable_reg <= 1'b0;
        period_reg <= '0;
        count_reg <= '0;
        pending_reg <= 1'b0;
    end else begin
        if (psel && !penable) begin
            wait_reg <= WAIT_W'(WAIT_CYCLES);
        end else if (psel && penable && wait_reg != 0) begin
            wait_reg <= wait_reg - WAIT_W'(1);
        end

        enable_reg <= enable_next;
        periodic_reg <= periodic_next;
        irq_enable_reg <= irq_enable_next;
        period_reg <= period_next;
        count_reg <= count_next;
        pending_reg <= pending_next;
    end
end

endmodule

`default_nettype wire
