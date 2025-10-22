#!/usr/bin/env bash
# bootstrap.sh - Automated LFS bootstrap & stage builder
# Version: 1.0
# Purpose: initialize /mnt/lfs, create environment (chapter 4), build stages (1/2/3)
set -Eeuo pipefail
IFS=$'\n\t'

# -------- Configuration (override via env) --------
: "${LFS_ROOT:=/mnt/lfs}"
: "${STAGE:=stage1}"
: "${METAFILE_DIR:=${LFS_ROOT}/usr/src}"
: "${LOG_DIR:=${LFS_ROOT}/logs}"
: "${STATE_DIR:=/var/lib/lfs/bootstrap}"
: "${LOCKFILE:=/var/lock/lfs_bootstrap.lock}"
: "${WORKERS:=1}"
: "${SILENT_ERRORS:=false}"
: "${ABORT_ON_ERROR:=true}"
: "${CONTINUE_ON_ERROR:=false}"
: "${RETRY:=2}"
: "${BUILD_SCRIPT_HOST:=/usr/bin/build.sh}"
: "${DEPS_SCRIPT_HOST:=/usr/bin/deps.sh}"
: "${SANDBOX_SCRIPT_HOST:=/usr/bin/sandbox.sh}"
: "${DOWNLOAD_SCRIPT_HOST:=/usr/bin/download.sh}"
: "${CREATE_INSTALL_HOST:=/usr/bin/create_install.sh}"
: "${UNINSTALL_SCRIPT_HOST:=/usr/bin/uninstall.sh}"
: "${METAFILE_SCRIPT_HOST:=/usr/bin/metafile.sh}"
export LFS_ROOT METAFILE_DIR LOG_DIR STATE_DIR LOCKFILE WORKERS SILENT_ERRORS ABORT_ON_ERROR CONTINUE_ON_ERROR RETRY
export BUILD_SCRIPT_HOST DEPS_SCRIPT_HOST SANDBOX_SCRIPT_HOST DOWNLOAD_SCRIPT_HOST CREATE_INSTALL_HOST UNINSTALL_SCRIPT_HOST METAFILE_SCRIPT_HOST

# try to source log.sh if present
LOG_API=false
if [ -f /usr/bin/logs.sh ]; then
  # shellcheck source=/dev/null
  source /usr/bin/logs.sh || true
  LOG_API=true
fi

_bs_log(){ if [ "$LOG_API" = true ] && type log_info >/dev/null 2>&1; then log_info "$@"; else printf "[BOOT][INFO] %s\n" "$@"; fi }
_bs_warn(){ if [ "$LOG_API" = true ] && type log_warn >/dev/null 2>&1; then log_warn "$@"; else printf "[BOOT][WARN] %s\n" "$@"; fi }
_bs_error(){ if [ "$LOG_API" = true ] && type log_error >/dev/null 2>&1; then log_error "$@"; else printf "[BOOT][ERROR] %s\n" "$@" >&2; fi; if [ "${SILENT_ERRORS}" = "true" ]; then return 1; fi; if [ "${ABORT_ON_ERROR}" = "true" ] && [ "${CONTINUE_ON_ERROR}" != "true" ]; then exit 1; fi; return 1; }

_safe_mkdir(){ mkdir -p "$@" 2>/dev/null || _bs_error "failed to mkdir $*"; }
_check_space_mb(){
  local dir="$1"; local need="${2:-0}"
  local avail
  avail=$(df -Pm "$dir" | awk 'NR==2{print $4}' 2>/dev/null || echo 0)
  if [ "$avail" -lt "$need" ]; then _bs_error "Not enough space on $dir: need ${need}MB, avail ${avail}MB"; return 1; fi
  return 0
}

_acquire_lock(){
  exec 200>"$LOCKFILE"
  flock -n 200 || { _bs_error "Another bootstrap is running (lockfile: $LOCKFILE)"; return 1; }
  printf "%s\n" "$$" >&200
  return 0
}
_release_lock(){ exec 200>&- || true; }

_state_file="$STATE_DIR/state.json"
_safe_mkdir "$LOG_DIR" "$STATE_DIR" "$LFS_ROOT"

# helper: locate scripts either on host or in LFS_ROOT/usr/bin
_find_script(){
  local name="$1"
  if [ -x "/usr/bin/$name" ]; then echo "/usr/bin/$name"; return 0; fi
  if [ -x "${LFS_ROOT}/usr/bin/$name" ]; then echo "${LFS_ROOT}/usr/bin/$name"; return 0; fi
  echo ""
  return 1
}

# locate metafiles for a stage
_find_metafiles_for_stage(){
  local stage="$1"
  local dir1="${LFS_ROOT}/usr/src/${stage}"
  local dir2="${METAFILE_DIR}/${stage}"
  local dir3="/usr/src/${stage}"
  local out=()
  for d in "$dir1" "$dir2" "$dir3"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.ini; do [ -f "$f" ] && out+=("$f"); done
    if [ "${#out[@]}" -gt 0 ]; then printf "%s\n" "${out[@]}"; return 0; fi
  done
  return 1
}

# read package name from metafile (simple)
_metafile_pkgname(){
  awk -F= '/^name=|^pkg=/{print $2; exit}' "$1" 2>/dev/null | tr -d ' '
}

# build queue: resolve with deps.sh if available; otherwise use file order
_resolve_build_queue(){
  local stage="$1"
  local tmp
  tmp=$(_find_metafiles_for_stage "$stage") || return 1
  local files=( $tmp )
  local names=()
  # try deps.sh resolution
  local deps_script
  deps_script=$(_find_script "deps.sh" || true)
  if [ -n "$deps_script" ] && type deps_resolve >/dev/null 2>&1; then
    # use metafile.sh if available to get package names
    for mf in "${files[@]}"; do
      names+=( "$(_metafile_pkgname "$mf")" )
    done
    # call deps_resolve for each; expect it to output ordered list (one per line)
    local resolved=()
    for n in "${names[@]}"; do
      if deps_resolve "$n" >/dev/null 2>&1; then
        # collect (deps_resolve should print list)
        while IFS= read -r l; do resolved+=( "$l" ); done < <(deps_resolve "$n")
      else
        resolved+=( "$n" )
      fi
    done
    # unique preserve order
    local seen=()
    local ordered=()
    for r in "${resolved[@]}"; do
      if [ -z "${seen[$r]:-}" ]; then ordered+=( "$r" ); seen[$r]=1; fi
    done
    printf "%s\n" "${ordered[@]}"
    return 0
  else
    # fallback: return names in files order
    for mf in "${files[@]}"; do names+=( "$(_metafile_pkgname "$mf")" ); done
    printf "%s\n" "${names[@]}"
    return 0
  fi
}

# progress UI: single-line update
_progress_line(){
  local idx="$1"; local total="$2"; local pkg="$3"; local logpath="$4"
  # cpu load and mem
  local load; load=$(awk '{printf "%.2f", $1}' /proc/loadavg 2>/dev/null || echo "0.00")
  local cores; cores=$(nproc 2>/dev/null || echo 1)
  # cpu usage approximate via top: use /proc/stat delta (simple approach)
  local mem_total mem_available mem_used
  mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  mem_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "$mem_total" -gt 0 ]; then
    mem_used=$((mem_total - mem_available))
    # human
    mem_h=$(printf "%.1fMB" "$(echo "$mem_used/1024" | bc -l)")
  else
    mem_h="0MB"
  fi
  printf "\r\033[1;36m(%d/%d)\033[0m \033[1;33m%s\033[0m — log: %s — cores: %s load: %s mem_used: %s" \
    "$idx" "$total" "$pkg" "$logpath" "$cores" "$load" "$mem_h"
}

# prepare environment files per LFS ch4 inside $LFS_ROOT
_write_lfs_env_files(){
  _bs_log "Writing LFS environment files under $LFS_ROOT/etc"
  _safe_mkdir "${LFS_ROOT}/etc" "${LFS_ROOT}/etc/profile.d"
  cat > "${LFS_ROOT}/etc/profile" <<'EOF'
# /etc/profile -- created by bootstrap.sh
export LFS="${LFS_ROOT:-/mnt/lfs}"
export LC_ALL=POSIX
export PATH=/usr/bin:/bin
# user may extend PATH later
EOF
  cat > "${LFS_ROOT}/etc/inputrc" <<'EOF'
# Readline settings
set editing-mode vi
set show-all-if-ambiguous on
EOF
  # minimal shells
  cat > "${LFS_ROOT}/etc/shells" <<'EOF'
/bin/sh
/bin/bash
EOF
  # passwd/group entries for root and lfs (lfs user only in rootfs)
  _safe_mkdir "${LFS_ROOT}/etc"
  if ! grep -q '^lfs:' "${LFS_ROOT}/etc/passwd" 2>/dev/null || true; then
    # create minimal passwd and group if missing
    if [ ! -f "${LFS_ROOT}/etc/passwd" ]; then
      cat > "${LFS_ROOT}/etc/passwd" <<EOF
root:x:0:0:root:/root:/bin/bash
lfs:x:1000:1000:LFS User:/home/lfs:/bin/bash
EOF
    fi
    if [ ! -f "${LFS_ROOT}/etc/group" ]; then
      cat > "${LFS_ROOT}/etc/group" <<EOF
root:x:0:
lfs:x:1000:
EOF
    fi
  fi
  _bs_log "Environment files written"
}

# create base directories & perms
_bs_init(){
  _bs_log "Initializing LFS root: $LFS_ROOT"
  _safe_mkdir "$LFS_ROOT" "$LFS_ROOT"/{bin,lib,lib64,usr,usr/bin,usr/src,dev,proc,sys,tmp,home,build,logs}
  chmod 1777 "${LFS_ROOT}/tmp" || true
  _safe_mkdir "$LOG_DIR"
  _write_lfs_env_files
  _bs_log "Initialization complete"
}

# check required host tools
_check_host_requirements(){
  local need=(bash coreutils sed awk grep make gcc tar xz gzip bzip2 patch python3)
  local missing=()
  for cmd in "${need[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then missing+=("$cmd"); fi
  done
  if [ ${#missing[@]} -ne 0 ]; then
    _bs_warn "Missing host tools: ${missing[*]}"
    return 1
  fi
  return 0
}

# build a single package by name (uses build.sh if available)
_bs_build_pkg(){
  local pkg="$1"
  local stage="$2"
  local idx="$3"
  local total="$4"
  local logpath="${LOG_DIR}/${stage}/${pkg}.log"
  _safe_mkdir "$(dirname "$logpath")"
  _bs_log "Starting build for $pkg (stage=$stage)"
  # find metafile path
  local mf=""
  for d in "${LFS_ROOT}/usr/src/${stage}" "${METAFILE_DIR}/${stage}" "/usr/src/${stage}"; do
    if [ -f "$d/${pkg}.ini" ]; then mf="$d/${pkg}.ini"; break; fi
  done
  if [ -z "$mf" ]; then
    _bs_warn "metafile for $pkg not found; skipping"
    echo "{\"pkg\":\"$pkg\",\"status\":\"SKIPPED\",\"reason\":\"metafile not found\"}" > "${LOG_DIR}/${stage}/${pkg}.json"
    return 0
  fi
  # ensure destdir exists
  local destdir="${LFS_ROOT}/build/${pkg}"
  _safe_mkdir "$destdir"
  # choose build script
  local build_sh
  build_sh=$(_find_script "build.sh" || true)
  if [ -n "$build_sh" ] && [ -x "$build_sh" ]; then
    # call build.sh run <pkg> or build <pkg>
    _progress_line "$idx" "$total" "$pkg" "$logpath"
    if "$build_sh" run "$pkg" >> "$logpath" 2>&1; then
      _bs_log ""
      _bs_log "SUCCESS: $pkg"
      echo "{\"pkg\":\"$pkg\",\"status\":\"SUCCESS\"}" > "${LOG_DIR}/${stage}/${pkg}.json"
      return 0
    else
      _bs_error "Build failed for $pkg; see log: $logpath"
      echo "{\"pkg\":\"$pkg\",\"status\":\"FAILED\",\"log\":\"$logpath\"}" > "${LOG_DIR}/${stage}/${pkg}.json"
      return 2
    fi
  else
    # fallback: try to run generic commands from metafile
    local install_cmd
    install_cmd=$(awk -F= '/^install=/{print substr($0,index($0,$2))}' "$mf" 2>/dev/null || echo "")
    local build_cmd
    build_cmd=$(awk -F= '/^build=/{print substr($0,index($0,$2))}' "$mf" 2>/dev/null || echo "make")
    local prepare_cmd
    prepare_cmd=$(awk -F= '/^prepare=/{print substr($0,index($0,$2))}' "$mf" 2>/dev/null || echo "")
    _progress_line "$idx" "$total" "$pkg" "$logpath"
    # basic naive build: extract source to workdir, run prepare, build, install to DESTDIR
    local srcurl
    srcurl=$(awk -F= '/^url=|^sources=/{print substr($0,index($0,$2))}' "$mf" 2>/dev/null | head -n1 || echo "")
    if [ -z "$srcurl" ]; then _bs_warn "No source URL in metafile for $pkg"; return 1; fi
    # download to cache
    local cache_dir="${LFS_ROOT}/sources"
    _safe_mkdir "$cache_dir"
    local tarball="$cache_dir/$(basename "$srcurl")"
    if [ ! -f "$tarball" ]; then
      if [ -x "$DOWNLOAD_SCRIPT_HOST" ]; then
        "$DOWNLOAD_SCRIPT_HOST" fetch "$srcurl" "$tarball" >> "$logpath" 2>&1 || _bs_warn "download.sh failed"
      else
        # fallback to curl/wget
        if command -v curl >/dev/null 2>&1; then curl -fsSL "$srcurl" -o "$tarball" >> "$logpath" 2>&1 || true; fi
        if [ ! -f "$tarball" ] && command -v wget >/dev/null 2>&1; then wget -q -O "$tarball" "$srcurl" >> "$logpath" 2>&1 || true; fi
      fi
    fi
    # extract
    if [ -f "$tarball" ]; then
      mkdir -p "$destdir/src"
      tar -xf "$tarball" -C "$destdir/src" >> "$logpath" 2>&1 || _bs_warn "tar failed"
      # attempt to find top dir
      local topdir
      topdir=$(find "$destdir/src" -maxdepth 1 -mindepth 1 -type d | head -n1)
      if [ -n "$prepare_cmd" ]; then (cd "$topdir" && eval "$prepare_cmd") >> "$logpath" 2>&1 || _bs_warn "prepare failed"; fi
      (cd "$topdir" && eval "$build_cmd") >> "$logpath" 2>&1 || { _bs_error "build failed for $pkg; see $logpath"; return 2; }
      # run install to DESTDIR
      local dest_install="${LFS_ROOT}/build/${pkg}/destdir"
      mkdir -p "$dest_install"
      (cd "$topdir" && eval "$install_cmd" || eval "make install DESTDIR=${dest_install} PREFIX=/usr") >> "$logpath" 2>&1 || { _bs_error "install failed for $pkg; see $logpath"; return 2; }
      _bs_log "SUCCESS (fallback build) $pkg"
      echo "{\"pkg\":\"$pkg\",\"status\":\"SUCCESS\"}" > "${LOG_DIR}/${stage}/${pkg}.json"
      return 0
    else
      _bs_error "Tarball not found for $pkg ($tarball)"
      return 3
    fi
  fi
}

# validate rootfs minimal smoke tests
_bs_validate_rootfs(){
  local stage="$1"
  _bs_log "Validating rootfs for $stage"
  # check that basic shell exists
  if [ ! -x "${LFS_ROOT}/bin/sh" ] && [ ! -x "${LFS_ROOT}/bin/bash" ]; then
    _bs_warn "No /bin/sh or /bin/bash in rootfs"
    return 1
  fi
  # try a chroot echo
  if command -v chroot >/dev/null 2>&1; then
    chroot "$LFS_ROOT" /bin/sh -c 'echo _LFS_TEST_' >/dev/null 2>&1 || _bs_warn "chroot test failed"
  fi
  return 0
}

# driver to build stage
_bs_build_stage(){
  local stage="$1"
  _bs_log "Building stage: $stage"
  local queue
  IFS=$'\n' read -r -d '' -a queue < <(_resolve_build_queue "$stage" && printf '\0') || queue=()
  local total=${#queue[@]}
  if [ "$total" -eq 0 ]; then _bs_warn "No packages found for $stage"; return 0; fi
  _safe_mkdir "${LOG_DIR}/${stage}"
  local idx=0
  for pkg in "${queue[@]}"; do
    idx=$((idx+1))
    local logpath="${LOG_DIR}/${stage}/${pkg}.log"
    _progress_line "$idx" "$total" "$pkg" "$logpath"
    # attempt build with retries
    local attempt=0
    local rc=0
    while [ $attempt -le $RETRY ]; do
      attempt=$((attempt+1))
      if _bs_build_pkg "$pkg" "$stage" "$idx" "$total"; then rc=0; break; else rc=$?; fi
      _bs_warn "Attempt $attempt failed for $pkg (rc=$rc)"
      if [ $attempt -le $RETRY ]; then sleep 2; fi
    done
    if [ "$rc" -ne 0 ]; then
      _bs_error "Package $pkg failed after $attempt attempts. See log: ${LOG_DIR}/${stage}/${pkg}.log"
      if [ "${CONTINUE_ON_ERROR}" = "true" ]; then
        _bs_warn "Continuing despite error due to CONTINUE_ON_ERROR"
        continue
      else
        return $rc
      fi
    fi
    printf "\n"  # newline after status line
  done
  _bs_log "Stage $stage build complete"
  return 0
}

# entrypoint: create stage (init then build then validate then snapshot)
_bs_create_stage(){
  local stage="$1"
  _bs_log "Create stage requested: $stage"
  _check_space_mb "$LFS_ROOT" 1024 || _bs_warn "Low disk space"
  # ensure env
  _bs_init
  _bs_setup_scripts_search() { :; }  # placeholder
  # check host tools
  _check_host_requirements || _bs_warn "Host missing tools; some builds may fail"
  # build
  if ! _bs_build_stage "$stage"; then
    _bs_error "Stage $stage build failed"
    return 2
  fi
  # validate
  if ! _bs_validate_rootfs "$stage"; then
    _bs_warn "Validation reported issues for $stage"
  fi
  # create snapshot via create_install if available
  local create_sh
  create_sh=$(_find_script "create_install.sh" || true)
  if [ -n "$create_sh" ]; then
    _bs_log "Creating snapshot tarball of rootfs"
    # use create_install.sh package of entire rootfs (use package name lfs-stage1-<ts>)
    local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
    "$create_sh" package "lfs-${stage}-${ts}" "${LFS_ROOT}" >> "${LOG_DIR}/${stage}/snapshot.log" 2>&1 || _bs_warn "snapshot creation failed"
  fi
  _bs_log "Stage $stage creation finished"
  return 0
}

# main CLI dispatcher
_usage(){
  cat <<EOF
bootstrap.sh - LFS bootstrap helper

Usage:
  bootstrap.sh --ini
  bootstrap.sh --create stage1|stage2|stage3
  bootstrap.sh --check-deps
  bootstrap.sh --status
  bootstrap.sh --help

Flags:
  --workers N
  --silent
  --continue-on-error
  --force
  --metafile-dir PATH
EOF
}

if [ "${BASH_SOURCE[0]}" == "$0" ]; then
  case "${1:-}" in
    --ini) _acquire_lock || exit 1; _bs_init; _release_lock; exit 0;;
    --create) shift; stage="${1:-stage1}"; _acquire_lock || exit 1; _bs_create_stage "$stage"; _release_lock; exit $?;;
    --check-deps) _check_host_requirements; exit $?;;
    --status) cat "${STATE_DIR}/state.json" 2>/dev/null || echo "{}"; exit 0;;
    --help|-h|help) _usage; exit 0;;
    *) _usage; exit 2;;
  esac
fi

# export functions
export -f _bs_init _bs_create_stage _bs_build_stage _bs_build_pkg _bs_validate_rootfs _find_metafiles_for_stage
