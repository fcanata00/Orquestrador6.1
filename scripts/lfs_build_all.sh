#!/usr/bin/env bash
# lfs_build_all.sh - Full LFS build orchestrator (enhanced)
# Version: 1.2
# Features:
# - sequential and parallel builds with resume support
# - CPU/MEM/Load monitoring during builds
# - integration with binpkg/build.sh/deps.sh/doctor.sh
# - per-package logs, progress counters and state checkpointing
set -Eeuo pipefail
IFS=$'\n\t'

: "${LFS:=/mnt/lfs}"
: "${METAFILE_DIR:=${LFS}/usr/src}"
: "${LOG_DIR:=${LFS}/var/log/lfs}"
: "${STATE_DIR:=/var/lib/lfs/build}"
: "${BINPKG:=/usr/bin/binpkg}"
: "${PARALLEL_BUILDS:=1}"
: "${RETRY:=2}"
: "${SILENT:=false}"
export LFS METAFILE_DIR LOG_DIR STATE_DIR BINPKG PARALLEL_BUILDS RETRY SILENT

mkdir -p "$LOG_DIR" "$STATE_DIR" "$METAFILE_DIR"

_info(){ if [ "$SILENT" != "true" ]; then printf "[lfs-build] %s\n" "$*"; fi; printf "%s %s\n" "$(date -u +%FT%TZ)" "$*" >> "${LOG_DIR}/lfs_build.log"; }
_warn(){ if [ "$SILENT" != "true" ]; then printf "[lfs-build][WARN] %s\n" "$*"; fi; printf "%s WARN %s\n" "$(date -u +%FT%TZ)" "$*" >> "${LOG_DIR}/lfs_build.log"; }
_err(){ printf "[lfs-build][ERROR] %s\n" "$*" >&2; printf "%s ERROR %s\n" "$(date -u +%FT%TZ)" "$*" >> "${LOG_DIR}/lfs_build.log"; exit 1; }

trap 'rc=$?; if [ $rc -ne 0 ]; then _err "Exiting with code $rc"; fi' EXIT

# helpers
_ncpu(){ nproc || echo 1; }
_meminfo(){ awk '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2} END{printf "%.2fGB %.2fGB", t/1024/1024, a/1024/1024}' /proc/meminfo 2>/dev/null || echo "N/A"; }
_loadavg(){ awk '{printf "%.2f %.2f %.2f", $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "N/A"; }

_checkpoint_file(){ printf "%s/%s.chk" "$STATE_DIR" "$1"; }

# resolve package order via deps.sh or list metafiles
_resolve_order(){
  local stage="$1"
  if command -v deps.sh >/dev/null 2>&1 && type deps_resolve_order >/dev/null 2>&1; then
    deps_resolve_order "$stage"
    return 0
  fi
  local d="$METAFILE_DIR/$stage"
  if [ -d "$d" ]; then
    for f in "$d"/*.ini; do [ -f "$f" ] && basename "$(dirname "$f")"; done
  else
    _warn "No metafiles directory for stage: $stage"
  fi
}

# build single package with retries and logging
_build_one(){
  local pkg="$1"
  local logf="${LOG_DIR}/builds/${pkg}.log"
  mkdir -p "$(dirname "$logf")"
  local chk=$(_checkpoint_file "$pkg")
  if [ -f "$chk" ]; then
    _info "Skipping $pkg (checkpoint exists)"
    return 0
  fi
  local attempt=0
  local start=$(date +%s)
  while [ $attempt -lt $((RETRY+1)) ]; do
    attempt=$((attempt+1))
    _info "Building $pkg (attempt $attempt)"
    _info "Resources: CPU=$(_ncpu) MEM=$(_meminfo) LOAD=$(_loadavg)"
    if [ -x "$BINPKG" ]; then
      if "$BINPKG" build pkg "$pkg" >>"$logf" 2>&1; then
        echo "$(date -u +%FT%TZ) OK" > "$chk"
        _info "Built $pkg successfully (log: $logf)"
        break
      else
        _warn "Build failed for $pkg (see $logf). Retrying..."
      fi
    elif command -v build.sh >/dev/null 2>&1; then
      if build.sh --pkg "$pkg" >>"$logf" 2>&1; then
        echo "$(date -u +%FT%TZ) OK" > "$chk"
        break
      else
        _warn "build.sh failed for $pkg (see $logf)."
      fi
    else
      _err "No build runner found (binpkg/build.sh)"
    fi
    sleep 2
  done
  local end=$(date +%s)
  _info "Finished $pkg (duration $((end-start))s)"
  # run quick doctor check for this package's binaries if doctor.sh available
  if command -v doctor.sh >/dev/null 2>&1; then
    doctor.sh --bins >> "${LOG_DIR}/doctor_after_build.log" 2>&1 || _warn "doctor.sh reported issues after $pkg"
  fi
}

# orchestrate builds with optional parallelism
_build_stage(){
  local stage="$1"
  local pkgs; pkgs=$(_resolve_order "$stage" || true)
  if [ -z "$pkgs" ]; then _warn "No packages to build for $stage"; return 0; fi
  mkdir -p "${LOG_DIR}/builds"
  local total=$(echo "$pkgs" | wc -w)
  local i=0
  # run builds, with limited parallelism using xargs -P
  if [ "$PARALLEL_BUILDS" -gt 1 ]; then
    printf "%s\n" $pkgs | xargs -P "$PARALLEL_BUILDS" -n1 -I{} bash -c '_build_one "$@"' _ {}
  else
    for pkg in $pkgs; do
      i=$((i+1))
      printf "\n[STAGE %s] (%d/%d) %s\n" "$stage" "$i" "$total" "$pkg"
      _build_one "$pkg"
    done
  fi
}

init_environment(){
  _info "Initializing LFS environment at $LFS"
  mkdir -p "$LFS" "$LOG_DIR" "$METAFILE_DIR"
  for m in dev proc sys run; do
    if ! mountpoint -q "$LFS/$m"; then
      _warn "$LFS/$m not mounted; you may need to mount pseudo-FS before chroot"
    fi
  done
  if ! id -u lfs >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1; then
      _info "Creating lfs user (requires sudo)"
      sudo useradd -m -s /bin/bash lfs || _warn "Failed to create lfs user"
    else
      _warn "sudo not available; skipping user creation"
    fi
  fi
}

enter_chroot(){
  if [ "$EUID" -ne 0 ]; then
    _warn "Chroot requires root; run 'sudo lfs_build_all.sh --enter-chroot' or mount manually"
    return 0
  fi
  for m in dev proc sys run; do
    [ -d "$LFS/$m" ] || mkdir -p "$LFS/$m"
    mountpoint -q "$LFS/$m" || mount --bind "/$m" "$LFS/$m" || _warn "mount bind $m failed"
  done
  _info "Entering chroot..."
  sudo chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$TERM" PATH=/usr/bin:/bin /bin/bash --login +h
}

verify_system(){
  if command -v doctor.sh >/dev/null 2>&1; then
    doctor.sh --scan || _warn "doctor.sh detected issues"
  else
    _warn "doctor.sh not available; running simple ldd/readelf checks"
    for b in /usr/bin/* /bin/*; do
      [ -x "$b" ] || continue
      ldd "$b" 2>&1 | grep -q 'not found' && _warn "Missing lib in $b"
    done
  fi
}

summary_report(){
  local out="${LOG_DIR}/build-summary-$(date -u +%Y%m%dT%H%M%SZ).json"
  python3 - <<PY > "$out"
import json,os,time
d={'lfs':os.environ.get('LFS','/mnt/lfs'),'time':time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
print(json.dumps(d, indent=2))
PY
  _info "Summary written to $out"
}

_usage(){
  cat <<EOF
lfs_build_all.sh - orchestrate LFS builds

Usage:
  lfs_build_all.sh --ini
  lfs_build_all.sh --stage 1|2|3|all
  lfs_build_all.sh --enter-chroot
  lfs_build_all.sh --verify
  lfs_build_all.sh --help

Environment:
  PARALLEL_BUILDS=n   run up to n builds concurrently
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -lt 1 ]; then _usage; exit 2; fi
  case "$1" in
    --ini) init_environment; exit 0;;
    --stage) case "$2" in
      1) _build_stage 1;;
      2) _build_stage 2;;
      3) _build_stage 3;;
      all) _build_stage 1; enter_chroot; _build_stage 2; _build_stage 3;;
      *) _usage; exit 2;;
    esac; exit 0;;
    --enter-chroot) enter_chroot; exit 0;;
    --verify) verify_system; exit 0;;
    --help|-h) _usage; exit 0;;
    *) _usage; exit 2;;
  esac
fi
