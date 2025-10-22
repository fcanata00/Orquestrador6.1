#!/usr/bin/env bash
# sandbox.sh - Cria e gerencia sandboxes seguros para builds LFS
# Versão: 1.0
# Requisitos: bash 4+, coreutils, util-linux (unshare, nsenter), mount, tar, rsync (fallback), prlimit (from util-linux)
# Se disponível: bubblewrap (bwrap), systemd-run, cgroup v2
set -Eeuo pipefail

# ========== Configurações (variáveis ajustáveis) ==========
: "${SANDBOX_BASE_DIR:=/var/tmp/lfs-sandbox}"
: "${SANDBOX_OVERLAY_BASE:=/var/lib/lfs/sandbox-base}"
: "${SANDBOX_CACHE_BIND:=/var/cache/lfs-sources}"
: "${SANDBOX_USE_USERNS:=auto}"    # auto|force|disable
: "${SANDBOX_ALLOW_NETWORK:=false}" # default safe: no network
: "${SANDBOX_TIMEOUT:=3600}"       # default 1 hour
: "${SANDBOX_CPUS:=0}"             # 0 -> no explicit cpu limit, else number of cpus
: "${SANDBOX_MEM_MB:=0}"           # 0 -> no explicit memory limit
: "${SANDBOX_CGROUPS:=auto}"       # auto|force|disable
: "${SANDBOX_PERSISTENT:=false}"   # keep upperdir after destroy
: "${SILENT_ERRORS:=false}"
: "${ABORT_ON_ERROR:=true}"
: "${LOG_SCRIPT:=/usr/bin/logs.sh}"
: "${UTILS_SCRIPT:=/usr/bin/utils.sh}"

export SANDBOX_BASE_DIR SANDBOX_OVERLAY_BASE SANDBOX_CACHE_BIND SANDBOX_USE_USERNS SANDBOX_ALLOW_NETWORK SANDBOX_TIMEOUT SANDBOX_CPUS SANDBOX_MEM_MB SANDBOX_CGROUPS SANDBOX_PERSISTENT SILENT_ERRORS ABORT_ON_ERROR LOG_SCRIPT UTILS_SCRIPT

# ========== Try to source log and utils if available ==========
LOG_API_READY=false
if [ -f "$LOG_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$LOG_SCRIPT" || true
  LOG_API_READY=true
fi
if [ -f "$UTILS_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$UTILS_SCRIPT" || true
fi

# ========== Logging helpers ==========
_sb_info(){ if [ "$LOG_API_READY" = true ] && type log_info >/dev/null 2>&1; then log_info "$@"; else printf "[SB][INFO] %s\n" "$@"; fi }
_sb_warn(){ if [ "$LOG_API_READY" = true ] && type log_warn >/dev/null 2>&1; then log_warn "$@"; else printf "[SB][WARN] %s\n" "$@"; fi }
_sb_error(){ if [ "$LOG_API_READY" = true ] && type log_error >/dev/null 2>&1; then log_error "$@"; else printf "[SB][ERROR] %s\n" "$@" >&2; fi; if [ "${SILENT_ERRORS}" = "true" ]; then return 1; fi; if [ "${ABORT_ON_ERROR}" = "true" ]; then exit 1; fi; return 1; }

# ========== Helpers ==========
_safe_mkdir(){ mkdir -p "$1" 2>/dev/null || _sb_error "failed to mkdir $1"; }
_safe_rmdir(){ rm -rf "$1" 2>/dev/null || _sb_warn "failed to remove $1"; }

# Check features
_has_bwrap(){ command -v bwrap >/dev/null 2>&1; }
_has_unshare(){ command -v unshare >/dev/null 2>&1; }
_has_prlimit(){ command -v prlimit >/dev/null 2>&1; }
_has_rsync(){ command -v rsync >/dev/null 2>&1; }
_has_systemd_run(){ command -v systemd-run >/dev/null 2>&1; }

# Kernel features
_supports_userns(){
  case "$SANDBOX_USE_USERNS" in
    disable) return 1;;
    force) command -v unshare >/dev/null 2>&1 || return 1; unshare -U true >/dev/null 2>&1 || return 1; return 0;;
    *) # auto
       if command -v unshare >/dev/null 2>&1; then
         unshare -U true >/dev/null 2>&1 && return 0 || return 1
       else
         return 1
       fi;;
  esac
}

_supports_overlay(){
  # check if overlayfs supported by kernel
  grep -Eiq overlay /proc/filesystems 2>/dev/null || return 1
  return 0
}

_supports_cgroupv2(){
  [ -f /sys/fs/cgroup/cgroup.controllers ] && return 0 || return 1
}

# Unique sandbox id generator
_sb_id_new(){
  local pkg="$1"
  printf "%s-%s-%s" "${pkg//[^a-zA-Z0-9_.-]/_}" "$(date +%Y%m%d%H%M%S)" "$BASHPID"
}

# Path helpers
_sb_paths(){
  # returns path variables: base workdir, upper, work, merged, log
  local id="$1"
  echo "${SANDBOX_BASE_DIR}/${id}"
}

# ========== Initialize base directories ==========
sb_init(){
  _safe_mkdir "$SANDBOX_BASE_DIR"
  _safe_mkdir "$SANDBOX_OVERLAY_BASE"
  _safe_mkdir "$(dirname "$SANDBOX_CACHE_BIND")"
  _sb_info "Sandbox base initialized: $SANDBOX_BASE_DIR (overlay-base: $SANDBOX_OVERLAY_BASE)"
  return 0
}

# ========== Create sandbox ==========
# returns sandbox_id (echo)
sb_create(){
  local pkg="$1"; shift || true
  local mode="restricted"; local mount_cache="yes"; local ro_base=""
  # parse flags
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) mode="$2"; shift 2;;
      --mount-cache) mount_cache="$2"; shift 2;;
      --ro-base) ro_base="$2"; shift 2;;
      *) shift;;
    esac
  done
  if [ -z "$pkg" ]; then _sb_error "sb_create requires <pkg>"; return 1; fi
  sb_init || true
  local id; id=$(_sb_id_new "$pkg")
  local base=$(_sb_paths "$id")
  local upper="$base/upper"; local work="$base/work"; local merged="$base/merged"; local log="$base/sb.log"
  _safe_mkdir "$upper" "$work" "$merged" "$(dirname "$log")"
  touch "$log"
  # mount overlay if supported and ro_base provided
  if [ -n "$ro_base" ] && _supports_overlay; then
    _sb_info "Creating overlay with ro_base=$ro_base for $id"
    mount -t overlay overlay -o lowerdir="$ro_base",upperdir="$upper",workdir="$work" "$merged" 2>>"$log" || { _sb_warn "overlay mount failed; fallback to rsync copy"; _fallback_rsync "$ro_base" "$merged" "$log"; }
  elif _supports_overlay && [ -d "$SANDBOX_OVERLAY_BASE" ]; then
    # use overlay base if exists
    _sb_info "Using overlay base $SANDBOX_OVERLAY_BASE"
    mount -t overlay overlay -o lowerdir="$SANDBOX_OVERLAY_BASE",upperdir="$upper",workdir="$work" "$merged" 2>>"$log" || { _sb_warn "overlay mount failed; using tmpfs fallback"; _fallback_rsync "$SANDBOX_OVERLAY_BASE" "$merged" "$log"; }
  else
    # fallback copy into merged (tmpfs or dir)
    _sb_warn "Overlay not supported; using rsync fallback for $id"
    _fallback_rsync "$SANDBOX_OVERLAY_BASE" "$merged" "$log"
  fi
  # bind cache if requested
  if [ "$mount_cache" = "yes" ] && [ -d "$SANDBOX_CACHE_BIND" ]; then
    _sb_info "Binding cache $SANDBOX_CACHE_BIND into $merged/sources"
    _safe_mkdir "$merged/sources"
    mount --bind "$SANDBOX_CACHE_BIND" "$merged/sources" 2>>"$log" || _sb_warn "bind mount cache failed"
  fi
  # basic mounts
  mount --bind /dev "$merged/dev" 2>>"$log" || _sb_warn "bind /dev failed"
  mount -t devpts devpts "$merged/dev/pts" 2>>"$log" || true
  mount -t proc proc "$merged/proc" 2>>"$log" || _sb_warn "mount proc failed"
  mount -t sysfs sysfs "$merged/sys" 2>>"$log" || _sb_warn "mount sys failed"
  # minimal /etc resolv.conf if network disabled
  if [ "${SANDBOX_ALLOW_NETWORK}" != "true" ]; then
    : > "$merged/etc/resolv.conf" 2>/dev/null || true
  fi
  # record metadata
  echo "id=$id" > "$base/meta"
  echo "pkg=$pkg" >> "$base/meta"
  echo "mode=$mode" >> "$base/meta"
  echo "created=$(date -u +%FT%TZ)" >> "$base/meta"
  echo "merged=$merged" >> "$base/meta"
  echo "log=$log" >> "$base/meta"
  _sb_info "Sandbox created: $id (merged: $merged)"
  echo "$id"
}

# fallback rsync copy for when overlay not supported
_fallback_rsync(){
  local src="$1"; local dest="$2"; local log="$3"
  _safe_mkdir "$dest"
  if [ -d "$src" ] && _has_rsync; then
    rsync -aH --numeric-ids --delete "$src"/ "$dest"/ >>"$log" 2>&1 || _sb_warn "rsync copy had warnings"
  else
    # empty skeleton
    mkdir -p "$dest"/{bin,usr,lib,lib64,dev,proc,sys,tmp,build,sources} 2>/dev/null || true
  fi
}

# ========== Enter sandbox and run command ==========
# sb_enter <id> -- cmd...
sb_enter(){
  local id="$1"; shift || true
  if [ -z "$id" ]; then _sb_error "sb_enter requires sandbox id"; return 1; fi
  # load metadata
  local base="${SANDBOX_BASE_DIR}/${id}"; local meta="$base/meta"
  if [ ! -f "$meta" ]; then _sb_error "sandbox metadata not found for $id"; return 2; fi
  local merged; merged=$(grep '^merged=' "$meta" | cut -d= -f2-)
  local log; log=$(grep '^log=' "$meta" | cut -d= -f2-)
  local cmd=("$@")
  if [ "${#cmd[@]}" -eq 0 ]; then _sb_error "No command provided to sb_enter"; return 1; fi
  _sb_info "Entering sandbox $id to run: ${cmd[*]}"
  # create a small wrapper script inside merged to execute the command and collect resource usage
  local runner="$base/runner.sh"
  cat > "$runner" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
TS_START=$(date +%s)
exec "$@"
EOF
  chmod +x "$runner"
  # choose execution method: prefer bwrap if available (safer), else unshare+chroot
  if _has_bwrap; then
    _sb_info "Using bubblewrap (bwrap) to run inside sandbox"
    local bargs=(--unshare-all --die-with-parent --proc /proc --dev /dev)
    if [ "${SANDBOX_ALLOW_NETWORK}" != "true" ]; then
      bargs+=(--unshare-net)
    fi
    bargs+=(--bind "$merged" /)
    if [ -d "$merged/sources" ]; then bargs+=(--ro-bind "$merged/sources" /sources); fi
    if _has_prlimit && { [ "$SANDBOX_TIMEOUT" -gt 0 ] || [ "$SANDBOX_MEM_MB" -gt 0 ] || [ "$SANDBOX_CPUS" -gt 0 ]; }; then
      local prargs=()
      [ "$SANDBOX_TIMEOUT" -gt 0 ] && prargs+=(--cpu="$SANDBOX_TIMEOUT")
      [ "$SANDBOX_MEM_MB" -gt 0 ] && prargs+=(--as=$((SANDBOX_MEM_MB*1024*1024)))
      _sb_info "Applying prlimit ($prargs) for command"
      prlimit "${prargs[@]}" -- bwrap "${bargs[@]}" -- "$@"
      return $?
    else
      bwrap "${bargs[@]}" -- "$@"
      return $?
    fi
  fi

  if _has_unshare; then
    _sb_info "Using unshare+chroot fallback to run inside sandbox"
    local nsargs=(--fork --pid --mount --ipc --uts)
    if [ "${SANDBOX_ALLOW_NETWORK}" != "true" ]; then nsargs+=(--net); fi
    unshare "${nsargs[@]}" -- bash -c '
      set -Eeuo pipefail
      mount -t proc proc "'"$merged"'/proc" >/dev/null 2>&1 || true
      mount -t sysfs sysfs "'"$merged"'/sys" >/dev/null 2>&1 || true
      chroot "'"$merged"'" "'"${cmd[0]}"'" "${cmd[@]:1}"
    '
    return $?
  fi

  _sb_error "No supported sandbox runtime available (bwrap or unshare required)"
  return 2
}

# ========== Mount bind helper ==========
sb_mount_bind(){
  local id="$1"; local hostpath="$2"; local target="$3"; local mode="${4:-ro}"
  if [ -z "$id" ] || [ -z "$hostpath" ] || [ -z "$target" ]; then _sb_error "Usage: sb_mount_bind <id> <hostpath> <target> [ro|rw]"; return 1; fi
  local base="${SANDBOX_BASE_DIR}/${id}"; local merged; merged=$(grep '^merged=' "$base/meta" | cut -d= -f2-)
  _safe_mkdir "$merged/$target"
  if [ "$mode" = "ro" ]; then
    mount --bind "$hostpath" "$merged/$target" 2>>"$base/sb.log" || _sb_error "bind failed"
    mount -o remount,ro,bind "$merged/$target" 2>>"$base/sb.log" || _sb_warn "remount ro failed"
  else
    mount --bind "$hostpath" "$merged/$target" 2>>"$base/sb.log" || _sb_error "bind failed"
  fi
  _sb_info "Mounted $hostpath -> $merged/$target ($mode)"
  return 0
}

# ========== Unmount and destroy ==========
_sb_umount_all(){
  local base="$1"; local log="$base/sb.log"; local merged="$base/merged"
  set +e
  umount -l "$merged/proc" 2>>"$log" || true
  umount -l "$merged/sys" 2>>"$log" || true
  umount -l "$merged/dev/pts" 2>>"$log" || true
  umount -l "$merged/dev" 2>>"$log" || true
  if mountpoint -q "$merged/sources"; then umount -l "$merged/sources" 2>>"$log" || true; fi
  umount -l "$merged" 2>>"$log" || true
  set -e
}

sb_unmount_all(){
  local id="$1"
  local base="${SANDBOX_BASE_DIR}/${id}"
  if [ ! -d "$base" ]; then _sb_warn "No sandbox base for $id"; return 0; fi
  _sb_info "Unmounting sandbox $id"
  _sb_umount_all "$base"
  return 0
}

sb_destroy(){
  local id="$1"
  local base="${SANDBOX_BASE_DIR}/${id}"
  if [ ! -d "$base" ]; then _sb_warn "No sandbox base for $id"; return 0; fi
  sb_unmount_all "$id"
  if [ "${SANDBOX_PERSISTENT}" = "true" ]; then
    _sb_info "Persistent mode: keeping upperdir for $id at $base"
    return 0
  fi
  _safe_rmdir "$base"
  _sb_info "Sandbox $id destroyed and cleaned"
  return 0
}

# ========== Snapshot (basic via rsync hardlink strategy) ==========
sb_snapshot(){
  local id="$1"; local name="$2"
  if [ -z "$id" ] || [ -z "$name" ]; then _sb_error "sb_snapshot <id> <name>"; return 1; fi
  local base="${SANDBOX_BASE_DIR}/${id}"; local merged="$base/merged"; local snaps="$base/snapshots"
  _safe_mkdir "$snaps"
  if _has_rsync; then
    rsync -aH --numeric-ids --link-dest="$merged" "$merged"/ "$snaps/$name" || _sb_error "snapshot failed"
  else
    tar -C "$merged" -cf "$snaps/$name.tar" . || _sb_error "snapshot via tar failed"
  fi
  _sb_info "Snapshot $name created for $id"
  return 0
}

sb_restore(){
  local id="$1"; local name="$2"
  local base="${SANDBOX_BASE_DIR}/${id}"; local merged="$base/merged"; local snaps="$base/snapshots"
  if [ -d "$snaps/$name" ]; then
    rsync -aH --numeric-ids --delete "$snaps/$name"/ "$merged"/ || _sb_error "restore rsync failed"
  elif [ -f "$snaps/$name.tar" ]; then
    tar -C "$merged" -xf "$snaps/$name.tar" || _sb_error "restore tar failed"
  else
    _sb_error "snapshot not found: $name"
  fi
  _sb_info "Snapshot $name restored for $id"
  return 0
}

# ========== Status ==========
sb_status(){
  local id="$1"
  local base="${SANDBOX_BASE_DIR}/${id}"; local meta="$base/meta"
  if [ ! -f "$meta" ]; then _sb_error "Sandbox $id not found"; return 2; fi
  cat "$meta"
  mount | grep "$base" || true
  ps -ef | grep "$base" || true
  return 0
}

# ========== Self-test ==========
sb_self_test(){
  _sb_info "Running sandbox self-test..."
  sb_init
  local id; id=$(sb_create "sb-selftest" --mode build --mount-cache no)
  _sb_info "Created sandbox: $id"
  sb_enter "$id" -- /bin/sh -c 'echo hello; ls -la /'
  local rc=$?
  sb_destroy "$id"
  if [ $rc -eq 0 ]; then _sb_info "self-test passed"; else _sb_warn "self-test returned $rc"; fi
  return $rc
}

# ========== Usage ==========
_sb_usage(){
  cat <<EOF
Usage: sandbox.sh <command> [args...]
Commands:
  --ini                    Initialize sandbox base dirs
  create <pkg> [--mode MODE] [--mount-cache yes|no] [--ro-base PATH]  Create sandbox and print id
  enter <id> -- <cmd...>   Enter sandbox and run command (use -- to pass command)
  mount <id> <host> <target> [ro|rw]  Bind-mount host path into sandbox
  unmount <id>             Unmount all and cleanup mounts
  destroy <id>             Destroy sandbox (and remove files unless persistent)
  snapshot <id> <name>     Create snapshot of sandbox
  restore <id> <name>      Restore snapshot
  status <id>              Show sandbox status
  self-test                Run internal self-test
  help
EOF
}

if [ "${BASH_SOURCE[0]}" == "$0" ]; then
  case "${1:-}" in
    --ini) sb_init; exit $?;;
    create) shift; id=$(sb_create "$@"); echo "$id"; exit $?;;
    enter) shift; sb_enter "$@"; exit $?;;
    mount) shift; sb_mount_bind "$@"; exit $?;;
    unmount) shift; sb_unmount_all "$1"; exit $?;;
    destroy) shift; sb_destroy "$1"; exit $?;;
    snapshot) shift; sb_snapshot "$@"; exit $?;;
    restore) shift; sb_restore "$@"; exit $?;;
    status) shift; sb_status "$1"; exit $?;;
    self-test) sb_self_test; exit $?;;
    help|--help|-h) _sb_usage; exit 0;;
    *) _sb_usage; exit 2;;
  esac
fi

export -f sb_init sb_create sb_enter sb_mount_bind sb_unmount_all sb_destroy sb_snapshot sb_restore sb_status sb_self_test
