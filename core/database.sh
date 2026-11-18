#!/bin/bash

# --------------------------------------------------
# Case matrix and result table
#
# paramDatabase/caseMatrix.csv is the authoritative
# source of submitted parameter values.
#
# paramDatabase/paramTable.csv contains:
#   metadata + paramDict parameters + calculationScript
#   constants (excluding paramDict parameters).
# --------------------------------------------------

calc_script_all_keys() {

    local scriptFile=$1
    local line key value
    local p isParam

    [ -f "$scriptFile" ] || return 0

    while IFS= read -r line; do

        line=${line%%//*}
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+([^;]+)\; ]] || continue

        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}

        case "$key" in
            version|format|class|location|object|arch|note) continue ;;
        esac

        isParam=0
        for p in "${paramNames[@]}"; do
            if [ "$key" == "$p" ]; then
                isParam=1
                break
            fi
        done
        [ "$isParam" -eq 1 ] && continue

        printf '%s\n' "$key"

    done < "$scriptFile" | awk '!seen[$0]++'
}

calc_resolved_value() {

    local resolvedFile=$1
    local wanted=$2
    local line key value

    [ -f "$resolvedFile" ] || return 0

    while IFS= read -r line; do

        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+([^;]+)\; ]] || continue

        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}

        if [ "$key" == "$wanted" ]; then
            printf '%s' "$value"
            return 0
        fi

    done < "$resolvedFile"
}

calc_script_keys() {

    local scriptFile=$1
    local line key value
    local p isParam

    [ -f "$scriptFile" ] || return 0

    while IFS= read -r line; do

        line=${line%%//*}
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+([^;]+)\; ]] || continue

        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}

        case "$key" in
            version|format|class|location|object|arch|note) continue ;;
        esac

        # Expressions are not table constants.
        case "$value" in
            *'#calc'*|*'$'*) continue ;;
        esac

        isParam=0
        for p in "${paramNames[@]}"; do
            if [ "$key" == "$p" ]; then
                isParam=1
                break
            fi
        done
        [ "$isParam" -eq 1 ] && continue

        printf '%s\n' "$key"

    done < "$scriptFile" | awk '!seen[$0]++'
}

calc_script_value() {

    local scriptFile=$1
    local wanted=$2
    local line key value

    [ -f "$scriptFile" ] || return 0

    while IFS= read -r line; do

        line=${line%%//*}
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+([^;]+)\; ]] || continue

        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}

        case "$key" in
            version|format|class|location|object|arch|note) continue ;;
        esac

        if [ "$key" == "$wanted" ]; then
            printf '%s' "$value"
            return 0
        fi

    done < "$scriptFile"
}

load_old_timing() {

    local outputFile=$1
    local caseName studyType runTag runComment authorNote start end elapsed rest
    local header line
    local -a fields=()
    local i

    declare -gA OLD_START=()
    declare -gA OLD_END=()
    declare -gA OLD_ELAPSED=()
    declare -gA OLD_ROW=()
    declare -gA OLD_INDEX=()

    [ -f "$outputFile" ] || return 0

    IFS= read -r header < "$outputFile" || return 0
    IFS=, read -r -a fields <<< "$header"
    for ((i=0;i<${#fields[@]};i++)); do
        OLD_INDEX["${fields[$i]}"]=$i
    done

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        IFS=, read -r caseName studyType runTag runComment authorNote start end elapsed rest <<< "$line"
        [ "$caseName" == "caseName" ] && continue
        OLD_START[$caseName]="$start"
        OLD_END[$caseName]="$end"
        OLD_ELAPSED[$caseName]="$elapsed"
        OLD_ROW[$caseName]="$line"
    done < <(tail -n +2 "$outputFile")
}

build_param_table() {

    local outputFile="paramDatabase/paramTable.csv"
    local header
    local caseName
    local scriptFile
    local timeFile
    local start end elapsed
    local row
    local line
    local value=""
    local calcFile=""
    local -a values=()
    local -a calcKeys=()
    local -a oldFields=()
    local oldRow=""
    local idx
    local i

    ui_info "Creating parametric table from case matrix"

    if ! ensure_case_matrix; then
        ui_warn "No case matrix or compatible existing table found"
        return 1
    fi

    if ! load_case_matrix; then
        ui_warn "Could not read paramDatabase/caseMatrix.csv"
        return 1
    fi

    if [ ${#MATRIX_PARAM_NAMES[@]} -ne ${#paramNames[@]} ]; then
        ui_error "caseMatrix.csv parameter count does not match paramDict"
        return 1
    fi

    for ((i=0;i<${#paramNames[@]};i++)); do
        if [ "${MATRIX_PARAM_NAMES[$i]}" != "${paramNames[$i]}" ]; then
            ui_error "caseMatrix.csv parameter '${MATRIX_PARAM_NAMES[$i]}' does not match '${paramNames[$i]}'"
            return 1
        fi
    done

    mapfile -t calcKeys < <(calc_script_all_keys "calculationScript")
    load_old_timing "$outputFile"

    header="caseName,studyType,runTag,runComment,authorNote,startTime,endTime,elapsedTime (s)"

    for ((i=0;i<${#paramNames[@]};i++)); do
        header="$header,${paramNames[$i]}"
    done

    for ((i=0;i<${#calcKeys[@]};i++)); do
        header="$header,${calcKeys[$i]}"
    done

    : > "$outputFile"
    printf '%s\n' "$header" >> "$outputFile"

    for caseName in "${MATRIX_CASES[@]}"; do

        read -r -a values <<< "${MATRIX_VALUES[$caseName]}"

        timeFile="parametricLogs/${caseName}_time.txt"
        start=""
        end=""
        elapsed=""

        if [ -f "$timeFile" ]; then
            IFS="|" read start end elapsed < "$timeFile"
        else
            start="${OLD_START[$caseName]:-}"
            end="${OLD_END[$caseName]:-}"
            elapsed="${OLD_ELAPSED[$caseName]:-}"
        fi

        scriptFile="parametricStudy/${caseName}/calculationScript"
        [ -f "$scriptFile" ] || scriptFile="calculationScript"

        calcFile="parametricLogs/${caseName}_calc.txt"
        oldFields=()
        oldRow="${OLD_ROW[$caseName]:-}"
        [ -n "$oldRow" ] && IFS=, read -r -a oldFields <<< "$oldRow"

        row="$caseName,$studyType,$runTag,$runComment,$authorNote,$start,$end,$elapsed"

        for ((i=0;i<${#paramNames[@]};i++)); do
            row="$row,${values[$i]:-}"
        done

        for ((i=0;i<${#calcKeys[@]};i++)); do
            value=$(calc_resolved_value "$calcFile" "${calcKeys[$i]}")

            if [ -z "$value" ] && [ -n "$oldRow" ]; then
                idx=${OLD_INDEX["${calcKeys[$i]}"]:-}
                if [ -n "$idx" ]; then
                    value="${oldFields[$idx]:-}"
                fi
            fi

            [ -z "$value" ] && value=$(calc_script_value "$scriptFile" "${calcKeys[$i]}")
            row="$row,$value"
        done

        printf '%s\n' "$row" >> "$outputFile"

    done

    # The per-case transport-property text files are no longer part of
    # the database.
    rm -f paramDatabase/${prefix}[0-9]*.txt
    rm -f paramDatabase/*_mesh.txt

    ui_ok "Parametric table ready: $outputFile"
}

rebuild_param_table() {
    build_param_table
}

finalize_database() {

    ui_info "Consolidating derived database"

    mkdir -p paramDatabase

    # Old transport-property dumps from previous versions.
    rm -f ${prefix}[0-9]*.txt

    build_param_table

    if [ -f "parametricLogs/run.log" ]; then
        cp "parametricLogs/run.log" "paramDatabase/run.log"
        ui_kv "Run log" "paramDatabase/run.log"
    fi

    if [ -d "parametricLogs" ]; then
        ui_info "Removing temporary parametricLogs directory"
        rm -rf parametricLogs
    fi

    if [ -f "parametricStatus/dashboard.txt" ]; then
        cp "parametricStatus/dashboard.txt" "paramDatabase/status.txt"
    fi

    if [ -d "parametricStatus" ]; then
        ui_debug "Removing temporary parametricStatus directory"
        rm -rf parametricStatus
    fi

    ui_ok "Database ready at: paramDatabase/"
}
