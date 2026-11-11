#!/usr/bin/env python3
"""Bowen's regression: integer-oracle rounder tests and existing TestFloat TB.

No third-party Python packages. Requires iverilog/vvp (or explicit paths).
Preserves the full FPU log, including the unfinished divide/sqrt failures.
"""
import argparse
from pathlib import Path
import random
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build"
OUT = BUILD / "fpu_math"
MATH_OPS = {
    "fadd.s", "fsub.s", "fmul.s", "fmadd.s", "fmsub.s", "fnmsub.s",
    "fnmadd.s", "fcvt.w.s", "fcvt.wu.s", "fcvt.s.w", "fcvt.s.wu",
}
TOP_OPS = {
    "feq.s", "flt.s", "fle.s", "fsgnj.s", "fsgnjn.s", "fsgnjx.s",
    "fmin.s", "fmax.s", "fclass.s", "fmv.x.w", "fmv.w.x",
    "CSR instructions", "hold/commit protocol", "rm trap, i_valid low",
    "fcsr sequence",
}
DIV_OPS = {"fdiv.s", "fsqrt.s", "PDF 4.6.2 fcsr breakdown", "back-to-back fdiv/fsqrt"}


def quantize(n, shift, sign, mode):
    """Round a positive exact integer divided by 2**shift."""
    if shift <= 0:
        return n << -shift, False
    q, r = divmod(n, 1 << shift)
    midpoint = 1 << (shift - 1)
    inc = ((mode == 0 and (r > midpoint or (r == midpoint and q % 2)))
           or (mode == 2 and sign and r != 0)
           or (mode == 3 and not sign and r != 0)
           or (mode == 4 and r >= midpoint))
    return q + int(inc), r != 0


def reference(sign, exp, sig, mode):
    # Interpret the input as an exact rational sig * 2**(exp-152).
    # This uses integer division at the target precision, independently of
    # the RTL's barrel stages, jam bits, increment circuit and packing.
    if sig == 0:
        return sign << 31, 0
    leading = sig.bit_length() - 1
    unbiased = leading + exp - 152
    full, _ = quantize(sig, leading - 23, sign, mode)
    rounded_exp = unbiased + int(full == 1 << 24)
    if rounded_exp > 127:
        infinity = mode in (0, 4) or (mode == 2 and sign) or (mode == 3 and not sign)
        return (sign << 31) | (0x7F800000 if infinity else 0x7F7FFFFF), 5
    if unbiased >= -126:
        fraction = (full >> 1) if full == 1 << 24 else full
        result = ((rounded_exp + 127) << 23) | (fraction & 0x7FFFFF)
        _, lost = quantize(sig, leading - 23, sign, mode)
    else:
        result, lost = quantize(sig, 3 - exp, sign, mode)
    flags = int(lost) | (2 if rounded_exp < -126 and lost else 0)
    return (sign << 31) | result, flags


def generate_round_vectors(path):
    rng = random.Random(4768)
    exponents = [-171, -31, -25, -24, -23, -22, -1, 0, 1, 2, 127, 253, 254, 255, 382]
    significands = [0, 0x2000000, 0x2000001, 0x2000002, 0x2000003,
                    0x2000004, 0x2000006, 0x3FFFFF9, 0x3FFFFFC,
                    0x3FFFFFD, 0x3FFFFFE, 0x3FFFFFF]
    cases = [(s, e, n, m) for s in range(2) for e in exponents
             for n in significands for m in range(5)]
    cases += [(rng.randrange(2), rng.randint(-171, 382),
               rng.randrange(1 << 25, 1 << 26), rng.randrange(5))
              for _ in range(20000)]
    with path.open("w", encoding="ascii") as f:
        for s, e, n, m in cases:
            result, flags = reference(s, e, n, m)
            f.write(f"{s:X} {e & 1023:03X} {n:07X} {m:X} {result:08X} {flags:02X}\n")
    return len(cases)


def simulate(iverilog, vvp, top, extra=()):
    sources = sorted(p for p in ROOT.glob("*.v") if not p.name.endswith("_tb.v"))
    sim = OUT / top
    subprocess.run([iverilog, "-g2005", "-s", top, "-o", str(sim),
                    str(ROOT / (top + ".v")), *map(str, sources)], check=True, cwd=ROOT)
    log = OUT / (top + ".log")
    with log.open("w", encoding="utf-8") as f:
        subprocess.run([vvp, "-n", str(sim), *extra], cwd=BUILD,
                       stdout=f, stderr=subprocess.STDOUT, check=True, timeout=300)
    return log.read_text(encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iverilog", default=shutil.which("iverilog"))
    parser.add_argument("--vvp", default=shutil.which("vvp"))
    parser.add_argument("--round-only", action="store_true")
    args = parser.parse_args()
    if not args.iverilog or not args.vvp:
        parser.error("install Icarus Verilog or supply --iverilog and --vvp")
    # The simulator runs from build/ so the existing testbench finds its
    # vectors. Resolve explicit relative executable paths before that move.
    args.iverilog = shutil.which(args.iverilog) or str(Path(args.iverilog).resolve())
    args.vvp = shutil.which(args.vvp) or str(Path(args.vvp).resolve())
    OUT.mkdir(parents=True, exist_ok=True)
    vectors = OUT / "round.hex"
    count = generate_round_vectors(vectors)
    log = simulate(args.iverilog, args.vvp, "fpu_round_tb", ["+vectors=" + str(vectors)])
    if "ALL TESTS PASSED" not in log:
        raise RuntimeError(log)
    print(f"PASS rounder: {count} integer-oracle vectors + 150 directed checks", flush=True)
    if args.round_only:
        return
    log = simulate(args.iverilog, args.vvp, "fpu_tb")
    rows = {}
    for name, passed, failed in re.findall(r"^\s+(.+?)\s+(\d+) passed\s+(\d+) failed", log, re.M):
        if name in MATH_OPS | TOP_OPS | DIV_OPS:
            rows[name] = (int(passed), int(failed))
    required = MATH_OPS | TOP_OPS | DIV_OPS
    if set(rows) != required or "34824 vectors" not in log:
        raise RuntimeError(f"incomplete FPU regression; see {OUT / 'fpu_tb.log'}")
    failures = {name: rows[name][1] for name in MATH_OPS | TOP_OPS if rows[name][1]}
    if failures:
        raise RuntimeError(f"FPU math/top failures: {failures}; see {OUT / 'fpu_tb.log'}")
    print(f"PASS FPU math: {sum(rows[n][0] for n in MATH_OPS)} TestFloat/directed checks, all 11 operations")
    print(f"PASS FPU top/CSR/protocol: {sum(rows[n][0] for n in TOP_OPS)} checks")
    div_fail = sum(rows[n][1] for n in DIV_OPS)
    if div_fail:
        print(f"PENDING divide/sqrt: {div_fail} failures outside Bowen's scope (retained in full log)")
    print(f"Logs: {OUT}")


if __name__ == "__main__":
    main()
