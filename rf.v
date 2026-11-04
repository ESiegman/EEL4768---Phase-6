`default_nettype none

// The register file is effectively a single cycle memory with 32-bit words
// and depth 32. It has two asynchronous read ports, allowing two independent
// registers to be read at the same time combinationally, and one synchronous
// write port, allowing a register to be written to on the next clock edge.
//
// The register `x0` is hardwired to zero.
// NOTE: This can be implemented either by silently discarding writes to
// address 5'd0, or by muxing the output to zero when reading from that
// address.
//
// Phase 6: the same module also holds the 32 floating-point registers
// f0-f31, with three read ports (the fused multiply-add instructions read
// rs3) and a write port with an explicit write enable. Unlike x0, f0 is an
// ordinary register, so address 5'd0 cannot mean "no write" there.
module rf #
(
    // 1: a write is visible on the read ports in the same cycle (bypass).
    // Phase 4 uses 1 (phase_4.pdf 4.4); both modes are tested. Applies to
    // both register sets (phase_6.pdf 5.2).
    parameter BYPASS_EN = 1
) 

(
    // Global clock.
    input  wire        i_clk,
    // Synchronous active-high reset.
    input  wire        i_rst,
    // Both read register ports are asynchronous (zero-cycle). That is, read
    // data is visible combinationally without having to wait for a clock.
    //
    // The read ports are *independent* and can read two different registers
    // (but of course, also the same register if needed).
    //
    // Register `x0` is hardwired to zero, so reading from address 5'd0
    // should always return 32'd0 on either port regardless of any writes.
    //
    // Register read port 1, with input address [0, 31] and output data.
    input  wire [ 4:0] i_rs1_raddr,
    output wire [31:0] o_rs1_rdata,
    // Register read port 2, with input address [0, 31] and output data.
    input  wire [ 4:0] i_rs2_raddr,
    output wire [31:0] o_rs2_rdata,
    
    // The register write port is synchronous. with no write enable,
    // a write to any adress other than 5'd0 happens at the next
    // clock edge.
    // A write to 5'd0 is discarded, so x0 stays zero.
    //
    // Write register address [0, 31] and input data.
    input  wire [ 4:0] i_rd_waddr,
    input  wire [31:0] i_rd_wdata,

    // Floating-point read ports 1-3, with input address [0, 31] and output
    // data. All three are asynchronous and independent, like the integer
    // ports. f0 is an ordinary register.
    input  wire [ 4:0] i_frs1_raddr,
    output wire [31:0] o_frs1_rdata,
    input  wire [ 4:0] i_frs2_raddr,
    output wire [31:0] o_frs2_rdata,
    input  wire [ 4:0] i_frs3_raddr,
    output wire [31:0] o_frs3_rdata,
    // Floating-point write port: synchronous, written at the next clock edge
    // when the write enable is high (any address, f0 included).
    input  wire        i_frd_wen,
    input  wire [ 4:0] i_frd_waddr,
    input  wire [31:0] i_frd_wdata
);
    // Your implementation goes under here
    // ------------------------------------
    
reg  [31:0] regs [0:31];

genvar i;
generate
    for (i = 1; i < 32; i = i + 1) begin : g_regs
    always @(posedge i_clk)
    begin
    //reset is checked first, so it wins over a write in the same cycle
        if (i_rst)
        //resets all registers to 0.
        regs[i] <= 32'd0;
        //there is no write enable: the register is written when the write
        //address selects it (address 0 selects nothing, so it means "no write")
        else if (i_rd_waddr == i)
        //when neither of the conditions are met, the register holds the value
        regs[i] <= i_rd_wdata;
    end
end
endgenerate

//rsX_stored is a 32 bit value. If the address on the read address is 0, then its 0
//otherwise, it is the whatever data is stored inside the array at the address
wire [31:0] rs1_stored = (i_rs1_raddr == 5'd0) ? 32'd0 : regs[i_rs1_raddr];
wire [31:0] rs2_stored = (i_rs2_raddr == 5'd0) ? 32'd0 : regs[i_rs2_raddr];

generate
if (BYPASS_EN != 0)
begin : g_bypass
    //bypass when reading the register being written this cycle (never x0)
    wire rs1_byp = (i_rs1_raddr == i_rd_waddr) && (i_rs1_raddr != 5'd0);
    wire rs2_byp = (i_rs2_raddr == i_rd_waddr) && (i_rs2_raddr != 5'd0);
    assign o_rs1_rdata = rs1_byp ? i_rd_wdata : rs1_stored;
    assign o_rs2_rdata = rs2_byp ? i_rd_wdata : rs2_stored;
end
else 
begin : g_no_bypass
    assign o_rs1_rdata = rs1_stored;
    assign o_rs2_rdata = rs2_stored;
end
endgenerate

// floating-point registers f0-f31. same structure as the integer set, but
// f0 is a real register and writes need i_frd_wen.
reg  [31:0] fregs [0:31];

genvar j;
generate
    for (j = 0; j < 32; j = j + 1) begin : g_fregs
    always @(posedge i_clk)
    begin
        //reset clears every FP register to +0.0 (all zero bits)
        if (i_rst)
        fregs[j] <= 32'd0;
        else if (i_frd_wen && (i_frd_waddr == j))
        fregs[j] <= i_frd_wdata;
    end
end
endgenerate

wire [31:0] frs1_stored = fregs[i_frs1_raddr];
wire [31:0] frs2_stored = fregs[i_frs2_raddr];
wire [31:0] frs3_stored = fregs[i_frs3_raddr];

generate
if (BYPASS_EN != 0)
begin : g_fbypass
    //bypass any FP write in flight, f0 included
    wire frs1_byp = i_frd_wen && (i_frs1_raddr == i_frd_waddr);
    wire frs2_byp = i_frd_wen && (i_frs2_raddr == i_frd_waddr);
    wire frs3_byp = i_frd_wen && (i_frs3_raddr == i_frd_waddr);
    assign o_frs1_rdata = frs1_byp ? i_frd_wdata : frs1_stored;
    assign o_frs2_rdata = frs2_byp ? i_frd_wdata : frs2_stored;
    assign o_frs3_rdata = frs3_byp ? i_frd_wdata : frs3_stored;
end
else
begin : g_no_fbypass
    assign o_frs1_rdata = frs1_stored;
    assign o_frs2_rdata = frs2_stored;
    assign o_frs3_rdata = frs3_stored;
end
endgenerate
endmodule

`default_nettype wire
