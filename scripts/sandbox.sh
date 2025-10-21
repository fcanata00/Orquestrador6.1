#!/usr/bin/env bash
# sandbox.sh - mandatory sandbox/chroot helper for LFS builds
if [ -n "${SANDBOX_SH_LOADED-}" ]; then return 0 2>/dev/null || exit 0; fi
SANDBOX_SH_LOADED=1
: "${LFS_ROOT:=/mnt/lfs}"

sandbox_mount() {
  local root="$1"
  [ -d "$root" ] || { log_error "sandbox_mount: root $root missing"; return 2; }
  log_info "Mounting sandbox for $root"
  for d in dev dev/pts proc sys run; do mkdir -p "$root/$d" 2>/dev/null || true; done
  mount --bind /dev "$root/dev" || log_warn "bind /dev failed"
  mount --bind /dev/pts "$root/dev/pts" || true
  mount -t proc proc "$root/proc" || true
  mount -t sysfs sysfs "$root/sys" || true
  mount -t tmpfs tmpfs "$root/run" || true
  # bind resolv
  if [ -f /etc/resolv.conf ]; then
    mkdir -p "$root/etc"
    mount --bind /etc/resolv.conf "$root/etc/resolv.conf" || true
  fi
  # minimal passwd/group for chroot to work
  if [ ! -f "$root/etc/passwd" ]; then
    printf "root:x:0:0:root:/root:/bin/bash\n" > "$root/etc/passwd"
  fi
  if [ ! -f "$root/etc/group" ]; then
    printf "root:x:0:\n" > "$root/etc/group"
  fi
  return 0
}

sandbox_exec() {
  local root="$1"; shift
  if [ ! -d "$root" ]; then log_error "sandbox_exec: root missing"; return 2; fi
  chroot "$root" /usr/bin/env -i PATH=/usr/bin:/bin:/tools/bin TERM="$TERM" HOME=/root /bin/bash -lc "$*"
}

sandbox_umount() {
  local root="$1"
  log_info "Unmounting sandbox for $root"
  umount -l "$root/dev/pts" 2>/dev/null || true
  umount -l "$root/dev" 2>/dev/null || true
  umount -l "$root/proc" 2>/dev/null || true
  umount -l "$root/sys" 2>/dev/null || true
  umount -l "$root/run" 2>/dev/null || true
  return 0
}
