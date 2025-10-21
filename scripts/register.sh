#!/usr/bin/env bash
# register.sh - robust logger for LFS orchestrator
# Provides: log_debug, log_info, log_warn, log_error, log_fatal
if [ -n "${REGISTER_SH_LOADED-}" ]; then return 0 2>/dev/null || exit 0; fi
REGISTER_SH_LOADED=1

: "${LFS_LOG_DIR:=/var/log/lfs}"
: "${LFS_LOG_FILE:=${LFS_LOG_DIR}/orquestrador.log}"
: "${LFS_LOG_MAX_BYTES:=10485760}"   # 10MB
: "${LFS_LOG_BACKUPS:=5}"
: "${LFS_LOG_LEVEL:=INFO}"
: "${LFS_SENSITIVE_KEYS:=password secret token api_key auth key}"
mkdir -p "${LFS_LOG_DIR}" 2>/dev/null || true

C_INFO='\033[1;34m'; C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_OK='\033[1;32m'; C_RST='\033[0m'

_log_now() { date +'%Y-%m-%dT%H:%M:%S%z'; }

_mask_sensitive() {
  local line="$1"
  for k in ${LFS_SENSITIVE_KEYS}; do
    line="$(echo "$line" | sed -E "s/(${k})[[:space:]]*[:=][[:space:]]*([^[:space:]]+)/\1=*****/Ig")"
    line="$(echo "$line" | sed -E "s/\"(${k})\"[[:space:]]*[:=][[:space:]]*\"[^\"]+\"/\"\1\"=\"*****\"/Ig")"
  done
  echo "$line"
}

_write_line_atomic() {
  local file="$1"; shift
  local line="$*"
  if command -v flock >/dev/null 2>&1; then
    ( flock -x 200
      printf '%s\n' "$line" >> "$file"
    ) 200>"${file}.lock"
  else
    local lockdir="${file}.lockdir"
    local tries=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      tries=$((tries+1))
      sleep 0.05
      if [ $tries -gt 200 ]; then
        printf '%s\n' "$line" >> "$file"
        return 0
      fi
    done
    printf '%s\n' "$line" >> "$file"
    rmdir "$lockdir" 2>/dev/null || true
  fi
}

_rotate_core() {
  if [ ! -f "${LFS_LOG_FILE}" ]; then return 0; fi
  local size
  size=$(stat -c%s "${LFS_LOG_FILE}" 2>/dev/null || echo 0)
  if [ "$size" -lt "$LFS_LOG_MAX_BYTES" ]; then return 0; fi
  for ((i=LFS_LOG_BACKUPS; i>=1; i--)); do
    [ -f "${LFS_LOG_FILE}.$i.gz" ] && mv -f "${LFS_LOG_FILE}.$i.gz" "${LFS_LOG_FILE}.$((i+1)).gz" 2>/dev/null || true
    [ -f "${LFS_LOG_FILE}.$i" ] && mv -f "${LFS_LOG_FILE}.$i" "${LFS_LOG_FILE}.$((i+1))" 2>/dev/null || true
  done
  mv -f "${LFS_LOG_FILE}" "${LFS_LOG_FILE}.1" 2>/dev/null || true
  if command -v gzip >/dev/null 2>&1; then gzip -9 "${LFS_LOG_FILE}.1" >/dev/null 2>&1 || true; fi
  : > "${LFS_LOG_FILE}" 2>/dev/null || true
}

_log_generic() {
  local level="$1"; shift
  local color="$1"; shift
  local msg="$*"
  local ts; ts=$(_log_now)
  local plain="${ts} [${level}] ${msg}"
  plain="$(_mask_sensitive "$plain")"
  _write_line_atomic "${LFS_LOG_FILE}" "$plain"
  case "$level" in
    ERROR|FATAL) printf '%b %s %b\n' "${C_ERR}" "[$level]" "${C_RST}" >&2; printf '%s\n' "$msg" >&2 ;;
    WARN) printf '%b %s %b\n' "${C_WARN}" "[$level]" "${C_RST}" >&2 ;;
    INFO) printf '%b %s %b\n' "${C_INFO}" "[$level]" "${C_RST}" >&2 ;;
    DEBUG) [ "${DEBUG:-0}" -eq 1 ] && printf '%b %s %b\n' "[DEBUG]" "$msg" >&2 || true ;;
    OK) printf '%b %s %b\n' "${C_OK}" "[OK]" "${C_RST}" >&2 ;;
    *) printf '%s\n' "$msg" >&2 ;;
  esac
  # rotate if needed (synchronous)
  _rotate_core
}

log_debug() { _log_generic "DEBUG" "$C_INFO" "$*"; }
log_info()  { _log_generic "INFO"  "$C_INFO" "$*"; }
log_warn()  { _log_generic "WARN"  "$C_WARN" "$*"; }
log_error() { _log_generic "ERROR" "$C_ERR" "$*"; }
log_fatal() {
  _log_generic "FATAL" "$C_ERR" "$*"
  # run hooks if any (non-blocking, with timeout)
  if [ -n "${REGISTER_FATAL_HOOKS-}" ]; then
    for h in ${REGISTER_FATAL_HOOKS}; do
      if command -v timeout >/dev/null 2>&1; then
        timeout 10 "$h" "$*" >/dev/null 2>&1 || log_warn "Fatal hook $h failed/timeout"
      else
        "$h" "$*" >/dev/null 2>&1 || log_warn "Fatal hook $h failed"
      fi
    done
  fi
  exit 1
}
