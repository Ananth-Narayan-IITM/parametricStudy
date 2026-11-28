#!/bin/bash

# --------------------------------------------------
# Distributed tagged-suite execution
#
# The master keeps the authoritative queue, case numbers,
# databases, and merge state.  Workers execute one case
# in an isolated job directory and publish PULL_COMPLETE
# only after the archive, status, and metadata are ready.
# --------------------------------------------------

DIST_ENABLED=0
DIST_NODES=()
DIST_RANK_ORDER=()
DIST_SUITE_ID=""
DIST_TOTAL_SLOTS=0
DIST_MAX_PARALLEL=0

declare -gA DIST_NODE_TRANSPORT=()
declare -gA DIST_NODE_RANK=()
declare -gA DIST_NODE_CORES=()
declare -gA DIST_NODE_SLOTS=()
declare -gA DIST_NODE_ACTIVE=()
declare -gA DIST_NODE_ONLINE=()
declare -gA DIST_NODE_TEMP=()
declare -gA DIST_NODE_HOST=()

declare -gA DIST_ACTIVE=()
declare -gA DIST_JOB_NODE=()
declare -gA DIST_JOB_TAG=()
declare -gA DIST_JOB_CASE=()
declare -gA DIST_JOB_VALUES=()
declare -gA DIST_JOB_ROOT=()

distributed_enabled() {
    local value
    value=$(foamDictionary "$CASE_DIR/system/paramDict" -entry distributed -value 2>/dev/null | tr -d '"[:space:]')
    case "${value,,}" in
        true|1|yes|on) return 0 ;;
        *)             return 1 ;;
    esac
}

distributed_nodes_file() {
    local file
    file=$(foamDictionary "$CASE_DIR/system/paramDict" -entry nodesFile -value 2>/dev/null | tr -d '"[:space:]')
    file=${file:-system/nodes.conf}

    case "$file" in
        /*) ;;
        *) file="$CASE_DIR/$file" ;;
    esac

    printf '%s' "$file"
}

distributed_ssh() {
    local node=$1
    shift
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "$@"
}

distributed_node_temp() {
    printf '%s' "${DIST_NODE_TEMP[$1]:-}"
}

distributed_node_slots() {
    printf '%s' "${DIST_NODE_SLOTS[$1]:-0}"
}

distributed_preflight_node() {
    local node=$1
    local transport=${DIST_NODE_TRANSPORT[$node]}
    local cores=${DIST_NODE_CORES[$node]}
    local temp=${DIST_NODE_TEMP[$node]}
    local home="" detectedCores="" host=""

    if [ "$transport" == "local" ]; then
        host=$(hostname 2>/dev/null || printf 'local')
        [ "$cores" == "auto" ] && cores=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)
        [ "$temp" == "auto" ] && temp="$HOME/.parametricStudy"
        if ! mkdir -p "$temp" 2>/dev/null || [ ! -w "$temp" ]; then
            ui_error "Node $node: temp root is not writable: $temp"
            return 1
        fi
    else
        if ! command -v ssh >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
            ui_error "Distributed mode requires ssh and rsync"
            return 1
        fi

        local info=""
        info=$(distributed_ssh "$node" \
            'printf "%s\n" "$HOME"; nproc; hostname' 2>/dev/null) || info=""
        if [ -n "$info" ]; then
            {
                IFS= read -r home
                IFS= read -r detectedCores
                IFS= read -r host
            } <<< "$info"
        fi

        if [ -z "$home" ] || [ -z "$detectedCores" ]; then
            ui_error "Node $node: cannot connect or run nproc (check passwordless SSH)"
            return 1
        fi

        if ! distributed_ssh "$node" 'command -v setsid >/dev/null 2>&1 && command -v rsync >/dev/null 2>&1' >/dev/null 2>&1; then
            ui_error "Node $node: setsid and rsync are required"
            return 1
        fi

        [ "$cores" == "auto" ] && cores=$detectedCores
        [ "$temp" == "auto" ] && temp="$home/.parametricStudy"

        if ! distributed_ssh "$node" "mkdir -p '$temp' && test -w '$temp'" >/dev/null 2>&1; then
            ui_error "Node $node: temp root is not writable: $temp"
            return 1
        fi
    fi

    if ! [[ "$cores" =~ ^[0-9]+$ ]] || [ "$cores" -lt 1 ]; then
        ui_error "Node $node: invalid core count '$cores'"
        return 1
    fi

    if [ "$cores" -lt "${SUITE_PROCESSORS:-1}" ]; then
        ui_error "Node $node: cores ($cores) is less than processors per case (${SUITE_PROCESSORS:-1})"
        return 1
    fi

    DIST_NODE_CORES[$node]=$cores
    DIST_NODE_TEMP[$node]=$temp
    DIST_NODE_HOST[$node]=$host
    DIST_NODE_SLOTS[$node]=$((cores / ${SUITE_PROCESSORS:-1}))
    DIST_NODE_ACTIVE[$node]=0
    DIST_NODE_ONLINE[$node]=1
}

distributed_init() {
    local file line name transport rank cores temp extra
    local seen=""
    local total=0
    local maxCases

    DIST_ENABLED=0
    if ! distributed_enabled; then
        return 0
    fi

    DIST_ENABLED=1
    DIST_SUITE_ID=${SUITE_ID:-}
    [ -z "$DIST_SUITE_ID" ] && DIST_SUITE_ID="$(date +%Y%m%dT%H%M%S)-$$"

    file=$(distributed_nodes_file)
    if [ ! -f "$file" ]; then
        ui_error "Distributed mode is enabled but nodes file is missing: $file"
        return 1
    fi

    DIST_NODES=()
    DIST_RANK_ORDER=()
    DIST_NODE_TRANSPORT=()
    DIST_NODE_RANK=()
    DIST_NODE_CORES=()
    DIST_NODE_SLOTS=()
    DIST_NODE_ACTIVE=()
    DIST_NODE_ONLINE=()
    DIST_NODE_TEMP=()
    DIST_NODE_HOST=()

    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%%#*}
        read -r name transport rank cores temp extra <<< "$line"
        [ -z "${name:-}" ] && continue

        if [ -z "${transport:-}" ] || [ -z "${rank:-}" ] || \
           [ -z "${cores:-}" ] || [ -z "${temp:-}" ] || [ -n "${extra:-}" ]; then
            ui_error "Invalid nodes.conf line (expected: name transport rank cores tempRoot): $line"
            return 1
        fi

        if ! [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
            ui_error "Invalid node name: '$name'"
            return 1
        fi
        if [ "$transport" != "local" ] && [ "$transport" != "ssh" ]; then
            ui_error "Node $name: transport must be local or ssh"
            return 1
        fi
        if ! [[ "$rank" =~ ^[0-9]+$ ]]; then
            ui_error "Node $name: rank must be a non-negative integer"
            return 1
        fi
        if [ "$cores" != "auto" ] && { ! [[ "$cores" =~ ^[0-9]+$ ]] || [ "$cores" -lt 1 ]; }; then
            ui_error "Node $name: cores must be auto or a positive integer"
            return 1
        fi
        if [ "$temp" != "auto" ] && [[ "$temp" != /* ]]; then
            ui_error "Node $name: tempRoot must be auto or an absolute path"
            return 1
        fi

        case " $seen " in
            *" $name "*) ui_error "Duplicate node name: $name"; return 1 ;;
        esac
        seen="$seen $name"

        DIST_NODES+=("$name")
        DIST_NODE_TRANSPORT[$name]=$transport
        DIST_NODE_RANK[$name]=$rank
        DIST_NODE_CORES[$name]=$cores
        DIST_NODE_TEMP[$name]=$temp
    done < "$file"

    if [ ${#DIST_NODES[@]} -eq 0 ]; then
        ui_error "No nodes configured in $file"
        return 1
    fi

    mapfile -t DIST_RANK_ORDER < <(
        for name in "${DIST_NODES[@]}"; do
            printf '%s\t%s\n' "${DIST_NODE_RANK[$name]}" "$name"
        done | sort -n -k1,1 -k2,2 | cut -f2
    )

    for name in "${DIST_RANK_ORDER[@]}"; do
        distributed_preflight_node "$name" || return 1
        total=$((total + ${DIST_NODE_SLOTS[$name]}))
    done

    DIST_TOTAL_SLOTS=$total

    maxCases=$(foamDictionary "$CASE_DIR/system/paramDict" -entry maxConcurrentCases -value 2>/dev/null | tr -d '[:space:]')
    if [ "$maxCases" == "auto" ] || [ -z "$maxCases" ]; then
        DIST_MAX_PARALLEL=$DIST_TOTAL_SLOTS
    else
        if ! [[ "$maxCases" =~ ^[0-9]+$ ]] || [ "$maxCases" -lt 1 ]; then
            ui_error "Invalid maxConcurrentCases: $maxCases"
            return 1
        fi
        DIST_MAX_PARALLEL=$maxCases
        [ "$DIST_MAX_PARALLEL" -gt "$DIST_TOTAL_SLOTS" ] && \
            DIST_MAX_PARALLEL=$DIST_TOTAL_SLOTS
    fi

    [ "$DIST_MAX_PARALLEL" -lt 1 ] && DIST_MAX_PARALLEL=1
    if [ "${#SUITE_Q_TAG[@]}" -gt 0 ] && \
       [ "$DIST_MAX_PARALLEL" -gt "${#SUITE_Q_TAG[@]}" ]; then
        DIST_MAX_PARALLEL=${#SUITE_Q_TAG[@]}
    fi
    SUITE_MAX_PARALLEL=$DIST_MAX_PARALLEL

    return 0
}

distributed_print_plan() {
    local node

    [ "$DIST_ENABLED" -eq 1 ] || return 0

    ui_section "Nodes"
    printf '  %-14s %-6s %-6s %-6s %-7s %s\n' \
        "Node" "Rank" "Cores" "Slots" "Active" "Temp root"

    for node in "${DIST_RANK_ORDER[@]}"; do
        printf '  %-14s %-6s %-6s %-6s %-7s %s\n' \
            "$node" "${DIST_NODE_RANK[$node]}" "${DIST_NODE_CORES[$node]}" \
            "${DIST_NODE_SLOTS[$node]}" "${DIST_NODE_ACTIVE[$node]:-0}" \
            "${DIST_NODE_TEMP[$node]}"
    done
}

distributed_sync_node() {
    local node=$1
    local temp=${DIST_NODE_TEMP[$node]}
    local tag
    local engineRoot="$PARAMETRIC_CORE_DIR/.."

    [ "${DIST_NODE_TRANSPORT[$node]}" == "ssh" ] || return 0

    if ! distributed_ssh "$node" "mkdir -p '$temp/engine' '$temp/bases'" >/dev/null 2>&1; then
        ui_error "Node $node: cannot create remote directories under $temp"
        return 1
    fi

    if ! rsync -a --delete "$engineRoot/allParametric" "$node:$temp/engine/"; then
        ui_error "Node $node: failed to synchronize allParametric"
        return 1
    fi
    if ! rsync -a --delete "$engineRoot/core/" "$node:$temp/engine/core/"; then
        ui_error "Node $node: failed to synchronize core/"
        return 1
    fi

    for tag in "${SUITE_TAGS[@]}"; do
        if ! rsync -a --delete \
            --exclude='parametricStudy/' \
            --exclude='paramDatabase/' \
            --exclude='parametricWork/' \
            --exclude='parametricLogs/' \
            --exclude='parametricStatus/' \
            --exclude='coreScalingLogs/' \
            --exclude='[[]backup*[]]*' \
            --exclude='processor*/' \
            --exclude='log.*' \
            --exclude='dynamicCode/' \
            "$CASE_DIR/tags/$tag/" "$node:$temp/bases/$tag/"; then
            ui_error "Node $node: failed to synchronize tag base $tag"
            return 1
        fi
    done

    return 0
}

distributed_sync_all() {
    local node

    [ "$DIST_ENABLED" -eq 1 ] || return 0

    for node in "${DIST_RANK_ORDER[@]}"; do
        distributed_sync_node "$node" || return 1
    done
}

distributed_write_job_file() {
    local file=$1
    local node=$2
    local tag=$3
    local caseName=$4
    local values=$5

    {
        printf 'SUITE_ID=%q\n' "$DIST_SUITE_ID"
        printf 'JOB_ID=%q\n' "${DIST_SUITE_ID}-${caseName}"
        printf 'TAG=%q\n' "$tag"
        printf 'CASE_NAME=%q\n' "$caseName"
        printf 'CASE_VALUES=%q\n' "$values"
        printf 'NODE_NAME=%q\n' "$node"
        printf 'TRANSPORT=%q\n' "${DIST_NODE_TRANSPORT[$node]}"
    } > "$file"
}

distributed_prepare_local_case() {
    local tag=$1
    local jobRoot=$2

    mkdir -p "$jobRoot/case" || return 1

    rsync -a \
        --exclude='parametricStudy/' \
        --exclude='paramDatabase/' \
        --exclude='parametricWork/' \
        --exclude='parametricLogs/' \
        --exclude='parametricStatus/' \
        --exclude='coreScalingLogs/' \
        --exclude='[[]backup*[]]*' \
        --exclude='processor*/' \
        --exclude='log.*' \
        --exclude='dynamicCode/' \
        "$CASE_DIR/tags/$tag/" "$jobRoot/case/" || return 1

    return 0
}

distributed_job_root() {
    local node=$1
    local tag=$2
    local jobId=$3
    local temp

    if [ "${DIST_NODE_TRANSPORT[$node]}" == "local" ]; then
        printf '%s' "$CASE_DIR/parametricSuite/jobs/$DIST_SUITE_ID/$tag/$jobId"
    else
        temp=${DIST_NODE_TEMP[$node]}
        printf '%s' "$temp/jobs/$DIST_SUITE_ID/$tag/$jobId"
    fi
}

distributed_launch_case() {
    local node=$1
    local tag=$2
    local caseName=$3
    local values=$4
    local jobId=$5
    local jobRoot
    local tmpEnv=""

    jobRoot=$(distributed_job_root "$node" "$tag" "$jobId")

    if [ "${DIST_NODE_TRANSPORT[$node]}" == "local" ]; then
        rm -rf "$jobRoot" || return 1
        mkdir -p "$jobRoot" || return 1
        distributed_prepare_local_case "$tag" "$jobRoot" || return 1
        distributed_write_job_file "$jobRoot/job.env" "$node" "$tag" "$caseName" "$values" || return 1

        (
            cd "$jobRoot" || exit 1
            PARAMETRIC_WORKER=1 \
            PARAMETRIC_JOB_FILE="$jobRoot/job.env" \
            setsid nohup "$(suite_engine)" "$jobRoot/case" \
                </dev/null >worker.log 2>&1 &
            echo $! > job.pid
        ) || return 1
    else
        local temp=${DIST_NODE_TEMP[$node]}
        tmpEnv=$(mktemp "${TMPDIR:-/tmp}/parametricJob.XXXXXX") || return 1
        distributed_write_job_file "$tmpEnv" "$node" "$tag" "$caseName" "$values" || {
            rm -f "$tmpEnv"
            return 1
        }

        if ! distributed_ssh "$node" \
            "rm -rf '$jobRoot' && mkdir -p '$jobRoot' && cp -a '$temp/bases/$tag' '$jobRoot/case'"; then
            rm -f "$tmpEnv"
            return 1
        fi

        if ! scp -q "$tmpEnv" "$node:$jobRoot/job.env"; then
            rm -f "$tmpEnv"
            return 1
        fi
        rm -f "$tmpEnv"

        if ! distributed_ssh "$node" \
            "cd '$jobRoot' || exit 1; PARAMETRIC_WORKER=1 PARAMETRIC_JOB_FILE='$jobRoot/job.env' setsid nohup '$temp/engine/allParametric' '$jobRoot/case' </dev/null >worker.log 2>&1 & echo \$! >job.pid"; then
            return 1
        fi
    fi

    JOB_ROOT=$jobRoot
    return 0
}

distributed_job_status() {
    local node=$1
    local jobRoot=$2
    local out

    if [ "${DIST_NODE_TRANSPORT[$node]}" == "local" ]; then
        if [ -f "$jobRoot/PULL_COMPLETE" ]; then
            printf 'complete'
        elif [ -f "$jobRoot/FAILED" ]; then
            printf 'failed'
        else
            local pid=""
            [ -f "$jobRoot/job.pid" ] && pid=$(cat "$jobRoot/job.pid" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                printf 'running'
            else
                printf 'missing'
            fi
        fi
        return 0
    fi

    if ! out=$(distributed_ssh "$node" \
        "if [ -f '$jobRoot/PULL_COMPLETE' ]; then echo complete; elif [ -f '$jobRoot/FAILED' ]; then echo failed; else pid=\$(cat '$jobRoot/job.pid' 2>/dev/null || true); if [ -n \"\$pid\" ] && kill -0 \"\$pid\" 2>/dev/null; then echo running; else echo missing; fi; fi" 2>/dev/null); then
        printf 'unreachable'
        return 0
    fi

    printf '%s' "$out"
}

distributed_pull_success() {
    local expectedNode=$1
    local expectedJobRoot=$2
    local expectedTag=$3
    local expectedCase=$4
    local expectedJob=$5
    local staging="$SUITE_ROOT/pull/$expectedJob"
    local tagDir="$CASE_DIR/tags/$expectedTag"
    local marker=""
    local markerSuite markerJob markerTag markerCase markerState markerNode
    local markerStart markerEnd markerElapsed markerExit markerReason
    # Keep marker fields local so sourcing the marker cannot overwrite
    # master queue variables.
    local suiteId jobId tag caseName node transport state exitCode reason
    local archivePath startTime endTime elapsedTime

    rm -rf "$staging"
    mkdir -p "$staging/archive" "$staging/logs" "$staging/db" || return 1

    if [ "${DIST_NODE_TRANSPORT[$expectedNode]}" == "local" ]; then
        cp -a "$expectedJobRoot/case/parametricStudy/$expectedCase/." "$staging/archive/" || return 1
        [ -f "$expectedJobRoot/case/parametricStatus/${expectedCase}.status" ] && \
            cp -a "$expectedJobRoot/case/parametricStatus/${expectedCase}.status" "$staging/status" || true
        if [ -d "$expectedJobRoot/case/parametricLogs" ]; then
            cp -a "$expectedJobRoot/case/parametricLogs/." "$staging/logs/" || true
        fi
        if [ -d "$expectedJobRoot/case/paramDatabase" ]; then
            cp -a "$expectedJobRoot/case/paramDatabase/." "$staging/db/" || true
        fi
        cp -a "$expectedJobRoot/PULL_COMPLETE" "$staging/PULL_COMPLETE" || return 1
        [ -f "$expectedJobRoot/job.env" ] && \
            cp -a "$expectedJobRoot/job.env" "$staging/job.env" || true
    else
        if ! rsync -a "$expectedNode:$expectedJobRoot/case/parametricStudy/$expectedCase/" "$staging/archive/"; then
            return 1
        fi
        rsync -a "$expectedNode:$expectedJobRoot/case/parametricStatus/${expectedCase}.status" "$staging/status" 2>/dev/null || true
        rsync -a "$expectedNode:$expectedJobRoot/case/parametricLogs/" "$staging/logs/" 2>/dev/null || true
        rsync -a "$expectedNode:$expectedJobRoot/case/paramDatabase/" "$staging/db/" 2>/dev/null || true
        if ! rsync -a "$expectedNode:$expectedJobRoot/PULL_COMPLETE" "$staging/PULL_COMPLETE"; then
            return 1
        fi
        rsync -a "$expectedNode:$expectedJobRoot/job.env" "$staging/job.env" 2>/dev/null || true
    fi

    marker="$staging/PULL_COMPLETE"
    [ -f "$marker" ] || return 1

    # Marker is shell-sourceable and includes the identity of this job.
    # shellcheck disable=SC1090
    . "$marker"
    markerSuite=${suiteId:-}
    markerJob=${jobId:-}
    markerTag=${tag:-}
    markerCase=${caseName:-}
    markerState=${state:-DONE}
    markerNode=${node:-$expectedNode}
    markerStart=${startTime:-}
    markerEnd=${endTime:-}
    markerElapsed=${elapsedTime:-}
    markerExit=${exitCode:-0}
    markerReason=${reason:-}

    if [ "$markerSuite" != "$DIST_SUITE_ID" ] || \
       [ "$markerJob" != "$expectedJob" ] || \
       [ "$markerTag" != "$expectedTag" ] || \
       [ "$markerCase" != "$expectedCase" ]; then
        ui_error "Ignoring stale or mismatched PULL_COMPLETE for $expectedJob"
        rm -rf "$staging"
        return 1
    fi

    if [ -z "$(find "$staging/archive" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        ui_error "PULL_COMPLETE without archive for $expectedJob"
        rm -rf "$staging"
        return 1
    fi

    mkdir -p "$tagDir/parametricStudy" "$tagDir/parametricStatus" \
             "$tagDir/parametricLogs" "$tagDir/paramDatabase" || return 1

    rm -rf "$tagDir/parametricStudy/$expectedCase"
    mv "$staging/archive" "$tagDir/parametricStudy/$expectedCase" || return 1

    if [ -f "$staging/status" ]; then
        cp -a "$staging/status" "$tagDir/parametricStatus/${expectedCase}.status" || return 1
    else
        PARAMETRIC_STATUS_DIR="$tagDir/parametricStatus" \
            status_set "$expectedCase" "$markerState" "$markerStart" \
                "$markerEnd" "$markerElapsed" "$markerExit" "$markerReason" \
                "$markerNode"
    fi

    if [ -d "$staging/logs" ]; then
        cp -a "$staging/logs/." "$tagDir/parametricLogs/" 2>/dev/null || true
    fi
    if [ -d "$staging/db" ]; then
        cp -a "$staging/db/." "$tagDir/paramDatabase/" 2>/dev/null || true
    fi

    mkdir -p "$SUITE_ROOT/jobs/$expectedJob"
    cp -a "$marker" "$SUITE_ROOT/jobs/$expectedJob/PULL_COMPLETE" 2>/dev/null || true
    [ -f "$staging/job.env" ] && \
        cp -a "$staging/job.env" "$SUITE_ROOT/jobs/$expectedJob/" 2>/dev/null || true

    rm -rf "$staging"
    distributed_remove_job "$expectedNode" "$expectedJobRoot"
    return 0
}

distributed_pull_failure() {
    local expectedNode=$1
    local expectedJobRoot=$2
    local expectedTag=$3
    local expectedCase=$4
    local expectedJob=$5
    local staging="$SUITE_ROOT/pull/$expectedJob"
    local tagDir="$CASE_DIR/tags/$expectedTag"
    local markerRc=1 markerReason="worker failed" markerNode=$expectedNode
    local suiteId jobId tag caseName node transport state exitCode reason
    local archivePath startTime endTime elapsedTime

    rm -rf "$staging"
    mkdir -p "$staging/logs" || return 1

    if [ "${DIST_NODE_TRANSPORT[$expectedNode]}" == "local" ]; then
        [ -f "$expectedJobRoot/case/parametricStatus/${expectedCase}.status" ] && \
            cp -a "$expectedJobRoot/case/parametricStatus/${expectedCase}.status" "$staging/status" || true
        [ -d "$expectedJobRoot/case/parametricLogs" ] && \
            cp -a "$expectedJobRoot/case/parametricLogs/." "$staging/logs/" || true
        [ -f "$expectedJobRoot/FAILED" ] && \
            cp -a "$expectedJobRoot/FAILED" "$staging/FAILED" || true
    else
        rsync -a "$expectedNode:$expectedJobRoot/case/parametricStatus/${expectedCase}.status" "$staging/status" 2>/dev/null || true
        rsync -a "$expectedNode:$expectedJobRoot/case/parametricLogs/" "$staging/logs/" 2>/dev/null || true
        rsync -a "$expectedNode:$expectedJobRoot/FAILED" "$staging/FAILED" 2>/dev/null || true
    fi

    if [ -f "$staging/FAILED" ]; then
        # shellcheck disable=SC1090
        . "$staging/FAILED"
        markerRc=${exitCode:-1}
        markerReason=${reason:-worker failed}
        markerNode=${node:-$expectedNode}
    fi

    mkdir -p "$tagDir/parametricStatus" "$tagDir/parametricLogs" \
             "$tagDir/paramDatabase" "$SUITE_ROOT/jobs/$expectedJob"

    if [ -f "$staging/status" ]; then
        cp -a "$staging/status" "$tagDir/parametricStatus/${expectedCase}.status" || true
    else
        PARAMETRIC_STATUS_DIR="$tagDir/parametricStatus" \
            status_set "$expectedCase" FAILED "" "" "" "$markerRc" "$markerReason" \
                "$markerNode"
    fi

    if [ -d "$staging/logs" ]; then
        cp -a "$staging/logs/." "$tagDir/parametricLogs/" 2>/dev/null || true
    fi
    [ -f "$staging/FAILED" ] && \
        cp -a "$staging/FAILED" "$SUITE_ROOT/jobs/$expectedJob/" 2>/dev/null || true

    rm -rf "$staging"
    return 0
}

distributed_remove_job() {
    local node=$1
    local jobRoot=$2

    if [ "${DIST_NODE_TRANSPORT[$node]}" == "local" ]; then
        rm -rf "$jobRoot"
    else
        distributed_ssh "$node" "rm -rf '$jobRoot'" >/dev/null 2>&1 || true
    fi
}

distributed_pick_node() {
    local node active best="" bestActive=0 bestRank=0

    for node in "${DIST_RANK_ORDER[@]}"; do
        [ "${DIST_NODE_ONLINE[$node]:-0}" -eq 1 ] || continue
        active=${DIST_NODE_ACTIVE[$node]:-0}
        [ "$active" -lt "${DIST_NODE_SLOTS[$node]:-0}" ] || continue

        if [ -z "$best" ] || \
           [ "$active" -lt "$bestActive" ] || \
           { [ "$active" -eq "$bestActive" ] && [ "${DIST_NODE_RANK[$node]}" -lt "$bestRank" ]; }; then
            best=$node
            bestActive=$active
            bestRank=${DIST_NODE_RANK[$node]}
        fi
    done

    [ -n "$best" ] || return 1
    printf '%s' "$best"
}

distributed_mark_failed() {
    local tag=$1
    local caseName=$2
    local node=$3
    local reason=$4
    local values=$5

    local start end elapsed
    PARAMETRIC_STATUS_DIR="$CASE_DIR/tags/$tag/parametricStatus" \
        status_load "$caseName"
    start=${ST_START:-$(date +%s)}
    end=$(date +%s)
    elapsed=$((end - start))
    PARAMETRIC_STATUS_DIR="$CASE_DIR/tags/$tag/parametricStatus" \
        status_set "$caseName" FAILED "$start" "$end" "$elapsed" "1" \
            "$reason" "$node"
    SUITE_CASE_NODE["$tag|$caseName"]=$node
    suite_report_case_result "$tag" "$caseName"
    suite_update_tag_status "$tag" >/dev/null 2>&1 || true
}

distributed_run_queue() {
    local i=0
    local total=${#SUITE_Q_TAG[@]}
    local activeTotal=0
    local node tag caseName values jobId job status details
    local launched
    local attempts
    local nodeCount=${#DIST_RANK_ORDER[@]}

    if [ "$DIST_ENABLED" -ne 1 ]; then
        return 1
    fi

    DIST_ACTIVE=()
    DIST_JOB_NODE=()
    DIST_JOB_TAG=()
    DIST_JOB_CASE=()
    DIST_JOB_VALUES=()
    DIST_JOB_ROOT=()

    distributed_sync_all || return 1

    while [ "$i" -lt "$total" ] || [ "$activeTotal" -gt 0 ]; do

        local stopLaunch=0 anyOnline
        while [ "$i" -lt "$total" ] && [ "$stopLaunch" -eq 0 ]; do

            launched=0
            attempts=0

            while [ "$attempts" -lt "$nodeCount" ]; do
                node=$(distributed_pick_node) || break
                attempts=$((attempts + 1))
                tag=${SUITE_Q_TAG[$i]}
                caseName=${SUITE_Q_CASE[$i]}
                values=${SUITE_Q_VALUES[$i]}
                jobId="${DIST_SUITE_ID}-${caseName}"

                if distributed_launch_case "$node" "$tag" "$caseName" "$values" "$jobId"; then
                    DIST_ACTIVE[$jobId]=1
                    DIST_JOB_NODE[$jobId]=$node
                    DIST_JOB_TAG[$jobId]=$tag
                    DIST_JOB_CASE[$jobId]=$caseName
                    DIST_JOB_VALUES[$jobId]=$values
                    DIST_JOB_ROOT[$jobId]=$JOB_ROOT
                    DIST_NODE_ACTIVE[$node]=$(( ${DIST_NODE_ACTIVE[$node]:-0} + 1 ))
                    activeTotal=$((activeTotal + 1))
                    SUITE_CASE_NODE["$tag|$caseName"]=$node
                    PARAMETRIC_STATUS_DIR="$CASE_DIR/tags/$tag/parametricStatus" \
                        status_set "$caseName" RUNNING "$(date +%s)" "" "" "" "" "$node"
                    details=$(suite_case_parameters "$tag" "$values")
                    ui_info "Launching $tag/$caseName on $node${details:+  ($details)}"
                    launched=1
                    break
                fi

                DIST_NODE_ONLINE[$node]=0
                ui_warn "Node $node failed to accept $tag/$caseName"
            done

            if [ "$launched" -eq 0 ]; then
                anyOnline=0
                for node in "${DIST_RANK_ORDER[@]}"; do
                    [ "${DIST_NODE_ONLINE[$node]:-0}" -eq 1 ] && anyOnline=1
                done

                if [ "$anyOnline" -eq 0 ]; then
                    tag=${SUITE_Q_TAG[$i]}
                    caseName=${SUITE_Q_CASE[$i]}
                    values=${SUITE_Q_VALUES[$i]}
                    distributed_mark_failed "$tag" "$caseName" "-" \
                        "no online node accepted the job" "$values"
                    i=$((i + 1))
                    continue
                fi

                # Online nodes exist but all slots are currently busy.
                stopLaunch=1
                break
            fi

            i=$((i + 1))
        done

        for job in "${!DIST_ACTIVE[@]}"; do
            node=${DIST_JOB_NODE[$job]}
            tag=${DIST_JOB_TAG[$job]}
            caseName=${DIST_JOB_CASE[$job]}
            values=${DIST_JOB_VALUES[$job]}
            status=$(distributed_job_status "$node" "${DIST_JOB_ROOT[$job]}")

            case "$status" in
                complete)
                    if distributed_pull_success "$node" "${DIST_JOB_ROOT[$job]}" \
                        "$tag" "$caseName" "$job"; then
                        suite_report_case_result "$tag" "$caseName"
                        suite_update_tag_status "$tag" >/dev/null 2>&1 || true
                    else
                        distributed_mark_failed "$tag" "$caseName" "$node" \
                            "result pull failed" "$values"
                    fi
                    unset 'DIST_ACTIVE[$job]'
                    activeTotal=$((activeTotal - 1))
                    DIST_NODE_ACTIVE[$node]=$(( ${DIST_NODE_ACTIVE[$node]:-1} - 1 ))
                    ;;
                failed)
                    distributed_pull_failure "$node" "${DIST_JOB_ROOT[$job]}" \
                        "$tag" "$caseName" "$job"
                    suite_report_case_result "$tag" "$caseName"
                    suite_update_tag_status "$tag" >/dev/null 2>&1 || true
                    unset 'DIST_ACTIVE[$job]'
                    activeTotal=$((activeTotal - 1))
                    DIST_NODE_ACTIVE[$node]=$(( ${DIST_NODE_ACTIVE[$node]:-1} - 1 ))
                    ;;
                unreachable)
                    DIST_NODE_ONLINE[$node]=0
                    distributed_mark_failed "$tag" "$caseName" "$node" \
                        "node unreachable" "$values"
                    unset 'DIST_ACTIVE[$job]'
                    activeTotal=$((activeTotal - 1))
                    DIST_NODE_ACTIVE[$node]=$(( ${DIST_NODE_ACTIVE[$node]:-1} - 1 ))
                    ;;
                missing)
                    distributed_pull_failure "$node" "${DIST_JOB_ROOT[$job]}" \
                        "$tag" "$caseName" "$job"
                    distributed_mark_failed "$tag" "$caseName" "$node" \
                        "worker exited without PULL_COMPLETE" "$values"
                    unset 'DIST_ACTIVE[$job]'
                    activeTotal=$((activeTotal - 1))
                    DIST_NODE_ACTIVE[$node]=$(( ${DIST_NODE_ACTIVE[$node]:-1} - 1 ))
                    ;;
            esac
        done

        if [ "$activeTotal" -gt 0 ]; then
            sleep 1
        fi
    done

    suite_report_finished_cases

    local t
    for t in "${SUITE_TAGS[@]}"; do
        suite_update_tag_status "$t" >/dev/null 2>&1 || true
    done

    rmdir "$SUITE_ROOT/jobs/$DIST_SUITE_ID" 2>/dev/null || true
    rmdir "$SUITE_ROOT/pull" 2>/dev/null || true

    return 0
}

distributed_cleanup_remote() {
    local scope=$1
    shift
    local -a cleanTags=("$@")
    local file line name transport rank cores temp rest
    local home tag

    distributed_enabled || return 0

    file=$(distributed_nodes_file)
    [ -f "$file" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%%#*}
        read -r name transport rank cores temp rest <<< "$line"
        [ -z "${name:-}" ] && continue
        [ "${transport:-}" == "ssh" ] || continue

        if [ "${temp:-}" == "auto" ]; then
            home=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$name" \
                'printf "%s" "$HOME"' 2>/dev/null) || {
                ui_warn "Node $name: cannot resolve temp root for cleanup"
                continue
            }
            temp="$home/.parametricStudy"
        fi

        if [ "$scope" == "all" ]; then
            ssh -o BatchMode=yes -o ConnectTimeout=10 "$name" \
                "rm -rf '$temp/jobs' '$temp/bases'" >/dev/null 2>&1 || \
                ui_warn "Node $name: remote cleanup failed"
        else
            for tag in "${cleanTags[@]}"; do
                ssh -o BatchMode=yes -o ConnectTimeout=10 "$name" \
                    "rm -rf '$temp/jobs'/*/'$tag' '$temp/bases/$tag'" \
                    >/dev/null 2>&1 || \
                    ui_warn "Node $name: remote cleanup failed for tag $tag"
            done
        fi
    done < "$file"
}

# --------------------------------------------------
# Worker side
# --------------------------------------------------

distributed_worker_write_marker() {
    local marker=$1
    local state=$2
    local rc=$3
    local reason=$4
    local caseName=$5
    local tag=$6
    local node=$7
    local transport=$8
    local archive=$9
    local start=${10:-}
    local end=${11:-}
    local elapsed=${12:-}
    local jobRoot
    local tmp

    jobRoot=$(dirname "$marker")
    tmp="${marker}.tmp.$$"

    {
        printf 'suiteId=%q\n' "$DIST_SUITE_ID"
        printf 'jobId=%q\n' "${PARAMETRIC_JOB_ID:-}"
        printf 'tag=%q\n' "$tag"
        printf 'caseName=%q\n' "$caseName"
        printf 'node=%q\n' "$node"
        printf 'transport=%q\n' "$transport"
        printf 'state=%q\n' "$state"
        printf 'exitCode=%q\n' "$rc"
        printf 'reason=%q\n' "${reason//$'\n'/ }"
        printf 'archivePath=%q\n' "$archive"
        printf 'startTime=%q\n' "$start"
        printf 'endTime=%q\n' "$end"
        printf 'elapsedTime=%q\n' "$elapsed"
    } > "$tmp" && mv "$tmp" "$marker"
}

distributed_worker_run() {
    local jobFile=${PARAMETRIC_JOB_FILE:-}
    local jobRoot caseName values tag nodeName transport jobId
    local rc=0 reason start end elapsed
    local archiveDir
    local SUITE_ID JOB_ID TAG CASE_NAME CASE_VALUES NODE_NAME TRANSPORT

    if [ -z "$jobFile" ] || [ ! -f "$jobFile" ]; then
        ui_error "Worker job file not found: $jobFile"
        return 1
    fi

    # shellcheck disable=SC1090
    . "$jobFile"

    caseName=${CASE_NAME:-}
    values=${CASE_VALUES:-}
    tag=${TAG:-untagged}
    nodeName=${NODE_NAME:-local}
    transport=${TRANSPORT:-local}
    jobId=${JOB_ID:-}
    DIST_SUITE_ID=${SUITE_ID:-${DIST_SUITE_ID:-}}
    jobRoot=$(dirname "$jobFile")

    if [ -z "$caseName" ] || [ -z "$jobId" ] || [ -z "$DIST_SUITE_ID" ]; then
        ui_error "Worker job file is incomplete: $jobFile"
        return 1
    fi

    export PARAMETRIC_TAG="$tag"
    export PARAMETRIC_NODE_ALIAS="$nodeName"
    export PARAMETRIC_TRANSPORT="$transport"
    export PARAMETRIC_SUITE_ID="$DIST_SUITE_ID"
    export PARAMETRIC_JOB_ID="$jobId"

    PARAMETRIC_STUDY_DIR="$CASE_DIR/parametricStudy"
    PARAMETRIC_WORK_DIR="$CASE_DIR/parametricWork"
    PARAMETRIC_LOG_DIR="$CASE_DIR/parametricLogs"
    PARAMETRIC_STATUS_DIR="$CASE_DIR/parametricStatus"

    mkdir -p "$PARAMETRIC_STUDY_DIR" "$PARAMETRIC_WORK_DIR" \
             "$PARAMETRIC_LOG_DIR" "$PARAMETRIC_STATUS_DIR" || return 1

    load_config >/dev/null 2>&1 || {
        ui_error "Worker configuration failed for $tag/$caseName"
        distributed_worker_write_marker "$jobRoot/FAILED" "FAILED" 1 \
            "configuration failed" "$caseName" "$tag" "$nodeName" "$transport" ""
        return 1
    }

    run_case "$caseName" "$values" > "$PARAMETRIC_LOG_DIR/worker.${caseName}.log" 2>&1
    rc=$?

    PARAMETRIC_STATUS_DIR="$PARAMETRIC_STATUS_DIR" status_load "$caseName"
    start=$ST_START
    end=$ST_END
    elapsed=$ST_ELAPSED
    reason=$ST_REASON
    archiveDir="$PARAMETRIC_STUDY_DIR/$caseName"

    if [ "$rc" -eq 0 ] && [ -d "$archiveDir" ]; then
        distributed_worker_write_marker "$jobRoot/PULL_COMPLETE" "DONE" 0 "" \
            "$caseName" "$tag" "$nodeName" "$transport" "$archiveDir" \
            "$start" "$end" "$elapsed"
    else
        [ "$rc" -eq 0 ] && rc=1
        [ -z "$reason" ] && reason="worker failed with exit code $rc"
        [ ! -d "$archiveDir" ] && [ "$rc" -eq 1 ] && \
            reason="case archive was not created"
        distributed_worker_write_marker "$jobRoot/FAILED" "FAILED" "$rc" "$reason" \
            "$caseName" "$tag" "$nodeName" "$transport" "$archiveDir" \
            "$start" "$end" "$elapsed"
    fi

    return "$rc"
}
