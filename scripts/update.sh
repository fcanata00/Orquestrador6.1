#!/usr/bin/env bash
# update.sh - verifica versões upstream, atualiza metafiles, testa links e rebuild (dry-run/upgrade)
# Suporta GNU/GitHub/SourceForge scraping, integração com downloader.sh, depende.sh, build.sh.
# Implementa escrita atômica de metafiles (.bak/.tmp), locks, logs, rollback, silent/debug.
# Versão: 2025-10-23

set -eEuo pipefail
IFS=$'\n\t'
umask 027

SCRIPT_NAME="update"
SCRIPT_VERSION="1.0.0"

# -------------------------
# Configuráveis (ENV / ajuste)
# -------------------------
: "${META_SEARCH_DIRS:=/usr/src /mnt/lfs/usr/src /usr/src/repo /mnt/lfs/usr/src/repo}"
: "${LOG_DIR:=/var/log/orquestrador/update}"
: "${LOCK_DIR:=/run/lock/orquestrador}"
: "${TMP_DIR:=/var/tmp/orquestrador/update}"
: "${RETRY_DOWNLOADS:=3}"
: "${SCRAPE_TIMEOUT:=10}"
: "${UPDATE_SILENT:=false}"
: "${UPDATE_DEBUG:=false}"
: "${UPDATE_FALLBACK_MIRRORS:=https://ftp.gnu.org/gnu}"
: "${BUILD_CMD:="/usr/bin/build.sh"}"   # caminho ao build.sh dentro host (ou chroot)
: "${DL_CMD:=$(command -v dl_fetch || true)}"
: "${CURL_BIN:=$(command -v curl || true)}"
: "${WGET_BIN:=$(command -v wget || true)}"
: "${SHA256SUM_BIN:=$(command -v sha256sum || true)}"

: "${LOCK_TIMEOUT_SEC:=600}"

# -------------------------
# Runtime vars
# -------------------------
_LOCK_FD=""
_SESSION_TS="$(date -u +"%Y%m%dT%H%M%SZ")-$$"
_DEBUG="${UPDATE_DEBUG}"
_SILENT="${UPDATE_SILENT}"
mkdir -p "${LOG_DIR}" "${LOCK_DIR}" "${TMP_DIR}" 2>/dev/null || true

# -------------------------
# Logging helpers and register integration
# -------------------------
_log() {
  local level="$1"; shift
  local msg="$*"
  if type register_info >/dev/null 2>&1; then
    case "$level" in
      INFO) register_info "$msg"; return 0 ;;
      WARN) register_warn "$msg"; return 0 ;;
      ERROR) register_error "$msg"; return 0 ;;
      DEBUG) register_debug "$msg"; return 0 ;;
      *) register_info "$msg"; return 0 ;;
    esac
  fi
  if [[ "${_SILENT}" == "true" && "$level" != "ERROR" ]]; then
    return 0
  fi
  case "$level" in
    INFO)  printf '\e[32m[INFO]\e[0m %s\n' "$msg" ;;
    WARN)  printf '\e[33m[WARN]\e[0m %s\n' "$msg" >&2 ;;
    ERROR) printf '\e[31m[ERROR]\e[0m %s\n' "$msg" >&2 ;;
    DEBUG) [[ "${_DEBUG}" == "true" ]] && printf '\e[36m[DEBUG]\e[0m %s\n' "$msg" ;;
    *) printf '[LOG] %s\n' "$msg" ;;
  esac
}

_fail() {
  local msg="$1"; local code="${2:-1}"
  _log ERROR "$msg"
  _update_rollback || true
  exit "$code"
}

# -------------------------
# Acquire global lock (prevent concurrent updates)
# -------------------------
_acquire_lock() {
  local lockfile="${LOCK_DIR}/update.lock"
  exec {LOCK_FD}>"${lockfile}" || _fail "Não foi possível abrir lock ${lockfile}"
  if flock -n "${LOCK_FD}"; then
    _log DEBUG "Lock adquirido"
    return 0
  fi
  _log INFO "Aguardando lock (timeout ${LOCK_TIMEOUT_SEC}s)..."
  local waited=0
  while ! flock -n "${LOCK_FD}"; do
    sleep 1
    waited=$((waited+1))
    if (( waited >= LOCK_TIMEOUT_SEC )); then
      _fail "Timeout aguardando lock ${lockfile}"
    fi
  done
  _log DEBUG "Lock adquirido após espera ${waited}s"
}

_release_lock() {
  if [[ -n "${LOCK_FD:-}" ]]; then
    eval "exec ${LOCK_FD}>&-"
    unset LOCK_FD
  fi
}

# -------------------------
# Utility functions
# -------------------------
_realpath_safe() {
  local p="${1:-.}"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p"
  else
    (cd "$p" 2>/dev/null && pwd -P) || echo "$p"
  fi
}

_safe_mkdir() {
  mkdir -p "$1" 2>/dev/null || _fail "Falha ao criar diretório $1"
  chmod 750 "$1" 2>/dev/null || true
}

# atomic write: write to tmp then mv
_atomic_write_file() {
  local file="$1"; local content="$2"
  local dir; dir=$(dirname "$file")
  _safe_mkdir "$dir"
  local tmp; tmp="$(mktemp "${file}.tmp.XXXX")"
  printf '%s\n' "$content" > "$tmp"
  mv -f "$tmp" "$file"
}

# -------------------------
# Find metafile for package
# Returns path in STDOUT or empty if not found
# -------------------------
find_metafile_for_pkg() {
  local pkg="$1"
  for d in ${META_SEARCH_DIRS}; do
    if [[ -d "${d}" ]]; then
      # search for files named pkg*.ini or pkg.ini or <pkg>.meta
      local found
      found=$(find "${d}" -type f -iname "${pkg}*.ini" -o -iname "${pkg}.ini" -o -iname "${pkg}.meta" 2>/dev/null | head -n1 || true)
      if [[ -n "${found}" ]]; then
        printf '%s' "${found}"
        return 0
      fi
      # also try directories /usr/src/<category>/<pkg>/*.ini
      found=$(find "${d}" -type f -path "*/${pkg}/*.ini" 2>/dev/null | head -n1 || true)
      if [[ -n "${found}" ]]; then
        printf '%s' "${found}"
        return 0
      fi
    fi
  done
  return 1
}

# -------------------------
# Parse metafile simple INI-like to associative array (returns via global)
# sets: META_NAME, META_VERSION, META_URLS (comma), META_SHA256S (comma), META_DEPENDS (space list)
# Also returns full associative map in variable name passed as second arg (by name)
# -------------------------
parse_metafile() {
  local file="$1"; local out_assoc_name="$2"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  declare -A tmp=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line%%;*}"
    line="$(echo -n "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^([A-Za-z0-9_.-]+)=(.*)$ ]]; then
      local k="${BASH_REMATCH[1]}"
      local v="${BASH_REMATCH[2]}"
      tmp["$k"]="$v"
    fi
  done < "$file"
  # export certain common fields to globals for backward compatibility
  META_NAME="${tmp[name]:-${tmp[package]:-}}"
  META_VERSION="${tmp[version]:-${tmp[${META_NAME}.version]:-}}"
  # URLS: support both "urls=" or "<pkg>.url="
  if [[ -n "${tmp[urls]:-}" ]]; then
    META_URLS="${tmp[urls]}"
  else
    META_URLS="${tmp[${META_NAME}.url]:-${tmp[url]:-}}"
  fi
  META_SHA256S="${tmp[sha256sums]:-${tmp[sha256]:-}}"
  META_DEPENDS="${tmp[depends]:-}"
  # return assoc by reference name
  eval "$out_assoc_name=()"
  for k in "${!tmp[@]}"; do
    # declare in associative... use printf to create declare -A content
    eval "$out_assoc_name[\"$k\"]=\"${tmp[$k]}\""
  done
  return 0
}

# -------------------------
# Update metafile safely: backup .bak, write new content atomically
# new_kv is associative array name passed by caller; keys/values to replace / add
# -------------------------
update_metafile_atomic() {
  local mf="$1"; local -n new_kv="$2"
  if [[ ! -f "$mf" ]]; then
    _fail "metafile não existe: $mf"
  fi
  local bak="${mf}.bak.${_SESSION_TS}"
  cp -a "$mf" "${bak}" || _fail "Falha ao criar backup ${bak}"
  _log INFO "Backup do metafile criado: ${bak}"
  # build new temp file content by reading lines and replacing keys
  local tmpf; tmpf="$(mktemp "${mf}.tmp.XXXX")"
  touch "$tmpf"
  # track which keys were replaced
  declare -A replaced=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([A-Za-z0-9_.-]+)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      if [[ -n "${new_kv[$key]:-}" ]]; then
        printf '%s=%s\n' "$key" "${new_kv[$key]}" >> "$tmpf"
        replaced["$key"]=1
      else
        printf '%s\n' "$line" >> "$tmpf"
      fi
    else
      printf '%s\n' "$line" >> "$tmpf"
    fi
  done < "$mf"
  # append any keys not present before
  for k in "${!new_kv[@]}"; do
    if [[ -z "${replaced[$k]:-}" ]]; then
      printf '%s=%s\n' "$k" "${new_kv[$k]}" >> "$tmpf"
    fi
  done
  # move tmp to mf atomically
  mv -f "$tmpf" "$mf" || { cp -a "${bak}" "$mf"; _fail "Falha ao gravar novo metafile; rollback aplicado"; }
  _log INFO "Metafile atualizado: ${mf}"
  return 0
}

# -------------------------
# Try to detect latest version from known upstream types:
# - GNU ftp pages (ftp.gnu.org)
# - GitHub releases/tags
# - SourceForge project pages
# Fallback mirror list if first fails.
# Returns newest version string in stdout (or empty)
# -------------------------
detect_latest_upstream_version() {
  local url="$1"
  local name_hint="$2"   # optional, e.g. 'gcc'
  # heuristics: determine host type
  if [[ "$url" =~ github.com ]]; then
    _detect_latest_github "$url" "$name_hint"
    return $?
  elif [[ "$url" =~ ftp.gnu.org|gnu.org|ftp.gnu|ftp.gnu.org/gnu|sourceware.org ]]; then
    _detect_latest_gnu "$url" "$name_hint"
    return $?
  elif [[ "$url" =~ sourceforge.net ]]; then
    _detect_latest_sourceforge "$url" "$name_hint"
    return $?
  else
    # attempt to infer by visiting parent path
    if [[ -n "${CURL_BIN}" ]]; then
      # fetch page and attempt to find versions e.g. name-1.2.3.tar.xz links
      local page
      page=$("${CURL_BIN}" -fsSL --max-time "${SCRAPE_TIMEOUT}" "${url}" 2>/dev/null || true)
      if [[ -n "$page" ]]; then
        # try to extract version-like patterns
        local ver
        ver=$(printf '%s' "$page" | grep -Eo "${name_hint}[._-]?[vV]?[0-9]+\.[0-9]+(\.[0-9]+)?" | sed -E "s/^${name_hint}[._-]?[vV]?//" | sort -V | tail -n1 || true)
        if [[ -n "$ver" ]]; then
          printf '%s' "$ver"
          return 0
        fi
      fi
    fi
  fi
  return 1
}

# -------------------------
# Helpers: detect versions on specific hosts
# -------------------------
_detect_latest_github() {
  local url="$1"; local name_hint="$2"
  # Accept formats: https://github.com/owner/repo or asset URL
  # Use GitHub API if available (no auth) or scrape tags page.
  # Prefer tags/releases via anonymous API: https://api.github.com/repos/{owner}/{repo}/releases
  if [[ "$url" =~ github.com/([^/]+)/([^/]+) ]]; then
    local owner="${BASH_REMATCH[1]}"; local repo="${BASH_REMATCH[2]}"
    # query releases first
    if [[ -n "${CURL_BIN}" ]]; then
      local api="https://api.github.com/repos/${owner}/${repo}/releases"
      local json
      json=$("${CURL_BIN}" -sSL -H "Accept: application/vnd.github.v3+json" --max-time "${SCRAPE_TIMEOUT}" "${api}" 2>/dev/null || true)
      if [[ -n "$json" ]]; then
        # parse latest non-prerelease tag_name
        local tag
        tag=$(printf '%s' "$json" | grep -Eo '"tag_name":[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//' | head -n1 || true)
        if [[ -n "$tag" ]]; then
          printf '%s' "$tag"
          return 0
        fi
        # fallback: tags endpoint
        json=$("${CURL_BIN}" -sSL --max-time "${SCRAPE_TIMEOUT}" "https://api.github.com/repos/${owner}/${repo}/tags" 2>/dev/null || true)
        tag=$(printf '%s' "$json" | grep -Eo '"name":[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//' | head -n1 || true)
        if [[ -n "$tag" ]]; then
          printf '%s' "$tag"
          return 0
        fi
      fi
    fi
  fi
  return 1
}

_detect_latest_gnu() {
  local url="$1"; local name_hint="$2"
  # For GNU projects often index at ftp.gnu.org/gnu/<pkg>/
  # If URL points to a tarball path, compute directory: strip filename
  local dir
  dir=$(dirname "$url")
  # if dir contains 'ftp.gnu.org', use it directly
  if [[ -n "${CURL_BIN}" ]]; then
    local page
    page=$("${CURL_BIN}" -fsSL --max-time "${SCRAPE_TIMEOUT}" "${dir}/" 2>/dev/null || true)
    if [[ -n "$page" ]]; then
      # find patterns like pkg-1.2.3.tar.xz
      local pattern
      if [[ -n "$name_hint" ]]; then
        pattern="${name_hint}[._-]v?[0-9]+(\\.[0-9]+)*"
      else
        pattern="[A-Za-z0-9_.-]+-[0-9]+(\\.[0-9]+)*"
      fi
      local ver
      ver=$(printf '%s' "$page" | grep -Eo "${pattern}" | sed -E "s/^${name_hint}[._-]?v?//" 2>/dev/null | sed -E 's/^[^0-9]*([0-9].*)/\1/' | sort -V | tail -n1 || true)
      if [[ -n "$ver" ]]; then
        printf '%s' "$ver"
        return 0
      fi
    fi
  fi
  return 1
}

_detect_latest_sourceforge() {
  local url="$1"; local name_hint="$2"
  # Sourceforge has project pages; try to use its RSS or files listing
  if [[ -n "${CURL_BIN}" ]]; then
    local page
    page=$("${CURL_BIN}" -fsSL --max-time "${SCRAPE_TIMEOUT}" "${url}" 2>/dev/null || true)
    if [[ -n "$page" ]]; then
      local ver
      ver=$(printf '%s' "$page" | grep -Eo "${name_hint}-[0-9]+(\\.[0-9]+)*" | sed -E "s/^${name_hint}-//" | sort -V | tail -n1 || true)
      if [[ -n "$ver" ]]; then
        printf '%s' "$ver"
        return 0
      fi
    fi
  fi
  return 1
}

# -------------------------
# Compare semver-like versions (simple)
# returns:
#  0 -> equal
#  1 -> a > b
#  2 -> a < b
# naive implementation: compare numeric parts
# -------------------------
compare_versions() {
  local a="$1"; local b="$2"
  if [[ "$a" == "$b" ]]; then return 0; fi
  IFS='.-_' read -ra A <<<"$a"
  IFS='.-_' read -ra B <<<"$b"
  local i max; max=$(( ${#A[@]} > ${#B[@]} ? ${#A[@]} : ${#B[@]} ))
  for ((i=0;i<max;i++)); do
    local ai="${A[i]:-0}"; local bi="${B[i]:-0}"
    # strip non-digits at end
    ai=$(echo "$ai" | sed -E 's/[^0-9].*$//g' || true)
    bi=$(echo "$bi" | sed -E 's/[^0-9].*$//g' || true)
    ai=${ai:-0}; bi=${bi:-0}
    if ((10#${ai} > 10#${bi})); then return 1; fi
    if ((10#${ai} < 10#${bi})); then return 2; fi
  done
  return 0
}

# -------------------------
# Test link via downloader.sh if available, else use curl/wget fallback and verify sha256 if provided
# Arguments:
#   $1 url
#   $2 optional sha256
#   $3 destpath (optional)
# Returns 0 if success
# -------------------------
test_link_and_checksum() {
  local url="$1"; local sha="$2"; local dest="${3:-${TMP_DIR}/download.$(_rand)}"
  mkdir -p "$(dirname "$dest")"
  if [[ -n "${DL_CMD}" && type dl_fetch >/dev/null 2>&1 ]]; then
    # dl_fetch <url> <sha> <dest>
    if dl_fetch "$url" "$sha" "$dest"; then
      _log INFO "download test ok: $url"
      return 0
    else
      _log WARN "dl_fetch falhou para $url"
      return 1
    fi
  fi

  # curl fallback
  if [[ -n "${CURL_BIN}" ]]; then
    if "${CURL_BIN}" -L --fail --max-time 60 -o "${dest}" "${url}" >/dev/null 2>&1; then
      if [[ -n "$sha" && -n "${SHA256SUM_BIN}" ]]; then
        if echo "${sha}  ${dest}" | "${SHA256SUM_BIN}" -c - >/dev/null 2>&1; then
          _log INFO "checksum verificado para ${url}"
          return 0
        else
          _log WARN "checksum inválido para ${url}"
          rm -f "${dest}" || true
          return 2
        fi
      fi
      _log INFO "download test ok (no checksum): $url"
      return 0
    else
      _log WARN "curl falhou para $url"
    fi
  fi

  # wget fallback
  if [[ -n "${WGET_BIN}" ]]; then
    if "${WGET_BIN}" -q -O "${dest}" "${url}"; then
      if [[ -n "$sha" && -n "${SHA256SUM_BIN}" ]]; then
        if echo "${sha}  ${dest}" | "${SHA256SUM_BIN}" -c - >/dev/null 2>&1; then
          _log INFO "checksum verificado para ${url}"
          return 0
        else
          _log WARN "checksum inválido para ${url}"
          rm -f "${dest}" || true
          return 2
        fi
      fi
      _log INFO "download test ok (wget): $url"
      return 0
    else
      _log WARN "wget falhou para $url"
    fi
  fi

  _log ERROR "Nenhum método de download disponível para testar $url"
  return 3
}

# helper random
_rand() { echo $(( (RANDOM<<15) ^ RANDOM )); }

# -------------------------
# Check program dependencies using depende.sh if available
# returns 0 if ok (all deps installed)
# -------------------------
check_package_dependencies() {
  local pkg="$1"
  if type dep_check >/dev/null 2>&1; then
    # dep_check should return 0 if deps satisfied, non-zero otherwise
    if dep_check "$pkg"; then
      _log INFO "Dependências satisfeitas para ${pkg}"
      return 0
    else
      _log WARN "Dependências faltando ou não satisfeitas para ${pkg}"
      return 2
    fi
  else
    # fallback: check metafile for 'depends' key and fail if present (conservative)
    local mf; mf="$(find_metafile_for_pkg "$pkg" || true)"
    if [[ -n "$mf" ]]; then
      declare -A mm; parse_metafile "$mf" mm || true
      local deps="${mm[depends]:-}"
      if [[ -n "$deps" ]]; then
        _log WARN "depende.sh não disponível; metafile declara depends for ${pkg}: ${deps}. Atualização pode falhar."
      else
        _log DEBUG "Sem depends declaradas em metafile para ${pkg}"
      fi
    else
      _log WARN "Metafile não encontrado para ${pkg}; não é possível checar dependências"
      return 1
    fi
  fi
  return 0
}

# -------------------------
# Determine candidate new URL for a package given version and sources
# Try to construct canonical FTP/HTTP url for common patterns
# -------------------------
construct_candidate_urls() {
  local pkg="$1"; local ver="$2"
  # try standard GNU ftp
  local arr=()
  arr+=("${UPDATE_FALLBACK_MIRRORS}/${pkg}/${pkg}-${ver}.tar.xz")
  arr+=("${UPDATE_FALLBACK_MIRRORS}/${pkg}/${pkg}-${ver}.tar.gz")
  arr+=("${UPDATE_FALLBACK_MIRRORS}/${pkg}/${pkg}-${ver}.tar.bz2")
  # github variations (if name matches owner/repo style, user may provide url)
  # return array via stdout
  printf '%s\n' "${arr[@]}"
}

# -------------------------
# Update process for single package:
#  - locate metafile
#  - parse current values
#  - detect candidate latest version (scrape)
#  - compare, if new -> compute new URL candidates, test, compute sha, update metafile atomically
#  - run dry-run build if requested
#  - optionally rebuild/install
# -------------------------
_update_single_pkg() {
  local pkg="$1"
  local mode="${2:-check}"   # check | update-meta | test-link | dry-run | upgrade
  local logf="${LOG_DIR}/${pkg}.log"
  _log INFO "Iniciando operação '${mode}' para pacote: ${pkg} (log: ${logf})"
  mkdir -p "$(dirname "$logf")"
  : > "${logf}"

  # find metafile
  local mf; mf="$(find_metafile_for_pkg "$pkg" || true)"
  if [[ -z "$mf" ]]; then
    _log ERROR "Metafile não encontrado para pacote ${pkg}"
    return 2
  fi
  _log DEBUG "Metafile detectado: ${mf}"

  # parse
  declare -A META_ARR=()
  parse_metafile "$mf" META_ARR || { _log ERROR "Falha ao parsear metafile ${mf}"; return 3; }
  local cur_ver="${META_ARR[version]:-${META_ARR[${pkg}.version]:-}}"
  local cur_url="${META_ARR[url]:-${META_ARR[${pkg}.url]:-}}"
  local cur_sha="${META_ARR[sha256sums]:-${META_ARR[${pkg}.sha256]:-}}"
  _log INFO "${pkg} versão atual: ${cur_ver:-<unknown>}"

  # check dependencies first
  if ! check_package_dependencies "$pkg"; then
    _log WARN "Dependências parecem faltantes para ${pkg}; abortando operação para evitar quebra"
    return 4
  fi

  # detect latest
  local detected=""
  if [[ -n "${cur_url}" ]]; then
    detected="$(detect_latest_upstream_version "$cur_url" "$pkg" 2>>"${logf}" || true)"
  fi
  if [[ -z "$detected" ]]; then
    _log INFO "Não foi possível detectar versão upstream automaticamente para ${pkg} (usar --update-meta manualmente)"
    detected=""
  else
    _log INFO "Versão upstream detectada para ${pkg}: ${detected}"
  fi

  # if mode is --check, compare and exit
  if [[ "$mode" == "check" ]]; then
    if [[ -z "$detected" ]]; then
      _log INFO "Sem informação de versão upstream para ${pkg}"
      return 0
    fi
    if [[ -z "${cur_ver}" ]]; then
      _log INFO "${pkg} não possui versão declarada; upstream: ${detected}"
      return 0
    fi
    compare_versions "$detected" "$cur_ver"
    local cmp=$?
    if [[ $cmp -eq 1 ]]; then
      _log INFO "${pkg}: nova versão disponível ${detected} (atual ${cur_ver})"
      return 1
    elif [[ $cmp -eq 2 ]]; then
      _log INFO "${pkg}: versão atual ${cur_ver} é mais recente que upstream ${detected}? (possível anomalia)"
      return 0
    else
      _log INFO "${pkg}: já está atualizado (${cur_ver})"
      return 0
    fi
  fi

  # For update-meta / upgrade: if detected empty allow manual override
  if [[ "$mode" == "update-meta" || "$mode" == "upgrade" || "$mode" == "dry-run" || "$mode" == "test-link" ]]; then
    # Determine candidate version: prefer detected, else require manual interactive version (not interactive here)
    local new_ver="${detected:-}"
    if [[ -z "$new_ver" ]]; then
      _log WARN "Nenhuma versão detectada automaticamente para ${pkg}; atualizando apenas se caller forneceu explicit version (not implemented). Aborting."
      return 5
    fi

    # If same as current -> nothing to do (unless force)
    if [[ -n "${cur_ver}" ]]; then
      compare_versions "${new_ver}" "${cur_ver}"; cmp=$?
      if [[ $cmp -eq 0 ]]; then
        _log INFO "${pkg} já está em ${cur_ver}, nada a atualizar"
        # still allow test-link / dry-run if requested; but for update-meta skip
        if [[ "$mode" == "update-meta" ]]; then return 0; fi
      fi
    fi

    # construct possible URLs and test
    local candidate_urls=()
    # If current URL root can be used: replace version segment if possible
    if [[ -n "${cur_url}" ]]; then
      # try substitution: replace cur_ver with new_ver
      if [[ "${cur_url}" =~ ${cur_ver} ]]; then
        candidate_urls+=("${cur_url//${cur_ver}/${new_ver}}")
      fi
      # try base dir
      local base_dir; base_dir=$(dirname "${cur_url}")
      candidate_urls+=("${base_dir}/${pkg}-${new_ver}.tar.xz")
      candidate_urls+=("${base_dir}/${pkg}-${new_ver}.tar.gz")
    fi
    # add constructed candidates
    while IFS= read -r l; do candidate_urls+=("$l";) done < <(construct_candidate_urls "$pkg" "$new_ver")

    # remove duplicates
    candidate_urls=($(printf "%s\n" "${candidate_urls[@]}" | awk '!seen[$0]++'))
    _log DEBUG "Candidate URLs: ${candidate_urls[*]}"

    local chosen_url=""
    local chosen_sha=""
    for u in "${candidate_urls[@]}"; do
      _log INFO "Testando URL candidate: ${u}"
      if test_link_and_checksum "$u" "" "${TMP_DIR}/${pkg}-${new_ver}.tmp" ; then
        chosen_url="$u"
        # compute sha
        if [[ -n "${SHA256SUM_BIN}" ]]; then
          chosen_sha="$("${SHA256SUM_BIN}" "${TMP_DIR}/${pkg}-${new_ver}.tmp" | awk '{print $1}')"
        fi
        break
      else
        _log DEBUG "Candidate $u falhou"
      fi
    done

    if [[ -z "$chosen_url" ]]; then
      _log WARN "Nenhuma URL candidata funcionou para ${pkg} ${new_ver}"
      return 6
    fi
    _log INFO "Escolhida URL para ${pkg}: ${chosen_url}"
    _log DEBUG "Computed sha256: ${chosen_sha:-<none>}"

    # prepare kvs to update metafile
    declare -A kv=()
    # common keys: version, url, sha256sums (or <pkg>.version etc)
    # detect existing format keys in META_ARR
    if [[ -n "${META_ARR[version]:-}" || -n "${META_ARR[url]:-}" ]]; then
      kv[version]="${new_ver}"
      kv[url]="${chosen_url}"
      [[ -n "${chosen_sha}" ]] && kv[sha256sums]="${chosen_sha}"
    else
      # fallback to pkg-specific keys
      kv["${pkg}.version"]="${new_ver}"
      kv["${pkg}.url"]="${chosen_url}"
      [[ -n "${chosen_sha}" ]] && kv["${pkg}.sha256"]="${chosen_sha}"
    fi

    # If mode is test-link-only
    if [[ "$mode" == "test-link" ]]; then
      _log INFO "test-link: URL válida para ${pkg}: ${chosen_url}"
      return 0
    fi

    # update metafile atomically
    update_metafile_atomic "$mf" kv || { _log ERROR "Falha ao atualizar metafile para ${pkg}"; return 7; }

    # If mode is update-meta only, done
    if [[ "$mode" == "update-meta" ]]; then
      _log INFO "metafile atualizado para ${pkg} -> ${new_ver}"
      return 0
    fi

    # If mode dry-run: call build.sh with --metafile <mf> --dry-run or equivalent
    if [[ "$mode" == "dry-run" ]]; then
      if [[ -x "${BUILD_CMD}" ]]; then
        _log INFO "Executando build (dry-run) para ${pkg}"
        if "${BUILD_CMD}" --metafile "${mf}" --dry-run >>"${logf}" 2>&1; then
          _log INFO "dry-run build OK para ${pkg}"
          return 0
        else
          _log ERROR "dry-run build falhou para ${pkg}; ver ${logf}"
          return 8
        fi
      else
        _log ERROR "build.sh não encontrado em ${BUILD_CMD}; não é possível executar dry-run"
        return 9
      fi
    fi

    # If mode upgrade: perform full rebuild/install
    if [[ "$mode" == "upgrade" ]]; then
      # run test download + sha already done, now invoke build with actual install
      if [[ -x "${BUILD_CMD}" ]]; then
        _log INFO "Iniciando upgrade (rebuild+install) para ${pkg}"
        if "${BUILD_CMD}" --metafile "${mf}" >>"${logf}" 2>&1; then
          _log INFO "Upgrade/build concluído para ${pkg}"
          return 0
        else
          _log ERROR "Build/install falhou para ${pkg}; revertendo metafile (restaurar .bak)"
          # attempt rollback of metafile
          local bak="${mf}.bak.${_SESSION_TS}"
          if [[ -f "${bak}" ]]; then
            cp -a "${bak}" "${mf}" || _log WARN "Falha ao restaurar metafile de backup ${bak}"
          fi
          return 10
        fi
      else
        _log ERROR "build.sh não encontrado; não é possível executar upgrade"
        return 11
      fi
    fi
  fi

  _log DEBUG "update_single_pkg fim"
  return 0
}

# -------------------------
# Rollback routine (best-effort)
# -------------------------
_update_rollback() {
  _log WARN "update.sh rollback: tentando restaurar estado anterior se aplicável"
  # look for backups in META_SEARCH_DIRS for this session and restore if present
  for d in ${META_SEARCH_DIRS}; do
    if [[ -d "$d" ]]; then
      for bak in $(find "$d" -type f -name "*.bak.${_SESSION_TS}" 2>/dev/null || true); do
        local orig="${bak%.bak.${_SESSION_TS}}"
        if [[ -f "$bak" ]]; then
          cp -a "$bak" "$orig" 2>/dev/null || _log WARN "Falha ao restaurar $orig from $bak"
          _log INFO "Restaurado metafile $orig a partir de $bak"
        fi
      done
    fi
  done
  _release_lock || true
}

# -------------------------
# Iterate all metafiles under META_SEARCH_DIRS and perform action
# -------------------------
_update_all_packages() {
  local action="$1"   # check|update-meta|test-link|dry-run|upgrade
  local updated=()
  local failed=()
  for d in ${META_SEARCH_DIRS}; do
    if [[ -d "$d" ]]; then
      # find ini files
      while IFS= read -r mf; do
        [[ -z "$mf" ]] && continue
        # derive pkg name from file name
        local base; base="$(basename "$mf")"
        local pkg="${base%%.*}"
        _log DEBUG "processando metafile detected: $mf (pkg=${pkg})"
        if _update_single_pkg "$pkg" "$action"; then
          updated+=("$pkg")
        else
          failed+=("$pkg")
        fi
      done < <(find "$d" -maxdepth 3 -type f -iname "*.ini" -o -iname "*.meta" 2>/dev/null || true)
    fi
  done
  _log INFO "Resumo: atualizados: ${#updated[@]}; falhas: ${#failed[@]}"
  if (( ${#failed[@]} > 0 )); then
    _log WARN "Pacotes que falharam: ${failed[*]}"
  fi
}
# ------- Part 2 of update.sh (append to Part 1) -------

# -------------------------
# CLI and main dispatcher
# -------------------------
_print_usage() {
  cat <<EOF
update.sh - verifica upstream, atualiza metafiles, testa links, rebuild (dry-run/upgrade)

Uso:
  update.sh --check <pkg>           : verifica se há nova versão upstream
  update.sh --update-meta <pkg>    : atualiza apenas o metafile (version/url/sha)
  update.sh --test-link <pkg>      : testa link/sha sem alterar metafile
  update.sh --dry-run <pkg>        : testa build sem instalar (após update-meta)
  update.sh --upgrade <pkg>        : atualiza metafile, rebuild e instala
  update.sh --all --check|--upgrade|--dry-run : aplica ação a todos os metafiles
  update.sh --rollback <pkg>       : restaura metafile do .bak mais recente (por sessão)
  update.sh --help                 : mostra ajuda

Flags ENV:
  UPDATE_DEBUG=true      - ativa logs debug
  UPDATE_SILENT=true     - suprime INFO/WARN (apenas ERROR mostrados)

Exemplos:
  update.sh --check gcc
  update.sh --update-meta gcc
  update.sh --test-link gcc
  update.sh --dry-run gcc
  update.sh --upgrade --all
EOF
}

_main() {
  if (( $# == 0 )); then
    _print_usage; exit 0
  fi

  _acquire_lock
  trap '_update_rollback; exit 1' ERR INT TERM
  local cmd="$1"; shift

  case "$cmd" in
    --check)
      pkg="$1"; shift || _fail "--check requer pacote"
      _update_single_pkg "$pkg" "check"
      _release_lock
      ;;

    --update-meta)
      pkg="$1"; shift || _fail "--update-meta requer pacote"
      _update_single_pkg "$pkg" "update-meta"
      _release_lock
      ;;

    --test-link)
      pkg="$1"; shift || _fail "--test-link requer pacote"
      _update_single_pkg "$pkg" "test-link"
      _release_lock
      ;;

    --dry-run)
      pkg="$1"; shift || _fail "--dry-run requer pacote"
      _update_single_pkg "$pkg" "dry-run"
      _release_lock
      ;;

    --upgrade)
      # support --upgrade <pkg> or --upgrade --all
      if [[ "${1:-}" == "--all" || "${1:-}" == "all" ]]; then
        _update_all_packages "upgrade"
      elif [[ -n "${1:-}" ]]; then
        pkg="$1"; shift
        _update_single_pkg "$pkg" "upgrade"
      else
        _fail "--upgrade requer pacote ou --all"
      fi
      _release_lock
      ;;

    --all)
      # --all combined with an action, next arg
      act="$1"; shift || _fail "--all requer uma ação (check|upgrade|dry-run|update-meta)"
      if [[ "$act" == "--check" || "$act" == "check" ]]; then
        _update_all_packages "check"
      elif [[ "$act" == "--upgrade" || "$act" == "upgrade" ]]; then
        _update_all_packages "upgrade"
      elif [[ "$act" == "--dry-run" || "$act" == "dry-run" ]]; then
        _update_all_packages "dry-run"
      elif [[ "$act" == "--update-meta" || "$act" == "update-meta" ]]; then
        _update_all_packages "update-meta"
      else
        _fail "Ação inválida para --all: $act"
      fi
      _release_lock
      ;;

    --rollback)
      pkg="$1"; shift || _fail "--rollback requer pacote"
      # locate latest bak for this session or any
      local mf; mf="$(find_metafile_for_pkg "$pkg" || true)"
      if [[ -z "$mf" ]]; then _fail "Metafile não encontrado para $pkg"; fi
      local bak; bak="$(ls -1 "${mf}".bak.* 2>/dev/null | tail -n1 || true)"
      if [[ -z "$bak" ]]; then _fail "Nenhum backup encontrado para ${mf}"; fi
      cp -a "${bak}" "${mf}" || _fail "Falha ao restaurar ${mf} a partir de ${bak}"
      _log INFO "Rollback aplicado: ${mf} <- ${bak}"
      _release_lock
      ;;

    --help|-h)
      _print_usage
      _release_lock
      ;;

    *)
      _print_usage
      _release_lock
      exit 2
      ;;
  esac
}

# Export useful functions if others want to source
export -f find_metafile_for_pkg parse_metafile update_metafile_atomic detect_latest_upstream_version \
  compare_versions test_link_and_checksum check_package_dependencies _update_single_pkg _update_all_packages

# Run main when executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _main "$@"
fi
