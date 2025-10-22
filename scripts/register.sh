#!/usr/bin/env bash
# register.sh - Logging / progress / registration API for LFS build scripts
# Features:
# - Exportable functions for other scripts (when sourced)
# - Standalone CLI for simple logging and init
# - Colorized output with auto-detect of TTY
# - File logging with atomic append using flock
# - Progress bar with percentage and ETA (task-scoped via an ID)
# - Silent / verbose / debug modes
# - Robust error handling and traps
#
# Usage (sourced):
#   source /mnt/lfs/usr/bin/register.sh
#   register_init
#   register_info "Starting build"
#   register_progress "task1" 5 20 "Compiling GCC"
#
# CLI usage (standalone):
#   register.sh --init
#   register.sh --info "Message"
#   register.sh --progress taskid current total "message"
#
set -eEuo pipefail

# ---- Defaults (expandable) ----
: "${LFS:=/mnt/lfs}"
: "${LFS_LOG_DIR:=${LFS}/var/log}"
: "${LFS_BIN_DIR:=${LFS}/usr/bin}"
: "${LFS_LOG_FILE:=${LFS_LOG_DIR}/lfs-build.log}"
: "${LFS_COLOR:=true}"
: "${LFS_DEBUG:=false}"
: "${LFS_SILENT:=false}"
: "${LFS_DATE_FMT:='%Y-%m-%d %H:%M:%S'}"
: "${LFS_PROGRESS_DIR:=${LFS_LOG_DIR}/.progress}"

# Internal constants
REGISTER_PID=$$
REGISTER_LOCK_FD=200
REGISTER_LOCK_FILE="${LFS_LOG_DIR}/.register.lock"

# color codes (only if tty and LFS_COLOR true)
_register_detect_tty() {
    if [[ "${LFS_COLOR}" != "true" ]]; then
        REGISTER_CAN_COLOR=false
        return
    fi
    if [[ -t 1 ]]; then
        REGISTER_CAN_COLOR=true
    else
        REGISTER_CAN_COLOR=false
    fi
}

_register_setup_colors() {
    if [[ "${REGISTER_CAN_COLOR}" == "true" ]]; then
        COLOR_RESET=$'\e[0m'
        COLOR_RED=$'\e[31m'
        COLOR_GREEN=$'\e[32m'
        COLOR_YELLOW=$'\e[33m'
        COLOR_BLUE=$'\e[34m'
        COLOR_MAGENTA=$'\e[35m'
        COLOR_CYAN=$'\e[36m'
        COLOR_GRAY=$'\e[90m'
    else
        COLOR_RESET=''
        COLOR_RED=''
        COLOR_GREEN=''
        COLOR_YELLOW=''
        COLOR_BLUE=''
        COLOR_MAGENTA=''
        COLOR_CYAN=''
        COLOR_GRAY=''
    fi
}

# Ensure directories exist and are writable
register_init() {
    _register_detect_tty
    _register_setup_colors

    # check root for operations that write to LFS root
    if [[ $EUID -ne 0 ]]; then
        echo "register.sh: warning: recommended to run as root for --init to create system dirs" >&2
    fi

    mkdir -p "${LFS_LOG_DIR}" "${LFS_BIN_DIR}" "${LFS_PROGRESS_DIR}"
    touch "${LFS_LOG_FILE}"
    chmod 644 "${LFS_LOG_FILE}" || true

    # lock file
    mkdir -p "$(dirname "${REGISTER_LOCK_FILE}")"
    : > "${REGISTER_LOCK_FILE}" || true

    register_info "register.sh initialized. Logs: ${LFS_LOG_FILE}"
}

# Internal: write a line to the log file atomically using flock
_register_log_write() {
    local line="$1"
    # Use file descriptor lock for atomic append
    exec {REGISTER_LOCK_FD}>>"${LFS_LOG_FILE}"
    flock -n "${REGISTER_LOCK_FD}" || true
    printf '%s\n' "${line}" >&"${REGISTER_LOCK_FD}" || true
    # release happens on close (fd closed when function exits)
    eval "exec ${REGISTER_LOCK_FD}>&-"
}

# Format timestamp
_register_timestamp() {
    date +"${LFS_DATE_FMT}"
}

# Basic logging functions
register_info() {
    local msg="$*"
    local ts=$(_register_timestamp)
    local text="[INFO] ${ts} - ${msg}"
    if [[ "${LFS_SILENT}" != "true" ]]; then
        printf "%b\n" "${COLOR_CYAN}${text}${COLOR_RESET}"
    fi
    _register_log_write "${text}"
}

register_warn() {
    local msg="$*"
    local ts=$(_register_timestamp)
    local text="[WARN] ${ts} - ${msg}"
    if [[ "${LFS_SILENT}" != "true" ]]; then
        printf "%b\n" "${COLOR_YELLOW}${text}${COLOR_RESET}" >&2
    fi
    _register_log_write "${text}"
}

register_error() {
    local msg="$*"
    local ts=$(_register_timestamp)
    local text="[ERROR] ${ts} - ${msg}"
    # Errors should always be visible unless explicitly suppressed
    if [[ "${LFS_SILENT}" != "true" ]]; then
        printf "%b\n" "${COLOR_RED}${text}${COLOR_RESET}" >&2
    fi
    _register_log_write "${text}"
}

register_debug() {
    if [[ "${LFS_DEBUG}" != "true" ]]; then
        return 0
    fi
    local msg="$*"
    local ts=$(_register_timestamp)
    local text="[DEBUG] ${ts} - ${msg}"
    if [[ "${LFS_SILENT}" != "true" ]]; then
        printf "%b\n" "${COLOR_GRAY}${text}${COLOR_RESET}"
    fi
    _register_log_write "${text}"
}

# Trap handler for unexpected errors
_register_trap_err() {
    local rc=$?
    local line=${1:-$LINENO}
    register_error "Unexpected error (exit code ${rc}) at line ${line} in ${BASH_SOURCE[1]:-register.sh}"
    # don't exit if in debug mode? we will exit to be safe
    exit "${rc}"
}

# Ensure trap is set when sourced
_register_enable_trap() {
    trap '_register_trap_err ${LINENO}' ERR
}

# Progress management:
# state is stored per-task in ${LFS_PROGRESS_DIR}/taskid.meta
# functions: register_progress(taskid,current,total,message)
# Example: register_progress build_gcc 5 20 "Compiling gcc"

_register_progress_taskfile() {
    local taskid="$1"
    printf '%s/%s' "${LFS_PROGRESS_DIR}" "${taskid}.meta"
}

# create or update task metadata (start_ts,total)
_register_progress_init_if_needed() {
    local taskid="$1"
    local tf=$(_register_progress_taskfile "${taskid}")
    if [[ ! -f "${tf}" ]]; then
        # store start epoch and total
        local start=$(date +%s)
        echo "${start}:$2" > "${tf}"
    fi
}

register_progress() {
    local taskid="${1:-default}"
    local current="${2:-0}"
    local total="${3:-100}"
    local msg="${4:-}"

    # basic validation
    if ! [[ "${current}" =~ ^[0-9]+$ ]] || ! [[ "${total}" =~ ^[0-9]+$ ]]; then
        register_warn "register_progress: 'current' and 'total' must be integers. Got current='${current}' total='${total}'"
        return 1
    fi
    if (( total <= 0 )); then
        register_warn "register_progress: 'total' must be > 0"
        return 1
    fi
    if (( current < 0 )); then
        register_warn "register_progress: 'current' must be >= 0"
        return 1
    fi
    if (( current > total )); then
        current=${total}
    fi

    mkdir -p "${LFS_PROGRESS_DIR}"
    local tf=$(_register_progress_taskfile "${taskid}")

    # init if needed
    if [[ ! -f "${tf}" ]]; then
        _register_progress_init_if_needed "${taskid}" "${total}"
    fi

    local data
    data=$(cat "${tf}" 2>/dev/null || echo "")
    local start_ts
    local recorded_total
    if [[ "${data}" == *:* ]]; then
        start_ts="${data%%:*}"
        recorded_total="${data##*:}"
    else
        # fallback
        start_ts=$(date +%s)
        recorded_total="${total}"
        echo "${start_ts}:${recorded_total}" > "${tf}"
    fi

    # compute percentage
    local percent=$(( 100 * current / recorded_total ))
    # compute elapsed and ETA
    local now
    now=$(date +%s)
    local elapsed=$(( now - start_ts ))
    local eta=0
    if (( current > 0 )); then
        local avg_per_item=$(( elapsed / current ))
        local remain=$(( recorded_total - current ))
        eta=$(( avg_per_item * remain ))
    fi

    # render bar
    local cols=40
    local filled=$(( percent * cols / 100 ))
    local empty=$(( cols - filled ))
    local bar
    bar="$(printf '%0.s#' $(seq 1 "${filled}"))$(printf '%0.s-' $(seq 1 "${empty}"))"

    local ts=$(_register_timestamp)
    local pretty_eta
    if (( eta <= 0 )); then
        pretty_eta="--:--:--"
    else
        pretty_eta=$(printf '%02d:%02d:%02d' $((eta/3600)) $(((eta%3600)/60)) $((eta%60)))
    fi

    local out="[PROG] ${ts} - ${taskid} ${percent}% [${bar}] (${current}/${recorded_total}) ETA ${pretty_eta} ${msg}"

    if [[ "${LFS_SILENT}" != "true" ]]; then
        # carriage return if TTY so progress updates inline; otherwise normal line
        if [[ "${REGISTER_CAN_COLOR}" == "true" && -t 1 ]]; then
            printf "\r%b" "${COLOR_GREEN}${out}${COLOR_RESET}"
            # if finished, end line
            if (( current >= recorded_total )); then
                printf "\n"
            fi
        else
            printf "%b\n" "${out}"
        fi
    fi

    _register_log_write "${out}"

    return 0
}

# Export API for other scripts when sourced
register_export_api() {
    # make sure functions are available to child processes
    # 'declare -fx' exports functions in bash
    declare -fx register_init register_info register_warn register_error register_debug register_progress
    register_debug "API exported"
}

# CLI handling when run as a program
_register_usage() {
    cat <<EOF
register.sh - logging and progress API for LFS builds

Usage:
  register.sh --init
  register.sh --export-api
  register.sh --info "message"
  register.sh --warn "message"
  register.sh --error "message"
  register.sh --debug "message"
  register.sh --progress taskid current total "optional message"

Environment variables (optional):
  LFS, LFS_LOG_DIR, LFS_LOG_FILE, LFS_PROGRESS_DIR, LFS_COLOR, LFS_DEBUG, LFS_SILENT

EOF
}

# Parse CLI args only if script is executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # script executed directly
    _register_detect_tty
    _register_setup_colors
    _register_enable_trap

    if [[ "${#:-0}" -eq 0 ]]; then
        _register_usage
        exit 0
    fi

    cmd="${1:-}"
    case "${cmd}" in
        --init)
            register_init
            exit 0
            ;;
        --export-api)
            register_export_api
            exit 0
            ;;
        --info)
            shift
            register_info "$*"
            exit $?
            ;;
        --warn)
            shift
            register_warn "$*"
            exit $?
            ;;
        --error)
            shift
            register_error "$*"
            exit $?
            ;;
        --debug)
            shift
            register_debug "$*"
            exit $?
            ;;
        --progress)
            shift
            taskid="${1:-default}"; shift || true
            current="${1:-0}"; shift || true
            total="${1:-100}"; shift || true
            msg="$*"
            register_progress "${taskid}" "${current}" "${total}" "${msg}"
            exit $?
            ;;
        --help|-h)
            _register_usage
            exit 0
            ;;
        *)
            _register_usage
            exit 2
            ;;
    esac
fi

# When sourced, prepare environment but do not init directories automatically.
_register_detect_tty
_register_setup_colors
_register_enable_trap

# End of register.sh
