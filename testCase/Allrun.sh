#!/bin/bash
# --------------------------------------------------
# Parametric-study entry point
#
# Case commands : AllrunSimple
# Timing/logging: runDetails.sh
# --------------------------------------------------

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1

source "$SCRIPT_DIR/AllrunSimple"
source "$SCRIPT_DIR/runDetails.sh"

run_detailed_case
