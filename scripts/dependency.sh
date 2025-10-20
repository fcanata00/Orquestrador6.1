#!/usr/bin/env bash
set -euo pipefail; IFS=$'\n\t'
SCRIPTS_DIR="${SCRIPTS_DIR:-/usr/bin}"; source "$SCRIPTS_DIR/utils.sh"
if [ "$#" -lt 1 ]; then echo "usage: dependency.sh <pkgname|meta.ini>"; exit 2; fi
target="$1"
if [ -f "$target" ]; then meta="$target"; else meta=$(find "$META_ROOT" -type f -name "$(basename "$target").ini" | head -n1 || true); fi
if [ -z "$meta" ]; then log_error "Metafile not found for $target"; exit 3; fi
parse_ini "$meta"
name=$(ini_get meta name "$(basename "$meta" .ini)")
deps=$(ini_get deps depends "")
echo "Dependencies for $name: $deps"
# simple print tree for comma-separated deps
IFS=',' read -r -a arr <<< "$deps"
for d in "${arr[@]}"; do echo " - $d"; done
