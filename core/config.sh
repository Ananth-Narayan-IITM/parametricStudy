#!/bin/bash

load_config() {

    PARAM_DICT="system/paramDict"
    SCRIPT_FILE="calculationScript"
    SCRIPT_BACKUP="${SCRIPT_FILE}.backup"

    DEBUG=${DEBUG:-0}

    if [ ! -f "$PARAM_DICT" ]; then
        ui_error "paramDict not found: $PARAM_DICT"
        exit 1
    fi

    if [ ! -f "$SCRIPT_FILE" ]; then
        ui_error "calculationScript not found: $SCRIPT_FILE"
        exit 1
    fi

    cp "$SCRIPT_FILE" "$SCRIPT_BACKUP"

    solver=$(foamDictionary "$PARAM_DICT" -entry solver -value)
    export processors=$(foamDictionary "$PARAM_DICT" -entry processors -value)
    prefix=$(foamDictionary "$PARAM_DICT" -entry prefix -value)

    runComment=$(foamDictionary "$PARAM_DICT" -entry runComment -value 2>/dev/null | tr -d '"')
    runTag=$(foamDictionary "$PARAM_DICT" -entry runTag -value 2>/dev/null | tr -d '"')
    authorNote=$(foamDictionary "$PARAM_DICT" -entry authorNote -value 2>/dev/null | tr -d '"')

    coreScreening=$(foamDictionary "$PARAM_DICT" -entry coreScreening -value 2>/dev/null)
    coreListRaw=$(foamDictionary "$PARAM_DICT" -entry coreList -value 2>/dev/null)
    optimalCore=$(foamDictionary "$PARAM_DICT" -entry optimalCore -value 2>/dev/null)

    coreScreening=${coreScreening:-false}
    coreList=($(echo "$coreListRaw" | tr -d '();'))

    availableCores=$(foamDictionary "$PARAM_DICT" -entry availableCores -value 2>/dev/null)
    maxConcurrentCases=$(foamDictionary "$PARAM_DICT" -entry maxConcurrentCases -value 2>/dev/null)
    statusRefresh=$(foamDictionary "$PARAM_DICT" -entry statusRefresh -value 2>/dev/null)

    availableCores=${availableCores:-$(nproc)}
    maxConcurrentCases=${maxConcurrentCases:-auto}
    statusRefresh=${statusRefresh:-1}

    if ! [[ "$statusRefresh" =~ ^[0-9]+$ ]]; then
        statusRefresh=1
    fi

    studyType=$(foamDictionary "$PARAM_DICT" -entry studyType -value)

    if [ "$studyType" == "parametricStudy" ]; then
        paramListRaw=$(foamDictionary "$PARAM_DICT" -entry parameters -value)
    else
        paramListRaw=$(foamDictionary "$PARAM_DICT" -entry meshParameters -value)
    fi

    paramNames=($(echo "$paramListRaw" | tr -d '();'))

    ui_section "Configuration"
    ui_kv "Solver" "$solver"
    ui_kv "Study type" "$studyType"
    ui_kv "Case prefix" "$prefix"
    ui_kv "Parameters" "${paramNames[*]}"
    ui_kv "Processors / case" "$processors"
    ui_kv "Available cores" "$availableCores"
    ui_kv "Concurrent cases" "$maxConcurrentCases"
    ui_kv "Status refresh" "${statusRefresh}s"

    if [ "$coreScreening" == "true" ]; then
        ui_kv "Core screening" "enabled"
        ui_kv "Core list" "${coreList[*]}"
        ui_kv "Optimal core" "${optimalCore:-auto}"
    fi
}
