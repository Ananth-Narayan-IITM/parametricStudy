#!/bin/bash

restore_script() {
    cp "$SCRIPT_BACKUP" "$SCRIPT_FILE"
}

# Set a scalar entry in a dictionary without reformatting the file.
# Existing comments and layout are preserved.
set_dict_entry() {

    local dictFile=$1
    local key=$2
    local value=$3
    local escaped

    [ -f "$dictFile" ] || return 1
    [ -z "$key" ] && return 1

    value=${value//$'\n'/ }
    escaped=$(printf '%s' "$value" | sed 's/[\\&|]/\\&/g')

    if grep -qE "^[[:space:]]*${key}[[:space:]]" "$dictFile"; then
        sed -i "s|^[[:space:]]*${key}[[:space:]].*|${key} \"${escaped}\";|" "$dictFile"
    else
        printf '\n%s        "%s";\n' "$key" "$value" >> "$dictFile"
    fi
}

replace_param() {

    paramName=$1
    paramValue=$2

    defLine=$(grep -nE "^[[:space:]]*$paramName[[:space:]]+" "$SCRIPT_FILE" | head -n1)
    lineText=$(echo "$defLine" | cut -d: -f2-)

    if echo "$lineText" | grep -q "#calc"; then
        ui_error "$paramName is defined using #calc and cannot be replaced"
        return 1
    fi

    sed -i "s|^[[:space:]]*$paramName[[:space:]].*|$paramName $paramValue;|" "$SCRIPT_FILE"
}
