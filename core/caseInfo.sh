#!/bin/bash

# --------------------------------------------------
# Show details for one case
#
# Works for running, archived, and failed cases.
# --------------------------------------------------

format_case_time() {
    local value=$1
    if [ -z "$value" ]; then
        printf '%s' "--"
    elif [[ "$value" =~ ^[0-9]+$ ]]; then
        fmt_wallclock "$value"
    else
        printf '%s' "$value"
    fi
}

show_case_details() {

    local caseName=$1
    local statusFile
    local archiveDir
    local workDir
    local scriptFile
    local fullLog
    local summaryLog
    local workerLog
    local state start end elapsed
    local paramValues
    local -a values=()
    local i
    local tableRow=""
    local header=""
    local -a headerFields=()
    local -a rowFields=()
    local -a calcKeys=()
    local resolvedFile=""
    local value=""
    local showLog=1
    local answer=""

    if [ -z "$caseName" ]; then
        ui_error "No case name supplied"
        return 1
    fi

    archiveDir="$PARAMETRIC_STUDY_DIR/$caseName"
    workDir="$PARAMETRIC_WORK_DIR/$caseName"
    statusFile="$PARAMETRIC_STATUS_DIR/${caseName}.status"

    if [ ! -d "$archiveDir" ] && [ ! -d "$workDir" ] && [ ! -f "$statusFile" ]; then
        ui_error "Case not found: $caseName"
        return 1
    fi

    state=""
    start=""
    end=""
    elapsed=""

    if [ -f "$statusFile" ]; then
        status_load "$caseName"
        state=$ST_STATE
        start=$ST_START
        end=$ST_END
        elapsed=$ST_ELAPSED
    fi

    if [ -z "$state" ] && [ -d "$workDir" ]; then
        state="RUNNING"
    fi

    # Finished cases lose parametricStatus at finalize.
    if [ -z "$state" ] && [ -f "paramDatabase/status.txt" ]; then
        state=$(grep -E "^[[:space:]]+${caseName}[[:space:]]" "paramDatabase/status.txt" 2>/dev/null | \
            grep -oE 'DONE|FAILED|SKIPPED|QUEUED|RUNNING' | head -1)
    fi

    if [ -z "$state" ] && [ -d "$archiveDir" ]; then
        state="ARCHIVED"
    fi

    # Timing fallback for finished cases.
    if [ -f "paramDatabase/paramTable.csv" ]; then
        tableRow=$(awk -F, -v c="$caseName" '$1==c {print; exit}' "paramDatabase/paramTable.csv")
        if [ -n "$tableRow" ] && [ ! -f "$statusFile" ]; then
            IFS=, read -r _ _ _ _ _ start end elapsed _ <<< "$tableRow"
        fi
    fi

    if [ "$state" == "RUNNING" ] && [ -n "$start" ] && [[ "$start" =~ ^[0-9]+$ ]]; then
        elapsed=$(( $(date +%s) - start ))
    fi

    if [ "$state" == "RUNNING" ] || [ -d "$workDir" ]; then
        fullLog="$PARAMETRIC_LOG_DIR/full.${caseName}.log"
        [ -f "$fullLog" ] || fullLog="$workDir/log.Allrun.full"
    else
        fullLog="$archiveDir/log.Allrun.full"
        [ -f "$fullLog" ] || fullLog="$PARAMETRIC_LOG_DIR/full.${caseName}.log"
        [ -f "$fullLog" ] || fullLog="$workDir/log.Allrun.full"
    fi

    summaryLog="$archiveDir/log.Allrun.${caseName}"
    [ -f "$summaryLog" ] || summaryLog="$PARAMETRIC_LOG_DIR/log.Allrun.${caseName}"

    workerLog="$PARAMETRIC_LOG_DIR/worker.${caseName}.log"

    ui_section "CASE $caseName"
    ui_kv "State" "${state:-unknown}"

    [ -n "$start" ] && ui_kv "Started" "$(format_case_time "$start")"
    [ -n "$end" ]   && ui_kv "Finished" "$(format_case_time "$end")"

    if [ -n "$elapsed" ] && [[ "$elapsed" =~ ^[0-9]+$ ]]; then
        ui_kv "Elapsed" "$(fmt_duration "$elapsed")"
    fi

    [ -d "$archiveDir" ] && ui_kv "Archive" "$archiveDir"
    [ -d "$workDir" ] && ui_kv "Work directory" "$workDir"
    ui_kv "Log" "$fullLog"

    # --------------------------------------------------
    # Log first, details after
    # --------------------------------------------------
    if [ -t 0 ]; then
        read -r -p "Show log? [Y/n]: " answer
        case "$answer" in
            n|N|no|NO) showLog=0 ;;
            *)         showLog=1 ;;
        esac
    else
        showLog=0
    fi

    if [ "$showLog" -eq 1 ]; then

        if [ "$state" == "RUNNING" ]; then

            ui_section "LIVE LOG (last 20 lines, Ctrl-C to stop)"
            echo "Following: $fullLog"

            trap ':' INT
            tail -n 20 -F "$fullLog"
            trap - INT

        elif [ -f "$fullLog" ]; then

            ui_section "LOG (last 20 lines)"
            tail -n 20 "$fullLog"

        else
            ui_warn "Log file not available: $fullLog"
        fi
    fi

    # --------------------------------------------------
    # paramDict values
    # --------------------------------------------------
    ui_section "PARAMDICT VALUES"

    if ensure_case_matrix && load_case_matrix 2>/dev/null; then
        if [ -n "${MATRIX_VALUES[$caseName]+x}" ]; then
            paramValues="${MATRIX_VALUES[$caseName]}"
            read -r -a values <<< "$paramValues"
            for ((i=0;i<${#paramNames[@]};i++)); do
                ui_kv "${paramNames[$i]}" "${values[$i]:-}"
            done
        else
            ui_warn "Case not present in caseMatrix.csv"
        fi
    else
        ui_warn "caseMatrix.csv not available"
    fi

    # --------------------------------------------------
    # Calculated values
    # --------------------------------------------------
    ui_section "CALCULATED VALUES"

    if [ -n "$tableRow" ] && [ ! -d "$workDir" ]; then

        IFS= read -r header < "paramDatabase/paramTable.csv"
        IFS=, read -r -a headerFields <<< "$header"
        IFS=, read -r -a rowFields <<< "$tableRow"

        local firstCalc=$(( 8 + ${#paramNames[@]} ))
        for ((i=firstCalc;i<${#headerFields[@]};i++)); do
            ui_kv "${headerFields[$i]}" "${rowFields[$i]:-}"
        done

    elif [ "$state" == "RUNNING" ] || [ -d "$workDir" ]; then

        # Do not compile codeStream just to inspect a running case.
        scriptFile="$workDir/calculationScript"
        [ -f "$scriptFile" ] || scriptFile="calculationScript"

        if [ -f "$scriptFile" ]; then
            mapfile -t calcKeys < <(calc_script_all_keys "$scriptFile")
            for ((i=0;i<${#calcKeys[@]};i++)); do
                value=$(calc_script_value "$scriptFile" "${calcKeys[$i]}")
                [ -n "$value" ] && ui_kv "${calcKeys[$i]}" "$value"
            done
            ui_info "Derived #calc values become available after the case finishes"
        fi

    else

        # Finished case without a table row: evaluate the script.
        scriptFile="$archiveDir/calculationScript"
        [ -f "$scriptFile" ] || scriptFile="calculationScript"

        if [ -f "$scriptFile" ]; then
            resolvedFile=$(mktemp /tmp/parametricCase.XXXXXX)
            if foamDictionary "$scriptFile" > "$resolvedFile" 2>/dev/null; then
                mapfile -t calcKeys < <(calc_script_all_keys "$scriptFile")
                for ((i=0;i<${#calcKeys[@]};i++)); do
                    value=$(calc_resolved_value "$resolvedFile" "${calcKeys[$i]}")
                    [ -z "$value" ] && value=$(calc_script_value "$scriptFile" "${calcKeys[$i]}")
                    ui_kv "${calcKeys[$i]}" "$value"
                done
            else
                ui_warn "Could not evaluate calculationScript with foamDictionary"
            fi
            rm -f "$resolvedFile"
        fi
    fi

    # --------------------------------------------------
    # Log paths
    # --------------------------------------------------
    ui_section "LOG FILES"

    [ -f "$fullLog" ] && ui_kv "Full log" "$fullLog"
    [ -f "$summaryLog" ] && ui_kv "Summary log" "$summaryLog"
    [ -f "$workerLog" ] && ui_kv "Worker log" "$workerLog"

    return 0
}
