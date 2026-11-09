`default_nettype none

// The floating-point unit implements the RISC-V F extension (single
// precision, IEEE 754-2008) and the Zicsr instructions for its control and
// status register fcsr. It sits in the execute stage beside the ALU and the
// multiply/divide unit, and decodes the details of its own instructions from
// the instruction word.
//
// It owns all F-extension state: fcsr, holding the dynamic rounding mode frm
// (fcsr[7:5]) and the accrued exception flags fflags (fcsr[4:0] = NV DZ OF
// UF NX). Floating-point exceptions never trap; they only set flags, which
// stay set until software clears them through a CSR instruction.
//
// fcsr only changes on a rising edge where the instruction in execute
// actually moves on to the memory stage (`i_advance`). An instruction can sit
// in execute for several cycles (for example while a cache miss freezes the
// pipeline); committing its flags or CSR write on every one of those cycles
// would make a CSR instruction read back its own write.
//
// Organization (docs/fpu_interfaces.md has the submodule contracts):
//  * decode, and the effective rounding mode / dynamic-rm trap
//  * unpack and classify fs1, fs2, fs3 (phase_6.pdf 5.3.1)
//  * the instructions that don't round, computed here: sign injection,
//    fmin/fmax, feq/flt/fle, fclass, fmv.x.w, fmv.w.x
//  * fcsr and the six CSR instructions
//  * special operands of the rounding instructions (NaN, infinity, and the
//    zero cases of divide and square root), resolved here so the datapaths
//    only ever see finite operands
//  * the datapaths: fpu_fma (fadd/fsub/fmul/fused) and fpu_cvt (Bowen),
//    fpu_divsqrt (Bradly), and the one shared rounder fpu_round (Bowen)
//  * busy, which is the busy of whichever datapath the instruction uses
module fpu (
    // Global clock.
    input  wire        i_clk,
    // Synchronous active-high reset. Clears fcsr (frm = round to nearest,
    // ties to even; no flags set).
    input  wire        i_rst,
    // The instruction word in the execute stage.
    input  wire [31:0] i_inst,
    // Asserted when `i_inst` is a valid, legal floating-point unit
    // instruction (decoder `o_fpu`): every OP-FP and fused multiply-add
    // instruction and the CSR instructions on fflags/frm/fcsr.
    input  wire        i_valid,
    // Asserted when the instruction in execute advances to the memory stage
    // on the next rising edge. Side effects (fcsr updates) happen only then.
    input  wire        i_advance,
    // Floating-point source operands (rs1, rs2, rs3), raw IEEE bit patterns.
    input  wire [31:0] i_frs1,
    input  wire [31:0] i_frs2,
    input  wire [31:0] i_frs3,
    // Integer source operand (forwarded rs1), used by fmv.w.x, fcvt.s.w[u]
    // and the register forms of the CSR instructions.
    input  wire [31:0] i_xrs1,
    // Result for instructions that write a floating-point register.
    output wire [31:0] o_fp_result,
    // Result for instructions that write an integer register: fmv.x.w,
    // fclass.s, feq/flt/fle.s, fcvt.w[u].s, and the old CSR value.
    output wire [31:0] o_int_result,
    // The accrued exception flags as they will be after this instruction
    // (reported in the retire trace).
    output wire [ 4:0] o_fflags,
    // Asserted while a multi-cycle operation (fdiv.s/fsqrt.s) is in
    // progress and the instruction must stay in execute.
    output wire        o_busy,
    // Asserted when a rounding instruction selects the dynamic rounding mode
    // (rm = 111) while frm holds a reserved value (101-111). The instruction
    // traps as illegal and changes no state.
    output wire        o_rm_trap
);

    localparam [31:0] CANON_NAN = 32'h7FC00000;

    // ------------------------------------------------------------------
    // Decode. i_valid is high only for legal encodings (the decoder checks
    // every fixed field), so only the fields that pick the operation are
    // looked at here.
    // ------------------------------------------------------------------
    wire [6:0] opc  = i_inst[6:0];
    wire [2:0] f3   = i_inst[14:12];
    wire [4:0] rs1f = i_inst[19:15];
    wire [6:0] f7   = i_inst[31:25];

    wire is_csr   = (opc == 7'b1110011);
    // MADD 1000011, MSUB 1000111, NMSUB 1001011, NMADD 1001111.
    wire is_fused = (opc[6:4] == 3'b100) & (opc[1:0] == 2'b11);
    wire is_opfp  = (opc == 7'b1010011);

    wire op_fadd  = is_opfp & (f7 == 7'b0000000);
    wire op_fsub  = is_opfp & (f7 == 7'b0000100);
    wire op_fmul  = is_opfp & (f7 == 7'b0001000);
    wire op_fdiv  = is_opfp & (f7 == 7'b0001100);
    wire op_fsqrt = is_opfp & (f7 == 7'b0101100);
    wire op_sgnj  = is_opfp & (f7 == 7'b0010000);
    wire op_mnmx  = is_opfp & (f7 == 7'b0010100);
    wire op_cmp   = is_opfp & (f7 == 7'b1010000);
    wire op_f2i   = is_opfp & (f7 == 7'b1100000);  // fcvt.w[u].s
    wire op_i2f   = is_opfp & (f7 == 7'b1101000);  // fcvt.s.w[u]
    wire op_mvcls = is_opfp & (f7 == 7'b1110000);  // fmv.x.w (f3 000), fclass.s (f3 001)
    wire op_mvwx  = is_opfp & (f7 == 7'b1111000);

    wire op_addsub = op_fadd | op_fsub;
    wire op_fma    = op_addsub | op_fmul | is_fused;  // the fpu_fma datapath
    wire op_ds     = op_fdiv | op_fsqrt;              // the fpu_divsqrt datapath
    wire op_round  = op_fma | op_ds | op_i2f;         // result comes from fpu_round
    // Instructions with an rm field (phase_6.pdf 4.7). The others have a
    // fixed funct3, and a CSR instruction's funct3 is not a rounding mode.
    wire uses_rm   = op_fma | op_ds | op_f2i | op_i2f;
    // fcvt.wu.s and fcvt.s.wu: rs2 = 00001.
    wire cvt_unsigned = i_inst[20];

    // ------------------------------------------------------------------
    // fcsr
    // ------------------------------------------------------------------
    reg  [4:0] fflags;
    reg  [2:0] frm;

    // Effective rounding mode, and the dynamic-rm trap (phase_6.pdf 4.5.1).
    wire       dyn_rm = (f3 == 3'b111);
    wire [2:0] rm     = dyn_rm ? frm : f3;
    assign o_rm_trap  = i_valid & uses_rm & dyn_rm & (frm >= 3'd5);

    // ------------------------------------------------------------------
    // Unpack and classify fs1, fs2, fs3. A subnormal gets exponent 1 and
    // hidden bit 0 (phase_6.pdf 5.3.1), then its leading zeros are shifted
    // out in constant stages (16, 8, 4, 2, 1) to give the normalized form
    // the datapaths take: sig[23] = 1 and a signed 10-bit exponent that can
    // go below 1. A zero normalizes to sig = 0.
    // ------------------------------------------------------------------
    wire [95:0] op_bits = {i_frs3, i_frs2, i_frs1};
    wire [ 2:0] u_sign, u_zero, u_sub, u_norm, u_inf, u_nan, u_snan, u_qnan;
    wire [29:0] u_nexp;
    wire [71:0] u_nsig;

    genvar g;
    generate
        for (g = 0; g < 3; g = g + 1) begin : g_unpack
            wire [31:0] x      = op_bits[32*g +: 32];
            wire        e_zero = (x[30:23] == 8'h00);
            wire        e_max  = (x[30:23] == 8'hFF);
            wire        f_zero = (x[22:0] == 23'd0);

            assign u_sign[g] = x[31];
            assign u_zero[g] = e_zero & f_zero;
            assign u_sub[g]  = e_zero & ~f_zero;
            assign u_norm[g] = ~e_zero & ~e_max;
            assign u_inf[g]  = e_max & f_zero;
            assign u_nan[g]  = e_max & ~f_zero;
            assign u_snan[g] = e_max & ~f_zero & ~x[22];
            assign u_qnan[g] = e_max & x[22];

            wire [ 7:0] exp1 = e_zero ? 8'd1 : x[30:23];
            wire [23:0] sig1 = {~e_zero, x[22:0]};

            wire        z16 = (sig1[23:8] == 16'd0);
            wire [23:0] s16 = z16 ? {sig1[7:0], 16'd0} : sig1;
            wire        z8  = (s16[23:16] == 8'd0);
            wire [23:0] s8  = z8 ? {s16[15:0], 8'd0} : s16;
            wire        z4  = (s8[23:20] == 4'd0);
            wire [23:0] s4  = z4 ? {s8[19:0], 4'd0} : s8;
            wire        z2  = (s4[23:22] == 2'd0);
            wire [23:0] s2  = z2 ? {s4[21:0], 2'd0} : s4;
            wire        z1  = ~s2[23];
            wire [23:0] s1  = z1 ? {s2[22:0], 1'b0} : s2;

            assign u_nsig[24*g +: 24] = s1;
            assign u_nexp[10*g +: 10] = {2'b00, exp1} - {5'd0, z16, z8, z4, z2, z1};
        end
    endgenerate

    wire        a_sign = u_sign[0], b_sign = u_sign[1], c_sign = u_sign[2];
    wire        a_zero = u_zero[0], b_zero = u_zero[1], c_zero = u_zero[2];
    wire        a_sub  = u_sub[0];
    wire        a_norm = u_norm[0];
    wire        a_inf  = u_inf[0],  b_inf  = u_inf[1],  c_inf  = u_inf[2];
    wire        a_nan  = u_nan[0],  b_nan  = u_nan[1],  c_nan  = u_nan[2];
    wire        a_snan = u_snan[0], b_snan = u_snan[1], c_snan = u_snan[2];
    wire        a_qnan = u_qnan[0];
    wire [ 9:0] a_nexp = u_nexp[ 9: 0], b_nexp = u_nexp[19:10], c_nexp = u_nexp[29:20];
    wire [23:0] a_nsig = u_nsig[23: 0], b_nsig = u_nsig[47:24], c_nsig = u_nsig[71:48];

    // ------------------------------------------------------------------
    // Instructions that don't round (phase_6.pdf 4.7.4-4.7.6)
    // ------------------------------------------------------------------
    // Sign injection: fs1[30:0] with a new sign. NaN payloads pass through.
    wire        sgnj_sign = (f3[1:0] == 2'b00) ? b_sign :
                            (f3[1:0] == 2'b01) ? ~b_sign :
                                                 (a_sign ^ b_sign);
    wire [31:0] sgnj_res  = {sgnj_sign, i_frs1[30:0]};

    // Ordering of two non-NaN values. On sign-magnitude bits, a larger
    // magnitude is a larger [30:0], subnormals and infinities included.
    wire mag_lt    = (i_frs1[30:0] < i_frs2[30:0]);
    wire mag_eq    = (i_frs1[30:0] == i_frs2[30:0]);
    // a < b with -0 < +0 (the order fmin/fmax use).
    wire lt_total  = (a_sign != b_sign) ? a_sign :
                     a_sign             ? (~mag_lt & ~mag_eq) :
                                          mag_lt;
    // IEEE comparisons, where +0 == -0.
    wire both_zero = a_zero & b_zero;
    wire cmp_eq    = both_zero | (i_frs1 == i_frs2);
    wire cmp_lt    = ~both_zero & lt_total;
    wire any_nan   = a_nan | b_nan;
    wire any_snan  = a_snan | b_snan;

    // feq (f3 010) is quiet: NV only for a signaling NaN. flt (001) and
    // fle (000) signal: NV for any NaN. A NaN makes every compare false.
    wire        cmp_true = ~any_nan & (f3[1] ? cmp_eq : f3[0] ? cmp_lt : (cmp_lt | cmp_eq));
    wire        cmp_nv   = f3[1] ? any_snan : any_nan;

    // fmin (f3 000) / fmax (001): one NaN returns the other operand, two
    // return the canonical NaN, and NV is only for a signaling NaN.
    wire [31:0] mnmx_pick = (lt_total ^ f3[0]) ? i_frs1 : i_frs2;
    wire [31:0] mnmx_res  = (a_nan & b_nan) ? CANON_NAN :
                            a_nan           ? i_frs2 :
                            b_nan           ? i_frs1 :
                                              mnmx_pick;
    wire        mnmx_nv   = any_snan;

    // fclass.s: one-hot class of fs1 (phase_6.pdf 4.7.5).
    wire [9:0]  fclass = {a_qnan, a_snan,
                          a_inf & ~a_sign, a_norm & ~a_sign, a_sub & ~a_sign, a_zero & ~a_sign,
                          a_zero & a_sign, a_sub & a_sign, a_norm & a_sign, a_inf & a_sign};

    // ------------------------------------------------------------------
    // CSR instructions (phase_6.pdf 4.6.2). csr[1:0]: 01 fflags, 10 frm,
    // 11 fcsr (the decoder rejects every other address). The register
    // forms take the source from x[rs1], the i forms from uimm = inst[19:15].
    // csrrs/csrrc skip the write when the rs1/uimm field is 0, whatever
    // the register holds; rd = x0 still writes.
    // ------------------------------------------------------------------
    wire [1:0] csr_addr = i_inst[21:20];
    wire [7:0] csr_old  = (csr_addr == 2'b01) ? {3'd0, fflags} :
                          (csr_addr == 2'b10) ? {5'd0, frm} :
                                                {frm, fflags};
    wire [7:0] csr_src  = f3[2] ? {3'd0, rs1f} : i_xrs1[7:0];
    wire [7:0] csr_new  = (f3[1:0] == 2'b01) ? csr_src :
                          (f3[1:0] == 2'b10) ? (csr_old | csr_src) :
                                               (csr_old & ~csr_src);
    wire       csr_wr   = (f3[1:0] == 2'b01) | (rs1f != 5'd0);
    // Each field keeps only its own width: writing frm takes the low 3 bits.
    wire       csr_wr_ff  = is_csr & csr_wr & (csr_addr != 2'b10);
    wire       csr_wr_frm = is_csr & csr_wr & csr_addr[1];
    wire [2:0] csr_frm    = (csr_addr == 2'b10) ? csr_new[2:0] : csr_new[7:5];

    // ------------------------------------------------------------------
    // Special operands of the rounding instructions, resolved here
    // (docs/fpu_interfaces.md). Every result is exact. The datapaths only
    // start when none of these applies.
    // ------------------------------------------------------------------
    // The FMA's effective operands: a*b + c, with the sign flips applied.
    // fadd/fsub are fs1*1.0 +/- fs2; fmul skips the addend. The fused ops
    // negate the product (fnmsub, fnmadd: opc[3]) and the addend (fmsub,
    // fnmadd: opc[2]).
    wire neg_prod  = is_fused & opc[3];
    wire neg_add   = (is_fused & opc[2]) | op_fsub;
    wire mul_only  = op_fmul;
    wire fa_sign   = a_sign ^ neg_prod;
    wire fb_sign   = op_addsub ? 1'b0 : b_sign;
    wire fb_zero   = ~op_addsub & b_zero;
    wire fb_inf    = ~op_addsub & b_inf;
    wire fb_nan    = ~op_addsub & b_nan;
    wire fb_snan   = ~op_addsub & b_snan;
    wire fc_sign   = (op_addsub ? b_sign : c_sign) ^ neg_add;
    wire fc_inf    = ~mul_only & (op_addsub ? b_inf  : c_inf);
    wire fc_nan    = ~mul_only & (op_addsub ? b_nan  : c_nan);
    wire fc_snan   = ~mul_only & (op_addsub ? b_snan : c_snan);

    // inf*0 is NV even when the addend is a quiet NaN (phase_6.pdf 4.7.3).
    wire fma_inv_mul = (a_inf & fb_zero) | (a_zero & fb_inf);
    wire fma_nan_in  = a_nan | fb_nan | fc_nan;
    wire fma_snan_in = a_snan | fb_snan | fc_snan;
    wire fma_p_inf   = a_inf | fb_inf;
    wire fma_p_sign  = fa_sign ^ fb_sign;
    wire fma_inv_add = fma_p_inf & fc_inf & (fma_p_sign != fc_sign);
    wire fma_nan_out = fma_inv_mul | fma_nan_in | fma_inv_add;
    wire fma_special = fma_nan_out | fma_p_inf | fc_inf;
    wire fma_s_nv    = fma_inv_mul | fma_snan_in | fma_inv_add;
    wire [31:0] fma_s_res = fma_nan_out ? CANON_NAN :
                            fma_p_inf   ? {fma_p_sign, 31'h7F800000} :
                                          {fc_sign, 31'h7F800000};

    // fdiv / fsqrt. The divider only sees finite nonzero operands, and
    // square root only positive ones.
    wire        q_sign     = a_sign ^ b_sign;
    wire        div_nan    = any_nan | (a_inf & b_inf) | (a_zero & b_zero);
    wire        div_nv     = any_snan | (a_inf & b_inf) | (a_zero & b_zero);
    wire        div_inf    = a_inf | b_zero;  // after the NaN cases
    wire        div_dz     = ~a_inf & ~a_zero & ~a_nan & b_zero;
    wire        div_special = any_nan | a_inf | b_inf | a_zero | b_zero;
    wire [31:0] div_s_res  = div_nan ? CANON_NAN :
                             div_inf ? {q_sign, 31'h7F800000} :
                                       {q_sign, 31'h00000000};
    wire        sqrt_nan    = a_nan | (a_sign & ~a_zero);
    wire        sqrt_nv     = a_snan | (a_sign & ~a_zero & ~a_nan);
    wire        sqrt_special = a_nan | a_zero | a_sign | a_inf;
    // +-0 returns itself, +inf returns +inf.
    wire [31:0] sqrt_s_res  = sqrt_nan ? CANON_NAN : i_frs1;

    wire        ds_special = op_fsqrt ? sqrt_special : div_special;
    wire [31:0] ds_s_res   = op_fsqrt ? sqrt_s_res : div_s_res;
    wire [ 4:0] ds_s_flags = op_fsqrt ? {sqrt_nv, 4'b0000} : {div_nv, div_dz, 3'b000};

    // fcvt.w[u].s of NaN or infinity saturates with NV (phase_6.pdf 4.7.6).
    wire        f2i_special = a_nan | a_inf;
    wire        f2i_neg     = a_inf & a_sign;
    wire [31:0] f2i_s_res   = cvt_unsigned ? (f2i_neg ? 32'h00000000 : 32'hFFFFFFFF) :
                                             (f2i_neg ? 32'h80000000 : 32'h7FFFFFFF);

    wire        arith_special = (op_fma & fma_special) | (op_ds & ds_special);
    wire [31:0] arith_s_res   = op_ds ? ds_s_res : fma_s_res;
    wire [ 4:0] arith_s_flags = op_ds ? ds_s_flags : {fma_s_nv, 4'b0000};

    // ------------------------------------------------------------------
    // Datapaths. Each one starts only for its own instruction, when it
    // doesn't trap and has no special operand. fmul skips the addend, and
    // fadd/fsub multiply by 1.0 (docs/fpu_interfaces.md has the table).
    // ------------------------------------------------------------------
    wire        fma_valid    = i_valid & op_fma & ~o_rm_trap & ~fma_special;
    wire        ds_valid     = i_valid & op_ds & ~o_rm_trap & ~ds_special;

    wire        fma_a_sign   = fa_sign;
    wire [ 9:0] fma_a_exp    = a_nexp;
    wire [23:0] fma_a_sig    = a_nsig;
    wire        fma_b_sign   = fb_sign;
    wire [ 9:0] fma_b_exp    = op_addsub ? 10'd127 : b_nexp;
    wire [23:0] fma_b_sig    = op_addsub ? 24'h800000 : b_nsig;
    wire        fma_c_sign   = fc_sign;
    wire [ 9:0] fma_c_exp    = op_addsub ? b_nexp : c_nexp;
    wire [23:0] fma_c_sig    = op_addsub ? b_nsig : c_nsig;

    wire        fma_busy;
    wire        fma_o_sign;
    wire [ 9:0] fma_o_exp;
    wire [25:0] fma_o_sig;

    // MISSING UNIT: fpu_fma (Bowen) is not on main yet, so fadd, fsub,
    // fmul and the fused instructions return 0 with no flags (special
    // operands still work, above). When fpu_fma.v lands, delete the four
    // tie-off assigns below and uncomment this instance:
    //
    // fpu_fma u_fma (
    //     .i_clk     (i_clk),
    //     .i_rst     (i_rst),
    //     .i_valid   (fma_valid),
    //     .i_advance (i_advance),
    //     .i_mul_only(mul_only),
    //     .i_rm      (rm),
    //     .i_a_sign  (fma_a_sign),
    //     .i_a_exp   (fma_a_exp),
    //     .i_a_sig   (fma_a_sig),
    //     .i_b_sign  (fma_b_sign),
    //     .i_b_exp   (fma_b_exp),
    //     .i_b_sig   (fma_b_sig),
    //     .i_c_sign  (fma_c_sign),
    //     .i_c_exp   (fma_c_exp),
    //     .i_c_sig   (fma_c_sig),
    //     .o_busy    (fma_busy),
    //     .o_sign    (fma_o_sign),
    //     .o_exp     (fma_o_exp),
    //     .o_sig     (fma_o_sig)
    // );
    assign fma_busy   = 1'b0;
    assign fma_o_sign = 1'b0;
    assign fma_o_exp  = 10'd0;
    assign fma_o_sig  = 26'd0;

    wire        ds_busy;
    wire        ds_o_sign;
    wire [ 9:0] ds_o_exp;
    wire [25:0] ds_o_sig;

    // MISSING UNIT: fpu_divsqrt (Bradly) is not on main yet, so fdiv and
    // fsqrt return 0 with no flags and never stall (special operands still
    // work, above). When fpu_divsqrt.v lands, delete the four tie-off
    // assigns below and uncomment this instance:
    //
    // fpu_divsqrt u_divsqrt (
    //     .i_clk    (i_clk),
    //     .i_rst    (i_rst),
    //     .i_valid  (ds_valid),
    //     .i_advance(i_advance),
    //     .i_sqrt   (op_fsqrt),
    //     .i_a_sign (a_sign),
    //     .i_a_exp  (a_nexp),
    //     .i_a_sig  (a_nsig),
    //     .i_b_sign (b_sign),
    //     .i_b_exp  (b_nexp),
    //     .i_b_sig  (b_nsig),
    //     .o_busy   (ds_busy),
    //     .o_sign   (ds_o_sign),
    //     .o_exp    (ds_o_exp),
    //     .o_sig    (ds_o_sig)
    // );
    assign ds_busy   = 1'b0;
    assign ds_o_sign = 1'b0;
    assign ds_o_exp  = 10'd0;
    assign ds_o_sig  = 26'd0;

    wire [31:0] cvt_f2i_result;
    wire [ 4:0] cvt_f2i_flags;
    wire        cvt_i2f_sign;
    wire [ 9:0] cvt_i2f_exp;
    wire [25:0] cvt_i2f_sig;

    // MISSING UNIT: fpu_cvt (Bowen) is not on main yet, so fcvt.w[u].s
    // and fcvt.s.w[u] return 0 with no flags (fcvt.w[u].s of NaN and
    // infinity still works, above). When fpu_cvt.v lands, delete the five
    // tie-off assigns below and uncomment this instance:
    //
    // fpu_cvt u_cvt (
    //     .i_unsigned  (cvt_unsigned),
    //     .i_rm        (rm),
    //     .i_a_sign    (a_sign),
    //     .i_a_exp     (a_nexp),
    //     .i_a_sig     (a_nsig),
    //     .o_f2i_result(cvt_f2i_result),
    //     .o_f2i_flags (cvt_f2i_flags),
    //     .i_int       (i_xrs1),
    //     .o_i2f_sign  (cvt_i2f_sign),
    //     .o_i2f_exp   (cvt_i2f_exp),
    //     .o_i2f_sig   (cvt_i2f_sig)
    // );
    assign cvt_f2i_result = 32'd0;
    assign cvt_f2i_flags  = 5'd0;
    assign cvt_i2f_sign   = 1'b0;
    assign cvt_i2f_exp    = 10'd0;
    assign cvt_i2f_sig    = 26'd0;

    // The one rounder, shared by every rounding instruction. Only one is in
    // EX at a time, and each datapath holds its output until i_advance.
    wire        rnd_sign = op_ds ? ds_o_sign : op_i2f ? cvt_i2f_sign : fma_o_sign;
    wire [ 9:0] rnd_exp  = op_ds ? ds_o_exp  : op_i2f ? cvt_i2f_exp  : fma_o_exp;
    wire [25:0] rnd_sig  = op_ds ? ds_o_sig  : op_i2f ? cvt_i2f_sig  : fma_o_sig;
    wire [31:0] rnd_result;
    wire [ 4:0] rnd_flags;

    // MISSING UNIT: fpu_round (Bowen) is not on main yet, so every
    // rounding instruction without a special operand returns 0 with no
    // flags. When fpu_round.v lands, delete the two tie-off assigns below
    // and uncomment this instance:
    //
    // fpu_round u_round (
    //     .i_sign  (rnd_sign),
    //     .i_exp   (rnd_exp),
    //     .i_sig   (rnd_sig),
    //     .i_rm    (rm),
    //     .o_result(rnd_result),
    //     .o_flags (rnd_flags)
    // );
    assign rnd_result = 32'd0;
    assign rnd_flags  = 5'd0;

    // A datapath's busy only counts for the instruction that started it.
    // Nothing here depends on i_advance: the hart's i_advance depends on
    // o_busy.
    assign o_busy = (fma_valid & fma_busy) | (ds_valid & ds_busy);

    // ------------------------------------------------------------------
    // Results and flags
    // ------------------------------------------------------------------
    assign o_fp_result  = op_sgnj  ? sgnj_res :
                          op_mnmx  ? mnmx_res :
                          op_mvwx  ? i_xrs1 :
                          arith_special ? arith_s_res :
                                     rnd_result;

    assign o_int_result = is_csr   ? {24'd0, csr_old} :
                          op_cmp   ? {31'd0, cmp_true} :
                          op_mvcls ? (f3[0] ? {22'd0, fclass} : i_frs1) :
                          op_f2i   ? (f2i_special ? f2i_s_res : cvt_f2i_result) :
                                     32'd0;

    // This instruction's own flags.
    wire [4:0] op_flags = op_mnmx  ? {mnmx_nv, 4'b0000} :
                          op_cmp   ? {cmp_nv, 4'b0000} :
                          op_f2i   ? (f2i_special ? 5'b10000 : cvt_f2i_flags) :
                          op_round ? (arith_special ? arith_s_flags : rnd_flags) :
                                     5'b00000;

    // fcsr after this instruction. Flags accrue; only a CSR write clears.
    wire [4:0] ff_after  = is_csr ? (csr_wr_ff ? csr_new[4:0] : fflags) : (fflags | op_flags);
    wire [2:0] frm_after = csr_wr_frm ? csr_frm : frm;

    // The current flags while nothing runs or the instruction traps.
    assign o_fflags = (i_valid & ~o_rm_trap) ? ff_after : fflags;

    // fcsr changes once per instruction, on the edge where it leaves EX
    // (phase_6.pdf 5.3.3). A trapped instruction changes nothing.
    always @(posedge i_clk) begin
        if (i_rst) begin
            fflags <= 5'd0;
            frm    <= 3'd0;
        end else if (i_valid & i_advance & ~o_rm_trap) begin
            fflags <= ff_after;
            frm    <= frm_after;
        end
    end

endmodule

`default_nettype wire
