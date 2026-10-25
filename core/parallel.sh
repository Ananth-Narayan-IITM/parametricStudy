#!/bin/bash

# --------------------------------------------------
# Parallel case scheduler
#
# Every case runs in its own isolated working copy.
# A case starts as soon as a slot is free, so no case
# waits for an entire batch to finish.
# --------------------------------------------------

declare -A CASE_REPORTED=()

report_case_result() {

    local caseName=$1

    status_load "$caseName"

    case "$ST_STATE" in
        DONE)
            ui_ok "Finished $caseName in $(fmt_duration "$ST_ELAPSED")"
            ;;
        FAILED)
            ui_error "Failed $caseName after $(fmt_duration "$ST_ELAPSED") (rc=$ST_RC)"
            ;;
        *)
            return 0
            ;;
    esac

    CASE_REPORTED[$caseName]=1
}

report_finished_cases() {

    local caseName

    for caseName in "${CASE_NAMES[@]}"; do

        [ -n "${CASE_REPORTED[$caseName]+x}" ] && continue

        status_load "$caseName"

        case "$ST_STATE" in
            DONE|FAILED)
                report_case_result "$caseName"
                ;;
        esac
    done
}

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

    if is_true "$continueFromPrevious"; then

        if is_true "$coreScreening"; then
            ui_error "continueFromPrevious cannot be combined with coreScreening"
            return 1
        fi

        if [ "$studyType" == "gridIndependence" ]; then
            ui_error "continueFromPrevious is not supported for gridIndependence"
            return 1
        fi

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

        return 0
    fi

    if is_true "$coreScreening"; then

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
    local sourceDir=${2:-$CASE_DIR}
    local keepMesh=${3:-0}
    local entry
    local base

    rm -rf "$workDir"
    mkdir -p "$workDir" || return 1

    shopt -s nullglob dotglob

    for entry in "$sourceDir"/*; do

        base=$(basename "$entry")

        case "$base" in
            parametricStudy|paramDatabase|parametricLogs|parametricWork|parametricStatus|coreScalingLogs|postProcessing|dynamicCode|.git)
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
            constant)
                # polyMesh is rebuilt from Mesh/ anyway, so copying it
                # only wastes I/O and disk space.
                mkdir -p "$workDir/constant"
                for sub in "$entry"/*; do
                    if [ "$(basename "$sub")" == "polyMesh" ] && [ "$keepMesh" -eq 0 ]; then
                        continue
                    fi
                    if ! copy_item "$sub" "$workDir/constant/"; then
                        shopt -u nullglob dotglob
                        ui_error "Failed to copy '$sub' into $workDir/constant"
                        return 1
                    fi
                done
                continue
                ;;
            Mesh)
                # The .msh file is regenerated by gmsh from the .geo source.
                mkdir -p "$workDir/Mesh"
                for sub in "$entry"/*; do
                    case "$(basename "$sub")" in
                        *.msh) continue ;;
                    esac
                    if ! copy_item "$sub" "$workDir/Mesh/"; then
                        shopt -u nullglob dotglob
                        ui_error "Failed to copy '$sub' into $workDir/Mesh"
                        return 1
                    fi
                done
                continue
                ;;
        esac

        if ! copy_item "$entry" "$workDir/"; then
            shopt -u nullglob dotglob
            ui_error "Failed to copy '$entry' into $workDir"
            return 1
        fi
    done

    shopt -u nullglob dotglob

    # Normal runs rebuild the mesh from the case's own mesh source.
    # Chained runs keep the previous mesh because the mesh is unchanged
    # throughout the study.
    if [ "$keepMesh" -eq 0 ]; then
        rm -rf "$workDir/constant/polyMesh"
    fi

    return 0
}

latest_time_dir() {

    local caseDir=$1

    find "$caseDir" -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?' \
        -printf '%f\n' 2>/dev/null | sort -g | tail -1
}

prepare_chained_workspace() {

    local workDir=$1
    local previousDir=$2
    local latest

    if [ ! -d "$previousDir" ]; then
        ui_error "Previous case not found: $previousDir"
        return 1
    fi

    latest=$(latest_time_dir "$previousDir")

    if [ -z "$latest" ] || [ "$latest" == "0" ]; then
        ui_error "Previous case has no completed time directory: $previousDir"
        return 1
    fi

    if ! prepare_case_workspace "$workDir" "$previousDir" 1; then
        return 1
    fi

    # Older archived cases may not contain the run scripts.
    for entry in Allrun AllrunSimple Allclean; do
        if [ ! -f "$workDir/$entry" ] && [ -f "$CASE_DIR/$entry" ]; then
            copy_item "$CASE_DIR/$entry" "$workDir/"
        fi
    done

    # Make the previous latest time the new 0.  controlDict
    # therefore keeps its existing startTime/endTime values.
    rm -rf "$workDir/0"
    if ! copy_item "$previousDir/$latest" "$workDir/0"; then
        ui_error "Failed to seed $workDir/0 from $previousDir/$latest"
        return 1
    fi

    rm -rf "$workDir/0/uniform"

    return 0
}

run_case() {

    local caseName=$1
    local values=$2
    local previousCase=${3:-}
    local workDir="$PARAMETRIC_WORK_DIR/$caseName"
    local rc=0

    ui_info "[START] $caseName"
    mark_case_running "$caseName"

    if [ -n "$previousCase" ]; then
        if ! prepare_chained_workspace "$workDir" "$PARAMETRIC_STUDY_DIR/$previousCase"; then
            mark_case_finished "$caseName" 1
            ui_error "[FAIL] $caseName (chained workspace setup failed)"
            return 1
        fi
    elif ! prepare_case_workspace "$workDir"; then
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

        status_load "$caseName"
        state=$ST_STATE
        rc=$ST_RC

        if [ "$state" == "SKIPPED" ]; then
            continue
        fi

        if [ -z "$state" ] || [ -z "$rc" ]; then
            ui_error "No status recorded for $caseName (worker may have been killed)"
            mkdir -p "$PARAMETRIC_STUDY_DIR/$caseName"
            cp "$PARAMETRIC_LOG_DIR/worker.${caseName}.log" \
                "$PARAMETRIC_STUDY_DIR/$caseName/" 2>/dev/null
            failures=$((failures + 1))
            continue
        fi

        if [ "$state" != "DONE" ]; then
            if [ -z "${CASE_REPORTED[$caseName]+x}" ]; then
                ui_error "Case failed: $caseName (state: $state, rc: $rc)"
            fi
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

    return 0
}

run_chained_cases() {

    local total=${#CASE_NAMES[@]}
    local i j
    local caseName
    local previous
    local rc=0

    prepare_parallel_workspace || return 1
    validate_core_budget || return 1

    STATUS_START=$(date +%s)
    init_case_statuses
    CASE_REPORTED=()

    ui_section "Execution plan"
    ui_kv "Mode" "chained (serial)"
    ui_kv "Continue from previous" "yes"
    ui_kv "Current" "0 running"
    ui_kv "Staged" "$total queued"
    ui_kv "Ran" "0 completed"
    ui_kv "Cores per case" "$processors"
    ui_kv "Concurrent cases" "1"
    ui_kv "Case logs" "$PARAMETRIC_LOG_DIR/"

    if is_true "$coreScreening"; then
        ui_error "continueFromPrevious cannot be combined with coreScreening"
        return 1
    fi

    if [ "$maxConcurrentCases" != "auto" ]; then
        ui_warn "maxConcurrentCases is ignored when continueFromPrevious is true"
    fi

    for ((i=0;i<total;i++)); do

        caseName=${CASE_NAMES[$i]}
        previous=""

        if [ "$i" -gt 0 ]; then
            previous=${CASE_NAMES[$((i-1))]}
        fi

        ui_info "Launching $caseName${previous:+ from $previous}"

        run_case "$caseName" "${CASE_VALUES[$i]}" "$previous" \
            > "$PARAMETRIC_LOG_DIR/worker.${caseName}.log" 2>&1
        rc=$?

        report_case_result "$caseName"

        if [ "$rc" -ne 0 ]; then
            for ((j=i+1;j<total;j++)); do
                mark_case_skipped "${CASE_NAMES[$j]}"
            done
            break
        fi
    done

    render_status_dashboard
    print_sweep_summary

    report_case_status || rc=1

    if [ "$rc" -eq 0 ]; then
        rm -rf "$PARAMETRIC_WORK_DIR"
    fi

    return "$rc"
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

    if is_true "$continueFromPrevious"; then
        run_chained_cases
        return $?
    fi

    prepare_parallel_workspace || return 1
    validate_core_budget || return 1

    maxParallel=$(compute_max_parallel "$total") || return 1

    STATUS_START=$(date +%s)
    init_case_statuses
    CASE_REPORTED=()

    # With concurrent cases, let the OS distribute MPI ranks over all
    # available cores. This is an OpenMPI MCA setting and is ignored
    # by other MPI implementations.
    if [ "$maxParallel" -gt 1 ]; then
        export OMPI_MCA_hwloc_base_binding_policy="${OMPI_MCA_hwloc_base_binding_policy:-none}"
    fi

    ui_section "Execution plan"
    ui_kv "Current" "0 running"
    ui_kv "Staged" "$total queued"
    ui_kv "Ran" "0 completed"
    ui_kv "Cores per case" "$processors"
    ui_kv "Available cores" "$availableCores"
    ui_kv "Concurrent cases" "$maxParallel"
    ui_kv "Core budget" "$(( maxParallel * processors )) / $availableCores"
    ui_kv "Case logs" "$PARAMETRIC_LOG_DIR/"

    for ((i=0;i<total;i++)); do

        while [ "$(jobs -rp | wc -l)" -ge "$maxParallel" ]; do
            wait -n || true
            report_finished_cases
        done

        ui_info "Launching ${CASE_NAMES[$i]}"
        run_case "${CASE_NAMES[$i]}" "${CASE_VALUES[$i]}" \
            > "$PARAMETRIC_LOG_DIR/worker.${CASE_NAMES[$i]}.log" 2>&1 &
    done

    wait
    report_finished_cases

    render_status_dashboard
    print_sweep_summary

    report_case_status || reportRc=$?

    if [ "$reportRc" -eq 0 ]; then
        rm -rf "$PARAMETRIC_WORK_DIR"
    fi

    return "$reportRc"
}
