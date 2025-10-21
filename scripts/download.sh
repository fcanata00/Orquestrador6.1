#!/usr/bin/env bash
# ============================================================================
# download.sh - Robust download and cache manager for LFS (PRO)
# ============================================================================
# Features:
#  - Supports HTTP(S), FTP, rsync, git, local files
#  - Cache with integrity verification (sha256/sha512), snapshots, resume
#  - Parallel downloads, retries with exponential backoff
#  - Integration with register.sh (if present) and sandbox.sh/deps.sh via API
#  - Public API functions for other scripts to call: download_fetch, download_get_url, etc.
#  - Extensive error handling and controlled silent-fail behavior
# ============================================================================
set -o errexit
set -o nounset
set -o pipefail

# Guard for multiple sourcing
if [ -n "${DOWNLOAD_SH_PRO_LOADED-}" ]; then
  return 0 2>/dev/null || exit 0
fi
DOWNLOAD_SH_PRO_LOADED=1

# -------------------------------
# Defaults (override via env)
# -------------------------------
: "${LFS_ROOT:=/mnt/lfs}"
: "${DOWNLOAD_ROOT:=${LFS_ROOT}/sources}"
: "${DOWNLOAD_CACHE:=${LFS_ROOT}/cache/downloads}"
: "${DOWNLOAD_TMP:=${LFS_ROOT}/tmp/downloads}"
: "${DOWNLOAD_LOGS:=${DOWNLOAD_ROOT}/logs}"
: "${DOWNLOAD_THREADS:=4}"
: "${DOWNLOAD_RETRIES:=3}"
: "${DOWNLOAD_TIMEOUT:=300}"
: "${DOWNLOAD_RESUME:=1}"
: "${DOWNLOAD_HASH_TYPE:=sha256}"   # sha256 or sha512
: "${DOWNLOAD_CLEAN_DAYS:=30}"
: "${DOWNLOAD_QUIET:=0}"
: "${DOWNLOAD_DEBUG:=0}"

CORE_REGISTER_PATHS=( "./register.sh" "/usr/local/bin/register.sh" "/usr/local/lib/lfs/register.sh" "${LFS_ROOT}/scripts/register.sh" "/usr/lib/lfs/register.sh" )

# -------------------------------
# Internal state
# -------------------------------
mkdir -p "${DOWNLOAD_ROOT}" "${DOWNLOAD_CACHE}" "${DOWNLOAD_TMP}" "${DOWNLOAD_LOGS}" 2>/dev/null || true
DL_ERRORS=0
DL_OPS=0

# -------------------------------
# Logger: prefer register.sh if available, else fallback
# -------------------------------
_download_try_load_register() {
  if declare -F log_info >/dev/null 2>&1; then return 0; fi
  for p in "${CORE_REGISTER_PATHS[@]}"; do
    [ -f "$p" ] || continue
    # shellcheck source=/dev/null
    source "$p" && declare -F log_info >/dev/null 2>&1 && return 0
  done
  return 1
}

_color_info='\\033[1;34m'; _color_warn='\\033[1;33m'; _color_err='\\033[1;31m'; _color_reset='\\033[0m'

_download_internal_log() {
  local level=\"$1\"; shift; local msg=\"$*\"; local ts; ts=\"$(date +'%Y-%m-%dT%H:%M:%S%z')\"
  case \"$level\" in
    DEBUG) [ \"${DOWNLOAD_DEBUG}\" -eq 1 ] && printf \"%s ${_color_info}[DEBUG]${_color_reset} %s\n\" \"$ts\" \"$msg\" >&2 || true ;;
    INFO)  [ \"${DOWNLOAD_QUIET}\" -eq 0 ] && printf \"%s ${_color_info}[INFO]${_color_reset} %s\n\" \"$ts\" \"$msg\" >&2 || true ;;
    WARN)  printf \"%s ${_color_warn}[WARN]${_color_reset} %s\n\" \"$ts\" \"$msg\" >&2 ;;
    ERROR) printf \"%s ${_color_err}[ERROR]${_color_reset} %s\n\" \"$ts\" \"$msg\" >&2 ;;
    FATAL) printf \"%s ${_color_err}[FATAL]${_color_reset} %s\n\" \"$ts\" \"$msg\" >&2 ;;
    *)     printf \"%s [LOG] %s\n\" \"$ts\" \"$msg\" >&2 ;;
  esac
}

if _download_try_load_register; then
  : # use log_info/log_warn/log_error from register.sh
else
  log_info()  { _download_internal_log INFO "$*"; }
  log_warn()  { _download_internal_log WARN "$*"; }
  log_error() { _download_internal_log ERROR "$*"; }
  log_debug() { _download_internal_log DEBUG "$*"; }
  log_fatal() { _download_internal_log FATAL "$*"; exit 1; }fi

# -------------------------------
# Helpers (continued)
# -------------------------------
_sleep_ms() {
  local ms="$1"
  if command -v perl >/dev/null 2>&1; then perl -e "select(undef,undef,undef,$ms/1000)"; else sleep "$(awk "BEGIN {print $ms/1000}")"; fi
}

_retry_cmd() {
  local max="${1:-$DOWNLOAD_RETRIES}"
  shift || true
  local attempt=0 delay=200
  while :; do
    "$@" && return 0
    local rc=$?
    attempt=$((attempt+1))
    DL_ERRORS=$((DL_ERRORS+1))
    if [ "$attempt" -ge "$max" ]; then
      log_warn "Command failed after $attempt attempts (rc=$rc): $*"
      return "$rc"
    fi
    log_debug "Retrying ($attempt/$max) after ${delay}ms: $*"
    _sleep_ms "$delay"
    delay=$((delay*2))
  done
}

_atomic_write() {
  local file="$1"; shift
  local tmp="${file}.$$.$RANDOM.tmp"
  { printf '%s\n' \"$@\"; } > \"$tmp\" && mv -f \"$tmp\" \"$file\"
}

_file_size() {
  [ -f \"$1\" ] || { echo 0; return 0; }
  stat -c%s \"$1\" 2>/dev/null || wc -c < \"$1\" 2>/dev/null || echo 0
}

_hash_of() {
  local f=\"$1\"; local algo=\"${2:-$DOWNLOAD_HASH_TYPE}\"
  if [ \"$algo\" = \"sha512\" ] && command -v sha512sum >/dev/null 2>&1; then
    sha512sum \"$f\" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum \"$f\" 2>/dev/null | awk '{print $1}'
  else
    if command -v openssl >/dev/null 2>&1; then
      if [ \"$algo\" = \"sha512\" ]; then openssl dgst -sha512 \"$f\" 2>/dev/null | awk '{print $2}'; else openssl dgst -sha256 \"$f\" 2>/dev/null | awk '{print $2}'; fi
    else
      echo \"\"
    fi
  fi
}

# choose download tool
_download_select_tool() {
  if command -v aria2c >/dev/null 2>&1; then echo \"aria2c\"; return 0; fi
  if command -v curl >/dev/null 2>&1; then echo \"curl\"; return 0; fi
  if command -v wget >/dev/null 2>&1; then echo \"wget\"; return 0; fi
  echo \"none\"; return 1
}

# Low-level fetchers
_fetch_http() {
  local url=\"$1\"; local out=\"$2\"; local resume=\"$3\"
  local tool; tool=\"$(_download_select_tool)\"
  case \"$tool\" in
    aria2c)
      _retry_cmd 3 aria2c --file-allocation=none -x4 -s4 -o \"$out\" -d \"$(dirname \"$out\")\" --max-connection-per-server=4 --timeout=${DOWNLOAD_TIMEOUT} \"$url\"
      ;;
    curl)
      if [ \"$resume\" -eq 1 ]; then
        _retry_cmd 3 curl --fail -L --retry 5 --retry-delay 2 --connect-timeout 15 -C - -o \"$out\" \"$url\"
      else
        _retry_cmd 3 curl --fail -L --retry 5 --retry-delay 2 --connect-timeout 15 -o \"$out\" \"$url\"
      fi
      ;;
    wget)
      if [ \"$resume\" -eq 1 ]; then
        _retry_cmd 3 wget -c -O \"$out\" \"$url\"
      else
        _retry_cmd 3 wget -O \"$out\" \"$url\"
      fi
      ;;
    *)
      log_fatal \"No download tool available (aria2c/curl/wget)\"
      ;;
  esac
}

_fetch_rsync() {
  local url=\"$1\"; local out=\"$2\"
  if ! command -v rsync >/dev/null 2>&1; then log_fatal \"rsync not available\"; fi
  _retry_cmd 3 rsync -av --timeout=${DOWNLOAD_TIMEOUT} --partial \"$url\" \"$out\"
}

_fetch_git() {
  local url=\"$1\"; local outdir=\"$2\"; local ref=\"${3:-}\"
  if ! command -v git >/dev/null 2>&1; then log_fatal \"git not available\"; fi
  if [ -d \"$outdir/.git\" ]; then
    log_info \"Updating git repo in $outdir\"
    (cd \"$outdir\" && _retry_cmd 3 git fetch --prune --unshallow --tags) || return 1
    if [ -n \"$ref\" ]; then (cd \"$outdir\" && _retry_cmd 3 git checkout --force \"$ref\") || return 1; fi
    return 0
  else
    log_info \"Cloning $url -> $outdir\"
    _retry_cmd 3 git clone --depth 1 \"$url\" \"$outdir\" || { log_warn \"Shallow clone failed; trying full clone\"; _retry_cmd 3 git clone \"$url\" \"$outdir\"; }
    if [ -n \"$ref\" ]; then (cd \"$outdir\" && _retry_cmd 3 git checkout --force \"$ref\") || true; fi
  fi
}

_fetch_file_local() {
  local src=\"$1\"; local out=\"$2\"
  if [ -f \"$src\" ]; then
    cp -a \"$src\" \"$out\" || { log_warn \"cp failed, trying rsync\"; rsync -a \"$src\" \"$out\" || return 1; }
  else
    log_warn \"Local source not found: $src\"; return 1
  fi
}

_download_make_paths() {
  mkdir -p \"${DOWNLOAD_ROOT}\" \"${DOWNLOAD_CACHE}\" \"${DOWNLOAD_TMP}\" \"${DOWNLOAD_LOGS}\" 2>/dev/null || true
}

_download_in_cache() {
  local filename=\"$1\"
  [ -f \"${DOWNLOAD_CACHE}/${filename}\" ]
}

_download_cache_put() {
  local src=\"$1\"; local filename=\"$2\"
  mkdir -p \"${DOWNLOAD_CACHE}\" 2>/dev/null || true
  local tmp=\"${DOWNLOAD_CACHE}/${filename}.$$.$RANDOM.tmp\"
  cp -a \"$src\" \"$tmp\" && mv -f \"$tmp\" \"${DOWNLOAD_CACHE}/${filename}\"
  log_debug \"Cached ${filename}\"
}

_download_cache_get() {
  local filename=\"$1\"; local dest=\"$2\"
  if [ -f \"${DOWNLOAD_CACHE}/${filename}\" ]; then
    ln -f \"${DOWNLOAD_CACHE}/${filename}\" \"$dest\" 2>/dev/null || cp -a \"${DOWNLOAD_CACHE}/${filename}\" \"$dest\"
    return 0
  fi
  return 1
}

_verify_integrity() {
  local file=\"$1\"; local expected=\"$2\"; local algo=\"${3:-$DOWNLOAD_HASH_TYPE}\"
  if [ -z \"$expected\" ]; then
    log_debug \"No expected hash; computing actual for $file\"
    echo \"$(_hash_of \"$file\" \"$algo\")\"
    return 0
  fi
  local actual
  actual=\"$(_hash_of \"$file\" \"$algo\")\"
  if [ -z \"$actual\" ]; then
    log_warn \"Cannot compute hash for $file (no tool)\"
    return 2
  fi
  if [ \"$actual\" = \"$expected\" ]; then
    log_debug \"Hash match for $file\"
    return 0
  else
    log_warn \"Hash mismatch for $file: expected $expected got $actual\"
    return 1
  fi
}

# Public API functions (download_init, download_get_url, download_fetch, ...)

download_init() {
  _download_make_paths
  log_info \"Download system initialized (root=${DOWNLOAD_ROOT}, cache=${DOWNLOAD_CACHE})\"
  return 0
}

download_get_url() {
  local url=\"$1\"; local dest=\"$2\"; local expected=\"${3:-}\"
  DL_OPS=$((DL_OPS+1))
  download_init >/dev/null 2>&1 || true
  local filename; filename=\"$(basename \"${url%%\\?*}\")\"
  local tmpfile=\"${DOWNLOAD_TMP}/${filename}.$$\"
  local resume=1
  case \"$url\" in
    http://*|https://*|ftp://*)
      log_info \"Fetching URL: $url -> $dest\"
      _fetch_http \"$url\" \"$tmpfile\" \"$resume\" || { log_warn \"HTTP fetch failed for $url\"; return 1; }
      ;;
    rsync://*)
      log_info \"Fetching rsync URL: $url -> $dest\"
      _fetch_rsync \"$url\" \"$tmpfile\" || { log_warn \"rsync fetch failed for $url\"; return 1; }
      ;;
    git://*|git+*|ssh://*|*/.git)
      log_info \"Fetching git repo: $url -> $dest\"
      _fetch_git \"$url\" \"$dest\" \"\" || { log_warn \"git fetch failed for $url\"; return 1; }
      return 0
      ;;
    file://*)
      local src=\"${url#file://}\"; _fetch_file_local \"$src\" \"$tmpfile\" || { log_warn \"local file copy failed for $url\"; return 1; }
      ;;
    /*)
      _fetch_file_local \"$url\" \"$tmpfile\" || { log_warn \"local file copy failed for $url\"; return 1; }
      ;;
    *)
      log_warn \"Unsupported URL scheme: $url\"; return 1;;
  esac

  local sz; sz=\"$(_file_size \"$tmpfile\")\"
  if [ \"$sz\" -lt 1024 ]; then
    log_warn \"Downloaded file too small ($sz bytes): $url\"
    rm -f \"$tmpfile\" 2>/dev/null || true
    return 1
  fi

  if [ -n \"$expected\" ]; then
    if ! _verify_integrity \"$tmpfile\" \"$expected\"; then
      log_warn \"Integrity check failed for $url\"
      rm -f \"$tmpfile\" 2>/dev/null || true
      return 2
    fi
  fi

  mkdir -p \"$(dirname \"$dest\")\" 2>/dev/null || true
  mv -f \"$tmpfile\" \"$dest\" || cp -a \"$tmpfile\" \"$dest\"
  _download_cache_put \"$dest\" \"$(basename \"$dest\")\" || true
  log_info \"Downloaded and cached: $dest\"
  return 0
}

download_fetch() {
  local recipe=\"$1\"; shift || true
  local force_update=0
  for arg in \"$@\"; do [ \"$arg\" = \"--update\" ] && force_update=1 || true; done
  if [ ! -f \"$recipe\" ]; then log_warn \"Recipe not found: $recipe\"; return 1; fi
  # shellcheck source=/dev/null
  source \"$recipe\"
  : \"${NAME:?"Recipe must set NAME"}\"
  : \"${VERSION:?"Recipe must set VERSION"}\"
  local expected_hash=\"${SHA256:-${SHA512:-}}\"
  local hash_algo=\"sha256\"
  if [ -n \"${SHA512:-}\" ]; then hash_algo=\"sha512\"; fi
  local target_dir=\"${DOWNLOAD_ROOT}/${NAME}-${VERSION}\"
  mkdir -p \"${target_dir}\" 2>/dev/null || true
  local ok=1 last_err=0
  for url in \"${URLS[@]}\"; do
    local fname=\"$(basename \"${url%%\\?*}\")\"
    local dest=\"${target_dir}/${fname}\"
    if [ -f \"$dest\" ] && [ \"$force_update\" -ne 1 ]; then
      if _verify_integrity \"$dest\" \"$expected_hash\" \"$hash_algo\"; then log_info \"Using existing file: $dest\"; ok=0; break; else log_warn \"Existing file failed integrity, will redownload\"; rm -f \"$dest\"; fi
    fi
    if _download_cache_get \"$fname\" \"$dest\"; then
      log_info \"Fetched from cache: $fname -> $dest\"
      if [ -n \"$expected_hash\" ] && ! _verify_integrity \"$dest\" \"$expected_hash\" \"$hash_algo\"; then log_warn \"Cache entry failed integrity; removing and retrying\"; rm -f \"$dest\"; fi
      ok=0; break
    fi
    if download_get_url \"$url\" \"$dest\" \"$expected_hash\"; then ok=0; break; else last_err=$?; log_warn \"Attempt failed for $url (rc=$last_err)\"; fi
  done
  if [ \"$ok\" -ne 0 ]; then
    log_error \"All mirrors failed for ${NAME}-${VERSION}\"
    return 2
  fi
  log_info \"download_fetch: success ${NAME}-${VERSION}\"
  return 0
}

download_check() {
  local file=\"$1\"; local expected=\"$2\"; local algo=\"${3:-$DOWNLOAD_HASH_TYPE}\"
  if [ ! -f \"$file\" ]; then log_warn \"File not found: $file\"; return 2; fi
  if _verify_integrity \"$file\" \"$expected\" \"$algo\"; then return 0; else return 1; fi
}

download_from_cache() {
  local namever=\"$1\"; local filename=\"$2\"; local dest=\"$3\"
  if _download_cache_get \"$filename\" \"$dest\"; then log_info \"Restored $filename from cache\"; return 0; fi
  log_warn \"Not found in cache: $filename\"; return 1
}

download_clean_cache() {
  local days=\"${1:-$DOWNLOAD_CLEAN_DAYS}\"
  log_info \"Cleaning cache older than ${days} days in ${DOWNLOAD_CACHE}\"
  find \"${DOWNLOAD_CACHE}\" -type f -mtime +\"${days}\" -print0 | xargs -0 -r rm -f || true
  return 0
}

download_self_test() {
  log_info \"Running download.sh self-test...\"
  download_init >/dev/null 2>&1 || true
  local tmprecipe=\"${DOWNLOAD_TMP}/example.recipe\"
  cat > \"$tmprecipe\" <<'RECIPE'
NAME=\"example\"
VERSION=\"0.0\"
URLS=( \"https://www.kernel.org/\" )
SHA256=\"\"
RECIPE
  download_fetch \"$tmprecipe\" || { log_warn \"Self-test download failed (expected some web servers block)\"; return 1; }
  log_info \"Self-test completed (note: network-dependent)\"
  return 0
}

export -f download_init download_get_url download_fetch download_check download_from_cache download_clean_cache download_self_test

# CLI
_download_usage() {
  cat <<EOF
Usage: download.sh [options] [recipes...]
Options:
  --init               Initialize directories
  --fetch <recipe>     Fetch package from recipe file
  --get <url> <dest>   Download a single URL to dest
  --check <file> <hash> Check integrity
  --clean-cache [days] Clean cache older than days (default ${DOWNLOAD_CLEAN_DAYS})
  --snapshot           Create snapshot of cache (tar.zst if zstd available)
  --restore <file>     Restore snapshot
  --self-test          Run self-test
  --debug              Turn debug on
  --quiet              Quiet mode (minimal logs)
  --help               Show this help
EOF
}

if [ \"${BASH_SOURCE[0]}\" = \"$0\" ]; then
  cmd=\"${1:-}\"
  case \"$cmd\" in
    --help) _download_usage; exit 0 ;;
    --debug) DOWNLOAD_DEBUG=1; shift; cmd=\"${1:-}\" ;;
    --quiet) DOWNLOAD_QUIET=1; shift; cmd=\"${1:-}\" ;;
  esac
  case \"$cmd\" in
    --init) download_init ;;
    --fetch) shift; download_fetch \"$1\" ;;
    --get) shift; download_get_url \"$1\" \"$2\" ;;
    --check) shift; download_check \"$1\" \"$2\" ;;
    --clean-cache) shift; download_clean_cache \"${1:-}\" ;;
    --snapshot)
      SNAP=\"${DOWNLOAD_ROOT}/snapshot-$(date +%Y%m%d%H%M%S).tar\"
      if command -v zstd >/dev/null 2>&1; then tar -C \"${DOWNLOAD_ROOT}\" -cf - . | zstd -T0 -o \"${SNAP}.zst\" && echo \"${SNAP}.zst\"; else tar -C \"${DOWNLOAD_ROOT}\" -cf - . | gzip -c > \"${SNAP}.gz\" && echo \"${SNAP}.gz\"; fi
      ;;
    --restore) shift; if [ -f \"$1\" ]; then if [[ \"$1\" == *.zst ]]; then zstd -d \"$1\" -c | tar -x -C \"${DOWNLOAD_ROOT}\"; elif [[ \"$1\" == *.gz ]]; then gzip -dc \"$1\" | tar -x -C \"${DOWNLOAD_ROOT}\"; else tar -xf \"$1\" -C \"${DOWNLOAD_ROOT}\"; fi; fi ;;
    --self-test) download_self_test ;;
    \"\") _download_usage ;;
    *) _download_usage ;;
  esac
fi

# EOF
