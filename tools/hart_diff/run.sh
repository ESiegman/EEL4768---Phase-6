#!/usr/bin/env bash
set -uo pipefail

# Differential test for hart.v: run a program on the hart and on iss.py and
# diff the two retire streams line by line. See README.md.
#
# usage: tools/hart_diff/run.sh [--real decoder|alu|fpu]... [--directed]
#                               [--prog file.hex] [iverilog -P/-D flags...]

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TOOL_DIR}/../.." && pwd)"
OUT_DIR="${REPO_DIR}/build/hart_diff"
mkdir -p "${OUT_DIR}"

REAL_DECODER=0
REAL_ALU=0
REAL_FPU=0
PROG="${REPO_DIR}/traces/random_program.hex"
GOLD="${REPO_DIR}/traces/random_dmem.hex"
FLAGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --real)
            case "${2:-}" in
                decoder) REAL_DECODER=1 ;;
                alu)     REAL_ALU=1 ;;
                fpu)     REAL_FPU=1 ;;
                *) echo "--real takes decoder, alu or fpu" >&2; exit 1 ;;
            esac
            shift 2 ;;
        --directed)
            python3 "${TOOL_DIR}/directed.py" "${OUT_DIR}/directed.hex" || exit 1
            PROG="${OUT_DIR}/directed.hex"
            GOLD=""
            shift ;;
        --prog)
            PROG="$2"
            GOLD=""
            shift 2 ;;
        *)
            FLAGS+=("$1")
            shift ;;
    esac
done

# The hart and every other design file at the repo root, minus the modules a
# stand-in replaces. A stand-in and the real module share a name, so only one
# of them can be compiled.
SOURCES=()
while IFS= read -r f; do
    name="$(basename "${f}" .v)"
    if [[ "${name}" == "decoder" && "${REAL_DECODER}" -eq 0 ]]; then continue; fi
    if [[ "${name}" == "alu" && "${REAL_ALU}" -eq 0 ]]; then continue; fi
    if [[ "${name}" == "fpu" && "${REAL_FPU}" -eq 0 ]]; then continue; fi
    SOURCES+=("${f}")
done < <(find "${REPO_DIR}" -maxdepth 1 -name '*.v' ! -name '*_tb.v' | sort)

if [[ "${REAL_DECODER}" -eq 0 ]]; then
    SOURCES+=("${TOOL_DIR}/standin_decoder.v" "${TOOL_DIR}/rv32i_decoder.v")
fi
if [[ "${REAL_ALU}" -eq 0 ]]; then
    SOURCES+=("${TOOL_DIR}/standin_alu.v" "${TOOL_DIR}/rv32i_alu.v")
fi
if [[ "${REAL_FPU}" -eq 0 ]]; then
    SOURCES+=("${TOOL_DIR}/standin_fpu.v")
fi

echo "stand-ins: decoder=$([[ ${REAL_DECODER} -eq 1 ]] && echo real || echo standin)" \
     "alu=$([[ ${REAL_ALU} -eq 1 ]] && echo real || echo standin)" \
     "fpu=$([[ ${REAL_FPU} -eq 1 ]] && echo real || echo standin)"

SIM="${OUT_DIR}/sim"
rm -f "${SIM}"
if ! iverilog -g2005 -I "${REPO_DIR}" -s tb -o "${SIM}" ${FLAGS[@]+"${FLAGS[@]}"} \
        "${TOOL_DIR}/hart_diff_tb.v" "${SOURCES[@]}"; then
    echo "FAIL: compile error" >&2
    exit 1
fi

( cd "${OUT_DIR}" && vvp -n "${SIM}" "+prog=${PROG}" "+gold=${GOLD}" "+out=hart.trace" ) \
    | grep -v '\$finish called' > "${OUT_DIR}/sim.log"
cat "${OUT_DIR}/sim.log"
sim_failed=0
if grep -qE '^ERROR|DID NOT HALT|\[FAIL\]' "${OUT_DIR}/sim.log"; then
    sim_failed=1
fi

# The ISS only knows the stand-in FPU's fake math, so with the real fpu the
# retire streams are not comparable. Use the golden sections instead.
if [[ "${REAL_FPU}" -eq 1 ]]; then
    echo "real fpu: retire stream not diffed, check the golden sections above"
    exit "${sim_failed}"
fi

python3 "${TOOL_DIR}/iss.py" "${PROG}" "${OUT_DIR}/iss.trace" || exit 1

if cmp -s "${OUT_DIR}/hart.trace" "${OUT_DIR}/iss.trace"; then
    if [[ "${sim_failed}" -eq 1 ]]; then
        echo "FAIL: retire streams match, but the simulation reported errors above"
        exit 1
    fi
    echo "PASS: retire streams match ($(wc -l < "${OUT_DIR}/iss.trace" | tr -d ' ') instructions)"
    exit 0
fi

# First differing line, with the three instructions before it for context.
line=$(cmp "${OUT_DIR}/hart.trace" "${OUT_DIR}/iss.trace" 2>/dev/null | sed -n 's/.* line \([0-9]*\).*/\1/p')
line=${line:-1}
start=$(( line > 3 ? line - 3 : 1 ))
echo "FAIL: retire streams differ at instruction ${line}"
echo "--- iss (expected)"
sed -n "${start},${line}p" "${OUT_DIR}/iss.trace"
echo "--- hart"
sed -n "${start},${line}p" "${OUT_DIR}/hart.trace"
exit 1
