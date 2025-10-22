#!/usr/bin/env bash
# metafile.sh - carrega, cria e gerencia receitas de compilação (metafiles)
set -eEuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="metafile"
# ===============================
# CONFIG PADRÃO
# ===============================
: "${LFS:=/mnt/lfs}"
: "${SRC_DIR_SYSTEM:=/usr/src}"
: "${SRC_DIR_LFS:=${LFS}/usr/src}"
: "${CACHE_SOURCES:=/var/cache/sources}"
: "${CACHE_BINARIES:=/var/cache/binaries}"
: "${MF_SILENT:=false}"
: "${MF_DEBUG:=false}"
# logs básicos ou usa register.sh se disponível
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
    [[ "${MF_SILENT}" == "true" && "$level" != "ERROR" ]] && return 0
    local color_reset="\e[0m"
    local color_info="\e[32m"; local color_warn="\e[33m"; local color_err="\e[31m"; local color_dbg="\e[36m"
    case "$level" in
      INFO)  echo -e "${color_info}[INFO]${color_reset} $msg";;
      WARN)  echo -e "${color_warn}[WARN]${color_reset} $msg" >&2;;
      ERROR) echo -e "${color_err}[ERROR]${color_reset} $msg" >&2;;
      DEBUG) [[ "${MF_DEBUG}" == "true" ]] && echo -e "${color_dbg}[DEBUG]${color_reset} $msg";;
    esac
  fi
}

# ===============================
# FUNÇÕES AUXILIARES
# ===============================
fail() { log ERROR "$*"; exit 1; }
safe_mkdir() { mkdir -p "$1" 2>/dev/null || fail "Não foi possível criar diretório $1"; chmod 755 "$1" || true; }

# sanitização básica
sanitize_key() { echo "$1" | sed -E 's/[^A-Za-z0-9_.-]//g'; }
sanitize_value() { echo "$1" | sed -E 's/[;`$]//g'; }
# ===============================
# Integração automática com downloader.sh
# ===============================
if ! type dl_fetch >/dev/null 2>&1; then
  if [[ -f /usr/bin/downloader.sh ]]; then
    source /usr/bin/downloader.sh
    dl_init || log WARN "Falha ao inicializar downloader"
    log INFO "downloader.sh carregado com sucesso"
  elif [[ -f /mnt/lfs/usr/bin/downloader.sh ]]; then
    source /mnt/lfs/usr/bin/downloader.sh
    dl_init || log WARN "Falha ao inicializar downloader (LFS)"
    log INFO "downloader.sh (LFS) carregado com sucesso"
  else
    log WARN "downloader.sh não encontrado — downloads diretos serão usados"
  fi
fi
# ===============================
# mf_load - carrega um metafile.ini
# ===============================
mf_load() {
  local metafile="$1"
  [[ ! -f "$metafile" ]] && fail "Arquivo metafile.ini não encontrado: $metafile"
  log INFO "Carregando metafile: $metafile"

  # limpar variáveis antigas
  unset MF_NAME MF_VERSION MF_DESC MF_URLS MF_PATCHES MF_CATEGORY MF_ENV MF_ARCH MF_HOOKS MF_SHA256S

  local section=""
  while IFS='=' read -r raw_key raw_value || [[ -n "$raw_key" ]]; do
    [[ "$raw_key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$raw_key" ]] && continue
    if [[ "$raw_key" =~ ^\[.*\]$ ]]; then
      section=$(echo "$raw_key" | tr -d '[]')
      continue
    fi
    key=$(sanitize_key "${raw_key// /}")
    value=$(sanitize_value "${raw_value}")
    value=$(echo "$value" | xargs) # trim
    [[ -z "$key" ]] && continue
    case "$section" in
      General)
        case "$key" in
          Name)     MF_NAME="$value";;
          Version)  MF_VERSION="$value";;
          Desc*)    MF_DESC="$value";;
          Category) MF_CATEGORY="$value";;
          Arch)     MF_ARCH="$value";;
        esac ;;
      Source)
        case "$key" in
          URL*)       MF_URLS+=("$value");;
          SHA256*|Sum*) MF_SHA256S+=("$value");;
        esac ;;
      Patch)
        MF_PATCHES+=("$value");;
      Hooks)
        MF_HOOKS+=("$value");;
      Environment)
        MF_ENV+=("$key=$value");;
    esac
  done < "$metafile"

  MF_NAME="${MF_NAME:-unknown}"
  MF_VERSION="${MF_VERSION:-0.0}"
  MF_CATEGORY="${MF_CATEGORY:-misc}"
  MF_ARCH="${MF_ARCH:-$(uname -m)}"

  log INFO "Metafile carregado: ${MF_NAME}-${MF_VERSION} [${MF_CATEGORY}]"
}

# ===============================
# mf_expand_vars - expande ${NAME}, ${VERSION}
# ===============================
mf_expand_vars() {
  local input="$1"
  local output="${input//\$\{NAME\}/${MF_NAME}}"
  output="${output//\$\{VERSION\}/${MF_VERSION}}"
  echo "$output"
}

# ===============================
# mf_fetch_sources - busca os sources
# ===============================
# ===============================
# mf_fetch_sources - busca os sources
# ===============================
mf_fetch_sources() {
  [[ -z "${MF_URLS[*]:-}" ]] && { log WARN "Nenhum source definido"; return 0; }
  safe_mkdir "${CACHE_SOURCES:-/var/cache/sources}"
  local idx=0
  for url in "${MF_URLS[@]}"; do
    local expanded_url; expanded_url=$(mf_expand_vars "$url")
    local sha="${MF_SHA256S[$idx]:-}"
    idx=$((idx+1))
    if type dl_fetch >/dev/null 2>&1; then
      # Usa o downloader integrado
      if ! dl_fetch "$expanded_url" "$sha"; then
        log ERROR "Falha no download via downloader.sh: $expanded_url"
        return 1
      fi
    else
      # Fallback para curl se downloader não estiver disponível
      local filename=$(basename "$expanded_url")
      local dest="${CACHE_SOURCES}/${filename}"
      if [[ -f "$dest" ]]; then
        log INFO "Fonte já em cache: $filename"
      else
        log INFO "Baixando: $expanded_url"
        if ! curl -L --fail --silent --show-error -o "$dest" "$expanded_url"; then
          fail "Falha no download: $expanded_url"
        fi
      fi
    fi
  done
}
# ===============================
# mf_apply_patches - aplica patches
# ===============================
mf_apply_patches() {
  [[ -z "${MF_PATCHES[*]:-}" ]] && { log DEBUG "Sem patches"; return 0; }
  for patchfile in "${MF_PATCHES[@]}"; do
    local expanded; expanded=$(mf_expand_vars "$patchfile")
    if [[ ! -f "$expanded" ]]; then
      log WARN "Patch não encontrado: $expanded"
      continue
    fi
    log INFO "Aplicando patch: $(basename "$expanded")"
    if ! patch -p1 < "$expanded" >/dev/null 2>&1; then
      fail "Erro ao aplicar patch $expanded"
    fi
  done
}
# ===============================
# mf_environment - exporta variáveis
# ===============================
mf_environment() {
  log DEBUG "Configurando ambiente de build"
  for kv in "${MF_ENV[@]:-}"; do
    eval "export ${kv}" || log WARN "Variável inválida em Environment: $kv"
  done
}
# ===============================
# mf_create - cria metafile exemplo
# ===============================
mf_create() {
  local category="$1"
  local name="$2"
  [[ -z "$category" || -z "$name" ]] && fail "Uso: metafile.sh --create <categoria> <nome>"
  local base_dir="${SRC_DIR_SYSTEM}/${category}/${name}"
  safe_mkdir "$base_dir"
  local metafile="${base_dir}/${name}.ini"

  if [[ -f "$metafile" ]]; then
    log WARN "Arquivo já existe: $metafile"
    return 0
  fi

  cat >"$metafile" <<EOF
[General]
Name=${name}
Version=1.0.0
Category=${category}
Arch=$(uname -m)
Description=Exemplo de pacote ${name}

[Source]
URL=https://example.com/\${NAME}-\${VERSION}.tar.xz
SHA256=d41d8cd98f00b204e9800998ecf8427e

[Environment]
CFLAGS=-O2 -pipe
LDFLAGS=-Wl,-O1

[Hooks]
pre-build=echo "Preparando build..."
post-install=echo "Instalação concluída"
EOF

  chmod 640 "$metafile"
  log INFO "Metafile criado em: $metafile"
}

# ===============================
# mf_summary - mostra resumo
# ===============================
mf_summary() {
  echo "--------------------------------"
  echo "Pacote:   ${MF_NAME}"
  echo "Versão:   ${MF_VERSION}"
  echo "Categoria:${MF_CATEGORY}"
  echo "Arquitet.:${MF_ARCH}"
  echo "Sources:  ${#MF_URLS[@]:-0}"
  echo "Patches:  ${#MF_PATCHES[@]:-0}"
  echo "--------------------------------"
}

# ===============================
# CLI
# ===============================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  case "$cmd" in
    --load)
      shift
      mf_load "${1:-metafile.ini}"
      mf_summary
      ;;
    --fetch)
      shift
      mf_load "${1:-metafile.ini}"
      mf_fetch_sources
      ;;
    --apply-patches)
      shift
      mf_load "${1:-metafile.ini}"
      mf_apply_patches
      ;;
    --env)
      shift
      mf_load "${1:-metafile.ini}"
      mf_environment
      env | grep -E 'CFLAGS|LDFLAGS|PATH'
      ;;
    --create)
      shift
      mf_create "$@"
      ;;
    --show)
      shift
      mf_load "${1:-metafile.ini}"
      mf_summary
      ;;
    --help|-h|"")
      cat <<EOF
Uso:
  metafile.sh --load <arquivo>         Carrega e mostra resumo
  metafile.sh --fetch <arquivo>        Faz download dos sources
  metafile.sh --apply-patches <arq>    Aplica patches
  metafile.sh --env <arquivo>          Exporta variáveis de ambiente
  metafile.sh --create <cat> <nome>    Cria novo metafile exemplo
  metafile.sh --show <arquivo>         Mostra resumo
EOF
      ;;
    *)
      fail "Comando inválido: $cmd"
      ;;
  esac
fi

# ===============================
# EXPORTA FUNÇÕES
# ===============================
export -f mf_load mf_fetch_sources mf_apply_patches mf_environment mf_expand_vars mf_create mf_summary
