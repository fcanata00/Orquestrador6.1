#!/usr/bin/env bash
# ============================================================================
# deps.sh - Gerenciador de dependências completo do sistema LFS modular
# ============================================================================
# Autor: GPT-5 Automation System
# Descrição:
#   Sistema robusto de gerenciamento, ordenação e reconstrução de dependências
#   entre módulos (build, update, upgrade, uninstall, etc).
# ============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configurações e variáveis padrão
# -----------------------------------------------------------------------------
LFS_ROOT=${LFS_ROOT:-/mnt/lfs}
LFS_DEPS_DIR=${LFS_DEPS_DIR:-${LFS_ROOT}/scripts}
LFS_DEPS_CACHE=${LFS_DEPS_CACHE:-${LFS_ROOT}/.cache/deps_cache.txt}
LFS_LOCK_FILE=${LFS_LOCK_FILE:-/tmp/lfs_deps.lock}

CORE_REGISTER_PATHS=(
  "./register.sh"
  "/usr/local/bin/register.sh"
  "/usr/local/lib/lfs/register.sh"
  "${LFS_ROOT}/scripts/register.sh"
  "/usr/lib/lfs/register.sh"
)

# -----------------------------------------------------------------------------
# Logger interno (fallback se register.sh não estiver presente)
# -----------------------------------------------------------------------------
COLOR_INFO="\033[1;34m"; COLOR_WARN="\033[1;33m"; COLOR_ERROR="\033[1;31m"; COLOR_RESET="\033[0m"
log() { printf "%b[%s]%b %s\n" "$1" "$2" "$COLOR_RESET" "$3" >&2; }
log_info()  { [ "${DEPS_QUIET:-0}" -eq 0 ] && log "$COLOR_INFO" "INFO" "$*"; }
log_warn()  { log "$COLOR_WARN" "WARN" "$*"; }
log_error() { log "$COLOR_ERROR" "ERROR" "$*"; }
log_fatal() { log "$COLOR_ERROR" "FATAL" "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Importar register.sh automaticamente, se disponível
# -----------------------------------------------------------------------------
for p in "${CORE_REGISTER_PATHS[@]}"; do
  if [ -f "$p" ]; then
    # shellcheck disable=SC1090
    source "$p" && log_info "Carregado: $p" && break
  fi
done

# -----------------------------------------------------------------------------
# Estruturas internas
# -----------------------------------------------------------------------------
declare -A DEPS_REQ DEPS_OPT DEPS_REV
declare -A MODULE_PATH MODULE_HASH
declare -a TOPO_ORDER

# -----------------------------------------------------------------------------
# Funções auxiliares
# -----------------------------------------------------------------------------
sha1_of() { sha1sum "$1" 2>/dev/null | awk '{print $1}' || echo "0"; }
safe_read() { cat "$1" 2>/dev/null || true; }
atomic_write() { local f="$1"; shift; echo "$*" > "${f}.tmp" && mv -f "${f}.tmp" "$f"; }
lock_acquire() { exec 200>"$LFS_LOCK_FILE" && flock -x 200 || true; }
lock_release() { flock -u 200 2>/dev/null || true; }

# -----------------------------------------------------------------------------
# Parser de metadados
# -----------------------------------------------------------------------------
deps_parse_file() {
  local file="$1" name deps opt
  name=$(grep -E "^# *@name:" "$file" | awk -F: '{print $2}' | xargs || true)
  deps=$(grep -E "^# *@deps:" "$file" | awk -F: '{print $2}' | xargs || true)
  opt=$(grep -E "^# *@optional:" "$file" | awk -F: '{print $2}' | xargs || true)
  [ -z "$name" ] && return 0
  DEPS_REQ["$name"]="$deps"
  DEPS_OPT["$name"]="$opt"
  MODULE_PATH["$name"]="$file"
  MODULE_HASH["$name"]="$(sha1_of "$file")"
}

deps_scan_all() {
  log_info "Escaneando diretório de scripts: $LFS_DEPS_DIR"
  for f in "$LFS_DEPS_DIR"/*.sh; do
    [ -f "$f" ] && deps_parse_file "$f"
  done
}

# -----------------------------------------------------------------------------
# Construção de grafo reverso e ordenação topológica
# -----------------------------------------------------------------------------
deps_build_reverse() {
  DEPS_REV=()
  for mod in "${!DEPS_REQ[@]}"; do
    for dep in ${DEPS_REQ[$mod]:-}; do
      [ -z "$dep" ] && continue
      DEPS_REV["$dep"]="${DEPS_REV[$dep]} $mod"
    done
  done
}

declare -A visited
TOPO_ORDER=()

deps_dfs() {
  local node="$1"
  visited["$node"]=1
  for dep in ${DEPS_REQ[$node]:-}; do
    [ -z "$dep" ] && continue
    if [ "${visited[$dep]:-}" = "1" ]; then
      log_fatal "Ciclo detectado entre $node → $dep"
    fi
    [ "${visited[$dep]:-}" ] || deps_dfs "$dep"
  done
  visited["$node"]=2
  TOPO_ORDER+=("$node")
}

deps_ordered_list() {
  TOPO_ORDER=()
  for mod in "${!DEPS_REQ[@]}"; do
    [ "${visited[$mod]:-}" ] || deps_dfs "$mod"
  done
  printf '%s\n' "${TOPO_ORDER[@]}" | tac
}

# -----------------------------------------------------------------------------
# Validação e rebuild reverso
# -----------------------------------------------------------------------------
deps_validate() {
  log_info "Validando dependências..."
  local missing=0
  for m in "${!DEPS_REQ[@]}"; do
    for d in ${DEPS_REQ[$m]:-}; do
      [[ -n "${DEPS_REQ[$d]:-}" ]] || { log_warn "Dependência ausente: $m → $d"; ((missing++)); }
    done
  done
  [ "$missing" -eq 0 ] && log_info "Validação concluída." || log_warn "$missing dependências faltando."
}

deps_reverse() {
  local target="$1"
  for mod in "${!DEPS_REQ[@]}"; do
    for dep in ${DEPS_REQ[$mod]:-}; do
      [ "$dep" = "$target" ] && echo "$mod"
    done
  done
}

deps_rebuild() {
  local mod="$1"; local rev
  log_info "Rebuild solicitado para: $mod"
  rev=$(deps_reverse "$mod")
  for m in $mod $rev; do
    log_info "Reconstruindo módulo: $m"
    [ -x "${MODULE_PATH[$m]:-}" ] && bash "${MODULE_PATH[$m]}" || log_warn "Script ausente: $m"
  done
  log_info "Rebuild finalizado."
}

# -----------------------------------------------------------------------------
# Cache simples e auto-teste
# -----------------------------------------------------------------------------
deps_save_cache() {
  atomic_write "$LFS_DEPS_CACHE" "$(for m in "${!DEPS_REQ[@]}"; do echo "$m:${DEPS_REQ[$m]}"; done)"
  log_info "Cache salvo em $LFS_DEPS_CACHE"
}

deps_load_cache() {
  [ -f "$LFS_DEPS_CACHE" ] || return 1
  while IFS=: read -r mod deps; do
    [ -z "$mod" ] && continue
    DEPS_REQ["$mod"]="$deps"
  done < "$LFS_DEPS_CACHE"
  log_info "Cache carregado de $LFS_DEPS_CACHE"
}

deps_self_test() {
  log_info "Executando auto-teste do deps.sh..."
  deps_scan_all
  deps_validate
  deps_ordered_list >/dev/null
  deps_save_cache
  log_info "Auto-teste concluído com sucesso."
}

# -----------------------------------------------------------------------------
# CLI principal
# -----------------------------------------------------------------------------
case "${1:-}" in
  --list) deps_scan_all; deps_ordered_list ;;
  --validate) deps_scan_all; deps_validate ;;
  --reverse) shift; deps_scan_all; deps_reverse "${1:-}" ;;
  --rebuild) shift; deps_scan_all; deps_build_reverse; deps_rebuild "${1:-}" ;;
  --self-test) deps_self_test ;;
  --reload-cache) deps_scan_all; deps_save_cache ;;
  *) echo "Uso: $0 [--list|--validate|--rebuild <mod>|--reverse <mod>|--self-test|--reload-cache]" ;;
esac
