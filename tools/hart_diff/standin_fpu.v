`default_nettype none

// TEST ONLY -- not synthesizable, never submit. See tools/hart_diff/README.md.
`ifndef FDIV_LAT
`define FDIV_LAT 12
`endif
// Fake FPU: deterministic nonsense results with the real fcsr rules
// (accrue, commit on advance, CSR semantics, dynamic rm trap) and
// multi-cycle fdiv/fsqrt.
module fpu #(
    parameter DIV_LAT = `FDIV_LAT
) (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire [31:0] i_inst,
    input  wire        i_valid,
    input  wire        i_advance,
    input  wire [31:0] i_frs1,
    input  wire [31:0] i_frs2,
    input  wire [31:0] i_frs3,
    input  wire [31:0] i_xrs1,
    output reg  [31:0] o_fp_result,
    output reg  [31:0] o_int_result,
    output wire [ 4:0] o_fflags,
    output wire        o_busy,
    output wire        o_rm_trap
);
    reg [4:0] fflags;
    reg [2:0] frm;
    wire [6:0] opc = i_inst[6:0];
    wire [2:0] f3  = i_inst[14:12];
    wire [6:0] f7  = i_inst[31:25];
    wire [4:0] r2  = i_inst[24:20];
    wire [4:0] r1  = i_inst[19:15];
    wire [11:0] csr = i_inst[31:20];
    wire is_fma = opc[6:4] == 3'b100;
    wire opfp   = opc == 7'b1010011;
    wire is_csr = opc == 7'b1110011;
    wire multi  = opfp && (f7 == 7'h0C || f7 == 7'h2C);
    wire uses_rm = is_fma || (opfp && (f7 == 7'h00 || f7 == 7'h04 || f7 == 7'h08 ||
                   f7 == 7'h0C || f7 == 7'h2C || f7 == 7'h60 || f7 == 7'h68));
    wire [2:0] rm = (f3 == 3'b111) ? frm : f3;
    assign o_rm_trap = i_valid && uses_rm && f3 == 3'b111 && frm >= 3'd5;

    function [31:0] rotl;
        input [31:0] v;
        input integer n;
        rotl = (v << n) | (v >> (32 - n));
    endfunction

    reg [31:0] res;
    reg        flag_op;
    reg        int_out;
    reg [7:0]  csr_old, csr_new;
    reg        csr_wr;
    always @(*) begin
        res = 0; flag_op = 0; int_out = 0; csr_old = 0; csr_new = 0; csr_wr = 0;
        if (is_csr) begin
            int_out = 1;
            csr_old = (csr == 12'h001) ? {3'd0, fflags} :
                      (csr == 12'h002) ? {5'd0, frm} : {frm, fflags};
            res = {24'd0, csr_old};
            case (f3[1:0])
                2'b01: begin csr_new = f3[2] ? {3'd0, r1} : i_xrs1[7:0]; csr_wr = 1; end
                2'b10: begin csr_new = csr_old | (f3[2] ? {3'd0, r1} : i_xrs1[7:0]); csr_wr = r1 != 0; end
                default: begin csr_new = csr_old & ~(f3[2] ? {3'd0, r1} : i_xrs1[7:0]); csr_wr = r1 != 0; end
            endcase
        end else if (is_fma) begin
            res = i_frs1 + rotl(i_frs2, 1) + rotl(i_frs3, 2) + opc[3:2] + rm; flag_op = 1;
        end else case (f7)
            7'h00: begin res = i_frs1 + rotl(i_frs2, 1) + rm; flag_op = 1; end
            7'h04: begin res = i_frs1 - rotl(i_frs2, 1) + rm; flag_op = 1; end
            7'h08: begin res = (i_frs1 ^ rotl(i_frs2, 5)) + rm * 3; flag_op = 1; end
            7'h0C: begin res = (i_frs1 - rotl(i_frs2, 3)) ^ rm; flag_op = 1; end
            7'h2C: begin res = ~i_frs1 + rm; flag_op = 1; end
            7'h10: res = i_frs1 ^ (i_frs2 & 32'h80000000) ^ f3;
            7'h14: begin res = f3[0] ? (i_frs1 | i_frs2) : (i_frs1 & i_frs2); flag_op = 1; end
            7'h60: begin res = (i_frs1 ^ 32'h55) + r2 + rm; flag_op = 1; int_out = 1; end
            7'h70: begin res = f3[0] ? (i_frs1 & 32'h3FF) : i_frs1; int_out = 1; end
            7'h50: begin res = ((i_frs1 ^ i_frs2) >> f3) & 1; flag_op = 1; int_out = 1; end
            7'h68: begin res = i_xrs1 + 7 + r2 + rm; flag_op = 1; end
            default: res = i_xrs1;  // fmv.w.x
        endcase
    end
    wire [4:0] new_flags = flag_op ? res[31:27] : 5'd0;
    wire [4:0] flags_after = is_csr ? ((csr_wr && csr != 12'h002) ? csr_new[4:0] : fflags)
                                    : (fflags | new_flags);
    wire [2:0] frm_after = (is_csr && csr_wr && csr == 12'h002) ? csr_new[2:0] :
                           (is_csr && csr_wr && csr == 12'h003) ? csr_new[7:5] : frm;
    assign o_fflags = (i_valid && !o_rm_trap) ? flags_after : fflags;

    integer cnt;
    reg     done;
    always @(posedge i_clk) begin
        if (i_rst) begin
            fflags <= 0; frm <= 0; cnt <= 0; done <= 0;
        end else if (i_advance) begin
            cnt <= 0; done <= 0;
            if (i_valid && !o_rm_trap) begin
                fflags <= flags_after;
                frm    <= frm_after;
            end
        end else if (i_valid && multi && !o_rm_trap && !done) begin
            cnt <= cnt + 1;
            if (cnt + 1 >= DIV_LAT) done <= 1;
        end
    end
    assign o_busy = i_valid && multi && !o_rm_trap && !done && DIV_LAT > 0;
    always @(*) begin
        o_fp_result  = (multi && !done && DIV_LAT > 0) ? 32'hBAD0F00D : res;
        o_int_result = res;
    end
endmodule

`default_nettype wire
