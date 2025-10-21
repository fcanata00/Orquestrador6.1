#!/usr/bin/env bash
#
# logger.sh - módulo de logging robusto para scripts bash
# Implementa:
# - cores ANSI opcionais
# - níveis numéricos (DEBUG, INFO, WARN, ERROR)
# - gravação em /var/log/adm (fallback /tmp/adm-logs)
# - thread-safety com flock
# - criação automática de diretório/arquivo
# - formato customizável com tokens: %datetime% %level% %script% %pid% %message%
# - modo silent/quiet, --no-color, --strict, --no-flock
# - funções de etapa: log_step_start/progress/end
# - mostra info do sistema (núcleos, memória, loadavg)
#
# Uso:
# source /path/to/logger.sh
# log_init --dir /var/log/adm --level INFO --no-color=false --format "[%datetime%] [%level%] [%script%:%pid%] %message%"
# log_info "Mensagem"
#

# --- Guarda para evitar múltiplos source ---
if [[ -n "${LOGGER_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
LOGGER_LOADED=1

# --- Defaults ---
LOG_DIR_DEFAULT="/var/log/adm"
LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"
LOG_LEVEL_NAME="${LOG_LEVEL_NAME:-INFO}"
LOG_NO_COLOR="${LOG_NO_COLOR:-0}"
LOG_SILENT="${LOG_SILENT:-0}"
LOG_STRICT="${LOG_STRICT:-0}"
LOG_NO_FLOCK="${LOG_NO_FLOCK:-0}"
LOG_FORMAT="${LOG_FORMAT:-[%datetime%] [%level%] [%script%:%pid%] %message%}"
LOG_FALLBACK_DIR="${LOG_FALLBACK_DIR:-/tmp/adm-logs}"
LOG_RETRY_FLOCK="${LOG_RETRY_FLOCK:-3}"
LOG_RETRY_SLEEP="${LOG_RETRY_SLEEP:-0.1}"

# Numeric levels
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3
LOG_LEVEL_NONE=4
LOG_LEVEL=$LOG_LEVEL_INFO

# ANSI colors
_ANSI_RESET=$'\033[0m'
_ANSI_DEBUG=$'\033[90m'
_ANSI_INFO=$'\033[34m'
_ANSI_WARN=$'\033[33m'
_ANSI_ERROR=$'\033[31m'

# Internal state
_LOG_FILE=""
_LOG_FD=""
_LOG_PROGNAME=""
_LOG_START_TS=0
_LOG_STEP_TOTAL=0
_LOG_STEP_CUR=0
_LOG_STEP_NAME=""
_LOG_STEP_FILE=""

# Helper: convert level name -> number
_level_to_num() {
    local lvl=$(awk '{print toupper($0)}' <<<"$1")
    case "$lvl" in
        DEBUG) echo "$LOG_LEVEL_DEBUG";;
        INFO)  echo "$LOG_LEVEL_INFO";;
        WARN|WARNING) echo "$LOG_LEVEL_WARN";;
        ERROR) echo "$LOG_LEVEL_ERROR";;
        NONE)  echo "$LOG_LEVEL_NONE";;
        *)     echo "$LOG_LEVEL_INFO";;
    esac
}

# Helper: timestamp
_log_timestamp() {
    if [[ -n "${LOG_TZ:-}" ]]; then
        TZ="$LOG_TZ" date '+%Y-%m-%d %H:%M:%S'
    else
        date '+%Y-%m-%d %H:%M:%S'
    fi
}

# Sanitize names for filenames
_sanitize() {
    local s="$1"
    # replace spaces with _, remove unsafe chars
    s="${s// /_}"
    s="$(sed 's/[^A-Za-z0-9._-]/_/g' <<<"$s")"
    echo "$s"
}

# Check for flock availability
_have_flock=0
if command -v flock >/dev/null 2>&1; then
    _have_flock=1
fi

# Internal write with flock
_write_log() {
    local text="$1"
    local tries=0
    if [[ -z "$_LOG_FILE" ]]; then
        return 1
    fi
    # ensure fd opened
    if [[ -z "${_LOG_FD}" ]]; then
        # open append fd
        exec {LOGFD}>>"$_LOG_FILE" || return 2
        _LOG_FD=$LOGFD
    fi

    # If flock disabled by flag or not available, just append (risk interleaving)
    if [[ "$LOG_NO_FLOCK" -eq 1 ]] || [[ "$_have_flock" -eq 0 ]]; then
        printf '%s\n' "$text" >>"$_LOG_FILE" || return 3
        return 0
    fi

    # Try flock on the fd
    while true; do
        if flock -n "$_LOG_FD" ; then
            printf '%s\n' "$text" >&$_LOG_FD || { flock -u "$_LOG_FD" ; return 4; }
            # release
            flock -u "$_LOG_FD"
            return 0
        else
            tries=$((tries+1))
            if (( tries >= LOG_RETRY_FLOCK )); then
                # last resort: append without flock but log warning
                printf '%s\n' "$text" >>"$_LOG_FILE" || return 5
                return 0
            fi
            sleep "$LOG_RETRY_SLEEP"
        fi
    done
}

# Remove ANSI codes (for file)
_strip_ansi() {
    # remove ESC [ ... m
    sed -E "s/\x1b\\[[0-9;]*m//g" <<<"$1"
}

# Format message according to LOG_FORMAT
_format_message() {
    local lvlname="$1"
    local msg="$2"
    local dt="$(_log_timestamp)"
    local pid="$$"
    local scriptname="${_LOG_PROGNAME:-${BASH_SOURCE[1]##*/}}"
    local out="$LOG_FORMAT"
    out="${out//%datetime%/$dt}"
    out="${out//%level%/$lvlname}"
    out="${out//%pid%/$pid}"
    out="${out//%script%/$scriptname}"
    out="${out//%message%/$msg}"
    printf '%s' "$out"
}

# Decide if should log based on LOG_LEVEL
_should_log() {
    local levelnum="$1"
    if (( levelnum >= LOG_LEVEL )); then
        return 0
    else
        return 1
    fi
}

# Print to terminal with optional color (but do not write color to file)
_terminal_print() {
    local lvlname="$1"
    local msg="$2"
    local color=""
    case "$lvlname" in
        DEBUG) color="$_ANSI_DEBUG";;
        INFO)  color="$_ANSI_INFO";;
        WARN)  color="$_ANSI_WARN";;
        ERROR) color="$_ANSI_ERROR";;
        *)     color="";;
    esac
    if [[ "$LOG_NO_COLOR" -eq 1 ]]; then
        printf '%s\n' "$msg"
    else
        printf '%b\n' "${color}${msg}${_ANSI_RESET}"
    fi
}

# Public: log_init
log_init() {
    # parse args (simple)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir) LOG_DIR="$2"; shift 2;;
            --level) LOG_LEVEL_NAME="$2"; shift 2;;
            --no-color) LOG_NO_COLOR=1; shift;;
            --no-color=*) LOG_NO_COLOR="${1#*=}"; shift;;
            --silent) LOG_SILENT=1; shift;;
            --strict) LOG_STRICT=1; shift;;
            --no-flock) LOG_NO_FLOCK=1; shift;;
            --format) LOG_FORMAT="$2"; shift 2;;
            --progname) _LOG_PROGNAME="$2"; shift 2;;
            --fallback-dir) LOG_FALLBACK_DIR="$2"; shift 2;;
            *) shift;;
        esac
    done

    # set numeric level
    LOG_LEVEL="$( _level_to_num "$LOG_LEVEL_NAME" )"

    # ensure dir exists or fallback
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    if [[ ! -d "$LOG_DIR" ]]; then
        # try sudo if available and allowed
        if command -v sudo >/dev/null 2>&1 && [[ "${LOG_ALLOW_SUDO:-0}" -eq 1 ]]; then
            sudo mkdir -p "$LOG_DIR" || true
        fi
    fi
    if [[ ! -d "$LOG_DIR" ]]; then
        # fallback
        mkdir -p "$LOG_FALLBACK_DIR" 2>/dev/null || true
        if [[ -d "$LOG_FALLBACK_DIR" ]]; then
            LOG_DIR="$LOG_FALLBACK_DIR"
            if [[ "$LOG_SILENT" -ne 1 ]]; then
                printf '%s\n' "WARN: Não foi possível criar $LOG_DIR_DEFAULT, usando fallback $LOG_DIR" >&2
            fi
        else
            if [[ "$LOG_STRICT" -eq 1 ]]; then
                printf '%s\n' "FATAL: não foi possível criar diretório de logs em $LOG_DIR_DEFAULT nem em $LOG_FALLBACK_DIR" >&2
                return 2
            else
                LOG_DIR="."
            fi
        fi
    fi

    # create unique log file per run
    local timestamp="$(date '+%Y%m%d_%H%M%S')"
    local prog="${_LOG_PROGNAME:-${BASH_SOURCE[1]##*/}}"
    prog="$(_sanitize "$prog")"
    _LOG_FILE="$LOG_DIR/adm-${timestamp}-$$.log"

    # create file and write header with program name
    touch "$_LOG_FILE" 2>/dev/null || {
        if [[ "$LOG_STRICT" -eq 1 ]]; then
            printf '%s\n' "FATAL: não foi possível criar arquivo de log $_LOG_FILE" >&2
            return 3
        else
            printf '%s\n' "WARN: não foi possível criar arquivo de log $_LOG_FILE, tentando fallback" >&2
            _LOG_FILE="./adm-${timestamp}-$$.log"
            touch "$_LOG_FILE" || return 4
        fi
    }

    # set safe permissions
    chmod 0644 "$_LOG_FILE" 2>/dev/null || true

    # write header: program name and system info
    local header="--- LOG START: program=${prog} pid=$$ timestamp=$(date '+%Y-%m-%d %H:%M:%S') ---"
    printf '%s\n' "$header" >>"$_LOG_FILE"
    _write_log "Program: $prog"
    _write_log "Log file: $_LOG_FILE"
    _log_start_system_info

    # print initial summary to terminal (unless silent)
    if [[ "$LOG_SILENT" -ne 1 ]]; then
        _terminal_print "INFO" "$(_format_message "INFO" "Log inicializado em $_LOG_FILE")"
        _terminal_print "INFO" "$(_format_message "INFO" "Programa: $prog | PID: $$")"
    fi

    return 0
}

# System info logging
_log_start_system_info() {
    local cores="unknown"
    if command -v nproc >/dev/null 2>&1; then
        cores="$(nproc --all 2>/dev/null || echo unknown)"
    elif [[ -r /proc/cpuinfo ]]; then
        cores="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo unknown)"
    fi
    local mem_total="unknown"
    if [[ -r /proc/meminfo ]]; then
        mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
        mem_total=$((mem_total_kb/1024))" KB"
    elif command -v free >/dev/null 2>&1; then
        mem_total="$(free -m | awk '/Mem:/ {print $2 " MB"}')"
    fi
    local loadavg="$(awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null || echo unknown)"
    _write_log "System: cores=${cores} mem_total=${mem_total} loadavg=${loadavg}"
}

# Public logging functions
log_debug() {
    local msg="$*"
    local lvl=DEBUG
    local lvlnum=$LOG_LEVEL_DEBUG
    if _should_log "$lvlnum"; then
        local formatted="$(_format_message "$lvl" "$msg")"
        # terminal
        if [[ "$LOG_SILENT" -ne 1 ]]; then
            _terminal_print "$lvl" "$formatted"
        fi
        # file (strip ansi)
        local fileline="$(_strip_ansi "$formatted")"
        _write_log "$fileline"
    fi
}

log_info() {
    local msg="$*"
    local lvl=INFO
    local lvlnum=$LOG_LEVEL_INFO
    if _should_log "$lvlnum"; then
        local formatted="$(_format_message "$lvl" "$msg")"
        if [[ "$LOG_SILENT" -ne 1 ]]; then
            _terminal_print "$lvl" "$formatted"
        fi
        local fileline="$(_strip_ansi "$formatted")"
        _write_log "$fileline"
    fi
}

log_warn() {
    local msg="$*"
    local lvl=WARN
    local lvlnum=$LOG_LEVEL_WARN
    if _should_log "$lvlnum"; then
        local formatted="$(_format_message "$lvl" "$msg")"
        if [[ "$LOG_SILENT" -ne 1 ]]; then
            _terminal_print "$lvl" "$formatted" >&2
        fi
        local fileline="$(_strip_ansi "$formatted")"
        _write_log "$fileline"
    fi
}

log_error() {
    local msg="$*"
    local lvl=ERROR
    local lvlnum=$LOG_LEVEL_ERROR
    if _should_log "$lvlnum"; then
        local formatted="$(_format_message "$lvl" "$msg")"
        if [[ "$LOG_SILENT" -ne 1 ]]; then
            _terminal_print "$lvl" "$formatted" >&2
        fi
        local fileline="$(_strip_ansi "$formatted")"
        _write_log "$fileline"
    fi
}

log_fatal() {
    local code="${2:-1}"
    local msg="$1"
    log_error "$msg"
    if [[ "$LOG_STRICT" -eq 1 ]]; then
        exit "$code"
    else
        return "$code"
    fi
}

# Step management: show only steps in the terminal with counts and log path
log_step_start() {
    local name="$1"
    shift
    local total=0
    # optional args like total=5 logname="instalacao"
    for arg in "$@"; do
        case "$arg" in
            total=*) total="${arg#total=}";;
            logname=*) name="${arg#logname=}";;
        esac
    done
    name="$(_sanitize "$name")"
    _LOG_STEP_TOTAL="${total:-0}"
    _LOG_STEP_CUR=0
    _LOG_STEP_NAME="$name"
    local ts="$(date '+%Y%m%d_%H%M%S')"
    _LOG_STEP_FILE="$_LOG_FILE.${name}.${ts}"
    touch "$_LOG_STEP_FILE" 2>/dev/null || true
    _write_log "STEP START: $name total=$_LOG_STEP_TOTAL file=$_LOG_STEP_FILE"
    if [[ "$LOG_SILENT" -ne 1 ]]; then
        _terminal_print "INFO" "> [0/${_LOG_STEP_TOTAL}] ${name} — log: ${_LOG_STEP_FILE}"
    fi
}

log_step_progress() {
    local cur="$1"
    shift
    local msg="$*"
    _LOG_STEP_CUR="$cur"
    if [[ -z "$_LOG_STEP_NAME" ]]; then
        log_warn "log_step_progress called without log_step_start"
        return 1
    fi
    if [[ "$LOG_SILENT" -ne 1 ]]; then
        _terminal_print "INFO" "> [${_LOG_STEP_CUR}/${_LOG_STEP_TOTAL}] ${_LOG_STEP_NAME} — ${msg}"
    fi
    # also write to step-specific file
    _write_log "STEP PROGRESS [$ _LOG_STEP_CUR/$_LOG_STEP_TOTAL ] ${msg}"
    if [[ -n "$_LOG_STEP_FILE" ]]; then
        printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >>"$_LOG_STEP_FILE" 2>/dev/null || true
    fi
}

log_step_end() {
    local status="${1:-OK}"
    if [[ -z "$_LOG_STEP_NAME" ]]; then
        log_warn "log_step_end called without log_step_start"
        return 1
    fi
    _write_log "STEP END: ${_LOG_STEP_NAME} status=${status}"
    if [[ "$LOG_SILENT" -ne 1 ]]; then
        _terminal_print "INFO" "> [${_LOG_STEP_TOTAL}/${_LOG_STEP_TOTAL}] ${_LOG_STEP_NAME} — ${status} — log: ${_LOG_STEP_FILE}"
    fi
    # reset
    _LOG_STEP_NAME=""
    _LOG_STEP_TOTAL=0
    _LOG_STEP_CUR=0
    _LOG_STEP_FILE=""
}

# Show summary of environment (cores, memory, loadavg, log dir)
log_show_env() {
    local cores="unknown"
    if command -v nproc >/dev/null 2>&1; then
        cores="$(nproc --all 2>/dev/null || echo unknown)"
    elif [[ -r /proc/cpuinfo ]]; then
        cores="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo unknown)"
    fi
    local mem_total="unknown"
    if [[ -r /proc/meminfo ]]; then
        mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
        mem_total="$((mem_total_kb/1024)) KB"
    elif command -v free >/dev/null 2>&1; then
        mem_total="$(free -m | awk '/Mem:/ {print $2 " MB"}')"
    fi
    local loadavg="$(awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null || echo unknown)"
    local msg="Cores=${cores} Mem=${mem_total} Loadavg=${loadavg} LogDir=${LOG_DIR} LogFile=${_LOG_FILE}"
    _write_log "ENV: $msg"
    if [[ "$LOG_SILENT" -ne 1 ]]; then
        _terminal_print "INFO" "$msg"
    fi
}

# Cleanup on exit (optional)
logger_cleanup() {
    # close fd if opened
    if [[ -n "${_LOG_FD}" ]]; then
        eval "exec ${_LOG_FD}>&-"
        _LOG_FD=""
    fi
}

# trap exit to cleanup
trap logger_cleanup EXIT

# End of logger.sh
