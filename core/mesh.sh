#!/bin/bash

update_gmsh_parameter() {

    gmshFile=$(foamDictionary system/paramDict -entry meshFile -value | tr -d '"')

    paramName=$1
    paramValue=$2

    if [ ! -f "$gmshFile" ]; then
        ui_error "Mesh file not found: $gmshFile"
        return 1
    fi

    sed -i "s/^${paramName}[[:space:]]*=.*/${paramName} = ${paramValue};/" "$gmshFile"
}
