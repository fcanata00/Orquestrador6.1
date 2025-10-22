#!/usr/bin/env bash
# register.sh - logging, progress, rotation, locks, --ini initialization
set -euo pipefail
IFS=$'\n\t'

# Defaults (environment override allowed)
: "${LFS:=/mnt/lfs}"
: "${LOG_DIR:=${LFS}/var/log}"
: "${LOCK_DIR:=${LOG_DIR}/locks}"
: "${SCRIPTS_LOG_DIR:=${LOG_DIR}/scripts}"
: "${LOG_MAX_SIZE_MB:=50}"
: "${LOG_MAX_FILES:=5}"
: "${SILENT:=false}"
: "${DEBUG:=false}"
: "${COLOR:=true}"
: "${JSON_OUTPUT:=false}"
: "${TIMESTAMP_FORMAT:=%Y-%m-%dT%H:%M:%SZ}"
: "${PROGRESS_WIDTH:=40}"

# Internal state
_REGISTER_INITIALIZED=false
_REGISTER_ERROR_COUNT=0
_REGISTER_LAST_LOG="${LOG_DIR}/system.log"

# Safe characters for tag names
_tag_sanitize() {
  local tag="$1"
  # keep alnum, dot, dash, underscore
  echo "$tag" | sed -E 's/[^A-Za-z0-9._-]/_/g'
}

# timestamp in UTC
register_timestamp() {
  date -u +"${TIMESTAMP_FORMAT}"
}

# Ensure directories exist with safe perms
_register_init_dirs() {
  if [[ "${_REGISTER_INITIALIZED}" == "true" ]]; then
    return 0
  fi
  mkdir -p "${LOG_DIR}" "${LOCK_DIR}" "${SCRIPTS_LOG_DIR}" 2>/dev/null || true
  # set permissions - secure but usable (owner rwx, group rx, others none)
  umask 027
  chmod 750 "${LOG_DIR}" || true
  chmod 750 "${LOCK_DIR}" || true
  chmod 750 "${SCRIPTS_LOG_DIR}" || true
  # touch main system log
  mkdir -p "$(dirname "${_REGISTER_LAST_LOG}")" 2>/dev/null || true
  touch "${_REGISTER_LAST_LOG}" 2>/dev/null || true
  chmod 640 "${_REGISTER_LAST_LOG}" || true
  _REGISTER_INITIALIZED=true
}

# Internal write - uses flock per file
_register_write() {
  local file="$1"; shift
  local line="$*"
  mkdir -p "$(dirname "${file}")" 2>/dev/null || true
  # use a file descriptor based flock for atomic append
  exec {__fd}>>"${file}" || { echo "ERROR opening log file ${file}" >&2; return 3; }
  if ! flock -n "${__fd}"; then
    # fallback to blocking flock for short time
    flock "${__fd}" || true
  fi
  printf "%s\n" "${line}" >&${__fd}
  # release
  eval "exec ${__fd}>&-"
  return 0
}

# Choose whether to print color codes
if [[ "${COLOR}" != "true" || -z "${TERM:-}" || "${TERM}" == "dumb" ]]; then
  _C_INFO=""; _C_WARN=""; _C_ERR=""; _C_DEBUG=""; _C_RESET=""
else
  _C_INFO="\e[32m"; _C_WARN="\e[33m"; _C_ERR="\e[31m"; _C_DEBUG="\e[36m"; _C_RESET="\e[0m"
fi

# core logging API
_register_log_line() {
  local level="$1"; local tag="$2"; shift 2
  local msg="$*"
  local ts; ts=$(register_timestamp)
  local pid=$$
  local clean_tag; clean_tag=$(_tag_sanitize "${tag:-system}")
  local logfile="${SCRIPTS_LOG_DIR}/${clean_tag}.log"
  local line="${ts} [${level}] ${clean_tag} ${pid} - ${msg}"
  # write to global system log and per-tag log
  _register_write "${_REGISTER_LAST_LOG}" "${line}" || true
  _register_write "${logfile}" "${line}" || true
  # optionally echo to console unless SILENT
  if [[ "${SILENT}" != "true" ]]; then
    case "${level}" in
      INFO) printf "%s %s%s%s\n" "${ts}" "${_C_INFO}" "${msg}" "${_C_RESET}" ;;
      WARN) printf "%s %s%s%s\n" "${ts}" "${_C_WARN}" "${msg}" "${_C_RESET}" >&2 ;;
      ERROR) printf "%s %s%s%s\n" "${ts}" "${_C_ERR}" "${msg}" "${_C_RESET}" >&2 ;;
      DEBUG) if [[ "${DEBUG}" == "true" ]]; then printf "%s %s%s%s\n" "${ts}" "${_C_DEBUG}" "${msg}" "${_C_RESET}"; fi ;;
      *) printf "%s %s\n" "${ts}" "${msg}" ;;
    esac
  fi
}

register_info()  { _register_init_dirs; _register_log_line INFO "${SCRIPT_NAME:-system}" "$*"; }
register_warn()  { _register_init_dirs; _register_log_line WARN "${SCRIPT_NAME:-system}" "$*"; }
register_error() { _register_init_dirs; _REGISTER_ERROR_COUNT=$(( _REGISTER_ERROR_COUNT + 1 )); _register_log_line ERROR "${SCRIPT_NAME:-system}" "$*"; }
register_debug() { _register_init_dirs; if [[ "${DEBUG}" == "true" ]]; then _register_log_line DEBUG "${SCRIPT_NAME:-system}" "$*"; fi; }

register_fatal() {
  _register_init_dirs
  _register_log_line ERROR "${SCRIPT_NAME:-system}" "$*"
  exit 1
}

# JSON-safe encoder for simple key=val pairs (not full JSON lib)
_register_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//"/\\\"}
  s=${s//$'\n'/\\n}
  printf '%s' "${s}"
}

register_json_out() {
  _register_init_dirs
  # accepts KEY=VALUE ...; outputs compact JSON to stdout or file
  local -a parts=()
  for kv in "$@"; do
    local k=${kv%%=*}; local v=${kv#*=}
    k=$(_tag_sanitize "${k}")
    v=$(_register_json_escape "${v}")
    parts+=("\"${k}\":\"${v}\"")
  done
  local ts; ts=$(register_timestamp)
  local json="{\"timestamp\":\"${ts}\",${parts[*]// /,}}"
  if [[ "${JSON_OUTPUT}" == "true" ]]; then
    printf '%s\n' "${json}"
  else
    # append to system log as JSON line as well
    _register_write "${_REGISTER_LAST_LOG}" "${json}" || true
    printf '%s\n' "${json}"
  fi
}

# progress bar (0..100)
progress_bar() {
  local percent=${1:-0}; local width=${2:-${PROGRESS_WIDTH}}
  if (( percent < 0 )); then percent=0; fi
  if (( percent > 100 )); then percent=100; fi
  local filled=$(( percent * width / 100 ))
  local empty=$(( width - filled ))
  local i
  printf '['
  for ((i=0;i<filled;i++)); do printf '#'; done
  for ((i=0;i<empty;i++)); do printf '-'; done
  printf "] %d%%\r" "${percent}"
  if (( percent >= 100 )); then printf '\n'; fi
}

# simple lock helpers using flock via descriptor
register_lock() {
  _register_init_dirs
  local name=${1:-global}
  local lockfile="${LOCK_DIR}/lock.${name}.lck"
  mkdir -p "${LOCK_DIR}" 2>/dev/null || true
  exec {LOCK_FD}>>"${lockfile}" || { register_error "Cannot open lockfile ${lockfile}"; return 4; }
  flock -n "${LOCK_FD}" || { register_warn "Lock busy: ${name}"; return 1; }
  return 0
}

register_unlock() {
  if [[ -n "${LOCK_FD:-}" ]]; then
    eval "exec ${LOCK_FD}>&-" || true
  fi
  return 0
}

# rotate single log if exceeding size (MB)
register_rotate() {
  _register_init_dirs
  local logfile=${1:-${_REGISTER_LAST_LOG}}
  if [[ ! -f "${logfile}" ]]; then return 0; fi
  local maxbytes=$(( LOG_MAX_SIZE_MB * 1024 * 1024 ))
  local bytes=$(stat -c%s "${logfile}" 2>/dev/null || echo 0)
  if (( bytes < maxbytes )); then return 0; fi
  # acquire lock on logfile
  local base=$(basename "${logfile}")
  register_lock "rotate_${base}" || { register_warn "Could not acquire rotate lock for ${logfile}"; return 4; }
  # rotate: move files up to LOG_MAX_FILES
  for ((i=LOG_MAX_FILES-1;i>=1;i--)); do
    if [[ -f "${logfile}.${i}" ]]; then mv -f "${logfile}.${i}" "${logfile}.$((i+1))" || true; fi
  done
  if [[ -f "${logfile}" ]]; then mv -f "${logfile}" "${logfile}.1" || true; fi
  # create new empty logfile
  : > "${logfile}"
  register_unlock || true
  register_info "Rotated ${logfile}"
  return 0
}

# show tail of a log file
register_tail() {
  local logfile=${1:-${_REGISTER_LAST_LOG}}
  local lines=${2:-200}
  if [[ -f "${logfile}" ]]; then tail -n "${lines}" "${logfile}"; else echo "(no log: ${logfile})"; fi
}

# count errors
register_last_error_count() {
  printf '%d' "${_REGISTER_ERROR_COUNT:-0}"
}

# --ini: initialize directories and write basic config file
_register_write_conf() {
  local conf_file="${LOG_DIR}/register.conf"
  cat > "${conf_file}" <<EOF
# register.conf autogenerated on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
LFS=${LFS}
LOG_DIR=${LOG_DIR}
LOCK_DIR=${LOCK_DIR}
SCRIPTS_LOG_DIR=${SCRIPTS_LOG_DIR}
LOG_MAX_SIZE_MB=${LOG_MAX_SIZE_MB}
LOG_MAX_FILES=${LOG_MAX_FILES}
SILENT=${SILENT}
DEBUG=${DEBUG}
COLOR=${COLOR}
JSON_OUTPUT=${JSON_OUTPUT}
TIMESTAMP_FORMAT=${TIMESTAMP_FORMAT}
PROGRESS_WIDTH=${PROGRESS_WIDTH}
EOF
  chmod 640 "${conf_file}" || true
  register_info "Wrote config ${conf_file}"
}

# CLI handling when run as script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --ini)
      _register_init_dirs
      _register_write_conf
      echo "register initialized at ${LOG_DIR}"
      ;;
    --status)
      _register_init_dirs
      echo "Log dir: ${LOG_DIR}"
      echo "Files: $(find ${LOG_DIR} -type f | wc -l)"
      echo "Size: $(du -sh ${LOG_DIR} 2>/dev/null | awk '{print $1}')"
      ;;
    --rotate)
      _register_init_dirs
      register_rotate "${LOG_DIR}/system.log"
      ;;
    --tail)
      _register_init_dirs
      register_tail "${LOG_DIR}/system.log" "${2:-200}"
      ;;
    --json)
      shift || true
      register_json_out "$@"
      ;;
    --help|-h|help)
      cat <<'EOF'
register.sh --ini [--force]      Initialize logging directories and config
register.sh --status             Show basic log directory status
register.sh --rotate             Force rotate system.log
register.sh --tail [N]           Tail system.log (default 200)
register.sh --json key=val ...   Emit JSON record
EOF
      ;;
    *)
      echo "Use --help"
      exit 2
      ;;
  esac
  exit 0
fi

# If sourced, export functions for other scripts
export -f register_info register_warn register_error register_debug register_fatal register_json_out progress_bar register_lock register_unlock register_rotate register_tail register_last_error_count register_timestamp
