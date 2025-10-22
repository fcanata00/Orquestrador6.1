# ==== PART 2/4 ====
        done <<< "${hkeys}"
    fi

    # build section
    MF_BUILD_SYSTEM="$(_mf_get build system auto)"
    MF_BUILD_CONFIGURE="$(_mf_get build configure)"
    MF_BUILD_BUILD="$(_mf_get build build)"
    MF_BUILD_CHECK="$(_mf_get build check)"
    MF_BUILD_INSTALL="$(_mf_get build install)"
    MF_BUILD_PREFIX="$(_mf_get build prefix /usr)"
    MF_BUILD_OPTIONS="$(_mf_get build options '')"

    # dependencies
    MF_DEPENDS_BUILD=()
    MF_DEPENDS_RUNTIME=()
    MF_DEPENDS_OPTIONAL=()
    MF_DEPENDS_VIRTUAL=()
    if [[ -n "${MF_INI[depends.build]:-}" ]]; then
        readarray -t MF_DEPENDS_BUILD < <(_mf_split_csv "${MF_INI[depends.build]}")
    fi
    if [[ -n "${MF_INI[depends.runtime]:-}" ]]; then
        readarray -t MF_DEPENDS_RUNTIME < <(_mf_split_csv "${MF_INI[depends.runtime]}")
    fi
    if [[ -n "${MF_INI[depends.optional]:-}" ]]; then
        readarray -t MF_DEPENDS_OPTIONAL < <(_mf_split_csv "${MF_INI[depends.optional]}")
    fi
    if [[ -n "${MF_INI[depends.virtual]:-}" ]]; then
        readarray -t MF_DEPENDS_VIRTUAL < <(_mf_split_csv "${MF_INI[depends.virtual]}")
    fi

    # fingerprint base info
    MF_FINGERPRINT_SOURCE_LIST="$(printf '%s\n' "${MF_SOURCES[@]:-}")"
    MF_META_PATH="$(realpath "${ini}")"
    MF_DIR="$(dirname "${MF_META_PATH}")"

    # logs
    MF_LOG="${LFS_LOG_DIR}/${MF_NAME}-${MF_VERSION}.log"
    MF_BUILD_LOG="${LFS_LOG_DIR}/${MF_NAME}-${MF_VERSION}.build.log"

    register_info "Loaded metafile ${ini} (name=${MF_NAME}, version=${MF_VERSION})"
    return 0
}

# Helper: find source cache dir for this package
_mf_sources_cache_dir() {
    printf '%s\n' "${LFS_SOURCES_CACHE}/${MF_NAME}-${MF_VERSION}"
}

# Helper: acquire lock for package
_mf_lock() {
    local mode="${1:-build}"
    local lockfile="${LFS_LOCK_DIR}/${MF_NAME}-${MF_VERSION}.${mode}.lock"
    mkdir -p "${LFS_LOCK_DIR}" 2>/dev/null || true
    exec {MF_LOCK_FD}>"${lockfile}"
    flock -n "${MF_LOCK_FD}" || return 1
    return 0
}
_mf_unlock() {
    if [[ -n "${MF_LOCK_FD:-}" ]]; then
        eval "exec ${MF_LOCK_FD}>&-"
    fi
    return 0
}

# Compute simple fingerprint (sources+patches+build cmds)
mf_compute_fingerprint() {
    local tmp
    tmp="$(mktemp "${LFS_TMP}/mf-fp.XXXX")"
    {
        printf '%s\n' "${MF_NAME}"
        printf '%s\n' "${MF_VERSION}"
        printf '%s\n' "${MF_FINGERPRINT_SOURCE_LIST}"
        printf '%s\n' "${MF_PATCHES[@]:-}"
        printf '%s\n' "${MF_BUILD_SYSTEM}"
        printf '%s\n' "${MF_BUILD_CONFIGURE}"
        printf '%s\n' "${MF_BUILD_BUILD}"
    } > "${tmp}"
    sha256sum "${tmp}" | awk '{print $1}'
}

# Fetch sources (supports url::, git::, file::, mirror::)
mf_fetch_sources() {
    local force="${1:-false}"
    mkdir -p "${LFS_SOURCES_CACHE}" "${LFS_LOG_DIR}" "${LFS_BUILD_DIR}" "${LFS_TMP}"
    local scache="$(_mf_sources_cache_dir)"
    mkdir -p "${scache}"
    _mf_lock "download" || { register_warn "Could not acquire download lock; another process may be downloading"; }

    local i=0
    for src in "${MF_SOURCES[@]:-}"; do
        i=$((i+1))
        local sha_expected="${MF_SOURCES_SHA[$((i-1))]:-}"
        register_info "Processing source #${i}: ${src}"
        if [[ "${src}" =~ ^git::(.+?)(@(.+))?$ ]]; then
            local uri="${BASH_REMATCH[1]}"
            local ref="${BASH_REMATCH[3]:-}"
            local dest="${scache}/git-${i}"
            if [[ -d "${dest}" && "${force}" != "true" ]]; then
                register_info "Using cached git clone ${dest}"
            else
                rm -rf "${dest}"
                mkdir -p "${dest}"
                register_info "Cloning ${uri} into ${dest}"
                if ! git clone --depth 1 --no-single-branch "${uri}" "${dest}" >> "${MF_BUILD_LOG}" 2>&1; then
                    register_error "git clone failed for ${uri}. See ${MF_BUILD_LOG}"
                    _mf_unlock || true
                    return 3
                fi
                if [[ -n "${ref}" ]]; then
                    (cd "${dest}" && git fetch --tags origin +refs/tags/*:refs/tags/* >> "${MF_BUILD_LOG}" 2>&1 || true)
                    (cd "${dest}" && git checkout "${ref}" >> "${MF_BUILD_LOG}" 2>&1) || true
                fi
                # optionally create tarball for reproducibility
                (cd "${dest}" && tar -cJf "${scache}/git-${i}.tar.xz" .) || true
            fi
            # verify if sha provided comparing tarball
            if [[ -n "${sha_expected}" ]]; then
                if [[ -f "${scache}/git-${i}.tar.xz" ]]; then
                    local got
                    got="$(sha256sum "${scache}/git-${i}.tar.xz" | awk '{print $1}')"
                    if [[ "${got}" != "${sha_expected}" ]]; then
                        register_error "Checksum mismatch for git-derived tarball ${scache}/git-${i}.tar.xz"
                        _mf_unlock || true
                        return 4
                    fi
                else
                    register_warn "No tarball created for git source; cannot verify sha"
                    if [[ "${MF_ALLOW_NO_CHECKSUM}" != "true" ]]; then
                        register_warn "No checksum; MF_ALLOW_NO_CHECKSUM=false, continuing but this may be insecure"
                    fi
                fi
            fi
        elif [[ "${src}" =~ ^(https?|ftp):// || "${src}" =~ ^file:// || "${src}" =~ ^mirror:: ]]; then
            # treat as URL
            local url="${src}"
            url="${url#mirror::}"  # mirrors handled by user ordering
            local fname
            fname="$(basename "${url}")"
            local out="${scache}/${fname}"
            if [[ -f "${out}" && "${force}" != "true" ]]; then
                register_info "Using cached source ${out}"
            else
                register_info "Downloading ${url} -> ${out}"
                local tries=0
                local ok=false
                while (( tries < MF_DOWNLOAD_RETRIES )); do
                    tries=$((tries+1))
                    if command -v curl >/dev/null 2>&1; then
                        if curl -L --connect-timeout 15 --max-time "${MF_DOWNLOAD_TIMEOUT}" -o "${out}.part" "${url}" >> "${MF_BUILD_LOG}" 2>&1; then
                            mv -f "${out}.part" "${out}"
                            ok=true
                            break
                        fi
                    elif command -v wget >/dev/null 2>&1; then
                        if wget -O "${out}.part" "${url}" >> "${MF_BUILD_LOG}" 2>&1; then
                            mv -f "${out}.part" "${out}"
                            ok=true
                            break
                        fi
                    else
                        register_error "No download tool (curl/wget) available"
                        _mf_unlock || true
                        return 3
                    fi
                    register_warn "Download attempt ${tries} failed for ${url}, backing off ${MF_DOWNLOAD_BACKOFF}s"
                    sleep "${MF_DOWNLOAD_BACKOFF}"
                done
                if [[ "${ok}" != "true" ]]; then
                    register_error "Failed to download ${url} after ${MF_DOWNLOAD_RETRIES} attempts"
                    _mf_unlock || true
                    return 3
                fi
            fi
            if [[ -n "${sha_expected}" ]]; then
                local got
                if command -v sha256sum >/dev/null 2>&1; then
                    got="$(sha256sum "${out}" | awk '{print $1}')"
                    if [[ "${got}" != "${sha_expected}" ]]; then
                        register_error "Checksum mismatch for ${out} (expected ${sha_expected}, got ${got})"
                        _mf_unlock || true
                        return 4
                    fi
                else
                    register_warn "sha256sum not available; cannot verify checksum"
                fi
            else
                register_debug "No checksum provided for ${out}"
                if [[ "${MF_ALLOW_NO_CHECKSUM}" != "true" ]]; then
                    register_warn "No checksum provided and MF_ALLOW_NO_CHECKSUM=false; continuing but insecure"
                fi
            fi
        else
            # treat as local path
            local fpath="${src}"
            if [[ -f "${fpath}" ]]; then
                register_info "Found local source ${fpath}"
                # optionally copy to cache
                cp -a "${fpath}" "${scache}/" || true
            else
                register_error "Unknown source format or file not found: ${src}"
                _mf_unlock || true
                return 3
            fi
        fi
    done

    _mf_unlock || true
    register_info "All sources fetched/verified for ${MF_NAME}-${MF_VERSION}"
    return 0
}

# Apply patches (simple implementation with fallback)
mf_apply_patches() {
    local pkgdir="${MF_DIR}"
    local workdir="${1:-${LFS_BUILD_DIR}/${MF_NAME}-${MF_VERSION}}"
    if [[ "${#MF_PATCHES[@]}" -eq 0 ]]; then
        register_debug "No patches to apply"
        return 0
    fi
    mkdir -p "${LFS_LOG_DIR}"
    local idx=0
# ==== END OF PART 2/4 ====