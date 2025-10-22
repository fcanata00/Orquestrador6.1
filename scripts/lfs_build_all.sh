#!/usr/bin/env bash
# lfs_build_all.sh - Orquestrador para construir LFS (stage1, stage2, stage3)
# Versão: 1.0
set -Eeuo pipefail
IFS=$'\n\t'

: "${LFS:=/mnt/lfs}"
: "${LOG_DIR:=${LFS}/var/log/lfs}"
: "${METAFILE_DIR:=${LFS}/usr/src}"
: "${BINPKG:=/usr/bin/binpkg}"

export LFS LOG_DIR METAFILE_DIR BINPKG

mkdir -p "$LOG_DIR" "$METAFILE_DIR" || true

_info(){ printf "[lfs-build] %s\n" "$*"; printf "%s %s\n" "$(date -u +%FT%TZ)" "$*" >> "${LOG_DIR}/lfs_build.log"; }
_warn(){ printf "[lfs-build][WARN] %s\n" "$*"; printf "%s WARN %s\n" "$(date -u +%FT%TZ)" "$*" >> "${LOG_DIR}/lfs_build.log"; }
_err(){ printf "[lfs-build][ERROR] %s\n" "$*" >&2; printf "%s ERROR %s\n" "$(date -u +%FT%TZ)" "$*" >> "${LOG_DIR}/lfs_build.log"; exit 1; }

trap 'rc=$?; if [ $rc -ne 0 ]; then _err "Exiting with code $rc"; fi' EXIT

_check_deps(){
  local deps=(bash awk grep sed tar xz zstd curl wget chroot sudo jq ldd readelf)
  local miss=()
  for d in "${deps[@]}"; do
    if ! command -v "$d" >/dev/null 2>&1; then miss+=("$d"); fi
  done
  if [ ${#miss[@]} -gt 0 ]; then
    _warn "Dependências ausentes: ${miss[*]}. Alguns checks/funções podem falhar."
  fi
}

init_environment(){
  _info "Inicializando ambiente LFS em $LFS"
  mkdir -p "$LFS" "$LOG_DIR" "$METAFILE_DIR" || true
  for m in dev proc sys run; do
    if ! mountpoint -q "$LFS/$m"; then _warn "$LFS/$m não montado. Bootstrap poderá requerer montagem manual."
    fi
  done
  if ! id -u lfs >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1; then
      _info "Tentando criar usuário 'lfs' (requer sudo)"
      sudo useradd -m -s /bin/bash lfs || _warn "Não foi possível criar usuário lfs (permissão)"
    else
      _warn "sudo não encontrado; pule criação do usuário lfs"
    fi
  fi
  if command -v bootstrap.sh >/dev/null 2>&1; then
    bootstrap.sh --ini || _warn "bootstrap.sh --ini falhou (continuando)"
  fi
  _check_deps
}

_resolve_order(){
  local stage="$1"
  if command -v deps.sh >/dev/null 2>&1 && type deps_resolve_order >/dev/null 2>&1; then
    deps_resolve_order "$stage"
    return 0
  fi
  local dir="$METAFILE_DIR/$stage"
  if [ -d "$dir" ]; then
    for f in "$dir"/*.ini; do [ -f "$f" ] && basename "$(dirname "$f")"; done
  else
    _warn "Diretório de metafiles $dir não encontrado; listagem fallback vazia"
  fi
}

_build_pkg(){
  local pkg="$1"
  _info "Construindo pacote: $pkg"
  local start=$(date +%s)
  if [ -x "$BINPKG" ]; then
    if ! "$BINPKG" build pkg "$pkg"; then
      _err "Falha no build de $pkg. Checar logs em $LOG_DIR"
      return 1
    fi
  elif command -v build.sh >/dev/null 2>&1; then
    build.sh --pkg "$pkg" || { _err "build.sh falhou para $pkg"; }
  else
    _warn "Nenhum runner de build encontrado (binpkg/build.sh). Pulando $pkg."
  fi
  local end=$(date +%s)
  _info "Concluído $pkg (tempo: $((end-start))s)"
  return 0
}

build_stage1(){
  _info "Iniciando Stage 1 (toolchain temporário)"
  local pkgs; pkgs=$(_resolve_order "stage1" || true)
  if [ -z "$pkgs" ]; then _warn "Nenhum pacote listado para stage1"; return 0; fi
  local total=$(echo "$pkgs" | wc -w)
  local n=0
  for pkg in $pkgs; do
    n=$((n+1))
    printf "\n[STAGE1] (%d/%d) %s\n" "$n" "$total" "$pkg"
    if ! _build_pkg "$pkg"; then _err "Construção interrompida no pacote $pkg (veja logs)"; fi
  done
  _info "Stage 1 concluído"
}

enter_chroot(){
  _info "Preparando chroot em $LFS"
  for m in dev proc sys run; do
    if ! mountpoint -q "$LFS/$m"; then
      if [ "$EUID" -ne 0 ]; then _warn "Montagem de $m requer root; pule ou monte manualmente"; else
        mkdir -p "$LFS/$m"; mount --bind "/$m" "$LFS/$m" || _warn "mount --bind /$m -> $LFS/$m falhou"
      fi
    fi
  done
  if [ "$EUID" -ne 0 ]; then
    _warn "Entrar em chroot requer root; execute manualmente:\n  sudo chroot \"$LFS\" /usr/bin/env -i HOME=/root TERM=\"$TERM\" PATH=/usr/bin:/bin /bin/bash --login +h"
    return 0
  fi
  _info "Entrando em chroot..."
  sudo chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$TERM" PATH=/usr/bin:/bin /bin/bash --login +h
}

build_stage2(){
  _info "Iniciando Stage 2 (dentro do chroot)"
  if [ "$(readlink -f /)" != "$LFS" ] && [ "$EUID" -ne 0 ]; then
    _warn "Parece que você não está no chroot. Use enter_chroot ou execute este script dentro do chroot."
    return 0
  fi
  local pkgs; pkgs=$(_resolve_order "stage2" || true)
  if [ -z "$pkgs" ]; then _warn "Nenhum pacote listado para stage2"; return 0; fi
  local total=$(echo "$pkgs" | wc -w); local n=0
  for pkg in $pkgs; do
    n=$((n+1))
    printf "\n[STAGE2] (%d/%d) %s\n" "$n" "$total" "$pkg"
    if ! _build_pkg "$pkg"; then _err "Falha no pacote $pkg em stage2"; fi
  done
  _info "Stage 2 concluído"
}

build_stage3(){
  _info "Iniciando Stage 3 (otimizações e extras)"
  local pkgs; pkgs=$(_resolve_order "stage3" || true)
  if [ -z "$pkgs" ]; then _warn "Nenhum pacote listado para stage3"; return 0; fi
  for pkg in $pkgs; do _build_pkg "$pkg" || _warn "Falha em $pkg (continuando)"; done
  _info "Stage 3 concluído"
}

verify_system(){
  _info "Executando verificação completa com doctor.sh"
  if command -v doctor.sh >/dev/null 2>&1; then
    doctor.sh --scan || _warn "doctor.sh reportou problemas (ver logs)"
  else
    _warn "doctor.sh não encontrado; executando checagens básicas"
    for b in /usr/bin/* /bin/*; do
      [ -x "$b" ] || continue
      ldd "$b" 2>&1 | grep -q "not found" && _warn "Biblioteca faltando em $b"
      readelf -h "$b" >/dev/null 2>&1 || _warn "readelf falhou para $b"
    done
  fi
}

summary_report(){
  local out="${LOG_DIR}/build-summary.json"
  cat > "$out" <<EOF
{
  "lfs":"$LFS",
  "time":"$(date -u +%FT%TZ)",
  "log":"${LOG_DIR}/lfs_build.log"
}
EOF
  _info "Relatório de resumo gravado em $out"
}

_usage(){
  cat <<EOF
lfs_build_all.sh - orquestrador LFS
Usage:
  lfs_build_all.sh --ini
  lfs_build_all.sh --stage 1|2|3|all
  lfs_build_all.sh --enter-chroot
  lfs_build_all.sh --verify
  lfs_build_all.sh --help
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -lt 1 ]; then _usage; exit 2; fi
  case "$1" in
    --ini) init_environment; exit 0;;
    --stage) case "$2" in 1) build_stage1;; 2) build_stage2;; 3) build_stage3;; all) build_stage1; enter_chroot; build_stage2; build_stage3;; *) _usage; exit 2; esac; exit 0;;
    --enter-chroot) enter_chroot; exit 0;;
    --verify) verify_system; exit 0;;
    --help|-h) _usage; exit 0;;
    *) _usage; exit 2;;
  esac
fi
