#!/usr/bin/env bash
# metadata.sh - INI parser, patches and hooks handling
if [ -n "${METADATA_SH_LOADED-}" ]; then return 0 2>/dev/null || exit 0; fi
METADATA_SH_LOADED=1
# Simple INI parser supporting section.key and repeated key[] entries
declare -A META_STORE
metadata_load() {
  local file="$1"
  [ -f "$file" ] || return 2
  META_STORE=()
  local section=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#"${line%%[![:space:]]*}"}"
    [ -z "$line" ] && continue
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"
      key="${key%"${key##*[![:space:]]}"}"
      val="${val#"${val%%[![:space:]]*}"}"
      if [[ "$key" == *"[]" ]]; then
        key="${key%\[\]}"
        META_STORE["${section}.${key}"]+=$'\n'"$val"
      else
        META_STORE["${section}.${key}"]="$val"
      fi
    fi
  done < "$file"
  META_STORE[".file"]="$file"
  return 0
}
metadata_get() { local k="$1"; echo "${META_STORE[$k]:-}"; }

metadata_apply_patches() {
  local srcdir="$1"
  local pdir="${META_STORE[patches.dir]:-${srcdir}/patches}"
  [ -d "$pdir" ] || return 0
  local logfile="${srcdir}/.patches.log"
  local applied=0
  for p in "$pdir"/*; do
    [ -f "$p" ] || continue
    if _apply_patch "$srcdir" "$p" "$logfile"; then applied=$((applied+1)); fi
  done
  return 0
}

_apply_patch() {
  local src="$1" patch="$2" log="$3"
  echo "Applying patch $patch" >> "$log"
  # try git apply
  (cd "$src" && git apply --whitespace=nowarn "$patch") >>"$log" 2>&1 && return 0
  (cd "$src" && patch -p1 < "$patch") >>"$log" 2>&1 && return 0
  (cd "$src" && patch -p0 < "$patch") >>"$log" 2>&1 && return 0
  echo "Patch $patch failed" >> "$log"
  return 1
}

metadata_run_hook() {
  local hook="$1"; local srcdir="${2:-.}"
  local hdir="${META_STORE[hooks.dir]:-${srcdir}/hooks}"
  [ -d "$hdir" ] || return 0
  for s in "$hdir"/${hook}*; do
    [ -f "$s" ] || continue
    timeout 300 bash -e "$s" >/dev/null 2>&1 || echo "hook $s failed" >> "${srcdir}/.hooks.log"
  done
  return 0
}
