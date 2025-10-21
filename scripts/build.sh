#!/usr/bin/env bash
# build.sh - build orchestrator for one package (uses metadata.sh, download.sh, sandbox.sh, register.sh)
if [ -n "${BUILD_SH_LOADED-}" ]; then return 0 2>/dev/null || exit 0; fi
BUILD_SH_LOADED=1
: "${LFS_ROOT:=/mnt/lfs}"
: "${BUILD_ROOT:=${LFS_ROOT}/builds}"
: "${LOG_ROOT:=${LFS_ROOT}/build_logs}"
: "${CACHE_DIR:=${LFS_ROOT}/cache}"

_find_helpers() {
  for f in ./register.sh ./core.sh ./metadata.sh ./download.sh ./sandbox.sh ./deps.sh; do
    [ -f "$f" ] && source "$f"
  done
}
_find_helpers

_build_extract() {
  local srcdir="$1"
  for f in "$srcdir"/*; do
    [ -f "$f" ] || continue
    case "$f" in
      *.tar.gz|*.tgz) tar -xzf "$f" -C "$srcdir" ;;
      *.tar.xz) tar -xJf "$f" -C "$srcdir" ;;
      *.tar.bz2) tar -xjf "$f" -C "$srcdir" ;;
      *.zip) unzip -q "$f" -d "$srcdir" ;;
      *) : ;;
    esac
  done
}

build_pipeline() {
  local metafile="$1"
  metadata_load "$metafile" || { log_error "metadata_load failed for $metafile"; return 2; }
  local name="$(metadata_get 'meta.name' || basename "$metafile" .ini)"
  local version="$(metadata_get 'meta.version' || '')"
  local group="$(metadata_get 'meta.group' || core)"
  local pkgid="${group}/${name}-${version}"
  local pkgdir="${BUILD_ROOT}/${pkgid}"
  local srcdir="${pkgdir}/src"
  local workdir="${pkgdir}/build"
  local destdir="${pkgdir}/dest"
  local logdir="${LOG_ROOT}/${group}/${name}-${version}"
  mkdir -p "$pkgdir" "$srcdir" "$workdir" "$destdir" "$logdir" 2>/dev/null || true

  log_info "Building ${pkgid}"
  if ! download_fetch "$metafile"; then log_error "download_fetch failed"; return 3; fi
  # copy sources
  local cache_src="${SOURCES_DIR}/${name}-${version}"
  if [ -d "$cache_src" ]; then cp -a "$cache_src"/* "$srcdir"/ 2>/dev/null || true; fi
  _build_extract "$srcdir"
  metadata_apply_patches "$srcdir"
  metadata_run_hook pre_prepare "$srcdir"
  # run custom build blocks
  local prepare="$(metadata_get 'build.prepare' || true)"
  local compile="$(metadata_get 'build.compile' || true)"
  local check="$(metadata_get 'build.check' || true)"
  local install="$(metadata_get 'build.install' || true)"
  mkdir -p "$workdir"
  if [ -n "$prepare" ]; then (cd "$srcdir" && bash -euc "$prepare") > "${logdir}/prepare.log" 2>&1 || { log_error "prepare failed"; return 4; } fi
  if [ -n "$compile" ]; then (cd "$workdir" && bash -euc "$compile") > "${logdir}/compile.log" 2>&1 || { log_error "compile failed"; return 5; } else
    # default build
    ( cd "$srcdir" && ./configure --prefix=/usr > "${logdir}/configure.log" 2>&1 ) || true
    ( cd "$srcdir" && make -j"$(nproc)" > "${logdir}/make.log" 2>&1 ) || true
  fi
  metadata_run_hook post_compile "$srcdir"
  if [ -n "$check" ]; then (cd "$workdir" && bash -euc "$check") > "${logdir}/check.log" 2>&1 || log_warn "check failed"; fi
  mkdir -p "$destdir"
  if [ -n "$install" ]; then ( export DESTDIR="$destdir"; cd "$workdir"; bash -euc "$install" ) > "${logdir}/install.log" 2>&1 || { log_error "install failed"; return 6; } else
    ( cd "$workdir" && make DESTDIR="$destdir" install > "${logdir}/install.log" 2>&1 ) || { log_error "make install failed"; return 6; }
  fi
  metadata_run_hook post_install "$srcdir"
  # strip binaries
  if command -v strip >/dev/null 2>&1; then
    find "$destdir" -type f -exec file -L {} \; | grep -E 'ELF .*executable|ELF .*shared' -B1 | awk -F: '/:/{print $1}' | while read -r f; do strip --strip-unneeded "$f" 2>/dev/null || true; done || true
  fi
  # package
  mkdir -p "${CACHE_DIR}"
  local out="${CACHE_DIR}/${pkgid}.tar.zst"
  if command -v zstd >/dev/null 2>&1; then
    tar -C "$destdir" -cf - . | zstd -T0 -o "${out}" > /dev/null 2>&1 || { log_error "packaging failed"; return 7; }
  else
    tar -C "$destdir" -cf - . | gzip -c > "${out}.gz" || { log_error "packaging failed"; return 7; }
    out="${out}.gz"
  fi
  _atomic_write "${out}.sha256" "$(_hash_file "${out}" 2>/dev/null || true)"
  cp -a "$out" "${pkgdir}/" 2>/dev/null || true
  log_ok "Package built: ${out}"
  return 0
}
