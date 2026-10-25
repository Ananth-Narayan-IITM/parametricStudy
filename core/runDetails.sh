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
        printf '%s (rc=%s)\n' "$label" "$RUN_RC" > runFailure
        print_failure "$RUN_RC" | tee -a "$LOG_FILE"
        return "$RUN_RC"
    }
}

run_detailed_case() {

    LOG_FILE="${LOG_FILE:-log.Allrun}"
    CASE_NAME="${CASE_NAME:-$(basename "$PWD")}"
    rm -f runFailure
    : > "$LOG_FILE"

    TOTAL_STEPS=1
    STEP=0
    TOTAL_START=$(date +%s)

    print_header | tee -a "$LOG_FILE"

    run_step "Case run" run_simple_case || return $?

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
