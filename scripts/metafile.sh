#!/usr/bin/env bash
# metafile.sh — Carregador e gerenciador de receitas (metafiles)
# Integrado com downloader.sh, patches.sh, register.sh e hooks
set -eEuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="metafile"

# ==============================
# Configurações padrão
# ==============================
: "${LFS:=/mnt/lfs}"
: "${SRC_DIR:=/usr/src}"
: "${LFS_SRC_DIR:=/mnt/lfs/usr/src}"
: "${CACHE_SOURCES:=/var/cache/sources}"
: "${CACHE_BINARIES:=/var/cache/binaries}"
: "${MF_SILENT:=false}"
: "${MF_DEBUG:=false}"

# ==============================
# Logging e falhas
# ==============================
log() {
  local level="$1"; shift
  local msg="$*"
  if type register_info >/dev/null 2>&1; then
    case "$level" in
      INFO)  register_info "$msg" ;;
      WARN)  register_warn "$msg" ;;
      ERROR) register_error "$msg" ;;
      DEBUG) register_debug "$msg" ;;
      *) register_info "$msg" ;;
    esac
  else
    [[ "$MF_SILENT" == "true" && "$level" != "ERROR" ]] && return 0
    case "$level" in
      INFO)  echo -e "\e[32m[INFO]\e[0m $msg" ;;
      WARN)  echo -e "\e[33m[WARN]\e[0m $msg" ;;
      ERROR) echo -e "\e[31m[ERROR]\e[0m $msg" >&2 ;;
      DEBUG) [[ "$MF_DEBUG" == "true" ]] && echo -e "\e[36m[DEBUG]\e[0m $msg" ;;
      *)     echo "[LOG] $msg" ;;
    esac
  fi
}

fail() { log ERROR "$*"; exit 1; }

safe_mkdir() { mkdir -p "$1" 2>/dev/null || fail "Falha ao criar diretório $1"; chmod 750 "$1" || true; }

sanitize_key() { echo "$1" | sed -E 's/[^A-Za-z0-9_.-]//g'; }
sanitize_value() { echo "$1" | sed -E 's/[;`$]//g'; }

# ==============================
# Integração automática com módulos
# ==============================
for mod in downloader patches hooks register; do
  if ! type "${mod}_init" >/dev/null 2>&1 && [[ -f /usr/bin/${mod}.sh ]]; then
    source /usr/bin/${mod}.sh || log WARN "Falha ao carregar ${mod}.sh"
    log INFO "${mod}.sh carregado"
  elif ! type "${mod}_init" >/dev/null 2>&1 && [[ -f /mnt/lfs/usr/bin/${mod}.sh ]]; then
    source /mnt/lfs/usr/bin/${mod}.sh || log WARN "Falha ao carregar ${mod}.sh (LFS)"
    log INFO "${mod}.sh (LFS) carregado"
  fi
done

# ==============================
# Estrutura de dados
# ==============================
declare MF_FILE MF_NAME MF_VERSION MF_URLS MF_SHA256S MF_PATCHES MF_PATCH_SHA256S
declare MF_ENV_FLAGS MF_DESCRIPTION MF_CATEGORY MF_ARCH MF_HOOKS

declare -a MF_URLS=()
declare -a MF_SHA256S=()
declare -a MF_PATCHES=()
declare -a MF_PATCH_SHA256S=()

# ==============================
# Parser de metafile.ini
# ==============================
mf_load() {
  MF_FILE="$1"
  [[ ! -f "$MF_FILE" ]] && fail "Metafile não encontrado: $MF_FILE"
  log INFO "Carregando metafile: $MF_FILE"

  while IFS='=' read -r key val; do
    [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
    key=$(sanitize_key "$key"); val=$(sanitize_value "$val")
    case "$key" in
      name) MF_NAME="$val" ;;
      version) MF_VERSION="$val" ;;
      description) MF_DESCRIPTION="$val" ;;
      category) MF_CATEGORY="$val" ;;
      arch) MF_ARCH="$val" ;;
      urls) read -ra MF_URLS <<<"$val" ;;
      sha256sums) read -ra MF_SHA256S <<<"$val" ;;
      patches) read -ra MF_PATCHES <<<"$val" ;;
      patchsha256sums) read -ra MF_PATCH_SHA256S <<<"$val" ;;
      envflags) MF_ENV_FLAGS="$val" ;;
      hooks) MF_HOOKS="$val" ;;
      *) log DEBUG "Ignorando chave desconhecida: $key" ;;
    esac
  done <"$MF_FILE"

  [[ -z "${MF_NAME:-}" ]] && fail "Campo 'name' ausente no metafile"
  log INFO "Metafile carregado: $MF_NAME $MF_VERSION"
}

# ==============================
# Expansão de variáveis
# ==============================
mf_expand_vars() {
  local text="$1"
  text="${text//\$\{NAME\}/${MF_NAME}}"
  text="${text//\$\{VERSION\}/${MF_VERSION}}"
  echo "$text"
}

# ==============================
# Criação automática de metafile
# ==============================
mf_create() {
  local category="$1"; local pkg="$2"
  [[ -z "$category" || -z "$pkg" ]] && fail "Uso: metafile.sh --create <categoria> <pacote>"
  local path="${SRC_DIR}/${category}/${pkg}"
  safe_mkdir "$path"
  local ini="${path}/${pkg}.ini"

  cat >"$ini" <<EOF
# Exemplo de metafile para ${pkg}
name=${pkg}
version=1.0
description=Exemplo de pacote ${pkg}
category=${category}
arch=$(uname -m)

urls=https://example.org/${pkg}-\${VERSION}.tar.xz
sha256sums=
patches=
patchsha256sums=

envflags=CFLAGS="-O2 -pipe"
hooks=
EOF
  log INFO "Metafile criado em: $ini"
}

# ==============================
# Buscar e validar sources
# ==============================
mf_fetch_sources() {
  [[ ${#MF_URLS[@]} -eq 0 ]] && { log WARN "Nenhum source definido"; return 0; }
  safe_mkdir "${CACHE_SOURCES}"
  local idx=0
  for url in "${MF_URLS[@]}"; do
    local expanded_url; expanded_url=$(mf_expand_vars "$url")
    local sha="${MF_SHA256S[$idx]:-}"
    idx=$((idx+1))
    if type dl_fetch >/dev/null 2>&1; then
      dl_fetch "$expanded_url" "$sha" || fail "Falha no download: $expanded_url"
    else
      local fname=$(basename "$expanded_url")
      log WARN "downloader.sh não encontrado, usando curl"
      curl -L --fail -o "${CACHE_SOURCES}/${fname}" "$expanded_url" || fail "Erro: $expanded_url"
    fi
  done
}

# ==============================
# Aplicar patches declarados
# ==============================
mf_apply_patches() {
  [[ ${#MF_PATCHES[@]} -eq 0 ]] && { log INFO "Nenhum patch definido"; return 0; }
  log INFO "Aplicando ${#MF_PATCHES[@]} patches"
  if type pt_fetch_all >/dev/null 2>&1; then
    pt_fetch_all "${MF_PATCHES[@]}"
  fi
  if type pt_apply_all >/dev/null 2>&1; then
    pt_apply_all "${MF_PATCHES[@]}"
  else
    log WARN "patches.sh não disponível — pulando aplicação de patches"
  fi
}

# ==============================
# Hooks
# ==============================
mf_run_hook() {
  local stage="$1"
  local hook_file="${MF_HOOKS}/${stage}.sh"
  [[ -x "$hook_file" ]] && { log INFO "Executando hook: ${stage}"; "$hook_file" || log WARN "Hook ${stage} falhou"; }
}

# ==============================
# Construção (prepare/configure/build/install)
# ==============================
mf_construction() {
  mf_run_hook pre-prepare
  log INFO "Preparando ambiente para ${MF_NAME}"
  export ${MF_ENV_FLAGS:-}
  mf_run_hook pre-configure
  log INFO "Configurando ${MF_NAME}..."
  [[ -f "./configure" ]] && ./configure --prefix=/usr || log WARN "Sem script configure"
  mf_run_hook post-configure
  log INFO "Compilando ${MF_NAME}..."
  make -j"$(nproc)" || fail "Erro em make"
  mf_run_hook post-build
  log INFO "Instalando ${MF_NAME}..."
  make install || fail "Erro em make install"
  mf_run_hook post-install
}

# ==============================
# CLI
# ==============================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  case "$cmd" in
    --load)
      shift; mf_load "$1" ;;
    --fetch)
      shift; mf_load "$1"; mf_fetch_sources ;;
    --patch)
      shift; mf_load "$1"; mf_apply_patches ;;
    --build)
      shift; mf_load "$1"; mf_fetch_sources; mf_apply_patches; mf_construction ;;
    --create)
      shift; mf_create "$@" ;;
    --help|-h|"")
      cat <<EOF
Uso:
  metafile.sh --load <arquivo.ini>          Carrega metafile
  metafile.sh --fetch <arquivo.ini>         Baixa fontes
  metafile.sh --patch <arquivo.ini>         Baixa e aplica patches
  metafile.sh --build <arquivo.ini>         Faz build completo (fetch+patch+compilar)
  metafile.sh --create <categoria> <nome>   Cria metafile exemplo
EOF
      ;;
    *)
      fail "Comando inválido. Use --help."
      ;;
  esac
fi

# ==============================
# Exporta funções
# ==============================
export -f mf_load mf_fetch_sources mf_apply_patches mf_construction mf_create
