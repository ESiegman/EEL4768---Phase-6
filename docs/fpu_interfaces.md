# FPU submodule interfaces (proposal)

Status: **proposal, needs Bowen's and Bradly's OK.** Nothing here is final
until both of you agree. If you want a change, say so before you write the
ports, and I'll update `fpu.v` to match.

`fpu.v` (shadyyr) is the top. It instantiates three modules from Bowen and
one from Bradly. Each one goes in its own file at the repo root, and the file
is named after the module:

| File / module | Owner | What it does | Timing |
|---|---|---|---|
| `fpu_round.v` / `fpu_round` | Bowen | The one shared rounder | combinational |
| `fpu_fma.v` / `fpu_fma` | Bowen | a*b+c for fadd, fsub, fmul and the 4 fused ops | combinational or multi-cycle |
| `fpu_cvt.v` / `fpu_cvt` | Bowen | fcvt.w[u].s (complete) and fcvt.s.w[u] (unrounded) | combinational |
| `fpu_divsqrt.v` / `fpu_divsqrt` | Bradly | fdiv.s and fsqrt.s significands (restoring) | multi-cycle |

`tools/fpu_standins/` has a fake-math stand-in for each module with exactly
these ports. The real modules must lint clean with `ece552 validate -w`,
just like every other root `.v` file.

## What the top does, so you don't have to

- **Decoding.** Each unit gets only the controls it needs, already decoded.
- **Effective rounding mode.** `i_rm` is always 0-4 (RNE, RTZ, RDN, RUP,
  RMM). The top resolves `rm = 111` to `frm`. An instruction that would trap
  on a reserved `frm` never reaches a unit.
- **Operand signs.** The top flips signs before the unit sees them, so the
  FMA always computes `(+/-a) * (+/-b) + (+/-c)` as given:

  | Instruction | a | b | c | `i_mul_only` |
  |---|---|---|---|---|
  | fadd.s | fs1 | +1.0 | fs2 | 0 |
  | fsub.s | fs1 | +1.0 | -fs2 | 0 |
  | fmul.s | fs1 | fs2 | (ignored) | 1 |
  | fmadd.s | fs1 | fs2 | fs3 | 0 |
  | fmsub.s | fs1 | fs2 | -fs3 | 0 |
  | fnmsub.s | -fs1 | fs2 | fs3 | 0 |
  | fnmadd.s | -fs1 | fs2 | -fs3 | 0 |

  With `i_mul_only = 1` the FMA returns the product alone, without adding
  any zero. PDF 5.3.1: `-0 * 5` must stay `-0`, but `-0 * 5 + 0` would be
  `+0`.
- **Special operands.** The top handles every NaN and infinity case, plus
  the zero cases of divide and square root, and doesn't start the unit for
  them. A unit only ever sees:

  | Unit | Operands it can get |
  |---|---|
  | `fpu_fma` | finite: zero, subnormal or normal |
  | `fpu_divsqrt`, fdiv | finite and nonzero |
  | `fpu_divsqrt`, fsqrt | finite, nonzero and positive |
  | `fpu_cvt`, fcvt.w[u].s | finite |
  | `fpu_cvt`, fcvt.s.w[u] | any 32-bit integer |

  The top's special-case table (all results exact, so no rounding):

  | Op | Case | Result | Flags |
  |---|---|---|---|
  | all arithmetic | any NaN operand | 0x7FC00000 | NV if any sNaN |
  | fused | inf * 0 (even when fs3 is a qNaN) | 0x7FC00000 | NV |
  | fadd/fsub/fused | inf - inf (after sign flips) | 0x7FC00000 | NV |
  | fadd/fsub/fused | one or both infinite, same sign | that infinity | none |
  | fmul | inf * 0 | 0x7FC00000 | NV |
  | fmul | inf * nonzero | inf, sign a^b | none |
  | fdiv | 0/0, inf/inf | 0x7FC00000 | NV |
  | fdiv | inf/finite | inf, sign a^b | none |
  | fdiv | finite/inf, 0/nonzero | zero, sign a^b | none |
  | fdiv | nonzero finite/0 | inf, sign a^b | DZ |
  | fsqrt | +-0 | same zero | none |
  | fsqrt | negative nonzero (incl. -inf) | 0x7FC00000 | NV |
  | fsqrt | +inf | +inf | none |
  | fcvt.w.s | NaN, +inf | 0x7FFFFFFF | NV |
  | fcvt.w.s | -inf | 0x80000000 | NV |
  | fcvt.wu.s | NaN, +inf | 0xFFFFFFFF | NV |
  | fcvt.wu.s | -inf | 0x00000000 | NV |

  NaN checks go first, except that fused `inf * 0` is NV even if fs3 is a
  quiet NaN.

## Shared formats

### Unpacked operand (top to units)

```
sign       1 bit
exp [9:0]  signed, biased: value = (-1)^sign * (sig / 2^23) * 2^(exp - 127)
sig [23:0] sig[23] = 1 (normalized), or sig = 0 for a zero
```

Subnormals arrive **already normalized**. The top's unpack first gives a
subnormal exponent 1 and hidden bit 0 (PDF 5.3.1), then shifts out its
leading zeros and lowers `exp` to match. So `exp` can be as low as -22. For a
normal number this is just `{1, fraction}` with the stored exponent.

### Unrounded result (units to the rounder)

```
sign       1 bit
exp [9:0]  signed, biased exponent of sig[25]: value = (-1)^sign * (sig / 2^25) * 2^(exp - 127)
sig [25:0] sig[25] = leading 1 (must be normalized unless the value is zero)
           sig[24:2] = the 23 fraction bits
           sig[1]    = guard bit
           sig[0]    = sticky (OR of every bit below the guard, including a nonzero remainder)
```

- An exact zero is `sig == 0`. The producer sets its sign: for the FMA, that's
  the IEEE rule (`x + (-x)` is `+0`, or `-0` under RDN; `-0 + -0` is `-0`;
  fmul's zero product is `a^b`). The rounder returns +-0 with no flags.
- `exp` may be <= 0 (tiny result) or >= 255 (overflow). The rounder handles
  both. Ten signed bits cover every case: an FMA product of normalized
  subnormals is about -170 at worst, and the largest is about 400.
- An exact operand fits as is: `{sig, 2'b00}` with the same `exp`.

## Ports

### `fpu_round` (Bowen)

```verilog
module fpu_round (
    input  wire        i_sign,
    input  wire [ 9:0] i_exp,    // signed, see "Unrounded result"
    input  wire [25:0] i_sig,
    input  wire [ 2:0] i_rm,     // 0-4
    output wire [31:0] o_result,
    output wire [ 4:0] o_flags   // {NV=0, DZ=0, OF, UF, NX}
);
```

What it does: it denormalizes when `exp < 1`, shifting right and ORing
everything shifted out into sticky. It rounds in all 5 modes, and produces
overflow results per mode (PDF 4.5.3). Subnormals stay exact, never flushed.
UF means tiny **after rounding** (with an unbounded exponent range) **and**
inexact. OF always comes with NX. 26 bits are enough to decide
tininess-after-rounding: round at bit 2 as if the exponent were unbounded,
then check whether that carried out to 2^-126.

### `fpu_fma` (Bowen)

```verilog
module fpu_fma (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_valid,     // handshake, see below
    input  wire        i_advance,
    input  wire        i_mul_only,  // fmul: return a*b, ignore c
    input  wire [ 2:0] i_rm,        // only for the sign of an exact zero sum
    input  wire        i_a_sign,
    input  wire [ 9:0] i_a_exp,
    input  wire [23:0] i_a_sig,
    input  wire        i_b_sign,
    input  wire [ 9:0] i_b_exp,
    input  wire [23:0] i_b_sig,
    input  wire        i_c_sign,
    input  wire [ 9:0] i_c_exp,
    input  wire [23:0] i_c_sig,
    output wire        o_busy,
    output wire        o_sign,
    output wire [ 9:0] o_exp,
    output wire [25:0] o_sig
);
```

The handshake ports are there even if the FMA is combinational. A
combinational FMA ties `o_busy` to 0 and ignores `i_clk`, `i_rst` and
`i_advance` (lint doesn't mind unused inputs). It needs **one** rounding at
the end, so keep everything below the guard bit as sticky. Massive
cancellation needs a leading-zero count over the whole sum.

### `fpu_cvt` (Bowen)

```verilog
module fpu_cvt (
    input  wire        i_unsigned,      // inst[20]: .wu / .s.wu
    input  wire [ 2:0] i_rm,
    // fcvt.w[u].s: fs1 is finite (the top handles NaN and inf)
    input  wire        i_a_sign,
    input  wire [ 9:0] i_a_exp,
    input  wire [23:0] i_a_sig,
    output wire [31:0] o_f2i_result,
    output wire [ 4:0] o_f2i_flags,     // {NV, 0, 0, 0, NX}, never NV and NX together
    // fcvt.s.w[u]: xrs1, to the shared rounder
    input  wire [31:0] i_int,
    output wire        o_i2f_sign,
    output wire [ 9:0] o_i2f_exp,
    output wire [25:0] o_i2f_sig
);
```

fcvt.w[u].s rounds to an integer in `i_rm`, then range-checks (PDF 4.7.6).
Out of range gives the clipped value and NV, with no NX. For example,
fcvt.wu.s of -0.3 is 0 with NX under RNE, but 0 with NV under RDN. fcvt.s.w
of 0 is `sig = 0, sign = 0` (+0).

### `fpu_divsqrt` (Bradly)

```verilog
module fpu_divsqrt (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_valid,     // handshake, see below
    input  wire        i_advance,
    input  wire        i_sqrt,      // 1: sqrt(a), 0: a / b
    input  wire        i_a_sign,
    input  wire [ 9:0] i_a_exp,
    input  wire [23:0] i_a_sig,
    input  wire        i_b_sign,    // unused for sqrt
    input  wire [ 9:0] i_b_exp,
    input  wire [23:0] i_b_sig,
    output wire        o_busy,
    output wire        o_sign,
    output wire [ 9:0] o_exp,
    output wire [25:0] o_sig
);
```

Both significands arrive normalized, so the quotient's leading 1 is at most
one place off. About 26 steps give 24 bits plus a guard bit, and a nonzero
remainder sets sticky (PDF 5.3.2). For sqrt, make the exponent even first
(shift the significand when `exp - 127` is odd), then halve it with a
literal shift (`>>> 1` on a signed value). `/` on a signal fails lint.

## Multi-cycle handshake (same contract as the ALU, PDF 5.1)

This applies to `fpu_divsqrt` and to `fpu_fma` if it's iterative.

1. `i_valid` is high while this unit's instruction is in EX and should run.
   The top already ANDs in the op select, `~o_rm_trap` and "not a special
   operand", so a unit never sees an instruction it shouldn't start.
2. While `i_valid` is high, the operands and controls don't change until
   the edge where `i_advance` is high (the hart holds EX).
3. `o_busy` is high from the **first** cycle `i_valid` is high (before any
   clock edge) until the result is ready. Usually that's
   `assign o_busy = i_valid & ~done;`.
4. **`o_busy` must not depend on `i_advance`, even indirectly.** The hart
   computes `i_advance = ~(freeze | ex_stall)`, and `ex_stall` includes
   `o_busy`, so that path would be a combinational loop.
5. `o_busy` is low whenever `i_valid` is low.
6. Once done, the outputs stay stable until `i_advance`. A cache miss can
   hold the instruction in EX for many cycles after the result is ready.
7. Never restart while held: `i_valid` high, `i_advance` low and done means
   stay done.
8. On every clock edge where `i_advance` is high, clear the state (counter,
   done). The next cycle can hold a new op that starts fresh, back to back.
9. Synchronous reset clears the state too.

The outputs are don't-care while `o_busy` is high. The top ORs the busy
signals into its own `o_busy` and only commits fcsr on the `i_advance` edge.

## Flags

- `fpu_round` returns OF, UF and NX.
- `fpu_cvt` returns NV and NX for fcvt.w[u].s.
- `fpu_fma` and `fpu_divsqrt` return **no** flags. Everything they can raise
  for finite operands (OF, UF, NX) comes from the rounder, and the top
  raises NV and DZ for the special operands.
- The top's per-instruction flags are the special-case flags if a special
  case applied, otherwise the unit's or rounder's flags. They're ORed into
  `fflags` on the `i_advance` edge, and only then.

## Where the rounder lives

One instance, in `fpu.v`. Its input is muxed by instruction:

- FMA output: fadd, fsub, fmul, fused
- `fpu_divsqrt` output: fdiv, fsqrt
- `fpu_cvt` int-to-float output: fcvt.s.w[u]

Only one FP instruction is in EX at a time, and every unit holds its output
until `i_advance`, so one rounder is enough. fcvt.w[u].s rounds to an integer
inside `fpu_cvt`, since integer rounding happens at the binary point, not
at bit 23.

## Until a unit lands

`fpu.v` must compile and lint against whatever is on main, so it
instantiates a unit only once that unit's file is at the repo root. Until
then:

- the unit's outputs are tied to 0
- its instructions return 0 with no flags
- special operands still work, since they're handled in the top

`fpu.v` has one `MISSING UNIT` comment per unit. Each comment holds the
instance, ready to uncomment, and names the tie-offs to delete.

## Testing

`fpu_tb.v` drives the whole FPU with Berkeley TestFloat vectors (RISC-V
specialization, tininess after rounding, all 5 modes). It also uses `rm = 111`
with `frm` set through a CSR instruction for part of the vectors. The vectors
and how to regenerate them are in `tools/fpu_vectors/`. The arithmetic group
fails until your modules are on main, and should pass once they are. To try
your module before you push, put it at the repo root and uncomment its
instance in `fpu.v`, then run `make test`.
