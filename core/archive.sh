#!/bin/bash

archive_case() {

  caseName=$1
  logFile="parametricLogs/log.Allrun.${caseName}"

  dest="${PARAMETRIC_STUDY_DIR:-parametricStudy}/${caseName}"
  mkdir -p "$dest"

  ui_info "Archiving case: $caseName"

  # Base folders
  copy_item 0 "$dest/"
  copy_item constant "$dest/"
  copy_item system "$dest/"
  copy_item postProcessing "$dest/" 2>/dev/null
  copy_item calculationScript "$dest/"

  if [ -f runScript.py ]; then
    copy_item runScript.py "$dest/"
  fi

  # --------------------------------------------------
  # Archive mesh source (.geo) preserving Mesh/ folder
  # --------------------------------------------------

  meshFile=$(foamDictionary system/paramDict -entry meshFile -value | tr -d '"')

  if [ -f "$meshFile" ]; then
    meshDir=$(dirname "$meshFile")
    ui_info "Archiving mesh source: $meshFile"
    mkdir -p "$dest/$meshDir"
    copy_item "$meshFile" "$dest/$meshDir/"
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
      copy_item "$dir" "$dest/"
    fi
  done

  # Copy engine summary log
  if [ -f "$logFile" ]; then
    copy_item "$logFile" "$dest/"
  else
    ui_warn "Log file not found for $caseName"
  fi

  # Copy full command log produced by Allrun
  if [ -f "log.Allrun" ]; then
    copy_item "log.Allrun" "$dest/"
  fi
}
