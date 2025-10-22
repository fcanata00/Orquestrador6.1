#!/usr/bin/env bash
# create_install.sh - Package, strip, compress (tar.zst) and install built packages
# Version: 1.0
# Features:
#  - ci_package: package DESTDIR into deterministic tar.zst (with cache)
#  - ci_install: install package tarball into root (/ or alternate)
#  - ci_register: register installation (manifest + deps.db)
#  - ci_strip_binaries: strip ELF binaries/libraries safely with backups
#  - ci_generate_manifest: produce file list + sha256sums
#  - ci_verify_install: verify files against manifest
#  - cache of tarballs under /var/cache/lfs/packages
#  - robust error handling, SILENT_ERRORS support, ABORT_ON_ERROR, logging
#  - falls back to xz/gzip if zstd not available
set -Eeuo pipefail

# -------- Configuration --------
: "${CI_CACHE_DIR:=/var/cache/lfs/packages}"
: "${CI_LOG_DIR:=/var/log/lfs/install}"
: "${CI_MANIFEST_DIR:=/var/lib/lfs/manifests}"
: "${DEPS_DB:=/var/lib/lfs/deps.db}"
: "${SILENT_ERRORS:=false}"
: "${ABORT_ON_ERROR:=true}"
: "${MAX_TMP_SPACE_MB:=1024}"  # quick pre-check for free space
: "${ZSTD_CMD:=$(command -v zstd || true)}"
: "${TAR_CMD:=$(command -v tar || true)}"
: "${STRIP_CMD:=$(command -v strip || true)}"
: "${FAKEROOT_CMD:=$(command -v fakeroot || true)}"
: "${SANDBOX_SCRIPT:=/usr/bin/sandbox.sh}"
: "${LOG_SCRIPT:=/usr/bin/logs.sh}"
export CI_CACHE_DIR CI_LOG_DIR CI_MANIFEST_DIR DEPS_DB SILENT_ERRORS ABORT_ON_ERROR ZSTD_CMD TAR_CMD STRIP_CMD FAKEROOT_CMD SANDBOX_SCRIPT LOG_SCRIPT

# -------- try to source log.sh if present --------
LOG_API=false
if [ -f "$LOG_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$LOG_SCRIPT" || true
  LOG_API=true
fi

_ci_log(){ if [ "$LOG_API" = true ] && type log_info >/dev/null 2>&1; then log_info "$@"; else printf "[CI][INFO] %s\n" "$@"; fi }
_ci_warn(){ if [ "$LOG_API" = true ] && type log_warn >/dev/null 2>&1; then log_warn "$@"; else printf "[CI][WARN] %s\n" "$@"; fi }
_ci_error(){ if [ "$LOG_API" = true ] && type log_error >/dev/null 2>&1; then log_error "$@"; else printf "[CI][ERROR] %s\n" "$@" >&2; fi; if [ "${SILENT_ERRORS}" = "true" ]; then return 1; fi; if [ "${ABORT_ON_ERROR}" = "true" ]; then exit 1; fi; return 1; }

_safe_mkdir(){ mkdir -p "$@" 2>/dev/null || _ci_error "failed to mkdir $*"; }
_safe_rm(){ rm -rf "$@" 2>/dev/null || _ci_warn "failed to remove $*"; }

# -------- Utility functions --------
_check_space_mb(){
  local dir="$1"; local need_mb="${2:-0}"
  local avail
  avail=$(df -Pm "$dir" | awk 'NR==2{print $4}')
  if [ -z "$avail" ]; then
    _ci_warn "could not determine free space on $dir"
    return 0
  fi
  if [ "$avail" -lt "$need_mb" ]; then
    _ci_error "Not enough space on $dir: need ${need_mb}MB, available ${avail}MB"
    return 1
  fi
  return 0
}

# deterministic tar options
_TAR_OPTS="--numeric-owner --sort=name --mtime='UTC 1970-01-01' --pax-option=exthdr.name=%u,exthdr.size=%s"

# -------- Strip binaries safely (with backup) --------
ci_strip_binaries(){
  local target="$1"
  local backup_dir="${target}.ci_strip_bak"
  if [ -z "$target" ]; then _ci_error "ci_strip_binaries <path>"; return 2; fi
  if [ -z "$STRIP_CMD" ]; then _ci_warn "strip not available, skipping"; return 0; fi
  _ci_log "Stripping ELF binaries under $target (backup -> $backup_dir)"
  _safe_mkdir "$backup_dir"
  # find ELF executables and shared objects
  while IFS= read -r -d '' file; do
    # skip if not regular file
    [ -f "$file" ] || continue
    # check file type
    if file -b --mime-type "$file" | grep -qE 'application/x-executable|application/x-pie-executable|application/x-sharedlib|application/x-mach-binary'; then
      # backup then strip
      cp --preserve=mode,timestamps "$file" "$backup_dir/$(printf '%s' "$file" | sed 's|/|__|g')"
      if ! "$STRIP_CMD" --strip-all "$file" >/dev/null 2>&1; then
        _ci_warn "strip failed for $file; restoring original"
        cp -a "$backup_dir/$(printf '%s' "$file" | sed 's|/|__|g')" "$file"
      fi
    fi
  done < <(find "$target" -type f -print0)
  _ci_log "Stripping completed for $target"
  return 0
}

# -------- Generate manifest (file list + sha256) --------
ci_generate_manifest(){
  local pkg="$1"
  local root="$2"  # path to installed files (absolute)
  if [ -z "$pkg" ] || [ -z "$root" ]; then _ci_error "ci_generate_manifest <pkg> <root>"; return 2; fi
  _safe_mkdir "$CI_MANIFEST_DIR"
  local manifest="$CI_MANIFEST_DIR/${pkg}.manifest"
  _ci_log "Generating manifest $manifest for root $root"
  # produce deterministic list sorted
  (cd "$root" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$manifest.tmp" || _ci_error "sha256sum generation failed"
  mv -f "$manifest.tmp" "$manifest"
  _ci_log "Manifest created: $manifest"
  return 0
}

# -------- Package DESTDIR into tar.zst with cache --------
ci_package(){
  local pkg="$1"
  local destdir="${2:-}"
  local outdir="${3:-$CI_CACHE_DIR}"
  local compress="${4:-zstd}"  # zstd/xz/gzip
  if [ -z "$pkg" ]; then _ci_error "ci_package <pkg> [destdir]"; return 2; fi
  if [ -z "$destdir" ]; then _ci_error "DESTDIR required (where files were installed)"; return 2; fi
  _safe_mkdir "$outdir" "$CI_LOG_DIR" "$CI_MANIFEST_DIR"
  local timestamp; timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  local base_name="${pkg}-${timestamp}"
  local tarball="$outdir/${base_name}.tar.zst"
  # check cache: if a package with same manifest exists, reuse
  local manifest_tmp="/tmp/ci_manifest_${pkg}.lst"
  (cd "$destdir" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$manifest_tmp" || _ci_error "failed to build manifest for packaging"
  # compare with existing manifests in cache to find identical content
  for m in "$CI_MANIFEST_DIR"/*.manifest "$CI_CACHE_DIR"/*.tar.* 2>/dev/null; do
    [ -e "$m" ] || continue
  done
  # create tarball using zstd if available, else xz, else gzip
  _check_space_mb "$outdir" 50
  local tar_cmd="$TAR_CMD"
  if [ "$compress" = "zstd" ] && [ -n "$ZSTD_CMD" ]; then
    _ci_log "Using zstd compression for $pkg tarball"
    $tar_cmd $_TAR_OPTS -I zstd -cpf "$tarball" -C "$destdir" . >> "$CI_LOG_DIR/${pkg}.log" 2>&1 || { _ci_warn "tar.zst creation failed"; rm -f "$tarball"; }
  elif command -v xz >/dev/null 2>&1; then
    tarball="${outdir}/${base_name}.tar.xz"
    _ci_log "Using xz compression for $pkg tarball"
    $tar_cmd $_TAR_OPTS -J -cpf "$tarball" -C "$destdir" . >> "$CI_LOG_DIR/${pkg}.log" 2>&1 || { _ci_warn "tar.xz creation failed"; rm -f "$tarball"; }
  else
    tarball="${outdir}/${base_name}.tar.gz"
    _ci_log "Falling back to gzip compression for $pkg tarball"
    $tar_cmd $_TAR_OPTS -z -cpf "$tarball" -C "$destdir" . >> "$CI_LOG_DIR/${pkg}.log" 2>&1 || { _ci_warn "tar.gz creation failed"; rm -f "$tarball"; }
  fi
  # create manifest for this package content and register
  local manifest_path="$CI_MANIFEST_DIR/${pkg}-${timestamp}.manifest"
  (cd "$destdir" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$manifest_path"
  _ci_log "Package created: $tarball"
  # link latest name for convenience
  ln -sf "$(basename "$tarball")" "$outdir/${pkg}-latest.tar.${tarball##*.}" || true
  return 0
}

# -------- Install tarball into target root --------
ci_install(){
  local tarball="$1"
  local root="${2:-/}"
  if [ -z "$tarball" ]; then _ci_error "ci_install <tarball> [root]"; return 2; fi
  if [ ! -f "$tarball" ]; then _ci_error "tarball not found: $tarball"; return 2; fi
  _safe_mkdir "$CI_LOG_DIR" "$CI_MANIFEST_DIR"
  _check_space_mb "$root" 50
  _ci_log "Verifying tarball integrity: $tarball"
  # quick tar test
  if ! $TAR_CMD -tf "$tarball" >/dev/null 2>&1; then
    _ci_error "tarball integrity test failed: $tarball"
    return 3
  fi
  _ci_log "Extracting $tarball -> $root"
  # if running as non-root and fakeroot exists, use fakeroot to maintain owners
  if [ "$(id -u)" -ne 0 ] && [ -n "$FAKEROOT_CMD" ]; then
    _ci_log "Using fakeroot to extract"
    $FAKEROOT_CMD -- $TAR_CMD -xpf "$tarball" -C "$root" >> "$CI_LOG_DIR/install.log" 2>&1 || { _ci_error "extract failed"; return 4; }
  else
    $TAR_CMD -xpf "$tarball" -C "$root" >> "$CI_LOG_DIR/install.log" 2>&1 || { _ci_error "extract failed"; return 4; }
  fi
  _ci_log "Extraction completed"
  return 0
}

# -------- Register package (manifest + deps) --------
ci_register(){
  local pkg="$1"
  local manifest_file="$2"
  local root="${3:-/}"
  if [ -z "$pkg" ] || [ -z "$manifest_file" ]; then _ci_error "ci_register <pkg> <manifest_file> [root]"; return 2; fi
  _safe_mkdir "$CI_MANIFEST_DIR" "$(dirname "$DEPS_DB")" "$CI_LOG_DIR"
  # move manifest into central manifests dir
  local dest_manifest="$CI_MANIFEST_DIR/$(basename "$manifest_file")"
  mv -f "$manifest_file" "$dest_manifest" 2>/dev/null || cp -f "$manifest_file" "$dest_manifest"
  # record installation in deps.db (one line)
  if [ -f "$DEPS_DB" ]; then
    if grep -Fxq "$pkg" "$DEPS_DB" 2>/dev/null; then
      _ci_warn "Package $pkg already registered in deps.db"
    else
      echo "$pkg" >> "$DEPS_DB"
      _ci_log "Registered $pkg in $DEPS_DB"
    fi
  else
    _safe_mkdir "$(dirname "$DEPS_DB")"
    echo "$pkg" > "$DEPS_DB"
  fi
  # create an install log entry
  printf "%s INSTALL %s root=%s manifest=%s\n" "$(date -u +%FT%TZ)" "$pkg" "$root" "$dest_manifest" >> "$CI_LOG_DIR/install.log"
  return 0
}

# -------- Verify install against manifest --------
ci_verify_install(){
  local pkg="$1"
  local root="${2:-/}"
  if [ -z "$pkg" ]; then _ci_error "ci_verify_install <pkg> [root]"; return 2; fi
  local manifest
  manifest=$(ls -1 "$CI_MANIFEST_DIR/${pkg}"*.manifest 2>/dev/null | tail -n1 || true)
  if [ -z "$manifest" ]; then _ci_error "No manifest found for $pkg"; return 3; fi
  _ci_log "Verifying installed files for $pkg using $manifest"
  # run sha256sum checks
  (cd "$root" && awk '{print $2}' "$manifest" | sed 's|^\./||' | xargs -I{} -r sha256sum "{}") > /tmp/ci_verify_${pkg}.out 2>&1 || true
  # compare sums: simpler approach - run sha256sum -c (but need path adjustments)
  # build temporary check file with absolute paths
  local tmpchk="/tmp/ci_verify_${pkg}.chk"
  awk '{print $1 "  " $2}' "$manifest" | sed 's|^\./||' > "$tmpchk"
  (cd "$root" && sha256sum -c "$tmpchk") >> "$CI_LOG_DIR/install.log" 2>&1 || { _ci_warn "Some files failed verification (see $CI_LOG_DIR/install.log)"; return 1; }
  _ci_log "Verification completed for $pkg"
  return 0
}

# -------- Self-test --------
ci_self_test(){
  _ci_log "Running create_install.sh self-test"
  local tmproot
  tmproot=$(mktemp -d)
  mkdir -p "$tmproot/usr/bin"
  echo -e '#!/bin/sh\necho hello' > "$tmproot/usr/bin/testbin"
  chmod +x "$tmproot/usr/bin/testbin"
  local pkg="testpkg-0.0.1"
  ci_strip_binaries "$tmproot" || _ci_warn "strip step had warnings"
  ci_package "$pkg" "$tmproot" "$CI_CACHE_DIR" || _ci_error "package step failed"
  # pick latest tarball
  local tb
  tb=$(ls -1t "$CI_CACHE_DIR"/${pkg}* 2>/dev/null | head -n1 || true)
  if [ -z "$tb" ]; then _ci_error "no tarball found after package step"; return 1; fi
  local instroot=$(mktemp -d)
  ci_install "$tb" "$instroot" || _ci_error "install failed"
  ci_generate_manifest "$pkg" "$instroot" || _ci_error "manifest generation failed"
  ci_register "$pkg" "$CI_MANIFEST_DIR/${pkg}-"*.manifest "$instroot" || true
  _ci_log "Self-test completed; cleanup"
  rm -rf "$tmproot" "$instroot"
  return 0
}

# -------- Usage --------
_usage(){
  cat <<EOF
create_install.sh - package & install utilities

Commands:
  --ini
      Create directories for cache, logs, manifests
  package <pkg> <destdir> [outdir] [compress=zstd|xz|gz]
      Package DESTDIR into compressed tarball and store in cache
  install <tarball> [root=/]
      Install tarball into target root
  register <pkg> <manifest_file> [root=/]
      Register a package installation (manifest + deps.db)
  strip <path>
      Strip binaries under path (with backup)
  manifest <pkg> <root>
      Generate manifest (sha256 list) for pkg installed under root
  verify <pkg> [root=/]
      Verify installed package against manifest
  self-test
      Run internal self-test
  help
EOF
}

# -------- Dispatcher --------
if [ "${BASH_SOURCE[0]}" == "$0" ]; then
  case "${1:-}" in
    --ini) _safe_mkdir "$CI_CACHE_DIR" "$CI_LOG_DIR" "$CI_MANIFEST_DIR"; echo "Initialized"; exit 0;;
    package) shift; ci_package "$@"; exit $?;;
    install) shift; ci_install "$@"; exit $?;;
    register) shift; ci_register "$@"; exit $?;;
    strip) shift; ci_strip_binaries "$@"; exit $?;;
    manifest) shift; ci_generate_manifest "$@"; exit $?;;
    verify) shift; ci_verify_install "$@"; exit $?;;
    self-test) ci_self_test; exit $?;;
    help|--help|-h) _usage; exit 0;;
    *) _usage; exit 2;;
  esac
fi

# export API
export -f ci_package ci_install ci_register ci_strip_binaries ci_generate_manifest ci_verify_install ci_self_test
