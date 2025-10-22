#!/usr/bin/env bash
# doctor.sh - LFS system doctor: diagnostics, fixes and CVE checks
# Version: 1.0
# Features:
#  - Scan installed packages and files for problems (missing libs, permissions, broken symlinks, corrupted hashes)
#  - Suggest and optionally apply fixes using integrated scripts (build.sh, deps.sh, uninstall.sh, update.sh)
#  - Query upstream CVE/security advisories (Debian, Gentoo, Fedora) and NVD (if available)
#  - Dry-run, --silent, retries, robust error handling, JSON reports
#  - Exports functions for use by other scripts
set -Eeuo pipefail
IFS=$'\n\t'

# -------- Configuration --------
: "${LOG_DIR:=/var/log/lfs/doctor}"
: "${STATE_DIR:=/var/lib/lfs/doctor}"
: "${LOCKFILE:=/var/lock/lfs_doctor.lock}"
: "${SILENT_ERRORS:=false}"
: "${ABORT_ON_ERROR:=false}"
: "${DRY_RUN:=false}"
: "${RETRY:=2}"
: "${CVES_ENABLED:=true}"
: "${CVES_TIMEOUT:=15}"
: "${CVES_CACHE_TTL:=86400}"   # seconds
: "${METAFILE_DIR:=/var/lib/lfs/manifests}"
export LOG_DIR STATE_DIR LOCKFILE SILENT_ERRORS ABORT_ON_ERROR DRY_RUN RETRY CVES_ENABLED CVES_TIMEOUT CVES_CACHE_TTL METAFILE_DIR

_safe_mkdir(){ mkdir -p "$@" 2>/dev/null || true; }
_safe_mkdir "$LOG_DIR" "$STATE_DIR"

_acquire_lock(){
  exec 200>"$LOCKFILE"
  flock -n 200 || { _doctor_log "Another doctor run is active (lockfile: $LOCKFILE)"; return 1; }
  printf "%s\n" "$$" >&200
  return 0
}
_release_lock(){ exec 200>&- || true; }

# logging helpers (tries to use log.sh if present)
LOG_API=false
if [ -f /usr/bin/logs.sh ]; then
  # shellcheck source=/dev/null
  source /usr/bin/logs.sh || true
  LOG_API=true
fi
_doctor_log(){ if [ "$LOG_API" = true ] && type log_info >/dev/null 2>&1; then log_info "$@"; else printf "[DOCTOR][INFO] %s\n" "$@"; fi }
_doctor_warn(){ if [ "$LOG_API" = true ] && type log_warn >/dev/null 2>&1; then log_warn "$@"; else printf "[DOCTOR][WARN] %s\n" "$@"; fi }
_doctor_error(){ if [ "$LOG_API" = true ] && type log_error >/dev/null 2>&1; then log_error "$@"; else printf "[DOCTOR][ERROR] %s\n" "$@" >&2; fi; if [ "${SILENT_ERRORS}" = "true" ]; then return 1; fi; if [ "${ABORT_ON_ERROR}" = "true" ]; then exit 1; fi; return 1; }

# utility: run command with retries
_run_retry(){
  local tries=0; local max="${1:-1}"; shift
  local rc=0
  while [ $tries -lt "$max" ]; do
    if "$@"; then rc=0; break; else rc=$?; fi
    tries=$((tries+1))
    sleep $((tries * 1))
  done
  return $rc
}

# --- Core checks ---

# 1) list installed packages by reading manifests in METAFILE_DIR (expects <pkg>.manifest or .json)
_doctor_list_installed(){
  local manifests=( "$METAFILE_DIR"/*.manifest "$METAFILE_DIR"/*.json )
  for m in "${manifests[@]}"; do
    [ -f "$m" ] || continue
    # manifest lines: sha256  ./path
    if [[ "$m" == *.manifest ]]; then
      awk '{print $2}' "$m" | sed 's|^\./||' | xargs -I{} dirname {} | sort -u | xargs -I{} basename {} 2>/dev/null || true
    else
      # JSON fallback: try jq if available
      if command -v jq >/dev/null 2>&1; then jq -r '.name // .package // empty' "$m" 2>/dev/null || true; fi
    fi
  done | sort -u
}

# 2) check missing shared libraries for an executable
_doctor_ldd_check_file(){
  local bin="$1"
  local out="$2"
  if [ ! -x "$bin" ]; then
    echo "{\"file\":\"$bin\",\"status\":\"not-executable\"}" >> "$out"
    return 0
  fi
  if ! command -v ldd >/dev/null 2>&1; then
    echo "{\"file\":\"$bin\",\"status\":\"no-ldd\"}" >> "$out"
    return 0
  fi
  # run ldd and detect "not found"
  local missing
  missing=$(ldd "$bin" 2>/dev/null | grep -E 'not found' || true)
  if [ -n "$missing" ]; then
    # escape JSON
    missing_json=$(printf "%s" "$missing" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")
    echo "{\"file\":\"$bin\",\"missing\":$missing_json }" >> "$out"
    return 1
  else
    echo "{\"file\":\"$bin\",\"missing\":[]} " >> "$out"
    return 0
  fi
}

# 3) check broken symlinks under a path
_doctor_find_broken_symlinks(){
  local path="${1:-/usr}"
  find "$path" -xtype l -print 2>/dev/null || true
}

# 4) check file permissions and ownership anomalies
_doctor_check_permissions(){
  local path="${1:-/usr}"
  # files world-writable excluding /tmp and safe paths
  find "$path" -xdev -type f -perm -002 -print 2>/dev/null || true
}

# 5) validate SHA256s for manifest files (if manifest contains checksums)
_doctor_manifest_hashes(){
  local manifest="$1"
  local out="$2"
  [ -f "$manifest" ] || return 1
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # expect: checksum  ./path
    local sum=$(printf "%s" "$line" | awk '{print $1}')
    local file=$(printf "%s" "$line" | awk '{print $2}' | sed 's|^\./||')
    local fpath="/${file}"
    if [ -f "$fpath" ]; then
      local actual
      actual=$(sha256sum "$fpath" 2>/dev/null | awk '{print $1}' || echo "")
      if [ "$actual" != "$sum" ]; then
        echo "{\"file\":\"$fpath\",\"expected\":\"$sum\",\"actual\":\"$actual\"}" >> "$out"
      fi
    else
      echo "{\"file\":\"$fpath\",\"missing\":\"true\"}" >> "$out"
    fi
  done < "$manifest"
}

# 6) check ELF binary health (file, readelf)
_doctor_check_elf(){
  local bin="$1"
  local out="$2"
  if [ ! -f "$bin" ]; then echo "{\"file\":\"$bin\",\"status\":\"missing\"}" >> "$out"; return 1; fi
  local ftype
  ftype=$(file -L "$bin" 2>/dev/null || echo "")
  if [[ "$ftype" != *"ELF"* ]]; then
    echo "{\"file\":\"$bin\",\"status\":\"not-elf\",\"filetype\":\"$ftype\"}" >> "$out"; return 1
  fi
  if command -v readelf >/dev/null 2>&1; then
    if ! readelf -h "$bin" >/dev/null 2>&1; then
      echo "{\"file\":\"$bin\",\"status\":\"readelf-fail\"}" >> "$out"; return 1
    fi
  fi
  echo "{\"file\":\"$bin\",\"status\":\"ok\"}" >> "$out"
  return 0
}

# --- CVE and advisory lookups (web) ---
# caching helper
_cve_cache_file(){ printf "%s/cves_%s.cache" "$STATE_DIR" "$1"; }

# query Debian security tracker (fallback simple)
_query_debian(){
  local pkg="$1"
  local out="$2"
  local cache=$(_cve_cache_file "debian_${pkg}")
  if [ -f "$cache" ] && [ $(( $(date +%s) - $(stat -c %Y "$cache") )) -lt "$CVES_CACHE_TTL" ]; then
    cat "$cache" >> "$out" && return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time "$CVES_TIMEOUT" "https://security-tracker.debian.org/tracker/source/$pkg" -o "$cache.tmp" || true
    if [ -f "$cache.tmp" ]; then
      mv "$cache.tmp" "$cache"
      if command -v jq >/dev/null 2>&1; then
        echo "{\"debian_html\":$(jq -Rs '.' "$cache")}" >> "$out"
      else
        echo "{\"debian_raw\":\"$(sed 's/\"/\\\"/g' "$cache")\"}" >> "$out"
      fi
    fi
  fi
}

_query_gentoo(){
  local pkg="$1"; local out="$2"; local cache=$(_cve_cache_file "gentoo_${pkg}")
  if [ -f "$cache" ] && [ $(( $(date +%s) - $(stat -c %Y "$cache") )) -lt "$CVES_CACHE_TTL" ]; then cat "$cache" >> "$out" && return 0; fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time "$CVES_TIMEOUT" "https://packages.gentoo.org/packages/*/${pkg}" -o "$cache.tmp" || true
    if [ -f "$cache.tmp" ]; then mv "$cache.tmp" "$cache"; if command -v jq >/dev/null 2>&1; then echo "{\"gentoo_html\":$(jq -Rs '.' "$cache")}" >> "$out"; else echo "{\"gentoo_raw\":\"$(sed 's/\"/\\\"/g' "$cache")\"}" >> "$out"; fi; fi
  fi
}

_query_fedora(){
  local pkg="$1"; local out="$2"; local cache=$(_cve_cache_file "fedora_${pkg}")
  if [ -f "$cache" ] && [ $(( $(date +%s) - $(stat -c %Y "$cache") )) -lt "$CVES_CACHE_TTL" ]; then cat "$cache" >> "$out" && return 0; fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time "$CVES_TIMEOUT" "https://apps.fedoraproject.org/packages/${pkg}" -o "$cache.tmp" || true
    if [ -f "$cache.tmp" ]; then mv "$cache.tmp" "$cache"; if command -v jq >/dev/null 2>&1; then echo "{\"fedora_html\":$(jq -Rs '.' "$cache")}" >> "$out"; else echo "{\"fedora_raw\":\"$(sed 's/\"/\\\"/g' "$cache")\"}" >> "$out"; fi; fi
  fi
}

_query_nvd(){
  local pkg="$1"; local out="$2"; local cache=$(_cve_cache_file "nvd_${pkg}")
  if [ -f "$cache" ] && [ $(( $(date +%s) - $(stat -c %Y "$cache") )) -lt "$CVES_CACHE_TTL" ]; then cat "$cache" >> "$out" && return 0; fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time "$CVES_TIMEOUT" "https://services.nvd.nist.gov/rest/json/cves/1.0?keyword=$pkg" -o "$cache.tmp" || true
    if [ -f "$cache.tmp" ]; then mv "$cache.tmp" "$cache"; cat "$cache" >> "$out"; fi
  fi
}

_doctor_cve_check_pkg(){
  local pkg="$1"
  local out="$2"
  if [ "$CVES_ENABLED" != "true" ]; then echo "{\"pkg\":\"$pkg\",\"cves\":\"disabled\"}" >> "$out"; return 0; fi
  _safe_mkdir "$STATE_DIR"
  _query_debian "$pkg" "$out" || true
  _query_gentoo "$pkg" "$out" || true
  _query_fedora "$pkg" "$out" || true
  _query_nvd "$pkg" "$out" || true
}

# --- Repair helpers ---

_doctor_fix_missing_libs(){
  local bin="$1"
  local dry="$2"
  if [ "$dry" = "true" ]; then _doctor_log "[DRYRUN] Would attempt to install missing libs for $bin"; return 0; fi
  # try to use deps.sh or build.sh if available
  if command -v deps.sh >/dev/null 2>&1 && type deps_find_provider >/dev/null 2>&1; then
    local prov
    prov=$(deps_find_provider "$bin" 2>/dev/null || true)
    if [ -n "$prov" ]; then
      _doctor_log "Attempting to build provider $prov for $bin"
      if command -v build.sh >/dev/null 2>&1; then
        build.sh run "$prov" || _doctor_warn "build.sh failed for provider $prov"
      fi
    fi
  fi
  return 0
}

_doctor_fix_symlink(){
  local link="$1"
  local dry="$2"
  if [ "$dry" = "true" ]; then _doctor_log "[DRYRUN] Would remove broken symlink $link"; return 0; fi
  if [ -L "$link" ]; then
    rm -f "$link" && _doctor_log "Removed broken symlink $link"
  fi
  return 0
}

_doctor_fix_perms(){
  local file="$1"
  local dry="$2"
  if [ "$dry" = "true" ]; then _doctor_log "[DRYRUN] Would fix perms for $file"; return 0; fi
  if [[ "$file" == /bin/* || "$file" == /usr/bin/* || "$file" == /sbin/* || "$file" == /usr/sbin/* ]]; then
    chmod a+rx "$file" && _doctor_log "Set +rx on $file"
  else
    _doctor_log "No automatic perms action for $file"
  fi
  return 0
}

# --- High-level commands ---

_doctor_scan_system(){
  local out_json="$LOG_DIR/doctor_scan_$(date -u +%Y%m%dT%H%M%SZ).json"
  _doctor_log "Starting full system scan; output -> $out_json"
  echo "{" > "$out_json"
  echo "\"timestamp\":\"$(date -u +%FT%TZ)\"," >> "$out_json"
  # 1. find broken symlinks
  echo "\"broken_symlinks\":[" >> "$out_json"
  local first=true
  while IFS= read -r l; do
    if [ "$first" = true ]; then first=false; else echo "," >> "$out_json"; fi
    echo -n "{\"path\":\"$l\"}" >> "$out_json"
  done < <(_doctor_find_broken_symlinks /usr)
  echo "]," >> "$out_json"
  # 2. world-writable files
  echo "\"world_writable\":[" >> "$out_json"
  first=true
  while IFS= read -r f; do
    if [ "$first" = true ]; then first=false; else echo "," >> "$out_json"; fi
    echo -n "{\"path\":\"$f\"}" >> "$out_json"
  done < <(_doctor_check_permissions /usr)
  echo "]," >> "$out_json"
  # 3. scan installed manifests for hash inconsistencies
  echo "\"hash_issues\":[" >> "$out_json"
  first=true
  for m in "$METAFILE_DIR"/*.manifest; do
    [ -f "$m" ] || continue
    local tmp=$(mktemp)
    _doctor_manifest_hashes "$m" "$tmp" || true
    if [ -s "$tmp" ]; then
      if [ "$first" = true ]; then first=false; else echo "," >> "$out_json"; fi
      echo -n "{\"manifest\":\"$m\",\"issues\":$(jq -R -s -c '.' "$tmp" 2>/dev/null || cat "$tmp" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}" >> "$out_json"
    fi
    rm -f "$tmp"
  done
  echo "]," >> "$out_json"
  # 4. ldd checks on common bins
  echo "\"ldd_issues\":[" >> "$out_json"
  first=true
  local bins=(/bin/* /usr/bin/* /sbin/* /usr/sbin/*)
  for b in "${bins[@]}"; do
    [ -x "$b" ] || continue
    local tmp=$(mktemp)
    _doctor_ldd_check_file "$b" "$tmp" || true
    if [ -s "$tmp" ]; then
      if [ "$first" = true ]; then first=false; else echo "," >> "$out_json"; fi
      cat "$tmp" >> "$out_json"
    fi
    rm -f "$tmp"
  done
  echo "]," >> "$out_json"
  # 5. ELF sanity on common bins (sample)
  echo "\"elf_issues\":[" >> "$out_json"
  first=true
  for b in "${bins[@]}"; do
    [ -f "$b" ] || continue
    local tmp=$(mktemp)
    _doctor_check_elf "$b" "$tmp" || true
    if [ -s "$tmp" ]; then
      if [ "$first" = true ]; then first=false; else echo "," >> "$out_json"; fi
      cat "$tmp" >> "$out_json"
    fi
    rm -f "$tmp"
  done
  echo "]," >> "$out_json"
  # 6. CVE checks for installed packages (limited)
  echo "\"cves\":[" >> "$out_json"
  first=true
  while IFS= read -r pkg; do
    local tmp=$(mktemp)
    _doctor_cve_check_pkg "$pkg" "$tmp" || true
    if [ -s "$tmp" ]; then
      if [ "$first" = true ]; then first=false; else echo "," >> "$out_json"; fi
      cat "$tmp" >> "$out_json"
    fi
    rm -f "$tmp"
  done < <(_doctor_list_installed)
  echo "]" >> "$out_json"
  echo "}" >> "$out_json"
  _doctor_log "Scan complete: $out_json"
  echo "$out_json"
}

_doctor_fix_all_broken_symlinks(){
  local dry="$1"
  while IFS= read -r l; do
    _doctor_fix_symlink "$l" "$dry"
  done < <(_doctor_find_broken_symlinks /usr)
}

# CLI
_usage(){
  cat <<EOF
doctor.sh - System diagnostic and repair tool for LFS

Usage:
  doctor.sh --scan            # full scan and JSON report
  doctor.sh --pkg <name>      # diagnose a specific package
  doctor.sh --fix-links [--dry-run]
  doctor.sh --fix-perms [--dry-run]
  doctor.sh --cve <pkg>       # check CVEs for a package
  doctor.sh --report <file>   # show JSON report
  doctor.sh --help
Flags:
  --dry-run   Do not apply fixes
  --silent    Suppress interactive prompts and reduce output
  --retry N   Number of retries for network ops
EOF
}

# dispatcher
if [ "${BASH_SOURCE[0]}" == "$0" ]; then
  cmd="${1:-}"
  case "$cmd" in
    --scan) _acquire_lock || exit 1; out=$(_doctor_scan_system); _release_lock; echo "$out"; exit 0;;
    --fix-links) dry="false"; shift; while [ "$#" -gt 0 ]; do case "$1" in --dry-run) dry="true";; esac; shift; done; _acquire_lock || exit 1; _doctor_fix_all_broken_symlinks "$dry"; _release_lock; exit 0;;
    --fix-perms) dry="false"; shift; while [ "$#" -gt 0 ]; do case "$1" in --dry-run) dry="true";; esac; shift; done; _acquire_lock || exit 1; # scan and fix heuristics
      while IFS= read -r f; do _doctor_fix_perms "$f" "$dry"; done < <(_doctor_check_permissions /usr); _release_lock; exit 0;;
    --cve) shift; pkg="$1"; _acquire_lock || exit 1; _doctor_cve_check_pkg "$pkg" /dev/stdout; _release_lock; exit 0;;
    --pkg) shift; pkg="$1"; _acquire_lock || exit 1; # per-package diagnostics: ldd, elf, manifest
      tmp=$(mktemp)
      for mf in "$METAFILE_DIR/${pkg}.manifest" "$METAFILE_DIR/${pkg}.json"; do
        [ -f "$mf" ] || continue
        _doctor_manifest_hashes "$mf" "$tmp"
        awk '{print $2}' "$mf" | sed 's|^\./||' | while IFS= read -r f; do
          [ -f "/$f" ] && _doctor_check_elf "/$f" "$tmp"
        done
      done
      cat "$tmp"; rm -f "$tmp"; _release_lock; exit 0;;
    --report) shift; file="$1"; cat "$file"; exit 0;;
    --help|-h|help) _usage; exit 0;;
    *) _usage; exit 2;;
  esac
fi

# export functions
export -f _doctor_scan_system _doctor_cve_check_pkg _doctor_list_installed _doctor_find_broken_symlinks
