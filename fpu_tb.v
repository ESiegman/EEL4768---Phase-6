// Unit test of the whole FPU (fpu.v and the submodules it instantiates).
//
// The FPU is driven the way hart.v drives it: an instruction is held in EX
// (i_valid high, i_advance low) while o_busy is high, plus a random 0-5
// extra cycles that stand in for a cache freeze, then advances for one
// edge. Every instruction is checked for:
//  * the protocol (phase_6.pdf 5.3.3, 5.5.2-5.5.3): o_busy doesn't depend on
//    i_advance; the results and o_fflags stay stable while held; o_busy
//    doesn't rise again (no restart); fcsr doesn't change until the advance
//    edge, and then changes exactly to what o_fflags showed
//  * its value: result and flags against golden vectors
//
// Golden vectors are in tools/fpu_vectors/ (Berkeley TestFloat with the
// RISC-V specialization, tininess after rounding, all five rounding modes,
// part of them through frm with rm = 111, plus the phase_6.pdf examples and
// a cross product of special values; see the README there). Before
// each vector a CSR instruction writes fcsr = {frm, 00000}, so the vector's
// flags are isolated and the CSR read checks the previous commit.
//
// Directed tests: every CSR form on every address (no-write cases, the
// field widths), a CSR instruction held for several cycles, the dynamic-rm
// trap, i_valid low, back-to-back multi-cycle operations, and the fcsr
// breakdown of phase_6.pdf 4.6.2.
//
// Results are printed in two groups. "top / CSR / non-rounding" is fpu.v's
// own logic and passes on its own. "arithmetic and conversion" needs
// fpu_fma, fpu_cvt, fpu_divsqrt and fpu_round (docs/fpu_interfaces.md) and
// fails until they are on main (special operands already pass).
//
// With +define+FPU_STANDINS, the fake submodules in tools/fpu_standins/ are
// bound to fpu.v's tie-off nets so the multi-cycle protocol can be
// exercised before the real ones exist (tools/fpu_standins/run.sh).

module fpu_tb;

    localparam MAX_MSGS = 5;   // failure messages printed per op

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    reg         clk;
    reg         rst;
    reg  [31:0] inst;
    reg         valid;
    reg         advance;
    reg  [31:0] frs1, frs2, frs3, xrs1;
    wire [31:0] fp_result, int_result;
    wire [ 4:0] fflags;
    wire        busy, rm_trap;

    fpu dut (
        .i_clk       (clk),
        .i_rst       (rst),
        .i_inst      (inst),
        .i_valid     (valid),
        .i_advance   (advance),
        .i_frs1      (frs1),
        .i_frs2      (frs2),
        .i_frs3      (frs3),
        .i_xrs1      (xrs1),
        .o_fp_result (fp_result),
        .o_int_result(int_result),
        .o_fflags    (fflags),
        .o_busy      (busy),
        .o_rm_trap   (rm_trap)
    );

    // Period 20. Inputs change at a negedge, outputs are checked 6 later,
    // and the posedge is 10 after the negedge.
    initial clk = 1'b0;
    always #10 clk = ~clk;

    // fcsr inside the DUT, read directly so the testbench can see exactly
    // when it changes.
    wire [7:0] dut_fcsr = {dut.frm, dut.fflags};

`ifdef FPU_STANDINS
    // ------------------------------------------------------------------
    // Fake submodules (tools/fpu_standins/) driving fpu.v's tie-off nets.
    // ------------------------------------------------------------------
    wire        sb_fma_busy, sb_fma_sign, sb_ds_busy, sb_ds_sign, sb_i2f_sign;
    wire [ 9:0] sb_fma_exp, sb_ds_exp, sb_i2f_exp;
    wire [25:0] sb_fma_sig, sb_ds_sig, sb_i2f_sig;
    wire [31:0] sb_f2i_result, sb_rnd_result;
    wire [ 4:0] sb_f2i_flags, sb_rnd_flags;

    fpu_fma s_fma (
        .i_clk(clk), .i_rst(rst), .i_valid(dut.fma_valid), .i_advance(advance),
        .i_mul_only(dut.mul_only), .i_rm(dut.rm),
        .i_a_sign(dut.fma_a_sign), .i_a_exp(dut.fma_a_exp), .i_a_sig(dut.fma_a_sig),
        .i_b_sign(dut.fma_b_sign), .i_b_exp(dut.fma_b_exp), .i_b_sig(dut.fma_b_sig),
        .i_c_sign(dut.fma_c_sign), .i_c_exp(dut.fma_c_exp), .i_c_sig(dut.fma_c_sig),
        .o_busy(sb_fma_busy), .o_sign(sb_fma_sign), .o_exp(sb_fma_exp), .o_sig(sb_fma_sig));
    fpu_divsqrt s_ds (
        .i_clk(clk), .i_rst(rst), .i_valid(dut.ds_valid), .i_advance(advance),
        .i_sqrt(dut.op_fsqrt),
        .i_a_sign(dut.a_sign), .i_a_exp(dut.a_nexp), .i_a_sig(dut.a_nsig),
        .i_b_sign(dut.b_sign), .i_b_exp(dut.b_nexp), .i_b_sig(dut.b_nsig),
        .o_busy(sb_ds_busy), .o_sign(sb_ds_sign), .o_exp(sb_ds_exp), .o_sig(sb_ds_sig));
    fpu_cvt s_cvt (
        .i_unsigned(dut.cvt_unsigned), .i_rm(dut.rm),
        .i_a_sign(dut.a_sign), .i_a_exp(dut.a_nexp), .i_a_sig(dut.a_nsig),
        .o_f2i_result(sb_f2i_result), .o_f2i_flags(sb_f2i_flags), .i_int(xrs1),
        .o_i2f_sign(sb_i2f_sign), .o_i2f_exp(sb_i2f_exp), .o_i2f_sig(sb_i2f_sig));
    fpu_round s_round (
        .i_sign(dut.rnd_sign), .i_exp(dut.rnd_exp), .i_sig(dut.rnd_sig), .i_rm(dut.rm),
        .o_result(sb_rnd_result), .o_flags(sb_rnd_flags));

    initial begin
        force dut.fma_busy       = sb_fma_busy;
        force dut.fma_o_sign     = sb_fma_sign;
        force dut.fma_o_exp      = sb_fma_exp;
        force dut.fma_o_sig      = sb_fma_sig;
        force dut.ds_busy        = sb_ds_busy;
        force dut.ds_o_sign      = sb_ds_sign;
        force dut.ds_o_exp       = sb_ds_exp;
        force dut.ds_o_sig       = sb_ds_sig;
        force dut.cvt_f2i_result = sb_f2i_result;
        force dut.cvt_f2i_flags  = sb_f2i_flags;
        force dut.cvt_i2f_sign   = sb_i2f_sign;
        force dut.cvt_i2f_exp    = sb_i2f_exp;
        force dut.cvt_i2f_sig    = sb_i2f_sig;
        force dut.rnd_result     = sb_rnd_result;
        force dut.rnd_flags      = sb_rnd_flags;
    end
`endif

    // ------------------------------------------------------------------
    // Per-op results
    // ------------------------------------------------------------------
    localparam N_OPS     = 30;
    localparam OP_FDIV   = 3;
    localparam OP_FSQRT  = 4;
    localparam OP_FEQ    = 13;
    localparam OP_CSR    = 24;  // CSR instructions against the fcsr model
    localparam OP_PROTO  = 25;  // hold/commit protocol of every instruction
    localparam OP_TRAP   = 26;  // dynamic-rm trap, and i_valid low
    localparam OP_SEQ_T  = 27;  // an fcsr sequence with no rounding op
    localparam OP_SEQ_A  = 28;  // phase_6.pdf 4.6.2 breakdown (needs fdiv, fcvt)
    localparam OP_B2B    = 29;  // back-to-back fdiv/fsqrt values

    reg [8*28-1:0] op_name [0:N_OPS-1];
    integer        op_pass [0:N_OPS-1];
    integer        op_fail [0:N_OPS-1];
    integer        op_dir  [0:N_OPS-1];  // directed and special-value vectors among them
    integer        i;

    initial begin
        op_name[0]  = "fadd.s";       op_name[1]  = "fsub.s";
        op_name[2]  = "fmul.s";       op_name[3]  = "fdiv.s";
        op_name[4]  = "fsqrt.s";      op_name[5]  = "fmadd.s";
        op_name[6]  = "fmsub.s";      op_name[7]  = "fnmsub.s";
        op_name[8]  = "fnmadd.s";     op_name[9]  = "fcvt.w.s";
        op_name[10] = "fcvt.wu.s";    op_name[11] = "fcvt.s.w";
        op_name[12] = "fcvt.s.wu";    op_name[13] = "feq.s";
        op_name[14] = "flt.s";        op_name[15] = "fle.s";
        op_name[16] = "fsgnj.s";      op_name[17] = "fsgnjn.s";
        op_name[18] = "fsgnjx.s";     op_name[19] = "fmin.s";
        op_name[20] = "fmax.s";       op_name[21] = "fclass.s";
        op_name[22] = "fmv.x.w";      op_name[23] = "fmv.w.x";
        op_name[24] = "CSR instructions";
        op_name[25] = "hold/commit protocol";
        op_name[26] = "rm trap, i_valid low";
        op_name[27] = "fcsr sequence";
        op_name[28] = "PDF 4.6.2 fcsr breakdown";
        op_name[29] = "back-to-back fdiv/fsqrt";
        for (i = 0; i < N_OPS; i = i + 1) begin
            op_pass[i] = 0;
            op_fail[i] = 0;
            op_dir[i]  = 0;
        end
    end

    function in_arith_group;
        input integer op;
        begin
            in_arith_group = (op <= 12) || (op == OP_SEQ_A) || (op == OP_B2B);
        end
    endfunction

    // Which op an instruction word is (vectors only hold F instructions).
    function integer op_of;
        input [31:0] w;
        begin
            op_of = -1;
            case (w[6:0])
                7'b1000011: op_of = 5;
                7'b1000111: op_of = 6;
                7'b1001011: op_of = 7;
                7'b1001111: op_of = 8;
                7'b1010011:
                    case (w[31:25])
                        7'b0000000: op_of = 0;
                        7'b0000100: op_of = 1;
                        7'b0001000: op_of = 2;
                        7'b0001100: op_of = 3;
                        7'b0101100: op_of = 4;
                        7'b1100000: op_of = w[20] ? 10 : 9;
                        7'b1101000: op_of = w[20] ? 12 : 11;
                        7'b1010000: op_of = (w[14:12] == 3'b010) ? 13 : (w[14:12] == 3'b001) ? 14 : 15;
                        7'b0010000: op_of = 16 + w[13:12];
                        7'b0010100: op_of = 19 + w[12];
                        7'b1110000: op_of = w[12] ? 21 : 22;
                        7'b1111000: op_of = 23;
                        default:    op_of = -1;
                    endcase
                default: op_of = -1;
            endcase
        end
    endfunction

    // Ops whose result is o_int_result.
    function int_op;
        input integer op;
        begin
            int_op = (op == 9) || (op == 10) || (op == 13) || (op == 14) ||
                     (op == 15) || (op == 21) || (op == 22);
        end
    endfunction

    task record;
        input integer op;
        input         ok;
        begin
            if (ok)
                op_pass[op] = op_pass[op] + 1;
            else
                op_fail[op] = op_fail[op] + 1;
        end
    endtask

    // Records a value check and prints the first failures of each op.
    task record_value;
        input integer    op;
        input            ok;
        input [31:0]     t_inst;
        input [31:0]     a, b, c, x;
        input [31:0]     got;
        input [ 4:0]     got_ff;
        input [31:0]     want;
        input [ 4:0]     want_ff;
        input [ 2:0]     t_frm;
        begin
            if (!ok && op_fail[op] < MAX_MSGS)
                $display("[FAIL] %0s: inst %h frm %0d a %h b %h c %h x %h: got %h flags %b, expected %h flags %b",
                         op_name[op], t_inst, t_frm, a, b, c, x, got, got_ff, want, want_ff);
            record(op, ok);
        end
    endtask

    // ------------------------------------------------------------------
    // Driving one instruction
    // ------------------------------------------------------------------
    integer    seed;
    integer    total_busy;   // busy cycles seen over the whole run
    integer    proto_msgs;

    // fcsr model, following what the DUT committed (each check compares
    // against it first), so a wrong value fails once instead of cascading.
    reg [4:0]  m_ff;
    reg [2:0]  m_frm;

    // What the last run_inst saw.
    reg [31:0] r_fp, r_int;
    reg [ 4:0] r_ff;
    reg        r_trap;
    reg [ 7:0] r_pre, r_post;   // fcsr before the instruction, and after its edge
    integer    r_busy;          // cycles o_busy was high
    reg        r_ok;            // protocol held

    task proto_fail;
        input [8*56-1:0] why;
        begin
            if (r_ok && proto_msgs < 2 * MAX_MSGS)
                $display("[FAIL] protocol: %0s (inst %h, cycle %0d)", why, inst, $time / 20);
            if (r_ok)
                proto_msgs = proto_msgs + 1;
            r_ok = 1'b0;
        end
    endtask

    // Called right after a negedge with the instruction already in place;
    // ends at the next negedge after the advance edge, with i_valid still
    // high, so the next call follows back to back.
    task run_inst;
        input [31:0] t_inst, t_a, t_b, t_c, t_x;
        input integer extra;
        integer k;
        reg     b0;
        begin
            inst    = t_inst;
            frs1    = t_a;
            frs2    = t_b;
            frs3    = t_c;
            xrs1    = t_x;
            valid   = 1'b1;
            advance = 1'b0;
            r_pre   = dut_fcsr;
            r_busy  = 0;
            r_ok    = 1'b1;
            #2;
            // No combinational path from i_advance to o_busy.
            b0 = busy;
            advance = 1'b1;
            #2;
            if (busy !== b0)
                proto_fail("o_busy depends on i_advance");
            advance = 1'b0;
            #2;
            while (busy === 1'b1 && r_busy < 1000) begin
                if (rm_trap !== 1'b0)
                    proto_fail("o_busy and o_rm_trap both high");
                @(posedge clk);
                #1;
                if (dut_fcsr !== r_pre)
                    proto_fail("fcsr changed while busy");
                @(negedge clk);
                #6;
                r_busy = r_busy + 1;
            end
            if (busy !== 1'b0)
                proto_fail("o_busy stuck high or X");
            r_fp   = fp_result;
            r_int  = int_result;
            r_ff   = fflags;
            r_trap = rm_trap;
            if (r_trap === 1'b1 && fflags !== r_pre[4:0])
                proto_fail("o_fflags is not the current fflags on an rm trap");
            for (k = 0; k < extra; k = k + 1) begin
                @(posedge clk);
                #1;
                if (dut_fcsr !== r_pre)
                    proto_fail("fcsr changed while held with i_advance low");
                @(negedge clk);
                #6;
                if (busy !== 1'b0)
                    proto_fail("o_busy rose again while held (restart)");
                if (fp_result !== r_fp || int_result !== r_int || fflags !== r_ff || rm_trap !== r_trap)
                    proto_fail("result or o_fflags changed while held");
            end
            advance = 1'b1;
            #2;
            if (busy !== 1'b0 || fp_result !== r_fp || int_result !== r_int || fflags !== r_ff)
                proto_fail("outputs changed when i_advance rose");
            @(posedge clk);
            #1;
            r_post = dut_fcsr;
            if (r_trap === 1'b1 ? (r_post !== r_pre) : (r_post[4:0] !== r_ff))
                proto_fail("fcsr after the advance edge is not what o_fflags showed");
            if (t_inst[6:0] != 7'b1110011 && r_post[7:5] !== r_pre[7:5])
                proto_fail("frm changed by a non-CSR instruction");
            total_busy = total_busy + r_busy;
            @(negedge clk);
            advance = 1'b0;
        end
    endtask

    // Cycles with no instruction: o_busy and o_rm_trap low, o_fflags the
    // current flags, fcsr unchanged whatever i_inst and i_advance hold. The
    // instruction word is sometimes a dynamic-rm fdiv, which would trap.
    task idle;
        input integer n;
        integer k;
        reg ok;
        begin
            for (k = 0; k < n; k = k + 1) begin
                valid   = 1'b0;
                advance = $random(seed);
                inst    = ($random(seed) & 1) ? 32'h183170D3 : $random(seed);
                frs1    = $random(seed);
                frs2    = $random(seed);
                #6;
                ok = (busy === 1'b0) && (rm_trap === 1'b0) && (fflags === m_ff);
                @(posedge clk);
                #1;
                ok = ok && (dut_fcsr === {m_frm, m_ff});
                if (!ok && op_fail[OP_TRAP] < MAX_MSGS)
                    $display("[FAIL] %0s: i_valid low: busy %b rm_trap %b o_fflags %b fcsr %h, expected 0 0 %b %h",
                             op_name[OP_TRAP], busy, rm_trap, fflags, dut_fcsr, m_ff, {m_frm, m_ff});
                record(OP_TRAP, ok);
                @(negedge clk);
            end
            advance = 1'b0;
        end
    endtask

    // One CSR instruction, checked against the model (phase_6.pdf 4.6.2):
    // rd gets the old value zero-extended, the write keeps only the field's
    // width, and csrrs/csrrc[i] skip the write when the rs1/uimm field is 0.
    reg [7:0] c_old;
    task csr;
        input [ 2:0] f3;
        input [ 1:0] addr;    // 1 fflags, 2 frm, 3 fcsr
        input [ 4:0] rs1f;    // register number or uimm
        input [31:0] x;       // i_xrs1
        input integer hold;
        reg [7:0] src, nw;
        reg       wr, ok;
        reg [4:0] ff_exp;
        reg [2:0] frm_exp;
        begin
            c_old   = (addr == 2'd1) ? {3'd0, m_ff} : (addr == 2'd2) ? {5'd0, m_frm} : {m_frm, m_ff};
            src     = f3[2] ? {3'd0, rs1f} : x[7:0];
            nw      = (f3[1:0] == 2'b01) ? src : (f3[1:0] == 2'b10) ? (c_old | src) : (c_old & ~src);
            wr      = (f3[1:0] == 2'b01) || (rs1f != 5'd0);
            ff_exp  = (wr && addr != 2'd2) ? nw[4:0] : m_ff;
            frm_exp = (wr && addr == 2'd2) ? nw[2:0] : (wr && addr == 2'd3) ? nw[7:5] : m_frm;
            run_inst({10'd0, addr, rs1f, f3, 5'd5, 7'b1110011}, $random(seed), $random(seed),
                     $random(seed), x, hold);
            ok = (r_int === {24'd0, c_old}) && (r_ff === ff_exp) && (r_trap === 1'b0) &&
                 (r_busy == 0) && (r_post === {frm_exp, ff_exp});
            if (!ok && op_fail[OP_CSR] < MAX_MSGS)
                $display("[FAIL] %0s: f3 %b csr %0d rs1/uimm %0d x %h from fcsr %h: rd %h o_fflags %b fcsr after %h, expected %h %b %h",
                         op_name[OP_CSR], f3, addr, rs1f, x, {m_frm, m_ff}, r_int, r_ff, r_post,
                         {24'd0, c_old}, ff_exp, {frm_exp, ff_exp});
            record(OP_CSR, ok);
            record(OP_PROTO, r_ok);
            m_ff  = r_post[4:0];
            m_frm = r_post[7:5];
        end
    endtask

    // Sets fcsr through csrrw (and checks that like any CSR instruction).
    task set_fcsr;
        input [2:0] t_frm;
        input [4:0] t_ff;
        begin
            csr(3'b001, 2'd3, 5'd6, {24'd0, t_frm, t_ff}, 0);
        end
    endtask

    // One non-CSR instruction with an expected value, outside the vector
    // files.
    task op_check;
        input integer op;           // where to count the value check
        input [31:0]  t_inst, a, b, c, x;
        input [31:0]  want;
        input [ 4:0]  want_ff;      // the full o_fflags expected
        input integer extra;
        reg   [31:0]  got;
        begin
            run_inst(t_inst, a, b, c, x, extra);
            got = int_op(op_of(t_inst)) ? r_int : r_fp;
            record_value(op, (got === want) && (r_ff === want_ff) && (r_trap === 1'b0),
                         t_inst, a, b, c, x, got, r_ff, want, want_ff, m_frm);
            record(OP_PROTO, r_ok);
            m_ff  = r_post[4:0];
            m_frm = r_post[7:5];
        end
    endtask

    // ------------------------------------------------------------------
    // Vector files
    // ------------------------------------------------------------------
    reg  [31:0] v_inst, v_a, v_b, v_c, v_x, v_res;
    reg  [ 7:0] v_ctrl;
    reg  [31:0] got;
    integer     fd, nread, op, n_vec, n_in_file;
    reg [8*96-1:0] path;

    task run_file;
        input [8*16-1:0] name;
        input            is_directed;
        begin
            $sformat(path, "../tools/fpu_vectors/%0s.hex", name);
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $sformat(path, "tools/fpu_vectors/%0s.hex", name);
                fd = $fopen(path, "r");
            end
            n_in_file = 0;
            if (fd == 0) begin
                $display("[FAIL] cannot open tools/fpu_vectors/%0s.hex", name);
                record(OP_PROTO, 1'b0);
            end else begin
                nread = $fscanf(fd, "%h %h %h %h %h %h %h\n", v_inst, v_a, v_b, v_c, v_x, v_res, v_ctrl);
                while (nread == 7) begin
                    // fcsr = {frm, 00000}, held 0-2 cycles.
                    set_fcsr(v_ctrl[7:5], 5'd0);
                    run_inst(v_inst, v_a, v_b, v_c, v_x, {$random(seed)} % 6);
                    op  = op_of(v_inst);
                    got = int_op(op) ? r_int : r_fp;
                    if (op < 0) begin
                        $display("[FAIL] %0s.hex: not an F instruction: %h", name, v_inst);
                        record(OP_PROTO, 1'b0);
                    end else begin
                        record_value(op, (got === v_res) && (r_ff === v_ctrl[4:0]) && (r_trap === 1'b0),
                                     v_inst, v_a, v_b, v_c, v_x, got, r_ff, v_res, v_ctrl[4:0], v_ctrl[7:5]);
                        if (is_directed)
                            op_dir[op] = op_dir[op] + 1;
                    end
                    record(OP_PROTO, r_ok);
                    m_ff  = r_post[4:0];
                    m_frm = r_post[7:5];
                    n_in_file = n_in_file + 1;
                    if ({$random(seed)} % 16 == 0)
                        idle(1 + {$random(seed)} % 2);
                    nread = $fscanf(fd, "%h %h %h %h %h %h %h\n", v_inst, v_a, v_b, v_c, v_x, v_res, v_ctrl);
                end
                $fclose(fd);
                if (n_in_file == 0) begin
                    $display("[FAIL] tools/fpu_vectors/%0s.hex has no vectors", name);
                    record(OP_PROTO, 1'b0);
                end
            end
            n_vec = n_vec + n_in_file;
        end
    endtask

    // ------------------------------------------------------------------
    // Instruction words for the directed tests
    // ------------------------------------------------------------------
    function [31:0] opfp;
        input [6:0] f7;
        input [4:0] rs2;
        input [2:0] f3;
        begin
            opfp = {f7, rs2, 5'd2, f3, 5'd1, 7'b1010011};
        end
    endfunction

    function [31:0] fused;
        input [6:0] opc;
        input [2:0] rm;
        begin
            fused = {5'd4, 2'b00, 5'd3, 5'd2, rm, 5'd1, opc};
        end
    endfunction

    localparam [31:0] F_ONE   = 32'h3F800000;
    localparam [31:0] F_THREE = 32'h40400000;
    localparam [31:0] F_TWO   = 32'h40000000;
    localparam [31:0] F_SEVEN = 32'h40E00000;
    localparam [31:0] F_QNAN  = 32'h7FC00000;

    // Every instruction with an rm field, with rm = 111.
    reg [31:0] dyn_insts [0:12];
    initial begin
        dyn_insts[0]  = opfp(7'b0000000, 5'd3, 3'b111);  // fadd
        dyn_insts[1]  = opfp(7'b0000100, 5'd3, 3'b111);  // fsub
        dyn_insts[2]  = opfp(7'b0001000, 5'd3, 3'b111);  // fmul
        dyn_insts[3]  = opfp(7'b0001100, 5'd3, 3'b111);  // fdiv
        dyn_insts[4]  = opfp(7'b0101100, 5'd0, 3'b111);  // fsqrt
        dyn_insts[5]  = fused(7'b1000011, 3'b111);
        dyn_insts[6]  = fused(7'b1000111, 3'b111);
        dyn_insts[7]  = fused(7'b1001011, 3'b111);
        dyn_insts[8]  = fused(7'b1001111, 3'b111);
        dyn_insts[9]  = opfp(7'b1100000, 5'd0, 3'b111);  // fcvt.w.s
        dyn_insts[10] = opfp(7'b1100000, 5'd1, 3'b111);  // fcvt.wu.s
        dyn_insts[11] = opfp(7'b1101000, 5'd0, 3'b111);  // fcvt.s.w
        dyn_insts[12] = opfp(7'b1101000, 5'd1, 3'b111);  // fcvt.s.wu
    end

    // Instructions that never trap on a reserved frm.
    reg [31:0] nontrap_insts [0:11];
    initial begin
        nontrap_insts[0]  = opfp(7'b0000000, 5'd3, 3'b000);  // fadd, static RNE
        nontrap_insts[1]  = opfp(7'b0001100, 5'd3, 3'b100);  // fdiv, static RMM
        nontrap_insts[2]  = opfp(7'b1101000, 5'd0, 3'b001);  // fcvt.s.w, static RTZ
        nontrap_insts[3]  = fused(7'b1001111, 3'b010);       // fnmadd, static RDN
        nontrap_insts[4]  = opfp(7'b0010000, 5'd3, 3'b010);  // fsgnjx
        nontrap_insts[5]  = opfp(7'b0010100, 5'd3, 3'b001);  // fmax
        nontrap_insts[6]  = opfp(7'b1010000, 5'd3, 3'b010);  // feq
        nontrap_insts[7]  = opfp(7'b1010000, 5'd3, 3'b000);  // fle
        nontrap_insts[8]  = opfp(7'b1110000, 5'd0, 3'b001);  // fclass
        nontrap_insts[9]  = opfp(7'b1110000, 5'd0, 3'b000);  // fmv.x.w
        nontrap_insts[10] = opfp(7'b1111000, 5'd0, 3'b000);  // fmv.w.x
        nontrap_insts[11] = opfp(7'b0101100, 5'd0, 3'b011);  // fsqrt, static RUP
    end

    // ------------------------------------------------------------------
    // Directed tests
    // ------------------------------------------------------------------
    integer t, a_i, f_i, k2;
    reg [2:0] csr_f3s [0:5];
    reg [4:0] uimm;
    reg [31:0] xv;
    reg        ok;
    integer    busy1, busy2;

    task directed_csr;
        begin
            // After reset fcsr is 0 (frm RNE, no flags).
            csr(3'b010, 2'd3, 5'd0, 32'hFFFFFFFF, 0);   // frcsr

            // Every form on every address, from random states, including
            // rs1/uimm = 0 (no write for s/c, however i_xrs1 looks) and a
            // zero register value (still a write).
            csr_f3s[0] = 3'b001; csr_f3s[1] = 3'b010; csr_f3s[2] = 3'b011;
            csr_f3s[3] = 3'b101; csr_f3s[4] = 3'b110; csr_f3s[5] = 3'b111;
            for (a_i = 1; a_i <= 3; a_i = a_i + 1) begin
                for (f_i = 0; f_i < 6; f_i = f_i + 1) begin
                    for (t = 0; t < 6; t = t + 1) begin
                        set_fcsr($random(seed), $random(seed));
                        uimm = (t == 0) ? 5'd0 : (t == 1) ? 5'd31 : $random(seed);
                        xv   = (t == 2) ? 32'd0 : $random(seed);
                        csr(csr_f3s[f_i], a_i, uimm, xv, {$random(seed)} % 3);
                    end
                end
            end

            // Field widths: frm takes the low 3 bits, so it can hold 5-7;
            // fflags the low 5; fcsr bits [7:0], and reads zero-extend.
            set_fcsr(3'd0, 5'd0);
            csr(3'b001, 2'd2, 5'd6, 32'hFFFFFFFD, 0);   // frm = 5
            csr(3'b001, 2'd1, 5'd6, 32'hFFFFFFFF, 0);   // fflags = 1F, frm stays 5
            csr(3'b001, 2'd3, 5'd6, 32'h000001FF, 0);   // fcsr = FF (bit 8 dropped)
            csr(3'b010, 2'd3, 5'd0, 32'h12345678, 0);   // reads 000000FF
            csr(3'b101, 2'd2, 5'd7, 32'h0, 0);           // csrrwi frm, 7
            csr(3'b111, 2'd3, 5'd31, 32'h0, 0);          // csrrci fcsr, 31: flags cleared
            csr(3'b110, 2'd1, 5'd16, 32'h0, 0);          // csrrsi fflags, NV
            csr(3'b011, 2'd2, 5'd9, 32'h00000006, 0);    // csrrc frm, x9 (= 6)

            // A CSR instruction held by a "cache miss" keeps reading the old
            // value (phase_6.pdf 5.3.3: csrrw x5, fcsr, x6 must not read x6).
            set_fcsr(3'd2, 5'h0A);
            csr(3'b001, 2'd3, 5'd6, 32'h000000E5, 7);
            csr(3'b010, 2'd1, 5'd6, 32'h00000011, 5);
            csr(3'b111, 2'd3, 5'd31, 32'h0, 6);
        end
    endtask

    task directed_trap;
        begin
            // Dynamic rm with frm = 5, 6, 7: trap, no busy, o_fflags = the
            // current flags, and nothing commits. Operands would raise NX
            // and start the divider if the instruction ran.
            for (k2 = 5; k2 <= 7; k2 = k2 + 1) begin
                set_fcsr(k2, 5'b00101);
                for (t = 0; t < 13; t = t + 1) begin
                    run_inst(dyn_insts[t], F_ONE, F_THREE, F_TWO, 32'd7, {$random(seed)} % 4);
                    ok = (r_trap === 1'b1) && (r_busy == 0) && (r_ff === 5'b00101) && (r_post === r_pre);
                    if (!ok && op_fail[OP_TRAP] < MAX_MSGS)
                        $display("[FAIL] %0s: inst %h with frm %0d: rm_trap %b busy cycles %0d o_fflags %b fcsr %h -> %h",
                                 op_name[OP_TRAP], dyn_insts[t], k2, r_trap, r_busy, r_ff, r_pre, r_post);
                    record(OP_TRAP, ok);
                    record(OP_PROTO, r_ok);
                    m_ff  = r_post[4:0];
                    m_frm = r_post[7:5];
                end
                // Static rm, non-rounding instructions, and csrrci (funct3
                // 111) never trap on it.
                for (t = 0; t < 12; t = t + 1) begin
                    run_inst(nontrap_insts[t], F_ONE, F_THREE, F_TWO, 32'd7, {$random(seed)} % 4);
                    ok = (r_trap === 1'b0);
                    if (!ok && op_fail[OP_TRAP] < MAX_MSGS)
                        $display("[FAIL] %0s: inst %h with frm %0d trapped", op_name[OP_TRAP],
                                 nontrap_insts[t], k2);
                    record(OP_TRAP, ok);
                    record(OP_PROTO, r_ok);
                    m_ff  = r_post[4:0];
                    m_frm = r_post[7:5];
                end
                csr(3'b111, 2'd1, 5'd1, 32'h0, 1);
                idle(3);
            end
            set_fcsr(3'd0, 5'd0);
            idle(4);
        end
    endtask

    task directed_sequences;
        begin
            // phase_6.pdf 4.6.2, verbatim. Needs fdiv's NX and fcvt.w.s.
            set_fcsr(3'd0, 5'd0);
            op_check(OP_SEQ_A, opfp(7'b0001100, 5'd3, 3'b111), F_SEVEN, F_THREE ^ 32'h80000000, 0, 0,
                     32'hC0155555, 5'b00001, 1);                     // fdiv.s f3, f1, f2
            csr(3'b010, 2'd1, 5'd0, 32'hFFFFFFFF, 2);                // csrrs x12, fflags, x0
            record(OP_SEQ_A, r_int === 32'd1);
            csr(3'b101, 2'd2, 5'd1, 32'h0, 0);                       // csrrwi x0, frm, 1
            op_check(OP_SEQ_A, opfp(7'b1100000, 5'd0, 3'b111), 32'hC0155555, 0, 0, 0,
                     32'hFFFFFFFE, 5'b00001, 2);                     // fcvt.w.s x14, f3 (RTZ)
            csr(3'b001, 2'd3, 5'd0, 32'h0, 3);                       // csrrw x5, fcsr, x0
            record(OP_SEQ_A, r_int === 32'h21 && r_post === 8'h00);

            // The same shape with flags from fpu.v alone: flt with a NaN
            // raises NV.
            op_check(OP_SEQ_T, opfp(7'b1010000, 5'd3, 3'b001), F_QNAN, F_ONE, 0, 0, 32'd0, 5'b10000, 1);
            csr(3'b010, 2'd1, 5'd0, 32'hFFFFFFFF, 2);
            record(OP_SEQ_T, r_int === 32'h10);
            csr(3'b101, 2'd2, 5'd1, 32'h0, 0);
            op_check(OP_SEQ_T, opfp(7'b0010000, 5'd3, 3'b010), F_SEVEN, F_ONE ^ 32'h80000000, 0, 0,
                     F_SEVEN ^ 32'h80000000, 5'b10000, 0);           // fsgnjx: no flags
            csr(3'b001, 2'd3, 5'd0, 32'h0, 3);
            record(OP_SEQ_T, r_int === 32'h30 && r_post === 8'h00);
            // Flags committed once: nothing reappears after the clear.
            idle(5);
            op_check(OP_SEQ_T, opfp(7'b1010000, 5'd3, 3'b010), 32'h7F800001, F_ONE, 0, 0, 32'd0, 5'b10000, 2);
            set_fcsr(3'd0, 5'd0);
            idle(5);
            op_check(OP_SEQ_T, opfp(7'b1110000, 5'd0, 3'b000), F_ONE, 0, 0, 0, F_ONE, 5'b00000, 3);
        end
    endtask

    task directed_back_to_back;
        begin
            // Multi-cycle ops one after another with no gap: the second must
            // start cleanly (same latency as the first), and the special
            // operand never starts the unit.
            set_fcsr(3'd0, 5'd0);
            op_check(OP_B2B, opfp(7'b0001100, 5'd3, 3'b000), F_ONE, F_THREE, 0, 0, 32'h3EAAAAAB, 5'b00001, 2);
            busy1 = r_busy;
            op_check(OP_B2B, opfp(7'b0001100, 5'd3, 3'b001), F_ONE ^ 32'h80000000, F_THREE, 0, 0,
                     32'hBEAAAAAA, 5'b00001, 0);
            busy2 = r_busy;
            if (busy1 != busy2)
                $display("[FAIL] %0s: back-to-back fdiv busy for %0d then %0d cycles",
                         op_name[OP_PROTO], busy1, busy2);
            record(OP_PROTO, busy1 == busy2);
            op_check(OP_B2B, opfp(7'b0101100, 5'd0, 3'b000), F_TWO, 0, 0, 0, 32'h3FB504F3, 5'b00001, 0);
            op_check(OP_B2B, opfp(7'b0001100, 5'd3, 3'b000), F_ONE, 32'h0, 0, 0, 32'h7F800000, 5'b01001, 0);
            if (r_busy != 0)
                $display("[FAIL] %0s: fdiv by zero (a special operand) was busy for %0d cycles",
                         op_name[OP_PROTO], r_busy);
            record(OP_PROTO, r_busy == 0);
            csr(3'b010, 2'd1, 5'd0, 32'h0, 1);
            record(OP_B2B, r_int === 32'h09);
            // fdiv, fsqrt, fdiv back to back with long freezes after each.
            op_check(OP_B2B, opfp(7'b0001100, 5'd3, 3'b000), F_SEVEN, F_THREE ^ 32'h80000000, 0, 0,
                     32'hC0155555, 5'b01001, 5);
            op_check(OP_B2B, opfp(7'b0101100, 5'd0, 3'b000), F_TWO, 0, 0, 0, 32'h3FB504F3, 5'b01001, 4);
            op_check(OP_B2B, opfp(7'b0001100, 5'd3, 3'b000), F_ONE, F_THREE, 0, 0, 32'h3EAAAAAB, 5'b01001, 3);
            set_fcsr(3'd0, 5'd0);
        end
    endtask

    // ------------------------------------------------------------------
    // Main
    // ------------------------------------------------------------------
    integer total_pass, total_fail, g_pass, g_fail, grp;

    task print_group;
        input integer which;
        begin
            g_pass = 0;
            g_fail = 0;
            $display("== %0s ==", which ? "arithmetic and conversion (needs fpu_fma, fpu_cvt, fpu_divsqrt, fpu_round)"
                                        : "top / CSR / non-rounding (fpu.v)");
            for (i = 0; i < N_OPS; i = i + 1) begin
                if (in_arith_group(i) == which && op_pass[i] + op_fail[i] > 0) begin
                    if (op_dir[i] > 0)
                        $display("  %-28s %6d passed %6d failed   (%0d directed)",
                                 op_name[i], op_pass[i], op_fail[i], op_dir[i]);
                    else
                        $display("  %-28s %6d passed %6d failed", op_name[i], op_pass[i], op_fail[i]);
                    g_pass = g_pass + op_pass[i];
                    g_fail = g_fail + op_fail[i];
                end
            end
            $display("  %-28s %6d passed %6d failed", "group total", g_pass, g_fail);
            total_pass = total_pass + g_pass;
            total_fail = total_fail + g_fail;
        end
    endtask

    initial begin
        seed       = 4768;
        total_busy = 0;
        proto_msgs = 0;
        n_vec      = 0;
        rst        = 1'b1;
        valid      = 1'b0;
        advance    = 1'b0;
        inst       = 32'h00000013;
        frs1       = 32'd0;
        frs2       = 32'd0;
        frs3       = 32'd0;
        xrs1       = 32'd0;
        m_ff       = 5'd0;
        m_frm      = 3'd0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // i_valid low straight out of reset.
        idle(4);

        directed_csr;
        directed_trap;
        directed_sequences;
        directed_back_to_back;

        // Golden vectors.
        run_file("directed", 1'b1);
        run_file("special", 1'b1);
        run_file("feq", 1'b0);       run_file("flt", 1'b0);       run_file("fle", 1'b0);
        run_file("fsgnj", 1'b0);     run_file("fsgnjn", 1'b0);    run_file("fsgnjx", 1'b0);
        run_file("fmin", 1'b0);      run_file("fmax", 1'b0);      run_file("fclass", 1'b0);
        run_file("fmv_x_w", 1'b0);   run_file("fmv_w_x", 1'b0);
        run_file("fadd", 1'b0);      run_file("fsub", 1'b0);      run_file("fmul", 1'b0);
        run_file("fdiv", 1'b0);      run_file("fsqrt", 1'b0);
        run_file("fmadd", 1'b0);     run_file("fmsub", 1'b0);
        run_file("fnmsub", 1'b0);    run_file("fnmadd", 1'b0);
        run_file("fcvt_w_s", 1'b0);  run_file("fcvt_wu_s", 1'b0);
        run_file("fcvt_s_w", 1'b0);  run_file("fcvt_s_wu", 1'b0);
        idle(4);

`ifdef FPU_STANDINS
        // With the stand-ins the multi-cycle protocol must actually have run.
        if (total_busy == 0)
            $display("[FAIL] %0s: the stand-ins never raised o_busy", op_name[OP_PROTO]);
        record(OP_PROTO, total_busy > 0);
`endif

        total_pass = 0;
        total_fail = 0;
        $display("");
        $display("fpu_tb: %0d vectors from tools/fpu_vectors, %0d busy cycles seen", n_vec, total_busy);
        print_group(0);
        print_group(1);
        $display("%0d passed, %0d failed", total_pass, total_fail);
        if (total_fail == 0 && total_pass > 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end

endmodule
