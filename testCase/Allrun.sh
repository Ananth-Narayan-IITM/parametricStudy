#!/bin/bash
# --------------------------------------------------
# UNIVERSAL OpenFOAM Allrun
# Compatible with:
#   - Core screening
#   - Grid independence
#   - Parametric study
#   - Standalone execution
#
# All command output is diverted to log.Allrun.
# Only a compact progress/summary is written to the
# terminal.
# --------------------------------------------------

PARAM_DICT="${PARAM_DICT:-system/paramDict}"

# Standalone runs read the core count from paramDict.  The
# parametric engine overrides NP through the environment.
if [ -z "$NP" ]; then
    NP=$(foamDictionary "$PARAM_DICT" -entry processors -value 2>/dev/null)
fi

if [ -z "$NP" ] || ! [[ "$NP" =~ ^[0-9]+$ ]] || [ "$NP" -lt 1 ]; then
    echo "[WARN] Invalid processors entry in $PARAM_DICT -> defaulting to serial"
    NP=1
fi

solver=$(foamDictionary "$PARAM_DICT" -entry solver -value)
cores=${NP:-1}

if [ "$cores" -gt 1 ]; then
    RUN_PARALLEL=1
else
    RUN_PARALLEL=0
fi

meshFile=$(foamDictionary "$PARAM_DICT" -entry meshFile -value | tr -d '"')
meshOut=$(foamDictionary "$PARAM_DICT" -entry meshOut -value | tr -d '"')

CASE_NAME=$(basename "$PWD")
LOG_FILE="log.Allrun"
: > "$LOG_FILE"

TOTAL_STEPS=2
[ "$RUN_PARALLEL" == "1" ] && TOTAL_STEPS=4
STEP=0
TOTAL_START=$(date +%s)

format_time() {
    local seconds=${1:-0}
    [ "$seconds" -lt 0 ] && seconds=0
    printf '%02d:%02d:%02d' \
        $((seconds / 3600)) \
        $(((seconds % 3600) / 60)) \
        $((seconds % 60))
}

print_header() {
    printf '\n'
    printf '%s\n' "------------------------------------------------------------"
    printf ' %-14s %s\n' "Case" "$CASE_NAME"
    printf ' %-14s %s\n' "Solver" "$solver"
    printf ' %-14s %s\n' "Cores" "$cores"
    printf ' %-14s %s\n' "Mode" "$([ "$RUN_PARALLEL" == "1" ] && echo parallel || echo serial)"
    printf ' %-14s %s\n' "Mesh" "$meshFile"
    printf ' %-14s %s\n' "Log" "$LOG_FILE"
    printf '%s\n' "------------------------------------------------------------"
}

print_failure() {
    local rc=${1:-1}
    local elapsed=$(( $(date +%s) - TOTAL_START ))

    printf '%s\n' "------------------------------------------------------------"
    printf ' %-14s %s\n' "Status" "FAILED"
    printf ' %-14s %s\n' "Case" "$CASE_NAME"
    printf ' %-14s %s\n' "Elapsed" "$(format_time "$elapsed")"
    printf ' %-14s %s\n' "Log" "$LOG_FILE"
    printf '%s\n' "------------------------------------------------------------"
}

trap 'rc=$?; if [ "$rc" -ne 0 ]; then print_failure "$rc" | tee -a "$LOG_FILE"; fi' EXIT

run_logged() {
    local label=$1
    shift

    local start end elapsed rc

    STEP=$((STEP + 1))

    printf '  [%d/%d] %-20s ' "$STEP" "$TOTAL_STEPS" "$label"

    {
        printf '\n===== %s =====\n' "$label"
        printf 'Command : %s\n' "$*"
        printf 'Started : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } >> "$LOG_FILE"

    start=$(date +%s)

    if "$@" >> "$LOG_FILE" 2>&1; then
        rc=0
    else
        rc=$?
    fi

    end=$(date +%s)
    elapsed=$((end - start))

    {
        printf 'Finished: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'Status  : %s\n' "$rc"
    } >> "$LOG_FILE"

    if [ "$rc" -eq 0 ]; then
        printf 'ok    %s\n' "$(format_time "$elapsed")"
    else
        printf 'FAIL  %s\n' "$(format_time "$elapsed")"
    fi

    return "$rc"
}

print_skipped() {
    local label=$1
    local reason=$2

    STEP=$((STEP + 1))

    printf '  [%d/%d] %-20s %s\n' \
        "$STEP" "$TOTAL_STEPS" "$label" "$reason"
}

generate_mesh() {
    gmsh "${meshFile}" -3 -format msh2 -o "${meshOut}" &&
    gmshToFoam "${meshOut}" &&
    changeDictionary -constant
}

decompose_case() {
    rm -rf processor* &&
    foamDictionary system/decomposeParDict \
        -entry numberOfSubdomains \
        -set "$NP" &&
    decomposePar -force
}

solve_parallel() {
    mpirun -np "$NP" "$solver" -parallel
}

solve_serial() {
    "$solver"
}

reconstruct_case() {
    reconstructPar
}

print_header | tee -a "$LOG_FILE"

if [ ! -d "constant/polyMesh" ]; then
    run_logged "Mesh generation" generate_mesh || exit 1
else
    print_skipped "Mesh" "existing mesh"
fi

if [ "$RUN_PARALLEL" == "1" ]; then

    run_logged "Decompose" decompose_case || exit 1
    run_logged "Solve" solve_parallel || exit 1

    if ls -d processor*/[0-9]* 2>/dev/null | grep -qv '/0$'; then
        run_logged "Reconstruct" reconstruct_case || exit 1
    else
        print_skipped "Reconstruct" "nothing to do"
    fi

else

    run_logged "Solve" solve_serial || exit 1

fi

TOTAL_ELAPSED=$(( $(date +%s) - TOTAL_START ))

{
    printf '%s\n' "------------------------------------------------------------"
    printf ' %-14s %s\n' "Status" "COMPLETE"
    printf ' %-14s %s\n' "Case" "$CASE_NAME"
    printf ' %-14s %s\n' "Elapsed" "$(format_time "$TOTAL_ELAPSED")"
    printf ' %-14s %s\n' "Log" "$LOG_FILE"
    printf '%s\n' "------------------------------------------------------------"
} | tee -a "$LOG_FILE"
