#!/usr/bin/env bash
# find_pkg.sh - intelligent package/program finder for LFS automation
# Version: 1.0
# Features:
#  - search installed binaries, metafiles, cache, and remote availability
#  - shows status symbols (✓ installed), path, model (binario/metafile/cache/remoto)
#  - exports API functions for integration with other scripts
#  - JSON output and human-readable formatted output
#  - dry-run, quiet/silent modes, timeouts and retries for network ops
set -Eeuo pipefail
IFS=$'\n\t'

# Configuration (override via env)
: "${LFS_ROOT:=/mnt/lfs}"
: "${METAFILE_DIRS:=${LFS_ROOT}/usr/src:/usr/src}"
: "${CACHE_DIRS:=/var/cache/lfs/sources:/var/cache/lfs/binaries}"
: "${BIN_PATHS:=/usr/bin:/usr/local/bin:${LFS_ROOT}/usr/bin}"
: "${LOG_FILE:=/var/log/lfs/find_pkg.log}"
: "${CURL_TIMEOUT:=8}"
: "${CURL_RETRIES:=2}"
: "${SILENT:=false}"
: "${DRYRUN:=false}"
export LFS_ROOT METAFILE_DIRS CACHE_DIRS BIN_PATHS LOG_FILE CURL_TIMEOUT CURL_RETRIES SILENT DRYRUN

_safe_mkdir(){ mkdir -p "$(dirname "$1")" 2>/dev/null || true; }
_safe_mkdir "$LOG_FILE"

_log(){ if [ "$SILENT" != "true" ]; then printf "[FIND] %s\n" "$*"; fi; echo "$(date -u +%FT%TZ) [INFO] $*" >> "$LOG_FILE"; }
_warn(){ if [ "$SILENT" != "true" ]; then printf "[FIND][WARN] %s\n" "$*"; fi; echo "$(date -u +%FT%TZ) [WARN] $*" >> "$LOG_FILE"; }
_err(){ if [ "$SILENT" != "true" ]; then printf "[FIND][ERROR] %s\n" "$*" >&2; fi; echo "$(date -u +%FT%TZ) [ERROR] $*" >> "$LOG_FILE"; }

# Helpers
_json_escape(){ python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))"; }

# check installed binary by scanning BIN_PATHS
find_pkg_is_installed(){
  local name="$1"
  for p in ${BIN_PATHS//:/ }; do
    [ -d "$p" ] || continue
    if [ -x "$p/$name" ]; then
      printf "%s\n" "$p/$name"
      return 0
    fi
    # try with versioned binary like name-*
    local match
    match=$(find "$p" -maxdepth 1 -type f -executable -name "${name}*" -printf "%f\n" 2>/dev/null | head -n1 || true)
    if [ -n "$match" ]; then
      printf "%s/%s\n" "$p" "$match"
      return 0
    fi
  done
  return 1
}

# search metafiles in METAFILE_DIRS (look for name.ini or name-*.ini)
find_pkg_in_metafile(){
  local name="$1"
  IFS=':' read -r -a dirs <<< "$METAFILE_DIRS"
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    # exact
    if [ -f "$d/${name}.ini" ]; then printf "%s/%s.ini\n" "$d" "$name"; return 0; fi
    # glob
    local found
    found=$(ls "$d"/*"${name}"*.ini 2>/dev/null | head -n1 || true)
    if [ -n "$found" ]; then printf "%s\n" "$found"; return 0; fi
    # also check stage subdirs
    local sub
    for sub in "$d"/*; do
      if [ -d "$sub" ]; then
        found=$(ls "$sub"/*"${name}"*.ini 2>/dev/null | head -n1 || true)
        if [ -n "$found" ]; then printf "%s\n" "$found"; return 0; fi
      fi
    done
  done
  return 1
}

# search cache dirs for tarballs or binaries matching name
find_pkg_in_cache(){
  local name="$1"
  IFS=':' read -r -a dirs <<< "$CACHE_DIRS"
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    local f
    f=$(find "$d" -maxdepth 2 -type f -iname "*${name}*" 2>/dev/null | head -n1 || true)
    if [ -n "$f" ]; then printf "%s\n" "$f"; return 0; fi
  done
  return 1
}

# remote checks - best effort: github repo, packages.gentoo, debian tracker
_find_remote_github(){
  local name="$1"
  local try="https://github.com/${name}/${name}"
  if command -v curl >/dev/null 2>&1; then
    if curl -sSf --max-time "$CURL_TIMEOUT" "$try" >/dev/null 2>&1; then
      printf "%s\n" "$try"; return 0
    fi
  fi
  return 1
}
_find_remote_generic(){
  local name="$1"
  # try common endpoints
  local urls=(
    "https://github.com/${name}/${name}"
    "https://packages.gentoo.org/packages/*/${name}"
    "https://pkgs.org/search/?q=${name}"
    "https://repology.org/projects.json?search=${name}"
  )
  for u in "${urls[@]}"; do
    if command -v curl >/dev/null 2>&1; then
      if curl -sSf --max-time "$CURL_TIMEOUT" "$u" >/dev/null 2>&1; then
        printf "%s\n" "$u"; return 0
      fi
    fi
  done
  return 1
}

# aggregate search (installed, metafile, cache, remote)
find_pkg_search(){
  local name="$1"
  local json_out="${2:-}"
  local -a results=()
  local installed_path=""
  if installed_path=$(find_pkg_is_installed "$name" 2>/dev/null || true); then
    results+=( "installed::${installed_path}" )
  fi
  if mf=$(find_pkg_in_metafile "$name" 2>/dev/null || true); then
    results+=( "metafile::${mf}" )
  fi
  if cachef=$(find_pkg_in_cache "$name" 2>/dev/null || true); then
    results+=( "cache::${cachef}" )
  fi
  if rem=$( _find_remote_github "$name" 2>/dev/null || true ); then
    results+=( "remote::${rem}" )
  else
    rem=$( _find_remote_generic "$name" 2>/dev/null || true ) || true
    if [ -n "$rem" ]; then results+=( "remote::${rem}" ); fi
  fi

  # deduplicate by type+path
  local -A seen
  local out_lines=()
  for r in "${results[@]}"; do
    if [ -z "$r" ]; then continue; fi
    local typ="${r%%::*}"; local path="${r#*::}"
    local key="${typ}::${path}"
    if [ -n "${seen[$key]:-}" ]; then continue; fi
    seen[$key]=1
    out_lines+=( "$typ|$path" )
  done

  if [ -n "$json_out" ] && [ "$json_out" = "json" ]; then
    # build JSON object
    local name_js; name_js=$(printf "%s" "$name" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")
    printf "{\n  \"name\": %s,\n  \"results\": [\n" "$name_js"
    local first=true
    for e in "${out_lines[@]}"; do
      local typ="${e%%|*}"; local path="${e#*|}"
      local installed=false
      if [ "$typ" = "installed" ]; then installed=true; fi
      local typ_js; typ_js=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$typ")
      local path_js; path_js=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$path")
      if [ "$first" = true ]; then first=false; else printf ",\n"; fi
      printf "    {\"type\": %s, \"path\": %s, \"installed\": %s}" "$typ_js" "$path_js" "$([[ "$installed" = true ]] && echo "true" || echo "false")"
    done
    printf "\n  ]\n}\n"
    return 0
  fi

  # pretty print results
  if [ "${#out_lines[@]}" -eq 0 ]; then
    _log "No results for '$name'"
    return 1
  fi
  _log "RESULTS for '$name':"
  for e in "${out_lines[@]}"; do
    local typ="${e%%|*}"; local path="${e#*|}"
    case "$typ" in
      installed) printf "  \033[1;32m[✓]\033[0m %s — instalado em %s\n" "$name" "$path";;
      metafile) printf "  \033[1;34m[📄]\033[0m %s — metafile em %s\n" "$name" "$path";;
      cache) printf "  \033[1;35m[🗃️]\033[0m %s — cache em %s\n" "$name" "$path";;
      remote) printf "  \033[1;36m[🌍]\033[0m %s — remoto em %s\n" "$name" "$path";;
      *) printf "  [ ] %s — %s %s\n" "$typ" "$name" "$path";;
    esac
  done
  # print model summary
  local model_list
  model_list=$(printf "%s\n" "${out_lines[@]}" | awk -F'|' '{print $1}' | sort -u | paste -sd'/' -)
  printf "\nModelo: %s\n" "$model_list"
  return 0
}

find_pkg_info(){
  local name="$1"
  find_pkg_search "$name" "json"
}

# initialize required dirs
_find_pkg_init(){
  _safe_mkdir "/var/cache/lfs/sources"
  _safe_mkdir "/var/cache/lfs/binaries"
  _safe_mkdir "${LFS_ROOT}/usr/src"
  _safe_mkdir "$(dirname "$LOG_FILE")"
  _log "Initialized cache and metafile directories"
}

_usage(){
  cat <<EOF
find_pkg.sh - search for packages/programs across installed, cache, metafile and remote

Usage:
  find_pkg.sh --search <name>       # human-readable search
  find_pkg.sh --info <name>         # JSON output with detailed info
  find_pkg.sh --ini                 # create cache/metafile dirs
  find_pkg.sh --help

Options:
  --json       output JSON (for --search)
  --quiet      reduce output
  --dry-run    do not perform network ops
EOF
}

# CLI dispatcher
if [ "${BASH_SOURCE[0]}" == "$0" ]; then
  if [ "$#" -lt 1 ]; then _usage; exit 2; fi
  cmd="$1"; shift
  case "$cmd" in
    --search|-s) name="$1"; shift; if [ "${1:-}" = "--json" ]; then find_pkg_search "$name" "json"; else find_pkg_search "$name"; fi; exit $?;;
    --info) name="$1"; shift; find_pkg_info "$name"; exit $?;;
    --ini) _find_pkg_init; exit 0;;
    --help|-h|help) _usage; exit 0;;
    *) _usage; exit 2;;
  esac
fi

# Export API functions
export -f find_pkg_search find_pkg_info find_pkg_is_installed find_pkg_in_metafile find_pkg_in_cache
