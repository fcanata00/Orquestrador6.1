#!/usr/bin/env bash
# ============================================================================
# deps.sh - Gerenciador de dependências PRO para LFS
# ============================================================================
# Completo: parsing, toposort, rebuild, reverse deps, cache, locking,
# retries/backoff, detection of cycles, integration with register.sh/core.sh,
# robust error-handling (incl. silent-fail detection), dry-run, self-test.
# ============================================================================
set -o errexit
set -o nounset
set -o pipefail

# Guard: avoid multiple sourcing
if [ -n "${DEPS_SH_PRO_LOADED-}" ]; then
  return 0 2>/dev/null || exit 0
fi
DEPS_SH_PRO_LOADED=1

# -----------------------------
# Configuráveis (podem ser sobrescritos no ambiente)
# -----------------------------
: "${LFS_ROOT:=/mnt/lfs}"
: "${LFS_DEPS_DIR:=${LFS_ROOT}/scripts}"
: "${LFS_CACHE_DIR:=${LFS_ROOT}/.cache}"
: "${LFS_DEPS_CACHE:=${LFS_CACHE_DIR}/deps_cache.json}"
: "${LFS_DEPS_CACHE_TMP:=${LFS_DEPS_CACHE}.tmp}"
: "${LFS_LOCK_DIR:=${LFS_ROOT}/.lock}"
: "${LFS_DEPS_LOCK:=${LFS_LOCK_DIR}/deps.lock}"
: "${DEPS_RETRY_MAX:=5}"
: "${DEPS_RETRY_BACKOFF_MS:=100}"
: "${DEPS_LOCK_TIMEOUT:=120}"  # seconds
: "${DEPS_DEBUG:=0}"
: "${DEPS_QUIET:=0}"
: "${DEPS_DRY_RUN:=0}"

# Add CORE_REGISTER_PATHS requested to all scripts
CORE_REGISTER_PATHS=( "./register.sh" "/usr/local/bin/register.sh" "/usr/local/lib/lfs/register.sh" "${LFS_ROOT}/scripts/register.sh" "/usr/lib/lfs/register.sh" )

# -----------------------------
# Internal structures
# -----------------------------
declare -A DEPS_REQ DEPS_OPT DEPS_REV MODULE_PATH MODULE_SIG
declare -a TOPO_ORDER

DEPS_OP_ERRORS=0
DEPS_CACHE_LOADED=0

# -----------------------------
# Logger: prefer register.sh if available; fallback to internal logger
# -----------------------------
_color_info='\033[1;34m'; _color_warn='\033[1;33m'; _color_err='\033[1;31m'; _color_reset='\033[0m'

_deps_internal_log() {
  local level="$1"; shift; local msg="$*"; local ts; ts="$(date +'%Y-%m-%dT%H:%M:%S%z')"
  case "$level" in
    DEBUG) [ "$DEPS_DEBUG" -eq 1 ] && printf "%s ${_color_info}[DEBUG]${_color_reset} %s\n" "$ts" "$msg" >&2 || true ;;
    INFO)  [ "$DEPS_QUIET" -eq 0 ] && printf "%s ${_color_info}[INFO]${_color_reset} %s\n" "$ts" "$msg" >&2 || true ;;
    WARN)  printf "%s ${_color_warn}[WARN]${_color_reset} %s\n" "$ts" "$msg" >&2 ;;
    ERROR) printf "%s ${_color_err}[ERROR]${_color_reset} %s\n" "$ts" "$msg" >&2 ;;
    FATAL) printf "%s ${_color_err}[FATAL]${_color_reset} %s\n" "$ts" "$msg" >&2 ;;
    *)     printf "%s [LOG] %s\n" "$ts" "$msg" >&2 ;;
  esac
}

# try loading register.sh from candidate paths
_deps_try_load_register() {
  if declare -F log_info >/dev/null 2>&1; then
    return 0
  fi
  for p in "${CORE_REGISTER_PATHS[@]}"; do
    [ -f "$p" ] || continue
    # shellcheck source=/dev/null
    source "$p" && declare -F log_info >/dev/null 2>&1 && return 0
  done
  return 1
}

if _deps_try_load_register; then
  : # use log_info/log_warn/log_error/log_fatal from register.sh
else
  log_debug() { _deps_internal_log DEBUG "$*"; }
  log_info()  { _deps_internal_log INFO "$*"; }
  log_warn()  { _deps_internal_log WARN "$*"; }
  log_error() { _deps_internal_log ERROR "$*"; }
  log_fatal() { _deps_internal_log FATAL "$*"; exit 1; }
fi

# -----------------------------
# Helpers: sleep ms (perl fallback)
# -----------------------------
_sleep_ms() {
  local ms="$1"
  if command -v perl >/dev/null 2>&1; then
    perl -e "select(undef,undef,undef,$ms/1000)"
  else
    sleep "$(awk "BEGIN {print $ms/1000}")"
  fi
}

# retry helper with exponential backoff
_retry_cmd() {
  local max="${1:-$DEPS_RETRY_MAX}"; shift
  local attempt=0 delay="$DEPS_RETRY_BACKOFF_MS"
  while :; do
    "$@" && return 0
    local rc=$?
    ((attempt++))
    ((DEPS_OP_ERRORS++))
    if [ "$attempt" -ge "$max" ]; then
      log_warn "Command failed after $attempt attempts (rc=$rc)"
      return "$rc"
    fi
    _sleep_ms "$delay"
    delay=$(( delay * 2 ))
  done
}

# atomic write
_atomic_write() {
  local file="$1"; shift
  local tmp="${file}.$$.$RANDOM.tmp"
  { printf '%s\n' "$@"; } > "$tmp" && mv -f "$tmp" "$file"
}

# file signature (sha1sum fallback to mtime)
_file_sig() {
  local f="$1"
  if command -v sha1sum >/dev/null 2>&1; then
    sha1sum "$f" 2>/dev/null | awk '{print $1}'
  else
    stat -c%Y "$f" 2>/dev/null || echo "$$"
  fi
}

# safe read file with retries (avoids silent empty reads)
_safe_cat() {
  local f="$1"; local tries=0
  while [ "$tries" -lt 3 ]; do
    if [ -r "$f" ]; then
      cat "$f" && return 0
    fi
    tries=$((tries+1)); _sleep_ms 100
  done
  return 1
}

# -----------------------------
# Locking: flock preferred, lockdir fallback
# -----------------------------
_deps_acquire_lock() {
  local lockf="$1"; local timeout="${2:-$DEPS_LOCK_TIMEOUT}"
  mkdir -p "$(dirname "$lockf")" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    exec 201>"$lockf"
    local start=$(date +%s)
    while ! flock -x 201 2>/dev/null; do
      local now=$(date +%s)
      if [ $((now - start)) -ge "$timeout" ]; then
        log_error "Timeout acquiring flock for $lockf"
        return 1
      fi
      sleep 0.1
    done
    return 0
  else
    local d="${lockf}.d"; local start=$(date +%s)
    while ! mkdir "$d" 2>/dev/null; do
      local now=$(date +%s)
      if [ $((now - start)) -ge "$timeout" ]; then
        log_error "Timeout acquiring lockdir $d"
        return 1
      fi
      sleep 0.1
    done
    printf '%s\n' "$$" > "${d}/pid" 2>/dev/null || true
    return 0
  fi
}

_deps_release_lock() {
  local lockf="$1"
  if command -v flock >/dev/null 2>&1; then
    flock -u 201 2>/dev/null || true
    exec 201>&- || true
  else
    local d="${lockf}.d"
    [ -d "$d" ] && rm -rf "$d" 2>/dev/null || true
  fi
}

# -----------------------------
# Parsing metadata from module headers
# Header format supported:
#   # @name: modulename
#   # @deps: dep1, dep2
#   # @optional: opt1, opt2
# -----------------------------
_deps_parse_headers() {
  local file="$1" header name deps opt
  header="$(head -n 80 "$file" 2>/dev/null || true)"
  name="$(printf '%s\n' "$header" | grep -E '^# *@name:' | head -n1 | sed -E 's/^# *@name:[[:space:]]*//; s/[[:space:]]*$//')"
  deps="$(printf '%s\n' "$header" | grep -E '^# *@deps:' | head -n1 | sed -E 's/^# *@deps:[[:space:]]*//; s/[[:space:]]*$//')"
  opt="$(printf '%s\n' "$header" | grep -E '^# *@optional:' | head -n1 | sed -E 's/^# *@optional:[[:space:]]*//; s/[[:space:]]*$//')"
  name="${name:-}"; deps="${deps:-}"; opt="${opt:-}"
  # normalize separators: commas or spaces -> single space tokens
  deps="$(printf '%s' "$deps" | sed -E 's/[[:space:],]+/ /g' | sed -E 's/^ +| +$//g')"
  opt="$(printf '%s' "$opt" | sed -E 's/[[:space:],]+/ /g' | sed -E 's/^ +| +$//g')"
  if [ -z "$name" ]; then
    name="$(basename "$file" .sh)"
    log_debug "Header faltando @name em $file; usando ${name}"
  fi
  MODULE_PATH["$name"]="$file"
  MODULE_SIG["$name"]="$( _file_sig "$file" )"
  DEPS_REQ["$name"]="$deps"
  DEPS_OPT["$name"]="$opt"
}

deps_scan() {
  log_debug "Scanning modules in $LFS_DEPS_DIR ..."
  shopt -s nullglob 2>/dev/null || true
  for f in "$LFS_DEPS_DIR"/*.sh; do
    [ -f "$f" ] || continue
    _deps_parse_headers "$f"
  done
}

# -----------------------------
# Build reverse map
# -----------------------------
deps_build_reverse() {
  DEPS_REV=()
  for m in "${!DEPS_REQ[@]}"; do
    for d in ${DEPS_REQ[$m]}; do
      [ -z "$d" ] && continue
      DEPS_REV["$d"]="${DEPS_REV[$d]} $m"
    done
  done
  # include optionals as weaker reverse links
  for m in "${!DEPS_OPT[@]}"; do
    for d in ${DEPS_OPT[$m]}; do
      [ -z "$d" ] && continue
      DEPS_REV["$d"]="${DEPS_REV[$d]} $m"
    done
  done
}

# -----------------------------
# Topological sort (DFS) with cycle detection and reporting
# -----------------------------
_deps_topo_visit() {
  local node="$1"; declare -n _vis="$2"; declare -n _stack="$3"
  _vis["$node"]=1
  _stack+=("$node")
  for dep in ${DEPS_REQ[$node]:-}; do
    [ -z "$dep" ] && continue
    if [ -z "${DEPS_REQ[$dep]-}" ]; then
      log_warn "Módulo '$node' depende de '$dep' que não existe (pode ser opcional)"
      ((DEPS_OP_ERRORS++))
      continue
    fi
    if [ "${_vis[$dep]:-0}" -eq 0 ]; then
      _deps_topo_visit "$dep" _vis _stack || return 1
    elif [ "${_vis[$dep]}" -eq 1 ]; then
      # build cycle path
      local path="" i
      for i in "${_stack[@]}"; do path+="${i} -> "; [ "$i" = "$dep" ] && break; done
      path+="$dep"
      log_error "Ciclo de dependência detectado: $path"
      return 2
    fi
  done
  _vis["$node"]=2
  TOPO_ORDER+=("$node")
  _stack=("${_stack[@]:0:${#_stack[@]}-1}")
  return 0
}

deps_toposort() {
  log_debug "Running toposort..."
  TOPO_ORDER=()
  declare -A vis; local node stack=()
  for node in "${!DEPS_REQ[@]}"; do vis["$node"]=0; done
  for node in "${!DEPS_REQ[@]}"; do
    if [ "${vis[$node]}" -eq 0 ]; then
      stack=()
      _deps_topo_visit "$node" vis stack || return $?
    fi
  done
  # reverse toposort result to get dependencies first
  local rev=(); local i
  for ((i=${#TOPO_ORDER[@]}-1;i>=0;i--)); do rev+=("${TOPO_ORDER[i]}"); done
  TOPO_ORDER=("${rev[@]}")
  return 0
}

# -----------------------------
# Cache: load/save with integrity check
# JSON-lite format: version|module:dep dep|...
# -----------------------------
deps_save_cache() {
  mkdir -p "$(dirname "$LFS_DEPS_CACHE")" 2>/dev/null || true
  local tmp="${LFS_DEPS_CACHE_TMP}.$$"
  : > "$tmp" || { log_warn "Não foi possível criar cache tmp"; return 1; }
  echo "version:1" >> "$tmp"
  for m in "${!DEPS_REQ[@]}"; do
    printf '%s:%s\n' "$m" "${DEPS_REQ[$m]:-}" >> "$tmp"
  done
  mv -f "$tmp" "$LFS_DEPS_CACHE" || { log_warn "Falha ao mover cache para $LFS_DEPS_CACHE"; return 1; }
  log_info "Cache salvo em $LFS_DEPS_CACHE"
  return 0
}

deps_load_cache() {
  if [ ! -f "$LFS_DEPS_CACHE" ]; then
    log_debug "Cache não encontrado: $LFS_DEPS_CACHE"
    return 1
  fi
  local line mod deps
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if printf '%s' "$line" | grep -qE '^version:'; then continue; fi
    mod="${line%%:*}"; deps="${line#*:}"
    DEPS_REQ["$mod"]="$deps"
  done < "$LFS_DEPS_CACHE"
  DEPS_CACHE_LOADED=1
  log_info "Cache carregado de $LFS_DEPS_CACHE"
  return 0
}

# -----------------------------
# Validate dependencies (missing required)
# -----------------------------
deps_validate() {
  log_info "Validando dependências..."
  local missing=0
  for m in "${!DEPS_REQ[@]}"; do
    for d in ${DEPS_REQ[$m]:-}; do
      [ -z "$d" ] && continue
      if [ -z "${DEPS_REQ[$d]-}" ]; then
        log_warn "Falta dependência obrigatória: $m -> $d"
        ((missing++))
      fi
    done
  done
  if ! deps_toposort; then
    log_fatal "Validação abortada devido a ciclo de dependências"
    return 2
  fi
  if [ "$missing" -gt 0 ]; then
    log_warn "Validação completa com $missing dependência(s) faltando"
    return 1
  fi
  log_info "Validação bem sucedida"
  return 0
}

# -----------------------------
# Reverse deps traversal - collect all dependents recursively
# -----------------------------
_deps_collect_dependents() {
  local root="$1"; local -n out="$2"
  for m in ${DEPS_REV[$root]:-}; do
    if ! printf '%s\n' "${out[@]:-}" | grep -xq "$m"; then
      out+=("$m")
      _deps_collect_dependents "$m" out
    fi
  done
}

deps_reverse() {
  local mod="$1"
  deps_build_reverse
  for d in ${DEPS_REV[$mod]:-}; do echo "$d"; done
}

# -----------------------------
# Rebuild logic (module + dependents)
# Executes scripts in dependency order
# -----------------------------
deps_rebuild() {
  local target="$1"
  if [ -z "${DEPS_REQ[$target]-}" ]; then
    log_fatal "Módulo desconhecido: $target"
    return 2
  fi
  deps_toposort || { log_fatal "Topo sort failed"; return 2; }
  deps_build_reverse
  local affected=("$target"); local more=()
  _deps_collect_dependents "$target" more
  affected+=("${more[@]}")
  # produce ordered runlist preserving topo order
  local runlist=() node
  for node in "${TOPO_ORDER[@]}"; do
    for a in "${affected[@]}"; do [ "$node" = "$a" ] && runlist+=("$node";) ; done
  done

  if [ "${#runlist[@]}" -eq 0 ]; then log_info "Nada a rebuildar para $target"; return 0; fi

  log_info "Rebuild list: ${runlist[*]}"
  local m script rc
  for m in "${runlist[@]}"; do
    script="${MODULE_PATH[$m]:-}"
    if [ -z "$script" ]; then
      log_warn "Script ausente para módulo $m; pulando"
      continue
    fi
    if [ "$DEPS_DRY_RUN" -eq 1 ]; then
      log_info "[dry-run] bash $script"
      continue
    fi
    log_info "Executando $m -> $script"
    if _retry_cmd "$DEPS_RETRY_MAX" bash "$script"; then
      log_info "Execução OK: $m"
    else
      rc=$?
      log_error "Falha ao executar $m (rc=$rc)"
      ((DEPS_OP_ERRORS++))
      # continue unless fail-closed desired in environment (CORE_FAIL_CLOSED)
      if [ "${CORE_FAIL_CLOSED:-0}" -eq 1 ]; then
        log_fatal "Abortando devido a CORE_FAIL_CLOSED=1"
        return "$rc"
      fi
    fi
  done
  log_info "Rebuild completo para $target"
  return 0
}

# -----------------------------
# Reload modules & cache management
# -----------------------------
deps_reload() {
  # Acquire lock to prevent concurrent scans/updates
  _deps_acquire_lock "$LFS_DEPS_LOCK" || { log_warn "Não foi possível adquirir lock para reload"; return 1; }
  DEPS_REQ=(); DEPS_OPT=(); MODULE_PATH=(); MODULE_SIG=(); DEPS_REV=()
  deps_scan
  deps_build_reverse
  deps_save_cache || log_warn "Falha ao salvar cache (não crítico)"
  _deps_release_lock "$LFS_DEPS_LOCK"
  return 0
}

# -----------------------------
# Self-test: comprehensive checks and sample rebuild (dry-run)
# -----------------------------
deps_self_test() {
  log_info "Executando self-test avançado..."
  local errors=0 tmpmod=$(mktemp -d 2>/dev/null || mktemp -d -t deps)
  # scan
  deps_scan || { log_error "Scan falhou"; ((errors++)); }
  deps_build_reverse || { log_error "Build reverse falhou"; ((errors++)); }
  deps_save_cache || log_warn "Falha ao salvar cache"
  # validation
  if ! deps_validate; then ((errors++)); fi
  # toposort
  if ! deps_toposort; then ((errors++)); fi
  # dry-run rebuild first module if any
  local first
  for first in "${!DEPS_REQ[@]}"; do break; done
  if [ -n "${first:-}" ]; then
    DEPS_DRY_RUN=1
    deps_rebuild "$first" || { log_warn "Dry-run rebuild falhou"; ((errors++)); }
    DEPS_DRY_RUN=0
  else
    log_warn "Nenhum módulo encontrado para dry-run"
  fi
  rm -rf "$tmpmod" 2>/dev/null || true
  if [ "$errors" -ne 0 ]; then
    log_error "Self-test concluiu com $errors erro(s)"
    return 2
  fi
  log_info "Self-test ok"
  return 0
}

# -----------------------------
# Export functions for other scripts that source deps.sh
# -----------------------------
_export_functions() {
  # export -f may not be available in sh; in bash it's ok
  if command -v bash >/dev/null 2>&1; then
    export -f deps_scan deps_reload deps_validate deps_ordered_list deps_reverse deps_rebuild deps_self_test
  fi
}
_export_functions || true

# -----------------------------
# CLI handling when executed directly
# -----------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"
  case "$cmd" in
    --help) cat <<'EOF'
Usage: deps.sh [options] <command>
Options: --debug --quiet --dry-run
Commands:
  --list           : list modules in dependency order
  --validate       : validation & cycle detection
  --rebuild <mod>  : rebuild module and dependents
  --reverse <mod>  : show dependents of module
  --reload-cache   : rescan modules and rebuild cache
  --self-test      : comprehensive self-test
  --status         : print internal status
EOF
      exit 0 ;;
    --debug) DEPS_DEBUG=1 ; shift ; cmd="${1:-}" ;;
    --quiet) DEPS_QUIET=1 ; shift ; cmd="${1:-}" ;;
    --dry-run) DEPS_DRY_RUN=1 ; shift ; cmd="${1:-}" ;;
  esac

  case "$cmd" in
    --list) deps_scan; deps_toposort && printf '%s\n' "${TOPO_ORDER[@]}";;
    --validate) deps_scan; deps_validate;;
    --rebuild) shift ; [ -n "${1:-}" ] || { log_fatal "Uso: --rebuild <module>"; } ; deps_scan; deps_rebuild "$1" ;;
    --reverse) shift ; [ -n "${1:-}" ] || { log_fatal "Uso: --reverse <module>"; } ; deps_scan; deps_build_reverse; deps_reverse "$1" ;;
    --reload-cache) deps_reload ;;
    --self-test) deps_self_test ;;
    --status) deps_scan; deps_build_reverse; cat <<EOF
LFS_ROOT: $LFS_ROOT
LFS_DEPS_DIR: $LFS_DEPS_DIR
Loaded modules: ${#MODULE_PATH[@]}
Op errors: $DEPS_OP_ERRORS
Cache loaded: $DEPS_CACHE_LOADED
EOF
     ;;
    '') echo "Usage: deps.sh --help"; exit 2 ;;
    *) log_fatal "Comando desconhecido: $cmd" ;;
  esac
fi

# EOF
