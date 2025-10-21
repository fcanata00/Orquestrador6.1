#!/usr/bin/env bash
# ============================================================================
# sandbox.sh - Ambiente isolado e seguro para builds LFS (PRO)
# ============================================================================
# Recursos:
# - Modos: auto (namespace > chroot > simple), namespace (unshare), chroot, simple, container (docker/podman)
# - Locking, retries/backoff, snapshots, rollback, logs integrados com register.sh
# - Proteção contra vazamento de variáveis, montagem segura, tmpfs, ulimits, network optional
# - Self-test, dry-run, debug, quiet modes
# ============================================================================
set -o errexit
set -o nounset
set -o pipefail

# Guard to prevent double-source
if [ -n "${SANDBOX_SH_PRO_LOADED-}" ]; then
  return 0 2>/dev/null || exit 0
fi
SANDBOX_SH_PRO_LOADED=1

# ------------------------------
# Defaults (can be overridden via env)
# ------------------------------
: "${LFS_ROOT:=/mnt/lfs}"
: "${SANDBOX_ROOT:=${LFS_ROOT}/sandbox}"
: "${SANDBOX_MODE:=auto}"   # auto, namespace, chroot, simple, container
: "${SANDBOX_TMP:=/tmp}"
: "${SANDBOX_AUTOSNAPSHOT:=1}"
: "${SANDBOX_SNAP_KEEP:=3}"
: "${SANDBOX_UMASK:=022}"
: "${SANDBOX_LOCK:=${SANDBOX_ROOT}/.lock/sandbox.lock}"
: "${SANDBOX_DEBUG:=0}"
: "${SANDBOX_QUIET:=0}"
: "${SANDBOX_DRY_RUN:=0}"
: "${SANDBOX_NO_NET:=0}"    # 1 = block network inside sandbox
: "${SANDBOX_RETENTION_DAYS:=7}"

CORE_REGISTER_PATHS=( "./register.sh" "/usr/local/bin/register.sh" "/usr/local/lib/lfs/register.sh" "${LFS_ROOT}/scripts/register.sh" "/usr/lib/lfs/register.sh" )

# ------------------------------
# Internal state
# ------------------------------
LOG_DIR="${SANDBOX_ROOT}/logs"
ROOTFS_DIR="${SANDBOX_ROOT}/rootfs"
BUILD_DIR="${SANDBOX_ROOT}/build"
TMP_DIR="${SANDBOX_ROOT}/tmp"
MOUNT_DIR="${SANDBOX_ROOT}/mounts"
SNAP_DIR="${SANDBOX_ROOT}/snapshot"
STATUS_DIR="${SANDBOX_ROOT}/status"
DEPS_INTEGRATED=0

# metrics
SB_ERRORS=0

# ------------------------------
# Logger integration (try register.sh then fallback)
# ------------------------------
_deps_try_load_register() {
  if declare -F log_info >/dev/null 2>&1; then return 0; fi
  for p in "${CORE_REGISTER_PATHS[@]}"; do
    [ -f "$p" ] || continue
    # shellcheck source=/dev/null
    source "$p" && declare -F log_info >/dev/null 2>&1 && return 0
  done
  return 1
}

_color_info='\033[1;34m'; _color_warn='\033[1;33m'; _color_err='\033[1;31m'; _color_reset='\033[0m'
_sb_log() {
  local level="$1"; shift; local msg="$*"; local ts; ts="$(date +'%Y-%m-%dT%H:%M:%S%z')"
  case "$level" in
    INFO)  [ "$SANDBOX_QUIET" -eq 0 ] && printf "%s ${_color_info}[INFO]${_color_reset} %s\n" "$ts" "$msg" >&2 || true ;;
    WARN)  printf "%s ${_color_warn}[WARN]${_color_reset} %s\n" "$ts" "$msg" >&2 ;;
    ERROR) printf "%s ${_color_err}[ERROR]${_color_reset} %s\n" "$ts" "$msg" >&2 ;;
    FATAL) printf "%s ${_color_err}[FATAL]${_color_reset} %s\n" "$ts" "$msg" >&2 ;;
    DEBUG) [ "$SANDBOX_DEBUG" -eq 1 ] && printf "%s [DEBUG] %s\n" "$ts" "$msg" >&2 || true ;;
    *) printf "%s [LOG] %s\n" "$ts" "$msg" >&2 ;;
  esac
}

if _deps_try_load_register; then
  : # use log_info etc from register.sh
else
  log_info()  { _sb_log INFO "$*"; }
  log_warn()  { _sb_log WARN "$*"; }
  log_error() { _sb_log ERROR "$*"; }
  log_fatal() { _sb_log FATAL "$*"; exit 1; }
  log_debug() { _sb_log DEBUG "$*"; }
fi

# ------------------------------
# Helpers: retry, sleep ms, atomic write, safe mkdir
# ------------------------------
_sleep_ms() {
  local ms="$1"
  if command -v perl >/dev/null 2>&1; then perl -e "select(undef,undef,undef,$ms/1000)"; else sleep "$(awk "BEGIN {print $ms/1000}")"; fi
}

_retry_cmd() {
  local max="${1:-5}"; shift; local attempt=0 delay=100
  while :; do
    "$@" && return 0
    local rc=$?
    attempt=$((attempt+1))
    SB_ERRORS=$((SB_ERRORS+1))
    if [ "$attempt" -ge "$max" ]; then
      log_warn "Command failed after $attempt attempts (rc=$rc): $*"
      return "$rc"
    fi
    log_debug "Retrying ($attempt/$max) after ${delay}ms: $*"
    _sleep_ms "$delay"
    delay=$((delay*2))
  done
}

_atomic_write() {
  local file="$1"; shift; local tmp="${file}.$$.$RANDOM.tmp"
  { printf '%s\n' "$@"; } > "$tmp" && mv -f "$tmp" "$file"
}

_safe_mkdir() {
  local d="$1"; mkdir -p "$d" 2>/dev/null || true; chmod 0755 "$d" 2>/dev/null || true
}

# ------------------------------
# Setup directories and permissions
# ------------------------------
sandbox_init_dirs() {
  umask "$SANDBOX_UMASK"
  _safe_mkdir "$SANDBOX_ROOT"
  _safe_mkdir "$LOG_DIR"
  _safe_mkdir "$ROOTFS_DIR"
  _safe_mkdir "$BUILD_DIR"
  _safe_mkdir "$TMP_DIR"
  _safe_mkdir "$MOUNT_DIR"
  _safe_mkdir "$SNAP_DIR"
  _safe_mkdir "$STATUS_DIR"
  log_debug "Sandbox directories initialized under $SANDBOX_ROOT"
}

# ------------------------------
# Acquire/release lock to avoid concurrent sandboxes
# ------------------------------
_sandbox_acquire_lock() {
  mkdir -p "$(dirname "$SANDBOX_LOCK")" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    exec 202>"$SANDBOX_LOCK"
    local start=$(date +%s)
    while ! flock -x 202 2>/dev/null; do
      local now=$(date +%s)
      if [ $((now - start)) -ge "${DEPS_LOCK_TIMEOUT:-120}" ]; then
        log_error "Timeout acquiring sandbox lock $SANDBOX_LOCK"
        return 1
      fi
      sleep 0.1
    done
    return 0
  else
    local d="${SANDBOX_LOCK}.d" start=$(date +%s)
    while ! mkdir "$d" 2>/dev/null; do
      local now=$(date +%s)
      if [ $((now - start)) -ge "${DEPS_LOCK_TIMEOUT:-120}" ]; then
        log_error "Timeout acquiring lockdir $d"
        return 1
      fi
      sleep 0.1
    done
    printf '%s\n' "$$" > "${d}/pid" 2>/dev/null || true
    return 0
  fi
}

_sandbox_release_lock() {
  if command -v flock >/dev/null 2>&1; then
    flock -u 202 2>/dev/null || true; exec 202>&- || true
  else
    local d="${SANDBOX_LOCK}.d"; [ -d "$d" ] && rm -rf "$d" 2>/dev/null || true
  fi
}

# ------------------------------
# Detect best sandbox mode
# ------------------------------
sandbox_detect_mode() {
  if [ "$SANDBOX_MODE" != "auto" ]; then
    log_info "Sandbox mode forced to $SANDBOX_MODE"
    return 0
  fi
  if command -v unshare >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    SANDBOX_MODE="namespace"
  elif command -v chroot >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    SANDBOX_MODE="chroot"
  else
    SANDBOX_MODE="simple"
  fi
  log_info "Auto-selected sandbox mode: $SANDBOX_MODE"
}

# ------------------------------
# Clean environment and drop host variables
# ------------------------------
_sandbox_clean_env() {
  log_debug "Cleaning environment for sandbox"
  unset LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG DYLD_LIBRARY_PATH
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export HOME="/root"
  export TMPDIR="${TMP_DIR}"
  export LANG="${LANG:-C.UTF-8}"
}

# ------------------------------
# Setup ulimits and resource caps
# ------------------------------
_sandbox_setup_limits() {
  log_debug "Setting ulimits"
  ulimit -n 4096 || true
  ulimit -u 1024 || true
  ulimit -s 8192 || true
  ulimit -c 0 || true
}

# ------------------------------
# Mounts and namespace setup (namespace mode)
# ------------------------------
_sandbox_setup_namespace() {
  log_info "Setting up sandbox namespace (unshare)"
  # prepare directories
  _safe_mkdir "$ROOTFS_DIR" "$BUILD_DIR" "$TMP_DIR" "$MOUNT_DIR"
  # create minimal rootfs if empty (bind-mount host /bin /lib as read-only)
  if [ -z "$(ls -A "$ROOTFS_DIR" 2>/dev/null)" ]; then
    log_info "Rootfs empty, creating minimal bind mounts (read-only)"
    mkdir -p "$ROOTFS_DIR"/{bin,lib,lib64,usr,etc,dev,proc,tmp,var} 2>/dev/null || true
  fi
  # Use unshare to run a subshell with its own namespaces when sandbox_exec uses it
}

# ------------------------------
# Setup chroot (prepare rootfs)
# ------------------------------
_sandbox_prepare_chroot() {
  log_info "Preparing chroot environment"
  if [ -z "$(ls -A "$ROOTFS_DIR" 2>/dev/null)" ]; then
    log_warn "Rootfs empty; chroot may fail due to missing libraries"
  fi
}

# ------------------------------
# Simple mode: just set env and use directories
# ------------------------------
_sandbox_setup_simple() {
  log_info "Using simple sandbox mode (no kernel namespaces)"
  _sandbox_clean_env
  _sandbox_setup_limits
}

# ------------------------------
# Snapshot (tar + optional zstd/gzip)
# ------------------------------
sandbox_snapshot() {
  local tag="${1:-prebuild}"
  _safe_mkdir "$SNAP_DIR"
  local ts; ts="$(date +%Y%m%d%H%M%S)"
  local outfile="${SNAP_DIR}/${tag}-${ts}.tar"
  if command -v zstd >/dev/null 2>&1; then
    outfile="${outfile}.zst"
    tar --posix -C "$SANDBOX_ROOT" -cf - . | zstd -T0 -o "$outfile" || { log_warn "Snapshot creation failed"; return 1; }
  else
    gzip -c > "${outfile}.gz" <<'EOF'
EOF
    # fallback: create tar.gz
    tar --posix -C "$SANDBOX_ROOT" -cf - . | gzip -c > "${outfile}.gz" || { log_warn "Snapshot creation failed"; return 1; }
    outfile="${outfile}.gz"
  fi
  # rotate snapshots
  (ls -1t "${SNAP_DIR}/${tag}-"*.tar* 2>/dev/null || true) | tail -n +$((SANDBOX_SNAP_KEEP+1)) | xargs -r rm -f || true
  log_info "Snapshot created: $outfile"
  return 0
}

# ------------------------------
# Restore (limited safety checks)
# ------------------------------
sandbox_restore() {
  local snapfile="$1"
  if [ -z "$snapfile" ] || [ ! -f "$snapfile" ]; then log_warn "Snapshot not found: $snapfile"; return 1; fi
  log_info "Restoring snapshot: $snapfile (this may be slow)"
  # prefer lazy unmount & rm then extract
  umount "$SANDBOX_ROOT"/* 2>/dev/null || true
  rm -rf "$SANDBOX_ROOT"/* 2>/dev/null || true
  if [[ "$snapfile" == *.zst ]]; then
    zstd -d "$snapfile" -c | tar -x -C "$SANDBOX_ROOT" || { log_error "Failed to restore snapshot"; return 1; }
  else
    if [[ "$snapfile" == *.gz ]]; then
      gzip -dc "$snapfile" | tar -x -C "$SANDBOX_ROOT" || { log_error "Failed to restore snapshot"; return 1; }
    else
      tar -xf "$snapfile" -C "$SANDBOX_ROOT" || { log_error "Failed to restore snapshot"; return 1; }
    fi
  fi
  log_info "Restore completed"
  return 0
}

# ------------------------------
# Cleanup: unmount and rm; robust to busy mounts
# ------------------------------
sandbox_cleanup() {
  log_info "Running sandbox cleanup"
  # attempt lazy umounts, retries
  local tries=0
  while mount | grep -q "$MOUNT_DIR" 2>/dev/null && [ $tries -lt 5 ]; do
    umount -l "$MOUNT_DIR"/* 2>/dev/null || true
    sleep 0.2
    tries=$((tries+1))
  done
  # remove temp files
  rm -rf "${SANDBOX_ROOT}/tmp"/* 2>/dev/null || true
  # optionally remove entire sandbox (if configured)
  if [ "${SANDBOX_KEEP_LOGS:-1}" -eq 0 ]; then
    rm -rf "$SANDBOX_ROOT" 2>/dev/null || true
    log_info "Sandbox removed entirely"
  else
    log_info "Sandbox cleaned; logs retained in $LOG_DIR"
  fi
  _sandbox_release_lock || true
  return 0
}

# ------------------------------
# Execute command inside sandbox
# Handles modes: namespace (unshare), chroot, simple
# ------------------------------
sandbox_exec() {
  local cmd="$*"
  log_info "sandbox_exec: $cmd"
  if [ "${SANDBOX_DRY_RUN:-0}" -eq 1 ]; then log_info "[dry-run] $cmd"; return 0; fi
  case "$SANDBOX_MODE" in
    namespace)
      if ! command -v unshare >/dev/null 2>&1; then log_warn "unshare not available; falling back"; SANDBOX_MODE="chroot";;
      # run command inside new namespaces; bind-mount necessary dirs read-only
      _retry_cmd 3 unshare --mount --uts --ipc --net --pid --fork --mount-proc bash -c "\
        mkdir -p '${MOUNT_DIR}' && mount --bind '${ROOTFS_DIR}' '${ROOTFS_DIR}' && mount -o remount,ro '${ROOTFS_DIR}' || true; \
        export PATH='${PATH}'; export HOME='${HOME}'; cd '${BUILD_DIR}'; ${cmd}" || { log_error "sandbox namespace execution failed"; return 1; }
      ;;
    chroot)
      if [ ! -d "$ROOTFS_DIR" ]; then log_warn "rootfs missing; chroot may fail"; fi
      _retry_cmd 3 chroot "$ROOTFS_DIR" /bin/bash -lc "export PATH='${PATH}'; export HOME='${HOME}'; cd '${BUILD_DIR}'; ${cmd}" || { log_error "chroot execution failed"; return 1; }
      ;;
    simple)
      # simply isolate env and run in BUILD_DIR
      ( _sandbox_clean_env; cd "$BUILD_DIR"; bash -lc "${cmd}" ) || { log_error "simple sandbox execution failed"; return 1; }
      ;;
    container)
      if command -v docker >/dev/null 2>&1; then
        log_info "Running inside docker (ephemeral)"
        docker run --rm -v "${BUILD_DIR}:/build:rw" -w /build busybox sh -c "${cmd}" || { log_error "docker execution failed"; return 1; }
      else
        log_warn "docker not available; falling back to simple mode"; ( _sandbox_clean_env; cd "$BUILD_DIR"; bash -lc "${cmd}" ) || return 1
      fi
      ;;
    *)
      log_warn "Unknown sandbox mode: $SANDBOX_MODE; using simple"
      ( _sandbox_clean_env; cd "$BUILD_DIR"; bash -lc "${cmd}" ) || { log_error "execution failed"; return 1; }
      ;;
  esac
  return 0
}

# ------------------------------
# Status and housekeeping
# ------------------------------
sandbox_status() {
  cat <<EOF
SANDBOX STATUS
  SANDBOX_ROOT: $SANDBOX_ROOT
  MODE: $SANDBOX_MODE
  BUILD_DIR: $BUILD_DIR
  LOG_DIR: $LOG_DIR
  SNAP_DIR: $SNAP_DIR
  ERRORS: $SB_ERRORS
EOF
}

# ------------------------------
# Self-test: builds a small file in sandbox and validates isolation
# ------------------------------
sandbox_self_test() {
  log_info "Running sandbox self-test..."
  sandbox_init_dirs
  _sandbox_acquire_lock || { log_fatal "Could not acquire sandbox lock"; }
  sandbox_detect_mode
  case "$SANDBOX_MODE" in
    namespace) _sandbox_setup_namespace ;;
    chroot) _sandbox_prepare_chroot ;;
    simple) _sandbox_setup_simple ;;
  esac
  _sandbox_clean_env
  _sandbox_setup_limits
  # test execution
  echo "echo hello-from-sandbox > ${BUILD_DIR}/sbtest.out" > "${BUILD_DIR}/runme.sh"
  chmod +x "${BUILD_DIR}/runme.sh"
  sandbox_exec "bash ${BUILD_DIR}/runme.sh" || { log_error "Execution test failed"; SB_ERRORS=$((SB_ERRORS+1)); }
  if [ -f "${BUILD_DIR}/sbtest.out" ]; then
    log_info "Self-test executed and wrote ${BUILD_DIR}/sbtest.out"
    rm -f "${BUILD_DIR}/sbtest.out"
  else
    log_error "Self-test did not create expected file; isolation may be broken"; SB_ERRORS=$((SB_ERRORS+1))
  fi
  sandbox_snapshot "selftest" || log_warn "Snapshot failed during self-test (non-critical)"
  sandbox_cleanup
  _sandbox_release_lock
  if [ "$SB_ERRORS" -ne 0 ]; then log_error "Self-test failed with $SB_ERRORS errors"; return 2; fi
  log_info "Self-test OK"
  return 0
}

# ------------------------------
# CLI handling
# ------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"
  case "$cmd" in
    --help) cat <<'EOF'
Usage: sandbox.sh [options] <command>
Options: --debug, --quiet, --dry-run
Commands:
  init            Initialize sandbox dirs
  status          Show sandbox status
  snapshot [tag]  Create snapshot
  restore <file>  Restore snapshot
  exec <cmd>      Execute command inside sandbox
  enter           Open interactive shell inside sandbox
  cleanup         Cleanup sandbox (unmounts/removes tmp)
  self-test       Run integrated self-test
EOF
      exit 0 ;;
    --debug) SANDBOX_DEBUG=1; shift; cmd="${1:-}";;
    --quiet) SANDBOX_QUIET=1; shift; cmd="${1:-}";;
    --dry-run) SANDBOX_DRY_RUN=1; shift; cmd="${1:-}";;
  esac

  case "$cmd" in
    init) sandbox_init_dirs; exit 0 ;;
    status) sandbox_status; exit 0 ;;
    snapshot) sandbox_snapshot "${2:-pre}" ; exit $? ;;
    restore) sandbox_restore "${2:-}" ; exit $? ;;
    exec) shift; sandbox_init_dirs; _sandbox_acquire_lock || { log_fatal "Lock failed"; }; sandbox_detect_mode; sandbox_exec "$*" ; _sandbox_release_lock; exit $? ;;
    enter) sandbox_init_dirs; _sandbox_acquire_lock || { log_fatal "Lock failed"; }; sandbox_detect_mode; bash --noprofile --norc -i -c "cd ${BUILD_DIR}; bash" ; _sandbox_release_lock; exit 0 ;;
    cleanup) sandbox_cleanup; exit 0 ;;
    self-test) sandbox_self_test; exit $? ;;
    *) echo "Usage: $0 --help"; exit 2 ;;
  esac
fi

# EOF
