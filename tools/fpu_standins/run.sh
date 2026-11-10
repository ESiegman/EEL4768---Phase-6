#!/usr/bin/env bash
set -uo pipefail

# Runs fpu_tb.v with the fake FPU submodules in this folder bound to fpu.v's
# tie-off nets (+define+FPU_STANDINS), so the busy/hold/commit protocol of
# fpu.v is exercised before the real submodules exist. See README.md.
#
# usage: tools/fpu_standins/run.sh [iverilog -P/-D flags...]
#   e.g. tools/fpu_standins/run.sh -Pfpu_tb.s_ds.LAT=30 -Pfpu_tb.s_fma.LAT=0

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TOOL_DIR}/../.." && pwd)"
OUT_DIR="${REPO_DIR}/build/fpu_standins"
mkdir -p "${OUT_DIR}"

# Every root design file except a real submodule a stand-in replaces (they
# share module names). Once a real one is on main and instantiated in fpu.v,
# this flow is no longer needed for it.
SOURCES=()
while IFS= read -r f; do
    name="$(basename "${f}" .v)"
    if [[ -f "${TOOL_DIR}/${name}.v" ]]; then continue; fi
    SOURCES+=("${f}")
done < <(find "${REPO_DIR}" -maxdepth 1 -name '*.v' ! -name '*_tb.v' | sort)

SIM="${OUT_DIR}/sim"
rm -f "${SIM}"
if ! iverilog -g2005 -DFPU_STANDINS -s fpu_tb -o "${SIM}" "$@" \
        "${REPO_DIR}/fpu_tb.v" "${SOURCES[@]}" "${TOOL_DIR}"/fpu_*.v; then
    echo "FAIL: compile error" >&2
    exit 1
fi
# From build/, like run_test.sh, so fpu_tb.v finds ../tools/fpu_vectors.
( cd "${REPO_DIR}/build" && vvp -n "${SIM}" ) | grep -v '\$finish called' > "${OUT_DIR}/sim.log"
# The arithmetic group fails on purpose (fake math); the top group and the
# protocol must pass.
sed -n '/^fpu_tb: /,$p' "${OUT_DIR}/sim.log"
if awk '/^== top/{t=1} /^== arith/{t=0} t && /group total/ && $5 != 0 {bad=1} END{exit !bad}' "${OUT_DIR}/sim.log"; then
    echo "FAIL: the top / CSR / non-rounding group has failures (see ${OUT_DIR}/sim.log)"
    exit 1
fi
echo "PASS: top / CSR / non-rounding group and protocol (arithmetic values are fake here)"
