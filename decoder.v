`default_nettype none

module decoder (
    // Input instruction word.
    input  wire [31:0] i_inst,
    // Asserted if the instruction was decoded as a legal instruction. It is
    // important that the decoder not accept any illegal instruction
    // encodings as this could lead to undefined behavior in the processor
    // which is a safety hazard.
    output wire        o_legal,
    // Indicates that the instruction is an ebreak and should halt execution.
    output wire        o_halt,
    // First source register address.
    // For instructions that do not use a source register, this is effectively
    // a don't care because reading unused registers does not have any side
    // effects (and we don't care about power usage, really).
    output wire [ 4:0] o_rs1,
    // Second source register address.
    // Similarly to o_rs1, this is a don't care for instructions that do not
    // read a (second) source register.
    output wire [ 4:0] o_rs2,
    // Destination register address.
    // For instructions that do not write to a register, this must be set to
    // x0 so the value is discarded. This avoids the need for a separate write
    // enable since discard behavior must be present anyway.
    output wire [ 4:0] o_rd,
    // 32-bit immediate value, decoded from the instruction word. For R-type
    // instructions that do not use an immediate, this is a don't care.
    output wire [31:0] o_immediate,
    // Selects whether the first operand for the ALU is fed by the first
    // register source (rs1) or the current pc.
    // When asserted, the second operand is the immediate.
    output wire        o_op1_sel,
    // Selects whether the second operand for the ALU is fed by the second
    // register source (rs2) or the immediate.
    // When asserted, the second operand is the immediate.
    output wire        o_op2_sel,
    // Major opsel for the ALU. See ALU documentation for the encoding.
    output wire [ 2:0] o_alu_opsel,
    // Minor opsel flags for the ALU. See ALU documentation for the encoding.
    output wire        o_alu_sub,
    output wire        o_alu_unsigned,
    output wire        o_alu_arith,
    // If asserted, the instruction is a branch instruction and the PC should
    // be updated to the target address if the branch condition is met.
    output wire        o_branch,
    // If asserted, the instruction is a jump instruction and the PC should
    // be updated to the target address unconditionally.
    output wire        o_jump,
    // When asserted, the branch comparator checks for equality. When not
    // asserted, it checks for less than [unsigned].
    output wire        o_branch_equal,
    // When asserted, the branch comparator treats the less than comparison
    // operands as unsigned. This is only used when `!o_branch_equal`.
    output wire        o_branch_unsigned,
    // When asserted, the branch condition is inverted.
    // Equality -> inequality, less than -> greater than or equal.
    output wire        o_branch_invert,
    // When asserted, the instruction will load from memory.
    output wire        o_dmem_ren,
    // When asserted, the instruction will store to memory.
    output wire        o_dmem_wen,
    // This 2-bit mask selects which LSBs of the memory address should be
    // checked for alignment. This is because byte and half-word accesses need
    // only be 1-byte and 2-byte aligned, respectively.
    output wire [ 1:0] o_dmem_align,
    // These 3 bits select the size of the memory access.
    // They are effectively one-hot encoded.
    output wire        o_dmem_memb,
    output wire        o_dmem_memh,
    output wire        o_dmem_memw,
    // If asserted, the (byte or half-word) memory access is unsigned and the
    // load should be zero-extended to 32 bits instead of sign-extended.
    output wire        o_dmem_memu,
    // Selects the data to write to the destination register, one-hot.
    // [0] = ALU result (including the RV32M multiply/divide result)
    // [1] = immediate
    // [2] = PC + 4
    // [3] = memory
    // [4] = floating-point unit integer result (F extension): fmv.x.w,
    //       fclass.s, feq/flt/fle.s, fcvt.w[u].s, and the old CSR value
    //       for the CSR instructions.
    output wire [ 4:0] o_rd_sel,
    // Asserted for the RV32M instructions (OP opcode, funct7 = 0000001).
    // The ALU then performs the multiply/divide operation selected by
    // `o_alu_opsel` (the instruction's funct3).
    output wire        o_mext,
    // F extension. The floating-point unit decodes the details of its own
    // instructions (funct7, rs2, rm) from the instruction word; the decoder
    // only reports legality and which register file each operand uses.
    //
    // Asserted for instructions executed by the floating-point unit: every
    // OP-FP and fused multiply-add instruction, and the CSR instructions on
    // fflags/frm/fcsr. flw/fsw are ordinary memory accesses and are not
    // included.
    output wire        o_fpu,
    // Asserted when the instruction reads floating-point rs1/rs2/rs3. The
    // register addresses are the usual `o_rs1`/`o_rs2` fields, plus `o_rs3`
    // (bits [31:27]) for the fused multiply-add instructions.
    output wire        o_frs1_en,
    output wire        o_frs2_en,
    output wire        o_frs3_en,
    output wire [ 4:0] o_rs3,
    // Asserted when the instruction writes floating-point register rd
    // (bits [11:7]). For these instructions `o_rd` is 5'd0, since they do
    // not write the integer register file.
    output wire        o_frd_en,
    // If asserted, the PC jumps to the target address calculated by the ALU
    // rather than directly to the PC + immediate. This is used for JALR.
    output wire        o_pc_sel,
    // Phase 4 hazard detection: the instruction reads integer rs1 / rs2.
    // These cover only the integer register file; an F instruction that
    // reads FP rs1/rs2 reports it on o_frs1_en/o_frs2_en instead.
    output wire        o_uses_rs1,
    output wire        o_uses_rs2
);
  wire [6:0] opcode = i_inst[6:0];
  wire [4:0] rd     = i_inst[11:7];
  wire [2:0] funct3 = i_inst[14:12];
  wire [4:0] rs1    = i_inst[19:15];
  wire [4:0] rs2    = i_inst[24:20];
  wire [6:0] funct7 = i_inst[31:25];
  wire [1:0] fmt    = i_inst[26:25];
  wire [11:0] csr   = i_inst[31:20];

  localparam reg [6:0] OpcLui     = 7'b0110111;
  localparam reg [6:0] OpcAuipc   = 7'b0010111;
  localparam reg [6:0] OpcJal     = 7'b1101111;
  localparam reg [6:0] OpcJalr    = 7'b1100111;
  localparam reg [6:0] OpcBranch  = 7'b1100011;
  localparam reg [6:0] OpcLoad    = 7'b0000011;
  localparam reg [6:0] OpcStore   = 7'b0100011;
  localparam reg [6:0] OpcOpImm   = 7'b0010011;
  localparam reg [6:0] OpcOp      = 7'b0110011;
  localparam reg [6:0] OpcLoadFp  = 7'b0000111;
  localparam reg [6:0] OpcStoreFp = 7'b0100111;
  localparam reg [6:0] OpcOpFp    = 7'b1010011;
  localparam reg [6:0] OpcMadd    = 7'b1000011;
  localparam reg [6:0] OpcMsub    = 7'b1000111;
  localparam reg [6:0] OpcNmsub   = 7'b1001011;
  localparam reg [6:0] OpcNmadd   = 7'b1001111;
  localparam reg [6:0] OpcSystem  = 7'b1110011;

  // ---------------- RV32I (phase 4) ----------------
  wire is_lui    = (opcode == OpcLui);
  wire is_auipc  = (opcode == OpcAuipc);
  wire is_jal    = (opcode == OpcJal);
  wire is_jalr   = (opcode == OpcJalr && funct3 == 3'b000);
  wire is_branch = (opcode == OpcBranch && !(funct3 == 3'b010 || funct3 == 3'b011));
  wire is_load   = (opcode == OpcLoad && !(funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111));
  wire is_store  = (opcode == OpcStore && (funct3 == 3'b000 ||
                   funct3 == 3'b001 || funct3 == 3'b010));
  wire is_op_imm = (opcode == OpcOpImm && (funct3 != 3'b001 ||
                   funct7 == 7'b0000000) && (funct3 != 3'b101 || (funct7 == 7'b0000000 ||
                   funct7 == 7'b0100000)));
  wire is_op     = (opcode == OpcOp && (funct7 == 7'b0000000 ||
                   ((funct3 == 3'b000 || funct3 == 3'b101) && funct7 == 7'b0100000)));
  wire is_ebreak = (i_inst == 32'h00100073);

  // ---------------- RV32M (phase_6.pdf 4.3) ----------------
  // OP with funct7 = 0000001, any funct3.
  wire is_mext = (opcode == OpcOp && funct7 == 7'b0000001);

  // ---------------- RV32F (phase_6.pdf 4.7, 5.4.1) ----------------
  // A static rm of 101 or 110 is reserved. 111 (dynamic) is legal here;
  // the fpu traps it if frm holds a reserved value.
  wire rm_ok = (funct3 != 3'b101) && (funct3 != 3'b110);

  wire is_flw = (opcode == OpcLoadFp  && funct3 == 3'b010);
  wire is_fsw = (opcode == OpcStoreFp && funct3 == 3'b010);

  wire opfp = (opcode == OpcOpFp);
  // fadd.s / fsub.s / fmul.s / fdiv.s: fd = fs1 op fs2, rounded.
  wire is_farith = opfp && rm_ok && (funct7 == 7'b0000000 || funct7 == 7'b0000100 ||
                                     funct7 == 7'b0001000 || funct7 == 7'b0001100);
  // fsqrt.s: rs2 = 00000.
  wire is_fsqrt  = opfp && rm_ok && funct7 == 7'b0101100 && rs2 == 5'd0;
  // fsgnj.s / fsgnjn.s / fsgnjx.s: funct3 000, 001, 010.
  wire is_fsgnj  = opfp && funct7 == 7'b0010000 &&
                   (funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b010);
  // fmin.s / fmax.s: funct3 000, 001.
  wire is_fminmax = opfp && funct7 == 7'b0010100 && (funct3 == 3'b000 || funct3 == 3'b001);
  // fle.s / flt.s / feq.s: funct3 000, 001, 010; result in an integer register.
  wire is_fcmp   = opfp && funct7 == 7'b1010000 &&
                   (funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b010);
  // fmv.x.w (funct3 000) and fclass.s (funct3 001): rs2 = 00000.
  wire is_fmvxw_class = opfp && funct7 == 7'b1110000 && rs2 == 5'd0 &&
                        (funct3 == 3'b000 || funct3 == 3'b001);
  // fcvt.w.s / fcvt.wu.s: rs2 = 00000 / 00001.
  wire is_fcvt_ws = opfp && rm_ok && funct7 == 7'b1100000 && (rs2 == 5'd0 || rs2 == 5'd1);
  // fcvt.s.w / fcvt.s.wu: rs2 = 00000 / 00001; source is an integer register.
  wire is_fcvt_sw = opfp && rm_ok && funct7 == 7'b1101000 && (rs2 == 5'd0 || rs2 == 5'd1);
  // fmv.w.x: rs2 = 00000, funct3 = 000; source is an integer register.
  wire is_fmvwx   = opfp && funct7 == 7'b1111000 && rs2 == 5'd0 && funct3 == 3'b000;

  // Fused multiply-add (R4): fmt must be 00 (single precision).
  wire is_fused = (opcode == OpcMadd || opcode == OpcMsub ||
                   opcode == OpcNmsub || opcode == OpcNmadd) && fmt == 2'b00 && rm_ok;

  // ---------------- Zicsr on fcsr (phase_6.pdf 4.6.2) ----------------
  // SYSTEM with funct3 in {001,010,011,101,110,111}, and only fflags,
  // frm and fcsr. funct3[2] selects the immediate (uimm) forms.
  wire is_csr = (opcode == OpcSystem) && funct3 != 3'b000 && funct3 != 3'b100 &&
                (csr == 12'h001 || csr == 12'h002 || csr == 12'h003);
  wire csr_reg_form = is_csr && !funct3[2];

  // Groups by which register files they read and write.
  wire f_writes_frd = is_farith | is_fsqrt | is_fsgnj | is_fminmax |
                      is_fcvt_sw | is_fmvwx | is_fused | is_flw;
  wire f_writes_xrd = is_fcmp | is_fmvxw_class | is_fcvt_ws | is_csr;
  wire f_reads_frs1 = is_farith | is_fsqrt | is_fsgnj | is_fminmax |
                      is_fcmp | is_fmvxw_class | is_fcvt_ws | is_fused;
  wire f_reads_frs2 = is_farith | is_fsgnj | is_fminmax | is_fcmp | is_fused | is_fsw;

  assign o_legal = is_lui | is_auipc | is_jal | is_jalr | is_branch |
                   is_load | is_store | is_op_imm | is_op | is_ebreak |
                   is_mext |
                   is_flw | is_fsw | is_farith | is_fsqrt | is_fsgnj | is_fminmax |
                   is_fcmp | is_fmvxw_class | is_fcvt_ws | is_fcvt_sw | is_fmvwx |
                   is_fused | is_csr;
  assign o_halt  = is_ebreak;

  // ---------------- Immediate ----------------
  // flw uses the I format and fsw the S format, like lw and sw.
  wire is_op_or_imm   = is_op | is_op_imm;
  wire mem_load       = is_load | is_flw;
  wire mem_store      = is_store | is_fsw;
  wire is_dmem_access = mem_load | mem_store;

  wire [5:0] format;
  assign format[0] = is_op | is_mext;
  assign format[1] = is_jalr || mem_load || is_op_imm;
  assign format[2] = mem_store;
  assign format[3] = is_branch;
  assign format[4] = is_lui || is_auipc;
  assign format[5] = is_jal;

  imm immediate (
      .i_inst     (i_inst),
      .i_format   (format),
      .o_immediate(o_immediate)
  );

  // ---------------- ALU control ----------------
  assign o_rs1 = rs1;
  assign o_rs2 = rs2;
  assign o_rs3 = i_inst[31:27];
  assign o_op1_sel = is_auipc;
  assign o_op2_sel = is_op_imm | is_dmem_access | is_auipc | is_jalr;
  // For RV32M the ALU's opsel carries funct3 and o_mext selects M.
  assign o_alu_opsel = (is_op_or_imm | is_mext) ? funct3 : 3'b000;
  assign o_alu_sub = is_op && funct3 == 3'b000 && funct7 == 7'b0100000;
  assign o_alu_unsigned = is_branch ? funct3[1] : (is_op_or_imm && funct3 == 3'b011);
  assign o_alu_arith = is_op_or_imm && funct3 == 3'b101 && funct7 == 7'b0100000;
  assign o_mext = is_mext;

  // ---------------- Control flow ----------------
  assign o_branch = is_branch;
  assign o_jump = is_jal | is_jalr;
  assign o_pc_sel = is_jalr;
  assign o_branch_equal = ~funct3[2];
  assign o_branch_unsigned = funct3[1];
  assign o_branch_invert = funct3[0];

  // ---------------- Memory ----------------
  // flw and fsw are word accesses (funct3 = 010, like lw and sw).
  assign o_dmem_ren = mem_load;
  assign o_dmem_wen = mem_store;
  assign o_dmem_memb = is_dmem_access && funct3[1:0] == 2'b00;
  assign o_dmem_memh = is_dmem_access && funct3[1:0] == 2'b01;
  assign o_dmem_memw = is_dmem_access && funct3[1:0] == 2'b10;
  assign o_dmem_memu = is_load && funct3[2];
  assign o_dmem_align = o_dmem_memw ? 2'b11 : (o_dmem_memh ? 2'b01 : 2'b00);

  // ---------------- Writeback ----------------
  // [0] ALU (incl. RV32M), [1] immediate, [2] PC+4, [3] memory (incl. flw),
  // [4] the fpu's integer result (compares, fclass, fmv.x.w, fcvt.w[u].s,
  // and the old CSR value).
  assign o_rd_sel[0] = is_op_or_imm | is_mext | is_auipc;
  assign o_rd_sel[1] = is_lui;
  assign o_rd_sel[2] = o_jump;
  assign o_rd_sel[3] = mem_load;
  assign o_rd_sel[4] = f_writes_xrd;
  // An instruction that writes an FP register writes no integer register.
  assign o_frd_en = f_writes_frd;
  assign o_rd = ((|o_rd_sel) & ~f_writes_frd) ? rd : 5'd0;

  // ---------------- F extension ----------------
  // Everything the fpu executes: OP-FP, fused, and the CSR instructions.
  // flw/fsw go through the ALU (address) and the data cache instead.
  assign o_fpu = is_farith | is_fsqrt | is_fsgnj | is_fminmax | is_fcmp |
                 is_fmvxw_class | is_fcvt_ws | is_fcvt_sw | is_fmvwx |
                 is_fused | is_csr;
  assign o_frs1_en = f_reads_frs1;
  assign o_frs2_en = f_reads_frs2;
  assign o_frs3_en = is_fused;

  // ---------------- Integer register reads (hazards) ----------------
  // Run off the legality-checked "is" wires, so immediate bits that look
  // like a register never cause a false dependency (phase_4.pdf 4.2.3).
  // F instructions read integer rs1 for the flw/fsw base address,
  // fcvt.s.w[u], fmv.w.x, and the register forms of the CSR instructions.
  assign o_uses_rs1 = is_op | is_op_imm | is_load | is_store | is_branch | is_jalr |
                      is_mext | is_flw | is_fsw | is_fcvt_sw | is_fmvwx | csr_reg_form;
  assign o_uses_rs2 = is_op | is_store | is_branch | is_mext;

endmodule

`default_nettype wire
