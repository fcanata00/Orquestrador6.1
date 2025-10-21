#!/usr/bin/env bash
# utils.sh - Utilitários centrais para Linux From Scratch
# Autor: Sistema Automatizado LFS
# Versão: 1.0

set -Eeuo pipefail

# ========== VARIÁVEIS GLOBAIS ==========
export UTILS_VERSION="1.0"
export UTILS_LOCK_DIR="/tmp/utils-locks"
export SILENT_ERRORS="${SILENT_ERRORS:-false}"
export ABORT_ON_ERROR="${ABORT_ON_ERROR:-true}"
export LOG_API_READY="${LOG_API_READY:-false}"

# ========== FUNÇÕES DE LOG Fallback ==========
util_color_red="\033[0;31m"
util_color_yellow="\033[0;33m"
util_color_green="\033[0;32m"
util_color_reset="\033[0m"

util_info() {
  if [[ "$LOG_API_READY" == "true" && "$(type -t log_info)" == "function" ]]; then
    log_info "$@"
  else
    echo -e "${util_color_green}[INFO]${util_color_reset} $*"
  fi
}

util_warn() {
  if [[ "$LOG_API_READY" == "true" && "$(type -t log_warn)" == "function" ]]; then
    log_warn "$@"
  else
    echo -e "${util_color_yellow}[WARN]${util_color_reset} $*"
  fi
}

util_error() {
  if [[ "$LOG_API_READY" == "true" && "$(type -t log_error)" == "function" ]]; then
    log_error "$@"
  else
    echo -e "${util_color_red}[ERROR]${util_color_reset} $*" >&2
  fi
  if [[ "$SILENT_ERRORS" == "true" ]]; then
    return 1
  elif [[ "$ABORT_ON_ERROR" == "true" ]]; then
    exit 1
  fi
}

# ========== FUNÇÕES DE SISTEMA ==========
util_check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    util_warn "Este script requer privilégios de root."
    if command -v sudo >/dev/null 2>&1; then
      sudo "$@"
    else
      util_error "sudo não encontrado."
    fi
  fi
}

util_ensure_dir() {
  local dir="$1"
  [[ -z "$dir" ]] && util_error "Caminho de diretório não especificado."
  mkdir -p "$dir" || util_error "Falha ao criar diretório: $dir"
}

util_clean_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -delete || util_error "Falha ao limpar diretório: $dir"
}

util_safe_rm() {
  local path="$1"
  case "$path" in
    ""|"/"|"/usr"|"/bin"|"/etc"|"/lib"|"/root"|"/home"|"/var") util_error "Remoção bloqueada: caminho inseguro $path" ;;
    *) rm -rf --one-file-system "$path" || util_error "Falha ao remover $path" ;;
  esac
}

# ========== FUNÇÕES DE REDE ==========
util_check_internet() {
  ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 || util_error "Sem conectividade com a Internet."
}

util_test_url() {
  local url="$1"
  curl -fsI "$url" >/dev/null 2>&1 || util_error "URL inacessível: $url"
}

# ========== EXECUÇÃO E COMANDOS ==========
util_command_exists() { command -v "$1" >/dev/null 2>&1; }

util_run_safe() {
  local cmd="$1"
  eval "$cmd" || util_error "Comando falhou: $cmd"
}

util_retry() {
  local retries="$1"; shift
  local cmd="$*"
  local count=0
  until eval "$cmd"; do
    ((count++))
    [[ $count -ge $retries ]] && util_error "Falhou após $retries tentativas: $cmd"
    sleep $((count * 2))
  done
}

# ========== LOCKS ==========
util_lock() {
  local name="$1"
  local lockfile="$UTILS_LOCK_DIR/$name.lock"
  mkdir -p "$UTILS_LOCK_DIR"
  if [[ -f "$lockfile" ]]; then
    util_warn "Lock ativo: $name"
    return 1
  fi
  echo "$$" > "$lockfile"
  trap "rm -f '$lockfile'" EXIT
}

util_unlock() {
  local name="$1"
  rm -f "$UTILS_LOCK_DIR/$name.lock"
}

# ========== TRATAMENTO DE ERROS E SINAIS ==========
util_trap_errors() {
  trap 'util_error "Erro inesperado no script ($BASH_COMMAND)"' ERR
  trap 'util_info "Encerrando com segurança..."; exit 0' SIGINT SIGTERM
}

# ========== CLI ==========
util_cli_ini() {
  util_info "Inicializando diretórios do utils.sh"
  util_ensure_dir "$UTILS_LOCK_DIR"
}

util_self_test() {
  util_info "Executando autoteste..."
  util_check_internet || true
  util_command_exists curl && util_info "curl OK" || util_warn "curl ausente"
  util_info "Autoteste concluído."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --ini) util_cli_ini ;;
    --self-test) util_self_test ;;
    --help|*) echo "Uso: utils.sh [--ini | --self-test | --help]" ;;
  esac
fi

export -f util_info util_warn util_error util_check_root util_ensure_dir util_clean_dir util_safe_rm util_check_internet util_test_url util_command_exists util_run_safe util_retry util_lock util_unlock util_trap_errors
