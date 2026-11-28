#!/bin/bash

# --------------------------------------------------
# Persistent case matrix
#
# paramDatabase/caseMatrix.csv stores the exact
# parameter values submitted for each case.  It is the
# authoritative source for reruns.
# --------------------------------------------------

case_matrix_file() {
    printf '%s' "paramDatabase/caseMatrix.csv"
}


sync_append_case_matrix() {

    local file
    local caseName
    local tmp
    local -a dirs=()
    local -a studyCases=()

    file=$(case_matrix_file)
    [ -f "$file" ] || return 0

    load_case_matrix || return 0

    shopt -s nullglob
    dirs=("$PARAMETRIC_STUDY_DIR"/${prefix}[0-9]*)
    shopt -u nullglob

    for caseName in "${dirs[@]}"; do
        caseName=${caseName##*/}
        [ -n "${MATRIX_VALUES[$caseName]+x}" ] || continue
        studyCases+=("$caseName")
    done

    if [ ${#studyCases[@]} -gt 0 ]; then
        mapfile -t studyCases < <(printf '%s\n' "${studyCases[@]}" | sort -V)
    fi

    tmp="${file}.tmp.$$"
    {
        printf 'caseName'
        local i
        for ((i=0;i<${#paramNames[@]};i++)); do
            printf ',%s' "${paramNames[$i]}"
        done
        printf '\n'

        for caseName in "${studyCases[@]}"; do
            printf '%s,%s\n' "$caseName" "${MATRIX_VALUES[$caseName]// /,}"
        done
    } > "$tmp" && mv "$tmp" "$file"
}

write_case_matrix() {

    local file
    local i j
    local line

    file=$(case_matrix_file)
    mkdir -p paramDatabase || return 1

    if [ ! -f "$file" ] && [ -f "paramDatabase/paramTable.csv" ]; then
        ensure_case_matrix || {
            ui_error "Cannot migrate paramTable.csv to caseMatrix.csv"
            return 1
        }
    fi

    if [ "$MODE" == "--append" ]; then
        sync_append_case_matrix || return 1
    fi

    if [ ! -f "$file" ]; then
        {
            printf 'caseName'
            for ((i=0;i<${#paramNames[@]};i++)); do
                printf ',%s' "${paramNames[$i]}"
            done
            printf '\n'
        } > "$file" || return 1
    else
        local -a header
        IFS= read -r line < "$file" || return 1
        IFS=, read -r -a header <<< "$line"
        if [ ${#header[@]} -ne $(( ${#paramNames[@]} + 1 )) ]; then
            ui_error "caseMatrix.csv header does not match paramDict"
            return 1
        fi
        for ((i=0;i<${#paramNames[@]};i++)); do
            if [ "${header[$((i+1))]}" != "${paramNames[$i]}" ]; then
                ui_error "caseMatrix.csv column '${header[$((i+1))]}' does not match '${paramNames[$i]}'"
                return 1
            fi
        done
    fi

    for ((j=0;j<${#CASE_NAMES[@]};j++)); do
        printf '%s' "${CASE_NAMES[$j]}"
        local -a values
        read -r -a values <<< "${CASE_VALUES[$j]}"
        for ((i=0;i<${#paramNames[@]};i++)); do
            printf ',%s' "${values[$i]}"
        done
        printf '\n'
    done >> "$file" || return 1

    return 0
}

load_case_matrix() {

    local file
    local line
    local -a fields

    file=$(case_matrix_file)
    [ -f "$file" ] || return 1

    IFS= read -r line < "$file" || return 1
    IFS=, read -r -a fields <<< "$line"
    [ "${fields[0]}" == "caseName" ] || return 1

    local start=1
    if [ "${fields[1]:-}" == "tag" ]; then
        start=2
    fi

    MATRIX_PARAM_NAMES=("${fields[@]:$start}")
    MATRIX_CASES=()
    declare -gA MATRIX_VALUES=()
    declare -gA MATRIX_TAGS=()

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        IFS=, read -r -a fields <<< "$line"
        [ ${#fields[@]} -lt 1 ] && continue
        local caseName=${fields[0]}
        MATRIX_CASES+=("$caseName")
        MATRIX_VALUES[$caseName]="${fields[*]:$start}"
        if [ "$start" -eq 2 ]; then
            MATRIX_TAGS[$caseName]="${fields[1]:-}"
        fi
    done < <(tail -n +2 "$file")

    return 0
}

ensure_case_matrix() {

    local file
    local legacy
    local line
    local -a header fields
    local i j idx
    local -a indices=()

    file=$(case_matrix_file)
    [ -f "$file" ] && return 0

    legacy="paramDatabase/paramTable.csv"
    [ -f "$legacy" ] || return 1

    IFS= read -r line < "$legacy" || return 1
    IFS=, read -r -a header <<< "$line"

    for ((i=0;i<${#paramNames[@]};i++)); do
        idx=-1
        for ((j=0;j<${#header[@]};j++)); do
            if [ "${header[$j]}" == "${paramNames[$i]}" ]; then
                idx=$j
                break
            fi
        done
        [ "$idx" -lt 0 ] && return 1
        indices[$i]=$idx
    done

    {
        printf 'caseName'
        for ((i=0;i<${#paramNames[@]};i++)); do
            printf ',%s' "${paramNames[$i]}"
        done
        printf '\n'
    } > "$file" || return 1

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        IFS=, read -r -a fields <<< "$line"
        printf '%s' "${fields[0]}"
        for ((i=0;i<${#paramNames[@]};i++)); do
            printf ',%s' "${fields[${indices[$i]}]}"
        done
        printf '\n'
    done < <(tail -n +2 "$legacy") >> "$file" || return 1

    return 0
}
