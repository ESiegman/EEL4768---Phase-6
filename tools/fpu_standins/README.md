# fpu_standins

Fake versions of the FPU submodules proposed in `docs/fpu_interfaces.md`:
`fpu_fma`, `fpu_divsqrt`, `fpu_cvt` and `fpu_round`. Each one has exactly the
proposed ports, so it also works as an executable copy of the interface. The
math is deterministic nonsense. What's real is the busy, latency, hold and
restart behavior of the multi-cycle handshake. They use `integer`, `+`, `>=`
and `if` freely and are not synthesizable. Nothing here is part of the
submission.

## Why

`fpu.v` has to compile and lint against main, so it can't instantiate a
module that isn't there yet. Until then, each missing unit's outputs are
tie-off nets in `fpu.v`.

`run.sh` compiles `fpu_tb.v` with `+define+FPU_STANDINS`. That instantiates
these stand-ins in the testbench and `force`s `fpu.v`'s tie-off nets to their
outputs. So the committed `fpu.v` is what gets tested, including its busy
combine, its gating of trapped and special-operand instructions, and how it
holds results and commits fcsr around a multi-cycle operation.

```
tools/fpu_standins/run.sh                                  # fma 3 cycles, div/sqrt 12
tools/fpu_standins/run.sh -Pfpu_tb.s_ds.LAT=30 -Pfpu_tb.s_fma.LAT=0
```

The arithmetic group fails here on purpose, because the values are fake. The
script passes when the "top / CSR / non-rounding" group, including the
hold/commit protocol of every instruction, has no failures.

Once a real submodule is on main and instantiated in `fpu.v`, `make test`
covers it and this flow is no longer needed for it. A stand-in shares its
module name with the real file, so `run.sh` leaves a real root file out of
the build and uses the stand-in instead.
