// Rubric row: FP control and status.
// Runs traces/random_program.hex on hart in the graded cache configuration
// (PLRU, 4 ways, 2 KB, 16 B blocks, prefetch on, 4-cycle memory).
// Graded range: fp csr, 0x10029000-0x1002A7FF (phase_6.pdf 6.1).
// Every check is in hart_tb_common.vh.

`include "hart_tb_common.vh"

module hart_fp_csr_tb;

    reg  start;
    wire done;

    hart_harness #(
        .LABEL       ("fp_csr"),
        .EVICT_POLICY(1),
        .NUM_WAYS    (4),
        .CACHE_SIZE  (2),
        .BLOCK_SIZE  (16),
        .PREFETCH_EN (1),
        .LATENCY     (4),
        .SEC_LO      (32'h10029000),
        .SEC_HI      (32'h1002A7FF)
    ) h (
        .i_start(start),
        .o_done (done)
    );

    initial begin
        start = 1'b0;
        #1 start = 1'b1;
        wait (done === 1'b1);
        $display("%0d passed, %0d failed", h.passed, h.failed);
        if (h.failed == 0 && h.passed > 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end

endmodule
