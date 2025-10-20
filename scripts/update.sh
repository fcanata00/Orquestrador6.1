#!/usr/bin/env bash
set -euo pipefail; IFS=$'\n\t'
SCRIPTS_DIR="${SCRIPTS_DIR:-/usr/bin}"; source "$SCRIPTS_DIR/utils.sh"
# very small wrapper to call update_autorebuild if exists
if [ -x "$SCRIPTS_DIR/update_autorebuild.sh" ]; then bash "$SCRIPTS_DIR/update_autorebuild.sh" "$@"; else log_warn "No update_autorebuild.sh present"; fi
