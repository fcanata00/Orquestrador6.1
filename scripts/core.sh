#!/usr/bin/env bash
# ============================================================================
# core.sh - Núcleo (fusão de lib.sh + env.sh) para LFS
# Descrição: define ambiente, funções utilitárias, validações e integra com register.sh
# Autor: ChatGPT (OpenAI)
# Versão: 1.0
# Licença: MIT
# ============================================================================

# Guard: evita carregamento múltiplo
if [ -n "${CORE_SH_LOADED-}" ]; then
  return 0 2>/dev/null || exit 0
fi
CORE_SH_LOADED=1

set -o errexit
set -o nounset
set -o pipefail

# ----------------------------
# Defaults (podem ser sobrescritos por core.conf ou ambiente)
# ----------------------------
: "${LFS_ROOT:=/mnt/lfs}"
: "${LFS:=${LFS_ROOT}}"
: "${LFS_TOOLS:=${LFS}/tools}"
: "${LFS_SRC:=${LFS}/sources}"
: "${LFS_BUILD:=${LFS}/build}"
: "${LFS_LOG_DIR:=/var/log/lfs}"
: "${LFS_CONF_DIR:=/etc/lfs}"
: "${CORE_CONF_FILE:=${LFS_CONF_DIR}/core.conf}"
: "${CORE_DEBUG:=0}"
: "${CORE_VERBOSE:=1}"
: "${CORE_FAIL_CLOSED:=0}"   # 0 = fail-open (padrão), 1 = fail-closed (abortar em faltas)
: "${CORE_LOCK_DIR:=/var/lock/lfs-core}"
: "${CORE_RETRY_MAX:=5}"
: "${CORE_RETRY_DELAY_MS:=100}"

# Initialize metrics/counters
CORE_OP_ERRORS=0
CORE_LOCK_WAIT=0
CORE_RETRIES=0

# ----------------------------
# Utility: logging integration (tentaremos usar register.sh se presente)
# ----------------------------
CORE_REGISTER_PATHS=( "./register.sh" "/usr/local/bin/register.sh" "/usr/local/lib/lfs/register.sh" "${LFS_ROOT}/scripts/register.sh" "/usr/lib/lfs/register.sh" )
CORE_REGISTER_LOADED=0

_core_simple_log() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts="$(date +'%Y-%m-%dT%H:%M:%S%z')"
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" >&2
}

_core_try_load_register() {
  # If register.sh already sourced (log functions exist), detect by checking function name
  if declare -F log_info >/dev/null 2>&1; then
    CORE_REGISTER_LOADED=1
    return 0
  fi
  for p in "${CORE_REGISTER_PATHS[@]}"; do
    [ -f "$p" ] || continue
    # shellcheck source=/dev/null
    source "$p" || continue
    if declare -F log_info >/dev/null 2>&1; then
      CORE_REGISTER_LOADED=1
      return 0
    fi
  done
  CORE_REGISTER_LOADED=0
  return 1
}

# Attempt load now
_core_try_load_register || true

# Provide wrapper functions that prefer register.sh if available
info()  { if [ "${CORE_REGISTER_LOADED}" -eq 1 ]; then log_info "$@"; else _core_simple_log "INFO" "$@"; fi }
warn()  { if [ "${CORE_REGISTER_LOADED}" -eq 1 ]; then log_warn "$@"; else _core_simple_log "WARN" "$@"; fi }
error() { if [ "${CORE_REGISTER_LOADED}" -eq 1 ]; then log_error "$@"; else _core_simple_log "ERROR" "$@"; fi }
debug() { if [ "${CORE_REGISTER_LOADED}" -eq 1 ]; then log_debug "$@"; else [ "$CORE_DEBUG" -ne 0 ] && _core_simple_log "DEBUG" "$@"; fi }
fatal() { if [ "${CORE_REGISTER_LOADED}" -eq 1 ]; then log_fatal "$@"; else _core_simple_log "FATAL" "$@"; exit 1; fi }

# ----------------------------
# Helper: safe export of variables (não exporta senhas acidentalmente)
# ----------------------------
_core_secret_patterns='(PASS|PASSWORD|SECRET|TOKEN|KEY|AWS|GPG)'

safe_export() {
  local name="$1" value="$2"
  if printf '%s' "$name" | grep -Eq "$_core_secret_patterns"; then
    warn "Skipping export of potential secret variable: $name"
    return 0
  fi
  export "$name"="$value"
}

# ----------------------------
# Config loader
# ----------------------------
load_config() {
  local conf_file="${1:-$CORE_CONF_FILE}"
  if [ -z "${conf_file:-}" ] || [ ! -f "$conf_file" ]; then
    debug "No config file found at $conf_file, skipping"
    return 0
  fi
  info "Loading config from $conf_file"
  # Only accept lines KEY=VALUE, comments starting with #
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}" # strip comments
    line="${line#"${line%%[![:space:]]*}"}" # ltrim
    [ -z "$line" ] && continue
    if printf '%s' "$line" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*='; then
      local key="${line%%=*}"
      local val="${line#*=}"
      # Remove possible surrounding quotes
      val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
      # Do not overwrite existing environment variables unless they are empty
      if [ -z "${!key-}" ]; then
        safe_export "$key" "$val"
      else
        debug "Skipping $key from config (already defined)"
      fi
    else
      warn "Ignoring invalid config line: $line"
    fi
  done < "$conf_file"
}

# ----------------------------
# Ensure directory with retries and ownership
# ----------------------------
ensure_dir() {
  local dir="${1:?usage: ensure_dir <dir> [owner:group] [mode]}"
  local owner="${2:-}"
  local mode="${3:-0755}"
  local tries=0
  while :; do
    if mkdir -p "$dir" 2>/dev/null; then
      chmod "$mode" "$dir" 2>/dev/null || true
      if [ -n "$owner" ]; then
        chown "$owner" "$dir" 2>/dev/null || true
      fi
      [ -d "$dir" ] || { ((tries++)); }
    else
      ((tries++))
    fi
    if [ -d "$dir" ]; then
      debug "ensure_dir: $dir ready (mode=$mode owner=${owner:-none})"
      return 0
    fi
    if [ "$tries" -ge 5 ]; then
      warn "ensure_dir failed for $dir after $tries tries"
      # fallback to HOME if allowed
      if [ "$CORE_FAIL_CLOSED" -eq 0 ]; then
        local fallback="${HOME}/.lfs/$(basename "$dir")"
        warn "Falling back to $fallback"
        mkdir -p "$fallback" 2>/dev/null || { error "Fallback also failed"; return 1; }
        return 0
      fi
      return 1
    fi
    sleep 0.1
  done
}

# ----------------------------
# Ensure file exists (touch) with checks
# ----------------------------
ensure_file() {
  local file="${1:?usage: ensure_file <file> [owner:group] [mode]}"
  local owner="${2:-}"; local mode="${3:-0644}"
  touch "$file" 2>/dev/null || true
  if [ ! -e "$file" ]; then
    warn "Failed to create $file"
    return 1
  fi
  chmod "$mode" "$file" 2>/dev/null || true
  [ -n "$owner" ] && chown "$owner" "$file" 2>/dev/null || true
  return 0
}

# ----------------------------
# Tool checks
# ----------------------------
check_tool() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

require_tool() {
  local cmd="$1"
  if ! check_tool "$cmd"; then
    error "Required tool '$cmd' not found in PATH"
    ((CORE_OP_ERRORS++))
    if [ "$CORE_FAIL_CLOSED" -eq 1 ]; then
      fatal "Aborting: missing required tool $cmd"
    fi
    return 1
  fi
  return 0
}

# ----------------------------
# Require user/root context
# ----------------------------
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fatal "This operation must be run as root"
  fi
}

require_user() {
  local want_user="$1"
  if [ "$(id -un)" != "$want_user" ]; then
    fatal "This operation must be run as user: $want_user"
  fi
}

# ----------------------------
# Disk space check
# ----------------------------
check_disk_space() {
  local path="${1:-/}"; local min_bytes="${2:-10485760}" # default 10MB
  if ! command -v df >/dev/null 2>&1; then
    warn "df not available; skipping disk space check"
    return 0
  fi
  local avail; avail=$(df -P "$path" 2>/dev/null | awk 'NR==2{print $4}') || avail=0
  avail=$((avail*1024))
  if [ "$avail" -lt "$min_bytes" ]; then
    warn "Low disk space on $path: ${avail} < ${min_bytes} bytes"
    ((CORE_OP_ERRORS++))
    return 1
  fi
  return 0
}

# ----------------------------
# Retries with exponential backoff
# ----------------------------
retry_cmd() {
  local max="${1:-$CORE_RETRY_MAX}"; shift
  local attempt=0 delay_ms="$CORE_RETRY_DELAY_MS"
  while :; do
    "$@" && return 0
    local rc=$?
    ((attempt++))
    ((CORE_RETRIES++))
    if [ "$attempt" -ge "$max" ]; then
      warn "retry_cmd: command failed after $attempt attempts (rc=$rc)"
      return "$rc"
    fi
    sleep "$(awk "BEGIN {print $delay_ms/1000}")"
    delay_ms=$(( delay_ms * 2 ))
  done
}

# ----------------------------
# with_lock: flock preferred, fallback to lockdir
# ----------------------------
with_lock() {
  local lockname="${1:?usage: with_lock <name> -- cmd...}"; shift
  local cmd=( "$@" )
  local lockfile="${CORE_LOCK_DIR}/${lockname}.lock"
  ensure_dir "$CORE_LOCK_DIR" || { error "Cannot create lock dir"; return 1; }
  if command -v flock >/dev/null 2>&1; then
    ( exec 9>"$lockfile"; flock -x 9; "${cmd[@]}" ) || return 1
  else
    local d="${lockfile}.d"; local tries=0
    until mkdir "$d" 2>/dev/null; do
      ((tries++)); ((CORE_LOCK_WAIT++))
      if [ "$tries" -gt 50 ]; then
        warn "with_lock: timeout obtaining lock $lockname"
        return 1
      fi
      sleep 0.1
    done
    "${cmd[@]}"; local rc=$?
    rmdir "$d" 2>/dev/null || true
    return "$rc"
  fi
}

# ----------------------------
# run_safe: captura saída, rc e loga adequadamente
# ----------------------------
run_safe() {
  local desc="$1"; shift
  if [ "$#" -eq 0 ]; then
    error "run_safe usage: run_safe <desc> -- <cmd> [args...]"; return 2
  fi
  local out; out="$("$@" 2>&1)" || { local rc=$?; error "$desc failed (rc=$rc): $(sed 's/^/  /' <<<"$out")"; return "$rc"; }
  debug "$desc OK"
  printf '%s\n' "$out"
  return 0
}

# ----------------------------
# capture_output: captura stdout em uma variável (nome passado por referência)
# ----------------------------
capture_output() {
  local __var="$1"; shift
  local out; out="$("$@" 2>&1)" || { local rc=$?; printf -v "$__var" '%s' "$out"; return "$rc"; }
  printf -v "$__var" '%s' "$out"
  return 0
}

# ----------------------------
# core cleanup (traps)
# ----------------------------
_core_cleanup() {
  # implement cleanup: remove stale lockdirs no-owner older than X
  # liberar recursos, salvar metrics se necessário
  debug "core cleanup running"
  return 0
}
trap '_core_cleanup' EXIT

# ----------------------------
# Health & status
# ----------------------------
core_status() {
  cat <<EOF
CORE STATUS
  LFS_ROOT: ${LFS_ROOT}
  LFS: ${LFS}
  LFS_TOOLS: ${LFS_TOOLS}
  LFS_SRC: ${LFS_SRC}
  CORE_DEBUG: ${CORE_DEBUG}
  CORE_VERBOSE: ${CORE_VERBOSE}
  CORE_FAIL_CLOSED: ${CORE_FAIL_CLOSED}
  CORE_RETRIES: ${CORE_RETRIES}
  CORE_OP_ERRORS: ${CORE_OP_ERRORS}
  CORE_LOCK_WAIT: ${CORE_LOCK_WAIT}
EOF
}

# ----------------------------
# Self-test and unit-tests harness
# ----------------------------
core_self_test() {
  info "Running core.sh self-test..."
  local errors=0
  # test load_config (noop if none)
  load_config || { warn "load_config failed"; ((errors++)); }
  # test ensure_dir
  local tmpd; tmpd="$(mktemp -d -t core_test.XXXX)" || { error "mktemp failed"; return 1; }
  if ! ensure_dir "$tmpd/testdir" "root:root" "0755"; then
    warn "ensure_dir test failed"; ((errors++))
  fi
  # test ensure_file
  if ! ensure_file "$tmpd/testdir/testfile" "root:root" "0644"; then
    warn "ensure_file test failed"; ((errors++))
  fi
  # test run_safe success and failure
  run_safe "echo hello" sh -c 'echo hello' >/dev/null || { warn "run_safe echo failed"; ((errors++)); }
  if run_safe "false command" false >/dev/null 2>&1; then
    warn "run_safe false did not fail as expected"; ((errors++))
  fi
  # test with_lock concurrency (simple)
  with_lock core_test_lock sh -c 'sleep 0.1; echo locked' >/dev/null || { warn "with_lock failed"; ((errors++)); }
  # disk check (may be skipped)
  check_disk_space "/" 1024 || warn "check_disk_space reported low, but continuing"
  rm -rf "$tmpd"
  if [ "$errors" -ne 0 ]; then
    error "Self-test found $errors problem(s)"
    return 2
  fi
  info "Self-test OK"
  return 0
}

# ----------------------------
# run-tests: simple test harness that reports NDJSON-like lines
# ----------------------------
core_run_tests() {
  core_self_test
}

# ----------------------------
# Export public API (helpers for other scripts)
# ----------------------------
# Note: export -f may not be supported in /bin/sh; this is for bash environments.
export -f ensure_dir ensure_file check_tool require_tool require_root require_user \
  check_disk_space retry_cmd with_lock run_safe capture_output core_status core_self_test core_run_tests

# ----------------------------
# CLI
# ----------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --self-test) core_self_test ; exit $? ;;
    --run-tests) core_run_tests ; exit $? ;;
    --status) core_status ; exit 0 ;;
    *) echo "Usage: core.sh [--self-test|--run-tests|--status]"; exit 2 ;;
  esac
fi

# EOF
