#!/bin/bash

# Detect whether this process is running inside a container.
is_container_environment() {

    if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
        return 0
    fi

    if [ -n "${container:-}" ] || [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; then
        return 0
    fi

    if grep -qaE 'docker|containerd|kubepods|lxc' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi

    return 1
}

node_map_file() {

    local coreDir=${PARAMETRIC_CORE_DIR:-}

    if [ -z "$coreDir" ]; then
        coreDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    fi

    printf '%s/nodeMap.csv' "$coreDir"
}

# Warn about rows that can never be selected because an earlier row already
# uses the same key.
validate_node_map() {

    local mapFile keyType key hostUser hostIp nodeValue combo
    local -A seen=()
    local -A warned=()

    mapFile=$(node_map_file)
    [ -f "$mapFile" ] || return 0

    while IFS=, read -r keyType key hostUser hostIp nodeValue; do

        keyType=${keyType//[[:space:]]/}
        key=${key//[[:space:]]/}
        hostUser=${hostUser//[[:space:]]/}
        hostIp=${hostIp//[[:space:]]/}

        [ -z "$keyType" ] && continue

        case "$keyType" in
            \#*|keyType) continue ;;
        esac

        [ -z "$key" ] && continue

        if [ -z "$hostUser" ] || [ -z "$hostIp" ]; then
            ui_warn "core/nodeMap.csv: incomplete row for key '$key' (need hostUser and hostIp)"
            continue
        fi

        combo="${keyType},${key}"

        if [ -n "${seen[$combo]+x}" ]; then
            if [ -z "${warned[$combo]+x}" ]; then
                ui_warn "core/nodeMap.csv: duplicate key '$combo'; only the first row can match"
                warned[$combo]=1
            fi
        else
            seen[$combo]=1
        fi

    done < "$mapFile"
}

# Look up a container identity in core/nodeMap.csv.
#
# CSV columns:
#   keyType,key,hostUser,hostIp,node
#
# keyType is one of:
#   containerUser  containerIp  hostname  workspaceUid
#
# On success sets MAP_HOST_USER, MAP_HOST_IP, MAP_NODE, MAP_MATCH.
lookup_node_map() {

    local candidateUser=$1
    local candidateIp=$2
    local candidateHost=$3
    local candidateUid=$4
    local mapFile keyType key hostUser hostIp nodeValue matched

    MAP_HOST_USER=""
    MAP_HOST_IP=""
    MAP_NODE=""
    MAP_MATCH=""

    mapFile=$(node_map_file)
    [ -f "$mapFile" ] || return 1

    while IFS=, read -r keyType key hostUser hostIp nodeValue; do

        keyType=${keyType//[[:space:]]/}
        key=${key//[[:space:]]/}
        hostUser=${hostUser//[[:space:]]/}
        hostIp=${hostIp//[[:space:]]/}
        nodeValue=${nodeValue//[[:space:]]/}

        [ -z "$keyType" ] && continue

        case "$keyType" in
            \#*|keyType) continue ;;
        esac

        [ -z "$key" ] && continue
        [ -z "$hostUser" ] && continue
        [ -z "$hostIp" ] && continue

        matched=0

        case "$keyType" in
            containerUser|container-user|user)
                [ "$key" == "$candidateUser" ] && matched=1
                ;;
            containerIp|container-ip|ip)
                [ "$key" == "$candidateIp" ] && matched=1
                ;;
            hostname|containerHostname|container-hostname)
                [ "$key" == "$candidateHost" ] && matched=1
                ;;
            workspaceUid|workspace-uid|uid)
                [ "$key" == "$candidateUid" ] && matched=1
                ;;
        esac

        if [ "$matched" -eq 1 ]; then
            MAP_HOST_USER=$hostUser
            MAP_HOST_IP=$hostIp
            MAP_NODE=${nodeValue:-${hostUser}@${hostIp}}
            MAP_MATCH="${keyType}=${key}"
            return 0
        fi

    done < "$mapFile"

    return 1
}

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

    # --------------------------------------------------
    # Execution identity
    # --------------------------------------------------
    # A Docker container cannot see the host login name or LAN IP by
    # default.  Provide them from the host wrapper with
    # PARAMETRIC_HOST_USER / PARAMETRIC_HOST_IP, or add a matching row
    # to core/nodeMap.csv.  Without either, the container identity is
    # recorded with a warning.
    #
    #   runUser        : user that ran the case
    #   nodeIp         : IP of the execution machine
    #   sshIp          : IP the user connected from (blank if local)
    #   node           : runUser@nodeIp
    #   identitySource : local | host-env | host-map | container

    detectedUser=${PARAMETRIC_USER:-}
    [ -z "$detectedUser" ] && detectedUser=$(id -un 2>/dev/null)
    [ -z "$detectedUser" ] && detectedUser=${USER:-}
    [ -z "$detectedUser" ] && detectedUser=$(whoami 2>/dev/null)

    detectedIp=${PARAMETRIC_NODE_IP:-}
    if [ -z "$detectedIp" ]; then
        detectedIp=$(ip route get 1.1.1.1 2>/dev/null | \
            awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    fi
    if [ -z "$detectedIp" ]; then
        detectedIp=$(hostname -I 2>/dev/null | tr ' ' '\n' | \
            grep -vE '^$|^127\.|^::1$' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n1)
    fi
    if [ -z "$detectedIp" ]; then
        detectedIp=$(hostname -I 2>/dev/null | tr ' ' '\n' | \
            grep -vE '^$|^127\.|^::1$' | head -n1)
    fi
    if [ -z "$detectedIp" ]; then
        detectedIp=$(hostname -i 2>/dev/null | awk '{print $1}' | grep -vE '^$|^127\.')
    fi
    if [ -z "$detectedIp" ]; then
        detectedIp=$(ip -4 -o addr show scope global 2>/dev/null | \
            awk '{print $4}' | cut -d/ -f1 | head -n1)
    fi

    detectedSshIp=${PARAMETRIC_SSH_IP:-}
    if [ -z "$detectedSshIp" ] && [ -n "${SSH_CONNECTION:-}" ]; then
        detectedSshIp=${SSH_CONNECTION%% *}
    fi
    if [ -z "$detectedSshIp" ] && [ -n "${SSH_CLIENT:-}" ]; then
        detectedSshIp=${SSH_CLIENT%% *}
    fi

    inContainer=0
    if is_container_environment; then
        inContainer=1
    fi

    identitySource=""
    runUser=""
    nodeIp=""
    mappedNode=""

    # 1. Host identity passed explicitly by the Docker wrapper.
    hostUser=${PARAMETRIC_HOST_USER:-}
    hostIp=${PARAMETRIC_HOST_IP:-}

    if [ -n "$hostUser" ] && [ -n "$hostIp" ]; then
        runUser=$hostUser
        nodeIp=$hostIp
        identitySource="host-env"
    elif [ -n "$hostUser" ] || [ -n "$hostIp" ]; then
        ui_warn "Set both PARAMETRIC_HOST_USER and PARAMETRIC_HOST_IP; partial host identity ignored"
    fi

    # 2. Mapping table fallback for container runs.
    if [ -z "$identitySource" ] && [ "$inContainer" -eq 1 ]; then

        workspaceUid=$(stat -c %u . 2>/dev/null)
        containerHost=$(hostname 2>/dev/null)

        validate_node_map

        if lookup_node_map "$detectedUser" "$detectedIp" "$containerHost" "$workspaceUid"; then
            runUser=$MAP_HOST_USER
            nodeIp=$MAP_HOST_IP
            mappedNode=$MAP_NODE
            identitySource="host-map"
            ui_info "Host identity matched core/nodeMap.csv ($MAP_MATCH)"
        fi
    fi

    # 3. Fall back to the identity detected in this environment.
    if [ -z "$identitySource" ]; then
        runUser=$detectedUser
        nodeIp=$detectedIp

        if [ "$inContainer" -eq 1 ]; then
            identitySource="container"
            ui_warn "Running inside a container and no host identity matched"
            ui_warn "Recording container identity; pass PARAMETRIC_HOST_USER/PARAMETRIC_HOST_IP or add core/nodeMap.csv"
        else
            identitySource="local"
        fi
    fi

    sshIp=$detectedSshIp
    node=${PARAMETRIC_NODE:-${mappedNode:-${runUser}@${nodeIp}}}

    if [ -z "$runUser" ]; then
        ui_error "Cannot determine the execution user; set PARAMETRIC_USER or PARAMETRIC_HOST_USER"
        exit 1
    fi

    if [ -z "$nodeIp" ]; then
        ui_error "Cannot determine the execution node IP; set PARAMETRIC_NODE_IP or PARAMETRIC_HOST_IP"
        exit 1
    fi

    export runUser nodeIp sshIp node identitySource

    coreScreening=$(foamDictionary "$PARAM_DICT" -entry coreScreening -value 2>/dev/null)
    coreListRaw=$(foamDictionary "$PARAM_DICT" -entry coreList -value 2>/dev/null)
    optimalCore=$(foamDictionary "$PARAM_DICT" -entry optimalCore -value 2>/dev/null)

    coreScreening=${coreScreening:-false}
    coreList=($(echo "$coreListRaw" | tr -d '();'))

    availableCores=$(foamDictionary "$PARAM_DICT" -entry availableCores -value 2>/dev/null)
    maxConcurrentCases=$(foamDictionary "$PARAM_DICT" -entry maxConcurrentCases -value 2>/dev/null)
    continueFromPrevious=$(foamDictionary "$PARAM_DICT" -entry continueFromPrevious -value 2>/dev/null)
    paramTimeZone=$(foamDictionary "$PARAM_DICT" -entry logTimeZone -value 2>/dev/null | tr -d '"[:space:]')

    # Human-readable log time zone.  Change this line or set
    # logTimeZone in paramDict.  Examples: Asia/Kolkata, UTC, Europe/London.
    LOG_TIMEZONE=${paramTimeZone:-${LOG_TIMEZONE:-Asia/Kolkata}}
    export LOG_TIMEZONE

    availableCores=${availableCores:-$(nproc)}
    maxConcurrentCases=${maxConcurrentCases:-auto}
    continueFromPrevious=${continueFromPrevious:-false}

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
    ui_kv "User" "$runUser"
    ui_kv "Node" "$node"
    ui_kv "IP" "$nodeIp"
    [ -n "$sshIp" ] && ui_kv "SSH from" "$sshIp"
    ui_kv "Identity source" "$identitySource"
    ui_kv "Case prefix" "$prefix"
    ui_kv "Parameters" "${paramNames[*]}"
    ui_kv "Processors / case" "$processors"
    ui_kv "Available cores" "$availableCores"
    ui_kv "Concurrent cases" "$maxConcurrentCases"
    ui_kv "Continue from previous" "$continueFromPrevious"
    ui_kv "Log time zone" "$LOG_TIMEZONE"

    if is_true "$coreScreening"; then
        ui_kv "Core screening" "enabled"
        ui_kv "Core list" "${coreList[*]}"
        ui_kv "Optimal core" "${optimalCore:-auto}"
    fi
}
