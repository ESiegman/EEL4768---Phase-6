`timescale 1ns / 1ps
`default_nettype none

// i_unsigned selects signed vs unsigned for o_slt and for the opsel 010
// result. opsel 011 is set less than unsigned per the alu.v port comment,
// so its result is always an unsigned compare regardless of i_unsigned
module alu_tb;

    reg  [ 2:0] opsel;
    reg         sub;
    reg         is_unsigned;
    reg         arith;
    reg  [31:0] op1;
    reg  [31:0] op2;

    // phase 6: clock/reset and the RV32M handshake
    reg         clk;
    reg         rst;
    reg         mext;
    reg         advance;

    wire [31:0] result;
    wire        eq;
    wire        slt;
    wire        busy;

    integer passed;
    integer failed;

    localparam [2:0] OP_ADD  = 3'b000;
    localparam [2:0] OP_SLL  = 3'b001;
    localparam [2:0] OP_SLT  = 3'b010;
    localparam [2:0] OP_SLTU = 3'b011;
    localparam [2:0] OP_XOR  = 3'b100;
    localparam [2:0] OP_SRL  = 3'b101;
    localparam [2:0] OP_OR   = 3'b110;
    localparam [2:0] OP_AND  = 3'b111;

    alu dut (
        .i_clk      (clk),
        .i_rst      (rst),
        .i_mext     (mext),
        .i_advance  (advance),
        .o_busy     (busy),
        .i_opsel    (opsel),
        .i_sub      (sub),
        .i_unsigned (is_unsigned),
        .i_arith    (arith),
        .i_op1      (op1),
        .i_op2      (op2),
        .o_result   (result),
        .o_eq       (eq),
        .o_slt      (slt)
    );

    // one comparison. === rather than ==, so an undriven output fails here
    // instead of quietly comparing unknown and returning unknown
    task check;
        input [511:0] label;   // 64 chars; a wider literal loses its LEADING
        input [  2:0] t_opsel; // characters silently, so size generously
        input         t_sub;
        input         t_unsigned;
        input         t_arith;
        input [ 31:0] t_op1;
        input [ 31:0] t_op2;
        input [ 31:0] want_result;
        input         want_eq;
        input         want_slt;
        begin
            opsel       = t_opsel;
            sub         = t_sub;
            is_unsigned = t_unsigned;
            arith       = t_arith;
            op1         = t_op1;
            op2         = t_op2;
            #1;  // combinational, one step is enough to settle

            if (result === want_result && eq === want_eq && slt === want_slt && busy === 1'b0) begin
                passed = passed + 1;
                $display("[PASS] %0s", label);
            end else begin
                failed = failed + 1;
                $display("[FAIL] %0s", label);
                $display("         opsel=%b sub=%b unsigned=%b arith=%b op1=%h op2=%h",
                         t_opsel, t_sub, t_unsigned, t_arith, t_op1, t_op2);
                $display("         result=%h (want %h)  eq=%b (want %b)  slt=%b (want %b)  busy=%b (want 0)",
                         result, want_result, eq, want_eq, slt, want_slt, busy);
            end
        end
    endtask

    // one shift vector, checked against the model rather than a hand-written
    // literal. used by the sweep over all 32 shift amounts below.
    task shift_case;
        input [  2:0] t_opsel;
        input         t_arith;
        input [ 31:0] t_op1;
        input [ 31:0] t_op2;
        reg   [ 31:0] want;
        begin
            opsel = t_opsel; sub = 1'b0; is_unsigned = 1'b0;
            arith = t_arith; op1 = t_op1; op2 = t_op2;
            #1;
            want = model_result(t_opsel, 1'b0, 1'b0, t_arith, t_op1, t_op2);
            if (result === want && eq === (t_op1 == t_op2)
                                && slt === model_lt(1'b0, t_op1, t_op2))
                passed = passed + 1;
            else begin
                failed = failed + 1;
                $display("[FAIL] shift sweep: opsel=%b arith=%b op1=%h shamt=%0d",
                         t_opsel, t_arith, t_op1, t_op2[4:0]);
                $display("         result=%h (want %h)", result, want);
            end
        end
    endtask

    // reference model, written from the spec rather than from alu.v, which
    // has to build the same operations out of constant shifts and gates

    // signedness comes from i_unsigned, except opsel 011 which is always unsigned
    function model_lt;
        input        m_unsigned;
        input [31:0] a;
        input [31:0] b;
        begin
            if (m_unsigned) model_lt = (a < b);
            else            model_lt = ($signed(a) < $signed(b));
        end
    endfunction

    function [31:0] model_result;
        input [  2:0] m_opsel;
        input         m_sub;
        input         m_unsigned;
        input         m_arith;
        input [ 31:0] m_op1;
        input [ 31:0] m_op2;
        reg   [ 31:0] value;
        reg signed [31:0] signed_op1;
        begin
            // the shift must stay an if/else on a signed intermediate: as a
            // ?: the unsigned else-branch makes the whole expression
            // unsigned, undoing $signed and turning sra into srl
            signed_op1 = m_op1;
            case (m_opsel)
                OP_ADD:  value = m_sub ? (m_op1 - m_op2) : (m_op1 + m_op2);
                OP_SLL:  value = m_op1 << m_op2[4:0];
                OP_SLT:  value = model_lt(m_unsigned, m_op1, m_op2) ? 32'd1 : 32'd0;
                OP_SLTU: value = model_lt(1'b1,       m_op1, m_op2) ? 32'd1 : 32'd0;
                OP_XOR:  value = m_op1 ^ m_op2;
                OP_SRL:  if (m_arith) value = signed_op1 >>> m_op2[4:0];
                         else         value = m_op1 >> m_op2[4:0];
                OP_OR:   value = m_op1 | m_op2;
                default: value = m_op1 & m_op2;
            endcase
            model_result = value;
        end
    endfunction


    // ------------------------------------------------------------------
    // RV32M (phase_6.pdf 4.3, 5.1)
    // ------------------------------------------------------------------
    localparam [2:0] M_MUL    = 3'b000;
    localparam [2:0] M_MULH   = 3'b001;
    localparam [2:0] M_MULHSU = 3'b010;
    localparam [2:0] M_MULHU  = 3'b011;
    localparam [2:0] M_DIV    = 3'b100;
    localparam [2:0] M_DIVU   = 3'b101;
    localparam [2:0] M_REM    = 3'b110;
    localparam [2:0] M_REMU   = 3'b111;

    always #5 clk = ~clk;

    // Reference model straight from the spec table, using the simulator's
    // * / % (fine in a testbench, never in the RTL).
    function [31:0] model_m;
        input [ 2:0] f3;
        input [31:0] a;
        input [31:0] b;
        reg   [63:0] p;
        reg signed [31:0] sa, sb, sq, sr;
        begin
            // Signed quotient/remainder in their own statements: inside a
            // ?: with unsigned operands, $signed(a) / $signed(b) would be
            // evaluated unsigned.
            sa = a;
            sb = b;
            sq = 0;
            sr = 0;
            if (b != 0 && !(a == 32'h8000_0000 && b == 32'hFFFF_FFFF)) begin
                sq = sa / sb;   // Verilog truncates toward zero
                sr = sa % sb;   // and the remainder takes the dividend's sign
            end
            case (f3)
                M_MUL:    begin p = a * b; model_m = p[31:0]; end
                M_MULH:   begin p = {{32{a[31]}}, a} * {{32{b[31]}}, b}; model_m = p[63:32]; end
                M_MULHSU: begin p = {{32{a[31]}}, a} * {32'd0, b};       model_m = p[63:32]; end
                M_MULHU:  begin p = {32'd0, a} * {32'd0, b};             model_m = p[63:32]; end
                M_DIV:    model_m = (b == 0) ? 32'hFFFF_FFFF :
                                    (a == 32'h8000_0000 && b == 32'hFFFF_FFFF) ? 32'h8000_0000 : sq;
                M_DIVU:   model_m = (b == 0) ? 32'hFFFF_FFFF : a / b;
                M_REM:    model_m = (b == 0) ? a :
                                    (a == 32'h8000_0000 && b == 32'hFFFF_FFFF) ? 32'd0 : sr;
                default:  model_m = (b == 0) ? a : a % b;
            endcase
        end
    endfunction

    integer m_cycles;
    integer m_max_cycles;
    reg [31:0] m_held;
    reg        m_ok;
    reg        m_b0;

    // Run one M instruction through the handshake, the way the hart does:
    // i_mext stays high and i_advance low while o_busy is high, then
    // `freeze` extra cycles with i_advance low stand in for a cache miss
    // that keeps the finished instruction in EX, then one advance edge.
    // Checks: o_busy is high on the first cycle and drops within the time
    // limit; o_busy has no combinational path from i_advance; the result is
    // right and held through the freeze; o_busy never rises again (no
    // restart). Starts and ends just after a negedge.
    task m_case;
        input [511:0] label;
        input [  2:0] f3;
        input [ 31:0] a;
        input [ 31:0] b;
        input integer freeze;
        reg   [ 31:0] want_m;
        begin
            want_m = model_m(f3, a, b);
            m_ok   = 1'b1;
            mext = 1'b1; advance = 1'b0;
            opsel = f3; op1 = a; op2 = b;
            sub = 1'b0; is_unsigned = 1'b0; arith = 1'b0;
            #1;
            if (busy !== 1'b1) begin
                m_ok = 1'b0;
                $display("         o_busy not high on the first cycle");
            end
            m_b0 = busy; advance = 1'b1; #1;
            if (busy !== m_b0) begin
                m_ok = 1'b0;
                $display("         o_busy depends on i_advance");
            end
            advance = 1'b0;
            m_cycles = 0;
            while (busy === 1'b1 && m_cycles < 100) begin
                @(negedge clk);
                m_cycles = m_cycles + 1;
            end
            if (busy !== 1'b0) begin
                m_ok = 1'b0;
                $display("         o_busy stuck high or X after %0d cycles", m_cycles);
            end
            if (m_cycles > m_max_cycles) m_max_cycles = m_cycles;
            m_held = result;
            if (m_held !== want_m) begin
                m_ok = 1'b0;
                $display("         result=%h (want %h)", m_held, want_m);
            end
            repeat (freeze) begin
                @(negedge clk);
                if (busy !== 1'b0) begin
                    m_ok = 1'b0;
                    $display("         o_busy rose again while held (restart)");
                end
                if (result !== m_held) begin
                    m_ok = 1'b0;
                    $display("         result changed while held: %h -> %h", m_held, result);
                end
            end
            advance = 1'b1;
            @(negedge clk);
            advance = 1'b0;
            if (m_ok) passed = passed + 1;
            else begin
                failed = failed + 1;
                $display("[FAIL] %0s: f3=%b op1=%h op2=%h", label, f3, a, b);
            end
        end
    endtask

    // Directed vector: print a PASS line too.
    task m_check;
        input [511:0] label;
        input [  2:0] f3;
        input [ 31:0] a;
        input [ 31:0] b;
        input [ 31:0] want_m;
        integer failures_before;
        begin
            if (model_m(f3, a, b) !== want_m) begin
                failed = failed + 1;
                $display("[FAIL] %0s: testbench model gives %h, table says %h", label, model_m(f3, a, b), want_m);
            end
            failures_before = failed;
            m_case(label, f3, a, b, 0);
            if (failed == failures_before) $display("[PASS] %0s", label);
        end
    endtask

    integer i;
    integer k;
    integer seed;
    reg [31:0] shift_op [0:4];
    reg [31:0] r_op1, r_op2, want;
    reg [ 2:0] r_opsel;
    reg        r_sub, r_uns, r_arith, want_eq, want_slt;

    initial begin
        $dumpfile("alu.vcd");
        $dumpvars(0, alu_tb);

        passed = 0;
        failed = 0;
        clk = 1'b0;
        rst = 1'b1;
        mext = 1'b0;
        advance = 1'b1;
        m_max_cycles = 0;
        $display("========== alu testbench ==========");
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;

        // add / sub, carry out is discarded so results wrap
        $display("--- add/sub ---");
        check("add: 7 + 9",                    OP_ADD, 1'b0,1'b0,1'b0, 32'd7,         32'd9,         32'd16,        1'b0,1'b1);
        check("add: 9 + 7, slt false",         OP_ADD, 1'b0,1'b0,1'b0, 32'd9,         32'd7,         32'd16,        1'b0,1'b0);
        check("add: 0 + 0, operands equal",    OP_ADD, 1'b0,1'b0,1'b0, 32'd0,         32'd0,         32'd0,         1'b1,1'b0);
        check("add: wraps past 2^32",          OP_ADD, 1'b0,1'b0,1'b0, 32'hffff_ffff, 32'd1,         32'd0,         1'b0,1'b1);
        check("add: 0x80000000 + 0x80000000 wraps to zero",
                                               OP_ADD, 1'b0,1'b0,1'b0, 32'h8000_0000, 32'h8000_0000, 32'd0,         1'b1,1'b0);
        check("add: 0x7fffffff + 1 overflows into the sign bit",
                                               OP_ADD, 1'b0,1'b0,1'b0, 32'h7fff_ffff, 32'd1,         32'h8000_0000, 1'b0,1'b0);
        check("add: i_arith ignored outside right shifts",
                                               OP_ADD, 1'b0,1'b0,1'b1, 32'd7,         32'd9,         32'd16,        1'b0,1'b1);
        // same operands as the wrap case; i_unsigned flips o_slt only
        check("add: i_unsigned changes o_slt, not the sum",
                                               OP_ADD, 1'b0,1'b1,1'b0, 32'hffff_ffff, 32'd1,         32'd0,         1'b0,1'b0);
        check("sub: 9 - 7",                    OP_ADD, 1'b1,1'b0,1'b0, 32'd9,         32'd7,         32'd2,         1'b0,1'b0);
        check("sub: 7 - 9 borrows",            OP_ADD, 1'b1,1'b0,1'b0, 32'd7,         32'd9,         32'hffff_fffe, 1'b0,1'b1);
        check("sub: x - x is zero",            OP_ADD, 1'b1,1'b0,1'b0, 32'd42,        32'd42,        32'd0,         1'b1,1'b0);
        check("sub: 0 - 1 wraps to all ones",  OP_ADD, 1'b1,1'b0,1'b0, 32'd0,         32'd1,         32'hffff_ffff, 1'b0,1'b1);
        check("sub: 0 - 0x80000000",           OP_ADD, 1'b1,1'b0,1'b0, 32'd0,         32'h8000_0000, 32'h8000_0000, 1'b0,1'b0);
        check("sub: i_unsigned changes o_slt, not the difference",
                                               OP_ADD, 1'b1,1'b1,1'b0, 32'hffff_ffff, 32'd1,         32'hffff_fffe, 1'b0,1'b0);
        check("edge: -1 + -1 = -2",            OP_ADD, 1'b0,1'b0,1'b0, 32'hffff_ffff, 32'hffff_ffff, 32'hffff_fffe, 1'b1,1'b0);

        // sll, shift amount is i_op2[4:0]
        $display("--- sll ---");
        check("sll: 1 << 0 is a no-op",        OP_SLL, 1'b0,1'b0,1'b0, 32'd1,         32'd0,         32'd1,         1'b0,1'b0);
        check("sll: 1 << 1",                   OP_SLL, 1'b0,1'b0,1'b0, 32'd1,         32'd1,         32'd2,         1'b1,1'b0);
        check("sll: 1 << 16",                  OP_SLL, 1'b0,1'b0,1'b0, 32'd1,         32'd16,        32'h0001_0000, 1'b0,1'b1);
        check("sll: 1 << 31 lands in the sign bit",
                                               OP_SLL, 1'b0,1'b0,1'b0, 32'd1,         32'd31,        32'h8000_0000, 1'b0,1'b1);
        // 32 is 6'b100000, low five bits zero, so this shifts by 0
        check("sll: only i_op2[4:0], so 32 means 0",
                                               OP_SLL, 1'b0,1'b0,1'b0, 32'd1,         32'd32,        32'd1,         1'b0,1'b1);
        // 0xffffffe1 low five bits are 00001, a shift of 1; as a signed
        // value it is -31, which is why o_slt reads 0 here
        check("sll: upper 27 bits of i_op2 ignored",
                                               OP_SLL, 1'b0,1'b0,1'b0, 32'd1,         32'hffff_ffe1, 32'd2,         1'b0,1'b0);
        check("sll: bits shifted off the top are lost",
                                               OP_SLL, 1'b0,1'b0,1'b0, 32'h8000_0001, 32'd1,         32'd2,         1'b0,1'b1);
        check("sll: 0xdeadbeef << 4",          OP_SLL, 1'b0,1'b0,1'b0, 32'hdead_beef, 32'd4,         32'headb_eef0, 1'b0,1'b1);
        check("sll: i_arith ignored on left shifts",
                                               OP_SLL, 1'b0,1'b0,1'b1, 32'h8000_0000, 32'd1,         32'd0,         1'b0,1'b1);

        // set less than. opsel 010's result follows i_unsigned, opsel 011's
        // result is always unsigned, and o_slt always follows i_unsigned.
        // all four (opsel, i_unsigned) pairings are exercised
        $display("--- set less than, signed (i_unsigned = 0) ---");
        check("slt: 7 < 9",                    OP_SLT, 1'b0,1'b0,1'b0, 32'd7,         32'd9,         32'd1,         1'b0,1'b1);
        check("slt: 9 < 7 is false",           OP_SLT, 1'b0,1'b0,1'b0, 32'd9,         32'd7,         32'd0,         1'b0,1'b0);
        check("slt: equal is not less than",   OP_SLT, 1'b0,1'b0,1'b0, 32'd42,        32'd42,        32'd0,         1'b1,1'b0);
        check("slt: -1 < 1",                   OP_SLT, 1'b0,1'b0,1'b0, 32'hffff_ffff, 32'd1,         32'd1,         1'b0,1'b1);
        check("slt: 0x80000000 is most negative",
                                               OP_SLT, 1'b0,1'b0,1'b0, 32'h8000_0000, 32'd0,         32'd1,         1'b0,1'b1);
        check("slt: 0x80000000 < 0x7fffffff",  OP_SLT, 1'b0,1'b0,1'b0, 32'h8000_0000, 32'h7fff_ffff, 32'd1,         1'b0,1'b1);
        check("slt: 0x80000000 < -1",          OP_SLT, 1'b0,1'b0,1'b0, 32'h8000_0000, 32'hffff_ffff, 32'd1,         1'b0,1'b1);
        // opsel 011 with i_unsigned deasserted: result is still unsigned,
        // but o_slt follows i_unsigned and compares signed
        check("slt: opsel 011 with i_unsigned low, result is unsigned",
                                               OP_SLTU,1'b0,1'b0,1'b0, 32'hffff_ffff, 32'd1,         32'd0,         1'b0,1'b1);
        check("slt: opsel 011 low, 0x80000000 < 0x7fffffff result false",
                                               OP_SLTU,1'b0,1'b0,1'b0, 32'h8000_0000, 32'h7fff_ffff, 32'd0,         1'b0,1'b1);

        $display("--- set less than, unsigned (i_unsigned = 1) ---");
        check("sltu: 7 < 9",                   OP_SLTU,1'b0,1'b1,1'b0, 32'd7,         32'd9,         32'd1,         1'b0,1'b1);
        // 0xffffffff is 4294967295 unsigned, so this is false
        check("sltu: 0xffffffff < 1 is false", OP_SLTU,1'b0,1'b1,1'b0, 32'hffff_ffff, 32'd1,         32'd0,         1'b0,1'b0);
        check("sltu: 1 < 0xffffffff",          OP_SLTU,1'b0,1'b1,1'b0, 32'd1,         32'hffff_ffff, 32'd1,         1'b0,1'b1);
        check("sltu: equal is not less than",  OP_SLTU,1'b0,1'b1,1'b0, 32'h8000_0000, 32'h8000_0000, 32'd0,         1'b1,1'b0);
        check("sltu: 0x80000000 < 0x7fffffff is false",
                                               OP_SLTU,1'b0,1'b1,1'b0, 32'h8000_0000, 32'h7fff_ffff, 32'd0,         1'b0,1'b0);
        check("sltu: 0x80000000 < 0xffffffff", OP_SLTU,1'b0,1'b1,1'b0, 32'h8000_0000, 32'hffff_ffff, 32'd1,         1'b0,1'b1);
        check("sltu: 0 < 0 is false",          OP_SLTU,1'b0,1'b1,1'b0, 32'd0,         32'd0,         32'd0,         1'b1,1'b0);
        // opsel 010 with i_unsigned asserted compares unsigned
        check("sltu: opsel 010 with i_unsigned high is unsigned",
                                               OP_SLT, 1'b0,1'b1,1'b0, 32'hffff_ffff, 32'd1,         32'd0,         1'b0,1'b0);
        check("sltu: opsel 010 high, 0x80000000 < 0x7fffffff is false",
                                               OP_SLT, 1'b0,1'b1,1'b0, 32'h8000_0000, 32'h7fff_ffff, 32'd0,         1'b0,1'b0);

        // xor
        $display("--- xor ---");
        check("xor: mixed bit patterns",       OP_XOR, 1'b0,1'b0,1'b0, 32'hf0f0_f0f0, 32'h0ff0_0ff0, 32'hff00_ff00, 1'b0,1'b1);
        check("xor: x ^ x is zero",            OP_XOR, 1'b0,1'b0,1'b0, 32'hdead_beef, 32'hdead_beef, 32'd0,         1'b1,1'b0);
        check("xor: x ^ 0 is x",               OP_XOR, 1'b0,1'b0,1'b0, 32'hdead_beef, 32'd0,         32'hdead_beef, 1'b0,1'b1);
        check("xor: x ^ all-ones inverts x",   OP_XOR, 1'b0,1'b0,1'b0, 32'hdead_beef, 32'hffff_ffff, 32'h2152_4110, 1'b0,1'b1);

        // srl / sra
        $display("--- srl ---");
        check("srl: 16 >> 4",                  OP_SRL, 1'b0,1'b0,1'b0, 32'd16,        32'd4,         32'd1,         1'b0,1'b0);
        check("srl: shift by 0 is a no-op",    OP_SRL, 1'b0,1'b0,1'b0, 32'hdead_beef, 32'd0,         32'hdead_beef, 1'b0,1'b1);
        check("srl: zeros shift in",           OP_SRL, 1'b0,1'b0,1'b0, 32'hffff_ffff, 32'd28,        32'h0000_000f, 1'b0,1'b1);
        check("srl: 0x80000000 >> 31",         OP_SRL, 1'b0,1'b0,1'b0, 32'h8000_0000, 32'd31,        32'd1,         1'b0,1'b1);
        check("srl: 0xdeadbeef >> 16",         OP_SRL, 1'b0,1'b0,1'b0, 32'hdead_beef, 32'd16,        32'h0000_dead, 1'b0,1'b1);
        check("srl: only i_op2[4:0], so 32 means 0",
                                               OP_SRL, 1'b0,1'b0,1'b0, 32'hffff_ffff, 32'd32,        32'hffff_ffff, 1'b0,1'b1);
        check("srl: upper 27 bits of i_op2 ignored",
                                               OP_SRL, 1'b0,1'b0,1'b0, 32'h8000_0000, 32'hffff_ffff, 32'd1,         1'b0,1'b1);
        check("srl: 0xf0000000 >> 4 zero-fills",
                                               OP_SRL, 1'b0,1'b0,1'b0, 32'hf000_0000, 32'd4,         32'h0f00_0000, 1'b0,1'b1);

        $display("--- sra ---");
        // same operand and shift as the case above, i_arith asserted
        check("sra: 0xf0000000 >> 4 replicates the sign",
                                               OP_SRL, 1'b0,1'b0,1'b1, 32'hf000_0000, 32'd4,         32'hff00_0000, 1'b0,1'b1);
        check("sra: shift by 0 is a no-op",    OP_SRL, 1'b0,1'b0,1'b1, 32'h8000_0000, 32'd0,         32'h8000_0000, 1'b0,1'b1);
        check("sra: 0x80000000 >> 1",          OP_SRL, 1'b0,1'b0,1'b1, 32'h8000_0000, 32'd1,         32'hc000_0000, 1'b0,1'b1);
        check("sra: 0x80000000 >> 31 becomes all ones",
                                               OP_SRL, 1'b0,1'b0,1'b1, 32'h8000_0000, 32'd31,        32'hffff_ffff, 1'b0,1'b1);
        check("sra: all ones stays all ones",  OP_SRL, 1'b0,1'b0,1'b1, 32'hffff_ffff, 32'd28,        32'hffff_ffff, 1'b0,1'b1);
        check("sra: 0xdeadbeef >> 16 sign-extends",
                                               OP_SRL, 1'b0,1'b0,1'b1, 32'hdead_beef, 32'd16,        32'hffff_dead, 1'b0,1'b1);
        check("sra: a positive operand is zero-filled",
                                               OP_SRL, 1'b0,1'b0,1'b1, 32'h7fff_ffff, 32'd4,         32'h07ff_ffff, 1'b0,1'b0);

        // a barrel shifter is cascaded stages of 1, 2, 4, 8 and 16, and a
        // fault in one stage only shows at amounts with that bit set, so a
        // few sampled amounts can miss a whole stage
        $display("--- shift sweep, all 32 amounts ---");
        shift_op[0] = 32'hdead_beef;  // mixed, sign bit set
        shift_op[1] = 32'h8000_0000;  // sign bit only
        shift_op[2] = 32'h0000_0001;  // low bit only
        shift_op[3] = 32'h7fff_ffff;  // positive, all but sign
        shift_op[4] = 32'hffff_ffff;  // all ones
        for (k = 0; k < 5; k = k + 1) begin
            for (i = 0; i < 32; i = i + 1) begin
                shift_case(OP_SLL, 1'b0, shift_op[k], i);  // sll
                shift_case(OP_SRL, 1'b0, shift_op[k], i);  // srl, zero fill
                shift_case(OP_SRL, 1'b1, shift_op[k], i);  // sra, sign fill
            end
        end
        $display("       5 operands x 32 amounts x 3 ops = 480 shift vectors");

        // or / and
        $display("--- or ---");
        check("or: mixed bit patterns",        OP_OR,  1'b0,1'b0,1'b0, 32'hf0f0_f0f0, 32'h0ff0_0ff0, 32'hfff0_fff0, 1'b0,1'b1);
        check("or: x | 0 is x",                OP_OR,  1'b0,1'b0,1'b0, 32'hdead_beef, 32'd0,         32'hdead_beef, 1'b0,1'b1);
        check("or: x | all-ones is all-ones",  OP_OR,  1'b0,1'b0,1'b0, 32'hdead_beef, 32'hffff_ffff, 32'hffff_ffff, 1'b0,1'b1);
        check("or: i_sub ignored outside add/sub",
                                               OP_OR,  1'b1,1'b0,1'b0, 32'hf0f0_f0f0, 32'h0ff0_0ff0, 32'hfff0_fff0, 1'b0,1'b1);

        $display("--- and ---");
        check("and: mixed bit patterns",       OP_AND, 1'b0,1'b0,1'b0, 32'hf0f0_f0f0, 32'h0ff0_0ff0, 32'h00f0_00f0, 1'b0,1'b1);
        check("and: x & 0 is 0",               OP_AND, 1'b0,1'b0,1'b0, 32'hdead_beef, 32'd0,         32'd0,         1'b0,1'b1);
        check("and: x & all-ones is x",        OP_AND, 1'b0,1'b0,1'b0, 32'hdead_beef, 32'hffff_ffff, 32'hdead_beef, 1'b0,1'b1);
        check("and: equal operands pass through",
                                               OP_AND, 1'b0,1'b0,1'b0, 32'h8000_0000, 32'h8000_0000, 32'h8000_0000, 1'b1,1'b0);

        // shift amount is 0x78 & 0x1f = 24
        $display("--- o_eq across every opsel ---");
        check("eq: add",   OP_ADD, 1'b0,1'b0,1'b0, 32'h1234_5678, 32'h1234_5678, 32'h2468_acf0, 1'b1,1'b0);
        check("eq: sll",   OP_SLL, 1'b0,1'b0,1'b0, 32'h1234_5678, 32'h1234_5678, 32'h7800_0000, 1'b1,1'b0);
        check("eq: slt",   OP_SLT, 1'b0,1'b0,1'b0, 32'h1234_5678, 32'h1234_5678, 32'd0,         1'b1,1'b0);
        check("eq: sltu",  OP_SLTU,1'b0,1'b1,1'b0, 32'h1234_5678, 32'h1234_5678, 32'd0,         1'b1,1'b0);
        check("eq: xor",   OP_XOR, 1'b0,1'b0,1'b0, 32'h1234_5678, 32'h1234_5678, 32'd0,         1'b1,1'b0);
        check("eq: srl",   OP_SRL, 1'b0,1'b0,1'b0, 32'h1234_5678, 32'h1234_5678, 32'h0000_0012, 1'b1,1'b0);
        check("eq: or",    OP_OR,  1'b0,1'b0,1'b0, 32'h1234_5678, 32'h1234_5678, 32'h1234_5678, 1'b1,1'b0);
        check("eq: and",   OP_AND, 1'b0,1'b0,1'b0, 32'h1234_5678, 32'h1234_5678, 32'h1234_5678, 1'b1,1'b0);

        // o_slt across every opsel, 1 vs 2
        $display("--- o_slt across every opsel ---");
        check("slt out: add",  OP_ADD, 1'b0,1'b0,1'b0, 32'd1, 32'd2, 32'd3, 1'b0,1'b1);
        check("slt out: sll",  OP_SLL, 1'b0,1'b0,1'b0, 32'd1, 32'd2, 32'd4, 1'b0,1'b1);
        check("slt out: slt",  OP_SLT, 1'b0,1'b0,1'b0, 32'd1, 32'd2, 32'd1, 1'b0,1'b1);
        check("slt out: sltu", OP_SLTU,1'b0,1'b1,1'b0, 32'd1, 32'd2, 32'd1, 1'b0,1'b1);
        check("slt out: xor",  OP_XOR, 1'b0,1'b0,1'b0, 32'd1, 32'd2, 32'd3, 1'b0,1'b1);
        check("slt out: srl",  OP_SRL, 1'b0,1'b0,1'b0, 32'd1, 32'd2, 32'd0, 1'b0,1'b1);
        check("slt out: or",   OP_OR,  1'b0,1'b0,1'b0, 32'd1, 32'd2, 32'd3, 1'b0,1'b1);
        check("slt out: and",  OP_AND, 1'b0,1'b0,1'b0, 32'd1, 32'd2, 32'd0, 1'b0,1'b1);

        // a fixed seed keeps the run reproducible
        $display("--- random ---");
        seed = 32'd12345;
        for (i = 0; i < 500; i = i + 1) begin
            r_op1   = $random(seed);
            r_op2   = $random(seed);
            r_opsel = $random(seed);
            r_sub   = $random(seed);
            r_uns   = $random(seed);
            r_arith = $random(seed);

            want     = model_result(r_opsel, r_sub, r_uns, r_arith, r_op1, r_op2);
            want_eq  = (r_op1 == r_op2);
            want_slt = model_lt(r_uns, r_op1, r_op2);

            opsel = r_opsel; sub = r_sub; is_unsigned = r_uns;
            arith = r_arith; op1 = r_op1; op2 = r_op2;
            #1;

            if (result !== want || eq !== want_eq || slt !== want_slt) begin
                failed = failed + 1;
                $display("[FAIL] random %0d: opsel=%b sub=%b unsigned=%b arith=%b op1=%h op2=%h",
                         i, r_opsel, r_sub, r_uns, r_arith, r_op1, r_op2);
                $display("         result=%h (want %h)  eq=%b (want %b)  slt=%b (want %b)",
                         result, want, eq, want_eq, slt, want_slt);
            end else passed = passed + 1;
        end
        $display("       500 wide-operand vectors checked against the model");

        // wide random operands are almost never equal, so o_eq only ever
        // gets exercised deasserted above. draw both operands from {0..3}
        // so collisions are frequent and the equality path sees real use.
        for (i = 0; i < 300; i = i + 1) begin
            r_op1   = $random(seed) & 32'd3;
            r_op2   = $random(seed) & 32'd3;
            r_opsel = $random(seed);
            r_sub   = $random(seed);
            r_uns   = $random(seed);
            r_arith = $random(seed);

            want     = model_result(r_opsel, r_sub, r_uns, r_arith, r_op1, r_op2);
            want_eq  = (r_op1 == r_op2);
            want_slt = model_lt(r_uns, r_op1, r_op2);

            opsel = r_opsel; sub = r_sub; is_unsigned = r_uns;
            arith = r_arith; op1 = r_op1; op2 = r_op2;
            #1;

            if (result !== want || eq !== want_eq || slt !== want_slt) begin
                failed = failed + 1;
                $display("[FAIL] narrow random %0d: opsel=%b sub=%b unsigned=%b arith=%b op1=%h op2=%h",
                         i, r_opsel, r_sub, r_uns, r_arith, r_op1, r_op2);
                $display("         result=%h (want %h)  eq=%b (want %b)  slt=%b (want %b)",
                         result, want, eq, want_eq, slt, want_slt);
            end else passed = passed + 1;
        end
        $display("       300 narrow-operand vectors checked against the model");


        // --------------------------------------------------------------
        $display("--- RV32M directed (phase_6.pdf 4.3) ---");
        @(negedge clk);
        m_check("mul: 11 * 13 = 143",                   M_MUL,    32'd11,        32'd13,        32'd143);
        m_check("mul: 0xFFFFFFFF * 0xFFFFFFFF low",     M_MUL,    32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0000_0001);
        m_check("mulh: -1 * -1 high = 0",               M_MULH,   32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0000_0000);
        m_check("mulhsu: -1 * (2^32-1) high",           M_MULHSU, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'hFFFF_FFFF);
        m_check("mulhu: (2^32-1)^2 high",               M_MULHU,  32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'hFFFF_FFFE);
        m_check("mul: -7 * 3 = -21",                    M_MUL,    32'hFFFF_FFF9, 32'd3,         32'hFFFF_FFEB);
        m_check("mulh: -2^31 * -2^31 high = 2^30",      M_MULH,   32'h8000_0000, 32'h8000_0000, 32'h4000_0000);
        m_check("mulh: -2^31 * 1 high = -1",            M_MULH,   32'h8000_0000, 32'd1,         32'hFFFF_FFFF);
        m_check("mulhsu: -2^31 * 0x80000000 high",      M_MULHSU, 32'h8000_0000, 32'h8000_0000, 32'hC000_0000);
        m_check("mulhsu: positive * 0xFFFFFFFF high",   M_MULHSU, 32'd2,         32'hFFFF_FFFF, 32'h0000_0001);
        m_check("mul: x * 0 = 0",                       M_MUL,    32'h1234_5678, 32'd0,         32'd0);
        m_check("mulh: negative * 0 = 0 (no -0 issue)", M_MULH,   32'hFFFF_FFF0, 32'd0,         32'd0);
        m_check("div: 7 / -3 = -2",                     M_DIV,    32'd7,         32'hFFFF_FFFD, 32'hFFFF_FFFE);
        m_check("rem: 7 % -3 = 1",                      M_REM,    32'd7,         32'hFFFF_FFFD, 32'd1);
        m_check("div: -7 / 3 = -2",                     M_DIV,    32'hFFFF_FFF9, 32'd3,         32'hFFFF_FFFE);
        m_check("rem: -7 % 3 = -1",                     M_REM,    32'hFFFF_FFF9, 32'd3,         32'hFFFF_FFFF);
        m_check("div: -7 / -3 = 2",                     M_DIV,    32'hFFFF_FFF9, 32'hFFFF_FFFD, 32'd2);
        m_check("rem: -7 % -3 = -1",                    M_REM,    32'hFFFF_FFF9, 32'hFFFF_FFFD, 32'hFFFF_FFFF);
        m_check("divu: 13 / 3 = 4",                     M_DIVU,   32'd13,        32'd3,         32'd4);
        m_check("remu: 13 % 3 = 1",                     M_REMU,   32'd13,        32'd3,         32'd1);
        m_check("divu: 0xFFFFFFFF / 2",                 M_DIVU,   32'hFFFF_FFFF, 32'd2,         32'h7FFF_FFFF);
        m_check("div by zero: 5 / 0 = -1",              M_DIV,    32'd5,         32'd0,         32'hFFFF_FFFF);
        m_check("div by zero: -5 / 0 = -1 (no sign fix)", M_DIV,  32'hFFFF_FFFB, 32'd0,         32'hFFFF_FFFF);
        m_check("divu by zero = 0xFFFFFFFF",            M_DIVU,   32'h8000_0000, 32'd0,         32'hFFFF_FFFF);
        m_check("rem by zero: -5 % 0 = -5",             M_REM,    32'hFFFF_FFFB, 32'd0,         32'hFFFF_FFFB);
        m_check("remu by zero: x % 0 = x",              M_REMU,   32'hDEAD_BEEF, 32'd0,         32'hDEAD_BEEF);
        m_check("div overflow: -2^31 / -1 = -2^31",     M_DIV,    32'h8000_0000, 32'hFFFF_FFFF, 32'h8000_0000);
        m_check("rem overflow: -2^31 % -1 = 0",         M_REM,    32'h8000_0000, 32'hFFFF_FFFF, 32'd0);
        m_check("divu: -2^31 / -1 as unsigned = 0",     M_DIVU,   32'h8000_0000, 32'hFFFF_FFFF, 32'd0);
        m_check("remu: 0x80000000 % 0xFFFFFFFF",        M_REMU,   32'h8000_0000, 32'hFFFF_FFFF, 32'h8000_0000);
        m_check("div: -2^31 / 1",                       M_DIV,    32'h8000_0000, 32'd1,         32'h8000_0000);
        m_check("div: -2^31 / 2",                       M_DIV,    32'h8000_0000, 32'd2,         32'hC000_0000);
        m_check("div: small / large = 0",               M_DIV,    32'd3,         32'd1000,      32'd0);
        m_check("rem: small % large = small",           M_REM,    32'hFFFF_FFFD, 32'd1000,      32'hFFFF_FFFD);
        m_check("div: x / x = 1",                       M_DIV,    32'h7FFF_FFFF, 32'h7FFF_FFFF, 32'd1);

        $display("--- RV32M hold through a freeze (phase_6.pdf 5.5.3) ---");
        k = failed;
        m_case("mul held 5 cycles",    M_MUL,    32'h0001_0003, 32'h0002_0005, 5);
        m_case("mulh held 3 cycles",   M_MULH,   32'hDEAD_BEEF, 32'h1234_5678, 3);
        m_case("div held 7 cycles",    M_DIV,    32'h8000_0001, 32'h0000_0007, 7);
        m_case("remu held 1 cycle",    M_REMU,   32'hFFFF_FFFF, 32'h0000_0010, 1);
        m_case("div/0 held 4 cycles",  M_DIV,    32'hFFFF_FF00, 32'd0,         4);
        if (failed == k) $display("[PASS] results held, no restart, while i_advance low");

        $display("--- RV32M back to back ---");
        // m_case ends with i_mext still high and the next one starts right
        // after the advance edge, so these run with no idle cycle between.
        k = failed;
        m_case("b2b mul",   M_MUL,  32'd100,       32'd200,       0);
        m_case("b2b div",   M_DIV,  32'hFFFF_FC18, 32'd7,         0);
        m_case("b2b mulhu", M_MULHU,32'hFFFF_FFFF, 32'h8000_0000, 2);
        m_case("b2b rem",   M_REM,  32'h7FFF_FFFF, 32'hFFFF_FFF0, 0);
        m_case("b2b mul",   M_MUL,  32'hFFFF_FFFF, 32'd2,         0);
        if (failed == k) $display("[PASS] back-to-back M instructions restart cleanly");

        // An RV32I op right after an M op: combinational again, busy low.
        mext = 1'b0; advance = 1'b1;
        check("add right after an M op",       OP_ADD, 1'b0,1'b0,1'b0, 32'd5,         32'd6,         32'd11,        1'b0,1'b1);

        $display("--- RV32M reset mid-operation ---");
        mext = 1'b1; advance = 1'b0; opsel = M_DIV; op1 = 32'd100; op2 = 32'd3;
        repeat (5) @(negedge clk);
        rst = 1'b1; mext = 1'b0;
        @(negedge clk);
        rst = 1'b0;
        k = failed;
        m_case("div after reset",  M_DIV, 32'd100, 32'd3, 0);
        if (failed == k) $display("[PASS] a reset mid-divide does not corrupt the next operation");

        $display("--- RV32M random vs model ---");
        seed = 32'd4768;
        for (i = 0; i < 400; i = i + 1) begin
            r_opsel = $random(seed);
            r_op1   = $random(seed);
            r_op2   = $random(seed);
            // mix in small, zero and extreme operands
            case ($random(seed) & 7)
                0: r_op2 = 32'd0;
                1: r_op2 = $random(seed) & 32'hF;
                2: r_op1 = 32'h8000_0000;
                3: r_op2 = 32'hFFFF_FFFF;
                default: ;
            endcase
            m_case("random M", r_opsel, r_op1, r_op2, $random(seed) & 3);
        end
        $display("       400 random M vectors checked against the model");
        $display("       longest M operation: %0d busy cycles", m_max_cycles);
        mext = 1'b0;
        advance = 1'b1;

        $display("===================================");
        $display("%0d passed, %0d failed", passed, failed);
        if (failed == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");

        $finish;  // without this vvp never returns
    end

endmodule

`default_nettype wire
