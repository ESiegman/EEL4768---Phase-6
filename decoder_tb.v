`timescale 1ns / 1ps
`default_nettype none
module decoder_tb;

  // Policy switch: the spec gives o_branch_equal / o_branch_unsigned /
  // o_branch_invert as bare funct3 formulas with no "only for branches"
  // qualifier, so by default this testbench expects them to follow funct3
  // on EVERY instruction.

  
  localparam BRANCH_FLAGS_GATED = 0;

  localparam [6:0] OPC_LUI    = 7'b0110111;
  localparam [6:0] OPC_AUIPC  = 7'b0010111;
  localparam [6:0] OPC_JAL    = 7'b1101111;
  localparam [6:0] OPC_JALR   = 7'b1100111;
  localparam [6:0] OPC_BRANCH = 7'b1100011;
  localparam [6:0] OPC_LOAD   = 7'b0000011;
  localparam [6:0] OPC_STORE  = 7'b0100011;
  localparam [6:0] OPC_OPIMM  = 7'b0010011;
  localparam [6:0] OPC_OP     = 7'b0110011;
  localparam [6:0] OPC_SYSTEM = 7'b1110011;

  localparam [6:0] F7_ZERO = 7'b0000000;
  localparam [6:0] F7_ALT  = 7'b0100000;

  // --------------------------------------------------------------------
  // DUT
  // --------------------------------------------------------------------
  reg  [31:0] inst;

  wire        o_legal;
  wire        o_halt;
  wire [ 4:0] o_rs1;
  wire [ 4:0] o_rs2;
  wire [ 4:0] o_rd;
  wire [31:0] o_immediate;
  wire        o_op1_sel;
  wire        o_op2_sel;
  wire [ 2:0] o_alu_opsel;
  wire        o_alu_sub;
  wire        o_alu_unsigned;
  wire        o_alu_arith;
  wire        o_branch;
  wire        o_jump;
  wire        o_branch_equal;
  wire        o_branch_unsigned;
  wire        o_branch_invert;
  wire        o_dmem_ren;
  wire        o_dmem_wen;
  wire [ 1:0] o_dmem_align;
  wire        o_dmem_memb;
  wire        o_dmem_memh;
  wire        o_dmem_memw;
  wire        o_dmem_memu;
  wire [ 4:0] o_rd_sel;
  wire        o_pc_sel;
  wire        o_uses_rs1;
  wire        o_uses_rs2;
  wire        o_mext;
  wire        o_fpu;
  wire        o_frs1_en;
  wire        o_frs2_en;
  wire        o_frs3_en;
  wire [ 4:0] o_rs3;
  wire        o_frd_en;

  decoder dut (
      .i_inst           (inst),
      .o_legal          (o_legal),
      .o_halt           (o_halt),
      .o_rs1            (o_rs1),
      .o_rs2            (o_rs2),
      .o_rd             (o_rd),
      .o_immediate      (o_immediate),
      .o_op1_sel        (o_op1_sel),
      .o_op2_sel        (o_op2_sel),
      .o_alu_opsel      (o_alu_opsel),
      .o_alu_sub        (o_alu_sub),
      .o_alu_unsigned   (o_alu_unsigned),
      .o_alu_arith      (o_alu_arith),
      .o_branch         (o_branch),
      .o_jump           (o_jump),
      .o_branch_equal   (o_branch_equal),
      .o_branch_unsigned(o_branch_unsigned),
      .o_branch_invert  (o_branch_invert),
      .o_dmem_ren       (o_dmem_ren),
      .o_dmem_wen       (o_dmem_wen),
      .o_dmem_align     (o_dmem_align),
      .o_dmem_memb      (o_dmem_memb),
      .o_dmem_memh      (o_dmem_memh),
      .o_dmem_memw      (o_dmem_memw),
      .o_dmem_memu      (o_dmem_memu),
      .o_rd_sel         (o_rd_sel),
      .o_pc_sel         (o_pc_sel),
      .o_uses_rs1       (o_uses_rs1),
      .o_uses_rs2       (o_uses_rs2),
      .o_mext           (o_mext),
      .o_fpu            (o_fpu),
      .o_frs1_en        (o_frs1_en),
      .o_frs2_en        (o_frs2_en),
      .o_frs3_en        (o_frs3_en),
      .o_rs3            (o_rs3),
      .o_frd_en         (o_frd_en)
  );

  // --------------------------------------------------------------------
  // Expected values
  // --------------------------------------------------------------------
  reg        e_legal;
  reg        e_halt;
  reg [ 4:0] e_rs1;
  reg [ 4:0] e_rs2;
  reg [ 4:0] e_rd;
  reg [31:0] e_immediate;
  reg        e_imm_valid;  // 0 => immediate is a don't care for this word
  reg        e_op1_sel;
  reg        e_op2_sel;
  reg [ 2:0] e_alu_opsel;
  reg        e_alu_sub;
  reg        e_alu_unsigned;
  reg        e_alu_arith;
  reg        e_branch;
  reg        e_jump;
  reg        e_branch_equal;
  reg        e_branch_unsigned;
  reg        e_branch_invert;
  reg        e_dmem_ren;
  reg        e_dmem_wen;
  reg [ 1:0] e_dmem_align;
  reg        e_dmem_memb;
  reg        e_dmem_memh;
  reg        e_dmem_memw;
  reg        e_dmem_memu;
  reg [ 4:0] e_rd_sel;
  reg        e_pc_sel;
  reg        e_uses_rs1;
  reg        e_uses_rs2;
  reg        e_mext;
  reg        e_fpu;
  reg        e_frs1_en;
  reg        e_frs2_en;
  reg        e_frs3_en;
  reg [ 4:0] e_rs3;
  reg        e_frd_en;

  integer pass_count;
  integer fail_count;

  // --------------------------------------------------------------------
  // Instruction encoders (RV32I reference card layouts)
  // --------------------------------------------------------------------
  function [31:0] enc_r;
    input [6:0] f7;
    input [4:0] rs2;
    input [4:0] rs1;
    input [2:0] f3;
    input [4:0] rd;
    input [6:0] op;
    begin
      enc_r = {f7, rs2, rs1, f3, rd, op};
    end
  endfunction

  function [31:0] enc_i;
    input [11:0] imm;
    input [ 4:0] rs1;
    input [ 2:0] f3;
    input [ 4:0] rd;
    input [ 6:0] op;
    begin
      enc_i = {imm, rs1, f3, rd, op};
    end
  endfunction

  function [31:0] enc_s;
    input [11:0] imm;
    input [ 4:0] rs2;
    input [ 4:0] rs1;
    input [ 2:0] f3;
    input [ 6:0] op;
    begin
      enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], op};
    end
  endfunction

  function [31:0] enc_b;
    input [12:0] imm;  // imm[0] is always zero
    input [ 4:0] rs2;
    input [ 4:0] rs1;
    input [ 2:0] f3;
    input [ 6:0] op;
    begin
      enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], op};
    end
  endfunction

  function [31:0] enc_u;
    input [31:0] imm;  // only imm[31:12] is encoded
    input [ 4:0] rd;
    input [ 6:0] op;
    begin
      enc_u = {imm[31:12], rd, op};
    end
  endfunction

  function [31:0] enc_j;
    input [20:0] imm;  // imm[0] is always zero
    input [ 4:0] rd;
    input [ 6:0] op;
    begin
      enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, op};
    end
  endfunction

  // Sign / zero extension helpers for the expected immediate values
  function [31:0] sext12;
    input [11:0] v;
    begin
      sext12 = {{20{v[11]}}, v};
    end
  endfunction

  function [31:0] sext13;
    input [12:0] v;
    begin
      sext13 = {{19{v[12]}}, v};
    end
  endfunction

  function [31:0] sext21;
    input [20:0] v;
    begin
      sext21 = {{11{v[20]}}, v};
    end
  endfunction


  // Expectation defaults
  // Call AFTER setting `inst`. Establishes the baseline every instruction
  // shares -- illegal, no register write, no memory access -- so each test
  // only states what makes it different.
  //
  // o_rs1 and o_rs2 are unconditional field extractions per the spec, so
  // they always come straight from the instruction word.
  task expect_defaults;
    begin
      e_legal           = 1'b0;
      e_halt            = 1'b0;
      e_rs1             = inst[19:15];
      e_rs2             = inst[24:20];
      e_rd              = 5'd0;
      e_immediate       = 32'd0;
      e_imm_valid       = 1'b0;
      e_op1_sel         = 1'b0;
      e_op2_sel         = 1'b0;
      e_alu_opsel       = 3'b000;
      e_alu_sub         = 1'b0;
      e_alu_unsigned    = 1'b0;
      e_alu_arith       = 1'b0;
      e_branch          = 1'b0;
      e_jump            = 1'b0;
      e_dmem_ren        = 1'b0;
      e_dmem_wen        = 1'b0;
      e_dmem_align      = 2'b00;
      e_dmem_memb       = 1'b0;
      e_dmem_memh       = 1'b0;
      e_dmem_memw       = 1'b0;
      e_dmem_memu       = 1'b0;
      e_rd_sel          = 5'b00000;
      e_pc_sel          = 1'b0;
      e_uses_rs1        = 1'b0;
      e_uses_rs2        = 1'b0;
      e_mext            = 1'b0;
      e_fpu             = 1'b0;
      e_frs1_en         = 1'b0;
      e_frs2_en         = 1'b0;
      e_frs3_en         = 1'b0;
      e_rs3             = inst[31:27];
      e_frd_en          = 1'b0;

      if (BRANCH_FLAGS_GATED) begin
        e_branch_equal    = 1'b0;
        e_branch_unsigned = 1'b0;
        e_branch_invert   = 1'b0;
      end else begin
        e_branch_equal    = ~inst[14];
        e_branch_unsigned = inst[13];
        e_branch_invert   = inst[12];
      end
    end
  endtask

  // Checker -- compares every output, every time
  task check;
    input [8*48-1:0] name;
    reg bad;
    begin
      #1;
      bad = 1'b0;

      if (o_legal           !== e_legal)           bad = 1'b1;
      if (o_halt            !== e_halt)            bad = 1'b1;
      if (o_rs1             !== e_rs1)             bad = 1'b1;
      if (o_rs2             !== e_rs2)             bad = 1'b1;
      if (o_rd              !== e_rd)              bad = 1'b1;
      if (e_imm_valid && (o_immediate !== e_immediate)) bad = 1'b1;
      if (o_op1_sel         !== e_op1_sel)         bad = 1'b1;
      if (o_op2_sel         !== e_op2_sel)         bad = 1'b1;
      if (o_alu_opsel       !== e_alu_opsel)       bad = 1'b1;
      if (o_alu_sub         !== e_alu_sub)         bad = 1'b1;
      if (o_alu_unsigned    !== e_alu_unsigned)    bad = 1'b1;
      if (o_alu_arith       !== e_alu_arith)       bad = 1'b1;
      if (o_branch          !== e_branch)          bad = 1'b1;
      if (o_jump            !== e_jump)            bad = 1'b1;
      if (o_branch_equal    !== e_branch_equal)    bad = 1'b1;
      if (o_branch_unsigned !== e_branch_unsigned) bad = 1'b1;
      if (o_branch_invert   !== e_branch_invert)   bad = 1'b1;
      if (o_dmem_ren        !== e_dmem_ren)        bad = 1'b1;
      if (o_dmem_wen        !== e_dmem_wen)        bad = 1'b1;
      if (o_dmem_align      !== e_dmem_align)      bad = 1'b1;
      if (o_dmem_memb       !== e_dmem_memb)       bad = 1'b1;
      if (o_dmem_memh       !== e_dmem_memh)       bad = 1'b1;
      if (o_dmem_memw       !== e_dmem_memw)       bad = 1'b1;
      if (o_dmem_memu       !== e_dmem_memu)       bad = 1'b1;
      if (o_rd_sel          !== e_rd_sel)          bad = 1'b1;
      if (o_pc_sel          !== e_pc_sel)          bad = 1'b1;
      if (o_uses_rs1        !== e_uses_rs1)        bad = 1'b1;
      if (o_uses_rs2        !== e_uses_rs2)        bad = 1'b1;
      if (o_mext            !== e_mext)            bad = 1'b1;
      if (o_fpu             !== e_fpu)             bad = 1'b1;
      if (o_frs1_en         !== e_frs1_en)         bad = 1'b1;
      if (o_frs2_en         !== e_frs2_en)         bad = 1'b1;
      if (o_frs3_en         !== e_frs3_en)         bad = 1'b1;
      if (o_rs3             !== e_rs3)             bad = 1'b1;
      if (o_frd_en          !== e_frd_en)          bad = 1'b1;

      if (!bad) begin
        pass_count = pass_count + 1;
        $display("[PASS] %0s", name);
      end else begin
        fail_count = fail_count + 1;
        $display("[FAIL] %0s   (inst = 32'h%08h)", name, inst);
        if (o_legal        !== e_legal)        $display("         legal:          exp=%b got=%b", e_legal, o_legal);
        if (o_halt         !== e_halt)         $display("         halt:           exp=%b got=%b", e_halt, o_halt);
        if (o_rs1          !== e_rs1)          $display("         rs1:            exp=%0d got=%0d", e_rs1, o_rs1);
        if (o_rs2          !== e_rs2)          $display("         rs2:            exp=%0d got=%0d", e_rs2, o_rs2);
        if (o_rd           !== e_rd)           $display("         rd:             exp=%0d got=%0d", e_rd, o_rd);
        if (e_imm_valid && (o_immediate !== e_immediate))
                                               $display("         immediate:      exp=32'h%08h got=32'h%08h", e_immediate, o_immediate);
        if (o_op1_sel      !== e_op1_sel)      $display("         op1_sel:        exp=%b got=%b", e_op1_sel, o_op1_sel);
        if (o_op2_sel      !== e_op2_sel)      $display("         op2_sel:        exp=%b got=%b", e_op2_sel, o_op2_sel);
        if (o_alu_opsel    !== e_alu_opsel)    $display("         alu_opsel:      exp=%b got=%b", e_alu_opsel, o_alu_opsel);
        if (o_alu_sub      !== e_alu_sub)      $display("         alu_sub:        exp=%b got=%b", e_alu_sub, o_alu_sub);
        if (o_alu_unsigned !== e_alu_unsigned) $display("         alu_unsigned:   exp=%b got=%b", e_alu_unsigned, o_alu_unsigned);
        if (o_alu_arith    !== e_alu_arith)    $display("         alu_arith:      exp=%b got=%b", e_alu_arith, o_alu_arith);
        if (o_branch       !== e_branch)       $display("         branch:         exp=%b got=%b", e_branch, o_branch);
        if (o_jump         !== e_jump)         $display("         jump:           exp=%b got=%b", e_jump, o_jump);
        if (o_branch_equal !== e_branch_equal) $display("         branch_equal:   exp=%b got=%b", e_branch_equal, o_branch_equal);
        if (o_branch_unsigned !== e_branch_unsigned) $display("         branch_unsigned:exp=%b got=%b", e_branch_unsigned, o_branch_unsigned);
        if (o_branch_invert !== e_branch_invert) $display("         branch_invert:  exp=%b got=%b", e_branch_invert, o_branch_invert);
        if (o_dmem_ren     !== e_dmem_ren)     $display("         dmem_ren:       exp=%b got=%b", e_dmem_ren, o_dmem_ren);
        if (o_dmem_wen     !== e_dmem_wen)     $display("         dmem_wen:       exp=%b got=%b", e_dmem_wen, o_dmem_wen);
        if (o_dmem_align   !== e_dmem_align)   $display("         dmem_align:     exp=%b got=%b", e_dmem_align, o_dmem_align);
        if (o_dmem_memb    !== e_dmem_memb)    $display("         dmem_memb:      exp=%b got=%b", e_dmem_memb, o_dmem_memb);
        if (o_dmem_memh    !== e_dmem_memh)    $display("         dmem_memh:      exp=%b got=%b", e_dmem_memh, o_dmem_memh);
        if (o_dmem_memw    !== e_dmem_memw)    $display("         dmem_memw:      exp=%b got=%b", e_dmem_memw, o_dmem_memw);
        if (o_dmem_memu    !== e_dmem_memu)    $display("         dmem_memu:      exp=%b got=%b", e_dmem_memu, o_dmem_memu);
        if (o_rd_sel       !== e_rd_sel)       $display("         rd_sel:         exp=%b got=%b", e_rd_sel, o_rd_sel);
        if (o_pc_sel       !== e_pc_sel)       $display("         pc_sel:         exp=%b got=%b", e_pc_sel, o_pc_sel);
        if (o_uses_rs1     !== e_uses_rs1)     $display("         uses_rs1:       exp=%b got=%b", e_uses_rs1, o_uses_rs1);
        if (o_uses_rs2     !== e_uses_rs2)     $display("         uses_rs2:       exp=%b got=%b", e_uses_rs2, o_uses_rs2);
        if (o_mext         !== e_mext)         $display("         mext:           exp=%b got=%b", e_mext, o_mext);
        if (o_fpu          !== e_fpu)          $display("         fpu:            exp=%b got=%b", e_fpu, o_fpu);
        if (o_frs1_en      !== e_frs1_en)      $display("         frs1_en:        exp=%b got=%b", e_frs1_en, o_frs1_en);
        if (o_frs2_en      !== e_frs2_en)      $display("         frs2_en:        exp=%b got=%b", e_frs2_en, o_frs2_en);
        if (o_frs3_en      !== e_frs3_en)      $display("         frs3_en:        exp=%b got=%b", e_frs3_en, o_frs3_en);
        if (o_rs3          !== e_rs3)          $display("         rs3:            exp=%0d got=%0d", e_rs3, o_rs3);
        if (o_frd_en       !== e_frd_en)       $display("         frd_en:         exp=%b got=%b", e_frd_en, o_frd_en);
      end
    end
  endtask

  // Which source registers the instruction really reads. Class-based, per
  // traces/README.md: rs1 for op, op-imm, load, store, branch and jalr; rs2
  // for op, store and branch. Everything else leaves both at the default 0.
  task expect_reads;
    input r1;
    input r2;
    begin
      e_uses_rs1 = r1;
      e_uses_rs2 = r2;
    end
  endtask

  // Shorthand for a legal register-writing instruction
  task expect_writes_rd;
    input [4:0] rd;
    input [4:0] sel;
    begin
      e_legal  = 1'b1;
      e_rd     = rd;
      e_rd_sel = sel;
    end
  endtask


  // --------------------------------------------------------------------
  // Phase 6 helpers
  // --------------------------------------------------------------------
  localparam [6:0] OPC_LOADFP  = 7'b0000111;
  localparam [6:0] OPC_STOREFP = 7'b0100111;
  localparam [6:0] OPC_OPFP    = 7'b1010011;
  localparam [6:0] OPC_MADD    = 7'b1000011;
  localparam [6:0] OPC_MSUB    = 7'b1000111;
  localparam [6:0] OPC_NMSUB   = 7'b1001011;
  localparam [6:0] OPC_NMADD   = 7'b1001111;
  localparam [6:0] F7_MEXT     = 7'b0000001;

  function [31:0] enc_r4;
    input [4:0] rs3;
    input [1:0] fmt;
    input [4:0] rs2;
    input [4:0] rs1;
    input [2:0] rm;
    input [4:0] rd;
    input [6:0] op;
    begin
      enc_r4 = {rs3, fmt, rs2, rs1, rm, rd, op};
    end
  endfunction

  // An RV32M instruction: integer rs1/rs2 -> integer rd, ALU result, opsel
  // carries funct3.
  task expect_mext;
    begin
      expect_writes_rd(inst[11:7], 5'b00001);
      expect_reads(1'b1, 1'b1);
      e_alu_opsel = inst[14:12];
      e_mext      = 1'b1;
    end
  endtask

  // An fpu instruction that writes FP rd. o_rd stays 0.
  task expect_fpu_frd;
    input fr1;
    input fr2;
    input fr3;
    input xr1;
    begin
      e_legal   = 1'b1;
      e_fpu     = 1'b1;
      e_frd_en  = 1'b1;
      e_frs1_en = fr1;
      e_frs2_en = fr2;
      e_frs3_en = fr3;
      e_uses_rs1 = xr1;
    end
  endtask

  // An fpu instruction that writes integer rd from the fpu (rd_sel[4]).
  task expect_fpu_xrd;
    input fr1;
    input fr2;
    input xr1;
    begin
      expect_writes_rd(inst[11:7], 5'b10000);
      e_fpu      = 1'b1;
      e_frs1_en  = fr1;
      e_frs2_en  = fr2;
      e_uses_rs1 = xr1;
    end
  endtask

  // Independent legality model for OP-FP, straight from phase_6.pdf 4.7
  // and 5.4.1. Returns {legal, writes_frd, reads_frs1, reads_frs2,
  // reads_xrs1}.
  function [4:0] ref_opfp;
    input [6:0] f7;
    input [2:0] f3;
    input [4:0] r2;
    reg rmok;
    begin
      rmok = (f3 != 3'b101) && (f3 != 3'b110);
      case (f7)
        7'b0000000, 7'b0000100, 7'b0001000, 7'b0001100:            // fadd fsub fmul fdiv
          ref_opfp = rmok ? 5'b11110 : 5'b00000;
        7'b0101100:                                                 // fsqrt
          ref_opfp = (rmok && r2 == 5'd0) ? 5'b11100 : 5'b00000;
        7'b0010000:                                                 // fsgnj[n|x]
          ref_opfp = (f3 <= 3'b010) ? 5'b11110 : 5'b00000;
        7'b0010100:                                                 // fmin fmax
          ref_opfp = (f3 <= 3'b001) ? 5'b11110 : 5'b00000;
        7'b1010000:                                                 // fle flt feq
          ref_opfp = (f3 <= 3'b010) ? 5'b10110 : 5'b00000;
        7'b1110000:                                                 // fmv.x.w fclass
          ref_opfp = (r2 == 5'd0 && f3 <= 3'b001) ? 5'b10100 : 5'b00000;
        7'b1100000:                                                 // fcvt.w[u].s
          ref_opfp = (rmok && r2 <= 5'd1) ? 5'b10100 : 5'b00000;
        7'b1101000:                                                 // fcvt.s.w[u]
          ref_opfp = (rmok && r2 <= 5'd1) ? 5'b11001 : 5'b00000;
        7'b1111000:                                                 // fmv.w.x
          ref_opfp = (r2 == 5'd0 && f3 == 3'b000) ? 5'b11001 : 5'b00000;
        default:
          ref_opfp = 5'b00000;
      endcase
    end
  endfunction

  integer sw_bad;   // sweep mismatches
  integer sw_n;     // sweep vectors
  integer a, b, c;
  reg [4:0] r;

  // Sweep check: the classifying outputs only, no per-vector PASS line.
  task sweep_check;
    input       x_legal;
    input       x_fpu;
    input       x_frs1;
    input       x_frs2;
    input       x_frs3;
    input       x_frd;
    input       x_xrs1;
    input [4:0] x_rd_sel;
    input [4:0] x_rd;
    begin
      #1;
      sw_n = sw_n + 1;
      if (o_legal !== x_legal || o_fpu !== x_fpu || o_frs1_en !== x_frs1 ||
          o_frs2_en !== x_frs2 || o_frs3_en !== x_frs3 || o_frd_en !== x_frd ||
          o_uses_rs1 !== x_xrs1 || o_rd_sel !== x_rd_sel || o_rd !== x_rd ||
          o_mext !== 1'b0 || o_halt !== 1'b0 || o_dmem_ren !== 1'b0 || o_dmem_wen !== 1'b0 ||
          o_branch !== 1'b0 || o_jump !== 1'b0) begin
        sw_bad = sw_bad + 1;
        if (sw_bad <= 10)
          $display("[FAIL] sweep inst=%08h: legal %b/%b fpu %b/%b frs %b%b%b/%b%b%b frd %b/%b xrs1 %b/%b rd_sel %b/%b rd %0d/%0d",
                   inst, o_legal, x_legal, o_fpu, x_fpu, o_frs1_en, o_frs2_en, o_frs3_en,
                   x_frs1, x_frs2, x_frs3, o_frd_en, x_frd, o_uses_rs1, x_xrs1,
                   o_rd_sel, x_rd_sel, o_rd, x_rd);
      end
    end
  endtask

  // Tests
  initial begin
    pass_count = 0;
    fail_count = 0;

    $display("========== decoder testbench ==========");

    $display("--- op (R-type) ---");
    // rd_sel = ALU result, op2_sel = 0 (rs2), alu_opsel = funct3

    inst = enc_r(F7_ZERO, 5'd3, 5'd2, 3'b000, 5'd1, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_alu_opsel = 3'b000;
    expect_reads(1'b1, 1'b1);
    check("add x1, x2, x3");

    inst = enc_r(F7_ALT, 5'd3, 5'd2, 3'b000, 5'd1, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_alu_opsel = 3'b000;
    e_alu_sub   = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("sub x1, x2, x3");

    inst = enc_r(F7_ZERO, 5'd7, 5'd6, 3'b001, 5'd5, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd5, 4'b0001);
    e_alu_opsel = 3'b001;
    expect_reads(1'b1, 1'b1);
    check("sll x5, x6, x7");

    inst = enc_r(F7_ZERO, 5'd7, 5'd6, 3'b010, 5'd5, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd5, 4'b0001);
    e_alu_opsel = 3'b010;
    expect_reads(1'b1, 1'b1);
    check("slt x5, x6, x7");

    inst = enc_r(F7_ZERO, 5'd7, 5'd6, 3'b011, 5'd5, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd5, 4'b0001);
    e_alu_opsel    = 3'b011;
    e_alu_unsigned = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("sltu x5, x6, x7");

    inst = enc_r(F7_ZERO, 5'd10, 5'd9, 3'b100, 5'd8, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd8, 4'b0001);
    e_alu_opsel = 3'b100;
    expect_reads(1'b1, 1'b1);
    check("xor x8, x9, x10");

    inst = enc_r(F7_ZERO, 5'd10, 5'd9, 3'b101, 5'd8, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd8, 4'b0001);
    e_alu_opsel = 3'b101;
    expect_reads(1'b1, 1'b1);
    check("srl x8, x9, x10");

    inst = enc_r(F7_ALT, 5'd10, 5'd9, 3'b101, 5'd8, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd8, 4'b0001);
    e_alu_opsel = 3'b101;
    e_alu_arith = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("sra x8, x9, x10");

    inst = enc_r(F7_ZERO, 5'd31, 5'd30, 3'b110, 5'd29, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd29, 4'b0001);
    e_alu_opsel = 3'b110;
    expect_reads(1'b1, 1'b1);
    check("or x29, x30, x31");

    inst = enc_r(F7_ZERO, 5'd31, 5'd30, 3'b111, 5'd29, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd29, 4'b0001);
    e_alu_opsel = 3'b111;
    expect_reads(1'b1, 1'b1);
    check("and x29, x30, x31");

    // rd = x0 is a legal encoding; the write is discarded by the rf, not here
    inst = enc_r(F7_ZERO, 5'd3, 5'd2, 3'b000, 5'd0, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd0, 4'b0001);
    expect_reads(1'b1, 1'b1);
    check("add x0, x2, x3 (rd = x0 still legal)");

    // ================================================================
    $display("--- op-imm (I-type) ---");
    // op2_sel = 1 (immediate), rd_sel = ALU result
    // ================================================================

    inst = enc_i(12'h123, 5'd2, 3'b000, 5'd1, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b000;
    e_immediate = sext12(12'h123);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("addi x1, x2, 0x123");

    inst = enc_i(12'hFFF, 5'd2, 3'b000, 5'd1, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_op2_sel   = 1'b1;
    e_immediate = sext12(12'hFFF);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("addi x1, x2, -1 (negative sign extend)");

    inst = enc_i(12'h800, 5'd2, 3'b000, 5'd1, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_op2_sel   = 1'b1;
    e_immediate = sext12(12'h800);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("addi x1, x2, -2048 (most negative)");

    inst = enc_i(12'h7FF, 5'd2, 3'b000, 5'd1, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_op2_sel   = 1'b1;
    e_immediate = sext12(12'h7FF);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("addi x1, x2, 2047 (most positive)");

    inst = enc_i(12'h0AA, 5'd6, 3'b010, 5'd5, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd5, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b010;
    e_immediate = sext12(12'h0AA);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("slti x5, x6, 0xAA");

    inst = enc_i(12'h0AA, 5'd6, 3'b011, 5'd5, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd5, 4'b0001);
    e_op2_sel      = 1'b1;
    e_alu_opsel    = 3'b011;
    e_alu_unsigned = 1'b1;
    e_immediate    = sext12(12'h0AA);
    e_imm_valid    = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("sltiu x5, x6, 0xAA");

    inst = enc_i(12'h0F0, 5'd9, 3'b100, 5'd8, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd8, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b100;
    e_immediate = sext12(12'h0F0);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("xori x8, x9, 0xF0");

    inst = enc_i(12'h0F0, 5'd9, 3'b110, 5'd8, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd8, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b110;
    e_immediate = sext12(12'h0F0);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("ori x8, x9, 0xF0");

    inst = enc_i(12'h0F0, 5'd9, 3'b111, 5'd8, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd8, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b111;
    e_immediate = sext12(12'h0F0);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("andi x8, x9, 0xF0");

    // Shift-immediates: funct7 occupies imm[11:5], shamt is imm[4:0]
    inst = enc_i({F7_ZERO, 5'd13}, 5'd2, 3'b001, 5'd1, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b001;
    e_immediate = sext12({F7_ZERO, 5'd13});
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("slli x1, x2, 13");

    inst = enc_i({F7_ZERO, 5'd13}, 5'd2, 3'b101, 5'd1, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b101;
    e_immediate = sext12({F7_ZERO, 5'd13});
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("srli x1, x2, 13");

    inst = enc_i({F7_ALT, 5'd13}, 5'd2, 3'b101, 5'd1, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b101;
    e_alu_arith = 1'b1;
    e_immediate = sext12({F7_ALT, 5'd13});
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("srai x1, x2, 13");

    // ================================================================
    $display("--- load (I-type) ---");
    // op2_sel = 1, alu_opsel = add (address calc), rd_sel = memory
    // ================================================================

    inst = enc_i(12'h010, 5'd2, 3'b000, 5'd1, OPC_LOAD);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b1000);
    e_op2_sel    = 1'b1;
    e_dmem_ren   = 1'b1;
    e_dmem_memb  = 1'b1;
    e_dmem_align = 2'b00;
    e_immediate  = sext12(12'h010);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("lb x1, 16(x2)");

    inst = enc_i(12'h010, 5'd2, 3'b001, 5'd1, OPC_LOAD);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b1000);
    e_op2_sel    = 1'b1;
    e_dmem_ren   = 1'b1;
    e_dmem_memh  = 1'b1;
    e_dmem_align = 2'b01;
    e_immediate  = sext12(12'h010);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("lh x1, 16(x2)");

    inst = enc_i(12'hFF0, 5'd2, 3'b010, 5'd1, OPC_LOAD);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b1000);
    e_op2_sel    = 1'b1;
    e_dmem_ren   = 1'b1;
    e_dmem_memw  = 1'b1;
    e_dmem_align = 2'b11;
    e_immediate  = sext12(12'hFF0);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("lw x1, -16(x2)");

    inst = enc_i(12'h010, 5'd2, 3'b100, 5'd1, OPC_LOAD);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b1000);
    e_op2_sel    = 1'b1;
    e_dmem_ren   = 1'b1;
    e_dmem_memb  = 1'b1;
    e_dmem_memu  = 1'b1;
    e_dmem_align = 2'b00;
    e_immediate  = sext12(12'h010);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("lbu x1, 16(x2)");

    inst = enc_i(12'h010, 5'd2, 3'b101, 5'd1, OPC_LOAD);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b1000);
    e_op2_sel    = 1'b1;
    e_dmem_ren   = 1'b1;
    e_dmem_memh  = 1'b1;
    e_dmem_memu  = 1'b1;
    e_dmem_align = 2'b01;
    e_immediate  = sext12(12'h010);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("lhu x1, 16(x2)");

    // ================================================================
    $display("--- store (S-type) ---");
    // rd MUST be 5'd0 even though inst[11:7] carries immediate bits
    // ================================================================

    inst = enc_s(12'h004, 5'd5, 5'd1, 3'b000, OPC_STORE);
    expect_defaults;
    e_legal      = 1'b1;
    e_op2_sel    = 1'b1;
    e_dmem_wen   = 1'b1;
    e_dmem_memb  = 1'b1;
    e_dmem_align = 2'b00;
    e_immediate  = sext12(12'h004);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("sb x5, 4(x1)  [rd field nonzero -> rd must be 0]");

    inst = enc_s(12'h004, 5'd5, 5'd1, 3'b001, OPC_STORE);
    expect_defaults;
    e_legal      = 1'b1;
    e_op2_sel    = 1'b1;
    e_dmem_wen   = 1'b1;
    e_dmem_memh  = 1'b1;
    e_dmem_align = 2'b01;
    e_immediate  = sext12(12'h004);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("sh x5, 4(x1)");

    inst = enc_s(12'hFFC, 5'd5, 5'd1, 3'b010, OPC_STORE);
    expect_defaults;
    e_legal      = 1'b1;
    e_op2_sel    = 1'b1;
    e_dmem_wen   = 1'b1;
    e_dmem_memw  = 1'b1;
    e_dmem_align = 2'b11;
    e_immediate  = sext12(12'hFFC);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("sw x5, -4(x1)  [negative S-type immediate]");

    $display("--- branch (B-type) ---");
    // rd MUST be 0; op2_sel = 0; pc_sel = 0 (target base is PC)

    inst = enc_b(13'h010, 5'd2, 5'd1, 3'b000, OPC_BRANCH);
    expect_defaults;
    e_legal           = 1'b1;
    e_branch          = 1'b1;
    e_branch_equal    = 1'b1;
    e_branch_unsigned = 1'b0;
    e_branch_invert   = 1'b0;
    e_alu_unsigned    = 1'b0;
    e_immediate       = sext13(13'h010);
    e_imm_valid       = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("beq x1, x2, +16");

    inst = enc_b(13'h010, 5'd2, 5'd1, 3'b001, OPC_BRANCH);
    expect_defaults;
    e_legal           = 1'b1;
    e_branch          = 1'b1;
    e_branch_equal    = 1'b1;
    e_branch_unsigned = 1'b0;
    e_branch_invert   = 1'b1;
    e_alu_unsigned    = 1'b0;
    e_immediate       = sext13(13'h010);
    e_imm_valid       = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("bne x1, x2, +16");

    inst = enc_b(13'h1FF0, 5'd2, 5'd1, 3'b100, OPC_BRANCH);
    expect_defaults;
    e_legal           = 1'b1;
    e_branch          = 1'b1;
    e_branch_equal    = 1'b0;
    e_branch_unsigned = 1'b0;
    e_branch_invert   = 1'b0;
    e_alu_unsigned    = 1'b0;
    e_immediate       = sext13(13'h1FF0);
    e_imm_valid       = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("blt x1, x2, -16  [negative B-type immediate]");

    inst = enc_b(13'h010, 5'd2, 5'd1, 3'b101, OPC_BRANCH);
    expect_defaults;
    e_legal           = 1'b1;
    e_branch          = 1'b1;
    e_branch_equal    = 1'b0;
    e_branch_unsigned = 1'b0;
    e_branch_invert   = 1'b1;
    e_alu_unsigned    = 1'b0;
    e_immediate       = sext13(13'h010);
    e_imm_valid       = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("bge x1, x2, +16");

    inst = enc_b(13'h010, 5'd2, 5'd1, 3'b110, OPC_BRANCH);
    expect_defaults;
    e_legal           = 1'b1;
    e_branch          = 1'b1;
    e_branch_equal    = 1'b0;
    e_branch_unsigned = 1'b1;
    e_branch_invert   = 1'b0;
    e_alu_unsigned    = 1'b1;
    e_immediate       = sext13(13'h010);
    e_imm_valid       = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("bltu x1, x2, +16");

    inst = enc_b(13'h010, 5'd2, 5'd1, 3'b111, OPC_BRANCH);
    expect_defaults;
    e_legal           = 1'b1;
    e_branch          = 1'b1;
    e_branch_equal    = 1'b0;
    e_branch_unsigned = 1'b1;
    e_branch_invert   = 1'b1;
    e_alu_unsigned    = 1'b1;
    e_immediate       = sext13(13'h010);
    e_imm_valid       = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("bgeu x1, x2, +16");


    $display("--- lui / auipc (U-type) ---");


    inst = enc_u(32'hDEADB000, 5'd1, OPC_LUI);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0010);  // writeback source = immediate
    e_immediate = 32'hDEADB000;
    e_imm_valid = 1'b1;
    check("lui x1, 0xDEADB");

    inst = enc_u(32'h00001000, 5'd1, OPC_AUIPC);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);  // writeback source = ALU result
    e_op1_sel   = 1'b1;               // only auipc selects the PC
    e_op2_sel   = 1'b1;
    e_immediate = 32'h00001000;
    e_imm_valid = 1'b1;
    check("auipc x1, 0x1");

    // ================================================================
    $display("--- jal / jalr ---");
    // rd_sel = PC + 4 for both; pc_sel distinguishes them
    // ================================================================

    inst = enc_j(21'h00100, 5'd1, OPC_JAL);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0100);
    e_jump      = 1'b1;
    e_pc_sel    = 1'b0;               // target base = PC
    e_immediate = sext21(21'h00100);
    e_imm_valid = 1'b1;
    check("jal x1, +256");

    inst = enc_j(21'h1FFF00, 5'd1, OPC_JAL);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0100);
    e_jump      = 1'b1;
    e_immediate = sext21(21'h1FFF00);
    e_imm_valid = 1'b1;
    check("jal x1, -256  [negative J-type immediate]");

    inst = enc_i(12'h008, 5'd2, 3'b000, 5'd1, OPC_JALR);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0100);
    e_jump      = 1'b1;
    e_op2_sel   = 1'b1;
    e_pc_sel    = 1'b1;               // target base = rs1
    e_immediate = sext12(12'h008);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("jalr x1, 8(x2)");

    // ================================================================
    $display("--- ebreak ---");
    // ================================================================

    inst = 32'h00100073;
    expect_defaults;
    e_legal = 1'b1;
    e_halt  = 1'b1;
    check("ebreak (legal, halts)");

    // ================================================================
    $display("--- hazard outputs: false dependencies and load-use ---");
    // o_rs1/o_rs2 are raw fields, so they can name a real register even when
    // the instruction never reads it. These cases pin uses_rs1/uses_rs2 low
    // exactly where a naive hazard unit would see a match.
    // ================================================================

    // phase_4.pdf 4.2.3: addi x3, x0, 1 puts imm[4:0] = 1 in the rs2 field,
    // so after add x1, x0, x2 a hazard unit comparing o_rs2 sees "x1"
    inst = enc_i(12'd1, 5'd0, 3'b000, 5'd3, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd3, 4'b0001);
    expect_reads(1'b1, 1'b0);
    e_op2_sel   = 1'b1;
    e_immediate = 32'd1;
    e_imm_valid = 1'b1;
    check("addi x3, x0, 1: rs2 field = x1 but unused");

    // same trap on rs1: lui's immediate fills inst[19:15] (here x31) and
    // inst[24:20] (x31) and it reads neither
    inst = enc_u(32'hFFFFF000, 5'd7, OPC_LUI);
    expect_defaults;
    expect_writes_rd(5'd7, 4'b0010);
    e_immediate = 32'hFFFFF000;
    e_imm_valid = 1'b1;
    check("lui x7, 0xFFFFF: rs1/rs2 fields = x31, unused");

    // jal's offset bits also land in both fields
    inst = enc_j(21'h0FFFFE, 5'd1, OPC_JAL);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0100);
    e_jump      = 1'b1;
    e_immediate = sext21(21'h0FFFFE);
    e_imm_valid = 1'b1;
    check("jal x1, max offset: rs1/rs2 fields set, unused");

    // the load-use producer from phase_4.pdf 4.2.1: a load, and the
    // rs2 field (imm[4:0] = 4 -> x4) is not a read
    inst = enc_i(12'd4, 5'd11, 3'b010, 5'd12, OPC_LOAD);
    expect_defaults;
    expect_writes_rd(5'd12, 4'b1000);
    expect_reads(1'b1, 1'b0);
    e_op2_sel    = 1'b1;
    e_dmem_ren   = 1'b1;
    e_dmem_memw  = 1'b1;
    e_dmem_align = 2'b11;
    e_immediate  = 32'd4;
    e_imm_valid  = 1'b1;
    check("lw x12, 4(x11): load, rs2 field unused");

    // the load-store consumer: a store reads rs2 (the data) and is not a load
    inst = enc_s(12'd8, 5'd12, 5'd10, 3'b010, OPC_STORE);
    expect_defaults;
    e_legal      = 1'b1;
    expect_reads(1'b1, 1'b1);
    e_op2_sel    = 1'b1;
    e_dmem_wen   = 1'b1;
    e_dmem_memw  = 1'b1;
    e_dmem_align = 2'b11;
    e_immediate  = 32'd8;
    e_imm_valid  = 1'b1;
    check("sw x12, 8(x10): reads rs1 and rs2, not a load");

    // an illegal load funct3 must not look like a load to the hazard unit
    inst = enc_i(12'd4, 5'd11, 3'b011, 5'd12, OPC_LOAD);
    expect_defaults;
    check("load funct3=011: not a load, reads nothing");

    // ================================================================
    $display("--- illegal encodings ---");
    // All must give legal=0, halt=0, rd=0, and no memory/branch/jump
    // ================================================================

    // ecall is explicitly NOT legal in this decoder
    inst = 32'h00000073;
    expect_defaults;
    check("ecall (illegal here, halt must stay low)");

    // A SYSTEM word that is neither ecall nor ebreak
    inst = 32'h30200073;
    expect_defaults;
    check("mret (illegal)");

    // Undefined opcodes
    inst = 32'hFFFFFFFF;
    expect_defaults;
    check("all-ones word (illegal)");

    inst = 32'h00000000;
    expect_defaults;
    check("all-zeros word (illegal)");

    inst = enc_r(F7_ZERO, 5'd3, 5'd2, 3'b000, 5'd1, 7'b0001011);
    expect_defaults;
    check("custom-0 opcode (illegal)");

    // op with a bad funct7 -- rd field is nonzero, so this proves the
    // illegal path forces rd to 0 rather than passing inst[11:7] through
    inst = enc_r(7'b0100001, 5'd3, 5'd2, 3'b000, 5'd1, OPC_OP);
    expect_defaults;
    check("add with funct7=0100001 (illegal, rd must be 0)");

    inst = enc_r(F7_ALT, 5'd3, 5'd2, 3'b001, 5'd1, OPC_OP);
    expect_defaults;
    check("sll with funct7=0100000 (illegal)");

    inst = enc_r(F7_ALT, 5'd3, 5'd2, 3'b111, 5'd1, OPC_OP);
    expect_defaults;
    check("and with funct7=0100000 (illegal)");

    // op-imm shift with a bad funct7
    inst = enc_i({F7_ALT, 5'd4}, 5'd2, 3'b001, 5'd1, OPC_OPIMM);
    expect_defaults;
    check("slli with funct7=0100000 (illegal)");

    inst = enc_i({7'b0100001, 5'd4}, 5'd2, 3'b101, 5'd1, OPC_OPIMM);
    expect_defaults;
    check("srli with funct7=0100001 (illegal)");

    // Undefined load widths -- confirms the memory-size bits stay low
    inst = enc_i(12'h010, 5'd2, 3'b011, 5'd1, OPC_LOAD);
    expect_defaults;
    check("load funct3=011 (illegal, no dmem_mem* set)");

    inst = enc_i(12'h010, 5'd2, 3'b110, 5'd1, OPC_LOAD);
    expect_defaults;
    check("load funct3=110 (illegal)");

    inst = enc_i(12'h010, 5'd2, 3'b111, 5'd1, OPC_LOAD);
    expect_defaults;
    check("load funct3=111 (illegal)");

    // Undefined store widths
    inst = enc_s(12'h004, 5'd5, 5'd1, 3'b011, OPC_STORE);
    expect_defaults;
    check("store funct3=011 (illegal)");

    inst = enc_s(12'h004, 5'd5, 5'd1, 3'b111, OPC_STORE);
    expect_defaults;
    check("store funct3=111 (illegal)");

    // Reserved branch funct3 values -- nonzero rd field again
    inst = enc_b(13'h010, 5'd2, 5'd1, 3'b010, OPC_BRANCH);
    expect_defaults;
    check("branch funct3=010 (illegal, branch must stay low)");

    inst = enc_b(13'h010, 5'd2, 5'd1, 3'b011, OPC_BRANCH);
    expect_defaults;
    check("branch funct3=011 (illegal)");

    // jalr is only defined for funct3 = 000
    inst = enc_i(12'h008, 5'd2, 3'b001, 5'd1, OPC_JALR);
    expect_defaults;
    check("jalr funct3=001 (illegal, jump must stay low)");

    inst = enc_i(12'h008, 5'd2, 3'b111, 5'd1, OPC_JALR);
    expect_defaults;
    check("jalr funct3=111 (illegal)");


    // ================================================================
    $display("--- RV32M (phase_6.pdf 4.3) ---");
    // ================================================================
    inst = enc_r(F7_MEXT, 5'd3, 5'd2, 3'b000, 5'd1, OPC_OP);  expect_defaults; expect_mext; check("mul x1, x2, x3");
    inst = enc_r(F7_MEXT, 5'd6, 5'd5, 3'b001, 5'd4, OPC_OP);  expect_defaults; expect_mext; check("mulh x4, x5, x6");
    inst = enc_r(F7_MEXT, 5'd9, 5'd8, 3'b010, 5'd7, OPC_OP);  expect_defaults; expect_mext; check("mulhsu x7, x8, x9");
    inst = enc_r(F7_MEXT, 5'd12,5'd11,3'b011, 5'd10, OPC_OP); expect_defaults; expect_mext; check("mulhu x10, x11, x12 (alu_unsigned stays 0)");
    inst = enc_r(F7_MEXT, 5'd15,5'd14,3'b100, 5'd13, OPC_OP); expect_defaults; expect_mext; check("div x13, x14, x15");
    inst = enc_r(F7_MEXT, 5'd18,5'd17,3'b101, 5'd16, OPC_OP); expect_defaults; expect_mext; check("divu x16, x17, x18 (alu_arith stays 0)");
    inst = enc_r(F7_MEXT, 5'd21,5'd20,3'b110, 5'd19, OPC_OP); expect_defaults; expect_mext; check("rem x19, x20, x21");
    inst = enc_r(F7_MEXT, 5'd31,5'd30,3'b111, 5'd29, OPC_OP); expect_defaults; expect_mext; check("remu x29, x30, x31");
    inst = enc_r(F7_MEXT, 5'd3, 5'd2, 3'b100, 5'd0, OPC_OP);  expect_defaults; expect_mext; check("div x0, x2, x3 (rd = x0 still legal)");
    // funct7 = 0000001 on OP-IMM is not RV32M
    inst = enc_i({F7_MEXT, 5'd4}, 5'd2, 3'b001, 5'd1, OPC_OPIMM); expect_defaults; check("slli with funct7=0000001 (illegal)");
    inst = enc_r(7'b0000011, 5'd3, 5'd2, 3'b000, 5'd1, OPC_OP); expect_defaults; check("OP funct7=0000011 (illegal)");
    inst = enc_r(7'b0100001, 5'd3, 5'd2, 3'b100, 5'd1, OPC_OP); expect_defaults; check("OP funct7=0100001 funct3=100 (illegal)");

    // ================================================================
    $display("--- flw / fsw (phase_6.pdf 4.7.1) ---");
    // ================================================================
    inst = enc_i(12'hFFC, 5'd10, 3'b010, 5'd7, OPC_LOADFP);
    expect_defaults;
    e_legal = 1'b1; e_rd = 5'd0; e_rd_sel = 5'b01000; e_frd_en = 1'b1;
    expect_reads(1'b1, 1'b0);
    e_op2_sel = 1'b1; e_dmem_ren = 1'b1; e_dmem_memw = 1'b1; e_dmem_align = 2'b11;
    e_immediate = 32'hFFFF_FFFC; e_imm_valid = 1'b1;
    check("flw f7, -4(x10): like lw, FP rd, o_rd = 0");

    inst = enc_i(12'h010, 5'd2, 3'b010, 5'd0, OPC_LOADFP);
    expect_defaults;
    e_legal = 1'b1; e_rd_sel = 5'b01000; e_frd_en = 1'b1;
    expect_reads(1'b1, 1'b0);
    e_op2_sel = 1'b1; e_dmem_ren = 1'b1; e_dmem_memw = 1'b1; e_dmem_align = 2'b11;
    e_immediate = 32'h10; e_imm_valid = 1'b1;
    check("flw f0, 16(x2): f0 is a real register");

    inst = enc_s(12'h024, 5'd9, 5'd3, 3'b010, OPC_STOREFP);
    expect_defaults;
    e_legal = 1'b1; e_frs2_en = 1'b1;
    expect_reads(1'b1, 1'b0);   // the data register is FP, not x9
    e_op2_sel = 1'b1; e_dmem_wen = 1'b1; e_dmem_memw = 1'b1; e_dmem_align = 2'b11;
    e_immediate = 32'h24; e_imm_valid = 1'b1;
    check("fsw f9, 36(x3): FP data register, integer base");

    inst = enc_i(12'h010, 5'd2, 3'b011, 5'd1, OPC_LOADFP); expect_defaults; check("LOAD-FP funct3=011 (fld, illegal)");
    inst = enc_i(12'h010, 5'd2, 3'b000, 5'd1, OPC_LOADFP); expect_defaults; check("LOAD-FP funct3=000 (illegal)");
    inst = enc_s(12'h004, 5'd5, 5'd1, 3'b011, OPC_STOREFP); expect_defaults; check("STORE-FP funct3=011 (fsd, illegal)");
    inst = enc_s(12'h004, 5'd5, 5'd1, 3'b001, OPC_STOREFP); expect_defaults; check("STORE-FP funct3=001 (illegal)");

    // ================================================================
    $display("--- OP-FP arithmetic (phase_6.pdf 4.7.2) ---");
    // ================================================================
    inst = enc_r(7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3, OPC_OPFP); expect_defaults; expect_fpu_frd(1,1,0,0); check("fadd.s f3, f1, f2, rne");
    inst = enc_r(7'b0000100, 5'd2, 5'd1, 3'b001, 5'd3, OPC_OPFP); expect_defaults; expect_fpu_frd(1,1,0,0); check("fsub.s f3, f1, f2, rtz");
    inst = enc_r(7'b0001000, 5'd2, 5'd1, 3'b100, 5'd3, OPC_OPFP); expect_defaults; expect_fpu_frd(1,1,0,0); check("fmul.s f3, f1, f2, rmm");
    inst = enc_r(7'b0001100, 5'd2, 5'd1, 3'b111, 5'd3, OPC_OPFP); expect_defaults; expect_fpu_frd(1,1,0,0); check("fdiv.s f3, f1, f2, dyn (legal at decode)");
    inst = enc_r(7'b0101100, 5'd0, 5'd1, 3'b010, 5'd0, OPC_OPFP); expect_defaults; expect_fpu_frd(1,0,0,0); check("fsqrt.s f0, f1, rdn");
    inst = enc_r(7'b0000000, 5'd2, 5'd1, 3'b101, 5'd3, OPC_OPFP); expect_defaults; check("fadd.s rm=101 (reserved, illegal)");
    inst = enc_r(7'b0001100, 5'd2, 5'd1, 3'b110, 5'd3, OPC_OPFP); expect_defaults; check("fdiv.s rm=110 (reserved, illegal)");
    inst = enc_r(7'b0101100, 5'd1, 5'd1, 3'b000, 5'd3, OPC_OPFP); expect_defaults; check("fsqrt.s rs2=00001 (illegal)");
    inst = enc_r(7'b0000001, 5'd2, 5'd1, 3'b000, 5'd3, OPC_OPFP); expect_defaults; check("fadd.d (fmt=01, illegal)");

    // ================================================================
    $display("--- fused multiply-add (phase_6.pdf 4.7.3) ---");
    // ================================================================
    inst = enc_r4(5'd4, 2'b00, 5'd2, 5'd1, 3'b000, 5'd5, OPC_MADD);  expect_defaults; expect_fpu_frd(1,1,1,0); check("fmadd.s f5, f1, f2, f4");
    inst = enc_r4(5'd31,2'b00, 5'd30,5'd29,3'b011, 5'd28,OPC_MSUB);  expect_defaults; expect_fpu_frd(1,1,1,0); check("fmsub.s f28, f29, f30, f31, rup");
    inst = enc_r4(5'd0, 2'b00, 5'd0, 5'd0, 3'b111, 5'd0, OPC_NMSUB); expect_defaults; expect_fpu_frd(1,1,1,0); check("fnmsub.s f0, f0, f0, f0, dyn");
    inst = enc_r4(5'd9, 2'b00, 5'd8, 5'd7, 3'b100, 5'd6, OPC_NMADD); expect_defaults; expect_fpu_frd(1,1,1,0); check("fnmadd.s f6, f7, f8, f9, rmm");
    inst = enc_r4(5'd4, 2'b01, 5'd2, 5'd1, 3'b000, 5'd5, OPC_MADD);  expect_defaults; check("fmadd.d (fmt=01, illegal)");
    inst = enc_r4(5'd4, 2'b11, 5'd2, 5'd1, 3'b000, 5'd5, OPC_NMADD); expect_defaults; check("fnmadd.q (fmt=11, illegal)");
    inst = enc_r4(5'd4, 2'b00, 5'd2, 5'd1, 3'b101, 5'd5, OPC_MSUB);  expect_defaults; check("fmsub.s rm=101 (illegal)");
    inst = enc_r4(5'd4, 2'b00, 5'd2, 5'd1, 3'b110, 5'd5, OPC_NMSUB); expect_defaults; check("fnmsub.s rm=110 (illegal)");

    // ================================================================
    $display("--- sign injection, min/max (phase_6.pdf 4.7.4-4.7.5) ---");
    // ================================================================
    inst = enc_r(7'b0010000, 5'd2, 5'd1, 3'b000, 5'd3, OPC_OPFP); expect_defaults; expect_fpu_frd(1,1,0,0); check("fsgnj.s f3, f1, f2");
    inst = enc_r(7'b0010000, 5'd2, 5'd1, 3'b001, 5'd3, OPC_OPFP); expect_defaults; expect_fpu_frd(1,1,0,0); check("fsgnjn.s f3, f1, f2");
    inst = enc_r(7'b0010000, 5'd2, 5'd2, 3'b010, 5'd3, OPC_OPFP); expect_defaults; expect_fpu_frd(1,1,0,0); check("fsgnjx.s f3, f2, f2 (fabs.s)");
    inst = enc_r(7'b0010000, 5'd2, 5'd1, 3'b011, 5'd3, OPC_OPFP); expect_defaults; check("fsgnj funct3=011 (illegal)");
    inst = enc_r(7'b0010100, 5'd2, 5'd1, 3'b000, 5'd3, OPC_OPFP); expect_defaults; expect_fpu_frd(1,1,0,0); check("fmin.s f3, f1, f2");
    inst = enc_r(7'b0010100, 5'd2, 5'd1, 3'b001, 5'd3, OPC_OPFP); expect_defaults; expect_fpu_frd(1,1,0,0); check("fmax.s f3, f1, f2");
    inst = enc_r(7'b0010100, 5'd2, 5'd1, 3'b010, 5'd3, OPC_OPFP); expect_defaults; check("fmin/fmax funct3=010 (illegal)");

    // ================================================================
    $display("--- compare, classify, moves, conversions ---");
    // ================================================================
    inst = enc_r(7'b1010000, 5'd2, 5'd1, 3'b010, 5'd5, OPC_OPFP); expect_defaults; expect_fpu_xrd(1,1,0); check("feq.s x5, f1, f2");
    inst = enc_r(7'b1010000, 5'd2, 5'd1, 3'b001, 5'd5, OPC_OPFP); expect_defaults; expect_fpu_xrd(1,1,0); check("flt.s x5, f1, f2");
    inst = enc_r(7'b1010000, 5'd2, 5'd1, 3'b000, 5'd0, OPC_OPFP); expect_defaults; expect_fpu_xrd(1,1,0); check("fle.s x0, f1, f2");
    inst = enc_r(7'b1010000, 5'd2, 5'd1, 3'b011, 5'd5, OPC_OPFP); expect_defaults; check("compare funct3=011 (illegal)");
    inst = enc_r(7'b1110000, 5'd0, 5'd1, 3'b001, 5'd5, OPC_OPFP); expect_defaults; expect_fpu_xrd(1,0,0); check("fclass.s x5, f1");
    inst = enc_r(7'b1110000, 5'd0, 5'd1, 3'b000, 5'd5, OPC_OPFP); expect_defaults; expect_fpu_xrd(1,0,0); check("fmv.x.w x5, f1");
    inst = enc_r(7'b1110000, 5'd1, 5'd1, 3'b001, 5'd5, OPC_OPFP); expect_defaults; check("fclass.s rs2=00001 (illegal)");
    inst = enc_r(7'b1110000, 5'd0, 5'd1, 3'b010, 5'd5, OPC_OPFP); expect_defaults; check("fmv.x.w funct3=010 (illegal)");
    inst = enc_r(7'b1100000, 5'd0, 5'd1, 3'b001, 5'd5, OPC_OPFP); expect_defaults; expect_fpu_xrd(1,0,0); check("fcvt.w.s x5, f1, rtz");
    inst = enc_r(7'b1100000, 5'd1, 5'd1, 3'b111, 5'd5, OPC_OPFP); expect_defaults; expect_fpu_xrd(1,0,0); check("fcvt.wu.s x5, f1, dyn");
    inst = enc_r(7'b1100000, 5'd2, 5'd1, 3'b000, 5'd5, OPC_OPFP); expect_defaults; check("fcvt.l.s (rs2=00010, RV64 only, illegal)");
    inst = enc_r(7'b1100000, 5'd0, 5'd1, 3'b101, 5'd5, OPC_OPFP); expect_defaults; check("fcvt.w.s rm=101 (illegal)");
    inst = enc_r(7'b1101000, 5'd0, 5'd11,3'b000, 5'd5, OPC_OPFP); expect_defaults; expect_fpu_frd(0,0,0,1); check("fcvt.s.w f5, x11 (integer rs1)");
    inst = enc_r(7'b1101000, 5'd1, 5'd11,3'b100, 5'd5, OPC_OPFP); expect_defaults; expect_fpu_frd(0,0,0,1); check("fcvt.s.wu f5, x11, rmm");
    inst = enc_r(7'b1101000, 5'd3, 5'd11,3'b000, 5'd5, OPC_OPFP); expect_defaults; check("fcvt.s.lu (rs2=00011, illegal)");
    inst = enc_r(7'b1101000, 5'd0, 5'd11,3'b110, 5'd5, OPC_OPFP); expect_defaults; check("fcvt.s.w rm=110 (illegal)");
    inst = enc_r(7'b1111000, 5'd0, 5'd12,3'b000, 5'd5, OPC_OPFP); expect_defaults; expect_fpu_frd(0,0,0,1); check("fmv.w.x f5, x12 (integer rs1)");
    inst = enc_r(7'b1111000, 5'd0, 5'd12,3'b001, 5'd5, OPC_OPFP); expect_defaults; check("fmv.w.x funct3=001 (illegal)");
    inst = enc_r(7'b1111000, 5'd4, 5'd12,3'b000, 5'd5, OPC_OPFP); expect_defaults; check("fmv.w.x rs2=00100 (illegal)");

    // ================================================================
    $display("--- CSR instructions on fcsr (phase_6.pdf 4.6.2) ---");
    // ================================================================
    // register forms read x[rs1]; i forms take uimm from the same field
    inst = enc_i(12'h003, 5'd6, 3'b001, 5'd5, OPC_SYSTEM); expect_defaults; expect_fpu_xrd(0,0,1); check("csrrw x5, fcsr, x6");
    inst = enc_i(12'h001, 5'd0, 3'b010, 5'd12, OPC_SYSTEM); expect_defaults; expect_fpu_xrd(0,0,1); check("csrrs x12, fflags, x0 (frflags)");
    inst = enc_i(12'h002, 5'd7, 3'b011, 5'd0, OPC_SYSTEM); expect_defaults; expect_fpu_xrd(0,0,1); check("csrrc x0, frm, x7");
    inst = enc_i(12'h002, 5'd1, 3'b101, 5'd0, OPC_SYSTEM); expect_defaults; expect_fpu_xrd(0,0,0); check("csrrwi x0, frm, 1 (no integer read)");
    inst = enc_i(12'h001, 5'd31,3'b110, 5'd8, OPC_SYSTEM); expect_defaults; expect_fpu_xrd(0,0,0); check("csrrsi x8, fflags, 31");
    inst = enc_i(12'h003, 5'd4, 3'b111, 5'd9, OPC_SYSTEM); expect_defaults; expect_fpu_xrd(0,0,0); check("csrrci x9, fcsr, 4");
    inst = enc_i(12'h000, 5'd6, 3'b001, 5'd5, OPC_SYSTEM); expect_defaults; check("csrrw on CSR 0x000 (illegal)");
    inst = enc_i(12'h004, 5'd6, 3'b010, 5'd5, OPC_SYSTEM); expect_defaults; check("csrrs on CSR 0x004 (illegal)");
    inst = enc_i(12'hC00, 5'd0, 3'b010, 5'd5, OPC_SYSTEM); expect_defaults; check("rdcycle (CSR 0xC00, illegal)");
    inst = enc_i(12'h300, 5'd6, 3'b001, 5'd5, OPC_SYSTEM); expect_defaults; check("csrrw mstatus (illegal)");
    inst = enc_i(12'h103, 5'd6, 3'b001, 5'd5, OPC_SYSTEM); expect_defaults; check("csrrw CSR 0x103 (low bits match, illegal)");
    inst = enc_i(12'h003, 5'd6, 3'b100, 5'd5, OPC_SYSTEM); expect_defaults; check("SYSTEM funct3=100 on fcsr (illegal)");
    inst = 32'h00100073; expect_defaults; e_legal = 1'b1; e_halt = 1'b1; check("ebreak still halts");

    // ================================================================
    $display("--- exhaustive OP-FP sweep (funct7 x funct3 x rs2) ---");
    // ================================================================
    sw_bad = 0; sw_n = 0;
    for (a = 0; a < 128; a = a + 1)
      for (b = 0; b < 8; b = b + 1)
        for (c = 0; c < 32; c = c + 1) begin
          inst = enc_r(a[6:0], c[4:0], 5'd17, b[2:0], 5'd9, OPC_OPFP);
          r = ref_opfp(a[6:0], b[2:0], c[4:0]);
          // r = {legal, frd, frs1, frs2, xrs1}
          sweep_check(r[4], r[4], r[2], r[1], 1'b0, r[3] & r[4], r[0],
                      (r[4] & ~r[3]) ? 5'b10000 : 5'b00000,
                      (r[4] & ~r[3]) ? 5'd9 : 5'd0);
        end
    if (sw_bad == 0) begin pass_count = pass_count + 1; $display("[PASS] %0d OP-FP encodings match the legality model", sw_n); end
    else begin fail_count = fail_count + 1; $display("[FAIL] OP-FP sweep: %0d of %0d mismatched", sw_bad, sw_n); end

    $display("--- exhaustive fused sweep (opcode x fmt x rm) ---");
    sw_bad = 0; sw_n = 0;
    for (a = 0; a < 4; a = a + 1)
      for (b = 0; b < 4; b = b + 1)
        for (c = 0; c < 8; c = c + 1) begin
          inst = enc_r4(5'd3, b[1:0], 5'd2, 5'd1, c[2:0], 5'd4, {3'b100, a[1:0], 2'b11});
          sweep_check((b == 0) && (c != 5) && (c != 6), (b == 0) && (c != 5) && (c != 6),
                      (b == 0) && (c != 5) && (c != 6), (b == 0) && (c != 5) && (c != 6),
                      (b == 0) && (c != 5) && (c != 6), (b == 0) && (c != 5) && (c != 6),
                      1'b0, 5'b00000, 5'd0);
        end
    if (sw_bad == 0) begin pass_count = pass_count + 1; $display("[PASS] %0d fused encodings match the legality model", sw_n); end
    else begin fail_count = fail_count + 1; $display("[FAIL] fused sweep: %0d of %0d mismatched", sw_bad, sw_n); end

    $display("--- exhaustive CSR sweep (address x funct3) ---");
    sw_bad = 0; sw_n = 0;
    for (a = 0; a < 4096; a = a + 1)
      for (b = 1; b < 8; b = b + 1) begin
        if (b != 4) begin
          inst = enc_i(a[11:0], 5'd6, b[2:0], 5'd5, OPC_SYSTEM);
          if (a >= 1 && a <= 3)
            sweep_check(1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, ~b[2], 5'b10000, 5'd5);
          else
            sweep_check(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 5'b00000, 5'd0);
        end
      end
    if (sw_bad == 0) begin pass_count = pass_count + 1; $display("[PASS] %0d CSR encodings: only fflags/frm/fcsr are legal", sw_n); end
    else begin fail_count = fail_count + 1; $display("[FAIL] CSR sweep: %0d of %0d mismatched", sw_bad, sw_n); end

    $display("--- exhaustive OP funct7 sweep (RV32I vs RV32M vs illegal) ---");
    sw_bad = 0; sw_n = 0;
    for (a = 0; a < 128; a = a + 1)
      for (b = 0; b < 8; b = b + 1) begin
        inst = enc_r(a[6:0], 5'd3, 5'd2, b[2:0], 5'd1, OPC_OP);
        #1;
        sw_n = sw_n + 1;
        if (o_legal !== ((a == 0) || (a == 1) || (a == 32 && (b == 0 || b == 5))) ||
            o_mext !== (a == 1) || o_fpu !== 1'b0 || o_frd_en !== 1'b0 ||
            o_rd !== (o_legal ? 5'd1 : 5'd0)) begin
          sw_bad = sw_bad + 1;
          if (sw_bad <= 10) $display("[FAIL] OP sweep inst=%08h legal=%b mext=%b rd=%0d", inst, o_legal, o_mext, o_rd);
        end
      end
    if (sw_bad == 0) begin pass_count = pass_count + 1; $display("[PASS] %0d OP encodings classified correctly", sw_n); end
    else begin fail_count = fail_count + 1; $display("[FAIL] OP sweep: %0d of %0d mismatched", sw_bad, sw_n); end

    // ================================================================
    $display("=======================================");
    $display("%0d passed, %0d failed", pass_count, fail_count);
    if (fail_count == 0) $display("ALL TESTS PASSED");
    else                 $display("TEST FAILED");
    $finish;
  end

endmodule

`default_nettype wire
