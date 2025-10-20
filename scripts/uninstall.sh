#!/usr/bin/env bash
set -euo pipefail; IFS=$'\n\t'
SCRIPTS_DIR="${SCRIPTS_DIR:-/usr/bin}"; source "$SCRIPTS_DIR/utils.sh"
if [ "$#" -lt 1 ]; then echo "usage: uninstall.sh <pkgname> [...]"; exit 2; fi
for pkg in "$@"; do
  meta="$(find "$META_ROOT" -type f -name "${pkg}.ini" | head -n1 || true)"
  log_info "Uninstall requested: $pkg (meta: $meta)"
  log_warn "Uninstall is conservative: review files manually or implement package DB"
done
