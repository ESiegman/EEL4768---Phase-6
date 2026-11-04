# hart_diff

A differential test for `hart.v`. It runs a program on the hart and on a
Python instruction-set model (`iss.py`), then diffs the two retire streams one
instruction at a time. Every retire port is compared:

- pc, next pc and trap
- integer and FP source registers and their values
- rd and frd writes
- fflags
- load and store address, mask and data

When something goes wrong, you get the first instruction that differs instead
of a wrong word somewhere in a register dump.

Nothing here is part of the submission. `run_test.sh`, lint and the
schematics only look at `.v` files in the repo root, so they never see this
folder.

## Stand-ins

The hart can run before the real decoder, ALU and FPU are done. Each one can
be replaced by a test-only stand-in with the phase 6 ports. The stand-ins use
`*`, `/`, `%` and `if`, so they are not synthesizable.

| File | What it does |
|---|---|
| `standin_decoder.v` | Wraps the phase 5 decoder (`rv32i_decoder.v`). It adds M, `flw`/`fsw`, OP-FP, the fused instructions and CSR decoding with the legality rules from phase_6.pdf 5.4.1, plus `o_uses_rs1`/`o_uses_rs2`. |
| `standin_alu.v` | Wraps the phase 5 ALU (`rv32i_alu.v`). RV32M is real, including the divide-by-zero and overflow results. Multiply takes `MUL_LAT` cycles and divide takes `DIV_LAT` cycles (0 means combinational). |
| `standin_fpu.v` | **Fake math, real rules.** Every FP result is deterministic nonsense chosen so that a swapped or stale operand changes the answer. The fcsr behavior is real: flags accrue and commit only on `i_advance`, the six CSR instructions read, set and clear, and the dynamic-rm trap fires. `fdiv`/`fsqrt` take `FDIV_LAT` cycles. |

`iss.py` implements the same fake FP math, so the retire streams only match
when the hart's plumbing is right: hazards, forwarding, stalls, freezes,
traps and retire ports.

## Running

From the repo root:

```
tools/hart_diff/run.sh                      # phase 6 trace, graded cache config
tools/hart_diff/run.sh --directed           # traps + back-to-back hazards (directed.py)
tools/hart_diff/run.sh -Ptb.BYPASS_EN=0     # any hart_diff_tb.v parameter
tools/hart_diff/run.sh -DFDIV_LAT=0 -DMUL_LAT=32 -DDIV_LAT=1
tools/hart_diff/run.sh --real decoder --real alu   # swap in the real modules
tools/hart_diff/run.sh --real fpu           # no diff; golden sections only
```

These are the `hart_diff_tb.v` parameters:

| Parameter | Default |
|---|---|
| `LATENCY` | 4 |
| `EVICT_POLICY` | 1 (PLRU) |
| `NUM_WAYS` | 4 |
| `CACHE_SIZE` | 2 (KB) |
| `BLOCK_SIZE` | 16 |
| `PREFETCH_EN` | 1 |
| `BYPASS_EN` | 1 |
| `FWD_EN` | 1 |

The run also compares main data memory with `traces/random_dmem.hex` for each
section in phase_6.pdf 6.1. With the stand-in FPU, only `muldiv` should match
(0 words differ). Once the real FPU is in, use `--real fpu` and watch every
section go to 0. The run also fails if the D-cache sees a request while a
multi-cycle operation holds EX.

Output goes to `build/hart_diff/`: `hart.trace`, `iss.trace` and `sim.log`.

## The decoder contract

The stand-in decoder, and therefore the hart, expects the skeleton ports plus
two extra outputs:

- `o_uses_rs1`: the instruction reads integer rs1. This includes `flw`, `fsw`,
  `fmv.w.x`, `fcvt.s.w[u]` and the register forms of the CSR instructions.
  It is low when rs1 is an FP register.
- `o_uses_rs2`: the instruction reads integer rs2. It is low for `fsw`, whose
  rs2 is an FP register.

There are no other extra outputs. `ece552 validate -w` rejects an
unconnected port.
