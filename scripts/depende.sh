#!/usr/bin/env bash
# depende.sh - resolução e instalação automática de dependências para Orquestrador LFS
# - formato packages.db: pacote|versão|depends|build_deps|opt_deps
# - integrações: metafile.sh (meta_load), build.sh (construir dependências), register.sh (logs)
# - funcionalidades: resolve, install, check, orphans, rebuild-all, graph export, etc.
# Versão: 2025-10-23

set -eEuo pipefail
IFS=$'\n\t'
umask 027

SCRIPT_NAME="depende"
SCRIPT_VERSION="1.0.0"

# -------------------------
# Configuráveis (ENV)
# -------------------------
: "${DB_PATH:=/var/lib/orquestrador/packages.db}"
: "${DB_LOCK_DIR:=/run/lock/orquestrador}"
: "${DB_BACKUP_DIR:=/var/lib/orquestrador/backups}"
: "${DB_RETENTION:=10}"
: "${DEP_CACHE_DIR:=/var/cache/orquestrador/deps}"
: "${GRAPH_DIR:=/var/lib/orquestrador/graphs}"
: "${BUILD_CMD:="/usr/bin/build.sh"}"
: "${META_CMD:="/usr/bin/metafile.sh"}"
: "${REGISTER_IF_PRESENT:=true}"
: "${DEP_DEBUG:=false}"
: "${DEP_SILENT:=false}"
: "${DEP_FAIL_ON_MISSING:=false}"   # if true, abort when missing metafile for a dep
: "${DEP_VIRTUAL_MAP:=}"            # file path to map virtual names -> comma list (optional)

mkdir -p "$(dirname "${DB_PATH}")" "${DB_LOCK_DIR}" "${DB_BACKUP_DIR}" "${DEP_CACHE_DIR}" "${GRAPH_DIR}" 2>/dev/null || true

# runtime
_SESSION_TS="$(date -u +"%Y%m%dT%H%M%SZ")-$$"
_DB_LOCK_FD=""

# -------------------------
# Logging helpers (register.sh integration if available)
# -------------------------
_dlog() {
  local lvl="$1"; shift
  local msg="$*"
  if ${REGISTER_IF_PRESENT} && type register_info >/dev/null 2>&1; then
    case "$lvl" in
      INFO) register_info "$msg"; return 0 ;;
      WARN) register_warn "$msg"; return 0 ;;
      ERROR) register_error "$msg"; return 0 ;;
      DEBUG) register_debug "$msg"; return 0 ;;
      *) register_info "$msg"; return 0 ;;
    esac
  fi
  if [[ "${DEP_SILENT}" == "true" && "$lvl" != "ERROR" ]]; then
    return 0
  fi
  case "$lvl" in
    INFO)  printf '\e[32m[DEP INFO]\e[0m %s\n' "$msg" ;;
    WARN)  printf '\e[33m[DEP WARN]\e[0m %s\n' "$msg" >&2 ;;
    ERROR) printf '\e[31m[DEP ERR]\e[0m %s\n' "$msg" >&2 ;;
    DEBUG) [[ "${DEP_DEBUG}" == "true" ]] && printf '\e[36m[DEP DBG]\e[0m %s\n' "$msg" ;;
    *) printf '[DEP] %s\n' "$msg" ;;
  esac
}

_dfail() {
  local msg="$1"; local code="${2:-1}"
  _dlog ERROR "$msg"
  _db_unlock || true
  exit "$code"
}

# -------------------------
# DB lock helpers
# -------------------------
_db_lock() {
  local lockfile="${DB_LOCK_DIR}/packages.db.lock"
  mkdir -p "${DB_LOCK_DIR}" 2>/dev/null || true
  exec {DB_FD}>"${lockfile}" || _dfail "Não foi possível abrir lock ${lockfile}"
  if flock -n "${DB_FD}"; then
    _dlog DEBUG "DB lock adquirido"
    return 0
  fi
  _dlog INFO "Aguardando lock DB..."
  local waited=0
  local timeout="${DB_LOCK_TIMEOUT:-300}"
  while ! flock -n "${DB_FD}"; do
    sleep 1
    waited=$((waited+1))
    if (( waited >= timeout )); then
      _dfail "Timeout aguardando DB lock"
    fi
  done
  _dlog DEBUG "DB lock obtido após ${waited}s"
}

_db_unlock() {
  if [[ -n "${DB_FD:-}" ]]; then
    eval "exec ${DB_FD}>&-"
    unset DB_FD
  fi
}

# -------------------------
# DB utilities
# DB row format: name|version|depends|build_deps|opt_deps
# - depends/build_deps/opt_deps are comma-separated lists (no spaces recommended)
# -------------------------
_db_ensure() {
  if [[ ! -f "${DB_PATH}" ]]; then
    mkdir -p "$(dirname "${DB_PATH}")" 2>/dev/null || true
    printf '# packages.db - auto-created %s\n' "$(_SESSION_TS)" > "${DB_PATH}"
    chmod 0640 "${DB_PATH}" 2>/dev/null || true
    _dlog INFO "DB criado em ${DB_PATH}"
  fi
}

_db_backup() {
  mkdir -p "${DB_BACKUP_DIR}" 2>/dev/null || true
  local bak="${DB_BACKUP_DIR}/packages.db.bak.${_SESSION_TS}"
  cp -a "${DB_PATH}" "${bak}" 2>/dev/null || _dlog WARN "Falha ao criar backup DB"
  # rotate retention
  local arr; IFS=$'\n' read -r -d '' -a arr < <(ls -1t "${DB_BACKUP_DIR}"/packages.db.bak.* 2>/dev/null || true; printf '\0')
  local cnt="${#arr[@]}"
  if (( cnt > DB_RETENTION )); then
    for ((i=DB_RETENTION;i<cnt;i++)); do
      rm -f "${arr[i]}" || true
      _dlog DEBUG "Removido old backup ${arr[i]}"
    done
  fi
  _dlog DEBUG "DB backup criado: ${bak}"
}

# parse a DB line into associative array (by reference)
# usage: _db_parse_line "line" assoc_name
_db_parse_line() {
  local line="$1"; local out="$2"
  IFS='|' read -r name version depends build_deps opt_deps <<< "${line}"
  declare -A tmp=()
  tmp[name]="${name:-}"
  tmp[version]="${version:-}"
  tmp[depends]="${depends:-}"
  tmp[build_deps]="${build_deps:-}"
  tmp[opt_deps]="${opt_deps:-}"
  # export to caller var name
  eval "${out}=( )"
  for k in "${!tmp[@]}"; do
    local v="${tmp[$k]}"
    v="${v//\"/\\\"}"
    eval "${out}[\"$k\"]=\"$v\""
  done
}

# get DB row line by pkg name (first match)
_db_get_line() {
  local pkg="$1"
  _db_ensure
  local line
  line="$(grep -E "^${pkg}\\|" "${DB_PATH}" 2>/dev/null || true)"
  if [[ -z "${line}" ]]; then
    return 1
  fi
  printf '%s' "${line%%$'\n'*}"
  return 0
}

# set/update DB entry atomically
# usage: _db_set pkg version depends build_deps opt_deps
_db_set() {
  local pkg="$1"; local version="$2"; local depends="$3"; local build_deps="$4"; local opt_deps="$5"
  _db_ensure
  _db_backup
  local tmp; tmp="$(mktemp "${DB_PATH}.tmp.XXXX")"
  # write header preserved
  grep -E '^#' "${DB_PATH}" 2>/dev/null || true > "${tmp}" || true
  # filter out existing entry
  grep -v -E "^${pkg}\\|" "${DB_PATH}" 2>/dev/null || true >> "${tmp}"
  # append new entry
  printf '%s|%s|%s|%s|%s\n' "${pkg}" "${version:-}" "${depends:-}" "${build_deps:-}" "${opt_deps:-}" >> "${tmp}"
  mv -f "${tmp}" "${DB_PATH}" || _dfail "Falha ao gravar DB"
  chmod 0640 "${DB_PATH}" 2>/dev/null || true
  _dlog INFO "DB atualizado: ${pkg}|${version}|${depends}|${build_deps}|${opt_deps}"
}

# remove DB entry
_db_remove() {
  local pkg="$1"
  _db_ensure
  _db_backup
  local tmp; tmp="$(mktemp "${DB_PATH}.tmp.XXXX")"
  grep -E '^#' "${DB_PATH}" 2>/dev/null || true > "${tmp}" || true
  grep -v -E "^${pkg}\\|" "${DB_PATH}" 2>/dev/null || true >> "${tmp}"
  mv -f "${tmp}" "${DB_PATH}" || _dfail "Falha ao remover do DB"
  _dlog INFO "DB remove: ${pkg}"
}

# list all installed packages (names)
_db_list_pkgs() {
  _db_ensure
  awk -F'|' '$0 !~ /^#/ && NF>=1 { print $1 }' "${DB_PATH}" 2>/dev/null || true
}

# check if pkg installed
_db_is_installed() {
  local pkg="$1"
  if _db_get_line "$pkg" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# get fields from DB entry into associative array by name
_db_get_assoc() {
  local pkg="$1"; local out="$2"
  local line
  line="$(_db_get_line "$pkg" 2>/dev/null || true)"
  if [[ -z "$line" ]]; then return 1; fi
  _db_parse_line "$line" "$out"
  return 0
}
# Part 2 continuation of depende.sh

# -------------------------
# Helpers: split/join lists (comma separated)
# -------------------------
_split_commas() {
  local s="$1"
  if [[ -z "$s" ]]; then
    echo ""
    return 0
  fi
  # replace commas with newlines, trim spaces
  printf '%s' "$s" | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' || true
}

_join_commas() {
  local arr=("$@")
  local out=""
  for e in "${arr[@]}"; do
    if [[ -z "$out" ]]; then out="${e}"; else out="${out},${e}"; fi
  done
  printf '%s' "$out"
}

# -------------------------
# Virtual mapping (optional)
# Format file (simple):
# virtual_name=real1,real2,real3
# -------------------------
_virtual_resolve() {
  local name="$1"
  if [[ -z "${DEP_VIRTUAL_MAP}" ]]; then
    return 1
  fi
  if [[ ! -f "${DEP_VIRTUAL_MAP}" ]]; then
    _dlog WARN "VIRTUAL_MAP configured but file not found: ${DEP_VIRTUAL_MAP}"
    return 1
  fi
  local line
  line="$(grep -E "^${name}=" "${DEP_VIRTUAL_MAP}" 2>/dev/null || true)"
  if [[ -z "$line" ]]; then return 1; fi
  local val="${line#*=}"
  # output comma list
  printf '%s' "$val"
  return 0
}

# -------------------------
# Resolve dependencies recursively for a package (reads metafile via meta_load)
# Returns ordered list (topological) in stdout, or non-zero on cycle/missing
# Approach:
#  - build adjacency via dfs
#  - detect cycles
#  - produce reverse postorder (dependency first)
# -------------------------
_resolve_recursive() {
  local root="$1"
  local seen_file; seen_file="$(mktemp)"
  local visiting_file; visiting_file="$(mktemp)"
  declare -A ADJ=()
  declare -A ALL_PKGS=()

  # read metafile: try to locate via meta_find if available, else expect just name if installed
  _load_meta_info() {
    local pkg="$1"
    local name version depends build_deps opt_deps
    # Try using meta_load if available
    if type meta_find >/dev/null 2>&1 && type meta_load >/dev/null 2>&1; then
      local mf
      mf="$(meta_find "$pkg" 2>/dev/null || true)"
      if [[ -n "$mf" ]]; then
        meta_load "$mf" TMP_META || true
        name="${META_NAME:-$pkg}"
        version="${META_VERSION:-}"
        depends="${META_DEPENDS:-}"
        build_deps="${META_BUILD_DEPS:-}"
        opt_deps="${META_OPT_DEPS:-}"
      else
        # fallback: if installed, read from DB
        if _db_is_installed "$pkg"; then
          declare -A row=()
          _db_get_assoc "$pkg" row || true
          name="${row[name]:-$pkg}"
          version="${row[version]:-}"
          depends="${row[depends]:-}"
          build_deps="${row[build_deps]:-}"
          opt_deps="${row[opt_deps]:-}"
        else
          name="$pkg"; version=""; depends=""; build_deps=""; opt_deps=""
        fi
      fi
    else
      # no metafile helpers: try DB
      if _db_is_installed "$pkg"; then
        declare -A row=()
        _db_get_assoc "$pkg" row || true
        name="${row[name]:-$pkg}"
        version="${row[version]:-}"
        depends="${row[depends]:-}"
        build_deps="${row[build_deps]:-}"
        opt_deps="${row[opt_deps]:-}"
      else
        name="$pkg"; version=""; depends=""; build_deps=""; opt_deps=""
      fi
    fi
    # expand virtual if needed
    if [[ -n "$depends" ]]; then
      printf '%s\n' "DEPENDS::$pkg::$depends"
    fi
    if [[ -n "$build_deps" ]]; then
      printf '%s\n' "BUILD::$pkg::$build_deps"
    fi
    if [[ -n "$opt_deps" ]]; then
      printf '%s\n' "OPT::$pkg::$opt_deps"
    fi
  }

  # dfs to build adjacency
  declare -A visited=()
  declare -A instack=()
  declare -a topo=()
  _dfs() {
    local pkg="$1"
    if [[ "${visited[$pkg]:-}" == "1" ]]; then
      return 0
    fi
    if [[ "${instack[$pkg]:-}" == "1" ]]; then
      _dlog ERROR "Ciclo detectado envolvendo ${pkg}"
      return 2
    fi
    instack[$pkg]=1
    # load pkg deps
    local depline
    # Try to get metafile; if not exists and DEP_FAIL_ON_MISSING true => abort
    local mf
    mf="$(type meta_find >/dev/null 2>&1 && meta_find "$pkg" 2>/dev/null || true)"
    if [[ -z "$mf" && "${DEP_FAIL_ON_MISSING}" == "true" && ! _db_is_installed "$pkg" ]]; then
      _dlog ERROR "Metafile não encontrado para ${pkg} e DEP_FAIL_ON_MISSING=true"
      return 3
    fi
    # obtain lists
    local depends_list=""
    local build_list=""
    if [[ -n "$mf" ]]; then
      meta_load "$mf" TMP_META || true
      depends_list="${META_DEPENDS:-}"
      build_list="${META_BUILD_DEPS:-}"
      # note: opt_deps are not automatically recursed unless flagged
    else
      # try DB
      if _db_is_installed "$pkg"; then
        declare -A row=(); _db_get_assoc "$pkg" row || true
        depends_list="${row[depends]:-}"
        build_list="${row[build_deps]:-}"
      fi
    fi

    # expand comma lists and virtuals
    local dep_item
    local rawdeps dep_resolved
    rawdeps="$(printf '%s\n' "${depends_list}" | sed 's/,/ /g')"
    for dep_item in ${rawdeps}; do
      dep_item="$(echo -n "$dep_item" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
      [[ -z "$dep_item" ]] && continue
      # if virtual map contains entry, expand
      if _virtual_resolve "$dep_item" >/dev/null 2>&1; then
        dep_resolved="$(_virtual_resolve "$dep_item")"
        # expand those
        for dd in $(echo "$dep_resolved" | tr ',' ' '); do
          _dfs "$dd" || return $?
        done
      else
        _dfs "$dep_item" || return $?
      fi
    done

    # also include build_deps as they may be needed before compile
    rawdeps="$(printf '%s\n' "${build_list}" | sed 's/,/ /g')"
    for dep_item in ${rawdeps}; do
      dep_item="$(echo -n "$dep_item" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
      [[ -z "$dep_item" ]] && continue
      if _virtual_resolve "$dep_item" >/dev/null 2>&1; then
        dep_resolved="$(_virtual_resolve "$dep_item")"
        for dd in $(echo "$dep_resolved" | tr ',' ' '); do
          _dfs "$dd" || return $?
        done
      else
        _dfs "$dep_item" || return $?
      fi
    done

    visited[$pkg]=1
    instack[$pkg]=0
    topo+=("$pkg")
    return 0
  }

  # start dfs at root
  instack=()
  visited=()
  topo=()
  _dfs "$root" || return $?

  # topo array now contains reverse-postorder (dependency-first?), reverse it to get install order: dependencies first
  # currently topo has order: children before parent (we appended after recursion), so it's correct: first elements are deepest deps.
  # print unique in order
  declare -A seen=()
  for p in "${topo[@]}"; do
    if [[ -z "${seen[$p]:-}" ]]; then
      printf '%s\n' "$p"
      seen[$p]=1
    fi
  done

  rm -f "$seen_file" "$visiting_file" 2>/dev/null || true
  return 0
}

# -------------------------
# Top-level resolve wrapper: expands opt_deps only if flag set
# returns newline separated ordered list
# -------------------------
resolve_deps() {
  local pkg="$1"; shift
  local include_opt="${1:-false}"
  _dlog DEBUG "resolve_deps: resolving ${pkg} include_opt=${include_opt}"
  _resolve_recursive "$pkg" || return $?
  # if include_opt true, we should add opt_deps from metafile at end (not required)
  if [[ "${include_opt}" == "true" ]]; then
    # load opt_deps and append if not present
    if type meta_find >/dev/null 2>&1 && type meta_load >/dev/null 2>&1; then
      local mf
      mf="$(meta_find "$pkg" 2>/dev/null || true)"
      if [[ -n "$mf" ]]; then
        meta_load "$mf" TMP_META || true
        local opt="${META_OPT_DEPS:-}"
        for o in $(_split_commas "$opt"); do
          # print if not already in list (simple approach: append)
          printf '%s\n' "$o"
        done
      fi
    fi
  fi
}

# -------------------------
# Check dependencies installed: returns 0 if all installed, else non-zero and prints missing list
# -------------------------
dep_check_installed() {
  local pkg="$1"
  local include_opt="${2:-false}"
  local missing=()
  local dep
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    if ! _db_is_installed "$dep"; then
      missing+=("$dep")
    fi
  done < <(resolve_deps "$pkg" "${include_opt}" || true)

  if (( ${#missing[@]} == 0 )); then
    _dlog INFO "dep_check_installed: todas as dependências satisfeitas para ${pkg}"
    return 0
  else
    _dlog WARN "dep_check_installed: dependências faltantes para ${pkg}: ${missing[*]}"
    printf '%s\n' "${missing[@]}"
    return 2
  fi
}

# -------------------------
# Install missing dependencies by building them (calls build.sh)
# Behavior:
#  - resolves ordered list
#  - for each dep not installed, call build.sh --metafile <metafile> (or build.sh <pkg>)
#  - stop on first failure and report
# -------------------------
dep_install_missing() {
  local pkg="$1"
  local include_opt="${2:-false}"
  local deps_to_install=()
  local dep

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    if ! _db_is_installed "$dep"; then
      deps_to_install+=("$dep")
    fi
  done < <(resolve_deps "$pkg" "${include_opt}" || true)

  if (( ${#deps_to_install[@]} == 0 )); then
    _dlog INFO "dep_install_missing: nada a instalar para ${pkg}"
    return 0
  fi

  _dlog INFO "dep_install_missing: instalar na ordem: ${deps_to_install[*]}"

  for d in "${deps_to_install[@]}"; do
    _dlog INFO "Construindo dependência: ${d}"
    # Find metafile for d
    local mf
    if type meta_find >/dev/null 2>&1; then
      mf="$(meta_find "$d" 2>/dev/null || true)"
    fi
    if [[ -z "${mf}" ]]; then
      _dlog WARN "metafile não encontrado para ${d}; tentando construir via build.sh com nome"
      if [[ -x "${BUILD_CMD}" ]]; then
        if "${BUILD_CMD}" --name "${d}" >> "${DEP_CACHE_DIR}/${d}.build.log" 2>&1; then
          _dlog INFO "build.sh succeeded for ${d}"
          # After successful build, try to register in DB if build.sh created meta or outputs
          # Attempt to detect version by reading metafile if created
          local version=""
          if [[ -n "${mf}" ]]; then
            meta_load "$mf" TMP_META || true
            version="${META_VERSION:-}"
          fi
          _db_set "${d}" "${version}" "" "" "" || true
        else
          _dlog ERROR "Falha ao construir ${d}; ver log ${DEP_CACHE_DIR}/${d}.build.log"
          return 3
        fi
      else
        _dlog ERROR "BUILD_CMD não encontrado (${BUILD_CMD}); não é possível construir ${d}"
        return 4
      fi
    else
      # call build.sh with --metafile <mf>
      if [[ -x "${BUILD_CMD}" ]]; then
        _dlog DEBUG "Invocando build.sh --metafile ${mf} para ${d}"
        if "${BUILD_CMD}" --metafile "${mf}" >> "${DEP_CACHE_DIR}/${d}.build.log" 2>&1; then
          _dlog INFO "Build concluído para ${d}"
          # try to load version from metafile and register in DB
          meta_load "$mf" TMP_META || true
          local ver="${META_VERSION:-}"
          local deps="${META_DEPENDS:-}"
          local bdeps="${META_BUILD_DEPS:-}"
          local opdeps="${META_OPT_DEPS:-}"
          _db_set "${d}" "${ver}" "${deps}" "${bdeps}" "${opdeps}"
        else
          _dlog ERROR "Build falhou para ${d}; ver ${DEP_CACHE_DIR}/${d}.build.log"
          return 5
        fi
      else
        _dlog ERROR "BUILD_CMD não executável: ${BUILD_CMD}"
        return 6
      fi
    fi
  done

  _dlog INFO "dep_install_missing: dependências instaladas para ${pkg}"
  return 0
}

# -------------------------
# List orphan packages (installed but not required by any other installed package)
# -------------------------
dep_list_orphans() {
  _db_ensure
  local all; IFS=$'\n' read -r -d '' -a all < <(_db_list_pkgs && printf '\0')
  declare -A required=()
  # iterate DB lines and collect depends/build_deps
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    IFS='|' read -r name version depends build_deps opt_deps <<< "$line"
    for dep in $(_split_commas "${depends:-}"); do required["$dep"]=1; done
    for dep in $(_split_commas "${build_deps:-}"); do required["$dep"]=1; done
    for dep in $(_split_commas "${opt_deps:-}"); do required["$dep"]=1; done
  done < "${DB_PATH}"

  local orphans=()
  for p in "${all[@]}"; do
    [[ -z "$p" ]] && continue
    if [[ -z "${required[$p]:-}" ]]; then
      orphans+=("$p")
    fi
  done

  if (( ${#orphans[@]} == 0 )); then
    _dlog INFO "dep_list_orphans: nenhum órfão"
    return 0
  else
    printf '%s\n' "${orphans[@]}"
    return 0
  fi
}

# -------------------------
# Rebuild all packages in dependency order (topological)
# Strategy:
#  - build order: resolve for each installed package and collect union, then sort unique preserving dependency order
#  - invoke build.sh for each package (skip if build.sh opts say skip)
# -------------------------
dep_rebuild_all() {
  _dlog INFO "dep_rebuild_all: iniciando rebuild-all"
  # collect order by resolving each installed package
  declare -A order_index=()
  declare -a final_order=()
  local idx=0
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    while IFS= read -r d; do
      if [[ -z "${order_index[$d]:-}" ]]; then
        order_index[$d]=$((idx++))
        final_order+=("$d")
      fi
    done < <(resolve_deps "$pkg" "false" || true)
  done < <(_db_list_pkgs)

  _dlog INFO "dep_rebuild_all: ordem calculada: ${final_order[*]}"

  for p in "${final_order[@]}"; do
    _dlog INFO "Reconstruindo ${p}"
    # find metafile if exists
    local mf=""
    if type meta_find >/dev/null 2>&1; then
      mf="$(meta_find "$p" 2>/dev/null || true)"
    fi
    if [[ -n "${mf}" && -x "${BUILD_CMD}" ]]; then
      if ! "${BUILD_CMD}" --metafile "${mf}" >> "${DEP_CACHE_DIR}/${p}.rebuild.log" 2>&1; then
        _dlog ERROR "Falha reconstruir ${p}; ver ${DEP_CACHE_DIR}/${p}.rebuild.log"
        return 2
      fi
      _dlog INFO "Reconstrução concluída: ${p}"
    else
      _dlog WARN "pular ${p}: metafile/build.sh não disponível"
    fi
  done

  _dlog INFO "dep_rebuild_all: finalizado"
  return 0
}

# -------------------------
# Export dependency graph for a package (DOT or JSON)
# -------------------------
dep_graph_export() {
  local pkg="$1"; local fmt="${2:-dot}"; local out="${3:-${GRAPH_DIR}/${pkg}-graph.${fmt}}"
  mkdir -p "${GRAPH_DIR}" 2>/dev/null || true
  declare -A edges=()
  # produce edges by reading each package's depends from metafile or DB
  _add_edges_for() {
    local p="$1"
    local mf
    mf="$(type meta_find >/dev/null 2>&1 && meta_find "$p" 2>/dev/null || true)"
    local deps=""
    if [[ -n "$mf" ]]; then
      meta_load "$mf" TMP_META || true
      deps="${META_DEPENDS:-}"
    else
      if _db_is_installed "$p"; then
        declare -A row=(); _db_get_assoc "$p" row || true
        deps="${row[depends]:-}"
      fi
    fi
    for d in $(_split_commas "${deps:-}"); do
      [[ -z "$d" ]] && continue
      edges["$p->$d"]=1
      # recursively add for dependency if not processed
      if [[ -z "${edges[$d->*]:-}" ]]; then
        true
      fi
    done
  }

  # seed: build edges for resolved deps for pkg
  while IFS= read -r p; do
    _add_edges_for "$p"
  done < <(resolve_deps "$pkg" "false" || true)

  if [[ "$fmt" == "dot" ]]; then
    {
      echo "digraph deps {"
      echo "  node [shape=box];"
      for e in "${!edges[@]}"; do
        local a="${e%%->*}"; local b="${e##*->}"
        printf '  "%s" -> "%s";\n' "$a" "$b"
      done
      echo "}"
    } > "${out}"
    _dlog INFO "dep_graph_export: DOT gerado em ${out}"
    return 0
  elif [[ "$fmt" == "json" ]]; then
    # simple json adjacency list
    declare -A adj=()
    for e in "${!edges[@]}"; do
      local a="${e%%->*}"; local b="${e##*->}"
      adj["$a"]="${adj[$a]:+,}${b}"
    done
    {
      echo "{"
      local first=1
      for k in "${!adj[@]}"; do
        local vals
        vals="$(printf '%s' "${adj[$k]}" | sed 's/^,//')"
        if [[ $first -eq 0 ]]; then echo ","; fi
        first=0
        printf '  "%s": ["%s"]' "$k" "$(echo "$vals" | sed 's/,/","/g')"
      done
      echo ""
      echo "}"
    } > "${out}"
    _dlog INFO "dep_graph_export: JSON gerado em ${out}"
    return 0
  else
    _dlog ERROR "Formato desconhecido: ${fmt}"
    return 2
  fi
}

# -------------------------
# CLI dispatcher
# -------------------------
_print_help_dep() {
  cat <<EOF
depende.sh - gerenciador de dependências

Usage:
  depende.sh --resolve <pkg> [--include-opt]     : mostra ordem de construção (dependees first)
  depende.sh --check <pkg> [--include-opt]       : checa se dependências instaladas (prints missing)
  depende.sh --install <pkg> [--include-opt]     : resolve e auto-build dependências ausentes, registra no DB
  depende.sh --orphans                           : lista pacotes órfãos
  depende.sh --remove <pkg>                      : remove do DB (não remove arquivos binários)
  depende.sh --rebuild-all                       : reconstrói todo o sistema (resolves order)
  depende.sh --graph <pkg> [dot|json] [outfile]  : exporta grafo de dependências
  depende.sh --list                              : lista pacotes no DB
  depende.sh --help
ENV:
  DEP_DEBUG=true    - ativa logs debug
  DEP_SILENT=true   - suprime INFO/WARN
EOF
}

# main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if (( $# == 0 )); then _print_help_dep; exit 0; fi
  cmd="$1"; shift

  case "$cmd" in
    --resolve)
      pkg="$1"; shift || _dfail "--resolve requires <pkg>"
      include_opt="false"
      if [[ "${1:-}" == "--include-opt" ]]; then include_opt="true"; fi
      resolve_deps "$pkg" "${include_opt}"
      exit $?
      ;;

    --check)
      pkg="$1"; shift || _dfail "--check requires <pkg>"
      include_opt="false"
      if [[ "${1:-}" == "--include-opt" ]]; then include_opt="true"; fi
      dep_check_installed "$pkg" "${include_opt}"
      exit $?
      ;;

    --install)
      pkg="$1"; shift || _dfail "--install requires <pkg>"
      include_opt="false"
      if [[ "${1:-}" == "--include-opt" ]]; then include_opt="true"; fi
      _db_lock
      _db_ensure
      dep_install_missing "$pkg" "${include_opt}" || { _db_unlock; _dfail "Falha instalar dependências"; }
      # Finally, register main package if metafile exists
      if type meta_find >/dev/null 2>&1 && type meta_load >/dev/null 2>&1; then
        mf="$(meta_find "$pkg" 2>/dev/null || true)"
        if [[ -n "$mf" ]]; then
          meta_load "$mf" TMP_META || true
          _db_set "$pkg" "${META_VERSION:-}" "${META_DEPENDS:-}" "${META_BUILD_DEPS:-}" "${META_OPT_DEPS:-}"
        else
          _dlog WARN "metafile não encontrado para ${pkg}; registro no DB não efetuado"
        fi
      fi
      _db_unlock
      exit $?
      ;;

    --orphans)
      dep_list_orphans
      exit $?
      ;;

    --remove)
      pkg="$1"; shift || _dfail "--remove requires <pkg>"
      _db_lock
      _db_remove "$pkg"
      _db_unlock
      exit 0
      ;;

    --rebuild-all)
      _db_lock
      dep_rebuild_all || { _db_unlock; _dfail "rebuild-all falhou"; }
      _db_unlock
      exit 0
      ;;

    --graph)
      pkg="$1"; fmt="${2:-dot}"; out="${3:-}"
      out="${out:-${GRAPH_DIR}/${pkg}-graph.${fmt}}"
      dep_graph_export "$pkg" "$fmt" "$out"
      exit $?
      ;;

    --list)
      _db_list_pkgs
      exit 0
      ;;

    --help|-h)
      _print_help_dep
      exit 0
      ;;

    *)
      _print_help_dep
      exit 2
      ;;
  esac
fi

# export functions for other scripts (build.sh, update.sh, uninstall.sh)
export -f resolve_deps dep_check_installed dep_install_missing dep_list_orphans dep_rebuild_all dep_graph_export _db_is_installed _db_set _db_get_line
