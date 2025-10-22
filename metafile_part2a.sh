# ==== PART 2A/3 ====
            ;;
    esac
    register_info "Build step completed"
    return 0
}

# check step
mf_check() {
    local wd="${BUILD_DIR:-}"
    local cmd="${MF_BUILD_CHECK:-}"
    if [[ -z "${cmd}" ]]; then
        register_info "No check step defined"
        return 0
    fi
    register_info "Running check: ${cmd}"
    utils_run_cmd "cd '${wd}' && ${cmd}" --capture-output || { register_warn "Check failed"; return 0; }
    register_info "Check succeeded"
    return 0
}

# install step
mf_install() {
    local dest="${1:-${LFS}}"
    local wd="${BUILD_DIR:-}"
    if [[ -z "${wd}" ]]; then
        register_error "BUILD_DIR not set; run mf_prepare_build first"
        return 8
    fi
    mkdir -p "${dest}"
    local bs="$(_mf_detect_build_system "${wd}")"
    case "${bs}" in
        autotools|make|cmake)
            local inst="${MF_BUILD_INSTALL:-make install DESTDIR=${dest}}"
            register_info "Installing with: ${inst}"
            utils_run_cmd "cd '${wd}' && ${inst}" --capture-output || return 8
            ;;
        cargo)
            local inst="${MF_BUILD_INSTALL:-cargo install --root '${dest}' --path .}"
            register_info "Installing (cargo): ${inst}"
            utils_run_cmd "cd '${wd}' && ${inst}" --capture-output || return 8
            ;;
        python)
            local inst="${MF_BUILD_INSTALL:-python -m pip install --prefix='${dest}' .}"
            register_info "Installing (python): ${inst}"
            utils_run_cmd "cd '${wd}' && ${inst}" --capture-output || return 8
            ;;
        node)
            local inst="${MF_BUILD_INSTALL:-npm install --prefix '${dest}'}"
            register_info "Installing (node): ${inst}"
            utils_run_cmd "cd '${wd}' && ${inst}" --capture-output || return 8
            ;;
        *)
            if [[ -n "${MF_BUILD_INSTALL}" ]]; then
                utils_run_cmd "cd '${wd}' && ${MF_BUILD_INSTALL}" --capture-output || return 8
            else
                register_warn "No install command; skipping install"
            fi
            ;;
    esac

# create manifest of installed files
    local manifest_dir="${LFS}/var/lib/lfs-packages"
    mkdir -p "${manifest_dir}"
    local manifest="${manifest_dir}/${MF_NAME}-${MF_VERSION}.files"
    if command -v find >/dev/null 2>&1; then
        (cd "${dest}" && find . -type f | sed 's|^\./||') > "${manifest}" || true
    fi
    register_info "Installation completed; manifest at ${manifest}"
    return 0
}

# build orchestration
mf_construction() {
    # parse args
    local stages="prepare,configure,build,check,install"
    local from=""
    local force="false"
    local dest="${LFS}"
    local resume="false"
    local bootstrap_mode="false"
    local jobs_override=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stages=*) stages="${1#*=}"; shift ;;
            --from=*) from="${1#*=}"; shift ;;
            --force) force="true"; shift ;;
            --destdir=*) dest="${1#*=}"; shift ;;
            --resume) resume="true"; shift ;;
            --bootstrap-mode) bootstrap_mode="true"; shift ;;
            --jobs=*) jobs_override="${1#*=}"; shift ;;
            --help) echo "mf_construction --destdir=... --stages=... --from=..."; return 0 ;;
            *) shift ;;
        esac
    done
    [[ -n "${jobs_override}" ]] && MF_JOBS="${jobs_override}"

    # preflight checks
    if [[ -n "${MF_MIN_DISK_MB:-}" ]]; then
        local avail
        avail=$(df -Pm "${LFS_BUILD_DIR}" 2>/dev/null | awk 'NR==2{print $4}')
        if [[ -n "${avail}" && "${avail}" -lt "${MF_MIN_DISK_MB}" ]]; then
            register_error "Insufficient disk space in ${LFS_BUILD_DIR}: ${avail}MB < ${MF_MIN_DISK_MB}MB"
            return 2
        fi
    fi

    # stages order array
    IFS=',' read -ra STEPS <<< "${stages}"

    # run hooks and steps
    for step in "${STEPS[@]}"; do
        case "${step}" in
            prepare)
                mf_run_hook pre-fetch || true
                mf_fetch_sources "${force}" || return $?
                mf_run_hook post-fetch || true
                mf_prepare_build || return $?
                mf_run_hook pre-build || true
                ;;
            configure)
                mf_configure || return $?
                mf_run_hook post-configure || true
                ;;
            build)
                mf_build || return $?
                mf_run_hook post-build || true
                ;;
            check)
                mf_check || true
                ;;
            install)
                mf_run_hook pre-install || true
                mf_install "${dest}" || return $?
                mf_run_hook post-install || true
                ;;
            *)
                register_warn "Unknown stage: ${step}"
                ;;
        esac
    done

    # success metadata
    local meta_dir="${LFS}/var/lib/lfs-packages"
    mkdir -p "${meta_dir}"
    local meta_file="${meta_dir}/${MF_NAME}-${MF_VERSION}.meta"
    _mf_atomic_write "${meta_file}" "name=${MF_NAME}" "version=${MF_VERSION}" "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" "origin=${MF_WWW:-unknown}"
    register_info "Construction finished for ${MF_NAME}-${MF_VERSION}"
    return 0
}

# CLI: allow running actions directly
_mf_usage() {
    cat <<EOF
metafile.sh - operations on package metafile.ini

Usage:
  source metafile.sh
  mf_load <metafile.ini>
  mf_fetch_sources [--force]
  mf_prepare_build
  mf_configure
  mf_build
  mf_check
  mf_install [--destdir=/path]
  mf_construction [--stages=...] [--force] [--destdir=...]

EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --help|-h|'')
            _mf_usage
            exit 0
        ;;
        *)
            echo "This script is intended to be sourced by other scripts."
            _mf_usage
            exit 2
        ;;
    esac
fi
# ==== END OF PART 2A/3 ====