#!/bin/bash

archive_case() {

  caseName=$1
  logFile="parametricLogs/log.Allrun.${caseName}"

  dest="${PARAMETRIC_STUDY_DIR:-parametricStudy}/${caseName}"
  mkdir -p "$dest"

  ui_info "Archiving case: $caseName"

  # Base folders
  cp -r 0 "$dest/"
  cp -r constant "$dest/"
  cp -r system "$dest/"
  cp -r postProcessing "$dest/" 2>/dev/null
  cp calculationScript "$dest/"

  if [ -f runScript.py ]; then
    cp runScript.py "$dest/"
  fi

  # --------------------------------------------------
  # Archive mesh source (.geo) preserving Mesh/ folder
  # --------------------------------------------------

  meshFile=$(foamDictionary system/paramDict -entry meshFile -value | tr -d '"')

  if [ -f "$meshFile" ]; then
    meshDir=$(dirname "$meshFile")
    ui_info "Archiving mesh source: $meshFile"
    mkdir -p "$dest/$meshDir"
    cp "$meshFile" "$dest/$meshDir/"
  fi

  # ---------------------------------------------
  # Copy time directories (solution folders)
  # ---------------------------------------------
  for d in */; do

    dir=${d%/}

    if [[ "$dir" == "0" ||
      "$dir" == "constant" ||
      "$dir" == "system" ||
      "$dir" == "postProcessing" ||
      "$dir" == parametric* ||
      "$dir" == processor* ]]; then
      continue
    fi

    if [[ "$dir" =~ ^[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?$ ]]; then
      ui_debug "Archiving time directory: $dir"
      cp -r "$dir" "$dest/"
    fi
  done

  # Copy log
  if [ -f "$logFile" ]; then
    cp "$logFile" "$dest/"
  else
    ui_warn "Log file not found for $caseName"
  fi
}
