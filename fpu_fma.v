`default_nettype none

// One combinational a*b+c datapath for add/subtract, multiply and all four
// fused operations. Inputs are finite normalized significands (or zero).
// The top applies instruction sign changes; only fpu_round rounds.
module fpu_fma (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_valid,
    input  wire        i_advance,
    input  wire        i_mul_only,
    input  wire [ 2:0] i_rm,
    input  wire        i_a_sign,
    input  wire [ 9:0] i_a_exp,
    input  wire [23:0] i_a_sig,
    input  wire        i_b_sign,
    input  wire [ 9:0] i_b_exp,
    input  wire [23:0] i_b_sig,
    input  wire        i_c_sign,
    input  wire [ 9:0] i_c_exp,
    input  wire [23:0] i_c_sig,
    output wire        o_busy,
    output wire        o_sign,
    output wire [ 9:0] o_exp,
    output wire [25:0] o_sig
);
    // Fully unrolled shift-and-add 24x24 multiplier, using no signal *.
    wire [47:0] partial [0:24];
    wire [47:0] multiplicand [0:24];
    assign partial[0] = 48'd0;
    assign multiplicand[0] = {24'd0, i_a_sig};
    genvar k;
    generate
        for (k = 0; k < 24; k = k + 1) begin : g_product
            assign partial[k+1] = partial[k] + (i_b_sig[k] ? multiplicand[k] : 48'd0);
            assign multiplicand[k+1] = multiplicand[k] << 1;
        end
    endgenerate
    wire [47:0] product = partial[24];
    wire [47:0] p_sig = product[47] ? product : (product << 1);
    wire [9:0] p_exp = i_a_exp + i_b_exp - 10'd127 + {9'd0, product[47]};
    wire [9:0] c_exp = i_c_exp;
    wire p_sign = i_a_sign ^ i_b_sign;
    wire c_sign = i_mul_only ? p_sign : i_c_sign;
    wire p_zero = ~(|product);
    wire c_zero = i_mul_only | ~(|i_c_sig);
    // Invert the sign bit to compare two's-complement exponents unsigned.
    wire p_high = c_zero | (~p_zero & ({~p_exp[9], p_exp[8:0]} >=
                                      {~c_exp[9], c_exp[8:0]}));
    wire [9:0] common_exp = p_high ? p_exp : c_exp;
    wire [9:0] distance = (p_zero | c_zero) ? 10'd0 :
                          p_high ? p_exp - c_exp : c_exp - p_exp;

    // Leading bits start at bit 75, with a carry bit at 76. Retain the
    // entire 48-bit product and 28 trailing places before alignment. Close
    // cancellation is exact; distant tails are jammed far below guard.
    wire [76:0] p = {1'b0, p_sig, 28'd0};
    wire [76:0] c = c_zero ? 77'd0 : {1'b0, i_c_sig, 52'd0};
    wire [76:0] high = p_high ? p : c;
    wire [76:0] low  = p_high ? c : p;
    wire [76:0] s1  = distance[0] ? {1'd0, low[76:2], |low[1:0]} : low;
    wire [76:0] s2  = distance[1] ? {2'd0, s1[76:3], |s1[2:0]} : s1;
    wire [76:0] s4  = distance[2] ? {4'd0, s2[76:5], |s2[4:0]} : s2;
    wire [76:0] s8  = distance[3] ? {8'd0, s4[76:9], |s4[8:0]} : s4;
    wire [76:0] s16 = distance[4] ? {16'd0, s8[76:17], |s8[16:0]} : s8;
    wire [76:0] s32 = distance[5] ? {32'd0, s16[76:33], |s16[32:0]} : s16;
    wire [76:0] s64 = distance[6] ? {64'd0, s32[76:65], |s32[64:0]} : s32;
    wire [76:0] aligned = (|distance[9:7]) ? {76'd0, |s64} : s64;
    wire high_sign = p_high ? p_sign : c_sign;
    wire low_sign  = p_high ? c_sign : p_sign;
    wire high_magnitude = high >= aligned;
    wire [76:0] sum = (high_sign == low_sign) ? high + aligned :
                     high_magnitude ? high - aligned : aligned - high;
    wire sum_sign = high_magnitude ? high_sign : low_sign;
    wire zero_sign = (p_sign == c_sign) ? p_sign : (i_rm == 3'd2);
    assign o_sign = (|sum) ? sum_sign : zero_sign;

    // Carry normalization, followed by a leading-zero barrel normalizer
    // over the whole sum, including the product's low cancellation bits.
    wire [76:0] n0 = sum[76] ? {1'b0, sum[76:2], |sum[1:0]} : sum;
    wire z64 = ~(|n0[75:12]);
    wire [76:0] n64 = z64 ? (n0 << 64) : n0;
    wire z32 = ~(|n64[75:44]);
    wire [76:0] n32 = z32 ? (n64 << 32) : n64;
    wire z16 = ~(|n32[75:60]);
    wire [76:0] n16 = z16 ? (n32 << 16) : n32;
    wire z8 = ~(|n16[75:68]);
    wire [76:0] n8 = z8 ? (n16 << 8) : n16;
    wire z4 = ~(|n8[75:72]);
    wire [76:0] n4 = z4 ? (n8 << 4) : n8;
    wire z2 = ~(|n4[75:74]);
    wire [76:0] n2 = z2 ? (n4 << 2) : n4;
    wire z1 = ~n2[75];
    wire [76:0] normalized = z1 ? (n2 << 1) : n2;
    wire [6:0] leading_zeros = {z64, z32, z16, z8, z4, z2, z1};
    assign o_exp = (|sum) ? common_exp + {9'd0, sum[76]} - {3'd0, leading_zeros} : 10'd0;
    assign o_sig = {normalized[75:51], |normalized[50:0]};
    assign o_busy = 1'b0;
endmodule

`default_nettype wire
