`default_nettype none

// TEST ONLY -- not synthesizable, never submit. See tools/fpu_standins/README.md.
// Fake fpu_cvt with the ports of docs/fpu_interfaces.md: combinational,
// deterministic nonsense results and flags.
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
    assign o_f2i_result = {i_a_sign, i_a_exp[6:0], i_a_sig} ^ {29'd0, i_rm};
    assign o_f2i_flags  = i_unsigned ? 5'b10000 : {4'b0000, i_a_sig[0]};
    assign o_i2f_sign   = i_unsigned ? 1'b0 : i_int[31];
    assign o_i2f_exp    = 10'd150;
    assign o_i2f_sig    = {1'b1, i_int[22:0], 2'b00};
endmodule

`default_nettype wire
