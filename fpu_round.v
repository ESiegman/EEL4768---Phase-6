`default_nettype none

// Shared binary32 round/pack stage. Exponents are signed and biased by 127;
// sig[25:2] is the significand, sig[1] guard, sig[0] sticky.
module fpu_round (
    input  wire        i_sign,
    input  wire [ 9:0] i_exp,
    input  wire [25:0] i_sig,
    input  wire [ 2:0] i_rm,
    output wire [31:0] o_result,
    output wire [ 4:0] o_flags
);
    wire tiny_exp = i_exp[9] | (i_exp == 10'd0);
    wire [9:0] distance = tiny_exp ? 10'd1 - i_exp : 10'd0;

    // Right barrel shifter with jamming at every stage. Even shifts larger
    // than the entire significand preserve a nonzero tail in sticky.
    wire [25:0] s1  = distance[0] ? {1'b0, i_sig[25:2], |i_sig[1:0]} : i_sig;
    wire [25:0] s2  = distance[1] ? {2'd0, s1[25:3], |s1[2:0]} : s1;
    wire [25:0] s4  = distance[2] ? {4'd0, s2[25:5], |s2[4:0]} : s2;
    wire [25:0] s8  = distance[3] ? {8'd0, s4[25:9], |s4[8:0]} : s4;
    wire [25:0] s16 = distance[4] ? {16'd0, s8[25:17], |s8[16:0]} : s8;
    wire [25:0] sig = (|distance[9:5]) ? {25'd0, |s16} : s16;
    wire lost = |sig[1:0];
    wire increment = (i_rm == 3'd0) ? (sig[1] & (sig[0] | sig[2])) :
                     (i_rm == 3'd2) ? (i_sign & lost) :
                     (i_rm == 3'd3) ? (~i_sign & lost) :
                     (i_rm == 3'd4) ? sig[1] : 1'b0;
    wire [24:0] rounded = {1'b0, sig[25:2]} + {24'd0, increment};
    wire [9:0] exp = tiny_exp ? {9'd0, rounded[23]} :
                              i_exp + {9'd0, rounded[24]};
    wire overflow = ~exp[9] & (exp >= 10'd255);
    wire to_inf = (i_rm == 3'd0) | (i_rm == 3'd4) |
                  ((i_rm == 3'd2) & i_sign) |
                  ((i_rm == 3'd3) & ~i_sign);

    // IEEE tininess-after-rounding uses precision rounding with an
    // unbounded exponent, before the extra loss from denormalization.
    wire original_lost = |i_sig[1:0];
    wire original_inc = (i_rm == 3'd0) ? (i_sig[1] & (i_sig[0] | i_sig[2])) :
                        (i_rm == 3'd2) ? (i_sign & original_lost) :
                        (i_rm == 3'd3) ? (~i_sign & original_lost) :
                        (i_rm == 3'd4) ? i_sig[1] : 1'b0;
    wire [24:0] original_round = {1'b0, i_sig[25:2]} + {24'd0, original_inc};
    wire tiny = i_exp[9] | ((i_exp == 10'd0) & ~original_round[24]);
    wire nonzero = |i_sig;

    assign o_result = ~nonzero ? {i_sign, 31'd0} :
                      overflow ? {i_sign, (to_inf ? 31'h7F800000 : 31'h7F7FFFFF)} :
                                 {i_sign, exp[7:0], rounded[22:0]};
    assign o_flags = nonzero ? {2'b00, overflow, (tiny & lost), (overflow | lost)} : 5'd0;
endmodule

`default_nettype wire
