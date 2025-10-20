#!/usr/bin/env bash
set -euo pipefail; IFS=$'\n\t'
SCRIPTS_DIR="${SCRIPTS_DIR:-/usr/bin}"; source "$SCRIPTS_DIR/utils.sh"
CHECK_ONLY=false; DIFF=false
while [[ $# -gt 0 ]]; do case "$1" in --check-only) CHECK_ONLY=true; shift;; --diff) DIFF=true; shift;; --dry-run) DRY_RUN=true; shift;; --verbose) VERBOSE=true; shift;; --help) echo "install.sh [--check-only] <pkg|archive>"; exit 0;; *) break;; esac; done
if [ "$#" -lt 1 ]; then echo "usage: install.sh [options] <pkgname|path/to/archive>..."; exit 2; fi
for arg in "$@"; do
  if [ -f "$arg" ]; then pkgfile="$arg"; log_info "Installing from file $pkgfile"; if [ "$DRY_RUN" = true ]; then log_info "DRY-RUN extract $pkgfile -> /"; continue; fi; tar -xpf "$pkgfile" -C / || die "extract failed"; log_info "Installed from $pkgfile"; else meta="$(find "$META_ROOT" -type f -name "$(basename "$arg").ini" | head -n1 || true)"; if [ -z "$meta" ]; then log_error "metafile for $arg not found"; continue; fi; parse_ini "$meta"; name=$(ini_get meta name "$arg"); ver=$(ini_get meta version "0.0.0"); pkgarchive="$SOURCES_DIR/${name}-${ver}.tar.xz"; if [ -f "$pkgarchive" ]; then if [ "$DRY_RUN" = true ]; then log_info "DRY-RUN extract $pkgarchive -> /"; else tar -xpf "$pkgarchive" -C / || die "extract failed"; fi; log_info "Installed $name"; else log_warn "archive $pkgarchive not found - run build"; fi; fi
done
