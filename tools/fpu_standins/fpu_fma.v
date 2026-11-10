`default_nettype none

// TEST ONLY -- not synthesizable, never submit. See tools/fpu_standins/README.md.
// Fake fpu_fma with the ports and handshake of docs/fpu_interfaces.md. The
// result is deterministic nonsense in the rounder's input format; busy,
// latency, hold and restart behave per the contract. LAT = 0 is
// combinational.
module fpu_fma #(
    parameter LAT = 3
) (
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

    wire [25:0] mix = {i_a_sig ^ i_b_sig ^ (i_mul_only ? 24'd0 : i_c_sig), 2'b01};
    assign o_sign = i_a_sign ^ i_b_sign;
    assign o_exp  = i_a_exp + i_b_exp - 10'd127 + {7'd0, i_rm};
    assign o_sig  = o_busy ? 26'h2BADBAD : (mix | 26'h2000000);
endmodule

`default_nettype wire
