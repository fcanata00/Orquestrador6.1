#!/usr/bin/env bash
# commit.sh - Automated SVN commit helper for LFS project
# Version: 1.0
# Features:
#  - init a working copy and remote repo config
#  - add/commit/remove files automatically with descriptive messages
#  - push (svn commit to remote), branch, tag, revert, diff, audit
#  - dry-run, silent mode, retries, exponential backoff
#  - integration hooks for other scripts (build.sh, update.sh, etc.)
#  - robust error handling and clear logs
set -Eeuo pipefail
IFS=$'\n\t'

# ------------- Configuration -------------
: "${REPO_URL:=}"                 # remote SVN repo (required for some ops)
: "${WC_DIR:=./lfs_wc}"           # working copy directory
: "${SVN_BIN:=$(command -v svn || true)}"
: "${LOG_DIR:=/var/log/lfs/commit}"
: "${STATE_DIR:=/var/lib/lfs/commit}"
: "${LOCKFILE:=/var/lock/lfs_commit.lock}"
: "${RETRIES:=3}"
: "${SILENT:=false}"
: "${DRYRUN:=false}"
: "${AUTHOR:=$(whoami)}"
export REPO_URL WC_DIR SVN_BIN LOG_DIR STATE_DIR LOCKFILE RETRIES SILENT DRYRUN AUTHOR

_safe_mkdir(){ mkdir -p "$@" 2>/dev/null || true; }
_safe_mkdir "$LOG_DIR" "$STATE_DIR"

# logging helpers (tries to use log.sh if present)
LOG_API=false
if [ -f /usr/bin/logs.sh ]; then
  # shellcheck source=/dev/null
  source /usr/bin/logs.sh || true
  LOG_API=true
fi
_cmt_log(){ if [ "$LOG_API" = true ] && type log_info >/dev/null 2>&1; then log_info "$@"; elif [ "$SILENT" != "true" ]; then printf "[COMMIT][INFO] %s\n" "$@"; fi }
_cmt_warn(){ if [ "$LOG_API" = true ] && type log_warn >/dev/null 2>&1; then log_warn "$@"; elif [ "$SILENT" != "true" ]; then printf "[COMMIT][WARN] %s\n" "$@"; fi }
_cmt_error(){ if [ "$LOG_API" = true ] && type log_error >/dev/null 2>&1; then log_error "$@"; elif [ "$SILENT" != "true" ]; then printf "[COMMIT][ERROR] %s\n" "$@" >&2; fi; if [ "${DRYRUN}" = "true" ]; then return 1; fi; exit 1; }

_acquire_lock(){
  exec 201>"$LOCKFILE"
  flock -n 201 || { _cmt_error "Another commit operation is running (lockfile: $LOCKFILE)"; return 1; }
  printf "%s\n" "$$" >&201
  return 0
}
_release_lock(){ exec 201>&- || true; }

# helper: run svn command with retries and backoff
_svn_run(){
  local tries=0
  local max="${RETRIES:-3}"
  local delay=1
  local cmd=( "$@" )
  if [ -z "$SVN_BIN" ]; then _cmt_error "svn binary not found in PATH"; return 2; fi
  while [ $tries -lt "$max" ]; do
    if "${cmd[@]}"; then return 0; fi
    tries=$((tries+1))
    sleep $delay
    delay=$((delay * 2))
  done
  return 1
}

# validate working copy exists or checkout
_wc_ensure(){
  if [ ! -d "$WC_DIR/.svn" ]; then
    if [ -z "$REPO_URL" ]; then _cmt_error "No working copy and REPO_URL not set"; return 2; fi
    if [ "$DRYRUN" = "true" ]; then _cmt_log "[DRYRUN] Would checkout $REPO_URL -> $WC_DIR"; return 0; fi
    _cmt_log "Checking out $REPO_URL -> $WC_DIR"
    _svn_run "$SVN_BIN" checkout "$REPO_URL" "$WC_DIR" || { _cmt_error "svn checkout failed"; return 1; }
  fi
  return 0
}

# create repo layout in WC if requested (trunk/branches/tags)
_init_repo_layout(){
  local repo="$1"
  if [ -z "$repo" ]; then _cmt_error "repo url required"; fi
  if [ "$DRYRUN" = "true" ]; then _cmt_log "[DRYRUN] Would create standard layout at $repo (trunk branches tags)"; return 0; fi
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/trunk" "$tmpdir/branches" "$tmpdir/tags"
  _svn_run "$SVN_BIN" import -m "Init layout" "$tmpdir" "$repo" || { rm -rf "$tmpdir"; _cmt_error "svn import failed"; return 1; }
  rm -rf "$tmpdir"
  _cmt_log "Repository layout created at $repo"
  return 0
}

# add files (supports globs), with message and optional author
commit_add(){
  local msg="$1"; shift || true
  local files=( "$@" )
  if [ "${#files[@]}" -eq 0 ]; then _cmt_error "commit_add requires message and at least one file"; fi
  _wc_ensure || return 1
  pushd "$WC_DIR" >/dev/null 2>&1
  for f in "${files[@]}"; do
    if [ -e "$f" ]; then
      if [ "$DRYRUN" = "true" ]; then _cmt_log "[DRYRUN] svn add $f"; else _svn_run "$SVN_BIN" add --force "$f" || _cmt_warn "svn add failed for $f"; fi
    else
      _cmt_warn "File not found: $f"
    fi
  done
  if [ "$DRYRUN" = "true" ]; then _cmt_log "[DRYRUN] Would commit with message: $msg"; popd >/dev/null 2>&1; return 0; fi
  _svn_run "$SVN_BIN" commit -m "$msg" --username "$AUTHOR" || { _cmt_warn "Commit returned non-zero"; popd >/dev/null 2>&1; return 1; }
  popd >/dev/null 2>&1
  return 0
}

# remove files from repo & commit
commit_remove(){
  local msg="$1"; shift || true
  local files=( "$@" )
  if [ "${#files[@]}" -eq 0 ]; then _cmt_error "commit_remove requires message and at least one file"; fi
  _wc_ensure || return 1
  pushd "$WC_DIR" >/dev/null 2>&1
  for f in "${files[@]}"; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      if [ "$DRYRUN" = "true" ]; then _cmt_log "[DRYRUN] svn rm $f"; else _svn_run "$SVN_BIN" rm --force "$f" || _cmt_warn "svn rm failed for $f"; fi
    else
      _cmt_warn "File not present: $f"
    fi
  done
  if [ "$DRYRUN" = "true" ]; then _cmt_log "[DRYRUN] Would commit removal: $msg"; popd >/dev/null 2>&1; return 0; fi
  _svn_run "$SVN_BIN" commit -m "$msg" --username "$AUTHOR" || { _cmt_warn "Commit failed"; popd >/dev/null 2>&1; return 1; }
  popd >/dev/null 2>&1
  return 0
}

# commit changes in working copy with message
commit_all(){
  local msg="${1:-Auto commit}"
  _wc_ensure || return 1
  pushd "$WC_DIR" >/dev/null 2>&1
  # status and detect modified/new/deleted
  local status
  status=$("$SVN_BIN" status --no-ignore) || true
  if [ -z "$status" ]; then _cmt_log "No changes to commit"; popd >/dev/null 2>&1; return 0; fi
  if [ "$DRYRUN" = "true" ]; then _cmt_log "[DRYRUN] svn status output:"; echo "$status"; _cmt_log "[DRYRUN] Would commit with message: $msg"; popd >/dev/null 2>&1; return 0; fi
  # add unknown files automatically
  echo "$status" | awk '/^\?/ {print $2}' | while IFS= read -r nf; do
    [ -n "$nf" ] && _svn_run "$SVN_BIN" add --force "$nf" || _cmt_warn "svn add failed for $nf"
  done
  # commit
  _svn_run "$SVN_BIN" commit -m "$msg" --username "$AUTHOR" || { _cmt_error "svn commit failed"; popd >/dev/null 2>&1; return 1; }
  popd >/dev/null 2>&1
  return 0
}

# show diff
commit_diff(){
  _wc_ensure || return 1
  pushd "$WC_DIR" >/dev/null 2>&1
  "$SVN_BIN" diff || true
  popd >/dev/null 2>&1
}

# create branch (svn copy trunk -> branches/name)
commit_branch(){
  local branch_name="$1"
  if [ -z "$branch_name" ]; then _cmt_error "branch name required"; fi
  if [ -z "$REPO_URL" ]; then _cmt_error "REPO_URL not configured"; fi
  local branches_url="${REPO_URL%/}/branches/${branch_name}"
  if [ "$DRYRUN" = "true" ]; then _cmt_log "[DRYRUN] Would create branch $branches_url"; return 0; fi
  _svn_run "$SVN_BIN" copy "${REPO_URL%/}/trunk" "$branches_url" -m "Create branch ${branch_name}" --username "$AUTHOR" || { _cmt_error "Failed to create branch"; return 1; }
  _cmt_log "Branch created: $branches_url"
  return 0
}

# create tag (svn copy trunk -> tags/name)
commit_tag(){
  local tag_name="$1"
  if [ -z "$tag_name" ]; then _cmt_error "tag name required"; fi
  if [ -z "$REPO_URL" ]; then _cmt_error "REPO_URL not configured"; fi
  local tags_url="${REPO_URL%/}/tags/${tag_name}"
  if [ "$DRYRUN" = "true" ]; then _cmt_log "[DRYRUN] Would create tag $tags_url"; return 0; fi
  _svn_run "$SVN_BIN" copy "${REPO_URL%/}/trunk" "$tags_url" -m "Create tag ${tag_name}" --username "$AUTHOR" || { _cmt_error "Failed to create tag"; return 1; }
  _cmt_log "Tag created: $tags_url"
  return 0
}

# revert to revision
commit_revert(){
  local rev="$1"
  if [ -z "$rev" ]; then _cmt_error "revision required"; fi
  _wc_ensure || return 1
  pushd "$WC_DIR" >/dev/null 2>&1
  if [ "$DRYRUN" = "true" ]; then _cmt_log "[DRYRUN] Would revert to r$rev"; popd >/dev/null 2>&1; return 0; fi
  _svn_run "$SVN_BIN" update -r "$rev" || { _cmt_error "svn update -r $rev failed"; popd >/dev/null 2>&1; return 1; }
  _cmt_log "Reverted working copy to r$rev"
  popd >/dev/null 2>&1
  return 0
}

# audit: generate JSON summary of changes since last commit
commit_audit(){
  _wc_ensure || return 1
  pushd "$WC_DIR" >/dev/null 2>&1
  local out="${LOG_DIR}/commit_audit_$(date -u +%Y%m%dT%H%M%SZ).json"
  echo "{\"timestamp\":\"$(date -u +%FT%TZ)\",\"changes\":[" > "$out"
  local first=true
  # parse svn status
  "$SVN_BIN" status --no-ignore | while IFS= read -r line; do
    local code=$(echo "$line" | awk '{print $1}')
    local file=$(echo "$line" | awk '{print $2}')
    if [ "$first" = true ]; then first=false; else echo "," >> "$out"; fi
    # ensure json escaping
    printf '{"code":"%s","file":"%s"}' "$code" "$(printf "%s" "$file" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' )" >> "$out"
  done
  echo "]}" >> "$out"
  _cmt_log "Audit written to $out"
  popd >/dev/null 2>&1
  return 0
}

# helper: secure storage of credentials (uses gpg if available)
_commit_store_creds(){
  local user="$1"; local token="$2"
  local cfg="${STATE_DIR}/svn_auth.gpg"
  if command -v gpg >/dev/null 2>&1; then
    printf "%s\n%s\n" "$user" "$token" | gpg --symmetric --batch --yes -o "$cfg" || _cmt_warn "gpg store failed"
    chmod 600 "$cfg"
    _cmt_log "Stored SVN credentials encrypted at $cfg"
  else
    printf "%s\n%s\n" "$user" "$token" > "${STATE_DIR}/svn_auth" || _cmt_warn "plain store failed"
    chmod 600 "${STATE_DIR}/svn_auth"
    _cmt_warn "gpg not available; credentials stored in plain text at ${STATE_DIR}/svn_auth"
  fi
}

# helper: load stored creds
_commit_load_creds(){
  local cfg="${STATE_DIR}/svn_auth.gpg"
  if [ -f "$cfg" ] && command -v gpg >/dev/null 2>&1; then
    gpg --quiet --batch --yes -o - "$cfg" 2>/dev/null || true
  elif [ -f "${STATE_DIR}/svn_auth" ]; then
    cat "${STATE_DIR}/svn_auth" 2>/dev/null || true
  fi
}

# usage
_usage(){
  cat <<EOF
commit.sh - SVN automation for LFS

Usage:
  commit.sh --init --repo-url <url>         # create repo layout (trunk/branches/tags)
  commit.sh --checkout --repo-url <url>     # checkout repo to WC_DIR
  commit.sh --add "message" <files...>      # add files and commit
  commit.sh --remove "message" <files...>   # remove files and commit
  commit.sh --commit "message"              # commit all local changes
  commit.sh --diff                           # show svn diff
  commit.sh --branch <name>                 # create branch
  commit.sh --tag <name>                    # create tag
  commit.sh --revert <revision>             # revert working copy to revision
  commit.sh --audit                         # generate audit JSON
  commit.sh --store-creds <user> <token>    # store credentials (gpg if available)
  Global flags:
    --wc <path>       (change working copy path)
    --repo <url>      (change repo url)
    --dry-run         (simulate operations)
    --silent          (suppress console output)
    --retries N       (set retries for network ops)
EOF
}

# dispatcher
if [ "${BASH_SOURCE[0]}" == "$0" ]; then
  if [ "$#" -eq 0 ]; then _usage; exit 2; fi
  # parse common options
  while [ $# -gt 0 ]; do
    case "$1" in
      --wc) WC_DIR="$2"; shift 2;;
      --repo) REPO_URL="$2"; shift 2;;
      --dry-run) DRYRUN="true"; shift;;
      --silent) SILENT="true"; shift;;
      --retries) RETRIES="$2"; shift 2;;
      --init) shift; _init_repo_layout "$REPO_URL"; exit $?;;
      --checkout) shift; REPO_URL="${REPO_URL:-$1}"; _wc_ensure || exit 1; _wc_ensure; exit $?;;
      --add) shift; msg="$1"; shift; commit_add "$msg" "$@"; exit $?;;
      --remove) shift; msg="$1"; shift; commit_remove "$msg" "$@"; exit $?;;
      --commit) shift; msg="${1:-Auto commit}"; commit_all "$msg"; exit $?;;
      --diff) shift; commit_diff; exit $?;;
      --branch) shift; commit_branch "$1"; exit $?;;
      --tag) shift; commit_tag "$1"; exit $?;;
      --revert) shift; commit_revert "$1"; exit $?;;
      --audit) shift; commit_audit; exit $?;;
      --store-creds) shift; _commit_store_creds "$1" "$2"; exit $?;;
      --help|-h|help) _usage; exit 0;;
      *) _usage; exit 2;;
    esac
  done
fi

# export functions for external use
export -f commit_add commit_remove commit_all commit_diff commit_branch commit_tag commit_revert commit_audit _commit_store_creds
