#!/usr/bin/env bash
set -euo pipefail; IFS=$'\n\t'
mode="${1:-bootstrap}"; shift || true
case "$mode" in
  bootstrap)
    sudo /usr/bin/bootstrap.sh --auto "$@"
    ;;
  system)
    sudo /usr/bin/bootstrap.sh --auto "$@"
    for meta in $(find "${META_ROOT:-$HOME/lfs-sandbox/meta/bootstrap}" -type f -name '*.ini' 2>/dev/null); do
      sudo /usr/bin/build.sh --parallel --report "$meta" || { echo "build failed: $meta"; exit 1; }
      sudo /usr/bin/install.sh "$meta" || { echo "install failed: $meta"; exit 1; }
    done
    ;;
  *) echo "unknown pipeline: $mode"; exit 2;;
esac
