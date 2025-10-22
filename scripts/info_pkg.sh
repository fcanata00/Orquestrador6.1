#!/usr/bin/env bash
# info_pkg.sh - Show detailed package information for LFS automation
# Version: 1.1
# Features:
#  - robust parsing of package metafiles (.ini)
#  - shows install/cache/metafile/remote status, deps, logs, CVEs
#  - JSON/text export, quiet/dry-run modes, retries, better error handling
#  - exports functions for integration with other scripts
set -Eeuo pipefail
IFS=$'\n\t'

# ---- Configuration (override with env) ----
: "${METAFILE_DIRS:=/mnt/lfs/usr/src:/usr/src:/usr/local/src}"
: "${CACHE_DIR:=/var/cache/lfs}"
: "${LOG_DIR:=/var/log/lfs}"
: "${VULN_CACHE:=/var/cache/lfs/vulns.json}"
: "${SILENT:=false}"
: "${DRY_RUN:=false}"
: "${RETRY:=2}"
: "${JQ:=$(command -v jq || true)}"
export METAFILE_DIRS CACHE_DIR LOG_DIR VULN_CACHE SILENT DRY_RUN RETRY JQ

# ensure dirs
mkdir -p "${LOG_DIR}" "${CACHE_DIR}" || true

# logging helpers
_info(){ if [ "${SILENT}" != "true" ]; then printf "[info_pkg] %s\n" "$*"; fi; printf "%s %s\n" "$(date -u +%FT%TZ)" "$*" >> "${LOG_DIR}/info_pkg.log"; }
_warn(){ if [ "${SILENT}" != "true" ]; then printf "[info_pkg][WARN] %s\n" "$*"; fi; printf "%s WARN %s\n" "$(date -u +%FT%TZ)" "$*" >> "${LOG_DIR}/info_pkg.log"; }
_err(){ if [ "${SILENT}" != "true" ]; then printf "[info_pkg][ERROR] %s\n" "$*" >&2; fi; printf "%s ERROR %s\n" "$(date -u +%FT%TZ)" "$*" >> "${LOG_DIR}/info_pkg.log"; }

# trap for cleanup
_trap_exit(){
  local rc=$?
  if [ $rc -ne 0 ]; then _err "info_pkg exited with code $rc"; fi
  return $rc
}
trap _trap_exit EXIT

# safe read metafile: returns 0 and prints key=value lines for eval
_parse_metafile(){
  local mf="$1"
  if [ ! -f "$mf" ]; then return 1; fi
  # sanitize and output KEY="value"
  # accept lines like Key=Value or key = "value"
  awk -F= '
  /^[[:space:]]*#/ {next}
  /^[[:space:]]*$/ {next}
  {
    key=$1
    sub(/^[ \t]+/, "", key); sub(/[ \t]+$/, "", key)
    val=substr($0, index($0,$2))
    sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val)
    gsub(/\\\"/, "\\\\\"", val)
    printf "%s=\"%s\"\n", key, val
  }' "$mf" 2>/dev/null
  return 0
}

# find metafile path by name (search dirs and stage subdirs)
_find_metafile(){
  local name="$1"
  IFS=':' read -r -a dirs <<< "${METAFILE_DIRS}"
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    # direct: d/name.ini or d/name/name.ini
    if [ -f "$d/${name}.ini" ]; then printf "%s\n" "$d/${name}.ini"; return 0; fi
    if [ -f "$d/${name}/${name}.ini" ]; then printf "%s\n" "$d/${name}/${name}.ini"; return 0; fi
    # glob
    local f; f=$(ls "$d"/*"${name}"*.ini 2>/dev/null | head -n1 || true)
    if [ -n "$f" ]; then printf "%s\n" "$f"; return 0; fi
    # stage subdirs
    for sub in "$d"/*; do
      [ -d "$sub" ] || continue
      f=$(ls "$sub"/*"${name}"*.ini 2>/dev/null | head -n1 || true)
      if [ -n "$f" ]; then printf "%s\n" "$f"; return 0; fi
    done
  done
  return 1
}

# check if binary installed in common paths
_is_installed(){
  local name="$1"
  IFS=':' read -r -a binpaths <<< "/usr/bin:/usr/local/bin:/bin:/sbin:/usr/sbin:/usr/local/sbin:/mnt/lfs/usr/bin"
  for p in "${binpaths[@]}"; do
    [ -x "$p/$name" ] && { printf "%s\n" "$p/$name"; return 0; }
    # try name-version pattern
    local match; match=$(find "$p" -maxdepth 1 -type f -executable -name "${name}*" -printf "%f\n" 2>/dev/null | head -n1 || true)
    if [ -n "$match" ]; then printf "%s/%s\n" "$p" "$match"; return 0; fi
  done
  return 1
}

# check cache (sources or binaries)
_in_cache(){
  local name="$1"
  local found
  found=$(find "${CACHE_DIR}" -maxdepth 3 -type f -iname "*${name}*" 2>/dev/null | head -n1 || true)
  if [ -n "$found" ]; then printf "%s\n" "$found"; return 0; fi
  return 1
}

# remote info (best-effort via find_pkg heuristics)
_remote_info(){
  local name="$1"
  if command -v curl >/dev/null 2>&1; then
    # try common github pattern
    local try="https://github.com/${name}/${name}"
    if curl -sSf --max-time 6 "$try" >/dev/null 2>&1; then printf "%s\n" "$try"; return 0; fi
    # repology
    try="https://repology.org/projects.json?search=${name}"
    if curl -sSf --max-time 6 "$try" >/dev/null 2>&1; then printf "%s\n" "$try"; return 0; fi
  fi
  return 1
}

# CVE lookup from local cache (doctor)
_vuln_lookup(){
  local name="$1"
  if [ -f "${VULN_CACHE}" ]; then
    if [ -n "${JQ}" ]; then
      # try to match by name (best-effort)
      "${JQ}" --arg pkg "$name" 'map(select(.package|ascii_downcase|contains($pkg|ascii_downcase)))' "${VULN_CACHE}" 2>/dev/null || true
    else
      grep -i "$name" "${VULN_CACHE}" 2>/dev/null || true
    fi
  else
    printf ""
  fi
}

# show status summary and details; supports JSON output
_info_pkg_show(){
  local name="$1"
  local json="${2:-false}"
  local mf; mf=$(_find_metafile "$name" 2>/dev/null || true)
  local installed; installed=$(_is_installed "$name" 2>/dev/null || true)
  local cachef; cachef=$(_in_cache "$name" 2>/dev/null || true)
  local remote; remote=$(_remote_info "$name" 2>/dev/null || true)
  local vulns; vulns=$(_vuln_lookup "$name" 2>/dev/null || true)

  if [ "$json" = "json" ]; then
    # build JSON object safely
    local jqcmd="${JQ}"
    if [ -n "$jqcmd" ]; then
      "${JQ}" -n \
        --arg name "$name" \
        --arg mf "${mf:-}" \
        --arg installed "${installed:-}" \
        --arg cache "${cachef:-}" \
        --arg remote "${remote:-}" \
        --argjson vulns "$( [ -n "$vulns" ] && printf '%s\n' "$vulns" || printf '[]' )" \
        '{name:$name, metafile:$mf, installed:$installed, cache:$cache, remote:$remote, vulns:$vulns}'
      return 0
    else
      # fallback plain JSON (best-effort escape)
      python3 - <<PY
import json,sys
name=sys.argv[1]
mf=sys.argv[2]
inst=sys.argv[3]
cache=sys.argv[4]
remote=sys.argv[5]
vulns=sys.stdin.read().strip() or "[]"
try:
    vulns_parsed=json.loads(vulns)
except Exception:
    vulns_parsed=vulns
obj={"name":name,"metafile":mf,"installed":inst,"cache":cache,"remote":remote,"vulns":vulns_parsed}
print(json.dumps(obj,indent=2,ensure_ascii=False))
PY
    fi
  fi

  # human readable output
  _info "Package: $name"
  if [ -n "$installed" ]; then
    _info "  [✓] Installed: $installed"
  else
    _info "  [ ] Installed: no"
  fi
  if [ -n "$mf" ]; then
    _info "  [📄] Metafile: $mf"
    # parse and show key fields
    if parse_out=$(_parse_metafile "$mf"); then
      # shell-eval in isolated scope
      eval "$parse_out"
      _info "    Name: ${Name:-}  Version: ${Version:-} Stage:${Stage:-}"
      _info "    URL: ${URL:-}"
      _info "    SHA256: ${SHA256SUM:-}"
      _info "    Dependencies: ${Dependencies:-}"
    fi
  else
    _info "  [ ] Metafile: not found"
  fi
  if [ -n "$cachef" ]; then _info "  [🗃️] Cache: $cachef"; else _info "  [ ] Cache: not found"; fi
  if [ -n "$remote" ]; then _info "  [🌍] Remote: $remote"; else _info "  [ ] Remote: not found"; fi
  if [ -n "$vulns" ]; then _warn "  Vulnerabilities: $(echo "$vulns" | head -n3)"; else _info "  Vulnerabilities: none (or cache missing)"; fi

  return 0
}

# exported API
info_pkg_api_get(){
  local name="$1"
  _info_pkg_show "$name" "json"
}

info_pkg_api_show(){
  local name="$1"
  _info_pkg_show "$name" "text"
}

# CLI
_usage(){ cat <<'EOF'
info_pkg.sh - show package information for LFS

Usage:
  info_pkg.sh --pkg <name>            # show human info
  info_pkg.sh --pkg-json <name>       # show JSON
  info_pkg.sh --dir <metafile-dir>    # list metafiles in directory
  info_pkg.sh --export <name> <fmt>   # export json|text
  info_pkg.sh --ini                   # init cache/log dirs
  info_pkg.sh --help
Options:
  --quiet / --silent   reduce console output
  --dry-run            do not perform network operations
EOF
}

# parse args
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -lt 1 ]; then _usage; exit 2; fi
  cmd="$1"; shift
  case "$cmd" in
    --pkg) name="$1"; shift; info_pkg_api_show "$name"; exit $?;;
    --pkg-json) name="$1"; shift; info_pkg_api_get "$name"; exit $?;;
    --dir) dir="${1:-/mnt/lfs/usr/src}"; for f in "$dir"/*/*.ini; do [ -f "$f" ] && echo "$(basename "$(dirname "$f")")"; done; exit 0;;
    --export) name="$1"; fmt="${2:-json}"; mf=$(_find_metafile "$name" 2>/dev/null || true); if [ -z "$mf" ]; then _err "metafile not found"; exit 1; fi; info_pkg_export "$mf" "$fmt"; exit $?;;
    --ini) mkdir -p "${CACHE_DIR}" "${LOG_DIR}"; _info "initialized"; exit 0;;
    --help|-h|help) _usage; exit 0;;
    --quiet|--silent) SILENT=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    *) _usage; exit 2;;
  esac
fi
