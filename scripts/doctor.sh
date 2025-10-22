#!/usr/bin/env bash
# doctor.sh - Deep system verifier for LFS automation
# Version: 3.0
# CLI (strict):
#   doctor.sh --scan        # full scan (bins + fs) and aggregate
#   doctor.sh --bins        # only binaries checks
#   doctor.sh --fs          # only filesystem checks
#   doctor.sh --cve <pkg>   # query CVE cache for package (best-effort)
#   doctor.sh --help
# Options:
#   --quiet / --silent
#   --dry-run
set -Eeuo pipefail
IFS=$'\n\t'

: "${DOCTOR_LOG_DIR:=/var/log/lfs/doctor}"
: "${DOCTOR_STATE_DIR:=/var/lib/lfs/doctor}"
: "${DOCTOR_CACHE_DIR:=/var/cache/lfs/doctor}"
: "${DOCTOR_PARALLEL:=$(nproc 2>/dev/null || echo 2)}"
: "${DOCTOR_CVE_CACHE_TTL:=86400}"
: "${DOCTOR_TIMEOUT:=8}"
: "${DOCTOR_RETRIES:=3}"
: "${SILENT:=false}"
: "${DRY_RUN:=false}"
export DOCTOR_LOG_DIR DOCTOR_STATE_DIR DOCTOR_CACHE_DIR DOCTOR_PARALLEL DOCTOR_CVE_CACHE_TTL DOCTOR_TIMEOUT DOCTOR_RETRIES SILENT DRY_RUN

mkdir -p "$DOCTOR_LOG_DIR" "$DOCTOR_STATE_DIR" "$DOCTOR_CACHE_DIR"

_log(){ if [ "$SILENT" != "true" ]; then printf "[doctor] %s\n" "$*"; fi; printf "%s %s\n" "$(date -u +%FT%TZ)" "$*" >> "${DOCTOR_LOG_DIR}/doctor.log"; }
_warn(){ if [ "$SILENT" != "true" ]; then printf "[doctor][WARN] %s\n" "$*"; fi; printf "%s WARN %s\n" "$(date -u +%FT%TZ)" "$*" >> "${DOCTOR_LOG_DIR}/doctor.log"; }
_err(){ if [ "$SILENT" != "true" ]; then printf "[doctor][ERROR] %s\n" "$*" >&2; fi; printf "%s ERROR %s\n" "$(date -u +%FT%TZ)" "$*" >> "${DOCTOR_LOG_DIR}/doctor.log"; }

_has(){ command -v "$1" >/dev/null 2>&1; }
_safe_curl(){
  local url="$1" out="$2" tries=0 ok=1
  while [ $tries -lt "$DOCTOR_RETRIES" ]; do
    if [ "$DRY_RUN" = "true" ]; then _log "[DRY-RUN] curl $url -> $out"; return 0; fi
    if _has curl; then
      if curl -sS --max-time "$DOCTOR_TIMEOUT" -f "$url" -o "$out" 2>/dev/null; then ok=0; break; fi
    fi
    tries=$((tries+1))
    sleep $((tries*2))
  done
  return $ok
}

BIN_PATHS=(/usr/bin /bin /usr/sbin /sbin /usr/local/bin /opt /mnt/lfs/usr/bin)
_find_bins(){
  for p in "${BIN_PATHS[@]}"; do
    [ -d "$p" ] || continue
    find "$p" -type f -executable -print 2>/dev/null || true
  done
}

_find_broken_symlinks(){
  local root="${1:-/usr}"
  find "${root}" -xtype l -not -path "*/.git/*" -print 2>/dev/null || true
}
_find_world_writable(){
  local root="${1:-/usr}"
  find "${root}" -xdev -type f -perm -0002 -print 2>/dev/null || true
}
_find_setuid_setgid(){
  local root="${1:-/usr}"
  find "${root}" -xdev -type f \( -perm -4000 -o -perm -2000 \) -print 2>/dev/null || true
}

_check_ldd(){ local bin="$1"; if ! _has ldd; then echo "__no_ldd__"; return 1; fi; ldd "$bin" 2>&1 || true; }
_check_elf_header(){ local bin="$1"; if ! _has readelf; then echo "__no_readelf__"; return 1; fi; readelf -h "$bin" 2>/dev/null || echo "__readelf_fail__"; }
_extract_rpaths(){ local bin="$1"; readelf -d "$bin" 2>/dev/null | awk -F']' '/RPATH|RUNPATH/{gsub(/^[ \t]+/,""); print substr($0, index($0,$2))}' || true; }

_binary_worker(){
  local bin="$1"
  local miss header rpath missing_libs
  miss=$(_check_ldd "$bin" 2>/dev/null || true)
  header=$(_check_elf_header "$bin" 2>/dev/null || true)
  rpath=$(_extract_rpaths "$bin" 2>/dev/null || true)
  if printf "%s" "$miss" | grep -E 'not found' >/dev/null 2>&1; then
    missing_libs=$(printf "%s" "$miss" | awk '/not found/ {print $0}' | sed 's/"/\\"/g' | tr '\n' ';' )
  fi
  python3 - <<PY
import json,sys
bin=${bin!r}
miss=${missing_libs!r}
rpath=${rpath!r}
header=${header!r}
obj={"file":bin}
if miss:
    obj["missing_libs"]=miss
if rpath and rpath.strip():
    obj["rpath"]=rpath
obj["elf_header_ok"]=("ELF" in header)
print(json.dumps(obj, ensure_ascii=False))
PY
}

_export_workers(){
  export -f _check_ldd _check_elf_header _extract_rpaths _binary_worker _has
}

_scan_bins(){
  local out="${DOCTOR_STATE_DIR}/bins_$(date -u +%Y%m%dT%H%M%SZ).json"
  mkdir -p "$(dirname "$out")"
  _log "Scanning binaries (parallel=${DOCTOR_PARALLEL})..."
  mapfile -t bins < <(_find_bins)
  if [ "${#bins[@]}" -eq 0 ]; then _warn "No binaries found to scan"; echo "{}" > "$out"; echo "$out"; return 0; fi
  _export_workers
  echo "{" > "$out"
  echo "\"timestamp\":\"$(date -u +%FT%TZ)\"," >> "$out"
  echo "\"binaries\":[" >> "$out"
  local first=true
  printf "%s\n" "${bins[@]}" | xargs -P "$DOCTOR_PARALLEL" -n1 -I{} bash -c '_binary_worker "{}"' 2>/dev/null | while IFS= read -r line; do
    if [ -n "$line" ]; then
      if [ "$first" = true ]; then first=false; else echo "," >> "$out"; fi
      echo "$line" >> "$out"
    fi
  done
  echo "]" >> "$out"
  echo "}" >> "$out"
  _log "Binary scan written to $out"
  echo "$out"
}

_scan_fs(){
  local out="${DOCTOR_STATE_DIR}/fs_$(date -u +%Y%m%dT%H%M%SZ).json"
  mkdir -p "$(dirname "$out")"
  _log "Scanning filesystem..."
  python3 - <<PY > "$out"
import json,subprocess,os
res={'timestamp': "$('" + '$(date -u +%FT%TZ)' + "')"}
def run(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL).decode('utf-8').splitlines()
    except:
        return []
res['broken_symlinks']=[]
res['world_writable']=[]
res['setuid_setgid']=[]
for root in ['/usr','/lib','/lib64','/etc','/var']:
    if os.path.exists(root):
        out = run("find %s -xtype l -not -path '*/.git/*' -print 2>/dev/null || true" % root)
        res['broken_symlinks'] += out
out = run("find /usr -xdev -type f -perm -0002 -print 2>/dev/null || true")
res['world_writable'] += out
out = run(\"find /usr -xdev -type f \\( -perm -4000 -o -perm -2000 \\) -print 2>/dev/null || true\")
res['setuid_setgid'] += out
print(json.dumps(res, indent=2))
PY
  _log "Filesystem scan written to $out"
  echo "$out"
}

_cve_cache_file(){ local pkg="$1"; printf "%s/%s.json" "$DOCTOR_CACHE_DIR" "$(echo "$pkg" | sed 's/[^a-zA-Z0-9._-]/_/g')"; }
_query_circl(){
  local pkg="$1"
  local out="$(_cve_cache_file "$pkg")"
  if [ -f "$out" ]; then
    local mtime=$(stat -c %Y "$out" 2>/dev/null || echo 0)
    local now=$(date +%s)
    if [ $((now - mtime)) -lt "$DOCTOR_CVE_CACHE_TTL" ]; then cat "$out"; return 0; fi
  fi
  local url="https://cve.circl.lu/api/search/$pkg"
  if _safe_curl "$url" "$out"; then cat "$out"; return 0; fi
  return 1
}
_query_nvd(){ local pkg="$1"; _query_circl "$pkg" > "$(_cve_cache_file "nvd_$pkg")" 2>/dev/null || true; [ -f "$(_cve_cache_file "nvd_$pkg")" ] && cat "$(_cve_cache_file "nvd_$pkg")" && return 0 || return 1; }

_check_cve(){
  local pkg="$1"
  if _query_circl "$pkg" >/dev/null 2>&1; then _query_circl "$pkg"; return 0; fi
  if _query_nvd "$pkg" >/dev/null 2>&1; then _query_nvd "$pkg"; return 0; fi
  printf "[]"; return 1
}

_aggregate(){
  local bins_json="$1" fs_json="$2"
  local agg="${DOCTOR_LOG_DIR}/doctor_agg_$(date -u +%Y%m%dT%H%M%SZ).json"
  python3 - <<PY > "$agg"
import json,sys
try: b=json.load(open("$bins_json"))
except: b={}
try: f=json.load(open("$fs_json"))
except: f={}
print(json.dumps({'bins':b,'fs':f}, indent=2, ensure_ascii=False))
PY
  _log "Aggregated report written to $agg"
  echo "$agg"
}

_cmd_scan(){ local bins_file fs_file agg; bins_file=$(_scan_bins) || true; fs_file=$(_scan_fs) || true; agg=$(_aggregate "$bins_file" "$fs_file") || true; _log "Full scan complete. Aggregate: $agg"; printf "%s\n" "$agg"; }
_cmd_bins(){ _scan_bins; }
_cmd_fs(){ _scan_fs; }
_cmd_cve(){ local pkg="$1"; if [ -z "$pkg" ]; then _err "Package name required for --cve"; return 2; fi; _log "Querying CVE cache for package: $pkg"; local out=$(_cve_cache_file "$pkg"); if [ -f "$out" ]; then local mtime=$(stat -c %Y "$out" 2>/dev/null || echo 0); local now=$(date +%s); if [ $((now - mtime)) -lt "$DOCTOR_CVE_CACHE_TTL" ]; then _log "Using cached CVE data: $out"; cat "$out"; return 0; fi; fi; _check_cve "$pkg" | tee "$out"; return 0; }

_usage(){ cat <<'EOF'
doctor.sh - deep verifier for LFS automation

Usage:
  doctor.sh --scan        # full scan (bins + fs) and aggregate
  doctor.sh --bins        # only binaries checks
  doctor.sh --fs          # only filesystem checks
  doctor.sh --cve <pkg>   # query CVE cache for package (best-effort)
  doctor.sh --help

Options:
  --quiet / --silent   run without console output (logs only)
  --dry-run            simulate network actions and heavy ops
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -lt 1 ]; then _usage; exit 2; fi
  ARGS=("$@")
  i=0
  while [ $i -lt ${#ARGS[@]} ]; do
    a="${ARGS[$i]}"
    case "$a" in
      --quiet|--silent) SILENT=true; ARGS=("${ARGS[@]:0:$i}" "${ARGS[@]:$((i+1))}"); continue;;
      --dry-run) DRY_RUN=true; ARGS=("${ARGS[@]:0:$i}" "${ARGS[@]:$((i+1))}"); continue;;
      *) i=$((i+1));;
    esac
  done
  set -- "${ARGS[@]}"
  cmd="$1"; shift || true
  case "$cmd" in
    --scan) _cmd_scan; exit $?;;
    --bins) _cmd_bins; exit $?;;
    --fs) _cmd_fs; exit $?;;
    --cve) _cmd_cve "$1"; exit $?;;
    --help|-h) _usage; exit 0;;
    *) _usage; exit 2;;
  esac
fi
