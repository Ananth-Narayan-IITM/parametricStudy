#!/bin/bash

# --------------------------------------------------
# Parallel case scheduler
#
# Every case runs in its own isolated working copy.
# A case starts as soon as a slot is free, so no case
# waits for an entire batch to finish.
# --------------------------------------------------

prepare_parallel_workspace() {

    # Stale working copies, logs and status files must never
    # influence a new run.
    rm -rf "$PARAMETRIC_WORK_DIR"
    rm -rf "$PARAMETRIC_LOG_DIR"
    rm -rf "$PARAMETRIC_STATUS_DIR"

    mkdir -p "$PARAMETRIC_WORK_DIR" "$PARAMETRIC_LOG_DIR" "$PARAMETRIC_STATUS_DIR" || return 1
}

validate_core_budget() {

    if [ -z "$availableCores" ] || \
       ! [[ "$availableCores" =~ ^[0-9]+$ ]] || \
       [ "$availableCores" -le 0 ]; then
        ui_error "availableCores must be a positive integer in $PARAM_DICT"
        return 1
    fi

    if [ "$coreScreening" == "true" ]; then

        if [ ${#coreList[@]} -eq 0 ]; then
            ui_error "coreList is empty"
            return 1
        fi

        local core
        for core in "${coreList[@]}"; do
            if ! [[ "$core" =~ ^[0-9]+$ ]] || [ "$core" -le 0 ]; then
                ui_error "Invalid core count in coreList: $core"
                return 1
            fi
            if [ "$core" -gt "$availableCores" ]; then
                ui_error "coreList entry $core exceeds availableCores ($availableCores)"
                return 1
            fi
        done

        if [ "${coreList[0]}" -ne 1 ]; then
            ui_error "coreList must start with 1 (serial baseline for speedup)"
            return 1
        fi

    else

        if [ -z "$processors" ] || \
           ! [[ "$processors" =~ ^[0-9]+$ ]] || \
           [ "$processors" -le 0 ]; then
            ui_error "processors must be a positive integer in $PARAM_DICT"
            return 1
        fi

        if [ "$processors" -gt "$availableCores" ]; then
            ui_error "processors ($processors) exceeds availableCores ($availableCores)"
            return 1
        fi

        if [ "$maxConcurrentCases" != "auto" ]; then
            if ! [[ "$maxConcurrentCases" =~ ^[0-9]+$ ]] || \
               [ "$maxConcurrentCases" -le 0 ]; then
                ui_error "maxConcurrentCases must be 'auto' or a positive integer"
                return 1
            fi

            if [ $(( maxConcurrentCases * processors )) -gt "$availableCores" ]; then
                ui_error "maxConcurrentCases ($maxConcurrentCases) x processors ($processors) exceeds availableCores ($availableCores)"
                return 1
            fi
        fi
    fi
}

compute_max_parallel() {

    local total=$1
    local computed=$(( availableCores / processors ))
    local requested="$maxConcurrentCases"

    if [ "$computed" -lt 1 ]; then
        ui_error "availableCores ($availableCores) < processors ($processors)"
        return 1
    fi

    if [ "$requested" != "auto" ]; then
        if ! [[ "$requested" =~ ^[0-9]+$ ]] || [ "$requested" -lt 1 ]; then
            ui_error "maxConcurrentCases must be 'auto' or a positive integer (got: $requested)"
            return 1
        fi

        if [ $(( requested * processors )) -gt "$availableCores" ]; then
            ui_error "maxConcurrentCases ($requested) x processors ($processors) exceeds availableCores ($availableCores)"
            return 1
        fi

        computed=$requested
    fi

    if [ "$computed" -gt "$total" ]; then
        computed=$total
    fi

    printf '%s\n' "$computed"
}

prepare_case_workspace() {

    local workDir=$1
    local entry
    local base

    rm -rf "$workDir"
    mkdir -p "$workDir" || return 1

    shopt -s nullglob dotglob

    for entry in "$CASE_DIR"/*; do

        base=$(basename "$entry")

        case "$base" in
            parametricStudy|paramDatabase|parametricLogs|parametricWork|parametricStatus|coreScalingLogs|postProcessing|.git)
                continue
                ;;
            processor*|log.*)
                continue
                ;;
            \[backup*\]*)
                continue
                ;;
            0|0.orig)
                ;;
            [0-9]*)
                continue
                ;;
            "$prefix"[0-9]*.txt)
                continue
                ;;
        esac

        if ! cp -a "$entry" "$workDir/"; then
            shopt -u nullglob dotglob
            ui_error "Failed to copy '$entry' into $workDir"
            return 1
        fi
    done

    shopt -u nullglob dotglob

    # Always rebuild the mesh from the case's own mesh source.
    # This also guarantees that a stale polyMesh from an interrupted
    # previous run can never leak into a new case.
    rm -rf "$workDir/constant/polyMesh"

    return 0
}

run_case() {

    local caseName=$1
    local values=$2
    local workDir="$PARAMETRIC_WORK_DIR/$caseName"
    local rc=0

    ui_info "[START] $caseName"
    mark_case_running "$caseName"

    if ! prepare_case_workspace "$workDir"; then
        mark_case_finished "$caseName" 1
        ui_error "[FAIL] $caseName (workspace setup failed)"
        return 1
    fi

    (
        cd "$workDir" || exit 1

        export SCRIPT_FILE="calculationScript"
        export SCRIPT_BACKUP="${SCRIPT_FILE}.backup"

        cp "$SCRIPT_FILE" "$SCRIPT_BACKUP" || exit 1

        local -a valArray
        read -r -a valArray <<< "$values"

        if [ "${#valArray[@]}" -ne "${#paramNames[@]}" ]; then
            ui_error "Parameter count mismatch for $caseName"
            exit 1
        fi

        local i

        if [ "$studyType" == "parametricStudy" ]; then

            for ((i=0;i<${#paramNames[@]};i++)); do
                replace_param "${paramNames[$i]}" "${valArray[$i]}" || exit 1
            done

        elif [ "$studyType" == "gridIndependence" ]; then

            for ((i=0;i<${#paramNames[@]};i++)); do
                update_gmsh_parameter "${paramNames[$i]}" "${valArray[$i]}" || exit 1
            done

            mkdir -p "$CASE_DIR/paramDatabase" || exit 1
            printf '%s\n' "${valArray[*]}" > "$CASE_DIR/paramDatabase/${caseName}_mesh.txt" || exit 1

        else

            ui_error "Unknown studyType: $studyType"
            exit 1
        fi

        ui_info "Writing derived properties for $caseName"

        if ! foamDictionary constant/transportProperties > "$CASE_DIR/${caseName}.txt" 2>/dev/null; then
            ui_error "Could not write derived properties for $caseName"
            exit 1
        fi

        if [ ! -s "$CASE_DIR/${caseName}.txt" ]; then
            ui_error "Derived property file is empty for $caseName"
            exit 1
        fi

        export NP="$processors"
        export OMP_NUM_THREADS=1

        set_core_count "$processors" || exit 1

        local simRc=0
        local archiveRc=0

        run_simulation "$caseName" || simRc=$?

        # Preserve timing metadata in the base case before the
        # isolated workspace is removed.
        if [ -f "parametricLogs/${caseName}_time.txt" ]; then
            cp "parametricLogs/${caseName}_time.txt" \
                "$PARAMETRIC_LOG_DIR/${caseName}_time.txt" 2>/dev/null
        fi

        archive_case "$caseName" || archiveRc=$?

        if [ "$simRc" -ne 0 ] || [ "$archiveRc" -ne 0 ]; then
            exit 1
        fi

        exit 0
    )
    rc=$?

    if [ "$rc" -eq 0 ]; then
        rm -rf "$workDir"
        mark_case_finished "$caseName" 0
        ui_ok "[DONE] $caseName"
    else
        mark_case_finished "$caseName" "$rc"
        ui_error "[FAIL] $caseName (workspace kept: $workDir)"
    fi

    return "$rc"
}

report_case_status() {

    local failures=0
    local caseName
    local state
    local rc

    for caseName in "${CASE_NAMES[@]}"; do

        state=$(status_get "$caseName" state)
        rc=$(status_get "$caseName" rc)

        if [ -z "$state" ] || [ -z "$rc" ]; then
            ui_error "No status recorded for $caseName (worker may have been killed)"
            mkdir -p "$PARAMETRIC_STUDY_DIR/$caseName"
            cp "$PARAMETRIC_LOG_DIR/worker.${caseName}.log" \
                "$PARAMETRIC_STUDY_DIR/$caseName/" 2>/dev/null
            failures=$((failures + 1))
            continue
        fi

        if [ "$state" != "DONE" ]; then
            ui_error "Case failed: $caseName (state: $state, rc: $rc)"
            mkdir -p "$PARAMETRIC_STUDY_DIR/$caseName"
            cp "$PARAMETRIC_LOG_DIR/worker.${caseName}.log" \
                "$PARAMETRIC_STUDY_DIR/$caseName/" 2>/dev/null
            failures=$((failures + 1))
        fi
    done

    if [ "$failures" -gt 0 ]; then
        ui_error "$failures of ${#CASE_NAMES[@]} case(s) failed"
        return 1
    fi

    ui_ok "All ${#CASE_NAMES[@]} case(s) completed successfully"
    return 0
}

run_all_cases() {

    local total=${#CASE_NAMES[@]}
    local maxParallel
    local i
    local reportRc=0

    if [ "$total" -le 0 ]; then
        ui_error "No cases were generated"
        return 1
    fi

    prepare_parallel_workspace || return 1
    validate_core_budget || return 1

    maxParallel=$(compute_max_parallel "$total") || return 1

    STATUS_START=$(date +%s)
    init_case_statuses

    # With concurrent cases, let the OS distribute MPI ranks over all
    # available cores. This is an OpenMPI MCA setting and is ignored
    # by other MPI implementations.
    if [ "$maxParallel" -gt 1 ]; then
        export OMPI_MCA_hwloc_base_binding_policy="${OMPI_MCA_hwloc_base_binding_policy:-none}"
    fi

    ui_section "Execution plan"
    ui_kv "Total cases" "$total"
    ui_kv "Cores per case" "$processors"
    ui_kv "Available cores" "$availableCores"
    ui_kv "Concurrent cases" "$maxParallel"
    ui_kv "Core budget" "$(( maxParallel * processors )) / $availableCores"

    render_status_dashboard

    for ((i=0;i<total;i++)); do

        while [ "$(jobs -rp | wc -l)" -ge "$maxParallel" ]; do
            wait -n || true
        done

        ui_info "Launching ${CASE_NAMES[$i]}"
        run_case "${CASE_NAMES[$i]}" "${CASE_VALUES[$i]}" \
            > "$PARAMETRIC_LOG_DIR/worker.${CASE_NAMES[$i]}.log" 2>&1 &
    done

    if [ "$statusRefresh" -gt 0 ] && [ -t 1 ] && [ "${STATUS_LIVE:-1}" = "1" ]; then
        while [ "$(jobs -rp | wc -l)" -gt 0 ]; do
            sleep "$statusRefresh"
            render_status_dashboard
        done
    fi

    wait

    render_status_dashboard

    report_case_status || reportRc=$?

    if [ "$reportRc" -eq 0 ]; then
        rm -rf "$PARAMETRIC_WORK_DIR"
    fi

    return "$reportRc"
}
