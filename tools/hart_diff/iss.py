#!/usr/bin/env python3
"""TEST ONLY. Instruction-set model for tools/hart_diff.

Real RV32I and RV32M, and the same fake F semantics as standin_fpu.v (real
fcsr rules: accrued flags, CSR read/modify/write, dynamic-rm trap). Writes
one line per retired instruction in the format hart_diff_tb.v writes.

usage: iss.py program.hex out.trace
"""
import sys

M32 = 0xFFFFFFFF


def sx(v, b):
    v &= (1 << b) - 1
    return v - (1 << b) if v >> (b - 1) else v


def s32(v):
    return sx(v, 32)


def rotl(v, n):
    return ((v << n) | (v >> (32 - n))) & M32


def run(prog, out):
    imem = [int(l, 16) for l in open(prog) if l.strip()]
    dmem = {}
    x = [0] * 32
    f = [0] * 32
    fflags = 0
    frm = 0
    pc = 0x00400000
    o = open(out, "w")

    def ld(a):
        return dmem.get(a & ~3, 0)

    while True:
        inst = imem[(pc - 0x00400000) >> 2]
        opc = inst & 0x7F
        rd = (inst >> 7) & 31
        f3 = (inst >> 12) & 7
        r1 = (inst >> 15) & 31
        r2 = (inst >> 20) & 31
        r3 = inst >> 27
        f7 = inst >> 25
        immi = sx(inst >> 20, 12)
        imms = sx(((inst >> 25) << 5) | rd, 12)
        immb = sx(((inst >> 31) << 12) | (((inst >> 7) & 1) << 11) | (((inst >> 25) & 63) << 5) | (((inst >> 8) & 15) << 1), 13)
        immu = inst & 0xFFFFF000
        immj = sx(((inst >> 31) << 20) | (((inst >> 12) & 255) << 12) | (((inst >> 20) & 1) << 11) | (((inst >> 21) & 1023) << 1), 21)

        use1 = use2 = False
        fu = [False, False, False]
        rdw = None  # (reg, val)
        fdw = None
        ldr = None  # (addr, mask, data)
        st = None
        trap = False
        halt = False
        npc = (pc + 4) & M32
        legal = True
        rm_ok = f3 not in (5, 6)

        a, b = x[r1], x[r2]
        fsrc = [f[r1], f[r2], f[r3]]
        if opc == 0x37:
            rdw = (rd, immu)
        elif opc == 0x17:
            rdw = (rd, (pc + immu) & M32)
        elif opc == 0x6F:
            rdw = (rd, npc); npc = (pc + immj) & M32
        elif opc == 0x67 and f3 == 0:
            use1 = True; rdw = (rd, npc); npc = (a + immi) & M32 & ~1
        elif opc == 0x63 and f3 not in (2, 3):
            use1 = use2 = True
            c = {0: a == b, 1: a != b, 4: s32(a) < s32(b), 5: s32(a) >= s32(b), 6: a < b, 7: a >= b}[f3]
            if c:
                npc = (pc + immb) & M32
        elif (opc == 0x03 and f3 not in (3, 6, 7)) or (opc == 0x07 and f3 == 2):
            use1 = True
            ad = (a + immi) & M32
            size = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}[f3]
            if ad % size:
                trap = True
            else:
                w = ld(ad); off = ad & 3
                mask = ((1 << size) - 1) << off
                v = (w >> (8 * off)) & ((1 << (8 * size)) - 1)
                if opc == 0x03:
                    if f3 in (0, 1):
                        v = sx(v, 8 * size) & M32
                    rdw = (rd, v)
                else:
                    fdw = (rd, w)
                ldr = (ad & ~3, mask, w)
        elif (opc == 0x23 and f3 in (0, 1, 2)) or (opc == 0x27 and f3 == 2):
            use1 = True
            if opc == 0x23:
                use2 = True; sv = b
            else:
                fu[1] = True; sv = f[r2]
            ad = (a + imms) & M32
            size = 1 << f3
            if ad % size:
                trap = True
            else:
                off = ad & 3
                mask = ((1 << size) - 1) << off
                bm = sum(0xFF << (8 * i) for i in range(4) if mask >> i & 1)
                old = ld(ad)
                dmem[ad & ~3] = (old & ~bm) | ((sv << (8 * off)) & bm)
                st = (ad & ~3, mask, (sv << (8 * off)) & bm)
        elif opc == 0x13 and (f3 != 1 or f7 == 0) and (f3 != 5 or f7 in (0, 0x20)):
            use1 = True
            sh = immi & 31
            v = {0: a + immi, 2: int(s32(a) < immi), 3: int(a < (immi & M32)), 4: a ^ (immi & M32),
                 6: a | (immi & M32), 7: a & (immi & M32), 1: a << sh,
                 5: (s32(a) >> sh) if f7 == 0x20 else (a >> sh)}[f3]
            rdw = (rd, v & M32)
        elif opc == 0x33 and (f7 == 0 or (f7 == 0x20 and f3 in (0, 5))):
            use1 = use2 = True
            sh = b & 31
            v = {0: (a - b) if f7 else (a + b), 1: a << sh, 2: int(s32(a) < s32(b)), 3: int(a < b),
                 4: a ^ b, 5: (s32(a) >> sh) if f7 else (a >> sh), 6: a | b, 7: a & b}[f3]
            rdw = (rd, v & M32)
        elif opc == 0x33 and f7 == 1:
            use1 = use2 = True
            sa, sb = s32(a), s32(b)
            if f3 == 0: v = a * b
            elif f3 == 1: v = (sa * sb) >> 32
            elif f3 == 2: v = (sa * b) >> 32
            elif f3 == 3: v = (a * b) >> 32
            elif f3 == 4: v = M32 if b == 0 else (0x80000000 if (a == 0x80000000 and b == M32) else int(abs(sa) // abs(sb)) * (1 if (sa < 0) == (sb < 0) else -1))
            elif f3 == 5: v = M32 if b == 0 else a // b
            elif f3 == 6: v = a if b == 0 else (0 if (a == 0x80000000 and b == M32) else (abs(sa) % abs(sb)) * (-1 if sa < 0 else 1))
            else: v = a if b == 0 else a % b
            rdw = (rd, v & M32)
        elif inst == 0x00100073:
            halt = True
        else:
            # F / CSR, fake semantics identical to standins.v
            is_fma = opc in (0x43, 0x47, 0x4B, 0x4F) and ((inst >> 25) & 3) == 0 and rm_ok
            opfp = opc == 0x53
            kind = None
            if is_fma: kind = "fma"
            elif opfp and f7 in (0, 4, 8, 12) and rm_ok: kind = "arith"
            elif opfp and f7 == 0x2C and r2 == 0 and rm_ok: kind = "sqrt"
            elif opfp and f7 == 0x10 and f3 in (0, 1, 2): kind = "sgnj"
            elif opfp and f7 == 0x14 and f3 in (0, 1): kind = "minmax"
            elif opfp and f7 == 0x60 and r2 in (0, 1) and rm_ok: kind = "cvtws"
            elif opfp and f7 == 0x70 and r2 == 0 and f3 in (0, 1): kind = "mvxw"
            elif opfp and f7 == 0x50 and f3 in (0, 1, 2): kind = "cmp"
            elif opfp and f7 == 0x68 and r2 in (0, 1) and rm_ok: kind = "cvtsw"
            elif opfp and f7 == 0x78 and r2 == 0 and f3 == 0: kind = "mvwx"
            elif opc == 0x73 and f3 not in (0, 4) and (inst >> 20) in (1, 2, 3): kind = "csr"
            if kind is None:
                legal = False
                trap = True
            else:
                fa, fb, fc = f[r1], f[r2], f[r3]
                uses_rm = kind in ("fma", "arith", "sqrt", "cvtws", "cvtsw")
                rm = frm if f3 == 7 else f3
                if kind in ("cvtsw", "mvwx") or (kind == "csr" and not f3 & 4):
                    use1 = True
                fu[0] = kind not in ("cvtsw", "mvwx", "csr")
                fu[1] = kind in ("fma", "arith", "sgnj", "minmax", "cmp")
                fu[2] = kind == "fma"
                if uses_rm and f3 == 7 and frm >= 5:
                    trap = True
                else:
                    flag = False; intout = False
                    if kind == "csr":
                        csr = inst >> 20
                        old = fflags if csr == 1 else frm if csr == 2 else (frm << 5) | fflags
                        src = r1 if f3 & 4 else (a & 0xFF)
                        op = f3 & 3
                        if op == 1: new, wr = src, True
                        elif op == 2: new, wr = old | src, r1 != 0
                        else: new, wr = old & ~src & 0xFF, r1 != 0
                        if wr:
                            if csr == 1: fflags = new & 31
                            elif csr == 2: frm = new & 7
                            else: fflags = new & 31; frm = (new >> 5) & 7
                        rdw = (rd, old)
                    else:
                        if kind == "fma": res = fa + rotl(fb, 1) + rotl(fc, 2) + ((opc >> 2) & 3) + rm; flag = True
                        elif kind == "arith":
                            if f7 == 0: res = fa + rotl(fb, 1) + rm
                            elif f7 == 4: res = fa - rotl(fb, 1) + rm
                            elif f7 == 8: res = (fa ^ rotl(fb, 5)) + rm * 3
                            else: res = (fa - rotl(fb, 3)) ^ rm
                            flag = True
                        elif kind == "sqrt": res = (~fa & M32) + rm; flag = True
                        elif kind == "sgnj": res = fa ^ (fb & 0x80000000) ^ f3
                        elif kind == "minmax": res = (fa | fb) if f3 & 1 else (fa & fb); flag = True
                        elif kind == "cvtws": res = (fa ^ 0x55) + r2 + rm; flag = True; intout = True
                        elif kind == "mvxw": res = (fa & 0x3FF) if f3 & 1 else fa; intout = True
                        elif kind == "cmp": res = ((fa ^ fb) >> f3) & 1; flag = True; intout = True
                        elif kind == "cvtsw": res = a + 7 + r2 + rm; flag = True
                        else: res = a
                        res &= M32
                        if flag:
                            fflags |= res >> 27
                        if intout: rdw = (rd, res)
                        else: fdw = (rd, res)

        if trap:
            rdw = fdw = ldr = st = None
            npc = (pc + 4) & M32
        if rdw and rdw[0]:
            x[rdw[0]] = rdw[1] & M32
        if fdw:
            f[fdw[0]] = fdw[1] & M32
        s = "%08x %08x t%d h%d npc=%08x x%d=%08x x%d=%08x" % (
            pc, inst, trap, halt, npc, r1 if use1 else 0, a if use1 and r1 else 0,
            r2 if use2 else 0, b if use2 and r2 else 0)
        rs = [r1, r2, r3]
        for i in range(3):
            s += " f%d=%08x" % ((rs[i], fsrc[i]) if fu[i] else (0, 0))
        if rdw and rdw[0]:
            s += " rd%d=%08x" % rdw
        if fdw:
            s += " fd%d=%08x" % fdw
        s += " ff=%02x" % fflags
        if ldr:
            s += " ld[%08x]%x=%08x" % ldr
        if st:
            s += " st[%08x]%x=%08x" % st
        o.write(s + "\n")
        pc = npc
        if halt:
            break
    o.close()


if __name__ == "__main__":
    run(sys.argv[1], sys.argv[2])
