#!/usr/bin/env bash
# utils.sh - core utilities for lfsctl
set -eEuo pipefail
IFS=$'\n\t'

: "${LFS:=/mnt/lfs}"
: "${META_ROOT:=$HOME/lfs-sandbox/meta}"
: "${SOURCES_DIR:=$LFS/sources}"
: "${LOG_DIR:=/var/log/lfsctl}"
: "${GLOBAL_LOGFILE:=$LOG_DIR/utils-20251020T213050Z.log}"
: "${DRY_RUN:=false}"
: "${VERBOSE:=false}"

mkdir -p "$LOG_DIR" "$META_ROOT" "$SOURCES_DIR" || true
# load logging if present
if [ -f "$(dirname "$0")/log.sh" ]; then source "$(dirname "$0")/log.sh"; fi

timestamp(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
die(){ log_error "$*"; exit ${2:-1}; }

# INI parser (basic)
declare -A META
parse_ini(){ local file="$1"; META=(); local sec=""; while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%[#;]*}"; line="${line#${line%%[![:space:]]*}}"; line="${line%${line##*[![:space:]]}}"
  [ -z "$line" ] && continue
  if [[ "$line" =~ ^\[(.+)\]$ ]]; then sec="${BASH_REMATCH[1]}"; continue; fi
  if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then local key="${BASH_REMATCH[1]}"; key="${key,,}"; key="${key// /_}"; META["${sec}.${key}"]="${BASH_REMATCH[2]}"; fi
done < "$file"; }

ini_get(){ local sec="$1" key="$2" def="${3:-}"; printf "%s" "${META[${sec}.${key}]:-$def}"; }

ensure_dir(){ local d="$1"; case "$d" in "$LFS"*|"$META_ROOT"*|/*) : ;; *) die "Refusing to create dir outside allowed prefixes: $d" 2;; esac
  if [ "$DRY_RUN" = true ]; then log_info "DRY-RUN: mkdir -p $d"; return 0; fi
  mkdir -p "$d"
}

sha256_of(){ if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else die "sha256sum required" 2; fi }

download(){ local url="$1" outdir="$2"; ensure_dir "$outdir"; local fname="$(basename "$url" | sed 's/?.*$//')"; local out="$outdir/$fname"
  if [ -f "$out" ]; then log_info "Already have $out"; return 0; fi
  if [ "$DRY_RUN" = true ]; then log_info "DRY-RUN download $url -> $out"; return 0; fi
  if [[ "$url" =~ ^git(@|://) ]] || [[ "$url" =~ \.git$ ]]; then
    command -v git >/dev/null 2>&1 || die "git required to clone $url" 3
    git clone --depth=1 "$url" "$outdir/$(basename "$url" .git)" || die "git clone failed" 3
  else
    if command -v curl >/dev/null 2>&1; then curl -L --fail --retry 4 -o "$out" "$url" || die "curl failed $url" 3
    elif command -v wget >/dev/null 2>&1; then wget -O "$out" "$url" || die "wget failed $url" 3
    else die "No HTTP client available" 3; fi
  fi
  log_info "Downloaded: $url -> $out"
}

download_from_meta(){ local meta="$1" dest="$2"; parse_ini "$meta"; local urls="$(ini_get source url)"; [ -z "$urls" ] && die "No source.url in $meta" 4
  IFS=',' read -r -a arr <<< "$urls"; for u in "${arr[@]}"; do u="${u//[[:space:]]/}"; [ -z "$u" ] && continue; download "$u" "$dest"; done; }

run_hooks(){ local pkgdir="$1" stage="$2" ignore=false; shift 2; for a in "$@"; do [ "$a" = --ignore-errors ] && ignore=true; done
  local hd="$pkgdir/hooks/$stage"; [ ! -d "$hd" ] && return 0
  for h in "$hd"/*; do [ -f "$h" ] || continue; log_info "hook: $h"; if [ "$DRY_RUN" = true ]; then log_info "DRY-RUN hook $h"; continue; fi; timeout 120 bash "$h" >> "$GLOBAL_LOGFILE" 2>&1 || { if [ "$ignore" = true ]; then log_warn "ignored hook failure $h"; else die "Hook failed: $h" 5; fi; }; done; }

verify_checksum(){ local file="$1" expected="$2"; if [ ! -f "$file" ]; then log_warn "no file $file"; return 2; fi; local got; got="$(sha256_of "$file")"; if [ "$got" != "$expected" ]; then log_warn "checksum mismatch for $file"; return 1; fi; log_info "checksum ok $file"; return 0; }

create_meta(){ local pkgdir="$1" name="$2" ver="$3" url="$4" sha="$5" deps="$6"; ensure_dir "$pkgdir"; cat > "$pkgdir/$(basename "$pkgdir").ini" <<EOF
[meta]
name=$name
version=$ver

[source]
url=$url
sha256=$sha

[deps]
depends=$deps
EOF
log_info "meta created $pkgdir"
}
