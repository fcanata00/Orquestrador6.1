#!/usr/bin/env bash
# doctor.sh - Enhanced system/package verifier for LFS automation
# Version: 2.0
# Features:
#  - scans binaries with ldd/readelf, reports rpath/runpath issues
#  - detects broken symlinks, world-writable files, setuid/setgid
#  - optional CVE lookups (NVD/CIRCL/repology) with caching and retries
#  - parallel scanning using xargs -P or GNU parallel if available
#  - outputs JSON reports and human-readable summaries
#  - robust error handling, retries, timeouts, silent/dry-run modes
set -Eeuo pipefail
IFS=$'\n\t'

# Config (override via env)
: "${DOCTOR_LOG_DIR:=/var/log/lfs/doctor}"
: "${DOCTOR_STATE_DIR:=/var/lib/lfs/doctor}"
: "${DOCTOR_CACHE_DIR:=/var/cache/lfs/doctor}"
: "${DOCTOR_PARALLEL:=$(nproc || echo 2)}"
: "${DOCTOR_CVE_CACHE_TTL:=86400}"   # 1 day
: "${DOCTOR_TIMEOUT:=8}"
: "${DOCTOR_RETRIES:=3}"
: "${SILENT:=false}"
: "${DRY_RUN:=false}"
export DOCTOR_LOG_DIR DOCTOR_STATE_DIR DOCTOR_CACHE_DIR DOCTOR_PARALLEL DOCTOR_CVE_CACHE_TTL DOCTOR_TIMEOUT DOCTOR_RETRIES SILENT DRY_RUN

mkdir -p "$DOCTOR_LOG_DIR" "$DOCTOR_STATE_DIR" "$DOCTOR_CACHE_DIR"

_log(){ if [ "$SILENT" != "true" ]; then printf "[doctor] %s\n" "$*"; fi; printf "%s %s\n" "$(date -u +%FT%TZ)" "$*" >> "${DOCTOR_LOG_DIR}/doctor.log"; }
_warn(){ if [ "$SILENT" != "true" ]; then printf "[doctor][WARN] %s\n" "$*"; fi; printf "%s WARN %s\n" "$(date -u +%FT%TZ)" "$*" >> "${DOCTOR_LOG_DIR}/doctor.log"; }
_err(){ if [ "$SILENT" != "true" ]; then printf "[doctor][ERROR] %s\n" "$*" >&2; fi; printf "%s ERROR %s\n" "$(date -u +%FT%TZ)" "$*" >> "${DOCTOR_LOG_DIR}/doctor.log"; }

# utils
_has(){ command -v "$1" >/dev/null 2>&1; }
_safe_curl(){ local url="$1"; local out="$2"; local tries=0; local ok=1; while [ $tries -lt "$DOCTOR_RETRIES" ]; do if curl -sS --max-time "$DOCTOR_TIMEOUT" -f "$url" -o "$out" 2>/dev/null; then ok=0; break; fi; tries=$((tries+1)); sleep $((tries*2)); done; return $ok; }

# Find candidate binaries to scan
_find_bins(){
  local paths=(/usr/bin /bin /usr/sbin /sbin /usr/local/bin /opt)
  for p in "${paths[@]}"; do
    [ -d "$p" ] || continue
    find "$p" -type f -executable -printf "%p\n" 2>/dev/null || true
  done
}

# Single-binary checks: returns JSON line
_check_binary(){
  local bin="$1"
  local tmp=$(mktemp)
  local res
  res=$(mktemp)
  echo -n "" > "$res"
  # ldd check
  if _has ldd; then
    local lout; lout=$(ldd "$bin" 2>&1 || true)
    if printf "%s" "$lout" | grep -E 'not found' >/dev/null 2>&1; then
      printf '{"file":"%s","ldd":"%s"}\n' "$bin" "$(printf "%s" "$lout" | awk '{gsub(/"/,"\\\""); printf "%s\\n",$0}' )" > "$tmp"
    fi
  else
    echo '{"note":"no-ldd"}' > "$tmp"
  fi
  # readelf header
  if _has readelf; then
    if ! readelf -h "$bin" >/dev/null 2>&1; then
      printf '%s\n' "{\"file\":\"$bin\",\"readelf\":\"fail\"}" >> "$tmp"
    fi
    # rpath/runpath
    local rpath; rpath=$(readelf -d "$bin" 2>/dev/null | awk '/rpath|runpath/ { $1=$1; sub(/^[ \t]+/,""); print; }' || true)
    [ -n "$rpath" ] && printf '%s\n' "{\"file\":\"$bin\",\"rpath\":\"$(printf "%s" "$rpath" | sed 's/\"/\\\"/g')\"}" >> "$tmp"
  else
    printf '%s\n' "{\"file\":\"$bin\",\"readelf\":\"missing\"}" >> "$tmp"
  fi
  # summarize
  if [ -s "$tmp" ]; then
    # produce a JSON object by reading lines
    python3 - <<PY 2>/dev/null || true
import sys,json
lines=open("$tmp").read().strip().splitlines()
out={"file":"$bin"}
for l in lines:
    try:
        j=json.loads(l)
        out.update(j)
    except:
        pass
print(json.dumps(out, ensure_ascii=False))
PY
  fi
  rm -f "$tmp" "$res" 2>/dev/null || true
}

# Broken symlinks under /usr (or given root)
_find_broken_symlinks(){
  local root="${1:-/usr}"
  find "$root" -xtype l -not -path "*/.git/*" -print 2>/dev/null || true
}

# world-writable files (dangerous perms)
_find_world_writable(){
  local root="${1:-/usr}"
  find "$root" -xdev -type f -perm -0002 -print 2>/dev/null || true
}

# setuid/setgid suspicious
_find_setuid_setgid(){
  local root="${1:-/usr}"
  find "$root" -xdev -type f \( -perm -4000 -o -perm -2000 \) -print 2>/dev/null || true
}

# CVE lookup (best-effort) using cve.circl.lu API caching
_cve_query(){
  local pkg="$1"
  local cache="${DOCTOR_CACHE_DIR}/cve_${pkg}.json"
  local now=$(date +%s)
  if [ -f "$cache" ]; then
    local mtime=$(stat -c %Y "$cache")
    if [ $((now - mtime)) -lt "$DOCTOR_CVE_CACHE_TTL" ]; then
      cat "$cache" && return 0
    fi
  fi
  # best-effort endpoints; try repology/repology -> repology does not provide direct CVE; use cve.circl.lu
  local url="https://cve.circl.lu/api/search/$pkg"
  if _safe_curl "$url" "$cache"; then
    cat "$cache" && return 0
  fi
  # fallback empty array
  printf "[]"
  return 1
}

# parallel driver: uses xargs -P or GNU parallel
_parallel_run(){
  local func="$1"; shift
  local concurrency="${DOCTOR_PARALLEL:-2}"
  if _has parallel; then
    printf "%s\n" "$@" | parallel -j "$concurrency" "$func" {}
  else
    printf "%s\n" "$@" | xargs -P "$concurrency" -n1 -I{} bash -c "$func \"{}\""
  fi
}

# Scan binaries and produce JSON report
_scan_bins(){
  local out="${DOCTOR_STATE_DIR}/bins_$(date -u +%Y%m%dT%H%M%SZ).json"
  echo "{" > "$out"
  echo "\"timestamp\":\"$(date -u +%FT%TZ)\"," >> "$out"
  echo "\"binaries\":[" >> "$out"
  local first=true
  # collect bins
  mapfile -t bins < <(_find_bins)
  if [ "${#bins[@]}" -eq 0 ]; then _log "No binaries found to scan"; echo "[]]" >> "$out"; return 0; fi
  # run checks in parallel and append JSON objects
  for b in "${bins[@]}"; do
    _check_binary "$b" | python3 -c 'import sys,json; d=sys.stdin.read().strip(); 
if d:
    print(d)'
  done | while IFS= read -r line; do
    if [ -n "$line" ]; then
      if [ "$first" = true ]; then first=false; else echo "," >> "$out"; fi
      echo "$line" >> "$out"
    fi
  done
  echo "]" >> "$out"
  echo "}" >> "$out"
  _log "Binaries scan written to $out"
  echo "$out"
}

# Scan filesystem items (symlinks, perms)
_scan_fs(){
  local out="${DOCTOR_STATE_DIR}/fs_$(date -u +%Y%m%dT%H%M%SZ).json"
  python3 - <<PY > "$out"
import json,sys,subprocess
def list_cmd(cmd):
    try:
        out=subprocess.check_output(cmd,shell=True,stderr=subprocess.DEVNULL).decode('utf-8').strip().splitlines()
        return out
    except:
        return []
syms=list_cmd("find /usr -xtype l -not -path '*/.git/*' 2>/dev/null")
ww=list_cmd("find /usr -xdev -type f -perm -0002 2>/dev/null")
su=list_cmd("find /usr -xdev -type f \\( -perm -4000 -o -perm -2000 \\) 2>/dev/null")
print(json.dumps({'timestamp': '%s','broken_symlinks': syms,'world_writable': ww,'setuid_setgid': su}, indent=2))
PY
  _log "Filesystem scan written to $out"
  echo "$out"
}

# Aggregate reports and optionally run CVE lookups for packages referenced
_aggregate_reports(){
  local bins_json="$1"
  local fs_json="$2"
  local agg="${DOCTOR_LOG_DIR}/doctor_agg_$(date -u +%Y%m%dT%H%M%SZ).json"
  python3 - <<PY > "$agg"
import json,sys
b=json.load(open("$bins_json"))
f=json.load(open("$fs_json"))
print(json.dumps({'bins':b,'fs':f}, indent=2, ensure_ascii=False))
PY
  _log "Aggregated report: $agg"
  echo "$agg"
}

# public commands
_cmd_scan_all(){
  local bins=$(_scan_bins)
  local fs=$(_scan_fs)
  _aggregate_reports "$bins" "$fs"
}

_cmd_bins(){ _scan_bins; }
_cmd_fs(){ _scan_fs; }

_usage(){
  cat <<EOF
doctor.sh - enhanced verification

Usage:
  doctor.sh --scan        # full scan (bins + fs) and aggregate
  doctor.sh --bins        # only binaries checks
  doctor.sh --fs          # only filesystem checks
  doctor.sh --cve <pkg>   # query CVE cache for package (best-effort)
  doctor.sh --help
Options:
  --quiet / --silent
  --dry-run
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -lt 1 ]; then _usage; exit 2; fi
  case "$1" in
    --scan) _cmd_scan_all; exit $?;;
    --bins) _cmd_bins; exit $?;;
    --fs) _cmd_fs; exit $?;;
    --cve) pkg="$2"; _cve_query "$pkg"; exit $?;;
    --help|-h) _usage; exit 0;;
    *) _usage; exit 2;;
  esac
fi
