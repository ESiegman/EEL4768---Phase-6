`default_nettype none

// Finite binary32 <-> signed/unsigned RV32 conversions. The top handles
// NaN/infinity; integer-to-float is rounded by the shared fpu_round.
module fpu_cvt (
    input  wire        i_unsigned,
    input  wire [ 2:0] i_rm,
    input  wire        i_a_sign,
    input  wire [ 9:0] i_a_exp,
    input  wire [23:0] i_a_sig,
    output wire [31:0] o_f2i_result,
    output wire [ 4:0] o_f2i_flags,
    input  wire [31:0] i_int,
    output wire        o_i2f_sign,
    output wire [ 9:0] o_i2f_exp,
    output wire [25:0] o_i2f_sig
);
    // Place the binary point above guard/sticky when exp=158 (2^31).
    // Larger nonzero inputs are out of range for both target formats.
    wire too_large = ~i_a_exp[9] & (i_a_exp > 10'd158);
    wire [9:0] distance = too_large ? 10'd0 : 10'd158 - i_a_exp;
    wire [33:0] s0  = {i_a_sig, 10'd0};
    wire [33:0] s1  = distance[0] ? {1'b0, s0[33:2], |s0[1:0]} : s0;
    wire [33:0] s2  = distance[1] ? {2'd0, s1[33:3], |s1[2:0]} : s1;
    wire [33:0] s4  = distance[2] ? {4'd0, s2[33:5], |s2[4:0]} : s2;
    wire [33:0] s8  = distance[3] ? {8'd0, s4[33:9], |s4[8:0]} : s4;
    wire [33:0] s16 = distance[4] ? {16'd0, s8[33:17], |s8[16:0]} : s8;
    wire [33:0] s32 = distance[5] ? {32'd0, s16[33], |s16[32:0]} : s16;
    wire [33:0] sig = (|distance[9:6]) ? {33'd0, |s32} : s32;
    wire lost = |sig[1:0];
    wire increment = (i_rm == 3'd0) ? (sig[1] & (sig[0] | sig[2])) :
                     (i_rm == 3'd2) ? (i_a_sign & lost) :
                     (i_rm == 3'd3) ? (~i_a_sign & lost) :
                     (i_rm == 3'd4) ? sig[1] : 1'b0;
    wire [32:0] magnitude = {1'b0, sig[33:2]} + {32'd0, increment};
    wire [32:0] limit = i_unsigned ? 33'h0FFFFFFFF :
                       i_a_sign ? 33'h080000000 : 33'h07FFFFFFF;
    wire invalid = (|i_a_sig) & (too_large | (magnitude > limit) |
                                (i_unsigned & i_a_sign & (|magnitude)));
    wire [31:0] clipped = i_unsigned ? (i_a_sign ? 32'd0 : 32'hFFFFFFFF) :
                                     (i_a_sign ? 32'h80000000 : 32'h7FFFFFFF);
    assign o_f2i_result = invalid ? clipped :
                         i_a_sign ? (~magnitude[31:0] + 32'd1) : magnitude[31:0];
    assign o_f2i_flags = {invalid, 3'd0, (lost & ~invalid)};

    // Magnitude and leading-zero barrel normalizer. INT_MIN is handled
    // naturally as the unsigned magnitude 0x80000000.
    assign o_i2f_sign = ~i_unsigned & i_int[31];
    wire [31:0] absolute = o_i2f_sign ? (~i_int + 32'd1) : i_int;
    wire z16 = ~(|absolute[31:16]);
    wire [31:0] n16 = z16 ? (absolute << 16) : absolute;
    wire z8 = ~(|n16[31:24]);
    wire [31:0] n8 = z8 ? (n16 << 8) : n16;
    wire z4 = ~(|n8[31:28]);
    wire [31:0] n4 = z4 ? (n8 << 4) : n8;
    wire z2 = ~(|n4[31:30]);
    wire [31:0] n2 = z2 ? (n4 << 2) : n4;
    wire z1 = ~n2[31];
    wire [31:0] normalized = z1 ? (n2 << 1) : n2;
    wire [4:0] leading_zeros = {z16, z8, z4, z2, z1};
    assign o_i2f_exp = (|absolute) ? 10'd158 - {5'd0, leading_zeros} : 10'd0;
    assign o_i2f_sig = {normalized[31:7], |normalized[6:0]};
endmodule

`default_nettype wire
