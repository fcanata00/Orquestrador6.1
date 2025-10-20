#!/usr/bin/env bash
set -euo pipefail; IFS=$'\n\t'
SCRIPTS_DIR="${SCRIPTS_DIR:-/usr/bin}"; source "$SCRIPTS_DIR/utils.sh"
if [ "$#" -lt 1 ]; then echo "usage: uninstall.sh <pkgname>"; exit 2; fi
for pkg in "$@"; do
  meta=$(find "$META_ROOT" -type f -name "$(basename "$pkg").ini" | head -n1 || true)
  if [ -z "$meta" ]; then log_warn "Metafile for $pkg not found; attempting conservative remove"; fi
  # conservative: look for files installed under /usr/local or /usr that match package name
  # NOTE: this is heuristic and may miss files; recommend using package manager metadata in future
  log_info "Attempting to remove files for $pkg (heuristic)"
  # no-op: just log for safety in this simplified implementation
  log_warn "uninstall is conservative: review files manually"
done
