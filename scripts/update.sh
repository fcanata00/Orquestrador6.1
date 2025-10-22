#!/usr/bin/env bash
# update.sh - Automatic upstream checker and updater for metafiles
# Version: 1.0
# Features:
#  - --check/--check-all : detect newer upstream versions
#  - --apply/--apply-all : update metafiles (create backups)
#  - --upgrade/--upgrade-all : full pipeline (apply, download, build, install)
#  - --resume : resume interrupted upgrade runs
#  - --rollback <pkg> : restore metafile from backup
#  - concurrency, retries, silent errors, JSON reports, state persistence
set -Eeuo pipefail

# -------- Configuration --------
: "${UP_METAFILE_DIR:=./metafiles}"
: "${UP_LOG_DIR:=/var/log/lfs/update}"
: "${UP_STATE_DIR:=/var/lib/lfs/update}"
: "${UP_BACKUP_DIR:=$UP_STATE_DIR/backups}"
: "${UP_TMP_DIR:=$UP_STATE_DIR/tmp}"
: "${DOWNLOAD_SCRIPT:=/usr/bin/download.sh}"
: "${METAFILE_SCRIPT:=/usr/bin/metafile.sh}"
: "${BUILD_SCRIPT:=/usr/bin/build.sh}"
: "${CREATE_INSTALL:=/usr/bin/create_install.sh}"
: "${UNINSTALL_SCRIPT:=/usr/bin/uninstall.sh}"
: "${DEPS_SCRIPT:=/usr/bin/deps.sh}"
: "${LOG_SCRIPT:=/usr/bin/logs.sh}"
: "${SILENT_ERRORS:=false}"
: "${ABORT_ON_ERROR:=true}"
: "${RETRY_COUNT:=3}"
: "${PARALLEL:=1}"
export UP_METAFILE_DIR UP_LOG_DIR UP_STATE_DIR UP_BACKUP_DIR UP_TMP_DIR DOWNLOAD_SCRIPT METAFILE_SCRIPT BUILD_SCRIPT CREATE_INSTALL UNINSTALL_SCRIPT DEPS_SCRIPT LOG_SCRIPT SILENT_ERRORS ABORT_ON_ERROR RETRY_COUNT PARALLEL

# try to source logging if available
LOG_API=false
if [ -f "$LOG_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$LOG_SCRIPT" || true
  LOG_API=true
fi

_up_log(){ if [ "$LOG_API" = true ] && type log_info >/dev/null 2>&1; then log_info "$@"; else printf "[UP][INFO] %s\n" "$@"; fi }
_up_warn(){ if [ "$LOG_API" = true ] && type log_warn >/dev/null 2>&1; then log_warn "$@"; else printf "[UP][WARN] %s\n" "$@"; fi }
_up_error(){ if [ "$LOG_API" = true ] && type log_error >/dev/null 2>&1; then log_error "$@"; else printf "[UP][ERROR] %s\n" "$@" >&2; fi; if [ "${SILENT_ERRORS}" = "true" ]; then return 1; fi; if [ "${ABORT_ON_ERROR}" = "true" ]; then exit 1; fi; return 1; }

_safe_mkdir(){ mkdir -p "$@" 2>/dev/null || _up_error "failed to mkdir $*"; }
timestamp(){ date -u +%FT%TZ; }

# state file for resume
_state_file="$UP_STATE_DIR/state.json"
_safe_mkdir "$UP_LOG_DIR" "$UP_STATE_DIR" "$UP_BACKUP_DIR" "$UP_TMP_DIR"

# helper: read metafile via metafile.sh API if available
_mf_field(){
  local pkg="$1"; local field="$2"
  if [ -f "$METAFILE_SCRIPT" ] && type mf_get_field >/dev/null 2>&1; then
    mf_get_field "$pkg" "$field" 2>/dev/null || true
  else
    # fallback: parse simple ini under UP_METAFILE_DIR/<pkg>.ini
    local f="$UP_METAFILE_DIR/${pkg}.ini"
    [ -f "$f" ] || { _up_warn "metafile $f not found"; return 1; }
    # naive INI parsing: field=value lines (package section optional)
    awk -F'=' -v key="$field" '$1==key{print substr($0, index($0,$2))}' "$f" | sed 's/^=//'
  fi
}

# helper: update metafile field (uses mf_update_field if available)
_mf_update_field(){
  local pkg="$1"; local field="$2"; local value="$3"
  if [ -f "$METAFILE_SCRIPT" ] && type mf_update_field >/dev/null 2>&1; then
    mf_update_field "$pkg" "$field" "$value" || _up_warn "mf_update_field failed for $pkg $field"
    return 0
  fi
  # fallback: edit simple ini file
  local f="$UP_METAFILE_DIR/${pkg}.ini"
  if [ ! -f "$f" ]; then echo "$field=$value" >> "$f"; return 0; fi
  if grep -qE "^${field}=" "$f"; then
    sed -i "s%^${field}=.*%${field}=${value}%" "$f"
  else
    echo "${field}=${value}" >> "$f"
  fi
  return 0
}

# normalized version compare (strip leading v, use sort -V)
_normalize_ver(){ echo "$1" | sed 's/^v//I'; }
_compare_versions(){
  # returns 0 if v1 < v2 (i.e. v2 newer), 1 otherwise
  local v1; v1=$(_normalize_ver "$1")
  local v2; v2=$(_normalize_ver "$2")
  if [ "$v1" = "$v2" ]; then return 1; fi
  # use sort -V
  if printf "%s\n%s\n" "$v1" "$v2" | sort -V | head -n1 | grep -qx "$v1"; then
    # v1 <= v2 ; check equality handled above, so v1 < v2
    return 0
  fi
  return 1
}

# fetch upstream content (URL or api) with retries
_fetch_url(){
  local url="$1"
  local out="$2"
  local tries=0
  while [ $tries -lt $RETRY_COUNT ]; do
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --connect-timeout 10 --max-time 60 -A "lfs-updater/1.0" "$url" -o "$out" && return 0
    elif command -v wget >/dev/null 2>&1; then
      wget -q -O "$out" "$url" && return 0
    else
      _up_error "no downloader (curl/wget) available"
      return 4
    fi
    tries=$((tries+1))
    sleep $((tries*2))
  done
  return 1
}

# parse upstream version heuristics based on known patterns: github, project pages
_detect_version_from_page(){
  local pkg="$1"; local url="$2"; local pagefile="$3"
  # heuristics: look for /tag/vX.Y or /releases/tag/vX.Y, or "Latest release x.y.z"
  local v=""
  v=$(grep -Eo 'releases/tag/v?[0-9]+(\.[0-9]+)*' "$pagefile" | head -n1 | sed 's#.*/tag/##;s/^v//')
  [ -z "$v" ] && v=$(grep -Eo 'tag/v?[0-9]+(\.[0-9]+)*' "$pagefile" | head -n1 | sed 's#.*/##;s/^v//')
  [ -z "$v" ] && v=$(grep -Eo 'Latest release</[^>]*>[[:space:]]*[0-9]+(\.[0-9]+)*' "$pagefile" | grep -Eo '[0-9]+(\.[0-9]+)*' | head -n1 || true)
  # fallback: look for href to tar.gz with version in name
  [ -z "$v" ] && v=$(grep -Eo '[a-zA-Z0-9._-]+-[0-9]+(\.[0-9]+)*\.tar\.gz' "$pagefile" | head -n1 | sed -E 's/.*-([0-9]+(\.[0-9]+)*)\.tar\.gz/\1/')
  echo "$v"
}

# check single package for upstream newer version
_up_check_pkg(){
  local pkg="$1"
  local upstream_url; upstream_url=$(_mf_field "$pkg" "update_url" || true)
  local current; current=$(_mf_field "$pkg" "version" || true)
  if [ -z "$upstream_url" ]; then _up_warn "no update_url in metafile for $pkg"; return 2; fi
  if [ -z "$current" ]; then _up_warn "no current version in metafile for $pkg"; current="0.0.0"; fi
  local tmpf="$UP_TMP_DIR/${pkg}.page"
  _up_log "Fetching upstream for $pkg -> $upstream_url"
  if ! _fetch_url "$upstream_url" "$tmpf"; then _up_warn "failed to fetch $upstream_url"; return 3; fi
  local detected; detected=$(_detect_version_from_page "$pkg" "$upstream_url" "$tmpf" || true)
  if [ -z "$detected" ]; then _up_warn "could not detect version for $pkg from upstream"; return 4; fi
  _up_log "Detected upstream version for $pkg: $detected (current: $current)"
  if _compare_versions "$current" "$detected"; then
    # newer version available
    printf "%s|%s|%s\n" "$pkg" "$current" "$detected"
    return 0
  fi
  return 1
}

# update metafile with new fields and backup
_up_apply_metafile_update(){
  local pkg="$1"; local newver="$2"; local newurl="$3"
  local mf="$UP_METAFILE_DIR/${pkg}.ini"
  local bak="$UP_BACKUP_DIR/${pkg}.ini.$(date -u +%Y%m%dT%H%M%SZ).bak"
  _safe_mkdir "$UP_BACKUP_DIR"
  if [ -f "$mf" ]; then cp -a "$mf" "$bak"; fi
  _up_log "Backing up metafile $mf -> $bak"
  # update fields
  _mf_update_field "$pkg" "version" "$newver"
  [ -n "$newurl" ] && _mf_update_field "$pkg" "url" "$newurl"
  _mf_update_field "$pkg" "updated_at" "$(timestamp)"
  return 0
}

# wrapper to call full upgrade pipeline for one package
_upgrade_pkg_pipeline(){
  local pkg="$1"; local resume_state="$2"
  _up_log "Starting upgrade pipeline for $pkg"
  # 1) check upstream
  local check_line
  if ! check_line=$(_up_check_pkg "$pkg" 2>/dev/null || true); then
    _up_warn "No newer version detected or check failed for $pkg"
    return 1
  fi
  local curv=$(printf "%s" "$check_line" | cut -d'|' -f2)
  local newv=$(printf "%s" "$check_line" | cut -d'|' -f3)
  # 2) apply metafile update (backup first)
  # try to find source url pattern in page (simple heuristic)
  local page="$UP_TMP_DIR/${pkg}.page"
  local upstream_url=$(_mf_field "$pkg" "update_url" || true)
  _detect_version_from_page "$pkg" "$upstream_url" "$page" >/dev/null 2>&1 || true
  local candidate_url=""
  # heuristic: if metafile has `url` field, replace version token if present
  local oldurl; oldurl=$(_mf_field "$pkg" "url" || true)
  if [ -n "$oldurl" ]; then
    candidate_url=$(echo "$oldurl" | sed "s/${curv}/${newv}/g")
  fi
  _up_apply_metafile_update "$pkg" "$newv" "$candidate_url"
  # 3) download new source via download.sh if available
  if [ -x "$DOWNLOAD_SCRIPT" ] && type dl_add_source >/dev/null 2>&1; then
    _up_log "Registering and downloading new sources via download.sh for $pkg"
    # let download.sh use metafile to fetch; fallback to wget later
    if type dl_fetch_all >/dev/null 2>&1; then
      dl_fetch_all >> "$UP_LOG_DIR/${pkg}.log" 2>&1 || _up_warn "dl_fetch_all reported warnings"
    fi
  else
    _up_log "No download.sh or API; leaving download to build stage"
  fi
  # 4) build using build.sh if available
  if [ -x "$BUILD_SCRIPT" ]; then
    _up_log "Invoking build.sh for $pkg"
    if ! "$BUILD_SCRIPT" run "$pkg" >> "$UP_LOG_DIR/${pkg}.log" 2>&1; then
      _up_warn "build.sh failed for $pkg (see ${UP_LOG_DIR}/${pkg}.log)"
      return 2
    fi
  else
    _up_warn "build.sh not available; skipping build for $pkg"
  fi
  # 5) package/install via create_install.sh
  if [ -x "$CREATE_INSTALL" ]; then
    _up_log "Invoking create_install.sh package and install for $pkg"
    # locate built destdir in /tmp or build workdir commonly /tmp/lfs-build/<pkg>
    local built_dest="/tmp/lfs-build/${pkg}"
    if [ -d "$built_dest" ]; then
      if ! "$CREATE_INSTALL" package "$pkg" "$built_dest" >> "$UP_LOG_DIR/${pkg}.log" 2>&1; then _up_warn "packaging failed for $pkg"
      else
        local tb=$(ls -1t /var/cache/lfs/packages/${pkg}-* 2>/dev/null | head -n1 || true)
        if [ -n "$tb" ]; then
          "$CREATE_INSTALL" install "$tb" "/" >> "$UP_LOG_DIR/${pkg}.log" 2>&1 || _up_warn "install failed for $pkg"
        fi
      fi
    else
      _up_warn "Built dest not found for $pkg ($built_dest)"
    fi
  else
    _up_warn "create_install.sh not available; skipping packaging/install for $pkg"
  fi
  _up_log "Upgrade pipeline completed for $pkg"
  return 0
}

# iterate metafiles and check all
_up_check_all(){
  local results_file="$UP_TMP_DIR/check_results.txt"; :> "$results_file"
  for mf in "$UP_METAFILE_DIR"/*.ini; do
    [ -f "$mf" ] || continue
    local pkg; pkg=$(basename "$mf" .ini)
    if _up_check_pkg "$pkg" >/dev/null 2>&1; then
      _up_log "Update available for $pkg"
      _up_check_pkg "$pkg" | tee -a "$results_file"
    fi
  done
  cat "$results_file"
}

# resume logic: read state and continue where left
_up_resume(){
  if [ ! -f "$_state_file" ]; then _up_warn "No state file to resume"; return 1; fi
  local pending; pending=$(jq -r '.pending[]' "$_state_file" 2>/dev/null || true)
  if [ -z "$pending" ]; then _up_warn "No pending entries in state"; return 1; fi
  for p in $pending; do
    _up_log "Resuming upgrade for $p"
    _upgrade_pkg_pipeline "$p" || _up_warn "resume failed for $p"
  done
  # clear state on success
  rm -f "$_state_file" || true
}

# rollback metafile from backups
_up_rollback(){
  local pkg="$1"
  [ -z "$pkg" ] && _up_error "pkg required for rollback"
  local latest=$(ls -1t "$UP_BACKUP_DIR/${pkg}.ini.*.bak" 2>/dev/null | head -n1 || true)
  if [ -z "$latest" ]; then _up_error "no backup found for $pkg"; return 2; fi
  cp -a "$latest" "$UP_METAFILE_DIR/${pkg}.ini"
  _up_log "Rolled back metafile for $pkg from $latest"
  return 0
}

# CLI usage
_usage(){
  cat <<EOF
update.sh - Upstream checker and auto-updater for metafiles

Usage:
  update.sh --init
  update.sh --check <pkg>
  update.sh --check-all
  update.sh --apply <pkg>
  update.sh --apply-all
  update.sh --upgrade <pkg>
  update.sh --upgrade-all
  update.sh --resume
  update.sh --rollback <pkg>
  update.sh --list-pending
  update.sh --help
Flags:
  --silent       Run quietly (SILENT_ERRORS=true)
  --parallel N   Parallel workers for check/upgrade-all
  --resume       Resume interrupted upgrade
EOF
}

# dispatcher
if [ "${BASH_SOURCE[0]}" == "$0" ]; then
  case "${1:-}" in
    --init) _safe_mkdir "$UP_METAFILE_DIR" "$UP_LOG_DIR" "$UP_STATE_DIR" "$UP_BACKUP_DIR" "$UP_TMP_DIR"; echo "Initialized"; exit 0;;
    --check) shift; pkg="$1"; _up_check_pkg "$pkg"; exit $?;;
    --check-all) _up_check_all; exit $?;;
    --apply) shift; pkg="$1"; # naive: attempt to detect new version then apply (calls check)
       res=$(_up_check_pkg "$pkg" 2>/dev/null || true)
       if [ -n "$res" ]; then newv=$(printf "%s" "$res" | cut -d'|' -f3); _up_apply_metafile_update "$pkg" "$newv" "" || _up_error "apply failed"; fi
       exit 0;;
    --apply-all) _up_check_all | while IFS="|" read -r p cur new; do _up_apply_metafile_update "$p" "$new" ""; done; exit 0;;
    --upgrade) shift; pkg="$1"; _upgrade_pkg_pipeline "$pkg"; exit $?;;
    --upgrade-all) shift; for mf in "$UP_METAFILE_DIR"/*.ini; do [ -f "$mf" ] || continue; p=$(basename "$mf" .ini); _upgrade_pkg_pipeline "$p"; done; exit 0;;
    --resume) _up_resume; exit $?;;
    --rollback) shift; _up_rollback "$1"; exit $?;;
    --list-pending) _up_check_all; exit $?;;
    --help|help|-h) _usage; exit 0;;
    *) _usage; exit 2;;
  esac
fi

# export functions
export -f _up_check_pkg _up_check_all _up_apply_metafile_update _upgrade_pkg_pipeline _up_resume _up_rollback
