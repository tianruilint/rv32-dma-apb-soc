// Testbench RAM only; not a synthesized memory implementation.
`timescale 1ns / 1ps
`default_nettype none

module soc_ram_model #(
    parameter int WORDS = 65536  // 1 MiB at 16 bytes per word
)(
    input wire logic clk,
    input wire logic rst,
    p2_axil_if.slave s_axi,
    output logic [31:0] read_accepts,
    output logic [31:0] write_accepts
);
    logic [127:0] mem [0:WORDS-1];
    string program_hex;
    initial begin
        for (int i = 0; i < WORDS; i++) mem[i] = '0;
        if ($value$plusargs("PROGRAM_HEX=%s", program_hex)) begin
            $display("SOC_RAM_INIT %s", program_hex);
            $readmemh(program_hex, mem);
        end
    end

    logic aw_full, w_full;
    logic [31:0] awaddr_q;
    logic [7:0] awid_q;
    logic [127:0] wdata_q;
    logic [15:0] wstrb_q;
    logic bvalid_q;
    logic [7:0] bid_q;
    logic rvalid_q;
    logic [127:0] rdata_q;
    logic [7:0] rid_q;
    logic b_pending, r_pending;
    logic [3:0] b_delay, r_delay;
    logic [31:0] random_state;
    int unsigned stall_seed = 0;
    initial begin
        if ($value$plusargs("RAM_STALL_SEED=%d", stall_seed))
            $display("SOC_RAM_STALL_SEED %0d", stall_seed);
    end

    assign s_axi.awready = !aw_full && !bvalid_q && !b_pending &&
                          (stall_seed == 0 || random_state[0]);
    assign s_axi.wready  = !w_full && !bvalid_q && !b_pending &&
                          (stall_seed == 0 || random_state[7]);
    assign s_axi.bvalid  = bvalid_q;
    assign s_axi.bresp   = 2'b00;
    assign s_axi.bid     = bid_q;
    assign s_axi.arready = !rvalid_q && !r_pending &&
                          (stall_seed == 0 || random_state[13]);
    assign s_axi.rvalid  = rvalid_q;
    assign s_axi.rdata   = rdata_q;
    assign s_axi.rresp   = 2'b00;
    assign s_axi.rid     = rid_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            aw_full <= 1'b0;
            w_full <= 1'b0;
            awaddr_q <= '0;
            awid_q <= '0;
            wdata_q <= '0;
            wstrb_q <= '0;
            bvalid_q <= 1'b0;
            bid_q <= '0;
            rvalid_q <= 1'b0;
            rdata_q <= '0;
            rid_q <= '0;
            b_pending <= 0;
            r_pending <= 0;
            b_delay <= 0;
            r_delay <= 0;
            random_state <= stall_seed == 0 ? 32'h1 : 32'(stall_seed);
            read_accepts <= '0;
            write_accepts <= '0;
        end else begin
            random_state <= {random_state[30:0], random_state[31] ^
                random_state[21] ^ random_state[1] ^ random_state[0]};
            if (s_axi.awvalid && s_axi.awready) begin
                aw_full <= 1'b1;
                awaddr_q <= s_axi.awaddr;
                awid_q <= s_axi.awid;
            end
            if (s_axi.wvalid && s_axi.wready) begin
                w_full <= 1'b1;
                wdata_q <= s_axi.wdata;
                wstrb_q <= s_axi.wstrb;
            end
            if (aw_full && w_full && !bvalid_q && !b_pending) begin
                if (awaddr_q[31:20] != 0) $fatal(1, "RAM write outside 1 MiB");
                for (int lane = 0; lane < 16; lane++) begin
                    if (wstrb_q[lane])
                        mem[awaddr_q[19:4]][8*lane +: 8] <= wdata_q[8*lane +: 8];
                end
                $display("SOC_RAM_WRITE addr=%08x strb=%04x id=%02x", awaddr_q, wstrb_q, awid_q);
                write_accepts <= write_accepts + 1;
                aw_full <= 1'b0;
                w_full <= 1'b0;
                bid_q <= awid_q;
                if (stall_seed == 0) bvalid_q <= 1'b1;
                else begin
                    b_pending <= 1'b1;
                    b_delay <= {1'b0, random_state[19:17]};
                end
            end
            if (b_pending) begin
                if (b_delay == 0) begin b_pending <= 0; bvalid_q <= 1; end
                else b_delay <= b_delay - 1'b1;
            end
            if (bvalid_q && s_axi.bready) bvalid_q <= 1'b0;
            if (s_axi.arvalid && s_axi.arready) begin
                if (s_axi.araddr[31:20] != 0) $fatal(1, "RAM read outside 1 MiB");
                rdata_q <= mem[s_axi.araddr[19:4]];
                rid_q <= s_axi.arid;
                if (stall_seed == 0) rvalid_q <= 1'b1;
                else begin
                    r_pending <= 1'b1;
                    r_delay <= {1'b0, random_state[26:24]};
                end
                read_accepts <= read_accepts + 1;
                $display("SOC_RAM_READ addr=%08x id=%02x", s_axi.araddr, s_axi.arid);
            end
            if (r_pending) begin
                if (r_delay == 0) begin r_pending <= 0; rvalid_q <= 1; end
                else r_delay <= r_delay - 1'b1;
            end
            if (rvalid_q && s_axi.rready) rvalid_q <= 1'b0;
        end
    end
endmodule

`default_nettype wire
