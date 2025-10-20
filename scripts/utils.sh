#!/usr/bin/env bash
# utils.sh - Utility library for LFS rolling system (from earlier)
set -eEuo pipefail
IFS=$'\n\t'
: "${LFS:=/mnt/lfs}"
: "${META_ROOT:=$HOME/lfs-sandbox/meta}"
: "${SOURCES_DIR:=$LFS/sources}"
: "${LOG_DIR:=/var/log/lfs-utils}"
: "${REQUIRE_CHECKSUM:=false}"
: "${DRY_RUN:=false}"
: "${VERBOSE:=false}"
: "${GLOBAL_LOGFILE:=$LOG_DIR/utils-$(date -u +%Y%m%dT%H%M%SZ).log}"
mkdir -p "$LOG_DIR" "$META_ROOT" "$SOURCES_DIR" || true
_log(){ local lvl="$1"; shift; printf "[%s] %s %s\n" "$lvl" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$GLOBAL_LOGFILE"; }
log_info(){ _log INFO "$*"; }
log_warn(){ _log WARN "$*"; }
log_error(){ _log ERROR "$*"; }
declare -A META
parse_ini(){
  local file="$1"; META=(); local section=""; while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%[#;]*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"; [ -z "$line" ] && continue
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then section="${BASH_REMATCH[1]}"; continue; fi
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      local key="$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' )"
      local val="${BASH_REMATCH[2]}"
      META["${section}.${key}"]="$val"
    fi
  done < "$file"
}
ini_get(){ local sec="$1" key="$2" default="${3:-}"; printf "%s" "${META[${sec}.${key}]:-$default}"; }
ensure_dir(){ local d="$1"; if [[ "$d" != "$LFS"* && "$d" != "$META_ROOT"* && "$d" != /* ]]; then log_error "Refusing to create dir outside allowed prefixes: $d"; return 2; fi; mkdir -p "$d"; }
sha256_file(){ if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else log_warn "sha256sum missing"; return 2; fi }
download_source(){
  local url="$1" dest="$2"; ensure_dir "$dest"; if [[ "$url" =~ ^git(@|://) ]] || [[ "$url" =~ \.git$ ]]; then
    if [ "$DRY_RUN" = true ]; then log_info "DRY-RUN git clone $url -> $dest"; return 0; fi
    git clone --depth=1 "$url" "$dest" || { log_error "git clone failed $url"; return 4; }
  else
    local fname="$(basename "$url" | sed 's/?.*$//')"; local out="$dest/$fname"; if [ -f "$out" ]; then log_info "Already downloaded $out"; return 0; fi
    if [ "$DRY_RUN" = true ]; then log_info "DRY-RUN curl $url -> $out"; return 0; fi
    if command -v curl >/dev/null 2>&1; then curl -L --fail --retry 4 -o "$out" "$url" || { log_error "curl failed $url"; return 3; }
    else wget -O "$out" "$url" || { log_error "wget failed $url"; return 3; }; fi
    log_info "Downloaded $out"
  fi
}
download_sources_from_meta(){ local meta="$1" dest="$2"; parse_ini "$meta"; local urls="$(ini_get source url)"; if [ -z "$urls" ]; then log_warn "No source.url in $meta"; return 1; fi; IFS=',' read -r -a arr <<< "$urls"; for u in "${arr[@]}"; do u="$(echo "$u" | xargs)"; [ -z "$u" ] && continue; download_source "$u" "$dest" || return 1; done; return 0; }
verify_checksum(){ local file="$1" expected="$2"; if [ ! -f "$file" ]; then log_error "File missing $file"; return 2; fi; local got; got="$(sha256_file "$file")"; if [ "$got" != "$expected" ]; then log_warn "Checksum mismatch $file expected $expected got $got"; return 1; fi; log_info "Checksum OK $file"; return 0; }
run_hooks_for(){ local pkgdir="$1" stage="$2" ignore=false; for a in "$@"; do [ "$a" = "--ignore-errors" ] && ignore=true; done; local hooksdir="$pkgdir/hooks/$stage"; [ ! -d "$hooksdir" ] && return 0; for h in "$hooksdir"/*; do [ -f "$h" ] || continue; log_info "Running hook $h"; if [ "$DRY_RUN" = true ]; then log_info "DRY-RUN hook $h"; continue; fi; if ! timeout 120 bash "$h" >> "$GLOBAL_LOGFILE" 2>&1; then log_error "Hook failed $h"; if [ "$ignore" = true ]; then log_warn "Ignoring hook failure"; else return 1; fi; fi; done; }
create_package_skeleton(){ local category="$1" pkg="$2"; local base="$META_ROOT/$category"; local pkgdir="$base/$pkg"; ensure_dir "$base"; if [ -d "$pkgdir" ]; then log_warn "Package dir exists $pkgdir"; else mkdir -p "$pkgdir"; fi; local meta_file="$pkgdir/$pkg.ini"; if [ ! -f "$meta_file" ]; then cat > "$meta_file" <<'EOF'\n[meta]\nname=REPLACE_ME\nversion=0.0.0\n\n[source]\nurl=\nsha256=\n\n[deps]\ndepends=\n\n[build]\ncheck=true\ndirectory=base\nbootstrap=true\n\n[hooks]\npre_build=hooks/pre_build\npost_build=hooks/post_build\n\n[environment]\nenv=\nEOF\n log_info "Created $meta_file"; else log_info "Metafile exists $meta_file"; fi; echo "$pkgdir"; }
