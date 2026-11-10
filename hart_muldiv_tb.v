// Rubric row: Multiply and divide.
// Runs traces/random_program.hex on hart in the graded cache configuration
// (PLRU, 4 ways, 2 KB, 16 B blocks, prefetch on, 4-cycle memory).
// Graded range: muldiv, 0x10020000-0x100217FF (phase_6.pdf 6.1).
// Every check is in hart_tb_common.vh.

`include "hart_tb_common.vh"

module hart_muldiv_tb;

    reg  start;
    wire done;

    hart_harness #(
        .LABEL       ("muldiv"),
        .EVICT_POLICY(1),
        .NUM_WAYS    (4),
        .CACHE_SIZE  (2),
        .BLOCK_SIZE  (16),
        .PREFETCH_EN (1),
        .LATENCY     (4),
        .SEC_LO      (32'h10020000),
        .SEC_HI      (32'h100217FF)
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
