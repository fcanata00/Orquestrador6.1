#!/usr/bin/env bash
# core.sh - shared helpers for all scripts
if [ -n "${CORE_SH_LOADED-}" ]; then return 0 2>/dev/null || exit 0; fi
CORE_SH_LOADED=1
# safe shell options for sourced libraries
set -o errexit
set -o nounset
set -o pipefail

# helper: atomic write to file
_atomic_write() { local file="$1"; shift; local tmp="${file}.$$.$RANDOM.tmp"; { printf '%s\n' "$@"; } > "$tmp" && mv -f "$tmp" "$file"; }

# detect command or fail
_require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "required command missing: $1" >&2; return 1; } }

# safe cd
_safe_cd() { cd "$1" 2>/dev/null || return 1; }
