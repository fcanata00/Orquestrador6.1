#!/usr/bin/env bash
# install_binpkg.sh – Instalação dos scripts “Orquestrador”/binpkg
# Uso: sudo ./install_binpkg.sh --prefix /usr/bin   ou   --prefix /mnt/lfs/usr/bin

set -euo pipefail
IFS=$'\n\t'

PREFIX=""
DEPENDENCIES=(bash awk grep curl wget tar xz zstd jq pv)
SCRIPTS=(log.sh utils.sh metafile.sh download.sh deps.sh sandbox.sh build.sh uninstall.sh update.sh bootstrap.sh doctor.sh commit.sh find_pkg.sh create_diff.sh info_pkg.sh binpkg)

_log(){ printf "[INSTALL] %s\n" "$*"; }
_warn(){ printf "[INSTALL][WARN] %s\n" "$*"; }
_err(){ printf "[INSTALL][ERROR] %s\n" "$*" >&2; exit 1; }

_usage(){
  cat <<EOF
Usage: sudo ./install_binpkg.sh --prefix <install-dir>

Options:
  --prefix <path>   Diretório de instalação (/usr/bin ou /mnt/lfs/usr/bin)
EOF
}

# Parse args
if [ $# -lt 2 ]; then _usage; exit 1; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2;;
    -h|--help) _usage; exit 0;;
    *) _err "Unknown option: $1";;
  esac
done

# Validate prefix
if [ -z "$PREFIX" ]; then _err "Prefix não informado"; fi
if [ ! -d "$PREFIX" ]; then
  _warn "Diretório $PREFIX não existe. Tentando criar..."
  mkdir -p "$PREFIX" || _err "Falha ao criar prefixo $PREFIX"
fi

# Verificar dependências
_log "Verificando dependências..."
missing=()
for dep in "${DEPENDENCIES[@]}"; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    missing+=( "$dep" )
    printf "  ✗ %s\n" "$dep"
  else
    printf "  ✓ %s\n" "$dep"
  fi
done
if [ ${#missing[@]} -gt 0 ]; then
  _err "Dependências faltando: ${missing[*]}. Instale-as antes."
fi

# Instalar scripts
_log "Instalando scripts em $PREFIX ..."
for script in "${SCRIPTS[@]}"; do
  if [ ! -f "./$script" ]; then
    _warn "Arquivo de script não encontrado: $script. Pulando."
    continue
  fi
  cp "./$script" "$PREFIX/$script" || _err "Falha ao copiar $script"
  chmod 755 "$PREFIX/$script" || _err "Falha ao definir permissão $script"
  _log "Instalado: $PREFIX/$script"
done

# Criar link simbólico para binpkg se não for diretamente o nome
if [ -f "$PREFIX/binpkg" ]; then
  ln -sf "$PREFIX/binpkg" "$PREFIX/bpkg" 2>/dev/null || true
  _log "Link simbólico criado: bpkg -> binpkg"
fi

_log "Instalação concluída com sucesso."
