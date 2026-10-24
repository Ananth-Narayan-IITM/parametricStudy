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

    file=$(status_file "$caseName")
    [ -f "$file" ] || return 0

    while IFS='=' read -r key value; do
        case "$key" in
            state)   ST_STATE=$value ;;
            start)   ST_START=$value ;;
            end)     ST_END=$value ;;
            elapsed) ST_ELAPSED=$value ;;
            rc)      ST_RC=$value ;;
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
    esac
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

state_color() {
    case "$1" in
        DONE)    printf '%s' "$UI_GREEN" ;;
        FAILED)  printf '%s' "$UI_RED" ;;
        RUNNING) printf '%s' "$UI_CYAN" ;;
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

status_progress() {
    local caseName=$1
    local workDir="$PARAMETRIC_WORK_DIR/$caseName"
    local latest
    local pct

    [ -d "$workDir" ] || { printf '0'; return; }

    latest=$(find "$workDir" -maxdepth 2 -type d -regextype posix-extended \
        -regex '.*/[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?' \
        -printf '%f\n' 2>/dev/null | sort -g | tail -1)
    [ -z "$latest" ] && latest=0

    pct=$(awk -v l="$latest" -v s="$STATUS_START_TIME" -v e="$STATUS_END_TIME" 'BEGIN {
        if (e <= s || l <= s) { printf "0"; exit }
        v = (l - s) / (e - s) * 100
        if (v > 99) v = 99
        if (v < 0) v = 0
        printf "%d", v
    }')

    printf '%s' "${pct:-0}"
}

build_status_table() {

    local now
    local done=0 running=0 queued=0 failed=0
    local total=${#CASE_NAMES[@]}
    local completed=0 overall=0
    local totalElapsed=""
    local eta="--:--:--"
    local etaSec=0
    local paramWidth=24
    local barWidth=16
    local showCores=1
    local i caseName state start elapsed params progress
    local progressText stateColor

    if [ "${UI_WIDTH:-64}" -lt 90 ]; then
        paramWidth=14
        barWidth=10
    fi

    if [ "${UI_WIDTH:-64}" -lt 72 ]; then
        showCores=0
        paramWidth=12
        barWidth=8
    fi

    now=$(date +%s)

    [ -n "${STATUS_START:-}" ] && totalElapsed=$((now - STATUS_START))

    for ((i=0;i<total;i++)); do

        status_load "${CASE_NAMES[$i]}"

        case "$ST_STATE" in
            DONE)    done=$((done + 1)) ;;
            FAILED)  failed=$((failed + 1)) ;;
            RUNNING) running=$((running + 1)) ;;
            *)       queued=$((queued + 1)) ;;
        esac
    done

    completed=$((done + failed))
    [ "$total" -gt 0 ] && overall=$((completed * 100 / total))

    if [ "$completed" -gt 0 ] && [ "$totalElapsed" -gt 0 ]; then
        etaSec=$(( totalElapsed * (total - completed) / completed ))
        eta=$(fmt_duration "$etaSec")
    fi

    printf '  %s\n' "Case status"
    ui_rule

    printf '  %s%-14s %-*s ' "$UI_DIM" "Case" "$paramWidth" "Parameters"
    [ "$showCores" -eq 1 ] && printf '%-6s ' "Cores"
    printf '%-9s %-10s %-*s%s\n' \
        "State" "Elapsed" "$((barWidth + 5))" "Progress" "$UI_RESET"

    for ((i=0;i<total;i++)); do

        caseName=${CASE_NAMES[$i]}
        status_load "$caseName"

        state=${ST_STATE:-QUEUED}
        start=$ST_START
        elapsed=$ST_ELAPSED
        params=$(ui_fit "$(case_params "${CASE_VALUES[$i]}")" "$paramWidth")

        if [ "$state" = "RUNNING" ]; then
            if [ -n "$start" ]; then
                elapsed=$((now - start))
            else
                elapsed=""
            fi
        fi

        case "$state" in
            DONE)
                progress=100
                progressText="$(ui_bar "$progress" "$barWidth" "$UI_GREEN") $(printf '%3d%%' "$progress")"
                ;;
            FAILED)
                progress=100
                progressText="$(ui_bar "$progress" "$barWidth" "$UI_RED") $(printf '%3d%%' "$progress")"
                ;;
            RUNNING)
                progress=$(status_progress "$caseName")
                progressText="$(ui_bar "$progress" "$barWidth" "$UI_CYAN") $(printf '%3d%%' "$progress")"
                ;;
            *)
                state=QUEUED
                elapsed=""
                progressText="$(ui_bar 0 "$barWidth" "$UI_DIM")   --"
                ;;
        esac

        stateColor=$(state_color "$state")

        printf '  %s%-14s%s %-*s ' \
            "$UI_BOLD" "$caseName" "$UI_RESET" \
            "$paramWidth" "$params"

        [ "$showCores" -eq 1 ] && printf '%-6s ' "$processors"

        printf '%s%-9s%s %-10s %s\n' \
            "$stateColor" "$state" "$UI_RESET" \
            "$(fmt_duration "$elapsed")" \
            "$progressText"
    done

    ui_rule

    printf '  %s%-14s%s Done: %s%d%s   Running: %s%d%s   Failed: %s%d%s   Queued: %s%d%s\n' \
        "$UI_DIM" "Summary" "$UI_RESET" \
        "$UI_GREEN" "$done" "$UI_RESET" \
        "$UI_CYAN" "$running" "$UI_RESET" \
        "$UI_RED" "$failed" "$UI_RESET" \
        "$UI_YELLOW" "$queued" "$UI_RESET"
    printf '  %s%-14s%s %s %3d%%   ETA %s\n' \
        "$UI_DIM" "Overall" "$UI_RESET" \
        "$(ui_bar "$overall" "$barWidth" "$UI_GREEN")" \
        "$overall" "$eta"
    printf '  %s%-14s%s %s\n' \
        "$UI_DIM" "Total elapsed" "$UI_RESET" "$(fmt_duration "$totalElapsed")"
}

render_status_line() {

    [ "${UI_ANSI:-0}" -eq 1 ] || return 0

    local now
    local done=0 running=0 queued=0 failed=0
    local total=${#CASE_NAMES[@]}
    local i caseName current="" pct

    now=$(date +%s)

    for ((i=0;i<total;i++)); do

        caseName=${CASE_NAMES[$i]}
        status_load "$caseName"

        case "$ST_STATE" in
            DONE)    done=$((done + 1)) ;;
            FAILED)  failed=$((failed + 1)) ;;
            RUNNING)
                running=$((running + 1))
                pct=$(status_progress "$caseName")
                current+="${caseName} ${pct}%   "
                ;;
            *)       queued=$((queued + 1)) ;;
        esac
    done

    printf '\r\033[2K  %sSTATUS%s  %s  done %s%d%s  running %s%d%s  queued %s%d%s  failed %s%d%s' \
        "$UI_CYAN" "$UI_RESET" "$(fmt_duration $((now - STATUS_START)))" \
        "$UI_GREEN" "$done" "$UI_RESET" \
        "$UI_CYAN" "$running" "$UI_RESET" \
        "$UI_YELLOW" "$queued" "$UI_RESET" \
        "$UI_RED" "$failed" "$UI_RESET"

    if [ -n "$current" ]; then
        printf '  %sCURRENT%s %s' \
            "$UI_CYAN" "$UI_RESET" \
            "$(ui_fit "$current" $((UI_WIDTH - 48)))"
    fi

    STATUS_LINE_ACTIVE=1
}

render_status_dashboard() {

    local table
    table=$(build_status_table)

    if [ "${STATUS_LINE_ACTIVE:-0}" = "1" ]; then
        printf '\n'
        STATUS_LINE_ACTIVE=0
    fi

    printf '%s\n' "$table" > "$PARAMETRIC_STATUS_DIR/dashboard.txt"

    if [ "${UI_ANSI:-0}" -eq 1 ]; then

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

print_sweep_summary() {

    local wall
    local sumCase=0
    local maxCase=0
    local minCase=0
    local fastest=""
    local slowest=""
    local util=0
    local total=${#CASE_NAMES[@]}
    local done=0 running=0 queued=0 failed=0
    local i caseName elapsed

    wall=$(( $(date +%s) - STATUS_START ))

    for ((i=0;i<total;i++)); do

        caseName=${CASE_NAMES[$i]}
        status_load "$caseName"

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

        case "$ST_STATE" in
            DONE)    done=$((done + 1)) ;;
            FAILED)  failed=$((failed + 1)) ;;
            RUNNING) running=$((running + 1)) ;;
            *)       queued=$((queued + 1)) ;;
        esac
    done

    if [ "$wall" -gt 0 ] && [ -n "$availableCores" ] && [ "$availableCores" -gt 0 ]; then
        util=$(( sumCase * processors * 100 / (wall * availableCores) ))
        [ "$util" -gt 100 ] && util=100
    fi

    ui_section "Sweep summary"

    if [ "$failed" -eq 0 ] && [ "$done" -eq "$total" ]; then
        ui_kv "Status" "$UI_GREEN all cases completed$UI_RESET"
    elif [ "$failed" -gt 0 ]; then
        ui_kv "Status" "$UI_RED $failed case(s) failed$UI_RESET"
    else
        ui_kv "Status" "$UI_YELLOW $done/$total completed$UI_RESET"
    fi

    ui_kv "Current" "$running running"
    ui_kv "Staged" "$queued queued"
    ui_kv "Ran" "$done / $total  ($done passed, $failed failed)"
    ui_kv "Wall time" "$(fmt_duration "$wall")"
    ui_kv "Aggregate case time" "$(fmt_duration "$sumCase")"
    ui_kv "Core utilization" "$(ui_bar "$util" 20) ${util}%"
    [ -n "$fastest" ] && ui_kv "Fastest case" "$fastest  ($(fmt_duration "$minCase"))"
    [ -n "$slowest" ] && ui_kv "Slowest case" "$slowest  ($(fmt_duration "$maxCase"))"

    ui_rule

    if [ "$failed" -gt 0 ]; then
        ui_kv "Failed workdirs" "$PARAMETRIC_WORK_DIR"
    fi
}
