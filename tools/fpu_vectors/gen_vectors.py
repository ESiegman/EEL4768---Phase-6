#!/usr/bin/env python3
"""Generates the fpu_tb.v vectors in this directory. README.md says how to
build the two tools it runs.

usage: gen_vectors.py --testfloat-gen PATH --sf-eval PATH [--out DIR]

Golden values come from Berkeley TestFloat (testfloat_gen, built on SoftFloat
with SPECIALIZE_TYPE=RISCV, so NaN results are 0x7FC00000 and out-of-range
conversions saturate the RISC-V way), run with -tininessafter, all five
rounding modes, and -exact for the conversions to integer. testfloat_gen has
a minimum case count per function (46464 for two operands, 6133248 for
f32_mulAdd), so each function's stream is subsampled with a fixed seed. The
directed vectors from phase_6.pdf are evaluated with sf_eval (the same
SoftFloat) and checked against the values the PDF states.

special.hex is a cross product of special values (zeros, ones, subnormals,
max finite, infinities, quiet and signaling NaNs) for every instruction, so
each special-operand rule is hit deterministically.

TestFloat has no min/max/classify/sign-injection/move, so those are computed
by the small reference below, on operands taken from testfloat_gen's own
f32_add stream (which is full of NaNs, infinities, zeros and subnormals).

One vector per line, all hex:
    inst frs1 frs2 frs3 xrs1 result ctrl
ctrl[7:5] is the frm the testbench writes (with fflags = 0) through a CSR
instruction before the vector; ctrl[4:0] is the expected flags (NV DZ OF UF
NX, which is SoftFloat's flag order too). result is o_fp_result or
o_int_result, whichever the instruction writes. A quarter of each rounding
function's vectors use rm = 111 with frm set to the mode (dynamic rounding);
the rest use a static rm, with frm set to a random value, reserved ones
included, which must not matter.
"""
import argparse
import os
import random
import subprocess
import sys

MODES = ["rnear_even", "rminMag", "rmin", "rmax", "rnear_maxMag"]  # rm 0-4
SEED = 4768
PER_MODE = 320        # vectors per rounding function and mode
PER_COMPARE = 1000    # feq/flt/fle
PER_OTHER = 600       # the non-rounding instructions without TestFloat
NEG = 0x80000000

OPFP = 0b1010011
RD, RS1, RS2, RS3 = 1, 2, 3, 4


def r_type(f7, rs2, f3, opc=OPFP, rs1=RS1, rd=RD):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc


def r4_type(opc, rm):
    return (RS3 << 27) | (RS2 << 20) | (RS1 << 15) | (rm << 12) | (RD << 7) | opc


# Rounding instructions: name -> (testfloat function, encoder(rm), operand
# mapping). The mapping turns a testfloat case (a, b, c) into the FPU's
# (frs1, frs2, frs3, xrs1). Negating an input is exact, so the fused
# variants come from f32_mulAdd: fmsub(a,b,-c) = fnmsub(-a,b,c) =
# fnmadd(-a,b,-c) = a*b+c.
ROUNDING = {
    "fadd":      ("f32_add",     lambda rm: r_type(0b0000000, RS2, rm), lambda a, b, c: (a, b, 0, 0)),
    "fsub":      ("f32_sub",     lambda rm: r_type(0b0000100, RS2, rm), lambda a, b, c: (a, b, 0, 0)),
    "fmul":      ("f32_mul",     lambda rm: r_type(0b0001000, RS2, rm), lambda a, b, c: (a, b, 0, 0)),
    "fdiv":      ("f32_div",     lambda rm: r_type(0b0001100, RS2, rm), lambda a, b, c: (a, b, 0, 0)),
    "fsqrt":     ("f32_sqrt",    lambda rm: r_type(0b0101100, 0, rm),   lambda a, b, c: (a, 0, 0, 0)),
    "fmadd":     ("f32_mulAdd",  lambda rm: r4_type(0b1000011, rm),     lambda a, b, c: (a, b, c, 0)),
    "fmsub":     ("f32_mulAdd",  lambda rm: r4_type(0b1000111, rm),     lambda a, b, c: (a, b, c ^ NEG, 0)),
    "fnmsub":    ("f32_mulAdd",  lambda rm: r4_type(0b1001011, rm),     lambda a, b, c: (a ^ NEG, b, c, 0)),
    "fnmadd":    ("f32_mulAdd",  lambda rm: r4_type(0b1001111, rm),     lambda a, b, c: (a ^ NEG, b, c ^ NEG, 0)),
    "fcvt_w_s":  ("f32_to_i32",  lambda rm: r_type(0b1100000, 0, rm),   lambda a, b, c: (a, 0, 0, 0)),
    "fcvt_wu_s": ("f32_to_ui32", lambda rm: r_type(0b1100000, 1, rm),   lambda a, b, c: (a, 0, 0, 0)),
    "fcvt_s_w":  ("i32_to_f32",  lambda rm: r_type(0b1101000, 0, rm),   lambda a, b, c: (0, 0, 0, a)),
    "fcvt_s_wu": ("ui32_to_f32", lambda rm: r_type(0b1101000, 1, rm),   lambda a, b, c: (0, 0, 0, a)),
}
COMPARES = {
    "feq": ("f32_eq", r_type(0b1010000, RS2, 0b010)),
    "flt": ("f32_lt", r_type(0b1010000, RS2, 0b001)),
    "fle": ("f32_le", r_type(0b1010000, RS2, 0b000)),
}
N_INPUTS = {"f32_sqrt": 1, "f32_to_i32": 1, "f32_to_ui32": 1, "i32_to_f32": 1,
            "ui32_to_f32": 1, "f32_mulAdd": 3}


def line(inst, a, b, c, x, result, frm, flags):
    return "%08X %08X %08X %08X %08X %08X %02X" % (
        inst, a, b, c, x, result, ((frm & 7) << 5) | (flags & 31))


def min_cases(tg, fn):
    out = subprocess.run([tg, "-n", "1", fn], capture_output=True, text=True)
    msg = out.stderr + out.stdout
    marker = "minimum is "
    if marker not in msg:
        sys.exit("cannot read testfloat_gen's minimum for %s: %s" % (fn, msg))
    return int(msg.split(marker)[1].split(".")[0])


def sample(tg, fn, mode, count, rng):
    """count cases of fn in mode, picked uniformly (fixed seed) from the
    testfloat_gen stream. Returns [(inputs..., result, flags)]."""
    total = max(min_cases(tg, fn), 8 * count)
    want = set(rng.sample(range(total), count))
    args = [tg, "-seed", str(SEED), "-n", str(total), "-tininessafter", "-" + mode]
    if fn in ("f32_to_i32", "f32_to_ui32"):
        args.append("-exact")
    proc = subprocess.Popen(args + [fn], stdout=subprocess.PIPE, text=True, bufsize=1 << 20)
    picked = []
    n_in = N_INPUTS.get(fn, 2)
    for i, ln in enumerate(proc.stdout):
        if i in want:
            f = ln.split()
            picked.append(tuple(int(v, 16) for v in f[:n_in]) + (int(f[n_in], 16), int(f[n_in + 1], 16)))
    proc.wait()
    if proc.returncode != 0 or len(picked) != count:
        sys.exit("testfloat_gen %s %s failed (%d of %d cases)" % (fn, mode, len(picked), count))
    return picked


# ---------------------------------------------------------------------------
# Reference for the non-rounding instructions (phase_6.pdf 4.7.4-4.7.6).
# ---------------------------------------------------------------------------
def is_nan(v):
    return (v >> 23) & 0xFF == 0xFF and v & 0x7FFFFF != 0


def is_snan(v):
    return is_nan(v) and not (v >> 22) & 1


def as_key(v):
    """Total order key for non-NaN values with -0 < +0."""
    mag = v & 0x7FFFFFFF
    return -mag - 1 if v >> 31 else mag


def fminmax(a, b, is_max):
    flags = 0x10 if (is_snan(a) or is_snan(b)) else 0
    if is_nan(a) and is_nan(b):
        return 0x7FC00000, flags
    if is_nan(a):
        return b, flags
    if is_nan(b):
        return a, flags
    lo, hi = (a, b) if as_key(a) <= as_key(b) else (b, a)
    return (hi if is_max else lo), flags


def fclass(v):
    s, e, f = v >> 31, (v >> 23) & 0xFF, v & 0x7FFFFF
    if e == 0xFF:
        bit = 7 if f == 0 else (9 if f >> 22 else 8)
        if f == 0 and s:
            bit = 0
    elif e == 0:
        bit = (3 if s else 4) if f == 0 else (2 if s else 5)
    else:
        bit = 1 if s else 6
    return 1 << bit


def sgnj(a, b, kind):
    sign = {0: b >> 31, 1: (b >> 31) ^ 1, 2: (a ^ b) >> 31}[kind]
    return (sign << 31) | (a & 0x7FFFFFFF)


# ---------------------------------------------------------------------------
# Directed vectors from phase_6.pdf, evaluated by sf_eval and checked against
# the values the PDF states.
# ---------------------------------------------------------------------------
def sf_eval(tool, cases):
    text = "".join("%s %d %s\n" % (fn, rm, " ".join("%08X" % v for v in ops)) for fn, rm, ops in cases)
    out = subprocess.run([tool], input=text, capture_output=True, text=True, check=True).stdout.split("\n")
    return [(int(l.split()[0], 16), int(l.split()[1], 16)) for l in out if l.strip()]


def directed(tool):
    ONE, THREE, HALF = 0x3F800000, 0x40400000, 0x3F000000
    MAXF = 0x7F7FFFFF
    # (name, instruction, testfloat function, operand mapping for sf_eval,
    #  (frs1, frs2, frs3, xrs1), rm, PDF-stated (result, flags) or None)
    pdf = []
    third = {0: (0x3EAAAAAB, 0xBEAAAAAB), 1: (0x3EAAAAAA, 0xBEAAAAAA), 2: (0x3EAAAAAA, 0xBEAAAAAB),
             3: (0x3EAAAAAB, 0xBEAAAAAA), 4: (0x3EAAAAAB, 0xBEAAAAAB)}
    over = {0: (0x7F800000, 0xFF800000), 1: (0x7F7FFFFF, 0xFF7FFFFF), 2: (0x7F7FFFFF, 0xFF800000),
            3: (0x7F800000, 0xFF7FFFFF), 4: (0x7F800000, 0xFF800000)}
    for rm in range(5):
        # 4.5.2: 1/3 and -1/3 in every mode, all NX.
        pdf.append(("fdiv", ("f32_div", (ONE, THREE)), (ONE, THREE, 0, 0), rm, (third[rm][0], 0x01)))
        pdf.append(("fdiv", ("f32_div", (ONE ^ NEG, THREE)), (ONE ^ NEG, THREE, 0, 0), rm, (third[rm][1], 0x01)))
        # 4.5.3: overflow per mode (largest finite + itself), OF and NX.
        pdf.append(("fadd", ("f32_add", (MAXF, MAXF)), (MAXF, MAXF, 0, 0), rm, (over[rm][0], 0x05)))
        pdf.append(("fadd", ("f32_add", (MAXF ^ NEG, MAXF ^ NEG)), (MAXF ^ NEG, MAXF ^ NEG, 0, 0), rm,
                    (over[rm][1], 0x05)))
    # 4.6.1: an exact subnormal raises nothing, a rounded one UF and NX.
    pdf.append(("fmul", ("f32_mul", (0x00800000, HALF)), (0x00800000, HALF, 0, 0), 0, (0x00400000, 0x00)))
    pdf.append(("fmul", ("f32_mul", (0x00800001, HALF)), (0x00800001, HALF, 0, 0), 0, (0x00400000, 0x03)))
    # 4.6.1: 1/3 NX, 1/0 DZ, 0/0 NV.
    pdf.append(("fdiv", ("f32_div", (ONE, 0)), (ONE, 0, 0, 0), 0, (0x7F800000, 0x08)))
    pdf.append(("fdiv", ("f32_div", (0, 0)), (0, 0, 0, 0), 0, (0x7FC00000, 0x10)))
    # 4.6.2: 7 / -3 under RNE, NX.
    pdf.append(("fdiv", ("f32_div", (0x40E00000, 0xC0400000)), (0x40E00000, 0xC0400000, 0, 0), 0, (None, 0x01)))
    # 4.7.6: fcvt.wu.s of -0.3 under RNE (0, NX) and RDN (0, NV); fcvt.s.w
    # of 2^24 + 1 (2^24, NX).
    pdf.append(("fcvt_wu_s", ("f32_to_ui32", (0xBE99999A,)), (0xBE99999A, 0, 0, 0), 0, (0, 0x01)))
    pdf.append(("fcvt_wu_s", ("f32_to_ui32", (0xBE99999A,)), (0xBE99999A, 0, 0, 0), 2, (0, 0x10)))
    pdf.append(("fcvt_s_w", ("i32_to_f32", (0x01000001,)), (0, 0, 0, 0x01000001), 0, (0x4B800000, 0x01)))
    # 5.3.1: -0 * 5 is -0 (fmul must skip the addend).
    pdf.append(("fmul", ("f32_mul", (0x80000000, 0x40A00000)), (0x80000000, 0x40A00000, 0, 0), 0,
                (0x80000000, 0x00)))
    # 4.4.3: x + (-x) is +0, or -0 rounding down; sqrt(-0) = -0; sqrt(-1) NV.
    for rm in range(5):
        pdf.append(("fadd", ("f32_add", (ONE, ONE ^ NEG)), (ONE, ONE ^ NEG, 0, 0), rm,
                    (0x80000000 if rm == 2 else 0, 0x00)))
    pdf.append(("fsqrt", ("f32_sqrt", (0x80000000,)), (0x80000000, 0, 0, 0), 0, (0x80000000, 0x00)))
    pdf.append(("fsqrt", ("f32_sqrt", (ONE ^ NEG,)), (ONE ^ NEG, 0, 0, 0), 0, (0x7FC00000, 0x10)))
    # 4.7.3: fused zero signs under RDN/RUP. 1*2 - 2 is an exact zero:
    # fmadd(1,2,-2) is -0 under RDN, and fnmadd(1,2,-2) = -(1*2) - (-2) is
    # -0 under RDN too, so fnmadd is not a negated fmadd.
    TWO = 0x40000000
    for rm in (2, 3):
        z = 0x80000000 if rm == 2 else 0
        pdf.append(("fmadd", ("f32_mulAdd", (ONE, TWO, TWO ^ NEG)), (ONE, TWO, TWO ^ NEG, 0), rm, (z, 0x00)))
        pdf.append(("fnmadd", ("f32_mulAdd", (ONE ^ NEG, TWO, TWO)), (ONE, TWO, TWO ^ NEG, 0), rm, (z, 0x00)))
        pdf.append(("fmsub", ("f32_mulAdd", (ONE, TWO, TWO ^ NEG)), (ONE, TWO, TWO, 0), rm, (z, 0x00)))
        pdf.append(("fnmsub", ("f32_mulAdd", (ONE ^ NEG, TWO, TWO)), (ONE, TWO, TWO, 0), rm, (z, 0x00)))
    # 4.7.3: inf * 0 + qNaN raises NV.
    pdf.append(("fmadd", ("f32_mulAdd", (0x7F800000, 0, 0x7FC00000)), (0x7F800000, 0, 0x7FC00000, 0), 0,
                (0x7FC00000, 0x10)))
    pdf.append(("fmadd", ("f32_mulAdd", (0, 0xFF800000, 0x7FC12345)), (0, 0xFF800000, 0x7FC12345, 0), 0,
                (0x7FC00000, 0x10)))

    got = sf_eval(tool, [(fn, rm, ops) for _, (fn, ops), _, rm, _ in pdf])
    lines = []
    for (name, _, (a, b, c, x), rm, stated), (res, fl) in zip(pdf, got):
        want_res, want_fl = stated
        if (want_res is not None and res != want_res) or fl != want_fl:
            sys.exit("PDF example %s rm=%d: SoftFloat gives %08X/%02X, the PDF says %s/%02X"
                     % (name, rm, res, fl, "%08X" % want_res if want_res is not None else "-", want_fl))
        lines.append(line(ROUNDING[name][1](rm), a, b, c, x, res, rm ^ 1, fl))
        # The same vector with dynamic rounding.
        lines.append(line(ROUNDING[name][1](0b111), a, b, c, x, res, rm, fl))
    return lines


# ---------------------------------------------------------------------------
# Special-value cross products: every pair (or, for the fused ops, every
# triple from smaller sets) of these, so that each special-operand rule is
# hit deterministically, not just when the random sample happens to.
# ---------------------------------------------------------------------------
SPECIALS = [0x00000000, 0x80000000, 0x3F800000, 0xBF800000,   # +-0, +-1
            0x00000001, 0x807FFFFF, 0x7F7FFFFF, 0x80800000,   # subnormals, max finite, -min normal
            0x7F800000, 0xFF800000,                           # +-inf
            0x7FC00000, 0xFFC12345, 0x7F800001, 0xFF800001]   # qNaNs, sNaNs
FMA_AB = [0x00000000, 0x80000000, 0x3F800000, 0xBF800000, 0x00000001,
          0x7F7FFFFF, 0x7F800000, 0xFF800000, 0x7FC00000, 0x7F800001]
FMA_C = [0x00000000, 0x80000000, 0x3F800000, 0x7F800000, 0xFF800000, 0x7FC00000, 0x7F800001]


def special(tool, rng):
    sf_cases = []   # (name, rm, dynamic, (a, b, c, x), (fn, ops))
    lines = []
    pairs = [(a, b) for a in SPECIALS for b in SPECIALS]
    for a, b in pairs:
        for name, kind in (("fsgnj", 0), ("fsgnjn", 1), ("fsgnjx", 2)):
            lines.append(line(r_type(0b0010000, RS2, kind), a, b, 0, 0, sgnj(a, b, kind), rng.randrange(8), 0))
        for is_max in (0, 1):
            res, fl = fminmax(a, b, is_max)
            lines.append(line(r_type(0b0010100, RS2, is_max), a, b, 0, 0, res, rng.randrange(8), fl))
        for name, (fn, inst) in COMPARES.items():
            sf_cases.append((inst, None, (a, b, 0, 0), (fn, 0, (a, b))))
        for name in ("fadd", "fsub", "fmul", "fdiv"):
            fn, enc, _ = ROUNDING[name]
            for rm in (0, 2):   # RNE, and RDN for the sign of an exact zero
                sf_cases.append((enc(rm), rm, (a, b, 0, 0), (fn, rm, (a, b))))
    for a in SPECIALS:
        lines.append(line(r_type(0b1110000, 0, 0b001), a, 0, 0, 0, fclass(a), rng.randrange(8), 0))
        lines.append(line(r_type(0b1110000, 0, 0b000), a, 0, 0, 0, a, rng.randrange(8), 0))
        for rm in (0, 2):
            sf_cases.append((ROUNDING["fsqrt"][1](rm), rm, (a, 0, 0, 0), ("f32_sqrt", rm, (a,))))
        for rm in range(5):
            sf_cases.append((ROUNDING["fcvt_w_s"][1](rm), rm, (a, 0, 0, 0), ("f32_to_i32", rm, (a,))))
            sf_cases.append((ROUNDING["fcvt_wu_s"][1](rm), rm, (a, 0, 0, 0), ("f32_to_ui32", rm, (a,))))
    for a in FMA_AB:
        for b in FMA_AB:
            for c in FMA_C:
                for name in ("fmadd", "fmsub", "fnmsub", "fnmadd"):
                    _, enc, mapping = ROUNDING[name]
                    fa, fb, fc, _ = mapping(a, b, c)   # FPU operands whose result is mulAdd(a, b, c)
                    sf_cases.append((enc(0), 0, (fa, fb, fc, 0), ("f32_mulAdd", 0, (a, b, c))))
    got = sf_eval(tool, [spec for _, _, _, spec in sf_cases])
    for (inst, rm, (a, b, c, x), _), (res, fl) in zip(sf_cases, got):
        lines.append(line(inst, a, b, c, x, res, rng.randrange(8), fl))
    return lines


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--testfloat-gen", required=True)
    ap.add_argument("--sf-eval", required=True)
    ap.add_argument("--out", default=os.path.dirname(os.path.abspath(__file__)))
    args = ap.parse_args()
    tg = args.testfloat_gen
    rng = random.Random(SEED)
    files = {}

    # Rounding instructions, every mode. Each testfloat function is streamed
    # once per mode; the four fused variants split the f32_mulAdd cases, so
    # each gets its own.
    for name in ROUNDING:
        files[name] = []
    for fn in dict.fromkeys(v[0] for v in ROUNDING.values()):
        users = [name for name, v in ROUNDING.items() if v[0] == fn]
        for rm, mode in enumerate(MODES):
            cases = sample(tg, fn, mode, PER_MODE * len(users), rng)
            for u, name in enumerate(users):
                _, enc, mapping = ROUNDING[name]
                for k, case in enumerate(cases[u * PER_MODE:(u + 1) * PER_MODE]):
                    *ins, res, fl = case
                    ins += [0] * (3 - len(ins))
                    a, b, c, x = mapping(*ins)
                    if k % 4 == 3:
                        files[name].append(line(enc(0b111), a, b, c, x, res, rm, fl))
                    else:
                        files[name].append(line(enc(rm), a, b, c, x, res, rng.randrange(8), fl))

    for name, (fn, inst) in COMPARES.items():
        files[name] = [line(inst, a, b, 0, 0, res, rng.randrange(8), fl)
                       for a, b, res, fl in sample(tg, fn, "rnear_even", PER_COMPARE, rng)]

    # Operands for the rest, from the f32_add stream.
    pool = [(a, b) for a, b, _, _ in sample(tg, "f32_add", "rnear_even", 6 * PER_OTHER, rng)]
    rng.shuffle(pool)
    chunks = [pool[i * PER_OTHER:(i + 1) * PER_OTHER] for i in range(6)]
    for kind, name in enumerate(["fsgnj", "fsgnjn", "fsgnjx"]):
        inst = r_type(0b0010000, RS2, kind)
        files[name] = [line(inst, a, b, 0, 0, sgnj(a, b, kind), rng.randrange(8), 0)
                       for a, b in chunks[kind]]
    for is_max, name in enumerate(["fmin", "fmax"]):
        inst = r_type(0b0010100, RS2, is_max)
        files[name] = []
        for a, b in chunks[3 + is_max]:
            res, fl = fminmax(a, b, is_max)
            files[name].append(line(inst, a, b, 0, 0, res, rng.randrange(8), fl))
    files["fclass"] = [line(r_type(0b1110000, 0, 0b001), a, 0, 0, 0, fclass(a), rng.randrange(8), 0)
                       for a, _ in chunks[5]]
    files["fmv_x_w"] = [line(r_type(0b1110000, 0, 0b000), b, 0, 0, 0, b, rng.randrange(8), 0)
                        for _, b in chunks[5]]
    files["fmv_w_x"] = [line(r_type(0b1111000, 0, 0b000), 0, 0, 0, a, a, rng.randrange(8), 0)
                        for a, _ in chunks[4]]

    files["directed"] = directed(args.sf_eval)
    files["special"] = special(args.sf_eval, rng)

    total = 0
    for name, lines_ in files.items():
        with open(os.path.join(args.out, name + ".hex"), "w", newline="\n") as f:
            f.write("\n".join(lines_) + "\n")
        total += len(lines_)
        print("%-10s %6d vectors" % (name, len(lines_)))
    print("total      %6d vectors" % total)


if __name__ == "__main__":
    main()
