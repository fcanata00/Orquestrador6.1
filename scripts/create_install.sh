#!/usr/bin/env bash
# create_install.sh - Enhanced package & install utility with CLI, parallel installs and dependency resolution
# Version: 1.1
# Features:
#  - Full CLI: init, package, install-cache, install-dir, install-multi, list-cache, verify, purge-cache, strip, manifest, self-test
#  - Cache of tarballs under /var/cache/lfs/packages (configurable)
#  - Safe strip with backups
#  - Deterministic tar creation (zstd/xz/gz fallback)
#  - Integrates with deps.sh for dependency resolution (deps_resolve, deps_mark_installed)
#  - Parallel installation support while respecting dependency ordering
#  - Robust error handling, SILENT_ERRORS, ABORT_ON_ERROR
#  - Logging and manifest generation
set -Eeuo pipefail

# -------- Configuration --------
: "${CI_CACHE_DIR:=/var/cache/lfs/packages}"
: "${CI_LOG_DIR:=/var/log/lfs/install}"
: "${CI_MANIFEST_DIR:=/var/lib/lfs/manifests}"
: "${DEPS_DB:=/var/lib/lfs/deps.db}"
: "${SILENT_ERRORS:=false}"
: "${ABORT_ON_ERROR:=true}"
: "${MAX_TMP_SPACE_MB:=1024}"
: "${ZSTD_CMD:=$(command -v zstd || true)}"
: "${TAR_CMD:=$(command -v tar || true)}"
: "${STRIP_CMD:=$(command -v strip || true)}"
: "${FAKEROOT_CMD:=$(command -v fakeroot || true)}"
: "${DEPS_SCRIPT:=/usr/bin/deps.sh}"
: "${LOG_SCRIPT:=/usr/bin/logs.sh}"
export CI_CACHE_DIR CI_LOG_DIR CI_MANIFEST_DIR DEPS_DB SILENT_ERRORS ABORT_ON_ERROR ZSTD_CMD TAR_CMD STRIP_CMD FAKEROOT_CMD DEPS_SCRIPT LOG_SCRIPT

# try to source helpers if present
LOG_API=false
if [ -f "$LOG_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$LOG_SCRIPT" || true
  LOG_API=true
fi
# try deps integration
DEPS_API=false
if [ -f "$DEPS_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$DEPS_SCRIPT" || true
  if type deps_resolve >/dev/null 2>&1; then
    DEPS_API=true
  fi
fi

_ci_log(){ if [ "$LOG_API" = true ] && type log_info >/dev/null 2>&1; then log_info "$@"; else printf "[CI][INFO] %s\n" "$@"; fi }
_ci_warn(){ if [ "$LOG_API" = true ] && type log_warn >/dev/null 2>&1; then log_warn "$@"; else printf "[CI][WARN] %s\n" "$@"; fi }
_ci_error(){ if [ "$LOG_API" = true ] && type log_error >/dev/null 2>&1; then log_error "$@"; else printf "[CI][ERROR] %s\n" "$@" >&2; fi; if [ "${SILENT_ERRORS}" = "true" ]; then return 1; fi; if [ "${ABORT_ON_ERROR}" = "true" ]; then exit 1; fi; return 1; }

_safe_mkdir(){ mkdir -p "$@" 2>/dev/null || _ci_error "failed to mkdir $*"; }
_safe_rm(){ rm -rf "$@" 2>/dev/null || _ci_warn "failed to remove $*"; }

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

_TAR_OPTS="--numeric-owner --sort=name --mtime='UTC 1970-01-01' --pax-option=exthdr.name=%u,exthdr.size=%s"

# find tarball in cache for pkg (optional ver)
_find_cached_tarball(){
  local pkg="$1"; local ver="$2"
  # prefer exact version match if provided
  if [ -n "$ver" ]; then
    local candidate
    candidate=$(ls -1t "$CI_CACHE_DIR"/${pkg}-${ver}.* 2>/dev/null | head -n1 || true)
    [ -n "$candidate" ] && { echo "$candidate"; return 0; }
  fi
  # fallback to latest matching pkg-*
  local latest
  latest=$(ls -1t "$CI_CACHE_DIR"/${pkg}-*.* 2>/dev/null | head -n1 || true)
  [ -n "$latest" ] && { echo "$latest"; return 0; }
  return 1
}

# strip binaries safely
ci_strip_binaries(){
  local target="$1"
  local backup_dir="${target}.ci_strip_bak"
  if [ -z "$target" ]; then _ci_error "ci_strip_binaries <path>"; return 2; fi
  if [ -z "$STRIP_CMD" ]; then _ci_warn "strip not available, skipping"; return 0; fi
  _ci_log "Stripping ELF binaries under $target (backup -> $backup_dir)"
  _safe_mkdir "$backup_dir"
  while IFS= read -r -d '' file; do
    [ -f "$file" ] || continue
    if file -b --mime-type "$file" | grep -qE 'application/x-executable|application/x-pie-executable|application/x-sharedlib'; then
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

# generate manifest
ci_generate_manifest(){
  local pkg="$1"; local root="$2"; local out_manifest="${3:-}"
  if [ -z "$pkg" ] || [ -z "$root" ]; then _ci_error "ci_generate_manifest <pkg> <root>"; return 2; fi
  _safe_mkdir "$CI_MANIFEST_DIR"
  local manifest="${out_manifest:-$CI_MANIFEST_DIR/${pkg}-$(date -u +%Y%m%dT%H%M%SZ).manifest}"
  _ci_log "Generating manifest $manifest for root $root"
  (cd "$root" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "${manifest}.tmp" || _ci_error "sha256sum generation failed"
  mv -f "${manifest}.tmp" "$manifest"
  _ci_log "Manifest created: $manifest"
  echo "$manifest"
  return 0
}

# package destdir into compressed tarball with cache
ci_package(){
  local pkg="$1"; local destdir="$2"; local outdir="${3:-$CI_CACHE_DIR}"; local compress="${4:-zstd}"
  if [ -z "$pkg" ] || [ -z "$destdir" ]; then _ci_error "ci_package <pkg> <destdir> [outdir] [compress]"; return 2; fi
  _safe_mkdir "$outdir" "$CI_LOG_DIR" "$CI_MANIFEST_DIR"
  _check_space_mb "$outdir" 50
  local timestamp; timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  local base_name="${pkg}-${timestamp}"
  local tarball="$outdir/${base_name}.tar.zst"
  # create manifest for content to support cache dedup
  local temp_manifest="/tmp/ci_manifest_${pkg}_${timestamp}.lst"
  (cd "$destdir" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$temp_manifest" || _ci_error "failed to build manifest for packaging"
  # check existing manifests for identical content (simple heuristic: compare hashes)
  for m in "$CI_MANIFEST_DIR"/*.manifest 2>/dev/null; do
    [ -e "$m" ] || continue
    if cmp -s "$temp_manifest" "$m"; then
      # find tarball matching this manifest (by name convention)
      local existing
      existing=$(ls -1t "$CI_CACHE_DIR"/${pkg}-*.* 2>/dev/null | head -n1 || true)
      if [ -n "$existing" ]; then
        _ci_log "Found identical package in cache, reusing $existing"
        rm -f "$temp_manifest"
        ln -sf "$(basename "$existing")" "$outdir/${pkg}-latest.${existing##*.}" || true
        echo "$existing"
        return 0
      fi
    fi
  done
  # no identical cache, create tarball
  if [ "$compress" = "zstd" ] && [ -n "$ZSTD_CMD" ]; then
    _ci_log "Creating tar.zst -> $tarball"
    $TAR_CMD $_TAR_OPTS -I zstd -cpf "$tarball" -C "$destdir" . >> "$CI_LOG_DIR/${pkg}.log" 2>&1 || { _ci_warn "tar.zst creation failed"; rm -f "$tarball"; return 1; }
  elif command -v xz >/dev/null 2>&1; then
    tarball="$outdir/${base_name}.tar.xz"
    _ci_log "Creating tar.xz -> $tarball"
    $TAR_CMD $_TAR_OPTS -J -cpf "$tarball" -C "$destdir" . >> "$CI_LOG_DIR/${pkg}.log" 2>&1 || { _ci_warn "tar.xz creation failed"; rm -f "$tarball"; return 1; }
  else
    tarball="$outdir/${base_name}.tar.gz"
    _ci_log "Creating tar.gz -> $tarball"
    $TAR_CMD $_TAR_OPTS -z -cpf "$tarball" -C "$destdir" . >> "$CI_LOG_DIR/${pkg}.log" 2>&1 || { _ci_warn "tar.gz creation failed"; rm -f "$tarball"; return 1; }
  fi
  # move manifest into manifests dir
  mv -f "$temp_manifest" "$CI_MANIFEST_DIR/${pkg}-${timestamp}.manifest" 2>/dev/null || cp -f "$temp_manifest" "$CI_MANIFEST_DIR/${pkg}-${timestamp}.manifest"
  ln -sf "$(basename "$tarball")" "$outdir/${pkg}-latest.${tarball##*.}" || true
  _ci_log "Package created: $tarball"
  echo "$tarball"
  return 0
}

# install tarball into root
ci_install(){
  local tarball="$1"; local root="${2:-/}"
  if [ -z "$tarball" ]; then _ci_error "ci_install <tarball> [root]"; return 2; fi
  if [ ! -f "$tarball" ]; then _ci_error "tarball not found: $tarball"; return 2; fi
  _safe_mkdir "$CI_LOG_DIR" "$CI_MANIFEST_DIR"
  _check_space_mb "$root" 50
  _ci_log "Testing tarball integrity: $tarball"
  if ! $TAR_CMD -tf "$tarball" >/dev/null 2>&1; then
    _ci_error "tarball integrity test failed: $tarball"; return 3
  fi
  _ci_log "Extracting $tarball -> $root"
  if [ "$(id -u)" -ne 0 ] && [ -n "$FAKEROOT_CMD" ]; then
    _ci_log "Using fakeroot for extraction"
    $FAKEROOT_CMD -- $TAR_CMD -xpf "$tarball" -C "$root" >> "$CI_LOG_DIR/install.log" 2>&1 || { _ci_error "extract failed"; return 4; }
  else
    $TAR_CMD -xpf "$tarball" -C "$root" >> "$CI_LOG_DIR/install.log" 2>&1 || { _ci_error "extract failed"; return 4; }
  fi
  _ci_log "Extraction completed: $tarball -> $root"
  return 0
}

# register package
ci_register(){
  local pkg="$1"; local manifest_file="$2"; local root="${3:-/}"
  if [ -z "$pkg" ] || [ -z "$manifest_file" ]; then _ci_error "ci_register <pkg> <manifest> [root]"; return 2; fi
  _safe_mkdir "$CI_MANIFEST_DIR" "$(dirname "$DEPS_DB")" "$CI_LOG_DIR"
  local dest_manifest="$CI_MANIFEST_DIR/$(basename "$manifest_file")"
  mv -f "$manifest_file" "$dest_manifest" 2>/dev/null || cp -f "$manifest_file" "$dest_manifest"
  if [ -f "$DEPS_DB" ]; then
    if grep -Fxq "$pkg" "$DEPS_DB" 2>/dev/null; then
      _ci_warn "Package $pkg already registered"
    else
      echo "$pkg" >> "$DEPS_DB"
      _ci_log "Registered $pkg in $DEPS_DB"
      # if deps.sh available, call its mark API too
      if type deps_mark_installed >/dev/null 2>&1; then
        deps_mark_installed "$pkg" || true
      fi
    fi
  else
    _safe_mkdir "$(dirname "$DEPS_DB")"
    echo "$pkg" > "$DEPS_DB"
  fi
  printf "%s INSTALL %s root=%s manifest=%s\n" "$(date -u +%FT%TZ)" "$pkg" "$root" "$dest_manifest" >> "$CI_LOG_DIR/install.log"
  return 0
}

# verify installed package against manifest
ci_verify_install(){
  local pkg="$1"; local root="${2:-/}"
  if [ -z "$pkg" ]; then _ci_error "ci_verify_install <pkg> [root]"; return 2; fi
  local manifest
  manifest=$(ls -1 "$CI_MANIFEST_DIR/${pkg}"*.manifest 2>/dev/null | tail -n1 || true)
  if [ -z "$manifest" ]; then _ci_error "No manifest found for $pkg"; return 3; fi
  _ci_log "Verifying installed files for $pkg using $manifest"
  local tmpchk="/tmp/ci_verify_${pkg}.chk"
  awk '{print $1 "  " $2}' "$manifest" | sed 's|^\./||' > "$tmpchk"
  (cd "$root" && sha256sum -c "$tmpchk") >> "$CI_LOG_DIR/install.log" 2>&1 || { _ci_warn "Some files failed verification (see $CI_LOG_DIR/install.log)"; return 1; }
  _ci_log "Verification completed for $pkg"
  return 0
}

# install single package from cache by pkg name and optional version
ci_install_from_cache(){
  local pkg="$1"; local ver="$2"; local root="${3:-/}"
  if [ -z "$pkg" ]; then _ci_error "ci_install_from_cache <pkg> [ver] [root]"; return 2; fi
  local tb
  tb=$(_find_cached_tarball "$pkg" "$ver") || { _ci_error "No cached tarball found for $pkg ${ver:-}"; return 3; }
  _ci_log "Installing cached package $pkg from $tb to root $root"
  # extract into temp root if root is not allowed directly, but we'll extract directly
  ci_install "$tb" "$root" || { _ci_error "installation failed for $pkg"; return 4; }
  # generate manifest for registration (manifest from cache might exist; prefer created manifest matching tar)
  local manifest
  manifest=$(ls -1 "$CI_MANIFEST_DIR/${pkg}"* 2>/dev/null | tail -n1 || true)
  if [ -z "$manifest" ]; then
    manifest=$(ci_generate_manifest "$pkg" "$root")
  fi
  ci_register "$pkg" "$manifest" "$root" || _ci_warn "registration failed for $pkg"
  return 0
}

# install directory directly (copy into root)
ci_install_directory(){
  local srcdir="$1"; local root="${2:-/}"; local pkgname="${3:-localpkg-$(date -u +%Y%m%dT%H%M%SZ)}"
  if [ -z "$srcdir" ]; then _ci_error "ci_install_directory <srcdir> [root] [pkgname]"; return 2; fi
  _ci_log "Installing directory $srcdir -> $root"
  _check_space_mb "$root" 50
  if [ "$(id -u)" -ne 0 ] && [ -n "$FAKEROOT_CMD" ]; then
    $FAKEROOT_CMD -- $TAR_CMD -C "$srcdir" -cpf - . | $FAKEROOT_CMD -- $TAR_CMD -xpf - -C "$root" >> "$CI_LOG_DIR/install.log" 2>&1 || { _ci_error "install-dir failed"; return 3; }
  else
    $TAR_CMD -C "$srcdir" -cpf - . | $TAR_CMD -xpf - -C "$root" >> "$CI_LOG_DIR/install.log" 2>&1 || { _ci_error "install-dir failed"; return 3; }
  fi
  local manifest
  manifest=$(ci_generate_manifest "$pkgname" "$root")
  ci_register "$pkgname" "$manifest" "$root"
  return 0
}

# list cache
ci_list_cache(){
  _safe_mkdir "$CI_CACHE_DIR"
  ls -1t "$CI_CACHE_DIR" 2>/dev/null || true
  return 0
}

# purge cache older than N days (keep latest)
ci_purge_cache(){
  local keep="${1:-3}"
  _ci_log "Purging cache, keeping latest ${keep} files per package"
  # simple strategy: keep newest N files globally per package prefix
  for pkg_prefix in $(ls -1 "$CI_CACHE_DIR" 2>/dev/null | sed -E 's/-[0-9T].*$//' | sort -u); do
    local files=( $(ls -1t "$CI_CACHE_DIR"/${pkg_prefix}-* 2>/dev/null) )
    local idx=0
    for f in "${files[@]}"; do
      idx=$((idx+1))
      if [ "$idx" -gt "$keep" ]; then
        _ci_log "Removing cached file $f"
        rm -f "$f" || _ci_warn "failed to remove $f"
      fi
    done
  done
  return 0
}

# Install multiple packages with dependency resolution and optional parallelism.
# Accepts list of package names (pkg or pkg:ver). Uses deps_resolve to build full list and order.
ci_install_multi(){
  local parallel="${1:-1}"; shift || true
  local targets=( "$@" )
  if [ "${#targets[@]}" -eq 0 ]; then _ci_error "ci_install_multi <parallel> <pkg...>"; return 2; fi
  _ci_log "Installing multiple packages: ${targets[*]} with parallel=${parallel}"
  local order=()
  local seen=()
  # Use deps_resolve if available to get deps first order for each target
  if [ "$DEPS_API" = true ]; then
    for t in "${targets[@]}"; do
      # allow pkg:ver format
      local pkg="${t%%:*}"
      while IFS= read -r p; do
        if [ -z "${seen[$p]:-}" ]; then
          order+=( "$p" )
          seen["$p"]=1
        fi
      done < <(deps_resolve "$pkg")
    done
  else
    # no deps API: install targets in given order (best-effort)
    for t in "${targets[@]}"; do
      pkg="${t%%:*}"
      if [ -z "${seen[$pkg]:-}" ]; then order+=( "$pkg" ); seen["$pkg"]=1; fi
    done
  fi

  _ci_log "Resolved install order: ${order[*]}"

  # track installed flag
  declare -A installed
  declare -A inprogress
  local total=${#order[@]}
  local idx=0
  # function to start next eligible package respecting deps
  start_jobs(){
    while [ "${#inprogress[@]}" -lt "$parallel" ]; do
      # find next package whose dependencies are installed
      local found=""
      for p in "${order[@]}"; do
        [ -n "${installed[$p]:-}" ] && continue
        [ -n "${inprogress[$p]:-}" ] && continue
        # check if all deps of p are installed (use deps_required_by? better to query mf_get_field depends via metafile, but use deps_resolve result)
        local deps_ok=true
        if [ "$DEPS_API" = true ] && type mf_get_field >/dev/null 2>&1; then
          deps="$(mf_get_field "$p" depends 2>/dev/null || true)"
          deps="${deps//[[:space:]]/}"
          if [ -n "$deps" ]; then
            IFS=',' read -ra arr <<< "$deps"
            for d in "${arr[@]}"; do
              [ -z "$d" ] && continue
              if [ -z "${installed[$d]:-}" ]; then deps_ok=false; break; fi
            done
          fi
        fi
        if [ "$deps_ok" = true ]; then found="$p"; break; fi
      done
      if [ -z "$found" ]; then break; fi
      # start background job
      inprogress["$found"]=1
      (
        _ci_log "Starting install job for $found"
        # allow version spec if provided in original targets (search)
        local ver=""
        for tt in "${targets[@]}"; do [ "${tt%%:*}" = "$found" ] && { tmp="${tt#*:}"; if [ "$tmp" != "$tt" ]; then ver="$tmp"; fi; break; }; done
        if ci_install_from_cache "$found" "$ver"; then
          _ci_log "Install succeeded: $found"
          # signal success by touching flag file
          echo "$found" > "/tmp/ci_installed_${found}.$$"
          exit 0
        else
          _ci_warn "Install failed for $found"
          echo "FAILED:$found" > "/tmp/ci_installed_${found}.$$"
          exit 1
        fi
      ) &
      sleep 0.1
    done
  }

  # main loop: launch jobs and wait for completions
  while true; do
    start_jobs
    # wait for any job to finish
    if ! wait -n 2>/dev/null; then
      # wait -n unsupported: fallback to polling process list
      sleep 1
    fi
    # check tmp markers for completed jobs
    for p in "${order[@]}"; do
      if [ -n "${inprogress[$p]:-}" ]; then
        if [ -f "/tmp/ci_installed_${p}."* ]; then
          # find file
          for f in /tmp/ci_installed_${p}.*; do
            [ -e "$f" ] || continue
            if grep -q '^FAILED:' "$f" 2>/dev/null; then
              _ci_warn "Background install reported failure for $p"
              rm -f "$f"
              unset inprogress["$p"]
              installed["$p"]="failed"
            else
              _ci_log "Background install completed for $p"
              rm -f "$f"
              unset inprogress["$p"]
              installed["$p"]=1
            fi
          done
        fi
      fi
    done
    # check if all done
    local all_done=true
    for p in "${order[@]}"; do
      if [ -z "${installed[$p]:-}" ]; then all_done=false; break; fi
    done
    [ "$all_done" = true ] && break
    # loop continues
  done

  # summarize
  local failed=0
  for p in "${order[@]}"; do
    if [ "${installed[$p]}" = "failed" ]; then _ci_warn "Package failed: $p"; failed=1; fi
  done
  if [ "$failed" -eq 1 ]; then _ci_warn "Some packages failed to install; check logs"; return 1; fi
  _ci_log "All packages installed successfully"
  return 0
}

# usage
_usage(){
  cat <<EOF
create_install.sh - Enhanced packaging and install utility

Usage:
  create_install.sh --ini
  create_install.sh package <pkg> <destdir> [outdir] [compress=zstd|xz|gz]
  create_install.sh install-cache <pkg> [ver] [root=/]
  create_install.sh install-dir <srcdir> [root=/] [pkgname]
  create_install.sh install-multi [--parallel N] <pkg[:ver]...>
  create_install.sh list-cache
  create_install.sh verify <pkg> [root=/]
  create_install.sh purge-cache [keep=3]
  create_install.sh strip <path>
  create_install.sh manifest <pkg> <root>
  create_install.sh self-test
  create_install.sh help
EOF
}

# dispatcher
if [ "${BASH_SOURCE[0]}" == "$0" ]; then
  case "${1:-}" in
    --ini) _safe_mkdir "$CI_CACHE_DIR" "$CI_LOG_DIR" "$CI_MANIFEST_DIR"; echo "Initialized"; exit 0;;
    package) shift; ci_package "$@"; exit $?;;
    install-cache) shift; ci_install_from_cache "$@"; exit $?;;
    install-dir) shift; ci_install_directory "$@"; exit $?;;
    install-multi) shift; 
        # parse parallel opt
        PAR=1
        if [ "$1" = "--parallel" ]; then PAR="$2"; shift 2; fi
        ci_install_multi "$PAR" "$@"
        exit $?;;
    list-cache) shift; ci_list_cache; exit $?;;
    verify) shift; ci_verify_install "$@"; exit $?;;
    purge-cache) shift; ci_purge_cache "$@"; exit $?;;
    strip) shift; ci_strip_binaries "$@"; exit $?;;
    manifest) shift; ci_generate_manifest "$@"; exit $?;;
    self-test) ci_self_test; exit $?;;
    help|--help|-h|*) _usage; exit 0;;
  esac
fi

# export functions
export -f ci_package ci_install ci_install_from_cache ci_install_directory ci_list_cache ci_verify_install ci_purge_cache ci_strip_binaries ci_generate_manifest ci_install_multi ci_register
