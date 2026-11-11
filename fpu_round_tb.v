// Direct tests of the shared rounder, including inputs a future divider
// can produce. Optional +vectors=<file> accepts integer-oracle vectors.
module fpu_round_tb;
    reg sign;
    reg [9:0] exp;
    reg [25:0] sig;
    reg [2:0] rm;
    wire [31:0] result;
    wire [4:0] flags;
    fpu_round dut (.i_sign(sign), .i_exp(exp), .i_sig(sig), .i_rm(rm),
                   .o_result(result), .o_flags(flags));
    integer passed, failed, s, m, fd, scan;
    reg away, nearest, up;
    reg [31:0] expected;
    reg [4:0] expected_flags;
    reg [1023:0] path;

    task check;
        input v_sign;
        input [9:0] v_exp;
        input [25:0] v_sig;
        input [2:0] v_rm;
        input [31:0] want;
        input [4:0] want_flags;
        begin
            sign = v_sign; exp = v_exp; sig = v_sig; rm = v_rm;
            #1;
            if (result === want && flags === want_flags) passed = passed + 1;
            else begin
                if (failed < 10)
                    $display("round FAIL: sign=%b exp=%h sig=%h rm=%d got=%h/%h want=%h/%h",
                             sign, exp, sig, rm, result, flags, want, want_flags);
                failed = failed + 1;
            end
        end
    endtask

    initial begin
        passed = 0; failed = 0;
        for (s = 0; s < 2; s = s + 1) begin
            for (m = 0; m < 5; m = m + 1) begin
                away = (m == 2 && s == 1) || (m == 3 && s == 0);
                nearest = (m == 0 || m == 4);
                check(s, 127, 26'h2000000, m, {s[0], 31'h3F800000}, 0);
                check(s, -171, 0, m, {s[0], 31'd0}, 0);
                // Halfway with an even retained significand, then odd.
                up = away || m == 4;
                check(s, 127, 26'h2000002, m, {s[0], (31'h3F800000 + up)}, 1);
                up = away || nearest;
                check(s, 127, 26'h2000006, m, {s[0], (31'h3F800001 + up)}, 1);
                // Sticky alone must influence directed rounding.
                check(s, 127, 26'h2000001, m, {s[0], (31'h3F800000 + away)}, 1);
                // Exact subnormal and a half-ulp at the bottom of the range.
                check(s, 0, 26'h2000000, m, {s[0], 31'h00400000}, 0);
                check(s, -22, 26'h2000000, m, {s[0], 31'd1}, 0);
                check(s, -23, 26'h2000000, m, {s[0], 30'd0, (away || m == 4)}, 3);
                check(s, -171, 26'h2000000, m, {s[0], 30'd0, away}, 3);
                // The result may pack as minimum normal yet still be tiny
                // after precision rounding with an unbounded exponent.
                up = away || nearest;
                check(s, 0, 26'h3FFFFFC, m,
                      {s[0], (up ? 31'h00800000 : 31'h007FFFFF)}, 3);
                check(s, 0, 26'h3FFFFFD, m,
                      {s[0], (up ? 31'h00800000 : 31'h007FFFFF)}, away ? 1 : 3);
                check(s, 0, 26'h3FFFFFE, m,
                      {s[0], (up ? 31'h00800000 : 31'h007FFFFF)}, up ? 1 : 3);
                // At the largest exponent, only rounding carry overflows.
                check(s, 254, 26'h3FFFFFE, m,
                      {s[0], (up ? 31'h7F800000 : 31'h7F7FFFFF)}, up ? 5 : 1);
                check(s, 255, 26'h2000000, m,
                      {s[0], (up ? 31'h7F800000 : 31'h7F7FFFFF)}, 5);
                check(s, 382, 26'h2000000, m,
                      {s[0], (up ? 31'h7F800000 : 31'h7F7FFFFF)}, 5);
            end
        end
        if ($value$plusargs("vectors=%s", path)) begin
            fd = $fopen(path, "r");
            if (!fd) begin
                $display("FAIL: cannot open rounder vectors %0s", path);
                failed = failed + 1;
            end else begin
                scan = 6;
                while (scan == 6) begin
                    scan = $fscanf(fd, "%h %h %h %h %h %h\n",
                                   sign, exp, sig, rm, expected, expected_flags);
                    if (scan == 6) check(sign, exp, sig, rm, expected, expected_flags);
                end
                if (!$feof(fd)) begin
                    $display("FAIL: malformed rounder vector file");
                    failed = failed + 1;
                end
                $fclose(fd);
            end
        end
        $display("%0d passed, %0d failed", passed, failed);
        if (failed == 0) $display("ALL TESTS PASSED");
        else $display("TEST FAILED");
        $finish;
    end
endmodule
