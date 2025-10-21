#!/usr/bin/env bash
# download.sh - Gerenciador de downloads para LFS automated builder
# Requisitos: bash, coreutils (sha256sum, numfmt), curl/wget/aria2c (pelo menos um)
# Instalar em /usr/bin/download.sh
set -o pipefail
shopt -s nullglob

# Defaults (pode ser sobrescrito por env)
: "${DOWNLOAD_DIR:=/var/cache/lfs-sources}"
: "${TMP_DIR:=/var/cache/lfs-sources/tmp}"
: "${DOWNLOAD_INDEX:=/var/cache/lfs-sources/downloads.index}"
: "${DOWNLOAD_RETRY:=3}"
: "${DOWNLOAD_TIMEOUT:=60}"
: "${MAX_PARALLEL:=$(nproc 2>/dev/null || echo 1)}"
: "${VERIFY_CHECKSUM:=true}"
: "${SILENT_ERRORS:=false}"
: "${OFFLINE:=false}"
: "${LOG_SCRIPT:=/usr/bin/logs.sh}"
: "${ABORT_ON_ERROR:=true}"

export DOWNLOAD_DIR TMP_DIR DOWNLOAD_INDEX DOWNLOAD_RETRY DOWNLOAD_TIMEOUT MAX_PARALLEL VERIFY_CHECKSUM SILENT_ERRORS OFFLINE LOG_SCRIPT ABORT_ON_ERROR

# try to source log.sh if available
if [ -f "$LOG_SCRIPT" ]; then
    # shellcheck source=/dev/null
    source "$LOG_SCRIPT"
else
    echo "Aviso: $LOG_SCRIPT não encontrado. Funções log_* não estarão disponíveis." >&2
    # create stub functions to avoid errors
    log_init(){ :; }
    log_step_start(){ :; }
    log_step_end(){ :; }
    log_info(){ :; }
    log_warn(){ echo "WARN: $*"; }
    log_error(){ echo "ERROR: $*"; if [ "$ABORT_ON_ERROR" = true ]; then exit 1; fi; }
    log_progress(){ :; }
    log_get_path(){ echo "/dev/null"; }
fi

# Utilities
_now(){ date +"%Y-%m-%d %H:%M:%S"; }
_date(){ date +"%F"; }
_numfmt(){ if command -v numfmt >/dev/null 2>&1; then numfmt --to=iec --suffix=B --format=%.1f "$1" 2>/dev/null || echo "$1"; else printf "%sB" "$1"; fi; }
_safe_mkdir(){ mkdir -p "$1" 2>/dev/null || { log_warn "Falha ao criar $1"; return 1; } }

# Detect available downloader
_detect_downloader(){
    if command -v aria2c >/dev/null 2>&1; then
        DOWNLOADER="aria2c"
    elif command -v curl >/dev/null 2>&1; then
        DOWNLOADER="curl"
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOADER="wget"
    else
        DOWNLOADER=""
    fi
    export DOWNLOADER
}

# Parse simple INI metafile (key=value per line under [sources])
# Format expected:
# [sources]
# name=url checksum=sha256:abcd... mirrors=url2,url3
parse_metafile_ini(){
    local ini="$1"
    # Output lines: name|url|checksum|mirrors
    awk '
    BEGIN{section=""}
    /^\s*\[/{gsub(/[][]/,""); section=tolower($0); next}
    section=="[sources]" && NF>0{
        # parse key=value pairs separated by spaces (name=url checksum=sha:... mirrors=...)
        line=$0
        name=""; url=""; checksum=""; mirrors=""
        n=split(line, a, /[ \t]+/)
        for(i=1;i<=n;i++){
            if(a[i] ~ /=/){
                split(a[i], kv, "=")
                k=kv[1]; v=kv[2]
                if(k=="name") name=v
                else if(k=="url") url=v
                else if(k=="checksum") checksum=v
                else if(k=="mirrors") mirrors=v
            }
        }
        if(url!=""){ printf("%s|%s|%s|%s\n", (name==""?url:name), url, checksum, mirrors) }
    }' "$ini"
}

# Create index if not exists
dl_init_cache(){
    # Create directories with fallback to home if /var not writable
    if ! _safe_mkdir "$DOWNLOAD_DIR"; then
        DOWNLOAD_DIR="${HOME}/.cache/lfs-sources"
        _safe_mkdir "$DOWNLOAD_DIR" || { log_error "Não foi possível criar diretório de downloads"; return 1; }
    fi
    _safe_mkdir "$TMP_DIR" || true
    touch "$DOWNLOAD_INDEX" 2>/dev/null || true
    log_info "Cache inicializado em $DOWNLOAD_DIR (tmp: $TMP_DIR). Index: $DOWNLOAD_INDEX"
    echo "$DOWNLOAD_DIR"
}

# Add source to index: URL [checksum] [mirrors comma-separated]
# Index format: name|url|checksum|mirrors
dl_add_source(){
    local url="$1"; local checksum="$2"; local mirrors="$3"; local name="$4"
    if [ -z "$url" ]; then log_error "dl_add_source: url required"; return 1; fi
    if [ -z "$name" ]; then
        # derive name from url
        name="$(basename "${url%%\?*}")"
    fi
    printf "%s|%s|%s|%s\n" "$name" "$url" "$checksum" "$mirrors" >> "$DOWNLOAD_INDEX"
    log_info "Fonte adicionada ao índice: $name -> $url"
}

# Clean cache: remove .part, old files, or all
dl_clean_cache(){
    local all=false
    if [ "$1" = "--all" ]; then all=true; fi
    if [ "$all" = true ]; then
        log_warn "Limpando todo cache em $DOWNLOAD_DIR"
        rm -rf "$DOWNLOAD_DIR"/* || true
        dl_init_cache
        return 0
    fi
    # remove stale partials
    find "$DOWNLOAD_DIR" -type f -name "*.part" -o -name "*.aria2" -delete 2>/dev/null || true
    # optionally remove files older than retention (30d)
    find "$DOWNLOAD_DIR" -type f -name "*.log" -mtime +30 -delete 2>/dev/null || true
    log_info "Cache limpo (limpeza seletiva)"
}

# list cache status
dl_list(){
    echo "Diretório de cache: $DOWNLOAD_DIR"
    ls -lh "$DOWNLOAD_DIR" 2>/dev/null || true
    echo "Índice: $DOWNLOAD_INDEX"
    sed -n '1,200p' "$DOWNLOAD_INDEX" 2>/dev/null || true
}

# compute sha256 of a file
_compute_sha256(){
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    else
        echo ""
    fi
}

# verify checksum: supports formats like sha256:abcd... or plain hex
dl_verify(){
    local file="$1"; local checksum="$2"
    if [ -z "$file" ] || [ ! -f "$file" ]; then log_warn "dl_verify: file not found: $file"; return 2; fi
    if [ -z "$checksum" ] || [ "$VERIFY_CHECKSUM" != true ]; then
        log_info "dl_verify: checksum not provided or verification desabilitada"
        return 0
    fi
    # normalize checksum
    local algo="sha256"
    local expected="$checksum"
    if [[ "$checksum" == *:* ]]; then
        algo="${checksum%%:*}"
        expected="${checksum#*:}"
    fi
    if [ "$algo" != "sha256" ]; then
        log_warn "Algoritmo $algo não suportado; saltando verificação"
        return 0
    fi
    local got
    got="$(_compute_sha256 "$file")"
    if [ -z "$got" ]; then
        log_warn "Nenhuma ferramenta de checksum disponível"
        return 2
    fi
    if [ "$got" = "$expected" ]; then
        log_info "Verificação SHA256 OK: $(basename "$file")"
        return 0
    else
        log_warn "Checksum mismatch: expected=$expected got=$got"
        return 1
    fi
}

# Check free disk space (in KB)
_check_disk_space(){
    local dir="$1"
    local needed_kb="$2"
    local avail_kb
    avail_kb=$(df -P "$dir" | awk 'NR==2{print $4}')
    if [ -z "$avail_kb" ]; then return 0; fi
    if [ -n "$needed_kb" ] && [ "$avail_kb" -lt "$needed_kb" ]; then
        return 1
    fi
    return 0
}

# smart resume using available downloader
dl_resume(){
    local target="$1"
    if [ -z "$target" ]; then log_error "dl_resume requires target"; return 1; fi
    if [ "$DOWNLOADER" = "aria2c" ]; then
        aria2c -c -d "$(dirname "$target")" -o "$(basename "$target")" --check-integrity=true || return $?
    elif [ "$DOWNLOADER" = "curl" ]; then
        curl -C - -L -o "$target" "$2" || return $?
    elif [ "$DOWNLOADER" = "wget" ]; then
        wget -c -O "$target" "$2" || return $?
    else
        log_error "Nenhum downloader disponível para resume"
        return 2
    fi
}

# internal: single-file fetch (used by parallel workers)
_dl_fetch_single(){
    local name="$1"; local url="$2"; local checksum="$3"; local mirrors="$4"
    local filename
    filename="$(basename "${url%%\?*}")"
    local dest="$DOWNLOAD_DIR/$filename"
    local tmpfile="$TMP_DIR/$filename.part"
    local attempts=0
    local success=false

    # quick skip if in offline mode and file exists & valid
    if [ "$OFFLINE" = true ]; then
        if [ -f "$dest" ]; then
            if dl_verify "$dest" "$checksum"; then
                log_info "Usando cache offline para $filename"
                log_progress 100 100 "$filename"
                return 0
            else
                log_warn "Arquivo cache corrompido (offline): $filename"
                return 1
            fi
        else
            log_error "Offline e arquivo não encontrado: $filename"
            return 1
        fi
    fi

    # try url + mirrors
    local try_urls=("$url")
    IFS=',' read -ra extra_mirrors <<< "$mirrors"
    for m in "${extra_mirrors[@]}"; do
        [ -n "$m" ] && try_urls+=("$m")
    done

    for u in "${try_urls[@]}"; do
        attempts=0
        while [ $attempts -lt "$DOWNLOAD_RETRY" ]; do
            attempts=$((attempts+1))
            # ensure space check if Content-Length known (best-effort: use curl head)
            if command -v curl >/dev/null 2>&1; then
                content_len=$(curl -sI -L "$u" | awk '/Content-Length/ {print $2}' | tr -d '\r' | tail -1)
            else
                content_len=""
            fi
            if [ -n "$content_len" ]; then
                # convert to KB
                needed_kb=$((content_len/1024+1024))
                if ! _check_disk_space "$DOWNLOAD_DIR" "$needed_kb"; then
                    log_error "Espaço insuficiente em disco para $filename (precisa ~${needed_kb}KB)"
                    return 1
                fi
            fi

            # perform download according to available tool
            log_info "Tentando baixar ($attempts/${DOWNLOAD_RETRY}): $u -> $filename (tmp: $tmpfile)"
            if [ "$DOWNLOADER" = "aria2c" ]; then
                aria2c -x4 -s4 -c -d "$DOWNLOAD_DIR" -o "$filename" --timeout="$DOWNLOAD_TIMEOUT" --retry-wait=5 --max-tries=5 "$u" >> "$STEP_LOG_PATH" 2>&1
                rc=$?
            elif [ "$DOWNLOADER" = "curl" ]; then
                # use tmpfile and resume
                _safe_mkdir "$(dirname "$tmpfile")"
                curl -fL --retry 3 --retry-delay 5 --connect-timeout "$DOWNLOAD_TIMEOUT" -C - -o "$tmpfile" "$u" >> "$STEP_LOG_PATH" 2>&1
                rc=$?
                if [ $rc -eq 0 ]; then
                    mv -f "$tmpfile" "$dest"
                fi
            elif [ "$DOWNLOADER" = "wget" ]; then
                _safe_mkdir "$(dirname "$tmpfile")"
                wget -c -O "$tmpfile" "$u" >> "$STEP_LOG_PATH" 2>&1
                rc=$?
                if [ $rc -eq 0 ]; then
                    mv -f "$tmpfile" "$dest"
                fi
            else
                rc=2
            fi

            if [ $rc -eq 0 ]; then
                # verify
                if dl_verify "$dest" "$checksum"; then
                    log_info "Download concluído: $filename"
                    success=true
                    break 2
                else
                    log_warn "Checksum inválido após download: $filename; removendo e tentando novamente"
                    rm -f "$dest" || true
                fi
            else
                log_warn "Falha ao baixar $u (rc=$rc). Tentando novamente..."
                sleep $((attempts * 2))
            fi
        done
    done

    if [ "$success" = true ]; then
        log_progress 100 100 "$filename"
        return 0
    else
        log_error "Falha ao baixar $filename após tentativas"
        return 1
    fi
}

# Parallel manager: maintains semaphore using FIFO
_dl_parallel_worker(){
    local name="$1"; local url="$2"; local checksum="$3"; local mirrors="$4"
    _dl_fetch_single "$name" "$url" "$checksum" "$mirrors"
    local rc=$?
    return $rc
}

dl_fetch_all(){
    _detect_downloader
    dl_init_cache >/dev/null
    log_info "Iniciando fetch de todos do índice"
    local pids=()
    local active=0
    local total
    total=$(wc -l < "$DOWNLOAD_INDEX" 2>/dev/null || echo 0)
    local i=0

    # create a temp worklist
    local workfile
    workfile="$(mktemp -t dlwork.XXXX)"
    trap 'rm -f "$workfile"' EXIT
    cp "$DOWNLOAD_INDEX" "$workfile"

    while IFS='|' read -r name url checksum mirrors; do
        i=$((i+1))
        # skip empty lines
        [ -z "$url" ] && continue
        # wait if active >= MAX_PARALLEL
        while [ "$active" -ge "$MAX_PARALLEL" ]; do
            wait -n || true
            # recompute active
            active=$(jobs -rp | wc -l)
        done
        # launch worker in background
        (
            # child process: reuse logs; source log.sh ensures exported functions available
            log_info "Worker iniciando para $url"
            _dl_parallel_worker "$name" "$url" "$checksum" "$mirrors"
        ) &
        pids+=("$!")
        active=$(jobs -rp | wc -l)
        log_progress "$i" "$total" "batch-fetch"
    done < "$workfile"

    # wait all
    wait
    log_info "Fetch_all concluído"
}

# fetch single URL (CLI)
dl_fetch(){
    _detect_downloader
    dl_init_cache >/dev/null
    local url="$1"
    local checksum="$2"
    local mirrors="$3"
    local name="$4"
    if [ -z "$url" ]; then log_error "dl_fetch requer URL"; return 1; fi
    _dl_fetch_single "$name" "$url" "$checksum" "$mirrors"
}

# Resolve from metafile.ini - expects section [sources], lines parsed by parse_metafile_ini
dl_auto_resolve(){
    local metafile="$1"
    if [ -z "$metafile" ] || [ ! -f "$metafile" ]; then
        log_error "metafile.ini não encontrado: $metafile"
        return 1
    fi
    # parse and append to index
    while IFS='|' read -r name url checksum mirrors; do
        dl_add_source "$url" "$checksum" "$mirrors" "$name"
    done < <(parse_metafile_ini "$metafile")
    log_info "Metafile integrado: $metafile"
}

# verify-only mode: check files in index
dl_verify_all(){
    if [ ! -f "$DOWNLOAD_INDEX" ]; then log_error "Index não existe: $DOWNLOAD_INDEX"; return 1; fi
    local rc_all=0
    while IFS='|' read -r name url checksum mirrors; do
        [ -z "$url" ] && continue
        local filename="$(basename "${url%%\?*}")"
        local file="$DOWNLOAD_DIR/$filename"
        if [ ! -f "$file" ]; then
            log_warn "Arquivo ausente: $filename"
            rc_all=2
            continue
        fi
        dl_verify "$file" "$checksum"
        rc=$?
        if [ $rc -ne 0 ]; then rc_all=1; fi
    done < "$DOWNLOAD_INDEX"
    return $rc_all
}

# self test (simula downloads pequenos usando /dev/zero -> to temp files)
cli_self_test(){
    dl_init_cache
    log_info "Iniciando self-test do download.sh"
    # create fake entries using file:// urls (requires wget/curl support)
    tmpf1="$DOWNLOAD_DIR/selftest-1.bin"
    dd if=/dev/zero of="$tmpf1" bs=1K count=10 &>/dev/null || true
    # create index entry pointing to local file
    echo "selftest1|file://$tmpf1||" > "$DOWNLOAD_INDEX"
    dl_fetch_all
    log_info "Self-test concluído"
}

# CLI
_usage(){
    cat <<EOF
Usage: $(basename "$0") [options] <command> [args...]
Options:
  --ini                     Cria diretórios e arquivos necessários (cache, índice)
  --offline                 Usa apenas cache local (não baixa)
  --verify-only             Apenas verifica checksums de arquivos no índice
  --silent-errors true|false Habilita/desabilita erros silenciosos
  --retry N                 Número de tentativas por arquivo (default $DOWNLOAD_RETRY)
  --max-parallel N          Número máximo de downloads simultâneos (default $MAX_PARALLEL)
Commands:
  add <url> [checksum] [mirrors] [name]   Adiciona fonte ao índice
  fetch <url> [checksum] [mirrors] [name] Baixa arquivo único
  fetch-all                               Baixa tudo do índice (paralelo)
  resume <file> <url>                     Retoma download (se aplicável)
  list                                    Lista cache e índice
  clean [--all]                           Limpa cache
  auto-resolve <metafile.ini>             Adiciona entradas a partir do metafile.ini
  verify <file> [checksum]                Verifica um arquivo
  verify-all                              Verifica todo o índice
  self-test                               Executa autoteste
  help                                    Mostra esta ajuda
EOF
}

# CLI dispatcher
if [ "$#" -gt 0 ]; then
    case "$1" in
        --ini)
            dl_init_cache
            exit 0
            ;;
        --offline)
            OFFLINE=true; shift; ;;
        --verify-only)
            VERIFY_CHECKSUM=true
            dl_verify_all
            exit $?
            ;;
        --silent-errors)
            SILENT_ERRORS="$2"; shift 2 || true; ;;
        --retry)
            DOWNLOAD_RETRY="$2"; shift 2 || true; ;;
        --max-parallel)
            MAX_PARALLEL="$2"; shift 2 || true; ;;
    esac
    case "$1" in
        add)
            shift
            dl_add_source "$1" "$2" "$3" "$4"
            exit $?
            ;;
        fetch)
            shift
            dl_fetch "$1" "$2" "$3" "$4"
            exit $?
            ;;
        fetch-all)
            dl_fetch_all
            exit $?
            ;;
        resume)
            shift
            dl_resume "$1" "$2"
            exit $?
            ;;
        list)
            dl_list
            exit $?
            ;;
        clean)
            shift
            dl_clean_cache "$1"
            exit $?
            ;;
        auto-resolve)
            shift
            dl_auto_resolve "$1"
            exit $?
            ;;
        verify)
            shift
            dl_verify "$1" "$2"
            exit $?
            ;;
        verify-all)
            dl_verify_all
            exit $?
            ;;
        self-test)
            cli_self_test
            exit $?
            ;;
        help|-h|--help)
            _usage; exit 0;;
        *)
            echo "Comando desconhecido: $1" >&2
            _usage
            exit 2
            ;;
    esac
fi

# If sourced, export functions for other scripts
export -f dl_init_cache dl_add_source dl_fetch dl_fetch_all dl_verify dl_clean_cache dl_list dl_resume dl_auto_resolve dl_verify_all dl_fetch_all dl_auto_resolve _dl_fetch_single

# end of file
