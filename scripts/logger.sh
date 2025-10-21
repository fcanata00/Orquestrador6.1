#!/usr/bin/env bash
#
# logger.sh - Library-style logger for LFS build scripts
# Place this file in /usr/local/lfs-tools/logger.sh and source it from your build scripts:
#   source /usr/local/lfs-tools/logger.sh
#
# Public functions:
#   logger_init -- initialize logger for a program (returns status codes, does not exit)
#   logger_write -- append a log line (LEVEL MESSAGE)
#   logger_step -- print a colored step summary and write to log
#   logger_cleanup -- release locks and remove traps
#
# Behavior:
# - Safe creation of logdir (default /var/log/adm)
# - Sanitizes program names
# - Uses flock if available, fallback to lockdir
# - Honors DRY-RUN via --dry-run in logger_init or env LOGGER_DRY_RUN=1
# - Does NOT run main when sourced; if executed directly, runs main()
#

set -o pipefail

# ----------------------------
# Defaults / globals (prefixed LOGGER_)
# ----------------------------
LOGGER_LOGDIR_DEFAULT="/var/log/adm"
LOGGER_PROGRAM=""
LOGGER_COUNT=0
LOGGER_DRY_RUN=0
LOGGER_NO_COLOR=0
LOGGER_VERBOSE=0
LOGGER_UMASK_DEFAULT="0027"
LOGGER_LOGFILE=""
# internal lockdir variable when using lockdir fallback
__LOGGER_LOCKDIR=""

# ----------------------------
# Internal helpers (prefixed logger_)
# ----------------------------
logger_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
logger_err() { printf "%s\n" "$*" >&2; }

# sanitize_name: returns 0 and prints sanitized name, or returns 1 on invalid
logger_sanitize_name() {
  local name="$1"
  if [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf "%s" "$name"
    return 0
  fi
  return 1
}

# acquire lock using flock or lockdir fallback
logger_acquire_lock() {
  local lockfile="$1"
  local lockdir="${2:-${lockfile}.lock}"
  if command -v flock >/dev/null 2>&1; then
    # Open fd 200 and lock
    exec 200>>"$lockfile" || return 1
    flock -x 200 || return 1
    return 0
  else
    # fallback: try create lockdir
    local tries=0
    while ! mkdir -p "$lockdir" 2>/dev/null; do
      tries=$((tries+1))
      if [ "$tries" -ge 50 ]; then
        return 1
      fi
      sleep 0.05
    done
    __LOGGER_LOCKDIR="$lockdir"
    return 0
  fi
}

logger_release_lock() {
  if command -v flock >/dev/null 2>&1; then
    flock -u 200 2>/dev/null || true
    exec 200>&- || true
  else
    if [ -n "${__LOGGER_LOCKDIR:-}" ]; then
      rmdir "${__LOGGER_LOCKDIR}" 2>/dev/null || true
      __LOGGER_LOCKDIR=""
    fi
  fi
}

# atomic write with locking
logger_write() {
  local level="$1"; shift
  local msg="$*"
  local ts line
  ts="$(logger_timestamp)"
  line="[$ts] $level $LOGGER_PROGRAM: $msg"

  if [ "${LOGGER_DRY_RUN:-0}" -eq 1 ]; then
    logger_err "[DRY-RUN-LOG] >> ${LOGGER_LOGFILE} : ${line}"
    return 0
  fi

  # ensure logdir exists
  local logdir
  logdir="$(dirname "${LOGGER_LOGFILE}")"
  if [ ! -d "$logdir" ]; then
    logger_err "logger_write: log dir missing '$logdir'"
    return 2
  fi

  if ! logger_acquire_lock "${LOGGER_LOGFILE}" "${LOGGER_LOGFILE}.lock"; then
    logger_err "logger_write: could not acquire lock for '${LOGGER_LOGFILE}'"
    return 3
  fi

  if command -v flock >/dev/null 2>&1; then
    printf "%s\n" "$line" >&200 || { logger_release_lock; return 4; }
  else
    printf "%s\n" "$line" >> "${LOGGER_LOGFILE}" || { logger_release_lock; return 5; }
  fi

  logger_release_lock
  return 0
}

# Print step to stdout with colors if allowed
logger_print_step() {
  local level="$1"; local prog="$2"; local idx="$3"; local total="$4"; local msg="$5"
  local use_color=0
  if [ "${LOGGER_NO_COLOR:-0}" -eq 0 ] && [ -t 1 ]; then
    use_color=1
  fi
  local color_open="" color_close=""
  if [ "$use_color" -eq 1 ]; then
    case "$level" in
      STEP) color_open=$'\e[1;32m' ;; # green
      INFO) color_open=$'\e[1;34m' ;; # blue
      WARN) color_open=$'\e[1;33m' ;; # yellow
      ERROR) color_open=$'\e[1;31m' ;; # red
      *) color_open=$'\e[1m' ;;
    esac
    color_close=$'\e[0m'
  fi
  if [ -n "$idx" ] && [ -n "$total" ] && [ "$total" -ne 0 ]; then
    printf "[%s] %b%s%b (%d/%d) — %s\n" "$(logger_timestamp)" "${color_open}" "${prog}" "${color_close}" "$idx" "$total" "$msg"
  else
    printf "[%s] %b%s%b — %s\n" "$(logger_timestamp)" "${color_open}" "${prog}" "${color_close}" "$msg"
  fi
}

# ----------------------------
# Public functions (to be sourced)
# ----------------------------

# logger_init -- initialize logger for a program
# returns non-zero on error; does not exit.
logger_init() {
  # Reset defaults for this init
  LOGGER_PROGRAM=""
  LOGGER_COUNT=0
  LOGGER_LOGDIR=""
  LOGGER_DRY_RUN=0
  LOGGER_NO_COLOR=0
  LOGGER_VERBOSE=0
  LOGGER_LOGFILE=""

  # parse args
  local argv=("$@")
  local i=0
  while [ $i -lt ${#argv[@]} ]; do
    case "${argv[$i]}" in
      --program) i=$((i+1)); LOGGER_PROGRAM="${argv[$i]}" ;;
      --count)   i=$((i+1)); LOGGER_COUNT="${argv[$i]}" ;;
      --logdir)  i=$((i+1)); LOGGER_LOGDIR="${argv[$i]}" ;;
      --dry-run) LOGGER_DRY_RUN=1 ;;
      --no-color) LOGGER_NO_COLOR=1 ;;
      --verbose) LOGGER_VERBOSE=1 ;;
      *) logger_err "logger_init: unknown option: ${argv[$i]}"; return 2 ;;
    esac
    i=$((i+1))
  done

  if [ -z "$LOGGER_PROGRAM" ]; then
    logger_err "logger_init: missing --program"
    return 3
  fi

  local sanitized
  if ! sanitized="$(logger_sanitize_name "$LOGGER_PROGRAM")"; then
    logger_err "logger_init: invalid program name '$LOGGER_PROGRAM' (allowed: A-Za-z0-9._-)"
    return 4
  fi
  LOGGER_PROGRAM="$sanitized"
  LOGGER_LOGDIR="${LOGGER_LOGDIR:-$LOGGER_LOGDIR_DEFAULT}"
  LOGGER_LOGFILE="${LOGGER_LOGDIR%/}/${LOGGER_PROGRAM}.log"

  # create logdir if needed
  if [ "${LOGGER_DRY_RUN}" -eq 0 ]; then
    if [ -d "$LOGGER_LOGDIR" ]; then
      if [ ! -w "$LOGGER_LOGDIR" ]; then
        logger_err "logger_init: directory '$LOGGER_LOGDIR' exists but is not writable by $(id -un)"
        return 5
      fi
    else
      # attempt create with safe umask
      local saved_umask
      saved_umask="$(umask)"
      umask "${LOGGER_UMASK_DEFAULT}"
      if ! mkdir -p -- "$LOGGER_LOGDIR" 2>/dev/null; then
        umask "$saved_umask"
        logger_err "logger_init: failed to create logdir '$LOGGER_LOGDIR'"
        return 6
      fi
      umask "$saved_umask"
      chmod 750 "$LOGGER_LOGDIR" 2>/dev/null || true
    fi

    # create logfile if missing
    if [ ! -e "$LOGGER_LOGFILE" ]; then
      : > "$LOGGER_LOGFILE" || { logger_err "logger_init: cannot create logfile '$LOGGER_LOGFILE'"; return 7; }
      chmod 640 "$LOGGER_LOGFILE" 2>/dev/null || true
    fi
  else
    logger_err "[DRY-RUN] Would ensure directory: $LOGGER_LOGDIR and logfile: $LOGGER_LOGFILE"
  fi

  # Setup traps for signals (caller may override)
  trap 'logger_on_signal SIGINT' INT
  trap 'logger_on_signal SIGTERM' TERM

  return 0
}

# logger_step INDEX TOTAL MESSAGE
logger_step() {
  local idx="$1"; local total="$2"; shift 2
  local msg="$*"
  logger_print_step "STEP" "${LOGGER_PROGRAM}" "$idx" "$total" "$msg"
  if ! logger_write "STEP" "$msg"; then
    logger_err "logger_step: failed to write log"
    return 1
  fi
  return 0
}

# Generic write wrapper (LEVEL MESSAGE)
logger_write_level() {
  local level="$1"; shift
  logger_write "$level" "$*"
}

# logger_on_signal - default handler
logger_on_signal() {
  local sig="$1"
  # Best-effort logging (do not fail)
  logger_write "WARN" "Interrupted by signal $sig" >/dev/null 2>&1 || true
  logger_print_step "WARN" "${LOGGER_PROGRAM:-logger}" "" "" "Interrupted by $sig"
  # default behavior: exit 130 (but caller can override trap if they want different behavior)
  exit 130
}

# logger_cleanup - release locks and cleanup traps
logger_cleanup() {
  logger_release_lock || true
  trap - INT TERM
}

# Optional: export functions for subshell use (uncomment if needed)
# export -f logger_init logger_step logger_write logger_cleanup

# ----------------------------
# main - run when executed directly
# ----------------------------
_main() {
  # Use logger_init; exit on failure (standalone behavior)
  logger_init "$@" || { logger_err "main: logger_init failed"; exit 1; }

  logger_print_step "INFO" "${LOGGER_PROGRAM}" "1" "${LOGGER_COUNT}" "Iniciando. Log: ${LOGGER_LOGFILE}"
  local i=1
  while [ "$i" -le "${LOGGER_COUNT:-0}" ]; do
    logger_step "$i" "${LOGGER_COUNT}" "executando etapa $i"
    i=$((i+1))
  done

  logger_write "INFO" "Completed ${LOGGER_COUNT} steps" >/dev/null 2>&1 || true
  logger_cleanup
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _main "$@"
fi
