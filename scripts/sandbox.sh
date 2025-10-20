#!/usr/bin/env bash
set -euo pipefail; IFS=$'\n\t'
LFS="${LFS:-/mnt/lfs}"; CMD="$*"
if [ -z "$CMD" ]; then echo "Usage: sandbox.sh <command...>"; exit 2; fi
# run command inside chroot if available
if [ -d "$LFS" ] && mountpoint -q "$LFS/proc"; then chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$TERM" PATH=/usr/bin:/bin:/usr/sbin:/sbin:/tools/bin $CMD; else echo "Sandbox not ready"; exit 3; fi
