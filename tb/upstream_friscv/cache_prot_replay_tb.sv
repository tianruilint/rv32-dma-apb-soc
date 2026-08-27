// SPDX-License-Identifier: CERN-OHL-S-2.0
// The block fetcher must replay address, ID and PROT together after a cache miss.
`timescale 1ns/1ps
module cache_prot_replay_tb;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst_n = 0;
    reg srst = 0;
    reg arvalid = 0;
    wire arready;
    reg [31:0] araddr = 0;
    reg [7:0] arid = 0;
    reg [2:0] arprot = 0;
    reg miss = 0;
    wire cache_ren;
    wire [31:0] cache_addr;
    wire [7:0] cache_id;
    wire [2:0] cache_prot;
    wire rvalid;
    wire [7:0] rid;
    wire [1:0] rresp;
    wire [31:0] rdata;
    friscv_cache_block_fetcher #(.AXI_DATA_W(128)) dut (
        .aclk(clk), .aresetn(rst_n), .srst(srst),
        .flush_reqs(1'b0), .flush_blocks(1'b0),
        .mst_arvalid(arvalid), .mst_arready(arready),
        .mst_araddr(araddr), .mst_arid(arid), .mst_arprot(arprot),
        .mst_rvalid(rvalid), .mst_rready(1'b1), .mst_rid(rid),
        .mst_rresp(rresp), .mst_rdata(rdata),
        .cache_ren(cache_ren), .cache_raddr(cache_addr),
        .cache_rid(cache_id), .cache_rprot(cache_prot),
        .cache_rdata(32'b0), .block_fill(1'b0), .cache_hit(1'b0), .cache_miss(miss)
`ifdef P2_HARDENED
        , .mem_error_valid(1'b0), .mem_error_addr(32'b0), .mem_error_resp(2'b0)
`endif
    );
    initial begin
        for (integer p=0; p<8; p=p+1) begin
            @(negedge clk);
            rst_n = 0; srst = 0; arvalid = 0; miss = 0;
            repeat (2) @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            arvalid = 1; araddr = 32'h1200 + 32'(p*16); arid = 8'h50 + 8'(p); arprot = 3'(p);
            #1;
            if (!arready || !cache_ren || cache_prot !== 3'(p)) $fatal(1,"CACHE_PROT_INITIAL_FAIL prot=%h",cache_prot);
            @(posedge clk); #1;
            @(negedge clk); arvalid = 0; miss = 1;
            // A different request at the input must not replace the missed request.
            arprot = ~3'(p); araddr = 32'hdeadbeef; arid = 8'hee;
            repeat (3) begin
                #1;
                if (cache_addr !== (32'h1200 + 32'(p*16)) || cache_id !== (8'h50 + 8'(p)))
                    $fatal(1,"CACHE_REPLAY_ADDRESS_FAIL addr=%h id=%h",cache_addr,cache_id);
                if (cache_prot !== 3'(p))
                    $fatal(1,"CACHE_PROT_REPLAY_FAIL expected=%h got=%h",3'(p),cache_prot);
                @(negedge clk);
            end
        end
        $display("CACHE_PROT_REPLAY_PASS all_8_PROT_values held_3_cycles");
        $finish;
    end
    initial begin #10000; $fatal(1,"CACHE_PROT_TIMEOUT"); end
endmodule
