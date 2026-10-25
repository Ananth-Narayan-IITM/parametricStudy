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

status_load() {
    local caseName=$1
    local file key value

    ST_STATE=""
    ST_START=""
    ST_END=""
    ST_ELAPSED=""
    ST_RC=""
    ST_REASON=""

    file=$(status_file "$caseName")
    [ -f "$file" ] || return 0

    while IFS='=' read -r key value; do
        case "$key" in
            state)   ST_STATE=$value ;;
            start)   ST_START=$value ;;
            end)     ST_END=$value ;;
            elapsed) ST_ELAPSED=$value ;;
            rc)      ST_RC=$value ;;
            reason)  ST_REASON=$value ;;
        esac
    done < "$file"
}

status_get() {
    status_load "$1"

    case "$2" in
        state)   printf '%s' "$ST_STATE" ;;
        start)   printf '%s' "$ST_START" ;;
        end)     printf '%s' "$ST_END" ;;
        elapsed) printf '%s' "$ST_ELAPSED" ;;
        rc)      printf '%s' "$ST_RC" ;;
        reason)  printf '%s' "$ST_REASON" ;;
    esac
}

status_set() {
    local caseName=$1
    local state=$2
    local start=${3:-}
    local end=${4:-}
    local elapsed=${5:-}
    local rc=${6:-}
    local reason=${7:-}
    local file tmp

    file=$(status_file "$caseName")
    tmp="${file}.tmp.$$"

    {
        printf 'state=%s\n' "$state"
        printf 'start=%s\n' "$start"
        printf 'end=%s\n' "$end"
        printf 'elapsed=%s\n' "$elapsed"
        printf 'rc=%s\n' "$rc"
        printf 'reason=%s\n' "$reason"
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
    local reason=${3:-}
    local start end elapsed state

    status_load "$caseName"
    start=$ST_START
    end=$(date +%s)

    [ -z "$start" ] && start=$end

    elapsed=$((end - start))

    if [ "$rc" -eq 0 ]; then
        state=DONE
    else
        state=FAILED
    fi

    status_set "$caseName" "$state" "$start" "$end" "$elapsed" "$rc" "$reason"
}

mark_case_skipped() {
    status_set "$1" SKIPPED
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

state_color() {
    case "$1" in
        DONE)    printf '%s' "$UI_GREEN" ;;
        FAILED)  printf '%s' "$UI_RED" ;;
        RUNNING) printf '%s' "$UI_CYAN" ;;
        SKIPPED) printf '%s' "$UI_DIM" ;;
        *)       printf '%s' "$UI_YELLOW" ;;
    esac
}

case_params() {
    local values=$1
    local -a vals
    local out=""
    local i

    read -r -a vals <<< "$values"

    for ((i=0;i<${#paramNames[@]};i++)); do
        [ -n "$out" ] && out+=" "
        out+="${paramNames[$i]}=${vals[$i]}"
    done

    printf '%s' "$out"
}

build_status_table() {

    local plain=${1:-0}
    local now
    local done=0 running=0 queued=0 failed=0 skipped=0
    local total=${#CASE_NAMES[@]}
    local totalElapsed=""
    local paramWidth=24
    local showCores=1
    local i caseName state start elapsed params stateColor

    # The file copy must be plain text, not a terminal snapshot.
    if [ "$plain" -eq 1 ]; then
        local UI_RESET=""
        local UI_BOLD=""
        local UI_DIM=""
        local UI_GREEN=""
        local UI_RED=""
        local UI_CYAN=""
        local UI_YELLOW=""
    fi

    if [ "${UI_WIDTH:-64}" -lt 90 ]; then
        paramWidth=14
    fi

    if [ "${UI_WIDTH:-64}" -lt 72 ]; then
        showCores=0
        paramWidth=12
    fi

    now=$(date +%s)

    [ -n "${STATUS_START:-}" ] && totalElapsed=$((now - STATUS_START))

    for ((i=0;i<total;i++)); do

        status_load "${CASE_NAMES[$i]}"

        case "$ST_STATE" in
            DONE)    done=$((done + 1)) ;;
            FAILED)  failed=$((failed + 1)) ;;
            SKIPPED) skipped=$((skipped + 1)) ;;
            RUNNING) running=$((running + 1)) ;;
            *)       queued=$((queued + 1)) ;;
        esac
    done

    printf '  %s\n' "Case status"
    ui_rule

    printf '  %s%-14s %-*s ' "$UI_DIM" "Case" "$paramWidth" "Parameters"
    [ "$showCores" -eq 1 ] && printf '%-6s ' "Cores"
    printf '%-9s %-10s%s\n' "State" "Elapsed" "$UI_RESET"

    for ((i=0;i<total;i++)); do

        caseName=${CASE_NAMES[$i]}
        status_load "$caseName"

        state=${ST_STATE:-QUEUED}
        start=$ST_START
        elapsed=$ST_ELAPSED
        params=$(ui_fit "$(case_params "${CASE_VALUES[$i]}")" "$paramWidth")

        if [ "$state" = "RUNNING" ] && [ -n "$start" ]; then
            elapsed=$((now - start))
        fi

        if [ "$state" = "QUEUED" ] || [ "$state" = "SKIPPED" ]; then
            elapsed=""
        fi

        stateColor=$(state_color "$state")

        printf '  %s%-14s%s %-*s ' \
            "$UI_BOLD" "$caseName" "$UI_RESET" \
            "$paramWidth" "$params"

        [ "$showCores" -eq 1 ] && printf '%-6s ' "$processors"

        printf '%s%-9s%s %-10s\n' \
            "$stateColor" "$state" "$UI_RESET" \
            "$(fmt_duration "$elapsed")"

        if [ "$state" = "FAILED" ] && [ -n "$ST_REASON" ]; then
            printf '      reason: %s\n' "$ST_REASON"
        fi
    done

    ui_rule

    printf '  %s%-14s%s Done: %s%d%s   Running: %s%d%s   Failed: %s%d%s\n' \
        "$UI_DIM" "Summary" "$UI_RESET" \
        "$UI_GREEN" "$done" "$UI_RESET" \
        "$UI_CYAN" "$running" "$UI_RESET" \
        "$UI_RED" "$failed" "$UI_RESET"
    printf '  %s%-14s%s Queued: %s%d%s   Skipped: %s%d%s\n' \
        "$UI_DIM" "" "$UI_RESET" \
        "$UI_YELLOW" "$queued" "$UI_RESET" \
        "$UI_DIM" "$skipped" "$UI_RESET"
    printf '  %s%-14s%s %s\n' \
        "$UI_DIM" "Total elapsed" "$UI_RESET" "$(fmt_duration "$totalElapsed")"
}

build_config_summary() {

    local width=${UI_WIDTH:-64}
    local mode="parallel"
    local concurrent="$maxConcurrentCases"
    local chained=0
    local screening=0

    case "${continueFromPrevious,,}" in
        true|1|yes|on) chained=1 ;;
    esac

    case "${coreScreening,,}" in
        true|1|yes|on) screening=1 ;;
    esac

    if [ "$chained" -eq 1 ]; then
        mode="chained (serial)"
        concurrent="1"
    fi

    printf 'Parametric study settings\n'
    printf '%*s\n' "$width" '' | tr ' ' '-'
    printf '  %-24s %s\n' "Case directory" "$CASE_DIR"
    printf '  %-24s %s\n' "paramDict" "$PARAM_DICT"
    printf '  %-24s %s\n' "Solver" "$solver"
    printf '  %-24s %s\n' "Study type" "$studyType"
    printf '  %-24s %s\n' "Case prefix" "$prefix"
    printf '  %-24s %s\n' "Parameters" "${paramNames[*]}"
    printf '  %-24s %s\n' "Cases" "${#CASE_NAMES[@]}"
    printf '  %-24s %s\n' "Processors / case" "$processors"
    printf '  %-24s %s\n' "Available cores" "$availableCores"
    printf '  %-24s %s\n' "Execution mode" "$mode"
    printf '  %-24s %s\n' "Concurrent cases" "$concurrent"
    printf '  %-24s %s\n' "Continue from previous" "$continueFromPrevious"

    if [ "$screening" -eq 1 ]; then
        printf '  %-24s %s\n' "Core screening" "enabled"
        printf '  %-24s %s\n' "Core list" "${coreList[*]}"
        printf '  %-24s %s\n' "Optimal core" "${optimalCore:-auto}"
    fi

    [ -n "$runTag" ]     && printf '  %-24s %s\n' "Run tag" "$runTag"
    [ -n "$runComment" ] && printf '  %-24s %s\n' "Comment" "$runComment"
    [ -n "$authorNote" ] && printf '  %-24s %s\n' "Note" "$authorNote"

    printf '%*s\n' "$width" '' | tr ' ' '-'
}

render_status_dashboard() {

    local table
    local plainTable

    table=$(build_status_table)
    plainTable=$(build_status_table 1)

    {
        build_config_summary
        printf '\n'
        printf '%s\n' "$plainTable"
    } > "$PARAMETRIC_STATUS_DIR/dashboard.txt"

    printf '%s\n' "$table"
}

print_sweep_summary() {

    local wall
    local sumCase=0
    local maxCase=0
    local minCase=0
    local fastest=""
    local slowest=""
    local util=0
    local total=${#CASE_NAMES[@]}
    local done=0 running=0 queued=0 failed=0 skipped=0
    local i caseName elapsed

    wall=$(( $(date +%s) - STATUS_START ))

    for ((i=0;i<total;i++)); do

        caseName=${CASE_NAMES[$i]}
        status_load "$caseName"

        case "$ST_STATE" in
            DONE)    done=$((done + 1)) ;;
            FAILED)  failed=$((failed + 1)) ;;
            SKIPPED) skipped=$((skipped + 1)) ;;
            RUNNING) running=$((running + 1)) ;;
            *)       queued=$((queued + 1)) ;;
        esac

        case "$ST_STATE" in
            DONE|FAILED) ;;
            *) continue ;;
        esac

        elapsed=$ST_ELAPSED
        [ -z "$elapsed" ] && elapsed=0

        sumCase=$((sumCase + elapsed))

        if [ "$elapsed" -gt "$maxCase" ]; then
            maxCase=$elapsed
            slowest=$caseName
        fi

        if [ "$minCase" -eq 0 ] || [ "$elapsed" -lt "$minCase" ]; then
            minCase=$elapsed
            fastest=$caseName
        fi
    done

    if [ "$wall" -gt 0 ] && [ -n "$availableCores" ] && [ "$availableCores" -gt 0 ]; then
        util=$(( sumCase * processors * 100 / (wall * availableCores) ))
        [ "$util" -gt 100 ] && util=100
    fi

    ui_section "Sweep summary"

    if [ "$failed" -eq 0 ] && [ "$skipped" -eq 0 ] && [ "$done" -eq "$total" ]; then
        ui_kv "Status" "$UI_GREEN all cases completed$UI_RESET"
    elif [ "$failed" -gt 0 ]; then
        ui_kv "Status" "$UI_RED $failed case(s) failed$UI_RESET"
    elif [ "$skipped" -gt 0 ]; then
        ui_kv "Status" "$UI_YELLOW $skipped case(s) skipped$UI_RESET"
    else
        ui_kv "Status" "$UI_YELLOW $done/$total completed$UI_RESET"
    fi

    ui_kv "Current" "$running running"
    ui_kv "Staged" "$queued queued"
    ui_kv "Skipped" "$skipped"
    ui_kv "Ran" "$done / $total  ($done passed, $failed failed)"
    ui_kv "Wall time" "$(fmt_duration "$wall")"
    ui_kv "Aggregate case time" "$(fmt_duration "$sumCase")"
    ui_kv "Core utilization" "${util}%"
    [ -n "$fastest" ] && ui_kv "Fastest case" "$fastest  ($(fmt_duration "$minCase"))"
    [ -n "$slowest" ] && ui_kv "Slowest case" "$slowest  ($(fmt_duration "$maxCase"))"

    ui_rule

    if [ "$failed" -gt 0 ]; then
        for ((i=0;i<total;i++)); do
            caseName=${CASE_NAMES[$i]}
            status_load "$caseName"
            if [ "$ST_STATE" = "FAILED" ]; then
                ui_kv "Failed $caseName" "${ST_REASON:-unknown}"
            fi
        done
        ui_kv "Failed workdirs" "$PARAMETRIC_WORK_DIR"
    fi
}
