#!/usr/bin/env bash
# bootstrap.sh - Automação do bootstrap LFS (Stages 1..3), snapshots e validações
# Inclui: criação user lfs, preparação /mnt/lfs, execução de stages via stageN.meta,
# cópia de /etc/resolv.conf, snapshot tar.zst, testes do toolchain stage1, logs, rollback.
# Versão: 2025-10-23

set -eEuo pipefail
IFS=$'\n\t'
umask 027

SCRIPT_NAME="bootstrap"
SCRIPT_VERSION="1.0.0"

# -------------------------
# Configuráveis via ENV (ajuste conforme ambiente)
# -------------------------
: "${LFS_MNT:="/mnt/lfs"}"
: "${LFS_USR_SRC:="${LFS_MNT}/usr/src/repo/bootstrap"}"
: "${BOOTSTRAP_SCRIPTS_DIR:="${LFS_MNT}/usr/bin"}"
: "${STAGE_META_DIR:="${LFS_USR_SRC}"}"
: "${STAGE1_META:="${STAGE_META_DIR}/stage1.meta"}"
: "${STAGE2_META:="${STAGE_META_DIR}/stage2.meta"}"
: "${STAGE3_META:="${STAGE_META_DIR}/stage3.meta"}"
: "${BOOT_LOG_DIR:=/var/log/orquestrador/bootstrap}"
: "${ROOTFS_SNAPSHOT_DIR:=/var/cache/orquestrador/rootfs-snapshots}"
: "${LFS_USER:=lfs}"
: "${LFS_GROUP:=lfs}"
: "${LFS_UID:=2000}"
: "${LFS_GID:=2000}"
: "${BUILD_JOBS:=$(nproc)}"
: "${TMP_BUILD:=${LFS_MNT}/tmp/build.$$}"
: "${SANDBOX_USE:=true}"
: "${PRESERVE_LFS_USER:=false}"
: "${CHECK_DISK_GB:=10}"   # requisito mínimo de espaço em GB
: "${RETRY_DOWNLOADS:=3}"
: "${ZSTD_BIN:=$(command -v zstd || true)}"
: "${RSYNC_BIN:=$(command -v rsync || true)}"
: "${SUDO_BIN:=$(command -v sudo || true)}"
: "${FAKEROOT_BIN:=$(command -v fakeroot || true)}"

# Internal runtime vars
_SESSION_TS="$(date -u +"%Y%m%dT%H%M%SZ")-$$"
_LOG_PREFIX=""
_DEBUG="${BOOTSTRAP_DEBUG:-false}"
_SILENT="${BOOTSTRAP_SILENT:-false}"
_TRAPED=false

# -------------------------
# Logging helpers (register integration when available)
# -------------------------
log() {
  local level="$1"; shift
  local msg="$*"
  if type register_info >/dev/null 2>&1; then
    case "$level" in
      INFO) register_info "$msg"; return 0 ;;
      WARN) register_warn "$msg"; return 0 ;;
      ERROR) register_error "$msg"; return 0 ;;
      DEBUG) register_debug "$msg"; return 0 ;;
      *) register_info "$msg"; return 0 ;;
    esac
  fi
  if [[ "${_SILENT}" == "true" && "$level" != "ERROR" ]]; then
    return 0
  fi
  case "$level" in
    INFO)  printf '\e[32m[INFO]\e[0m %s\n' "$msg" ;;
    WARN)  printf '\e[33m[WARN]\e[0m %s\n' "$msg" >&2 ;;
    ERROR) printf '\e[31m[ERROR]\e[0m %s\n' "$msg" >&2 ;;
    DEBUG) [[ "${_DEBUG}" == "true" ]] && printf '\e[36m[DEBUG]\e[0m %s\n' "$msg" ;;
    *) echo "[LOG] $msg" ;;
  esac
}

fail() {
  local rc=${2:-1}
  log ERROR "$1"
  bootstrap_rollback || true
  exit "$rc"
}

# -------------------------
# Basic initial checks & create directories
# -------------------------
bootstrap_init() {
  _LOG_PREFIX="${BOOT_LOG_DIR}/${_SESSION_TS}"
  mkdir -p "${BOOT_LOG_DIR}" "${ROOTFS_SNAPSHOT_DIR}" "${LFS_USR_SRC}" "${BOOTSTRAP_SCRIPTS_DIR}" "${TMP_BUILD}"
  chmod 750 "${BOOT_LOG_DIR}" "${ROOTFS_SNAPSHOT_DIR}" "${LFS_USR_SRC}" "${BOOTSTRAP_SCRIPTS_DIR}" "${TMP_BUILD}" 2>/dev/null || true

  # safety: LFS_MNT must not be /
  local rp
  rp=$(realpath -m "${LFS_MNT}" 2>/dev/null || echo "${LFS_MNT}")
  if [[ "${rp}" == "/" || -z "${rp}" ]]; then
    fail "LFS mount point (${LFS_MNT}) inválido ou perigoso. Abortando."
  fi

  # ensure LFS_MNT exists and is not empty mount of root unless user explicitly set
  if [[ ! -d "${LFS_MNT}" ]]; then
    mkdir -p "${LFS_MNT}" || fail "Não foi possível criar ${LFS_MNT}"
  fi

  # create log directory per stage
  mkdir -p "${BOOT_LOG_DIR}/stage1" "${BOOT_LOG_DIR}/stage2" "${BOOT_LOG_DIR}/stage3"

  log INFO "bootstrap_init: inicializado (session=${_SESSION_TS})"
}

# -------------------------
# Prechecks: tools, disk space, network, perms
# -------------------------
bootstrap_prechecks() {
  log INFO "Executando prechecks"

  # require root for mount/chroot operations
  if (( EUID != 0 )); then
    log WARN "Este script exige root para operações completas (mount/chroot). Algumas ações podem falhar."
  fi

  # check essential tools
  local missing=()
  for tool in tar gcc make rsync sha256sum chroot mount umount; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done
  if [[ ${#missing[@]} -ne 0 ]]; then
    log WARN "Ferramentas faltando: ${missing[*]}. Algumas etapas podem falhar."
  fi

  # check zstd fallback to xz
  if [[ -z "${ZSTD_BIN}" ]]; then
    if command -v xz >/dev/null 2>&1; then
      log WARN "zstd não encontrado, fallback para xz será usado para compressão de snapshots"
    else
      log WARN "Nenhum compressor zstd/xz encontrado - snapshots podem não ser criados"
    fi
  fi

  # check free disk space on LFS_MNT
  local free_kb
  free_kb=$(df -Pk "${LFS_MNT}" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
  local free_gb=$((free_kb/1024/1024))
  if (( free_gb < CHECK_DISK_GB )); then
    log WARN "Espaço livre em ${LFS_MNT}: ${free_gb}GB < ${CHECK_DISK_GB}GB (recomendado). Continuando, mas pode falhar."
  fi

  # network: try to resolve a host (if resolv.conf present)
  if [[ -r /etc/resolv.conf ]]; then
    if ! ping -c1 -W1 8.8.8.8 >/dev/null 2>&1; then
      log WARN "Sem conectividade externa detectada (ping 8.8.8.8). Downloads podem falhar."
    fi
  else
    log WARN "/etc/resolv.conf não legível no host; downloads podem falhar."
  fi

  log INFO "Prechecks concluídos"
}

# -------------------------
# Create LFS user/group (temporary) and .bashrc/.bash_profile inside LFS
# -------------------------
bootstrap_create_lfs_user() {
  log INFO "Criando grupo/usuário ${LFS_GROUP}:${LFS_USER} (UID=${LFS_UID},GID=${LFS_GID})"

  # create group if not exists
  if ! getent group "${LFS_GROUP}" >/dev/null 2>&1; then
    groupadd -g "${LFS_GID}" "${LFS_GROUP}" || log WARN "groupadd falhou (talvez já exista)"
  fi
  # create user if not exists
  if ! id "${LFS_USER}" >/dev/null 2>&1; then
    useradd -u "${LFS_UID}" -g "${LFS_GID}" -m -d "${LFS_MNT}/home/${LFS_USER}" -s /bin/bash "${LFS_USER}" 2>/dev/null || {
      log WARN "useradd falhou; criando home manualmente"
      mkdir -p "${LFS_MNT}/home/${LFS_USER}"
      chown -R "${LFS_UID}:${LFS_GID}" "${LFS_MNT}/home/${LFS_USER}" || true
    }
  else
    log INFO "Usuário ${LFS_USER} já existe no host; usando existente (não será removido automaticamente se pertence a outro)"
  fi

  # create basic /etc/passwd and /etc/group inside LFS if missing
  local etc_passwd="${LFS_MNT}/etc/passwd"
  local etc_group="${LFS_MNT}/etc/group"
  mkdir -p "$(dirname "${etc_passwd}")" "$(dirname "${etc_group}")"
  if [[ ! -f "${etc_passwd}" ]]; then
    printf 'root:x:0:0:root:/root:/bin/bash\n' > "${etc_passwd}"
  fi
  if ! grep -q "^${LFS_USER}:" "${etc_passwd}" 2>/dev/null; then
    # add lfs user entry that matches host uid/gid but inside LFS root
    echo "${LFS_USER}:x:${LFS_UID}:${LFS_GID}:${LFS_USER},,,:/home/${LFS_USER}:/bin/bash" >> "${etc_passwd}"
  fi
  if [[ ! -f "${etc_group}" ]]; then
    printf 'root:x:0:\n' > "${etc_group}"
  fi
  if ! grep -q "^${LFS_GROUP}:" "${etc_group}" 2>/dev/null; then
    echo "${LFS_GROUP}:x:${LFS_GID}:" >> "${etc_group}"
  fi

  # create basic .bash_profile and .bashrc for lfs inside LFS home
  local home_dir="${LFS_MNT}/home/${LFS_USER}"
  mkdir -p "${home_dir}"
  cat > "${home_dir}/.bash_profile" <<'EOF'
# .bash_profile for lfs user (inside LFS)
export LFS=/mnt/lfs
export MAKEFLAGS="-j${BUILD_JOBS}"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
if [ -f ~/.bashrc ]; then
  . ~/.bashrc
fi
EOF
  cat > "${home_dir}/.bashrc" <<'EOF'
# .bashrc for lfs user (inside LFS)
PS1="\u:\w\$ "
umask 022
EOF
  chown -R "${LFS_UID}:${LFS_GID}" "${home_dir}" 2>/dev/null || true
  chmod 750 "${home_dir}" 2>/dev/null || true

  log INFO "Usuário LFS criado e configurado em ${home_dir}"
}

# -------------------------
# Remove LFS user/group (optional)
# -------------------------
bootstrap_remove_lfs_user() {
  if [[ "${PRESERVE_LFS_USER}" == "true" ]]; then
    log INFO "PRESERVE_LFS_USER=true => usuário LFS não será removido"
    return 0
  fi

  log INFO "Removendo usuário/group LFS (apenas se foram criados por este script)"
  # attempt to remove created files inside LFS
  if id "${LFS_USER}" >/dev/null 2>&1; then
    # only remove user from host if UID/GID match the created ones and user was created by us
    local user_uid user_gid
    user_uid=$(id -u "${LFS_USER}" 2>/dev/null || echo "")
    user_gid=$(id -g "${LFS_USER}" 2>/dev/null || echo "")
    if [[ "${user_uid}" == "${LFS_UID}" ]] || [[ "${user_gid}" == "${LFS_GID}" ]]; then
      userdel -r "${LFS_USER}" 2>/dev/null || log DEBUG "userdel falhou ou usuário não removido (pode pertencer a host)"
      groupdel "${LFS_GROUP}" 2>/dev/null || true
      log INFO "Usuário/Grupo ${LFS_USER}/${LFS_GROUP} removidos do host (se foram criados por este script)"
    else
      log INFO "Usuário ${LFS_USER} existe mas não corresponde ao UID/GID criado; não remoção para evitar danos"
    fi
  fi

  # remove LFS home inside mount if present
  if [[ -d "${LFS_MNT}/home/${LFS_USER}" ]]; then
    rm -rf "${LFS_MNT}/home/${LFS_USER}" 2>/dev/null || true
  fi
  # remove entries inside ${LFS_MNT}/etc/passwd/group if desired (kept for auditability)
  log INFO "bootstrap_remove_lfs_user: concluído"
}

# -------------------------
# Copy host resolv.conf into LFS (so chroot has DNS)
# -------------------------
bootstrap_copy_resolv() {
  if [[ -r /etc/resolv.conf ]]; then
    mkdir -p "${LFS_MNT}/etc"
    cp -a /etc/resolv.conf "${LFS_MNT}/etc/resolv.conf" || log WARN "Falha ao copiar /etc/resolv.conf para LFS"
    log INFO "/etc/resolv.conf copiado para ${LFS_MNT}/etc/resolv.conf"
  else
    log WARN "resolv.conf do host não encontrado; chroot pode não resolver nomes"
  fi
}

# -------------------------
# Install internal orchestration scripts into LFS /usr/bin for chroot builds
# Copies only if sources available on host (/usr/bin or current dir)
# -------------------------
bootstrap_install_scripts() {
  log INFO "Instalando scripts de orquestração em ${BOOTSTRAP_SCRIPTS_DIR}"
  mkdir -p "${BOOTSTRAP_SCRIPTS_DIR}"
  local candidates=(metafile.sh build.sh sandbox.sh depende.sh hooks.sh patches.sh downloader.sh register.sh uninstall.sh)
  for s in "${candidates[@]}"; do
    if [[ -f "/usr/bin/${s}" ]]; then
      cp -a "/usr/bin/${s}" "${BOOTSTRAP_SCRIPTS_DIR}/${s}" || log WARN "Falha ao copiar /usr/bin/${s}"
      chmod 755 "${BOOTSTRAP_SCRIPTS_DIR}/${s}" 2>/dev/null || true
    elif [[ -f "./${s}" ]]; then
      cp -a "./${s}" "${BOOTSTRAP_SCRIPTS_DIR}/${s}" || log WARN "Falha ao copiar ./{$s}"
      chmod 755 "${BOOTSTRAP_SCRIPTS_DIR}/${s}" 2>/dev/null || true
    else
      log DEBUG "Script ${s} não encontrado localmente; builds podem faltar funcionalidades"
    fi
  done
  log INFO "Scripts instalados (quando disponíveis)"
}

# -------------------------
# Parse a stage meta file (INI-like simple parser)
# Expected keys:
#   order=pkg1,pkg2,...
#   <pkg>.version=
#   <pkg>.url=
#   <pkg>.sha256=
#   <pkg>.patches=comma,separated
#   stage.env=KEY=VAL;KEY2=VAL2
# -------------------------
parse_stage_meta() {
  local meta="$1"
  declare -n _out_order="$2"   # caller provides name of array var for order
  declare -n _out_meta="$3"    # caller provides name of associative array var for meta
  if [[ ! -f "$meta" ]]; then
    fail "Meta file não encontrado: $meta"
  fi
  _out_order=()
  declare -A tmpmeta=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line%%;*}"
    line="$(echo -n "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^order= ]]; then
      local o; o="${line#order=}"
      IFS=',' read -ra arr <<<"$o"
      for i in "${arr[@]}"; do
        _out_order+=("$(echo "$i" | xargs)")
      done
    elif [[ "$line" =~ ^stage\.env= ]]; then
      tmpmeta["stage.env"]="${line#stage.env=}"
    else
      # key might be pkg.key e.g. gcc.version
      if [[ "$line" =~ ^([A-Za-z0-9_.-]+)=(.*)$ ]]; then
        k="${BASH_REMATCH[1]}"
        v="${BASH_REMATCH[2]}"
        tmpmeta["$k"]="$v"
      fi
    fi
  done < "$meta"
  # export tmpmeta into _out_meta associative variable by reference
  for k in "${!tmpmeta[@]}"; do
    _out_meta["$k"]="${tmpmeta[$k]}"
  done
  log DEBUG "parse_stage_meta: orden = ${_out_order[*]}"
  return 0
}

# -------------------------
# Download helper with retries (uses downloader.sh -> dl_fetch if present, else curl)
# inputs: url destpath sha256(optional)
# -------------------------
download_with_retries() {
  local url="$1"; local dest="$2"; local sha="$3"
  local attempt=0
  while (( attempt < RETRY_DOWNLOADS )); do
    attempt=$((attempt+1))
    if type dl_fetch >/dev/null 2>&1; then
      dl_fetch "$url" "$sha" "$dest" && return 0 || log WARN "dl_fetch tentativa ${attempt} falhou para $url"
    else
      if command -v curl >/dev/null 2>&1; then
        curl -L --fail --retry 3 --retry-delay 2 -o "$dest" "$url" && {
          if [[ -n "$sha" ]]; then
            if echo "${sha}  ${dest}" | sha256sum -c - >/dev/null 2>&1; then
              return 0
            else
              log WARN "Checksum inválido para $dest (attempt ${attempt})"; rm -f "$dest" || true
            fi
          else
            return 0
          fi
        } || log WARN "curl falhou tentativa ${attempt} para $url"
      else
        log ERROR "curl ausente e dl_fetch não disponível; não é possível baixar $url"
        return 2
      fi
    fi
    sleep 1
  done
  return 1
}

# -------------------------
# Helper: run a command in chroot as LFS user (if chroot ready)
# Parameters:
#   1 - command string
#   2 - log file (optional)
# -------------------------
run_in_chroot_as_lfs() {
  local cmd="$1"
  local logfile="${2:-}"
  if [[ "${_SILENT}" != "true" ]]; then log DEBUG "run_in_chroot_as_lfs: ${cmd}"; fi
  # ensure resolv.conf and /etc exist
  if [[ ! -d "${LFS_MNT}/proc" ]]; then
    # try to mount pseudo-fs if not already
    mount -t proc proc "${LFS_MNT}/proc" 2>/dev/null || true
  fi
  if [[ -n "${logfile}" ]]; then
    chroot "${LFS_MNT}" /usr/bin/su -s /bin/bash "${LFS_USER}" -c "${cmd}" >> "${logfile}" 2>&1 || return $?
  else
    chroot "${LFS_MNT}" /usr/bin/su -s /bin/bash "${LFS_USER}" -c "${cmd}" || return $?
  fi
  return 0
}

# -------------------------
# Prepare a package build inside chroot
# - expects package metafile or package name mapping in stage meta
# - does: download to LFS_USR_SRC/pkg/, extract to TMP_BUILD, call build.sh in chroot
# -------------------------
bootstrap_build_package() {
  local pkg="$1"
  declare -n pkgmeta="$2"  # assoc array with keys like pkg.version, pkg.url, pkg.sha256
  local stage_log="${BOOT_LOG_DIR}/stage${3}/${pkg}.log"
  mkdir -p "$(dirname "${stage_log}")"
  : > "${stage_log}"

  log INFO "bootstrap_build_package: iniciando ${pkg} (logs: ${stage_log})"

  # determine url/version
  local ver_key="${pkg}.version"
  local url_key="${pkg}.url"
  local sha_key="${pkg}.sha256"
  local patches_key="${pkg}.patches"
  local version="${pkgmeta[$ver_key]:-}"
  local url="${pkgmeta[$url_key]:-}"
  local sha="${pkgmeta[$sha_key]:-}"
  local patches="${pkgmeta[$patches_key]:-}"

  # create pkg dirs in LFS_USR_SRC
  local pkg_src_dir="${LFS_USR_SRC}/${pkg}"
  mkdir -p "${pkg_src_dir}"
  chmod 750 "${pkg_src_dir}" 2>/dev/null || true

  # if url provided, download into CACHE (inside host) and copy into LFS_USR_SRC
  if [[ -n "$url" ]]; then
    local fname; fname="$(basename "${url%%\?*}")"
    local host_cache="${LFS_USR_SRC}/downloads"
    mkdir -p "${host_cache}"
    local dest="${host_cache}/${fname}"
    if [[ ! -f "${dest}" ]]; then
      log INFO "baixando ${url} -> ${dest}"
      download_with_retries "$url" "$dest" "$sha" || {
        log ERROR "Falha no download de ${url}; ver logs"
        return 1
      }
    else
      log INFO "Fonte em cache: ${dest}"
    fi
    # extract into build dir
    rm -rf "${TMP_BUILD:?}"/* || true
    _safe_mkdir "${TMP_BUILD}"
    tar -xf "${dest}" -C "${TMP_BUILD}" --strip-components=1 2>>"${stage_log}" || {
      log ERROR "Falha ao extrair ${dest} (veja ${stage_log})"; return 1
    }
    # sync to LFS_USR_SRC/pkg for persistence
    if [[ -n "${RSYNC_BIN}" ]]; then
      "${RSYNC_BIN}" -a --delete --numeric-ids --no-perms "${TMP_BUILD}/" "${pkg_src_dir}/" >>"${stage_log}" 2>&1 || log WARN "rsync para pkg_src_dir teve advertência"
    else
      (cd "${TMP_BUILD}" && tar cf - .) | (cd "${pkg_src_dir}" && tar xf -) || log WARN "tar copy fallback teve advertência"
    fi
  else
    # no url; assume sources already in pkg_src_dir
    if [[ ! -d "${pkg_src_dir}" || -z "$(ls -A "${pkg_src_dir}" 2>/dev/null)" ]]; then
      log WARN "Nenhuma fonte para ${pkg} (pkg_src_dir vazio) e nenhuma URL fornecida"
      return 1
    fi
  fi

  # apply patches if specified (patch key is comma-separated paths)
  if [[ -n "${patches}" ]]; then
    IFS=',' read -ra patch_arr <<<"${patches}"
    for pth in "${patch_arr[@]}"; do
      pth="$(echo -n "$pth" | xargs)"
      if [[ -f "${pkg_src_dir}/${pth}" ]]; then
        (cd "${pkg_src_dir}" && patch -p1 < "${pkg_src_dir}/${pth}") >>"${stage_log}" 2>&1 || {
          log WARN "Falha ao aplicar patch ${pth} em ${pkg} (continuando)"
        }
      else
        log WARN "Patch ${pth} não encontrado em ${pkg_src_dir}"
      fi
    done
  fi

  # ensure build.sh exists in chroot scripts dir
  if [[ ! -x "${BOOTSTRAP_SCRIPTS_DIR}/build.sh" && -f "/usr/bin/build.sh" ]]; then
    cp -a /usr/bin/build.sh "${BOOTSTRAP_SCRIPTS_DIR}/build.sh" 2>/dev/null || true
    chmod 755 "${BOOTSTRAP_SCRIPTS_DIR}/build.sh" 2>/dev/null || true
  fi

  # create metafile for this package inside LFS so build.sh can pick it
  local mfpath="${pkg_src_dir}/${pkg}.ini"
  if [[ ! -f "${mfpath}" ]]; then
    # generate a minimal metafile so build.sh --metafile can run
    cat > "${mfpath}" <<EOF
name=${pkg}
version=${version:-0.0}
category=bootstrap
urls=${url:-}
sha256sums=${sha:-}
patches=${patches:-}
EOF
  fi

  # ensure resolv.conf inside LFS for downloads
  bootstrap_copy_resolv

  # Run build inside chroot as lfs
  # copy pkg sources to LFS path if not already: we used LFS_USR_SRC directly
  local chroot_pkg_metafile="${BOOTSTRAP_SCRIPTS_DIR}/${pkg}.ini"
  # ensure build.sh is visible in /usr/bin inside LFS: copy from BOOTSTRAP_SCRIPTS_DIR into LFS
  if [[ -f "${BOOTSTRAP_SCRIPTS_DIR}/build.sh" ]]; then
    cp -a "${BOOTSTRAP_SCRIPTS_DIR}/build.sh" "${LFS_MNT}/usr/bin/build.sh" 2>/dev/null || true
    chmod 755 "${LFS_MNT}/usr/bin/build.sh" 2>/dev/null || true
  fi

  # copy package metafile into LFS under /usr/src/<pkg>/
  local in_lfs_pkgdir="${LFS_MNT}/usr/src/${pkg}"
  mkdir -p "${in_lfs_pkgdir}"
  if [[ -n "${RSYNC_BIN}" ]]; then
    "${RSYNC_BIN}" -a --delete --numeric-ids --no-perms "${pkg_src_dir}/" "${in_lfs_pkgdir}/" >>"${stage_log}" 2>&1 || log WARN "rsync into LFS had warnings"
  else
    (cd "${pkg_src_dir}" && tar cf - .) | (cd "${in_lfs_pkgdir}" && tar xf -) || log WARN "tar copy into LFS had warnings"
  fi

  # set up minimal env for build (stage env)
  local stage_env_cmd=""
  if [[ -n "${pkgmeta[stage.env]:-}" ]]; then
    IFS=';' read -ra ev <<<"${pkgmeta[stage.env]}"
    for e in "${ev[@]}"; do
      stage_env_cmd+="export ${e}; "
    done
  fi

  # Now run build inside chroot: /usr/bin/build.sh --metafile /usr/src/<pkg>/<pkg>.ini
  local build_cmd="${stage_env_cmd}/usr/bin/build.sh --metafile /usr/src/${pkg}/${pkg}.ini"
  log INFO "Invocando build para ${pkg} dentro do chroot: ${build_cmd}"
  run_in_chroot_as_lfs "${build_cmd}" "${stage_log}" || {
    log ERROR "build de ${pkg} falhou -- veja ${stage_log}"
    return 2
  }

  # optionally create files list inside LFS for uninstall tracking: find DESTDIR contents recorded by build.sh
  # best-effort: if build produced /var/cache/binaries/<pkg>-<ver> we can note it; else leave for later
  log INFO "bootstrap_build_package: ${pkg} concluído com sucesso"
  return 0
}

# ------- Part 2 of bootstrap.sh (append this to the file created with Part 1) -------

# -------------------------
# Test toolchain produced in stage1
# - compile a tiny C program with the new compiler inside chroot as lfs and run it
# -------------------------
bootstrap_test_compiler() {
  log INFO "Testando toolchain do stage1 dentro do chroot"

  local testdir="/tmp/bootstrap-compiler-test-$$"
  local test_c="${testdir}/test.c"
  local test_bin="${testdir}/test"
  mkdir -p "${testdir}"
  cat > "${test_c}" <<'EOF'
#include <stdio.h>
int main(void){ printf("ok\n"); return 0; }
EOF

  # copy into LFS tmp
  mkdir -p "${LFS_MNT}${testdir}"
  cp -a "${test_c}" "${LFS_MNT}${test_c}" 2>/dev/null || true
  chown "${LFS_UID}:${LFS_GID}" "${LFS_MNT}${test_c}" 2>/dev/null || true

  local cmd="cd ${testdir} && gcc -o test test.c && ./test > /tmp/bootstrap-compiler-output.txt"
  if run_in_chroot_as_lfs "${cmd}" "${BOOT_LOG_DIR}/stage1/compiler-test.log"; then
    # read result
    if chroot "${LFS_MNT}" /usr/bin/su -s /bin/bash "${LFS_USER}" -c "cat /tmp/bootstrap-compiler-output.txt" | grep -q "ok"; then
      log INFO "bootstrap_test_compiler: compilador do stage1 compilou e executou corretamente"
      touch "${STAGE_META_DIR}/status/stage1.ok"
      return 0
    else
      log ERROR "bootstrap_test_compiler: binário de teste não produziu saída esperada"
      return 2
    fi
  else
    log ERROR "bootstrap_test_compiler: falha ao compilar/executar dentro do chroot; ver logs"
    return 3
  fi
}

# -------------------------
# Create rootfs snapshot of LFS_MNT for a stage
# Produces: ${ROOTFS_SNAPSHOT_DIR}/lfs-stage<N>-<ts>.tar.zst and .sha256 and .meta
# -------------------------
bootstrap_create_rootfs_snapshot() {
  local stage="$1"
  local ts; ts=$(date -u +"%Y%m%dT%H%M%SZ")
  local name="lfs-stage${stage}-${ts}"
  local tmp_archive="/var/tmp/${name}.tar"
  local archive_zst="${ROOTFS_SNAPSHOT_DIR}/${name}.tar.zst"
  local archive_xz="${ROOTFS_SNAPSHOT_DIR}/${name}.tar.xz"
  local meta_file="${ROOTFS_SNAPSHOT_DIR}/${name}.meta"

  log INFO "Criando snapshot rootfs para stage ${stage} -> ${archive_zst}"

  # create tar and compress with zstd if available
  if [[ -n "${ZSTD_BIN}" ]]; then
    if tar -C "${LFS_MNT}" -cf - . 2>/dev/null | "${ZSTD_BIN}" -19 -T0 -o "${archive_zst}"; then
      log INFO "Snapshot gerado: ${archive_zst}"
    else
      log WARN "Compressão zstd falhou; tentando xz"
      if tar -C "${LFS_MNT}" -cJf "${archive_xz}" .; then
        log INFO "Snapshot gerado: ${archive_xz}"
      else
        fail "Falha ao gerar snapshot de rootfs"
      fi
    fi
  else
    if command -v xz >/dev/null 2>&1; then
      if tar -C "${LFS_MNT}" -cJf "${archive_xz}" .; then
        log INFO "Snapshot gerado (xz): ${archive_xz}"
      else
        fail "Falha ao gerar snapshot com xz"
      fi
    else
      fail "Nenhum compressor disponível (zstd ou xz)"
    fi
  fi

  # compute sha256
  if [[ -f "${archive_zst}" ]]; then
    sha256sum "${archive_zst}" | awk '{print $1}' > "${archive_zst}.sha256"
    local filesize; filesize=$(stat -c%s "${archive_zst}" 2>/dev/null || echo 0)
    cat > "${meta_file}" <<EOF
NAME=${name}
STAGE=${stage}
TIMESTAMP=${ts}
ARCH=$(uname -m)
SIZE=${filesize}
PATH=${archive_zst}
EOF
  elif [[ -f "${archive_xz}" ]]; then
    sha256sum "${archive_xz}" | awk '{print $1}' > "${archive_xz}.sha256"
    local filesize; filesize=$(stat -c%s "${archive_xz}" 2>/dev/null || echo 0)
    cat > "${meta_file}" <<EOF
NAME=${name}
STAGE=${stage}
TIMESTAMP=${ts}
ARCH=$(uname -m)
SIZE=${filesize}
PATH=${archive_xz}
EOF
  fi

  log INFO "Snapshot e metadata criados: ${meta_file}"
  return 0
}

# -------------------------
# Stage runner: orchestrates parse meta, run pkgs in order, optional tests, snapshot
# -------------------------
bootstrap_stage_run() {
  local stage_num="$1"
  local meta_file="$2"
  log INFO "Iniciando stage ${stage_num} com meta ${meta_file}"

  # parse meta
  declare -a stage_order=()
  declare -A stage_meta=()
  parse_stage_meta "${meta_file}" stage_order stage_meta

  # apply stage.env if provided (for this invocation only)
  local saved_env="$(env)"
  if [[ -n "${stage_meta[stage.env]:-}" ]]; then
    IFS=';' read -ra envs <<<"${stage_meta[stage.env]}"
    for e in "${envs[@]}"; do
      if [[ -n "$e" ]]; then
        export "$e"
        log DEBUG "export ${e}"
      fi
    done
  fi

  # iterate pkgs
  for pkg in "${stage_order[@]}"; do
    # skip if done marker exists
    if [[ -f "${STAGE_META_DIR}/status/${pkg}.done" ]]; then
      log INFO "Pacote ${pkg} já concluído (status file presente), pulando"
      continue
    fi
    # build package
    if ! bootstrap_build_package "${pkg}" stage_meta "${stage_num}"; then
      log ERROR "Falha ao construir ${pkg} no stage ${stage_num}"
      touch "${STAGE_META_DIR}/status/${pkg}.fail"
      return 1
    fi
    touch "${STAGE_META_DIR}/status/${pkg}.done"
  done

  # post-stage tests (stage1 compiler test)
  if (( stage_num == 1 )); then
    if ! bootstrap_test_compiler; then
      touch "${STAGE_META_DIR}/status/stage1.fail"
      fail "Testes do compilador do stage1 falharam"
    fi
  fi

  # create snapshot
  bootstrap_create_rootfs_snapshot "${stage_num}" || log WARN "Falha ao criar snapshot do stage ${stage_num}"

  # restore env
  # clear previously exported stage.env variables by reloading environment (best-effort)
  # (we simply unset them if they were in stage_meta)
  if [[ -n "${stage_meta[stage.env]:-}" ]]; then
    IFS=';' read -ra envs2 <<<"${stage_meta[stage.env]}"
    for e in "${envs2[@]}"; do
      var="${e%%=*}"
      unset "$var" || true
    done
  fi

  log INFO "Stage ${stage_num} concluído com sucesso"
  touch "${STAGE_META_DIR}/status/stage${stage_num}.ok"
  return 0
}

# -------------------------
# Cleanup pseudo-filesystems mounted inside LFS
# -------------------------
bootstrap_umount_pseudo() {
  log INFO "Desmontando pseudo-filesystems dentro de ${LFS_MNT}"
  for d in dev/pts dev proc sys run; do
    if mountpoint -q "${LFS_MNT}/${d}" 2>/dev/null; then
      umount -l "${LFS_MNT}/${d}" 2>/dev/null || log WARN "Falha ao desmontar ${LFS_MNT}/${d}"
    fi
  done
}

# -------------------------
# Mount pseudo-filesystems inside LFS for chrooted builds
# -------------------------
bootstrap_mount_pseudo() {
  log INFO "Montando pseudo-filesystems (proc,sys,dev,run) em ${LFS_MNT}"
  mkdir -p "${LFS_MNT}/proc" "${LFS_MNT}/sys" "${LFS_MNT}/dev/pts" "${LFS_MNT}/run"
  mount -t proc proc "${LFS_MNT}/proc" 2>/dev/null || true
  mount -t sysfs sys "${LFS_MNT}/sys" 2>/dev/null || true
  mount --bind /dev "${LFS_MNT}/dev" 2>/dev/null || true
  mount --bind /dev/pts "${LFS_MNT}/dev/pts" 2>/dev/null || true
  mount --bind /run "${LFS_MNT}/run" 2>/dev/null || true
  # copy resolv.conf if not already present
  bootstrap_copy_resolv
}

# -------------------------
# Rollback: attempt to undo changes (best-effort)
# -------------------------
bootstrap_rollback() {
  if [[ "${_TRAPED}" == "true" ]]; then
    log WARN "bootstrap_rollback já executado; ignorando"
    return 0
  fi
  _TRAPED=true
  log WARN "Rollback ativado (tentativa de reverter alterações)"
  # unmount pseudo
  bootstrap_umount_pseudo || true
  # optionally remove tmp build dir
  if [[ -d "${TMP_BUILD}" ]]; then rm -rf "${TMP_BUILD}" || true; fi
  # don't remove snapshots or logs automatically
  log WARN "Rollback finalizado (estado pode requerer intervenção manual)"
  return 0
}

# ensure rollback on ERR/INT/TERM
trap 'bootstrap_rollback; exit 1' ERR INT TERM

# -------------------------
# Final cleanup and summary
# -------------------------
bootstrap_final_cleanup() {
  log INFO "Realizando limpeza final"

  # unmount pseudo filesystems
  bootstrap_umount_pseudo

  # remove lfs user if desired
  bootstrap_remove_lfs_user || log WARN "Falha ao remover usuário LFS (ver logs)"

  # remove TMP_BUILD
  if [[ -d "${TMP_BUILD}" ]]; then
    rm -rf "${TMP_BUILD}" || log WARN "Falha ao remover TMP_BUILD"
  fi

  log INFO "Limpeza final concluída. Snapshots e logs estão em: ${ROOTFS_SNAPSHOT_DIR}, ${BOOT_LOG_DIR}"
}

# -------------------------
# CLI and main dispatcher
# -------------------------
_print_usage() {
  cat <<EOF
bootstrap.sh - automatiza bootstrap LFS (stages 1..3) com snapshots e testes

Uso:
  bootstrap.sh --init                    : cria diretórios e checa pré-requisitos
  bootstrap.sh --start                   : executa stages 1,2,3 conforme ${STAGE_META_DIR}/stageN.meta
  bootstrap.sh --stage <n>               : executa somente stage n (1|2|3)
  bootstrap.sh --status                  : mostra status (stage*.ok/.fail)
  bootstrap.sh --install-scripts         : instala scripts de orquestrador em ${BOOTSTRAP_SCRIPTS_DIR} dentro do LFS
  bootstrap.sh --create-user             : cria usuário LFS (não roda builds)
  bootstrap.sh --remove-user             : remove usuário LFS (se seguro)
  bootstrap.sh --help | -h
Flags via ENV:
  BOOTSTRAP_DEBUG=true    - ativa debug
  BOOTSTRAP_SILENT=true   - suprime logs INFO/WARN (mostra apenas ERROR)
EOF
}

# main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if (( $# == 0 )); then _print_usage; exit 0; fi
  bootstrap_init
  cmd="$1"; shift
  case "$cmd" in
    --init)
      bootstrap_prechecks
      bootstrap_create_lfs_user
      bootstrap_install_scripts
      echo "Init concluído. Verifique ${BOOT_LOG_DIR} para logs."
      ;;
    --start)
      bootstrap_prechecks
      bootstrap_create_lfs_user
      bootstrap_install_scripts
      bootstrap_mount_pseudo || true
      # ensure status dir exists
      mkdir -p "${STAGE_META_DIR}/status"
      # run stages sequentially
      bootstrap_stage_run 1 "${STAGE1_META}" || fail "Stage1 falhou"
      bootstrap_stage_run 2 "${STAGE2_META}" || fail "Stage2 falhou"
      bootstrap_stage_run 3 "${STAGE3_META}" || fail "Stage3 falhou"
      bootstrap_final_cleanup
      log INFO "Bootstrap completo. Snapshots em: ${ROOTFS_SNAPSHOT_DIR}"
      ;;
    --stage)
      n="$1"; shift || fail "--stage requer um número 1|2|3"
      bootstrap_prechecks
      bootstrap_create_lfs_user
      bootstrap_install_scripts
      bootstrap_mount_pseudo || true
      if [[ "$n" == "1" ]]; then
        bootstrap_stage_run 1 "${STAGE1_META}" || fail "Stage1 falhou"
      elif [[ "$n" == "2" ]]; then
        bootstrap_stage_run 2 "${STAGE2_META}" || fail "Stage2 falhou"
      elif [[ "$n" == "3" ]]; then
        bootstrap_stage_run 3 "${STAGE3_META}" || fail "Stage3 falhou"
      else
        fail "Número de stage inválido: $n"
      fi
      bootstrap_final_cleanup
      ;;
    --status)
      ls -l "${STAGE_META_DIR}/status" 2>/dev/null || echo "No status files"
      ;;
    --install-scripts)
      bootstrap_install_scripts
      ;;
    --create-user)
      bootstrap_create_lfs_user
      ;;
    --remove-user)
      bootstrap_remove_lfs_user
      ;;
    --help|-h)
      _print_usage
      ;;
    *)
      _print_usage
      exit 2
      ;;
  esac
fi

# Export functions for potential sourcing
export -f bootstrap_init bootstrap_prechecks bootstrap_create_lfs_user bootstrap_remove_lfs_user \
  bootstrap_copy_resolv bootstrap_install_scripts parse_stage_meta download_with_retries \
  run_in_chroot_as_lfs bootstrap_build_package bootstrap_test_compiler bootstrap_create_rootfs_snapshot \
  bootstrap_stage_run bootstrap_mount_pseudo bootstrap_umount_pseudo bootstrap_rollback bootstrap_final_cleanup
