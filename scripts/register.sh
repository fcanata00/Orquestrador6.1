#!/usr/bin/env bash
# ============================================================================
# register.sh - Sistema de registro e logs unificado para LFS
# Autor: ChatGPT (OpenAI)
# Versão: 1.0
# Licença: MIT
# ============================================================================

set -euo pipefail

# ===========================
# Configurações iniciais
# ===========================
: "${LFS_LOG_DIR:=/var/log/lfs}"
: "${LFS_LOG_FILE:=$LFS_LOG_DIR/lfs.log}"
: "${LFS_LOG_LOCKFILE:=$LFS_LOG_FILE.lock}"
: "${LFS_LOG_MAX_BYTES:=10485760}"    # 10MB
: "${LFS_LOG_BACKUPS:=5}"
: "${LFS_LOG_LEVEL:=INFO}"
: "${LFS_LOG_COLOR:=auto}"
: "${LFS_LOG_SYSLOG:=no}"
: "${LFS_LOG_MANDATORY:=no}"
: "${LFS_LOG_UMASK:=022}"
: "${LFS_LOG_USER:=$(id -un)}"
: "${LFS_LOG_GROUP:=$(id -gn)}"
: "${LFS_LOG_TIMESTAMP_FMT:="%Y-%m-%dT%H:%M:%S%z"}"

declare -A LFS_LOG_LEVELS=( [DEBUG]=0 [INFO]=1 [NOTICE]=2 [WARN]=3 [ERROR]=4 [FATAL]=5 )
declare -A COLORS=( [DEBUG]='\033[36m' [INFO]='\033[32m' [NOTICE]='\033[34m' [WARN]='\033[33m' [ERROR]='\033[31m' [FATAL]='\033[1;37;41m' [RESET]='\033[0m' )

# ===========================
# Funções utilitárias
# ===========================

mask_sensitive() {
  sed -E 's/(pass(word)?|secret|token)=\S+/*****/gi'
}

strip_ansi() {
  sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g'
}

should_color() {
  case "${LFS_LOG_COLOR}" in
    always) return 0 ;;
    never)  return 1 ;;
    auto)   [ -t 1 ] && return 0 || return 1 ;;
  esac
}

timestamp() {
  date +"${LFS_LOG_TIMESTAMP_FMT}"
}

retry() {
  local max=${2:-5} delay=1
  for ((i=1; i<=max; i++)); do
    "$1" && return 0 || sleep $delay
    delay=$((delay * 2))
  done
  return 1
}

# ===========================
# Locking
# ===========================
acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 200>"$LFS_LOG_LOCKFILE"
    flock -x 200 || return 1
  else
    local tries=0
    while ! mkdir "${LFS_LOG_LOCKFILE}.d" 2>/dev/null; do
      ((tries++)); [ $tries -gt 10 ] && return 1
      sleep 0.1
    done
  fi
}

release_lock() {
  if command -v flock >/dev/null 2>&1; then
    flock -u 200 || true
  else
    rmdir "${LFS_LOG_LOCKFILE}.d" 2>/dev/null || true
  fi
}

# ===========================
# Escrita e rotação
# ===========================
rotate_logs() {
  acquire_lock || return 1
  if [ -f "$LFS_LOG_FILE" ]; then
    local size
    size=$(stat -c%s "$LFS_LOG_FILE" 2>/dev/null || echo 0)
    if (( size > LFS_LOG_MAX_BYTES )); then
      for ((i=LFS_LOG_BACKUPS; i>=1; i--)); do
        [ -f "$LFS_LOG_FILE.$i.gz" ] && mv "$LFS_LOG_FILE.$i.gz" "$LFS_LOG_FILE.$((i+1)).gz" 2>/dev/null || true
        [ -f "$LFS_LOG_FILE.$i" ] && mv "$LFS_LOG_FILE.$i" "$LFS_LOG_FILE.$((i+1))" 2>/dev/null || true
      done
      mv "$LFS_LOG_FILE" "$LFS_LOG_FILE.1" || true
      (gzip -f "$LFS_LOG_FILE.1" >/dev/null 2>&1 &)
      : > "$LFS_LOG_FILE"
    fi
  fi
  release_lock
}

write_log() {
  local line="$1"
  acquire_lock || { echo "Lock falhou"; return 1; }
  printf '%s\n' "$line" >> "$LFS_LOG_FILE" 2>/dev/null || {
    echo "Falha ao gravar log" >&2
    release_lock
    return 1
  }
  release_lock
}

# ===========================
# Logging principal
# ===========================
log_message() {
  local level="$1"; shift
  local msg="$*"
  local level_val=${LFS_LOG_LEVELS[$level]:-1}
  local min_val=${LFS_LOG_LEVELS[$LFS_LOG_LEVEL]:-1}
  (( level_val < min_val )) && return 0

  msg=$(echo "$msg" | mask_sensitive)
  local ts; ts=$(timestamp)
  local src="${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]:-0}"
  local pid="$$"
  local formatted="$ts [$level] [$src PID:$pid] $msg"
  local color_reset="${COLORS[RESET]}"
  local line_plain="$formatted"
  local line_colored="$formatted"
  if should_color; then
    line_colored="${COLORS[$level]}$formatted${color_reset}"
  fi

  echo -e "$line_colored" >&2
  write_log "$(echo "$line_plain" | strip_ansi)" || true

  [ "$LFS_LOG_SYSLOG" = "yes" ] && command -v logger >/dev/null 2>&1 && \
    logger -t "LFS[$level]" "$msg" || true

  if [ "$level" = "FATAL" ]; then
    run_fatal_hooks "$msg"
    exit 1
  fi
}

# ===========================
# API pública
# ===========================
log_debug() { log_message DEBUG "$*"; }
log_info()  { log_message INFO "$*"; }
log_notice(){ log_message NOTICE "$*"; }
log_warn()  { log_message WARN "$*"; }
log_error() { log_message ERROR "$*"; }
log_fatal() { log_message FATAL "$*"; }

# ===========================
# Hooks on_fatal
# ===========================
declare -a FATAL_HOOKS=()
register_on_fatal() {
  FATAL_HOOKS+=("$1")
}

run_fatal_hooks() {
  local msg="$1"
  for hook in "${FATAL_HOOKS[@]}"; do
    "$hook" "$msg" || log_warn "Hook $hook falhou"
  done
}

# ===========================
# Setup
# ===========================
log_setup() {
  umask "$LFS_LOG_UMASK"
  mkdir -p "$LFS_LOG_DIR" 2>/dev/null || {
    LFS_LOG_DIR="${HOME}/.lfs/logs"
    mkdir -p "$LFS_LOG_DIR" || { echo "Falha ao criar diretório de log"; return 1; }
    LFS_LOG_FILE="$LFS_LOG_DIR/lfs.log"
  }
  touch "$LFS_LOG_FILE" || { echo "Falha ao criar $LFS_LOG_FILE"; return 1; }
  chown "$LFS_LOG_USER:$LFS_LOG_GROUP" "$LFS_LOG_FILE" 2>/dev/null || true
  rotate_logs || true
}

# ===========================
# Self-test
# ===========================
self_test() {
  echo "Executando self-test do register.sh..."
  log_setup || { echo "Falha no setup"; exit 1; }
  log_info "Teste INFO"
  log_warn "Teste WARN"
  log_error "Teste ERROR password=1234"
  register_on_fatal "echo 'Hook FATAL executado'"
  log_fatal "Teste FATAL final"
}

# ===========================
# CLI
# ===========================
if [[ "${1:-}" == "--self-test" ]]; then
  self_test
fi

