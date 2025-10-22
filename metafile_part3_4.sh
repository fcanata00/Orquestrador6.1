# ==== PART 3/4 ====
    for p in "${MF_PATCHES[@]}"; do
        idx=$((idx+1))
        register_info "Applying patch #${idx}: ${p}"
        local patchpath
        if [[ "${p}" =~ ^https?:// ]]; then
            patchpath="${LFS_SOURCES_CACHE}/${MF_NAME}-${MF_VERSION}/patch-${idx}.patch"
            if [[ ! -f "${patchpath}" ]]; then
                register_info "Downloading patch ${p}"
                if command -v curl >/dev/null 2>&1; then
                    curl -L -o "${patchpath}" "${p}" >> "${MF_BUILD_LOG}" 2>&1 || true
                else
                    wget -O "${patchpath}" "${p}" >> "${MF_BUILD_LOG}" 2>&1 || true
                fi
            fi
        else
            # relative to pkgdir
            patchpath="${pkgdir}/${p}"
        fi
        if [[ ! -f "${patchpath}" ]]; then
            register_error "Patch not found: ${patchpath}"
            return 5
        fi
        # attempt apply with p=1 then p=0 fallback if MF_PATCH_FALLBACK true
        local applied=false
        for strip in 1 0 2; do
            (cd "${workdir}" && patch -p"${strip}" --batch < "${patchpath}" >> "${MF_BUILD_LOG}" 2>&1) && { applied=true; register_info "Patch applied with -p${strip}"; break; }
            register_debug "Patch -p${strip} failed for ${patchpath}"
        done
        if [[ "${applied}" != "true" ]]; then
            register_error "Failed to apply patch ${patchpath}; saving to ${LFS_LOG_DIR}/${MF_NAME}.patch.fail"
            mkdir -p "${LFS_LOG_DIR}"
            cp -a "${patchpath}" "${LFS_LOG_DIR}/${MF_NAME}.patch.fail-${idx}" || true
            return 5
        fi
    done
    register_info "All patches applied"
    return 0
}

# Execute hooks in controlled environment
mf_run_hook() {
    local hook="$1"
    shift || true
    local nofail="${1:-false}"
    local hpath="${MF_HOOKS[${hook}]:-}"
    if [[ -z "${hpath}" ]]; then
        register_debug "No hook configured: ${hook}"
        return 0
    fi
    # resolve relative to MF_DIR
    if [[ "${hpath}" =~ ^/ ]]; then
        # absolute path allowed only with trust
        if [[ "${MF_TRUST_HOOKS}" != "true" && "${MF_TRUST_HOOKS}" != "1" ]]; then
            register_error "Hook ${hook} is absolute path and MF_TRUST_HOOKS not set; refusing to run"
            return 10
        fi
    else
        hpath="${MF_DIR}/${hpath}"
    fi
    if [[ ! -f "${hpath}" ]]; then
        register_warn "Hook file not found: ${hpath}"
        return 0
    fi
    # ensure executable
    chmod +x "${hpath}" || true
    register_info "Running hook ${hook}: ${hpath}"
    # limited env
    local OLD_PATH="${PATH}"
    PATH="/bin:/usr/bin:${LFS_TOOLS_DIR}"
    export MF_NAME MF_VERSION MF_DIR BUILD_DIR LFS
    set +e
    bash -e "${hpath}" >> "${MF_BUILD_LOG}" 2>&1
    local rc=$?
    set -e
    PATH="${OLD_PATH}"
    if [[ ${rc} -ne 0 ]]; then
        register_error "Hook ${hook} failed (rc=${rc}), see ${MF_BUILD_LOG}"
        if [[ "${nofail}" == "false" ]]; then
            return 10
        fi
    fi
    return 0
}

# Extract sources to build dir
mf_prepare_build() {
    local workdir="${1:-${LFS_BUILD_DIR}/${MF_NAME}-${MF_VERSION}}"
    mkdir -p "${workdir}"
    # Prefer local source copy in cache
    local scache="$(_mf_sources_cache_dir)"
    mkdir -p "${scache}"
    # Try to find any tarball or git tar in scache
    local found=false
    shopt -s nullglob
    for f in "${scache}"/*; do
        if [[ -f "${f}" ]]; then
            case "${f}" in
                *.tar.*|*.tgz|*.tar|*.zip)
                    register_info "Extracting ${f} into ${workdir}"
                    case "${f}" in
                        *.tar.gz|*.tgz) tar -xzf "${f}" -C "${workdir}" >> "${MF_BUILD_LOG}" 2>&1 ;;
                        *.tar.xz) tar -xJf "${f}" -C "${workdir}" >> "${MF_BUILD_LOG}" 2>&1 ;;
                        *.tar) tar -xf "${f}" -C "${workdir}" >> "${MF_BUILD_LOG}" 2>&1 ;;
                        *.zip) unzip -q "${f}" -d "${workdir}" >> "${MF_BUILD_LOG}" 2>&1 ;;
                    esac
                    found=true
                    break
                    ;;
            esac
        fi
    done
    shopt -u nullglob
    # fallback: if git checkout exists in cache, copy it
    if [[ "${found}" != "true" ]]; then
        for d in "${scache}"/git-*; do
            if [[ -d "${d}" ]]; then
                register_info "Copying git checkout ${d} -> ${workdir}"
                cp -a "${d}/." "${workdir}/" || true
                found=true
                break
            fi
        done
    fi
    if [[ "${found}" != "true" ]]; then
        register_warn "No archive or git checkout found in cache; attempting to use MF_DIR sources"
        # if MF_DIR contains sources, copy
        if [[ -d "${MF_DIR}" ]]; then
            cp -a "${MF_DIR}/." "${workdir}/" || true
        fi
    fi
    # apply patches
    mf_apply_patches "${workdir}" || return 5
    register_info "Prepared build directory ${workdir}"
    BUILD_DIR="${workdir}"
    export BUILD_DIR
    return 0
}

# Detect build system heuristically
_mf_detect_build_system() {
    local wd="${1:-${BUILD_DIR}}"
    if [[ -n "${MF_BUILD_SYSTEM}" && "${MF_BUILD_SYSTEM}" != "auto" ]]; then
        printf '%s\n' "${MF_BUILD_SYSTEM}"
        return 0
    fi
    if [[ -f "${wd}/configure" ]]; then
        printf '%s\n' "autotools"
    elif [[ -f "${wd}/CMakeLists.txt" ]]; then
        printf '%s\n' "cmake"
    elif [[ -f "${wd}/pyproject.toml" ]] || [[ -f "${wd}/setup.py" ]]; then
        printf '%s\n' "python"
    elif [[ -f "${wd}/package.json" ]]; then
        printf '%s\n' "node"
    elif [[ -f "${wd}/Cargo.toml" ]]; then
        printf '%s\n' "cargo"
    else
        printf '%s\n' "make"
    fi
}

# configure step
mf_configure() {
    local dest="${1:-}"
    local wd="${BUILD_DIR:-}"
    if [[ -z "${wd}" ]]; then
        register_error "BUILD_DIR not set; run mf_prepare_build first"
        return 6
    fi
    local bs="$(_mf_detect_build_system "${wd}")"
    register_info "Detected build system: ${bs}"
    case "${bs}" in
        autotools)
            # run autoreconf if needed
            if [[ -f "${wd}/autogen.sh" ]]; then
                utils_run_cmd "cd '${wd}' && bash autogen.sh" --capture-output || true
            fi
            local cfg="${MF_BUILD_CONFIGURE:-./configure --prefix=${MF_BUILD_PREFIX}}"
            register_info "Configuring (autotools): ${cfg}"
            utils_run_cmd "cd '${wd}' && ${cfg}" --capture-output || return 6
            ;;
        cmake)
            mkdir -p "${wd}/build"
            local cfg="${MF_BUILD_CONFIGURE:-cmake -S . -B build -DCMAKE_INSTALL_PREFIX=${MF_BUILD_PREFIX}}"
            register_info "Configuring (cmake): ${cfg}"
            utils_run_cmd "cd '${wd}' && ${cfg}" --capture-output || return 6
            ;;
        python)
            register_info "Python package detected; skipping configure or running build backend"
            ;;
        cargo)
            register_info "Rust cargo detected; no configure step"
            ;;
        node)
            register_info "Node package detected; running npm install to prepare"
            utils_run_cmd "cd '${wd}' && npm ci" --capture-output || return 6
            ;;
        make)
            register_info "No configure step for make-based project"
            ;;
        *)
            if [[ -n "${MF_BUILD_CONFIGURE}" ]]; then
                utils_run_cmd "cd '${wd}' && ${MF_BUILD_CONFIGURE}" --capture-output || return 6
            else
                register_warn "Unknown build system and no configure command provided"
            fi
            ;;
    esac
    register_info "Configure step completed"
    return 0
}

# build step
mf_build() {
    local wd="${BUILD_DIR:-}"
    if [[ -z "${wd}" ]]; then
        register_error "BUILD_DIR not set; run mf_prepare_build first"
        return 7
    fi
    local bs="$(_mf_detect_build_system "${wd}")"
    local jobs="${MF_JOBS}"
    case "${bs}" in
# ==== END OF PART 3/4 ====