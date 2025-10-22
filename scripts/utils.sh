#!/usr/bin/env bash
# utils.sh - Utility library for LFS build system
# Provides:
#  - Standardized directory variables (LFS, caches, src, bins, metafiles)
#  - Robust environment validation and init (utils_init_env, utils_check_mounts)
#  - Utility functions (run command with logging, check deps, safe copy, mkdir)
#  - Integration with register.sh if available (register_info/warn/error)
#  - Silent/debug modes and traps for errors
#  - Search paths for metafiles (recipes) in /usr/src and $LFS/usr/src
#
# Place this file in /mnt/lfs/usr/bin or /usr/bin and `source` from other scripts.
#
set -eEuo pipefail

# -----------------------
# Defaults (overridable)
# -----------------------
: "${LFS:=/mnt/lfs}"
: "${LFS_ARCH:=$(uname -m)}"
: "${LFS_USER:=${SUDO_USER:-${USER:-root}}}"
: "${LFS_CONF_DIR:=${LFS}/etc/lfs}"
: "${LFS_LOG_DIR:=${LFS}/var/log}"
: "${LFS_BIN_DIR:=${LFS}/usr/bin}"
: "${LFS_SRC_DIRS:=/usr/src ${LFS}/usr/src}"
: "${LFS_SOURCES_CACHE:=${LFS}/sources/cache}"
: "${LFS_BIN_CACHE:=${LFS}/packages/cache}"
: "${LFS_BUILD_DIR:=${LFS}/build}"
: "${LFS_TOOLS_DIR:=${LFS}/tools}"
: "${LFS_TMP:=/tmp/lfs}"
: "${LFS_METAFILE_GLOB:=*.meta.sh *.recipe.sh *.mf}"
: "${LFS_PROGRESS_DIR:=${LFS_LOG_DIR}/.progress}"
: "${LFS_PATCH_SUBDIR:=patches}"
: "${LFS_HOOKS_SUBDIR:=hooks}"
: "${LFS_COLOR:=true}"
: "${LFS_DEBUG:=false}"
: "${LFS_SILENT:=false}"
: "${LFS_LOCK_DIR:=${LFS_LOG_DIR}/locks}"

# Script names (for use across scripts)
: "${SCRIPT_METAFILE:=metafile.sh}"
: "${SCRIPT_SANDBOX:=sandbox.sh}"
: "${SCRIPT_BUILD:=build.sh}"
: "${SCRIPT_DOWNLOADER:=downloader.sh}"
: "${SCRIPT_UPDATE:=update.sh}"
: "${SCRIPT_UNINSTALL:=uninstall.sh}"
: "${SCRIPT_DEPENDS:=depende.sh}"
: "${SCRIPT_BOOTSTRAP:=bootstrap.sh}"

# -----------------------
# Internal
# -----------------------
REGISTER_AVAILABLE=false
_register_check_register() {
    if type register_info >/dev/null 2>&1; then
        REGISTER_AVAILABLE=true
    else
        REGISTER_AVAILABLE=false
    fi
}

# minimal logging fallback (if register.sh not available)
_utils_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    if [[ "${LFS_SILENT}" == "true" ]]; then
        # silent mode: only append to log file
        :
    else
        case "${level}" in
            INFO) printf "[%s] [INFO] %s\n" "${ts}" "${msg}" ;;
            WARN) printf "[%s] [WARN] %s\n" "${ts}" "${msg}" >&2 ;;
            ERROR) printf "[%s] [ERROR] %s\n" "${ts}" "${msg}" >&2 ;;
            DEBUG)
                if [[ "${LFS_DEBUG}" == "true" ]]; then
                    printf "[%s] [DEBUG] %s\n" "${ts}" "${msg}"
                fi
                ;;
            *) printf "[%s] [LOG] %s\n" "${ts}" "${msg}" ;;
        esac
    fi
    # Always append to central log file if possible
    if [[ -n "${LFS_LOG_DIR:-}" ]]; then
        mkdir -p "${LFS_LOG_DIR}" 2>/dev/null || true
        local logfile="${LFS_LOG_DIR}/lfs-utils.log"
        # atomic append via flock where possible
        if command -v flock >/dev/null 2>&1; then
            exec 9>>"${logfile}" 2>/dev/null || true
            if [[ -e /proc/$$/fd/9 ]]; then
                flock -n 9 2>/dev/null || true
                printf '%s [%s] %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "${level}" "${msg}" >&9 || true
                eval "exec 9>&-"
            else
                printf '%s [%s] %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "${level}" "${msg}" >> "${logfile}" 2>/dev/null || true
            fi
        else
            printf '%s [%s] %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "${level}" "${msg}" >> "${logfile}" 2>/dev/null || true
        fi
    fi
}

register_log_proxy() {
    if type register_info >/dev/null 2>&1; then
        register_info "$*"
    else
        _utils_log INFO "$*"
    fi
}

register_warn_proxy() {
    if type register_warn >/dev/null 2>&1; then
        register_warn "$*"
    else
        _utils_log WARN "$*"
    fi
}

register_error_proxy() {
    if type register_error >/dev/null 2>&1; then
        register_error "$*"
    else
        _utils_log ERROR "$*"
    fi
}

register_debug_proxy() {
    if type register_debug >/dev/null 2>&1; then
        register_debug "$*"
    else
        _utils_log DEBUG "$*"
    fi
}

# -----------------------
# Error handling
# -----------------------
_utils_err_trap() {
    local rc=${1:-$?}
    local line=${2:-${LINENO}}
    register_error_proxy "Unexpected error (code ${rc}) at line ${line} in ${BASH_SOURCE[1]:-utils.sh}"
    exit "${rc}"
}

_utils_enable_traps() {
    trap '_utils_err_trap $? ${LINENO}' ERR
}

# -----------------------
# Path utilities
# -----------------------
_utils_realpath() {
    local p="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$p"
    elif command -v readlink >/dev/null 2>&1; then
        readlink -f "$p"
    else
        echo "$p"
    fi
}

# -----------------------
# Core utilities
# -----------------------
utils_init_env() {
    _register_check_register
    _utils_enable_traps

    register_log_proxy "Initializing utils environment"
    mkdir -p "${LFS}" "${LFS_LOG_DIR}" "${LFS_BIN_DIR}" "${LFS_BUILD_DIR}" "${LFS_SOURCES_CACHE}" "${LFS_BIN_CACHE}" "${LFS_TOOLS_DIR}" "${LFS_TMP}" "${LFS_LOCK_DIR}" "${LFS_PROGRESS_DIR}" 2>/dev/null || true

    chmod 755 "${LFS_BIN_DIR}" || true
    chmod 755 "${LFS_BUILD_DIR}" || true
    chmod 700 "${LFS_TMP}" || true

    if [[ "${LFS}" != "/" ]]; then
        utils_check_mounts || {
            register_warn_proxy "LFS mount check failed; continue only if you know what you're doing"
        }
    fi

    register_log_proxy "Environment initialized (LFS=${LFS}, ARCH=${LFS_ARCH})"
}

utils_check_mounts() {
    if [[ ! -d "${LFS}" ]]; then
        register_error_proxy "LFS root '${LFS}' does not exist"
        return 2
    fi
    if ! touch "${LFS}/.lfs_write_test" 2>/dev/null; then
        register_error_proxy "LFS root '${LFS}' is not writable by current user"
        return 3
    else
        rm -f "${LFS}/.lfs_write_test" 2>/dev/null || true
    fi
    return 0
}

utils_check_conf() {
    local conf="${LFS_CONF_DIR}/build.conf"
    if [[ -f "${conf}" ]]; then
        register_log_proxy "Loading configuration from ${conf}"
        # shellcheck disable=SC1090
        source "${conf}"
    fi
    if [[ -z "${LFS_BIN_DIR:-}" ]]; then
        register_error_proxy "LFS_BIN_DIR is empty"
        return 1
    fi
    return 0
}

utils_detect_arch() {
    LFS_ARCH="$(uname -m || echo x86_64)"
    register_log_proxy "Detected architecture: ${LFS_ARCH}"
}

utils_show_vars() {
    cat <<EOF
LFS=${LFS}
LFS_ARCH=${LFS_ARCH}
LFS_USER=${LFS_USER}
LFS_CONF_DIR=${LFS_CONF_DIR}
LFS_LOG_DIR=${LFS_LOG_DIR}
LFS_BIN_DIR=${LFS_BIN_DIR}
LFS_SRC_DIRS=${LFS_SRC_DIRS}
LFS_SOURCES_CACHE=${LFS_SOURCES_CACHE}
LFS_BIN_CACHE=${LFS_BIN_CACHE}
LFS_BUILD_DIR=${LFS_BUILD_DIR}
LFS_TOOLS_DIR=${LFS_TOOLS_DIR}
LFS_TMP=${LFS_TMP}
LFS_METAFILE_GLOB=${LFS_METAFILE_GLOB}
LFS_PATCH_SUBDIR=${LFS_PATCH_SUBDIR}
LFS_HOOKS_SUBDIR=${LFS_HOOKS_SUBDIR}
LFS_COLOR=${LFS_COLOR}
LFS_DEBUG=${LFS_DEBUG}
LFS_SILENT=${LFS_SILENT}
EOF
}

# -----------------------
# Dependency and command helpers
# -----------------------
utils_check_dep() {
    local prog="$1"
    if command -v "${prog}" >/dev/null 2>&1; then
        register_debug_proxy "Dependency '${prog}' found"
        return 0
    else
        register_warn_proxy "Dependency '${prog}' not found in PATH"
        return 1
    fi
}

utils_ensure_deps() {
    local missing=0
    for prog in "$@"; do
        if ! utils_check_dep "${prog}"; then
            missing=1
        fi
    done
    if [[ "${missing}" -ne 0 ]]; then
        register_error_proxy "One or more dependencies are missing"
        return 2
    fi
    return 0
}

# Runs a command with logging and optional silent capture.
utils_run_cmd() {
    local cmd="$1"
    shift || true
    local capture=false
    if [[ "${1:-}" == "--capture-output" ]]; then
        capture=true
    fi

    register_log_proxy "CMD: ${cmd}"
    if [[ "${capture}" == "true" ]]; then
        local tmpout
        tmpout="$(mktemp "${LFS_TMP}/cmdout.XXXXXX")"
        set +e
        bash -c "${cmd}" >"${tmpout}" 2>&1
        local rc=$?
        set -e
        if [[ ${rc} -ne 0 ]]; then
            register_error_proxy "Command failed (rc=${rc}): ${cmd}. See ${tmpout} for output"
        else
            register_debug_proxy "Command succeeded: ${cmd}"
        fi
        cat "${tmpout}" || true
        rm -f "${tmpout}" || true
        return ${rc}
    else
        if [[ "${LFS_SILENT}" == "true" ]]; then
            bash -c "${cmd}" >/dev/null 2>&1
            local rc=$?
            if [[ ${rc} -ne 0 ]]; then
                register_error_proxy "Command failed (rc=${rc}) in silent mode: ${cmd}"
            fi
            return ${rc}
        else
            bash -c "${cmd}"
            local rc=$?
            if [[ ${rc} -ne 0 ]]; then
                register_error_proxy "Command failed (rc=${rc}): ${cmd}"
            fi
            return ${rc}
        fi
    fi
}

# -----------------------
# File helpers
# -----------------------
utils_make_dir() {
    local dir="$1"
    if [[ -z "${dir}" ]]; then
        register_warn_proxy "utils_make_dir called with empty directory"
        return 1
    fi
    mkdir -p "${dir}" 2>/dev/null || {
        register_error_proxy "Failed to create directory: ${dir}"
        return 2
    }
    chmod 755 "${dir}" || true
    register_debug_proxy "Created/ensured dir: ${dir}"
    return 0
}

utils_copy_safe() {
    local src="$1" dest="$2"
    if [[ ! -e "${src}" ]]; then
        register_error_proxy "Source not found: ${src}"
        return 2
    fi
    utils_make_dir "$(dirname "${dest}")" || return 3
    if [[ -e "${dest}" ]]; then
        local srcsum destsum
        if command -v sha256sum >/dev/null 2>&1; then
            srcsum="$(sha256sum "${src}" | awk '{print $1}')"
            destsum="$(sha256sum "${dest}" | awk '{print $1}')"
            if [[ "${srcsum}" == "${destsum}" ]]; then
                register_debug_proxy "Destination up-to-date: ${dest}"
                return 0
            fi
        fi
    fi
    cp -a "${src}" "${dest}" || {
        register_error_proxy "Failed to copy ${src} -> ${dest}"
        return 4
    }
    register_log_proxy "Copied ${src} -> ${dest}"
    return 0
}

# -----------------------
# Metafile (recipe) discovery
# -----------------------
utils_find_metafiles() {
    local IFS_bak="$IFS"
    IFS=$'\n'
    local results=()
    for d in ${LFS_SRC_DIRS}; do
        if [[ -d "${d}" ]]; then
            while IFS= read -r -d $'\0' f; do
                results+=("$f")
            done < <(find "${d}" -maxdepth 2 -type f \( -name "*.meta.sh" -o -name "*.recipe.sh" -o -name "*.mf" \) -print0 2>/dev/null)
        fi
    done
    IFS="$IFS_bak"
    for f in "${results[@]:-}"; do
        printf '%s\n' "${f}"
    done
}

utils_load_metafile() {
    local mf="$1"
    if [[ ! -f "${mf}" ]]; then
        register_error_proxy "Metafile not found: ${mf}"
        return 2
    fi
    local saved_path="${PATH}"
    PATH="/bin:/usr/bin"
    # shellcheck disable=SC1090
    source "${mf}"
    PATH="${saved_path}"
    register_log_proxy "Loaded metafile: ${mf}"
    return 0
}

# -----------------------
# Hooks & patches helpers
# -----------------------
utils_package_patches_dir() {
    local pkgdir="$1"
    local p="${pkgdir}/${LFS_PATCH_SUBDIR}"
    if [[ -d "${p}" ]]; then
        printf '%s\n' "${p}"
        return 0
    fi
    return 1
}

utils_package_hooks_dir() {
    local pkgdir="$1"
    local p="${pkgdir}/${LFS_HOOKS_SUBDIR}"
    if [[ -d "${p}" ]]; then
        printf '%s\n' "${p}"
        return 0
    fi
    return 1
}

# -----------------------
# Sandbox management helper (lightweight)
# -----------------------
utils_prepare_sandbox() {
    local sandbox_root="${1:-${LFS_BUILD_DIR}/sandbox}"
    register_log_proxy "Preparing sandbox at ${sandbox_root}"
    utils_make_dir "${sandbox_root}"
    mkdir -p "${sandbox_root}/tmp" || true
    chmod 1777 "${sandbox_root}/tmp" || true
    printf '%s\n' "${sandbox_root}"
}

# -----------------------
# Cleanup helpers
# -----------------------
utils_clean_temp() {
    local dir="${1:-${LFS_TMP}}"
    register_warn_proxy "Cleaning temporary dir: ${dir}"
    case "${dir}" in
        /tmp*|${LFS_TMP}*|${LFS}/tmp*)
            rm -rf "${dir}"/* 2>/dev/null || true
            register_log_proxy "Cleaned temp: ${dir}"
            ;;
        *)
            register_error_proxy "Refusing to clean unsafe directory: ${dir}"
            return 2
            ;;
    esac
    return 0
}

# -----------------------
# CLI for utils.sh
# -----------------------
_utils_usage() {
    cat <<EOF
utils.sh - Utility library for LFS build system

Usage:
  source utils.sh             # to use functions
  utils.sh --init             # create dirs and validate env
  utils.sh --show-vars        # print active variables
  utils.sh --check-env        # run full environment checks

EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --init)
            utils_init_env
            exit 0
            ;;
        --show-vars)
            utils_show_vars
            exit 0
            ;;
        --check-env)
            utils_init_env
            utils_check_conf
            utils_detect_arch
            utils_ensure_deps bash coreutils find grep awk mkdir cp rm || true
            exit 0
            ;;
        --help|-h|'')
            _utils_usage
            exit 0
            ;;
        *)
            _utils_usage
            exit 2
            ;;
    esac
fi

_register_check_register
_utils_enable_traps

# End of utils.sh
