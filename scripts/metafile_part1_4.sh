# ==== PART 1/4 ====
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
# ==== END OF PART 1/4 ====