#!/usr/bin/env bash
#
# logger.sh - robust logger helper for Linux From Scratch scripts
#
# Features:
#  - Safe creation of log directory (default /var/log/adm) with permission checks
#  - Sanitization of program name
#  - Append logs atomically using flock or lockdir fallback
#  - Colorized step output (disabled with NO_COLOR or --no-color or non-TTY)
#  - --dry-run mode (shows actions, no FS modifications)
#  - Signal handling for SIGINT/SIGTERM
#  - Detailed error handling and reporting (no silent failures)
#  - Optional verbose mode
#
# Usage:
#   logger.sh --program myapp --count 3 [--logdir /var/log/adm] [--dry-run] [--no-color] [--verbose]
#

set -o pipefail

# Defaults
LOGDIR_DEFAULT="/var/log/adm"
PROGRAM=""
COUNT=0
DRY_RUN=0
NO_COLOR=0
VERBOSE=0
UMASK_DEFAULT="0027"   # results in directories 750 and files 640 for common umask usage

# Helpers
timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Print to stderr
err() { printf "%s\n" "$*" >&2; }

# Fatal error and exit
die() {
  local code=${2:-1}
  err "FATAL: $1"
  exit "$code"
}

# Safe sanitize program name: only allow A-Za-z0-9._- (no slashes)
sanitize_name() {
  local name="$1"
  if [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf "%s" "$name"
  else
    return 1
  fi
}

# Show action (respects dry-run)
do_action() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

# Check if running in a TTY and color allowed
use_color() {
  if [ "$NO_COLOR" -eq 1 ]; then
    return 1
  fi
  if [ -t 1 ]; then
    return 0
  fi
  return 1
}

# Color codes
_color_reset="\e[0m"
_color_bold="\e[1m"
_color_blue="\e[1;34m"
_color_green="\e[1;32m"
_color_yellow="\e[1;33m"
_color_red="\e[1;31m"

# Print step to stdout (colored if allowed)
print_step() {
  local level="$1"
  local prog="$2"
  local idx="$3"
  local total="$4"
  local msg="$5"
  local color_open=""
  local color_close=""
  if use_color; then
    case "$level" in
      STEP) color_open="$_color_green" ;;
      INFO) color_open="$_color_blue" ;;
      WARN) color_open="$_color_yellow" ;;
      ERROR) color_open="$_color_red" ;;
      *) color_open="$_color_bold" ;;
    esac
    color_close="$_color_reset"
  fi
  # Print single-line summary to stdout
  if [ -n "$idx" ] && [ -n "$total" ] && [ "$total" -ne 0 ]; then
    printf "%s %b%s%b (%d/%d) — %s\n" "[$(timestamp)]" "${color_open}" "${prog}" "${color_close}" "$idx" "$total" "$msg"
  else
    printf "%s %b%s%b — %s\n" "[$(timestamp)]" "${color_open}" "${prog}" "${color_close}" "$msg"
  fi
}

# Create directory safely (with umask)
safe_mkdir() {
  local dir="$1"
  local umask_val="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] mkdir -p -- '$dir' && umask $umask_val"
    return 0
  fi
  # Create parent if needed
  mkdir -p -- "$dir" || return 1
  # Apply umask-equivalent permissions: we set permissive umask temporarily
  ( umask "$umask_val"; mkdir -p -- "$dir" ) || true
  return 0
}

# Create file safely and set perms if provided
safe_touch_and_chmod() {
  local file="$1"
  local mode="$2"
  local owner="$3"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] touch -- '$file' && chmod $mode '$file' && chown ${owner:-'(no-change)'} '$file'"
    return 0
  fi
  : > "$file" || return 1
  if [ -n "$mode" ]; then chmod "$mode" "$file" || return 1; fi
  if [ -n "$owner" ]; then chown "$owner" "$file" || return 1; fi
  return 0
}

# Locking helpers: prefer 'flock' binary; fallback to mkdir lockdir
acquire_lock() {
  local lockfile="$1"
  local lockdir="$2"
  # If flock binary exists, use it by opening fd 200
  if command -v flock >/dev/null 2>&1; then
    # Open file descriptor 200 for append and lock it
    exec 200>>"$lockfile" || return 1
    flock -x 200 || return 1
    # Caller will write to fd 200 (we keep it locked)
    return 0
  else
    # Fallback: directory-based lock
    local ld="${lockdir:-${lockfile}.lock}"
    local tries=0
    while ! mkdir "$ld" 2>/dev/null; do
      tries=$((tries+1))
      if [ "$tries" -ge 50 ]; then
        return 1
      fi
      sleep 0.05
    done
    # Lock acquired; export LOCKDIR for caller to release
    export __LOGGER_LOCKDIR="$ld"
    return 0
  fi
}

release_lock() {
  if command -v flock >/dev/null 2>&1; then
    # Release fd 200 and close it
    flock -u 200 2>/dev/null || true
    exec 200>&- || true
  else
    if [ -n "${__LOGGER_LOCKDIR:-}" ]; then
      rmdir "${__LOGGER_LOCKDIR}" 2>/dev/null || true
      unset __LOGGER_LOCKDIR
    fi
  fi
}

# Append a line to logfile atomically (with locking)
log_write() {
  local level="$1"
  local prog="$2"
  local msg="$3"
  local logfile="$4"
  local ts
  ts="$(timestamp)"
  local line="[$ts] $level $prog: $msg"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN-LOG] >> $logfile : $line"
    return 0
  fi

  # Ensure logfile directory exists
  local logdir
  logdir="$(dirname "$logfile")"
  if [ ! -d "$logdir" ]; then
    err "log_write: log directory '$logdir' missing (this should not happen)"
    return 1
  fi

  # Attempt acquire lock
  acquire_lock "$logfile" "${logfile}.lock" || {
    err "Could not acquire lock for '$logfile'"
    return 1
  }

  # Write line safely; if flock used we have fd 200 open; else write normally
  if command -v flock >/dev/null 2>&1; then
    # Write to fd 200
    printf "%s\n" "$line" >&200 || { release_lock; return 1; }
  else
    # Fallback: append to tmp and move (not strictly atomic across filesystems)
    printf "%s\n" "$line" >> "$logfile" || { release_lock; return 1; }
  fi

  release_lock
  return 0
}

# Signal handler
on_signal() {
  local sig="$1"
  if [ -n "$PROGRAM" ] && [ -n "$LOGFILE" ]; then
    log_write "WARN" "$PROGRAM" "Interrupted by signal $sig" "$LOGFILE" || true
  fi
  print_step "WARN" "${PROGRAM:-logger}" "" "" "Interrupted by $sig"
  exit 130
}

# Parse args (simple)
while [ $# -gt 0 ]; do
  case "$1" in
    --program) PROGRAM="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --logdir) LOGDIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-color) NO_COLOR=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --help) cat <<'USAGE'
Usage: logger.sh --program NAME --count N [--logdir /var/log/adm] [--dry-run] [--no-color] [--verbose]
Options:
  --program NAME    Name of the program (allowed characters A-Za-z0-9._-)
  --count N         Number of steps (integer)
  --logdir PATH     Directory for logs (default /var/log/adm)
  --dry-run         Show actions without modifying filesystem
  --no-color        Disable color output
  --verbose         More verbose diagnostic output
  --help            Show this help
USAGE
  exit 0 ;;
    *) err "Unknown option: $1"; exit 2 ;;
  esac
done

# Validate required args
if [ -z "$PROGRAM" ]; then
  die "Missing --program argument"
fi
if ! PROGRAM_SANITIZED="$(sanitize_name "$PROGRAM")"; then
  die "Invalid program name '$PROGRAM'. Allowed characters: A-Za-z0-9._- (no slashes)"
fi
PROGRAM="$PROGRAM_SANITIZED"

LOGDIR="${LOGDIR:-$LOGDIR_DEFAULT}"
LOGFILE="${LOGDIR%/}/${PROGRAM}.log"

# Setup signal traps
trap 'on_signal SIGINT' INT
trap 'on_signal SIGTERM' TERM

# Dry-run note
if [ "$DRY_RUN" -eq 1 ]; then
  echo "[DRY-RUN] No filesystem changes will be made."
fi

# Ensure logdir exists (with safe umask)
if [ "$DRY_RUN" -eq 0 ]; then
  # Check write permission or ability to create
  if [ -d "$LOGDIR" ]; then
    if [ ! -w "$LOGDIR" ]; then
      err "Directory '$LOGDIR' exists but is not writable by $(id -un) ($(id -u))."
      err "You may need to run as root or pick a different --logdir."
      exit 1
    fi
  else
    # Attempt to create with safe permissions
    umask_save="$(umask)"
    umask "$UMASK_DEFAULT"
    if ! mkdir -p -- "$LOGDIR" 2>/dev/null; then
      umask "$umask_save"
      die "Failed to create log directory '$LOGDIR' (permission denied?)"
    fi
    umask "$umask_save"
    # If possible, set sticky/owner perms (best-effort)
    if command -v chown >/dev/null 2>&1; then
      # keep current owner, but ensure perms are restrictive
      chmod 750 "$LOGDIR" 2>/dev/null || true
    fi
  fi
else
  echo "[DRY-RUN] ensure directory exists: $LOGDIR"
fi

# Create logfile if missing
if [ "$DRY_RUN" -eq 0 ]; then
  if [ ! -e "$LOGFILE" ]; then
    if ! safe_touch_and_chmod "$LOGFILE" 640 ""; then
      die "Failed to create logfile '$LOGFILE'. Check permissions."
    fi
  fi
else
  echo "[DRY-RUN] touch $LOGFILE"
fi

# Check SELinux enforcing state (informational, not modifying)
if command -v getenforce >/dev/null 2>&1; then
  sel="$(getenforce 2>/dev/null || true)"
  if [ -n "$sel" ] && [ "$sel" != "Disabled" ] && [ "$sel" != "Permissive" ]; then
    echo "[INFO] SELinux mode: $sel — ensure correct file context for $LOGDIR if writes fail."
  fi
fi

# Final startup message
print_step "INFO" "$PROGRAM" "1" "$COUNT" "Iniciando. Log: $LOGFILE"

# Example workflow: simulate COUNT steps; in real usage your scripts call log_write directly
i=1
while [ "$i" -le "$COUNT" ]; do
  # Simulate step message
  STEP_MSG="executando etapa $i"
  # Print to stdout summary
  print_step "STEP" "$PROGRAM" "$i" "$COUNT" "$STEP_MSG"
  # Write to logfile (do not fail the whole run if a single write fails; report it)
  if ! log_write "STEP" "$PROGRAM" "$STEP_MSG" "$LOGFILE"; then
    err "Warning: failed to write log for step $i to $LOGFILE"
    # attempt to continue
  fi
  # Simulate a small delay to mimic work (remove in production)
  sleep 0.01
  i=$((i+1))
done

# Completion message
print_step "INFO" "$PROGRAM" "" "" "Completado $PROGRAM (steps: $COUNT)."
log_write "INFO" "$PROGRAM" "Completed $COUNT steps" "$LOGFILE" || true

exit 0
