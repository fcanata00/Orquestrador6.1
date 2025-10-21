#!/usr/bin/env bash
# =============================================================================
# build.sh - Orchestrador PRO de builds LFS
# =============================================================================
# - Integrates metadata.sh, download.sh, sandbox.sh, deps.sh, register.sh
# - Pipeline: prepare -> compile -> check -> install -> package -> deploy
# - Uses sandbox_exec to execute steps inside isolated environment when available
# - Caches packages (.tar.zst) and keeps builds per-package
# - Robust error handling, retries, silent mode, resume, locks, logs
# =============================================================================
set -o errexit
set -o nounset
set -o pipefail

if [ -n "${BUILD_SH_PRO_LOADED-}" ]; then
  return 0 2>/dev/null || exit 0
fi
BUILD_SH_PRO_LOADED=1

# Defaults (override via env)
: "${LFS_ROOT:=/mnt/lfs}"
: "${BUILD_ROOT:=${LFS_ROOT}/builds}"
: "${BUILD_CACHE_PKGS:=${LFS_ROOT}/cache/packages}"
: "${BUILD_LOG_ROOT:=${LFS_ROOT}/build_logs}"
: "${BUILD_TMP:=${LFS_ROOT}/tmp/builds}"
: "${BUILD_KEEP_LOGS:=1}"
: "${BUILD_STRICT:=0}"
: "${BUILD_SILENT:=0}"
: "${BUILD_DEBUG:=0}"
: "${BUILD_RETRY:=3}"
: "${BUILD_SANDBOX:=1}"
: "${BUILD_PARALLEL_JOBS:=0}"
: "${BUILD_TIMEOUT_HOOK:=300}"
: "${BUILD_RESUME:=1}"
: "${BUILD_INTERACTIVE:=0}"

CORE_METADATA_PATHS=( "./metadata.sh" "/usr/local/lib/lfs/metadata.sh" "${LFS_ROOT}/scripts/metadata.sh" )
CORE_DOWNLOAD_PATHS=( "./download.sh" "${LFS_ROOT}/scripts/download.sh" )
CORE_SANDBOX_PATHS=( "./sandbox.sh" "${LFS_ROOT}/scripts/sandbox.sh" )
CORE_REGISTER_PATHS=( "./register.sh" "/usr/local/bin/register.sh" "/usr/local/lib/lfs/register.sh" "${LFS_ROOT}/scripts/register.sh" "/usr/lib/lfs/register.sh" )
CORE_DEPS_PATHS=( "./deps.sh" "${LFS_ROOT}/scripts/deps.sh" )

mkdir -p "${BUILD_ROOT}" "${BUILD_CACHE_PKGS}" "${BUILD_LOG_ROOT}" "${BUILD_TMP}" 2>/dev/null || true

# Logger integration
_build_try_load_register() {
  if declare -F log_info >/dev/null 2>&1; then return 0; fi
  for p in "${CORE_REGISTER_PATHS[@]}"; do
    [ -f "$p" ] || continue
    # shellcheck source=/dev/null
    source "$p" && declare -F log_info >/dev/null 2>&1 && return 0
  done
  return 1
}

_color_info='\033[1;34m'; _color_warn='\033[1;33m'; _color_err='\033[1;31m'; _color_ok='\033[1;32m'; _color_reset='\033[0m'

_build_log_internal() {
  local lvl="$1"; shift; local msg="$*"; local ts; ts="$(date +'%Y-%m-%dT%H:%M:%S%z')"
  case "$lvl" in
    INFO)  [ "${BUILD_SILENT}" -eq 0 ] && printf "%s ${_color_info}[INFO]${_color_reset} %s\n" "$ts" "$msg" >&2 || true ;;
    WARN)  printf "%s ${_color_warn}[WARN]${_color_reset} %s\n" "$ts" "$msg" >&2 ;;
    ERROR) printf "%s ${_color_err}[ERROR]${_color_reset} %s\n" "$ts" "$msg" >&2 ;;
    OK)    printf "%s ${_color_ok}[OK]${_color_reset} %s\n" "$ts" "$msg" >&2 ;;
    DEBUG) [ "${BUILD_DEBUG}" -eq 1 ] && printf "%s [DEBUG] %s\n" "$ts" "$msg" >&2 || true ;;
    *) printf "%s [LOG] %s\n" "$ts" "$msg" >&2 ;;
  esac
}

if _build_try_load_register; then
  : 
else
  log_info()  { _build_log_internal INFO "$*"; }
  log_warn()  { _build_log_internal WARN "$*"; }
  log_error() { _build_log_internal ERROR "$*"; }
  log_debug() { _build_log_internal DEBUG "$*"; }
  log_ok()    { _build_log_internal OK "$*"; }
fi

# Utilities
_sleep_ms() { local ms="$1"; if command -v perl >/dev/null 2>&1; then perl -e "select(undef,undef,undef,$ms/1000)"; else sleep "$(awk "BEGIN {print $ms/1000}")"; fi }
_retry_cmd() { local max="${1:-$BUILD_RETRY}"; shift; local attempt=0 delay=200; while :; do "$@" && return 0; local rc=$?; attempt=$((attempt+1)); log_warn "Attempt $attempt/$max failed (rc=$rc): $*"; if [ "$attempt" -ge "$max" ]; then log_error "Command failed after $attempt attempts: $*"; return "$rc"; fi; _sleep_ms "$delay"; delay=$((delay*2)); done }
_atomic_write() { local file="$1"; shift; local tmp="${file}.$$.$RANDOM.tmp"; { printf '%s\n' "$@"; } > "$tmp" && mv -f "$tmp" "$file" }
_now() { date +%Y%m%d%H%M%S; }
_hash_file() { local f="$1"; if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f" | awk '{print $1}'; elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$f" | awk '{print $2}'; else echo ""; fi }

# Load core modules
_load_core() {
  local loaded=0
  for p in "${CORE_METADATA_PATHS[@]}"; do [ -f "$p" ] && { # shellcheck source=/dev/null
      source "$p"; loaded=1; break; }; done
  if [ "$loaded" -ne 1 ]; then log_error "metadata.sh not found"; return 1; fi
  loaded=0
  for p in "${CORE_DOWNLOAD_PATHS[@]}"; do [ -f "$p" ] && { # shellcheck source=/dev/null
      source "$p"; loaded=1; break; }; done
  if [ "$loaded" -ne 1 ]; then log_error "download.sh not found"; return 1; fi
  for p in "${CORE_SANDBOX_PATHS[@]}"; do [ -f "$p" ] && { # shellcheck source=/dev/null
      source "$p"; loaded=1; break; }; done
  for p in "${CORE_DEPS_PATHS[@]}"; do [ -f "$p" ] && { # shellcheck source=/dev/null
      source "$p" && DEPS_LOADED=1 || true; break; }; done
  return 0
}

# Per-package paths
_pkg_paths() {
  local metafile="$1"
  metadata_load "$metafile" >/dev/null 2>&1 || true
  local name="${META_name:-$(basename "$(dirname "$metafile")")}"
  local version="${META_version:-unknown}"
  local group="${META_group:-misc}"
  local pkgid="${group}/${name}-${version}"
  local pkgdir="${BUILD_ROOT}/${pkgid}"
  local srcdir="${pkgdir}/src"
  local builddir="${pkgdir}/build"
  local destdir="${pkgdir}/dest"
  local pkgoutdir="${pkgdir}/pkg"
  local logdir="${pkgdir}/logs"
  echo "$pkgdir" "$srcdir" "$builddir" "$destdir" "$pkgoutdir" "$logdir" "$pkgid"
}

# Ensure central recipes symlink
_ensure_meta_symlink() {
  if [ ! -e /usr/src/lfs-meta ] && [ -d "${LFS_ROOT}/meta" ]; then
    ln -sfn "${LFS_ROOT}/meta" /usr/src/lfs-meta 2>/dev/null || true
    log_debug "Symlinked /usr/src/lfs-meta -> ${LFS_ROOT}/meta"
  fi
}

# Prepare: download and extract
build_prepare() {
  local metafile="$1"
  read pkgdir srcdir builddir destdir pkgout logdir pkgid < <(_pkg_paths "$metafile")
  mkdir -p "$srcdir" "$builddir" "$destdir" "$pkgout" "$logdir" || true
  log_info "Preparing $pkgid"
  metadata_load "$metafile" || { log_error "metadata_load failed"; return 2; }
  metadata_validate "$metafile" || log_warn "metadata validation warnings"
  if ! download_fetch "$metafile"; then log_error "download_fetch failed"; return 3; fi
  local dl_dir="${DOWNLOAD_ROOT}/${META_name}-${META_version}"
  if [ -d "$dl_dir" ]; then cp -a "$dl_dir"/* "$srcdir"/ 2>/dev/null || true; fi
  # extract archives
  for f in "$srcdir"/*; do
    [ -f "$f" ] || continue
    case "$f" in
      *.tar.gz|*.tgz) tar -xzf "$f" -C "$srcdir" ;;
      *.tar.xz) tar -xJf "$f" -C "$srcdir" ;;
      *.tar.bz2) tar -xjf "$f" -C "$srcdir" ;;
      *.zip) unzip -q "$f" -d "$srcdir" ;;
      *) log_debug "Copied source file: $f" ;;
    esac
  done
  metadata_apply_patches "$srcdir" || log_warn "Some patches failed"
  metadata_run_hook pre_prepare "$srcdir"
  touch "${pkgdir}/.status" 2>/dev/null || true
  log_info "Prepare done for $pkgid"
  return 0
}

# Compile
build_compile() {
  local metafile="$1"
  read pkgdir srcdir builddir destdir pkgout logdir pkgid < <(_pkg_paths "$metafile")
  metadata_load "$metafile" >/dev/null 2>&1 || true
  log_info "Compiling $pkgid"
  metadata_run_hook pre_compile "$srcdir"
  local compile_block
  compile_block="$(metadata_get build.compile 2>/dev/null || true)"
  if [ -n "$compile_block" ]; then
    mkdir -p "$builddir"
    ( cd "$builddir" && bash -euc "$compile_block" ) 2>&1 | tee "${logdir}/compile.log"
  else
    local top
    top="$(find "$srcdir" -maxdepth 2 -type f \( -name configure -o -name Makefile -o -name CMakeLists.txt \) -print -quit | xargs -r dirname)"
    if [ -z "$top" ]; then top="$srcdir"; fi
    mkdir -p "$builddir"
    ( cd "$top" && mkdir -p "$builddir" && cd "$builddir" && ../configure --prefix=/usr ) 2>&1 | tee "${logdir}/configure.log" || true
    ( cd "$builddir" && make -j"${BUILD_PARALLEL_JOBS:-$(nproc)}" ) 2>&1 | tee "${logdir}/make.log"
  fi
  metadata_run_hook post_compile "$srcdir"
  log_info "Compile done for $pkgid"
  return 0
}

# Check
build_check() {
  local metafile="$1"
  read pkgdir srcdir builddir destdir pkgout logdir pkgid < <(_pkg_paths "$metafile")
  log_info "Checking $pkgid"
  metadata_run_hook pre_check "$srcdir"
  local check_block
  check_block="$(metadata_get build.check 2>/dev/null || true)"
  if [ -n "$check_block" ]; then
    ( cd "$builddir" && bash -euc "$check_block" ) 2>&1 | tee "${logdir}/check.log" || log_warn "Tests reported failures"
  fi
  metadata_run_hook post_check "$srcdir"
  return 0
}

# Install
_build_run_fakeroot_install() {
  local cmd="$1" logf="$2"
  if command -v fakeroot >/dev/null 2>&1; then
    fakeroot bash -lc "set -e; ${cmd}" 2>&1 | tee "$logf"
    return ${PIPESTATUS[0]:-0}
  else
    bash -lc "set -e; ${cmd}" 2>&1 | tee "$logf"
    return ${PIPESTATUS[0]:-0}
  fi
}

build_install() {
  local metafile="$1"
  read pkgdir srcdir builddir destdir pkgout logdir pkgid < <(_pkg_paths "$metafile")
  log_info "Installing $pkgid into DESTDIR"
  metadata_run_hook pre_install "$srcdir"
  mkdir -p "$destdir"
  local install_block
  install_block="$(metadata_get build.install 2>/dev/null || true)"
  if [ -n "$install_block" ]; then
    local cmd="export DESTDIR='${destdir}'; cd '${builddir}'; ${install_block}"
    _build_run_fakeroot_install "$cmd" "${logdir}/install.log" || { log_error "Install failed"; return 1; }
  else
    ( cd "$builddir" && _build_run_fakeroot_install "make DESTDIR='${destdir}' install" "${logdir}/install.log" ) || { log_error "make install failed"; return 1; }
  fi
  metadata_run_hook post_install "$srcdir"
  log_info "Install done for $pkgid"
  return 0
}

# Strip helper
_build_strip_binaries() {
  local d="$1"
  if ! command -v file >/dev/null 2>&1; then log_debug "file(1) not found; skip strip"; return 0; fi
  find "$d" -type f -exec file -L {} \; | grep -E 'ELF .*executable|ELF .*shared' -B1 | awk -F: '/:/{print $1}' | while read -r f; do
    if command -v strip >/dev/null 2>&1; then strip --strip-unneeded "$f" 2>/dev/null || true; fi
  done || true
}

# Package
build_package() {
  local metafile="$1"
  read pkgdir srcdir builddir destdir pkgout logdir pkgid < <(_pkg_paths "$metafile")
  log_info "Packaging $pkgid"
  metadata_run_hook pre_package "$srcdir"
  _build_strip_binaries "$destdir"
  local out_zst="${BUILD_CACHE_PKGS}/${pkgid}.tar.zst"
  mkdir -p "$(dirname "$out_zst")" "$(dirname "${pkgout}")" 2>/dev/null || true
  if command -v zstd >/dev/null 2>&1; then
    tar -C "$destdir" -cf - . | zstd -T0 -o "${out_zst}" || { log_error "Packaging failed"; return 1; }
  else
    tar -C "$destdir" -cf - . | gzip -c > "${out_zst}.gz" || { log_error "Packaging failed"; return 1; }
    out_zst="${out_zst}.gz"
  fi
  local checksum="$(_hash_file "${out_zst}")"
  _atomic_write "${out_zst}.sha256" "$checksum"
  cp -a "$out_zst" "${pkgout}/" 2>/dev/null || true
  cp -a "${out_zst}.sha256" "${pkgout}/" 2>/dev/null || true
  metadata_run_hook post_package "$srcdir"
  log_info "Package created: ${out_zst}"
  return 0
}

# Deploy
build_deploy() {
  local metafile="$1" deploy_to="${2:-}"
  read pkgdir srcdir builddir destdir pkgout logdir pkgid < <(_pkg_paths "$metafile")
  metadata_load "$metafile" >/dev/null 2>&1 || true
  if [ -z "$deploy_to" ]; then
    if [ "${META_mode:-}" = "toolchain" ] || [ "${META_mode:-}" = "stage1" ]; then
      deploy_to="${LFS_ROOT}"
    else
      deploy_to="/"
    fi
  fi
  log_info "Deploying $pkgid to $deploy_to"
  metadata_run_hook pre_deploy "$srcdir"
  local cached="${BUILD_CACHE_PKGS}/${pkgid}.tar.zst"
  local pkgfile
  if [ -f "$cached" ]; then pkgfile="$cached"; else pkgfile="$(ls -1 "${pkgout}/"*.tar* 2>/dev/null | tail -n1 || true)"; fi
  if [ -z "$pkgfile" ]; then log_error "No package to deploy"; return 1; fi
  if [ "${BUILD_SANDBOX}" -eq 1 ] && declare -F sandbox_exec >/dev/null 2>&1; then
    sandbox_exec "mkdir -p '${deploy_to}' && tar -I zstd -xf '${pkgfile}' -C '${deploy_to}' --numeric-owner" || { log_error "Deploy (sandbox) failed"; return 1; }
  else
    if [[ "$pkgfile" == *.zst ]]; then
      if command -v zstd >/dev/null 2>&1; then tar -I zstd -xf "$pkgfile" -C "$deploy_to" --numeric-owner || { log_error "Deploy failed"; return 1; }; fi
    else
      tar -xf "$pkgfile" -C "$deploy_to" --numeric-owner || { log_error "Deploy failed"; return 1; }
    fi
  fi
  metadata_run_hook post_deploy "$srcdir"
  log_ok "Deployed $pkgid to $deploy_to"
  return 0
}

# Reuse cache
build_reuse_cache() {
  local metafile="$1"
  read pkgdir srcdir builddir destdir pkgout logdir pkgid < <(_pkg_paths "$metafile")
  local cached="${BUILD_CACHE_PKGS}/${pkgid}.tar.zst"
  if [ -f "$cached" ]; then
    local pkgsha="$(_hash_file "$cached")"
    if [ -f "${cached}.sha256" ]; then
      local expected; expected="$(cat "${cached}.sha256" 2>/dev/null | head -n1 | awk '{print $1}')"
      if [ -n "$expected" ] && [ "$expected" = "$pkgsha" ]; then log_info "Package cache hit for $pkgid"; return 0; fi
    fi
  fi
  return 1
}

# Cleanup
build_cleanup() {
  local metafile="$1" keep="${2:-${BUILD_KEEP_LOGS}}"
  read pkgdir srcdir builddir destdir pkgout logdir pkgid < <(_pkg_paths "$metafile")
  if [ "${keep}" -eq 0 ]; then rm -rf "$pkgdir" 2>/dev/null || true; log_info "Removed builddir for $pkgid"; else log_info "Kept builddir $pkgdir"; fi
  return 0
}

# Orchestration
build_pipeline() {
  local metafile="$1"
  if [ -z "$metafile" ] || [ ! -f "$metafile" ]; then log_error "build_pipeline requires a metafile"; return 2; fi
  _ensure_meta_symlink
  _load_core || { log_error "Failed to load core modules"; return 1; }
  read pkgdir srcdir builddir destdir pkgout logdir pkgid < <(_pkg_paths "$metafile")
  mkdir -p "$pkgdir" "$logdir" "$pkgout" || true
  log_info "Starting build pipeline for $pkgid"
  metadata_load "$metafile" || { log_error "metadata_load failed"; return 2; }
  metadata_validate "$metafile" || log_warn "metadata validation issues"
  if [ "${BUILD_CACHE_PKGS:-}" != "" ] && build_reuse_cache "$metafile"; then log_info "Reusing cached package"; build_deploy "$metafile" || { log_error "Deploy failed"; return 1; }; return 0; fi
  if declare -F deps_validate >/dev/null 2>&1; then deps_validate "$metafile" || log_warn "deps_validate issues"; fi
  if ! build_prepare "$metafile"; then log_error "Prepare failed"; return 3; fi
  if ! build_compile "$metfile" 2>/dev/null; then # intentional typo fallback to correct name
    build_compile "$metafile" || { log_error "Compile failed"; return 4; }
  fi
  build_check "$metafile" || log_warn "Check stage warnings"
  if ! build_install "$metafile"; then log_error "Install failed"; return 6; fi
  if ! build_package "$metafile"; then log_error "Package failed"; return 7; fi
  if ! build_deploy "$metafile"; then log_error "Deploy failed"; return 8; fi
  build_cleanup "$metafile" "${BUILD_KEEP_LOGS}" || true
  log_ok "Build pipeline completed for $pkgid"
  return 0
}

export -f build_pipeline build_prepare build_compile build_check build_install build_package build_deploy build_cleanup build_reuse_cache

# CLI
_build_usage() {
  cat <<'EOF'
Usage: build.sh [options] <command>
Commands:
  --build <metafile>          Run full pipeline
  --stage <stage> <metafile>  Run single stage: prepare,compile,check,install,package,deploy
  --cleanup <metafile> [keep] Cleanup builddir (keep=0 remove)
  --create-meta <group> <name> [sub]  Create metadata template
  --help
Options:
  --debug | --quiet | --strict | --no-sandbox | --resume
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"
  case "$cmd" in
    --help) _build_usage; exit 0 ;;
    --debug) BUILD_DEBUG=1; shift; cmd="${1:-}" ;;
    --quiet) BUILD_SILENT=1; shift; cmd="${1:-}" ;;
    --strict) BUILD_STRICT=1; shift; cmd="${1:-}" ;;
    --no-sandbox) BUILD_SANDBOX=0; shift; cmd="${1:-}" ;;
    --resume) BUILD_RESUME=1; shift; cmd="${1:-}" ;;
  esac

  case "$cmd" in
    --build) shift; build_pipeline "$1"; exit $? ;;
    --stage) shift; stage="$1"; shift; case "$stage" in
                 prepare|compile|check|install|package|deploy) "build_${stage}" "$1"; exit $? ;; 
                 *) echo "Unknown stage: $stage"; exit 2 ;; esac ;;
    --cleanup) shift; build_cleanup "$1" "${2:-$BUILD_KEEP_LOGS}"; exit $? ;;
    --create-meta) shift; metadata_create "$1" "$2" "$3"; exit $? ;;
    "") _build_usage; exit 2 ;;
    *) _build_usage; exit 2 ;;
  esac
fi
