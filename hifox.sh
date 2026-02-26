#!/usr/bin/env bash
# hifox.sh - Firefox hifox CLI
set -euo pipefail

_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

source "${_dir}/lib/base.sh"

log "usage: hifox <command>"
log "  (foundation CLI skeleton)"
exit 1
