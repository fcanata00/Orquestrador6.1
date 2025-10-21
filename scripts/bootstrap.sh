#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh - LFS Bootstrap PRO (sandbox mandatory, tar.zst, retries=3)
# =============================================================================
# Full-featured bootstrapper for Linux From Scratch stages (1..3)
# - Sandbox/chroot is mandatory
# - Packages rootfs as .tar.zst
# - Default retries per package: 3
# - Robust error handling, logging, resume and cleanup
# =============================================================================
set -o errexit
set -o nounset
set -o pipefail

if [ -n "${BOOTSTRAP_SH_PRO_LOADED-}" ]; then
  return 0 2>/dev/null || exit 0
fi
BOOTSTRAP_SH_PRO_LOADED=1

: "${LFS_ROOT:=/mnt/lfs}"
: "${BOOTSTRAP_STAGES_DIR:=${LFS_ROOT}/meta/stages}"
: "${BOOTSTRAP_LOG_ROOT:=${LFS_ROOT}/build_logs}"
: "${BOOTSTRAP_CACHE_DIR:=${LFS_ROOT}/cache}"
: "${BUILD_SCRIPT:=./build.sh}"
: "${META_SCRIPT:=./metadata.sh}"
: "${DOWNLOAD_SCRIPT:=./download.sh}"
: "${SANDBOX_SCRIPT:=./sandbox.sh}"
: "${BOOTSTRAP_STRICT:=1}"
: "${BOOTSTRAP_RETRY:=3}"
: "${BOOTSTRAP_MIN_SPACE_MB:=10240}"
: "${BOOTSTRAP_TIMEOUT_PER_PKG:=0}"
: "${BOOTSTRAP_QUIET:=0}"
: "${BOOTSTRAP_KEEP_LOGS:=1}"
: "${BOOTSTRAP_RESUME:=1}"

CORE_BUILD_PATHS=( "./build.sh" "${LFS_ROOT}/scripts/build.sh" "/usr/local/bin/build.sh" )
CORE_METADATA_PATHS=( "./metadata.sh" "${LFS_ROOT}/scripts/metadata.sh" "/usr/local/lib/lfs/metadata.sh" )
CORE_SANDBOX_PATHS=( "./sandbox.sh" "${LFS_ROOT}/scripts/sandbox.sh" )
CORE_DOWNLOAD_PATHS=( "./download.sh" "${LFS_ROOT}/scripts/download.sh" )
CORE_REGISTER_PATHS=( "./register.sh" "/usr/local/bin/register.sh" "/usr/local/lib/lfs/register.sh" "${LFS_ROOT}/scripts/register.sh" "/usr/lib/lfs/register.sh" )

_color_info='\033[1;34m'; _color_warn='\033[1;33m'; _color_err='\033[1;31m'; _color_ok='\033[1;32m'; _color_reset='\033[0m'

# logger
_bootstrap_try_load_register() {
  if declare -F log_info >/dev/null 2>&1; then return 0; fi
  for p in "${CORE_REGISTER_PATHS[@]}"; do
    [ -f "$p" ] || continue
    # shellcheck source=/dev/null
    source "$p" && declare -F log_info >/dev/null 2>&1 && return 0
  done
  return 1
}
_bootstrap_log() {
  local lvl="$1"; shift; local msg="$*"; local ts
  ts="$(date +'%Y-%m-%dT%H:%M:%S%z')"
  case "$lvl" in
    INFO)  [ "${BOOTSTRAP_QUIET}" -eq 0 ] && printf "%s ${_color_info}[INFO]${_color_reset} %s\n" "$ts" "$msg" >&2 || true ;;
    WARN)  printf "%s ${_color_warn}[WARN]${_color_reset} %s\n" "$ts" "$msg" >&2 ;;
    ERROR) printf "%s ${_color_err}[ERROR]${_color_reset} %s\n" "$ts" "$msg" >&2 ;;
    OK)    printf "%s ${_color_ok}[OK]${_color_reset} %s\n" "$ts" "$msg" >&2 ;;
    *)     printf "%s [LOG] %s\n" "$ts" "$msg" >&2 ;;
  esac
}
if _bootstrap_try_load_register; then :; else
  log_info()  { _bootstrap_log INFO "$*"; }
  log_warn()  { _bootstrap_log WARN "$*"; }
  log_error() { _bootstrap_log ERROR "$*"; }
  log_ok()    { _bootstrap_log OK "$*"; }
fi

_now() { date +%s; }
_sleep_ms() { local ms="$1"; if command -v perl >/dev/null 2>&1; then perl -e "select(undef,undef,undef,$ms/1000)"; else sleep "$(awk "BEGIN {print $ms/1000}")"; fi }
_hash_file() { local f="$1"; if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f" | awk '{print $1}'; else echo ""; fi }
_atomic_write() { local file="$1"; shift; local tmp="${file}.$$.$RANDOM.tmp"; { printf '%s\n' "$@"; } > "$tmp" && mv -f "$tmp" "$file"; }

_find_core_scripts() {
  for p in "${CORE_BUILD_PATHS[@]}"; do [ -f "$p" ] && { BUILD_SCRIPT="$p"; break; }; done
  for p in "${CORE_METADATA_PATHS[@]}"; do [ -f "$p" ] && { META_SCRIPT="$p"; break; }; done
  for p in "${CORE_DOWNLOAD_PATHS[@]}"; do [ -f "$p" ] && { DOWNLOAD_SCRIPT="$p"; break; }; done
  for p in "${CORE_SANDBOX_PATHS[@]}"; do [ -f "$p" ] && { SANDBOX_SCRIPT="$p"; break; }; done
}

# cleanup trap
_BOOTSTRAP_MOUNTS_DONE=0
_cleanup_on_exit() {
  local rc=$?
  if [ "${_BOOTSTRAP_MOUNTS_DONE}" -eq 1 ]; then
    log_info "Cleaning up mounts..."
    _bootstrap_unmount_all || true
  fi
  if [ $rc -ne 0 ]; then log_error "bootstrap.sh exited with code $rc"; fi
  exit $rc
}
trap _cleanup_on_exit INT TERM EXIT

_check_root() {
  if [ "$(id -u)" -ne 0 ]; then log_error "bootstrap.sh must be run as root"; return 2; fi
  return 0
}
_check_space() {
  local need_mb=${1:-$BOOTSTRAP_MIN_SPACE_MB}
  local avail
  avail=$(df -Pm "$LFS_ROOT" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
  if [ "$avail" -lt "$need_mb" ]; then log_error "Insufficient space (${avail}MB) on $LFS_ROOT (need ${need_mb}MB)"; return 3; fi
  return 0
}

_prepare_lfs_layout() {
  log_info "Preparing LFS layout under ${LFS_ROOT}"
  mkdir -p "${LFS_ROOT}" "${LFS_ROOT}/sources" "${LFS_ROOT}/tools" "${LFS_ROOT}/builds" "${BOOTSTRAP_LOG_ROOT}" "${BOOTSTRAP_CACHE_DIR}" "${BOOTSTRAP_STAGES_DIR}" 2>/dev/null || true
  local dirs=( bin boot dev etc home lib lib64 mnt opt proc root run sbin srv sys tmp usr var tools sources build_logs cache meta )
  for d in "${dirs[@]}"; do mkdir -p "${LFS_ROOT}/${d}" 2>/dev/null || true; done
  chmod 0750 "${LFS_ROOT}/root" 2>/dev/null || true
  chmod 1777 "${LFS_ROOT}/tmp" 2>/dev/null || true
  ln -sfn usr/bin "${LFS_ROOT}/bin" 2>/dev/null || true
  ln -sfn usr/lib "${LFS_ROOT}/lib" 2>/dev/null || true
  ln -sfn usr/sbin "${LFS_ROOT}/sbin" 2>/dev/null || true
  log_ok "LFS layout created"
  return 0
}

_create_lfs_user() {
  log_info "Creating 'lfs' user/group if missing"
  if ! id lfs >/dev/null 2>&1; then
    groupadd lfs 2>/dev/null || true
    useradd -s /bin/bash -g lfs -m -k /dev/null lfs 2>/dev/null || true
    passwd -d lfs 2>/dev/null || true
  fi
  chown -R lfs:lfs "${LFS_ROOT}" 2>/dev/null || true
  chown -R lfs:lfs /home/lfs 2>/dev/null || true
  local profile="/home/lfs/.bash_profile"; local rc="/home/lfs/.bashrc"
  cat > "$profile" <<'EOF'
exec env -i HOME=/home/lfs TERM=$TERM PS1='\u:\w\$ ' \
  PATH=/usr/bin:/bin:/tools/bin /bin/bash
EOF
  cat > "$rc" <<'EOF'
set +h
umask 022
LFS=/mnt/lfs
LC_ALL=POSIX
LFS_TGT=$(uname -m)-lfs-linux-gnu
PATH=/usr/bin:/bin:/tools/bin
export LFS LC_ALL LFS_TGT PATH
EOF
  chown lfs:lfs "$profile" "$rc" 2>/dev/null || true
  log_ok "User 'lfs' prepared"
  return 0
}

_copy_resolv_conf() {
  log_info "Copying host /etc/resolv.conf into ${LFS_ROOT}/etc/resolv.conf"
  mkdir -p "${LFS_ROOT}/etc" 2>/dev/null || true
  if [ -f /etc/resolv.conf ]; then
    cp -a /etc/resolv.conf "${LFS_ROOT}/etc/resolv.conf" || { log_warn "Copy failed, writing fallback"; echo "nameserver 1.1.1.1" > "${LFS_ROOT}/etc/resolv.conf"; }
  else
    echo "nameserver 1.1.1.1" > "${LFS_ROOT}/etc/resolv.conf"
    log_warn "Host /etc/resolv.conf not found; fallback created"
  fi
  return 0
}

_bootstrap_mount_all() {
  log_info "Mounting pseudo-filesystems into ${LFS_ROOT} (sandbox mandatory)"
  # sandbox.sh must exist and provide sandbox_mount/sandbox_exec/sandbox_umount
  if [ ! -f "${SANDBOX_SCRIPT}" ]; then
    log_error "Sandbox script not found at ${SANDBOX_SCRIPT}. Sandbox/chroot is mandatory."
    return 2
  fi
  # shellcheck source=/dev/null
  source "${SANDBOX_SCRIPT}" || { log_error "Failed to source sandbox script"; return 2; }
  if ! declare -F sandbox_mount >/dev/null 2>&1; then
    log_error "sandbox_mount function not available in ${SANDBOX_SCRIPT}; sandbox required"
    return 2
  fi
  sandbox_mount "${LFS_ROOT}" || { log_error "sandbox_mount failed"; return 2; }
  _BOOTSTRAP_MOUNTS_DONE=1
  log_ok "Sandbox mounted"
  return 0
}

_bootstrap_unmount_all() {
  log_info "Unmounting sandbox and pseudo-filesystems"
  if declare -F sandbox_umount >/dev/null 2>&1; then
    sandbox_umount "${LFS_ROOT}" || true
  else
    umount -l "${LFS_ROOT}/dev/pts" 2>/dev/null || true
    umount -l "${LFS_ROOT}/dev" 2>/dev/null || true
    umount -l "${LFS_ROOT}/proc" 2>/dev/null || true
    umount -l "${LFS_ROOT}/sys" 2>/dev/null || true
    umount -l "${LFS_ROOT}/run" 2>/dev/null || true
  fi
  _BOOTSTRAP_MOUNTS_DONE=0
  log_ok "Unmount complete"
  return 0
}

_read_stage_list() {
  local stage_name="$1"
  local list_file="${BOOTSTRAP_STAGES_DIR}/${stage_name}.list"
  if [ ! -f "$list_file" ]; then log_error "Stage list not found: $list_file"; return 2; fi
  mapfile -t PKGS < "$list_file"
  local tmp=()
  for p in "${PKGS[@]}"; do
    p="$(echo "$p" | sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$p" ] && continue
    case "$p" in \#*) continue ;; esac
    tmp+=("$p")
  done
  PKGS=("${tmp[@]}")
  return 0
}

_run_single_pkg() {
  local metafile="$1"; local idx="$2"; local total="$3"
  local name="$(basename "$metafile")"; local pkgname="${name%.ini}"
  local pkgdir_rel="$(dirname "$metafile")"; local logdir="${BOOTSTRAP_LOG_ROOT}/${pkgdir_rel}/${pkgname}"
  local logfile="${logdir}/build.log"
  mkdir -p "$logdir" 2>/dev/null || true

  printf "%s" "(${idx}/${total}) ${pkgname} ... "
  local attempt=0 rc=0
  while [ $attempt -lt $BOOTSTRAP_RETRY ]; do
    attempt=$((attempt+1))
    _atomic_write "${logdir}/.status" "attempt=${attempt}" "start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "${BOOTSTRAP_TIMEOUT_PER_PKG}" -gt 0 ]; then timeout --preserve-status "${BOOTSTRAP_TIMEOUT_PER_PKG}" "${BUILD_SCRIPT}" --build "$metafile" >"${logfile}.tmp" 2>&1 || rc=$?; else "${BUILD_SCRIPT}" --build "$metafile" >"${logfile}.tmp" 2>&1 || rc=$?; fi
    mv -f "${logfile}.tmp" "$logfile" 2>/dev/null || true
    if [ "${rc:-0}" -eq 0 ]; then
      printf "%b\n" "${_color_ok}OK${_color_reset}"
      _atomic_write "${logdir}/.status" "result=ok" "end=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      return 0
    else
      printf "%b\n" "${_color_err}FAILED${_color_reset}"
      log_error "Package ${pkgname} failed (attempt ${attempt}) - log: ${logfile}"
      log_info "Showing last 50 lines of log:"
      tail -n 50 "${logfile}" | sed 's/^/    /'
      if [ $attempt -lt $BOOTSTRAP_RETRY ]; then
        log_info "Retrying ${pkgname} (next attempt $((attempt+1))/${BOOTSTRAP_RETRY})..."
        _sleep_ms 500
        continue
      fi
      _atomic_write "${logdir}/.status" "result=fail" "end=$(date -u +%Y-%m-%dT%H:%M:%SZ)" "rc=${rc}"
      if [ "${BOOTSTRAP_STRICT}" -eq 1 ]; then
        log_error "Aborting bootstrap due to failure of ${pkgname}"
        return $rc
      else
        log_warn "Continuing despite failure of ${pkgname}"
        return $rc
      fi
    fi
  done
  return $rc
}

_build_stage() {
  local stage_name="$1"
  _read_stage_list "$stage_name" || return 2
  local total="${#PKGS[@]}"
  log_info "Stage ${stage_name}: ${total} packages"
  local i=0
  for meta in "${PKGS[@]}"; do
    i=$((i+1))
    local name="$(basename "$meta")"; local pkgname="${name%.ini}"; local logdir="${BOOTSTRAP_LOG_ROOT}/$(dirname "$meta")/${pkgname}"
    if [ "${BOOTSTRAP_RESUME}" -eq 1 ] && [ -f "${logdir}/.status" ] && grep -q '^result=ok' "${logdir}/.status" 2>/dev/null; then
      log_info "Skipping ${pkgname} (already built)"
      continue
    fi
    _run_single_pkg "$meta" "$i" "$total" || {
      if [ "${BOOTSTRAP_STRICT}" -eq 1 ]; then return 1; else continue; fi
    }
  done
  log_ok "Stage ${stage_name} finished"
  return 0
}

_test_stage1_toolchain() {
  log_info "Quick toolchain test inside sandbox"
  if ! declare -F sandbox_exec >/dev/null 2>&1; then
    log_error "sandbox_exec missing; cannot run toolchain tests"
    return 2
  fi
  sandbox_exec "${LFS_ROOT}" "bash -lc 'echo \"int main(){}\" > /tmp/dummy.c && gcc /tmp/dummy.c -o /tmp/dummy && /tmp/dummy >/dev/null 2>&1 && echo OK'" >/dev/null 2>&1 || {
    log_error "Toolchain test failed inside sandbox"
    return 1
  }
  log_ok "Toolchain responded inside sandbox"
  return 0
}

_package_stage_rootfs() {
  local stage_name="$1"
  local outdir="${BOOTSTRAP_CACHE_DIR}"
  mkdir -p "$outdir" 2>/dev/null || true
  local ts; ts=$(date +%Y%m%d%H%M%S)
  local out="${outdir}/${stage_name}-rootfs-${ts}.tar.zst"
  log_info "Creating rootfs archive: ${out}"
  if ! command -v zstd >/dev/null 2>&1; then log_error "zstd required to create tar.zst archives"; return 2; fi
  tar -C "${LFS_ROOT}" -cf - . | zstd -T0 -o "${out}" || { log_error "Failed to package rootfs"; return 1; }
  _atomic_write "${out}.sha256" "$(_hash_file "${out}")"
  log_ok "Rootfs packaged: ${out}"
  return 0
}

_bootstrap_main() {
  local stage="${1:-stage1}"
  case "$stage" in 1|stage1) stage="stage1" ;; 2|stage2) stage="stage2" ;; 3|stage3) stage="stage3" ;; all) stage="all" ;; *) log_error "Unknown stage: $stage"; return 2 ;; esac
  _find_core_scripts
  _check_root || return 2
  _check_space || return 3
  _prepare_lfs_layout
  _create_lfs_user
  _copy_resolv_conf
  _bootstrap_mount_all

  if [ "$stage" = "all" ]; then
    for s in stage1 stage2 stage3; do
      _read_stage_list "$s" || { log_error "Missing list for $s"; return 2; }
      _build_stage "$s" || { log_error "Stage $s failed"; return 1; }
      if [ "$s" = "stage1" ]; then _test_stage1_toolchain || log_warn "Toolchain test failed"; fi
      _package_stage_rootfs "$s" || log_warn "Packaging failed for $s"
    done
    return 0
  fi

  _read_stage_list "$stage" || return 2
  _build_stage "$stage" || { log_error "Build failed for $stage"; return 1; }
  if [ "$stage" = "stage1" ]; then _test_stage1_toolchain || log_warn "Toolchain test failed"; fi
  _package_stage_rootfs "$stage" || log_warn "Packaging failed"
  log_ok "Bootstrap ${stage} completed"
  return 0
}

_bootstrap_usage() {
  cat <<'EOF'
Usage: bootstrap.sh [options] --stage <stage1|stage2|stage3|all>
Options:
  --stage <stage>    Which stage to build (default stage1)
  --no-strict        Continue on package failures
  --retry N          Number of retries per package (default 3)
  --quiet            Reduce console noise
  --keep-logs 0|1    Keep or remove logs after success
  --dry-run          Prepare layout and show package counts
  --help
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  stage_arg="stage1"; dry_run=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) stage_arg="$2"; shift 2 ;;
      --no-strict) BOOTSTRAP_STRICT=0; shift ;;
      --retry) BOOTSTRAP_RETRY="$2"; shift 2 ;;
      --quiet) BOOTSTRAP_QUIET=1; shift ;;
      --keep-logs) BOOTSTRAP_KEEP_LOGS="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --help) _bootstrap_usage; exit 0 ;;
      *) echo "Unknown arg: $1"; _bootstrap_usage; exit 2 ;;
    esac
  done

  if [ "$dry_run" -eq 1 ]; then
    _prepare_lfs_layout
    echo "Dry-run: Stage lists under ${BOOTSTRAP_STAGES_DIR}:"
    for f in "${BOOTSTRAP_STAGES_DIR}"/*.list; do [ -f "$f" ] || continue; echo " - $f: $(grep -vE '^\s*#' "$f" | sed '/^\s*$/d' | wc -l) packages"; done
    exit 0
  fi

  _bootstrap_main "$stage_arg"
  exit $?
fi

# End of bootstrap.sh
