#!/bin/bash

# --------------------------------------------------
# Console UI helpers
#
# Colours are enabled only for interactive terminals and
# can be disabled with NO_COLOR=1.
# --------------------------------------------------

UI_ANSI=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    if [ "$(tput colors 2>/dev/null || echo 0)" -gt 0 ]; then
        UI_ANSI=1
    fi
fi

if [ "$UI_ANSI" -eq 1 ]; then
    UI_RESET=$'\033[0m'
    UI_BOLD=$'\033[1m'
    UI_DIM=$'\033[2m'
    UI_RED=$'\033[31m'
    UI_GREEN=$'\033[32m'
    UI_YELLOW=$'\033[33m'
    UI_CYAN=$'\033[36m'
else
    UI_RESET=""
    UI_BOLD=""
    UI_DIM=""
    UI_RED=""
    UI_GREEN=""
    UI_YELLOW=""
    UI_CYAN=""
fi

if [ -z "${UI_WIDTH:-}" ]; then
    if [ -t 1 ]; then
        UI_WIDTH=$(tput cols 2>/dev/null || echo 64)
    else
        UI_WIDTH=64
    fi
fi

if ! [[ "$UI_WIDTH" =~ ^[0-9]+$ ]]; then
    UI_WIDTH=64
fi

[ "$UI_WIDTH" -lt 60 ] && UI_WIDTH=60
[ "$UI_WIDTH" -gt 120 ] && UI_WIDTH=120

ui_rule() {
    printf '%s' "$UI_DIM"
    printf '%*s' "$UI_WIDTH" '' | tr ' ' '-'
    printf '%s\n' "$UI_RESET"
}

ui_fit() {
    local text=$1
    local width=$2

    [ "$width" -le 0 ] && { printf ''; return; }

    if [ "${#text}" -le "$width" ]; then
        printf '%s' "$text"
    else
        printf '%s~' "${text:0:$((width - 1))}"
    fi
}

ui_banner() {
    local title=$1
    local subtitle=${2:-}

    echo
    ui_rule
    printf '%s%s%s\n' "$UI_BOLD" "$title" "$UI_RESET"

    if [ -n "$subtitle" ]; then
        printf '%s%s%s\n' "$UI_DIM" "$subtitle" "$UI_RESET"
    fi

    ui_rule
}

ui_section() {
    local title=$1

    echo
    printf '%s%s%s\n' "$UI_BOLD" "$title" "$UI_RESET"
    ui_rule
}

ui_info() {
    printf '%s[INFO]%s %s\n' "$UI_CYAN" "$UI_RESET" "$*"
}

ui_ok() {
    printf '%s[ OK ]%s %s\n' "$UI_GREEN" "$UI_RESET" "$*"
}

ui_warn() {
    printf '%s[WARN]%s %s\n' "$UI_YELLOW" "$UI_RESET" "$*" >&2
}

ui_error() {
    printf '%s[FAIL]%s %s\n' "$UI_RED" "$UI_RESET" "$*" >&2
}

ui_kv() {
    printf '  %s%-20s%s %s\n' "$UI_DIM" "$1" "$UI_RESET" "$2"
}

ui_case() {
    printf '  %s%-14s%s %s\n' "$UI_BOLD" "$1" "$UI_RESET" "$2"
}

ui_debug() {
    if [ "${DEBUG:-0}" = "1" ]; then
            printf '%s[DEBUG]%s %s\n' "$UI_DIM" "$UI_RESET" "$*"
    fi
}
