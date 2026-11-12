# Bowen's FPU math regression

From the repo root, with Python 3 and Icarus Verilog on PATH:

```sh
python3 tools/fpu_math/run.py
```

On Windows use `python` in place of `python3`. Portable simulator paths can
be supplied with `--iverilog <path-to-iverilog> --vvp <path-to-vvp>`.
No Python packages are required. `--round-only` runs just the rounder checks.

The script runs:

- `fpu_round_tb.v`: 150 directed boundary checks plus 21,800 deterministic
  vectors from an independent exact-integer reference. Covers all five
  rounding modes, both signs, ties, sticky-only tails, exact and inexact
  subnormals, very tiny values, tininess after precision rounding with an
  unbounded exponent, and overflow with and without a rounding carry.
- The existing, unchanged `fpu_tb.v`: all 34,824 Berkeley TestFloat,
  SoftFloat and directed vectors, including dynamic rounding modes and
  hold/commit/flag behavior. All eleven FMA/conversion operations and every
  top/CSR/protocol row must pass. Missing rows or an incomplete simulation
  fail the script.

The full log is kept in `build/fpu_math/fpu_tb.log`. All FPU rows, including
divide/sqrt and its hold/commit sequences, must pass. `make test` also runs
the full CPU suite and the direct rounder testbench.

Implementation notes:

- `fpu_fma` is combinational (`o_busy = 0`). Its unrolled shift/add
  multiplier retains all 48 product bits; the 77-bit alignment/add path
  keeps cancellation bits and uses constant-stage barrel shifters.
- `fpu_round` is the single rounding/packing stage shared with conversion
  and divide/sqrt. No finite subnormal is flushed.
- `fpu_cvt` rounds finite float-to-integer values before clipping and emits
  NV without NX for invalid conversions. Integer-to-float feeds the shared
  rounder, including unsigned values and signed INT_MIN.
- `fpu.v` instantiates all three and fixes quiet-NaN multiplicands being
  mistaken for an infinite product during fused special-case checks.

The implementation uses no signal multiplication/division/modulo, variable
shifts, procedural loops, or combinational `if` statements. Check the FPU
design in isolation with:

```sh
ece552 validate -w fpu.v fpu_fma.v fpu_cvt.v fpu_round.v fpu_divsqrt.v
```

Validated results for this implementation: 21,950 rounder checks, 21,778
FPU arithmetic/conversion checks and 117,706 top/CSR/protocol checks pass.
After the divider integration, the full FPU suite passes all 143,146
checks. All 17 CI testbenches and whole-design `ece552 validate -w` pass.
The hart also passes Yosys `hierarchy -check; proc; opt; check -assert`.
