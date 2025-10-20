#!/usr/bin/env bash
# build.sh - build packages from metafile or package name
set -eEuo pipefail; IFS=$'\n\t'
SCRIPTS_DIR="${SCRIPTS_DIR:-/usr/bin}"; source "$SCRIPTS_DIR/utils.sh"
PARALLEL=false; PARALLEL_N=""; REPORT=false; REQUIRE_CHECKSUM=false; RESUME=false
# parse flags
while [[ $# -gt 0 ]]; do case "$1" in --parallel) PARALLEL=true; PARALLEL_N=""; shift;; --parallel=*) PARALLEL=true; PARALLEL_N="${1#*=}"; shift;; --report) REPORT=true; shift;; --require-checksum) REQUIRE_CHECKSUM=true; shift;; --resume) RESUME=true; shift;; --dry-run) DRY_RUN=true; shift;; --verbose) VERBOSE=true; shift;; --help) echo "build.sh [--parallel[=N]] [--report] <pkg|meta.ini>..."; exit 0;; *) break;; esac; done
if [ "$#" -lt 1 ]; then echo "usage: build.sh [options] <meta.ini|pkgname>..."; exit 2; fi

start_time=$(date +%s)
results=()

for t in "$@"; do
  if [ -f "$t" ]; then meta="$t"; else meta="$(find "$META_ROOT" -type f -name "$(basename "$t").ini" | head -n1 || true)"; fi
  if [ -z "$meta" ]; then log_error "metafile for $t not found"; results+=("$t:missing"); continue; fi
  parse_ini "$meta"; name="$(ini_get meta name $(basename "$meta" .ini))"; ver="$(ini_get meta version "0.0.0")"
  log_info "Building $name version $ver"
  work="$SOURCES_DIR/$name-$ver"
  ensure_dir "$work"
  download_from_meta "$meta" "$work"
  # verify checksum if requested
  ssha="$(ini_get source sha256)"
  if [ "$REQUIRE_CHECKSUM" = true ] || [ "$REQUIRE_CHECKSUM" = "true" ]; then
    if [ -n "$ssha" ]; then f="$work/$(ls "$work" | head -n1 2>/dev/null)"; verify_checksum "$f" "$ssha" || { log_error "checksum failed for $name"; results+=("$name:checksum_failed"); continue; }
    else log_warn "no sha in meta for $name"; fi
  fi
  # extract + build
  a="$(ls "$work" 2>/dev/null | head -n1 || true)"
  if [ -n "$a" ]; then mkdir -p "$work/exp"; af="$work/$a"; if tar -tf "$af" >/dev/null 2>&1; then tar -xf "$af" -C "$work/exp"; fi; fi
  run_hooks "$(dirname "$meta")" pre-build || log_warn "pre-build hooks failed"
  srcroot="$(find "$work/exp" -maxdepth 2 -type d | head -n1 || true)"
  if [ -z "$srcroot" ]; then log_warn "no source root for $name"; run_hooks "$(dirname "$meta")" post-build; results+=("$name:skipped"); continue; fi
  pushd "$srcroot" >/dev/null
  if [ -f configure ]; then
    cfg="./configure --prefix=/usr"
    eval $cfg || log_warn "configure issues for $name"
    if [ "$PARALLEL" = true ]; then
      n="${PARALLEL_N:-$(nproc)}"
      make -j${n} || { log_error "make failed for $name"; results+=("$name:make_failed"); popd >/dev/null; continue; }
    else
      make || { log_error "make failed for $name"; results+=("$name:make_failed"); popd >/dev/null; continue; }
    fi
    make DESTDIR="$LFS" install || log_warn "make install warnings for $name"
  else
    log_warn "no configure; skipping build for $name"
  fi
  popd >/dev/null
  run_hooks "$(dirname "$meta")" post-build || log_warn "post-build hooks failed"
  results+=("$name:ok")
  log_info "Built $name"
done

end_time=$(date +%s)
dur=$((end_time-start_time))
# generate report
if [ "$REPORT" = true ]; then
  rpt="/var/log/lfsctl/build_report_$(date -u +%Y%m%dT%H%M%SZ).txt"
  jsonr="/var/log/lfsctl/build_report_$(date -u +%Y%m%dT%H%M%SZ).json"
  mkdir -p "$(dirname "$rpt")"
  echo "build report - $(date -u)" > "$rpt"
  echo "duration_seconds: $dur" >> "$rpt"
  echo "results:" >> "$rpt"
  for r in "${results[@]}"; do echo "  - $r" >> "$rpt"; done
  # write json using python3 if available
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<PYJSON > "$jsonr"
import json,sys
data = {"timestamp": "%s", "duration": %d, "results": %s}
print(json.dumps(data, indent=2))
PYJSON
  fi
  log_info "Report written: $rpt and $jsonr"
fi
