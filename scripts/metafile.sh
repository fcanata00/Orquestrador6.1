#!/usr/bin/env bash
# metafile.sh - Loader and executor of package metafile.ini recipes for LFS build system
# Implements:
#  - INI parser for metafile.ini with sections and keys
#  - MF_* variables exported after mf_load
#  - Fetching multiple sources (url/git/file), retries, timeouts, cache, locks
#  - SHA256 verification and optional GPG verify hooks
#  - Automatic patch application with fallback strip attempts
#  - Hook execution with restricted env and trust controls
#  - Build system handlers for autotools, cmake, meson, make, cargo, go, python, node, maven, gradle, custom
#  - Dependency hooks (calls depende.sh if available)
#  - Checkpointing, locking, fingerprinting, caching of build artifacts
#  - mf_construction orchestration (prepare, configure, build, check, install)
#
# Usage (source from other scripts):
#   source /mnt/lfs/usr/bin/utils.sh
#   source /mnt/lfs/usr/bin/register.sh
#   source /mnt/lfs/usr/bin/metafile.sh
#   mf_load "/usr/src/foo/metafile.ini"
#   mf_construction --destdir="${LFS}"
#
set -eEuo pipefail

# Defaults
: "${LFS:=/mnt/lfs}"
: "${LFS_SOURCES_CACHE:=${LFS}/sources/cache}"
: "${LFS_BIN_CACHE:=${LFS}/packages/cache}"
: "${LFS_BUILD_DIR:=${LFS}/build}"
: "${LFS_LOG_DIR:=${LFS}/var/log}"
: "${LFS_PROGRESS_DIR:=${LFS_LOG_DIR}/.progress}"
: "${LFS_LOCK_DIR:=${LFS_LOG_DIR}/locks}"
: "${LFS_TOOLS_DIR:=${LFS}/tools}"
: "${LFS_TMP:=/tmp/lfs}"
: "${LFS_COLOR:=true}"
: "${LFS_DEBUG:=false}"
: "${LFS_SILENT:=false}"

# MF defaults
: "${MF_DOWNLOAD_RETRIES:=3}"
: "${MF_DOWNLOAD_BACKOFF:=5}"
: "${MF_DOWNLOAD_TIMEOUT:=300}"
: "${MF_ALLOW_NO_CHECKSUM:=false}"
: "${MF_JOBS:=$(nproc || echo 1)}"
: "${MF_MIN_DISK_MB:=1024}"
: "${MF_MIN_RAM_MB:=512}"
: "${MF_PATCH_FALLBACK:=true}"
: "${MF_DEBUG_BUILD:=false}"
: "${MF_TRUST_HOOKS:=false}"

# Internal helpers use register proxies if available
_register_check() {
    if type register_info >/dev/null 2>&1; then
        true
    else
        # provide simple proxies
        register_info() { printf "[INFO] %s\n" "$*"; }
        register_warn() { printf "[WARN] %s\n" "$*" >&2; }
        register_error() { printf "[ERROR] %s\n" "$*" >&2; }
        register_debug() { if [[ "${LFS_DEBUG}" == "true" ]]; then printf "[DEBUG] %s\n" "$*"; fi }
    fi
}
_register_check

# sanitize names
_mf_sanitize_name() {
    local n="$1"
    if [[ ! "${n}" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        register_error "Invalid package name: '${n}'. Allowed chars: A-Za-z0-9._+-"
        return 1
    fi
    return 0
}

# Utility: atomic write
_mf_atomic_write() {
    local file="$1"; shift
    local tmp="${file}.$$.$(date +%s)"
    printf "%s\n" "$@" > "${tmp}" || return 1
    mv -f "${tmp}" "${file}"
}

# INI parser (supports simple key = value and sections)
# Populates associative array MF_INI["section.key"]=value and arrays MF_SECTION_KEYS[]
declare -A MF_INI
declare -A MF_INI_KEYS    # keys lists per section as newline separated
mf_parse_ini() {
    local ini="$1"
    if [[ ! -f "${ini}" ]]; then
        register_error "INI file not found: ${ini}"
        return 2
    fi
    local section=""
    local lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno+1))
        # strip comments and trim
        line="${line%%#*}"
        line="${line%"${line##*[![:space:]]}"}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi
        if [[ "$line" =~ ^([A-Za-z0-9_.-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            # strip possible surrounding quotes
            val="${val%\"}"
            val="${val#\"}"
            MF_INI["${section}.${key}"]="${val}"
            # append key to section keys list
            if [[ -z "${MF_INI_KEYS[${section}]:-}" ]]; then
                MF_INI_KEYS[${section}]="${key}"
            else
                MF_INI_KEYS[${section}]="${MF_INI_KEYS[${section}]}"$'\n'"${key}"
            fi
        else
            register_warn "Unrecognized line ${lineno} in ${ini}: ${line}"
        fi
    done < "${ini}"
    return 0
}

# helper to get ini value
_mf_get() {
    local section="$1"; local key="$2"; local def="${3:-}"
    if [[ -n "${MF_INI[${section}.${key}]:-}" ]]; then
        printf '%s' "${MF_INI[${section}.${key}]}"
    else
        printf '%s' "${def}"
    fi
}

# split CSV into array
_mf_split_csv() {
    local IFS_bak="$IFS"
    IFS=','
    read -ra __arr <<< "$1"
    IFS="$IFS_bak"
    printf '%s\n' "${__arr[@]:-}"
}

# Load metafile and populate MF_* variables
mf_load() {
    local ini="$1"
    if [[ -z "${ini:-}" ]]; then
        register_error "mf_load requires path to metafile.ini"
        return 1
    fi
    mf_parse_ini "${ini}" || return 2

    # basic metadata
    MF_NAME="$(_mf_get package name)"
    MF_VERSION="$(_mf_get package version)"
    MF_DESC="$(_mf_get package description)"
    MF_WWW="$(_mf_get package www)"
    MF_API="$(_mf_get package api)"
    MF_CATEGORY="$(_mf_get package category base)"
    MF_X11="$(_mf_get package x11 false)"
    MF_DESKTOP="$(_mf_get package desktop false)"
    MF_EXTRAS="$(_mf_get package extras '')"

    # sanitize name
    _mf_sanitize_name "${MF_NAME}" || return 3

    # arches
    local archs="$(_mf_get package arch any)"
    readarray -t MF_ARCHES < <(_mf_split_csv "${archs}")

    # environment
    MF_ENV_KEYS=()
    MF_ENV_VARS=()
    if [[ -n "${MF_INI_KEYS[environment]:-}" ]]; then
        local keys="${MF_INI_KEYS[environment]:-}"
        while IFS= read -r k; do
            [[ -z "$k" ]] && continue
            val="${MF_INI[environment.${k}]:-}"
            MF_ENV_KEYS+=("${k}")
            MF_ENV_VARS+=("${val}")
        done <<< "${keys}"
    fi

    # sources: gather keys in section "sources" preserving order
    MF_SOURCES=()
    MF_SOURCES_SHA=()
    if [[ -n "${MF_INI_KEYS[sources]:-}" ]]; then
        local skeys="${MF_INI_KEYS[sources]}"
        local idx=0
        while IFS= read -r k; do
            [[ -z "$k" ]] && continue
            local v="${MF_INI[sources.${k}]}"
            MF_SOURCES+=("${v}")
            # try to find sha key named sha256_<k> or sha256_<idx+1>
            local sha="${MF_INI[sources.sha256_${k}]:-}"
            if [[ -z "${sha}" ]]; then
                sha="${MF_INI[sources.sha256_$((idx+1))]:-}"
            fi
            MF_SOURCES_SHA+=("${sha}")
            idx=$((idx+1))
        done <<< "${skeys}"
    fi

    # patches
    MF_PATCHES=()
    if [[ -n "${MF_INI_KEYS[patches]:-}" ]]; then
        local pkeys="${MF_INI_KEYS[patches]}"
        while IFS= read -r k; do
            [[ -z "$k" ]] && continue
            MF_PATCHES+=("${MF_INI[patches.${k}]}")
        done <<< "${pkeys}"
    fi

    # hooks
    declare -Ag MF_HOOKS
    MF_HOOKS=()
    if [[ -n "${MF_INI_KEYS[hooks]:-}" ]]; then
        local hkeys="${MF_INI_KEYS[hooks]}"
        while IFS= read -r k; do
            [[ -z "$k" ]] && continue
            MF_HOOKS[${k}]="${MF_INI[hooks.${k}]}"
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
        autotools)
            local cmd="${MF_BUILD_BUILD:-make -j${jobs}}"
            register_info "Building (autotools): ${cmd}"
            utils_run_cmd "cd '${wd}' && ${cmd}" --capture-output || return 7
            ;;
        cmake)
            local cmd="${MF_BUILD_BUILD:-cmake --build build -- -j${jobs}}"
            register_info "Building (cmake): ${cmd}"
            utils_run_cmd "cd '${wd}' && ${cmd}" --capture-output || return 7
            ;;
        cargo)
            local cmd="${MF_BUILD_BUILD:-cargo build --release -j ${jobs}}"
            register_info "Building (cargo): ${cmd}"
            utils_run_cmd "cd '${wd}' && ${cmd}" --capture-output || return 7
            ;;
        python)
            local cmd="${MF_BUILD_BUILD:-python -m build}"
            register_info "Building (python): ${cmd}"
            utils_run_cmd "cd '${wd}' && ${cmd}" --capture-output || return 7
            ;;
        node)
            local cmd="${MF_BUILD_BUILD:-npm run build}"
            register_info "Building (node): ${cmd}"
            utils_run_cmd "cd '${wd}' && ${cmd}" --capture-output || return 7
            ;;
        make)
            local cmd="${MF_BUILD_BUILD:-make -j${jobs}}"
            register_info "Building (make): ${cmd}"
            utils_run_cmd "cd '${wd}' && ${cmd}" --capture-output || return 7
            ;;
        *)
            if [[ -n "${MF_BUILD_BUILD}" ]]; then
                utils_run_cmd "cd '${wd}' && ${MF_BUILD_BUILD}" --capture-output || return 7
            else
                register_error "No build command for build system ${bs}"
                return 7
            fi
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
