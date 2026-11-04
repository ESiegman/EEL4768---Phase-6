`timescale 1ns / 1ps
`default_nettype none

// Testbench for rf with BYPASS_EN = 1: a same-cycle read of the register
// being written must return the NEW value (except x0, always 0).
// Inputs change at negedge, reads are checked just after it, and write
// results are only checked after the posedge that commits them.
module rf_bypass_tb;

    reg         clk;
    reg         rst;
    reg  [ 4:0] rs1_raddr;
    reg  [ 4:0] rs2_raddr;
    reg  [ 4:0] rd_waddr;
    reg  [31:0] rd_wdata;
    wire [31:0] rs1_rdata;
    wire [31:0] rs2_rdata;
    reg  [ 4:0] frs1_raddr;
    reg  [ 4:0] frs2_raddr;
    reg  [ 4:0] frs3_raddr;
    reg         frd_wen;
    reg  [ 4:0] frd_waddr;
    reg  [31:0] frd_wdata;
    wire [31:0] frs1_rdata;
    wire [31:0] frs2_rdata;
    wire [31:0] frs3_rdata;

    integer passed;
    integer failed;
    integer i;

    rf #(.BYPASS_EN(1)) dut (
        .i_clk       (clk),
        .i_rst       (rst),
        .i_rs1_raddr (rs1_raddr),
        .o_rs1_rdata (rs1_rdata),
        .i_rs2_raddr (rs2_raddr),
        .o_rs2_rdata (rs2_rdata),
        .i_rd_waddr  (rd_waddr),
        .i_rd_wdata  (rd_wdata),
        .i_frs1_raddr(frs1_raddr),
        .o_frs1_rdata(frs1_rdata),
        .i_frs2_raddr(frs2_raddr),
        .o_frs2_rdata(frs2_rdata),
        .i_frs3_raddr(frs3_raddr),
        .o_frs3_rdata(frs3_rdata),
        .i_frd_wen   (frd_wen),
        .i_frd_waddr (frd_waddr),
        .i_frd_wdata (frd_wdata)
    );

    always #5 clk = ~clk;

    task check;
        input [511:0] label;
        input [ 31:0] got;
        input [ 31:0] want;
        begin
            if (got === want) begin
                passed = passed + 1;
            end else begin
                failed = failed + 1;
                $display("[FAIL] %0s: got %h, expected %h", label, got, want);
            end
        end
    endtask

    // set both read addresses, wait #1, check both ports
    task read2;
        input [511:0] label;
        input [  4:0] a1;
        input [ 31:0] want1;
        input [  4:0] a2;
        input [ 31:0] want2;
        begin
            rs1_raddr = a1;
            rs2_raddr = a2;
            #1;
            // checks must land while clk is low, before the next posedge
            check({label, " (testbench timing: clk low)"}, {31'd0, clk},
                  32'd0);
            check({label, " (rs1)"}, rs1_rdata, want1);
            check({label, " (rs2)"}, rs2_rdata, want2);
        end
    endtask

    // wait one cycle, keeping the current inputs
    task sync;
        begin
            @(negedge clk);
        end
    endtask

    // wait one cycle, then idle both write ports and drop reset
    task next_cycle;
        begin
            @(negedge clk);
            rd_waddr  = 5'd0;
            rd_wdata  = 32'd0;
            frd_wen   = 1'b0;
            frd_waddr = 5'd0;
            frd_wdata = 32'd0;
            rst       = 1'b0;
        end
    endtask

    // set all three FP read addresses, wait #1, check all three ports
    task fread3;
        input [511:0] label;
        input [  4:0] a1;
        input [ 31:0] want1;
        input [  4:0] a2;
        input [ 31:0] want2;
        input [  4:0] a3;
        input [ 31:0] want3;
        begin
            frs1_raddr = a1;
            frs2_raddr = a2;
            frs3_raddr = a3;
            #1;
            check({label, " (testbench timing: clk low)"}, {31'd0, clk},
                  32'd0);
            check({label, " (frs1)"}, frs1_rdata, want1);
            check({label, " (frs2)"}, frs2_rdata, want2);
            check({label, " (frs3)"}, frs3_rdata, want3);
        end
    endtask

    // write one FP register (called at a negedge)
    task write_freg;
        input [ 4:0] addr;
        input [31:0] data;
        begin
            frd_wen   = 1'b1;
            frd_waddr = addr;
            frd_wdata = data;
            next_cycle;
        end
    endtask

    // write one register (called at a negedge)
    task write_reg;
        input [ 4:0] addr;
        input [31:0] data;
        begin
            rd_waddr = addr;
            rd_wdata = data;
            next_cycle;
        end
    endtask

    // distinct value per FP register, different from pat() so a read of the
    // wrong register set shows up; f0..f2 are edge cases
    function [31:0] fpat;
        input [4:0] r;
        begin
            case (r)
                5'd0:    fpat = 32'h7FC00000;
                5'd1:    fpat = 32'h80000000;
                5'd2:    fpat = 32'hFFFFFFFF;
                default: fpat = {2'b01, r, 3'b110, ~r, 4'h9, r, 8'hF0};
            endcase
        end
    endfunction

    // distinct value per register; x1..x3 are edge cases
    function [31:0] pat;
        input [4:0] r;
        begin
            case (r)
                5'd1:    pat = 32'hFFFFFFFF;
                5'd2:    pat = 32'h80000000;
                5'd3:    pat = 32'h00000001;
                default: pat = {3'b101, r, ~{3'b000, r}, 3'b011, r, 8'h3C};
            endcase
        end
    endfunction

    initial begin
        passed = 0;
        failed = 0;

        clk       = 1'b0;
        rst       = 1'b1;
        rs1_raddr = 5'd0;
        rs2_raddr = 5'd0;
        rd_waddr  = 5'd0;
        rd_wdata  = 32'd0;
        frs1_raddr = 5'd0;
        frs2_raddr = 5'd0;
        frs3_raddr = 5'd0;
        frd_wen    = 1'b0;
        frd_waddr  = 5'd0;
        frd_wdata  = 32'd0;

        $display("========== rf_bypass testbench ==========");

        // 2 cycles of reset
        sync;
        sync;
        rst = 1'b0;

        // --- 1. Reset clears every register ----------------------------------
        $display("--- 1. reset ---");
        write_reg(5'd1,  32'h11111111);
        write_reg(5'd7,  32'h77777777);
        write_reg(5'd16, 32'h16161616);
        write_reg(5'd31, 32'h31313131);
        read2("reset: x7/x31 written before reset", 5'd7, 32'h77777777,
              5'd31, 32'h31313131);
        sync;
        rst = 1'b1;
        next_cycle;
        for (i = 0; i < 32; i = i + 1) begin
            sync;
            read2("reset: register reads 0 after reset", i[4:0], 32'd0,
                  i[4:0], 32'd0);
        end

        // --- 2. x0 is hardwired to zero --------------------------------------
        $display("--- 2. x0 ---");
        sync;
        rd_waddr = 5'd0;
        rd_wdata = 32'hDEADBEEF;
        read2("x0: during write of DEADBEEF", 5'd0, 32'd0, 5'd0, 32'd0);
        next_cycle;
        read2("x0: after write of DEADBEEF", 5'd0, 32'd0, 5'd0, 32'd0);

        // --- 3. Every register x1..x31 holds its own value --------------------
        $display("--- 3. all registers ---");
        sync;
        for (i = 1; i < 32; i = i + 1)
            write_reg(i[4:0], pat(i[4:0]));
        for (i = 1; i < 32; i = i + 1) begin
            sync;
            read2("all regs: same register on both ports", i[4:0],
                  pat(i[4:0]), i[4:0], pat(i[4:0]));
        end
        // rs2 walks backwards so the two ports read different registers
        for (i = 1; i < 32; i = i + 1) begin
            sync;
            read2("all regs: different registers per port", i[4:0],
                  pat(i[4:0]), 6'd32 - i[5:0], pat(6'd32 - i[5:0]));
        end
        sync;
        read2("all regs: x0 still zero", 5'd0, 32'd0, 5'd0, 32'd0);

        // --- 4. Bypass: the write port is visible on the read ports ----------
        $display("--- 4a. same-cycle read returns new value ---");
        sync;
        rd_waddr = 5'd5;
        rd_wdata = 32'hA5A5A5A5;
        read2("bypass: x5 before edge reads new", 5'd5, 32'hA5A5A5A5,
              5'd5, 32'hA5A5A5A5);
        next_cycle;
        read2("bypass: x5 after edge reads new", 5'd5, 32'hA5A5A5A5,
              5'd5, 32'hA5A5A5A5);

        sync;
        rd_waddr = 5'd17;
        rd_wdata = 32'h00000000;
        read2("bypass: x17 before edge reads new (zero)", 5'd17, 32'h00000000,
              5'd17, 32'h00000000);
        next_cycle;
        read2("bypass: x17 after edge reads new (zero)", 5'd17, 32'h00000000,
              5'd17, 32'h00000000);

        sync;
        rd_waddr = 5'd31;
        rd_wdata = 32'h0BADF00D;
        read2("bypass: x31 before edge reads new", 5'd31, 32'h0BADF00D,
              5'd31, 32'h0BADF00D);
        next_cycle;
        read2("bypass: x31 after edge reads new", 5'd31, 32'h0BADF00D,
              5'd31, 32'h0BADF00D);

        $display("--- 4b. other registers are not bypassed ---");
        sync;
        rd_waddr = 5'd8;
        rd_wdata = 32'h88888888;
        read2("bypass: x9/x7 while writing x8", 5'd9, pat(5'd9),
              5'd7, pat(5'd7));
        read2("bypass: x24/x1 while writing x8", 5'd24, pat(5'd24),
              5'd1, pat(5'd1));
        next_cycle;
        read2("bypass: x9/x7 after writing x8", 5'd9, pat(5'd9),
              5'd7, pat(5'd7));

        $display("--- 4c. bypass never leaks into x0 ---");
        sync;
        rd_waddr = 5'd0;
        rd_wdata = 32'hFFFFFFFF;
        read2("bypass: x0 while writing x0 with FFFFFFFF", 5'd0, 32'd0,
              5'd0, 32'd0);
        next_cycle;
        read2("bypass: x0 after writing x0 with FFFFFFFF", 5'd0, 32'd0,
              5'd0, 32'd0);

        $display("--- 4d. one port bypassed, the other not ---");
        sync;
        rd_waddr = 5'd1;
        rd_wdata = 32'h12345678;
        read2("bypass: rs1=x1 (being written), rs2=x2", 5'd1, 32'h12345678,
              5'd2, pat(5'd2));
        read2("bypass: rs1=x2, rs2=x1 (being written)", 5'd2, pat(5'd2),
              5'd1, 32'h12345678);
        read2("bypass: rs1=x0, rs2=x1 (being written)", 5'd0, 32'd0,
              5'd1, 32'h12345678);
        next_cycle;
        read2("bypass: x1 after edge", 5'd1, 32'h12345678, 5'd2, pat(5'd2));

        // --- 5. Ports and registers are independent ---------------------------
        $display("--- 5. independence ---");
        sync;
        read2("independence: rs1=x3, rs2=x30", 5'd3, pat(5'd3),
              5'd30, pat(5'd30));
        read2("independence: rs1=x30, rs2=x3", 5'd30, pat(5'd30),
              5'd3, pat(5'd3));
        sync;
        rd_waddr = 5'd10;
        rd_wdata = 32'hCAFEBABE;
        read2("independence: x11/x9 while writing x10", 5'd11, pat(5'd11),
              5'd9, pat(5'd9));
        next_cycle;
        read2("independence: x11/x9 after writing x10", 5'd11, pat(5'd11),
              5'd9, pat(5'd9));
        read2("independence: x10 written", 5'd10, 32'hCAFEBABE,
              5'd10, 32'hCAFEBABE);

        // --- 6. Back-to-back writes to one register: last one wins ------------
        $display("--- 6. last write wins ---");
        sync;
        rd_waddr = 5'd12;
        rd_wdata = 32'h1111AAAA;
        sync;
        rd_waddr = 5'd12;
        rd_wdata = 32'h2222BBBB;
        read2("last write: x12 during 2nd write sees 2nd value", 5'd12,
              32'h2222BBBB, 5'd12, 32'h2222BBBB);
        next_cycle;
        read2("last write: x12 after both writes", 5'd12, 32'h2222BBBB,
              5'd12, 32'h2222BBBB);

        // --- 7. Reset beats a write in the same cycle ------------------------
        $display("--- 7. reset priority ---");
        sync;
        write_reg(5'd20, 32'h20202020);
        read2("reset priority: x20 set up", 5'd20, 32'h20202020,
              5'd20, 32'h20202020);
        sync;
        rst      = 1'b1;
        rd_waddr = 5'd20;
        rd_wdata = 32'hFEEDFACE;
        next_cycle;
        read2("reset priority: x20 is 0, not the write data", 5'd20, 32'd0,
              5'd20, 32'd0);
        read2("reset priority: other registers also 0", 5'd10, 32'd0,
              5'd31, 32'd0);

        // --- 8. Floating-point registers (phase_6.pdf 5.2) -------------------
        $display("--- 8a. FP reset ---");
        sync;
        write_freg(5'd0,  32'h3F800000);
        write_freg(5'd13, 32'h13131313);
        write_freg(5'd31, 32'h31313131);
        fread3("fp reset: f0/f13/f31 written before reset", 5'd0, 32'h3F800000,
               5'd13, 32'h13131313, 5'd31, 32'h31313131);
        sync;
        rst = 1'b1;
        next_cycle;
        for (i = 0; i < 32; i = i + 1) begin
            sync;
            fread3("fp reset: register reads +0.0 after reset", i[4:0], 32'd0,
                   i[4:0], 32'd0, i[4:0], 32'd0);
        end

        $display("--- 8b. every FP register f0..f31 holds its own value ---");
        sync;
        for (i = 0; i < 32; i = i + 1)
            write_freg(i[4:0], fpat(i[4:0]));
        for (i = 0; i < 32; i = i + 1) begin
            sync;
            fread3("fp regs: same register on all ports", i[4:0], fpat(i[4:0]),
                   i[4:0], fpat(i[4:0]), i[4:0], fpat(i[4:0]));
        end
        for (i = 0; i < 32; i = i + 1) begin
            sync;
            fread3("fp regs: different registers per port", i[4:0], fpat(i[4:0]),
                   5'd31 - i[4:0], fpat(5'd31 - i[4:0]),
                   i[4:0] ^ 5'b10101, fpat(i[4:0] ^ 5'b10101));
        end

        $display("--- 8c. f0 is an ordinary register ---");
        sync;
        write_freg(5'd0, 32'hC0490FDB);
        fread3("fp f0: written value reads back", 5'd0, 32'hC0490FDB,
               5'd0, 32'hC0490FDB, 5'd0, 32'hC0490FDB);

        $display("--- 8d. write enable ---");
        sync;
        frd_wen   = 1'b0;
        frd_waddr = 5'd6;
        frd_wdata = 32'hDEADBEEF;
        fread3("fp wen low: f6 not bypassed", 5'd6, fpat(5'd6),
               5'd6, fpat(5'd6), 5'd6, fpat(5'd6));
        next_cycle;
        fread3("fp wen low: f6 unchanged after edge", 5'd6, fpat(5'd6),
               5'd6, fpat(5'd6), 5'd6, fpat(5'd6));
        sync;
        frd_wen   = 1'b0;
        frd_waddr = 5'd0;
        frd_wdata = 32'hDEADBEEF;
        next_cycle;
        fread3("fp wen low: f0 unchanged after edge", 5'd0, 32'hC0490FDB,
               5'd0, 32'hC0490FDB, 5'd0, 32'hC0490FDB);

        $display("--- 8e. same-cycle FP read returns new value ---");
        sync;
        frd_wen   = 1'b1;
        frd_waddr = 5'd9;
        frd_wdata = 32'hA5A5A5A5;
        fread3("fp same cycle: f9 on all ports", 5'd9, 32'hA5A5A5A5,
               5'd9, 32'hA5A5A5A5, 5'd9, 32'hA5A5A5A5);
        fread3("fp same cycle: only the port reading f9", 5'd8, fpat(5'd8),
               5'd9, 32'hA5A5A5A5, 5'd10, fpat(5'd10));
        next_cycle;
        fread3("fp same cycle: f9 after edge", 5'd9, 32'hA5A5A5A5,
               5'd9, 32'hA5A5A5A5, 5'd9, 32'hA5A5A5A5);
        sync;
        frd_wen   = 1'b1;
        frd_waddr = 5'd0;
        frd_wdata = 32'h00000000;
        fread3("fp same cycle: f0 being written with +0.0", 5'd0, 32'h00000000,
               5'd1, fpat(5'd1), 5'd0, 32'h00000000);
        next_cycle;
        fread3("fp same cycle: f0 after edge", 5'd0, 32'h00000000,
               5'd0, 32'h00000000, 5'd0, 32'h00000000);

        $display("--- 8f. integer and FP sets are separate ---");
        sync;
        rd_waddr  = 5'd5;
        rd_wdata  = 32'h55555555;
        frd_wen   = 1'b1;
        frd_waddr = 5'd5;
        frd_wdata = 32'hF5F5F5F5;
        read2("separate: x5 while writing x5 and f5", 5'd5, 32'h55555555,
              5'd5, 32'h55555555);
        fread3("separate: f5 while writing x5 and f5", 5'd5, 32'hF5F5F5F5,
               5'd5, 32'hF5F5F5F5, 5'd5, 32'hF5F5F5F5);
        next_cycle;
        read2("separate: x5 after edge", 5'd5, 32'h55555555, 5'd5, 32'h55555555);
        fread3("separate: f5 after edge", 5'd5, 32'hF5F5F5F5,
               5'd5, 32'hF5F5F5F5, 5'd5, 32'hF5F5F5F5);
        sync;
        frd_wen   = 1'b1;
        frd_waddr = 5'd11;
        frd_wdata = 32'h0BADF00D;
        read2("separate: x11 while writing f11", 5'd11, 32'd0, 5'd11, 32'd0);
        next_cycle;
        read2("separate: x11 after writing f11", 5'd11, 32'd0, 5'd11, 32'd0);
        sync;
        rd_waddr = 5'd12;
        rd_wdata = 32'h12121212;
        fread3("separate: f12 while writing x12", 5'd12, fpat(5'd12),
               5'd12, fpat(5'd12), 5'd12, fpat(5'd12));
        next_cycle;
        fread3("separate: f12 after writing x12", 5'd12, fpat(5'd12),
               5'd12, fpat(5'd12), 5'd12, fpat(5'd12));

        $display("--- 8g. reset beats an FP write in the same cycle ---");
        sync;
        rst       = 1'b1;
        frd_wen   = 1'b1;
        frd_waddr = 5'd20;
        frd_wdata = 32'hFEEDFACE;
        next_cycle;
        fread3("fp reset priority: f20 is +0.0, not the write data", 5'd20, 32'd0,
               5'd20, 32'd0, 5'd20, 32'd0);
        fread3("fp reset priority: other FP registers also +0.0", 5'd0, 32'd0,
               5'd9, 32'd0, 5'd31, 32'd0);

        $display("============================================");
        $display("%0d passed, %0d failed", passed, failed);
        if (failed == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end

endmodule

`default_nettype wire
