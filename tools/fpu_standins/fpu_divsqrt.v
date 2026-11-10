`default_nettype none

// TEST ONLY -- not synthesizable, never submit. See tools/fpu_standins/README.md.
// Fake fpu_divsqrt with the ports and handshake of docs/fpu_interfaces.md.
// Deterministic nonsense results; busy, latency (LAT cycles), hold and
// restart behave per the contract.
module fpu_divsqrt #(
    parameter LAT = 12
) (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_valid,
    input  wire        i_advance,
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
    integer cnt;
    reg     done;
    always @(posedge i_clk) begin
        if (i_rst || i_advance) begin
            cnt  <= 0;
            done <= 0;
        end else if (i_valid && !done) begin
            cnt <= cnt + 1;
            if (cnt + 1 >= LAT) done <= 1;
        end
    end
    assign o_busy = i_valid && !done && LAT > 0;

    assign o_sign = i_sqrt ? 1'b0 : (i_a_sign ^ i_b_sign);
    assign o_exp  = i_sqrt ? i_a_exp : (i_a_exp - i_b_exp + 10'd127);
    assign o_sig  = o_busy ? 26'h2BADBAD : {1'b1, i_a_sig[22:0] ^ (i_sqrt ? 23'd0 : i_b_sig[22:0]), 2'b11};
endmodule

`default_nettype wire
