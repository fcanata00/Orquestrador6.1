#!/usr/bin/env bash
# create_diff.sh - Sistema de geração e comparação de diffs completo
# Integração com todo o ecossistema LFS automatizado (build.sh, update.sh, doctor.sh, commit.sh, etc.)

set -euo pipefail

DIFF_CACHE="/var/cache/lfs/diffs"
LOG_FILE="/var/log/lfs/diff.log"
mkdir -p "$(dirname "$LOG_FILE")" "$DIFF_CACHE"

log() {
  local msg="$1"
  echo "[create_diff] $msg" | tee -a "$LOG_FILE"
}

error() {
  local msg="$1"
  echo "[ERRO] $msg" | tee -a "$LOG_FILE" >&2
}

diff_init() {
  mkdir -p "$DIFF_CACHE"
  log "Ambiente de diff inicializado em $DIFF_CACHE"
}

diff_files() {
  local f1="$1" f2="$2"
  [[ -f "$f1" && -f "$f2" ]] || { error "Arquivos inválidos: $f1, $f2"; return 1; }
  diff -u "$f1" "$f2" > "$DIFF_CACHE/$(basename "$f1")_vs_$(basename "$f2").diff" || true
  log "Diff entre $f1 e $f2 criado."
}

diff_dirs() {
  local d1="$1" d2="$2"
  [[ -d "$d1" && -d "$d2" ]] || { error "Diretórios inválidos: $d1, $d2"; return 1; }
  diff -ruN "$d1" "$d2" | grep -vE '(^Only in|\.cache|\.log)' > "$DIFF_CACHE/dir_diff_$(date +%s).diff" || true
  log "Diff entre diretórios $d1 e $d2 criado."
}

diff_metafile() {
  local m1="$1" m2="$2"
  [[ -f "$m1" && -f "$m2" ]] || { error "Metafiles inválidos: $m1, $m2"; return 1; }
  diff -u "$m1" "$m2" > "$DIFF_CACHE/$(basename "$m1")_vs_$(basename "$m2").diff" || true
  log "Diff entre metafiles $m1 e $m2 criado."
}

diff_stage() {
  local s1="$1" s2="$2"
  local d1="/mnt/lfs/$s1" d2="/mnt/lfs/$s2"
  [[ -d "$d1" && -d "$d2" ]] || { error "Stage inválido: $s1, $s2"; return 1; }
  diff -ruN "$d1" "$d2" | grep -vE '(cache|tmp|log)' > "$DIFF_CACHE/stage_${s1}_vs_${s2}.diff" || true
  log "Diff entre stages $s1 e $s2 criado."
}

diff_apply() {
  local patchfile="$1"
  [[ -f "$patchfile" ]] || { error "Patch não encontrado: $patchfile"; return 1; }
  patch -p1 < "$patchfile" || error "Falha ao aplicar patch $patchfile"
}

diff_report() {
  local format="${1:-text}"
  case "$format" in
    text) cat "$LOG_FILE";;
    json) jq -R -s '.' "$LOG_FILE";;
    html) echo "<pre>$(cat "$LOG_FILE")</pre>";;
    *) error "Formato desconhecido: $format"; return 1;;
  esac
}

diff_clean() {
  find "$DIFF_CACHE" -type f -mtime +7 -delete
  log "Limpeza de diffs antigos concluída."
}

# CLI handler
case "${1:-}" in
  --files) diff_files "$2" "$3" ;;
  --dirs) diff_dirs "$2" "$3" ;;
  --metafile) diff_metafile "$2" "$3" ;;
  --stage) diff_stage "$2" "$3" ;;
  --apply) diff_apply "$2" ;;
  --report) diff_report "${2:-text}" ;;
  --ini) diff_init ;;
  --clean) diff_clean ;;
  *) echo "Uso: create_diff.sh [--files f1 f2 | --dirs d1 d2 | --metafile m1 m2 | --stage s1 s2 | --apply patch | --report formato | --ini | --clean]";;
esac
