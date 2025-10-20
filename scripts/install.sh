#!/usr/bin/env bash
set -euo pipefail; IFS=$'\n\t'
SCRIPTS_DIR="${SCRIPTS_DIR:-/usr/bin}"; source "$SCRIPTS_DIR/utils.sh"
if [ "$#" -lt 1 ]; then echo "usage: install.sh <pkgname|path/to/archive>"; exit 2; fi
for arg in "$@"; do
  if [ -f "$arg" ]; then
    pkgfile="$arg"; log_info "Installing from file $pkgfile"
    # extract to / (be careful)
    if [ "$DRY_RUN" = true ]; then log_info "DRY-RUN extract $pkgfile -> /"; continue; fi
    if tar -tf "$pkgfile" >/dev/null 2>&1; then tar -xpf "$pkgfile" -C / || log_error "tar extract failed"; fi
    log_info "Installed from $pkgfile"
  else
    # install by package name: find package in META_ROOT or cache
    meta=$(find "$META_ROOT" -type f -name "$(basename "$arg").ini" | head -n1 || true)
    if [ -z "$meta" ]; then log_error "Metafile for $arg not found"; continue; fi
    parse_ini "$meta"
    name=$(ini_get meta name "$arg"); version=$(ini_get meta version "0.0.0")
    pkg_archive="$SOURCES_DIR/${name}-${version}.tar.xz"
    if [ -f "$pkg_archive" ]; then
      if [ "$DRY_RUN" = true ]; then log_info "DRY-RUN: would extract $pkg_archive -> /"; continue; fi
      tar -xpf "$pkg_archive" -C / || log_error "extract failed"
      log_info "Installed $name from $pkg_archive"
    else
      log_warn "Package archive $pkg_archive not found - consider running build.sh"
    fi
  fi
done
