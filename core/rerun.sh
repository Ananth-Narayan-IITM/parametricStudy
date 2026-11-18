#!/bin/bash

# --------------------------------------------------
# Rerun selected cases
#
# Uses paramDatabase/caseMatrix.csv as the source of
# original parameter values.  Rerun always starts from
# the base case and replaces the archived result.
# --------------------------------------------------

prepare_rerun_cases() {

    local -a requested=("$@")
    local caseName
    local i

    if [ ${#requested[@]} -eq 0 ]; then
        ui_error "No case names supplied for rerun"
        return 1
    fi

    if ! ensure_case_matrix; then
        ui_error "Cannot build caseMatrix.csv (no matrix or compatible paramTable.csv)"
        return 1
    fi

    if ! load_case_matrix; then
        ui_error "Cannot read paramDatabase/caseMatrix.csv"
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

    CASE_NAMES=()
    CASE_VALUES=()

    for caseName in "${requested[@]}"; do

        if [ -z "${MATRIX_VALUES[$caseName]+x}" ]; then
            ui_error "Case not found in caseMatrix.csv: $caseName"
            return 1
        fi

        if [ -n "$prefix" ] && [[ "$caseName" != "$prefix"* ]]; then
            ui_error "Case name does not match prefix '$prefix': $caseName"
            return 1
        fi

        CASE_NAMES+=("$caseName")
        CASE_VALUES+=("${MATRIX_VALUES[$caseName]}")
    done

    return 0
}

run_rerun() {

    local caseName
    local i

    if ! prepare_rerun_cases "$@"; then
        return 1
    fi

    if is_true "$continueFromPrevious"; then
        ui_warn "Rerun always starts from the base case; continueFromPrevious is ignored"
        continueFromPrevious=false
    fi

    if is_true "$coreScreening"; then
        ui_error "rerun cannot be combined with coreScreening"
        return 1
    fi

    # Replace the old archived results and old transport-property dumps.
    for caseName in "${CASE_NAMES[@]}"; do
        rm -rf "$PARAMETRIC_STUDY_DIR/$caseName"
        rm -f "paramDatabase/${caseName}.txt"
        rm -f "${caseName}.txt"
    done

    ui_section "Rerun plan"
    ui_kv "Cases" "${#CASE_NAMES[@]}"
    ui_kv "Case names" "${CASE_NAMES[*]}"
    ui_kv "Source" "paramDatabase/caseMatrix.csv"
    ui_kv "Start from" "base case"
    ui_kv "Cores / case" "$processors"
    ui_kv "Concurrent cases" "$maxConcurrentCases"

    for ((i=0;i<${#CASE_NAMES[@]};i++)); do
        ui_kv "${CASE_NAMES[$i]}" "${CASE_VALUES[$i]}"
    done

    run_all_cases || return 1

    return 0
}
