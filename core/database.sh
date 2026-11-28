#!/bin/bash

# --------------------------------------------------
# Case matrix and result table
#
# paramDatabase/caseMatrix.csv is the authoritative
# source of submitted parameter values.
#
# paramDatabase/paramTable.csv contains:
#   metadata + paramDict parameters + calculationScript
#   constants (excluding paramDict parameters).
# --------------------------------------------------

calc_script_all_keys() {

    local scriptFile=$1
    local line key value
    local p isParam

    [ -f "$scriptFile" ] || return 0

    while IFS= read -r line; do

        line=${line%%//*}
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+([^;]+)\; ]] || continue

        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}

        case "$key" in
            version|format|class|location|object|arch|note) continue ;;
        esac

        isParam=0
        for p in "${paramNames[@]}"; do
            if [ "$key" == "$p" ]; then
                isParam=1
                break
            fi
        done
        [ "$isParam" -eq 1 ] && continue

        printf '%s\n' "$key"

    done < "$scriptFile" | awk '!seen[$0]++'
}

calc_resolved_value() {

    local resolvedFile=$1
    local wanted=$2
    local line key value

    [ -f "$resolvedFile" ] || return 0

    while IFS= read -r line; do

        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+([^;]+)\; ]] || continue

        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}

        if [ "$key" == "$wanted" ]; then
            printf '%s' "$value"
            return 0
        fi

    done < "$resolvedFile"
}

calc_script_keys() {

    local scriptFile=$1
    local line key value
    local p isParam

    [ -f "$scriptFile" ] || return 0

    while IFS= read -r line; do

        line=${line%%//*}
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+([^;]+)\; ]] || continue

        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}

        case "$key" in
            version|format|class|location|object|arch|note) continue ;;
        esac

        # Expressions are not table constants.
        case "$value" in
            *'#calc'*|*'$'*) continue ;;
        esac

        isParam=0
        for p in "${paramNames[@]}"; do
            if [ "$key" == "$p" ]; then
                isParam=1
                break
            fi
        done
        [ "$isParam" -eq 1 ] && continue

        printf '%s\n' "$key"

    done < "$scriptFile" | awk '!seen[$0]++'
}

calc_script_value() {

    local scriptFile=$1
    local wanted=$2
    local line key value

    [ -f "$scriptFile" ] || return 0

    while IFS= read -r line; do

        line=${line%%//*}
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+([^;]+)\; ]] || continue

        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}

        case "$key" in
            version|format|class|location|object|arch|note) continue ;;
        esac

        if [ "$key" == "$wanted" ]; then
            printf '%s' "$value"
            return 0
        fi

    done < "$scriptFile"
}

load_old_timing() {

    local outputFile=$1
    local caseName header line
    local -a fields=()
    local i idx

    declare -gA OLD_START=()
    declare -gA OLD_END=()
    declare -gA OLD_ELAPSED=()
    declare -gA OLD_STUDY=()
    declare -gA OLD_TAG=()
    declare -gA OLD_COMMENT=()
    declare -gA OLD_NOTE=()
    declare -gA OLD_NODE=()
    declare -gA OLD_NODE_ALIAS=()
    declare -gA OLD_USER=()
    declare -gA OLD_IP=()
    declare -gA OLD_SSH=()
    declare -gA OLD_IDENTITY=()
    declare -gA OLD_TRANSPORT=()
    declare -gA OLD_SUITE=()
    declare -gA OLD_JOB=()
    declare -gA OLD_STATUS=()
    declare -gA OLD_REASON=()
    declare -gA OLD_EXIT=()
    declare -gA OLD_ROW=()
    declare -gA OLD_INDEX=()
    declare -g OLD_HAS_NODE=0

    [ -f "$outputFile" ] || return 0

    IFS= read -r header < "$outputFile" || return 0
    IFS=, read -r -a fields <<< "$header"
    for ((i=0;i<${#fields[@]};i++)); do
        OLD_INDEX["${fields[$i]}"]=$i
    done

    [ -n "${OLD_INDEX[node]:-}" ] && OLD_HAS_NODE=1

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        IFS=, read -r -a fields <<< "$line"

        caseName="${fields[0]:-}"
        [ -z "$caseName" ] && continue
        [ "$caseName" == "caseName" ] && continue

        # Read by column name so tables with and without `node` both work.
        idx=${OLD_INDEX[studyType]:-}
        [ -n "$idx" ] && OLD_STUDY[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[runTag]:-}
        [ -n "$idx" ] && OLD_TAG[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[runComment]:-}
        [ -n "$idx" ] && OLD_COMMENT[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[authorNote]:-}
        [ -n "$idx" ] && OLD_NOTE[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[node]:-}
        [ -n "$idx" ] && OLD_NODE[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[nodeAlias]:-}
        [ -n "$idx" ] && OLD_NODE_ALIAS[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[user]:-}
        [ -n "$idx" ] && OLD_USER[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[ip]:-}
        [ -n "$idx" ] && OLD_IP[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[sshIp]:-}
        [ -n "$idx" ] && OLD_SSH[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[identitySource]:-}
        [ -n "$idx" ] && OLD_IDENTITY[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[transport]:-}
        [ -n "$idx" ] && OLD_TRANSPORT[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[suiteId]:-}
        [ -n "$idx" ] && OLD_SUITE[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[jobId]:-}
        [ -n "$idx" ] && OLD_JOB[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[startTime]:-}
        [ -n "$idx" ] && OLD_START[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[endTime]:-}
        [ -n "$idx" ] && OLD_END[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX["elapsedTime (s)"]:-}
        [ -n "$idx" ] && OLD_ELAPSED[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[status]:-}
        [ -n "$idx" ] && OLD_STATUS[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[reason]:-}
        [ -n "$idx" ] && OLD_REASON[$caseName]="${fields[$idx]:-}"

        idx=${OLD_INDEX[exitCode]:-}
        [ -n "$idx" ] && OLD_EXIT[$caseName]="${fields[$idx]:-}"

        OLD_ROW[$caseName]="$line"
    done < <(tail -n +2 "$outputFile")
}

# Read run metadata from an archived paramDict.
#
# Archived cases keep the paramDict that was used when the case ran,
# so it is the reliable record of that case's study type and comments.
# Prints unit-separated fields:
#   studyType, runTag, runComment, authorNote,
#   node, runUser, nodeIp, sshIp, identitySource
read_archived_metadata() {

    local dictFile=$1

    [ -f "$dictFile" ] || return 1

    awk '
        /^[[:space:]]*(studyType|runTag|runComment|authorNote|node|nodeAlias|runUser|nodeIp|sshIp|identitySource|transport|suiteId|jobId)[[:space:]]/ {
            key=$1
            sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "")
            sub(/;.*$/, "")
            sub(/[[:space:]]+$/, "")
            if (substr($0, 1, 1) == "\"") {
                $0 = substr($0, 2)
                sub(/"$/, "", $0)
            }
            value[key]=$0
        }
        END {
            # ASCII unit separator avoids IFS whitespace collapsing empty
            # fields (for example sshIp on a local run).
            printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", \
                value["studyType"], value["runTag"], \
                value["runComment"], value["authorNote"], \
                value["node"], value["nodeAlias"], \
                value["runUser"], value["nodeIp"], value["sshIp"], \
                value["identitySource"], value["transport"], \
                value["suiteId"], value["jobId"]
        }
    ' "$dictFile"
}

build_param_table() {

    local outputFile="paramDatabase/paramTable.csv"
    local header
    local caseName
    local scriptFile
    local timeFile
    local start end elapsed
    local row
    local line
    local value=""
    local calcFile=""
    local metaFile=""
    local caseStudy caseTag caseComment caseNote caseNode caseNodeAlias
    local caseUser caseIp caseSshIp caseIdentitySource
    local caseTransport caseSuiteId caseJobId
    local caseStatus caseReason caseExitCode caseRowTag
    local caseSshPresent=0
    local -a values=()
    local -a calcKeys=()
    local -a oldFields=()
    local oldRow=""
    local idx
    local i

    ui_info "Creating parametric table from case matrix"

    if ! ensure_case_matrix; then
        ui_warn "No case matrix or compatible existing table found"
        return 1
    fi

    if ! load_case_matrix; then
        ui_warn "Could not read paramDatabase/caseMatrix.csv"
        return 1
    fi

    if [ ${#MATRIX_PARAM_NAMES[@]} -ne ${#paramNames[@]} ]; then
        ui_error "caseMatrix.csv parameter count does not match paramDict"
        return 1
    fi

    for ((i=0;i<${#paramNames[@]};i++)); do
        if [ "${MATRIX_PARAM_NAMES[$i]}" != "${paramNames[$i]}" ]; then
            ui_error "caseMatrix.csv parameter '${MATRIX_PARAM_NAMES[$i]}' does not match '${paramNames[$i]}'"
            return 1
        fi
    done

    mapfile -t calcKeys < <(calc_script_all_keys "calculationScript")
    load_old_timing "$outputFile"

    header="caseName,tag,studyType,runTag,runComment,authorNote,node,nodeAlias,user,ip,sshIp,identitySource,transport,suiteId,jobId,startTime,endTime,elapsedTime (s),status,reason,exitCode"

    for ((i=0;i<${#paramNames[@]};i++)); do
        header="$header,${paramNames[$i]}"
    done

    for ((i=0;i<${#calcKeys[@]};i++)); do
        header="$header,${calcKeys[$i]}"
    done

    : > "$outputFile"
    printf '%s\n' "$header" >> "$outputFile"

    for caseName in "${MATRIX_CASES[@]}"; do

        read -r -a values <<< "${MATRIX_VALUES[$caseName]}"

        timeFile="parametricLogs/${caseName}_time.txt"
        start=""
        end=""
        elapsed=""

        if [ -f "$timeFile" ]; then
            IFS="|" read start end elapsed < "$timeFile"
        else
            start="${OLD_START[$caseName]:-}"
            end="${OLD_END[$caseName]:-}"
            elapsed="${OLD_ELAPSED[$caseName]:-}"
        fi

        scriptFile="parametricStudy/${caseName}/calculationScript"
        [ -f "$scriptFile" ] || scriptFile="calculationScript"

        calcFile="parametricLogs/${caseName}_calc.txt"
        oldFields=()
        oldRow="${OLD_ROW[$caseName]:-}"
        [ -n "$oldRow" ] && IFS=, read -r -a oldFields <<< "$oldRow"

        # Per-case run metadata.  An archived case keeps the metadata it
        # was run with, so appending new cases must never rewrite the
        # runTag/runComment/authorNote of existing rows.
        metaFile="$PARAMETRIC_STUDY_DIR/${caseName}/system/paramDict"

        caseStudy=""
        caseTag=""
        caseComment=""
        caseNote=""
        caseNode=""
        caseNodeAlias=""
        caseUser=""
        caseIp=""
        caseSshIp=""
        caseIdentitySource=""
        caseTransport=""
        caseSuiteId=""
        caseJobId=""
        caseSshPresent=0

        if [ -f "$metaFile" ]; then
            if grep -qE '^[[:space:]]*sshIp[[:space:]]' "$metaFile"; then
                caseSshPresent=1
            fi

            IFS=$'\x1f' read -r caseStudy caseTag caseComment caseNote \
                caseNode caseNodeAlias caseUser caseIp caseSshIp \
                caseIdentitySource caseTransport caseSuiteId caseJobId \
                < <(read_archived_metadata "$metaFile")
        fi

        # Fall back to the previous table row, then to the current config.
        [ -n "$caseStudy" ]   || caseStudy="${OLD_STUDY[$caseName]:-$studyType}"
        [ -n "$caseTag" ]     || caseTag="${OLD_TAG[$caseName]:-$runTag}"
        [ -n "$caseComment" ] || caseComment="${OLD_COMMENT[$caseName]:-$runComment}"
        [ -n "$caseNote" ]    || caseNote="${OLD_NOTE[$caseName]:-$authorNote}"

        if [ -z "$caseNode" ]; then
            if [ "$OLD_HAS_NODE" -eq 1 ] && [ -n "${OLD_ROW[$caseName]+x}" ]; then
                caseNode="${OLD_NODE[$caseName]:-}"
            elif [ -n "${OLD_ROW[$caseName]+x}" ]; then
                # Legacy row from a table without a node column.
                caseNode=""
            else
                caseNode="$node"
            fi
        fi

        if [ -z "$caseNodeAlias" ]; then
            if [ -n "${OLD_ROW[$caseName]+x}" ]; then
                [ -n "${OLD_INDEX[nodeAlias]:-}" ] && \
                    caseNodeAlias="${OLD_NODE_ALIAS[$caseName]:-}"
            else
                caseNodeAlias=$(parametric_node_label)
            fi
        fi

        if [ -z "$caseTransport" ]; then
            if [ -n "${OLD_ROW[$caseName]+x}" ]; then
                [ -n "${OLD_INDEX[transport]:-}" ] && \
                    caseTransport="${OLD_TRANSPORT[$caseName]:-}"
            else
                caseTransport="${PARAMETRIC_TRANSPORT:-local}"
            fi
        fi

        if [ -z "$caseSuiteId" ] && [ -z "${OLD_ROW[$caseName]+x}" ]; then
            caseSuiteId="${PARAMETRIC_SUITE_ID:-}"
        fi

        if [ -z "$caseJobId" ] && [ -z "${OLD_ROW[$caseName]+x}" ]; then
            caseJobId="${PARAMETRIC_JOB_ID:-}"
        fi

        if [ -z "$caseUser" ]; then
            if [ -n "${OLD_ROW[$caseName]+x}" ]; then
                [ -n "${OLD_INDEX[user]:-}" ] && caseUser="${OLD_USER[$caseName]:-}"
            else
                caseUser="$runUser"
            fi
        fi

        if [ -z "$caseIp" ]; then
            if [ -n "${OLD_ROW[$caseName]+x}" ]; then
                [ -n "${OLD_INDEX[ip]:-}" ] && caseIp="${OLD_IP[$caseName]:-}"
            else
                caseIp="$nodeIp"
            fi
        fi

        if [ -z "$caseSshIp" ] && [ "$caseSshPresent" -eq 0 ]; then
            if [ -n "${OLD_ROW[$caseName]+x}" ]; then
                [ -n "${OLD_INDEX[sshIp]:-}" ] && caseSshIp="${OLD_SSH[$caseName]:-}"
            else
                caseSshIp="$sshIp"
            fi
        fi

        if [ -z "$caseIdentitySource" ]; then
            if [ -n "${OLD_ROW[$caseName]+x}" ]; then
                [ -n "${OLD_INDEX[identitySource]:-}" ] && \
                    caseIdentitySource="${OLD_IDENTITY[$caseName]:-}"
            else
                caseIdentitySource="$identitySource"
            fi
        fi

        ST_STATE=""
        ST_REASON=""
        ST_RC=""
        if declare -F status_load >/dev/null 2>&1; then
            status_load "$caseName"
        fi

        if [ -z "$ST_STATE" ] && [ -n "${OLD_ROW[$caseName]+x}" ] && \
           [ -n "${OLD_INDEX[status]:-}" ]; then
            caseStatus=${OLD_STATUS[$caseName]:-UNKNOWN}
            caseReason=${OLD_REASON[$caseName]:-}
            caseExitCode=${OLD_EXIT[$caseName]:-}
        else
            caseStatus=${ST_STATE:-UNKNOWN}
            caseReason=${ST_REASON:-}
            caseExitCode=${ST_RC:-}
        fi

        # Keep the CSV valid if metadata or a failure reason contains separators.
        caseStudy=${caseStudy//,/;}
        caseTag=${caseTag//,/;}
        caseComment=${caseComment//,/;}
        caseNote=${caseNote//,/;}
        caseNode=${caseNode//,/;}
        caseNodeAlias=${caseNodeAlias//,/;}
        caseUser=${caseUser//,/;}
        caseIp=${caseIp//,/;}
        caseSshIp=${caseSshIp//,/;}
        caseIdentitySource=${caseIdentitySource//,/;}
        caseTransport=${caseTransport//,/;}
        caseSuiteId=${caseSuiteId//,/;}
        caseJobId=${caseJobId//,/;}
        caseReason=${caseReason//$'\n'/ }
        caseReason=${caseReason//$'\r'/ }
        caseReason=${caseReason//,/;}

        caseRowTag="${MATRIX_TAGS[$caseName]:-${PARAMETRIC_TAG:-untagged}}"

        row="$caseName,$caseRowTag,$caseStudy,$caseTag,$caseComment,$caseNote,$caseNode,$caseNodeAlias,$caseUser,$caseIp,$caseSshIp,$caseIdentitySource,$caseTransport,$caseSuiteId,$caseJobId,$start,$end,$elapsed,$caseStatus,$caseReason,$caseExitCode"

        for ((i=0;i<${#paramNames[@]};i++)); do
            row="$row,${values[$i]:-}"
        done

        for ((i=0;i<${#calcKeys[@]};i++)); do
            value=$(calc_resolved_value "$calcFile" "${calcKeys[$i]}")

            if [ -z "$value" ] && [ -n "$oldRow" ]; then
                idx=${OLD_INDEX["${calcKeys[$i]}"]:-}
                if [ -n "$idx" ]; then
                    value="${oldFields[$idx]:-}"
                fi
            fi

            [ -z "$value" ] && value=$(calc_script_value "$scriptFile" "${calcKeys[$i]}")
            row="$row,$value"
        done

        printf '%s\n' "$row" >> "$outputFile"

    done

    # The per-case transport-property text files are no longer part of
    # the database.
    rm -f paramDatabase/${prefix}[0-9]*.txt
    rm -f paramDatabase/*_mesh.txt

    ui_ok "Parametric table ready: $outputFile"
}

rebuild_param_table() {
    build_param_table
}

finalize_database() {

    ui_info "Consolidating derived database"

    mkdir -p paramDatabase

    # Old transport-property dumps from previous versions.
    rm -f ${prefix}[0-9]*.txt

    build_param_table

    if [ -f "parametricLogs/run.log" ]; then
        cp "parametricLogs/run.log" "paramDatabase/run.log"
        ui_kv "Run log" "paramDatabase/run.log"
    fi

    if [ -d "parametricLogs" ]; then
        ui_info "Removing temporary parametricLogs directory"
        rm -rf parametricLogs
    fi

    if [ -f "parametricStatus/dashboard.txt" ]; then
        local statusTarget="paramDatabase/status.txt"
        local statusStamp

        statusStamp=$(fmt_wallclock "$(date +%s)")

        if [ -f "$statusTarget" ]; then
            # Keep the history of previous runs instead of overwriting it.
            {
                printf '\n'
                printf '%s\n' "======================================================================"
                printf 'Run appended: %s\n' "${statusStamp:-$(date '+%Y-%m-%d %H:%M:%S')}"
                printf '%s\n' "======================================================================"
                printf '\n'
                cat "parametricStatus/dashboard.txt"
            } >> "$statusTarget"
        else
            cp "parametricStatus/dashboard.txt" "$statusTarget"
        fi

        ui_kv "Status file" "$statusTarget"
    fi

    if [ -d "parametricStatus" ]; then
        ui_debug "Removing temporary parametricStatus directory"
        rm -rf parametricStatus
    fi

    ui_ok "Database ready at: paramDatabase/"
}
