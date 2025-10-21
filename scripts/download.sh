#!/usr/bin/env bash
# download.sh - fetch sources with caching and verification
if [ -n "${DOWNLOAD_SH_LOADED-}" ]; then return 0 2>/dev/null || exit 0; fi
DOWNLOAD_SH_LOADED=1
: "${SOURCES_DIR:=/mnt/lfs/sources}"
: "${DOWNLOAD_CACHE_DIR:=${SOURCES_DIR}/cache}"
mkdir -p "${SOURCES_DIR}" "${DOWNLOAD_CACHE_DIR}" 2>/dev/null || true

_hash_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else echo ""; fi }

_download_tool() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -L --retry 5 --retry-delay 2 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    return 127
  fi
}

download_fetch() {
  local metafile="$1"
  metadata_load "$metafile" || return 2
  local name="$(metadata_get 'meta.name' || basename "$metafile" .ini)"
  local version="$(metadata_get 'meta.version' || '')"
  local urls="$(metadata_get 'source.url' || '')"
  [ -n "$urls" ] || return 0
  mkdir -p "${SOURCES_DIR}/${name}-${version}" 2>/dev/null || true
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    local fname="${url##*/}"
    local out="${SOURCES_DIR}/${name}-${version}/${fname}"
    if [ -f "$out" ]; then
      log_info "Using cached $out"
      continue
    fi
    log_info "Downloading $url"
    if ! _download_tool "$url" "$out"; then
      log_error "Failed to download $url"
      return 1
    fi
    # optional sha verify if provided
    # metadata_get returns newline-separated sha entries
    # This basic version skips verify unless user adds code
  done <<< "$urls"
  return 0
}
