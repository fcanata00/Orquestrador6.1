#!/usr/bin/env bash
# depende.sh - Gerenciador de dependências para orquestrador LFS/BLFS
# - resolve dependências, topological sort, detecta ciclos
# - integra com build.sh, install.sh, uninstall.sh, update.sh, metafile.sh
# - DB simples em /var/lib/orquestrador/depends.db e installed.db
# - locking, backups, logs, tratamento de erros
#
# Versão: 2025-10-23
set -eEuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="depende"
SCRIPT_VERSION="1.0.0"

# ----------------------------
# Configuráveis via ENV
# ----------------------------
: "${DEP_BASE:=/var/lib/orquestrador}"
: "${DEP_DB:=${DEP_BASE}/depends.db}"            # formato: pkg:dep1 dep2 ...
: "${DEP_INSTALLED:=${DEP_BASE}/installed.db}"   # formato: pkg=version
: "${DEP_LOCK:=${DEP_BASE}/lock/depende.lock}"
: "${DEP_BACKUP_DIR:=${DEP_BASE}/backup}"
: "${DEP_LOG_DIR:=${DEP_BASE}/logs}"
: "${DEP_SILENT:=false}"
: "${DEP_DEBUG:=false}"
: "${DEP_FLOCK_TIMEOUT:=600}"   # 10 minutes for global lock
: "${DEP_AUTO_INSTALL_CMD:=install.sh}"   # command used by dep_auto_install
: "${DEP_AUTO_BUILD_CMD:=build.sh}"       # command used by dep_auto_build
: "${DEP_MAX_RECURSION:=1000}"

# Internal
declare -A _DEP_GRAPH        # adjacency list: pkg -> "dep1 dep2 ..."
declare -A _DEP_REVGRAPH    # reverse edges: pkg -> "pkg_that_depends_on_me ..."
declare -A _INSTALLED_VER   # installed pkg -> version
_DEP_LOADED=false

# ----------------------------
# Logging helpers
# ----------------------------
_dep_log() {
  local level="$1"; shift
  local msg="$*"
  if type register_info >/dev/null 2>&1; then
    case "$level" in
      INFO) register_info "$msg" ;;
      WARN) register_warn "$msg" ;;
      ERROR) register_error "$msg" ;;
      DEBUG) register_debug "$msg" ;;
      *) register_info "$msg" ;;
    esac
    return 0
  fi
  if [[ "${DEP_SILENT}" == "true" && "$level" != "ERROR" ]]; then
    return 0
  fi
  case "$level" in
    INFO)  printf '\e[32m[INFO]\e[0m %s\n' "$msg" ;;
    WARN)  printf '\e[33m[WARN]\e[0m %s\n' "$msg" >&2 ;;
    ERROR) printf '\e[31m[ERROR]\e[0m %s\n' "$msg" >&2 ;;
    DEBUG) [[ "${DEP_DEBUG}" == "true" ]] && printf '\e[36m[DEBUG]\e[0m %s\n' "$msg" ;;
    *) printf '[LOG] %s\n' "$msg" ;;
  esac
}

fail() {
  _dep_log ERROR "$*"
  exit 1
}

# ----------------------------
# File/dir initialization
# ----------------------------
_dep_init_dirs() {
  mkdir -p "${DEP_BASE}" "${DEP_BACKUP_DIR}" "${DEP_LOG_DIR}" "$(dirname "${DEP_LOCK}")"
  chmod 750 "${DEP_BASE}" || true
  touch "${DEP_DB}" "${DEP_INSTALLED}" 2>/dev/null || true
  chmod 640 "${DEP_DB}" "${DEP_INSTALLED}" 2>/dev/null || true
}

# ----------------------------
# Lock helpers (global)
# ----------------------------
_dep_lock_acquire() {
  _dep_init_dirs
  exec {DEP_FD}>"${DEP_LOCK}" || { _dep_log WARN "Não pode abrir lockfile ${DEP_LOCK}"; return 2; }
  # try non-blocking first, then blocking with timeout
  if flock -n "${DEP_FD}"; then
    _dep_log DEBUG "Lock adquirido imediatamente"
    return 0
  fi
  _dep_log INFO "Aguardando lock depende (timeout ${DEP_FLOCK_TIMEOUT}s)..."
  # block with timeout implemented via sleep loop
  local waited=0
  while ! flock -n "${DEP_FD}"; do
    sleep 1
    waited=$((waited+1))
    if (( waited >= DEP_FLOCK_TIMEOUT )); then
      _dep_log ERROR "Timeout ao aguardar lock (${DEP_FLOCK_TIMEOUT}s)"
      return 3
    fi
  done
  _dep_log DEBUG "Lock adquirido após espera ${waited}s"
  return 0
}

_dep_lock_release() {
  if [[ -n "${DEP_FD:-}" ]]; then
    eval "exec ${DEP_FD}>&-"
    unset DEP_FD
  fi
}

# ----------------------------
# Backup DB (transactional safety)
# ----------------------------
_dep_backup_db() {
  _dep_init_dirs
  local ts; ts=$(date -u +"%Y%m%dT%H%M%SZ")
  cp -a "${DEP_DB}" "${DEP_BACKUP_DIR}/depends.db.${ts}" 2>/dev/null || true
  cp -a "${DEP_INSTALLED}" "${DEP_BACKUP_DIR}/installed.db.${ts}" 2>/dev/null || true
  _dep_log DEBUG "Backup do DB criado em ${DEP_BACKUP_DIR} (ts=${ts})"
}

# ----------------------------
# Load DB into memory (associative arrays)
# ----------------------------
dep_load() {
  if [[ "${_DEP_LOADED}" == "true" ]]; then
    _dep_log DEBUG "dep_load: já carregado"
    return 0
  fi
  _dep_init_dirs
  # initialize arrays
  _DEP_GRAPH=()
  _DEP_REVGRAPH=()
  _INSTALLED_VER=()

  # load depends.db
  if [[ -f "${DEP_DB}" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line=${line%%#*}   # strip comments
      [[ -z "${line// /}" ]] && continue
      # format: pkg:dep1 dep2 ...
      if [[ "$line" =~ ^([^:]+):[[:space:]]*(.*)$ ]]; then
        local pkg="${BASH_REMATCH[1]}"
        local deps="${BASH_REMATCH[2]}"
        # normalize whitespace
        deps=$(echo "${deps}" | xargs)
        _DEP_GRAPH["$pkg"]="$deps"
        # populate reverse graph
        for d in $deps; do
          local cur="${_DEP_REVGRAPH[$d]:-}"
          if [[ -z "$cur" ]]; then
            _DEP_REVGRAPH[$d]="$pkg"
          else
            _DEP_REVGRAPH[$d]="${cur} ${pkg}"
          fi
        done
      fi
    done < "${DEP_DB}"
  fi

  # load installed.db
  if [[ -f "${DEP_INSTALLED}" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line=${line%%#*}
      [[ -z "${line// /}" ]] && continue
      if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
        local pkg="${BASH_REMATCH[1]}"
        local ver="${BASH_REMATCH[2]}"
        _INSTALLED_VER["$pkg"]="$ver"
      fi
    done < "${DEP_INSTALLED}"
  fi

  _DEP_LOADED=true
  _dep_log INFO "dep_load: banco carregado (pkgs=${#_DEP_GRAPH[@]})"
}

# ----------------------------
# Persist DB back to disk (atomic)
# ----------------------------
dep_save() {
  _dep_lock_acquire || fail "Não foi possível adquirir lock para salvar DB"
  _dep_backup_db
  local tmpdb; tmpdb=$(mktemp "${DEP_BASE}/depends.db.tmp.XXXX") || { _dep_lock_release; fail "mktemp failed"; }
  local tmpinst; tmpinst=$(mktemp "${DEP_BASE}/installed.db.tmp.XXXX") || { rm -f "$tmpdb"; _dep_lock_release; fail "mktemp failed"; }
  # write depends
  for pkg in "${!_DEP_GRAPH[@]}"; do
    echo "${pkg}: ${_DEP_GRAPH[$pkg]}" >> "$tmpdb"
  done
  chmod 640 "$tmpdb" || true
  mv -f "$tmpdb" "${DEP_DB}"
  # write installed
  for pkg in "${!_INSTALLED_VER[@]}"; do
    echo "${pkg}=${_INSTALLED_VER[$pkg]}" >> "$tmpinst"
  done
  chmod 640 "$tmpinst" || true
  mv -f "$tmpinst" "${DEP_INSTALLED}"
  _dep_log INFO "dep_save: DB persistido"
  _dep_lock_release
}

# ----------------------------
# Helpers: read deps from metafile if present
# ----------------------------
# Expects argument: path to metafile.ini
# Returns: prints space-separated dependencies
dep_read_from_metafile() {
  local mf="$1"
  [[ -f "$mf" ]] || { _dep_log DEBUG "metafile não encontrado: $mf"; return 0; }
  # crude but effective parser for key 'depends' or 'depends_on' or 'requires'
  local deps=""
  while IFS='=' read -r k v || [[ -n "$k" ]]; do
    k=${k// /}
    case "${k}" in
      depends|dependencies|requires)
        deps="$v"
        break
        ;;
      *) ;;
    esac
  done < "$mf"
  deps=$(echo "$deps" | xargs)
  printf '%s' "$deps"
}

# ----------------------------
# Manipular banco em memória
# ----------------------------
dep_add() {
  # dep_add <pkg> "<dep1 dep2 ...>"
  local pkg="$1"; shift
  local deps="$*"
  dep_load
  deps=$(echo "$deps" | xargs)
  _DEP_GRAPH["$pkg"]="$deps"
  # rebuild reverse graph entries for provided deps
  for d in $deps; do
    local cur="${_DEP_REVGRAPH[$d]:-}"
    if [[ -z "$cur" ]]; then
      _DEP_REVGRAPH[$d]="$pkg"
    else
      # avoid duplicates
      case " $cur " in
        *" $pkg "*) : ;;
        *) _DEP_REVGRAPH[$d]="${cur} ${pkg}" ;;
      esac
    fi
  done
  _dep_log INFO "dep_add: $pkg -> $deps"
  dep_save
}

dep_remove() {
  # dep_remove <pkg>
  local pkg="$1"
  dep_load
  if [[ -z "${_DEP_GRAPH[$pkg]:-}" && -z "${_INSTALLED_VER[$pkg]:-}" ]]; then
    _dep_log WARN "dep_remove: pacote desconhecido: $pkg"
  fi
  unset _DEP_GRAPH["$pkg"]
  unset _INSTALLED_VER["$pkg"]
  # rebuild reverse graph fresh
  _DEP_REVGRAPH=()
  for p in "${!_DEP_GRAPH[@]}"; do
    for d in ${_DEP_GRAPH[$p]}; do
      local c="${_DEP_REVGRAPH[$d]:-}"
      _DEP_REVGRAPH[$d]="${c} ${p}"
    done
  done
  _dep_log INFO "dep_remove: $pkg removido do DB"
  dep_save
}

# ----------------------------
# Query helpers
# ----------------------------
dep_check_installed() {
  local pkg="$1"
  dep_load
  if [[ -n "${_INSTALLED_VER[$pkg]:-}" ]]; then
    printf '%s' "${_INSTALLED_VER[$pkg]}"
    return 0
  fi
  return 1
}

dep_list_direct() {
  local pkg="$1"
  dep_load
  echo "${_DEP_GRAPH[$pkg]:-}" | xargs
}

dep_list_reverse() {
  local pkg="$1"
  dep_load
  echo "${_DEP_REVGRAPH[$pkg]:-}" | xargs
}

# ----------------------------
# Topological sort (DFS)
# ----------------------------
# returns ordered list (space-separated) of packages to build/install so that deps come first
# dep_resolve <pkg> [--include-root]
dep_resolve() {
  local root="$1"
  local include_root="${2:-true}"

  dep_load

  # We'll build a DAG by reading from memory; if a package not in DB, attempt to read metafile
  # Search strategy for metafile:
  #  - /usr/src/<category>/<pkg>/<pkg>.ini
  #  - /mnt/lfs/usr/src/<category>/<pkg>/<pkg>.ini
  # If not found, assume no declared deps.

  local -A visited=()
  local -A onstack=()
  local -a order=()
  local cycle_detected=0

  # helper function DFS
  _dfs() {
    local node="$1"
    # recursion guard
    if (( ${#visited[@]} > DEP_MAX_RECURSION )); then
      fail "dep_resolve: recursion limit exceeded"
    fi
    if [[ "${visited[$node]:-}" == "1" ]]; then
      return 0
    fi
    if [[ "${onstack[$node]:-}" == "1" ]]; then
      _dep_log ERROR "Ciclo detectado envolvendo: $node"
      cycle_detected=1
      return 1
    fi
    onstack[$node]=1

    # get direct deps: try DB, else attempt to read metafile path(s)
    local deps="${_DEP_GRAPH[$node]:-}"
    if [[ -z "$deps" ]]; then
      # try to find metafile by guessing category from installed DB or file system
      # This is heuristic; if not found, treat as leaf
      # Try /usr/src/*/<node>/*.ini and /mnt/lfs/usr/src/*/<node>/*.ini
      for base in "${SRC_DIR:-/usr/src}" "${LFS_SRC_DIR:-/mnt/lfs/usr/src}"; do
        if [[ -d "$base" ]]; then
          local mf
          mf=$(find "$base" -type f -name "${node}.ini" -print -quit 2>/dev/null || true)
          if [[ -n "$mf" ]]; then
            deps=$(dep_read_from_metafile "$mf")
            _dep_log DEBUG "dep_resolve: lido deps de metafile $mf => $deps"
            break
          fi
        fi
      done
    fi

    for d in $deps; do
      if [[ -z "$d" ]]; then continue; fi
      _dfs "$d" || return 1
    done

    visited[$node]=1
    onstack[$node]=0
    order+=("$node")
    return 0
  }

  # start DFS
  _dfs "$root" || {
    if (( cycle_detected == 1 )); then
      fail "dep_resolve: ciclo detectado; abortando resolução para $root"
    else
      fail "dep_resolve: falha ao resolver $root"
    fi
  }

  # order now has root last; reverse to get deps first
  local seq=""
  for ((i=${#order[@]}-1; i>=0; i--)); do
    if [[ "$include_root" == "true" ]]; then
      seq="${seq} ${order[i]}"
    else
      if [[ "${order[i]}" != "$root" ]]; then
        seq="${seq} ${order[i]}"
      fi
    fi
  done
  echo "${seq}" | xargs
}

# ----------------------------
# Topological sort for multiple roots (returns unique ordered list)
# dep_resolve_many pkg1 pkg2 ...
dep_resolve_many() {
  local roots=("$@")
  local combined=""
  for r in "${roots[@]}"; do
    local part
    part=$(dep_resolve "$r" "true") || fail "dep_resolve_many: erro resolvendo $r"
    combined="${combined} ${part}"
  done
  # uniq while preserving order
  local -a seen=()
  local -A mark=()
  for p in $combined; do
    if [[ -z "${mark[$p]:-}" ]]; then
      seen+=("$p")
      mark[$p]=1
    fi
  done
  echo "${seen[@]}"
}

# ----------------------------
# Orphans detection (installed packages without reverse deps)
# ----------------------------
dep_orphans() {
  dep_load
  local orphans=()
  for pkg in "${!_INSTALLED_VER[@]}"; do
    local rev; rev=$(dep_list_reverse "$pkg" || true)
    # rev may list packages not installed; filter by installed
    local has_installed_rev=false
    for r in $rev; do
      if [[ -n "${_INSTALLED_VER[$r]:-}" ]]; then has_installed_rev=true; break; fi
    done
    if [[ "$has_installed_rev" == "false" ]]; then
      orphans+=("$pkg")
    fi
  done
  echo "${orphans[@]}" | xargs
}

# ----------------------------
# Remove orphans safely (calls uninstall.sh or remove entry)
# dep_clean_orphans [--auto|--dry-run]
dep_clean_orphans() {
  local mode="${1:-dry-run}"
  dep_load
  local orphans; orphans=$(dep_orphans)
  if [[ -z "$orphans" ]]; then
    _dep_log INFO "dep_clean_orphans: nenhum órfão encontrado"
    return 0
  fi
  _dep_log INFO "dep_clean_orphans: órfãos detectados: $orphans"
  for p in $orphans; do
    if [[ "$mode" == "dry-run" ]]; then
      echo "$p"
    else
      # try to call uninstall.sh if available
      if type uninstall >/dev/null 2>&1 || command -v uninstall.sh >/dev/null 2>&1; then
        _dep_log INFO "Removendo $p via uninstall.sh"
        if type uninstall >/dev/null 2>&1; then
          uninstall "$p" || _dep_log WARN "uninstall $p retornou erro"
        else
          uninstall.sh --name "$p" || _dep_log WARN "uninstall.sh --name $p retornou erro"
        fi
      else
        _dep_log INFO "Removendo entradas DB para $p (uninstall tool ausente)"
        dep_remove "$p"
      fi
    fi
  done
}

# ----------------------------
# Auto-install dependencies via install.sh
# dep_auto_install <pkg>
# returns non-zero on error
dep_auto_install() {
  local pkg="$1"
  dep_load
  local seq
  seq=$(dep_resolve "$pkg" "true" ) || fail "dep_auto_install: não pôde resolver $pkg"
  _dep_log INFO "dep_auto_install: ordem resolvida: $seq"
  for p in $seq; do
    # skip if already installed
    if dep_check_installed "$p" >/dev/null 2>&1; then
      _dep_log DEBUG "dep_auto_install: $p já instalado; pulando"
      continue
    fi
    _dep_log INFO "dep_auto_install: instalando $p"
    # try to call install.sh --build or metafile approach
    if type install >/dev/null 2>&1; then
      install "$p" || { _dep_log ERROR "install $p falhou"; return 1; }
    elif command -v "${DEP_AUTO_INSTALL_CMD}" >/dev/null 2>&1; then
      ${DEP_AUTO_INSTALL_CMD} --name "$p" || { _dep_log ERROR "${DEP_AUTO_INSTALL_CMD} falhou para $p"; return 1; }
    elif type mf_load >/dev/null 2>&1; then
      # if metafile present try to find metafile and call mf_build
      # heuristics: search /usr/src/*/<p>/<p>.ini
      local mf
      mf=$(find /usr/src -type f -name "${p}.ini" -print -quit 2>/dev/null || true)
      if [[ -n "$mf" ]]; then
        mf_load "$mf"
        mf_fetch_sources || { _dep_log ERROR "fetch failed for $p"; return 1; }
        mf_apply_patches || true
        mf_construction || { _dep_log ERROR "build failed for $p"; return 1; }
      else
        _dep_log ERROR "dep_auto_install: não encontrou forma de instalar $p"
        return 1
      fi
    else
      _dep_log ERROR "dep_auto_install: Nenhuma ferramenta de instalação disponível for $p"
      return 1
    fi
    # on success, mark installed with unknown version if not set (update installed db)
    if [[ -z "${_INSTALLED_VER[$p]:-}" ]]; then
      _INSTALLED_VER[$p]="<unknown>"
      dep_save || true
    fi
  done
  return 0
}

# ----------------------------
# Auto-build dependencies via build.sh (similar to auto_install)
# dep_auto_build <pkg>
dep_auto_build() {
  local pkg="$1"
  dep_load
  local seq
  seq=$(dep_resolve "$pkg" "true") || fail "dep_auto_build: não pôde resolver $pkg"
  _dep_log INFO "dep_auto_build: ordem: $seq"
  for p in $seq; do
    # if installed skip
    if dep_check_installed "$p" >/dev/null 2>&1; then
      _dep_log DEBUG "dep_auto_build: $p já instalado; pulando build"
      continue
    fi
    _dep_log INFO "dep_auto_build: construindo $p"
    if type build >/dev/null 2>&1; then
      build "$p" || { _dep_log ERROR "build $p falhou"; return 1; }
    elif command -v "${DEP_AUTO_BUILD_CMD}" >/dev/null 2>&1; then
      ${DEP_AUTO_BUILD_CMD} --name "$p" || { _dep_log ERROR "${DEP_AUTO_BUILD_CMD} falhou para $p"; return 1; }
    elif type mf_load >/dev/null 2>&1; then
      local mf
      mf=$(find /usr/src -type f -name "${p}.ini" -print -quit 2>/dev/null || true)
      if [[ -n "$mf" ]]; then
        mf_load "$mf"
        mf_fetch_sources || { _dep_log ERROR "fetch failed for $p"; return 1; }
        mf_apply_patches || true
        mf_construction || { _dep_log ERROR "build failed for $p"; return 1; }
      else
        _dep_log ERROR "dep_auto_build: não encontrou forma de buildar $p"
        return 1
      fi
    else
      _dep_log ERROR "dep_auto_build: Nenhuma ferramenta de build disponível para $p"
      return 1
    fi
    # mark installed
    if [[ -z "${_INSTALLED_VER[$p]:-}" ]]; then
      _INSTALLED_VER[$p]="<unknown>"
      dep_save || true
    fi
  done
  return 0
}

# ----------------------------
# Reverse-dependency check (who depends on pkg)
# dep_reverse <pkg>
dep_reverse() {
  local pkg="$1"
  dep_load
  dep_list_reverse "$pkg"
}

# ----------------------------
# Update all: rebuild system respecting dependencies
# dep_update_all [--dry-run]
# Strategy: take all installed packages, compute topo order via resolving each installed root,
# deduplicate and run rebuild in order (deps first). This enables update.sh integration.
dep_update_all() {
  local mode="${1:-run}"
  dep_load
  # gather installed packages as roots
  local roots=()
  for p in "${!_INSTALLED_VER[@]}"; do
    roots+=("$p")
  done
  if [[ ${#roots[@]} -eq 0 ]]; then
    _dep_log INFO "dep_update_all: nenhum pacote instalado"
    return 0
  fi
  local ordered
  ordered=$(dep_resolve_many "${roots[@]}") || fail "dep_update_all: falha ao resolver grafo"
  _dep_log INFO "dep_update_all: ordem final: $ordered"
  if [[ "$mode" == "dry-run" ]]; then
    echo "$ordered"
    return 0
  fi
  for p in $ordered; do
    _dep_log INFO "dep_update_all: rebuild $p"
    # rebuild each package; prefer build.sh or build function; fallback to metafile
    if type build >/dev/null 2>&1; then
      build "$p" || { _dep_log ERROR "build $p falhou"; return 1; }
    elif command -v "${DEP_AUTO_BUILD_CMD}" >/dev/null 2>&1; then
      ${DEP_AUTO_BUILD_CMD} --name "$p" || { _dep_log ERROR "${DEP_AUTO_BUILD_CMD} falhou para $p"; return 1; }
    elif type mf_load >/dev/null 2>&1; then
      local mf
      mf=$(find /usr/src -type f -name "${p}.ini" -print -quit 2>/dev/null || true)
      if [[ -n "$mf" ]]; then
        mf_load "$mf"
        mf_fetch_sources || { _dep_log ERROR "fetch failed for $p"; return 1; }
        mf_apply_patches || true
        mf_construction || { _dep_log ERROR "build failed for $p"; return 1; }
      else
        _dep_log WARN "dep_update_all: não encontrou metafile para $p; pulando"
      fi
    else
      _dep_log WARN "dep_update_all: nenhuma ferramenta para rebuild $p; pulando"
    fi
  done
  return 0
}

# ----------------------------
# Utility: add installed package entry
# dep_mark_installed <pkg> [version]
dep_mark_installed() {
  local pkg="$1"; local version="${2:-<unknown>}"
  dep_load
  _INSTALLED_VER["$pkg"]="$version"
  dep_save
  _dep_log INFO "dep_mark_installed: $pkg=$version"
}

# ----------------------------
# Utility: remove installed mark
# dep_mark_uninstalled <pkg>
dep_mark_uninstalled() {
  local pkg="$1"
  dep_load
  unset _INSTALLED_VER["$pkg"]
  dep_save
  _dep_log INFO "dep_mark_uninstalled: $pkg marcado como desinstalado"
}

# ----------------------------
# CLI interface
# ----------------------------
_dep_usage() {
  cat <<EOF
depende.sh - gerenciador de dependências

Uso:
  depende.sh --resolve <pkg>              -> lista deps recursivas (deps primeiro)
  depende.sh --resolve-many <pkg...>     -> resolve vários pacotes (único ordenado)
  depende.sh --add <pkg> "<dep1 dep2>"  -> adiciona no DB e salva
  depende.sh --remove <pkg>              -> remove do DB
  depende.sh --installed                 -> lista pacotes instalados
  depende.sh --mark-installed <pkg> [ver] -> marca pacote instalado
  depende.sh --check-installed <pkg>     -> retorna versão se instalado
  depende.sh --reverse <pkg>             -> mostra quem depende de pkg
  depende.sh --orphans                   -> lista órfãos (dry-run)
  depende.sh --clean-orphans [auto]      -> remove órfãos; 'auto' efetua remoção
  depende.sh --auto-install <pkg>        -> instala recursivamente dependências e o pkg
  depende.sh --auto-build <pkg>          -> build recursivo de dependências
  depende.sh --update-all [dry-run]      -> reconstrói todo sistema (ou apenas mostra)
  depende.sh --save                       -> persiste DB atual (após mudanças)
  depende.sh --help                       -> ajuda
EOF
}

# ----------------------------
# Main CLI dispatcher
# ----------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if (( $# == 0 )); then _dep_usage; exit 0; fi
  cmd="$1"; shift
  case "$cmd" in
    --resolve)
      pkg="$1"; shift
      dep_resolve "$pkg" "true"
      ;;
    --resolve-many)
      dep_resolve_many "$@"
      ;;
    --add)
      pkg="$1"; shift
      deps="$*"
      dep_add "$pkg" "$deps"
      ;;
    --remove)
      dep_remove "$1"
      ;;
    --installed)
      dep_load
      for p in "${!_INSTALLED_VER[@]}"; do
        printf '%s=%s\n' "$p" "${_INSTALLED_VER[$p]}"
      done
      ;;
    --mark-installed)
      dep_mark_installed "$@"
      ;;
    --mark-uninstalled)
      dep_mark_uninstalled "$1"
      ;;
    --check-installed)
      dep_check_installed "$1" && exit 0 || exit 1
      ;;
    --reverse)
      dep_reverse "$1"
      ;;
    --orphans)
      dep_orphans
      ;;
    --clean-orphans)
      mode="${1:-dry-run}"
      dep_clean_orphans "$mode"
      ;;
    --auto-install)
      dep_auto_install "$1"
      ;;
    --auto-build)
      dep_auto_build "$1"
      ;;
    --update-all)
      mode="${1:-run}"
      dep_update_all "$mode"
      ;;
    --save)
      dep_save
      ;;
    --help|-h)
      _dep_usage
      ;;
    *)
      _dep_log ERROR "Comando inválido: $cmd"
      _dep_usage
      exit 2
      ;;
  esac
fi

# ----------------------------
# Export key functions for sourcing
# ----------------------------
export -f dep_load dep_save dep_add dep_remove dep_resolve dep_resolve_many \
  dep_orphans dep_clean_orphans dep_auto_install dep_auto_build dep_update_all \
  dep_mark_installed dep_mark_uninstalled dep_check_installed dep_reverse
