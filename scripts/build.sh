#!/usr/bin/env bash
# build.sh - Orquestrador de build para LFS automated builder
# Versão: 1.0
# Integra com: metafile.sh, deps.sh, download.sh, sandbox.sh, utils.sh, log.sh, uninstall.sh, update.sh
# Requisitos: bash 4+, coreutils, tar, gzip, xz, sha256sum, fakeroot (recommended), prlimit, rsync (optional)
set -Eeuo pipefail

# ====== Configurações ======
: "${BUILD_LOG_DIR:=/var/log/lfs/builds}"
: "${BUILD_MANIFEST_DIR:=/var/lib/lfs/manifests}"
: "${BUILD_WORK_DIR:=/tmp/lfs-build}"
: "${SILENT_ERRORS:=false}"
: "${ABORT_ON_ERROR:=true}"
: "${LOG_SCRIPT:=/usr/bin/logs.sh}"
: "${UTILS_SCRIPT:=/usr/bin/utils.sh}"
: "${METAFILE_SCRIPT:=/usr/bin/metafile.sh}"
: "${DOWNLOAD_SCRIPT:=/usr/bin/download.sh}"
: "${DEPS_SCRIPT:=/usr/bin/deps.sh}"
: "${SANDBOX_SCRIPT:=/usr/bin/sandbox.sh}"
: "${FAKEROOT_CMD:=$(command -v fakeroot || true)}"
: "${DOWNLOAD_RETRY:=3}"
: "${MAKEFLAGS:=-j$(nproc)}"

export BUILD_LOG_DIR BUILD_MANIFEST_DIR BUILD_WORK_DIR SILENT_ERRORS ABORT_ON_ERROR LOG_SCRIPT UTILS_SCRIPT METAFILE_SCRIPT DOWNLOAD_SCRIPT DEPS_SCRIPT SANDBOX_SCRIPT FAKEROOT_CMD DOWNLOAD_RETRY MAKEFLAGS

# ===== Try to source log and utils if available =====
LOG_API_READY=false
if [ -f "$LOG_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$LOG_SCRIPT" || true
  LOG_API_READY=true
fi
if [ -f "$UTILS_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$UTILS_SCRIPT" || true
fi
if [ -f "$METAFILE_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$METAFILE_SCRIPT" || true
fi
if [ -f "$DEPS_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$DEPS_SCRIPT" || true
fi
if [ -f "$SANDBOX_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$SANDBOX_SCRIPT" || true
fi

# ===== logging helpers =====
_bld_info(){ if [ "$LOG_API_READY" = true ] && type log_info >/dev/null 2>&1; then log_info "$@"; else printf "[BUILD][INFO] %s\n" "$@"; fi }
_bld_warn(){ if [ "$LOG_API_READY" = true ] && type log_warn >/dev/null 2>&1; then log_warn "$@"; else printf "[BUILD][WARN] %s\n" "$@"; fi }
_bld_error(){ if [ "$LOG_API_READY" = true ] && type log_error >/dev/null 2>&1; then log_error "$@"; else printf "[BUILD][ERROR] %s\n" "$@" >&2; fi; if [ "${SILENT_ERRORS}" = "true" ]; then return 1; fi; if [ "${ABORT_ON_ERROR}" = "true" ]; then exit 1; fi; return 1; }

# ===== helpers =====
_safe_mkdir(){ mkdir -p "$1" 2>/dev/null || _bld_error "failed to mkdir $1"; }
_timestamp(){ date -u +%FT%TZ; }

# run a command capturing stdout/stderr to build-specific log and returning code
_safe_run_log(){
  local log="$1"; shift
  if [ -z "$log" ]; then _bld_error "log path required"; return 2; fi
  "$@" >>"$log" 2>&1
  return $?
}

# run with retries
_retry_cmd(){
  local tries=${1:-3}; shift
  local i=0
  local rc=0
  until "$@"; do
    rc=$?
    i=$((i+1))
    if [ $i -ge $tries ]; then
      return $rc
    fi
    sleep $((i*2))
  done
  return 0
}

# safe exec wrapper for steps: logs stage start/end, records timestamp and status
_step_start(){
  local log="$1"; local stage="$2"; local pkg="$3"; local total="$4"; local num="$5"
  _bld_info "[$pkg] Step $num/$total: $stage"
  printf "%s STEP-START %s %s\n" "$(_timestamp)" "$stage" "$pkg" >> "$log"
}
_step_end(){
  local log="$1"; local stage="$2"; local pkg="$3"; local rc="$4"
  if [ "$rc" -eq 0 ]; then
    printf "%s STEP-END OK %s %s\n" "$(_timestamp)" "$stage" "$pkg" >> "$log"
  else
    printf "%s STEP-END FAIL %s %s rc=%d\n" "$(_timestamp)" "$stage" "$pkg" "$rc" >> "$log"
  fi
}

# ===== Build stages implementation =====

# load metafile for a package (expects metafile.sh loaded)
build_load_metafile(){
  local pkg="$1"
  local dir="${2:-}"
  if [ -z "$pkg" ]; then _bld_error "build_load_metafile requires package id"; return 2; fi
  # initialize metafiles if a dir passed
  if [ -n "$dir" ]; then
    if type mf_init >/dev/null 2>&1; then
      mf_init "$dir" || _bld_error "mf_init failed for $dir"
    fi
  fi
  # ensure package exists
  if ! mf_get_field "$pkg" "name" >/dev/null 2>&1; then
    # try init default dir
    mf_init "${METAFILE_DIR:-./metafiles}" 2>/dev/null || true
  fi
  # read important fields and export into associative MF_VARS (simple key=value file)
  local tmp="/tmp/build_mf_${pkg}.env"
  : > "$tmp"
  for field in name version description type stage dir base_dir sources git_url git_ref patches patch_dir hooks_dir environment flags install_prefix prepare build check install update_url; do
    val="$(mf_get_field "$pkg" "$field" 2>/dev/null || true)"
    printf "%s=%s\n" "$field" "$(printf "%s" "$val" | sed 's/"/\\"/g')" >> "$tmp"
  done
  echo "$tmp"
}

# prepare workspace and logs
build_prepare(){
  local pkg="$1"; local mf_env_file="$2"
  [ -z "$pkg" ] && _bld_error "build_prepare requires pkg" && return 2
  _safe_mkdir "$BUILD_LOG_DIR" "$BUILD_MANIFEST_DIR" "$BUILD_WORK_DIR"
  local workdir="$BUILD_WORK_DIR/$pkg"
  _safe_mkdir "$workdir"
  local log="$BUILD_LOG_DIR/${pkg}.log"
  touch "$log"
  printf "%s BUILD-START %s\n" "$(_timestamp)" "$pkg" >> "$log"
  echo "$workdir|$log"
}

# download sources using download.sh or curl fallback
build_download_sources(){
  local pkg="$1"; local mf_env="$2"; local worklog="$3"
  local srcs
  srcs="$(mf_get_field "$pkg" "sources" 2>/dev/null || true)"
  local git_url
  git_url="$(mf_get_field "$pkg" "git_url" 2>/dev/null || true)"
  # if download.sh provides API, try to register and fetch
  if [ -x "$DOWNLOAD_SCRIPT" ] && type dl_add_source >/dev/null 2>&1; then
    _bld_info "Registering sources in download.sh for $pkg"
    # try parse csv
    IFS=',' read -ra items <<< "$srcs"
    for it in "${items[@]:-}"; do
      it="$(echo "$it" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [ -z "$it" ] && continue
      url="$(echo "$it" | cut -d'|' -f1)"
      sha="$(echo "$it" | sed -n 's/.*sha256:\([a-fA-F0-9]\+\).*/\1/p' || true)"
      mirrors="$(echo "$it" | sed -n 's/.*mirrors=\([^|]*\).*/\1/p' || true)"
      dl_add_source "$url" "${sha:+sha256:$sha}" "$mirrors" "$pkg" || _bld_warn "dl_add_source failed for $url"
    done
    if [ -n "$git_url" ]; then
      dl_add_source "$git_url" "" "" "$pkg" || true
    fi
    _bld_info "Attempting download fetch-all via $DOWNLOAD_SCRIPT"
    if type dl_fetch_all >/dev/null 2>&1; then
      dl_fetch_all >> "$worklog" 2>&1 || _bld_warn "dl_fetch_all reported issues"
    else
      # fall back to calling download.sh CLI if supports fetch-all
      "$DOWNLOAD_SCRIPT" fetch-all >> "$worklog" 2>&1 || _bld_warn "download.sh fetch-all failed"
    fi
  else
    # fallback: use curl/wget per source
    _bld_warn "download.sh API not available; using curl fallback for $pkg"
    IFS=',' read -ra items <<< "$srcs"
    for it in "${items[@]:-}"; do
      it="$(echo "$it" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [ -z "$it" ] && continue
      url="$(echo "$it" | cut -d'|' -f1)"
      fname="$(basename "${url%%\?*}")"
      dest="$BUILD_WORK_DIR/$pkg/$fname"
      _bld_info "Downloading $url -> $dest"
      _retry_cmd "$DOWNLOAD_RETRY" curl -Lf -o "$dest" "$url" >> "$worklog" 2>&1 || _bld_error "Download failed for $url"
    done
    if [ -n "$git_url" ]; then
      # clone into workdir/sources/<pkg>-git
      dest="$BUILD_WORK_DIR/$pkg/sources/git"
      _safe_mkdir "$dest"
      _bld_info "Cloning $git_url -> $dest"
      git clone --depth 1 "$git_url" "$dest" >> "$worklog" 2>&1 || _bld_warn "git clone failed for $git_url"
      if [ -n "$(mf_get_field "$pkg" git_ref 2>/dev/null || true)" ]; then
        (cd "$dest" && git checkout "$(mf_get_field "$pkg" git_ref)") >> "$worklog" 2>&1 || true
      fi
    fi
  fi
  return 0
}

# verify checksums if provided
build_verify_checksums(){
  local pkg="$1"; local worklog="$2"
  local srcs
  srcs="$(mf_get_field "$pkg" "sources" 2>/dev/null || true)"
  if [ -z "$srcs" ]; then _bld_info "No sources defined for $pkg"; return 0; fi
  IFS=',' read -ra items <<< "$srcs"
  for it in "${items[@]}"; do
    it="$(echo "$it" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    url="$(echo "$it" | cut -d'|' -f1)"
    sha="$(echo "$it" | sed -n 's/.*sha256:\([a-fA-F0-9]\+\).*/\1/p' || true)"
    if [ -z "$sha" ]; then
      _bld_warn "No sha256 for $url; skipping verification"
      continue
    fi
    fname="$(basename "${url%%\?*}")"
    fpath="$BUILD_WORK_DIR/$pkg/$fname"
    if [ ! -f "$fpath" ]; then
      _bld_warn "Expected source file not found: $fpath"
      return 1
    fi
    echo "${sha}  ${fpath}" > "$BUILD_WORK_DIR/$pkg/check.sha256"
    if ! sha256sum -c "$BUILD_WORK_DIR/$pkg/check.sha256" >> "$worklog" 2>&1; then
      _bld_error "Checksum mismatch for $fpath"
      return 1
    fi
  done
  return 0
}

# extract sources into sandbox build dir (or workdir)
build_extract_sources(){
  local pkg="$1"; local worklog="$2"; local merged_build_dir="$3"
  _safe_mkdir "$merged_build_dir"
  # copy tarballs into merged_build_dir and extract
  IFS=',' read -ra items <<< "$(mf_get_field "$pkg" "sources" 2>/dev/null || true)"
  for it in "${items[@]:-}"; do
    it="$(echo "$it" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$it" ] && continue
    url="$(echo "$it" | cut -d'|' -f1)"
    fname="$(basename "${url%%\?*}")"
    srcpath="$BUILD_WORK_DIR/$pkg/$fname"
    if [ -f "$srcpath" ]; then
      _bld_info "Extracting $srcpath -> $merged_build_dir"
      case "$srcpath" in
        *.tar.gz|*.tgz) tar -xzf "$srcpath" -C "$merged_build_dir" --strip-components=1 >> "$worklog" 2>&1 || _bld_error "extract failed";;
        *.tar.xz) tar -xJf "$srcpath" -C "$merged_build_dir" --strip-components=1 >> "$worklog" 2>&1 || _bld_error "extract failed";;
        *.tar.bz2) tar -xjf "$srcpath" -C "$merged_build_dir" --strip-components=1 >> "$worklog" 2>&1 || _bld_error "extract failed";;
        *.zip) unzip -q "$srcpath" -d "$merged_build_dir" >> "$worklog" 2>&1 || _bld_error "extract failed";;
        *) _bld_warn "Unknown archive format for $srcpath; attempting cp" && cp -a "$srcpath" "$merged_build_dir/";;
      esac
    else
      _bld_warn "Source file not found for extraction: $srcpath"
    fi
  done
  # if git source exists in workdir, copy into build dir
  if [ -d "$BUILD_WORK_DIR/$pkg/sources/git" ]; then
    _bld_info "Copying git source into build dir"
    rsync -a "$BUILD_WORK_DIR/$pkg/sources/git/" "$merged_build_dir/" >> "$worklog" 2>&1 || _bld_warn "rsync git -> build failed"
  fi
  return 0
}

# apply patches listed in metafile
build_apply_patches(){
  local pkg="$1"; local worklog="$2"; local merged_build_dir="$3"
  local patches="$(mf_get_field "$pkg" "patches" 2>/dev/null || true)"
  local patch_dir="$(mf_get_field "$pkg" "patch_dir" 2>/dev/null || true)"
  if [ -z "$patches" ]; then _bld_info "No patches for $pkg"; return 0; fi
  IFS=',' read -ra arr <<< "$patches"
  for p in "${arr[@]}"; do
    p="$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    _bld_info "Applying patch $p to $pkg"
    ppath="$patch_dir/$p"
    if [ ! -f "$ppath" ]; then
      _bld_warn "Patch file not found: $ppath"
      return 1
    fi
    (cd "$merged_build_dir" && patch -p1 < "$ppath") >> "$worklog" 2>&1 || { _bld_error "patch failed: $ppath"; return 1; }
  done
  return 0
}

# run package hooks (pre/post phases) by delegating to metafile hooks or package hooks dir
build_run_hooks(){
  local pkg="$1"; local stage="$2"; local merged_build_dir="$3"
  _bld_info "Running hooks for $pkg stage=$stage"
  # try metafile hooks field (hooks.<stage>) first
  local hooks_field
  hooks_field="$(mf_get_field "$pkg" "hooks.$stage" 2>/dev/null || true)"
  if [ -n "$hooks_field" ]; then
    IFS=',' read -ra hh <<< "$hooks_field"
    for h in "${hh[@]}"; do
      h="$(echo "$h" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      if [ -f "$merged_build_dir/$h" ] && [ -x "$merged_build_dir/$h" ]; then
        sb_enter "$SANDBOX_ID" -- "$merged_build_dir/$h" >> "$BUILD_LOG" 2>&1 || _bld_warn "hook $h failed"
      else
        _bld_warn "Hook not found or not executable: $h"
      fi
    done
  fi
  # package hooks dir within source tree
  local hooks_dir="${merged_build_dir}/hooks/${stage}"
  if [ -d "$hooks_dir" ]; then
    for sc in "$hooks_dir"/*; do
      [ -x "$sc" ] || continue
      sb_enter "$SANDBOX_ID" -- "$sc" >> "$BUILD_LOG" 2>&1 || _bld_warn "hook $sc failed"
    done
  fi
  return 0
}

# compile: runs prepare/build/check/install inside sandbox
build_compile(){
  local pkg="$1"; local merged_build_dir="$2"; local worklog="$3"
  local install_prefix="$(mf_get_field "$pkg" install_prefix 2>/dev/null || echo /usr)"
  # run prepare if defined
  local prepare_cmd="$(mf_get_field "$pkg" prepare 2>/dev/null || true)"
  if [ -n "$prepare_cmd" ]; then
    _bld_info "Running prepare command for $pkg"
    sb_enter "$SANDBOX_ID" -- /bin/bash -lc "cd $merged_build_dir && $prepare_cmd" >> "$worklog" 2>&1 || _bld_error "prepare failed"
  elif [ -x "$merged_build_dir/prepare.sh" ]; then
    if [ "${ALLOW_PACKAGE_SCRIPTS:-false}" = "true" ]; then
      sb_enter "$SANDBOX_ID" -- /bin/bash -lc "cd $merged_build_dir && ./prepare.sh" >> "$worklog" 2>&1 || _bld_error "prepare.sh failed"
    else
      _bld_warn "prepare.sh exists but package scripts execution disabled"
    fi
  fi

  # run build: if build script defined, run it; else canonical flows
  local build_cmd="$(mf_get_field "$pkg" build 2>/dev/null || true)"
  if [ -n "$build_cmd" ]; then
    _bld_info "Running build command for $pkg"
    sb_enter "$SANDBOX_ID" -- /bin/bash -lc "cd $merged_build_dir && $build_cmd" >> "$worklog" 2>&1 || _bld_error "build script failed"
  else
    if [ -f "$merged_build_dir/configure" ]; then
      sb_enter "$SANDBOX_ID" -- /bin/bash -lc "cd $merged_build_dir && ./configure --prefix=${install_prefix} ${MF_FLAGS:-}" >> "$worklog" 2>&1 || _bld_error "configure failed"
      sb_enter "$SANDBOX_ID" -- /bin/bash -lc "cd $merged_build_dir && make ${MAKEFLAGS}" >> "$worklog" 2>&1 || _bld_error "make failed"
    elif [ -f "$merged_build_dir/CMakeLists.txt" ]; then
      sb_enter "$SANDBOX_ID" -- /bin/bash -lc "cd $merged_build_dir && mkdir -p build && cd build && cmake .. && make ${MAKEFLAGS}" >> "$worklog" 2>&1 || _bld_error "cmake build failed"
    elif [ -f "$merged_build_dir/Makefile" ]; then
      sb_enter "$SANDBOX_ID" -- /bin/bash -lc "cd $merged_build_dir && make ${MAKEFLAGS}" >> "$worklog" 2>&1 || _bld_error "make failed"
    else
      _bld_warn "No build method detected for $pkg"
      return 1
    fi
  fi
  return 0
}

# run tests inside sandbox
build_check(){
  local pkg="$1"; local merged_build_dir="$2"; local worklog="$3"
  local check_cmd="$(mf_get_field "$pkg" check 2>/dev/null || true)"
  if [ -n "$check_cmd" ]; then
    sb_enter "$SANDBOX_ID" -- /bin/bash -lc "cd $merged_build_dir && $check_cmd" >> "$worklog" 2>&1 || _bld_warn "check script failed"
  elif [ -f "$merged_build_dir/Makefile" ]; then
    sb_enter "$SANDBOX_ID" -- /bin/bash -lc "cd $merged_build_dir && make check" >> "$worklog" 2>&1 || _bld_warn "make check failed"
  else
    _bld_info "No checks defined for $pkg"
  fi
  return 0
}

# install into DESTDIR using fakeroot inside sandbox (or plain make install if not available)
build_install(){
  local pkg="$1"; local merged_build_dir="$2"; local worklog="$3"
  local install_prefix="$(mf_get_field "$pkg" install_prefix 2>/dev/null || echo /usr)"
  local destdir="/install"
  _safe_mkdir "$BUILD_WORK_DIR/$pkg/install"
  # ensure install dest exists in sandbox
  sb_mount_bind "$SANDBOX_ID" "$BUILD_WORK_DIR/$pkg/install" "$destdir" rw
  if [ -n "$FAKEROOT_CMD" ]; then
    _bld_info "Installing with fakeroot for $pkg"
    sb_enter "$SANDBOX_ID" -- $FAKEROOT_CMD -- /bin/bash -lc "cd $merged_build_dir && make install DESTDIR=$destdir" >> "$worklog" 2>&1 || _bld_error "make install (fakeroot) failed"
  else
    _bld_info "Installing without fakeroot for $pkg (may require privileges)"
    sb_enter "$SANDBOX_ID" -- /bin/bash -lc "cd $merged_build_dir && make install DESTDIR=$destdir" >> "$worklog" 2>&1 || _bld_error "make install failed"
  fi
  return 0
}

# finalize: save manifest, mark installed, cleanup
build_finalize(){
  local pkg="$1"; local workdir="$2"; local log="$3"
  local manifest="$BUILD_MANIFEST_DIR/${pkg}.manifest"
  _safe_mkdir "$(dirname "$manifest")"
  {
    echo "package=$(mf_get_field "$pkg" name)"
    echo "version=$(mf_get_field "$pkg" version)"
    echo "built_at=$(_timestamp)"
    echo "log=$log"
    echo "workdir=$workdir"
  } > "$manifest"
  if type deps_mark_installed >/dev/null 2>&1; then
    deps_mark_installed "$pkg"
  fi
  printf "%s BUILD-END %s\n" "$(_timestamp)" "$pkg" >> "$log"
  _bld_info "Build finalized for $pkg; manifest: $manifest"
}

# top-level runner for one package
build_run(){
  local pkg="$1"
  if [ -z "$pkg" ]; then _bld_error "build_run requires package id"; return 2; fi
  local mf_env_file
  mf_env_file=$(build_load_metafile "$pkg" "${METAFILE_DIR:-./metafiles}") || _bld_error "failed to load metafile for $pkg"
  local wf
  wf=$(build_prepare "$pkg" "$mf_env_file") || _bld_error "prepare failed"
  local workdir="${wf%%|*}"; local log="${wf##*|}"
  BUILD_LOG="$log"
  # total steps for progress numbering
  local TOTAL=9
  local STEP=1
  _step_start "$log" "prepare" "$pkg" "$TOTAL" "$STEP"
  # resolve deps
  if type deps_resolve >/dev/null 2>&1; then
    deps_resolve "$pkg" > /dev/null || _bld_warn "deps_resolve reported issues"
  fi
  STEP=$((STEP+1)); _step_end "$log" "prepare" "$pkg" $?
  # create sandbox
  _step_start "$log" "create-sandbox" "$pkg" "$TOTAL" "$STEP"
  SANDBOX_ID=$(sb_create "$pkg" --mode build --mount-cache yes)
  if [ -z "$SANDBOX_ID" ]; then _bld_error "failed to create sandbox for $pkg"; fi
  STEP=$((STEP+1)); _step_end "$log" "create-sandbox" "$pkg" $?
  # download
  _step_start "$log" "download-sources" "$pkg" "$TOTAL" "$STEP"
  build_download_sources "$pkg" "$mf_env_file" "$log" || _bld_error "download sources failed"
  STEP=$((STEP+1)); _step_end "$log" "download-sources" "$pkg" $?
  # verify
  _step_start "$log" "verify-checksums" "$pkg" "$TOTAL" "$STEP"
  build_verify_checksums "$pkg" "$log" || _bld_warn "checksum verification issues"
  STEP=$((STEP+1)); _step_end "$log" "verify-checksums" "$pkg" $?
  # extract
  _step_start "$log" "extract" "$pkg" "$TOTAL" "$STEP"
  # mount build dir in sandbox
  merged_build_dir="/build/$pkg"
  sb_mount_bind "$SANDBOX_ID" "$BUILD_WORK_DIR/$pkg" "$merged_build_dir" rw
  build_extract_sources "$pkg" "$log" "$BUILD_WORK_DIR/$pkg" || _bld_error "extract failed"
  STEP=$((STEP+1)); _step_end "$log" "extract" "$pkg" $?
  # apply patches
  _step_start "$log" "apply-patches" "$pkg" "$TOTAL" "$STEP"
  build_apply_patches "$pkg" "$log" "$BUILD_WORK_DIR/$pkg" || _bld_error "patch phase failed"
  STEP=$((STEP+1)); _step_end "$log" "apply-patches" "$pkg" $?
  # pre-build hooks
  _step_start "$log" "hooks-prebuild" "$pkg" "$TOTAL" "$STEP"
  build_run_hooks "$pkg" "pre-build" "$BUILD_WORK_DIR/$pkg" || _bld_warn "pre-build hooks had issues"
  STEP=$((STEP+1)); _step_end "$log" "hooks-prebuild" "$pkg" $?
  # build
  _step_start "$log" "build-compile" "$pkg" "$TOTAL" "$STEP"
  build_compile "$pkg" "$BUILD_WORK_DIR/$pkg" "$log" || _bld_error "compile failed"
  STEP=$((STEP+1)); _step_end "$log" "build-compile" "$pkg" $?
  # check
  _step_start "$log" "check" "$pkg" "$TOTAL" "$STEP"
  build_check "$pkg" "$BUILD_WORK_DIR/$pkg" "$log" || _bld_warn "check phase had issues"
  STEP=$((STEP+1)); _step_end "$log" "check" "$pkg" $?
  # install
  _step_start "$log" "install" "$pkg" "$TOTAL" "$STEP"
  build_install "$pkg" "$BUILD_WORK_DIR/$pkg" "$log" || _bld_error "install failed"
  STEP=$((STEP+1)); _step_end "$log" "install" "$pkg" $?
  # post-build hooks
  _step_start "$log" "hooks-postbuild" "$pkg" "$TOTAL" "$STEP"
  build_run_hooks "$pkg" "post-build" "$BUILD_WORK_DIR/$pkg" || _bld_warn "post-build hooks issues"
  STEP=$((STEP+1)); _step_end "$log" "hooks-postbuild" "$pkg" $?
  # finalize
  build_finalize "$pkg" "$workdir" "$log"
  # cleanup sandbox
  sb_destroy "$SANDBOX_ID" || _bld_warn "sb_destroy reported issues"
  return 0
}

# CLI
_bld_usage(){
  cat <<EOF
Usage: build.sh <command> [args...]
Commands:
  init                     Create log and manifest dirs
  run <package>            Run full build for package (reads metafile)
  self-test                Run internal self-test (creates fake metafile)
  help
EOF
}

build_self_test(){
  _bld_info "Running build.sh self-test"
  # create a minimal metafile for test in temp dir
  tmp=$(mktemp -d)
  cat > "$tmp/test.ini" <<'INI'
[package]
name=testpkg
version=0.0.1
dir=testpkg-0.0.1
sources=
INI
  mf_init "$tmp"
  # run build for testpkg (will be mostly no-op but exercise flow)
  build_run "testpkg"
  rm -rf "$tmp"
}

if [ "${BASH_SOURCE[0]}" == "$0" ]; then
  case "${1:-}" in
    init) _safe_mkdir "$BUILD_LOG_DIR" "$BUILD_MANIFEST_DIR" "$BUILD_WORK_DIR"; echo "Initialized"; exit 0;;
    run) shift; build_run "$1"; exit $?;;
    self-test) build_self_test; exit $?;;
    help|--help|-h) _bld_usage; exit 0;;
    *) _bld_usage; exit 2;;
  esac
fi

# export API
export -f build_run build_prepare build_download_sources build_verify_checksums build_extract_sources build_apply_patches build_run_hooks build_compile build_check build_install build_finalize build_load_metafile
