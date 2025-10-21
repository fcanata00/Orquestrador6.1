#!/usr/bin/env bash
# deps.sh - Gerenciador de dependências para LFS automated builder
# Features:
#  - Carrega pacotes via metafile.sh (mf_init, mf_list_packages, mf_get_field)
#  - Constrói grafo de dependência e calcula ordem com Kahn (topological sort)
#  - Detecta ciclos e imprime ciclo encontrado
#  - API exportada: deps_init, deps_list_all, deps_resolve, deps_check_ready, deps_rebuild_all, deps_mark_installed, deps_mark_removed, deps_required_by, etc.
#  - Robust error handling, SILENT_ERRORS support, logging via log.sh if present
#  - State DB in /var/lib/lfs/deps.db (simple newline list of installed packages)
#
# Requirements: bash 4+, awk, sed, coreutils. Integrates with metafile.sh, log.sh and utils.sh if available.
set -Eeuo pipefail

# ---------- Configuration ----------
: "${DEPS_DB:=/var/lib/lfs/deps.db}"
: "${DEPS_DB_BAK:=/var/lib/lfs/deps.db.bak}"
: "${DEPS_CACHE:=/var/cache/lfs/depgraph.cache}"
: "${SILENT_ERRORS:=false}"
: "${ABORT_ON_ERROR:=true}"
: "${LOG_SCRIPT:=/usr/bin/logs.sh}"
: "${METAFILE_SCRIPT:=/usr/bin/metafile.sh}"
: "${UTILS_SCRIPT:=/usr/bin/utils.sh}"
: "${STATE_DIR:=$(dirname "$DEPS_DB")}"

export DEPS_DB DEPS_DB_BAK DEPS_CACHE SILENT_ERRORS ABORT_ON_ERROR LOG_SCRIPT METAFILE_SCRIPT UTILS_SCRIPT STATE_DIR

# ---------- Try source log & utils & metafile if available ----------
LOG_API_READY=false
if [ -f "$LOG_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$LOG_SCRIPT" || true
  LOG_API_READY=true
fi
if [ -f "$UTILS_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$UTILS_SCRIPT" || true
fi
if [ -f "$METAFILE_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$METAFILE_SCRIPT" || true
fi

# ---------- logging helpers (prefer log.sh) ----------
_deps_info(){
  if [ "$LOG_API_READY" = true ] && type log_info >/dev/null 2>&1; then
    log_info "$@"
  else
    printf "[DEPS][INFO] %s\n" "$*"
  fi
}
_deps_warn(){
  if [ "$LOG_API_READY" = true ] && type log_warn >/dev/null 2>&1; then
    log_warn "$@"
  else
    printf "[DEPS][WARN] %s\n" "$*"
  fi
}
_deps_error(){
  if [ "$LOG_API_READY" = true ] && type log_error >/dev/null 2>&1; then
    log_error "$@"
  else
    printf "[DEPS][ERROR] %s\n" "$*" >&2
  fi
  if [ "${SILENT_ERRORS:-false}" = "true" ]; then
    return 1
  fi
  if [ "${ABORT_ON_ERROR:-true}" = "true" ]; then
    exit 1
  fi
  return 1
}

# ---------- Internal structures ----------
declare -A _DEP_LIST        # _DEP_LIST["pkg"]="dep1,dep2,..."
declare -A _REV_DEPS       # reverse deps: _REV_DEPS["dep"]="pkg1,pkg2"
declare -A _IN_DEGREE      # indegree integer
declare -A _NODES_PRESENT  # set of nodes present
declare -a _PKG_ORDER      # result of topological sort (Kahn)
declare -A _METADATA       # cached metadata key: pkg|field => value

# ---------- Utilities ----------
_safe_mkdir(){ mkdir -p "$1" 2>/dev/null || _deps_error "failed to create dir $1"; }
_save_db_backup(){
  _safe_mkdir "$STATE_DIR"
  if [ -f "$DEPS_DB" ]; then
    cp -f "$DEPS_DB" "$DEPS_DB_BAK" 2>/dev/null || _deps_warn "failed to backup deps db"
  fi
}
_db_ensure(){
  _safe_mkdir "$STATE_DIR"
  touch "$DEPS_DB" 2>/dev/null || _deps_error "cannot create deps db $DEPS_DB"
}

# ---------- State management ----------
deps_mark_installed(){
  local pkg="$1"
  _db_ensure
  if ! grep -Fxq "$pkg" "$DEPS_DB" 2>/dev/null; then
    echo "$pkg" >> "$DEPS_DB"
    _deps_info "Marked installed: $pkg"
  else
    _deps_info "Already marked installed: $pkg"
  fi
}
deps_mark_removed(){
  local pkg="$1"
  _db_ensure
  if grep -Fxq "$pkg" "$DEPS_DB" 2>/dev/null; then
    grep -Fxv "$pkg" "$DEPS_DB" > "${DEPS_DB}.tmp" && mv -f "${DEPS_DB}.tmp" "$DEPS_DB"
    _deps_info "Marked removed: $pkg"
  else
    _deps_warn "Package not listed installed: $pkg"
  fi
}
deps_list_installed(){
  _db_ensure
  cat "$DEPS_DB" 2>/dev/null || true
}

# ---------- Graph building (from metafile) ----------
deps_init(){
  local metafile_dir="${1:-}"
  if [ -n "${metafile_dir:-}" ]; then
    if type mf_init >/dev/null 2>&1; then
      mf_init "$metafile_dir" || _deps_error "mf_init failed for $metafile_dir"
    else
      _deps_warn "metafile.sh not available; cannot init from metafiles"
    fi
  fi

  _PKG_ORDER=()
  _DEP_LIST=()
  _REV_DEPS=()
  _IN_DEGREE=()
  _NODES_PRESENT=()

  local pkgs=()
  if type mf_list_packages >/dev/null 2>&1; then
    while IFS='|' read -r pkg ver type stage; do
      pkgs+=("$pkg")
    done < <(mf_list_packages)
  else
    _deps_error "metafile API (mf_list_packages) not available; cannot build dependency graph"
    return 2
  fi

  for p in "${pkgs[@]}"; do
    _NODES_PRESENT["$p"]=1
    local deps
    deps=$(mf_get_field "$p" "depends" 2>/dev/null || true)
    deps="${deps//[[:space:]]/}"
    if [ -z "$deps" ]; then
      _DEP_LIST["$p"]=""
      _IN_DEGREE["$p"]=0
    else
      IFS=',' read -ra arr <<< "$deps"
      local cleandeps=()
      for d in "${arr[@]}"; do
        [ -z "$d" ] && continue
        cleandeps+=("$d")
        if [ -n "${_REV_DEPS[$d]:-}" ]; then
          _REV_DEPS["$d"]="${_REV_DEPS[$d]},$p"
        else
          _REV_DEPS["$d"]="$p"
        fi
      done
      _DEP_LIST["$p"]=$(IFS=,; echo "${cleandeps[*]}")
      _IN_DEGREE["$p"]=${#cleandeps[@]}
    fi
  done

  for p in "${pkgs[@]}"; do
    _IN_DEGREE["$p"]="${_IN_DEGREE["$p"]:-0}"
  done

  _deps_info "Dependency graph built: ${#pkgs[@]} packages"
  _save_graph_cache
  return 0
}

_save_graph_cache(){
  _safe_mkdir "$(dirname "$DEPS_CACHE")"
  {
    for k in "${!_DEP_LIST[@]}"; do
      echo "NODE|$k|${_DEP_LIST[$k]}"
    done
    for k in "${!_REV_DEPS[@]}"; do
      echo "REV|$k|${_REV_DEPS[$k]}"
    done
  } > "$DEPS_CACHE" 2>/dev/null || _deps_warn "cannot write dep cache"
}

# ---------- Kahn topological sort with cycle detection ----------
deps_topo_sort(){
  _PKG_ORDER=()
  declare -a queue=()
  declare -A indeg
  for node in "${!_IN_DEGREE[@]}"; do
    indeg["$node"]="${_IN_DEGREE[$node]}"
    if [ "${indeg[$node]}" -eq 0 ]; then
      queue+=("$node")
    fi
  done

  while [ "${#queue[@]}" -gt 0 ]; do
    node="${queue[0]}"
    queue=("${queue[@]:1}")
    _PKG_ORDER+=("$node")
    for m in "${!_DEP_LIST[@]}"; do
      local depstr="${_DEP_LIST[$m]}"
      if [ -n "$depstr" ] && echo ",$depstr," | grep -q ",${node},"; then
        indeg["$m"]=$((indeg["$m"] - 1))
        if [ "${indeg[$m]}" -eq 0 ]; then
          queue+=("$m")
        fi
      fi
    done
  done

  local total_nodes=0
  for _ in "${!_NODES_PRESENT[@]}"; do ((total_nodes++)); done
  if [ "${#_PKG_ORDER[@]}" -ne "$total_nodes" ]; then
    declare -A seen
    for n in "${_PKG_ORDER[@]}"; do seen["$n"]=1; done
    local cycle_nodes=()
    for n in "${!_NODES_PRESENT[@]}"; do
      if [ -z "${seen[$n]:-}" ]; then cycle_nodes+=("$n"); fi
    done
    _deps_error "Cycle detected in dependency graph. Nodes involved: ${cycle_nodes[*]}"
    _deps_print_cycle "${cycle_nodes[0]}"
    return 3
  fi

  _deps_info "Topological sort successful. Order length: ${#_PKG_ORDER[@]}"
  return 0
}

_deps_print_cycle(){
  local start="$1"
  declare -A visited
  declare -A recstack
  declare -a path
  local found=0

  _dfs_cycle(){
    local v="$1"
    visited["$v"]=1
    recstack["$v"]=1
    path+=("$v")
    local deps="${_DEP_LIST[$v]:-}"
    IFS=',' read -ra arr <<< "$deps"
    for n in "${arr[@]:-}"; do
      [ -z "$n" ] && continue
      if [ -z "${visited[$n]:-}" ]; then
        _dfs_cycle "$n" || return $?
      elif [ "${recstack[$n]:-}" = "1" ]; then
        local out=()
        local started=0
        for x in "${path[@]}"; do
          if [ "$x" = "$n" ]; then started=1; fi
          if [ "$started" -eq 1 ]; then out+=("$x"); fi
        done
        out+=("$n")
        _deps_error "Dependency cycle path: ${out[*]}"
        found=1
        return 0
      fi
    done
    unset 'path[${#path[@]}-1]'
    recstack["$v"]=0
    return 0
  }

  _dfs_cycle "$start"
  if [ "$found" -eq 0 ]; then
    _deps_warn "Cycle detected but specific path could not be reconstructed starting from $start"
  fi
}

# ---------- API functions ----------
deps_list_all(){
  if type mf_list_packages >/dev/null 2>&1; then
    mf_list_packages
  else
    for p in "${!_DEP_LIST[@]}"; do
      echo "$p"
    done
  fi
}

deps_resolve(){
  local pkg="$1"
  if [ -z "$pkg" ]; then _deps_error "deps_resolve <pkg> required"; return 2; fi
  deps_topo_sort || return $?
  declare -A leads_to_pkg
  leads_to_pkg["$pkg"]=1
  local changed=1
  while [ "$changed" -eq 1 ]; do
    changed=0
    for n in "${!_DEP_LIST[@]}"; do
      local deps="${_DEP_LIST[$n]:-}"
      IFS=',' read -ra arr <<< "$deps"
      for d in "${arr[@]:-}"; do
        if [ -n "${leads_to_pkg[$d]:-}" ] && [ -z "${leads_to_pkg[$n]:-}" ]; then
          leads_to_pkg["$n"]=1
          changed=1
        fi
      done
    done
  done
  for node in "${_PKG_ORDER[@]}"; do
    if [ -n "${leads_to_pkg[$node]:-}" ]; then
      echo "$node"
    fi
  done
  return 0
}

deps_show(){
  local pkg="$1"
  if [ -z "$pkg" ]; then _deps_error "deps_show <pkg>"; return 2; fi
  echo "Package: $pkg"
  echo "Depends: ${_DEP_LIST[$pkg]:-}"
  echo "Required-by: ${_REV_DEPS[$pkg]:-}"
  echo "Installed: $(grep -Fxq "$pkg" "$DEPS_DB" 2>/dev/null && echo yes || echo no)"
}

deps_required_by(){
  local pkg="$1"
  echo "${_REV_DEPS[$pkg]:-}"
}

deps_check_ready(){
  local pkg="$1"
  if [ -z "${_DEP_LIST[$pkg]:-}" ] && [ -z "${_NODES_PRESENT[$pkg]:-}" ]; then
    _deps_error "Package unknown: $pkg"
    return 2
  fi
  local missing=0
  local deps="${_DEP_LIST[$pkg]:-}"
  IFS=',' read -ra arr <<< "$deps"
  for d in "${arr[@]:-}"; do
    [ -z "$d" ] && continue
    if ! grep -Fxq "$d" "$DEPS_DB" 2>/dev/null; then
      _deps_warn "Dependency $d for $pkg not installed"
      missing=1
    fi
  done
  return $missing
}

deps_rebuild_all(){
  deps_topo_sort || return $?
  _deps_info "Rebuilding all packages in order..."
  for p in "${_PKG_ORDER[@]}"; do
    _deps_info "Trigger build for $p"
    if [ -x "/usr/bin/build.sh" ]; then
      /usr/bin/build.sh build "$p" || _deps_warn "build.sh failed for $p"
    else
      _deps_warn "build.sh not available; skipping actual build for $p"
    fi
  done
  return 0
}

deps_rebuild_changed(){
  _deps_info "Checking for packages with changed dependencies..."
  local cache_versions="/var/cache/lfs/dep_versions"
  declare -A oldver newver
  if [ -f "$cache_versions" ]; then
    while IFS='|' read -r pkg ver; do oldver["$pkg"]="$ver"; done < "$cache_versions"
  fi
  for p in "${!_NODES_PRESENT[@]}"; do
    newver["$p"]="$(mf_get_field "$p" "version" 2>/dev/null || echo "")"
  done
  declare -a to_rebuild=()
  for p in "${!_NODES_PRESENT[@]}"; do
    local deps="${_DEP_LIST[$p]:-}"
    IFS=',' read -ra arr <<< "$deps"
    for d in "${arr[@]:-}"; do
      if [ -n "${oldver[$d]:-}" ] && [ "${oldver[$d]}" != "${newver[$d]:-}" ]; then
        _deps_info "Dependency $d of $p changed (${oldver[$d]} -> ${newver[$d]:-})"
        to_rebuild+=("$p")
        break
      fi
    done
  done
  if [ "${#to_rebuild[@]}" -eq 0 ]; then
    _deps_info "No changed-dependent packages detected."
    return 0
  fi
  declare -A seen
  for r in "${to_rebuild[@]}"; do
    if [ -z "${seen[$r]:-}"; then
      seen["$r"]=1
      _deps_info "Rebuilding $r"
      if [ -x "/usr/bin/build.sh" ]; then
        /usr/bin/build.sh build "$r" || _deps_warn "build failed for $r"
      else
        _deps_warn "build.sh not available; skipping build for $r"
      fi
    fi
  done
  _safe_mkdir "$(dirname "$cache_versions")"
  : > "$cache_versions"
  for p in "${!newver[@]}"; do
    echo "$p|${newver[$p]}" >> "$cache_versions"
  done
  return 0
}

deps_safe_to_remove(){
  local pkg="$1"
  if [ -z "$pkg" ]; then _deps_error "deps_safe_to_remove <pkg>"; return 2; fi
  if [ -n "${_REV_DEPS[$pkg]:-}" ]; then
    _deps_info "Package $pkg is required by: ${_REV_DEPS[$pkg]}"
    return 1
  fi
  _deps_info "Package $pkg can be safely removed (no dependents)"
  return 0
}

deps_validate_graph(){
  deps_topo_sort || return $?
  return 0
}

deps_print_graph(){
  local out="${1:-/dev/stdout}"
  {
    echo "digraph deps {"
    for p in "${!_DEP_LIST[@]}"; do
      IFS=',' read -ra arr <<< "${_DEP_LIST[$p]}"
      for d in "${arr[@]:-}"; do
        [ -z "$d" ] && continue
        echo "  \"${d}\" -> \"${p}\";"
      done
    done
    echo "}"
  } > "$out"
  _deps_info "Dep graph written to $out"
}

deps_dump_state(){
  local out="${1:-/var/cache/lfs/depstate.json}"
  _safe_mkdir "$(dirname "$out")"
  {
    echo "{"
    printf '  \"installed\": [\n'
    local first=1
    while IFS= read -r l; do
      if [ -z "$l" ]; then continue; fi
      if [ $first -eq 1 ]; then printf '    \"%s\"\n' "$l"; first=0; else printf '    ,\"%s\"\n' "$l"; fi
    done < "$DEPS_DB"
    echo "  ],"
    echo '  "packages": {'
    local pfirst=1
    for p in "${!_DEP_LIST[@]}"; do
      if [ $pfirst -eq 1 ]; then pfirst=0; else echo ","; fi
      printf '    \"%s\": {\"depends\":\"%s\"}' "$p" "${_DEP_LIST[$p]}"
    done
    echo ""
    echo "  }"
    echo "}"
  } > "$out"
  _deps_info "State dumped to $out"
}

_deps_usage(){
  cat <<EOF
Usage: deps.sh <command> [args...]
Commands:
  init [metafile_dir]      Load metafiles and build graph
  list                     List known packages
  topo                     Print topological order (Kahn)
  resolve <pkg>            Print resolve order for pkg (deps first)
  show <pkg>               Show dependencies for pkg
  check-ready <pkg>        Check if pkg has all deps installed
  rebuild-all              Rebuild all packages in topological order (calls build.sh)
  rebuild-changed          Rebuild packages affected by dependency version changes
  mark-installed <pkg>     Mark package as installed
  mark-removed <pkg>       Mark package removed
  safe-remove <pkg>        Check if safe to remove
  print-graph [out.dot]    Print graph DOT file
  dump-state [out.json]    Dump state JSON
  help
EOF
}

if [ "${BASH_SOURCE[0]}" == "$0" ]; then
  case "${1:-}" in
    init) deps_init "${2:-}"; exit $?;;
    list) deps_list_all; exit 0;;
    topo) deps_topo_sort && printf '%s\n' "${_PKG_ORDER[@]}"; exit $?;;
    resolve) deps_resolve "$2"; exit $?;;
    show) deps_show "$2"; exit $?;;
    "check-ready") deps_check_ready "$2"; exit $?;;
    "rebuild-all") deps_rebuild_all; exit $?;;
    "rebuild-changed") deps_rebuild_changed; exit $?;;
    "mark-installed") deps_mark_installed "$2"; exit $?;;
    "mark-removed") deps_mark_removed "$2"; exit $?;;
    "safe-remove") deps_safe_to_remove "$2"; exit $?;;
    "print-graph") deps_print_graph "${2:-/dev/stdout}"; exit $?;;
    "dump-state") deps_dump_state "${2:-/var/cache/lfs/depstate.json}"; exit $?;;
    help|--help|-h) _deps_usage; exit 0;;
    "") _deps_usage; exit 0;;
    *) echo "Unknown command: $1"; _deps_usage; exit 2;;
  esac
fi

export -f deps_init deps_list_all deps_topo_sort deps_resolve deps_show deps_check_ready deps_rebuild_all deps_rebuild_changed deps_mark_installed deps_mark_removed deps_required_by deps_safe_to_remove deps_validate_graph deps_print_graph deps_dump_state
