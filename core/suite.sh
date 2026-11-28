#!/bin/bash

# --------------------------------------------------
# Tagged studies / suite controller
#
# Results stay inside tags/<tag>/ unless tagMerge is enabled
# or --merge-tags is used.  Cases from all selected tags share
# one global queue and one global case-number sequence.
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

suite_merge_enabled() {
    local value
    value=$(foamDictionary "$CASE_DIR/system/paramDict" -entry tagMerge -value 2>/dev/null | tr -d '"[:space:]')
    case "${value,,}" in
        true|1|yes|on) return 0 ;;
        *)             return 1 ;;
    esac
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
    for dir in "$CASE_DIR"/tags/*/parametricStudy/"${prefix}"[0-9]* \
               "$CASE_DIR"/parametricStudy/"${prefix}"[0-9]*; do
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
            delete_backup_dirs "$tagDir"
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

suite_prepare_main_results() {
    local hadData=0

    [ -d "$CASE_DIR/parametricStudy" ] && hadData=1
    [ -d "$CASE_DIR/paramDatabase" ] && hadData=1
    [ -d "$CASE_DIR/coreScalingLogs" ] && hadData=1
    [ "$hadData" -eq 0 ] && return 0

    case "$MODE" in
        --delete)
            rm -rf "$CASE_DIR/parametricStudy" "$CASE_DIR/paramDatabase" \
                   "$CASE_DIR/coreScalingLogs"
            delete_backup_dirs "$CASE_DIR"
            ;;
        --backup)
            suite_backup_dir "$CASE_DIR" parametricStudy
            suite_backup_dir "$CASE_DIR" paramDatabase
            suite_backup_dir "$CASE_DIR" coreScalingLogs
            ;;
    esac
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
    local tag dir base number tmp statusFile statusCase statusTag
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

        # Failed or still-running cases have status files but no archive.
        for statusFile in "$CASE_DIR"/tags/*/parametricStatus/"${SUITE_PREFIX}"[0-9]*.status; do
            [ -f "$statusFile" ] || continue
            statusCase=${statusFile##*/}
            statusCase=${statusCase%.status}
            statusTag=${statusFile#*/tags/}
            statusTag=${statusTag%%/*}
            number=${statusCase#"$SUITE_PREFIX"}
            [[ "$number" =~ ^[0-9]+$ ]] || continue
            printf '%s,%s,%s\n' "$statusTag" "$statusCase" "$number"
        done

        # Cases merged into the main result tree.
        if [ -f "$CASE_DIR/paramDatabase/caseMatrix.csv" ]; then
            local mheader mtag mcase mnumber
            IFS= read -r mheader < "$CASE_DIR/paramDatabase/caseMatrix.csv"
            local -a mfields
            IFS=, read -r -a mfields <<< "$mheader"
            if [ "${mfields[1]:-}" == "tag" ]; then
                while IFS=, read -r mcase mtag mnumber; do
                    [ "$mcase" == "caseName" ] && continue
                    [ -z "$mcase" ] && continue
                    mnumber=${mcase#"$SUITE_PREFIX"}
                    [[ "$mnumber" =~ ^[0-9]+$ ]] || continue
                    printf '%s,%s,%s\n' "$mtag" "$mcase" "$mnumber"
                done < <(tail -n +2 "$CASE_DIR/paramDatabase/caseMatrix.csv")
            fi
        fi
    } | sort -t, -k3,3n -u > "$tmp"

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
    local nodeName
    nodeName=$(suite_local_node_label)

    (
        cd "$tagDir" || exit 1

        CASE_DIR="$tagDir"
        PARAMETRIC_STUDY_DIR="$tagDir/parametricStudy"
        PARAMETRIC_WORK_DIR="$tagDir/parametricWork"
        PARAMETRIC_LOG_DIR="$tagDir/parametricLogs"
        PARAMETRIC_STATUS_DIR="$tagDir/parametricStatus"
        export PARAMETRIC_TAGGED_CHILD=1
        export PARAMETRIC_TAG="$tag"
        export PARAMETRIC_NODE_ALIAS="$nodeName"
        export PARAMETRIC_TRANSPORT="local"
        export PARAMETRIC_SUITE_ID="$SUITE_ID"
        export PARAMETRIC_JOB_ID="${SUITE_ID}-${caseName}"

        load_config >/dev/null 2>&1 || exit 1
        run_case "$caseName" "$values"
    ) > "$tagDir/parametricLogs/worker.${caseName}.log" 2>&1 &
}

suite_run_queue() {
    local i=0
    local active=0
    local total=${#SUITE_Q_TAG[@]}
    local reportAt=0
    local tag caseName node details key

    if [ "$SUITE_MAX_PARALLEL" -gt 1 ]; then
        export OMPI_MCA_hwloc_base_binding_policy="${OMPI_MCA_hwloc_base_binding_policy:-none}"
    fi

    while [ "$i" -lt "$total" ] || [ "$active" -gt 0 ]; do

        while [ "$active" -lt "$SUITE_MAX_PARALLEL" ] && [ "$i" -lt "$total" ]; do
            tag=${SUITE_Q_TAG[$i]}
            caseName=${SUITE_Q_CASE[$i]}
            node=$(suite_local_node_label)
            key="$tag|$caseName"
            SUITE_CASE_NODE[$key]=$node
            details=$(suite_case_parameters "$tag" "${SUITE_Q_VALUES[$i]}")

            ui_info "Launching $tag/$caseName on $node${details:+  ($details)}"

            suite_launch_case "$tag" "$caseName" "${SUITE_Q_VALUES[$i]}"
            active=$((active + 1))
            i=$((i + 1))
        done

        if [ "$active" -gt 0 ]; then
            wait -n || true
            active=$((active - 1))
            suite_report_finished_cases

            reportAt=$((reportAt + 1))
            if [ "$reportAt" -ge 5 ]; then
                for tag in "${SUITE_TAGS[@]}"; do
                    suite_update_tag_status "$tag"
                done
                reportAt=0
            fi
        fi
    done

    suite_report_finished_cases

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

suite_tag_counts_from_table() {
    local tag=$1
    local tagTable="$CASE_DIR/tags/$tag/paramDatabase/paramTable.csv"
    local mainTable="$CASE_DIR/paramDatabase/paramTable.csv"
    local done=0 failed=0
    local -a tables=()

    [ -f "$mainTable" ] && tables+=("$mainTable")
    [ -f "$tagTable" ] && tables+=("$tagTable")

    if [ ${#tables[@]} -gt 0 ]; then
        read -r done failed < <(
            awk -F, -v t="$tag" '
                $1=="caseName" {
                    s=0
                    g=0
                    for (i=1; i<=NF; i++) {
                        if ($i=="status") s=i
                        if ($i=="tag") g=i
                    }
                    next
                }
                {
                    if (g && $g != t) next
                    seen[$1]=$s
                }
                END {
                    for (k in seen) {
                        if (seen[k]=="DONE") d++
                        else if (seen[k]=="FAILED") f++
                    }
                    print d+0, f+0
                }
            ' "${tables[@]}"
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
    local -A total=() done=() failed=() first=() last=() caseList=()

    if [ ! -f "$index" ]; then
        suite_rebuild_case_index
    fi

    while IFS=, read -r tag caseName number; do
        [ "$tag" == "tag" ] && continue
        [ -z "$tag" ] && continue
        total[$tag]=$(( ${total[$tag]:-0} + 1 ))
        [ -z "${first[$tag]:-}" ] && first[$tag]=$caseName
        last[$tag]=$caseName
        caseList[$tag]+="${caseList[$tag]:+;}${caseName}"
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

        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$tag" "${total[$tag]}" "${done[$tag]}" "${failed[$tag]}" \
            "$state" "${first[$tag]}" "${last[$tag]}" "${caseList[$tag]}"
    done | sort > "$summary.tmp"

    {
        printf 'tag,cases,done,failed,status,firstCase,lastCase,caseList\n'
        cat "$summary.tmp"
    } > "$summary"
    rm -f "$summary.tmp"
}

suite_print_summary_rows() {
    local summary="$SUITE_ROOT/summary.csv"
    local tag cases done failed state first last list

    if [ ! -f "$summary" ]; then
        ui_warn "Suite summary not available: $summary"
        return 0
    fi

    printf '  %-12s %-6s %-6s %-7s %-10s %s\n' \
        "Tag" "Cases" "Done" "Failed" "Status" "Cases"

    while IFS=, read -r tag cases done failed state first last list; do
        [ "$tag" == "tag" ] && continue
        [ -z "$tag" ] && continue
        list=${list//;/ }
        [ -z "$list" ] && list="${first:-} .. ${last:-}"
        printf '  %-12s %-6s %-6s %-7s %-10s %s\n' \
            "$tag" "$cases" "$done" "$failed" "$state" "$list"
    done < "$summary"
}

suite_case_parameters() {
    local tag=$1
    local values=$2
    local i details=""
    local -a names=()
    local -a vals=()

    read -r -a names <<< "${SUITE_PARAM_LIST[$tag]:-}"
    read -r -a vals <<< "$values"

    for ((i=0;i<${#names[@]};i++)); do
        [ -n "$details" ] && details+=" "
        details+="${names[$i]}=${vals[$i]:-}"
    done

    printf '%s' "$details"
}

suite_local_node_label() {
    printf '%s' "${SUITE_LOCAL_NODE:-$(parametric_node_label)}"
}

suite_case_node() {
    local tag=$1
    local caseName=$2
    local key="$tag|$caseName"
    local table

    if [ -n "${SUITE_CASE_NODE[$key]:-}" ]; then
        printf '%s' "${SUITE_CASE_NODE[$key]}"
        return 0
    fi

    local statusFile="$CASE_DIR/tags/$tag/parametricStatus/${caseName}.status"
    if [ -f "$statusFile" ]; then
        local statusNode
        statusNode=$(sed -n 's/^node=//p' "$statusFile" | tail -n 1)
        if [ -n "$statusNode" ]; then
            printf '%s' "$statusNode"
            return 0
        fi
    fi

    for table in "$CASE_DIR/tags/$tag/paramDatabase/paramTable.csv" \
                 "$CASE_DIR/paramDatabase/paramTable.csv"; do
        [ -f "$table" ] || continue
        local nodeValue
        nodeValue=$(awk -F, -v c="$caseName" -v t="$tag" '
            $1=="caseName" {
                a=0
                n=0
                g=0
                for (i=1; i<=NF; i++) {
                    if ($i=="nodeAlias") a=i
                    if ($i=="node") n=i
                    if ($i=="tag") g=i
                }
                next
            }
            $1==c && (!g || $g==t) {
                if (a && $a != "") { print $a; exit }
                if (n && $n != "") { print $n; exit }
            }
        ' "$table")
        if [ -n "$nodeValue" ]; then
            printf '%s' "$nodeValue"
            return 0
        fi
    done

    printf '%s' "-"
}

suite_list_cases_in_state() {
    local wanted=$1
    local i tag caseName list="" ref

    for ((i=0;i<${#SUITE_Q_TAG[@]};i++)); do
        tag=${SUITE_Q_TAG[$i]}
        caseName=${SUITE_Q_CASE[$i]}
        PARAMETRIC_STATUS_DIR="$CASE_DIR/tags/$tag/parametricStatus" \
            status_load "$caseName"
        if [ "$ST_STATE" == "$wanted" ]; then
            ref="$tag/$caseName"
            if [ "$wanted" == "RUNNING" ] && [ -n "${ST_NODE:-}" ]; then
                ref+="@$ST_NODE"
            fi
            list+="${list:+, }$ref"
        fi
    done

    printf '%s' "$list"
}

suite_report_case_result() {
    local tag=$1
    local caseName=$2
    local key="$tag|$caseName"
    local node endTime elapsed running queued logLine logFile

    [ -n "${SUITE_REPORTED[$key]+x}" ] && return 0

    PARAMETRIC_STATUS_DIR="$CASE_DIR/tags/$tag/parametricStatus" \
        status_load "$caseName"

    case "$ST_STATE" in
        DONE)
            node=${ST_NODE:-$(suite_case_node "$tag" "$caseName")}
            endTime=$(fmt_wallclock "$ST_END")
            elapsed=$(fmt_duration "$ST_ELAPSED")
            ui_ok "Completed $tag/$caseName at $endTime on $node  ($elapsed)"
            logLine="[ OK ] Completed $tag/$caseName at $endTime on $node  ($elapsed)"
            ;;
        FAILED)
            node=${ST_NODE:-$(suite_case_node "$tag" "$caseName")}
            endTime=$(fmt_wallclock "$ST_END")
            elapsed=$(fmt_duration "$ST_ELAPSED")
            ui_error "Failed $tag/$caseName at $endTime on $node after $elapsed (exit $ST_RC: $(rc_description "$ST_RC"); reason: ${ST_REASON:-unknown})"
            logLine="[FAIL] Failed $tag/$caseName at $endTime on $node after $elapsed (exit $ST_RC: $(rc_description "$ST_RC"); reason: ${ST_REASON:-unknown})"
            ;;
        *)
            return 0
            ;;
    esac

    running=$(suite_list_cases_in_state RUNNING)
    queued=$(suite_list_cases_in_state QUEUED)

    ui_kv "Running" "${running:-none}"
    ui_kv "Queue" "${queued:-none}"

    logFile="$CASE_DIR/tags/$tag/parametricLogs/run.log"
    mkdir -p "$(dirname "$logFile")" 2>/dev/null || true
    {
        printf '%s\n' "$logLine"
        printf '  Running: %s\n' "${running:-none}"
        printf '  Queue  : %s\n' "${queued:-none}"
        printf '%s\n' "----------------------------------------------------------------"
    } >> "$logFile"

    SUITE_REPORTED[$key]=1
}

suite_report_finished_cases() {
    local i tag caseName key

    for ((i=0;i<${#SUITE_Q_TAG[@]};i++)); do
        tag=${SUITE_Q_TAG[$i]}
        caseName=${SUITE_Q_CASE[$i]}
        key="$tag|$caseName"
        [ -n "${SUITE_REPORTED[$key]+x}" ] && continue

        PARAMETRIC_STATUS_DIR="$CASE_DIR/tags/$tag/parametricStatus" \
            status_load "$caseName"

        case "$ST_STATE" in
            DONE|FAILED)
                suite_report_case_result "$tag" "$caseName"
                ;;
        esac
    done
}

suite_case_state() {
    local tag=$1
    local caseName=$2
    local statusFile="$CASE_DIR/tags/$tag/parametricStatus/${caseName}.status"
    local table="$CASE_DIR/tags/$tag/paramDatabase/paramTable.csv"

    if [ -f "$statusFile" ]; then
        PARAMETRIC_STATUS_DIR="$CASE_DIR/tags/$tag/parametricStatus" \
            status_load "$caseName"
        printf '%s' "${ST_STATE:-QUEUED}"
        return 0
    fi

    if [ -f "$table" ]; then
        awk -F, -v c="$caseName" '
            NR==1 { for (i=1; i<=NF; i++) if ($i=="status") s=i }
            NR>1 && $1==c { print $s; exit }
        ' "$table"
        return 0
    fi

    table="$CASE_DIR/paramDatabase/paramTable.csv"
    if [ -f "$table" ]; then
        awk -F, -v c="$caseName" -v t="$tag" '
            NR==1 {
                for (i=1; i<=NF; i++) {
                    if ($i=="status") s=i
                    if ($i=="tag") g=i
                }
            }
            NR>1 && $1==c && (!g || $g==t) { print $s; exit }
        ' "$table"
        return 0
    fi

    printf 'QUEUED'
}

suite_merge_header() {
    local file=$1
    local line start i
    local -a fields

    IFS= read -r line < "$file" || return 1
    IFS=, read -r -a fields <<< "$line"
    [ "${fields[0]:-}" == "caseName" ] || return 1

    start=1
    [ "${fields[1]:-}" == "tag" ] && start=2

    printf 'caseName,tag'
    for ((i=start;i<${#fields[@]};i++)); do
        printf ',%s' "${fields[$i]}"
    done
}

suite_merge_file_has_tag() {
    local file=$1
    local line
    local -a fields

    IFS= read -r line < "$file" || return 1
    IFS=, read -r -a fields <<< "$line"
    [ "${fields[1]:-}" == "tag" ]
}

suite_merge_rows() {
    local src=$1
    local dst=$2
    local tag=$3
    local hasTag=$4
    local tmp="${dst}.merge.$$"

    awk -F, -v OFS=, -v tag="$tag" -v hasTag="$hasTag" '
        NR==FNR {
            if (FNR==1) {
                start = (hasTag == 1 ? 3 : 2)
                next
            }
            line = $1 OFS tag
            for (i=start; i<=NF; i++) line = line OFS $i
            new[$1] = line
            order[++n] = $1
            next
        }
        FNR==1 { print; next }
        !($1 in new) { print }
        END { for (i=1; i<=n; i++) print new[order[i]] }
    ' "$src" "$dst" > "$tmp" || return 1

    mv "$tmp" "$dst"
}

suite_merge_tags() {
    local tag tagDir src dst base header expected tableHeader tableHeaderExpected
    local tmpDst hasTag
    local matrix="$CASE_DIR/paramDatabase/caseMatrix.csv"
    local table="$CASE_DIR/paramDatabase/paramTable.csv"
    local -a tagWithData=()

    # Validate tag databases first.  Tags whose output was already merged
    # are allowed to have no result folders.
    for tag in "${SUITE_TAGS[@]}"; do
        tagDir="$CASE_DIR/tags/$tag"

        if [ -d "$tagDir/parametricStatus" ] && \
           [ -n "$(find "$tagDir/parametricStatus" -mindepth 1 -maxdepth 1 -name '*.status' -print -quit 2>/dev/null)" ]; then
            ui_error "Tag $tag has unfinished or failed cases; cannot merge"
            return 1
        fi

        if [ ! -f "$tagDir/paramDatabase/caseMatrix.csv" ] || \
           [ ! -f "$tagDir/paramDatabase/paramTable.csv" ]; then
            if { [ -d "$tagDir/parametricStudy" ] && \
                 [ -n "$(find "$tagDir/parametricStudy" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null)" ]; } || \
               { [ -d "$tagDir/parametricWork" ] && \
                 [ -n "$(find "$tagDir/parametricWork" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; }; then
                ui_error "Tag $tag has unfinished or failed cases; cannot merge"
                return 1
            fi
            ui_info "Tag $tag has no new results to merge"
            continue
        fi

        header=$(suite_merge_header "$tagDir/paramDatabase/caseMatrix.csv") || {
            ui_error "Invalid caseMatrix header for tag $tag"
            return 1
        }
        tableHeader=$(suite_merge_header "$tagDir/paramDatabase/paramTable.csv") || {
            ui_error "Invalid paramTable header for tag $tag"
            return 1
        }

        if [ -z "${expected:-}" ]; then
            expected="$header"
            tableHeaderExpected="$tableHeader"
        elif [ "$header" != "$expected" ] || [ "$tableHeader" != "$tableHeaderExpected" ]; then
            ui_error "Tag $tag has a different parameter or result layout; cannot merge"
            return 1
        fi

        tagWithData+=("$tag")
    done

    if [ ${#tagWithData[@]} -eq 0 ]; then
        ui_info "No tag results to merge"
        return 0
    fi

    mkdir -p "$CASE_DIR/parametricStudy" "$CASE_DIR/paramDatabase" \
             "$CASE_DIR/parametricLogs" || return 1

    if [ -f "$matrix" ]; then
        IFS= read -r header < "$matrix"
        if [ "$header" != "$expected" ]; then
            ui_error "Main caseMatrix.csv layout does not match tag results"
            return 1
        fi
    else
        printf '%s\n' "$expected" > "$matrix" || return 1
    fi

    if [ -f "$table" ]; then
        IFS= read -r header < "$table"
        if [ "$header" != "$tableHeaderExpected" ]; then
            ui_error "Main paramTable.csv layout does not match tag results"
            return 1
        fi
    else
        printf '%s\n' "$tableHeaderExpected" > "$table" || return 1
    fi

    # Copy archives, replacing an older copy of the same case if it exists.
    for tag in "${tagWithData[@]}"; do
        tagDir="$CASE_DIR/tags/$tag"
        for src in "$tagDir"/parametricStudy/"$SUITE_PREFIX"[0-9]*; do
            [ -d "$src" ] || continue
            base=${src##*/}
            dst="$CASE_DIR/parametricStudy/$base"
            tmpDst="$CASE_DIR/parametricStudy/.merge.$$.$base"

            rm -rf "$tmpDst"
            cp -a "$src" "$tmpDst" || {
                rm -rf "$tmpDst"
                ui_error "Failed to copy $src"
                return 1
            }
            rm -rf "$dst"
            mv "$tmpDst" "$dst" || return 1
        done
    done

    # Merge matrices and result tables.  Existing rows are replaced so that
    # a rerun copied from a tag overwrites the older main result.
    for tag in "${tagWithData[@]}"; do
        tagDir="$CASE_DIR/tags/$tag"

        if suite_merge_file_has_tag "$tagDir/paramDatabase/caseMatrix.csv"; then
            hasTag=1
        else
            hasTag=0
        fi
        suite_merge_rows "$tagDir/paramDatabase/caseMatrix.csv" "$matrix" "$tag" "$hasTag" || {
            ui_error "Failed to merge caseMatrix for tag $tag"
            return 1
        }

        if suite_merge_file_has_tag "$tagDir/paramDatabase/paramTable.csv"; then
            hasTag=1
        else
            hasTag=0
        fi
        suite_merge_rows "$tagDir/paramDatabase/paramTable.csv" "$table" "$tag" "$hasTag" || {
            ui_error "Failed to merge paramTable for tag $tag"
            return 1
        }

        if [ -d "$tagDir/parametricLogs" ]; then
            cp -a "$tagDir/parametricLogs/." "$CASE_DIR/parametricLogs/" 2>/dev/null || true
        fi
        if [ -d "$tagDir/coreScalingLogs" ]; then
            cp -a "$tagDir/coreScalingLogs" "$CASE_DIR/" 2>/dev/null || true
        fi
    done

    # All copies and merges succeeded; remove the per-tag result output.
    for tag in "${SUITE_TAGS[@]}"; do
        tagDir="$CASE_DIR/tags/$tag"
        rm -rf "$tagDir/parametricStudy" "$tagDir/paramDatabase"
        rm -rf "$tagDir/parametricWork" "$tagDir/parametricLogs" "$tagDir/parametricStatus"
        rm -rf "$tagDir/coreScalingLogs"
        rm -f "$SUITE_ROOT/tags/$tag.status"
    done

    # Drop empty generated folders left behind by the merge.
    local emptyDir
    for emptyDir in parametricStudy parametricWork parametricLogs parametricStatus coreScalingLogs; do
        if [ -d "$CASE_DIR/$emptyDir" ] && \
           [ -z "$(find "$CASE_DIR/$emptyDir" -mindepth 1 -print -quit 2>/dev/null)" ]; then
            rmdir "$CASE_DIR/$emptyDir" 2>/dev/null || true
        fi
    done

    suite_rebuild_case_index
    suite_write_summary_all
    suite_write_cases_csv

    ui_ok "Merged tagged results into main parametricStudy/ and paramDatabase/"
}

suite_print_case_table() {
    local i j tag caseName details state node
    local -a names=()
    local -a vals=()

    ui_section "Suite cases"
    printf '  %-12s %-14s %-12s %-14s %s\n' \
        "Tag" "Case" "State" "Node" "Parameters"

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
        state=$(suite_case_state "$tag" "$caseName")
        node=$(suite_case_node "$tag" "$caseName")
        printf '  %-12s %-14s %-12s %-14s %s\n' \
            "$tag" "$caseName" "$state" "$node" "$details"
    done
}

suite_write_cases_csv() {
    local index="$SUITE_ROOT/caseIndex.csv"
    local out="$SUITE_ROOT/cases.csv"
    local tag caseName number state node reason statusFile

    {
        printf 'tag,caseName,number,status,node,reason\n'
        if [ -f "$index" ]; then
            while IFS=, read -r tag caseName number; do
                [ "$tag" == "tag" ] && continue
                [ -z "$tag" ] && continue
                state=$(suite_case_state "$tag" "$caseName")
                node=$(suite_case_node "$tag" "$caseName")
                reason=""
                statusFile="$CASE_DIR/tags/$tag/parametricStatus/${caseName}.status"
                if [ -f "$statusFile" ]; then
                    PARAMETRIC_STATUS_DIR="$CASE_DIR/tags/$tag/parametricStatus" \
                        status_load "$caseName"
                    reason=${ST_REASON:-}
                fi
                reason=${reason//$'\n'/ }
                reason=${reason//$'\r'/ }
                reason=${reason//,/;}
                printf '%s,%s,%s,%s,%s,%s\n' \
                    "$tag" "$caseName" "$number" "$state" "$node" "$reason"
            done < "$index"
        fi
    } > "$out"
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
    declare -gA SUITE_CASE_NODE=()
    declare -gA SUITE_REPORTED=()
    SUITE_Q_TAG=()
    SUITE_Q_CASE=()
    SUITE_Q_VALUES=()

    SUITE_ID="${SUITE_ID:-$(date +%Y%m%dT%H%M%S)-$$-$RANDOM}"
    export SUITE_ID
    SUITE_LOCAL_NODE="${SUITE_LOCAL_NODE:-$(parametric_node_label)}"
    export SUITE_LOCAL_NODE

    suite_prepare_main_results

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

    if distributed_enabled; then
        distributed_init || {
            suite_unlock
            return 1
        }
    else
        DIST_ENABLED=0
        if ! suite_available_cores; then
            suite_unlock
            return 1
        fi
    fi

    suite_init_tag_statuses
    suite_rebuild_case_index

    if [ "$DIST_ENABLED" -eq 0 ]; then
        local q
        for ((q=0;q<${#SUITE_Q_TAG[@]};q++)); do
            SUITE_CASE_NODE["${SUITE_Q_TAG[$q]}|${SUITE_Q_CASE[$q]}"]=$(suite_local_node_label)
        done
    fi

    ui_section "Suite plan"
    ui_kv "Tags" "${SUITE_TAGS[*]}"
    ui_kv "Suite ID" "$SUITE_ID"
    ui_kv "Cases" "${#SUITE_Q_TAG[@]}"
    ui_kv "Processors / case" "$SUITE_PROCESSORS"
    ui_kv "Concurrent cases" "$SUITE_MAX_PARALLEL"
    ui_kv "Execution" "$([ "$DIST_ENABLED" -eq 1 ] && printf 'distributed' || printf 'local')"
    distributed_print_plan
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

    if [ "$DIST_ENABLED" -eq 1 ]; then
        if ! distributed_run_queue; then
            ui_error "Distributed execution failed"
            suiteRc=1
        fi
    else
        suite_run_queue
    fi

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
    suite_write_cases_csv
    suite_print_case_table

    if suite_merge_enabled; then
        if ! suite_merge_tags; then
            ui_error "Tag merge failed; tag outputs were kept"
            suiteRc=1
        fi
    fi

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
    ui_kv "Case index" "$SUITE_ROOT/cases.csv"
    suite_print_summary_rows

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
        if [ -d "$CASE_DIR/tags/$tag/parametricStudy/$caseName" ] || \
           [ -d "$CASE_DIR/parametricStudy/$caseName" ]; then
            printf '%s\t%s\n' "$tag" "$caseName"
            return 0
        fi
        return 1
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

    if [ "$matches" -eq 1 ]; then
        printf '%s\t%s\n' "$tag" "$caseName"
        return 0
    fi

    if [ -f "$SUITE_ROOT/caseIndex.csv" ]; then
        local indexPathTag indexPathCase
        while IFS=, read -r indexPathTag indexPathCase number; do
            [ "$indexPathTag" == "tag" ] && continue
            if [ "$indexPathCase" == "$query" ]; then
                matches=$((matches + 1))
                tag=$indexPathTag
                caseName=$indexPathCase
            fi
        done < "$SUITE_ROOT/caseIndex.csv"
    fi

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

    if [ -z "$tag" ] || [ -z "$caseName" ]; then
        ui_error "Cannot delete a case without a tag and case name"
        return 1
    fi

    if [[ "$caseName" == */* ]] || [[ "$caseName" == *..* ]]; then
        ui_error "Unsafe case name: $caseName"
        return 1
    fi

    # Merged results live only in the main result tree.
    if [ ! -d "$tagDir/parametricStudy/$caseName" ] && \
       [ -d "$CASE_DIR/parametricStudy/$caseName" ]; then
        rm -rf "$CASE_DIR/parametricStudy/$caseName"
        rm -f "$CASE_DIR/parametricStatus/${caseName}.status"
        rm -f "$CASE_DIR"/parametricLogs/*"${caseName}"* 2>/dev/null || true

        if [ -f "$CASE_DIR/paramDatabase/caseMatrix.csv" ]; then
            awk -F, -v c="$caseName" -v t="$tag" \
                'NR==1 || !($1==c && $2==t)' \
                "$CASE_DIR/paramDatabase/caseMatrix.csv" > \
                "$CASE_DIR/paramDatabase/caseMatrix.csv.tmp" && \
                mv "$CASE_DIR/paramDatabase/caseMatrix.csv.tmp" \
                   "$CASE_DIR/paramDatabase/caseMatrix.csv"
        fi

        (
            cd "$CASE_DIR" || exit 1
            CASE_DIR="$CASE_DIR"
            PARAMETRIC_STUDY_DIR="$CASE_DIR/parametricStudy"
            PARAMETRIC_WORK_DIR="$CASE_DIR/parametricWork"
            PARAMETRIC_LOG_DIR="$CASE_DIR/parametricLogs"
            PARAMETRIC_STATUS_DIR="$CASE_DIR/parametricStatus"
            unset PARAMETRIC_TAG
            load_config >/dev/null 2>&1 || exit 1
            build_param_table >>/dev/null 2>&1 || exit 1
        ) || return 1

        return 0
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
    suite_write_cases_csv

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

suite_merge_command() {
    local highest

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

    if ! suite_merge_tags; then
        suite_unlock
        return 1
    fi

    highest=$(suite_highest_number "$SUITE_PREFIX")
    mkdir -p "$SUITE_ROOT"
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
    suite_print_summary_rows

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
        suite_print_summary_rows
    }
    [ -f "$SUITE_ROOT/cases.csv" ] && {
        ui_section "CASES"
        cat "$SUITE_ROOT/cases.csv"
    }
    return 0
}

suite_seed_tag_matrix() {
    local tag=$1
    local caseName=$2
    local tagDir="$CASE_DIR/tags/$tag"
    local mainMatrix="$CASE_DIR/paramDatabase/caseMatrix.csv"
    local tagMatrix="$tagDir/paramDatabase/caseMatrix.csv"
    local header row existing

    [ -f "$mainMatrix" ] || return 1

    header=$(awk -F, '
        NR==1 {
            printf "caseName"
            for (i=3; i<=NF; i++) printf ",%s", $i
        }
    ' "$mainMatrix")

    row=$(awk -F, -v c="$caseName" -v t="$tag" '
        NR>1 && $1==c && $2==t {
            printf "%s", $1
            for (i=3; i<=NF; i++) printf ",%s", $i
            exit
        }
    ' "$mainMatrix")

    [ -n "$header" ] && [ -n "$row" ] || return 1
    mkdir -p "$tagDir/paramDatabase" || return 1

    if [ -f "$tagMatrix" ]; then
        IFS= read -r existing < "$tagMatrix"
        if [ "$existing" != "$header" ]; then
            ui_error "Tag $tag caseMatrix layout does not match the main caseMatrix"
            return 1
        fi
        awk -F, -v c="$caseName" 'NR==1 || $1 != c' "$tagMatrix" > "${tagMatrix}.tmp" || return 1
        printf '%s\n' "$row" >> "${tagMatrix}.tmp" || return 1
        mv "${tagMatrix}.tmp" "$tagMatrix"
    else
        {
            printf '%s\n' "$header"
            printf '%s\n' "$row"
        } > "$tagMatrix"
    fi
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

        if [ ! -d "$CASE_DIR/tags/$tag/parametricStudy/$caseName" ] && \
           [ -d "$CASE_DIR/parametricStudy/$caseName" ]; then
            if ! suite_seed_tag_matrix "$tag" "$caseName"; then
                ui_error "Cannot prepare tag $tag for rerunning merged case $caseName"
                suite_unlock
                return 1
            fi
        fi

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

    if [ ! -d "$CASE_DIR/tags/$tag/parametricStudy/$caseName" ] && \
       [ -d "$CASE_DIR/parametricStudy/$caseName" ]; then
        PARAMETRIC_SUITE_BYPASS=1 PARAMETRIC_TAG="$tag" \
            "$(suite_engine)" "$CASE_DIR" --case "$caseName"
    else
        PARAMETRIC_TAG="$tag" "$(suite_engine)" "$CASE_DIR/tags/$tag" --case "$caseName"
    fi
}

suite_clean_main_tags() {
    local -a cleanTags=("$@")
    local matrix table mapFile tag caseName rowTag tagFile emptyDir
    local matrixHasTag=0 tableHasTag=0

    [ ${#cleanTags[@]} -eq 0 ] && return 0

    matrix="$CASE_DIR/paramDatabase/caseMatrix.csv"
    table="$CASE_DIR/paramDatabase/paramTable.csv"

    if [ -f "$matrix" ] && [ "$(head -n 1 "$matrix" | cut -d, -f2)" == "tag" ]; then
        matrixHasTag=1
    fi
    if [ -f "$table" ] && [ "$(head -n 1 "$table" | cut -d, -f2)" == "tag" ]; then
        tableHasTag=1
    fi
    if [ "$matrixHasTag" -eq 0 ] && [ "$tableHasTag" -eq 0 ]; then
        return 0
    fi

    if [ "$matrixHasTag" -eq 1 ]; then
        mapFile="$matrix"
    else
        mapFile="$table"
    fi

    while IFS=, read -r caseName rowTag rest; do
        [ "$caseName" == "caseName" ] && continue
        [ -z "$caseName" ] && continue
        for tag in "${cleanTags[@]}"; do
            if [ "$rowTag" == "$tag" ]; then
                rm -rf "$CASE_DIR/parametricStudy/$caseName"
                rm -f "$CASE_DIR/parametricStatus/${caseName}.status"
                rm -f "$CASE_DIR"/parametricLogs/*"${caseName}"* 2>/dev/null || true
                break
            fi
        done
    done < <(tail -n +2 "$mapFile")

    tagFile=$(mktemp "${TMPDIR:-/tmp}/parametricCleanTags.XXXXXX") || return 1
    printf '%s\n' "${cleanTags[@]}" > "$tagFile"

    if [ "$matrixHasTag" -eq 1 ]; then
        awk -F, 'NR==FNR { drop[$1]=1; next }
                 FNR==1 || !($2 in drop)' \
            "$tagFile" "$matrix" > "${matrix}.tmp" && mv "${matrix}.tmp" "$matrix"
    fi
    if [ "$tableHasTag" -eq 1 ]; then
        awk -F, 'NR==FNR { drop[$1]=1; next }
                 FNR==1 || !($2 in drop)' \
            "$tagFile" "$table" > "${table}.tmp" && mv "${table}.tmp" "$table"
    fi
    rm -f "$tagFile"

    if { [ ! -f "$matrix" ] || [ "$(wc -l < "$matrix")" -le 1 ]; } && \
       { [ ! -f "$table" ]  || [ "$(wc -l < "$table")"  -le 1 ]; }; then
        rm -rf "$CASE_DIR/parametricStudy" "$CASE_DIR/paramDatabase" \
               "$CASE_DIR/parametricWork" "$CASE_DIR/parametricLogs" \
               "$CASE_DIR/parametricStatus" "$CASE_DIR/coreScalingLogs"
    else
        for emptyDir in parametricStudy parametricWork parametricLogs parametricStatus coreScalingLogs; do
            if [ -d "$CASE_DIR/$emptyDir" ] && \
               [ -z "$(find "$CASE_DIR/$emptyDir" -mindepth 1 -print -quit 2>/dev/null)" ]; then
                rmdir "$CASE_DIR/$emptyDir" 2>/dev/null || true
            fi
        done
    fi
}

suite_results_exist() {
    local tag file

    for file in "$CASE_DIR/paramDatabase/caseMatrix.csv" \
                "$CASE_DIR/paramDatabase/paramTable.csv"; do
        if [ -f "$file" ] && [ "$(wc -l < "$file")" -gt 1 ]; then
            return 0
        fi
    done

    if [ -d "$CASE_DIR/parametricStudy" ] && \
       [ -n "$(find "$CASE_DIR/parametricStudy" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        return 0
    fi

    for tag in "$CASE_DIR"/tags/*; do
        [ -d "$tag" ] || continue
        for file in "$tag/paramDatabase/caseMatrix.csv" \
                    "$tag/paramDatabase/paramTable.csv"; do
            if [ -f "$file" ] && [ "$(wc -l < "$file")" -gt 1 ]; then
                return 0
            fi
        done
        if [ -d "$tag/parametricStudy" ] && \
           [ -n "$(find "$tag/parametricStudy" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
            return 0
        fi
    done

    return 1
}

suite_clean() {
    local tag scope=individual answer removeSuite=0 suiteExisted=0

    [ -d "$SUITE_ROOT" ] && suiteExisted=1

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

    if [ -t 0 ]; then
        echo "Cleanup scope:"
        echo "  1) whole suite: remove all tag results and merged main results"
        echo "  2) individual tag: clean each selected tag and its merged main cases"
        read -r -p "Choose [1/2] (default 2): " answer
        [ "$answer" == "1" ] && scope=whole
    elif [ "${CLEAN_YES:-0}" -eq 1 ]; then
        scope=whole
    else
        ui_error "Cleanup needs confirmation; use --yes for whole-suite cleanup"
        suite_unlock
        return 1
    fi

    if [ "$scope" == "whole" ]; then
        if [ "${CLEAN_YES:-0}" -eq 0 ]; then
            read -r -p "Remove all tag results and merged main results? [y/N]: " answer
            case "$answer" in
                y|Y|yes|YES) ;;
                *) ui_info "Aborted"; suite_unlock; return 1 ;;
            esac
        fi

        if [ ${#TAG_FILTER[@]} -eq 0 ]; then
            rm -rf \
                "$CASE_DIR/parametricStudy" \
                "$CASE_DIR/paramDatabase" \
                "$CASE_DIR/parametricWork" \
                "$CASE_DIR/parametricLogs" \
                "$CASE_DIR/parametricStatus" \
                "$CASE_DIR/coreScalingLogs"
        else
            suite_clean_main_tags "${SUITE_TAGS[@]}"
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
    else
        for tag in "${SUITE_TAGS[@]}"; do
            PARAMETRIC_TAG="$tag" "$(suite_engine)" "$CASE_DIR/tags/$tag" --clean || true
        done
        suite_clean_main_tags "${SUITE_TAGS[@]}"
    fi

    if [ "$scope" == "whole" ] && [ ${#TAG_FILTER[@]} -eq 0 ]; then
        distributed_cleanup_remote all
    else
        distributed_cleanup_remote tags "${SUITE_TAGS[@]}"
        for tag in "${SUITE_TAGS[@]}"; do
            rm -rf "$SUITE_ROOT"/jobs/*/"$tag" 2>/dev/null || true
        done
    fi

    if suite_results_exist; then
        suite_rebuild_case_index
        suite_write_summary_all
        suite_write_cases_csv
    else
        removeSuite=1
    fi

    suite_unlock
    trap - EXIT

    if [ "$removeSuite" -eq 1 ]; then
        rm -rf "$SUITE_ROOT"
        [ "$suiteExisted" -eq 1 ] && ui_ok "Removed parametricSuite"
    fi

    return 0
}
