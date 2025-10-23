#!/usr/bin/env bash
# hooks.sh - execução segura de hooks (pre/post prepare, compile, install, uninstall)
# - hooks são scripts em <PKG_DIR>/hooks/*.sh ou em diretório fornecido
# - execução em subshell, timeout por hook, logs separados, validações de segurança
set -eEuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="hooks"
# -------------------------
# Defaults (overrides via env)
# -------------------------
: "${HOOKS_DIR:=${HOOKS_DIR:-./hooks}}"
: "${HOOKS_LOG_DIR:=${HOOKS_LOG_DIR:-/var/log/hooks}}"
: "${HOOKS_TMP_DIR:=${HOOKS_TMP_DIR:-/tmp/hooks.$$}}"
: "${HOOKS_TIMEOUT_SECS:=300}"       # default 5 minutes
: "${HOOKS_SILENT:=false}"
: "${HOOKS_DEBUG:=false}"
: "${HOOKS_MAX_LOG_BYTES:=1048576}"  # 1 MB rotation threshold
: "${HOOKS_LOCK_DIR:=${HOOKS_LOG_DIR}/locks}"
: "${HOOKS_TRUST:=false}"           # if true, relax some security checks
: "${HOOKS_SHCMD:=/bin/bash}"

# Internal state
_HOOKS_INITIALIZED=false
_HOOKS_STATS_TOTAL=0
_HOOKS_STATS_OK=0
_HOOKS_STATS_FAIL=0
declare -a _HOOKS_RUN_HISTORY=()

# -------------------------
# Logging - integrate register.sh if available
# -------------------------
_hlog() {
  local level="$1"; shift; local msg="$*"
  if type register_info >/dev/null 2>&1; then
    case "$level" in
      INFO)  register_info "$msg";;
      WARN)  register_warn "$msg";;
      ERROR) register_error "$msg";;
      DEBUG) register_debug "$msg";;
      *) register_info "$msg";;
    esac
  else
    [[ "${HOOKS_SILENT}" == "true" && "$level" != "ERROR" ]] && return 0
    case "$level" in
      INFO)  printf '%s %s\n' "[INFO]" "$msg";;
      WARN)  printf '%s %s\n' "[WARN]" "$msg" >&2;;
      ERROR) printf '%s %s\n' "[ERROR]" "$msg" >&2;;
      DEBUG) [[ "${HOOKS_DEBUG}" == "true" ]] && printf '%s %s\n' "[DEBUG]" "$msg";;
      *) printf '%s %s\n' "[LOG]" "$msg";;
    esac
  fi
}

# -------------------------
# Safety helpers
# -------------------------
_safe_mkdir() { mkdir -p "$1" 2>/dev/null || _hlog ERROR "Não foi possível criar $1"; chmod 750 "$1" || true; }

_sanitize_hook_name() {
  # allow only simple filenames (alnum, - _ .)
  local name="$1"
  if [[ "$name" =~ [^A-Za-z0-9._-] ]]; then
    printf '%s' ""
  else
    printf '%s' "$name"
  fi
}

_hook_rotate_if_needed() {
  local logfile="$1"
  if [[ -f "$logfile" ]]; then
    local bytes
    bytes=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
    if (( bytes > HOOKS_MAX_LOG_BYTES )); then
      for ((i=4;i>=1;i--)); do
        if [[ -f "${logfile}.${i}" ]]; then mv -f "${logfile}.${i}" "${logfile}.$((i+1))" || true; fi
      done
      mv -f "${logfile}" "${logfile}.1" || true
      : > "${logfile}"
    fi
  fi
}

# -------------------------
# Init / cleanup
# -------------------------
hooks_init() {
  if [[ "${_HOOKS_INITIALIZED}" == "true" ]]; then return 0; fi
  umask 027
  _safe_mkdir "${HOOKS_LOG_DIR}"
  _safe_mkdir "${HOOKS_TMP_DIR}"
  _safe_mkdir "${HOOKS_LOCK_DIR}"
  trap 'hooks_cleanup' EXIT INT TERM
  _HOOKS_INITIALIZED=true
  _hlog INFO "hooks inicializado (HOOKS_DIR=${HOOKS_DIR}, LOG_DIR=${HOOKS_LOG_DIR})"
}

hooks_cleanup() {
  # remove temp dir if created by us and owned by process
  if [[ -d "${HOOKS_TMP_DIR}" ]]; then
    rm -rf "${HOOKS_TMP_DIR}" || true
  fi
}

# -------------------------
# Validate hooks directory and individual hook scripts
# -------------------------
hooks_validate() {
  local dir="${1:-${HOOKS_DIR}}"
  local allow_trust="${2:-${HOOKS_TRUST}}"
  hooks_init
  if [[ ! -d "$dir" ]]; then
    _hlog WARN "Diretório de hooks não existe: $dir"
    return 1
  fi
  local ok=0 fail=0
  while IFS= read -r -d $'\0' f; do
    local base; base=$(basename "$f")
    # basic name checks
    if [[ "$base" == .* ]]; then
      _hlog WARN "Ignorando hook oculto: $base"; ((fail++)); continue
    fi
    if [[ "$base" =~ [^A-Za-z0-9._-] ]]; then
      _hlog WARN "Nome do hook inválido: $base"; ((fail++)); continue
    fi
    if [[ ! -f "$f" ]]; then
      _hlog WARN "Hook não é arquivo regular: $f"; ((fail++)); continue
    fi
    if [[ ! -x "$f" && "$allow_trust" != "true" ]]; then
      _hlog WARN "Hook não executável (use ./hooks --trust para aceitar): $base"; ((fail++)); continue
    fi
    # size
    if [[ $(stat -c%s "$f" 2>/dev/null || echo 0) -eq 0 ]]; then
      _hlog WARN "Hook vazio: $base"; ((fail++)); continue
    fi
    ((ok++))
  done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null)
  _hlog INFO "Validação de hooks em '$dir': OK=$ok FAIL=$fail"
  (( fail == 0 )) && return 0 || return 2
}

# -------------------------
# List hooks
# -------------------------
hooks_list() {
  local dir="${1:-${HOOKS_DIR}}"
  hooks_init
  if [[ ! -d "$dir" ]]; then
    _hlog WARN "Diretório de hooks inexistente: $dir"; return 1
  fi
  find "$dir" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort
}

# -------------------------
# Internal: run a single hook file with timeout, logs, isolation
# -------------------------
_hooks_run_file() {
  local hookfile="$1"
  local builddir="${2:-.}"
  local stage="${3:-unknown}"
  local timeout_secs="${4:-${HOOKS_TIMEOUT_SECS}}"
  local hookname; hookname=$(basename "$hookfile")
  local safe_hookname; safe_hookname=$(_sanitize_hook_name "$hookname")
  if [[ -z "$safe_hookname" ]]; then
    _hlog ERROR "Nome de hook inseguro: $hookname"; return 2
  fi
  if [[ ! -f "$hookfile" ]]; then
    _hlog WARN "Hook não encontrado: $hookfile"; return 3
  fi
  if [[ ! -x "$hookfile" && "${HOOKS_TRUST}" != "true" ]]; then
    _hlog WARN "Hook não executável (use HOOKS_TRUST=true para ignorar): $hookfile"; return 4
  fi

  local logf="${HOOKS_LOG_DIR}/${safe_hookname}-${stage}.log"
  _hook_rotate_if_needed "$logf"

  # Acquire per-hook lock
  local lockfile="${HOOKS_LOCK_DIR}/${safe_hookname}.lock"
  exec {HOOK_FD}>>"${lockfile}" || { _hlog WARN "Não pode abrir lockfile ${lockfile}"; }
  flock -n "${HOOK_FD}" || {
    _hlog WARN "Hook ${safe_hookname} já em execução, esperando..."
    flock "${HOOK_FD}" || true
  }

  _hlog INFO "Executando hook ${safe_hookname} para stage ${stage}"
  local start_ts; start_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local status=0
  # Execute in subshell, cd into builddir, with controlled environment
  (
    set -eEuo pipefail
    cd "$builddir"
    # minimal sanitized environment
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
    export PKG_NAME="${PKG_NAME:-}"
    export PKG_VERSION="${PKG_VERSION:-}"
    # run with timeout if available
    if command -v timeout >/dev/null 2>&1; then
      timeout --preserve-status "${timeout_secs}" "${HOOKS_SHCMD}" "$hookfile"
    else
      "${HOOKS_SHCMD}" "$hookfile"
    fi
  ) >"${logf}.out" 2>"${logf}.err" || status=$?

  local end_ts; end_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if (( status == 0 )); then
    _hlog INFO "Hook ${safe_hookname} concluído: status=0, logs: ${logf}.out"
    _HOOKS_STATS_OK=$(( _HOOKS_STATS_OK + 1 ))
    _HOOKS_RUN_HISTORY+=("${safe_hookname}:${stage}:ok:${start_ts}:${end_ts}")
  else
    _hlog ERROR "Hook ${safe_hookname} falhou com status=${status}. ver ${logf}.err"
    _HOOKS_STATS_FAIL=$(( _HOOKS_STATS_FAIL + 1 ))
    _HOOKS_RUN_HISTORY+=("${safe_hookname}:${stage}:fail:${start_ts}:${end_ts}:${status}")
    # for pre-* hooks, signal fatal to caller by returning status
  fi

  # Release lock
  eval "exec ${HOOK_FD}>&-"
  return "${status}"
}

# -------------------------
# Run hooks by stage (pre-prepare, post-compile, etc.)
# -------------------------
hooks_run() {
  local stage="$1"; local builddir="${2:-.}"; local dir="${3:-${HOOKS_DIR}}"
  hooks_init
  if [[ -z "$stage" ]]; then _hlog ERROR "hooks_run: stage requerido"; return 2; fi
  if [[ ! -d "$dir" ]]; then _hlog INFO "No hooks dir: $dir"; return 0; fi

  local executed=0
  # Consider files named like pre-prepare.sh, pre-prepare-1.sh etc.
  while IFS= read -r -d $'\0' hookpath; do
    local base; base=$(basename "$hookpath")
    # Only run hooks matching stage prefix (e.g., pre-prepare)
    if [[ "$base" == "${stage}"* ]]; then
      executed=$((executed+1))
      _HOOKS_STATS_TOTAL=$(( _HOOKS_STATS_TOTAL + 1 ))
      # run hook
      _hooks_run_file "$hookpath" "$builddir" "$stage" || {
        # if hook is a pre-* hook, abort the process
        if [[ "$stage" == pre-* ]]; then
          _hlog ERROR "Pre-hook ${base} falhou — abortando sequência"
          return 10
        else
          _hlog WARN "Hook ${base} falhou (post-*), continuando"
        fi
      }
    fi
  done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
  if (( executed == 0 )); then
    _hlog DEBUG "Nenhum hook para stage ${stage} em ${dir}"
  fi
  return 0
}

# -------------------------
# Summary
# -------------------------
hooks_summary() {
  hooks_init
  echo "Hooks summary:"
  echo "  Total attempted: ${_HOOKS_STATS_TOTAL}"
  echo "  Success:         ${_HOOKS_STATS_OK}"
  echo "  Failures:        ${_HOOKS_STATS_FAIL}"
  echo "  History:"
  for entry in "${_HOOKS_RUN_HISTORY[@]:-}"; do
    echo "    - ${entry}"
  done
  echo "  Logs dir: ${HOOKS_LOG_DIR}"
}

# -------------------------
# CLI
# -------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  case "$cmd" in
    --init)
      hooks_init
      _hlog INFO "Inicializado"
      exit 0
      ;;
    --list)
      dir="${2:-${HOOKS_DIR}}"
      hooks_list "$dir"
      exit 0
      ;;
    --validate)
      dir="${2:-${HOOKS_DIR}}"
      trust="${3:-${HOOKS_TRUST}}"
      hooks_validate "$dir" "$trust"
      exit $?
      ;;
    --run)
      stage="${2:-}"
      builddir="${3:-.}"
      dir="${4:-${HOOKS_DIR}}"
      if [[ -z "$stage" ]]; then echo "Uso: hooks.sh --run <stage> [builddir] [hooks_dir]"; exit 2; fi
      hooks_run "$stage" "$builddir" "$dir"
      exit $?
      ;;
    --summary)
      hooks_summary
      exit 0
      ;;
    --help|-h|help|"")
      cat <<'EOF'
hooks.sh - gerencia execução de hooks em pacote

Uso:
  hooks.sh --init
  hooks.sh --list [hooks_dir]
  hooks.sh --validate [hooks_dir] [trust]
  hooks.sh --run <stage> [builddir] [hooks_dir]
    (stage: pre-prepare, post-prepare, pre-compile, post-compile, pre-install, post-install, pre-uninstall, post-uninstall)
  hooks.sh --summary
  hooks.sh --help

Configuração via variáveis de ambiente:
  HOOKS_DIR, HOOKS_LOG_DIR, HOOKS_TIMEOUT_SECS, HOOKS_SILENT, HOOKS_TRUST
EOF
      exit 0
      ;;
    *)
      echo "Comando inválido. Use --help"
      exit 2
      ;;
  esac
fi

# -------------------------
# Export functions for sourcing
# -------------------------
export -f hooks_init hooks_validate hooks_list hooks_run hooks_summary hooks_cleanup _hooks_run_file
