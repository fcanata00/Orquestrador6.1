#!/usr/bin/env bash
# downloader.sh - gerenciador de downloads, verificação e unpack seguro
# Requisitos: bash, curl/wget, sha256sum, tar, unzip, flock, gzip/xz/bzip2 utilitários
set -eEuo pipefail
IFS=$'\n\t'

# -------------------------
# Configurações padrão
# -------------------------
: "${LFS:=/mnt/lfs}"
: "${DL_CACHE_DIR:=${CACHE_SOURCES:-/var/cache/sources}}"
: "${DL_BIN_CACHE:=${CACHE_BINARIES:-/var/cache/binaries}}"
: "${DL_TMP_DIR:=${TMPDIR:-/tmp}/dlwork.$$}"
: "${DL_MAX_RETRIES:=3}"
: "${DL_RETRY_BACKOFF:=3}"
: "${DL_TIMEOUT:=300}"
: "${DL_MIN_SIZE_BYTES:=1024}"
: "${DL_LOCK_DIR:=${DL_CACHE_DIR}/locks}"
: "${DL_VERBOSE:=${VERBOSE:-false}}"
: "${DL_SILENT:=${SILENT:-false}}"
: "${DL_DEBUG:=${DEBUG:-false}}"
: "${DL_CURL_OPTS:=-L --fail --connect-timeout 15 --max-time ${DL_TIMEOUT}}"

# Internal state
_DL_INITIALIZED=false
declare -a DL_LAST_FILES
declare -a DL_MIRRORS

# Helper: integrate register logger if available
_log() {
  local level="$1"; shift
  local msg="$*"
  if type register_info >/dev/null 2>&1; then
    case "$level" in
      INFO)  register_info "$msg" ;;
      WARN)  register_warn "$msg" ;;
      ERROR) register_error "$msg" ;;
      DEBUG) register_debug "$msg" ;;
      *)     register_info "$msg" ;;
    esac
  else
    if [[ "${DL_SILENT}" == "true" && "$level" != "ERROR" ]]; then
      return 0
    fi
    case "$level" in
      INFO)  printf "[INFO] %s\n" "$msg" ;;
      WARN)  printf "[WARN] %s\n" "$msg" >&2 ;;
      ERROR) printf "[ERROR] %s\n" "$msg" >&2 ;;
      DEBUG) [[ "${DL_DEBUG}" == "true" ]] && printf "[DEBUG] %s\n" "$msg" ;;
      *)     printf "[LOG] %s\n" "$msg" ;;
    esac
  fi
}

# Helper sanitize filename/url
_dl_basename() {
  local url="$1"
  # remove query strings
  url="${url%%\?*}"
  # if file:// handle
  url="${url#file://}"
  printf '%s' "$(basename "$url")"
}

# Helper: ensure necessary tools
_dl_check_tools() {
  local missing=()
  for cmd in curl sha256sum tar unzip flock; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    _log ERROR "Ferramentas ausentes: ${missing[*]}. Instale-as antes de prosseguir."
    return 1
  fi
  return 0
}

# Init dirs, perms, trap
dl_init() {
  if [[ "${_DL_INITIALIZED}" == "true" ]]; then return 0; fi
  umask 027
  mkdir -p "${DL_CACHE_DIR}" "${DL_BIN_CACHE}" "${DL_LOCK_DIR}" "${DL_TMP_DIR}" 2>/dev/null || true
  chmod 750 "${DL_CACHE_DIR}" "${DL_BIN_CACHE}" "${DL_LOCK_DIR}" || true
  trap 'dl_cleanup_tmp' EXIT INT TERM
  _dl_check_tools || true
  _DL_INITIALIZED=true
  _log INFO "Downloader inicializado. Cache: ${DL_CACHE_DIR}, TMP: ${DL_TMP_DIR}"
}

# Cleanup tmp area
dl_cleanup_tmp() {
  if [[ -d "${DL_TMP_DIR}" ]]; then
    rm -rf "${DL_TMP_DIR}" || true
  fi
}

# Acquire per-file lock
_dl_lock_acquire() {
  local name="$1"
  mkdir -p "${DL_LOCK_DIR}" 2>/dev/null || true
  local lockfile="${DL_LOCK_DIR}/$(echo "$name" | sed -E 's/[^A-Za-z0-9_.-]/_/g').lock"
  exec {DL_LOCK_FD}>>"${lockfile}" || return 2
  flock -n "${DL_LOCK_FD}" || return 1
  return 0
}

_dl_lock_release() {
  if [[ -n "${DL_LOCK_FD:-}" ]]; then
    eval "exec ${DL_LOCK_FD}>&-"
  fi
}

# Verify sha256
dl_verify() {
  local file="$1"; local want="$2"
  if [[ -z "$want" ]]; then
    _log WARN "Checksum não fornecido para $file"
    return 0
  fi
  if [[ ! -f "$file" ]]; then
    _log ERROR "Arquivo para verificação não encontrado: $file"
    return 2
  fi
  local got
  if ! got=$(sha256sum "$file" 2>/dev/null | awk '{print $1}'); then
    _log ERROR "sha256sum falhou para $file"
    return 3
  fi
  if [[ "$got" != "$want" ]]; then
    _log ERROR "Checksum mismatch para $file (esperado: $want, obtido: $got)"
    return 4
  fi
  _log INFO "Checksum válido: $(basename "$file")"
  return 0
}

# Internal downloader using curl or wget with retries
_dl_http_get() {
  local url="$1"; local out="$2"; local tries=0
  while (( tries < DL_MAX_RETRIES )); do
    tries=$((tries+1))
    if command -v curl >/dev/null 2>&1; then
      if curl ${DL_CURL_OPTS} -o "${out}.part" "$url" >/dev/null 2>&1; then
        mv -f "${out}.part" "${out}"
        return 0
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -q -O "${out}.part" "$url"; then
        mv -f "${out}.part" "${out}"
        return 0
      fi
    else
      _log ERROR "Nenhum download tool disponível (curl/wget necessário)"
      return 2
    fi
    _log WARN "Tentativa ${tries}/${DL_MAX_RETRIES} falhou para $url; aguardando ${DL_RETRY_BACKOFF}s"
    sleep "${DL_RETRY_BACKOFF}"
  done
  return 1
}

# Try mirrors list
dl_try_mirrors() {
  local url="$1"; local dest="$2"; local sha="$3"
  for m in "${DL_MIRRORS[@]:-}"; do
    local mirror_url="${m%/}/${url##*/}"
    _log INFO "Tentando mirror: ${mirror_url}"
    if _dl_http_get "${mirror_url}" "${dest}"; then
      if [[ -n "$sha" ]]; then
        if dl_verify "${dest}" "$sha"; then
          return 0
        else
          rm -f "${dest}" || true
          continue
        fi
      else
        return 0
      fi
    fi
  done
  return 1
}

# Main download function, returns path on success
dl_fetch() {
  dl_init
  local url="$1"; local sha="${2:-}"
  [[ -z "${url}" ]] && { _log ERROR "dl_fetch: URL vazia"; return 2; }

  # expand ${NAME} and ${VERSION} if present in URL by caller (metafile should do), but we allow simple env expansion
  eval "url=\"$url\""

  local fname; fname=$(_dl_basename "$url")
  [[ -z "$fname" ]] && { _log ERROR "Nome do arquivo não determinado a partir de $url"; return 3; }
  local dest="${DL_CACHE_DIR}/${fname}"

  # Acquire lock per filename to prevent concurrent downloads
  if ! _dl_lock_acquire "$fname"; then
    _log WARN "Outra instância pode estar baixando ${fname}; aguardando lock..."
    # blocking acquire
    exec {DL_LOCK_FD}>>"${DL_LOCK_DIR}/$(echo "$fname" | sed -E 's/[^A-Za-z0-9_.-]/_/g').lock"
    flock "${DL_LOCK_FD}" || true
  fi

  # If exists and valid, use cache
  if [[ -f "${dest}" ]]; then
    if [[ -n "${sha}" ]]; then
      if dl_verify "${dest}" "${sha}"; then
        _log INFO "Usando cache válido: ${fname}"
        DL_LAST_FILES+=("${dest}")
        _dl_lock_release || true
        return 0
      else
        _log WARN "Cache inválido, removendo ${dest}"
        rm -f "${dest}" || true
      fi
    else
      _log INFO "Usando cache: ${fname}"
      DL_LAST_FILES+=("${dest}")
      _dl_lock_release || true
      return 0
    fi
  fi

  # Try direct URL
  _log INFO "Iniciando download: ${url}"
  if [[ "${url}" =~ ^file:// ]]; then
    # local file copy
    local path="${url#file://}"
    if [[ -f "${path}" ]]; then
      cp -a "${path}" "${dest}" || { _log ERROR "Falha ao copiar ${path}"; _dl_lock_release || true; return 4; }
    else
      _log ERROR "Fonte local não encontrada: ${path}"
      _dl_lock_release || true
      return 5
    fi
  else
    if _dl_http_get "${url}" "${dest}"; then
      _log INFO "Download concluído: ${fname}"
    else
      _log WARN "Download direto falhou para ${url}; tentando mirrors..."
      if ! dl_try_mirrors "$url" "$dest" "$sha"; then
        _log ERROR "Todas as tentativas de download falharam para ${url}"
        _dl_lock_release || true
        return 6
      fi
    fi
  fi

  # Verify size
  local bytes=$(stat -c%s "${dest}" 2>/dev/null || echo 0)
  if (( bytes < DL_MIN_SIZE_BYTES )); then
    _log ERROR "Arquivo baixado muito pequeno (${bytes} bytes): ${dest}"
    rm -f "${dest}" || true
    _dl_lock_release || true
    return 7
  fi

  # Verify checksum if provided
  if [[ -n "${sha}" ]]; then
    if ! dl_verify "${dest}" "${sha}"; then
      _log ERROR "Checksum inválido após download: ${dest}"
      rm -f "${dest}" || true
      _dl_lock_release || true
      return 8
    fi
  fi

  DL_LAST_FILES+=("${dest}")
  _dl_lock_release || true
  return 0
}

# Unpack safely into destdir; returns path of extracted dir
dl_unpack() {
  dl_init
  local file="$1"; local dest="${2:-${DL_TMP_DIR}}"
  [[ ! -f "$file" ]] && { _log ERROR "Arquvo de origem não encontrado para unpack: $file"; return 2; }
  mkdir -p "$dest" || { _log ERROR "Não foi possível criar destino: $dest"; return 3; }
  local base="$(basename "$file")"
  local work="${dest%/}/${base%.*}.extract.$$"
  mkdir -p "${work}"
  _log INFO "Extraindo ${base} -> ${work}"

  case "$file" in
    *.tar.gz|*.tgz) tar -xzf "$file" -C "$work" --warning=no-unknown-keyword ;;
    *.tar.xz) tar -xJf "$file" -C "$work" --warning=no-unknown-keyword ;;
    *.tar.bz2|*.tbz2) tar -xjf "$file" -C "$work" --warning=no-unknown-keyword ;;
    *.tar) tar -xf "$file" -C "$work" --warning=no-unknown-keyword ;;
    *.zip) unzip -q "$file" -d "$work" ;;
    *.gz) mkdir -p "${work}/single" && gunzip -c "$file" > "${work}/single/${base%.gz}" ;;
    *) _log WARN "Formato desconhecido para extração: $file"; return 4 ;;
  esac

  # find top-level directory (first non-hidden)
  local top
  top=$(find "${work}" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)
  if [[ -z "${top}" ]]; then
    # files directly extracted - return work
    printf '%s' "${work}"
  else
    printf '%s' "${top}"
  fi
  return 0
}

# Clean cache older than N days
dl_clean_cache() {
  local days="${1:-30}"
  dl_init
  _log INFO "Limpando cache em ${DL_CACHE_DIR} com mais de ${days} dias"
  find "${DL_CACHE_DIR}" -type f -mtime +"${days}" -print -delete || true
  _log INFO "Limpeza concluída"
}

# Summary stats
dl_summary() {
  dl_init
  local count size free
  count=$(find "${DL_CACHE_DIR}" -type f 2>/dev/null | wc -l || echo 0)
  size=$(du -sh "${DL_CACHE_DIR}" 2>/dev/null | awk '{print $1}' || echo "0")
  free=$(df -h "${DL_CACHE_DIR}" 2>/dev/null | awk 'NR==2{print $(NF-2) " free"}' || echo "unknown")
  _log INFO "Cache: ${DL_CACHE_DIR} | Arquivos: ${count} | Tamanho: ${size} | Espaço livre: ${free}"
  if (( ${#DL_LAST_FILES[@]} > 0 )); then
    _log INFO "Últimos arquivos baixados:"
    for f in "${DL_LAST_FILES[@]}"; do _log INFO "  - ${f}"; done
  fi
}

# Add mirror
dl_add_mirror() {
  local m="$1"
  DL_MIRRORS+=("$m")
  _log INFO "Mirror adicionado: $m"
}

# Export functions for sourcing
export -f dl_init dl_fetch dl_verify dl_unpack dl_clean_cache dl_summary dl_add_mirror

# -------------------------
# CLI
# -------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --get|-g)
      shift || true
      url="${1:-}"; sha="${2:-}"
      if [[ -z "$url" ]]; then echo "Uso: downloader.sh --get <URL> [SHA256]"; exit 2; fi
      dl_init
      if dl_fetch "$url" "$sha"; then
        _log INFO "Arquivo disponível em cache"
        exit 0
      else
        _log ERROR "Falha ao obter $url"
        exit 3
      fi
      ;;
    --verify)
      shift || true
      file="${1:-}"; want="${2:-}"
      if [[ -z "$file" || -z "$want" ]]; then echo "Uso: downloader.sh --verify <file> <sha256>"; exit 2; fi
      if dl_verify "$file" "$want"; then exit 0; else exit 4; fi
      ;;
    --unpack)
      shift || true
      file="${1:-}"; dest="${2:-}"
      if [[ -z "$file" ]]; then echo "Uso: downloader.sh --unpack <file> [dest]"; exit 2; fi
      dl_init
      out=$(dl_unpack "$file" "${dest:-${DL_TMP_DIR}}") || { _log ERROR "Unpack falhou"; exit 5; }
      echo "$out"
      exit 0
      ;;
    --clean)
      shift || true
      days="${1:-30}"
      dl_clean_cache "$days"
      exit 0
      ;;
    --summary)
      dl_summary
      exit 0
      ;;
    --add-mirror)
      shift || true
      m="${1:-}"
      [[ -z "$m" ]] && { echo "Uso: --add-mirror <url>"; exit 2; }
      dl_add_mirror "$m"
      exit 0
      ;;
    --help|-h|help|"")
      cat <<EOF
downloader.sh - gerencia downloads e cache

Uso:
  downloader.sh --get <URL> [SHA256]     Baixa para cache e verifica checksum
  downloader.sh --verify <file> <sha256> Verifica SHA256 local
  downloader.sh --unpack <file> [dest]   Extrai arquivo para destino e imprime path extraído
  downloader.sh --clean [days]           Limpa cache com arquivos mais antigos que days
  downloader.sh --summary                Mostra estatísticas do cache
  downloader.sh --add-mirror <url>       Adiciona mirror temporário para tentativas
  downloader.sh --help
EOF
      exit 0
      ;;
    *)
      echo "Comando inválido. Use --help."
      exit 2
      ;;
  esac
fi
