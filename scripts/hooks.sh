#!/usr/bin/env bash
# ===========================================================
# hooks.sh - Gerenciador seguro de hooks pré/pós etapas de build
# ===========================================================
# Suporta:
#  - pre/post prepare, compile, install, uninstall
#  - logs coloridos e detalhados
#  - timeout, flock, isolamento e rollback limpo
#  - modo silencioso e debug
#  - integração com register.sh e metafile.sh
# ===========================================================

set -eEuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="hooks"

# =============================
# Configurações padrão
# =============================
: "${HOOKS_DIR:=${HOOKS_DIR:-./hooks}}"
: "${HOOKS_LOG_DIR:=${HOOKS_LOG_DIR:-/var/log/hooks}}"
: "${HOOKS_TMP_DIR:=${HOOKS_TMP_DIR:-/tmp/hooks.$$}}"
: "${HOOKS_TIMEOUT_SECS:=300}"
: "${HOOKS_SILENT:=false}"
: "${HOOKS_DEBUG:=false}"
: "${HOOKS_MAX_LOG_BYTES:=1048576}"
: "${HOOKS_LOCK_DIR:=${HOOKS_LOG_DIR}/locks}"
: "${HOOKS_TRUST:=false}"
: "${HOOKS_SHCMD:=/bin/bash}"

# Variáveis internas
_HOOKS_INITIALIZED=false
_HOOKS_STATS_TOTAL=0
_HOOKS_STATS_OK=0
_HOOKS_STATS_FAIL=0
declare -a _HOOKS_RUN_HISTORY=()

# ===========================================================
# Função de log integrada com register.sh
# ===========================================================
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
      INFO)  echo -e "\e[32m[INFO]\e[0m $msg";;
      WARN)  echo -e "\e[33m[WARN]\e[0m $msg" >&2;;
      ERROR) echo -e "\e[31m[ERROR]\e[0m $msg" >&2;;
      DEBUG) [[ "${HOOKS_DEBUG}" == "true" ]] && echo -e "\e[36m[DEBUG]\e[0m $msg";;
      *) echo "[LOG] $msg";;
    esac
  fi
}

# ===========================================================
# Utilitários de segurança
# ===========================================================
_safe_mkdir() { mkdir -p "$1" 2>/dev/null || _hlog ERROR "Não foi possível criar $1"; chmod 750 "$1" || true; }

# ===========================================================
# Inicialização / limpeza
# ===========================================================
hooks_init() {
  if [[ "${_HOOKS_INITIALIZED}" == "true" ]]; then return 0; fi
  umask 027
  _safe_mkdir "${HOOKS_LOG_DIR}"
  _safe_mkdir "${HOOKS_TMP_DIR}"
  _safe_mkdir "${HOOKS_LOCK_DIR}"
  trap 'hooks_cleanup' EXIT INT TERM
  _HOOKS_INITIALIZED=true
  _hlog INFO "Hooks inicializado (DIR=${HOOKS_DIR})"
}

hooks_cleanup() {
  if [[ -d "${HOOKS_TMP_DIR}" ]]; then
    rm -rf "${HOOKS_TMP_DIR}" || true
  fi
}

# ===========================================================
# Validação de segurança dos hooks
# ===========================================================
hooks_validate() {
  local dir="${1:-${HOOKS_DIR}}"
  local allow_trust="${2:-${HOOKS_TRUST}}"
  hooks_init
  [[ ! -d "$dir" ]] && { _hlog WARN "Diretório $dir não existe"; return 1; }
  local ok=0 bad=0
  for hook in "$dir"/*.sh; do
    [[ ! -f "$hook" ]] && continue
    local base; base=$(basename "$hook")
    if [[ "$base" =~ [^A-Za-z0-9._-] ]]; then
      _hlog WARN "Nome inválido: $base"; ((bad++)); continue
    fi
    if [[ ! -x "$hook" && "$allow_trust" != "true" ]]; then
      _hlog WARN "Hook não executável: $base"; ((bad++))
    fi
    ((ok++))
  done
  _hlog INFO "Validação: OK=$ok FAIL=$bad"
  (( bad == 0 )) && return 0 || return 2
}

# ===========================================================
# Listagem simples de hooks
# ===========================================================
hooks_list() {
  local dir="${1:-${HOOKS_DIR}}"
  hooks_init
  [[ ! -d "$dir" ]] && { _hlog WARN "Diretório não existe"; return 1; }
  find "$dir" -maxdepth 1 -type f -printf '%f\n' | sort
}

# ===========================================================
# Execução isolada de um único hook
# ===========================================================
_hooks_run_file() {
  local hookfile="$1"
  local builddir="${2:-.}"
  local stage="${3:-unknown}"
  local timeout_secs="${4:-${HOOKS_TIMEOUT_SECS}}"
  local hookname; hookname=$(basename "$hookfile")
  local safe_hookname="${hookname//[^A-Za-z0-9._-]/}"
  [[ -z "$safe_hookname" ]] && { _hlog ERROR "Nome inseguro: $hookname"; return 2; }
  [[ ! -f "$hookfile" ]] && { _hlog WARN "Hook não encontrado: $hookfile"; return 3; }

  local logf="${HOOKS_LOG_DIR}/${safe_hookname}-${stage}.log"
  mkdir -p "${HOOKS_LOG_DIR}" || true
  local lockfile="${HOOKS_LOCK_DIR}/${safe_hookname}.lock"

  exec {HOOK_FD}>>"${lockfile}" || true
  flock -n "${HOOK_FD}" || { _hlog WARN "Hook ${safe_hookname} já em execução..."; flock "${HOOK_FD}" || true; }

  _hlog INFO "Executando hook ${safe_hookname} (${stage})"
  local status=0
  (
    set -eEuo pipefail
    cd "$builddir"
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
    export PKG_NAME="${PKG_NAME:-}"
    export PKG_VERSION="${PKG_VERSION:-}"
    if command -v timeout >/dev/null 2>&1; then
      timeout --preserve-status "${timeout_secs}" "${HOOKS_SHCMD}" "$hookfile"
    else
      "${HOOKS_SHCMD}" "$hookfile"
    fi
  ) >"${logf}.out" 2>"${logf}.err" || status=$?

  if (( status == 0 )); then
    _hlog INFO "Hook ${safe_hookname} concluído com sucesso"
    _HOOKS_STATS_OK=$((_HOOKS_STATS_OK+1))
  else
    _hlog ERROR "Hook ${safe_hookname} falhou (status=$status)"
    _HOOKS_STATS_FAIL=$((_HOOKS_STATS_FAIL+1))
  fi
  _HOOKS_RUN_HISTORY+=("${safe_hookname}:${stage}:${status}")
  eval "exec ${HOOK_FD}>&-"
  return "$status"
}

# ===========================================================
# Execução de hooks por estágio
# ===========================================================
hooks_run() {
  local stage="$1"; local builddir="${2:-.}"; local dir="${3:-${HOOKS_DIR}}"
  hooks_init
  [[ -z "$stage" ]] && { _hlog ERROR "Stage requerido"; return 2; }
  [[ ! -d "$dir" ]] && { _hlog INFO "Sem hooks: $dir"; return 0; }

  local executed=0
  for hook in "$dir"/*.sh; do
    [[ ! -f "$hook" ]] && continue
    if [[ "$hook" == *"${stage}"* ]]; then
      executed=$((executed+1))
      _HOOKS_STATS_TOTAL=$((_HOOKS_STATS_TOTAL+1))
      _hooks_run_file "$hook" "$builddir" "$stage" || {
        if [[ "$stage" == pre-* ]]; then
          _hlog ERROR "Pre-hook falhou — abortando sequência"
          return 10
        fi
      }
    fi
  done
  (( executed == 0 )) && _hlog DEBUG "Nenhum hook encontrado para ${stage}"
  return 0
}

# ===========================================================
# Resumo final
# ===========================================================
hooks_summary() {
  echo "Resumo de Hooks:"
  echo "  Total:    ${_HOOKS_STATS_TOTAL}"
  echo "  Sucesso:  ${_HOOKS_STATS_OK}"
  echo "  Falhas:   ${_HOOKS_STATS_FAIL}"
  echo "  Logs:     ${HOOKS_LOG_DIR}"
  [[ "${HOOKS_DEBUG}" == "true" ]] && printf '%s\n' "${_HOOKS_RUN_HISTORY[@]}"
}

# ===========================================================
# CLI
# ===========================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  case "$cmd" in
    --init)      hooks_init ;;
    --list)      hooks_list "${2:-${HOOKS_DIR}}" ;;
    --validate)  hooks_validate "${2:-${HOOKS_DIR}}" "${3:-${HOOKS_TRUST}}" ;;
    --run)       hooks_run "${2:-}" "${3:-.}" "${4:-${HOOKS_DIR}}" ;;
    --summary)   hooks_summary ;;
    --help|-h|"")
      cat <<'EOF'
hooks.sh - Gerencia execução segura de hooks
Uso:
  hooks.sh --init
  hooks.sh --list [dir]
  hooks.sh --validate [dir] [trust]
  hooks.sh --run <stage> [builddir] [dir]
  hooks.sh --summary
  hooks.sh --help
EOF
      ;;
    *) _hlog ERROR "Comando inválido. Use --help"; exit 2 ;;
  esac
fi

# ===========================================================
# Exporta funções para uso por outros módulos
# ===========================================================
export -f hooks_init hooks_run hooks_validate hooks_list hooks_summary _hooks_run_file
