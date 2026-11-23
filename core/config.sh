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
    # default.  Pass them from the host wrapper with
    # PARAMETRIC_HOST_USER, PARAMETRIC_HOST_IP, and optionally
    # PARAMETRIC_HOST_NODE.  Without them, the container identity is
    # recorded with a warning.
    #
    #   runUser        : user that ran the case
    #   nodeIp         : IP of the execution machine
    #   sshIp          : IP the user connected from (blank if local)
    #   node           : PARAMETRIC_HOST_NODE, or runUser@nodeIp
    #   identitySource : local | host-env | container

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

    detectedSshHost=${PARAMETRIC_SSH_HOST:-}
    if [ -z "$detectedSshHost" ] && [ -n "$detectedSshIp" ]; then
        detectedSshHost=$(getent hosts "$detectedSshIp" 2>/dev/null | awk '{print $2; exit}')
    fi
    if [ -z "$detectedSshHost" ] && [ -n "$detectedSshIp" ] && \
       command -v dig >/dev/null 2>&1; then
        detectedSshHost=$(dig +short +time=1 +tries=1 -x "$detectedSshIp" 2>/dev/null | \
            sed 's/\.$//' | head -n1)
    fi

    inContainer=0
    if is_container_environment; then
        inContainer=1
    fi

    identitySource=""
    runUser=""
    nodeIp=""

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

    # 2. Fall back to the identity detected in this environment.
    if [ -z "$identitySource" ]; then
        runUser=$detectedUser
        nodeIp=$detectedIp

        if [ "$inContainer" -eq 1 ]; then
            identitySource="container"
            ui_warn "Running inside a container and no host identity was passed"
            ui_warn "Recording container identity; set PARAMETRIC_HOST_USER and PARAMETRIC_HOST_IP in docker run"
        else
            identitySource="local"
        fi
    fi

    sshIp=$detectedSshIp
    sshHost=$detectedSshHost
    hostNode=${PARAMETRIC_HOST_NODE:-${PARAMETRIC_NODE:-}}
    node=${hostNode:-${runUser}@${nodeIp}}

    if [ -z "$runUser" ]; then
        ui_error "Cannot determine the execution user; set PARAMETRIC_USER or PARAMETRIC_HOST_USER"
        exit 1
    fi

    if [ -z "$nodeIp" ]; then
        ui_error "Cannot determine the execution node IP; set PARAMETRIC_NODE_IP or PARAMETRIC_HOST_IP"
        exit 1
    fi

    export runUser nodeIp sshIp sshHost node identitySource

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
    if [ -n "$sshHost" ] && [ -n "$sshIp" ]; then
        ui_kv "SSH from" "$sshHost ($sshIp)"
    elif [ -n "$sshHost" ]; then
        ui_kv "SSH from" "$sshHost"
    elif [ -n "$sshIp" ]; then
        ui_kv "SSH from" "$sshIp"
    fi
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
