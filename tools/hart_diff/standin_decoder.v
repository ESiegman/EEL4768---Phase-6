`default_nettype none

// TEST ONLY -- not synthesizable, never submit. See tools/hart_diff/README.md.
// Phase 6 decoder ports (skeleton + o_uses_rs1/o_uses_rs2) around the
// phase 5 decoder, snapshotted as decoder_i in rv32i_decoder.v. M, flw and
// fsw are reshaped into RV32I instructions it already knows; F and CSR
// legality is decoded here.
module decoder (
    input  wire [31:0] i_inst,
    output wire        o_legal,
    output wire        o_halt,
    output wire [ 4:0] o_rs1,
    output wire [ 4:0] o_rs2,
    output wire [ 4:0] o_rd,
    output wire [31:0] o_immediate,
    output wire        o_op1_sel,
    output wire        o_op2_sel,
    output wire [ 2:0] o_alu_opsel,
    output wire        o_alu_sub,
    output wire        o_alu_unsigned,
    output wire        o_alu_arith,
    output wire        o_branch,
    output wire        o_jump,
    output wire        o_branch_equal,
    output wire        o_branch_unsigned,
    output wire        o_branch_invert,
    output wire        o_dmem_ren,
    output wire        o_dmem_wen,
    output wire [ 1:0] o_dmem_align,
    output wire        o_dmem_memb,
    output wire        o_dmem_memh,
    output wire        o_dmem_memw,
    output wire        o_dmem_memu,
    output wire [ 4:0] o_rd_sel,
    output wire        o_mext,
    output wire        o_fpu,
    output wire        o_frs1_en,
    output wire        o_frs2_en,
    output wire        o_frs3_en,
    output wire [ 4:0] o_rs3,
    output wire        o_frd_en,
    output wire        o_pc_sel,
    output wire        o_uses_rs1,
    output wire        o_uses_rs2
);
    wire [6:0] opc = i_inst[6:0];
    wire [2:0] f3  = i_inst[14:12];
    wire [6:0] f7  = i_inst[31:25];
    wire [4:0] r2  = i_inst[24:20];
    wire [11:0] csr = i_inst[31:20];

    wire is_m    = opc == 7'b0110011 && f7 == 7'b0000001;
    wire is_flw  = opc == 7'b0000111 && f3 == 3'b010;
    wire is_fsw  = opc == 7'b0100111 && f3 == 3'b010;
    wire rm_ok   = f3 != 3'b101 && f3 != 3'b110;
    wire is_fma  = (opc == 7'b1000011 || opc == 7'b1000111 || opc == 7'b1001011 ||
                    opc == 7'b1001111) && i_inst[26:25] == 2'b00 && rm_ok;
    wire opfp    = opc == 7'b1010011;
    wire fadd    = opfp && (f7 == 7'h00 || f7 == 7'h04 || f7 == 7'h08 || f7 == 7'h0C) && rm_ok;
    wire fsqrt   = opfp && f7 == 7'h2C && r2 == 0 && rm_ok;
    wire fsgnj   = opfp && f7 == 7'h10 && (f3 == 0 || f3 == 1 || f3 == 2);
    wire fminmax = opfp && f7 == 7'h14 && (f3 == 0 || f3 == 1);
    wire fcvtws  = opfp && f7 == 7'h60 && (r2 == 0 || r2 == 1) && rm_ok;
    wire fmvxw   = opfp && f7 == 7'h70 && r2 == 0 && (f3 == 0 || f3 == 1);
    wire fcmp    = opfp && f7 == 7'h50 && (f3 == 0 || f3 == 1 || f3 == 2);
    wire fcvtsw  = opfp && f7 == 7'h68 && (r2 == 0 || r2 == 1) && rm_ok;
    wire fmvwx   = opfp && f7 == 7'h78 && r2 == 0 && f3 == 0;
    wire is_csr  = opc == 7'b1110011 && f3 != 0 && f3 != 3'b100 &&
                   (csr == 12'h001 || csr == 12'h002 || csr == 12'h003);

    wire f_int_rd = fcvtws | fmvxw | fcmp | is_csr;
    wire f_fp_rd  = fadd | fsqrt | fsgnj | fminmax | fcvtsw | fmvwx | is_fma;
    wire f_any    = f_int_rd | f_fp_rd;

    // Let the RV32I decoder handle M (as add/sub-shaped OP), flw (as lw)
    // and fsw (as sw).
    wire [31:0] inner_inst = is_m   ? {7'b0000000, i_inst[24:0]} :
                             is_flw ? {i_inst[31:7], 7'b0000011} :
                             is_fsw ? {i_inst[31:7], 7'b0100011} : i_inst;
    wire       i_legal, i_uses_rs1, i_uses_rs2, i_is_load;
    wire [4:0] i_rd;
    wire [3:0] i_rd_sel;
    wire       i_branch, i_jump, i_dren, i_dwen;

    decoder_i inner (
        .i_inst(inner_inst), .o_legal(i_legal), .o_halt(o_halt), .o_rs1(o_rs1),
        .o_rs2(o_rs2), .o_rd(i_rd), .o_immediate(o_immediate), .o_op1_sel(o_op1_sel),
        .o_op2_sel(o_op2_sel), .o_alu_opsel(o_alu_opsel), .o_alu_sub(o_alu_sub),
        .o_alu_unsigned(o_alu_unsigned), .o_alu_arith(o_alu_arith), .o_branch(i_branch),
        .o_jump(i_jump), .o_branch_equal(o_branch_equal),
        .o_branch_unsigned(o_branch_unsigned), .o_branch_invert(o_branch_invert),
        .o_dmem_ren(i_dren), .o_dmem_wen(i_dwen), .o_dmem_align(o_dmem_align),
        .o_dmem_memb(o_dmem_memb), .o_dmem_memh(o_dmem_memh), .o_dmem_memw(o_dmem_memw),
        .o_dmem_memu(o_dmem_memu), .o_rd_sel(i_rd_sel), .o_pc_sel(o_pc_sel),
        .o_uses_rs1(i_uses_rs1), .o_uses_rs2(i_uses_rs2), .o_is_load(i_is_load)
    );

    assign o_legal   = f_any ? 1'b1 : i_legal;
    assign o_mext    = is_m & i_legal;
    assign o_fpu     = f_any;
    assign o_frs1_en = f_any & ~(fcvtsw | fmvwx | is_csr);
    assign o_frs2_en = is_fsw | fadd | fsgnj | fminmax | fcmp | is_fma;
    assign o_frs3_en = is_fma;
    assign o_rs3     = i_inst[31:27];
    assign o_frd_en  = is_flw | f_fp_rd;
    assign o_rd      = (is_flw | f_fp_rd) ? 5'd0 : f_int_rd ? i_inst[11:7] : i_rd;
    assign o_rd_sel  = f_int_rd ? 5'b10000 : f_fp_rd ? 5'b00000 : {1'b0, i_rd_sel};
    assign o_uses_rs1 = f_any ? (fcvtsw | fmvwx | (is_csr & ~f3[2])) : i_uses_rs1;
    assign o_uses_rs2 = is_fsw ? 1'b0 : f_any ? 1'b0 : i_uses_rs2;
    assign o_branch  = f_any ? 1'b0 : i_branch;
    assign o_jump    = f_any ? 1'b0 : i_jump;
    assign o_dmem_ren = f_any ? 1'b0 : i_dren;
    assign o_dmem_wen = f_any ? 1'b0 : i_dwen;
endmodule

`default_nettype wire
