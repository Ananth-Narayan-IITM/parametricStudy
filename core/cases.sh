#!/bin/bash

# --------------------------------------------------
# Case generation
#
# This module only builds the case matrix.  The cases
# are executed later by the parallel scheduler.
# --------------------------------------------------

declare -A CASE_SEEN=()

register_case() {

    local -a current_values=("$@")
    local details=""
    local key
    local i

    if [ "${#current_values[@]}" -ne "${#paramNames[@]}" ]; then
        ui_error "Parameter count mismatch: got ${#current_values[@]}, expected ${#paramNames[@]}"
        exit 1
    fi

    key="${current_values[*]}"
    if [ -n "${CASE_SEEN[$key]+x}" ]; then
        ui_warn "Skipping duplicate case: $key"
        return
    fi
    CASE_SEEN[$key]=1

    ((caseCounter++))
    caseName="${prefix}${caseCounter}"

    for ((i=0;i<${#paramNames[@]};i++)); do
        details+="${paramNames[$i]}=${current_values[$i]}  "
    done

    ui_case "$caseName" "$details"

    CASE_NAMES+=("$caseName")
    CASE_VALUES+=("${current_values[*]}")
}

generate_cases() {

    CASE_NAMES=()
    CASE_VALUES=()
    CASE_SEEN=()

    if foamDictionary "$PARAM_DICT" -entry sets >/dev/null 2>&1; then

        ui_info "Mode: user-defined sets"

        comboRaw=$(foamDictionary "$PARAM_DICT" -entry sets -value)
        mapfile -t combos < <(echo "$comboRaw" | grep -oE '\([^)]*\)')

        for combo in "${combos[@]}"; do

            values=$(echo "$combo" | tr -d '()')
            read -r -a valArray <<< "$values"

            register_case "${valArray[@]}"
        done

    else

        ui_info "Mode: full Cartesian combinations"

        declare -A paramValues

        for p in "${paramNames[@]}"; do
            raw=$(foamDictionary system/paramDict -entry "$p" -value)
            clean=$(echo "$raw" | tr -d '();')
            paramValues[$p]="$clean"
        done

        generate_cartesian 0
    fi
}

generate_cartesian() {

    local depth=$1
    shift
    local current_values=("$@")

    if [ "$depth" -eq "${#paramNames[@]}" ]; then

        register_case "${current_values[@]}"
        return
    fi

    local param="${paramNames[$depth]}"
    local val

    for val in ${paramValues[$param]}; do
        generate_cartesian $((depth+1)) "${current_values[@]}" "$val"
    done
}
