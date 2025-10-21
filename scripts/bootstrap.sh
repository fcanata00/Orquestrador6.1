#!/usr/bin/env bash
# bootstrap.sh - high level bootstrapper (uses the integrated scripts)
if [ -n "${BOOTSTRAP_SH_LOADED-}" ]; then return 0 2>/dev/null || exit 0; fi
BOOTSTRAP_SH_LOADED=1
: "${LFS_ROOT:=/mnt/lfs}"
: "${STAGES_DIR:=${LFS_ROOT}/meta/stages}"
: "${LOG_ROOT:=${LFS_ROOT}/build_logs}"
: "${BOOT_RETRY:=3}"
: "${BOOT_STRICT:=1}"
set -o errexit
set -o nounset
set -o pipefail

# load helpers
for f in register.sh core.sh metadata.sh download.sh deps.sh sandbox.sh build.sh; do
  if [ -f "./$f" ]; then source "./$f"; else echo "Missing $f" >&2; exit 2; fi
done

# preflight
preflight() {
  if [ "$(id -u)" -ne 0 ]; then log_fatal "bootstrap must be run as root"; fi
  for c in tar zstd sha256sum chroot; do command -v "$c" >/dev/null 2>&1 || log_warn "Missing $c - may fail"; done
  mkdir -p "${LFS_ROOT}" "${STAGES_DIR}" "${LOG_ROOT}" 2>/dev/null || true
}

_read_stage_list() {
  local stage="$1" listf="${STAGES_DIR}/${stage}.list"
  [ -f "$listf" ] || { log_error "Stage list $listf not found"; return 2; }
  mapfile -t LIST < "$listf"
  local tmp=()
  for l in "${LIST[@]}"; do l="${l%%#*}"; l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"; [ -z "$l" ] && continue; tmp+=("$l"); done
  LIST=("${tmp[@]}")
}

_run_pkg() {
  local meta="$1" idx="$2" total="$3"
  printf "%s" "(${idx}/${total}) ${meta} ... "
  local logdir="${LOG_ROOT}/${meta%/*}/$(basename "${meta%.ini}")"
  mkdir -p "$logdir" 2>/dev/null || true
  local attempt=0 rc=0
  while [ $attempt -lt $BOOT_RETRY ]; do
    attempt=$((attempt+1))
    if build_pipeline "$meta" > "${logdir}/build.log.tmp" 2>&1; then
      mv -f "${logdir}/build.log.tmp" "${logdir}/build.log"
      printf "%b\n" "${C_OK}OK${C_RST}"
      return 0
    else
      rc=$?
      mv -f "${logdir}/build.log.tmp" "${logdir}/build.log" 2>/dev/null || true
      printf "%b\n" "${C_ERR}FAILED${C_RST}"
      log_error "Package ${meta} failed (attempt ${attempt}) - log: ${logdir}/build.log"
      tail -n 50 "${logdir}/build.log" | sed 's/^/    /'
      if [ $attempt -lt $BOOT_RETRY ]; then log_info "Retrying..."; sleep 1; continue; fi
      if [ "$BOOT_STRICT" -eq 1 ]; then return $rc; else log_warn "Continuing despite failure"; return $rc; fi
    fi
  done
  return $rc
}

bootstrap_stage() {
  local stage="$1"
  _read_stage_list "$stage" || return 2
  local total=${#LIST[@]} i=0
  log_info "Starting stage $stage with ${total} packages"
  sandbox_mount "${LFS_ROOT}" || { log_error "sandbox mount failed"; return 2; }
  for m in "${LIST[@]}"; do
    i=$((i+1))
    # support meta paths under LFS_ROOT
    local meta="$m"
    if [ ! -f "$meta" ] && [ -f "${LFS_ROOT}/${m}" ]; then meta="${LFS_ROOT}/${m}"; fi
    _run_pkg "$meta" "$i" "$total" || { log_error "Build failed for $meta"; if [ "$BOOT_STRICT" -eq 1 ]; then sandbox_umount "${LFS_ROOT}"; return 1; fi; }
  done
  if [ "$stage" = "stage1" ]; then
    # quick test
    if ! sandbox_exec "${LFS_ROOT}" "bash -lc 'gcc --version >/dev/null 2>&1'"; then log_warn "Toolchain quick test failed"; fi
  fi
  _package_rootfs() {
    local outdir="${LFS_ROOT}/cache"; mkdir -p "$outdir"; local ts; ts=$(date +%Y%m%d%H%M%S); local out="${outdir}/${stage}-rootfs-${ts}.tar.zst"
    tar -C "${LFS_ROOT}" -cf - . | zstd -T0 -o "${out}" || log_warn "rootfs packaging failed"
    log_ok "Rootfs: ${out}"
  }
  _package_rootfs
  sandbox_umount "${LFS_ROOT}"
  log_ok "Stage $stage completed"
  return 0
}

# CLI
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  preflight
  stage="${1:-stage1}"
  bootstrap_stage "$stage"
fi
