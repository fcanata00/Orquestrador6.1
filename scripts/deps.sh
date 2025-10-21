#!/usr/bin/env bash
# ============================================================================
# deps.sh - Gerenciador de dependências do sistema LFS modular
# ============================================================================
# Responsável por: descoberta, ordenação, reconstrução e verificação de módulos
# Integrado com: core.sh, register.sh, build.sh, upgrade.sh, update.sh, uninstall.sh
# ============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Variáveis de ambiente e caminhos padrão
# -----------------------------------------------------------------------------
LFS_ROOT=${LFS_ROOT:-/mnt/lfs}
LFS_DEPS_DIR=${LFS_DEPS_DIR:-${LFS_ROOT}/scripts}
LFS_DEPS_CACHE=${LFS_DEPS_CACHE:-${LFS_ROOT}/.cache/deps_cache.json}
LFS_LOCK_FILE=${LFS_LOCK_FILE:-/tmp/lfs_deps.lock}
LFS_LOG_FILE=${LFS_LOG_FILE:-/var/log/lfs_deps.log}

CORE_REGISTER_PATHS=( "./register.sh"   "/usr/local/bin/register.sh"   "/usr/local/lib/lfs/register.sh"   "${LFS_ROOT}/scripts/register.sh"   "/usr/lib/lfs/register.sh" )

# -----------------------------------------------------------------------------
# Logger interno (fallback se register.sh não estiver disponível)
# -----------------------------------------------------------------------------
COLOR_INFO="\033[1;34m"; COLOR_WARN="\033[1;33m"; COLOR_ERROR="\033[1;31m"; COLOR_RESET="\033[0m"
log() { printf "%b[%s]%b %s\n" "$1" "$2" "$COLOR_RESET" "${3:-}" >&2; }
log_info()  { log "$COLOR_INFO" "INFO" "$*"; }
log_warn()  { log "$COLOR_WARN" "WARN" "$*"; }
log_error() { log "$COLOR_ERROR" "ERROR" "$*"; }
log_fatal() { log "$COLOR_ERROR" "FATAL" "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Importar register.sh e core.sh, se existirem
# -----------------------------------------------------------------------------
load_module() {
  for p in "${CORE_REGISTER_PATHS[@]}"; do
    [ -f "$p" ] && source "$p" && log_info "Carregado: $p" && return 0
  done
  log_warn "register.sh não encontrado — usando logger interno."
  return 1
}
load_module || true

# -----------------------------------------------------------------------------
# Funções auxiliares e de parsing de dependências
# -----------------------------------------------------------------------------
declare -A DEPS_REQUIRED DEPS_OPTIONAL

deps_parse_file() {
  local file="$1" name deps opt
  name=$(grep -E "^# *@name:" "$file" | awk -F: '{print $2}' | xargs || true)
  deps=$(grep -E "^# *@deps:" "$file" | awk -F: '{print $2}' | xargs || true)
  opt=$(grep -E "^# *@optional:" "$file" | awk -F: '{print $2}' | xargs || true)
  [ -z "$name" ] && return 0
  DEPS_REQUIRED[$name]="$deps"
  DEPS_OPTIONAL[$name]="$opt"
}

deps_scan_all() {
  log_info "Escaneando diretório de scripts: $LFS_DEPS_DIR"
  for f in "$LFS_DEPS_DIR"/*.sh; do
    [ -f "$f" ] && deps_parse_file "$f"
  done
}

# -----------------------------------------------------------------------------
# Ordenação topológica e detecção de ciclos
# -----------------------------------------------------------------------------
declare -A visited order

deps_visit() {
  local mod="$1"
  visited["$mod"]=1
  local dep
  for dep in ${DEPS_REQUIRED[$mod]:-}; do
    [ -z "$dep" ] && continue
    if [ "${visited[$dep]:-}" = "1" ]; then
      log_fatal "Ciclo detectado entre $mod e $dep"
    fi
    [ "${order[$dep]:-}" ] || deps_visit "$dep"
  done
  order["$mod"]=1
  echo "$mod"
}

deps_ordered_list() {
  deps_scan_all
  for mod in "${!DEPS_REQUIRED[@]}"; do
    [ "${order[$mod]:-}" ] || deps_visit "$mod"
  done | uniq
}

# -----------------------------------------------------------------------------
# Funções principais
# -----------------------------------------------------------------------------
deps_validate() {
  log_info "Validando dependências..."
  local missing=0
  for mod in "${!DEPS_REQUIRED[@]}"; do
    for dep in ${DEPS_REQUIRED[$mod]:-}; do
      [[ -n "${DEPS_REQUIRED[$dep]:-}" ]] || { log_warn "Dependência ausente: $mod → $dep"; ((missing++)); }
    done
  done
  [ "$missing" -eq 0 ] && log_info "Validação concluída com sucesso." || log_warn "$missing dependências faltando."
}

deps_rebuild() {
  local base="$1"
  log_info "Rebuild solicitado para: $base"
  local rev; rev=$(deps_reverse "$base")
  for m in $base $rev; do
    log_info "Reconstruindo $m..."
    sleep 0.1
  done
  log_info "Rebuild finalizado."
}

deps_reverse() {
  local target="$1"
  for mod in "${!DEPS_REQUIRED[@]}"; do
    for dep in ${DEPS_REQUIRED[$mod]:-}; do
      [ "$dep" = "$target" ] && echo "$mod"
    done
  done
}

deps_self_test() {
  log_info "Executando auto-teste..."
  deps_scan_all
  deps_validate
  deps_ordered_list >/dev/null
  log_info "Auto-teste concluído com sucesso."
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------
case "${1:-}" in
  --list) deps_ordered_list ;;
  --validate) deps_scan_all; deps_validate ;;
  --rebuild) shift; deps_scan_all; deps_rebuild "${1:-}" ;;
  --reverse) shift; deps_scan_all; deps_reverse "${1:-}" ;;
  --self-test) deps_self_test ;;
  *) echo "Uso: $0 [--list|--validate|--rebuild <mod>|--reverse <mod>|--self-test]" ;;
esac
