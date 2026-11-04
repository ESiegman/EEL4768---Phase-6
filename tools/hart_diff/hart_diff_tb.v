`timescale 1ns / 1ps
`default_nettype none
`include "mem_model.vh"

// TEST ONLY. Runs a program on hart (graded cache configuration by default:
// PLRU, 4 ways, 2 KB, 16 B blocks, prefetch on, 4-cycle memory), writes the
// retire stream to a text file for diffing against iss.py, then compares
// main data memory with a golden image per phase 6 section (phase_6.pdf
// 6.1). Driven by run.sh; override parameters with -Ptb.NAME=value.
module tb;
    parameter LATENCY      = 4;
    parameter EVICT_POLICY = 1;
    parameter NUM_WAYS     = 4;
    parameter CACHE_SIZE   = 2;
    parameter BLOCK_SIZE   = 16;
    parameter PREFETCH_EN  = 1;
    parameter BYPASS_EN    = 1;
    parameter FWD_EN       = 1;
    localparam IMEM_WORDS  = 40000;
    localparam DMEM_WORDS  = 32768 + 64;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    wire imem_rd, imem_valid, dmem_rd, dmem_valid, dmem_wr;
    wire [31:0] imem_rd_addr, dmem_rd_addr, dmem_wr_addr;
    wire [BLOCK_SIZE*8-1:0] imem_rd_data, dmem_rd_data, dmem_wr_data;
    wire [BLOCK_SIZE-1:0] dmem_wr_be;
    wire rv, rtrap, rhalt, rdren, rdwen, rfwen;
    wire [31:0] rinst, rpc, rnpc, rs1d, rs2d, rdd, daddr, drdata, dwdata, f1d, f2d, f3d, fdd;
    wire [4:0] rs1a, rs2a, rda, f1a, f2a, f3a, fda, ffl;
    wire [3:0] dmask;

    hart #(.RESET_ADDR(32'h00400000), .FWD_EN(FWD_EN), .BYPASS_EN(BYPASS_EN),
           .EVICT_POLICY(EVICT_POLICY), .NUM_WAYS(NUM_WAYS), .CACHE_SIZE(CACHE_SIZE),
           .BLOCK_SIZE(BLOCK_SIZE), .PREFETCH_EN(PREFETCH_EN)) dut (
        .i_clk(clk), .i_rst(rst),
        .o_imem_rd(imem_rd), .o_imem_rd_addr(imem_rd_addr), .i_imem_valid(imem_valid),
        .i_imem_rd_data(imem_rd_data), .o_dmem_rd(dmem_rd), .o_dmem_rd_addr(dmem_rd_addr),
        .i_dmem_valid(dmem_valid), .i_dmem_rd_data(dmem_rd_data), .o_dmem_wr(dmem_wr),
        .o_dmem_wr_addr(dmem_wr_addr), .o_dmem_wr_data(dmem_wr_data), .o_dmem_wr_be(dmem_wr_be),
        .o_retire_valid(rv), .o_retire_inst(rinst), .o_retire_trap(rtrap),
        .o_retire_halt(rhalt), .o_retire_rs1_raddr(rs1a), .o_retire_rs2_raddr(rs2a),
        .o_retire_rs1_rdata(rs1d), .o_retire_rs2_rdata(rs2d), .o_retire_rd_waddr(rda),
        .o_retire_rd_wdata(rdd), .o_retire_dmem_addr(daddr), .o_retire_dmem_mask(dmask),
        .o_retire_dmem_ren(rdren), .o_retire_dmem_wen(rdwen), .o_retire_dmem_rdata(drdata),
        .o_retire_dmem_wdata(dwdata), .o_retire_pc(rpc), .o_retire_next_pc(rnpc),
        .o_retire_frs1_raddr(f1a), .o_retire_frs1_rdata(f1d),
        .o_retire_frs2_raddr(f2a), .o_retire_frs2_rdata(f2d),
        .o_retire_frs3_raddr(f3a), .o_retire_frs3_rdata(f3d),
        .o_retire_frd_wen(rfwen), .o_retire_frd_waddr(fda), .o_retire_frd_wdata(fdd),
        .o_retire_fflags(ffl));

    main_mem #(.BLOCK_SIZE(BLOCK_SIZE), .LATENCY(LATENCY), .BASE_ADDR(32'h00400000),
               .SIZE_WORDS(IMEM_WORDS), .NAME("imem")) u_imem (
        .i_clk(clk), .i_rst(rst), .i_rd(imem_rd), .i_rd_addr(imem_rd_addr),
        .o_rd_valid(imem_valid), .o_rd_data(imem_rd_data), .i_wr(1'b0), .i_wr_addr(32'd0),
        .i_wr_data({BLOCK_SIZE*8{1'b0}}), .i_wr_be({BLOCK_SIZE{1'b0}}));
    main_mem #(.BLOCK_SIZE(BLOCK_SIZE), .LATENCY(LATENCY), .BASE_ADDR(32'h10010000),
               .SIZE_WORDS(DMEM_WORDS), .NAME("dmem")) u_dmem (
        .i_clk(clk), .i_rst(rst), .i_rd(dmem_rd), .i_rd_addr(dmem_rd_addr),
        .o_rd_valid(dmem_valid), .o_rd_data(dmem_rd_data), .i_wr(dmem_wr),
        .i_wr_addr(dmem_wr_addr), .i_wr_data(dmem_wr_data), .i_wr_be(dmem_wr_be));

    integer fd, n, cycles, retired, last_retire, k, s, bad;
    reg     saw_halt = 0;
    integer dstall_errs = 0;
    reg [8*256-1:0] prog, gold, out;
    reg [31:0] golden [0:32767];
    reg [31:0] lo [0:9];
    reg [31:0] hi [0:9];
    reg [8*16-1:0] nm [0:9];

    // ex_stall must never let the dcache see a request
    always @(posedge clk) if (!rst && dut.ex_stall && (dut.dcache_ren || dut.dcache_wen)) begin
        $display("ERROR: dcache request during ex_stall at %0t", $time);
        dstall_errs = dstall_errs + 1;
    end

    always @(posedge clk) begin
        if (!rst) cycles = cycles + 1;
        if (!rst && rv) begin
            retired = retired + 1;
            last_retire = cycles;
            if (rhalt) saw_halt = 1;
            $fwrite(fd, "%08x %08x t%0d h%0d npc=%08x x%0d=%08x x%0d=%08x",
                    rpc, rinst, rtrap, rhalt, rnpc, rs1a, rs1a ? rs1d : 0, rs2a, rs2a ? rs2d : 0);
            $fwrite(fd, " f%0d=%08x f%0d=%08x f%0d=%08x", f1a, f1d, f2a, f2d, f3a, f3d);
            if (rda != 0) $fwrite(fd, " rd%0d=%08x", rda, rdd);
            if (rfwen) $fwrite(fd, " fd%0d=%08x", fda, fdd);
            $fwrite(fd, " ff=%02x", ffl);
            if (rdren) $fwrite(fd, " ld[%08x]%x=%08x", daddr, dmask, drdata);
            if (rdwen) $fwrite(fd, " st[%08x]%x=%08x", daddr, dmask,
                               dwdata & {{8{dmask[3]}}, {8{dmask[2]}}, {8{dmask[1]}}, {8{dmask[0]}}});
            $fwrite(fd, "\n");
        end
    end

    initial begin
        if (!$value$plusargs("prog=%s", prog)) prog = "random_program.hex";
        if (!$value$plusargs("gold=%s", gold)) gold = "";
        if (!$value$plusargs("out=%s", out)) out = "hart.trace";
        u_imem.load_hex(prog, n);
        fd = $fopen(out, "w");
        cycles = 0; retired = 0; last_retire = 0;
        repeat (3) @(posedge clk);
        @(negedge clk) rst = 0;
        while (!saw_halt && cycles - last_retire < 3000 && cycles < 3000000)
            @(posedge clk);
        @(posedge clk);
        $fclose(fd);
        $display("retired %0d in %0d cycles, %0s, memory model errors: imem %0d, dmem %0d",
                 retired, cycles, saw_halt ? "halted" : "DID NOT HALT", u_imem.errors, u_dmem.errors);
        if (dstall_errs) $display("ERROR: %0d dcache requests during ex_stall", dstall_errs);
        if (gold != "") begin
            $readmemh(gold, golden);
            nm[0]="program data"; lo[0]=32'h10010000; hi[0]=32'h10017FFF;
            nm[1]="muldiv";       lo[1]=32'h10020000; hi[1]=32'h100217FF;
            nm[2]="fp_move_cmp";  lo[2]=32'h10021800; hi[2]=32'h10022FFF;
            nm[3]="fp_convert";   lo[3]=32'h10023000; hi[3]=32'h100247FF;
            nm[4]="fp_add_mul";   lo[4]=32'h10024800; hi[4]=32'h10025FFF;
            nm[5]="fp_fused";     lo[5]=32'h10026000; hi[5]=32'h100277FF;
            nm[6]="fp_div_sqrt";  lo[6]=32'h10027800; hi[6]=32'h10028FFF;
            nm[7]="fp_csr";       lo[7]=32'h10029000; hi[7]=32'h1002A7FF;
            nm[8]="mixed";        lo[8]=32'h1002A800; hi[8]=32'h1002BFFF;
            nm[9]="cache_stall";  lo[9]=32'h1002C000; hi[9]=32'h1002D7FF;
            for (s = 0; s < 10; s = s + 1) begin
                bad = 0;
                for (k = lo[s]; k <= hi[s]; k = k + 4)
                    if (u_dmem.peek(k) !== golden[(k - 32'h10010000) >> 2]) bad = bad + 1;
                $display("  golden %-13s %0d words differ", nm[s], bad);
            end
        end
        $finish;
    end
endmodule
