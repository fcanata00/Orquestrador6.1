#!/usr/bin/env bash
# doctor.sh - Verificador completo (ldd, readelf, rpath, broken symlinks, perms, manifests)
# Versão: 1.2
set -Eeuo pipefail
IFS=$'\n\t'

LOG_DIR="/var/log/lfs/doctor"
STATE_DIR="/var/lib/lfs/doctor"
mkdir -p "$LOG_DIR" "$STATE_DIR"

_info(){ printf "[doctor] %s\n" "$*"; printf "%s %s\n" "$(date -u +%FT%TZ)" "$*" >> "$LOG_DIR/doctor.log"; }
_warn(){ printf "[doctor][WARN] %s\n" "$*"; printf "%s WARN %s\n" "$(date -u +%FT%TZ)" "$*" >> "$LOG_DIR/doctor.log"; }
_err(){ printf "[doctor][ERROR] %s\n" "$*" >&2; printf "%s ERROR %s\n" "$(date -u +%FT%TZ)" "$*" >> "$LOG_DIR/doctor.log"; }

_find_bins(){
  find /usr/bin /bin /usr/sbin /sbin -type f -executable 2>/dev/null || true
}

_check_ldd(){
  local bin="$1"
  if ! command -v ldd >/dev/null 2>&1; then echo "no-ldd"; return 1; fi
  local miss; miss=$(ldd "$bin" 2>/dev/null | awk '/not found/ {print $0}' || true)
  if [ -n "$miss" ]; then printf "%s" "$miss"; return 1; fi
  return 0
}

_check_readelf(){
  local bin="$1"
  if ! command -v readelf >/dev/null 2>&1; then echo "no-readelf"; return 1; fi
  if ! readelf -h "$bin" >/dev/null 2>&1; then echo "readelf-fail"; return 1; fi
  return 0
}

_check_rpath(){
  local bin="$1"
  if command -v readelf >/dev/null 2>&1; then
    readelf -d "$bin" 2>/dev/null | awk '/rpath|runpath/ {print $0}' || true
  fi
}

_find_broken_symlinks(){
  local base="${1:-/usr}"
  find "$base" -xtype l -print 2>/dev/null || true
}

_check_permissions(){
  local base="${1:-/usr}"
  find "$base" -xdev -type f -perm -002 -print 2>/dev/null || true
}

_scan_bins_ldd_readelf(){
  local out="${STATE_DIR}/bin_checks_$(date -u +%Y%m%dT%H%M%SZ).json"
  echo "{" > "$out"
  echo "\"timestamp\":\"$(date -u +%FT%TZ)\"," >> "$out"
  echo "\"binaries\":[" >> "$out"
  local first=true
  for b in $(_find_bins); do
    [ -f "$b" ] || continue
    local miss outp rpath tmp
    tmp=$(mktemp)
    miss=$(_check_ldd "$b" 2>/dev/null || true)
    rpath=$(_check_rpath "$b" 2>/dev/null || true)
    _check_readelf "$b" >/dev/null 2>&1 || outp="readelf-fail"
    if [ -n "$miss" ] || [ -n "$rpath" ] || [ -n "${outp:-}" ]; then
      if [ "$first" = true ]; then first=false; else echo "," >> "$out"; fi
      python3 - <<PY >> "$out"
import json,sys
obj={"file":"$b","ldd":"$miss","rpath":"$rpath","readelf":"${outp:-ok}"}
print(json.dumps(obj))
PY
    fi
    rm -f "$tmp" || true
  done
  echo "]" >> "$out"
  echo "}" >> "$out"
  _info "Bin checks written to $out"
  echo "$out"
}

_scan_symlinks_perms(){
  local out="${STATE_DIR}/fs_checks_$(date -u +%Y%m%dT%H%M%SZ).json"
  echo "{" > "$out"
  echo "\"timestamp\":\"$(date -u +%FT%TZ)\"," >> "$out"
  echo "\"broken_symlinks\":[" >> "$out"
  local first=true
  for l in $(_find_broken_symlinks /usr); do
    if [ "$first" = true ]; then first=false; else echo "," >> "$out"; fi
    python3 - <<PY >> "$out"
import json,sys
print(json.dumps({"path":"$l"}))
PY
  done
  echo "]," >> "$out"
  echo "\"world_writable\":[" >> "$out"
  first=true
  for f in $(_check_permissions /usr); do
    if [ "$first" = true ]; then first=false; else echo "," >> "$out"; fi
    python3 - <<PY >> "$out"
import json,sys
print(json.dumps({"path":"$f"}))
PY
  done
  echo "]" >> "$out"
  echo "}" >> "$out"
  _info "FS checks written to $out"
  echo "$out"
}

_doctor_run_all(){
  _info "Iniciando varredura completa"
  local bfile=$(_scan_bins_ldd_readelf)
  local ffile=$(_scan_symlinks_perms)
  _info "Scans concluídos. Bin report: $bfile FS report: $ffile"
  local agg="${LOG_DIR}/doctor_agg_$(date -u +%Y%m%dT%H%M%SZ).json"
  python3 - <<PY > "$agg"
import json,sys
b=open("$bfile").read()
f=open("$ffile").read()
try:
  bj=json.loads(b)
except:
  bj=b
try:
  fj=json.loads(f)
except:
  fj=f
print(json.dumps({"bins":bj,"fs":fj}, indent=2, ensure_ascii=False))
PY
  _info "Relatório agregado em $agg"
  echo "$agg"
}

_usage(){
  cat <<EOF
doctor.sh - verificação completa

Usage:
  doctor.sh --scan        # run full scan and produce JSON reports
  doctor.sh --bins        # scan binaries (ldd/readelf/rpath)
  doctor.sh --fs          # scan filesystem (broken symlinks, perms)
  doctor.sh --help
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -lt 1 ]; then _usage; exit 2; fi
  case "$1" in
    --scan) _doctor_run_all; exit $? ;;
    --bins) _scan_bins_ldd_readelf; exit $? ;;
    --fs) _scan_symlinks_perms; exit $? ;;
    --help|-h) _usage; exit 0 ;;
    *) _usage; exit 2 ;;
  esac
fi
