#!/usr/bin/env bash
# bootstrap.sh - prepare /mnt/lfs and optionally run bootstrap pipeline
set -eEuo pipefail; IFS=$'\n\t'
LFS="${LFS:-/mnt/lfs}"; SCRIPTS_DIR="${SCRIPTS_DIR:-/usr/bin}"; DRY_RUN=false; VERBOSE=false; AUTO=false
for a in "$@"; do case "$a" in --dry-run) DRY_RUN=true;; --auto) AUTO=true;; --verbose) VERBOSE=true;; esac; done
source "$SCRIPTS_DIR/utils.sh"
log_info "Starting bootstrap (LFS=$LFS)"
ensure_dir "$LFS"
# create structure
for d in "$LFS"/{tools,sources,build,logs,cache,packages,temp,home}; do ensure_dir "$d"; done
# create user lfs if missing
if ! id lfs >/dev/null 2>&1; then if [ "$DRY_RUN" = true ]; then log_info "DRY-RUN create user lfs"; else groupadd -r lfs || true; useradd -m -d "$LFS/home/lfs" -s /bin/bash -g lfs lfs || true; fi; fi
# mount pseudo filesystems
if [ "$DRY_RUN" = false ]; then mount --bind /dev "$LFS/dev" || true; mount -t proc proc "$LFS/proc" || true; mount --rbind /sys "$LFS/sys" || true; mount --bind /run "$LFS/run" || true; fi
log_info "Bootstrap environment prepared under $LFS"
# optionally run minimal toolchain build list
if [ "$AUTO" = true ]; then log_info "AUTO bootstrap: building toolchain packages (binutils,gcc,glibc)"; /usr/bin/lfsctl build binutils gcc glibc; fi
