#!/usr/bin/env python3
"""TEST ONLY. Writes a short hand-assembled program (directed.hex) that the
phase 6 trace never exercises: dynamic-rm traps, illegal F/CSR encodings,
misaligned flw/fsw, and rs3 / fsw-data / flags hazards back to back.

usage: directed.py out.hex
"""
import sys
def R(f7,rs2,rs1,f3,rd,op): return (f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op
def I(imm,rs1,f3,rd,op): return ((imm&0xFFF)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op
def S(imm,rs2,rs1,f3,op): return (((imm>>5)&0x7F)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((imm&31)<<7)|op
def R4(rs3,rs2,rs1,rm,rd,op): return (rs3<<27)|(rs2<<20)|(rs1<<15)|(rm<<12)|(rd<<7)|op
lui=lambda rd,imm: (imm<<12)|(rd<<7)|0x37
addi=lambda rd,rs1,imm: I(imm,rs1,0,rd,0x13)
lw=lambda rd,rs1,imm: I(imm,rs1,2,rd,0x03)
sw=lambda rs2,rs1,imm: S(imm,rs2,rs1,2,0x23)
flw=lambda rd,rs1,imm: I(imm,rs1,2,rd,0x07)
fsw=lambda rs2,rs1,imm: S(imm,rs2,rs1,2,0x27)
fadd=lambda rd,a,b,rm=0: R(0,b,a,rm,rd,0x53)
fdiv=lambda rd,a,b,rm=0: R(0x0C,b,a,rm,rd,0x53)
fsqrt=lambda rd,a,rm=0: R(0x2C,0,a,rm,rd,0x53)
fmvwx=lambda rd,rs1: R(0x78,0,rs1,0,rd,0x53)
fmvxw=lambda rd,rs1: R(0x70,0,rs1,0,rd,0x53)
feq=lambda rd,a,b: R(0x50,b,a,2,rd,0x53)
fcvtsw=lambda rd,rs1,rm=0: R(0x68,0,rs1,rm,rd,0x53)
fmadd=lambda rd,a,b,c,rm=0: R4(c,b,a,rm,rd,0x43)
csr=lambda f3,rd,c,rs1: I(c,rs1,f3,rd,0x73)
mul=lambda rd,a,b: R(1,b,a,0,rd,0x33)
div=lambda rd,a,b: R(1,b,a,4,rd,0x33)
add=lambda rd,a,b: R(0,b,a,0,rd,0x33)
p=[lui(10,0x10010), lui(11,0x10018),
   addi(5,0,123), fmvwx(1,5), fmvwx(2,10), fcvtsw(3,5),            # int->FP
   fadd(4,1,2), fmadd(6,1,2,4), fsw(6,10,0), flw(7,10,0), fadd(8,7,7),   # rs3 / fsw data / flw load-use
   feq(12,8,1), add(13,12,12), fmvxw(14,8), sw(14,10,4),             # FP->int forwarding
   fdiv(9,8,1), csr(2,15,1,0),                                       # fdiv then frflags
   lw(16,11,0), fdiv(9,9,1), lw(17,11,0x40), fsqrt(18,9), mul(19,5,5), div(20,19,5), lw(21,11,0x80), add(22,20,21),
   csr(5,0,2,5), fadd(23,1,2,7), fadd(24,1,2,0), fsqrt(25,1,7), fdiv(26,1,2,7),  # frm=5: dynamic rm traps
   csr(5,0,2,7), fcvtsw(27,5,7), csr(5,27,2,1), fadd(28,1,2,7),              # frm=7 traps, then frm=1 OK
   fadd(29,1,2,5), fadd(29,1,2,6), R(0x2C,1,1,0,29,0x53), R4(3,2,1,0,29,0x43)|(1<<25),  # illegal: rm 5/6, fsqrt rs2!=0, fmt!=0
   csr(1,0,0x004,5), csr(1,0,0x001,5),                               # bad CSR address 4 is illegal; fflags=x5
   flw(30,10,1), fsw(1,10,2), flw(30,10,4), fsw(30,10,8), lw(31,10,8),   # misaligned flw/fsw trap
   csr(1,6,3,0), csr(6,7,1,0), csr(7,8,3,31), csr(2,9,3,0), fadd(0,1,2,0), fadd(0,0,0,0), fsw(0,10,12),
   0x00100073]
open(sys.argv[1],'w').write(''.join('%08x\n'%w for w in p))
