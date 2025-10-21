#!/usr/bin/env bash
# register.sh - Robust, sourceable logging library for LFS Orquestrador
# Provides public API functions:
#   log_debug, log_info, log_warn, log_error, log_fatal
# Usage:
#   source /path/to/register.sh
#   log_info "message"
#
# Design goals:
# - Safe to 'source' (doesn't exit when sourced)
# - Atomic writes with flock fallback
# - Sensitive value masking (configurable keys)
# - Log rotation with lock protection
# - Hooks support on FATAL (with timeout)
#
if [ -n "${REGISTER_SH_LOADED-}" ]; then
  return 0 2>/dev/null || exit 0
fi
REGISTER_SH_LOADED=1

# -----------------------------
# Configurable variables (override before sourcing)
# -----------------------------
: "${LFS_LOG_DIR:=/var/log/lfs}"
: "${LFS_LOG_FILE:=${LFS_LOG_DIR}/orquestrador.log}"
: "${LFS_LOG_MAX_BYTES:=10485760}"    # 10 MB
: "${LFS_LOG_BACKUPS:=5}"
: "${LFS_LOG_LEVEL:=INFO}"            # DEBUG|INFO|WARN|ERROR|FATAL
: "${LFS_SENSITIVE_KEYS:='password secret token api_key auth key'}"
: "${REGISTER_FATAL_HOOKS:=}"         # space-separated list of hook commands to run on fatal

mkdir -p "${LFS_LOG_DIR}" 2>/dev/null || true

# Colors
_C_INFO=$'\033[1;34m'; _C_WARN=$'\033[1;33m'; _C_ERR=$'\033[1;31m'; _C_OK=$'\033[1;32m'; _C_RST=$'\033[0m'

# Internal helpers
_log_now() { date +'%Y-%m-%dT%H:%M:%S%z'; }

# Mask sensitive keys in a line. Configurable via LFS_SENSITIVE_KEYS.
_mask_sensitive() {
  local line="$1"
  # iterate keys
  for key in $LFS_SENSITIVE_KEYS; do
    # patterns: key=val, key: val, "key"="val", 'key'='val'
    line="$(echo "$line" | sed -E "s/(${key})[[:space:]]*[:=][[:space:]]*([^[:space:]]+)/\\1=*****/Ig")"
    line="$(echo "$line" | sed -E "s/(\"${key}\"|'"'${key}'"')[[:space:]]*[:=][[:space:]]*(\"[^\"]*\"|'[^']*')/\\1=\\\"*****\\\"/Ig")"
  done
  echo "$line"
}

# Atomic append with flock fallback
_write_line_atomic() {
  local file="$1"; shift
  local line="$*"
  if command -v flock >/dev/null 2>&1; then
    # Use file descriptor lock on a lockfile unique per target file
    (
      flock -x 200
      printf '%s\n' "$line" >> "$file"
    ) 200>"${file}.lock"
  else
    # mkdir lock fallback
    local lockdir="${file}.lockdir"
    local tries=0
    while ! mkdir "${lockdir}" 2>/dev/null; do
      tries=$((tries+1))
      sleep 0.05
      if [ $tries -gt 200 ]; then
        # fallback to unprotected append
        printf '%s\n' "$line" >> "$file"
        return 0
      fi
    done
    printf '%s\n' "$line" >> "$file"
    rmdir "${lockdir}" 2>/dev/null || true
  fi
}

# Rotate logs (protected by flock if available)
_rotate_core() {
  # ensure log file exists
  [ -f "${LFS_LOG_FILE}" ] || return 0
  local size
  size=$(stat -c%s "${LFS_LOG_FILE}" 2>/dev/null || echo 0)
  if [ "${size:-0}" -lt "${LFS_LOG_MAX_BYTES}" ]; then
    return 0
  fi

  # perform rotation under a lock to avoid races
  if command -v flock >/dev/null 2>&1; then
    ( flock -x 201
      _rotate_core_inner
    ) 201>"${LFS_LOG_FILE}.rotlock"
  else
    _rotate_core_inner
  fi
}

_rotate_core_inner() {
  for ((i=LFS_LOG_BACKUPS; i>=1; i--)); do
    [ -f "${LFS_LOG_FILE}.$i.gz" ] && mv -f "${LFS_LOG_FILE}.$i.gz" "${LFS_LOG_FILE}.$((i+1)).gz" 2>/dev/null || true
    [ -f "${LFS_LOG_FILE}.$i" ] && mv -f "${LFS_LOG_FILE}.$i" "${LFS_LOG_FILE}.$((i+1))" 2>/dev/null || true
  done
  mv -f "${LFS_LOG_FILE}" "${LFS_LOG_FILE}.1" 2>/dev/null || true
  if command -v gzip >/dev/null 2>&1; then
    gzip -9 "${LFS_LOG_FILE}.1" >/dev/null 2>&1 || true
  fi
  : > "${LFS_LOG_FILE}" 2>/dev/null || true
}

# Map levels to numeric priority
_log_level_val() {
  case "${1:-INFO}" in
    DEBUG) echo 10 ;;
    INFO)  echo 20 ;;
    WARN)  echo 30 ;;
    ERROR) echo 40 ;;
    FATAL) echo 50 ;;
    *) echo 20 ;;
  esac
}

# Generic logger implementation
_log_generic() {
  local level="$1"; shift
  local msg="$*"
  local ts="$(_log_now)"
  local levelval; levelval=$(_log_level_val "$level")
  local minval; minval=$(_log_level_val "${LFS_LOG_LEVEL:-INFO}")
  if [ "$levelval" -lt "$minval" ]; then
    return 0
  fi

  # compose plain line (no ANSI)
  local plain="${ts} [${level}] ${msg}"
  plain="$(_mask_sensitive "${plain}")"

  # ensure dir exists
  mkdir -p "$(dirname "${LFS_LOG_FILE}")" 2>/dev/null || true

  # write atomically
  _write_line_atomic "${LFS_LOG_FILE}" "$plain"

  # echo to stderr with color for interactive users
  case "$level" in
    DEBUG) [ "${DEBUG:-0}" -eq 1 ] && printf '%s %s\n' "[DEBUG]" "$msg" >&2 || true ;;
    INFO)  printf '%b[INFO]%b %s\n' "${_C_INFO}" "${_C_RST}" "$msg" >&2 ;;
    WARN)  printf '%b[WARN]%b %s\n' "${_C_WARN}" "${_C_RST}" "$msg" >&2 ;;
    ERROR) printf '%b[ERROR]%b %s\n' "${_C_ERR}" "${_C_RST}" "$msg" >&2 ;;
    FATAL) printf '%b[FATAL]%b %s\n' "${_C_ERR}" "${_C_RST}" "$msg" >&2 ;;
    *) printf '%s\n' "$msg" >&2 ;;
  esac

  # rotate if necessary
  _rotate_core
}

# Public API
log_debug() { _log_generic "DEBUG" "$*"; }
log_info()  { _log_generic "INFO"  "$*"; }
log_warn()  { _log_generic "WARN"  "$*"; }
log_error() { _log_generic "ERROR" "$*"; }

log_fatal() {
  _log_generic "FATAL" "$*"
  # run fatal hooks (if any) with timeout
  if [ -n "${REGISTER_FATAL_HOOKS}" ]; then
    for hook in ${REGISTER_FATAL_HOOKS}; do
      if command -v timeout >/dev/null 2>&1; then
        timeout 10 ${hook} "$*" >/dev/null 2>&1 || _log_generic "WARN" "Fatal hook ${hook} failed or timed out"
      else
        ${hook} "$*" >/dev/null 2>&1 || _log_generic "WARN" "Fatal hook ${hook} failed"
      fi
    done
  fi
  # when script is run directly, exit; when sourced, do not exit caller
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    exit 1
  else
    return 1
  fi
}

# Self-test when executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "Running register.sh self-test..."
  log_info "Self-test info"
  log_debug "Self-test debug (visible only when DEBUG=1)"
  log_warn "Self-test warn"
  log_error "Self-test error"
  # run fatal hook demo (won't exit caller; will exit process)
  REGISTER_FATAL_HOOKS=""  # no hooks by default
  echo "Self-test completed."
fi
