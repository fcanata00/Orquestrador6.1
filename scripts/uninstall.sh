#!/usr/bin/env bash
# uninstall.sh - remoção segura de pacotes, limpeza de órfãos e hooks
# Versão: 2025-10-23
set -eEuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="uninstall"
SCRIPT_VERSION="1.0.0"

# -----------------------
# Configuráveis via ENV
# -----------------------
: "${DEP_BASE:=/var/lib/orquestrador}"
: "${DEP_DB:=${DEP_BASE}/depends.db}"
: "${INST_DB:=${DEP_BASE}/installed.db}"
: "${FILES_DIR:=${DEP_BASE}/files}"          # file lists: $FILES_DIR/<pkg>.list
: "${BACKUP_BASE:=/var/backups/orquestrador}"
: "${LOG_DIR:=/var/log/orquestrador/uninstall}"
: "${LOCK_DIR:=/run/lock/orquestrador}"
: "${UNINSTALL_FLOCK_TIMEOUT:=300}"
: "${UNINSTALL_SILENT:=false}"
: "${UNINSTALL_DEBUG:=false}"
: "${UNINSTALL_DRYRUN:=false}"
: "${UNINSTALL_WHITELIST:=/usr /etc /var /opt /bin /sbin /lib /lib64 /usr/local}" # allowed removal roots

# internal
declare -A _INSTALLED_VER   # pkg->version
declare -A _DEP_GRAPH      # pkg -> deps
declare -A _REV_GRAPH      # pkg -> reverse deps (pkg that depends on key)
declare -a _TO_REMOVE      # list of pkgs to remove this session
_SESSION_TS=""
_LOG_FILE=""
_LOCK_FD=""

# -----------------------
# Logging (register integration)
# -----------------------
log() {
  local level="$1"; shift; local msg="$*"
  if type register_info >/dev/null 2>&1; then
    case "$level" in
      INFO)  register_info "$msg";;
      WARN)  register_warn "$msg";;
      ERROR) register_error "$msg";;
      DEBUG) register_debug "$msg";;
      *) register_info "$msg";;
    esac
    return 0
  fi
  if [[ "${UNINSTALL_SILENT}" == "true" && "$level" != "ERROR" ]]; then
    return 0
  fi
  case "$level" in
    INFO)  printf '\e[32m[INFO]\e[0m %s\n' "$msg" ;;
    WARN)  printf '\e[33m[WARN]\e[0m %s\n' "$msg" >&2 ;;
    ERROR) printf '\e[31m[ERROR]\e[0m %s\n' "$msg" >&2 ;;
    DEBUG) [[ "${UNINSTALL_DEBUG}" == "true" ]] && printf '\e[36m[DEBUG]\e[0m %s\n' "$msg" ;;
    *) printf '[LOG] %s\n' "$msg" ;;
  esac
  [[ -n "${_LOG_FILE:-}" ]] && printf '%s %s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "[$level]" "$msg" >> "${_LOG_FILE}" 2>/dev/null || true
}

fail() {
  log ERROR "$*"
  uninstall_rollback || true
  exit 1
}

# -----------------------
# Setup dirs & files
# -----------------------
_init_dirs() {
  mkdir -p "${DEP_BASE}" "${FILES_DIR}" "${BACKUP_BASE}" "${LOG_DIR}" "${LOCK_DIR}"
  chmod 750 "${DEP_BASE}" "${FILES_DIR}" "${BACKUP_BASE}" "${LOG_DIR}" "${LOCK_DIR}" 2>/dev/null || true
  _SESSION_TS=$(date -u +"%Y%m%dT%H%M%SZ")-$$
}

_rotate_log() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local bytes; bytes=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if (( bytes > 10485760 )); then
      for i in 4 3 2 1; do
        [[ -f "${f}.${i}" ]] && mv -f "${f}.${i}" "${f}.$((i+1))" || true
      done
      mv -f "$f" "${f}.1" || true
      : > "$f"
    fi
  fi
}

# -----------------------
# Lock management (global and per-pkg)
# -----------------------
_acquire_global_lock() {
  local lockfile="${LOCK_DIR}/uninstall.lock"
  exec { _LOCK_FD }>"${lockfile}" || fail "Não pode abrir lockfile ${lockfile}"
  if flock -n "${_LOCK_FD}"; then
    log DEBUG "Lock global adquirido"
    return 0
  fi
  log INFO "Aguardando lock global (timeout ${UNINSTALL_FLOCK_TIMEOUT}s)..."
  local waited=0
  while ! flock -n "${_LOCK_FD}"; do
    sleep 1
    waited=$((waited+1))
    if (( waited >= UNINSTALL_FLOCK_TIMEOUT )); then
      fail "Timeout aguardando lock global"
    fi
  done
  log DEBUG "Lock global adquirido após espera ${waited}s"
  return 0
}

_release_global_lock() {
  if [[ -n "${_LOCK_FD:-}" ]]; then
    eval "exec ${_LOCK_FD}>&-"
    unset _LOCK_FD
  fi
}

# -----------------------
# Load DBs (installed & depends)
# -----------------------
db_load() {
  _INSTALLED_VER=()
  _DEP_GRAPH=()
  _REV_GRAPH=()

  if [[ -f "${INST_DB}" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line=${line%%#*}
      [[ -z "${line// /}" ]] && continue
      if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
        _INSTALLED_VER["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
      fi
    done < "${INST_DB}"
  fi

  if [[ -f "${DEP_DB}" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line=${line%%#*}
      [[ -z "${line// /}" ]] && continue
      if [[ "$line" =~ ^([^:]+):[[:space:]]*(.*)$ ]]; then
        local pkg="${BASH_REMATCH[1]}"
        local deps="${BASH_REMATCH[2]}"
        deps=$(echo "${deps}" | xargs)
        _DEP_GRAPH["$pkg"]="$deps"
        for d in $deps; do
          local cur="${_REV_GRAPH[$d]:-}"
          if [[ -z "$cur" ]]; then _REV_GRAPH[$d]="$pkg"; else _REV_GRAPH[$d]="${cur} ${pkg}"; fi
        done
      fi
    done < "${DEP_DB}"
  fi
  log INFO "DBs carregados: installed=${#_INSTALLED_VER[@]} pkgs, depends=${#_DEP_GRAPH[@]} entries"
}

# -----------------------
# Save DBs (atomic with backup)
# -----------------------
db_save() {
  _acquire_global_lock
  mkdir -p "${DEP_BASE}/backup" 2>/dev/null || true
  cp -a "${INST_DB}" "${DEP_BASE}/backup/installed.db.${_SESSION_TS}" 2>/dev/null || true
  cp -a "${DEP_DB}" "${DEP_BASE}/backup/depends.db.${_SESSION_TS}" 2>/dev/null || true

  local tmp_inst; tmp_inst=$(mktemp "${DEP_BASE}/installed.db.tmp.XXXX") || fail "mktemp failed"
  local tmp_dep; tmp_dep=$(mktemp "${DEP_BASE}/depends.db.tmp.XXXX") || fail "mktemp failed"

  for p in "${!_INSTALLED_VER[@]}"; do
    echo "${p}=${_INSTALLED_VER[$p]}" >> "$tmp_inst"
  done
  for p in "${!_DEP_GRAPH[@]}"; do
    echo "${p}: ${_DEP_GRAPH[$p]}" >> "$tmp_dep"
  done

  mv -f "$tmp_inst" "${INST_DB}"
  mv -f "$tmp_dep" "${DEP_DB}"
  chmod 640 "${INST_DB}" "${DEP_DB}" 2>/dev/null || true
  log INFO "DBs salvos"
  _release_global_lock
}

# -----------------------
# Helpers: read file list for a package
# -----------------------
pkg_filelist_path() {
  local pkg="$1"
  echo "${FILES_DIR}/${pkg}.list"
}

pkg_has_filelist() {
  local pkg="$1"
  [[ -f "$(pkg_filelist_path "$pkg")" ]]
}

list_files_of_pkg() {
  local pkg="$1"
  local fl
  fl=$(pkg_filelist_path "$pkg")
  if [[ -f "$fl" ]]; then
    sed '/^[[:space:]]*#/d' "$fl" | sed '/^[[:space:]]*$/d'
  else
    # try to read cache meta to infer? fallback: empty
    echo ""
  fi
}

# -----------------------
# Safety check for removal path
# Only allow removal of files that lie under allowed roots
# -----------------------
is_safe_to_remove() {
  local filepath="$1"
  # disallow empty, remove trailing slashes
  [[ -z "$filepath" ]] && return 1
  filepath=$(realpath -e "$filepath" 2>/dev/null || realpath -m "$filepath" 2>/dev/null || echo "$filepath")
  for root in ${UNINSTALL_WHITELIST}; do
    root=$(realpath -m "$root" 2>/dev/null || echo "$root")
    case "$filepath" in
      "$root"/*) return 0 ;;
    esac
  done
  return 1
}

# -----------------------
# Check reverse deps: abort if other installed pkgs depend on this one
# returns 0 if safe to remove (no dependents), else non-zero
# -----------------------
check_reverse_deps() {
  local pkg="$1"
  db_load
  local dependents
  dependents=$(echo "${_REV_GRAPH[$pkg]:-}" | xargs)
  if [[ -z "$dependents" ]]; then
    return 0
  fi
  # filter only installed dependents
  local installed_deps=""
  for p in $dependents; do
    if [[ -n "${_INSTALLED_VER[$p]:-}" ]]; then
      installed_deps="${installed_deps} ${p}"
    fi
  done
  installed_deps=$(echo "$installed_deps" | xargs)
  if [[ -n "$installed_deps" ]]; then
    log WARN "Pacote '$pkg' é dependência de: $installed_deps"
    return 2
  fi
  return 0
}

# -----------------------
# Run hooks for uninstall (pre/post)
# -----------------------
run_uninstall_hooks() {
  local hook_stage="$1"; shift
  local pkg="$1"; shift
  if type hooks_run >/dev/null 2>&1; then
    hooks_run "${hook_stage}" "${pkg}" "${FILES_DIR}/${pkg}.list" || {
      log WARN "Hook ${hook_stage} para ${pkg} retornou não-zero"
      return 1
    }
  fi
}

# -----------------------
# Backup files for a package (before deletion)
# Returns backup_dir path
# -----------------------
backup_pkg_files() {
  local pkg="$1"
  local dst="${BACKUP_BASE}/${pkg}-${_SESSION_TS}"
  mkdir -p "${dst}" || fail "Falha ao criar backup dir ${dst}"
  local fl
  fl=$(pkg_filelist_path "$pkg")
  if [[ ! -f "$fl" ]]; then
    log WARN "Nenhuma filelist para ${pkg}; nenhum arquivo será movido (backup vazio)"
    echo "$dst"
    return 0
  fi
  # copy each file into backup dir preserving dirs
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # skip comments/invalid
    if [[ "$f" =~ ^# ]]; then continue; fi
    # ensure absolute path
    if [[ "$f" != /* ]]; then
      log WARN "Caminho relativo na filelist: $f (ignorando)"
      continue
    fi
    # safety check
    if ! is_safe_to_remove "$f"; then
      log WARN "Arquivo fora da whitelist, não será removido: $f"
      continue
    fi
    if [[ -e "$f" ]]; then
      local rel; rel=$(echo "$f" | sed 's|^/||')
      local target_dir; target_dir=$(dirname "${dst}/${rel}")
      mkdir -p "$target_dir"
      # move to backup (use mv to preserve ownership/perm), if fails fallback to copy
      if mv -f "$f" "${dst}/${rel}" 2>/dev/null; then
        log DEBUG "Movido: $f -> ${dst}/${rel}"
      else
        # maybe permissions; try cp -a then rm
        if cp -a "$f" "${dst}/${rel}" 2>/dev/null; then
          rm -f "$f" 2>/dev/null || true
          log DEBUG "Copiado+removido: $f -> ${dst}/${rel}"
        else
          log WARN "Falha ao mover/copiar $f para backup; deixando no lugar"
        fi
      fi
    else
      log DEBUG "Arquivo não existe (ok): $f"
    fi
  done < <(list_files_of_pkg "$pkg")
  echo "$dst"
}

# -----------------------
# Remove package (core)
# Steps:
#  - validate reverse deps
#  - run pre-uninstall hooks
#  - backup files (move them)
#  - remove filelist and metadata entries
#  - run post-uninstall hooks
#  - update dbs
#  - log actions (session list)
# Supports dry-run mode
# -----------------------
_uninstall_package_core() {
  local pkg="$1"
  local dry="${2:-false}"
  log INFO "Iniciando uninstall de: $pkg (dry=${dry})"
  # check installed
  db_load
  if [[ -z "${_INSTALLED_VER[$pkg]:-}" ]]; then
    log WARN "Pacote ${pkg} não está marcado como instalado; ainda assim tentaremos remover arquivos se houver filelist"
  fi
  # check reverse deps
  if ! check_reverse_deps "$pkg"; then
    log ERROR "Remoção abortada: existem dependentes instalados para ${pkg}"
    return 2
  fi

  # run pre-uninstall hooks
  run_uninstall_hooks "pre-uninstall" "$pkg" || log WARN "pre-uninstall hook falhou para $pkg"

  if [[ "$dry" == "true" ]]; then
    # just list files and actions
    log INFO "[DRY-RUN] Arquivos que seriam removidos para ${pkg}:"
    list_files_of_pkg "$pkg" | while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if [[ "$f" =~ ^# ]]; then continue; fi
      if is_safe_to_remove "$f"; then
        printf '%s\n' "$f"
      else
        printf 'SKIP (unsafe): %s\n' "$f"
      fi
    done
    return 0
  fi

  # backup and remove files
  local backup_dir
  backup_dir=$(backup_pkg_files "$pkg") || { log ERROR "backup falhou para $pkg"; return 3; }

  # remove pkg filelist
  local filelist
  filelist=$(pkg_filelist_path "$pkg")
  if [[ -f "$filelist" ]]; then
    rm -f "$filelist" || log WARN "Falha ao remover filelist $filelist"
  fi

  # update DBs: remove installed marker and entry in depends (we keep depends entries for other pkgs)
  unset _INSTALLED_VER["$pkg"]
  unset _DEP_GRAPH["$pkg"]
  # rebuild reverse graph
  _REV_GRAPH=()
  for p in "${!_DEP_GRAPH[@]}"; do
    for d in ${_DEP_GRAPH[$p]}; do
      local cur="${_REV_GRAPH[$d]:-}"
      if [[ -z "$cur" ]]; then _REV_GRAPH[$d]="$p"; else _REV_GRAPH[$d]="${cur} ${p}"; fi
    done
  done

  # persist changes
  db_save || log WARN "db_save retornou não-zero (verifique permissões)"

  # run post-uninstall hooks
  run_uninstall_hooks "post-uninstall" "$pkg" || log WARN "post-uninstall hook falhou para $pkg"

  # record backup in log
  log INFO "Pacote ${pkg} removido. Backup dos arquivos em: ${backup_dir}"
  printf '%s %s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "REMOVED" "${pkg}" >> "${LOG_DIR}/actions.log" 2>/dev/null || true
  return 0
}

# -----------------------
# Uninstall single package wrapper (handles dry-run, lock, rollback)
# -----------------------
uninstall_package() {
  local pkg="$1"
  local dry="${2:-false}"
  _LOG_FILE="${LOG_DIR}/${pkg}.log"
  _rotate_log "$_LOG_FILE"
  db_load

  # per-package lock (to avoid concurrent ops)
  local plock="${LOCK_DIR}/pkg-${pkg}.lock"
  exec {PKG_FD}>"${plock}" || fail "Não pode abrir lockfile ${plock}"
  if ! flock -n "${PKG_FD}"; then
    log INFO "Aguardando lock para pacote ${pkg}..."
    flock "${PKG_FD}" || true
  fi

  if ! _uninstall_package_core "$pkg" "$dry"; then
    log ERROR "Falha ao desinstalar ${pkg}"
    eval "exec ${PKG_FD}>&-" || true
    return 1
  fi

  eval "exec ${PKG_FD}>&-" || true
  return 0
}

# -----------------------
# Orphans detection and removal
# -----------------------
list_orphans() {
  db_load
  local orphans=()
  for p in "${!_INSTALLED_VER[@]}"; do
    # if no reverse deps installed, it's orphan
    local rev; rev=$(echo "${_REV_GRAPH[$p]:-}" | xargs)
    local has_installed_rev=false
    for r in $rev; do
      if [[ -n "${_INSTALLED_VER[$r]:-}" ]]; then
        has_installed_rev=true
        break
      fi
    done
    if [[ "$has_installed_rev" == "false" ]]; then
      orphans+=("$p")
    fi
  done
  echo "${orphans[@]}" | xargs
}

clean_orphans() {
  local mode="${1:-dry-run}"
  local orph; orph=$(list_orphans)
  if [[ -z "$orph" ]]; then
    log INFO "Nenhum órfão detectado"
    return 0
  fi
  log INFO "Órfãos detectados: $orph"
  for p in $orph; do
    if [[ "$mode" == "dry-run" ]]; then
      echo "$p"
    else
      log INFO "Removendo órfão: $p"
      uninstall_package "$p" "false" || log WARN "Falha ao remover órfão $p"
    fi
  done
}

# -----------------------
# Rollback routine: restore backups if available for last failed pkg
# It attempts to restore any backups created during this session.
# -----------------------
uninstall_rollback() {
  log WARN "[ROLLBACK] Iniciando rollback de ações desta sessão (${_SESSION_TS})"
  # find backups for this session
  local bdir
  for bdir in "${BACKUP_BASE}"/*-"${_SESSION_TS}" 2>/dev/null; do
    [[ -d "$bdir" ]] || continue
    log INFO "Restaurando backup $bdir"
    # restore files under backup preserving paths
    (cd "$bdir" && tar -cf - .) | (cd / && tar xpf -) || log WARN "Falha ao restaurar $bdir (verifique permissões)"
  done
  _release_global_lock || true
  log WARN "[ROLLBACK] Concluído"
  return 0
}

# -----------------------
# CLI parsing and dispatch
# -----------------------
_print_usage() {
  cat <<EOF
uninstall.sh - remove pacotes e limpa órfãos com segurança

Uso:
  uninstall.sh --remove <pkg> [--dry-run]     : remove pacote
  uninstall.sh --remove-list <file> [--dry-run]: remove lista de pacotes do arquivo
  uninstall.sh --orphans                      : lista pacotes órfãos (dry-run)
  uninstall.sh --clean-orphans [--auto]       : remove órfãos (use --auto to actually remove)
  uninstall.sh --help
Flags (ENV):
  UNINSTALL_SILENT=true   - reduz logs
  UNINSTALL_DEBUG=true    - ativa logs debug
EOF
}

# -----------------------
# Main dispatcher
# -----------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _init_dirs
  db_load
  _acquire_global_lock
  trap 'uninstall_rollback; _release_global_lock' ERR INT TERM

  if (( $# == 0 )); then _print_usage; _release_global_lock; exit 0; fi
  cmd="$1"; shift
  case "$cmd" in
    --remove)
      pkg="$1"; shift || fail "--remove requer um pacote"
      dry="${UNINSTALL_DRYRUN:-false}"
      # allow explicit --dry-run arg
      while [[ "${1:-}" == "--dry-run" ]]; do dry=true; shift || break; done
      uninstall_package "$pkg" "$dry"
      _release_global_lock
      exit $?
      ;;
    --remove-list)
      file="$1"; shift || fail "--remove-list requer um arquivo"
      dry="${UNINSTALL_DRYRUN:-false}"
      while [[ "${1:-}" == "--dry-run" ]]; do dry=true; shift || break; done
      if [[ ! -f "$file" ]]; then fail "Arquivo não encontrado: $file"; fi
      while IFS= read -r p || [[ -n "$p" ]]; do
        [[ -z "$p" ]] && continue
        uninstall_package "$p" "$dry" || log WARN "Falha ao remover $p (continuando)"
      done < "$file"
      _release_global_lock
      exit 0
      ;;
    --orphans)
      list_orphans
      _release_global_lock
      exit 0
      ;;
    --clean-orphans)
      mode="${1:-dry-run}"; shift || true
      if [[ "$mode" == "auto" ]]; then
        clean_orphans "auto"
      else
        clean_orphans "dry-run"
      fi
      _release_global_lock
      exit 0
      ;;
    --help|-h)
      _print_usage
      _release_global_lock
      exit 0
      ;;
    *)
      _print_usage
      _release_global_lock
      exit 2
      ;;
  esac
fi

# -----------------------
# Expose functions for sourcing
# -----------------------
export -f db_load db_save list_files_of_pkg pkg_filelist_path uninstall_package \
  list_orphans clean_orphans run_uninstall_hooks check_reverse_deps
