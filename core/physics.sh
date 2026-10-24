#!/bin/bash

restore_script() {
    cp "$SCRIPT_BACKUP" "$SCRIPT_FILE"
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
