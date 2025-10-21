#!/usr/bin/env bash
# log.sh - Sistema de logging para LFS automated builder
# Compatível com bash (requer bash para arrays e traps)
# Instale em /usr/bin/logs.sh (ou ./logs.sh para testes)

set -o pipefail
# não set -e: queremos controlar erros e permitir tratamento

# ----------------------------
# Configurações padrão (podem ser sobrescritas externamente)
# ----------------------------
: "${LOG_DIR:=/var/log/lfs-builder}"
: "${LOG_LEVEL:=INFO}"
: "${LOG_PREFIX:=lfs-build}"
: "${SHOW_ON_SCREEN:=true}"
: "${STEP_TOTAL:=0}"
: "${CPU_SAMPLING_INTERVAL:=0.2}"
: "${LOG_RETENTION_DAYS:=30}"
: "${ABORT_ON_ERROR:=true}"
: "${USE_FLOCK:=true}"
: "${SILENT_ERRORS:=false}"

# internals
STEP_CURRENT=0
STEP_NAME=""
STEP_LOG_PATH=""
START_TIME=0
LOG_FD=200
LOCK_FD=201

# Ensure exported variables and functions available to sourced scripts
export LOG_DIR LOG_LEVEL LOG_PREFIX SHOW_ON_SCREEN STEP_TOTAL CPU_SAMPLING_INTERVAL LOG_RETENTION_DAYS ABORT_ON_ERROR USE_FLOCK SILENT_ERRORS

# ----------------------------
# Utils internas
# ----------------------------
_now() { date +"%Y-%m-%d %H:%M:%S"; }
_date() { date +"%Y-%m-%d"; }
_epoch() { date +%s; }

# safe echo that supports -n
_e() { printf "%b\n" "$*"; }

# write raw to log file with lock if enabled
_write_log_file() {
    local msg="$1"
    if [ "$USE_FLOCK" = true ] && command -v flock >/dev/null 2>&1; then
        # open fd if not opened
        if ! eval "exec ${LOG_FD}>&-" 2>/dev/null; then :; fi
        # use a temporary lock file per log path
        local lockfile="${STEP_LOG_PATH}.lock"
        mkdir -p "$(dirname "$lockfile")"
        # ensure lock fd
        exec {LOCK_FD}>>"$lockfile" || true
        flock -s "${LOCK_FD}" -w 5 2>/dev/null || true
        printf "%s\n" "$msg" >>"$STEP_LOG_PATH" 2>/dev/null || true
        # release
        flock -u "${LOCK_FD}" 2>/dev/null || true
        eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
    else
        printf "%s\n" "$msg" >>"$STEP_LOG_PATH" 2>/dev/null || true
    fi
}

# formata linhas de log para arquivo
_format_log_line() {
    local level="$1"; shift
    local meta="$1"; shift || true
    local msg="$*"
    printf "%s [%s] %s %s\n" "$(_now)" "$level" "$meta" "$msg"
}

# Printa para tela de forma controlada
_screen_write() {
    if [ "$SHOW_ON_SCREEN" = true ]; then
        # usa carriage return para sobrescrever a única linha de status
        printf "%s\r" "$*"
    fi
}

# imprime destaque para WARN/ERROR (não sobrescreve)
_screen_alert() {
    if [ "$SHOW_ON_SCREEN" = true ]; then
        printf "\n%s\n" "$*"
    fi
}

# ----------------------------
# API pública: inicialização e lifecycle
# ----------------------------

# log_init <step_name> <step_index> <step_total>
log_init() {
    local name="${1:-unnamed-step}"
    local idx="${2:-0}"
    local total="${3:-$STEP_TOTAL}"

    STEP_NAME="$name"
    STEP_CURRENT=$idx
    STEP_TOTAL=$total
    START_TIME=$(_epoch)

    # determina LOG_DIR (fallback para ./logs se sem permissão)
    if [ -z "$LOG_DIR" ]; then
        LOG_DIR="./logs"
    fi

    if [ ! -d "$LOG_DIR" ]; then
        if mkdir -p "$LOG_DIR" 2>/dev/null; then
            :
        else
            # fallback para dir local
            LOG_DIR="./logs"
            mkdir -p "$LOG_DIR" || true
        fi
    fi

    local date_dir="$LOG_DIR/$(_date)"
    mkdir -p "$date_dir" 2>/dev/null || true

    # cria nome de arquivo seguro
    local safe_name
    safe_name=$(echo "$name" | tr ' /' '_' | tr -cd '[:alnum:]_-.')
    STEP_LOG_PATH="$date_dir/$(printf "%02d" "$idx")-${LOG_PREFIX}-${safe_name}.log"

    # touch e header
    : >"$STEP_LOG_PATH" 2>/dev/null || true
    _write_log_file "$(_format_log_line INFO "step ${STEP_CURRENT}/${STEP_TOTAL}" "START: $STEP_NAME (pid $$) - log: $STEP_LOG_PATH")"

    # export path
    export STEP_LOG_PATH

    # register trap
    trap 'log_cleanup_on_exit' EXIT INT TERM

    # export functions for subshells
    export -f log_info log_warn log_error log_debug log_progress log_get_path log_measure_resources

    echo "$STEP_LOG_PATH"
}

log_step_start() {
    local descr="${1:-$STEP_NAME}"
    START_TIME=$(_epoch)
    _write_log_file "$(_format_log_line INFO "step ${STEP_CURRENT}/${STEP_TOTAL}" "STEP_START: $descr (pid $$)")"
    # show initial status
    log_measure_and_render
}

log_step_end() {
    local exit_code=${1:-0}
    local duration=$((_epoch - START_TIME))
    if [ "$exit_code" -eq 0 ]; then
        _write_log_file "$(_format_log_line INFO "step ${STEP_CURRENT}/${STEP_TOTAL}" "STEP_END: $STEP_NAME duration=${duration}s exit=0")"
    else
        _write_log_file "$(_format_log_line ERROR "step ${STEP_CURRENT}/${STEP_TOTAL}" "STEP_END: $STEP_NAME duration=${duration}s exit=${exit_code}")"
        if [ "$ABORT_ON_ERROR" = true ]; then
            log_error "step '${STEP_NAME}' failed with exit ${exit_code}"
            # exit after logging
            exit $exit_code
        fi
    fi
    # final render newline
    if [ "$SHOW_ON_SCREEN" = true ]; then
        printf "\n"
    fi
}

# ----------------------------
# Logging helpers
# ----------------------------
log_info() {
    local msg="$*"
    _write_log_file "$(_format_log_line INFO "pid $$" "$msg")"
}

log_warn() {
    local msg="$*"
    _write_log_file "$(_format_log_line WARN "pid $$" "$msg")"
    _screen_alert "WARN: (${STEP_CURRENT}/${STEP_TOTAL}) ${STEP_NAME} — $msg — ver $STEP_LOG_PATH"
}

log_error() {
    local msg="$*"
    _write_log_file "$(_format_log_line ERROR "pid $$" "$msg")"
    if [ "$SILENT_ERRORS" = false ]; then
        _screen_alert "ERROR: (${STEP_CURRENT}/${STEP_TOTAL}) ${STEP_NAME} — $msg — ver $STEP_LOG_PATH"
    fi
    if [ "$ABORT_ON_ERROR" = true ]; then
        # ensure final end is logged
        log_step_end 1
        exit 1
    fi
}

log_debug() {
    if [ "$LOG_LEVEL" = "DEBUG" ]; then
        local msg="$*"
        _write_log_file "$(_format_log_line DEBUG "pid $$" "$msg")"
    fi
}

# ----------------------------
# Progresso para downloads / operações com bytes
# ----------------------------
# log_progress <downloaded_bytes> <total_bytes> [label]
log_progress() {
    local dl=${1:-0}
    local total=${2:-0}
    local label=${3:-""}

    local percent=0
    if [ "$total" -gt 0 ]; then
        percent=$(( (dl * 100) / total ))
    fi
    local bars=40
    local filled=$(( (percent * bars) / 100 ))
    local barstr
    barstr=$(printf '#%.0s' $(seq 1 $filled) 2>/dev/null || true)
    local empties=$((bars - filled))
    local emptstr
    emptstr=$(printf '-%.0s' $(seq 1 $empties) 2>/dev/null || true)

    local human_dl human_total
    human_dl=$(numfmt --to=iec --suffix=B --format=%.1f ${dl} 2>/dev/null || printf "%sB" "$dl")
    human_total=$(numfmt --to=iec --suffix=B --format=%.1f ${total} 2>/dev/null || printf "%sB" "$total")

    # atualiza log e tela
    _write_log_file "$(_format_log_line INFO "progress" "${label} ${dl}/${total} (${percent}%)" )"

    # medição de recursos e render
    local resources
    resources=$(log_measure_resources)

    local status_line="(${STEP_CURRENT}/${STEP_TOTAL}) ${STEP_NAME} — ${resources} — ${STEP_LOG_PATH} — [${barstr}${emptstr}] ${percent}% (${human_dl}/${human_total})"
    _screen_write "$status_line"
}

# ----------------------------
# Medições de CPU/MEM/LOAD
# ----------------------------
log_measure_resources() {
    # núcleos
    local cores
    cores=$(nproc --all 2>/dev/null || awk '/^processor/ {c++} END{print c+0}' /proc/cpuinfo 2>/dev/null || echo "1")

    # CPU usage: amostra rápida via /proc/stat
    local cpu_idle1 cpu_total1 cpu_idle2 cpu_total2 cpu_used_pct
    read -r cpu_idle1 cpu_total1 < <(awk '/^cpu /{idle=$5; total=0; for(i=2;i<=NF;i++) total+= $i; print idle, total}' /proc/stat 2>/dev/null)
    sleep $CPU_SAMPLING_INTERVAL
    read -r cpu_idle2 cpu_total2 < <(awk '/^cpu /{idle=$5; total=0; for(i=2;i<=NF;i++) total+= $i; print idle, total}' /proc/stat 2>/dev/null)
    if [ -n "$cpu_idle1" ] && [ -n "$cpu_total1" ]; then
        local d_idle=$((cpu_idle2 - cpu_idle1))
        local d_total=$((cpu_total2 - cpu_total1))
        if [ "$d_total" -gt 0 ]; then
            cpu_used_pct=$(( (1000 * (d_total - d_idle) / d_total + 5) / 10 ))
        else
            cpu_used_pct=0
        fi
    else
        cpu_used_pct=0
    fi

    # Mem
    local mem_total mem_avail mem_used_mb mem_total_mb mem_used_pct
    mem_total=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    mem_avail=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "$mem_total" -gt 0 ]; then
        mem_used_mb=$(( (mem_total - mem_avail) / 1024 ))
        mem_total_mb=$(( mem_total / 1024 ))
        mem_used_pct=$(( (100 * (mem_total - mem_avail)) / mem_total ))
    else
        mem_used_mb=0; mem_total_mb=0; mem_used_pct=0
    fi

    # load avg
    local load1 load5 load15
    read -r load1 load5 load15 rest < /proc/loadavg 2>/dev/null || { load1=0; load5=0; load15=0; }

    echo "cores: ${cores} — CPU: ${cpu_used_pct}% — MEM: ${mem_used_mb}MB (${mem_used_pct}%) — load: ${load1} ${load5} ${load15}"
}

# ----------------------------
# auxiliares
# ----------------------------
log_get_path() { echo "$STEP_LOG_PATH"; }

log_set_level() {
    local lvl=${1:-INFO}
    LOG_LEVEL="$lvl"
    export LOG_LEVEL
}

log_rotate() {
    # simples limpeza por data
    find "$LOG_DIR" -maxdepth 2 -type f -mtime +${LOG_RETENTION_DAYS} -name "*.log" -exec rm -f {} \; 2>/dev/null || true
}

log_link_stdout_to_log() {
    # redireciona stdout/stderr para o log de passo atual
    if [ -n "$STEP_LOG_PATH" ]; then
        exec > >(tee -a "$STEP_LOG_PATH") 2>&1
    fi
}

log_cleanup_on_exit() {
    local rc=$?
    if [ $rc -ne 0 ]; then
        _write_log_file "$(_format_log_line ERROR "exit" "script exited with code ${rc}")"
    else
        _write_log_file "$(_format_log_line INFO "exit" "script exited normally")"
    fi
}

# ----------------------------
# CLI: --ini e comandos
# ----------------------------
_usage() {
    cat <<EOF
Usage: $(basename "$0") [--ini] [--install-path /usr/bin] <command> [args...]
Commands:
  --ini                     Cria diretórios e arquivos necessários (logs dir, datas)
  init NAME INDEX TOTAL      Inicializa passo (imprime caminho do log)
  start "descr"              Marca início da etapa
  end [exit_code]            Marca fim da etapa
  info "msg"                 Grava INFO
  warn "msg"                 Grava WARN (visível)
  error "msg"                Grava ERROR (visível e aborta se configurado)
  debug "msg"                Grava DEBUG (se LOG_LEVEL=DEBUG)
  progress DL TOTAL [label]   Atualiza barra de progresso
  getpath                    Imprime caminho do log da etapa
  setlevel LEVEL             Ajusta LOG_LEVEL
  self-test                  Executa testes rápidos de render e recursos
  install [path]             Copia este script para destination (ex: /usr/bin) (requires sudo)
  help                       Mostra esta ajuda
Options:
  --silent-errors true|false  Controla se erros são mostrados na tela
EOF
}

# cria diretórios e arquivos necessários
cli_ini() {
    # diretório base
    if [ -z "$LOG_DIR" ]; then LOG_DIR="./logs"; fi
    if mkdir -p "$LOG_DIR" 2>/dev/null; then
        :
    else
        echo "Falha ao criar $LOG_DIR — usando ./logs" >&2
        LOG_DIR=./logs
        mkdir -p "$LOG_DIR" || true
    fi
    mkdir -p "$LOG_DIR/$(date +%F)" || true
    touch "$LOG_DIR/.placeholder" 2>/dev/null || true
    echo "Diretórios iniciais criados em: $LOG_DIR"
}

cli_self_test() {
    echo "Running self-test..."
    log_set_level DEBUG
    log_init "selftest" 1 1 >/dev/null
    log_step_start "selftest"
    log_link_stdout_to_log
    log_info "testing info"
    log_debug "testing debug"
    log_progress 512 1024 "test-download"
    sleep 0.1
    log_progress 800 1024 "test-download"
    sleep 0.1
    log_warn "testing warn"
    # simulate error but don't abort
    local old_abort="$ABORT_ON_ERROR"
    ABORT_ON_ERROR=false
    log_error "testing error (should not abort)"
    ABORT_ON_ERROR="$old_abort"
    log_step_end 0
    echo "Self-test finished. Log at: $STEP_LOG_PATH"
}

cli_install() {
    local dest=${1:-/usr/bin/logs.sh}
    if [ ! -w "$(dirname "$dest")" ]; then
        echo "Precisa de permissões elevadas para instalar em $dest" >&2
        echo "Use: sudo $(basename "$0") install $dest" >&2
        exit 1
    fi
    cp "$0" "$dest" || { echo "Falha ao copiar" >&2; exit 1; }
    chmod 0755 "$dest" || true
    echo "Instalado em $dest"
}

# parse CLI
if [ "$#" -gt 0 ]; then
    case "$1" in
        --ini)
            cli_ini; exit 0;;
        install)
            shift; cli_install "$@"; exit $?;;
        init)
            shift; log_init "$@"; exit 0;;
        start)
            shift; log_step_start "$@"; exit 0;;
        end)
            shift; log_step_end "$@"; exit 0;;
        info)
            shift; log_info "$*"; exit 0;;
        warn)
            shift; log_warn "$*"; exit 0;;
        error)
            shift; log_error "$*"; exit 0;;
        debug)
            shift; log_debug "$*"; exit 0;;
        progress)
            shift; log_progress "$@"; exit 0;;
        getpath)
            log_get_path; exit 0;;
        setlevel)
            shift; log_set_level "$1"; exit 0;;
        self-test)
            cli_self_test; exit 0;;
        --silent-errors)
            shift; SILENT_ERRORS="$1"; export SILENT_ERRORS; exit 0;;
        help|-h|--help)
            _usage; exit 0;;
        *)
            # if sourced, we should not exit — just allow sourcing
            if [ "$(basename "$0")" = "$(basename "${BASH_SOURCE[0]}")" ]; then
                echo "Comando desconhecido: $1" >&2
                _usage
                exit 1
            fi
            ;;
    esac
fi

# fim do script - se for source, não sair
return 0 2>/dev/null || true

