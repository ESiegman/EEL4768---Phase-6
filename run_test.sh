#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 <name> [submission_dir]" >&2
    exit 1
fi
SUMMARY_FILE="${SCRIPT_DIR}/results/$1.txt"
SUBMISSION_ARG="${2:-${SCRIPT_DIR}}"

if [[ ! -d "${SUBMISSION_ARG}" ]]; then
    echo "ERROR: submission directory not found: ${SUBMISSION_ARG}" >&2
    exit 1
fi
SUBMISSION_DIR="$(cd "${SUBMISSION_ARG}" && pwd)"
echo "Submission under test: ${SUBMISSION_DIR}"

BUILD_DIR="${SCRIPT_DIR}/build"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${SCRIPT_DIR}/results"
: > "${SUMMARY_FILE}"

if ! command -v iverilog >/dev/null 2>&1; then
    echo "ERROR: iverilog not found on PATH. See README.md for install instructions." >&2
    exit 1
fi

# The phase-6 checks. Each is graded by its own <name>_tb.v, which you write
# yourself -- see README.md and example/opmux_tb.v. rf is checked twice, once
# per BYPASS_EN setting, against the same rf.v (rf_bypass_tb.v and
# rf_no_bypass_tb.v, carried over from phase 4). cache and plru carry over
# from phase 5, and fpu is checked on its own. hart is checked eight times
# against the same hart.v, one per rubric row in phase_6.pdf. Each runs
# traces/random_program.hex in the graded cache configuration (PLRU, 4 ways,
# 2 KB, 16 B blocks, prefetch on, 4-cycle memory) and compares its section's
# register dump range with traces/random_dmem.hex (phase_6.pdf 6.1):
#   hart_muldiv           muldiv           0x10020000-0x100217FF
#   hart_fp_move_compare  fp move compare  0x10021800-0x10022FFF
#   hart_fp_convert       fp convert       0x10023000-0x100247FF
#   hart_fp_arith         fp add mul       0x10024800-0x10025FFF
#                         + fp fused       0x10026000-0x100277FF
#   hart_fp_div_sqrt      fp div sqrt      0x10027800-0x10028FFF
#   hart_fp_csr           fp csr           0x10029000-0x1002A7FF
#   hart_mixed            mixed            0x1002A800-0x1002BFFF
#   hart_cache_stall      cache stall      0x1002C000-0x1002D7FF
MODULES=(alu imm rf_bypass rf_no_bypass decoder cache plru fpu fpu_round hart_muldiv hart_fp_move_compare hart_fp_convert hart_fp_arith hart_fp_div_sqrt hart_fp_csr hart_mixed hart_cache_stall)

# Most checks share a name with the .v file they test; rf's two checks both
# target rf.v and hart's eight target hart.v. No associative arrays on
# purpose -- macOS ships bash 3.2.
dut_for() {
    case "$1" in
        rf_bypass | rf_no_bypass) echo "rf" ;;
        hart_*) echo "hart" ;;
        *) echo "$1" ;;
    esac
}

# Every non-testbench .v file at the repo root is a potential dependency
# (hart instantiates alu/rf/decoder/cache/fpu, decoder instantiates imm), so every
# module is compiled against the full set.
SOURCES=()
while IFS= read -r f; do
    SOURCES+=("${f}")
done < <(find "${SUBMISSION_DIR}" -maxdepth 1 -name '*.v' ! -name '*_tb.v' | sort)

overall_status=0

for name in "${MODULES[@]}"; do
    dut_name="$(dut_for "${name}")"
    dut="${SUBMISSION_DIR}/${dut_name}.v"
    tb="${SUBMISSION_DIR}/${name}_tb.v"

    if [[ ! -f "${dut}" ]]; then
        echo "SKIP Verilog: ${name}  --  ${dut_name}.v not found" >> "${SUMMARY_FILE}"
        continue
    fi
    if [[ ! -s "${tb}" ]]; then
        echo "SKIP Verilog: ${name}  --  ${name}_tb.v not written yet" >> "${SUMMARY_FILE}"
        continue
    fi

    log="${BUILD_DIR}/${name}.log"
    sim="${BUILD_DIR}/${name}_sim"

    if ! iverilog -g2005 -s "${name}_tb" -o "${sim}" "${tb}" "${SOURCES[@]}" > "${log}" 2>&1; then
        echo "FAIL Verilog: ${name}  --  compile error, see build/${name}.log" >> "${SUMMARY_FILE}"
        overall_status=1
        continue
    fi

    ( cd "${BUILD_DIR}" && vvp "${sim}" ) >> "${log}" 2>&1

    tally=$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "${log}" | tail -1)
    verdict=$(grep -E '^(ALL TESTS PASSED|TEST FAILED)$' "${log}" | tail -1)

    if [[ "${verdict}" == "ALL TESTS PASSED" ]]; then
        echo "PASS Verilog: ${name}  --  ${tally}" >> "${SUMMARY_FILE}"
    else
        echo "FAIL Verilog: ${name}  --  ${tally:-simulation did not report a verdict, see build/${name}.log}" >> "${SUMMARY_FILE}"
        overall_status=1
    fi
done

# The rule checker the autograder runs (lint/, see README.md). It compiles
# every source file as one design, so it gets one row for all of them.
if ! command -v ece552 >/dev/null 2>&1; then
    echo "SKIP Lint: ece552  --  not installed, run pip install ./lint" >> "${SUMMARY_FILE}"
elif ece552 validate -w "${SOURCES[@]}" > "${BUILD_DIR}/lint.log" 2>&1; then
    echo "PASS Lint: ece552  --  no rule violations" >> "${SUMMARY_FILE}"
else
    echo "FAIL Lint: ece552  --  rule violations, see build/lint.log" >> "${SUMMARY_FILE}"
    overall_status=1
fi

echo "Wrote ${SUMMARY_FILE}"
echo "Build/sim logs and waveforms: ${BUILD_DIR}"
exit "${overall_status}"
