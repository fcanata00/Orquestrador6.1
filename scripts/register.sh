#!/usr/bin/env bash
# register.sh - logging e registro colorido com inicialização (--ini)
set -eEuo pipefail
IFS=$'\n\t'

# ========================
#  CONFIGURAÇÕES PADRÃO
# ========================
: "${LFS:=/mnt/lfs}"
: "${LOG_DIR:=${LFS}/var/log}"
: "${LOCK_DIR:=${LOG_DIR}/locks}"
: "${SCRIPTS_LOG_DIR:=${LOG_DIR}/scripts}"
: "${LOG_MAX_SIZE_MB:=50}"
: "${LOG_MAX_FILES:=5}"
: "${SILENT:=false}"
: "${DEBUG:=false}"
: "${COLOR:=true}"
: "${JSON_OUTPUT:=false}"
: "${TIMESTAMP_FORMAT:=%Y-%m-%dT%H:%M:%SZ}"
: "${PROGRESS_WIDTH:=40}"

_REGISTER_INITIALIZED=false
_REGISTER_LAST_LOG="${LOG_DIR}/system.log"

# ========================
#  FUNÇÕES AUXILIARES
# ========================
_tag_sanitize() { echo "$1" | sed -E 's/[^A-Za-z0-9._-]/_/g'; }
register_timestamp() { date -u +"${TIMESTAMP_FORMAT}"; }

_register_init_dirs() {
  if [[ "${_REGISTER_INITIALIZED}" == "true" ]]; then return 0; fi
  mkdir -p "${LOG_DIR}" "${LOCK_DIR}" "${SCRIPTS_LOG_DIR}" 2>/dev/null || true
  chmod 750 "${LOG_DIR}" "${LOCK_DIR}" "${SCRIPTS_LOG_DIR}" || true
  touch "${_REGISTER_LAST_LOG}" 2>/dev/null || true
  chmod 640 "${_REGISTER_LAST_LOG}" || true
  _REGISTER_INITIALIZED=true
}

_register_write() {
  local file="$1"; shift
  local line="$*"
  mkdir -p "$(dirname "${file}")" 2>/dev/null || true
  exec {__fd}>>"${file}" || { echo "ERROR: não foi possível abrir ${file}" >&2; return 3; }
  flock -n "${__fd}" || flock "${__fd}" || true
  printf "%s\n" "${line}" >&${__fd}
  eval "exec ${__fd}>&-"
}

# ========================
#  CORES
# ========================
if [[ "${COLOR}" != "true" || -z "${TERM:-}" || "${TERM}" == "dumb" ]]; then
  C_INFO=""; C_WARN=""; C_ERR=""; C_DEBUG=""; C_RESET=""
else
  C_INFO="\e[32m"; C_WARN="\e[33m"; C_ERR="\e[31m"; C_DEBUG="\e[36m"; C_RESET="\e[0m"
fi

# ========================
#  FUNÇÕES DE LOG
# ========================
_register_log_line() {
  local level="$1"; local tag="$2"; shift 2
  local msg="$*"; local ts; ts=$(register_timestamp)
  local pid=$$; local clean_tag; clean_tag=$(_tag_sanitize "${tag:-system}")
  local logfile="${SCRIPTS_LOG_DIR}/${clean_tag}.log"
  local line="${ts} [${level}] ${clean_tag} ${pid} - ${msg}"
  _register_write "${_REGISTER_LAST_LOG}" "${line}" || true
  _register_write "${logfile}" "${line}" || true

  if [[ "${SILENT}" != "true" ]]; then
    case "${level}" in
      INFO)  printf "%s %s%s%s\n" "${ts}" "${C_INFO}"  "${msg}" "${C_RESET}" ;;
      WARN)  printf "%s %s%s%s\n" "${ts}" "${C_WARN}"  "${msg}" "${C_RESET}" >&2 ;;
      ERROR) printf "%s %s%s%s\n" "${ts}" "${C_ERR}"   "${msg}" "${C_RESET}" >&2 ;;
      DEBUG) if [[ "${DEBUG}" == "true" ]]; then
               printf "%s %s%s%s\n" "${ts}" "${C_DEBUG}" "${msg}" "${C_RESET}"
             fi ;;
      *) printf "%s %s\n" "${ts}" "${msg}" ;;
    esac
  fi
}

register_info()  { _register_init_dirs; _register_log_line INFO  "${SCRIPT_NAME:-system}" "$*"; }
register_warn()  { _register_init_dirs; _register_log_line WARN  "${SCRIPT_NAME:-system}" "$*"; }
register_error() { _register_init_dirs; _register_log_line ERROR "${SCRIPT_NAME:-system}" "$*"; }
register_debug() { _register_init_dirs; if [[ "${DEBUG}" == "true" ]]; then _register_log_line DEBUG "${SCRIPT_NAME:-system}" "$*"; fi; }
register_fatal() { register_error "$*"; exit 1; }

# ========================
#  JSON E PROGRESS BAR
# ========================
register_json_out() {
  local ts; ts=$(register_timestamp)
  local json="{\"timestamp\":\"${ts}\""
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    json+=",\"$k\":\"$v\""
  done
  json+="}"
  [[ "${JSON_OUTPUT}" == "true" ]] && echo "${json}" || _register_write "${_REGISTER_LAST_LOG}" "${json}"
}

progress_bar() {
  local percent=${1:-0}; local width=${2:-${PROGRESS_WIDTH}}
  (( percent < 0 )) && percent=0
  (( percent > 100 )) && percent=100
  local filled=$(( percent * width / 100 ))
  local empty=$(( width - filled ))
  printf '['; printf '#%.0s' $(seq 1 ${filled})
  printf '-%.0s' $(seq 1 ${empty}); printf "] %d%%\r" "${percent}"
  (( percent >= 100 )) && printf '\n'
}

# ========================
#  LOCKS E ROTAÇÃO
# ========================
register_lock() {
  _register_init_dirs
  local name=${1:-global}
  local lockfile="${LOCK_DIR}/lock.${name}.lck"
  exec {LOCK_FD}>>"${lockfile}" || { register_error "Não foi possível abrir ${lockfile}"; return 4; }
  flock -n "${LOCK_FD}" || { register_warn "Lock ocupado: ${name}"; return 1; }
}
register_unlock() { [[ -n "${LOCK_FD:-}" ]] && eval "exec ${LOCK_FD}>&-"; }

register_rotate() {
  _register_init_dirs
  local logfile=${1:-${_REGISTER_LAST_LOG}}
  [[ ! -f "${logfile}" ]] && return 0
  local maxbytes=$(( LOG_MAX_SIZE_MB * 1024 * 1024 ))
  local bytes=$(stat -c%s "${logfile}" 2>/dev/null || echo 0)
  (( bytes < maxbytes )) && return 0
  local base=$(basename "${logfile}")
  register_lock "rotate_${base}" || return 4
  for ((i=LOG_MAX_FILES-1;i>=1;i--)); do
    [[ -f "${logfile}.${i}" ]] && mv -f "${logfile}.${i}" "${logfile}.$((i+1))"
  done
  mv -f "${logfile}" "${logfile}.1" || true
  : > "${logfile}"
  register_unlock || true
  register_info "Rotacionado ${logfile}"
}

# ========================
#  CLI
# ========================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --ini)
      _register_init_dirs
      cat > "${LOG_DIR}/register.conf" <<EOF
# Arquivo de configuração gerado automaticamente
LFS=${LFS}
LOG_DIR=${LOG_DIR}
LOCK_DIR=${LOCK_DIR}
SCRIPTS_LOG_DIR=${SCRIPTS_LOG_DIR}
LOG_MAX_SIZE_MB=${LOG_MAX_SIZE_MB}
LOG_MAX_FILES=${LOG_MAX_FILES}
EOF
      chmod 640 "${LOG_DIR}/register.conf"
      echo "Registro inicializado em ${LOG_DIR}"
      ;;
    --status)
      echo "Logs em: ${LOG_DIR}"
      echo "Total de arquivos: $(find ${LOG_DIR} -type f | wc -l)"
      du -sh "${LOG_DIR}" 2>/dev/null || true
      ;;
    --rotate)
      register_rotate "${LOG_DIR}/system.log"
      ;;
    --tail)
      tail -n "${2:-50}" "${LOG_DIR}/system.log"
      ;;
    --help|-h|help|"")
      cat <<EOF
Uso:
  register.sh --ini         Inicializa diretórios e config
  register.sh --status      Mostra status dos logs
  register.sh --rotate      Força rotação
  register.sh --tail [N]    Mostra últimas N linhas
EOF
      ;;
  esac
  exit 0
fi

# ========================
#  EXPORT
# ========================
export -f register_info register_warn register_error register_debug register_fatal \
          register_json_out progress_bar register_lock register_unlock \
          register_rotate register_timestamp
