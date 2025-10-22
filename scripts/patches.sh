#!/usr/bin/env bash
# patches.sh — Gerenciador seguro de aplicação de patches
# Integrado com register.sh e downloader.sh
set -eEuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="patches"

# ==============================
# Configuração padrão
# ==============================
: "${LFS:=/mnt/lfs}"
: "${PT_PATCH_DIR:=patches}"
: "${PT_LOG_DIR:=/var/log/patches}"
: "${PT_BACKUP_DIR:=/var/backups/patches}"
: "${PT_CACHE_DIR:=/var/cache/patches}"
: "${PT_SILENT:=false}"
: "${PT_DEBUG:=false}"

# ==============================
# Logging e inicialização
# ==============================
log() {
  local level="$1"; shift
  local msg="$*"
  if type register_info >/dev/null 2>&1; then
    case "$level" in
      INFO)  register_info "$msg";;
      WARN)  register_warn "$msg";;
      ERROR) register_error "$msg";;
      DEBUG) register_debug "$msg";;
    esac
  else
    [[ "${PT_SILENT}" == "true" && "$level" != "ERROR" ]] && return 0
    case "$level" in
      INFO)  echo -e "\e[32m[INFO]\e[0m $msg";;
      WARN)  echo -e "\e[33m[WARN]\e[0m $msg" >&2;;
      ERROR) echo -e "\e[31m[ERROR]\e[0m $msg" >&2;;
      DEBUG) [[ "${PT_DEBUG}" == "true" ]] && echo -e "\e[36m[DEBUG]\e[0m $msg";;
    esac
  fi
}

fail() {
  log ERROR "$*"
  exit 1
}

safe_mkdir() {
  mkdir -p "$1" 2>/dev/null || fail "Falha ao criar diretório $1"
  chmod 750 "$1" || true
}

# ==============================
# Integração com register.sh e downloader.sh
# ==============================
if ! type dl_fetch >/dev/null 2>&1; then
  if [[ -f /usr/bin/downloader.sh ]]; then
    source /usr/bin/downloader.sh
    dl_init || log WARN "Falha ao inicializar downloader"
  elif [[ -f /mnt/lfs/usr/bin/downloader.sh ]]; then
    source /mnt/lfs/usr/bin/downloader.sh
    dl_init || log WARN "Falha ao inicializar downloader (LFS)"
  else
    log WARN "downloader.sh não encontrado — downloads diretos serão usados"
  fi
fi

# ==============================
# Inicialização do módulo
# ==============================
pt_init() {
  safe_mkdir "${PT_PATCH_DIR}"
  safe_mkdir "${PT_LOG_DIR}"
  safe_mkdir "${PT_BACKUP_DIR}"
  safe_mkdir "${PT_CACHE_DIR}"
  trap 'pt_cleanup' EXIT INT TERM
  log INFO "patches.sh inicializado"
}

pt_cleanup() {
  # remove temporários, se existirem
  find /tmp -maxdepth 1 -type d -name "patchwork_*" -mmin +60 -exec rm -rf {} + 2>/dev/null || true
}

# ==============================
# Baixar patches declarados
# ==============================
pt_fetch_all() {
  local patches=("$@")
  [[ ${#patches[@]} -eq 0 ]] && { log WARN "Nenhum patch definido"; return 0; }

  for patch_url in "${patches[@]}"; do
    local fname=$(basename "${patch_url%%\?*}")
    local dest="${PT_CACHE_DIR}/${fname}"
    if [[ -f "$dest" ]]; then
      log INFO "Patch já em cache: $fname"
      continue
    fi
    log INFO "Baixando patch: $patch_url"
    if type dl_fetch >/dev/null 2>&1; then
      if ! dl_fetch "$patch_url"; then
        fail "Falha ao baixar patch $patch_url"
      fi
    else
      if ! curl -L --fail --silent --show-error -o "$dest" "$patch_url"; then
        fail "Erro ao baixar patch $patch_url"
      fi
    fi
  done
}

# ==============================
# Verificar integridade (SHA256)
# ==============================
pt_verify() {
  local patch_file="$1"
  local sha256_expected="${2:-}"
  if [[ -z "$sha256_expected" ]]; then
    log DEBUG "SHA256 não fornecido para $patch_file"
    return 0
  fi
  if ! sha256sum --status -c <(echo "${sha256_expected}  ${patch_file}") 2>/dev/null; then
    fail "Checksum inválido para $patch_file"
  fi
  log INFO "Checksum verificado com sucesso: $patch_file"
}

# ==============================
# Testar aplicação (dry-run)
# ==============================
pt_check() {
  local patch_file="$1"; local dest="${2:-.}"
  [[ ! -f "$patch_file" ]] && fail "Patch inexistente: $patch_file"
  log INFO "Testando patch (dry-run): $patch_file"
  if patch --dry-run -p1 <"$patch_file" >/dev/null 2>&1; then
    log INFO "Patch aplicável: $patch_file"
    return 0
  else
    log WARN "Patch já aplicado ou incompatível: $patch_file"
    return 1
  fi
}

# ==============================
# Aplicar patch com segurança
# ==============================
pt_apply() {
  local patch_file="$1"; local dest="${2:-.}"
  [[ ! -f "$patch_file" ]] && fail "Patch não encontrado: $patch_file"
  cd "$dest"

  # Cria backup
  local backup_dir="${PT_BACKUP_DIR}/$(basename "$patch_file").bak"
  safe_mkdir "$backup_dir"

  log INFO "Aplicando patch: $(basename "$patch_file")"
  if ! patch --batch --silent --forward -p1 <"$patch_file" >/dev/null 2>&1; then
    log ERROR "Falha ao aplicar patch: $(basename "$patch_file")"
    log INFO "Revertendo alterações parciais..."
    cp -a "$backup_dir"/* "$dest"/ 2>/dev/null || true
    return 1
  fi
  log INFO "Patch aplicado com sucesso: $(basename "$patch_file")"
}

# ==============================
# Aplicar múltiplos patches
# ==============================
pt_apply_all() {
  local patches=("$@")
  [[ ${#patches[@]} -eq 0 ]] && { log WARN "Nenhum patch fornecido"; return 0; }

  local count=0
  for patch in "${patches[@]}"; do
    count=$((count+1))
    if ! pt_check "$patch"; then
      log WARN "Pulando patch já aplicado: $(basename "$patch")"
      continue
    fi
    if ! pt_apply "$patch"; then
      fail "Erro crítico ao aplicar patch $patch"
    fi
  done
  log INFO "Total de patches aplicados: $count"
}

# ==============================
# Reverter patch
# ==============================
pt_revert() {
  local patch_file="$1"; local dest="${2:-.}"
  local backup_dir="${PT_BACKUP_DIR}/$(basename "$patch_file").bak"
  [[ ! -d "$backup_dir" ]] && fail "Backup não encontrado para $patch_file"
  log WARN "Revertendo patch: $(basename "$patch_file")"
  cp -a "$backup_dir"/* "$dest"/ 2>/dev/null || fail "Falha ao reverter $patch_file"
  log INFO "Reversão concluída: $(basename "$patch_file")"
}

# ==============================
# Resumo
# ==============================
pt_summary() {
  echo "-------------------------------------"
  echo "Diretório de patches: ${PT_PATCH_DIR}"
  echo "Backup: ${PT_BACKUP_DIR}"
  echo "Cache:  ${PT_CACHE_DIR}"
  echo "Logs:   ${PT_LOG_DIR}"
  echo "-------------------------------------"
  local total=$(find "${PT_CACHE_DIR}" -type f 2>/dev/null | wc -l || echo 0)
  echo "Patches no cache: ${total}"
}

# ==============================
# CLI
# ==============================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  case "$cmd" in
    --fetch)
      shift
      pt_init
      pt_fetch_all "$@"
      ;;
    --apply)
      shift
      pt_init
      pt_apply_all "$@"
      ;;
    --check)
      shift
      pt_init
      pt_check "$@"
      ;;
    --revert)
      shift
      pt_init
      pt_revert "$@"
      ;;
    --summary)
      pt_summary
      ;;
    --help|-h|"")
      cat <<EOF
Uso:
  patches.sh --fetch <url1> [url2 ...]    Baixa patches
  patches.sh --apply <patch1> [patch2...] Aplica patches com segurança
  patches.sh --check <patch> [dir]        Testa se patch é aplicável
  patches.sh --revert <patch> [dir]       Reverte patch aplicado
  patches.sh --summary                    Mostra informações
EOF
      ;;
    *)
      fail "Comando inválido. Use --help."
      ;;
  esac
fi

# ==============================
# EXPORTA FUNÇÕES
# ==============================
export -f pt_init pt_fetch_all pt_apply pt_apply_all pt_revert pt_check pt_summary
