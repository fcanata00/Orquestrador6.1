#!/usr/bin/env bash
# log.sh - colorized logging helper
set -euo pipefail
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
_log_base(){ local lvl="$1"; shift; printf "[%s] %s %s\n" "$lvl" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
log_info(){ printf "%b" "${GREEN}[INFO]${NC} "; _log_base INFO "$*"; }
log_warn(){ printf "%b" "${YELLOW}[WARN]${NC} "; _log_base WARN "$*"; }
log_error(){ printf "%b" "${RED}[ERROR]${NC} "; _log_base ERROR "$*"; }
