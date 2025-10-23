#!/usr/bin/env bash
# sandbox.sh - gerenciador seguro de sandbox para builds (chroot / unshare / fakeroot)
# Integração: build.sh, metafile.sh, downloader.sh, patches.sh, register.sh
# Autor: Orquestrador
# Versão: 2025-10-23

set -eEuo pipefail
IFS=$'\n\t'
umask 027

SCRIPT_NAME="sandbox"
SCRIPT_VERSION="1.0.0"

# -------------------------
# Configuráveis via ENV
# -------------------------
: "${SANDBOX_BASE:=/mnt/lfs/sandbox}"
: "${SANDBOX_TMP_BASE:=/var/tmp/orquestrador/sandbox}"
: "${SANDBOX_LOG_DIR:=/var/log/orquestrador/sandbox}"
: "${SANDBOX_KEEP_ON_FAIL:=false}"   # keep sandbox dir on failure (for debugging)
: "${SANDBOX_USE_CHROOT:=true}"      # prefer chroot when available
: "${SANDBOX_USE_UNSHARE:=false}"    # use unshare+mount namespaces instead of chroot
: "${SANDBOX_USE_FAKEROOT:=false}"   # use fakeroot for install phase if needed
: "${SANDBOX_BIND_SRC:=/usr/src}"    # host sources mount (downloader.sh cache)
: "${SANDBOX_MOUNT_RETRY:=3}"
: "${SANDBOX_DEBUG:=false}"
: "${SANDBOX_SILENT:=false}"
: "${LFS_MNT:=/mnt/lfs}"
: "${LFS_USER:=lfs}"
: "${LFS_UID:=2000}"
: "${LFS_GID:=2000}"
: "${BUILD_CMD:="/usr/bin/build.sh"}"  # typical build entrypoint inside sandbox/chroot

# Tools
: "${MOUNT_BIN:=$(command -v mount || true)}"
: "${UMOUNT_BIN:=$(command -v umount || true)}"
: "${CHROOT_BIN:=$(command -v chroot || true)}"
: "${NSENTER_BIN:=$(command -v nsenter || true)}"
: "${UNSHARE_BIN:=$(command -v unshare || true)}"
: "${FAKEROOT_BIN:=$(command -v fakeroot || true)}"
: "${RSYNC_BIN:=$(command -v rsync || true)}"
: "${MKDIR_BIN:=$(command -v mkdir || true)}"
: "${TAR_BIN:=$(command -v tar || true)}"
: "${ZSTD_BIN:=$(command -v zstd || true)}"

# runtime
_SESSION_TS="$(date -u +"%Y%m%dT%H%M%SZ")-$$"
_meta_logfile="${SANDBOX_LOG_DIR}/sandbox-${_SESSION_TS}.log"
mkdir -p "${SANDBOX_LOG_DIR}" "${SANDBOX_TMP_BASE}" "${SANDBOX_BASE}" 2>/dev/null || true

# -------------------------
# Logging helpers (integrate with register.sh if present)
# -------------------------
_slog() {
  local level="$1"; shift
  local msg="$*"
  if type register_info >/dev/null 2>&1; then
    case "$level" in
      INFO) register_info "$msg"; ;;
      WARN) register_warn "$msg"; ;;
      ERROR) register_error "$msg"; ;;
      DEBUG) register_debug "$msg"; ;;
      *) register_info "$msg"; ;;
    esac
  fi
  if [[ "${SANDBOX_SILENT}" == "true" && "$level" != "ERROR" ]]; then
    return 0
  fi
  case "$level" in
    INFO)  printf '\e[32m[SBX INFO]\e[0m %s\n' "$msg" ;;
    WARN)  printf '\e[33m[SBX WARN]\e[0m %s\n' "$msg" >&2 ;;
    ERROR) printf '\e[31m[SBX ERR]\e[0m %s\n' "$msg" >&2 ;;
    DEBUG) [[ "${SANDBOX_DEBUG}" == "true" ]] && printf '\e[36m[SBX DBG]\e[0m %s\n' "$msg" ;;
    *) printf '[SBX] %s\n' "$msg" ;;
  esac
  # append to logfile
  printf '%s %s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "[$level]" "$msg" >> "${_meta_logfile}" 2>/dev/null || true
}

_sfail() {
  local msg="$1"; local code="${2:-1}"
  _slog ERROR "$msg"
  sandbox_rollback || true
  exit "$code"
}

# -------------------------
# Utility helpers
# -------------------------
_safe_mkdir() {
  mkdir -p "$1" 2>/dev/null || _sfail "Unable to mkdir $1"
  chmod 750 "$1" 2>/dev/null || true
}

_realpath() {
  if command -v realpath >/dev/null 2>&1; then realpath "$1"; else (cd "$(dirname "$1")" && echo "$(pwd -P)/$(basename "$1")"); fi
}

# safe mktemp dir
_mktemp_dir() {
  local prefix="${1:-sandbox}"
  local tmp
  tmp="$(mktemp -d "${SANDBOX_TMP_BASE}/${prefix}.XXXXXX")" || _sfail "mktemp failed"
  echo "$tmp"
}

# retry helper
_retry_cmd() {
  local tries="${1}"; shift
  local cmd=("$@")
  local i=0
  while (( i < tries )); do
    if "${cmd[@]}"; then return 0; fi
    i=$((i+1))
    sleep 1
  done
  return 1
}

# -------------------------
# Check environment tools
# -------------------------
sandbox_check_tools() {
  local missing=()
  for t in mount umount chroot rsync tar; do
    if ! command -v "$t" >/dev/null 2>&1; then
      missing+=("$t")
    fi
  done
  if [[ "${#missing[@]}" -ne 0 ]]; then
    _slog WARN "Ferramentas ausentes: ${missing[*]} (algumas funcionalidades podem falhar)"
  fi
  if [[ "${SANDBOX_USE_UNSHARE}" == "true" && -z "${UNSHARE_BIN}" ]]; then
    _slog WARN "unshare não disponível; desativando SANDBOX_USE_UNSHARE"
    SANDBOX_USE_UNSHARE=false
  fi
  if [[ "${SANDBOX_USE_FAKEROOT}" == "true" && -z "${FAKEROOT_BIN}" ]]; then
    _slog WARN "fakeroot não encontrado; desativando SANDBOX_USE_FAKEROOT"
    SANDBOX_USE_FAKEROOT=false
  fi
  return 0
}

# -------------------------
# Sandbox path helpers:
# sandbox layout:
# ${SANDBOX_BASE}/${pkg}/rootfs        - target root for chroot
# ${SANDBOX_BASE}/${pkg}/build         - working build dir
# ${SANDBOX_BASE}/${pkg}/sources       - sources cache bind
# ${SANDBOX_BASE}/${pkg}/logs          - logs for build
# ${SANDBOX_BASE}/${pkg}/tmp           - tmp inside sandbox
# -------------------------
sandbox_paths() {
  local pkg="$1"
  printf '%s\n' \
    "${SANDBOX_BASE}/${pkg}" \
    "${SANDBOX_BASE}/${pkg}/rootfs" \
    "${SANDBOX_BASE}/${pkg}/build" \
    "${SANDBOX_BASE}/${pkg}/sources" \
    "${SANDBOX_BASE}/${pkg}/logs" \
    "${SANDBOX_BASE}/${pkg}/tmp"
}

# -------------------------
# Create base structure for a sandbox for a package
# -------------------------
sandbox_prepare_root() {
  local pkg="$1"
  if [[ -z "$pkg" ]]; then _sfail "sandbox_prepare_root: package name required"; fi
  local base_dir="${SANDBOX_BASE}/${pkg}"
  local rootfs="${base_dir}/rootfs"
  local build="${base_dir}/build"
  local sources="${base_dir}/sources"
  local logs="${base_dir}/logs"
  local tmp="${base_dir}/tmp"

  _safe_mkdir "${base_dir}"
  _safe_mkdir "${rootfs}"
  _safe_mkdir "${build}"
  _safe_mkdir "${sources}"
  _safe_mkdir "${logs}"
  _safe_mkdir "${tmp}"

  # ensure minimal etc inside rootfs for chroot (passwd/group/resolv)
  mkdir -p "${rootfs}/etc" "${rootfs}/var" "${rootfs}/tmp" "${rootfs}/run" "${rootfs}/proc" "${rootfs}/sys" "${rootfs}/dev"
  # copy host resolv.conf if available to allow dns inside chroot
  if [[ -r /etc/resolv.conf ]]; then
    cp -a /etc/resolv.conf "${rootfs}/etc/resolv.conf" || _slog WARN "falha ao copiar resolv.conf para sandbox ${pkg}"
  fi

  # create minimal /etc/passwd and /etc/group if not present
  if [[ ! -f "${rootfs}/etc/passwd" ]]; then
    printf 'root:x:0:0:root:/root:/bin/bash\n' > "${rootfs}/etc/passwd"
  fi
  if [[ ! -f "${rootfs}/etc/group" ]]; then
    printf 'root:x:0:\n' > "${rootfs}/etc/group"
  fi

  # set ownerships permissive for host root use
  chown -R root:root "${rootfs}" 2>/dev/null || true
  chmod 0755 "${rootfs}" 2>/dev/null || true

  _slog INFO "sandbox_prepare_root: estrutura criada para ${pkg} em ${base_dir}"
  return 0
}

# -------------------------
# Mount pseudo file-systems and bind-mounts into sandbox rootfs
# idempotent: skips mounts that already exist
# -------------------------
sandbox_mounts() {
  local pkg="$1"
  local base_dir="${SANDBOX_BASE}/${pkg}"
  local rootfs="${base_dir}/rootfs"
  local sources="${base_dir}/sources"
  local logs="${base_dir}/logs"
  local build="${base_dir}/build"
  local tmp="${base_dir}/tmp"

  if [[ ! -d "${rootfs}" ]]; then _sfail "sandbox_mounts: rootfs missing for ${pkg}"; fi

  # helper to test mountpoint
  _is_mounted() {
    mountpoint -q "$1" 2>/dev/null
  }

  # Bind /dev
  if ! _is_mounted "${rootfs}/dev"; then
    _retry_cmd "${SANDBOX_MOUNT_RETRY}" "${MOUNT_BIN}" --bind /dev "${rootfs}/dev" || _slog WARN "bind /dev failed"
  fi
  # dev/pts
  if [[ -d /dev/pts && ! -d "${rootfs}/dev/pts" ]]; then mkdir -p "${rootfs}/dev/pts"; fi
  if ! _is_mounted "${rootfs}/dev/pts"; then
    _retry_cmd "${SANDBOX_MOUNT_RETRY}" "${MOUNT_BIN}" --bind /dev/pts "${rootfs}/dev/pts" || true
  fi
  # /proc
  if ! _is_mounted "${rootfs}/proc"; then
    _retry_cmd "${SANDBOX_MOUNT_RETRY}" "${MOUNT_BIN}" -t proc proc "${rootfs}/proc" || _slog WARN "mount proc failed"
  fi
  # /sys
  if ! _is_mounted "${rootfs}/sys"; then
    _retry_cmd "${SANDBOX_MOUNT_RETRY}" "${MOUNT_BIN}" -t sysfs sys "${rootfs}/sys" || _slog WARN "mount sys failed"
  fi
  # /run (bind)
  if ! _is_mounted "${rootfs}/run"; then
    mkdir -p "${rootfs}/run"
    _retry_cmd "${SANDBOX_MOUNT_RETRY}" "${MOUNT_BIN}" --bind /run "${rootfs}/run" || true
  fi
  # /tmp inside sandbox (tmpfs)
  if ! _is_mounted "${rootfs}/tmp"; then
    mkdir -p "${rootfs}/tmp"
    # Use bind to host /tmp to share, safer than tmpfs here; allow isolation optional
    _retry_cmd "${SANDBOX_MOUNT_RETRY}" "${MOUNT_BIN}" --bind /tmp "${rootfs}/tmp" || true
  fi

  # Bind sources cache (host downloader)
  if [[ -d "${SANDBOX_BIND_SRC}" ]]; then
    if ! _is_mounted "${sources}"; then
      _retry_cmd "${SANDBOX_MOUNT_RETRY}" "${MOUNT_BIN}" --bind "${SANDBOX_BIND_SRC}" "${sources}" || _slog WARN "bind sources failed"
    fi
  else
    _slog WARN "SANDBOX_BIND_SRC ${SANDBOX_BIND_SRC} not present"
  fi

  # Bind build dir into rootfs at /build (so build.sh inside chroot finds sources)
  if ! _is_mounted "${rootfs}/build"; then
    mkdir -p "${rootfs}/build"
    _retry_cmd "${SANDBOX_MOUNT_RETRY}" "${MOUNT_BIN}" --bind "${build}" "${rootfs}/build" || _slog WARN "bind build failed"
  fi

  # create logs mountpoint inside rootfs to read from host if needed
  if [[ ! -d "${rootfs}/var/log" ]]; then mkdir -p "${rootfs}/var/log"; fi
  if ! _is_mounted "${rootfs}/var/log/sandbox"; then
    mkdir -p "${rootfs}/var/log/sandbox"
    _retry_cmd "${SANDBOX_MOUNT_RETRY}" "${MOUNT_BIN}" --bind "${logs}" "${rootfs}/var/log/sandbox" || true
  fi

  _slog INFO "sandbox_mounts: mounts applied for ${pkg}"
  return 0
}
# -------------------------
# Unmount all binds for a sandbox (best-effort)
# -------------------------
sandbox_umounts() {
  local pkg="$1"
  local base_dir="${SANDBOX_BASE}/${pkg}"
  local rootfs="${base_dir}/rootfs"
  if [[ ! -d "${rootfs}" ]]; then
    _slog DEBUG "sandbox_umounts: rootfs does not exist for ${pkg}, skipping"
    return 0
  fi

  local paths=( \
    "${rootfs}/var/log/sandbox" \
    "${rootfs}/build" \
    "${rootfs}/sources" \
    "${rootfs}/tmp" \
    "${rootfs}/run" \
    "${rootfs}/sys" \
    "${rootfs}/proc" \
    "${rootfs}/dev/pts" \
    "${rootfs}/dev" \
  )

  for p in "${paths[@]}"; do
    if mountpoint -q "$p" 2>/dev/null; then
      if ! "${UMOUNT_BIN}" -l "$p" 2>/dev/null; then
        _slog WARN "umount -l failed for $p; trying normal umount"
        "${UMOUNT_BIN}" "$p" 2>/dev/null || _slog WARN "umount failed for $p (ignored)"
      fi
    fi
  done

  _slog INFO "sandbox_umounts: unmounted pseudo and binds for ${pkg}"
  return 0
}

# -------------------------
# Cleanup sandbox directory (removes base dir unless keep flag set)
# -------------------------
sandbox_cleanup() {
  local pkg="$1"
  local base_dir="${SANDBOX_BASE}/${pkg}"
  sandbox_umounts "$pkg" || true
  if [[ "${SANDBOX_KEEP_ON_FAIL}" == "true" ]]; then
    _slog INFO "SANDBOX_KEEP_ON_FAIL=true => preserving sandbox ${base_dir} for inspection"
    return 0
  fi
  # ensure no mounts remain
  if find "${base_dir}" -mindepth 1 -maxdepth 4 -type d | grep -q .; then
    # attempt final unmounts
    sandbox_umounts "$pkg" || true
  fi
  rm -rf "${base_dir}" 2>/dev/null || _slog WARN "Failed to remove sandbox dir ${base_dir} (ignored)"
  _slog INFO "sandbox_cleanup: removed ${base_dir}"
  return 0
}

# -------------------------
# Ensure sandbox is mounted and ready; idempotent (prepare+mount)
# -------------------------
sandbox_ready() {
  local pkg="$1"
  sandbox_prepare_root "$pkg" || return 1
  sandbox_mounts "$pkg" || return 1
  return 0
}

# -------------------------
# Enter into sandbox and run a command as a given user (root by default)
# Uses chroot if available and SANDBOX_USE_CHROOT=true, else uses unshare if configured
# Arguments:
#   $1 = pkg
#   $2 = user (optional, default root or LFS_USER)
#   $3.. = command to run (string or list)
# Logs are appended to sandbox logs dir.
# Returns exit code of inner command
# -------------------------
sandbox_run() {
  local pkg="$1"; shift
  local user="${1:-root}"; shift || true
  if [[ -z "$pkg" ]]; then _sfail "sandbox_run: pkg required"; fi
  local base_dir="${SANDBOX_BASE}/${pkg}"
  local rootfs="${base_dir}/rootfs"
  local logs="${base_dir}/logs"
  mkdir -p "${logs}"
  local logfile="${logs}/run-$(date -u +"%Y%m%dT%H%M%SZ").log"

  if [[ ! -d "${rootfs}" ]]; then
    _slog ERROR "sandbox_run: rootfs missing for ${pkg}"
    return 2
  fi

  # build the command string
  local cmd=("$@")
  if [[ ${#cmd[@]} -eq 0 ]]; then
    _slog WARN "sandbox_run: no command provided"
    return 3
  fi

  _slog INFO "sandbox_run: running as '${user}' in sandbox ${pkg}: ${cmd[*]} (log: ${logfile})"

  # create run wrapper inside rootfs to ensure environment
  local wrapper="${rootfs}/.sandbox_run.sh"
  cat > "${wrapper}" <<'EOF'
#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
cd /build || true
exec "$@"
EOF
  chmod 755 "${wrapper}" || true

  # choose execution method
  if [[ "${SANDBOX_USE_CHROOT}" == "true" && -n "${CHROOT_BIN}" ]]; then
    # if user is not root, use su inside chroot to drop to user
    if [[ "${user}" == "root" ]]; then
      chroot "${rootfs}" /bin/bash -c "/.sandbox_run.sh ${cmd[*]}" >> "${logfile}" 2>&1 || {
        local rc=$?
        _slog ERROR "sandbox_run: command failed (rc=${rc}), see ${logfile}"
        return $rc
      }
    else
      # attempt to use su -s
      chroot "${rootfs}" /usr/bin/su -s /bin/bash "${user}" -c "/.sandbox_run.sh ${cmd[*]}" >> "${logfile}" 2>&1 || {
        local rc=$?
        _slog ERROR "sandbox_run: command as ${user} failed (rc=${rc}), see ${logfile}"
        return $rc
      }
    fi
  elif [[ "${SANDBOX_USE_UNSHARE}" == "true" && -n "${UNSHARE_BIN}" ]]; then
    # use unshare to create new mount namespace; then pivot_root or bind + chroot
    # we'll run a simple unshare --mount --pid --fork --mount-proc -- bash -c "..."
    unshare --mount --pid --fork --mount-proc bash -c "cd ${rootfs} && exec chroot . /bin/bash -c '/.sandbox_run.sh ${cmd[*]}'" >> "${logfile}" 2>&1 || {
      local rc=$?
      _slog ERROR "sandbox_run: unshare/chroot command failed (rc=${rc}), see ${logfile}"
      return $rc
    }
  else
    _slog ERROR "sandbox_run: no supported method to enter sandbox (chroot/unshare missing)"
    return 10
  fi

  _slog INFO "sandbox_run: command completed for ${pkg}"
  return 0
}

# -------------------------
# High-level build execution inside sandbox for a metafile/package
# Called by build.sh to orchestrate:
#  - ensure sandbox ready
#  - copy sources (from metafile or host cache)
#  - apply patches (patches.sh) inside sandbox build dir
#  - run build (BUILD_CMD) inside sandbox as LFS_USER or root
#  - capture logs and return status
# Usage: sandbox_exec_build <pkg> <metafile_path> [--user lfs] [--fakeroot]
# -------------------------
sandbox_exec_build() {
  local pkg="$1"; local metafile="$2"; shift 2 || true
  local run_user="${LFS_USER}"
  local use_fakeroot="${SANDBOX_USE_FAKEROOT}"
  # parse additional args (simple)
  while (( "$#" )); do
    case "$1" in
      --user) run_user="$2"; shift 2 ;;
      --no-fakeroot) use_fakeroot="false"; shift ;;
      --fakeroot) use_fakeroot="true"; shift ;;
      *) shift ;;
    esac
  done

  if [[ -z "$pkg" || -z "$metafile" ]]; then _sfail "sandbox_exec_build: pkg and metafile required"; fi
  if [[ ! -f "$metafile" ]]; then _sfail "sandbox_exec_build: metafile not found: $metafile"; fi

  # ensure sandbox paths exist and mounted
  sandbox_ready "$pkg" || { _slog ERROR "sandbox_exec_build: sandbox_ready failed"; return 2; }

  local base_dir="${SANDBOX_BASE}/${pkg}"
  local build_dir="${base_dir}/build"
  local rootfs="${base_dir}/rootfs"
  local logs="${base_dir}/logs"
  local sources="${base_dir}/sources"
  mkdir -p "${build_dir}" "${logs}" "${sources}"

  # load metafile to get sources/patches/hooks
  if type meta_load >/dev/null 2>&1; then
    meta_load "$metafile" MF || _slog WARN "meta_load not available; proceeding"
  fi

  # Copy sources into build dir if metafile lists local sources or tarball in host cache
  # If SOURCES are URLs, assume downloader has cached them in SANDBOX_BIND_SRC (bind). We only sync to build dir.
  local src_list="${MF_SOURCES:-${META_SOURCES:-}}"
  local urls_list="${MF_URLS:-${META_URLS:-}}"
  local logs_file="${logs}/build-$(date -u +"%Y%m%dT%H%M%SZ").log"

  _slog INFO "sandbox_exec_build: preparing sources for ${pkg} (build_dir=${build_dir})"

  # prefer rsync if available to copy from sources mount into build_dir
  if [[ -n "${RSYNC_BIN}" ]]; then
    # sync any folder named pkg inside SANDBOX_BIND_SRC to build_dir
    if [[ -d "${SANDBOX_BIND_SRC}/${pkg}" ]]; then
      "${RSYNC_BIN}" -a --delete "${SANDBOX_BIND_SRC}/${pkg}/" "${build_dir}/" >> "${logs_file}" 2>&1 || _slog WARN "rsync copy from cache had warnings"
    fi
  else
    # fallback: if a tarball exists in SANDBOX_BIND_SRC, extract first matching
    if compgen -G "${SANDBOX_BIND_SRC}/${pkg}*.tar.*" >/dev/null 2>&1; then
      for tb in "${SANDBOX_BIND_SRC}/${pkg}"*.tar.*; do
        _slog DEBUG "Extracting ${tb} into ${build_dir}"
        "${TAR_BIN}" -xf "${tb}" -C "${build_dir}" --strip-components=0 >> "${logs_file}" 2>&1 || _slog WARN "tar extract warning for ${tb}"
      done
    fi
  fi

  # If metafile has urls and no content in build_dir, attempt to copy downloaded file from SANDBOX_BIND_SRC
  if [[ -z "$(ls -A "${build_dir}" 2>/dev/null)" ]]; then
    # try to find tarball by version/name in SANDBOX_BIND_SRC
    if [[ -n "${MF_VERSION:-}" ]]; then
      local candidate
      candidate="$(ls -1 "${SANDBOX_BIND_SRC}/${pkg}-${MF_VERSION}"* 2>/dev/null | head -n1 || true)"
      if [[ -n "${candidate}" ]]; then
        if [[ -d "${candidate}" ]]; then
          "${RSYNC_BIN:-cp -a}" "${candidate}/" "${build_dir}/" >> "${logs_file}" 2>&1 || true
        else
          "${TAR_BIN}" -xf "${candidate}" -C "${build_dir}" --strip-components=0 >> "${logs_file}" 2>&1 || true
        fi
      fi
    fi
  fi

  # If still empty and url list is present, signal that downloader should fetch it; build.sh should call downloader first
  if [[ -z "$(ls -A "${build_dir}" 2>/dev/null)" && -n "${MF_URLS:-}" ]]; then
    _slog WARN "sandbox_exec_build: build_dir empty for ${pkg}; expected downloads in ${SANDBOX_BIND_SRC}. Ensure downloader.sh fetched sources."
  fi

  # apply patches if patches.sh available
  if type apply_patches >/dev/null 2>&1; then
    apply_patches "${build_dir}" "${MF_PATCHES:-}" >> "${logs_file}" 2>&1 || _slog WARN "apply_patches returned warnings"
  else
    _slog DEBUG "patches.sh/apply_patches not present; skipping patch application"
  fi

  # execute build inside sandbox
  local inner_cmd
  if [[ "${use_fakeroot}" == "true" && -n "${FAKEROOT_BIN}" ]]; then
    inner_cmd="${FAKEROOT_BIN} ${BUILD_CMD} --metafile /build/$(basename "${metafile}")"
  else
    inner_cmd="${BUILD_CMD} --metafile /build/$(basename "${metafile}")"
  fi

  # copy metafile into sandbox build area so build.sh --metafile path resolves
  cp -a "${metafile}" "${build_dir}/" || _slog WARN "Failed to copy metafile into build_dir"

  _slog INFO "sandbox_exec_build: invoking build inside sandbox: ${inner_cmd} (user=${run_user})"
  if sandbox_run "${pkg}" "${run_user}" "${inner_cmd}"; then
    _slog INFO "sandbox_exec_build: build succeeded for ${pkg} (logs: ${logs_file})"
    return 0
  else
    _slog ERROR "sandbox_exec_build: build failed for ${pkg}; logs: ${logs_file}"
    return 2
  fi
}

# -------------------------
# Snapshot sandbox (tar.zst) for debugging or caching
# Generates snapshot at SANDBOX_LOG_DIR or ROOTFS cache
# -------------------------
sandbox_snapshot() {
  local pkg="$1"; local stage="${2:-snapshot}"
  local base_dir="${SANDBOX_BASE}/${pkg}"
  local rootfs="${base_dir}/rootfs"
  local outdir="${SANDBOX_LOG_DIR}/snapshots"
  mkdir -p "${outdir}"
  local ts; ts="$(_ts)"
  local name="${pkg}-${stage}-${ts}.tar.zst"
  local out="${outdir}/${name}"
  if [[ ! -d "${rootfs}" ]]; then _slog WARN "sandbox_snapshot: no rootfs for ${pkg}"; return 1; fi
  if [[ -n "${ZSTD_BIN}" ]]; then
    tar -C "${rootfs}" -cf - . | "${ZSTD_BIN}" -19 -T0 -o "${out}" || { _slog WARN "snapshot compression failed"; return 2; }
  else
    tar -C "${rootfs}" -cJf "${out%.zst}.xz" . || { _slog WARN "snapshot xz failed"; return 2; }
  fi
  _slog INFO "sandbox_snapshot: created snapshot ${out}"
  return 0
}

# -------------------------
# Rollback handler for sandbox operations (best-effort)
# -------------------------
sandbox_rollback() {
  _slog WARN "sandbox_rollback called; attempting cleanup"
  # try to unmount all sandboxes
  for d in "${SANDBOX_BASE}"/*; do
    if [[ -d "$d" ]]; then
      local pkg; pkg="$(basename "$d")"
      sandbox_umounts "$pkg" || true
      if [[ "${SANDBOX_KEEP_ON_FAIL}" != "true" ]]; then
        rm -rf "$d" 2>/dev/null || true
      fi
    fi
  done
  _slog INFO "sandbox_rollback: completed cleanup attempts"
  return 0
}

# -------------------------
# CLI helper functions
# -------------------------
_print_usage() {
  cat <<EOF
sandbox.sh - manage isolated sandboxes for builds

Usage:
  sandbox.sh --check
  sandbox.sh --init
  sandbox.sh --prepare <pkg>
  sandbox.sh --enter <pkg> --user <user> --cmd "<command>"
  sandbox.sh --exec <pkg> <user> <command...>
  sandbox.sh --build <pkg> <metafile> [--user lfs] [--fakeroot]
  sandbox.sh --snapshot <pkg>
  sandbox.sh --clean <pkg|--all>
  sandbox.sh --help

Notes:
  - build.sh should call sandbox_exec_build to leverage this module.
  - SANDBOX_BASE controls where sandboxes live (default: /mnt/lfs/sandbox).
  - SANDBOX_BIND_SRC is bind-mounted into each sandbox at /sources (default: /usr/src).
EOF
}

# -------------------------
# CLI dispatcher
# -------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if (( $# == 0 )); then _print_usage; exit 0; fi
  cmd="$1"; shift
  case "$cmd" in
    --check)
      sandbox_check_tools
      ;;
    --init)
      sandbox_check_tools
      _safe_mkdir "${SANDBOX_BASE}"
      _slog INFO "sandbox: initialised base ${SANDBOX_BASE}"
      ;;
    --prepare)
      pkg="$1"; shift || _sfail "--prepare requires <pkg>"
      sandbox_prepare_root "$pkg"
      sandbox_mounts "$pkg"
      ;;
    --enter)
      pkg="$1"; shift || _sfail "--enter requires <pkg>"
      user="root"
      if [[ "$1" == "--user" ]]; then user="$2"; shift 2; fi
      cmdstr="$*"
      if [[ -z "$cmdstr" ]]; then _sfail "--enter requires a command to run"; fi
      sandbox_ready "$pkg"
      sandbox_run "$pkg" "$user" "$cmdstr"
      ;;
    --exec)
      pkg="$1"; shift || _sfail "--exec requires <pkg> <user> <command...>"
      user="$1"; shift || _sfail "--exec requires user"
      sandbox_run "$pkg" "$user" "$@"
      ;;
    --build)
      pkg="$1"; metafile="$2"; shift 2 || _sfail "--build requires <pkg> <metafile>"
      # parse optional flags for build
      run_user="${LFS_USER}"
      use_fkr="false"
      while (( $# )); do
        case "$1" in
          --user) run_user="$2"; shift 2 ;;
          --fakeroot) use_fkr="true"; shift ;;
          --no-fakeroot) use_fkr="false"; shift ;;
          *) shift ;;
        esac
      done
      sandbox_exec_build "$pkg" "$metafile" --user "${run_user}" $( [[ "${use_fkr}" == "true" ]] && echo --fakeroot || true )
      ;;
    --snapshot)
      pkg="$1"; shift || _sfail "--snapshot requires <pkg>"
      sandbox_snapshot "$pkg"
      ;;
    --clean)
      targ="$1"; shift || _sfail "--clean requires <pkg|--all>"
      if [[ "$targ" == "--all" ]]; then
        for d in "${SANDBOX_BASE}"/*; do
          [[ -d "$d" ]] || continue
          pkg="$(basename "$d")"
          sandbox_cleanup "$pkg"
        done
      else
        sandbox_cleanup "$targ"
      fi
      ;;
    --help|-h)
      _print_usage
      ;;
    *)
      _print_usage; exit 2
      ;;
  esac
fi

# export functions for build.sh integration
export -f sandbox_prepare_root sandbox_mounts sandbox_umounts sandbox_ready sandbox_run sandbox_exec_build sandbox_cleanup sandbox_snapshot sandbox_check_tools sandbox_rollback
