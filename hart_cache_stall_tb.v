// Rubric row: Stalls and cache misses.
// Runs traces/random_program.hex on hart in the graded cache configuration
// (PLRU, 4 ways, 2 KB, 16 B blocks, prefetch on, 4-cycle memory), then in
// three more legal configurations (BLOCK_SIZE >= 16, CACHE_SIZE <= 16 KB)
// with other memory latencies. The final memory image is architectural, so
// every configuration is checked against the same random_dmem.hex.
// Graded range: cache stall, 0x1002C000-0x1002D7FF (phase_6.pdf 6.1).
// Every check is in hart_tb_common.vh.

`include "hart_tb_common.vh"

module hart_cache_stall_tb;

    localparam [31:0] LO = 32'h1002C000;
    localparam [31:0] HI = 32'h1002D7FF;

    reg  [3:0] start;
    wire [3:0] done;

    // The graded configuration.
    hart_harness #(
        .LABEL("cache_stall graded PLRU 4w 2KB 16B pf L=4"),
        .EVICT_POLICY(1), .NUM_WAYS(4), .CACHE_SIZE(2), .BLOCK_SIZE(16),
        .PREFETCH_EN(1), .LATENCY(4), .SEC_LO(LO), .SEC_HI(HI)
    ) h0 (.i_start(start[0]), .o_done(done[0]));

    // Direct mapped, smallest cache and blocks, fastest memory: the most
    // conflict misses, each one short.
    hart_harness #(
        .LABEL("cache_stall DM LRU 1KB 16B pf L=1"),
        .EVICT_POLICY(0), .NUM_WAYS(1), .CACHE_SIZE(1), .BLOCK_SIZE(16),
        .PREFETCH_EN(1), .LATENCY(1), .SEC_LO(LO), .SEC_HI(HI)
    ) h1 (.i_start(start[1]), .o_done(done[1]));

    // Largest legal cache, long lines, no prefetch, slow memory: few misses,
    // each one long, overlapping fdiv/fsqrt and iterative muldiv.
    hart_harness #(
        .LABEL("cache_stall 8w LRU 16KB 64B L=10"),
        .EVICT_POLICY(0), .NUM_WAYS(8), .CACHE_SIZE(16), .BLOCK_SIZE(64),
        .PREFETCH_EN(0), .LATENCY(10), .SEC_LO(LO), .SEC_HI(HI)
    ) h2 (.i_start(start[2]), .o_done(done[2]));

    hart_harness #(
        .LABEL("cache_stall 2w PLRU 4KB 32B pf L=4"),
        .EVICT_POLICY(1), .NUM_WAYS(2), .CACHE_SIZE(4), .BLOCK_SIZE(32),
        .PREFETCH_EN(1), .LATENCY(4), .SEC_LO(LO), .SEC_HI(HI)
    ) h3 (.i_start(start[3]), .o_done(done[3]));

    integer passed;
    integer failed;

    initial begin
        start = 4'b0000;
        #1 start[0] = 1'b1;
        wait (done[0] === 1'b1);
        start[1] = 1'b1;
        wait (done[1] === 1'b1);
        start[2] = 1'b1;
        wait (done[2] === 1'b1);
        start[3] = 1'b1;
        wait (done[3] === 1'b1);

        passed = h0.passed + h1.passed + h2.passed + h3.passed;
        failed = h0.failed + h1.failed + h2.failed + h3.failed;
        $display("%0d passed, %0d failed", passed, failed);
        if (failed == 0 && passed > 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end

endmodule
