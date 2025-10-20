#!/usr/bin/env bash
set -eEuo pipefail; IFS=$'\n\t'
SCRIPTS_DIR="${SCRIPTS_DIR:-/usr/bin}"; source "$SCRIPTS_DIR/utils.sh"
AUTO=false; DRY=false
for a in "$@"; do case "$a" in --auto) AUTO=true;; --dry-run) DRY=true; DRY_RUN=true;; --repair) log_info "repair mode";; esac; done
log_info "Preparing LFS at $LFS"
ensure_dir "$LFS"
for d in "$LFS"/tools "$LFS"/sources "$LFS"/build "$LFS"/logs "$LFS"/cache "$LFS"/packages "$LFS"/temp "$LFS"/home; do ensure_dir "$d"; done
if [ "$DRY" = false ]; then mount --bind /dev "$LFS/dev" || true; mount -t proc proc "$LFS/proc" || true; mount --rbind /sys "$LFS/sys" || true; mount --bind /run "$LFS/run" || true; fi
log_info "Bootstrap environment ready"
if [ "$AUTO" = true ]; then log_info "AUTO: building toolchain (binutils,gcc,glibc)"; /usr/bin/lfsctl build binutils gcc glibc; fi
