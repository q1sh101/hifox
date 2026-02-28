#!/usr/bin/env bash
# hifox.sh - Firefox hifox CLI
set -euo pipefail

_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

source "${_dir}/lib/base.sh"
source "${_dir}/lib/deploy.sh"
source "${_dir}/lib/clean.sh"
source "${_dir}/lib/status.sh"
source "${_dir}/lib/watch.sh"

# --- dispatch ---
cmd="${1:-}"

case "$cmd" in
  install)
    flag="${2:-}"
    target=""
    case "$flag" in
      --flatpak)  target="flatpak" ;;
      --standard) target="standard" ;;
      "")         target="all" ;;
      *)          die "usage: hifox install [--flatpak|--standard]" ;;
    esac
    # validate target has installations before persisting
    installs=$(_list_installations)
    if [[ "$target" == "all" ]]; then
      [[ -n "$installs" ]] || die "no Firefox found (checked Flatpak + /usr/lib)"
    else
      echo "$installs" | grep -q "^${target}|" || die "no $target Firefox found"
    fi
    _save_target "$target"
    ok "target: $target"
    hifox_deploy
    hifox_watch_install
    _bin="${HOME}/.local/bin"
    mkdir -p "$_bin"
    ln -sf "${_dir}/hifox.sh" "${_bin}/hifox"
    [[ ":$PATH:" == *":${_bin}:"* ]] || warn "add ${_bin} to PATH"
    ok "command: hifox"
    ;;
  deploy)
    [[ $# -le 1 ]] || die "deploy takes no arguments"
    hifox_deploy
    ;;
  verify)
    _require_firefox
    source "${_dir}/lib/verify.sh"
    _hifox_verify
    ;;
  clean)
    hifox_clean
    ;;
  status)
    hifox_status
    ;;
  logs)
    command -v journalctl &>/dev/null || die "journalctl not found"
    exec journalctl --user -n 50 -f -o cat -u hifox-watch.path -u hifox-deploy.service
    ;;
  watch)
    sub="${2:-}"
    case "$sub" in
      install) hifox_watch_install ;;
      remove)  hifox_watch_remove ;;
      status)  hifox_watch_status ;;
      *)       die "usage: hifox watch <install|remove|status>" ;;
    esac
    ;;
  *)
    log "usage: hifox <command>"
    log "  install [--flatpak|--standard]  first-time setup (saves target, deploys, starts watcher)"
    log "  deploy                          deploy hardening to saved target"
    log "  verify                          check pref integrity after Firefox restart"
    log "  clean                           remove stale remnant files from profiles"
    log "  status                          show sync state between repo and live"
    log "  logs                            follow auto-deploy output"
    log "  watch   install                 auto-deploy on repo file changes"
    log "  watch   remove                  disable auto-deploy"
    log "  watch   status                  show watcher status"
    exit 1
    ;;
esac
