#!/usr/bin/env bash
# metafile.sh - gerenciador de metafiles (.ini) para orquestrador LFS
# Funções: meta_create, meta_load, meta_validate, meta_write (atômico), meta_backup, meta_diff, meta_list, meta_set/get, meta_export_env
# Integração com register.sh (register_info, register_warn, register_error, register_debug)
# Suporte a campos opcionais: build_deps,opt_deps,patches,hooks,sources,sha256sums,depends,category,description,urls
# Versão: 2025-10-23

set -eEuo pipefail
IFS=$'\n\t'
umask 027

# -------------------------
# Configuráveis por ENV
# -------------------------
: "${META_DIRS:=/usr/src /mnt/lfs/usr/src /usr/src/repo /mnt/lfs/usr/src/repo}"
: "${META_DEFAULT_DIR:=/usr/src}"
: "${META_LOG_DIR:=/var/log/orquestrador/metafile}"
: "${META_LOCK_DIR:=/run/lock/orquestrador}"
: "${META_BACKUP_RETENTION:=10}"   # número de backups a manter por metafile
: "${META_TMP_DIR:=/var/tmp/orquestrador/metafile}"
: "${META_SILENT:=false}"
: "${META_DEBUG:=false}"
: "${META_FILEMODE:=0640}"

# runtime
_SESSION_TS="$(date -u +"%Y%m%dT%H%M%SZ")-$$"
_LOCK_FD=""
mkdir -p "${META_LOG_DIR}" "${META_TMP_DIR}" "${META_LOCK_DIR}" 2>/dev/null || true

# -------------------------
# Logging helpers (register integration)
# -------------------------
_meta_log() {
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
  if [[ "${META_SILENT}" == "true" && "$level" != "ERROR" ]]; then
    return 0
  fi
  case "$level" in
    INFO)  printf '\e[32m[INFO]\e[0m %s\n' "$msg" ;;
    WARN)  printf '\e[33m[WARN]\e[0m %s\n' "$msg" >&2 ;;
    ERROR) printf '\e[31m[ERROR]\e[0m %s\n' "$msg" >&2 ;;
    DEBUG) [[ "${META_DEBUG}" == "true" ]] && printf '\e[36m[DEBUG]\e[0m %s\n' "$msg" ;;
    *) printf '[LOG] %s\n' "$msg" ;;
  esac
  # append to log file
  local logfile="${META_LOG_DIR}/metafile-${_SESSION_TS}.log"
  printf '%s %s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "[$level]" "$msg" >> "${logfile}" 2>/dev/null || true
}

_meta_fail() {
  local msg="$1"; local code="${2:-1}"
  _meta_log ERROR "$msg"
  exit "$code"
}

# -------------------------
# Lock helpers (global)
# -------------------------
_meta_acquire_lock() {
  local lf="${META_LOCK_DIR}/metafile.lock"
  exec {META_LOCK_FD}>"${lf}" || _meta_fail "Não pode abrir lock ${lf}"
  if flock -n "${META_LOCK_FD}"; then
    _meta_log DEBUG "Lock global metafile adquirido"
    return 0
  fi
  _meta_log INFO "Aguardando lock global em ${lf}..."
  local waited=0
  local timeout="${META_LOCK_TIMEOUT:-300}"
  while ! flock -n "${META_LOCK_FD}"; do
    sleep 1
    waited=$((waited+1))
    if (( waited >= timeout )); then
      _meta_fail "Timeout aguardando lock global (${timeout}s)"
    fi
  done
  _meta_log DEBUG "Lock global adquirido após ${waited}s"
}

_meta_release_lock() {
  if [[ -n "${META_LOCK_FD:-}" ]]; then
    eval "exec ${META_LOCK_FD}>&-"
    unset META_LOCK_FD
  fi
}

# -------------------------
# Helpers
# -------------------------
_realpath() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
  else
    (cd "$(dirname "$1")" 2>/dev/null && echo "$(pwd -P)/$(basename "$1")")" || echo "$1"
  fi
}

_safe_mkdir() {
  mkdir -p "$1" 2>/dev/null || _meta_fail "Falha ao criar diretório $1"
  chmod 750 "$1" 2>/dev/null || true
}

# atomic write helper: write to tmp then mv
_atomic_write() {
  local target="$1"; local tmp; tmp="$(mktemp "${META_TMP_DIR}/metafile.tmp.XXXX")"
  cat > "$tmp" || return 1
  mv -f "$tmp" "$target" || return 2
  chmod "${META_FILEMODE}" "$target" 2>/dev/null || true
  return 0
}

# sanitize key/value lines (keep safe chars)
_sanitize_kv_line() {
  local k="$1"; local v="$2"
  # remove control chars, keep printable
  k="$(printf '%s' "$k" | tr -cd '[:alnum:]._-')"
  v="$(printf '%s' "$v" | sed -E 's/[\r\n]+/ /g' | sed -E 's/[[:cntrl:]]//g')"
  printf '%s=%s\n' "$k" "$v"
}

# timestamp suffix
_ts() { date -u +"%Y%m%dT%H%M%SZ"; }

# -------------------------
# meta_find - locate metafile by package name or path
# Usage: meta_find <pkg_or_path>
# Returns path on stdout; exit 0 if found else non-zero
# -------------------------
meta_find() {
  local what="$1"
  # if path exists and is file -> return
  if [[ -f "$what" ]]; then
    printf '%s' "$(realpath "$what")"
    return 0
  fi
  # search by name across META_DIRS
  for d in ${META_DIRS}; do
    if [[ -d "${d}" ]]; then
      # exact name.ini or name.meta
      local f
      f=$(find "${d}" -maxdepth 4 -type f \( -iname "${what}.ini" -o -iname "${what}.meta" -o -iname "${what}*.ini" \) 2>/dev/null | head -n1 || true)
      if [[ -n "$f" ]]; then
        printf '%s' "$f"
        return 0
      fi
      # directory style /category/pkg/*.ini
      f=$(find "${d}" -maxdepth 5 -type f -path "*/${what}/*.ini" 2>/dev/null | head -n1 || true)
      if [[ -n "$f" ]]; then
        printf '%s' "$f"
        return 0
      fi
    fi
  done
  return 1
}
# -------------------------
# meta_list - list available metafiles (print paths)
# Usage: meta_list [dir]
# -------------------------
meta_list() {
  local dir="${1:-}"
  if [[ -n "$dir" ]]; then
    if [[ -d "$dir" ]]; then
      find "$dir" -maxdepth 4 -type f -iname "*.ini" -o -iname "*.meta" 2>/dev/null || true
    else
      _meta_log WARN "Diretório não existe: $dir"
      return 1
    fi
  else
    for d in ${META_DIRS}; do
      if [[ -d "$d" ]]; then
        find "$d" -maxdepth 4 -type f \( -iname "*.ini" -o -iname "*.meta" \) 2>/dev/null || true
      fi
    done
  fi
}
# -------------------------
# meta_load - parse a metafile into associative array and export META_* globals
# Usage: meta_load <file> [assoc_name]  # assoc_name optional to receive associative array by name
# Exports globals: META_NAME, META_VERSION, META_URLS, META_SHA256S, META_DEPENDS, META_CATEGORY
# -------------------------
meta_load() {
  local file="$1"; local out_assoc="$2"
  if [[ -z "$file" ]]; then _meta_fail "meta_load: file required"; fi
  if [[ ! -f "$file" ]]; then _meta_fail "meta_load: metafile não encontrado: $file"; fi

  declare -A meta_tmp=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    # strip comments
    line="${line%%#*}"
    line="${line%%;*}"
    line="$(echo -n "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^([A-Za-z0-9_.-]+)=(.*)$ ]]; then
      local k="${BASH_REMATCH[1]}"
      local v="${BASH_REMATCH[2]}"
      # trim
      v="$(echo -n "$v" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
      meta_tmp["$k"]="$v"
    fi
  done < "$file"

  # export common fields
  META_NAME="${meta_tmp[name]:-${meta_tmp[package]:-}}"
  META_VERSION="${meta_tmp[version]:-${meta_tmp[${META_NAME}.version]:-}}"
  META_URLS="${meta_tmp[urls]:-${meta_tmp[url]:-${meta_tmp[${META_NAME}.url]:-}}}"
  META_SHA256S="${meta_tmp[sha256sums]:-${meta_tmp[sha256]:-}}"
  META_DEPENDS="${meta_tmp[depends]:-}"
  META_CATEGORY="${meta_tmp[category]:-}"
  META_DESCRIPTION="${meta_tmp[description]:-}"
  META_SOURCES="${meta_tmp[sources]:-}"
  META_PATCHES="${meta_tmp[patches]:-}"
  META_HOOKS="${meta_tmp[hooks]:-}"
  META_BUILD_DEPS="${meta_tmp[build_deps]:-}"
  META_OPT_DEPS="${meta_tmp[opt_deps]:-}"

  # export as associative if requested
  if [[ -n "${out_assoc:-}" ]]; then
    # create assoc in caller by name using eval
    eval "declare -g -A ${out_assoc} || true"
    for k in "${!meta_tmp[@]}"; do
      local v="${meta_tmp[$k]}"
      # escape quotes
      v="${v//\"/\\\"}"
      eval "${out_assoc}[\"$k\"]=\"$v\""
    done
  fi

  export META_NAME META_VERSION META_URLS META_SHA256S META_DEPENDS META_CATEGORY META_DESCRIPTION META_SOURCES META_PATCHES META_HOOKS META_BUILD_DEPS META_OPT_DEPS
  _meta_log DEBUG "meta_load: ${file} -> name=${META_NAME:-<none>} version=${META_VERSION:-<none>}"
  return 0
}
# -------------------------
# meta_validate - basic validation of metafile, returns 0 if ok, non-zero otherwise
# checks: name present, version present (not mandatory?), url or sources present, sha if url present optionally
# -------------------------
meta_validate() {
  local file="$1"
  if [[ -z "$file" ]]; then _meta_fail "meta_validate: file required"; fi
  if [[ ! -f "$file" ]]; then _meta_fail "meta_validate: file not found: $file"; fi

  # load to env
  meta_load "$file" META_TMP || return 2

  local ok=0
  if [[ -z "${META_NAME:-}" ]]; then
    _meta_log ERROR "meta_validate: campo 'name' ausente em $file"
    ok=1
  fi
  if [[ -z "${META_URLS:-}" && -z "${META_SOURCES:-}" ]]; then
    _meta_log WARN "meta_validate: nem 'url(s)' nem 'sources' definidos em $file (pode ser intencional)"
    # not fatal; allow sources-only metafile
  fi
  # if URL provided but no sha, warn (not fatal)
  if [[ -n "${META_URLS:-}" && -z "${META_SHA256S:-}" ]]; then
    _meta_log WARN "meta_validate: URL presente mas sem sha256sums em $file (recomenda-se adicionar)"
  fi

  # validate optional lists: ensure no invalid characters
  for fld in META_PATCHES META_HOOKS META_BUILD_DEPS META_OPT_DEPS; do
    local val="${!fld:-}"
    if [[ -n "$val" ]]; then
      # ensure delimiter comma or semicolon or space allowed
      if ! printf '%s' "$val" | grep -qE '[A-Za-z0-9._/,-]'; then
        _meta_log WARN "meta_validate: campo ${fld} tem caracteres incomuns"
      fi
    fi
  done

  return $ok
}

# -------------------------
# meta_backup - create backup copy with timestamp, keep retention count
# Usage: meta_backup <file>
# -------------------------
meta_backup() {
  local file="$1"
  [[ -f "$file" ]] || { _meta_log WARN "meta_backup: file not found: $file"; return 1; }
  local ts; ts="$(_ts)"
  local bak="${file}.bak.${ts}"
  cp -a "$file" "${bak}" || { _meta_log ERROR "meta_backup: falha ao criar backup ${bak}"; return 2; }
  _meta_log INFO "Backup criado: ${bak}"
  # cleanup older backups
  local dir; dir="$(dirname "$file")"; local base; base="$(basename "$file")"
  local list; IFS=$'\n' read -r -d '' -a list < <(find "${dir}" -maxdepth 1 -type f -name "${base}.bak.*" -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}' && printf '\0')
  local cnt="${#list[@]}"
  if (( cnt > META_BACKUP_RETENTION )); then
    local toremove=$((cnt - META_BACKUP_RETENTION))
    for ((i=0;i<toremove;i++)); do
      rm -f "${list[i]}" || true
      _meta_log DEBUG "meta_backup: removed old backup ${list[i]}"
    done
  fi
  return 0
}
# -------------------------
# meta_write - atomic update of metafile
# Usage: meta_write <file> <assoc_var_name_with_updates>
# The assoc var is name of associative array in caller containing key->value pairs to be set/added
# -------------------------
meta_write() {
  local file="$1"; local assoc_name="$2"
  if [[ -z "$file" || -z "$assoc_name" ]]; then _meta_fail "meta_write: file and assoc name required"; fi
  if [[ ! -f "$file" ]]; then _meta_fail "meta_write: target file not found: $file"; fi

  # create backup first
  meta_backup "$file" || _meta_log WARN "meta_write: backup may have failed"

  # read assoc into local
  declare -n updates="$assoc_name"

  local tmp; tmp="$(mktemp "${META_TMP_DIR}/mf.tmp.XXXX")" || _meta_fail "meta_write: mktemp failed"
  # mark replaced keys
  declare -A replaced=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    # preserve comments/blank lines
    if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$(echo -n "$line" | sed -E 's/[[:space:]]+//g')" ]]; then
      printf '%s\n' "$line" >> "$tmp"
      continue
    fi
    if [[ "$line" =~ ^([A-Za-z0-9_.-]+)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      if [[ -n "${updates[$key]:-}" ]]; then
        printf '%s=%s\n' "$key" "${updates[$key]}" >> "$tmp"
        replaced["$key"]=1
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    else
      # unknown line, keep
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"

  # append new keys not replaced
  for k in "${!updates[@]}"; do
    if [[ -z "${replaced[$k]:-}" ]]; then
      printf '%s=%s\n' "$k" "${updates[$k]}" >> "$tmp"
    fi
  done

  # atomic move
  mv -f "$tmp" "$file" || { cp -a "${file}.bak.${_SESSION_TS}" "$file"; _meta_fail "meta_write: mv failed, restored backup"; }
  chmod "${META_FILEMODE}" "$file" 2>/dev/null || true
  _meta_log INFO "meta_write: atualizado ${file}"
  return 0
}
# -------------------------
# meta_create - generate a new metafile skeleton
# Usage: meta_create <category> <name> [dir]
# If dir not provided, uses META_DEFAULT_DIR/<category>/<name>.ini
# -------------------------
meta_create() {
  local category="$1"; local name="$2"; local dir="${3:-}"
  if [[ -z "$category" || -z "$name" ]]; then _meta_fail "meta_create: usage: meta_create <category> <name> [dir]"; fi

  local base_dir="${dir:-${META_DEFAULT_DIR}/${category}/${name}}"
  _safe_mkdir "${base_dir}"
  local file="${base_dir}/${name}.ini"

  if [[ -f "$file" ]]; then
    _meta_log WARN "meta_create: file already exists: $file"
    return 1
  fi

  cat > "$file" <<'EOF'
# Metafile generated by metafile.sh
# Edit values as needed
name=__NAME__
version=0.0.1
urls=https://example.org/__NAME__-__VERSION__.tar.xz
sha256sums=
category=__CATEGORY__
depends=
build_deps=
opt_deps=
sources=
patches=
hooks=
description=Example package __NAME__
EOF

  # replace tokens
  sed -i "s|__NAME__|${name}|g; s|__CATEGORY__|${category}|g; s|__VERSION__|0.0.1|g" "$file"
  chmod "${META_FILEMODE}" "$file" 2>/dev/null || true
  _meta_log INFO "meta_create: criado $file"
  return 0
}

# -------------------------
# meta_get_field - print a field value
# Usage: meta_get_field <field> <file>
# -------------------------
meta_get_field() {
  local field="$1"; local file="$2"
  if [[ -z "$field" || -z "$file" ]]; then _meta_fail "meta_get_field: usage"; fi
  if [[ ! -f "$file" ]]; then _meta_fail "meta_get_field: file not found: $file"; fi
  awk -F= -v k="$field" '$0 !~ /^#/ && $1==k { sub(/^[^=]*=/,""); print; exit }' "$file" || true
}

# -------------------------
# meta_set_field - set a single key value (atomic)
# Usage: meta_set_field <field> <value> <file>
# -------------------------
meta_set_field() {
  local field="$1"; local value="$2"; local file="$3"
  if [[ -z "$field" || -z "$file" ]]; then _meta_fail "meta_set_field: usage"; fi
  if [[ ! -f "$file" ]]; then _meta_fail "meta_set_field: file not found: $file"; fi
  declare -A up; up["$field"]="$value"
  meta_write "$file" up
}

# -------------------------
# meta_diff - show diff between current and last backup (or between two files)
# Usage: meta_diff <file> [backupfile]
# -------------------------
meta_diff() {
  local file="$1"; local bak="$2"
  if [[ -z "$file" ]]; then _meta_fail "meta_diff: usage"; fi
  if [[ -z "$bak" ]]; then
    # find latest backup
    local dir; dir="$(dirname "$file")"; local base; base="$(basename "$file")"
    bak="$(ls -1 "${dir}/${base}.bak.*" 2>/dev/null | tail -n1 || true)"
    if [[ -z "$bak" ]]; then
      _meta_log INFO "meta_diff: nenhum backup encontrado para $file"
      return 1
    fi
  fi
  if [[ ! -f "$bak" ]]; then _meta_fail "meta_diff: backup not found: $bak"; fi
  _meta_log INFO "Mostrando diff: ${bak} -> ${file}"
  diff -u "$bak" "$file" || true
}

# -------------------------
# meta_export_env - export meta fields into environment variables (useful for build.sh)
# Usage: meta_export_env <file>
# Exports: MF_NAME, MF_VERSION, MF_URLS, MF_SHA256S, MF_DEPENDS, MF_SOURCES, MF_PATCHES, MF_HOOKS, MF_BUILD_DEPS, MF_OPT_DEPS, MF_CATEGORY
# -------------------------
meta_export_env() {
  local file="$1"
  if [[ -z "$file" ]]; then _meta_fail "meta_export_env: usage"; fi
  meta_load "$file" MF_ASSOC || return 2
  export MF_NAME="${META_NAME:-}"
  export MF_VERSION="${META_VERSION:-}"
  export MF_URLS="${META_URLS:-}"
  export MF_SHA256S="${META_SHA256S:-}"
  export MF_DEPENDS="${META_DEPENDS:-}"
  export MF_SOURCES="${META_SOURCES:-}"
  export MF_PATCHES="${META_PATCHES:-}"
  export MF_HOOKS="${META_HOOKS:-}"
  export MF_BUILD_DEPS="${META_BUILD_DEPS:-}"
  export MF_OPT_DEPS="${META_OPT_DEPS:-}"
  export MF_CATEGORY="${META_CATEGORY:-}"
  _meta_log DEBUG "meta_export_env: exported MF_* variables for $file"
}

# -------------------------
# meta_clean_backups - remove backups older than retention policy across META_DIRS
# Usage: meta_clean_backups [retention]
# -------------------------
meta_clean_backups() {
  local retention="${1:-${META_BACKUP_RETENTION}}"
  for d in ${META_DIRS}; do
    if [[ -d "$d" ]]; then
      while IFS= read -r bak; do
        # collect backups per base file
        local base; base="$(basename "${bak%%.bak.*}")"
        local dir; dir="$(dirname "$bak")"
        # list backups for base
        local arr; IFS=$'\n' read -r -d '' -a arr < <(find "${dir}" -maxdepth 1 -type f -name "${base}.bak.*" -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}' && printf '\0')
        local cnt="${#arr[@]}"
        if (( cnt > retention )); then
          local toremove=$((cnt - retention))
          for ((i=0;i<toremove;i++)); do
            rm -f "${arr[i]}" || true
            _meta_log DEBUG "meta_clean_backups removed ${arr[i]}"
          done
        fi
      done < <(find "$d" -type f -name "*.bak.*" 2>/dev/null || true)
    fi
  done
}

# -------------------------
# CLI dispatcher
# -------------------------
_print_help() {
  cat <<EOF
metafile.sh - gerenciador de metafiles (.ini)

Uso:
  metafile.sh --create <category> <name> [dir]   : cria novo metafile template
  metafile.sh --list [dir]                      : lista metafiles (por padrão META_DIRS)
  metafile.sh --load <file>                     : carrega e mostra variáveis do metafile
  metafile.sh --get <field> <file>              : retorna valor do campo
  metafile.sh --set <field> <value> <file>      : atualiza campo (atômico)
  metafile.sh --backup <file>                   : cria backup manual do metafile
  metafile.sh --diff <file> [backup]            : mostra diff entre file e backup (último se não informado)
  metafile.sh --validate <file>                 : valida metafile
  metafile.sh --export-env <file>               : exporta variáveis MF_* no ambiente
  metafile.sh --clean-backups [retention]       : limpa backups antigos
  metafile.sh --help | -h
Flags via ENV:
  META_DEBUG=true    - ativa logs debug
  META_SILENT=true   - suprime INFO/WARN (apenas ERROR)
EOF
}

# main CLI
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if (( $# == 0 )); then _print_help; exit 0; fi
  cmd="$1"; shift
  case "$cmd" in
    --create)
      category="$1"; name="$2"; dir="${3:-}"
      meta_create "$category" "$name" "$dir"
      exit $?
      ;;
    --list)
      dir="${1:-}"
      meta_list "$dir"
      exit $?
      ;;
    --load)
      file="$1"
      meta_load "$file" META_TMP
      # display loaded values
      printf 'NAME=%s\nVERSION=%s\nURLS=%s\nSHA256S=%s\nDEPENDS=%s\nCATEGORY=%s\nSOURCES=%s\nPATCHES=%s\nHOOKS=%s\nBUILD_DEPS=%s\nOPT_DEPS=%s\nDESCRIPTION=%s\n' \
        "${META_NAME:-}" "${META_VERSION:-}" "${META_URLS:-}" "${META_SHA256S:-}" "${META_DEPENDS:-}" "${META_CATEGORY:-}" "${META_SOURCES:-}" "${META_PATCHES:-}" "${META_HOOKS:-}" "${META_BUILD_DEPS:-}" "${META_OPT_DEPS:-}" "${META_DESCRIPTION:-}"
      exit 0
      ;;
    --get)
      field="$1"; file="$2"
      meta_get_field "$field" "$file"
      exit $?
      ;;
    --set)
      field="$1"; value="$2"; file="$3"
      meta_set_field "$field" "$value" "$file"
      exit $?
      ;;
    --backup)
      file="$1"
      meta_backup "$file"
      exit $?
      ;;
    --diff)
      file="$1"; bak="$2"
      meta_diff "$file" "$bak"
      exit $?
      ;;
    --validate)
      file="$1"
      meta_validate "$file"
      exit $?
      ;;
    --export-env)
      file="$1"
      meta_export_env "$file"
      exit $?
      ;;
    --clean-backups)
      retention="${1:-}"
      meta_clean_backups "$retention"
      exit $?
      ;;
    --help|-h)
      _print_help
      exit 0
      ;;
    *)
      _print_help
      exit 2
      ;;
  esac
fi

# Export core functions for sourcing by other scripts
export -f meta_find meta_list meta_load meta_validate meta_backup meta_write meta_create meta_get_field meta_set_field meta_diff meta_export_env meta_clean_backups
