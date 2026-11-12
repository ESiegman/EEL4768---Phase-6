`default_nettype none

// The arithmetic logic unit (ALU) is responsible for performing the core
// calculations of the processor. It takes two 32-bit operands and outputs
// a 32 bit result based on the selection operation - addition, comparison,
// shift, or logical operation. Every RV32I operation is purely
// combinational. In phase 6 the ALU also performs the RV32M multiply and
// divide instructions, which may be combinational or take several cycles
// (see `documentation/phase_6.pdf`).
module alu (
    // Global clock and synchronous active-high reset (used by an iterative
    // multiplier or divider).
    input  wire        i_clk,
    input  wire        i_rst,
    // Major operation selection.
    // 3'b000: addition/subtraction if `i_sub` asserted
    // 3'b001: shift left logical
    // 3'b010: set less than
    // 3'b011: set less than unsigned
    // 3'b100: exclusive or
    // 3'b101: shift right logical/arithmetic if `i_arith` asserted
    // 3'b110: or
    // 3'b111: and
    // When `i_mext` is asserted, this is the M instruction's funct3 instead:
    // 3'b000: mul    - low 32 bits of op1 * op2
    // 3'b001: mulh   - high 32 bits of signed op1 * signed op2
    // 3'b010: mulhsu - high 32 bits of signed op1 * unsigned op2
    // 3'b011: mulhu  - high 32 bits of unsigned op1 * unsigned op2
    // 3'b100: div    - signed op1 / op2, rounded toward zero
    // 3'b101: divu   - unsigned op1 / op2
    // 3'b110: rem    - signed remainder, same sign as op1
    // 3'b111: remu   - unsigned remainder
    input  wire [ 2:0] i_opsel,
    // When asserted, addition operations should subtract instead.
    // This is only used for `i_opsel == 3'b000` (addition/subtraction).
    input  wire        i_sub,
    // When asserted, comparison operations should be treated as unsigned.
    // This is only used for branch comparisons, as the set less than unsigned
    // mode is already specified by `i_opsel`. For branch operations, the ALU
    // result is not used, only the comparison results.
    input  wire        i_unsigned,
    // When asserted, right shifts should be treated as arithmetic instead of
    // logical. This is only used for `i_opsel == 3'b101` (shift right).
    input  wire        i_arith,
    // Asserted while an RV32M instruction is in the execute stage.
    input  wire        i_mext,
    // Asserted when the instruction in the execute stage moves on at the next
    // rising edge. A finished M result is held until then.
    input  wire        i_advance,
    // First 32-bit input operand.
    input  wire [31:0] i_op1,
    // Second 32-bit input operand.
    input  wire [31:0] i_op2,
    // 32-bit output result. Any carry out (from addition) should be ignored.
    output wire [31:0] o_result,
    // Equality result. This is used downstream to determine if a
    // branch should be taken.
    output wire        o_eq,
    // Set less than result. This is used downstream to determine if a
    // branch should be taken.
    output wire        o_slt,
    // Asserted while an M operation is still running; the instruction must
    // stay in the execute stage until it drops.
    output wire        o_busy
);

    // Your implementation goes under here
    // ------------------------------------

    wire [31:0] add_op2;
    wire [31:0] add_propagate;
    wire [31:0] add_generate;
    wire [31:0] add_group_p1;
    wire [31:0] add_group_g1;
    wire [31:0] add_group_p2;
    wire [31:0] add_group_g2;
    wire [31:0] add_group_p4;
    wire [31:0] add_group_g4;
    wire [31:0] add_group_p8;
    wire [31:0] add_group_g8;
    wire [31:0] add_group_p16;
    wire [31:0] add_group_g16;
    wire [31:0] carry_into;
    wire [31:0] add_sub_result;

    assign add_op2       = i_op2 ^ {32{i_sub}};
    assign add_propagate = i_op1 ^ add_op2;
    assign add_generate  = i_op1 & add_op2;

    assign add_group_g1 = add_generate |
                          (add_propagate & {add_generate[30:0], 1'b0});
    assign add_group_p1 = add_propagate &
                          {add_propagate[30:0], 1'b1};

    assign add_group_g2 = add_group_g1 |
                          (add_group_p1 & {add_group_g1[29:0], 2'b00});
    assign add_group_p2 = add_group_p1 &
                          {add_group_p1[29:0], 2'b11};

    assign add_group_g4 = add_group_g2 |
                          (add_group_p2 & {add_group_g2[27:0], 4'b0000});
    assign add_group_p4 = add_group_p2 &
                          {add_group_p2[27:0], 4'b1111};

    assign add_group_g8 = add_group_g4 |
                          (add_group_p4 & {add_group_g4[23:0], 8'b00000000});
    assign add_group_p8 = add_group_p4 &
                          {add_group_p4[23:0], 8'b11111111};

    assign add_group_g16 = add_group_g8 |
                           (add_group_p8 & {add_group_g8[15:0], 16'b0000000000000000});
    assign add_group_p16 = add_group_p8 &
                           {add_group_p8[15:0], 16'b1111111111111111};

    assign carry_into[0] = i_sub;
    assign carry_into[31:1] = add_group_g16[30:0] |
                              (add_group_p16[30:0] & {31{i_sub}});
    assign add_sub_result = add_propagate ^ carry_into;

    wire [31:0] sll_stage1;
    wire [31:0] sll_stage2;
    wire [31:0] sll_stage4;
    wire [31:0] sll_stage8;
    wire [31:0] sll_result;

    assign sll_stage1 = i_op2[0] ? {i_op1[30:0], 1'b0} : i_op1;
    assign sll_stage2 = i_op2[1] ? {sll_stage1[29:0], 2'b00} : sll_stage1;
    assign sll_stage4 = i_op2[2] ? {sll_stage2[27:0], 4'b0000} : sll_stage2;
    assign sll_stage8 = i_op2[3] ? {sll_stage4[23:0], 8'b00000000} : sll_stage4;
    assign sll_result = i_op2[4] ? {sll_stage8[15:0], 16'b0000000000000000} : sll_stage8;

    wire        right_fill;
    wire [31:0] srx_stage1;
    wire [31:0] srx_stage2;
    wire [31:0] srx_stage4;
    wire [31:0] srx_stage8;
    wire [31:0] right_shift_result;

    assign right_fill = i_arith & i_op1[31];
    assign srx_stage1 = i_op2[0] ? {right_fill, i_op1[31:1]} : i_op1;
    assign srx_stage2 = i_op2[1] ? {{2{right_fill}}, srx_stage1[31:2]} : srx_stage1;
    assign srx_stage4 = i_op2[2] ? {{4{right_fill}}, srx_stage2[31:4]} : srx_stage2;
    assign srx_stage8 = i_op2[3] ? {{8{right_fill}}, srx_stage4[31:8]} : srx_stage4;
    assign right_shift_result = i_op2[4] ? {{16{right_fill}}, srx_stage8[31:16]} : srx_stage8;

    wire [31:0] equal_bits;
    wire [31:0] equal_group1;
    wire [31:0] equal_group2;
    wire [31:0] equal_group4;
    wire [31:0] equal_group8;
    wire [31:0] equal_group16;
    wire [31:0] upper_equal;
    wire        unsigned_less;
    wire        signed_less;

    assign equal_bits = ~(i_op1 ^ i_op2);
    assign equal_group1 = equal_bits &
                          {1'b1, equal_bits[31:1]};
    assign equal_group2 = equal_group1 &
                          {2'b11, equal_group1[31:2]};
    assign equal_group4 = equal_group2 &
                          {4'b1111, equal_group2[31:4]};
    assign equal_group8 = equal_group4 &
                          {8'b11111111, equal_group4[31:8]};
    assign equal_group16 = equal_group8 &
                           {16'b1111111111111111, equal_group8[31:16]};

    assign upper_equal = {1'b1, equal_group16[31:1]};
    assign unsigned_less = |(upper_equal & ~i_op1 & i_op2);
    assign signed_less = (i_op1[31] ^ i_op2[31]) ? i_op1[31] : unsigned_less;

    assign o_eq  = ~|(i_op1 ^ i_op2);
    assign o_slt = i_unsigned ? unsigned_less : signed_less;

    reg [31:0] result;
    always @(*) begin
        case (i_opsel)
            3'b000: result = add_sub_result;
            3'b001: result = sll_result;
            3'b010: result = {31'b0, o_slt};
            3'b011: result = {31'b0, unsigned_less};
            3'b100: result = i_op1 ^ i_op2;
            3'b101: result = right_shift_result;
            3'b110: result = i_op1 | i_op2;
            default: result = i_op1 & i_op2;
        endcase
    end

    // ------------------------------------------------------------------
    // RV32M: iterative shift-and-add multiplier and restoring divider
    // (phase_6.pdf 4.3, 5.1). Both work on unsigned magnitudes, one bit per
    // cycle, and fix the sign at the end (Figure 5).
    //
    //  * cycle 1: i_mext rises, o_busy goes high, operands are latched
    //  * cycles 2-33: 32 steps
    //  * then o_busy drops and the result is held until i_advance
    // A finished result is never restarted, so a cache freeze that keeps
    // the instruction in EX after it finishes cannot rerun it.
    // ------------------------------------------------------------------
    wire m_is_div = i_opsel[2];
    // Which operands are signed: mulh, mulhsu, div, rem read rs1 as signed;
    // mulh, div, rem read rs2 as signed. mul's low half is sign-agnostic.
    wire m_op1_signed = (i_opsel == 3'b001) | (i_opsel == 3'b010) |
                        (i_opsel == 3'b100) | (i_opsel == 3'b110);
    wire m_op2_signed = (i_opsel == 3'b001) | (i_opsel == 3'b100) |
                        (i_opsel == 3'b110);
    wire m_neg1 = m_op1_signed & i_op1[31];
    wire m_neg2 = m_op2_signed & i_op2[31];
    // Two's complement magnitude. -2^31 stays 0x80000000, read as unsigned.
    wire [31:0] m_mag1 = m_neg1 ? (~i_op1 + 32'd1) : i_op1;
    wire [31:0] m_mag2 = m_neg2 ? (~i_op2 + 32'd1) : i_op2;
    wire        m_div_zero = (i_op2 == 32'd0);

    reg         m_running;
    reg         m_done;
    reg  [ 4:0] m_count;      // steps taken, 0..31
    reg         m_div;        // latched: divide (1) or multiply (0)
    reg  [ 1:0] m_sel;        // latched funct3[1:0]
    reg         m_neg_main;   // negate the product / quotient
    reg         m_neg_rem;    // negate the remainder
    // Multiply: the multiplicand shifts left, the multiplier shifts right.
    reg  [63:0] m_mcand;
    reg  [31:0] m_mplier;
    reg  [63:0] m_prod;
    // Divide: {remainder, quotient} shift left together; the dividend
    // starts in the quotient register and is shifted out as quotient bits
    // are shifted in.
    reg  [31:0] m_rem;
    reg  [31:0] m_quo;
    reg  [31:0] m_dvsr;

    // One multiply step: add the multiplicand if the low multiplier bit is 1.
    wire [63:0] m_prod_next = m_mplier[0] ? (m_prod + m_mcand) : m_prod;

    // One restoring-division step: bring down the next dividend bit, and
    // subtract the divisor if the partial remainder is at least the divisor.
    wire [32:0] m_rem_shift = {m_rem, m_quo[31]};
    wire        m_rem_ge    = (m_rem_shift >= {1'b0, m_dvsr});
    wire [32:0] m_rem_sub   = m_rem_shift - {1'b0, m_dvsr};
    wire [31:0] m_rem_next  = m_rem_ge ? m_rem_sub[31:0] : m_rem_shift[31:0];

    wire        m_start = i_mext & ~m_running & ~m_done;

    always @(posedge i_clk) begin
        if (i_rst | i_advance | ~i_mext) begin
            m_running <= 1'b0;
            m_done    <= 1'b0;
            m_count   <= 5'd0;
        end else if (m_start) begin
            m_running  <= 1'b1;
            m_count    <= 5'd0;
            m_div      <= m_is_div;
            m_sel      <= i_opsel[1:0];
            // Divide by zero: the unsigned divider already gives an all-ones
            // quotient, so the quotient is never negated (x/0 = -1 for any
            // sign of x). The remainder takes the dividend's sign.
            m_neg_main <= m_is_div ? ((m_neg1 ^ m_neg2) & ~m_div_zero) : (m_neg1 ^ m_neg2);
            m_neg_rem  <= m_neg1;
            m_mcand    <= {32'd0, m_mag1};
            m_mplier   <= m_mag2;
            m_prod     <= 64'd0;
            m_rem      <= 32'd0;
            m_quo      <= m_mag1;
            m_dvsr     <= m_mag2;
        end else if (m_running) begin
            m_count  <= m_count + 5'd1;
            m_prod   <= m_prod_next;
            m_mcand  <= {m_mcand[62:0], 1'b0};
            m_mplier <= {1'b0, m_mplier[31:1]};
            m_rem    <= m_rem_next;
            m_quo    <= {m_quo[30:0], m_rem_ge};
            if (m_count == 5'd31) begin
                m_running <= 1'b0;
                m_done    <= 1'b1;
            end
        end
    end

    // Sign correction and result selection.
    wire [63:0] m_prod_fix = m_neg_main ? (~m_prod + 64'd1) : m_prod;
    wire [31:0] m_quo_fix  = m_neg_main ? (~m_quo + 32'd1) : m_quo;
    wire [31:0] m_rem_fix  = m_neg_rem  ? (~m_rem + 32'd1) : m_rem;
    // mul -> low half; mulh/mulhsu/mulhu -> high half; div[u] -> quotient;
    // rem[u] -> remainder.
    wire [31:0] m_result = m_div ? (m_sel[1] ? m_rem_fix : m_quo_fix) :
                                   ((m_sel == 2'b00) ? m_prod_fix[31:0] : m_prod_fix[63:32]);

    assign o_busy   = i_mext & ~m_done;
    assign o_result = i_mext ? m_result : result;

endmodule

`default_nettype wire
