// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns/1ps
`default_nettype none
module cache_write_backpressure_tb;
    bit clk = 0;
    always #5 clk = ~clk;
    bit rstn = 0;
    bit awvalid = 0, wvalid = 0;
    logic [31:0] addr = 0, data = 0;
    logic [2:0] prot = 3'b101;
    wire awready, wready, bvalid;
    wire [7:0] bid;
    wire [1:0] bresp;
    wire cache_ready;
    wire out_awvalid, out_wvalid, out_bready;
    wire [31:0] out_addr;
    wire [2:0] out_prot;
    wire [7:0] out_id;
    wire [127:0] out_data;
    wire [15:0] out_strb;
    logic out_bvalid = 0;
    logic [7:0] response_id = 0;
    bit release_responses = 0;
    logic [31:0] saved_addr [0:31];
    logic [2:0] saved_prot [0:31];
    logic [7:0] saved_id [0:31];
    logic [127:0] saved_data [0:31];
    logic [15:0] saved_strb [0:31];
    wire out_awready = rstn && external_aw < 24;
    wire out_wready = rstn && external_w < 24;
    int accepted_aw = 0, accepted_w = 0, external_aw = 0, external_w = 0;
    int responses = 0, external_b = 0;
    logic [31:0] expected_data [0:23];
    logic [2:0] expected_prot [0:23];

    friscv_dcache #(.OSTDREQ_NUM(4), .AXI_ADDR_W(32), .AXI_ID_W(8),
        .AXI_DATA_W(128), .AXI_ID_MASK(8'h10), .AXI_ID_FIXED(1),
        .IO_MAP_NB(1), .FAST_FWD_CPL(1), .CACHE_DEPTH(8)) dut (
        .aclk(clk), .aresetn(rstn), .srst(1'b0), .cache_ready(cache_ready),
        .memfy_awvalid(awvalid), .memfy_awready(awready), .memfy_awaddr(addr),
        .memfy_awprot(prot), .memfy_awcache(4'b0011), .memfy_awid(8'h10),
        .memfy_wvalid(wvalid), .memfy_wready(wready), .memfy_wdata(data), .memfy_wstrb(4'hf),
        .memfy_bvalid(bvalid), .memfy_bready(1'b1), .memfy_bid(bid), .memfy_bresp(bresp),
        .memfy_arvalid(1'b0), .memfy_arready(), .memfy_araddr(32'b0),
        .memfy_arprot(3'b0), .memfy_arcache(4'b0), .memfy_arid(8'b0),
        .memfy_rvalid(), .memfy_rready(1'b1), .memfy_rid(), .memfy_rresp(), .memfy_rdata(),
        .dcache_awvalid(out_awvalid), .dcache_awready(out_awready), .dcache_awaddr(out_addr),
        .dcache_awlen(), .dcache_awsize(), .dcache_awburst(), .dcache_awlock(),
        .dcache_awcache(), .dcache_awprot(out_prot), .dcache_awqos(), .dcache_awregion(),
        .dcache_awid(out_id), .dcache_wvalid(out_wvalid), .dcache_wready(out_wready),
        .dcache_wlast(), .dcache_wdata(out_data), .dcache_wstrb(out_strb),
        .dcache_bvalid(out_bvalid), .dcache_bready(out_bready), .dcache_bid(response_id), .dcache_bresp(2'b0),
        .dcache_arvalid(), .dcache_arready(1'b1), .dcache_araddr(), .dcache_arlen(),
        .dcache_arsize(), .dcache_arburst(), .dcache_arlock(), .dcache_arcache(),
        .dcache_arprot(), .dcache_arqos(), .dcache_arregion(), .dcache_arid(),
        .dcache_rvalid(1'b0), .dcache_rready(), .dcache_rid(8'b0), .dcache_rresp(2'b0),
        .dcache_rdata(128'b0), .dcache_rlast(1'b1)
    );

    always @(posedge clk) if (rstn) begin
        if (awvalid && awready) accepted_aw <= accepted_aw+1;
        if (wvalid && wready) accepted_w <= accepted_w+1;
        if (bvalid) begin
            if (bid != 8'h10 || bresp != 0) $fatal(1, "bad completion ID/response");
            responses <= responses+1;
        end
        if (out_awvalid && out_awready) begin
            saved_addr[external_aw] <= out_addr;
            saved_prot[external_aw] <= out_prot;
            saved_id[external_aw] <= out_id;
            external_aw <= external_aw+1;
        end
        if (out_wvalid && out_wready) begin
            saved_data[external_w] <= out_data;
            saved_strb[external_w] <= out_strb;
            external_w <= external_w+1;
        end
        if (external_aw > external_b && external_w > external_b && !out_bvalid && release_responses) begin
            int index, lane;
            index = int'((saved_addr[external_b]-32'h1000)/4);
            lane = index%4;
            if (index < 0 || index >= 24 || saved_data[external_b][lane*32 +:32] != expected_data[index] ||
                saved_strb[external_b] != (16'hf << (4*lane)))
                $fatal(1, "write data/offset corruption addr=%h data=%h strb=%h", saved_addr[external_b], saved_data[external_b], saved_strb[external_b]);
            // The original run can isolate the tag deadlock before the distinct
            // protection-metadata check. The final run checks both defects.
            if (!$test$plusargs("DEADLOCK_ONLY") && saved_prot[external_b] != expected_prot[index])
                $fatal(1, "AWPROT lost addr=%h actual=%h expected=%h", saved_addr[external_b], saved_prot[external_b], expected_prot[index]);
            out_bvalid <= 1;
            response_id <= saved_id[external_b];
        end
        if (out_bvalid && out_bready) begin
            out_bvalid <= 0;
            external_b <= external_b+1;
        end
    end

    task automatic issue(input int index, input int aw_delay, input int w_delay);
        bit aw_done, w_done;
        aw_done = 0; w_done = 0;
        @(negedge clk);
        addr = 32'h1000+32'(index*4);
        data = expected_data[index];
        prot = expected_prot[index];
        awvalid = aw_delay == 0; wvalid = w_delay == 0;
        for (int tick = 0; tick < 500; tick++) begin
            @(posedge clk);
            if (awvalid && awready) aw_done = 1;
            if (wvalid && wready) w_done = 1;
            @(negedge clk);
            if (aw_done) awvalid = 0;
            else if (tick+1 >= aw_delay) awvalid = 1;
            if (w_done) wvalid = 0;
            else if (tick+1 >= w_delay) wvalid = 1;
            if (aw_done && w_done) return;
        end
        $fatal(1, "write acceptance timeout index=%0d AW/W=%0d/%0d extAW/W/B=%0d/%0d/%0d completed=%0d tags=%h",
               index, accepted_aw, accepted_w, external_aw, external_w, external_b, responses, dut.wr_ooo_mgt.tags);
    endtask

    initial begin : stimulus
        bit completed;
        completed = 0;
        for (int idx = 0; idx < 24; idx++) begin
            expected_data[idx] = 32'hcafe0000 + 32'(idx);
            expected_prot[idx] = 3'(idx%7+1);
        end
        repeat (4) @(negedge clk);
        rstn = 1;
        wait (cache_ready);
        for (int idx = 0; idx < 16; idx++) issue(idx, 0, 0);
        for (int idx = 16; idx < 24; idx++) issue(idx, (idx%2)*3, ((idx+1)%2)*3);
        repeat (300) begin
            @(negedge clk);
            if (responses == 24) begin
                if (accepted_aw != 24 || accepted_w != 24 || external_aw != 24 || external_w != 24 || external_b != 24)
                    $fatal(1, "duplicate/missing transaction count");
                completed = 1;
                break;
            end
        end
        if (!completed)
            $fatal(1, "completion timeout AW/W=%0d/%0d external=%0d/%0d/%0d completed=%0d tags=%h",
                   accepted_aw, accepted_w, external_aw, external_w, external_b, responses, dut.wr_ooo_mgt.tags);
        repeat (20) @(negedge clk);
        if (responses != 24 || dut.wr_ooo_mgt.tags != 0) $fatal(1, "residual completion/tag");
        $display("CACHE_WRITE_BACKPRESSURE_PASS writes=24 completions=24 tag_wraps=6 AW_W_skew=8 AWPROT=all_nonzero");
        $finish;
    end
    initial begin
        // Hold completions long enough to exhaust all four tags while pusher
        // FIFOs still have space, then let every accepted memory write finish.
        #700;
        @(negedge clk);
        release_responses = 1;
    end
    initial begin
        #100000;
        $fatal(1, "global timeout");
    end
endmodule
`default_nettype wire
