#!/usr/bin/env bash
# =============================================================================
# metadata.sh - Metadata (recipe) manager PRO for LFS
# =============================================================================
# Responsibilities:
#  - Parse metadata INI files describing packages (sources, hashes, env, build steps)
#  - Provide public API for other scripts: metadata_load, metadata_get, metadata_validate,
#    metadata_apply_env, metadata_apply_patches, metadata_run_hook, metadata_get_sources,
#    metadata_create, metadata_lint, metadata_clear_cache
#  - Create new metafile templates (--create)
#  - Lint metafiles (--lint)
#  - Cache parsing results for speed and concurrency-safe operations
#  - Robust error handling, retries, silent-mode, and integration with register.sh
# =============================================================================
set -o errexit
set -o nounset
set -o pipefail

# prevent double source
if [ -n "${METADATA_SH_PRO_LOADED-}" ]; then
  return 0 2>/dev/null || exit 0
fi
METADATA_SH_PRO_LOADED=1

# ---------------------------
# Defaults (override via env)
# ---------------------------
: "${LFS_ROOT:=/mnt/lfs}"
: "${META_CACHE_DIR:=${LFS_ROOT}/cache/meta}"
: "${META_LOCK_DIR:=${LFS_ROOT}/.lock}"
: "${META_STRICT:=0}"         # if 1, treat validation warnings as fatal
: "${META_QUIET:=0}"
: "${META_DEBUG:=0}"
: "${META_RETRY:=3}"
: "${META_LINT_COLOR:=1}"

CORE_REGISTER_PATHS=( "./register.sh" "/usr/local/bin/register.sh" "/usr/local/lib/lfs/register.sh" "${LFS_ROOT}/scripts/register.sh" "/usr/lib/lfs/register.sh" )

# internal
mkdir -p "${META_CACHE_DIR}" 2>/dev/null || true
mkdir -p "${META_LOCK_DIR}" 2>/dev/null || true

# ---------------------------
# Logger: try register.sh then fallback
# ---------------------------
_meta_try_load_register() {
  if declare -F log_info >/dev/null 2>&1; then return 0; fi
  for p in "${CORE_REGISTER_PATHS[@]}"; do
    [ -f "$p" ] || continue
    # shellcheck source=/dev/null
    source "$p" && declare -F log_info >/dev/null 2>&1 && return 0
  done
  return 1
}

_color_info='\033[1;34m'; _color_warn='\033[1;33m'; _color_err='\033[1;31m'; _color_ok='\033[1;32m'; _color_reset='\033[0m'

_meta_log() {
  local level="$1"; shift; local msg="$*"; local ts; ts="$(date +'%Y-%m-%dT%H:%M:%S%z')"
  case "$level" in
    DEBUG) [ "${META_DEBUG}" -eq 1 ] && printf "%s ${_color_info}[DEBUG]${_color_reset} %s\n" "$ts" "$msg" >&2 || true ;;
    INFO)  [ "${META_QUIET}" -eq 0 ] && printf "%s ${_color_info}[INFO]${_color_reset} %s\n" "$ts" "$msg" >&2 || true ;;
    WARN)  printf "%s ${_color_warn}[WARN]${_color_reset} %s\n" "$ts" "$msg" >&2 ;;
    ERROR) printf "%s ${_color_err}[ERROR]${_color_reset} %s\n" "$ts" "$msg" >&2 ;;
    OK)    printf "%s ${_color_ok}[OK]${_color_reset} %s\n" "$ts" "$msg" >&2 ;;
    *)     printf "%s [LOG] %s\n" "$ts" "$msg" >&2 ;;
  esac
}

if _meta_try_load_register; then
  : # use register.sh's log_info/log_warn etc if present
else
  log_info()  { _meta_log INFO "$*"; }
  log_warn()  { _meta_log WARN "$*"; }
  log_error() { _meta_log ERROR "$*"; }
  log_debug() { _meta_log DEBUG "$*"; }
  log_ok()    { _meta_log OK "$*"; }
fi

# ---------------------------
# Helpers: sleep ms, retry, lock
# ---------------------------
_meta_sleep_ms() {
  local ms="$1"
  if command -v perl >/dev/null 2>&1; then perl -e "select(undef,undef,undef,$ms/1000)"; else sleep "$(awk "BEGIN {print $ms/1000}")"; fi
}

_meta_retry() {
  local max="${1:-${META_RETRY}}"; shift
  local attempt=0 delay=100
  while :; do
    "$@" && return 0
    local rc=$?
    attempt=$((attempt+1))
    log_warn "Attempt $attempt/$max failed (rc=$rc): $*"
    if [ "$attempt" -ge "$max" ]; then
      log_error "Command failed after $attempt attempts: $*"
      return "$rc"
    fi
    _meta_sleep_ms "$delay"
    delay=$((delay*2))
  done
}

_meta_lock_acquire() {
  local name="$1"; local timeout="${2:-30}"
  local lockf="${META_LOCK_DIR}/${name}.lock"
  mkdir -p "$(dirname "$lockf")" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    exec 300>"$lockf"
    local start=$(date +%s)
    while ! flock -x 300 2>/dev/null; do
      local now=$(date +%s)
      if [ $((now - start)) -ge "$timeout" ]; then
        log_error "Timeout acquiring lock $lockf"
        return 1
      fi
      sleep 0.1
    done
    return 0
  else
    local d="${lockf}.d" start=$(date +%s)
    while ! mkdir "$d" 2>/dev/null; do
      local now=$(date +%s)
      if [ $((now - start)) -ge "$timeout" ]; then
        log_error "Timeout creating lockdir $d"
        return 1
      fi
      sleep 0.1
    done
    printf '%s\n' "$$" > "${d}/pid" 2>/dev/null || true
    return 0
  fi
}

_meta_lock_release() {
  local name="$1"
  local lockf="${META_LOCK_DIR}/${name}.lock"
  if command -v flock >/dev/null 2>&1; then
    flock -u 300 2>/dev/null || true
    exec 300>&- || true
  else
    local d="${lockf}.d"; [ -d "$d" ] && rm -rf "$d" 2>/dev/null || true
  fi
}

# ---------------------------
# INI parsing (supports arrays and multiline '|' blocks)
# ---------------------------
declare -A META_KV
declare -A META_ARR_IDX

_meta_hash_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f" 2>/dev/null | awk '{print $1}'; else echo ""; fi
}

_meta_cache_path() {
  local metafile="$1"
  local hash
  if [ -f "$metafile" ]; then
    hash="$(_meta_hash_file "$metafile")"
  else
    hash="$(printf '%s' "$metafile" | sha256sum 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s/%s.cache' "$META_CACHE_DIR" "$hash"
}

_meta_parse_ini_awK() {
  awk '
    BEGIN{FS="="; section=""; OFS="="}
    /^\s*;/ {next} /^\s*#/ {next}
    /^\s*\[/ { gsub(/^\s*|\s*$/,"",$0); section=$0; gsub(/^\[|\]$/,"",section); next}
    /^[[:space:]]*$/ {next}
    {
      line=$0
      sub(/^[ \t]*/,"",line)
      k=substr(line,1,index(line,"=")-1)
      v=substr(line,index(line,"=")+1)
      gsub(/^[ \t]+|[ \t]+$/,"",k)
      gsub(/^[ \t]+|[ \t]+$/,"",v)
      if(v == "|") {
        val=""
        while(getline) {
          if($0 == ".") break
          val = val $0 "\n"
        }
        v=val
      }
      printf("[%s]|%s|%s\n", section, k, v)
    }
  ' "$1"
}

_meta_parse_ini() {
  local file="$1"
  if command -v awk >/dev/null 2>&1; then
    _meta_parse_ini_awK "$file"
    return $?
  fi
  local section=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%;*}"
    line="${line%%#*}"
    line="$(echo "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [ -z "$line" ] && continue
    if [[ "$line" =~ ^\[(.*)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      local k="${BASH_REMATCH[1]}"
      local v="${BASH_REMATCH[2]}"
      v="$(echo "$v" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
      printf "[%s]|%s|%s\n" "$section" "$k" "$v"
    fi
  done < "$file"
}

_meta_clear_inmemory() {
  META_KV=()
  META_ARR_IDX=()
  unset META_name META_version META_description META_group META_mode
}

_meta_store_kv() {
  local section="$1" key="$2" value="$3"
  local normalized_key
  normalized_key="$(printf '%s__%s' "$section" "$key" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g')"
  if printf '%s' "$key" | grep -q '\[\]'; then
    local base="${section}__${key%%\[\]}"
    local idx="${META_ARR_IDX[$base]:-0}"
    META_KV["${base}__ARR_${idx}"]="$value"
    META_ARR_IDX["$base"]=$((idx+1))
  else
    META_KV["$normalized_key"]="$value"
  fi
  if [ "$section" = "meta" ]; then
    case "$key" in
      name) META_name="$value" ;;
      version) META_version="$value" ;;
      description) META_description="$value" ;;
      group) META_group="$value" ;;
      mode) META_mode="$value" ;;
    esac
  fi
}

metadata_load() {
  local metafile="$1"
  if [ -z "$metafile" ] || [ ! -f "$metafile" ]; then
    log_error "metadata_load: file not found: $metafile"
    return 2
  fi
  local cachefile="$(_meta_cache_path "$metafile")"
  if [ -f "$cachefile" ]; then
    log_debug "Loading cached metadata for $metafile"
    # shellcheck source=/dev/null
    source "$cachefile" || { log_warn "Failed to source cache; reparsing"; rm -f "$cachefile"; }
    return 0
  fi

  _meta_lock_acquire "$(basename "$metafile")" 10 || { log_warn "Could not acquire lock to parse $metafile"; }

  _meta_clear_inmemory

  while IFS= read -r line; do
    section="$(printf '%s' "$line" | awk -F'|' '{print $1}' | sed -E 's/^[[]|[]]$//g')"
    key="$(printf '%s' "$line" | awk -F'|' '{print $2}')"
    value="$(printf '%s' "$line" | awk -F'|' '{print $3}')"
    _meta_store_kv "$section" "$key" "$value"
  done < <(_meta_parse_ini "$metafile")

  {
    echo "# cached metadata for ${metafile}"
    echo "# generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    for k in "${!META_KV[@]}"; do
      val="${META_KV[$k]}"
      printf 'META_KV["%s"]=%q\n' "$k" "$val"
    done
    for b in "${!META_ARR_IDX[@]}"; do
      printf 'META_ARR_IDX["%s"]=%s\n' "$b" "${META_ARR_IDX[$b]}"
    done
    printf 'META_name=%q\n' "${META_name:-}"
    printf 'META_version=%q\n' "${META_version:-}"
    printf 'META_description=%q\n' "${META_description:-}"
    printf 'META_group=%q\n' "${META_group:-}"
    printf 'META_mode=%q\n' "${META_mode:-}"
  } > "${cachefile}.tmp" && mv -f "${cachefile}.tmp" "$cachefile"

  _meta_lock_release "$(basename "$metafile")"
  log_info "Parsed and cached metadata: $metafile"
  return 0
}

metadata_get() {
  local key="$1"
  [ -n "$key" ] || { log_error "metadata_get requires a key"; return 2; }
  key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.]/_/g')"
  if [[ "$key" == *.* ]]; then
    local section="${key%%.*}"
    local k="${key##*.}"
    local norm="${section}__${k}"
    if [ -n "${META_KV[$norm]-}" ]; then
      printf '%s' "${META_KV[$norm]}"
      return 0
    fi
  fi
  case "$key" in
    name) printf '%s' "${META_name:-}"; return 0 ;;
    version) printf '%s' "${META_version:-}"; return 0 ;;
    description) printf '%s' "${META_description:-}"; return 0 ;;
    group) printf '%s' "${META_group:-}"; return 0 ;;
    mode) printf '%s' "${META_mode:-}"; return 0 ;;
  esac
  # arrays
  local base="${key//./__}"
  for idx in "${!META_KV[@]}"; do
    case "$idx" in
      ${base}__ARR_* )
        printf '%s\n' "${META_KV[$idx]}"
        ;;
    esac
  done
  return 1
}

metadata_get_sources() {
  local pref="source__url"
  for key in "${!META_KV[@]}"; do
    case "$key" in
      ${pref}__ARR_* )
        local idx="${key##*ARR_}"
        local url="${META_KV[$key]}"
        local sha_key="source__sha256__ARR_${idx}"
        local sha="${META_KV[$sha_key]:-}"
        local dir="${META_KV[source__dir]:-}"
        printf '%s %s %s\n' "$url" "$sha" "$dir"
        ;;
    esac
  done
}

metadata_validate() {
  local errors=0 warnings=0 file="${1:-}"
  if [ -n "$file" ]; then
    metadata_load "$file" || { log_error "Cannot load metadata $file"; return 2; }
  fi
  if [ -z "${META_name:-}" ]; then log_error "metadata_validate: missing meta.name"; errors=$((errors+1)); fi
  if [ -z "${META_version:-}" ]; then log_error "metadata_validate: missing meta.version"; errors=$((errors+1)); fi
  if [ -z "${META_group:-}" ]; then log_warn "metadata_validate: missing meta.group (recommended)"; warnings=$((warnings+1)); fi
  if [ -z "${META_mode:-}" ]; then log_warn "metadata_validate: missing meta.mode (recommended)"; warnings=$((warnings+1)); fi
  local has_url=0
  for k in "${!META_KV[@]}"; do
    case "$k" in
      source__url__ARR_*) has_url=1; break ;;
    esac
  done
  if [ "$has_url" -eq 0 ]; then log_error "metadata_validate: no source.url[] specified"; errors=$((errors+1)); fi
  for k in "${!META_KV[@]}"; do
    case "$k" in
      source__patches__ARR_*)
        local p="${META_KV[$k]}"
        if [[ "$p" =~ ^https?:// ]]; then
          :
        else
          if [ ! -f "$p" ] && [ ! -f "$(dirname "${file:-.}")/$p" ]; then
            log_warn "metadata_validate: patch not found: $p"
            warnings=$((warnings+1))
          fi
        fi
        ;;
    esac
  done

  if [ "$errors" -gt 0 ]; then
    log_error "metadata_validate: found $errors error(s) and $warnings warning(s)"
    if [ "${META_STRICT}" -eq 1 ]; then return 2; fi
    return 1
  fi
  if [ "$warnings" -gt 0 ]; then
    log_warn "metadata_validate: $warnings warning(s)"
  fi
  log_ok "metadata_validate: OK"
  return 0
}

declare -A _META_ENV_BACKUP
metadata_apply_env() {
  log_info "Applying metadata environment..."
  for k in "${!META_KV[@]}"; do
    case "$k" in
      env__*)
        local var="${k#env__}"
        local val="${META_KV[$k]}"
        _META_ENV_BACKUP["$var"]="${!var:-__unset__}"
        export "$var"="$val"
        log_debug "export $var=$val"
        ;;
    esac
  done
  return 0
}

metadata_restore_env() {
  log_info "Restoring previous environment..."
  for var in "${!_META_ENV_BACKUP[@]}"; do
    local old="${_META_ENV_BACKUP[$var]}"
    if [ "$old" = "__unset__" ]; then
      unset "$var" 2>/dev/null || true
    else
      export "$var"="$old"
    fi
  done
  return 0
}

metadata_apply_patches() {
  log_info "Applying patches..."
  local base_dir="${1:-$(pwd)}"
  local patchdir="${base_dir}/patches"
  local applied=0
  for k in "${!META_KV[@]}"; do
    case "$k" in
      source__patches__ARR_*)
        local p="${META_KV[$k]}"
        if [[ "$p" =~ ^https?:// ]]; then
          local tmpf
          tmpf="$(mktemp -p /tmp metadata_patch.XXXX)" || tmpf="/tmp/metadata_patch.$$"
          if command -v curl >/dev/null 2>&1; then
            _meta_retry curl -fsSL "$p" -o "$tmpf" || { log_warn "Failed to download patch $p"; rm -f "$tmpf"; continue; }
          else
            _meta_retry wget -qO "$tmpf" "$p" || { log_warn "Failed to download patch $p"; rm -f "$tmpf"; continue; }
          fi
          _meta_apply_patch_file "$tmpf" && applied=$((applied+1))
          rm -f "$tmpf"
        else
          if [ -f "${patchdir}/${p}" ]; then
            _meta_apply_patch_file "${patchdir}/${p}" && applied=$((applied+1))
          elif [ -f "${p}" ]; then
            _meta_apply_patch_file "${p}" && applied=$((applied+1))
          else
            log_warn "Patch not found: $p"
          fi
        fi
        ;;
    esac
  done
  log_info "Applied ${applied} patches (if any)"
  return 0
}

_meta_apply_patch_file() {
  local f="$1"
  if [ ! -f "$f" ]; then log_warn "_meta_apply_patch_file: missing $f"; return 1; fi
  log_info "Applying patch file: $f"
  if command -v git >/dev/null 2>&1; then
    if git apply --index --whitespace=nowarn "$f" 2>/dev/null; then
      log_info "Applied patch via git apply: $f"; return 0
    fi
  fi
  if patch -p1 --forward < "$f" 2>/dev/null; then
    log_info "Applied patch via patch -p1: $f"; return 0
  fi
  if patch --forward < "$f" 2>/dev/null; then
    log_info "Applied patch via patch: $f"; return 0
  fi
  log_warn "Failed to apply patch: $f"
  return 1
}

metadata_run_hook() {
  local hook="$1" base_dir="${2:-$(pwd)}" hookdir
  hookdir="${META_KV[hooks__dir]:-}"
  if [ -z "$hookdir" ]; then
    hookdir="${base_dir}/hooks"
  fi
  if [ ! -d "$hookdir" ]; then
    log_debug "No hook dir: $hookdir"
    return 0
  fi
  local script
  for script in "$hookdir/${hook}"* "$hookdir/${hook}.sh"; do
    [ -f "$script" ] || continue
    if [ ! -x "$script" ]; then chmod +x "$script" 2>/dev/null || true; fi
    log_info "Running hook: $script"
    if ! _meta_retry 2 bash -c "cd '$base_dir' && '$script'"; then
      log_warn "Hook failed: $script"
      if [ "${META_STRICT}" -eq 1 ]; then log_error "Aborting due to hook failure"; return 2; fi
    fi
  done
  return 0
}

metadata_create() {
  local group="$1" name="$2" sub="${3:-}"
  if [ -z "$group" ] || [ -z "$name" ]; then
    log_error "metadata_create requires group and name"
    return 2
  fi
  local base="${LFS_ROOT}/${group}/${name}"
  if [ -n "$sub" ]; then
    base="${LFS_ROOT}/${group}/${name}/${sub}"
    mkdir -p "$base" 2>/dev/null || true
    local file="${base}/${name}-${sub}.ini"
  else
    mkdir -p "$base" 2>/dev/null || true
    local file="${base}/${name}.ini"
  fi
  if [ -f "$file" ]; then
    log_warn "Metafile already exists: $file"
    return 1
  fi
  cat > "$file" <<'INI'
[meta]
name=__NAME__
version=0.0
description=Short description
group=__GROUP__
mode=stage2

[source]
url[]=https://example.org/__NAME__-__VERSION__.tar.gz
sha256[]=

[env]
PATH=/tools/bin:/usr/bin
CFLAGS=-O2 -pipe
LDFLAGS=

[build]
prepare=|
  mkdir -v build && cd build
compile=|
  ../configure --prefix=/usr
  make -j$(nproc)
check=|
  make check || true
install=|
  make install

[patches]
dir=patches

[hooks]
dir=hooks

[update]
api=https://example.org/releases/
regex=__NAME__-([0-9.]+)\.tar\.gz
INI
  sed -i "s|__NAME__|$name|g; s|__GROUP__|$group|g; s|__VERSION__|0.0|g" "$file" 2>/dev/null || true
  log_info "Created metafile: $file"
  return 0
}

metadata_lint() {
  local target="${1:-.}"
  local files=()
  if [ -d "$target" ]; then
    while IFS= read -r -d $'\0' f; do files+=("$f"); done < <(find "$target" -name '*.ini' -print0)
  elif [ -f "$target" ]; then
    files=("$target")
  else
    log_error "metadata_lint: path not found: $target"
    return 2
  fi
  local total=0 errs=0 warns=0
  for f in "${files[@]}"; do
    total=$((total+1))
    log_debug "Linting $f"
    if ! metadata_load "$f"; then
      log_error "Failed to parse $f"; errs=$((errs+1)); continue
    fi
    if metadata_validate "$f"; then
      if [ "${META_LINT_COLOR}" -eq 1 ]; then printf "%b %s (ok)%b\n" "${_color_ok}" "$f" "${_color_reset}"; else printf "OK %s\n" "$f"; fi
    else
      if [ "${META_LINT_COLOR}" -eq 1 ]; then printf "%b %s (issues)%b\n" "${_color_warn}" "$f" "${_color_reset}"; else printf "ISSUES %s\n" "$f"; fi
      warns=$((warns+1))
    fi
  done
  log_info "Lint summary: checked=${total} warnings=${warns} errors=${errs}"
  if [ "$errs" -gt 0 ]; then return 2; fi
  return 0
}

metadata_clear_cache() {
  rm -f "${META_CACHE_DIR}"/* 2>/dev/null || true
  log_info "Cleared metadata parse cache in ${META_CACHE_DIR}"
  return 0
}

metadata_get_api_info() {
  local api="${META_KV[update__api]:-}"
  local regex="${META_KV[update__regex]:-}"
  printf '%s %s\n' "$api" "$regex"
}

export -f metadata_load metadata_get metadata_validate metadata_apply_env metadata_restore_env metadata_apply_patches metadata_run_hook metadata_create metadata_lint metadata_clear_cache metadata_get_sources metadata_get_api_info

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"
  case "$cmd" in
    --help) cat <<'EOF'
Usage: metadata.sh [options] <command>
Commands:
  --create <group> <name> [sub]   Create a metadata ini template
  --load <file>                   Load and cache a metafile
  --get <key>                     Get a metadata key (name, version, source.url, etc.)
  --validate <file>               Validate a metafile
  --apply-env <file>              Apply env vars from metafile
  --restore-env                   Restore previously applied env
  --apply-patches <file> [dir]    Apply patches for metafile (dir optional)
  --lint <path|file>              Lint metafiles under path or single file
  --clear-cache                   Clear parse cache
  --create-and-open <group> <name> Create and open an editor (if $EDITOR) - convenience
  --help
EOF
      exit 0 ;;
    --create)
      metadata_create "$2" "$3" "$4"
      exit $? ;;
    --load)
      metadata_load "$2"
      exit $? ;;
    --get)
      metadata_get "$2"
      exit $? ;;
    --validate)
      metadata_validate "$2"
      exit $? ;;
    --apply-env)
      metadata_load "$2" && metadata_apply_env
      exit $? ;;
    --restore-env)
      metadata_restore_env
      exit $? ;;
    --apply-patches)
      metadata_load "$2"
      metadata_apply_patches "$3"
      exit $? ;;
    --lint)
      metadata_lint "${2:-.}"
      exit $? ;;
    --clear-cache)
      metadata_clear_cache
      exit $? ;;
    --create-and-open)
      metadata_create "$2" "$3" "$4"
      file="${LFS_ROOT}/$2/$3/${3}.ini"
      if [ -n "${EDITOR:-}" ] && [ -f "$file" ]; then $EDITOR "$file"; fi
      exit $? ;;
    *) echo "Usage: metadata.sh --help"; exit 2 ;;
  esac
fi

# End of metadata.sh
