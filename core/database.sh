#!/bin/bash

build_param_table() {

    dbDir="paramDatabase"
    outputFile="paramDatabase/paramTable.csv"

    ui_info "Creating parametric table from derived files"

    files=($(ls ${dbDir}/${prefix}[0-9]*.txt 2>/dev/null | grep -v "_mesh"))

    if [ ${#files[@]} -eq 0 ]; then
        ui_warn "No derived case files found"
        return
    fi

    # -----------------------------
    # HEADER
    # -----------------------------
    firstFile=${files[0]}

    header="caseName,studyType,runTag,runComment,authorNote,startTime,endTime,elapsedTime (s)"

    if [ "$studyType" == "gridIndependence" ]; then
        for p in "${paramNames[@]}"; do
            header="$header,$p"
        done
    fi

    while read -r key value rest; do

        if [[ "$key" == "FoamFile" || \
              "$key" == "version" || \
              "$key" == "format"  || \
              "$key" == "class"   || \
              "$key" == "object" ]]; then
            continue
        fi

        if [[ "$value" == *";" ]]; then
            header="$header,$key"
        fi

    done < "$firstFile"

    if [ -f "$outputFile" ]; then
        ui_info "Existing database found -> appending new cases"
    else
        echo "$header" > "$outputFile"
    fi

    # -----------------------------
    # ROWS
    # -----------------------------
    for f in "${files[@]}"; do

        caseName=$(basename "$f" .txt)
        timeFile="parametricLogs/${caseName}_time.txt"
        startTime=""
        endTime=""
        elapsed=""

        if [ -f "$timeFile" ]; then
            IFS="|" read startTime endTime elapsed < "$timeFile"
        fi

        row="$caseName,$studyType,$runTag,$runComment,$authorNote,$startTime,$endTime,$elapsed"

        # Mesh values
        if [ "$studyType" == "gridIndependence" ]; then
            meshFile="paramDatabase/${caseName}_mesh.txt"
            if [ -f "$meshFile" ]; then
                meshVals=$(cat "$meshFile")
                for val in $meshVals; do
                    row="$row,$val"
                done
            fi
        fi

        # Transport properties
        while read -r key value rest; do

            if [[ "$key" == "FoamFile" || \
                  "$key" == "version" || \
                  "$key" == "format"  || \
                  "$key" == "class"   || \
                  "$key" == "object" ]]; then
                continue
            fi

            if [[ "$value" == *";" ]]; then
                cleanValue=$(echo "$value" | tr -d ';')
                row="$row,$cleanValue"
            fi

        done < "$f"

        if ! grep -q "^${caseName}," "$outputFile" 2>/dev/null; then
            echo "$row" >> "$outputFile"
        fi

    done

    rm -f paramDatabase/*_mesh.txt

    ui_ok "Parametric table ready: $outputFile"
}

finalize_database() {

    ui_info "Consolidating derived database"

    mkdir -p paramDatabase

    local -a derived=()
    shopt -s nullglob
    derived=("${prefix}"*.txt)
    shopt -u nullglob

    [ ${#derived[@]} -gt 0 ] && mv "${derived[@]}" paramDatabase/

    build_param_table

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
