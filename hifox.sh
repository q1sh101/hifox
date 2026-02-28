#!/usr/bin/env bash
# hifox.sh - Firefox hifox CLI
set -euo pipefail

_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

source "${_dir}/lib/base.sh"
source "${_dir}/lib/deploy.sh"
source "${_dir}/lib/clean.sh"
source "${_dir}/lib/status.sh"

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

    installs=$(_list_installations)
    if [[ "$target" == "all" ]]; then
      [[ -n "$installs" ]] || die "no Firefox found (checked Flatpak + /usr/lib)"
    else
      echo "$installs" | grep -q "^${target}|" || die "no $target Firefox found"
    fi

    _save_target "$target"
    ok "target: $target"
    hifox_deploy

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

  *)
    log "usage: hifox <command>"
    log "  install [--flatpak|--standard]"
    log "  deploy"
    log "  verify"
    log "  clean"
    log "  status"
    exit 1
    ;;
esac
