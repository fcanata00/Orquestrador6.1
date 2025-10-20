#!/usr/bin/env bash
set -eEuo pipefail; IFS=$'\n\t'
SCRIPTS_DIR="${SCRIPTS_DIR:-/usr/bin}"; source "$SCRIPTS_DIR/utils.sh"
if [ "$#" -eq 0 ]; then echo "Usage: build.sh <pkg-name|meta.ini> [...]"; exit 2; fi
for target in "$@"; do
  if [ -f "$target" ]; then meta="$target"; else
    # try to find meta by name
    meta=$(find "$META_ROOT" -type f -name "$(basename "$target").ini" | head -n1 || true)
    if [ -z "$meta" ]; then log_error "Metafile for $target not found"; continue; fi
  fi
  log_info "Building from metafile: $meta"
  parse_ini "$meta"
  name=$(ini_get meta name "$(basename "$meta" .ini)")
  version=$(ini_get meta version "0.0.0")
  srcdir="$SOURCES_DIR/$name-$version-src"
  mkdir -p "$srcdir"
  download_sources_from_meta "$meta" "$srcdir" || { log_error "Download failed for $name"; continue; }
  # naive extract first archive
  archive=$(ls "$srcdir" | head -n1 2>/dev/null || true)
  if [ -n "$archive" ]; then
    a="$srcdir/$archive"
    log_info "Extracting $a"
    mkdir -p "$srcdir/exp"
    if tar -tf "$a" >/dev/null 2>&1; then tar -xf "$a" -C "$srcdir/exp"; fi
  fi
  # run hooks pre-build if any
  run_hooks_for "$(dirname "$meta")" pre-build || log_warn "pre-build hooks failed"
  # very simplified build: if there's a configure script, run configure/make/make install to $LFS/tools
  srcroot=$(find "$srcdir/exp" -maxdepth 2 -type d | head -n1 || true)
  if [ -z "$srcroot" ]; then log_warn "Source root not found for $name"; run_hooks_for "$(dirname "$meta")" post-build; continue; fi
  pushd "$srcroot" >/dev/null
  if [ -f configure ]; then
    ./configure --prefix=/usr || log_warn "configure failed"
    make -j$(nproc) || log_error "make failed for $name"
    make DESTDIR="$LFS" install || log_warn "make install may have issues"
  else
    log_warn "No configure - skipping build for $name"
  fi
  popd >/dev/null
  run_hooks_for "$(dirname "$meta")" post-build || log_warn "post-build hooks failed"
  log_info "Build finished for $name"
done
