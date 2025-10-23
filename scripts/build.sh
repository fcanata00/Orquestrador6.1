#!/usr/bin/env bash
# build.sh - Orquestrador de build, instalação e empacotamento
# - integração com metafile.sh, depende.sh, sandbox.sh, hooks.sh, register.sh
# - DESTDIR + fakeroot, strip, tar.zst packaging, cache, rollback
# - robust error handling, locks, silent/debug modes
#
# Versão: 2025-10-23
set -eEuo pipefail
IFS=$'\n\t'

# -------------------------
# Metadata
# -------------------------
SCRIPT_NAME="build"
SCRIPT_VERSION="1.0.0"

# -------------------------
# Configuráveis via ENV
# -------------------------
: "${CACHE_SOURCES:=/var/cache/sources}"
: "${CACHE_BINARIES:=/var/cache/binaries}"
: "${CACHE_METADATA:=/var/cache/metadata}"
: "${BUILD_LOG_DIR:=/var/log/orquestrador/builds}"
: "${BUILD_LOCK_DIR:=/run/lock/orquestrador}"
: "${DESTDIR_BASE:=/var/tmp/orquestrador/buildroot}"
: "${RSYNC_BIN:=$(command -v rsync || true)}"
: "${ZSTD_BIN:=$(command -v zstd || true)}"
: "${XZ_BIN:=$(command -v xz || true)}"
: "${FAKEROOT_BIN:=$(command -v fakeroot || true)}"
: "${STRIP_BIN:=$(command -v strip || true)}"
: "${MAINTAINER:=orquestrador}"
: "${BUILD_SILENT:=false}"
: "${BUILD_DEBUG:=false}"
: "${BUILD_JOBS:=$(nproc)}"
: "${BUILD_FLOCK_TIMEOUT:=600}"   # seconds to wait for global build lock
: "${PKG_RETENTION_DAYS:=90}"

# -------------------------
# Runtime vars
# -------------------------
BUILD_DIR_DEFAULT="/tmp/build.$$"
BUILD_DIR="${BUILD_DIR:-$BUILD_DIR_DEFAULT}"
DESTDIR=""
MF_FILE=""
MF_NAME=""
MF_VERSION=""
MF_CATEGORY=""
LOGFILE=""
LOCK_FD=""

# -------------------------
# Helpers: logging
# -------------------------
_log() {
  local level="$1"; shift; local msg="$*"
  if type register_info >/dev/null 2>&1; then
    case "$level" in
      INFO)  register_info "$msg";;
      WARN)  register_warn "$msg";;
      ERROR) register_error "$msg";;
      DEBUG) register_debug "$msg";;
      *) register_info "$msg";;
    esac
    return 0
  fi
  if [[ "${BUILD_SILENT}" == "true" && "$level" != "ERROR" ]]; then
    return 0
  fi
  case "$level" in
    INFO)  printf '\e[32m[INFO]\e[0m %s\n' "$msg" ;;
    WARN)  printf '\e[33m[WARN]\e[0m %s\n' "$msg" >&2 ;;
    ERROR) printf '\e[31m[ERROR]\e[0m %s\n' "$msg" >&2 ;;
    DEBUG) [[ "${BUILD_DEBUG}" == "true" ]] && printf '\e[36m[DEBUG]\e[0m %s\n' "$msg" ;;
    *) printf '[LOG] %s\n' "$msg" ;;
  esac
  # also write to logfile if set
  if [[ -n "${LOGFILE:-}" ]]; then
    printf '%s %s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "[$level]" "$msg" >> "${LOGFILE}" 2>/dev/null || true
  fi
}

fail() {
  local code="${2:-1}"
  _log ERROR "$1"
  build_rollback || true
  exit "$code"
}

# -------------------------
# Init directories & files
# -------------------------
_init_dirs() {
  mkdir -p "${CACHE_SOURCES}" "${CACHE_BINARIES}" "${CACHE_METADATA}" "${BUILD_LOG_DIR}" "${BUILD_LOCK_DIR}" "${DESTDIR_BASE}"
  chmod 750 "${CACHE_BINARIES}" "${CACHE_METADATA}" "${BUILD_LOG_DIR}" "${BUILD_LOCK_DIR}" "${DESTDIR_BASE}" 2>/dev/null || true
}

# -------------------------
# Lock (global build lock) to avoid concurrent conflicting installs
# -------------------------
_acquire_global_lock() {
  _init_dirs
  local lockfile="${BUILD_LOCK_DIR}/build.lock"
  exec {LOCK_FD}>"${lockfile}" || fail "Não foi possível abrir lockfile ${lockfile}"
  if flock -n "${LOCK_FD}"; then
    _log DEBUG "Lock global adquirido"
    return 0
  fi
  _log INFO "Aguardando lock global (timeout ${BUILD_FLOCK_TIMEOUT}s)..."
  local waited=0
  while ! flock -n "${LOCK_FD}"; do
    sleep 1
    waited=$((waited+1))
    if (( waited >= BUILD_FLOCK_TIMEOUT )); then
      fail "Timeout aguardando lock global"
    fi
  done
  _log DEBUG "Lock global adquirido após espera ${waited}s"
  return 0
}

_release_global_lock() {
  if [[ -n "${LOCK_FD:-}" ]]; then
    eval "exec ${LOCK_FD}>&-"
    unset LOCK_FD
  fi
}

# -------------------------
# Exported helpers to call other modules
# -------------------------
# try to auto-source modules if present
for mod in metafile depende sandbox hooks register patches uninstall; do
  if ! type "${mod}_init" >/dev/null 2>&1 && [[ -f /usr/bin/${mod}.sh ]]; then
    # shellcheck disable=SC1090
    source /usr/bin/${mod}.sh || _log WARN "Falha ao carregar ${mod}.sh"
  elif ! type "${mod}_init" >/dev/null 2>&1 && [[ -f /mnt/lfs/usr/bin/${mod}.sh ]]; then
    # shellcheck disable=SC1090
    source /mnt/lfs/usr/bin/${mod}.sh || _log WARN "Falha ao carregar ${mod}.sh (LFS)"
  fi
done

# -------------------------
# Utility functions
# -------------------------
_realpath_safe() {
  local p="${1:-.}"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p"
  else
    (cd "$p" 2>/dev/null && pwd -P) || return 1
  fi
}

_safe_mkdir() {
  mkdir -p "$1" 2>/dev/null || fail "Falha ao criar $1"
  chmod 750 "$1" 2>/dev/null || true
}

_rotate_log_if_needed() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local bytes
    bytes=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if (( bytes > 10485760 )); then
      for i in 4 3 2 1; do
        if [[ -f "${f}.${i}" ]]; then mv -f "${f}.${i}" "${f}.$((i+1))" || true; fi
      done
      mv -f "$f" "${f}.1" || true
      : > "$f"
    fi
  fi
}

# -------------------------
# prepare environment for a package (load metafile)
# -------------------------
build_load_metafile() {
  MF_FILE="$1"
  [[ -f "$MF_FILE" ]] || fail "metafile não encontrado: $MF_FILE"
  # use metafile.sh mf_load if available, else parse basic keys
  if type mf_load >/dev/null 2>&1; then
    mf_load "$MF_FILE"
    # expect mf_load to set MF_NAME MF_VERSION MF_CATEGORY etc.
    MF_NAME="${MF_NAME:-${MF_NAME}}"
    MF_VERSION="${MF_VERSION:-${MF_VERSION}}"
    MF_CATEGORY="${MF_CATEGORY:-${MF_CATEGORY:-misc}}"
  else
    # minimal parser
    MF_NAME=$(grep -E '^name=' "$MF_FILE" | head -n1 | cut -d= -f2- | xargs || true)
    MF_VERSION=$(grep -E '^version=' "$MF_FILE" | head -n1 | cut -d= -f2- | xargs || true)
    MF_CATEGORY=$(grep -E '^category=' "$MF_FILE" | head -n1 | cut -d= -f2- | xargs || true)
  fi
  [[ -n "${MF_NAME}" ]] || fail "MF_NAME não detectado no metafile"
  MF_VERSION="${MF_VERSION:-<unknown>}"
  MF_CATEGORY="${MF_CATEGORY:-misc}"
  LOGFILE="${BUILD_LOG_DIR}/${MF_NAME}-${MF_VERSION}.log"
  _rotate_log_if_needed "${LOGFILE}"
  _log INFO "Metafile carregado: ${MF_NAME} ${MF_VERSION} (categoria=${MF_CATEGORY})"
}

# -------------------------
# prepare build dir and DESTDIR
# -------------------------
build_prepare_dirs() {
  BUILD_DIR="${BUILD_DIR:-/tmp/build.$$}"
  rm -rf "${BUILD_DIR}" 2>/dev/null || true
  _safe_mkdir "${BUILD_DIR}"
  DESTDIR="${DESTDIR_BASE}/${MF_NAME}-${MF_VERSION}"
  rm -rf "${DESTDIR}" 2>/dev/null || true
  _safe_mkdir "${DESTDIR}"
  _log DEBUG "BUILD_DIR=${BUILD_DIR} DESTDIR=${DESTDIR}"
}

# -------------------------
# fetch sources (uses mf_fetch_sources if available)
# -------------------------
build_fetch_sources() {
  if type mf_fetch_sources >/dev/null 2>&1; then
    mf_fetch_sources || fail "mf_fetch_sources falhou"
  else
    _log WARN "mf_fetch_sources não disponível; certifique-se de preparar fontes manualmente"
  fi
}

# -------------------------
# apply patches (uses mf_apply_patches or patches.sh)
# -------------------------
build_apply_patches() {
  if type mf_apply_patches >/dev/null 2>&1; then
    mf_apply_patches || _log WARN "mf_apply_patches falhou"
  elif type pt_apply_all >/dev/null 2>&1; then
    pt_apply_all "${MF_NAME}" || _log WARN "pt_apply_all falhou"
  else
    _log DEBUG "Nenhuma ferramenta de patches disponível (skipping)"
  fi
}

# -------------------------
# install inside DESTDIR using fakeroot, supports sandbox_run
# -------------------------
_build_do_install() {
  # $1 = install command to run inside directory (e.g. "make install")
  local install_cmd="$1"
  # ensure DESTDIR exists
  _safe_mkdir "${DESTDIR}"
  if [[ "${SANDBOX_USE:-false}" == "true" && type sandbox_run >/dev/null 2>&1 ]]; then
    # we assume sandbox has the sources synchronized to /work
    local inside_cmd="cd ${SANDBOX_WORKDIR} && ${install_cmd} DESTDIR=${DESTDIR}"
    if [[ -n "${FAKEROOT_BIN}" ]]; then
      inside_cmd="cd ${SANDBOX_WORKDIR} && ${FAKEROOT_BIN} ${install_cmd} DESTDIR=${DESTDIR}"
    fi
    _log INFO "Instalando dentro do sandbox com DESTDIR=${DESTDIR}"
    sandbox_run "${inside_cmd}" || return 1
    return 0
  else
    # host mode
    if [[ -n "${FAKEROOT_BIN}" ]]; then
      _log INFO "Instalando com fakeroot no host (DESTDIR=${DESTDIR})"
      (cd "${BUILD_DIR}" && ${FAKEROOT_BIN} sh -c "${install_cmd} DESTDIR='${DESTDIR}'") || return 1
    else
      _log INFO "Instalando sem fakeroot (precisa de root para instalar no sistema real)"
      (cd "${BUILD_DIR}" && sh -c "${install_cmd} DESTDIR='${DESTDIR}'") || return 1
    fi
    return 0
  fi
}

# -------------------------
# strip ELF binaries under DESTDIR
# -------------------------
pkg_strip_binaries() {
  if [[ -z "${STRIP_BIN}" ]]; then
    _log WARN "strip não disponível; pulando strip de binários"
    return 0
  fi
  _log INFO "Stripando binários ELF em ${DESTDIR}"
  # find ELF files safely
  local failed=0
  while IFS= read -r -d $'\0' bin; do
    # sanity check: file is ELF executable or shared object
    if file "$bin" 2>/dev/null | grep -q 'ELF'; then
      # attempt to strip - ignore non-fatal failures
      if ! "${STRIP_BIN}" --strip-unneeded "$bin" >/dev/null 2>&1; then
        _log WARN "Falha ao stripar $bin (continuando)"
        failed=1
      fi
    fi
  done < <(find "${DESTDIR}" -type f -print0 2>/dev/null || true)
  if (( failed )); then
    _log WARN "Alguns binários não puderam ser stripados"
  else
    _log INFO "Strip concluído"
  fi
}

# -------------------------
# generate metadata for package
# -------------------------
pkg_generate_metadata() {
  local metafile="${CACHE_METADATA}/${MF_NAME}-${MF_VERSION}.meta"
  local pkgfile="${CACHE_BINARIES}/${MF_NAME}-${MF_VERSION}.tar.zst"
  local size=0 sha=""
  if [[ -f "${pkgfile}" ]]; then
    size=$(stat -c%s "${pkgfile}" 2>/dev/null || echo 0)
    sha=$(sha256sum "${pkgfile}" | awk '{print $1}' 2>/dev/null || true)
  fi
  mkdir -p "${CACHE_METADATA}"
  cat > "${metafile}.tmp" <<EOF
NAME=${MF_NAME}
VERSION=${MF_VERSION}
CATEGORY=${MF_CATEGORY}
ARCH=$(uname -m)
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MAINTAINER=${MAINTAINER}
SIZE=${size}
SHA256=${sha}
EOF
  mv -f "${metafile}.tmp" "${metafile}"
  _log INFO "Metadado gerado: ${metafile}"
  echo "${metafile}"
}

# -------------------------
# compress DESTDIR to tar.zst (fallback tar.xz)
# returns path to archive
# -------------------------
pkg_compress() {
  local out_tmp="/var/tmp/${MF_NAME}-${MF_VERSION}.tar"
  local archive_zst="${CACHE_BINARIES}/${MF_NAME}-${MF_VERSION}.tar.zst"
  local archive_xz="${CACHE_BINARIES}/${MF_NAME}-${MF_VERSION}.tar.xz"
  mkdir -p "$(dirname "${archive_zst}")"

  _log INFO "Compactando ${DESTDIR} em tar (temporário)"
  # create a tar in temp dir and pipe to compressor to avoid double-write issues
  if [[ -n "${ZSTD_BIN}" ]]; then
    _log DEBUG "Usando zstd para compressão"
    # use tar -C DESTDIR . | zstd -T0 -19 -o archive
    if tar -C "${DESTDIR}" -cf - . 2>/dev/null | "${ZSTD_BIN}" -19 -T0 -o "${archive_zst}"; then
      _log INFO "Arquivo gerado: ${archive_zst}"
      echo "${archive_zst}"
      return 0
    else
      _log WARN "zstd compress falhou, tentando xz fallback"
    fi
  fi

  if [[ -n "${XZ_BIN}" ]]; then
    if tar -C "${DESTDIR}" -cJf "${archive_xz}" . 2>/dev/null; then
      _log INFO "Arquivo gerado: ${archive_xz}"
      echo "${archive_xz}"
      return 0
    else
      _log ERROR "xz compress falhou também"
      return 1
    fi
  fi

  _log ERROR "Nenhum compressor disponível (zstd ou xz)"
  return 1
}

# -------------------------
# store package in cache atomically and generate metadata
# -------------------------
pkg_cache_store() {
  local archive_path="$1"
  [[ -f "$archive_path" ]] || fail "Arquivo de pacote não encontrado: $archive_path"
  mkdir -p "${CACHE_BINARIES}" "${CACHE_METADATA}"
  local dest="${CACHE_BINARIES}/$(basename "$archive_path")"
  # atomic move
  mv -f "$archive_path" "${dest}" || fail "Falha ao mover pacote para cache"
  _log INFO "Pacote movido para cache: ${dest}"
  pkg_generate_metadata >/dev/null || _log WARN "Falha ao gerar metadados"
  # update index (simple: touch)
  echo "${dest}" >> "${CACHE_METADATA}/index.list" 2>/dev/null || true
  return 0
}

# -------------------------
# check cache: returns path if found and valid sha matches meta
# -------------------------
pkg_cache_check() {
  local name="$1"; local ver="$2"
  local candidate="${CACHE_BINARIES}/${name}-${ver}.tar.zst"
  if [[ -f "${candidate}" ]]; then
    _log INFO "Pacote encontrado no cache: ${candidate}"
    echo "${candidate}"
    return 0
  fi
  candidate="${CACHE_BINARIES}/${name}-${ver}.tar.xz"
  if [[ -f "${candidate}" ]]; then
    _log INFO "Pacote encontrado no cache (xz): ${candidate}"
    echo "${candidate}"
    return 0
  fi
  return 1
}

# -------------------------
# restore from cache (install directly from archive into / using rsync after extract to temp)
# usage: pkg_restore_from_cache <archive> [--dry-run]
# -------------------------
pkg_restore_from_cache() {
  local archive="$1"; local mode="${2:-run}"
  [[ -f "$archive" ]] || fail "Arquivo de cache não existe: $archive"
  local tmp_extract="/var/tmp/orquestrador/extract-$$"
  rm -rf "${tmp_extract}"; mkdir -p "${tmp_extract}"
  _log INFO "Extraindo pacote ${archive} para ${tmp_extract}"
  if [[ "${archive}" == *.zst ]]; then
    if ! tar -I "zstd -d -T0" -xf "${archive}" -C "${tmp_extract}"; then
      rm -rf "${tmp_extract}"; fail "Falha ao extrair ${archive}"
    fi
  else
    if ! tar -xJf "${archive}" -C "${tmp_extract}"; then
      rm -rf "${tmp_extract}"; fail "Falha ao extrair ${archive}"
    fi
  fi
  if [[ "${mode}" == "dry-run" ]]; then
    _log INFO "DRY-RUN: arquivos que seriam copiados:"
    find "${tmp_extract}" -maxdepth 2 -type f | sed "s|${tmp_extract}||"
    rm -rf "${tmp_extract}"
    return 0
  fi
  # perform rsync from tmp_extract to /
  if [[ -n "${RSYNC_BIN}" ]]; then
    _log INFO "Instalando arquivos para / via rsync"
    sudo="${SUDO:-}"
    # require root to sync to / unless using fakeroot to emulate (we prefer actual root for system install)
    if [[ $(id -u) -ne 0 ]] && [[ -z "${FAKEROOT_BIN}" ]]; then
      _log WARN "Não está rodando como root e fakeroot não disponível; rsync para / pode falhar"
    fi
    # Use rsync to copy, preserving perms; we avoid --delete by default
    "${RSYNC_BIN}" -a --numeric-ids --delete "${tmp_extract}/" / || { rm -rf "${tmp_extract}"; fail "rsync falhou"; }
  else
    _log WARN "rsync ausente; usando tar extract direto no local (pode sobrescrever)"
    (cd "${tmp_extract}" && tar cf - .) | (cd / && tar xf -) || { rm -rf "${tmp_extract}"; fail "Instalação direta falhou"; }
  fi
  rm -rf "${tmp_extract}"
  _log INFO "Instalação a partir do cache concluída"
  return 0
}

# -------------------------
# finalize build: mark installed by integrating with depende.sh
# -------------------------
build_finalize() {
  _log INFO "Finalizando build: empacotando e cacheando"
  pkg_strip_binaries || _log WARN "strip warnings"
  # compress
  local archive
  archive=$(pkg_compress) || fail "Falha em empacotar"
  pkg_cache_store "${archive}" || _log WARN "Falha ao armazenar no cache"
  # mark installed in depende
  if type dep_mark_installed >/dev/null 2>&1; then
    dep_mark_installed "${MF_NAME}" "${MF_VERSION}" || _log WARN "dep_mark_installed falhou"
  fi
  _log INFO "Build finalizado para ${MF_NAME}-${MF_VERSION}"
}

# -------------------------
# rollback behavior on error or signal
# -------------------------
build_rollback() {
  local rc=$?
  _log ERROR "[ROLLBACK] Iniciando rollback para ${MF_NAME:-<unknown>}"
  # remove DESTDIR and builddir
  if [[ -n "${DESTDIR:-}" && -d "${DESTDIR}" ]]; then
    rm -rf "${DESTDIR}" || _log WARN "Falha ao remover DESTDIR ${DESTDIR}"
  fi
  if [[ -n "${BUILD_DIR:-}" && -d "${BUILD_DIR}" ]]; then
    rm -rf "${BUILD_DIR}" || _log WARN "Falha ao remover BUILD_DIR ${BUILD_DIR}"
  fi
  # attempt to cleanup sandbox if present
  if type sandbox_cleanup >/dev/null 2>&1; then
    sandbox_cleanup || _log WARN "sandbox_cleanup retornou erro"
  fi
  # unmark installed in depende if partially marked
  if type dep_mark_uninstalled >/dev/null 2>&1 && [[ -n "${MF_NAME:-}" ]]; then
    dep_mark_uninstalled "${MF_NAME}" || true
  fi
  _release_global_lock || true
  return "${rc:-1}"
}

# ensure rollback on ERR and on interrupts
trap 'build_rollback' ERR INT TERM

# -------------------------
# Build stages: prepare/configure/build/check/install
# These will call mf_* when available else fallback behavior
# -------------------------
_stage_prepare() {
  _log INFO "[PREPARE] Preparando ambiente de build"
  build_prepare_dirs
  # extract sources: try to find tarball in cache or use mf_fetch_sources
  build_fetch_sources || _log DEBUG "mf_fetch_sources not provided or failed (continuing if sources prepopulated)"
  # heuristic: find tarball in CACHE_SOURCES matching MF_NAME
  local tarball
  tarball=$(find "${CACHE_SOURCES}" -maxdepth 1 -type f -name "${MF_NAME}-*.tar.*" | head -n1 || true)
  if [[ -n "$tarball" && -f "$tarball" ]]; then
    _log INFO "Extraindo tarball ${tarball} para ${BUILD_DIR}"
    if ! tar -xf "${tarball}" -C "${BUILD_DIR}" --strip-components=1; then
      fail "Falha ao extrair tarball ${tarball}"
    fi
  else
    _log INFO "Tarball não encontrado em cache; esperando que mf_fetch_sources já populou ${BUILD_DIR}"
  fi

  # sync to sandbox workdir if sandbox is used
  if [[ "${SANDBOX_USE:-false}" == "true" && type sandbox_create >/dev/null 2>&1 ]]; then
    sandbox_create || fail "sandbox_create falhou"
    sandbox_mount_pseudofs || _log WARN "sandbox_mount_pseudofs falhou"
    # ensure workdir inside sandbox root
    if [[ -z "${_SANDBOX_SESSION:-}" ]]; then
      fail "Sandbox session não definida"
    fi
    mkdir -p "${_SANDBOX_SESSION}/root${SANDBOX_WORKDIR}" || fail "Falha ao criar sandbox workdir"
    # sync build dir to sandbox
    if [[ -n "${RSYNC_BIN}" ]]; then
      "${RSYNC_BIN}" -a --delete --numeric-ids --no-perms --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r "${BUILD_DIR}/" "${_SANDBOX_SESSION}/root${SANDBOX_WORKDIR}/" || fail "rsync para sandbox falhou"
    else
      (cd "${BUILD_DIR}" && tar cf - .) | (cd "${_SANDBOX_SESSION}/root${SANDBOX_WORKDIR}" && tar xf -) || fail "tar copy para sandbox falhou"
    fi
    _log INFO "Fontes sincronizadas para sandbox ${_SANDBOX_SESSION}/root${SANDBOX_WORKDIR}"
  fi

  build_apply_patches || _log WARN "patches aplicados com advertências"
  return 0
}

_stage_configure() {
  _log INFO "[CONFIGURE] Detectando sistema de build e executando configure"
  if type mf_configure >/dev/null 2>&1; then
    mf_configure || fail "mf_configure falhou"
  else
    # fallback: autodetect common build systems
    if [[ -f "${BUILD_DIR}/configure" ]]; then
      if [[ "${SANDBOX_USE:-false}" == "true" && type sandbox_run >/dev/null 2>&1 ]]; then
        sandbox_run "cd ${SANDBOX_WORKDIR} && ./configure --prefix=/usr" || fail "configure falhou no sandbox"
      else
        (cd "${BUILD_DIR}" && ./configure --prefix=/usr) || fail "configure falhou"
      fi
    elif [[ -f "${BUILD_DIR}/CMakeLists.txt" ]]; then
      if [[ "${SANDBOX_USE:-false}" == "true" && type sandbox_run >/dev/null 2>&1 ]]; then
        sandbox_run "cd ${SANDBOX_WORKDIR} && cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr" || fail "cmake falhou no sandbox"
      else
        (cd "${BUILD_DIR}" && cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr) || fail "cmake falhou"
      fi
    elif [[ -f "${BUILD_DIR}/meson.build" ]]; then
      if [[ "${SANDBOX_USE:-false}" == "true" && type sandbox_run >/dev/null 2>&1 ]]; then
        sandbox_run "cd ${SANDBOX_WORKDIR} && meson setup build --prefix=/usr" || fail "meson setup falhou no sandbox"
      else
        (cd "${BUILD_DIR}" && meson setup build --prefix=/usr) || fail "meson setup falhou"
      fi
    else
      _log INFO "Nenhum sistema de build detectado; pulando configure"
    fi
  fi
}

_stage_build() {
  _log INFO "[BUILD] Construindo (make/ninja/cargo/etc.)"
  if type mf_build >/dev/null 2>&1; then
    mf_build || fail "mf_build falhou"
  else
    # generic fallback: try make in build dir
    if [[ "${SANDBOX_USE:-false}" == "true" && type sandbox_run >/dev/null 2>&1 ]]; then
      sandbox_run "cd ${SANDBOX_WORKDIR} && if [[ -d build ]]; then cd build; fi && make -j${BUILD_JOBS}" || fail "make falhou no sandbox"
    else
      (cd "${BUILD_DIR}" && if [[ -d build ]]; then cd build; fi && make -j"${BUILD_JOBS}") || fail "make falhou"
    fi
  fi
}

_stage_check() {
  _log INFO "[CHECK] Executando testes (make check) - não-fatal"
  if type mf_check >/dev/null 2>&1; then
    mf_check || _log WARN "mf_check falhou"
  else
    if [[ "${SANDBOX_USE:-false}" == "true" && type sandbox_run >/dev/null 2>&1 ]]; then
      sandbox_run "cd ${SANDBOX_WORKDIR} && if [[ -d build ]]; then cd build; fi && make -k check" || _log WARN "make check falhou no sandbox"
    else
      (cd "${BUILD_DIR}" && if [[ -d build ]]; then cd build; fi && make -k check) || _log WARN "make check falhou"
    fi
  fi
}

_stage_install() {
  _log INFO "[INSTALL] Instalando para DESTDIR com fakeroot"
  if type mf_install >/dev/null 2>&1; then
    mf_install || fail "mf_install falhou"
  else
    # default install command
    _build_do_install "make install" || fail "make install falhou"
  fi
}

# -------------------------
# High level build orchestration
# -------------------------
build_run_flow() {
  _acquire_global_lock
  # resolve deps if depende available
  if type dep_auto_build >/dev/null 2>&1; then
    _log INFO "Resolvendo dependências e construindo-as automaticamente (dep_auto_build)"
    dep_auto_build "${MF_NAME}" || _log WARN "dep_auto_build retornou não-zero (continuando)"
  fi

  # run stages
  _stage_prepare
  _stage_configure
  _stage_build
  _stage_check
  _stage_install

  # post-install hooks
  if type hooks_run >/dev/null 2>&1; then
    hooks_run "post-install" "${BUILD_DIR}" "${PKG_DIR:-}" || _log WARN "post-install hooks falharam"
  fi

  # finalize (strip, compress, cache, mark installed)
  build_finalize

  # cleanup resources
  if [[ "${SANDBOX_USE:-false}" == "true" && type sandbox_cleanup >/dev/null 2>&1 ]]; then
    sandbox_cleanup || _log WARN "sandbox_cleanup falhou"
  fi

  _release_global_lock
  _log INFO "Build flow concluído para ${MF_NAME}-${MF_VERSION}"
}

# -------------------------
# Packaging utilities for directory or cache
# -------------------------
# pack a directory into cache: usage pack_from_dir <dir> [name] [version]
pack_from_dir() {
  local src_dir="$1"; local name="${2:-${MF_NAME:-auto}}"; local ver="${3:-${MF_VERSION:-1.0}}"
  [[ -d "$src_dir" ]] || fail "Diretório fonte inválido: $src_dir"
  # create temporary DESTDIR-like staging
  local tmpdest="/var/tmp/orquestrador/pack-$$"
  rm -rf "$tmpdest"; mkdir -p "$tmpdest"
  _log INFO "Copiando $src_dir para staging $tmpdest"
  if [[ -n "${RSYNC_BIN}" ]]; then
    "${RSYNC_BIN}" -a --delete --numeric-ids --no-perms --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r "${src_dir}/" "${tmpdest}/" || fail "rsync falhou"
  else
    (cd "$src_dir" && tar cf - .) | (cd "$tmpdest" && tar xf -) || fail "tar copy falhou"
  fi
  # strip
  DESTDIR="$tmpdest" pkg_strip_binaries || _log WARN "strip falhou no pack_from_dir"
  # compress
  MF_NAME="$name"; MF_VERSION="$ver"
  local archive
  archive=$(pkg_compress) || fail "pkg_compress falhou"
  pkg_cache_store "${archive}" || fail "Falha ao mover pacote para cache"
  rm -rf "$tmpdest"
  _log INFO "Pack from dir concluído: ${archive}"
}

# install from a directory (staging)
install_from_dir() {
  local src_dir="$1"
  [[ -d "$src_dir" ]] || fail "Diretório inválido: $src_dir"
  if [[ -n "${RSYNC_BIN}" ]]; then
    _log INFO "Instalando de ${src_dir} para / via rsync"
    "${RSYNC_BIN}" -a --numeric-ids --delete "${src_dir}/" / || fail "rsync install falhou"
  else
    (cd "$src_dir" && tar cf - .) | (cd / && tar xf -) || fail "Instalação direta falhou"
  fi
  _log INFO "Instalação de diretório concluída"
}

# install from cache (archive)
install_from_cache() {
  local name="$1"; local ver="$2"
  local archive
  archive=$(pkg_cache_check "$name" "$ver" || true)
  if [[ -z "$archive" ]]; then
    fail "Pacote não encontrado no cache: ${name}-${ver}"
  fi
  pkg_restore_from_cache "$archive" || fail "Instalação a partir do cache falhou"
}

# -------------------------
# Clean old cached packages
# -------------------------
pkg_cleanup_old() {
  _log INFO "Limpando pacotes no cache com mais de ${PKG_RETENTION_DAYS} dias"
  find "${CACHE_BINARIES}" -type f -mtime +"${PKG_RETENTION_DAYS}" -print0 | xargs -0 -r rm -f || true
  find "${CACHE_METADATA}" -type f -mtime +"${PKG_RETENTION_DAYS}" -print0 | xargs -0 -r rm -f || true
}

# -------------------------
# CLI
# -------------------------
_print_usage() {
  cat <<EOF
build.sh - constrói pacotes, instala em DESTDIR com fakeroot, empacota e cacheia

Uso:
  build.sh --metafile <arquivo.ini>      : constrói pacote a partir de metafile
  build.sh --from-dir <dir> [name ver]   : empacota diretório em cache (tar.zst) e gera meta
  build.sh --install-dir <dir>           : instala diretório diretamente para /
  build.sh --install-cache <name> <ver>  : instala pacote do cache
  build.sh --pack <dir> [name ver]       : alias para --from-dir
  build.sh --cleanup-cache               : limpa pacotes antigos do cache
  build.sh --help                        : mostra ajuda

Opções debug/silent (env):
  BUILD_DEBUG=true    - ativa logs debug
  BUILD_SILENT=true   - suprime INFO/WARN (apenas ERROR é mostrado)
EOF
}

# -------------------------
# Main dispatcher
# -------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if (( $# == 0 )); then _print_usage; exit 0; fi
  cmd="$1"; shift
  case "$cmd" in
    --metafile)
      MF_FILE="$1"; shift || fail "--metafile requer um arquivo"
      build_load_metafile "${MF_FILE}"
      build_prepare_dirs
      _acquire_global_lock
      build_run_flow
      _release_global_lock
      exit 0
      ;;
    --from-dir|--pack)
      src="$1"; name="${2:-}"; ver="${3:-}"
      pack_from_dir "$src" "$name" "$ver"
      exit $?
      ;;
    --install-dir)
      src="$1"
      install_from_dir "$src"
      exit $?
      ;;
    --install-cache)
      name="$1"; ver="$2"
      install_from_cache "$name" "$ver"
      exit $?
      ;;
    --cleanup-cache)
      pkg_cleanup_old
      exit 0
      ;;
    --help|-h)
      _print_usage; exit 0
      ;;
    *)
      _log ERROR "Comando inválido: $cmd"
      _print_usage
      exit 2
      ;;
  esac
fi

# -------------------------
# Export key functions
# -------------------------
export -f build_load_metafile build_prepare_dirs build_fetch_sources build_apply_patches \
  _stage_prepare _stage_configure _stage_build _stage_check _stage_install build_run_flow \
  pkg_strip_binaries pkg_compress pkg_cache_store pkg_cache_check pkg_restore_from_cache \
  pack_from_dir install_from_dir install_from_cache pkg_cleanup_old
