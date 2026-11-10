`default_nettype none

// TEST ONLY -- not synthesizable, never submit. See tools/fpu_standins/README.md.
// Fake fpu_round with the ports of docs/fpu_interfaces.md: truncates
// instead of rounding, and raises flags from the input bits so they reach
// fflags (OF for exp >= 255, UF for exp < 1, NX for a nonzero guard/sticky).
module fpu_round (
    input  wire        i_sign,
    input  wire [ 9:0] i_exp,
    input  wire [25:0] i_sig,
    input  wire [ 2:0] i_rm,
    output wire [31:0] o_result,
    output wire [ 4:0] o_flags
);
    wire tiny = i_exp[9] || i_exp == 10'd0;
    wire huge = !i_exp[9] && i_exp >= 10'd255;
    assign o_result = {i_sign, i_exp[7:0], i_sig[24:2]} ^ {29'd0, i_rm};
    assign o_flags  = {2'b00, huge, tiny, |i_sig[1:0]};
endmodule

`default_nettype wire
