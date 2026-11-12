`default_nettype none

// fdiv.s / fsqrt.s significand datapath (phase_6.pdf 5.3.2). Bit-serial
// restoring division and restoring square root, one result bit per cycle.
//
// The top (fpu.v) resolves every special operand, so this unit only sees
// finite, nonzero operands (and positive ones for square root). Each operand
// arrives normalized: sig[23] = 1, and a signed 10-bit exponent biased by
// 127 that may be below 1 for a subnormal input.
//
// The result goes unrounded to fpu_round: o_sig[25:2] is the 24-bit
// significand (o_sig[25] = 1), o_sig[1] the guard bit and o_sig[0] the
// sticky bit (a nonzero final remainder).
//
// Handshake (same as the other multi-cycle units):
//  * cycle 1: i_valid rises, o_busy goes high, operands are latched
//  * cycles 2-26: one quotient/root bit per cycle (25 bits)
//  * then o_busy drops and the result is held until i_advance
// The unit never restarts while a finished result is held, so a cache
// freeze after the operation finishes cannot rerun it.
module fpu_divsqrt (
    input  wire        i_clk,
    input  wire        i_rst,
    // Start/continue the operation (the fpu's ds_valid).
    input  wire        i_valid,
    // The instruction in EX moves to MEM at the next edge.
    input  wire        i_advance,
    // 1: square root of a. 0: a / b.
    input  wire        i_sqrt,
    input  wire        i_a_sign,
    input  wire [ 9:0] i_a_exp,
    input  wire [23:0] i_a_sig,
    input  wire        i_b_sign,
    input  wire [ 9:0] i_b_exp,
    input  wire [23:0] i_b_sig,
    output wire        o_busy,
    output wire        o_sign,
    output wire [ 9:0] o_exp,
    output wire [25:0] o_sig
);

    // ------------------------------------------------------------------
    // Set-up, computed from the operands on the start cycle.
    // ------------------------------------------------------------------
    // Divide: prescale a by 2 when a_sig < b_sig, so the quotient lands
    // in [1, 2) and its first bit is always 1.
    wire        a_lt_b   = (i_a_sig < i_b_sig);
    wire [25:0] div_rem0 = a_lt_b ? {1'b0, i_a_sig, 1'b0} : {2'b00, i_a_sig};
    wire [ 9:0] div_exp  = i_a_exp - i_b_exp + 10'd127 - {9'd0, a_lt_b};

    // Square root: make the unbiased exponent even by doubling the
    // significand when it is odd, then halve it. The radicand m is in
    // [1, 4), so its root is in [1, 2).
    wire [ 9:0] sq_unb   = i_a_exp - 10'd127;
    wire        sq_odd   = sq_unb[0];
    wire [ 9:0] sq_even  = sq_unb - {9'd0, sq_odd};
    wire [ 9:0] sq_exp   = {sq_even[9], sq_even[9:1]} + 10'd127;
    // m = sig_scaled / 2^23. The radicand X = m * 2^48 = sig_scaled * 2^25,
    // so its 25-bit integer root is sqrt(m) * 2^24.
    wire [24:0] sq_scaled = sq_odd ? {i_a_sig, 1'b0} : {1'b0, i_a_sig};
    wire [49:0] sq_rad0   = {sq_scaled, 25'd0};

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    reg         running;   // stepping
    reg         done;      // finished, result held until i_advance
    reg  [ 4:0] count;     // steps taken, 0..24
    reg         mode_sqrt;
    reg         res_sign;
    reg  [ 9:0] res_exp;
    reg  [27:0] rem;       // partial remainder
    reg  [24:0] res;       // quotient or root bits so far
    reg  [23:0] divisor;
    reg  [49:0] radicand;  // square root: bit pairs still to bring down

    // ------------------------------------------------------------------
    // One restoring step.
    // ------------------------------------------------------------------
    // Divide: if rem >= divisor, subtract and shift in a 1; then rem << 1.
    wire        d_ge   = (rem[25:0] >= {2'b00, divisor});
    wire [25:0] d_sub  = d_ge ? (rem[25:0] - {2'b00, divisor}) : rem[25:0];
    wire [27:0] d_rem  = {2'b00, d_sub[24:0], 1'b0};

    // Square root: bring down the next two radicand bits, and try
    // subtracting (4 * root + 1).
    wire [27:0] s_shift = {rem[25:0], radicand[49:48]};
    wire [27:0] s_trial = {1'b0, res, 2'b01};
    wire        s_ge    = (s_shift >= s_trial);
    wire [27:0] s_rem   = s_ge ? (s_shift - s_trial) : s_shift;

    wire        step_bit = mode_sqrt ? s_ge : d_ge;
    wire [27:0] step_rem = mode_sqrt ? s_rem : d_rem;

    wire        start = i_valid & ~running & ~done;

    always @(posedge i_clk) begin
        if (i_rst | i_advance | ~i_valid) begin
            running <= 1'b0;
            done    <= 1'b0;
            count   <= 5'd0;
        end else if (start) begin
            running   <= 1'b1;
            count     <= 5'd0;
            mode_sqrt <= i_sqrt;
            res_sign  <= i_sqrt ? 1'b0 : (i_a_sign ^ i_b_sign);
            res_exp   <= i_sqrt ? sq_exp : div_exp;
            rem       <= i_sqrt ? 28'd0 : {2'b00, div_rem0};
            res       <= 25'd0;
            divisor   <= i_b_sig;
            radicand  <= sq_rad0;
        end else if (running) begin
            rem      <= step_rem;
            res      <= {res[23:0], step_bit};
            radicand <= {radicand[47:0], 2'b00};
            count    <= count + 5'd1;
            if (count == 5'd24) begin
                running <= 1'b0;
                done    <= 1'b1;
            end
        end
    end

    assign o_busy = i_valid & ~done;
    assign o_sign = res_sign;
    assign o_exp  = res_exp;
    // The divide remainder is kept shifted left once, which doesn't change
    // whether it is zero.
    assign o_sig  = {res, |rem};

endmodule

`default_nettype wire
