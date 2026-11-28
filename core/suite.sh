#!/bin/bash

# --------------------------------------------------
# Tagged studies / suite controller
#
# Results stay inside tags/<tag>/, but cases from all
# selected tags share one global queue and one global
# case-number sequence.
# --------------------------------------------------

SUITE_ROOT="$CASE_DIR/parametricSuite"

suite_root() {
    printf '%s' "$SUITE_ROOT"
}

suite_is_enabled() {
    local value
    value=$(foamDictionary "$CASE_DIR/system/paramDict" -entry tag -value 2>/dev/null | tr -d '"[:space:]')
    case "${value,,}" in
        true|1|yes|on) return 0 ;;
        *)             return 1 ;;
    esac
}

suite_engine() {
    printf '%s/../allParametric' "$PARAMETRIC_CORE_DIR"
}

suite_tag_value() {
    local tag=$1
    local key=$2
    foamDictionary "$CASE_DIR/tags/$tag/system/paramDict" -entry "$key" -value 2>/dev/null | tr -d '"'
}

suite_tag_prefix() {
    suite_tag_value "$1" prefix
}

suite_tag_processors() {
    suite_tag_value "$1" processors
}

suite_tag_true() {
    local value
    value=$(suite_tag_value "$1" "$2" | tr -d '[:space:]')
    case "${value,,}" in
        true|1|yes|on) return 0 ;;
        *)             return 1 ;;
    esac
}

suite_lock() {
    mkdir -p "$SUITE_ROOT" || return 1

    if ! command -v flock >/dev/null 2>&1; then
        ui_error "flock is required for suite locking"
        return 1
    fi

    exec 9>"$SUITE_ROOT/suite.lock" || return 1

    if ! flock -n 9; then
        ui_error "Another suite operation is running"
        ui_kv "Lock" "$SUITE_ROOT/suite.lock"
        return 1
    fi

    return 0
}

suite_unlock() {
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
}

suite_read_tags() {
    local raw
    local tag

    SUITE_TAGS=()

    raw=$(foamDictionary "$CASE_DIR/system/paramDict" -entry tagCases -value 2>/dev/null)
    if [[ "$raw" == *"("* ]]; then
        raw=$(printf '%s' "$raw" | grep -oE '\([^)]*\)' | tr -d '();')
    else
        raw=$(printf '%s' "$raw" | tr -d '();')
    fi

    for tag in $raw; do
        [ -z "$tag" ] && continue
        SUITE_TAGS+=("$tag")
    done

    if [ ${#SUITE_TAGS[@]} -eq 0 ]; then
        ui_error "tag is enabled but tagCases is empty"
        return 1
    fi

    if [ ${#TAG_FILTER[@]} -gt 0 ]; then
        local -a filtered=()
        for tag in "${SUITE_TAGS[@]}"; do
            local wanted=0
            local f
            for f in "${TAG_FILTER[@]}"; do
                [ "$tag" == "$f" ] && wanted=1
            done
            [ "$wanted" -eq 1 ] && filtered+=("$tag")
        done
        if [ ${#filtered[@]} -eq 0 ]; then
            ui_error "None of the requested tags are present in tagCases"
            return 1
        fi
        SUITE_TAGS=("${filtered[@]}")
    fi

    return 0
}

suite_validate_tags() {
    local tag
    local firstPrefix=""
    local firstProcessors=""
    local prefix processors

    declare -A SUITE_SEEN=()
    declare -gA SUITE_PARAM_LIST=()

    for tag in "${SUITE_TAGS[@]}"; do

        case "$tag" in
            ""|.*|*/*)
                ui_error "Invalid tag name: '$tag'"
                return 1
                ;;
        esac

        if [ -n "${SUITE_SEEN[$tag]+x}" ]; then
            ui_error "Duplicate tag in tagCases: $tag"
            return 1
        fi
        SUITE_SEEN[$tag]=1

        if [ ! -d "$CASE_DIR/tags/$tag" ]; then
            ui_error "Tag directory not found: tags/$tag"
            return 1
        fi

        if [ ! -f "$CASE_DIR/tags/$tag/system/paramDict" ]; then
            ui_error "Tag paramDict not found: tags/$tag/system/paramDict"
            return 1
        fi

        if [ ! -f "$CASE_DIR/tags/$tag/calculationScript" ]; then
            ui_error "Tag calculationScript not found: tags/$tag/calculationScript"
            return 1
        fi

        if suite_tag_true "$tag" tag; then
            ui_error "Tag '$tag' contains tag=true; tags must not enable tagging"
            return 1
        fi

        if suite_tag_true "$tag" continueFromPrevious; then
            ui_error "Tag '$tag': continueFromPrevious is not supported in suite mode"
            return 1
        fi

        if suite_tag_true "$tag" coreScreening; then
            ui_error "Tag '$tag': coreScreening is not supported in suite mode"
            return 1
        fi

        prefix=$(suite_tag_prefix "$tag")
        processors=$(suite_tag_processors "$tag")

        if [ -z "$prefix" ]; then
            ui_error "Tag '$tag' has no prefix"
            return 1
        fi

        SUITE_PARAM_LIST[$tag]=$(suite_tag_value "$tag" parameters | tr -d '();')

        if ! [[ "$processors" =~ ^[0-9]+$ ]] || [ "$processors" -lt 1 ]; then
            ui_error "Tag '$tag' has invalid processors: '$processors'"
            return 1
        fi

        if [ -z "$firstPrefix" ]; then
            firstPrefix=$prefix
            firstProcessors=$processors
        else
            if [ "$prefix" != "$firstPrefix" ]; then
                ui_error "All tags must use the same prefix (expected '$firstPrefix', got '$prefix' in '$tag')"
                return 1
            fi
            if [ "$processors" -ne "$firstProcessors" ]; then
                ui_error "Option A requires the same processors per case (expected $firstProcessors, got $processors in '$tag')"
                return 1
            fi
        fi
    done

    SUITE_PREFIX=$firstPrefix
    SUITE_PROCESSORS=$firstProcessors

    return 0
}

suite_highest_number() {
    local prefix=$1
    local dir base number max=0

    shopt -s nullglob
    for dir in "$CASE_DIR"/tags/*/parametricStudy/"${prefix}"[0-9]*; do
        [ -d "$dir" ] || continue
        base=${dir##*/}
        number=${base#"$prefix"}
        [[ "$number" =~ ^[0-9]+$ ]] || continue
        [ "$number" -gt "$max" ] && max=$number
    done
    shopt -u nullglob

    printf '%s' "$max"
}

suite_highest_number_main() {
    local prefix=$1
    local dir base number max=0

    shopt -s nullglob
    for dir in "$CASE_DIR"/parametricStudy/"${prefix}"[0-9]*; do
        [ -d "$dir" ] || continue
        base=${dir##*/}
        number=${base#"$prefix"}
        [[ "$number" =~ ^[0-9]+$ ]] || continue
        [ "$number" -gt "$max" ] && max=$number
    done
    shopt -u nullglob

    printf '%s' "$max"
}

suite_backup_dir() {
    local dir=$1
    local name=$2
    local n=1

    [ -d "$dir/$name" ] || return 0

    while [ -e "$dir/[backup$n]$name" ]; do
        n=$((n + 1))
    done

    mv "$dir/$name" "$dir/[backup$n]$name"
}

suite_prepare_tag() {
    local tag=$1
    local tagDir="$CASE_DIR/tags/$tag"

    case "$MODE" in
        --delete)
            rm -rf "$tagDir/parametricStudy" "$tagDir/paramDatabase" "$tagDir/coreScalingLogs"
            ;;
        --backup)
            suite_backup_dir "$tagDir" parametricStudy
            suite_backup_dir "$tagDir" paramDatabase
            suite_backup_dir "$tagDir" coreScalingLogs
            ;;
        --append)
            ;;
        *)
            ;;
    esac

    rm -rf "$tagDir/parametricWork" "$tagDir/parametricLogs" "$tagDir/parametricStatus"
    mkdir -p "$tagDir/parametricWork" "$tagDir/parametricLogs" "$tagDir/parametricStatus" || return 1
}

suite_prepare_tags() {
    local tag
    for tag in "${SUITE_TAGS[@]}"; do
        suite_prepare_tag "$tag" || return 1
    done
}

suite_generate_tag_cases() {
    local tag=$1
    local start=$2
    local queueFile=$3
    local tagDir="$CASE_DIR/tags/$tag"
    local genLog="$SUITE_ROOT/logs/generate.$tag.log"

    mkdir -p "$SUITE_ROOT/logs"

    (
        cd "$tagDir" || exit 1

        CASE_DIR="$tagDir"
        PARAMETRIC_STUDY_DIR="$tagDir/parametricStudy"
        PARAMETRIC_WORK_DIR="$tagDir/parametricWork"
        PARAMETRIC_LOG_DIR="$tagDir/parametricLogs"
        PARAMETRIC_STATUS_DIR="$tagDir/parametricStatus"
        export PARAMETRIC_START_INDEX="$start"
        export PARAMETRIC_TAGGED_CHILD=1
        export PARAMETRIC_TAG="$tag"

        load_config >"$genLog" 2>&1 || exit 1
        detect_append_index "$MODE" >>"$genLog" 2>&1 || exit 1
        generate_cases >>"$genLog" 2>&1 || exit 1

        : > "$queueFile"
        local i
        for ((i=0;i<${#CASE_NAMES[@]};i++)); do
            printf '%s\t%s\n' "${CASE_NAMES[$i]}" "${CASE_VALUES[$i]}" >> "$queueFile"
        done
    )

    return $?
}

suite_build_queue() {
    local tag
    local line caseName values
    local count maxCount=0
    local i key

    declare -gA SUITE_COUNTS=()
    declare -A SUITE_LINES=()
    SUITE_Q_TAG=()
    SUITE_Q_CASE=()
    SUITE_Q_VALUES=()

    for tag in "${SUITE_TAGS[@]}"; do
        count=0
        if [ -f "$SUITE_ROOT/queue.$tag.tmp" ]; then
            while IFS=$'\t' read -r caseName values; do
                [ -z "$caseName" ] && continue
                key="$tag|$count"
                SUITE_LINES["$key"]="$caseName"$'\t'"$values"
                count=$((count + 1))
            done < "$SUITE_ROOT/queue.$tag.tmp"
        fi
        SUITE_COUNTS[$tag]=$count
        [ "$count" -gt "$maxCount" ] && maxCount=$count
    done

    for ((i=0;i<maxCount;i++)); do
        for tag in "${SUITE_TAGS[@]}"; do
            [ "$i" -ge "${SUITE_COUNTS[$tag]:-0}" ] && continue
            key="$tag|$i"
            line="${SUITE_LINES[$key]:-}"
            [ -z "$line" ] && continue
            IFS=$'\t' read -r caseName values <<< "$line"
            SUITE_Q_TAG+=("$tag")
            SUITE_Q_CASE+=("$caseName")
            SUITE_Q_VALUES+=("$values")
        done
    done

    {
        printf 'tag,caseName,state\n'
        for ((i=0;i<${#SUITE_Q_TAG[@]};i++)); do
            printf '%s,%s,QUEUED\n' "${SUITE_Q_TAG[$i]}" "${SUITE_Q_CASE[$i]}"
        done
    } > "$SUITE_ROOT/queue.csv"
}

suite_case_number() {
    local caseName=$1
    local number
    number=${caseName#"$SUITE_PREFIX"}
    [[ "$number" =~ ^[0-9]+$ ]] && printf '%s' "$number"
}

suite_rebuild_case_index() {
    local tag dir base number tmp
    tmp="$SUITE_ROOT/caseIndex.csv.tmp"

    {
        printf 'tag,caseName,number\n'
        shopt -s nullglob
        for tag in "$CASE_DIR"/tags/*; do
            [ -d "$tag" ] || continue
            for dir in "$tag"/parametricStudy/"${SUITE_PREFIX}"[0-9]*; do
                [ -d "$dir" ] || continue
                base=${dir##*/}
                number=${base#"$SUITE_PREFIX"}
                [[ "$number" =~ ^[0-9]+$ ]] || continue
                printf '%s,%s,%s\n' "${tag##*/}" "$base" "$number"
            done
        done
        shopt -u nullglob
    } | sort -t, -k3,3n > "$tmp"

    mv "$tmp" "$SUITE_ROOT/caseIndex.csv"
}

suite_available_cores() {
    local cores maxCases
    cores=$(foamDictionary "$CASE_DIR/system/paramDict" -entry availableCores -value 2>/dev/null | tr -d '[:space:]')
    maxCases=$(foamDictionary "$CASE_DIR/system/paramDict" -entry maxConcurrentCases -value 2>/dev/null | tr -d '[:space:]')

    if ! [[ "$cores" =~ ^[0-9]+$ ]] || [ "$cores" -lt 1 ]; then
        ui_error "Tagged mode requires a valid availableCores in the main paramDict"
        return 1
    fi

    if [ "$cores" -lt "$SUITE_PROCESSORS" ]; then
        ui_error "availableCores ($cores) is less than processors per case ($SUITE_PROCESSORS)"
        return 1
    fi

    SUITE_MAX_PARALLEL=$((cores / SUITE_PROCESSORS))

    if [ "$maxCases" != "auto" ] && [ -n "$maxCases" ]; then
        if ! [[ "$maxCases" =~ ^[0-9]+$ ]] || [ "$maxCases" -lt 1 ]; then
            ui_error "Invalid maxConcurrentCases: $maxCases"
            return 1
        fi
        [ "$maxCases" -lt "$SUITE_MAX_PARALLEL" ] && SUITE_MAX_PARALLEL=$maxCases
    fi

    [ "$SUITE_MAX_PARALLEL" -lt 1 ] && SUITE_MAX_PARALLEL=1
    if [ "${#SUITE_Q_TAG[@]}" -lt "$SUITE_MAX_PARALLEL" ]; then
        SUITE_MAX_PARALLEL=${#SUITE_Q_TAG[@]}
    fi

    return 0
}

suite_init_tag_statuses() {
    local i tag caseName

    for ((i=0;i<${#SUITE_Q_TAG[@]};i++)); do
        tag=${SUITE_Q_TAG[$i]}
        caseName=${SUITE_Q_CASE[$i]}
        PARAMETRIC_STATUS_DIR="$CASE_DIR/tags/$tag/parametricStatus" \
            status_set "$caseName" QUEUED
    done
}

suite_update_tag_status() {
    local tag=$1
    local i done=0 failed=0 running=0 queued=0
    local caseName state file

    for ((i=0;i<${#SUITE_Q_TAG[@]};i++)); do
        [ "${SUITE_Q_TAG[$i]}" == "$tag" ] || continue
        caseName=${SUITE_Q_CASE[$i]}
        PARAMETRIC_STATUS_DIR="$CASE_DIR/tags/$tag/parametricStatus" \
            status_load "$caseName"

        case "$ST_STATE" in
            DONE)    done=$((done + 1)) ;;
            FAILED)  failed=$((failed + 1)) ;;
            RUNNING) running=$((running + 1)) ;;
            *)       queued=$((queued + 1)) ;;
        esac
    done

    SUITE_TAG_DONE[$tag]=$done
    SUITE_TAG_FAILED[$tag]=$failed

    file="$SUITE_ROOT/tags/$tag.status"
    mkdir -p "$SUITE_ROOT/tags"
    {
        printf 'tag=%s\n' "$tag"
        printf 'cases=%s\n' "${SUITE_COUNTS[$tag]:-0}"
        printf 'done=%s\n' "$done"
        printf 'failed=%s\n' "$failed"
        printf 'running=%s\n' "$running"
        printf 'queued=%s\n' "$queued"
        printf 'state=%s\n' "$([ "$failed" -gt 0 ] && echo FAILED || echo RUNNING)"
        printf 'firstCase=%s\n' "$(suite_first_last_case "$tag" first)"
        printf 'lastCase=%s\n' "$(suite_first_last_case "$tag" last)"
    } > "$file"
}

suite_write_tag_final_status() {
    local tag=$1
    local total=${SUITE_COUNTS[$tag]:-0}
    local done=${SUITE_TAG_DONE[$tag]:-0}
    local failed=${SUITE_TAG_FAILED[$tag]:-0}
    local state=INCOMPLETE

    if [ "$failed" -gt 0 ] && [ "$done" -eq 0 ]; then
        state=FAILED
    elif [ "$failed" -gt 0 ]; then
        state=PARTIAL
    elif [ "$done" -eq "$total" ]; then
        state=DONE
    fi

    mkdir -p "$SUITE_ROOT/tags"
    {
        printf 'tag=%s\n' "$tag"
        printf 'cases=%s\n' "$total"
        printf 'done=%s\n' "$done"
        printf 'failed=%s\n' "$failed"
        printf 'running=0\n'
        printf 'queued=0\n'
        printf 'state=%s\n' "$state"
        printf 'firstCase=%s\n' "$(suite_first_last_case "$tag" first)"
        printf 'lastCase=%s\n' "$(suite_first_last_case "$tag" last)"
    } > "$SUITE_ROOT/tags/$tag.status"
}

suite_first_last_case() {
    local wantedTag=$1
    local which=$2
    local i caseName first="" last=""

    for ((i=0;i<${#SUITE_Q_TAG[@]};i++)); do
        [ "${SUITE_Q_TAG[$i]}" == "$wantedTag" ] || continue
        caseName=${SUITE_Q_CASE[$i]}
        [ -z "$first" ] && first=$caseName
        last=$caseName
    done

    if [ "$which" == "first" ]; then
        printf '%s' "$first"
    else
        printf '%s' "$last"
    fi
}

suite_launch_case() {
    local tag=$1
    local caseName=$2
    local values=$3
    local tagDir="$CASE_DIR/tags/$tag"

    (
        cd "$tagDir" || exit 1

        CASE_DIR="$tagDir"
        PARAMETRIC_STUDY_DIR="$tagDir/parametricStudy"
        PARAMETRIC_WORK_DIR="$tagDir/parametricWork"
        PARAMETRIC_LOG_DIR="$tagDir/parametricLogs"
        PARAMETRIC_STATUS_DIR="$tagDir/parametricStatus"
        export PARAMETRIC_TAGGED_CHILD=1
        export PARAMETRIC_TAG="$tag"

        load_config >/dev/null 2>&1 || exit 1
        run_case "$caseName" "$values"
    ) > "$tagDir/parametricLogs/worker.${caseName}.log" 2>&1 &
}

suite_run_queue() {
    local i=0
    local active=0
    local total=${#SUITE_Q_TAG[@]}
    local reportAt=0

    if [ "$SUITE_MAX_PARALLEL" -gt 1 ]; then
        export OMPI_MCA_hwloc_base_binding_policy="${OMPI_MCA_hwloc_base_binding_policy:-none}"
    fi

    while [ "$i" -lt "$total" ] || [ "$active" -gt 0 ]; do

        while [ "$active" -lt "$SUITE_MAX_PARALLEL" ] && [ "$i" -lt "$total" ]; do
            suite_launch_case \
                "${SUITE_Q_TAG[$i]}" \
                "${SUITE_Q_CASE[$i]}" \
                "${SUITE_Q_VALUES[$i]}"
            active=$((active + 1))
            i=$((i + 1))
        done

        if [ "$active" -gt 0 ]; then
            wait -n || true
            active=$((active - 1))
            reportAt=$((reportAt + 1))
            if [ "$reportAt" -ge 5 ]; then
                local tag
                for tag in "${SUITE_TAGS[@]}"; do
                    suite_update_tag_status "$tag"
                done
                reportAt=0
            fi
        fi
    done

    local tag
    for tag in "${SUITE_TAGS[@]}"; do
        suite_update_tag_status "$tag"
    done
}

suite_tag_failed_count() {
    local tag=$1
    local i caseName failed=0

    for ((i=0;i<${#SUITE_Q_TAG[@]};i++)); do
        [ "${SUITE_Q_TAG[$i]}" == "$tag" ] || continue
        caseName=${SUITE_Q_CASE[$i]}
        PARAMETRIC_STATUS_DIR="$CASE_DIR/tags/$tag/parametricStatus" \
            status_load "$caseName"
        [ "$ST_STATE" == "FAILED" ] && failed=$((failed + 1))
    done

    printf '%s' "$failed"
}

suite_finalize_tag() {
    local tag=$1
    local tagDir="$CASE_DIR/tags/$tag"
    local failed

    [ "${SUITE_COUNTS[$tag]:-0}" -eq 0 ] && return 0

    failed=$(suite_tag_failed_count "$tag")

    if [ "$failed" -gt 0 ] && [ "${SUITE_SAVE_FAILED_TAGS:-0}" -eq 0 ]; then
        ui_warn "Tag $tag has $failed failed case(s); database not finalized"
        return 0
    fi

    (
        cd "$tagDir" || exit 1
        CASE_DIR="$tagDir"
        PARAMETRIC_STUDY_DIR="$tagDir/parametricStudy"
        PARAMETRIC_WORK_DIR="$tagDir/parametricWork"
        PARAMETRIC_LOG_DIR="$tagDir/parametricLogs"
        PARAMETRIC_STATUS_DIR="$tagDir/parametricStatus"
        export PARAMETRIC_TAGGED_CHILD=1
        export PARAMETRIC_TAG="$tag"

        load_config >"$SUITE_ROOT/logs/finalize.$tag.log" 2>&1 || exit 1

        # Build the per-tag status dashboard before finalize copies it.
        CASE_NAMES=()
        CASE_VALUES=()
        if load_case_matrix 2>/dev/null; then
            local c
            for c in "${MATRIX_CASES[@]}"; do
                CASE_NAMES+=("$c")
                CASE_VALUES+=("${MATRIX_VALUES[$c]}")
            done
        fi

        # Cases finalized in an earlier run have no parametricStatus files.
        # Recreate their state from the old result table before rendering.
        if [ -f paramDatabase/paramTable.csv ]; then
            while IFS=$'\x1f' read -r c cstate creason cexit; do
                [ -z "$c" ] && continue
                [ -f "$PARAMETRIC_STATUS_DIR/${c}.status" ] && continue
                [ -z "$cstate" ] && continue
                status_set "$c" "$cstate" "" "" "" "$cexit" "$creason"
            done < <(
                awk -F, '
                    NR==1 {
                        for (i=1; i<=NF; i++) {
                            if ($i=="status") s=i
                            if ($i=="reason") r=i
                            if ($i=="exitCode") e=i
                        }
                    }
                    NR>1 { print $1 "\037" $s "\037" $r "\037" $e }
                ' paramDatabase/paramTable.csv
            )
        fi

        render_status_dashboard >>"$SUITE_ROOT/logs/finalize.$tag.log" 2>&1 || true

        finalize_database >>"$SUITE_ROOT/logs/finalize.$tag.log" 2>&1 || exit 1
    )

    if [ $? -eq 0 ]; then
        rm -rf "$tagDir/parametricWork"
        ui_ok "Finalized tag $tag"
    else
        ui_error "Failed to finalize tag $tag"
        return 1
    fi
}

suite_write_summary() {
    local tag failed done total state
    local summary="$SUITE_ROOT/summary.csv"

    {
        printf 'tag,cases,done,failed,status,firstCase,lastCase\n'
        for tag in "${SUITE_TAGS[@]}"; do
            total=${SUITE_COUNTS[$tag]:-0}
            done=${SUITE_TAG_DONE[$tag]:-0}
            failed=${SUITE_TAG_FAILED[$tag]:-0}
            if [ "$failed" -gt 0 ] && [ "$done" -eq 0 ]; then
                state=FAILED
            elif [ "$failed" -gt 0 ]; then
                state=PARTIAL
            elif [ "$done" -eq "$total" ]; then
                state=DONE
            else
                state=INCOMPLETE
            fi
            printf '%s,%s,%s,%s,%s,%s,%s\n' \
                "$tag" "$total" "$done" "$failed" "$state" \
                "$(suite_first_last_case "$tag" first)" \
                "$(suite_first_last_case "$tag" last)"
        done
    } > "$summary"
}

suite_tag_counts_from_table() {
    local tag=$1
    local table="$CASE_DIR/tags/$tag/paramDatabase/paramTable.csv"
    local done=0 failed=0

    if [ -f "$table" ]; then
        read -r done failed < <(
            awk -F, '
                NR==1 {
                    for (i=1; i<=NF; i++) if ($i=="status") c=i
                }
                NR>1 && c {
                    if ($c=="DONE") d++
                    else if ($c=="FAILED") f++
                }
                END { print d+0, f+0 }
            ' "$table"
        )
        printf '%s %s\n' "$done" "$failed"
        return 0
    fi

    if [ -f "$SUITE_ROOT/tags/$tag.status" ]; then
        done=0
        failed=0
        while IFS='=' read -r key value; do
            case "$key" in
                done) done=$value ;;
                failed) failed=$value ;;
            esac
        done < "$SUITE_ROOT/tags/$tag.status"
        printf '%s %s\n' "$done" "$failed"
        return 0
    fi

    printf '0 0\n'
}

suite_write_summary_all() {
    local summary="$SUITE_ROOT/summary.csv"
    local index="$SUITE_ROOT/caseIndex.csv"
    local tag caseName number state
    local -A total=() done=() failed=() first=() last=()

    if [ ! -f "$index" ]; then
        suite_rebuild_case_index
    fi

    while IFS=, read -r tag caseName number; do
        [ "$tag" == "tag" ] && continue
        [ -z "$tag" ] && continue
        total[$tag]=$(( ${total[$tag]:-0} + 1 ))
        [ -z "${first[$tag]:-}" ] && first[$tag]=$caseName
        last[$tag]=$caseName
    done < "$index"

    for tag in "${!total[@]}"; do
        read -r tdone tfailed < <(suite_tag_counts_from_table "$tag")
        done[$tag]=$tdone
        failed[$tag]=$tfailed

        if [ -f "$SUITE_ROOT/tags/$tag.status" ]; then
            local sdone=0 sfailed=0 skey svalue
            while IFS='=' read -r skey svalue; do
                case "$skey" in
                    done) sdone=$svalue ;;
                    failed) sfailed=$svalue ;;
                esac
            done < "$SUITE_ROOT/tags/$tag.status"
            if [ "${sfailed:-0}" -gt 0 ]; then
                done[$tag]=$sdone
                failed[$tag]=$sfailed
            fi
        fi

        if [ "${failed[$tag]}" -gt 0 ] && [ "${done[$tag]}" -eq 0 ]; then
            state=FAILED
        elif [ "${failed[$tag]}" -gt 0 ]; then
            state=PARTIAL
        elif [ "${done[$tag]}" -eq "${total[$tag]}" ]; then
            state=DONE
        else
            state=INCOMPLETE
        fi

        mkdir -p "$SUITE_ROOT/tags"
        {
            printf 'tag=%s\n' "$tag"
            printf 'cases=%s\n' "${total[$tag]}"
            printf 'done=%s\n' "${done[$tag]}"
            printf 'failed=%s\n' "${failed[$tag]}"
            printf 'running=0\n'
            printf 'queued=0\n'
            printf 'state=%s\n' "$state"
            printf 'firstCase=%s\n' "${first[$tag]}"
            printf 'lastCase=%s\n' "${last[$tag]}"
        } > "$SUITE_ROOT/tags/$tag.status"

        printf '%s,%s,%s,%s,%s,%s,%s\n' \
            "$tag" "${total[$tag]}" "${done[$tag]}" "${failed[$tag]}" \
            "$state" "${first[$tag]}" "${last[$tag]}"
    done | sort > "$summary.tmp"

    {
        printf 'tag,cases,done,failed,status,firstCase,lastCase\n'
        cat "$summary.tmp"
    } > "$summary"
    rm -f "$summary.tmp"
}

suite_print_case_table() {
    local i j tag caseName details
    local -a names=()
    local -a vals=()

    ui_section "Suite cases"
    printf '  %-12s %-14s %s\n' "Tag" "Case" "Parameters"

    for ((i=0;i<${#SUITE_Q_TAG[@]};i++)); do
        tag=${SUITE_Q_TAG[$i]}
        caseName=${SUITE_Q_CASE[$i]}
        read -r -a names <<< "${SUITE_PARAM_LIST[$tag]:-}"
        read -r -a vals <<< "${SUITE_Q_VALUES[$i]}"
        details=""
        for ((j=0;j<${#names[@]};j++)); do
            [ -n "$details" ] && details+=" "
            details+="${names[$j]}=${vals[$j]:-}"
        done
        printf '  %-12s %-14s %s\n' "$tag" "$caseName" "$details"
    done
}

suite_run() {
    local tag
    local start next maxInTag
    local tagQueue
    local suiteRc=0

    suite_lock || return 1
    trap 'suite_unlock' EXIT

    if ! suite_read_tags; then
        suite_unlock
        return 1
    fi

    if ! suite_validate_tags; then
        suite_unlock
        return 1
    fi

    mkdir -p "$SUITE_ROOT/logs" "$SUITE_ROOT/tags"
    declare -gA SUITE_COUNTS=()
    SUITE_Q_TAG=()
    SUITE_Q_CASE=()
    SUITE_Q_VALUES=()

    if ! suite_prepare_tags; then
        suite_unlock
        return 1
    fi

    start=$(suite_highest_number "$SUITE_PREFIX")
    next=$((start + 1))

    for tag in "${SUITE_TAGS[@]}"; do
        tagQueue="$SUITE_ROOT/queue.$tag.tmp"
        rm -f "$tagQueue"
        if ! suite_generate_tag_cases "$tag" "$next" "$tagQueue"; then
            ui_error "Case generation failed for tag $tag"
            suite_unlock
            return 1
        fi
        maxInTag=$start
        if [ -f "$tagQueue" ]; then
            local caseName values number
            while IFS=$'\t' read -r caseName values; do
                number=${caseName#"$SUITE_PREFIX"}
                [[ "$number" =~ ^[0-9]+$ ]] || continue
                [ "$number" -gt "$maxInTag" ] && maxInTag=$number
            done < "$tagQueue"
        fi
        next=$((maxInTag + 1))
    done

    suite_build_queue
    if ! suite_available_cores; then
        suite_unlock
        return 1
    fi

    suite_init_tag_statuses
    suite_rebuild_case_index

    ui_section "Suite plan"
    ui_kv "Tags" "${SUITE_TAGS[*]}"
    ui_kv "Cases" "${#SUITE_Q_TAG[@]}"
    ui_kv "Processors / case" "$SUITE_PROCESSORS"
    ui_kv "Concurrent cases" "$SUITE_MAX_PARALLEL"
    if [ ${#SUITE_Q_CASE[@]} -gt 0 ]; then
        ui_kv "First case" "${SUITE_Q_CASE[0]}"
        ui_kv "Last case" "${SUITE_Q_CASE[$((${#SUITE_Q_CASE[@]} - 1))]}"
    else
        ui_kv "Cases" "none"
    fi

    SUITE_SAVE_FAILED_TAGS=0
    if [ "${SAVE_ON_FAILURE:-0}" -eq 1 ]; then
        SUITE_SAVE_FAILED_TAGS=1
    fi

    declare -gA SUITE_TAG_DONE=()
    declare -gA SUITE_TAG_FAILED=()

    suite_print_case_table

    suite_run_queue

    for tag in "${SUITE_TAGS[@]}"; do
        suite_update_tag_status "$tag"
    done

    if [ "${SUITE_SAVE_FAILED_TAGS:-0}" -eq 0 ] && [ -t 0 ]; then
        local totalFailed=0 t
        for t in "${SUITE_TAGS[@]}"; do
            [ "${SUITE_TAG_FAILED[$t]:-0}" -gt 0 ] && totalFailed=$((totalFailed + 1))
        done
        if [ "$totalFailed" -gt 0 ]; then
            local answer
            read -r -p "Some tags have failed cases. Write partial databases for them? [y/N]: " answer
            case "$answer" in y|Y|yes|YES) SUITE_SAVE_FAILED_TAGS=1 ;; esac
        fi
    fi

    for tag in "${SUITE_TAGS[@]}"; do
        suite_finalize_tag "$tag" || true
        suite_write_tag_final_status "$tag"
    done

    suite_rebuild_case_index
    suite_write_summary_all

    local highest
    highest=$(suite_highest_number "$SUITE_PREFIX")

    {
        printf 'prefix=%s\n' "$SUITE_PREFIX"
        printf 'lastCase=%s\n' "$highest"
        printf 'nextCase=%s\n' "$((highest + 1))"
    } > "$SUITE_ROOT/sequence"

    ui_section "Suite summary"
    ui_kv "Tags" "${SUITE_TAGS[*]}"
    ui_kv "Highest case" "${SUITE_PREFIX}${highest}"
    ui_kv "Next case" "${SUITE_PREFIX}$((highest + 1))"
    ui_kv "Summary" "$SUITE_ROOT/summary.csv"

    for tag in "${SUITE_TAGS[@]}"; do
        [ "${SUITE_TAG_FAILED[$tag]:-0}" -gt 0 ] && suiteRc=1
    done

    suite_unlock
    trap - EXIT
    return "$suiteRc"
}

suite_resolve_case() {
    local query=$1
    local tag=""
    local caseName=""

    if [[ "$query" == */* ]]; then
        tag=${query%%/*}
        caseName=${query#*/}
        if [ ! -d "$CASE_DIR/tags/$tag/parametricStudy/$caseName" ]; then
            return 1
        fi
        printf '%s\t%s\n' "$tag" "$caseName"
        return 0
    fi

    local matches=0
    local d
    shopt -s nullglob
    for d in "$CASE_DIR"/tags/*/parametricStudy/"$query"; do
        [ -d "$d" ] || continue
        tag=$(basename "$(dirname "$(dirname "$d")")")
        caseName=$(basename "$d")
        matches=$((matches + 1))
    done
    shopt -u nullglob

    if [ "$matches" -ne 1 ]; then
        return 1
    fi

    printf '%s\t%s\n' "$tag" "$caseName"
}

suite_delete_case_from_tag() {
    local tag=$1
    local caseName=$2
    local tagDir="$CASE_DIR/tags/$tag"
    local matrix="$tagDir/paramDatabase/caseMatrix.csv"

    if [[ "$caseName" == */* ]] || [[ "$caseName" == *..* ]]; then
        ui_error "Unsafe case name: $caseName"
        return 1
    fi

    rm -rf "$tagDir/parametricStudy/$caseName"
    rm -f "$tagDir/parametricStatus/${caseName}.status"
    rm -f "$tagDir"/parametricLogs/*"${caseName}"* 2>/dev/null || true

    if [ -f "$matrix" ]; then
        awk -F, -v c="$caseName" 'NR==1 || $1 != c' \
            "$matrix" > "${matrix}.tmp" && mv "${matrix}.tmp" "$matrix"
    fi

    if [ -f "$SUITE_ROOT/queue.csv" ]; then
        awk -F, -v t="$tag" -v c="$caseName" \
            'NR==1 || !($1==t && $2==c)' \
            "$SUITE_ROOT/queue.csv" > "$SUITE_ROOT/queue.csv.tmp" && \
            mv "$SUITE_ROOT/queue.csv.tmp" "$SUITE_ROOT/queue.csv"
    fi

    mkdir -p "$SUITE_ROOT"
    if [ ! -f "$SUITE_ROOT/deletedCases.csv" ]; then
        printf 'caseName,tag,deletedAt,reason\n' > "$SUITE_ROOT/deletedCases.csv"
    fi
    printf '%s,%s,%s,%s\n' \
        "$caseName" "$tag" "$(date '+%Y-%m-%d %H:%M:%S')" "user request" \
        >> "$SUITE_ROOT/deletedCases.csv"

    # Rebuild this tag's result table.
    (
        cd "$tagDir" || exit 1
        CASE_DIR="$tagDir"
        PARAMETRIC_STUDY_DIR="$tagDir/parametricStudy"
        PARAMETRIC_WORK_DIR="$tagDir/parametricWork"
        PARAMETRIC_LOG_DIR="$tagDir/parametricLogs"
        PARAMETRIC_STATUS_DIR="$tagDir/parametricStatus"
        export PARAMETRIC_TAGGED_CHILD=1
        export PARAMETRIC_TAG="$tag"
        load_config >/dev/null 2>&1 || exit 1
        build_param_table >>/dev/null 2>&1 || exit 1
    )

    return $?
}

suite_delete_cases_main() {
    local query caseName matrix
    local -a queries=("$@")

    suite_lock || return 1
    trap 'suite_unlock' EXIT

    for query in "${queries[@]}"; do
        caseName=$query
        if [[ "$caseName" == */* ]] || [[ "$caseName" == *..* ]]; then
            ui_error "Unsafe case name: $caseName"
            suite_unlock
            return 1
        fi
        if [ ! -d "$CASE_DIR/parametricStudy/$caseName" ]; then
            ui_error "Case not found: $caseName"
            suite_unlock
            return 1
        fi
    done

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        for query in "${queries[@]}"; do
            ui_kv "$query" "main study"
        done
        suite_unlock
        trap - EXIT
        return 0
    fi

    if [ "${CLEAN_YES:-0}" -eq 0 ] && [ ! -t 0 ]; then
        ui_error "Case deletion needs confirmation; use --yes"
        suite_unlock
        return 1
    fi

    if [ "${CLEAN_YES:-0}" -eq 0 ] && [ -t 0 ]; then
        ui_section "Delete cases"
        for query in "${queries[@]}"; do
            ui_kv "$query" "main study"
        done
        local answer
        read -r -p "Delete these cases and update their databases? [y/N]: " answer
        case "$answer" in
            y|Y|yes|YES) ;;
            *) ui_info "Aborted"; suite_unlock; return 1 ;;
        esac
    fi

    matrix="$CASE_DIR/paramDatabase/caseMatrix.csv"

    for query in "${queries[@]}"; do
        caseName=$query
        rm -rf "$CASE_DIR/parametricStudy/$caseName"
        rm -f "$CASE_DIR/parametricStatus/${caseName}.status"
        rm -f "$CASE_DIR"/parametricLogs/*"${caseName}"* 2>/dev/null || true

        if [ -f "$matrix" ]; then
            awk -F, -v c="$caseName" 'NR==1 || $1 != c' \
                "$matrix" > "${matrix}.tmp" && mv "${matrix}.tmp" "$matrix"
        fi
        ui_ok "Deleted $caseName"
    done

    (
        cd "$CASE_DIR" || exit 1
        CASE_DIR="$CASE_DIR"
        PARAMETRIC_STUDY_DIR="$CASE_DIR/parametricStudy"
        PARAMETRIC_WORK_DIR="$CASE_DIR/parametricWork"
        PARAMETRIC_LOG_DIR="$CASE_DIR/parametricLogs"
        PARAMETRIC_STATUS_DIR="$CASE_DIR/parametricStatus"
        load_config >/dev/null 2>&1 || exit 1
        build_param_table >>/dev/null 2>&1 || exit 1
    )

    suite_unlock
    trap - EXIT
    return 0
}

suite_delete_cases() {
    local query
    local -a queries=("$@")
    local -a resolvedTags=()
    local -a resolvedCases=()
    local tag caseName line

    [ ${#queries[@]} -eq 0 ] && {
        ui_error "No cases supplied to --delete-cases"
        return 1
    }

    if ! suite_is_enabled; then
        suite_delete_cases_main "${queries[@]}"
        return $?
    fi

    suite_lock || return 1
    trap 'suite_unlock' EXIT

    if ! suite_read_tags; then
        suite_unlock
        return 1
    fi
    if ! suite_validate_tags; then
        suite_unlock
        return 1
    fi

    for query in "${queries[@]}"; do
        line=$(suite_resolve_case "$query") || {
            ui_error "Case not found or ambiguous: $query"
            suite_unlock
            return 1
        }
        IFS=$'\t' read -r tag caseName <<< "$line"
        resolvedTags+=("$tag")
        resolvedCases+=("$caseName")
    done

    if [ "${DRY_RUN:-0}" -eq 0 ] && [ "${CLEAN_YES:-0}" -eq 0 ] && [ ! -t 0 ]; then
        ui_error "Case deletion needs confirmation; use --yes"
        suite_unlock
        return 1
    fi

    if [ "${DRY_RUN:-0}" -eq 0 ] && [ "${CLEAN_YES:-0}" -eq 0 ] && [ -t 0 ]; then
        ui_section "Delete cases"
        local i
        for ((i=0;i<${#resolvedCases[@]};i++)); do
            ui_kv "${resolvedCases[$i]}" "${resolvedTags[$i]}"
        done
        local answer
        read -r -p "Delete these cases and update their databases? [y/N]: " answer
        case "$answer" in
            y|Y|yes|YES) ;;
            *) ui_info "Aborted"; suite_unlock; return 1 ;;
        esac
    fi

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        for ((i=0;i<${#resolvedCases[@]};i++)); do
            ui_kv "${resolvedCases[$i]}" "${resolvedTags[$i]}"
        done
        suite_unlock
        trap - EXIT
        return 0
    fi

    for ((i=0;i<${#resolvedCases[@]};i++)); do
        if ! suite_delete_case_from_tag "${resolvedTags[$i]}" "${resolvedCases[$i]}"; then
            ui_error "Failed to delete ${resolvedCases[$i]} from ${resolvedTags[$i]}"
            suite_unlock
            return 1
        fi
        ui_ok "Deleted ${resolvedCases[$i]} from ${resolvedTags[$i]}"
    done

    suite_rebuild_case_index
    suite_write_summary_all

    if [ -n "${SUITE_PREFIX:-}" ]; then
        local highest
        highest=$(suite_highest_number "$SUITE_PREFIX")
        {
            printf 'prefix=%s\n' "$SUITE_PREFIX"
            printf 'lastCase=%s\n' "$highest"
            printf 'nextCase=%s\n' "$((highest + 1))"
        } > "$SUITE_ROOT/sequence"
    fi

    suite_unlock
    trap - EXIT
    return 0
}

suite_reset_sequence() {
    local prefix highest

    suite_lock || return 1
    trap 'suite_unlock' EXIT

    if ! suite_read_tags 2>/dev/null; then
        SUITE_TAGS=()
    fi

    if [ ${#SUITE_TAGS[@]} -gt 0 ]; then
        prefix=$(suite_tag_prefix "${SUITE_TAGS[0]}")
        highest=$(suite_highest_number "$prefix")
    else
        prefix=$(foamDictionary "$CASE_DIR/system/paramDict" -entry prefix -value 2>/dev/null | tr -d '"')
        highest=$(suite_highest_number_main "$prefix")
    fi

    mkdir -p "$SUITE_ROOT"
    {
        printf 'prefix=%s\n' "$prefix"
        printf 'lastCase=%s\n' "$highest"
        printf 'nextCase=%s\n' "$((highest + 1))"
    } > "$SUITE_ROOT/sequence"

    ui_kv "Highest case" "${prefix}${highest}"
    ui_kv "Next case" "${prefix}$((highest + 1))"

    suite_unlock
    trap - EXIT
    return 0
}

suite_status() {
    local file tag
    if [ -d "$SUITE_ROOT/tags" ]; then
        for file in "$SUITE_ROOT"/tags/*.status; do
            [ -f "$file" ] || continue
            tag=$(basename "$file" .status)
            ui_section "TAG $tag"
            cat "$file"
        done
    fi
    [ -f "$SUITE_ROOT/summary.csv" ] && {
        ui_section "SUITE SUMMARY"
        cat "$SUITE_ROOT/summary.csv"
    }
    return 0
}

suite_rerun() {
    local query line tag caseName
    suite_lock || return 1
    trap 'suite_unlock' EXIT
    for query in "$@"; do
        line=$(suite_resolve_case "$query") || {
            ui_error "Case not found or ambiguous: $query"
            suite_unlock
            return 1
        }
        IFS=$'\t' read -r tag caseName <<< "$line"
        PARAMETRIC_TAG="$tag" "$(suite_engine)" "$CASE_DIR/tags/$tag" --rerun "$caseName" || {
            suite_unlock
            return 1
        }
    done
    suite_unlock
    trap - EXIT
    return 0
}

suite_case() {
    local query=$1 line tag caseName
    line=$(suite_resolve_case "$query") || {
        ui_error "Case not found or ambiguous: $query"
        return 1
    }
    IFS=$'\t' read -r tag caseName <<< "$line"
    PARAMETRIC_TAG="$tag" "$(suite_engine)" "$CASE_DIR/tags/$tag" --case "$caseName"
}

suite_clean() {
    local tag scope=individual answer

    suite_lock || return 1
    trap 'suite_unlock' EXIT

    if ! suite_read_tags; then
        suite_unlock
        return 1
    fi

    if [ -t 0 ]; then
        echo "Cleanup scope:"
        echo "  1) whole tag: remove generated folders for all selected tags"
        echo "  2) individual tag: current per-tag cleanup"
        read -r -p "Choose [1/2] (default 2): " answer
        [ "$answer" == "1" ] && scope=whole
    elif [ "${CLEAN_YES:-0}" -eq 1 ]; then
        scope=whole
    else
        ui_error "Cleanup needs confirmation; use --yes for whole-tag cleanup"
        suite_unlock
        return 1
    fi

    if [ "$scope" == "whole" ]; then
        if [ "${CLEAN_YES:-0}" -eq 0 ]; then
            read -r -p "Remove generated result folders for all selected tags? [y/N]: " answer
            case "$answer" in
                y|Y|yes|YES) ;;
                *) ui_info "Aborted"; suite_unlock; return 1 ;;
            esac
        fi

        for tag in "${SUITE_TAGS[@]}"; do
            rm -rf \
                "$CASE_DIR/tags/$tag/parametricStudy" \
                "$CASE_DIR/tags/$tag/paramDatabase" \
                "$CASE_DIR/tags/$tag/parametricWork" \
                "$CASE_DIR/tags/$tag/parametricLogs" \
                "$CASE_DIR/tags/$tag/parametricStatus" \
                "$CASE_DIR/tags/$tag/coreScalingLogs"
            rm -f "$SUITE_ROOT/tags/$tag.status"
            ui_ok "Cleaned tag $tag"
        done

        suite_rebuild_case_index
        suite_write_summary_all
    else
        for tag in "${SUITE_TAGS[@]}"; do
            PARAMETRIC_TAG="$tag" "$(suite_engine)" "$CASE_DIR/tags/$tag" --clean || true
        done
    fi

    suite_unlock
    trap - EXIT
    return 0
}
