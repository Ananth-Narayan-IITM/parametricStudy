#!/bin/bash

# --------------------------------------------------
# Case status and elapsed-time dashboard
#
# State is stored per case in:
#   parametricStatus/<caseName>.status
#
# A plain-text snapshot is always written to:
#   parametricStatus/dashboard.txt
# --------------------------------------------------

status_file() {
    printf '%s/%s.status' "$PARAMETRIC_STATUS_DIR" "$1"
}

status_get() {
    local file key
    file=$(status_file "$1")
    key=$2

    [ -f "$file" ] || return 0

    sed -n "s/^${key}=//p" "$file" | head -n1
}

status_set() {
    local caseName=$1
    local state=$2
    local start=${3:-}
    local end=${4:-}
    local elapsed=${5:-}
    local rc=${6:-}
    local file tmp

    file=$(status_file "$caseName")
    tmp="${file}.tmp.$$"

    {
        printf 'state=%s\n' "$state"
        printf 'start=%s\n' "$start"
        printf 'end=%s\n' "$end"
        printf 'elapsed=%s\n' "$elapsed"
        printf 'rc=%s\n' "$rc"
    } > "$tmp" && mv "$tmp" "$file"
}

init_case_statuses() {
    local caseName

    for caseName in "${CASE_NAMES[@]}"; do
        status_set "$caseName" QUEUED
    done
}

mark_case_running() {
    status_set "$1" RUNNING "$(date +%s)"
}

mark_case_finished() {
    local caseName=$1
    local rc=$2
    local start end elapsed state

    start=$(status_get "$caseName" start)
    end=$(date +%s)

    [ -z "$start" ] && start=$end

    elapsed=$((end - start))

    if [ "$rc" -eq 0 ]; then
        state=DONE
    else
        state=FAILED
    fi

    status_set "$caseName" "$state" "$start" "$end" "$elapsed" "$rc"
}

fmt_duration() {
    local s=$1

    if [ -z "$s" ] || ! [[ "$s" =~ ^[0-9]+$ ]]; then
        printf '%s' "--"
        return
    fi

    printf '%02d:%02d:%02d' \
        $((s / 3600)) \
        $(((s % 3600) / 60)) \
        $((s % 60))
}

build_status_table() {

    local now
    local done=0 running=0 queued=0 failed=0
    local caseName state start elapsed totalElapsed=""

    now=$(date +%s)

    for caseName in "${CASE_NAMES[@]}"; do

        state=$(status_get "$caseName" state)

        case "$state" in
            DONE)
                done=$((done + 1))
                ;;
            FAILED)
                failed=$((failed + 1))
                ;;
            RUNNING)
                running=$((running + 1))
                ;;
            *)
                queued=$((queued + 1))
                ;;
        esac
    done

    if [ -n "${STATUS_START:-}" ]; then
        totalElapsed=$((now - STATUS_START))
    fi

    printf '  %s\n' "Case status"
    printf '  %s\n' "------------------------------------------------------------"
    printf '  %-14s %-10s %-12s\n' "Case" "State" "Elapsed"
    printf '  %s\n' "------------------------------------------------------------"

    for caseName in "${CASE_NAMES[@]}"; do

        state=$(status_get "$caseName" state)
        elapsed=$(status_get "$caseName" elapsed)

        if [ "$state" = "RUNNING" ]; then
            start=$(status_get "$caseName" start)
            if [ -n "$start" ]; then
                elapsed=$((now - start))
            else
                elapsed=""
            fi
        fi

        if [ "$state" = "DONE" ] || [ "$state" = "FAILED" ]; then
            :
        elif [ "$state" = "RUNNING" ]; then
            :
        else
            state=QUEUED
            elapsed=""
        fi

        printf '  %-14s %-10s %-12s\n' \
            "$caseName" "$state" "$(fmt_duration "$elapsed")"
    done

    printf '  %s\n' "------------------------------------------------------------"
    printf '  %-14s %-10s %-12s\n' \
        "Summary" "Done: $done" "Running: $running"
    printf '  %-14s %-10s %-12s\n' \
        "Failed" "$failed" "Queued: $queued"
    printf '  %-14s %s\n' "Total elapsed" "$(fmt_duration "$totalElapsed")"
}

render_status_dashboard() {

    local table
    table=$(build_status_table)

    printf '%s\n' "$table" > "$PARAMETRIC_STATUS_DIR/dashboard.txt"

    if [ -t 1 ]; then

        if [ "${STATUS_RENDERED:-0}" = "1" ] && \
           [ "${STATUS_REDRAW:-1}" = "1" ]; then

            printf '\033[%dA' "${STATUS_LINES:-0}"

            while IFS= read -r line; do
                printf '\033[2K\r%s\n' "$line"
            done <<< "$table"

        else
            printf '%s\n' "$table"
        fi

        STATUS_RENDERED=1
        STATUS_LINES=$(printf '%s\n' "$table" | wc -l)

    else
        printf '%s\n' "$table"
    fi
}
