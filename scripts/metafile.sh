#!/usr/bin/env bash
# metafile.sh - Gerenciador de metafiles para LFS automated builder
# Prover: leitura/validação/criação de metafiles INI por pacote, API para outros scripts,
# geração de índice para download.sh, execução de hooks e fases prepare/build/check/install.
# Requisitos: bash (4+), coreutils, awk, sed, tar, git (opcional)
set -Eeuo pipefail

# ===== Global configuration =====
: "${METAFILE_DIR:=${PWD}/metafiles}"
: "${SILENT_ERRORS:=false}"
: "${ABORT_ON_ERROR:=true}"
: "${LOG_SCRIPT:=/usr/bin/logs.sh}"
: "${DOWNLOAD_SCRIPT:=/usr/bin/download.sh}"
: "${GLOBAL_HOOKS_DIR:=/usr/share/lfs/hooks}"
: "${VERIFY_CHECKSUM:=true}"
: "${ALLOW_PACKAGE_SCRIPTS:=false}"
: "${UTILS_SCRIPT:=/usr/bin/utils.sh}"

export METAFILE_DIR SILENT_ERRORS ABORT_ON_ERROR LOG_SCRIPT DOWNLOAD_SCRIPT GLOBAL_HOOKS_DIR VERIFY_CHECKSUM ALLOW_PACKAGE_SCRIPTS UTILS_SCRIPT

# try to source log.sh and utils.sh if available
if [ -f "$LOG_SCRIPT" ]; then
    # shellcheck source=/dev/null
    source "$LOG_SCRIPT" || true
    LOG_API_READY=true
else
    LOG_API_READY=false
fi
if [ -f "$UTILS_SCRIPT" ]; then
    # shellcheck source=/dev/null
    source "$UTILS_SCRIPT" || true
fi

# logging helpers that prefer log.sh if available
_mf_info(){ 
    if [ "$LOG_API_READY" = true ] && type log_info >/dev/null 2>&1; then
        log_info "$@"
    else
        printf "[INFO] %s\n" "$*"
    fi
}
_mf_warn(){
    if [ "$LOG_API_READY" = true ] && type log_warn >/dev/null 2>&1; then
        log_warn "$@"
    else
        printf "[WARN] %s\n" "$*"
    fi
}
_mf_error(){
    if [ "$LOG_API_READY" = true ] && type log_error >/dev/null 2>&1; then
        log_error "$@"
    else
        printf "[ERROR] %s\n" "$*" >&2
    fi
    if [ "$SILENT_ERRORS" = "true" ]; then
        return 1
    fi
    if [ "$ABORT_ON_ERROR" = "true" ]; then
        exit 1
    fi
    return 1
}

# ===== Utilities internal =====
_safe_mkdir(){ mkdir -p "$1" 2>/dev/null || _mf_error "Falha ao criar $1"; }
_safe_touch(){ : > "$1" 2>/dev/null || _mf_error "Falha ao criar $1"; }

# sanitize package name to safe filename
_mf_safe_name(){ echo "$1" | sed -E 's/[^a-zA-Z0-9_.-]/_/g'; }

# default metafile template
_mf_template(){
cat <<'EOF'
[package]
name={NAME}
version={VERSION}
description={DESCRIPTION}
type=utils
stage=3
dir={DIR}
base_dir={BASE_DIR}
install_prefix=/usr
# sources can be multiple, comma-separated. Each item: url|sha256[:hex]|mirrors=comma_separated
# examples:
# sources=https://ftp.gnu.org/gnu/gcc/gcc-12.2.0.tar.xz|sha256:abcd...,https://mirror/...
sources=
git_url=
git_ref=
patches=
patch_dir=patches
hooks_dir=hooks
environment=PATH=${PATH};CFLAGS=-O2
flags=
multiple_sources=false
ALLOW_PACKAGE_SCRIPTS=false
UPDATE_URL=
EOF
}

# ===== Parsing metafile(s) =====
# Support multiple metafiles in a directory. Each metafile is INI-like with [package] section
# and key=value lines. Values can contain commas; special fields are csv: sources, patches, hooks.

# parse a single metafile into associative array (bash 4+)
_mf_parse_file(){
    local file="$1"
    declare -A out
    local line key val
    local in_section=false
    while IFS= read -r line || [ -n "$line" ]; do
        # skip comments and empty
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" =~ ^[[:space:]]*\[ ]]; then
            in_section=true
            continue
        fi
        if [ "$in_section" = true ]; then
            if ! echo "$line" | grep -q '='; then
                _mf_warn "Linha inválida no metafile $file: $line"
                continue
            fi
            key=$(echo "$line" | sed -E 's/^[[:space:]]*([^=]+)=[[:space:]]*(.*)$/\1/')
            val=$(echo "$line" | sed -E 's/^[[:space:]]*([^=]+)=[[:space:]]*(.*)$/\2/')
            key=$(echo "$key" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
            out["$key"]="$val"
        fi
    done < "$file"

    # output as key=value lines to stdout for consumption
    for k in "${!out[@]}"; do
        printf "%s=%s\n" "$k" "${out[$k]}"
    done
}

# load metafiles from dir into internal index (associative arrays)
mf_init(){
    local dir="${1:-$METAFILE_DIR}"
    if [ ! -d "$dir" ]; then
        _mf_error "Diretório de metafiles não existe: $dir"
        return 1
    fi
    METAFILES_LIST=()
    MF_PACKAGES=() # array of package names
    declare -gA MF_DATA # associative array keyed by pkg|field
    for f in "$dir"/*.ini; do
        [ -f "$f" ] || continue
        local pkgname
        pkgname=$(_mf_safe_name "$(basename "$f" .ini)")
        METAFILES_LIST+=("$f")
        MF_PACKAGES+=("$pkgname")
        # parse
        while IFS= read -r kv || [ -n "$kv" ]; do
            [ -z "$kv" ] && continue
            local k="${kv%%=*}"
            local v="${kv#*=}"
            MF_DATA["$pkgname|$k"]="$v"
        done < <(_mf_parse_file "$f")
        # sanity checks
        if [ -z "${MF_DATA["$pkgname|name"]:-}" ]; then
            MF_DATA["$pkgname|name"]="$pkgname"
        fi
        if [ -z "${MF_DATA["$pkgname|dir"]:-}" ]; then
            MF_DATA["$pkgname|dir"]="${MF_DATA["$pkgname|name"]:-$pkgname}-${MF_DATA["$pkgname|version"]:-unknown}"
        fi
    done

    _mf_info "Carregados ${#MF_PACKAGES[@]} metafiles de $dir"
    export METAFILES_LIST MF_PACKAGES
    return 0
}

# list packages
mf_list_packages(){
    for p in "${MF_PACKAGES[@]:-}"; do
        local ver="${MF_DATA["$p|version"]:-}"
        local typ="${MF_DATA["$p|type"]:-}"
        local stage="${MF_DATA["$p|stage"]:-}"
        printf "%s|%s|%s|%s\n" "$p" "$ver" "$typ" "$stage"
    done
}

# get arbitrary field
mf_get_field(){
    local pkg="$1"; local field="$2"
    echo "${MF_DATA["$pkg|$field"]:-}"
}

# get environment exports for package (as lines "export KEY=VAL")
mf_get_env(){
    local pkg="$1"
    local env="${MF_DATA["$pkg|environment"]:-}"
    # split by ';'
    IFS=';' read -ra pairs <<< "$env"
    for p in "${pairs[@]:-}"; do
        [ -z "$p" ] && continue
        # avoid eval surprises; print safe export lines
        echo "export $p"
    done
}

# resolve sources into normalized lines: name|url|sha256|mirrors|kind
mf_resolve_sources(){
    local pkg="$1"
    local raw="${MF_DATA["$pkg|sources"]:-}"
    local git_url="${MF_DATA["$pkg|git_url"]:-}"
    local git_ref="${MF_DATA["$pkg|git_ref"]:-}"
    local outtmp
    outtmp=$(mktemp)
    # handle csv sources
    if [ -n "$raw" ]; then
        # split respecting commas
        IFS=',' read -ra items <<< "$raw"
        for it in "${items[@]}"; do
            it=$(echo "$it" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            # support format url|sha256:abcd|mirrors=...
            url="$it"
            sha=""
            mirrors=""
            if echo "$it" | grep -q '|' ; then
                url="$(echo "$it" | cut -d'|' -f1)"
                rest="$(echo "$it" | cut -d'|' -f2-)"
                # parse rest for sha256 and mirrors
                if echo "$rest" | grep -q 'sha256:'; then
                    sha="$(echo "$rest" | sed -n 's/.*sha256:\([a-fA-F0-9]\+\).*/\1/p')"
                fi
                if echo "$rest" | grep -q 'mirrors='; then
                    mirrors="$(echo "$rest" | sed -n 's/.*mirrors=\([^|]*\).*/\1/p')"
                fi
            fi
            kind="tar"
            if echo "$url" | grep -E '^git(@|://|:)' >/dev/null 2>&1 || echo "$url" | grep -E '\.git$' >/dev/null 2>&1; then
                kind="git"
            fi
            printf "%s|%s|%s|%s|%s\n" "$pkg" "$url" "$sha" "$mirrors" "$kind" >> "$outtmp"
        done
    fi
    # add git_url if present
    if [ -n "$git_url" ]; then
        printf "%s|%s|%s||git\n" "$pkg" "$git_url" "${MF_DATA["$pkg|git_ref"]:-}" >> "$outtmp"
    fi
    cat "$outtmp"
    rm -f "$outtmp"
}

# convert all packages to download.sh index format (name|url|checksum|mirrors)
mf_to_download_index(){
    local out="${1:-/tmp/downloads.index}"
    : > "$out"
    for p in "${MF_PACKAGES[@]:-}"; do
        while IFS='|' read -r pkg url sha mirrors kind; do
            [ -z "$url" ] && continue
            # prefer sha if formatted; if empty, leave blank
            if [ -n "$sha" ]; then
                checksum="sha256:$sha"
            else
                checksum=""
            fi
            # name in index: pkg-basename
            name="$(basename "${url%%\?*}")"
            printf "%s|%s|%s|%s\n" "$name" "$url" "$checksum" "$mirrors" >> "$out"
        done < <(mf_resolve_sources "$p")
    done
    _mf_info "Índice de downloads gerado em $out"
    echo "$out"
}

# create a new metafile skeleton in directory: create <dir>/<basename>.ini
mf_create_metafile(){
    local base_dir="$1"
    local pkgname="$2"
    if [ -z "$base_dir" ] || [ -z "$pkgname" ]; then
        _mf_error "Uso: mf_create_metafile <base_dir> <pkgname>"
        return 1
    fi
    _safe_mkdir "$base_dir"
    local safepkg=$(_mf_safe_name "$pkgname")
    local filename="$base_dir/${safepkg}.ini"
    if [ -f "$filename" ]; then
        _mf_warn "Metafile já existe: $filename"
        return 1
    fi
    # create with template, replace placeholders
    local tpl
    tpl=$(_mf_template)
    tpl="${tpl//\{NAME\}/$safepkg}"
    tpl="${tpl//\{VERSION\}/0.0}"
    tpl="${tpl//\{DESCRIPTION\}/\"Descrição do pacote $safepkg\"}"
    tpl="${tpl//\{DIR\}/$safepkg-0.0}"
    tpl="${tpl//\{BASE_DIR\}/$(pwd)}"
    printf "%s\n" "$tpl" > "$filename"
    _mf_info "Metafile criado: $filename"
    echo "$filename"
}

# run hooks for a package and a stage (pre-prepare, post-build, etc.)
mf_run_hook(){
    local pkg="$1"
    local stage="$2" # pre-prepare, post-build, etc.
    shift 2
    local args=("$@")
    local hooks_dir="${MF_DATA["$pkg|hooks_dir"]:-hooks}"
    local pkgdir="${MF_DATA["$pkg|dir"]:-$pkg}"
    local local_hooks_dir="${pkgdir}/${hooks_dir}/${stage}"
    local global_hooks_dir="${GLOBAL_HOOKS_DIR}/${stage}"
    local executed=0
    # run global hooks first
    if [ -d "$global_hooks_dir" ]; then
        for h in "$(ls -1 "$global_hooks_dir" 2>/dev/null | sort)" ; do
            [ -x "$global_hooks_dir/$h" ] || continue
            _mf_info "Executando hook global $global_hooks_dir/$h for $pkg $stage"
            "$global_hooks_dir/$h" "${args[@]}" || { _mf_warn "Hook global falhou: $h"; [[ "$SILENT_ERRORS" == "true" ]] || return 1; }
            executed=1
        done
    fi
    # run package hooks
    if [ -d "$local_hooks_dir" ]; then
        for h in "$local_hooks_dir"/*; do
            [ -x "$h" ] || continue
            _mf_info "Executando hook local $h for $pkg $stage"
            "$h" "${args[@]}" || { _mf_warn "Hook local falhou: $h"; [[ "$SILENT_ERRORS" == "true" ]] || return 1; }
            executed=1
        done
    fi
    return 0
}

# prepare: fetch/extract/clone/apply patches/run prepare script
mf_prepare(){
    local pkg="$1"
    [ -z "$pkg" ] && _mf_error "mf_prepare: package required"
    local basedir="${MF_DATA["$pkg|base_dir"]:-$PWD/build}"
    local dir="${MF_DATA["$pkg|dir"]:-$pkg}"
    local build_root="$basedir/$dir"
    _safe_mkdir "$basedir"
    # lock package dir to avoid concurrent prepare/build
    if type util_lock >/dev/null 2>&1; then
        util_lock "pkg-$pkg" || _mf_error "Falha ao obter lock para $pkg"
    fi
    mf_run_hook "$pkg" "pre-prepare"
    _mf_info "Preparando pacote $pkg em $build_root"
    _safe_mkdir "$build_root"
    # resolve sources
    local any_failed=0
    while IFS='|' read -r _pkg url sha mirrors kind; do
        [ -z "$url" ] && continue
        case "$kind" in
            git)
                # clone or fetch
                if [ -d "$build_root/.git" ]; then
                    _mf_info "Reutilizando clone existente para $pkg"
                    (cd "$build_root" && git fetch --all --tags) >> "${build_root}/mf-prepare.log" 2>&1 || true
                else
                    _mf_info "Clonando $url into $build_root"
                    git clone --depth 1 "$url" "$build_root" >> "${build_root}/mf-prepare.log" 2>&1 || { _mf_warn "git clone falhou: $url"; any_failed=1; }
                    if [ -n "${MF_DATA["$pkg|git_ref"]:-}" ]; then
                        (cd "$build_root" && git checkout "${MF_DATA["$pkg|git_ref"]}") >> "${build_root}/mf-prepare.log" 2>&1 || true
                    fi
                fi
                ;;
            *)
                # tarball or file: use download.sh if available
                local fname="$(basename "${url%%\?*}")"
                local dest="$basedir/$fname"
                if [ -f "$dest" ]; then
                    _mf_info "Arquivo já em cache: $dest"
                else
                    if [ -x "$DOWNLOAD_SCRIPT" ]; then
                        # use download.sh API if sourced
                        if type dl_add_source >/dev/null 2>&1; then
                            dl_add_source "$url" "sha256:${sha}" "$mirrors" "$pkg" || true
                        fi
                        # instruct: user or orchestrator should run download.sh fetch-all
                        _mf_info "Fonte registrada para download: $url"
                    else
                        _mf_warn "download.sh não encontrado; não será baixado: $url"
                    fi
                fi
                # when archive exists at dest, extract
                if [ -f "$dest" ]; then
                    _mf_info "Extraindo $dest para $build_root"
                    case "$dest" in
                        *.tar.gz|*.tgz) tar -xzf "$dest" -C "$build_root" --strip-components=1 >> "${build_root}/mf-prepare.log" 2>&1 || { _mf_warn "Falha ao extrair $dest"; any_failed=1; } ;;
                        *.tar.xz) tar -xJf "$dest" -C "$build_root" --strip-components=1 >> "${build_root}/mf-prepare.log" 2>&1 || { _mf_warn "Falha ao extrair $dest"; any_failed=1; } ;;
                        *.tar.bz2) tar -xjf "$dest" -C "$build_root" --strip-components=1 >> "${build_root}/mf-prepare.log" 2>&1 || { _mf_warn "Falha ao extrair $dest"; any_failed=1; } ;;
                        *.zip) unzip -q "$dest" -d "$build_root" || { _mf_warn "Falha ao extrair $dest"; any_failed=1; } ;;
                        *) _mf_warn "Formato não reconhecido para extração: $dest"; any_failed=1 ;;
                    esac
                fi
                ;;
        esac
    done < <(mf_resolve_sources "$pkg")

    # apply patches
    local patches="${MF_DATA["$pkg|patches"]:-}"
    local patch_dir="${MF_DATA["$pkg|patch_dir"]:-patches}"
    if [ -n "$patches" ]; then
        IFS=',' read -ra pitems <<< "$patches"
        for p in "${pitems[@]}"; do
            p="$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            local ppath="$patch_dir/$p"
            if [ ! -f "$ppath" ]; then
                _mf_warn "Patch não encontrado: $ppath"
                any_failed=1
                continue
            fi
            (cd "$build_root" && patch -p1 < "$ppath" >> "${build_root}/mf-prepare.log" 2>&1) || { _mf_warn "Falha aplicando patch $ppath"; any_failed=1; }
        done
    fi

    # execute package prepare script
    if [ -n "${MF_DATA["$pkg|prepare"]:-}" ]; then
        local prep="${MF_DATA["$pkg|prepare"]}"
        _mf_info "Executando prepare definido: $prep"
        (cd "$build_root" && bash -e -o pipefail -c "$prep") >> "${build_root}/mf-prepare.log" 2>&1 || { _mf_warn "Prepare falhou: $prep"; any_failed=1; }
    elif [ -x "$build_root/prepare.sh" ]; then
        if [ "$ALLOW_PACKAGE_SCRIPTS" = "true" ]; then
            _mf_info "Executando $build_root/prepare.sh"
            (cd "$build_root" && ./prepare.sh) >> "${build_root}/mf-prepare.log" 2>&1 || { _mf_warn "prepare.sh falhou"; any_failed=1; }
        else
            _mf_warn "prepare.sh existe mas execução de scripts de pacote está desabilitada"
        fi
    fi

    mf_run_hook "$pkg" "post-prepare"
    if [ "$any_failed" -ne 0 ]; then
        _mf_warn "Algumas ações de preparação falharam para $pkg (ver ${build_root}/mf-prepare.log)"
        return 1
    fi
    touch "${build_root}/.mf_prepared"
    _mf_info "mf_prepare concluído para $pkg"
    return 0
}

# Build: either call build script or attempt canonical flows
mf_build(){
    local pkg="$1"
    [ -z "$pkg" ] && _mf_error "mf_build: package required"
    local basedir="${MF_DATA["$pkg|base_dir"]:-$PWD/build}"
    local dir="${MF_DATA["$pkg|dir"]:-$pkg}"
    local build_root="$basedir/$dir"
    mf_run_hook "$pkg" "pre-build"
    _mf_info "Iniciando build para $pkg in $build_root"
    if [ -n "${MF_DATA["$pkg|build"]:-}" ]; then
        local cmd="${MF_DATA["$pkg|build"]}"
        (cd "$build_root" && bash -e -o pipefail -c "$cmd") >> "${build_root}/mf-build.log" 2>&1 || { _mf_warn "Build script falhou"; return 1; }
    elif [ -f "$build_root/configure" ]; then
        (cd "$build_root" && ./configure ${MF_DATA["$pkg|flags"]:-} ) >> "${build_root}/mf-build.log" 2>&1 || { _mf_warn "configure falhou"; return 1; }
        (cd "$build_root" && make -j"$(nproc)") >> "${build_root}/mf-build.log" 2>&1 || { _mf_warn "make falhou"; return 1; }
    elif [ -f "$build_root/CMakeLists.txt" ]; then
        _mf_info "Usando cmake flow"
        (cd "$build_root" && mkdir -p build && cd build && cmake .. && make -j"$(nproc)") >> "${build_root}/mf-build.log" 2>&1 || { _mf_warn "cmake build falhou"; return 1; }
    elif [ -f "$build_root/Makefile" ]; then
        (cd "$build_root" && make -j"$(nproc)") >> "${build_root}/mf-build.log" 2>&1 || { _mf_warn "make falhou"; return 1; }
    else
        _mf_warn "Nenhum método de build detectado para $pkg"
        return 1
    fi
    mf_run_hook "$pkg" "post-build"
    touch "${build_root}/.mf_built"
    _mf_info "Build concluído para $pkg"
    return 0
}

mf_check(){
    local pkg="$1"
    [ -z "$pkg" ] && _mf_error "mf_check: package required"
    local basedir="${MF_DATA["$pkg|base_dir"]:-$PWD/build}"
    local dir="${MF_DATA["$pkg|dir"]:-$pkg}"
    local build_root="$basedir/$dir"
    mf_run_hook "$pkg" "pre-check"
    _mf_info "Executando checks para $pkg"
    if [ -n "${MF_DATA["$pkg|check"]:-}" ]; then
        (cd "$build_root" && bash -e -o pipefail -c "${MF_DATA["$pkg|check"]}") >> "${build_root}/mf-check.log" 2>&1 || { _mf_warn "check script falhou"; return 1; }
    elif [ -f "$build_root/Makefile" ]; then
        (cd "$build_root" && make check) >> "${build_root}/mf-check.log" 2>&1 || { _mf_warn "make check falhou"; return 1; }
    else
        _mf_warn "Nenhum teste detectado para $pkg"
    fi
    mf_run_hook "$pkg" "post-check"
    touch "${build_root}/.mf_checked"
    _mf_info "Checks concluídos para $pkg"
    return 0
}

mf_install(){
    local pkg="$1"
    [ -z "$pkg" ] && _mf_error "mf_install: package required"
    local basedir="${MF_DATA["$pkg|base_dir"]:-$PWD/build}"
    local dir="${MF_DATA["$pkg|dir"]:-$pkg}"
    local build_root="$basedir/$dir"
    local install_prefix="${MF_DATA["$pkg|install_prefix"]:-/usr}"
    mf_run_hook "$pkg" "pre-install"
    _mf_info "Instalando $pkg para $install_prefix"
    if [ -n "${MF_DATA["$pkg|install"]:-}" ]; then
        (cd "$build_root" && bash -e -o pipefail -c "${MF_DATA["$pkg|install"]}") >> "${build_root}/mf-install.log" 2>&1 || { _mf_warn "install script falhou"; return 1; }
    elif [ -f "$build_root/Makefile" ]; then
        (cd "$build_root" && make install DESTDIR="${install_prefix}") >> "${build_root}/mf-install.log" 2>&1 || { _mf_warn "make install falhou"; return 1; }
    else
        _mf_warn "Nenhum método de instalação detectado para $pkg"
        return 1
    fi
    mf_run_hook "$pkg" "post-install"
    touch "${build_root}/.mf_installed"
    _mf_info "Instalação concluída para $pkg"
    return 0
}

# check updates: basic implementation (HEAD or github tags)
mf_check_updates(){
    local pkg="$1"
    local url="${MF_DATA["$pkg|update_url"]:-}"
    if [ -z "$url" ]; then
        _mf_warn "update_url não definido para $pkg"
        return 1
    fi
    if command -v curl >/dev/null 2>&1; then
        local head
        head=$(curl -sIL --max-time 15 "$url" | tr -d '\r' | sed -n '1,30p')
        echo "$head"
        return 0
    else
        _mf_warn "curl não disponível para checar atualizações"
        return 1
    fi
}

# create metafile(s) in directory. supports multiple names separated by comma
mf_create_many(){
    local base_dir="$1"
    local names="$2"
    IFS=',' read -ra arr <<< "$names"
    for n in "${arr[@]}"; do
        mf_create_metafile "$base_dir" "$n" || true
    done
}

# self-test: create tmp metafile and run parse
mf_self_test(){
    local tmpdir
    tmpdir=$(mktemp -d)
    _safe_mkdir "$tmpdir"
    local f="$tmpdir/gcc.ini"
    cat > "$f" <<'EOF'
[package]
name=gcc-pass1
version=12.2.0
description=GCC pass 1 example
type=toolchain
stage=1
dir=gcc-pass1-12.2.0
base_dir=/tmp/lfs-build
sources=https://example.org/gcc-12.2.0.tar.xz|sha256:deadbeef
patches=fix1.patch,fix2.patch
patch_dir=patches
hooks_dir=hooks
environment=PATH=/usr/local/bin;CFLAGS=-O2
EOF
    mf_init "$tmpdir"
    mf_list_packages
    mf_to_download_index "/tmp/test-downloads.index"
    _mf_info "Self-test completo. Temp dir: $tmpdir"
}

# CLI
_mf_usage(){
cat <<EOF
Usage: $(basename "$0") [--dir DIR] <command> [args...]
Commands:
  --dir DIR            Directory of metafiles (default: \$METAFILE_DIR)
  --init [DIR]         Load metafiles from DIR (or default)
  --list               List loaded packages
  --get PKG FIELD      Get field value for package
  --env PKG            Print environment exports for package
  --to-download INDEX  Generate download index for download.sh
  --create BASE NAME   Create metafile(s): e.g. --create /base "gcc,gcc-pass1"
  --self-test          Run internal self-test
  --help
EOF
}

# Dispatcher
if [ "${BASH_SOURCE[0]}" == "$0" ]; then
    cmd=""
    dir_arg=""
    if [ "$#" -eq 0 ]; then _mf_usage; exit 0; fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dir) dir_arg="$2"; shift 2;;
            --init) mf_init "${2:-$dir_arg:-$METAFILE_DIR}"; exit $?;;
            --list) mf_list_packages; exit 0;;
            --get) mf_get_field "$2" "$3"; exit 0;;
            --env) mf_get_env "$2"; exit 0;;
            --to-download) mf_to_download_index "$2"; exit 0;;
            --create) mf_create_many "$2" "$3"; exit $?;
            --self-test) mf_self_test; exit 0;;
            --help) _mf_usage; exit 0;;
            *) echo "Unknown arg: $1"; _mf_usage; exit 2;;
        esac
    done
fi

# export API
export -f mf_init mf_list_packages mf_get_field mf_get_env mf_resolve_sources mf_to_download_index mf_create_metafile mf_run_hook mf_prepare mf_build mf_check mf_install mf_check_updates mf_create_many mf_self_test
