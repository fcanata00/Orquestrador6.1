#!/usr/bin/env bash
# ============================================================
# metafile.sh - Sistema modular de construção de pacotes LFS/BLFS
# ============================================================
# Funções:
#  - Carrega receitas (metafiles)
#  - Faz download, aplica patches, compila e instala
#  - Executa hooks pré/pós em cada fase
#  - Integra com downloader.sh, patches.sh, register.sh, hooks.sh
# ============================================================

set -eEuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="metafile"

# ============================================================
# Configuração base
# ============================================================
: "${LFS:=/mnt/lfs}"
: "${SRC_DIR:=/usr/src}"
: "${LFS_SRC_DIR:=/mnt/lfs/usr/src}"
: "${CACHE_SOURCES:=/var/cache/sources}"
: "${CACHE_BINARIES:=/var/cache/binaries}"
: "${MF_SILENT:=false}"
: "${MF_DEBUG:=false}"
: "${MF_JOBS:=$(nproc)}"

BUILD_DIR="/tmp/build.$$"
PKG_DIR=""
MF_FILE=""

# ============================================================
# Logging
# ============================================================
log() {
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
    [[ "$MF_SILENT" == "true" && "$level" != "ERROR" ]] && return 0
    case "$level" in
      INFO)  echo -e "\e[32m[INFO]\e[0m $msg";;
      WARN)  echo -e "\e[33m[WARN]\e[0m $msg" >&2;;
      ERROR) echo -e "\e[31m[ERROR]\e[0m $msg" >&2;;
      DEBUG) [[ "$MF_DEBUG" == "true" ]] && echo -e "\e[36m[DEBUG]\e[0m $msg";;
      *) echo "[LOG] $msg";;
    esac
  fi
}
fail() { log ERROR "$*"; exit 1; }
safe_mkdir() { mkdir -p "$1" 2>/dev/null || fail "Falha ao criar diretório $1"; }

# ============================================================
# Integração automática com módulos
# ============================================================
for mod in register downloader patches hooks; do
  if ! type "${mod}_init" >/dev/null 2>&1 && [[ -f /usr/bin/${mod}.sh ]]; then
    source /usr/bin/${mod}.sh || log WARN "Falha ao carregar ${mod}.sh"
    [[ "${mod}" == "hooks" ]] && hooks_init || true
    log INFO "${mod}.sh carregado"
  elif ! type "${mod}_init" >/dev/null 2>&1 && [[ -f /mnt/lfs/usr/bin/${mod}.sh ]]; then
    source /mnt/lfs/usr/bin/${mod}.sh || log WARN "Falha ao carregar ${mod}.sh (LFS)"
    [[ "${mod}" == "hooks" ]] && hooks_init || true
    log INFO "${mod}.sh (LFS) carregado"
  fi
done

# ============================================================
# Estrutura de dados do metafile
# ============================================================
declare MF_NAME MF_VERSION MF_DESCRIPTION MF_CATEGORY MF_ARCH
declare MF_URLS MF_SHA256S MF_PATCHES MF_PATCH_SHA256S MF_ENV_FLAGS
declare -a MF_URLS=() MF_SHA256S=() MF_PATCHES=() MF_PATCH_SHA256S=()

sanitize_key() { echo "$1" | sed -E 's/[^A-Za-z0-9_.-]//g'; }
sanitize_value() { echo "$1" | sed -E 's/[;`$]//g'; }

# ============================================================
# Carrega o arquivo .ini (metafile)
# ============================================================
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
      *) log DEBUG "Ignorando chave desconhecida: $key" ;;
    esac
  done <"$MF_FILE"
  [[ -z "${MF_NAME:-}" ]] && fail "Campo 'name' ausente no metafile"
  PKG_DIR="${SRC_DIR}/${MF_CATEGORY}/${MF_NAME}"
  log INFO "Metafile carregado: ${MF_NAME} ${MF_VERSION}"
}

# ============================================================
# Busca e valida fontes
# ============================================================
mf_fetch_sources() {
  [[ ${#MF_URLS[@]} -eq 0 ]] && { log WARN "Nenhum source definido"; return 0; }
  safe_mkdir "${CACHE_SOURCES}"
  local idx=0
  for url in "${MF_URLS[@]}"; do
    local expanded_url="${url//\$\{VERSION\}/${MF_VERSION}}"
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

# ============================================================
# Aplica patches declarados
# ============================================================
mf_apply_patches() {
  [[ ${#MF_PATCHES[@]} -eq 0 ]] && { log INFO "Nenhum patch definido"; return 0; }
  log INFO "Aplicando ${#MF_PATCHES[@]} patches"
  if type pt_apply_all >/dev/null 2>&1; then
    pt_apply_all "${MF_PATCHES[@]}"
  else
    for p in "${MF_PATCHES[@]}"; do
      [[ -f "$p" ]] && patch -Np1 -i "$p" || log WARN "Patch não encontrado: $p"
    done
  fi
}

# ============================================================
# Execução de fases com hooks pré/pós
# ============================================================
mf_run_stage() {
  local stage="$1"
  log DEBUG "Executando etapa: $stage"
  type hooks_run >/dev/null 2>&1 && hooks_run "pre-${stage}" "${BUILD_DIR}" "${PKG_DIR}" || true
  "mf_${stage}" || fail "Falha em ${stage}"
  type hooks_run >/dev/null 2>&1 && hooks_run "post-${stage}" "${BUILD_DIR}" "${PKG_DIR}" || true
}

# ============================================================
# Etapas individuais
# ============================================================
mf_prepare() {
  log INFO "[PREPARE] Preparando ambiente"
  rm -rf "${BUILD_DIR}" && safe_mkdir "${BUILD_DIR}"
  tarball=$(find "${CACHE_SOURCES}" -maxdepth 1 -type f -name "${MF_NAME}-*.tar.*" | head -n1)
  [[ -f "$tarball" ]] || fail "Tarball não encontrado"
  tar xf "$tarball" -C "${BUILD_DIR}" --strip-components=1
  cd "${BUILD_DIR}"
}

mf_configure() {
  log INFO "[CONFIGURE] Configurando build"
  cd "${BUILD_DIR}"
  export ${MF_ENV_FLAGS:-}
  if [[ -f "./configure" ]]; then
    ./configure --prefix=/usr
  elif [[ -f "CMakeLists.txt" ]]; then
    cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
  elif [[ -f "meson.build" ]]; then
    meson setup build --prefix=/usr
  fi
}

mf_build() {
  log INFO "[BUILD] Compilando"
  cd "${BUILD_DIR}"
  if [[ -d "build" ]]; then cd build; fi
  make -j"${MF_JOBS}" || fail "Erro em make"
}

mf_check() {
  log INFO "[CHECK] Testando (se aplicável)"
  cd "${BUILD_DIR}"
  if [[ -d "build" ]]; then cd build; fi
  make -k check || log WARN "Testes falharam (continuando)"
}

mf_install() {
  log INFO "[INSTALL] Instalando"
  cd "${BUILD_DIR}"
  if [[ -d "build" ]]; then cd build; fi
  make install || fail "Falha em make install"
}

mf_uninstall() {
  log INFO "[UNINSTALL] Removendo pacote"
  [[ -n "${MF_NAME:-}" ]] || fail "mf_uninstall: nome não definido"
  find /usr -type f -name "${MF_NAME}*" -exec rm -f {} \; || true
  log INFO "Pacote ${MF_NAME} removido"
}

mf_summary() {
  log INFO "[SUMMARY] ${MF_NAME}-${MF_VERSION} concluído"
  if type hooks_summary >/dev/null 2>&1; then hooks_summary; fi
}

# ============================================================
# Construção completa
# ============================================================
mf_construction() {
  mf_run_stage prepare
  mf_run_stage configure
  mf_run_stage build
  mf_run_stage check
  mf_run_stage install
  mf_summary
}

# ============================================================
# CLI
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  case "$cmd" in
    --load) shift; mf_load "$1";;
    --fetch) shift; mf_load "$1"; mf_fetch_sources;;
    --patch) shift; mf_load "$1"; mf_apply_patches;;
    --build) shift; mf_load "$1"; mf_fetch_sources; mf_apply_patches; mf_construction;;
    --uninstall) shift; mf_load "$1"; mf_uninstall;;
    --help|-h|"")
      cat <<EOF
Uso:
  metafile.sh --build <arquivo.ini>     Constrói pacote completo
  metafile.sh --fetch <arquivo.ini>     Baixa sources
  metafile.sh --patch <arquivo.ini>     Aplica patches
  metafile.sh --uninstall <arquivo.ini> Remove pacote
EOF
      ;;
    *) fail "Comando inválido. Use --help." ;;
  esac
fi

# ============================================================
# Exporta funções
# ============================================================
export -f mf_load mf_fetch_sources mf_apply_patches mf_prepare mf_configure \
  mf_build mf_check mf_install mf_uninstall mf_summary mf_construction mf_run_stage
