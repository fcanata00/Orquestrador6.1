#!/usr/bin/env bash
# sandbox.sh - criação e execução segura de sandboxes para builds
# - suporte a chroot (preferido) e fallback para unshare namespaces
# - montagem segura (nosuid,nodev,noexec) de pseudofs (proc,sys,dev,run/tmp)
# - execução com timeout, logs, lock, auditoria e cleanup robusto
# - integración optional com register.sh para logs coloridos
set -eEuo pipefail
IFS=$'\n\t'

# -----------------------
# Metadados / versão
# -----------------------
SCRIPT_NAME="sandbox"
SCRIPT_VERSION="1.0.0"

# -----------------------
# Configurações padrão (podem ser sobrescritas pelo ambiente)
# -----------------------
: "${SANDBOX_ROOT:=${SANDBOX_ROOT:-/mnt/lfs/sandbox}}"
: "${SANDBOX_SESSION_DIR:=${SANDBOX_SESSION_DIR:-${SANDBOX_ROOT}/sessions}}"
: "${SANDBOX_TMP_DIR:=${SANDBOX_TMP_DIR:-/tmp/sandbox.$$}}"
: "${SANDBOX_LOG_DIR:=${SANDBOX_LOG_DIR:-/var/log/sandbox}}"
: "${SANDBOX_LOCK_DIR:=${SANDBOX_LOCK_DIR:-/run/lock/sandbox}}"
: "${SANDBOX_TIMEOUT_SECS:=1800}"         # default command timeout: 30 minutes
: "${SANDBOX_MOUNT_OPTS:=nosuid,nodev,noexec,relatime}"
: "${SANDBOX_SILENT:=false}"
: "${SANDBOX_DEBUG:=false}"
: "${SANDBOX_MAX_LOG_BYTES:=10485760}"    # 10 MB before rotation
: "${SANDBOX_USER:=${SANDBOX_USER:-$(id -u)}}"
: "${SANDBOX_GROUP:=${SANDBOX_GROUP:-$(id -g)}}"
: "${SANDBOX_RETENTION_DAYS:=7}"

# Internal state
_SANDBOX_SESSION=""
_SANDBOX_ROOT_REAL=""
_SANDBOX_LOCK_FD=""
_SANDBOX_INITIALIZED=false

# -----------------------
# Helpers - logging (integrates with register.sh if available)
# -----------------------
_slog() {
  local level="$1"; shift
  local msg="$*"
  if type register_info >/dev/null 2>&1; then
    case "$level" in
      INFO)  register_info "$msg" ;;
      WARN)  register_warn "$msg" ;;
      ERROR) register_error "$msg" ;;
      DEBUG) register_debug "$msg" ;;
      *)     register_info "$msg" ;;
    esac
    return 0
  fi
  # local printing
  if [[ "${SANDBOX_SILENT}" == "true" && "${level}" != "ERROR" ]]; then
    return 0
  fi
  case "$level" in
    INFO)  printf '\e[32m[INFO]\e[0m %s\n' "$msg" ;;
    WARN)  printf '\e[33m[WARN]\e[0m %s\n' "$msg" >&2 ;;
    ERROR) printf '\e[31m[ERROR]\e[0m %s\n' "$msg" >&2 ;;
    DEBUG) [[ "${SANDBOX_DEBUG}" == "true" ]] && printf '\e[36m[DEBUG]\e[0m %s\n' "$msg" ;;
    *)     printf '[LOG] %s\n' "$msg" ;;
  esac
}

# -----------------------
# Utility functions
# -----------------------
_realpath_safe() {
  # portable realpath fallback
  local p="${1:-.}"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p"
  else
    (cd "$p" 2>/dev/null && pwd -P) || return 1
  fi
}

_rotate_log_if_needed() {
  local logfile="$1"
  if [[ -f "$logfile" ]]; then
    local bytes
    bytes=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
    if (( bytes > SANDBOX_MAX_LOG_BYTES )); then
      for i in 4 3 2 1; do
        if [[ -f "${logfile}.${i}" ]]; then mv -f "${logfile}.${i}" "${logfile}.$((i+1))" || true; fi
      done
      mv -f "${logfile}" "${logfile}.1" || true
      : > "$logfile"
    fi
  fi
}

# safe mkdir + perms
_safe_mkdir() {
  local d="$1"
  mkdir -p "$d" 2>/dev/null || { _slog ERROR "Não foi possível criar diretório $d"; return 1; }
  chmod 750 "$d" 2>/dev/null || true
}

# ensure not root of filesystem
_sanity_check_root() {
  if [[ -z "${_SANDBOX_ROOT_REAL:-}" ]]; then
    _SANDBOX_ROOT_REAL=$(_realpath_safe "${SANDBOX_ROOT}" || true)
  fi
  if [[ -z "${_SANDBOX_ROOT_REAL}" ]]; then
    _slog ERROR "Não foi possível resolver SANDBOX_ROOT (${SANDBOX_ROOT})"
    return 1
  fi
  if [[ "${_SANDBOX_ROOT_REAL}" == "/" ]]; then
    _slog ERROR "SANDBOX_ROOT resolved to / — abortando (proteção anti-destructive)"
    return 1
  fi
  return 0
}

# lock helpers
_sandbox_lock_acquire() {
  _safe_mkdir "${SANDBOX_LOCK_DIR}" || return 1
  local lockfile="${SANDBOX_LOCK_DIR}/sandbox.lock"
  exec { _SANDBOX_LOCK_FD }>>"${lockfile}" || { _slog ERROR "Falha ao abrir lockfile ${lockfile}"; return 2; }
  if ! flock -n "${_SANDBOX_LOCK_FD}"; then
    _slog WARN "Outra instância do sandbox está em execução; aguardando lock..."
    flock "${_SANDBOX_LOCK_FD}" || true
  fi
  return 0
}

_sandbox_lock_release() {
  if [[ -n "${_SANDBOX_LOCK_FD:-}" ]]; then
    eval "exec ${_SANDBOX_LOCK_FD}>&-"
    unset _SANDBOX_LOCK_FD
  fi
}

# -----------------------
# Initialization
# -----------------------
sandbox_init() {
  if [[ "${_SANDBOX_INITIALIZED}" == "true" ]]; then return 0; fi
  umask 027
  _safe_mkdir "${SANDBOX_ROOT}" || return 1
  _safe_mkdir "${SANDBOX_SESSION_DIR}" || return 1
  _safe_mkdir "${SANDBOX_LOG_DIR}" || return 1
  _safe_mkdir "${SANDBOX_LOCK_DIR}" || return 1
  _slog INFO "Inicializando sandbox base em ${SANDBOX_ROOT}"
  _SANDBOX_ROOT_REAL=$(_realpath_safe "${SANDBOX_ROOT}") || return 1
  _sandbox_prune_old_sessions || true
  _SANDBOX_INITIALIZED=true
  return 0
}

# prune old sessions
_sandbox_prune_old_sessions() {
  # remove session dirs older than retention if owned by us
  if [[ -d "${SANDBOX_SESSION_DIR}" ]]; then
    find "${SANDBOX_SESSION_DIR}" -maxdepth 1 -type d -mtime +"${SANDBOX_RETENTION_DAYS}" -print0 2>/dev/null | while IFS= read -r -d $'\0' d; do
      rm -rf "$d" || true
    done
  fi
}

# -----------------------
# Create session
# -----------------------
sandbox_create() {
  sandbox_init || return 1
  _sandbox_lock_acquire || return 1

  local sid
  sid=$(date -u +"%Y%m%dT%H%M%SZ")-$$
  local session_dir="${SANDBOX_SESSION_DIR}/${sid}"
  mkdir -p "${session_dir}" || { _slog ERROR "Falha ao criar session dir ${session_dir}"; _sandbox_lock_release; return 1; }
  chmod 750 "${session_dir}" || true

  # session subdirs
  mkdir -p "${session_dir}/root" "${session_dir}/work" "${session_dir}/logs" "${session_dir}/tmp" || true
  chmod 750 "${session_dir}/root" "${session_dir}/work" "${session_dir}/logs" "${session_dir}/tmp" || true

  _SANDBOX_SESSION="${session_dir}"
  _slog INFO "Sessão criada: ${_SANDBOX_SESSION}"
  _sandbox_write_session_meta || true
  return 0
}

_sandbox_write_session_meta() {
  if [[ -n "${_SANDBOX_SESSION}" ]]; then
    cat > "${_SANDBOX_SESSION}/meta" <<EOF
session=${_SANDBOX_SESSION}
created=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
uid=$(id -u)
gid=$(id -g)
root=${SANDBOX_ROOT}
EOF
    chmod 640 "${_SANDBOX_SESSION}/meta" || true
  fi
}

# -----------------------
# Mount helpers (safe)
# -----------------------
_sandbox_mount() {
  local target="$1"; local src="$2"; local fstype="$3"; local opts="$4"
  mkdir -p "${target}" 2>/dev/null || true
  # check if already mounted
  if grep -qsE "^[^ ]+ ${target} " /proc/mounts; then
    _slog DEBUG "${target} já está montado"
    return 0
  fi
  if ! mount -t "${fstype}" -o "${opts}" "${src}" "${target}" >/dev/null 2>&1; then
    _slog WARN "Falha ao montar ${fstype} em ${target} (src=${src})"
    return 1
  fi
  _slog DEBUG "Montado ${fstype} em ${target}"
  return 0
}

_sandbox_umount_force() {
  local target="$1"
  if grep -qsE "^[^ ]+ ${target} " /proc/mounts; then
    for i in 1 2 3; do
      if umount "${target}" >/dev/null 2>&1; then
        return 0
      fi
      sleep 1
    done
    # lazy unmount as last resort
    umount -l "${target}" >/dev/null 2>&1 || true
  fi
  return 0
}

# -----------------------
# Setup root FS for session
# -----------------------
sandbox_mount_pseudofs() {
  local session_root="${_SANDBOX_SESSION}/root"
  # mount proc
  _sandbox_mount "${session_root}/proc" "proc" "proc" "nodev,noexec,nosuid"
  # mount sys
  _sandbox_mount "${session_root}/sys" "sysfs" "sysfs" "nodev,noexec,nosuid"
  # mount dev (devtmpfs if available)
  if mountpoint -q /dev; then
    _sandbox_mount "${session_root}/dev" "tmpfs" "tmpfs" "mode=0755,nosuid,nodev" || true
  else
    _slog WARN "Host não possui /dev montado de forma esperada"
  fi
  # create /run and /tmp as tmpfs
  _sandbox_mount "${session_root}/run" "tmpfs" "tmpfs" "mode=0755,nosuid,nodev" || true
  _sandbox_mount "${session_root}/tmp" "tmpfs" "tmpfs" "mode=1777,nosuid,nodev" || true
  return 0
}

sandbox_populate_root_minimal() {
  # Optionally copy minimal set of host files required (ld, sh, basic bins)
  # This is intentionally conservative; prefer bind mounts from host if needed.
  local session_root="${_SANDBOX_SESSION}/root"
  mkdir -p "${session_root}/bin" "${session_root}/usr/bin" "${session_root}/lib" "${session_root}/usr/lib" || true
  # No automatic copying to avoid polluting host; user should bind mount as needed.
  _slog DEBUG "Root minimal preparado em ${session_root}"
}

# -----------------------
# Enter sandbox: chroot preferred, fallback to unshare
# -----------------------
_sandbox_enter_chroot() {
  local session_root="${_SANDBOX_SESSION}/root"
  if ! command -v chroot >/dev/null 2>&1; then
    _slog WARN "chroot não disponível"
    return 2
  fi
  # Final safety checks
  _realpath_safe "${session_root}" >/dev/null 2>&1 || { _slog ERROR "Session root inválido"; return 1; }
  if [[ "$(id -u)" -ne 0 ]]; then
    _slog WARN "Entrar em chroot requer root; abortando chroot"
    return 3
  fi
  # chroot + exec a shell or command via chroot helper
  _slog INFO "Entrando em chroot: ${session_root}"
  CHROOT_CMD=(chroot "${session_root}")
  return 0
}

_sandbox_enter_unshare() {
  # fallback: use unshare to create namespace; requires util-linux with unshare
  if ! command -v unshare >/dev/null 2>&1; then
    _slog WARN "unshare não disponível"
    return 2
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    _slog WARN "unshare com namespaces UTS/PID/NS pode requerer root; tentando mesmo assim"
  fi
  _slog INFO "Usando unshare para isolar processo (fallback)"
  CHROOT_CMD=(unshare --mount --uts --ipc --net --pid --fork --mount-proc)
  return 0
}

# -----------------------
# Run a command inside sandbox
# -----------------------
_sandbox_run_internal() {
  local cmdline=("$@")
  local session_root="${_SANDBOX_SESSION}/root"
  local workdir="${_SANDBOX_SESSION}/work"
  local logbase="${_SANDBOX_SESSION}/logs/session"
  mkdir -p "${workdir}" "${_SANDBOX_SESSION}/logs" || true
  local logfile="${logbase}.log"
  _rotate_log_if_needed "${logfile}" || true

  # wrap command to run inside chroot/unshare
  if _sandbox_prerun_checks; then
    :
  fi

  local start_ts; start_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  _slog INFO "Executando em sandbox ${_SANDBOX_SESSION} (timeout=${SANDBOX_TIMEOUT_SECS}s): ${cmdline[*]}"
  # choose method: chroot or unshare
  local status=0
  if _sandbox_chroot_available; then
    # use chroot + su -s to drop to user if requested
    if [[ "$(id -u)" -eq 0 ]]; then
      # as root, chroot and run
      if command -v timeout >/dev/null 2>&1; then
        timeout --preserve-status "${SANDBOX_TIMEOUT_SECS}" chroot "${session_root}" /bin/sh -c "cd /work && ${cmdline[*]}"
      else
        chroot "${session_root}" /bin/sh -c "cd /work && ${cmdline[*]}"
      fi
      status=$?
    else
      _slog WARN "chroot disponível mas não executando como root — fallback para unshare"
      if command -v timeout >/dev/null 2>&1; then
        timeout --preserve-status "${SANDBOX_TIMEOUT_SECS}" unshare --mount --uts --ipc --net --pid --fork --mount-proc /bin/sh -c "cd ${workdir} && ${cmdline[*]}"
      else
        unshare --mount --uts --ipc --net --pid --fork --mount-proc /bin/sh -c "cd ${workdir} && ${cmdline[*]}"
      fi
      status=$?
    fi
  else
    # no chroot: try unshare
    if command -v timeout >/dev/null 2>&1; then
      timeout --preserve-status "${SANDBOX_TIMEOUT_SECS}" unshare --mount --uts --ipc --net --pid --fork --mount-proc /bin/sh -c "cd ${workdir} && ${cmdline[*]}"
    else
      unshare --mount --uts --ipc --net --pid --fork --mount-proc /bin/sh -c "cd ${workdir} && ${cmdline[*]}"
    fi
    status=$?
  fi

  local end_ts; end_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # write audit
  cat >> "${logfile}" <<EOF
[$start_ts - $end_ts] CMD: ${cmdline[*]} EXIT: ${status}
EOF

  if (( status != 0 )); then
    _slog ERROR "Comando retornou ${status}; ver logs: ${logfile}"
  else
    _slog INFO "Comando executado com sucesso; ver logs: ${logfile}"
  fi
  return "${status}"
}

# small helpers
_sandbox_chroot_available() {
  command -v chroot >/dev/null 2>&1 || return 1
  return 0
}

_sandbox_prerun_checks() {
  # ensure session exists and mounted
  [[ -n "${_SANDBOX_SESSION:-}" ]] || { _slog ERROR "Sessão não criada"; return 1; }
  [[ -d "${_SANDBOX_SESSION}/root" ]] || { _slog ERROR "Root da sessão inválido"; return 1; }
  return 0
}

# -----------------------
# High level run wrapper
# -----------------------
sandbox_run() {
  local cmd="${*:-}"
  if [[ -z "$cmd" ]]; then
    _slog ERROR "Uso: sandbox_run <comando>"
    return 2
  fi
  # ensure a session exists
  if [[ -z "${_SANDBOX_SESSION}" ]]; then
    sandbox_create || return 1
  fi
  # ensure pseudo filesystems are mounted
  sandbox_mount_pseudofs || _slog WARN "Falha ao montar pseudo-fs (continuando)"
  # populate minimal if needed
  sandbox_populate_root_minimal || true

  # execute
  _sandbox_run_internal "$cmd"
  return $?
}

# -----------------------
# Unmount and cleanup
# -----------------------
sandbox_unmount_all() {
  if [[ -z "${_SANDBOX_SESSION}" ]]; then
    _slog DEBUG "Nenhuma sessão ativa para desmontar"
    return 0
  fi
  local sroot="${_SANDBOX_SESSION}/root"
  _sandbox_umount_force "${sroot}/proc" || true
  _sandbox_umount_force "${sroot}/sys" || true
  _sandbox_umount_force "${sroot}/dev" || true
  _sandbox_umount_force "${sroot}/run" || true
  _sandbox_umount_force "${sroot}/tmp" || true
  _slog INFO "Desmontado pseudo-filesystems para sessão ${_SANDBOX_SESSION}"
  return 0
}

sandbox_cleanup() {
  # careful cleanup: do not rm -rf arbitrary paths
  if [[ -n "${_SANDBOX_SESSION}" && -d "${_SANDBOX_SESSION}" ]]; then
    sandbox_unmount_all || true
    # remove only within sessions dir
    rm -rf "${_SANDBOX_SESSION}" || true
    _slog INFO "Sessão ${_SANDBOX_SESSION} removida"
    unset _SANDBOX_SESSION
  fi
  _sandbox_lock_release || true
}

# -----------------------
# Status & summary
# -----------------------
sandbox_status() {
  if [[ -z "${_SANDBOX_SESSION}" ]]; then
    _slog INFO "Nenhuma sessão ativa"
    return 0
  fi
  _slog INFO "Sessão: ${_SANDBOX_SESSION}"
  if [[ -f "${_SANDBOX_SESSION}/meta" ]]; then
    cat "${_SANDBOX_SESSION}/meta"
  fi
  _slog INFO "Logs em: ${_SANDBOX_SESSION}/logs"
}

# -----------------------
# CLI
# -----------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  case "$cmd" in
    --init)
      sandbox_init && echo "Sandbox base inicializado em ${SANDBOX_ROOT}"
      exit $?
      ;;
    --create)
      sandbox_create && echo "Sessão criada: ${_SANDBOX_SESSION}"
      exit $?
      ;;
    --mount)
      sandbox_mount_pseudofs && echo "Pseudo-filesystems montados"
      exit $?
      ;;
    --enter)
      # open an interactive shell inside sandbox
      sandbox_create || exit 1
      sandbox_mount_pseudofs || true
      sandbox_populate_root_minimal || true
      if _sandbox_chroot_available && [[ "$(id -u)" -eq 0 ]]; then
        chroot "${_SANDBOX_SESSION}/root" /bin/sh -l
      else
        unshare --mount --uts --ipc --net --pid --fork --mount-proc /bin/sh -l
      fi
      sandbox_cleanup
      exit 0
      ;;
    --run)
      shift || true
      sandbox_run "$*" || exit $?
      exit $?
      ;;
    --cleanup)
      sandbox_cleanup
      exit 0
      ;;
    --status)
      sandbox_status
      exit 0
      ;;
    --help|-h|"")
      cat <<EOF
sandbox.sh - gerencia sandboxes para builds

Uso:
  sandbox.sh --init                Inicializa diretórios base (não cria sessão)
  sandbox.sh --create              Cria nova sessão sandbox
  sandbox.sh --mount               Monta pseudo-filesystems na sessão atual
  sandbox.sh --enter               Cria e entra em uma shell interativa dentro do sandbox
  sandbox.sh --run <cmd...>        Executa comando dentro do sandbox com timeout
  sandbox.sh --cleanup             Limpa sessão atual e desmonta
  sandbox.sh --status              Mostra status da sessão atual
  sandbox.sh --help

Variáveis de ambiente:
  SANDBOX_ROOT, SANDBOX_SESSION_DIR, SANDBOX_LOG_DIR, SANDBOX_TIMEOUT_SECS,
  SANDBOX_SILENT, SANDBOX_DEBUG

Nota: operações de mount e chroot exigem privilégios (root). O script fará checks e
avisos se não estiver rodando como root e tentará fallback para namespaces se possível.
EOF
      exit 0
      ;;
    *)
      echo "Comando inválido. Use --help"
      exit 2
      ;;
  esac
fi

# -----------------------
# Export API
# -----------------------
export -f sandbox_init sandbox_create sandbox_run sandbox_cleanup sandbox_status sandbox_mount_pseudofs sandbox_populate_root_minimal
