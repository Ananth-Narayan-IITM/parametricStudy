#!/bin/bash

handle_existing_data() {

    dbDir="$CASE_DIR/paramDatabase"
    studyDir="$CASE_DIR/parametricStudy"
    coreScaleDir="$CASE_DIR/coreScalingLogs"

    if [ ! -d "$dbDir" ] && [ ! -d "$studyDir" ] && [ ! -d "$coreScaleDir" ]; then
        return
    fi

    ui_info "Existing parametric folders detected"

    case "$MODE" in
        --delete)
            ui_info "Deleting previous results"
            rm -rf "$dbDir" "$studyDir" "$coreScaleDir"
            ;;

        --append)
            ui_info "Appending to existing data"
            ;;

        --backup)
            ui_info "Creating automatic backup"

            backup_folder() {

                folder=$1
                [ ! -d "$folder" ] && return

                n=1
                while true; do
                    backupName="$CASE_DIR/[backup${n}]$(basename "$folder")"
                    if [ ! -d "$backupName" ]; then
                        mv "$folder" "$backupName"
                        ui_info "$(basename "$folder") -> $(basename "$backupName")"
                        break
                    fi
                    ((n++))
                done
            }

            backup_folder "$dbDir"
            backup_folder "$studyDir"
            ;;

        *)
            ui_error "Unknown mode: $MODE"
            echo "Valid modes:" >&2
            echo "  --delete" >&2
            echo "  --append" >&2
            echo "  --backup" >&2
            exit 1
            ;;
    esac

}

detect_append_index() {

    startIndex=1

    if [ "$MODE" == "--append" ]; then

        studyDir="parametricStudy"

        ui_debug "Checking existing cases in: $studyDir"
        ui_debug "Using prefix: $prefix"

        if [ -d "$studyDir" ]; then

            maxIndex=$(ls "$studyDir" 2>/dev/null | \
                grep -E "^${prefix}[0-9]+$" | \
                sed "s/^${prefix}//" | \
                sort -n | tail -1)

            ui_debug "maxIndex found: ${maxIndex:-none}"

            if [ -n "$maxIndex" ]; then
                startIndex=$((maxIndex + 1))
                ui_info "Append mode: continuing from case $startIndex"
            else
                ui_info "No previous cases found for prefix"
            fi
        fi
    fi

    caseCounter=$((startIndex - 1))
}

set_core_count() {

    core=$1

    if [ -z "$core" ]; then
        ui_error "set_core_count called with empty value"
        exit 1
    fi

    if ! [[ "$core" =~ ^[0-9]+$ ]]; then
        ui_error "Invalid core count: $core"
        exit 1
    fi

    if [ "$core" -eq 1 ]; then
        ui_info "Running in SERIAL mode"
        export RUN_PARALLEL=0
        export NP=1
    else
        ui_info "Running in PARALLEL with $core cores"
        export RUN_PARALLEL=1
        export NP="$core"
    fi
}
