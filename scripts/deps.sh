#!/usr/bin/env bash
# deps.sh - simple dependency resolver for build order and checks
if [ -n "${DEPS_SH_LOADED-}" ]; then return 0 2>/dev/null || exit 0; fi
DEPS_SH_LOADED=1
# Minimal: metadata may include 'depends=group/pkg' lines (comma separated)
deps_parse() {
  local metafile="$1"
  metadata_load "$metafile" || return 2
  local raw="$(metadata_get 'meta.depends' || '')"
  # split by commas/newlines
  echo "$raw" | tr ',' '\n' | sed '/^\s*$/d' | sed 's/^\s*//;s/\s*$//'
}
deps_validate() {
  local metafile="$1"
  local missing=0
  for d in $(deps_parse "$metafile"); do
    # simplistic: check if installed under /mnt/lfs/tools or /usr
    if [ ! -e "/mnt/lfs/builds/${d}" ] && [ ! -e "/${d}" ]; then
      log_warn "Dependency ${d} not present"
      missing=1
    fi
  done
  return $missing
}
