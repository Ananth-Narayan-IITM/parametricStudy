#!/bin/bash
# --------------------------------------------------
# Detailed run wrapper
#
# All timing, logging, progress, and summary code lives
# here.  The actual case commands stay in AllrunSimple.
# --------------------------------------------------

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

print_skipped() {
    local label=$1
    local reason=$2

    STEP=$((STEP + 1))

    printf '  [%d/%d] %-20s %s\n' \
        "$STEP" "$TOTAL_STEPS" "$label" "$reason"
}

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

run_step() {
    local label=$1
    shift

    run_logged "$label" "$@" || {
        RUN_RC=$?
        print_failure "$RUN_RC" | tee -a "$LOG_FILE"
        return "$RUN_RC"
    }
}

run_detailed_case() {

    LOG_FILE="${LOG_FILE:-log.Allrun}"
    CASE_NAME="${CASE_NAME:-$(basename "$PWD")}"
    : > "$LOG_FILE"

    TOTAL_STEPS=2
    [ "$RUN_PARALLEL" == "1" ] && TOTAL_STEPS=4
    STEP=0
    TOTAL_START=$(date +%s)

    print_header | tee -a "$LOG_FILE"

    if [ ! -d "constant/polyMesh" ]; then
        run_step "Mesh generation" generate_mesh || return $?
    else
        print_skipped "Mesh" "existing mesh"
    fi

    if [ "$RUN_PARALLEL" == "1" ]; then

        run_step "Decompose" decompose_case || return $?
        run_step "Solve" solve_parallel || return $?

        if ls -d processor*/[0-9]* 2>/dev/null | grep -qv '/0$'; then
            run_step "Reconstruct" reconstruct_case || return $?
        else
            print_skipped "Reconstruct" "nothing to do"
        fi

    else

        run_step "Solve" solve_serial || return $?

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

    return 0
}
