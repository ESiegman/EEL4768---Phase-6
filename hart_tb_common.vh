// Harness shared by the eight phase 6 hart testbenches (hart_*_tb.v): one
// hart with a given cache configuration and memory latency, its instruction
// and data main memories, and every check that runs on it. A hart_*_tb.v
// instantiates one harness per configuration and starts them one after
// another, so the log reads in order.
//
// A .vh, not a .v, for the same reason as mem_model.vh: run_test.sh would
// otherwise compile it into every check and `ece552 validate` would lint it
// as a design file (it uses loops, file I/O and delays).
//
// A harness resets the hart, runs traces/random_program.hex until the final
// ebreak retires, then checks:
//  * The run: it halts within MAX_CYCLES, with no gap of IDLE_LIMIT cycles
//    between two retirements, and the program fits in instruction memory.
//  * The retire stream (phase_6.pdf 5.7). These checks find hazard,
//    forwarding, stall and fcsr-commit bugs whether or not the FP math is
//    right, because they only compare the hart with itself:
//      - shadow integer and FP register files, updated from every retiring
//        rd/frd write (FP registers reset to +0.0, f0 is an ordinary
//        register). Every integer source a retiring instruction reports, and
//        every FP source it reads (decoded here from the PDF 5.5 table),
//        must equal the shadow value
//      - FP destinations: an instruction that writes an FP register reports
//        frd_wen with frd = inst[11:7] and no integer rd; nothing else
//        reports frd_wen
//      - a shadow fcsr. fflags reported by an F instruction (flw, fsw,
//        OP-FP, fused, CSR) may only gain bits, and only on instructions
//        that can raise flags; a CSR instruction's rd must be the old CSR
//        value and its fflags the value it writes (PDF 4.6.2). A dynamic-rm
//        instruction must trap exactly when the shadow frm is 5-7
//      - loads: the dcache word equals a shadow data memory built from the
//        retiring stores; lw/lh/lb/flw take the right lanes, and flw writes
//        the whole word to frd
//      - stores: the masked lanes hold rs2, or frs2 for fsw
//      - the instruction word matches the program, the PC sequence follows
//        next_pc, and nothing traps (the trace has no traps)
//  * Memory, after halt. The program ends with loads that evict every dirty
//    dcache line (phase_6.pdf 6.1), so main memory must equal the shadow
//    memory everywhere. The section verdict is that both equal
//    traces/random_dmem.hex in [SEC_LO, SEC_HI]. The diff counts of every
//    other region are printed as INFO lines.
//  * The memory models saw no protocol errors (mem_model.vh), and the dcache
//    saw no request while dut.ex_stall was high (phase_6.pdf 5.5.3).
// It then prints cycles, instructions retired, CPI and memory traffic.

`ifndef HART_TB_COMMON_VH
`define HART_TB_COMMON_VH

`include "mem_model.vh"

module hart_harness #(
    // Printed in front of every message from this instance.
    parameter LABEL        = "hart",
    parameter EVICT_POLICY = 1,
    parameter NUM_WAYS     = 4,
    parameter CACHE_SIZE   = 2,
    parameter BLOCK_SIZE   = 16,
    parameter PREFETCH_EN  = 1,
    // Main memory read latency in cycles, for both memories.
    parameter LATENCY      = 4,
    // The register dump range this check is graded on (phase_6.pdf 6.1),
    // inclusive byte addresses.
    parameter [31:0] SEC_LO = 32'h10020000,
    parameter [31:0] SEC_HI = 32'h100217FF,
    // Watchdogs: give up after this many cycles in total, or after this many
    // cycles in a row without a retirement.
    parameter MAX_CYCLES   = 2000000,
    parameter IDLE_LIMIT   = 3000
) (
    input  wire i_start,
    output reg  o_done
);

    localparam [31:0] IMEM_BASE   = 32'h00400000;
    localparam [31:0] DMEM_BASE   = 32'h10010000;
    // random_program.hex is 36088 words, so the instruction memory has room
    // to spare; random_dmem.hex is 32768 words (128 KB).
    localparam        IMEM_WORDS  = 40000;
    localparam        DMEM_WORDS  = 32768;
    // One spare block past the end of each memory, so a next-line prefetch
    // after a miss on the last line is still a legal read. Nothing should
    // ever write it.
    localparam        GUARD_WORDS = BLOCK_SIZE / 4;
    localparam        MAX_MSGS    = 20;
    localparam        N_REGIONS   = 12;

    // Results, read by the top-level testbench.
    integer passed;
    integer failed;

    // ------------------------------------------------------------------
    // Clock (runs only while this instance is active), reset, DUT
    // ------------------------------------------------------------------
    reg clk;
    reg rst;
    reg running;

    always begin
        wait (running);
        #5 clk = ~clk;
    end

    wire                    imem_rd;
    wire [31:0]             imem_rd_addr;
    wire                    imem_valid;
    wire [BLOCK_SIZE*8-1:0] imem_rd_data;
    wire                    dmem_rd;
    wire [31:0]             dmem_rd_addr;
    wire                    dmem_valid;
    wire [BLOCK_SIZE*8-1:0] dmem_rd_data;
    wire                    dmem_wr;
    wire [31:0]             dmem_wr_addr;
    wire [BLOCK_SIZE*8-1:0] dmem_wr_data;
    wire [BLOCK_SIZE-1:0]   dmem_wr_be;

    wire        retire_valid;
    wire [31:0] retire_inst;
    wire        retire_trap;
    wire        retire_halt;
    wire [ 4:0] retire_rs1_raddr;
    wire [ 4:0] retire_rs2_raddr;
    wire [31:0] retire_rs1_rdata;
    wire [31:0] retire_rs2_rdata;
    wire [ 4:0] retire_rd_waddr;
    wire [31:0] retire_rd_wdata;
    wire [31:0] retire_dmem_addr;
    wire [ 3:0] retire_dmem_mask;
    wire        retire_dmem_ren;
    wire        retire_dmem_wen;
    wire [31:0] retire_dmem_rdata;
    wire [31:0] retire_dmem_wdata;
    wire [31:0] retire_pc;
    wire [31:0] retire_next_pc;
    wire [ 4:0] retire_frs1_raddr;
    wire [31:0] retire_frs1_rdata;
    wire [ 4:0] retire_frs2_raddr;
    wire [31:0] retire_frs2_rdata;
    wire [ 4:0] retire_frs3_raddr;
    wire [31:0] retire_frs3_rdata;
    wire        retire_frd_wen;
    wire [ 4:0] retire_frd_waddr;
    wire [31:0] retire_frd_wdata;
    wire [ 4:0] retire_fflags;

    hart #(
        .RESET_ADDR  (IMEM_BASE),
        .EVICT_POLICY(EVICT_POLICY),
        .NUM_WAYS    (NUM_WAYS),
        .CACHE_SIZE  (CACHE_SIZE),
        .BLOCK_SIZE  (BLOCK_SIZE),
        .PREFETCH_EN (PREFETCH_EN)
    ) dut (
        .i_clk              (clk),
        .i_rst              (rst),
        .o_imem_rd          (imem_rd),
        .o_imem_rd_addr     (imem_rd_addr),
        .i_imem_valid       (imem_valid),
        .i_imem_rd_data     (imem_rd_data),
        .o_dmem_rd          (dmem_rd),
        .o_dmem_rd_addr     (dmem_rd_addr),
        .i_dmem_valid       (dmem_valid),
        .i_dmem_rd_data     (dmem_rd_data),
        .o_dmem_wr          (dmem_wr),
        .o_dmem_wr_addr     (dmem_wr_addr),
        .o_dmem_wr_data     (dmem_wr_data),
        .o_dmem_wr_be       (dmem_wr_be),
        .o_retire_valid     (retire_valid),
        .o_retire_inst      (retire_inst),
        .o_retire_trap      (retire_trap),
        .o_retire_halt      (retire_halt),
        .o_retire_rs1_raddr (retire_rs1_raddr),
        .o_retire_rs2_raddr (retire_rs2_raddr),
        .o_retire_rs1_rdata (retire_rs1_rdata),
        .o_retire_rs2_rdata (retire_rs2_rdata),
        .o_retire_rd_waddr  (retire_rd_waddr),
        .o_retire_rd_wdata  (retire_rd_wdata),
        .o_retire_dmem_addr (retire_dmem_addr),
        .o_retire_dmem_mask (retire_dmem_mask),
        .o_retire_dmem_ren  (retire_dmem_ren),
        .o_retire_dmem_wen  (retire_dmem_wen),
        .o_retire_dmem_rdata(retire_dmem_rdata),
        .o_retire_dmem_wdata(retire_dmem_wdata),
        .o_retire_pc        (retire_pc),
        .o_retire_next_pc   (retire_next_pc),
        .o_retire_frs1_raddr(retire_frs1_raddr),
        .o_retire_frs1_rdata(retire_frs1_rdata),
        .o_retire_frs2_raddr(retire_frs2_raddr),
        .o_retire_frs2_rdata(retire_frs2_rdata),
        .o_retire_frs3_raddr(retire_frs3_raddr),
        .o_retire_frs3_rdata(retire_frs3_rdata),
        .o_retire_frd_wen   (retire_frd_wen),
        .o_retire_frd_waddr (retire_frd_waddr),
        .o_retire_frd_wdata (retire_frd_wdata),
        .o_retire_fflags    (retire_fflags)
    );

    // Instruction memory is read only: its write port is tied off.
    main_mem #(
        .BLOCK_SIZE(BLOCK_SIZE),
        .LATENCY   (LATENCY),
        .BASE_ADDR (IMEM_BASE),
        .SIZE_WORDS(IMEM_WORDS + GUARD_WORDS),
        .NAME      ({LABEL, ", imem"})
    ) u_imem (
        .i_clk     (clk),
        .i_rst     (rst),
        .i_rd      (imem_rd),
        .i_rd_addr (imem_rd_addr),
        .o_rd_valid(imem_valid),
        .o_rd_data (imem_rd_data),
        .i_wr      (1'b0),
        .i_wr_addr (32'd0),
        .i_wr_data ({BLOCK_SIZE*8{1'b0}}),
        .i_wr_be   ({BLOCK_SIZE{1'b0}})
    );

    main_mem #(
        .BLOCK_SIZE(BLOCK_SIZE),
        .LATENCY   (LATENCY),
        .BASE_ADDR (DMEM_BASE),
        .SIZE_WORDS(DMEM_WORDS + GUARD_WORDS),
        .NAME      ({LABEL, ", dmem"})
    ) u_dmem (
        .i_clk     (clk),
        .i_rst     (rst),
        .i_rd      (dmem_rd),
        .i_rd_addr (dmem_rd_addr),
        .o_rd_valid(dmem_valid),
        .o_rd_data (dmem_rd_data),
        .i_wr      (dmem_wr),
        .i_wr_addr (dmem_wr_addr),
        .i_wr_data (dmem_wr_data),
        .i_wr_be   (dmem_wr_be)
    );

    // ------------------------------------------------------------------
    // Checks
    // ------------------------------------------------------------------
    task check;
        input [8*80-1:0] what;
        input            ok;
        begin
            if (ok) begin
                passed = passed + 1;
            end else begin
                failed = failed + 1;
                $display("[FAIL] %0s: %0s", LABEL, what);
            end
        end
    endtask

    // Mismatches found while running, by kind. Only the first MAX_MSGS of
    // them, all kinds together, are printed.
    integer bad_load;     // load data from the dcache
    integer bad_inst;     // instruction word from the icache
    integer bad_pc;       // retire PC sequence
    integer bad_lane;     // dmem mask/address/lane formatting
    integer bad_xsrc;     // integer source vs the shadow register file
    integer bad_fsrc;     // FP source vs the shadow FP register file
    integer bad_dst;      // rd/frd reporting of F instructions
    integer bad_flags;    // fflags vs the shadow fcsr
    integer bad_csr;      // CSR instruction rd (old value)
    integer bad_rmtrap;   // dynamic-rm trap vs the shadow frm
    integer n_traps;
    integer dstall_errs;  // dcache requests while ex_stall was high
    integer msgs;

    integer cycles;       // cycles since reset was released
    integer idle;         // cycles since the last retirement
    integer retired;
    integer n_loads;
    integer n_stores;
    integer n_fp;         // F and CSR instructions retired
    integer n_csr;
    integer prog_words;
    reg     halted;
    reg     have_prev;
    reg [31:0] prev_next_pc;
    reg [31:0] last_pc;

    reg [31:0] shadow [0:DMEM_WORDS-1];
    reg [31:0] golden [0:DMEM_WORDS-1];
    reg [31:0] xs [0:31];     // shadow integer registers
    reg [31:0] fs [0:31];     // shadow FP registers
    reg [ 4:0] sh_fflags;     // shadow fcsr
    reg [ 2:0] sh_frm;

    // Prints one retire-stream mismatch (the first MAX_MSGS of them).
    task report;
        input [8*64-1:0] what;
        input [31:0]     got;
        input [31:0]     want;
        begin
            if (msgs < MAX_MSGS && (retire_dmem_ren === 1'b1 || retire_dmem_wen === 1'b1))
                $display("[FAIL] %0s: %0s at pc %h (inst %h, dmem addr %h): got %h, expected %h (retire #%0d, cycle %0d)",
                         LABEL, what, retire_pc, retire_inst, retire_dmem_addr,
                         got, want, retired, cycles);
            else if (msgs < MAX_MSGS)
                $display("[FAIL] %0s: %0s at pc %h (inst %h): got %h, expected %h (retire #%0d, cycle %0d)",
                         LABEL, what, retire_pc, retire_inst, got, want, retired, cycles);
            else if (msgs == MAX_MSGS)
                $display("[FAIL] %0s: further retire mismatches not shown", LABEL);
            msgs = msgs + 1;
        end
    endtask

    // Byte offset a load or store mask implies (0 for an illegal mask).
    function [1:0] mask_offset;
        input [3:0] mask;
        begin
            case (mask)
                4'b0010: mask_offset = 2'd1;
                4'b0100: mask_offset = 2'd2;
                4'b1000: mask_offset = 2'd3;
                4'b1100: mask_offset = 2'd2;
                default: mask_offset = 2'd0;
            endcase
        end
    endfunction

    // Whether a mask is legal for a load/store funct3 (size in [1:0]).
    function mask_ok;
        input [1:0] size;
        input [3:0] mask;
        begin
            case (size)
                2'd0:    mask_ok = (mask == 4'b0001) || (mask == 4'b0010) ||
                                   (mask == 4'b0100) || (mask == 4'b1000);
                2'd1:    mask_ok = (mask == 4'b0011) || (mask == 4'b1100);
                2'd2:    mask_ok = (mask == 4'b1111);
                default: mask_ok = 1'b0;
            endcase
        end
    endfunction

    // The dcache must not see a request while a multi-cycle operation holds
    // EX (phase_6.pdf 5.5.3). Same assertion as tools/hart_diff/hart_diff_tb.v.
    always @(posedge clk) begin
        if (running && rst === 1'b0 && dut.ex_stall === 1'b1 &&
            (dut.dcache_ren === 1'b1 || dut.dcache_wen === 1'b1)) begin
            if (dstall_errs < MAX_MSGS)
                $display("[FAIL] %0s: dcache request during ex_stall at cycle %0d (ren %b, wen %b)",
                         LABEL, cycles, dut.dcache_ren, dut.dcache_wen);
            dstall_errs = dstall_errs + 1;
        end
    end

    reg  [31:0] widx;
    reg  [31:0] want;
    reg  [31:0] lanes;
    reg  [31:0] st_src;
    reg  [ 2:0] funct3;
    reg  [ 6:0] opcode;
    reg  [ 6:0] funct7;
    reg  [ 4:0] f_rd, f_rs1, f_rs2, f_rs3;
    integer     b;

    // Decoded classes of the retiring instruction (phase_6.pdf 4.7, 5.5).
    reg is_flw, is_fsw, is_fma, is_opfp, is_csr, is_f;
    reg rd_f1, rd_f2, rd_f3;      // reads FP rs1/rs2/rs3
    reg wr_f;                     // writes an FP register
    reg wr_x_fpu;                 // FPU instruction that writes an integer rd
    reg can_flag;                 // can raise exception flags
    reg uses_rm;                  // has a rounding-mode field

    // CSR model.
    reg  [ 7:0] csr_old;
    reg  [ 7:0] csr_src;
    reg  [ 7:0] csr_new;
    reg         csr_wr;
    reg  [ 4:0] ff_after;
    reg  [ 2:0] frm_after;

    // Retire monitor, sampled mid-cycle while the outputs are stable.
    always @(negedge clk) begin
        if (running && !rst && !halted) begin
            cycles = cycles + 1;
            idle   = idle + 1;
            if (retire_valid === 1'b1) begin
                retired = retired + 1;
                idle    = 0;
                last_pc = retire_pc;
                opcode  = retire_inst[6:0];
                funct3  = retire_inst[14:12];
                funct7  = retire_inst[31:25];
                f_rd    = retire_inst[11:7];
                f_rs1   = retire_inst[19:15];
                f_rs2   = retire_inst[24:20];
                f_rs3   = retire_inst[31:27];

                is_flw  = (opcode == 7'b0000111);
                is_fsw  = (opcode == 7'b0100111);
                is_fma  = (opcode == 7'b1000011) || (opcode == 7'b1000111) ||
                          (opcode == 7'b1001011) || (opcode == 7'b1001111);
                is_opfp = (opcode == 7'b1010011);
                is_csr  = (opcode == 7'b1110011) && (funct3 != 3'b000);
                is_f    = is_flw || is_fsw || is_fma || is_opfp || is_csr;
                // OP-FP by funct7: 00 fadd, 04 fsub, 08 fmul, 0C fdiv,
                // 2C fsqrt, 10 fsgnj*, 14 fmin/fmax, 50 compares,
                // 60 fcvt.w[u].s, 68 fcvt.s.w[u], 70 fmv.x.w/fclass,
                // 78 fmv.w.x.
                rd_f1    = is_fma || (is_opfp && funct7 != 7'h68 && funct7 != 7'h78);
                rd_f2    = is_fsw || is_fma ||
                           (is_opfp && (funct7 == 7'h00 || funct7 == 7'h04 ||
                                        funct7 == 7'h08 || funct7 == 7'h0C ||
                                        funct7 == 7'h10 || funct7 == 7'h14 ||
                                        funct7 == 7'h50));
                rd_f3    = is_fma;
                wr_x_fpu = is_csr ||
                           (is_opfp && (funct7 == 7'h50 || funct7 == 7'h60 || funct7 == 7'h70));
                wr_f     = is_flw || is_fma || (is_opfp && !wr_x_fpu);
                can_flag = is_fma ||
                           (is_opfp && funct7 != 7'h10 && funct7 != 7'h70 && funct7 != 7'h78);
                uses_rm  = is_fma ||
                           (is_opfp && (funct7 == 7'h00 || funct7 == 7'h04 ||
                                        funct7 == 7'h08 || funct7 == 7'h0C ||
                                        funct7 == 7'h2C || funct7 == 7'h60 ||
                                        funct7 == 7'h68));
                if (is_f)
                    n_fp = n_fp + 1;

                // Instruction word, from the icache.
                if (retire_pc < IMEM_BASE || retire_pc >= IMEM_BASE + 4 * IMEM_WORDS ||
                    retire_pc[1:0] != 2'b00) begin
                    bad_pc = bad_pc + 1;
                    report("retire PC outside instruction memory", retire_pc, IMEM_BASE);
                end else if (retire_inst !== u_imem.mem[(retire_pc - IMEM_BASE) >> 2]) begin
                    bad_inst = bad_inst + 1;
                    report("instruction word", retire_inst,
                           u_imem.mem[(retire_pc - IMEM_BASE) >> 2]);
                end

                // PC sequence.
                if (!have_prev && retire_pc !== IMEM_BASE) begin
                    bad_pc = bad_pc + 1;
                    report("first retired PC", retire_pc, IMEM_BASE);
                end else if (have_prev && retire_pc !== prev_next_pc) begin
                    bad_pc = bad_pc + 1;
                    report("PC (previous next_pc)", retire_pc, prev_next_pc);
                end
                if (opcode != 7'b1100011 && opcode != 7'b1101111 &&
                    opcode != 7'b1100111 && !retire_halt &&
                    retire_next_pc !== retire_pc + 32'd4) begin
                    bad_pc = bad_pc + 1;
                    report("next_pc of a non-jump", retire_next_pc, retire_pc + 32'd4);
                end
                have_prev    = 1'b1;
                prev_next_pc = retire_next_pc;

                // Integer sources: whatever the hart reports reading must be
                // the value the shadow register file holds (x0 reads 0).
                if (retire_rs1_raddr !== 5'd0) begin
                    if (retire_rs1_raddr !== f_rs1) begin
                        bad_xsrc = bad_xsrc + 1;
                        report("rs1 address vs inst[19:15]", {27'd0, retire_rs1_raddr}, {27'd0, f_rs1});
                    end else if (retire_rs1_rdata !== xs[f_rs1]) begin
                        bad_xsrc = bad_xsrc + 1;
                        report("rs1 value vs shadow register", retire_rs1_rdata, xs[f_rs1]);
                    end
                end
                if (retire_rs2_raddr !== 5'd0) begin
                    if (retire_rs2_raddr !== f_rs2) begin
                        bad_xsrc = bad_xsrc + 1;
                        report("rs2 address vs inst[24:20]", {27'd0, retire_rs2_raddr}, {27'd0, f_rs2});
                    end else if (retire_rs2_rdata !== xs[f_rs2]) begin
                        bad_xsrc = bad_xsrc + 1;
                        report("rs2 value vs shadow register", retire_rs2_rdata, xs[f_rs2]);
                    end
                end

                if (retire_trap === 1'b1) begin
                    n_traps = n_traps + 1;
                    report("unexpected trap", {31'd0, retire_trap}, 32'd0);
                end

                // Dynamic rounding mode: traps exactly when frm is 5-7.
                if (uses_rm && funct3 == 3'b111 &&
                    (retire_trap === 1'b1) !== (sh_frm >= 3'd5)) begin
                    bad_rmtrap = bad_rmtrap + 1;
                    report("dynamic-rm trap vs shadow frm", {31'd0, retire_trap}, {29'd0, sh_frm});
                end

                // FP sources, for the operands the instruction reads.
                if (retire_trap !== 1'b1) begin
                    if (rd_f1 && (retire_frs1_raddr !== f_rs1 || retire_frs1_rdata !== fs[f_rs1])) begin
                        bad_fsrc = bad_fsrc + 1;
                        report(retire_frs1_raddr !== f_rs1 ? "frs1 address vs inst[19:15]"
                                                           : "frs1 value vs shadow FP register",
                               retire_frs1_raddr !== f_rs1 ? {27'd0, retire_frs1_raddr} : retire_frs1_rdata,
                               retire_frs1_raddr !== f_rs1 ? {27'd0, f_rs1} : fs[f_rs1]);
                    end
                    if (rd_f2 && (retire_frs2_raddr !== f_rs2 || retire_frs2_rdata !== fs[f_rs2])) begin
                        bad_fsrc = bad_fsrc + 1;
                        report(retire_frs2_raddr !== f_rs2 ? "frs2 address vs inst[24:20]"
                                                           : "frs2 value vs shadow FP register",
                               retire_frs2_raddr !== f_rs2 ? {27'd0, retire_frs2_raddr} : retire_frs2_rdata,
                               retire_frs2_raddr !== f_rs2 ? {27'd0, f_rs2} : fs[f_rs2]);
                    end
                    if (rd_f3 && (retire_frs3_raddr !== f_rs3 || retire_frs3_rdata !== fs[f_rs3])) begin
                        bad_fsrc = bad_fsrc + 1;
                        report(retire_frs3_raddr !== f_rs3 ? "frs3 address vs inst[31:27]"
                                                           : "frs3 value vs shadow FP register",
                               retire_frs3_raddr !== f_rs3 ? {27'd0, retire_frs3_raddr} : retire_frs3_rdata,
                               retire_frs3_raddr !== f_rs3 ? {27'd0, f_rs3} : fs[f_rs3]);
                    end

                    // Destinations of F instructions.
                    if (wr_f) begin
                        if (retire_frd_wen !== 1'b1 || retire_frd_waddr !== f_rd) begin
                            bad_dst = bad_dst + 1;
                            report("frd_wen/frd vs inst[11:7]", {26'd0, retire_frd_wen, retire_frd_waddr},
                                   {26'd0, 1'b1, f_rd});
                        end
                        if (retire_rd_waddr !== 5'd0) begin
                            bad_dst = bad_dst + 1;
                            report("integer rd of an FP-writing instruction", {27'd0, retire_rd_waddr}, 32'd0);
                        end
                    end else if (retire_frd_wen !== 1'b0) begin
                        bad_dst = bad_dst + 1;
                        report("frd_wen of an instruction that writes no FP register",
                               {31'd0, retire_frd_wen}, 32'd0);
                    end
                    if (wr_x_fpu && retire_rd_waddr !== f_rd) begin
                        bad_dst = bad_dst + 1;
                        report("integer rd vs inst[11:7]", {27'd0, retire_rd_waddr}, {27'd0, f_rd});
                    end
                end else if (retire_frd_wen !== 1'b0 || retire_rd_waddr !== 5'd0) begin
                    bad_dst = bad_dst + 1;
                    report("trapped instruction writes a register", {27'd0, retire_rd_waddr}, 32'd0);
                end

                // fcsr. Only F instructions report fflags (phase_6.pdf 5.7).
                if (is_f) begin
                    if (retire_trap === 1'b1) begin
                        if (retire_fflags !== sh_fflags) begin
                            bad_flags = bad_flags + 1;
                            report("fflags changed by a trapped instruction",
                                   {27'd0, retire_fflags}, {27'd0, sh_fflags});
                        end
                    end else if (is_csr) begin
                        n_csr   = n_csr + 1;
                        csr_old = (retire_inst[21:20] == 2'b01) ? {3'd0, sh_fflags} :
                                  (retire_inst[21:20] == 2'b10) ? {5'd0, sh_frm} :
                                                                  {sh_frm, sh_fflags};
                        csr_src = funct3[2] ? {3'd0, f_rs1} : xs[f_rs1][7:0];
                        csr_new = (funct3[1:0] == 2'b01) ? csr_src :
                                  (funct3[1:0] == 2'b10) ? (csr_old | csr_src) :
                                                           (csr_old & ~csr_src);
                        csr_wr  = (funct3[1:0] == 2'b01) || (f_rs1 != 5'd0);
                        ff_after  = (csr_wr && retire_inst[21:20] != 2'b10) ? csr_new[4:0] : sh_fflags;
                        frm_after = (csr_wr && retire_inst[21:20] == 2'b10) ? csr_new[2:0] :
                                    (csr_wr && retire_inst[21:20] == 2'b11) ? csr_new[7:5] : sh_frm;
                        if (retire_rd_waddr !== 5'd0 && retire_rd_wdata !== {24'd0, csr_old}) begin
                            bad_csr = bad_csr + 1;
                            report("CSR rd (old value) vs shadow fcsr", retire_rd_wdata, {24'd0, csr_old});
                        end
                        if (retire_fflags !== ff_after) begin
                            bad_flags = bad_flags + 1;
                            report("fflags after a CSR instruction", {27'd0, retire_fflags}, {27'd0, ff_after});
                        end
                        sh_fflags = ff_after;
                        sh_frm    = frm_after;
                    end else if (can_flag) begin
                        if ((retire_fflags & sh_fflags) !== sh_fflags) begin
                            bad_flags = bad_flags + 1;
                            report("fflags lost a bit (flags accrue)", {27'd0, retire_fflags}, {27'd0, sh_fflags});
                        end
                        sh_fflags = retire_fflags;
                    end else if (retire_fflags !== sh_fflags) begin
                        bad_flags = bad_flags + 1;
                        report("fflags changed by an instruction that raises none",
                               {27'd0, retire_fflags}, {27'd0, sh_fflags});
                    end
                end

                if (retire_dmem_ren === 1'b1 && retire_dmem_wen === 1'b1) begin
                    bad_lane = bad_lane + 1;
                    report("dmem ren and wen both high", 32'd1, 32'd0);
                end else if (retire_dmem_ren === 1'b1 || retire_dmem_wen === 1'b1) begin
                    widx = (retire_dmem_addr - DMEM_BASE) >> 2;
                    if (retire_dmem_addr < DMEM_BASE ||
                        retire_dmem_addr >= DMEM_BASE + 4 * DMEM_WORDS ||
                        retire_dmem_addr[1:0] != 2'b00) begin
                        bad_lane = bad_lane + 1;
                        report("dmem address outside data memory", retire_dmem_addr, DMEM_BASE);
                    end else if (!mask_ok(funct3[1:0], retire_dmem_mask)) begin
                        bad_lane = bad_lane + 1;
                        report("dmem mask", {28'd0, retire_dmem_mask}, 32'd0);
                    end else if (retire_dmem_ren === 1'b1) begin
                        // The dcache's word, then the hart's extraction.
                        n_loads = n_loads + 1;
                        if (retire_dmem_rdata !== shadow[widx]) begin
                            bad_load = bad_load + 1;
                            report("load data from the dcache", retire_dmem_rdata, shadow[widx]);
                        end
                        if (is_flw) begin
                            if (retire_frd_wdata !== retire_dmem_rdata) begin
                                bad_lane = bad_lane + 1;
                                report("flw frd value from rdata", retire_frd_wdata, retire_dmem_rdata);
                            end
                        end else begin
                            lanes = retire_dmem_rdata >> (8 * mask_offset(retire_dmem_mask));
                            case (funct3)
                                3'b000:  want = {{24{lanes[7]}}, lanes[7:0]};
                                3'b001:  want = {{16{lanes[15]}}, lanes[15:0]};
                                3'b100:  want = {24'd0, lanes[7:0]};
                                3'b101:  want = {16'd0, lanes[15:0]};
                                default: want = lanes;
                            endcase
                            if (retire_rd_waddr != 5'd0 && retire_rd_wdata !== want) begin
                                bad_lane = bad_lane + 1;
                                report("load rd value from rdata", retire_rd_wdata, want);
                            end
                        end
                    end else begin
                        n_stores = n_stores + 1;
                        // fsw stores FP rs2; its integer rs2 is not read.
                        st_src = is_fsw ? retire_frs2_rdata : retire_rs2_rdata;
                        want   = st_src << (8 * mask_offset(retire_dmem_mask));
                        for (b = 0; b < 4; b = b + 1) begin
                            if (retire_dmem_mask[b] &&
                                retire_dmem_wdata[8*b +: 8] !== want[8*b +: 8]) begin
                                bad_lane = bad_lane + 1;
                                report(is_fsw ? "store wdata lane vs frs2" : "store wdata lane vs rs2",
                                       retire_dmem_wdata, want);
                            end
                            if (retire_dmem_mask[b])
                                shadow[widx][8*b +: 8] = retire_dmem_wdata[8*b +: 8];
                        end
                    end
                end

                // Register writes, after every check of this instruction's
                // sources (an instruction may read the register it writes).
                if (retire_trap !== 1'b1) begin
                    if (retire_rd_waddr !== 5'd0)
                        xs[retire_rd_waddr] = retire_rd_wdata;
                    if (retire_frd_wen === 1'b1)
                        fs[retire_frd_waddr] = retire_frd_wdata;
                end

                if (retire_halt === 1'b1) begin
                    if (retire_inst !== 32'h00100073)
                        report("halt on a non-ebreak", retire_inst, 32'h00100073);
                    halted = 1'b1;
                end
            end else if (retire_valid !== 1'b0) begin
                bad_pc = bad_pc + 1;
                report("o_retire_valid is X/Z", 32'd0, 32'd0);
            end
        end
    end

    // ------------------------------------------------------------------
    // Memory regions (phase_6.pdf 6.1)
    // ------------------------------------------------------------------
    reg [8*16-1:0] rg_name [0:N_REGIONS-1];
    reg [31:0]     rg_lo   [0:N_REGIONS-1];
    reg [31:0]     rg_hi   [0:N_REGIONS-1];

    initial begin
        rg_name[0]  = "program data"; rg_lo[0]  = 32'h10010000; rg_hi[0]  = 32'h10017FFF;
        rg_name[1]  = "muldiv";       rg_lo[1]  = 32'h10020000; rg_hi[1]  = 32'h100217FF;
        rg_name[2]  = "fp move cmp";  rg_lo[2]  = 32'h10021800; rg_hi[2]  = 32'h10022FFF;
        rg_name[3]  = "fp convert";   rg_lo[3]  = 32'h10023000; rg_hi[3]  = 32'h100247FF;
        rg_name[4]  = "fp add mul";   rg_lo[4]  = 32'h10024800; rg_hi[4]  = 32'h10025FFF;
        rg_name[5]  = "fp fused";     rg_lo[5]  = 32'h10026000; rg_hi[5]  = 32'h100277FF;
        rg_name[6]  = "fp div sqrt";  rg_lo[6]  = 32'h10027800; rg_hi[6]  = 32'h10028FFF;
        rg_name[7]  = "fp csr";       rg_lo[7]  = 32'h10029000; rg_hi[7]  = 32'h1002A7FF;
        rg_name[8]  = "mixed";        rg_lo[8]  = 32'h1002A800; rg_hi[8]  = 32'h1002BFFF;
        rg_name[9]  = "cache stall";  rg_lo[9]  = 32'h1002C000; rg_hi[9]  = 32'h1002D7FF;
        // The range the final loads flush through, and the unused tail.
        rg_name[10] = "flush range";  rg_lo[10] = 32'h10018000; rg_hi[10] = 32'h1001FFFF;
        rg_name[11] = "tail";         rg_lo[11] = 32'h1002D800; rg_hi[11] = 32'h1002FFFF;
    end

    // Words in [lo, hi] where a memory differs from random_dmem.hex.
    // which = 0: main memory, 1: the retire-stream shadow.
    function integer count_diff;
        input        which;
        input [31:0] lo;
        input [31:0] hi;
        integer a;
        reg [31:0] v;
        begin
            count_diff = 0;
            for (a = (lo - DMEM_BASE) >> 2; a <= (hi - DMEM_BASE) >> 2; a = a + 1) begin
                v = which ? shadow[a] : u_dmem.mem[a];
                if (v !== golden[a])
                    count_diff = count_diff + 1;
            end
        end
    endfunction

    // ------------------------------------------------------------------
    // Run
    // ------------------------------------------------------------------
    reg [8*48-1:0]  why;
    reg [8*256-1:0] prog_path;
    reg [8*256-1:0] dmem_path;
    integer i;
    integer r;
    integer fd;
    integer n_words;
    integer sec_main;
    integer sec_shadow;
    integer main_vs_shadow;
    integer guard_bad;
    integer cpi_x100;

    initial begin
        clk         = 1'b0;
        rst         = 1'b1;
        running     = 1'b0;
        o_done      = 1'b0;
        passed      = 0;
        failed      = 0;
        bad_load    = 0;
        bad_inst    = 0;
        bad_pc      = 0;
        bad_lane    = 0;
        bad_xsrc    = 0;
        bad_fsrc    = 0;
        bad_dst     = 0;
        bad_flags   = 0;
        bad_csr     = 0;
        bad_rmtrap  = 0;
        n_traps     = 0;
        dstall_errs = 0;
        msgs        = 0;
        cycles      = 0;
        idle        = 0;
        retired     = 0;
        n_loads     = 0;
        n_stores    = 0;
        n_fp        = 0;
        n_csr       = 0;
        halted      = 1'b0;
        have_prev   = 1'b0;
        sh_fflags   = 5'd0;
        sh_frm      = 3'd0;
        for (i = 0; i < DMEM_WORDS; i = i + 1)
            shadow[i] = 32'd0;
        for (i = 0; i < 32; i = i + 1) begin
            xs[i] = 32'd0;
            fs[i] = 32'd0;   // +0.0
        end

        wait (i_start === 1'b1);

        // vvp runs from build/ under make test; fall back to the repo root
        // for a manual run from there.
        prog_path = "../traces/random_program.hex";
        dmem_path = "../traces/random_dmem.hex";
        fd = $fopen(prog_path, "r");
        if (fd == 0) begin
            prog_path = "traces/random_program.hex";
            dmem_path = "traces/random_dmem.hex";
        end else begin
            $fclose(fd);
        end
        u_imem.load_hex(prog_path, prog_words);
        $readmemh(dmem_path, golden);

        $display("--- %0s: EVICT_POLICY=%0d NUM_WAYS=%0d CACHE_SIZE=%0d BLOCK_SIZE=%0d PREFETCH_EN=%0d, memory latency %0d, section %h-%h ---",
                 LABEL, EVICT_POLICY, NUM_WAYS, CACHE_SIZE, BLOCK_SIZE, PREFETCH_EN, LATENCY,
                 SEC_LO, SEC_HI);

        running = 1'b1;
        repeat (5) @(posedge clk);
        #1 rst = 1'b0;

        while (!halted && cycles < MAX_CYCLES && idle < IDLE_LIMIT &&
               retired < 2 * prog_words)
            @(posedge clk);

        if (!halted) begin
            $sformat(why, "%0s", idle >= IDLE_LIMIT ? "nothing retired for IDLE_LIMIT cycles" :
                                 cycles >= MAX_CYCLES ? "MAX_CYCLES reached" :
                                                        "retired twice the program length");
            if (retired == 0)
                $display("[FAIL] %0s: timed out at cycle %0d: %0s; nothing retired at all",
                         LABEL, cycles, why);
            else
                $display("[FAIL] %0s: timed out at cycle %0d: %0s; %0d instructions retired, last retired PC %h",
                         LABEL, cycles, why, retired, last_pc);
        end

        // Let memory traffic still in flight (e.g. a prefetch) land.
        repeat (4 * LATENCY + 20) @(posedge clk);
        running = 1'b0;

        check("program fits in instruction memory", prog_words > 0 && prog_words < IMEM_WORDS);
        check("program ran to its final ebreak", halted);
        // With nothing retired these would pass without checking anything.
        if (retired > 0) begin
            check("retired instruction words match the program (icache)", bad_inst == 0);
            check("retire PC sequence", bad_pc == 0);
            check("no traps", n_traps == 0);
            check("load data returned by the dcache", bad_load == 0);
            check("dmem address/mask/lane formatting (incl. flw/fsw)", bad_lane == 0);
            check("integer sources match the shadow register file", bad_xsrc == 0);
            check("FP sources match the shadow FP register file", bad_fsrc == 0);
            check("rd/frd reporting of F instructions", bad_dst == 0);
            check("fflags accrue and match the shadow fcsr", bad_flags == 0);
            check("CSR instructions read the shadow fcsr", bad_csr == 0);
            check("dynamic-rm trap matches the shadow frm", bad_rmtrap == 0);
        end
        check("no dcache request while ex_stall is high", dstall_errs == 0);
        $display("  %0s: retire-stream invariant errors: xsrc %0d, fsrc %0d, dst %0d, fflags %0d, csr %0d, rm-trap %0d, dcache-in-stall %0d | lanes %0d, load %0d, inst %0d, pc %0d, traps %0d",
                 LABEL, bad_xsrc, bad_fsrc, bad_dst, bad_flags, bad_csr, bad_rmtrap, dstall_errs,
                 bad_lane, bad_load, bad_inst, bad_pc, n_traps);

        if (halted) begin
            // Every dirty line was evicted before the ebreak, so main memory
            // is the architectural memory.
            main_vs_shadow = 0;
            for (i = 0; i < DMEM_WORDS; i = i + 1) begin
                if (u_dmem.mem[i] !== shadow[i]) begin
                    if (main_vs_shadow < 10)
                        $display("[FAIL] %0s: main memory at %h: %h, but the retire stream stored %h",
                                 LABEL, DMEM_BASE + 4 * i, u_dmem.mem[i], shadow[i]);
                    main_vs_shadow = main_vs_shadow + 1;
                end
            end
            check("main memory after halt equals the retire-stream stores", main_vs_shadow == 0);

            // INFO: every region, main memory and retire stream vs golden.
            for (r = 0; r < N_REGIONS; r = r + 1)
                $display("  INFO %0s: golden %-12s %h-%h: main memory %0d words differ, retire stream %0d",
                         LABEL, rg_name[r], rg_lo[r], rg_hi[r],
                         count_diff(1'b0, rg_lo[r], rg_hi[r]),
                         count_diff(1'b1, rg_lo[r], rg_hi[r]));

            // The section verdict.
            sec_main   = count_diff(1'b0, SEC_LO, SEC_HI);
            sec_shadow = count_diff(1'b1, SEC_LO, SEC_HI);
            n_words = 0;
            for (i = (SEC_LO - DMEM_BASE) >> 2; i <= (SEC_HI - DMEM_BASE) >> 2; i = i + 1) begin
                if (u_dmem.mem[i] !== golden[i]) begin
                    if (n_words < 10)
                        $display("[FAIL] %0s: section word at %h: got %h, expected %h",
                                 LABEL, DMEM_BASE + 4 * i, u_dmem.mem[i], golden[i]);
                    n_words = n_words + 1;
                end
            end
            $display("  %0s: section %h-%h: main memory %0d words differ, retire stream %0d",
                     LABEL, SEC_LO, SEC_HI, sec_main, sec_shadow);
            check("section: retire-stream stores match random_dmem.hex", sec_shadow == 0);
            check("section: main memory after halt matches random_dmem.hex", sec_main == 0);

            guard_bad = 0;
            for (i = DMEM_WORDS; i < DMEM_WORDS + GUARD_WORDS; i = i + 1)
                if (u_dmem.mem[i] !== 32'd0)
                    guard_bad = guard_bad + 1;
            check("nothing written past the end of data memory", guard_bad == 0);
        end

        check("memory protocol (see mem_model.vh)",
              u_imem.errors == 0 && u_dmem.errors == 0);

        cpi_x100 = retired > 0 ? (cycles * 100) / retired : 0;
        $display("  %0s: %0d cycles, %0d retired (%0d F/CSR, %0d CSR), CPI %0d.%02d | imem reads %0d | dmem reads %0d, write-backs %0d, write-throughs %0d | %0d loads, %0d stores",
                 LABEL, cycles, retired, n_fp, n_csr, cpi_x100 / 100, cpi_x100 % 100,
                 u_imem.n_rd, u_dmem.n_rd, u_dmem.n_wb, u_dmem.n_wt,
                 n_loads, n_stores);
        if (u_dmem.n_wr_empty + u_dmem.n_rd_wr_same + u_dmem.n_wr_inflight > 0)
            $display("  %0s: note: dmem writes with no byte enabled %0d, read+write of one line in a cycle %0d, writes to a line with a read in flight %0d",
                     LABEL, u_dmem.n_wr_empty, u_dmem.n_rd_wr_same, u_dmem.n_wr_inflight);

        o_done = 1'b1;
    end

endmodule

`endif
