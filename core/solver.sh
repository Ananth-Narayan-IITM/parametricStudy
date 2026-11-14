#!/bin/bash

run_simulation() {

    caseName=$1

    mkdir -p parametricLogs
    logFile="parametricLogs/log.Allrun.${caseName}"
    timeFile="parametricLogs/${caseName}_time.txt"

    # Keep the full command log outside the case directory.  Case
    # Allclean scripts often remove local log files.
    export RUN_LOG_FILE="$PARAMETRIC_LOG_DIR/full.${caseName}.log"

    ui_info "Running simulation for $caseName"

    # Ensure runtime cores are visible to Allrun
    NP=${NP:-1}

    # -----------------------------
    # Capture timing metadata
    # -----------------------------
    startTime=$(TZ="${LOG_TIMEZONE:-Asia/Kolkata}" date '+%Y-%m-%d %H:%M:%S')
    startEpoch=$(date +%s)

    bash ./Allrun > "$logFile" 2>&1
    runRc=$?

    endEpoch=$(date +%s)
    endTime=$(TZ="${LOG_TIMEZONE:-Asia/Kolkata}" date '+%Y-%m-%d %H:%M:%S')

    elapsed=$((endEpoch - startEpoch))

    echo "${startTime}|${endTime}|${elapsed}" > "$timeFile"

    if [ "$runRc" -eq 0 ]; then
        ui_ok "Completed $caseName in ${elapsed}s using $NP core(s)"
    else
        ui_error "Simulation failed for $caseName after ${elapsed}s"
    fi

    return "$runRc"
}
