// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns/1ps
`default_nettype none
module cache_write_response_tb;
    bit clk=0;
    always #5 clk=~clk;
    bit rstn=0;
    bit req_valid=0, response_valid=0, app_ready=0;
    logic [1:0] response_code=0;
    logic [31:0] write_data=0;
    logic [3:0] write_mask=0;
    wire awready,wready,app_valid,mem_ready;
    wire [1:0] app_response;
    wire [7:0] app_id;
    wire mem_awvalid, mem_wvalid;
    wire [31:0] mem_addr,mem_data;
    wire [7:0] mem_id;
    wire [2:0] mem_prot;
    wire [3:0] mem_strb;
    wire cache_ren,cache_wen;
    wire [31:0] cache_raddr,cache_waddr;
    wire [127:0] cache_wdata;
    wire [15:0] cache_wstrb;
    bit cache_hit=0;
    logic [31:0] cache_word=32'h11223344;
    int requests=0,responses=0,mem_writes=0;
    bit got_aw=0,got_w=0;
    friscv_cache_pusher #(.XLEN(32),.OSTDREQ_NUM(4),.AXI_ADDR_W(32),
        .AXI_ID_W(8),.AXI_DATA_W(128),.AXI_ID_MASK(8'h10),.CACHE_BLOCK_W(128)) dut (
        .aclk(clk),.aresetn(rstn),.srst(1'b0),
        .mst_awvalid(req_valid),.mst_awready(awready),.mst_awaddr(32'h1008),
        .mst_awprot(3'b101),.mst_awcache(4'b0000),.mst_awid(8'h10),
        .mst_wvalid(req_valid),.mst_wready(wready),.mst_wdata(write_data),.mst_wstrb(write_mask),
        .mst_bvalid(app_valid),.mst_bready(app_ready),.mst_bid(app_id),.mst_bresp(app_response),
        .memctrl_awvalid(mem_awvalid),.memctrl_awready(1'b1),.memctrl_awaddr(mem_addr),
        .memctrl_awprot(mem_prot),.memctrl_awid(mem_id),
        .memctrl_wvalid(mem_wvalid),.memctrl_wready(1'b1),.memctrl_wdata(mem_data),.memctrl_wstrb(mem_strb),
        .memctrl_bvalid(response_valid),.memctrl_bready(mem_ready),.memctrl_bid(8'h10),.memctrl_bresp(response_code),
        .cache_ren(cache_ren),.cache_raddr(cache_raddr),.cache_hit(cache_hit),.cache_miss(1'b0),
        .cache_wen(cache_wen),.cache_waddr(cache_waddr),.cache_wdata(cache_wdata),.cache_wstrb(cache_wstrb)
    );
    always @(posedge clk) begin
        cache_hit <= rstn && cache_ren;
        if (rstn) begin
            if (req_valid && awready && wready) requests<=requests+1;
            if (app_valid && app_ready) responses<=responses+1;
            if (mem_awvalid) begin
                if(mem_addr!=32'h1008 || mem_id!=8'h10 || mem_prot!=5) $fatal(1,"forwarded AW metadata corrupted");
                got_aw<=1;
            end
            if(mem_wvalid) begin
                if(mem_data!=write_data || mem_strb!=write_mask) $fatal(1,"forwarded W payload corrupted");
                got_w<=1;mem_writes<=mem_writes+1;
            end
            if(cache_ren && cache_raddr!=32'h1008) $fatal(1,"cache probe address corrupted");
            if(cache_wen) begin
                if(cache_waddr!=32'h1008 || (cache_wstrb & 16'hf0ff)!=0) $fatal(1,"cache update lane corrupted");
                for(int b=0;b<4;b++)
                    if(cache_wstrb[b+8]) cache_word[b*8+:8]<=cache_wdata[64+b*8+:8];
            end
        end
    end
    task automatic check_write(input logic [1:0] resp,input logic [31:0] data,input logic [3:0] mask);
        logic [31:0] original,expected;
        bit seen;
        original=cache_word;expected=original;seen=0;
        if(resp==0)
            for(int b=0;b<4;b++) if(mask[b]) expected[b*8+:8]=data[b*8+:8];
        @(negedge clk);
        write_data=data;write_mask=mask;got_aw=0;got_w=0;req_valid=1;
        do @(posedge clk);while(!(awready && wready));
        @(negedge clk);req_valid=0;
        wait(got_aw && got_w);
        repeat(20) begin
            @(negedge clk);
            if(app_valid || cache_word!=original)
                $fatal(1,"CACHE_WRITE_EARLY_COMPLETION_FAIL B withheld app_valid=%b cache=%h expected_old=%h",app_valid,cache_word,original);
        end
        response_code=resp;response_valid=1;
        do @(posedge clk);while(!mem_ready);
        @(negedge clk);response_valid=0;
        repeat(50) begin
            @(negedge clk);
            if(app_valid) begin seen=1;break;end
        end
        if(!seen) $fatal(1,"write response timeout");
        repeat(5) begin
            if(!app_valid || app_response!=resp || app_id!=8'h10)
                $fatal(1,"write response lost under backpressure");
            @(negedge clk);
        end
        app_ready=1;
        @(negedge clk);app_ready=0;
        repeat(8) @(negedge clk);
        if(app_valid || cache_word!=expected || responses!=requests)
            $fatal(1,"cache response contract failed resp=%h cache=%h expected=%h responses=%0d requests=%0d",resp,cache_word,expected,responses,requests);
        $display("CACHE_WRITE_RESPONSE_CASE_PASS resp=%0d data=%h strobes=%h preserved_or_updated=%h",resp,data,mask,cache_word);
    endtask
    initial begin
        repeat(4) @(negedge clk);rstn=1;
        check_write(2,32'hbadc0ffe,4'hf);
        check_write(3,32'hdeadbeef,4'hf);
        check_write(0,32'haabbccdd,4'h5);
        check_write(0,32'h55667788,4'hf);
        if(requests!=4 || responses!=4 || mem_writes!=4) $fatal(1,"write response count");
        $display("CACHE_WRITE_RESPONSE_PASS delayed_B=4 error_preserves_cache=2 successful_updates=2 response_stall=5");
        $finish;
    end
    initial begin #100000;$fatal(1,"global timeout");end
endmodule
`default_nettype wire
