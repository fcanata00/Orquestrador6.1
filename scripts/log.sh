#!/usr/bin/env bash
# log.sh - simple logging with colors and levels
set -euo pipefail
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
_log(){ local lvl="$1"; shift; local msg="$*"; printf "[%s] %s %s\n" "$lvl" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg"; }
log_info(){ printf "${GREEN}[INFO]${NC} "; _log INFO "$*"; }
log_warn(){ printf "${YELLOW}[WARN]${NC} "; _log WARN "$*"; }
log_error(){ printf "${RED}[ERROR]${NC} "; _log ERROR "$*"; }
