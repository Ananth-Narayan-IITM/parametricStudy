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
    local caseNode=""
    local caseUser=""
    local caseIp=""
    local caseSshIp=""
    local caseIdentitySource=""
    local metaDict=""
    local key=""
    local j skip

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
        # status.txt accumulates one snapshot per run; use the latest entry.
        state=$(grep -E "^[[:space:]]+${caseName}[[:space:]]" "paramDatabase/status.txt" 2>/dev/null | \
            grep -oE 'DONE|FAILED|SKIPPED|QUEUED|RUNNING' | tail -1)
    fi

    if [ -z "$state" ] && [ -d "$archiveDir" ]; then
        state="ARCHIVED"
    fi

    # Timing and execution-identity fallback for finished cases.
    if [ -f "paramDatabase/paramTable.csv" ]; then
        tableRow=$(awk -F, -v c="$caseName" '$1==c {print; exit}' "paramDatabase/paramTable.csv")

        if [ -n "$tableRow" ]; then
            IFS= read -r header < "paramDatabase/paramTable.csv"
            IFS=, read -r -a headerFields <<< "$header"
            IFS=, read -r -a rowFields <<< "$tableRow"

            for ((i=0;i<${#headerFields[@]};i++)); do
                case "${headerFields[$i]}" in
                    node)
                        caseNode="${rowFields[$i]:-}"
                        ;;
                    user)
                        caseUser="${rowFields[$i]:-}"
                        ;;
                    ip)
                        caseIp="${rowFields[$i]:-}"
                        ;;
                    sshIp)
                        caseSshIp="${rowFields[$i]:-}"
                        ;;
                    identitySource)
                        caseIdentitySource="${rowFields[$i]:-}"
                        ;;
                    startTime)
                        if [ ! -f "$statusFile" ]; then start="${rowFields[$i]:-}"; fi
                        ;;
                    endTime)
                        if [ ! -f "$statusFile" ]; then end="${rowFields[$i]:-}"; fi
                        ;;
                    "elapsedTime (s)")
                        if [ ! -f "$statusFile" ]; then elapsed="${rowFields[$i]:-}"; fi
                        ;;
                esac
            done
        fi
    fi

    # Legacy tables may not have the identity columns yet.
    if [ -z "$caseNode" ] || [ -z "$caseUser" ] || [ -z "$caseIp" ] || \
       [ -z "$caseIdentitySource" ]; then
        for metaDict in "$archiveDir/system/paramDict" "$workDir/system/paramDict"; do
            [ -f "$metaDict" ] || continue

            [ -n "$caseNode" ] || \
                caseNode=$(foamDictionary "$metaDict" -entry node -value 2>/dev/null | tr -d '"')
            [ -n "$caseUser" ] || \
                caseUser=$(foamDictionary "$metaDict" -entry runUser -value 2>/dev/null | tr -d '"')
            [ -n "$caseIp" ] || \
                caseIp=$(foamDictionary "$metaDict" -entry nodeIp -value 2>/dev/null | tr -d '"')
            [ -n "$caseSshIp" ] || \
                caseSshIp=$(foamDictionary "$metaDict" -entry sshIp -value 2>/dev/null | tr -d '"')
            [ -n "$caseIdentitySource" ] || \
                caseIdentitySource=$(foamDictionary "$metaDict" -entry identitySource -value 2>/dev/null | tr -d '"')

            if [ -n "$caseNode" ] && [ -n "$caseUser" ] && [ -n "$caseIp" ] && \
               [ -n "$caseIdentitySource" ]; then
                break
            fi
        done
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

    [ -n "$caseNode" ] && ui_kv "Run node" "$caseNode"
    [ -n "$caseUser" ] && ui_kv "User" "$caseUser"
    [ -n "$caseIp" ] && ui_kv "IP" "$caseIp"
    [ -n "$caseSshIp" ] && ui_kv "SSH from" "$caseSshIp"
    [ -n "$caseIdentitySource" ] && ui_kv "Identity source" "$caseIdentitySource"

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

        # Everything that is not a metadata, timing, or parameter column
        # is a resolved calculationScript value.
        for ((i=0;i<${#headerFields[@]};i++)); do
            key="${headerFields[$i]}"

            skip=0
            case "$key" in
                caseName|studyType|runTag|runComment|authorNote|node|user|ip|sshIp|identitySource|startTime|endTime|"elapsedTime (s)")
                    skip=1
                    ;;
            esac

            if [ "$skip" -eq 0 ]; then
                for ((j=0;j<${#paramNames[@]};j++)); do
                    if [ "$key" == "${paramNames[$j]}" ]; then
                        skip=1
                        break
                    fi
                done
            fi

            [ "$skip" -eq 1 ] && continue

            ui_kv "$key" "${rowFields[$i]:-}"
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
