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

    # Automatic execution identity.  These values are derived from the
    # running session, so they cannot be mistyped in paramDict.
    #
    #   runUser : user running the case
    #   nodeIp  : IP of the machine that actually executes the case
    #   sshIp   : IP of the machine the user connected from (blank if local)
    #   node    : runUser@nodeIp
    #
    # Override any of them with PARAMETRIC_USER, PARAMETRIC_NODE_IP,
    # PARAMETRIC_SSH_IP, or PARAMETRIC_NODE when the automatic values are
    # not suitable (containers, schedulers, unusual networks).

    runUser=${PARAMETRIC_USER:-}
    [ -z "$runUser" ] && runUser=$(id -un 2>/dev/null)
    [ -z "$runUser" ] && runUser=${USER:-}
    [ -z "$runUser" ] && runUser=$(whoami 2>/dev/null)

    nodeIp=${PARAMETRIC_NODE_IP:-}
    if [ -z "$nodeIp" ]; then
        nodeIp=$(ip route get 1.1.1.1 2>/dev/null | \
            awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    fi
    if [ -z "$nodeIp" ]; then
        nodeIp=$(hostname -I 2>/dev/null | tr ' ' '\n' | \
            grep -vE '^$|^127\.|^::1$' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n1)
    fi
    if [ -z "$nodeIp" ]; then
        nodeIp=$(hostname -I 2>/dev/null | tr ' ' '\n' | \
            grep -vE '^$|^127\.|^::1$' | head -n1)
    fi
    if [ -z "$nodeIp" ]; then
        nodeIp=$(hostname -i 2>/dev/null | awk '{print $1}' | grep -vE '^$|^127\.')
    fi
    if [ -z "$nodeIp" ]; then
        nodeIp=$(ip -4 -o addr show scope global 2>/dev/null | \
            awk '{print $4}' | cut -d/ -f1 | head -n1)
    fi

    sshIp=${PARAMETRIC_SSH_IP:-}
    if [ -z "$sshIp" ] && [ -n "${SSH_CONNECTION:-}" ]; then
        sshIp=${SSH_CONNECTION%% *}
    fi
    if [ -z "$sshIp" ] && [ -n "${SSH_CLIENT:-}" ]; then
        sshIp=${SSH_CLIENT%% *}
    fi

    if [ -z "$runUser" ]; then
        ui_error "Cannot determine the execution user; set PARAMETRIC_USER"
        exit 1
    fi

    if [ -z "$nodeIp" ]; then
        ui_error "Cannot determine the execution node IP; set PARAMETRIC_NODE_IP"
        exit 1
    fi

    node=${PARAMETRIC_NODE:-${runUser}@${nodeIp}}
    export runUser nodeIp sshIp node

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
