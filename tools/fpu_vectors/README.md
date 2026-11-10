# fpu_vectors

Golden vectors for `fpu_tb.v`. Nothing here is part of the submission.

## Where the values come from

| Source | Instructions |
|---|---|
| Berkeley TestFloat `testfloat_gen` | fadd, fsub, fmul, fdiv, fsqrt, the four fused ops, fcvt.w[u].s, fcvt.s.w[u], feq/flt/fle |
| SoftFloat, through `sf_eval.c` | the phase_6.pdf worked examples (`directed.hex`) and the special-value cross products (`special.hex`) |
| the small Python reference in `gen_vectors.py` | fsgnj/fsgnjn/fsgnjx, fmin/fmax, fclass, fmv.x.w, fmv.w.x (TestFloat has none of them) |

Details:
- Both tools are built with `SPECIALIZE_TYPE=RISCV`, so a NaN result is
  `0x7FC00000` and out-of-range conversions saturate the RISC-V way.
- `testfloat_gen` runs with `-tininessafter`, every rounding mode, and
  `-exact` for the conversions to integer. `feq` is `f32_eq` (quiet), and
  `flt`/`fle` are `f32_lt`/`f32_le` (signaling).
- The fused variants come from `f32_mulAdd` with negated inputs, which is
  exact: `fmsub(a,b,-c) = fnmsub(-a,b,c) = fnmadd(-a,b,-c) = a*b+c`.
- `testfloat_gen` won't make fewer cases than its minimum (46464 for two
  operands, 6133248 for `f32_mulAdd`), so each stream is subsampled with a
  fixed seed.
- The directed vectors are checked against the values the PDF states, and
  generation stops if one disagrees.

## Format

One vector per line, all hex:

```
inst frs1 frs2 frs3 xrs1 result ctrl
```

- `ctrl[7:5]` is the `frm` that `fpu_tb.v` writes (with fflags = 0, through
  `csrrw fcsr`) before the vector.
- `ctrl[4:0]` is the expected flags, NV DZ OF UF NX. That's also SoftFloat's
  flag order.
- `result` is `o_fp_result` or `o_int_result`, whichever the instruction
  writes.
- A quarter of each rounding instruction's random vectors use `rm = 111`
  with `frm` set to the mode. The rest use a static rm with a random `frm`,
  reserved values included, which must not matter.

| File | Vectors |
|---|---|
| each rounding instruction (13 files) | 1600: 320 per rounding mode, 80 of them dynamic |
| `feq`, `flt`, `fle` | 1000 each |
| `fsgnj*`, `fmin`, `fmax`, `fclass`, `fmv_x_w`, `fmv_w_x` | 600 each |
| `directed.hex` | 92: the PDF examples, each one static and dynamic |
| `special.hex` | 6132: every pair of 14 special values, plus fused triples |
| total | 34824 (about 2 MB) |

## Regenerating

Build the tools outside the repo, then run the generator from the repo
root. The output is byte-identical every time. These versions were used:
SoftFloat `07ebd29` and TestFloat `a9c849f`. The `Linux-x86_64-GCC` makefiles
are plain C and also work on macOS arm64.

```sh
git clone https://github.com/ucb-bar/berkeley-softfloat-3.git ~/tf/berkeley-softfloat-3
git clone https://github.com/ucb-bar/berkeley-testfloat-3.git ~/tf/berkeley-testfloat-3
make -C ~/tf/berkeley-softfloat-3/build/Linux-x86_64-GCC SPECIALIZE_TYPE=RISCV
make -C ~/tf/berkeley-testfloat-3/build/Linux-x86_64-GCC SPECIALIZE_TYPE=RISCV \
     SOFTFLOAT_DIR=$HOME/tf/berkeley-softfloat-3 testfloat_gen
cc -O2 -I ~/tf/berkeley-softfloat-3/source/include -I ~/tf/berkeley-softfloat-3/build/Linux-x86_64-GCC \
   -o ~/tf/sf_eval tools/fpu_vectors/sf_eval.c ~/tf/berkeley-softfloat-3/build/Linux-x86_64-GCC/softfloat.a
python3 tools/fpu_vectors/gen_vectors.py \
   --testfloat-gen ~/tf/berkeley-testfloat-3/build/Linux-x86_64-GCC/testfloat_gen --sf-eval ~/tf/sf_eval
```

Sanity checks for a fresh build (`printf '...' | ~/tf/sf_eval`):

| Input | Expected output |
|---|---|
| `f32_add 0 7F800001 3F800000` | `7FC00000 10` (sNaN: canonical NaN, NV) |
| `f32_to_i32 0 7FC00000` | `7FFFFFFF 10` |
| `f32_to_ui32 0 FF800000` | `00000000 10` |
