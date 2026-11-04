`default_nettype none

// TEST ONLY -- not synthesizable, never submit. See tools/hart_diff/README.md.
// Phase 6 alu ports around the phase 5 alu (alu_i in rv32i_alu.v). RV32M
// uses Verilog * / % and takes MUL_LAT/DIV_LAT cycles (0 = combinational).
`ifndef MUL_LAT
`define MUL_LAT 4
`endif
`ifndef DIV_LAT
`define DIV_LAT 33
`endif
module alu #(
    parameter MUL_LAT = `MUL_LAT,
    parameter DIV_LAT = `DIV_LAT
) (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire [ 2:0] i_opsel,
    input  wire        i_sub,
    input  wire        i_unsigned,
    input  wire        i_arith,
    input  wire        i_mext,
    input  wire        i_advance,
    input  wire [31:0] i_op1,
    input  wire [31:0] i_op2,
    output wire [31:0] o_result,
    output wire        o_eq,
    output wire        o_slt,
    output wire        o_busy
);
    wire [31:0] base;
    alu_i inner (.i_opsel(i_opsel), .i_sub(i_sub), .i_unsigned(i_unsigned),
                 .i_arith(i_arith), .i_op1(i_op1), .i_op2(i_op2),
                 .o_result(base), .o_eq(o_eq), .o_slt(o_slt));

    wire signed [63:0] s1 = {{32{i_op1[31]}}, i_op1};
    wire signed [63:0] s2 = {{32{i_op2[31]}}, i_op2};
    wire        [63:0] u1 = {32'd0, i_op1};
    wire        [63:0] u2 = {32'd0, i_op2};
    wire [63:0] pss = s1 * s2;
    wire [63:0] psu = s1 * $signed(u2);
    wire [63:0] puu = u1 * u2;
    wire ovf = i_op1 == 32'h80000000 && i_op2 == 32'hFFFFFFFF;
    wire z = i_op2 == 0;
    wire signed [31:0] sq = $signed(i_op1) / $signed(i_op2);
    wire signed [31:0] sr = $signed(i_op1) % $signed(i_op2);
    reg  [31:0] m;
    always @(*) begin
        case (i_opsel)
            3'd0: m = pss[31:0];
            3'd1: m = pss[63:32];
            3'd2: m = psu[63:32];
            3'd3: m = puu[63:32];
            3'd4: m = z ? 32'hFFFFFFFF : ovf ? 32'h80000000 : sq;
            3'd5: m = z ? 32'hFFFFFFFF : i_op1 / i_op2;
            3'd6: m = z ? i_op1 : ovf ? 32'd0 : sr;
            default: m = z ? i_op1 : i_op1 % i_op2;
        endcase
    end

    integer cnt;
    reg     done;
    wire [31:0] lat = i_opsel[2] ? DIV_LAT : MUL_LAT;
    always @(posedge i_clk) begin
        if (i_rst) begin
            cnt <= 0; done <= 0;
        end else if (i_advance) begin
            cnt <= 0; done <= 0;
        end else if (i_mext && !done) begin
            cnt <= cnt + 1;
            if (cnt + 1 >= lat) done <= 1;
        end
    end
    assign o_busy   = i_mext && !done && lat > 0;
    assign o_result = i_mext ? ((done || lat == 0) ? m : 32'hBAD0BAD0) : base;
endmodule

`default_nettype wire
