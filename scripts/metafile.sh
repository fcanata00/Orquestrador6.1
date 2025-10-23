#!/usr/bin/env bash
# metafile.sh - Carregador de metafiles integrado com sandbox/hooks/downloader/patches
# Versão: 2025-10-23
set -eEuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="metafile"
SCRIPT_VERSION="1.0.0"

# -----------------------
# Configurações padrão (podem ser sobrescritas via env)
# -----------------------
: "${LFS:=/mnt/lfs}"
: "${SRC_DIR:=/usr/src}"
: "${LFS_SRC_DIR:=/mnt/lfs/usr/src}"
: "${CACHE_SOURCES:=/var/cache/sources}"
: "${CACHE_BINARIES:=/var/cache/binaries}"
: "${MF_SILENT:=false}"
: "${MF_DEBUG:=false}"
: "${MF_JOBS:=$(nproc)}"
: "${SANDBOX_USE:=true}"         # true/false - use sandbox when available
: "${SANDBOX_PERSIST:=false}"    # preserve sandbox after build
: "${SANDBOX_MODE:=auto}"        # auto / chroot / unshare
: "${RSYNC_BIN:=$(command -v rsync || true)}"

# -----------------------
# Runtime vars
# -----------------------
BUILD_DIR="${BUILD_DIR:-/tmp/build.$$}"
PKG_DIR=""            # /usr/src/<category>/<pkg>
MF_FILE=""
_SANDBOX_SESSION=""   # provided by sandbox.sh when sourced (internal var)
SANDBOX_WORKDIR="/work" # inside sandbox
# -----------------------
# Logging (integrates with register.sh if present)
# -----------------------
log() {
  local level="$1"; shift
  local msg="$*"
  if type register_info >/dev/null 2>&1; then
    case "$level" in
      INFO)  register_info "$msg";;
      WARN)  register_warn "$msg";;
      ERROR) register_error "$msg";;
      DEBUG) register_debug "$msg";;
      *) register_info "$msg";;
    esac
  else
    [[ "${MF_SILENT}" == "true" && "$level" != "ERROR" ]] && return 0
    case "$level" in
      INFO)  printf '\e[32m[INFO]\e[0m %s\n' "$msg" ;;
      WARN)  printf '\e[33m[WARN]\e[0m %s\n' "$msg" >&2 ;;
      ERROR) printf '\e[31m[ERROR]\e[0m %s\n' "$msg" >&2 ;;
      DEBUG) [[ "${MF_DEBUG}" == "true" ]] && printf '\e[36m[DEBUG]\e[0m %s\n' "$msg" ;;
      *) echo "[LOG] $msg";;
    esac
  fi
}
fail() { log ERROR "$*"; exit 1; }

safe_mkdir() { mkdir -p "$1" 2>/dev/null || fail "Não foi possível criar diretório $1"; chmod 750 "$1" || true; }

# -----------------------
# Auto-load modules (register, downloader, patches, hooks, sandbox)
# -----------------------
for mod in register downloader patches hooks sandbox; do
  if ! type "${mod}_init" >/dev/null 2>&1 && [[ -f /usr/bin/${mod}.sh ]]; then
    # shellcheck disable=SC1090
    source /usr/bin/${mod}.sh || log WARN "Falha ao carregar ${mod}.sh"
    log INFO "${mod}.sh carregado de /usr/bin"
    # try init for modules that define it
    if type "${mod}_init" >/dev/null 2>&1; then
      "${mod}_init" || log WARN "Inicialização ${mod}_init retornou não-zero"
    fi
  elif ! type "${mod}_init" >/dev/null 2>&1 && [[ -f /mnt/lfs/usr/bin/${mod}.sh ]]; then
    # shellcheck disable=SC1090
    source /mnt/lfs/usr/bin/${mod}.sh || log WARN "Falha ao carregar ${mod}.sh (LFS)"
    log INFO "${mod}.sh (LFS) carregado"
    if type "${mod}_init" >/dev/null 2>&1; then
      "${mod}_init" || log WARN "Inicialização ${mod}_init retornou não-zero"
    fi
  fi
done

# -----------------------
# Data structures for metafile
# -----------------------
declare MF_NAME MF_VERSION MF_DESCRIPTION MF_CATEGORY MF_ARCH MF_HOOKS MF_ENV_FLAGS
declare -a MF_URLS=() MF_SHA256S=() MF_PATCHES=() MF_PATCH_SHA256S=()

sanitize_key() { echo "$1" | sed -E 's/[^A-Za-z0-9_.-]//g'; }
sanitize_value() { echo "$1" | sed -E 's/[;`$]//g'; }

# -----------------------
# Parse metafile (simple ini-like)
# -----------------------
mf_load() {
  MF_FILE="$1"
  [[ -f "$MF_FILE" ]] || fail "Metafile não encontrado: $MF_FILE"
  log INFO "Carregando metafile: $MF_FILE"
  # reset
  MF_NAME=""; MF_VERSION=""; MF_DESCRIPTION=""; MF_CATEGORY=""; MF_ARCH=""
  MF_HOOKS=""; MF_ENV_FLAGS=""
  MF_URLS=(); MF_SHA256S=(); MF_PATCHES=(); MF_PATCH_SHA256S=()
  while IFS='=' read -r rawk rawv || [[ -n "$rawk" ]]; do
    [[ "$rawk" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$rawk" ]] && continue
    key=$(sanitize_key "${rawk// /}")
    value=$(sanitize_value "${rawv}")
    value=$(echo "$value" | xargs)
    case "$key" in
      name) MF_NAME="$value" ;;
      version) MF_VERSION="$value" ;;
      description) MF_DESCRIPTION="$value" ;;
      category) MF_CATEGORY="$value" ;;
      arch) MF_ARCH="$value" ;;
      urls) read -ra MF_URLS <<<"$value" ;;
      sha256sums) read -ra MF_SHA256S <<<"$value" ;;
      patches) read -ra MF_PATCHES <<<"$value" ;;
      patchsha256sums) read -ra MF_PATCH_SHA256S <<<"$value" ;;
      envflags) MF_ENV_FLAGS="$value" ;;
      hooks) MF_HOOKS="$value" ;;
      *) log DEBUG "Ignorando chave desconhecida: $key" ;;
    esac
  done < "$MF_FILE"

  [[ -z "${MF_NAME:-}" ]] && fail "Campo 'name' ausente no metafile"
  MF_CATEGORY="${MF_CATEGORY:-misc}"
  PKG_DIR="${SRC_DIR}/${MF_CATEGORY}/${MF_NAME}"
  log INFO "Metafile carregado: ${MF_NAME} ${MF_VERSION} (categoria: ${MF_CATEGORY})"
}

# -----------------------
# Utility: expand variables in strings (NAME, VERSION)
# -----------------------
mf_expand_vars() {
  local text="$1"
  text="${text//\$\{NAME\}/${MF_NAME}}"
  text="${text//\$\{VERSION\}/${MF_VERSION}}"
  echo "$text"
}

# -----------------------
# Downloader integration (fetch sources via dl_fetch when available)
# -----------------------
mf_fetch_sources() {
  safe_mkdir "${CACHE_SOURCES}"
  [[ ${#MF_URLS[@]} -eq 0 ]] && { log WARN "Nenhum source definido"; return 0; }
  local idx=0
  for u in "${MF_URLS[@]}"; do
    local expanded; expanded=$(mf_expand_vars "$u")
    local sha="${MF_SHA256S[$idx]:-}"
    idx=$((idx+1))
    if type dl_fetch >/dev/null 2>&1; then
      log INFO "Baixando via downloader: $expanded"
      dl_fetch "$expanded" "$sha" || fail "dl_fetch falhou para $expanded"
    else
      local fname; fname=$(basename "${expanded%%\?*}")
      local dest="${CACHE_SOURCES}/${fname}"
      if [[ -f "$dest" ]]; then
        log INFO "Fonte em cache: $fname"
      else
        log INFO "Baixando com curl: $expanded"
        curl -L --fail --silent --show-error -o "$dest" "$expanded" || fail "Falha no download $expanded"
      fi
      if [[ -n "$sha" ]]; then
        if ! sha256sum -c <(echo "${sha}  ${dest}") >/dev/null 2>&1; then
          rm -f "$dest" || true
          fail "Checksum inválido para $expanded"
        fi
      fi
    fi
  done
}

# -----------------------
# Apply patches (use patches.sh if available)
# -----------------------
mf_apply_patches() {
  [[ ${#MF_PATCHES[@]} -eq 0 ]] && { log INFO "Nenhum patch definido"; return 0; }
  log INFO "Aplicando patches (${#MF_PATCHES[@]})"
  if type pt_fetch_all >/dev/null 2>&1 && type pt_apply_all >/dev/null 2>&1; then
    pt_fetch_all "${MF_PATCHES[@]}" || fail "pt_fetch_all falhou"
    pt_apply_all "${MF_PATCHES[@]}" || fail "pt_apply_all falhou"
  else
    # fallback: try to apply local patches if they exist in package dir
    for p in "${MF_PATCHES[@]}"; do
      local pf; pf=$(mf_expand_vars "$p")
      if [[ -f "$pf" ]]; then
        log INFO "Aplicando patch local: $pf"
        (cd "${BUILD_DIR}" && patch -Np1 -i "$pf") || fail "Falha ao aplicar patch $pf"
      else
        log WARN "Patch não encontrado: $pf (pulando)"
      fi
    done
  fi
}

# -----------------------
# Sandbox helpers: sync sources into sandbox and back
# -----------------------
# Note: sandbox.sh when sourced creates function sandbox_create and exposes internal _SANDBOX_SESSION variable.
# We rely on sandbox_create/sandbox_run/sandbox_mount_pseudofs/sandbox_cleanup being available if sandbox.sh is sourced.
_sandbox_available() {
  type sandbox_run >/dev/null 2>&1
}

_sync_to_sandbox() {
  # $1 -> host_dir (full path), copies into ${_SANDBOX_SESSION}/root${SANDBOX_WORKDIR}/
  local host_dir="${1:-}"
  if [[ -z "$host_dir" || ! -d "$host_dir" ]]; then
    log ERROR "sync_to_sandbox: diretório inválido: $host_dir"; return 2
  fi
  if [[ -z "${_SANDBOX_SESSION:-}" || ! -d "${_SANDBOX_SESSION}/root" ]]; then
    log ERROR "sync_to_sandbox: sessão sandbox inexistente"; return 3
  fi
  local destroot="${_SANDBOX_SESSION}/root${SANDBOX_WORKDIR}"
  mkdir -p "${destroot}" || { log ERROR "Falha criar ${destroot}"; return 4; }
  if [[ -n "${RSYNC_BIN}" ]]; then
    "${RSYNC_BIN}" -a --delete --numeric-ids --no-perms --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r "${host_dir}/" "${destroot}/" || { log ERROR "rsync falhou"; return 5; }
  else
    # fallback: tar over pipe (preserve basic attrs)
    (cd "${host_dir}" && tar cf - .) | (cd "${destroot}" && tar xf -) || { log ERROR "tar copy falhou"; return 6; }
  fi
  log INFO "Sincronizado para sandbox: ${host_dir} -> ${destroot}"
  return 0
}

_sync_from_sandbox() {
  # $1 -> host_dir (full path), pulls from ${_SANDBOX_SESSION}/root${SANDBOX_WORKDIR}/ back to host_dir
  local host_dir="${1:-}"
  if [[ -z "$host_dir" ]]; then log ERROR "sync_from_sandbox: host_dir vazio"; return 2; fi
  if [[ -z "${_SANDBOX_SESSION:-}" || ! -d "${_SANDBOX_SESSION}/root${SANDBOX_WORKDIR}" ]]; then
    log WARN "sync_from_sandbox: caminho no sandbox não existe; nada a sincronizar"; return 0
  fi
  local srcroot="${_SANDBOX_SESSION}/root${SANDBOX_WORKDIR}"
  mkdir -p "${host_dir}" || { log ERROR "Falha criar ${host_dir}"; return 3; }
  if [[ -n "${RSYNC_BIN}" ]]; then
    "${RSYNC_BIN}" -a --delete --numeric-ids --no-perms --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r "${srcroot}/" "${host_dir}/" || { log WARN "rsync pull falhou"; return 4; }
  else
    (cd "${srcroot}" && tar cf - .) | (cd "${host_dir}" && tar xf -) || { log WARN "tar pull falhou"; return 5; }
  fi
  log INFO "Sincronizado do sandbox: ${srcroot} -> ${host_dir}"
  return 0
}

# -----------------------
# Stage functions
# -----------------------
mf_prepare() {
  log INFO "[PREPARE] Preparando ambiente"
  # ensure build dir
  rm -rf "${BUILD_DIR}" || true
  safe_mkdir "${BUILD_DIR}"
  # find a tarball in cache (simple heuristic)
  local tarball
  tarball=$(find "${CACHE_SOURCES}" -maxdepth 1 -type f -name "${MF_NAME}-*.*" | head -n1 || true)
  if [[ -z "${tarball}" ]]; then
    # try any archive
    tarball=$(find "${CACHE_SOURCES}" -maxdepth 1 -type f | head -n1 || true)
  fi
  [[ -n "${tarball}" && -f "${tarball}" ]] || fail "Tarball não encontrado em ${CACHE_SOURCES}"
  log INFO "Usando tarball: ${tarball}"
  # extract into BUILD_DIR
  tar -xf "${tarball}" -C "${BUILD_DIR}" --strip-components=1 || fail "Falha ao extrair ${tarball}"
  # prepare sandbox workdir: copy sources into sandbox /work
  if [[ "${SANDBOX_USE}" == "true" && $(_sandbox_available); then
    # ensure sandbox session
    if ! sandbox_create >/dev/null 2>&1; then
      fail "Falha ao criar sessão sandbox"
    fi
    sandbox_mount_pseudofs >/dev/null 2>&1 || log WARN "Falha mount pseudo-fs (continuando)"
    # create the destination inside sandbox root
    # note: _SANDBOX_SESSION is internal var from sandbox.sh; assume accessible after sourcing
    if [[ -z "${_SANDBOX_SESSION:-}" ]]; then
      fail "Sandbox session não definida após sandbox_create()"
    fi
    # ensure the /work path exists inside session root
    mkdir -p "${_SANDBOX_SESSION}/root${SANDBOX_WORKDIR}" || fail "Falha criar sandbox workdir"
    # sync sources
    _sync_to_sandbox "${BUILD_DIR}" || fail "Falha ao sincronizar fontes para sandbox"
  else
    log INFO "SANDBOX não usado - operando no host em ${BUILD_DIR}"
  fi
}

mf_configure() {
  log INFO "[CONFIGURE] Configurando build"
  # build env flags exported
  if [[ -n "${MF_ENV_FLAGS:-}" ]]; then
    # shellcheck disable=SC2086
    export ${MF_ENV_FLAGS}
  fi

  # decide where to run
  if [[ "${SANDBOX_USE}" == "true" && $(_sandbox_available) ]]; then
    # inside sandbox: run configure in /work
    local cfg_cmd=""
    cfg_cmd+="if [[ -f ./configure ]]; then ./configure --prefix=/usr; elif [[ -f CMakeLists.txt ]]; then cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr; elif [[ -f meson.build ]]; then meson setup build --prefix=/usr; else echo 'Nenhum sistema de build detectado'; fi"
    sandbox_run "cd ${SANDBOX_WORKDIR} && ${cfg_cmd}" || fail "configure falhou dentro do sandbox"
  else
    # host mode
    (cd "${BUILD_DIR}" && \
      if [[ -f "./configure" ]]; then \
        ./configure --prefix=/usr; \
      elif [[ -f CMakeLists.txt ]]; then \
        cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr; \
      elif [[ -f meson.build ]]; then \
        meson setup build --prefix=/usr; \
      else \
        log WARN "Nenhum sistema de build detectado"; \
      fi) || fail "configure falhou no host"
  fi
}

mf_build() {
  log INFO "[BUILD] Compilando"
  if [[ "${SANDBOX_USE}" == "true" && $(_sandbox_available) ]]; then
    sandbox_run "cd ${SANDBOX_WORKDIR} && if [[ -d build ]]; then cd build; fi && make -j${MF_JOBS}" || fail "make falhou dentro do sandbox"
  else
    (cd "${BUILD_DIR}" && if [[ -d build ]]; then cd build; fi && make -j"${MF_JOBS}") || fail "make falhou no host"
  fi
}

mf_check() {
  log INFO "[CHECK] Executando testes (se aplicável)"
  if [[ "${SANDBOX_USE}" == "true" && $(_sandbox_available) ]]; then
    sandbox_run "cd ${SANDBOX_WORKDIR} && if [[ -d build ]]; then cd build; fi && make -k check" || log WARN "make check falhou dentro do sandbox"
  else
    (cd "${BUILD_DIR}" && if [[ -d build ]]; then cd build; fi && make -k check) || log WARN "make check falhou no host"
  fi
}

mf_install() {
  log INFO "[INSTALL] Instalando"
  if [[ "${SANDBOX_USE}" == "true" && $(_sandbox_available) ]]; then
    sandbox_run "cd ${SANDBOX_WORKDIR} && if [[ -d build ]]; then cd build; fi && make install" || fail "make install falhou dentro do sandbox"
    # optionally sync built artifacts back to host build dir
    _sync_from_sandbox "${BUILD_DIR}" || log WARN "Falha ao sincronizar artefatos do sandbox"
  else
    (cd "${BUILD_DIR}" && if [[ -d build ]]; then cd build; fi && make install) || fail "make install falhou no host"
  fi
}

mf_uninstall() {
  log INFO "[UNINSTALL] Removendo (simples)"
  # Best-effort removal: remove files named after package (conservative)
  if [[ -z "${MF_NAME:-}" ]]; then fail "mf_uninstall: name não definido"; fi
  log WARN "mf_uninstall faz remoção simples; verifique manualmente"
  find /usr -type f -name "${MF_NAME}*" -exec rm -f {} \; || true
}

mf_summary() {
  log INFO "[SUMMARY] ${MF_NAME}-${MF_VERSION} concluído"
  if type hooks_summary >/dev/null 2>&1; then hooks_summary || true; fi
  if [[ "${SANDBOX_USE}" == "true" && $(_sandbox_available) ]]; then
    if [[ "${SANDBOX_PERSIST}" == "false" ]]; then
      sandbox_cleanup || log WARN "Falha ao limpar sandbox"
    else
      log INFO "Sandbox preservado (SANDBOX_PERSIST=true): ${_SANDBOX_SESSION:-<unknown>}"
    fi
  fi
}

# -----------------------
# Runner to call mf_* with pre/post hooks
# -----------------------
mf_run_stage() {
  local stage="$1"
  log DEBUG "Executando etapa: $stage"
  # pre-hook
  if type hooks_run >/dev/null 2>&1; then
    hooks_run "pre-${stage}" "${BUILD_DIR}" "${PKG_DIR}" || { log ERROR "pre-${stage} hook falhou"; return 10; }
  fi
  # call stage
  "mf_${stage}" || { log ERROR "Erro na etapa ${stage}"; return 20; }
  # post-hook (non-fatal)
  if type hooks_run >/dev/null 2>&1; then
    hooks_run "post-${stage}" "${BUILD_DIR}" "${PKG_DIR}" || log WARN "post-${stage} hook falhou"
  fi
  return 0
}

# -----------------------
# Top-level construction flow
# -----------------------
mf_construction() {
  # pre-check: make sure sandbox is created if requested
  if [[ "${SANDBOX_USE}" == "true" && $(_sandbox_available) ]]; then
    log INFO "Sandbox requested; ensuring session"
    sandbox_create || fail "sandbox_create falhou"
    sandbox_mount_pseudofs || log WARN "sandbox_mount_pseudofs falhou"
  else
    log INFO "Construindo sem sandbox (SANDBOX_USE=false ou sandbox não disponível)"
  fi

  mf_run_stage prepare
  mf_run_stage configure
  mf_run_stage build
  mf_run_stage check
  mf_run_stage install
  mf_summary
}

# -----------------------
# Create example metafile
# -----------------------
mf_create() {
  local category="$1"; local name="$2"
  [[ -z "$category" || -z "$name" ]] && fail "Uso: metafile.sh --create <categoria> <nome>"
  local base="${SRC_DIR}/${category}/${name}"
  safe_mkdir "$base"
  local ini="${base}/${name}.ini"
  cat > "$ini" <<EOF
# Exemplo metafile
name=${name}
version=1.0.0
description=Exemplo ${name}
category=${category}
arch=$(uname -m)
urls=https://example.org/\${NAME}-\${VERSION}.tar.xz
sha256sums=
patches=
patchsha256sums=
envflags=CFLAGS="-O2 -pipe"
hooks=${base}/hooks
EOF
  chmod 640 "$ini" || true
  log INFO "Metafile de exemplo criado em: $ini"
}

# -----------------------
# CLI
# -----------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  case "$cmd" in
    --load)
      shift; mf_load "${1:-}" ; exit $? ;;
    --fetch)
      shift; mf_load "${1:-}"; mf_fetch_sources ; exit $? ;;
    --patch)
      shift; mf_load "${1:-}"; mf_apply_patches ; exit $? ;;
    --build)
      shift
      mf_load "${1:-}" 
      mf_fetch_sources
      mf_apply_patches
      mf_construction
      exit $? ;;
    --create)
      shift; mf_create "$@" ; exit $? ;;
    --uninstall)
      shift; mf_load "${1:-}"; mf_uninstall ; exit $? ;;
    --help|-h|"")
      cat <<'EOF'
metafile.sh - gerenciador de receitas com sandbox/hook integration

Uso:
  metafile.sh --build <arquivo.ini>    Baixa (fetch) + patches + build (dentro do sandbox se disponível)
  metafile.sh --fetch <arquivo.ini>    Baixa sources
  metafile.sh --patch <arquivo.ini>    Baixa e aplica patches
  metafile.sh --create <categoria> <nome>  Cria exemplo de metafile
  metafile.sh --uninstall <arquivo.ini>  Remove pacote (simples)
  metafile.sh --help
EOF
      exit 0 ;;
    *)
      fail "Comando inválido. Use --help." ;;
  esac
fi

# Export functions for other scripts
export -f mf_load mf_fetch_sources mf_apply_patches mf_prepare mf_configure mf_build mf_check mf_install mf_uninstall mf_construction mf_create mf_run_stage

# End of file
