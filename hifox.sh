#!/usr/bin/env bash
set -euo pipefail

_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

source "${_dir}/lib/base.sh"
source "${_dir}/lib/deploy.sh"
source "${_dir}/lib/clean.sh"
source "${_dir}/lib/purge.sh"
source "${_dir}/lib/status.sh"
source "${_dir}/lib/watch.sh"
source "${_dir}/lib/systemconfig.sh"

cmd="${1:-}"

case "${cmd}" in
  install)
    flag="${2:-}"
    target=""
    other=""
    case "${flag}" in
      --flatpak)  target="flatpak"; other="standard" ;;
      --standard) target="standard"; other="flatpak" ;;
      *)          die "usage: hifox install <--flatpak|--standard>" ;;
    esac
    if [[ "${target}" == "standard" && -f /snap/firefox/current/usr/lib/firefox/application.ini ]]; then
      warn "alternatives:"
      warn "  - Mozilla apt repo (.deb)"
      warn "  - Mozilla tarball at /opt/firefox"
      warn "  - hifox install --flatpak"
      die "snap Firefox not supported (/snap is read-only)"
    fi
    installs=$(_list_installations)
    echo "${installs}" | grep -q "^${target}|" || die "no ${target} Firefox found"
    if echo "${installs}" | grep -q "^${other}|"; then
      warn "${other} Firefox is also installed"
      warn "  remove it first, then re-run: hifox install --${target}"
      die "hifox is single-target - pick one Firefox target"
    fi
    _save_target "${target}"
    ok "target: ${target}"
    if [[ "${target}" == "standard" && -t 0 ]]; then
      log "sudo required for /etc/firefox and Firefox install directory"
      sudo -v || die "sudo authentication failed"
    fi
    if [[ "${target}" == "flatpak" ]]; then
      if _check_command flatpak-builder || flatpak info org.flatpak.Builder &>/dev/null; then
        hifox_install_systemconfig
      else
        warn "Flatpak Builder not found - systemconfig extension not registered"
        warn "  install: flatpak install --user flathub org.flatpak.Builder"
        warn "  then run: hifox install-systemconfig"
      fi
    fi
    hifox_deploy
    _bin="${HOME}/.local/bin"
    mkdir -p "${_bin}"
    ln -sf "${_dir}/hifox.sh" "${_bin}/hifox"
    [[ ":${PATH}:" == *":${_bin}:"* ]] || warn "add ${_bin} to PATH"
    ok "command: hifox"
    hifox_watch_install
    log "done - launch Firefox once, close it, launch again"
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
  purge)
    hifox_purge "${2:-}"
    ;;
  status)
    hifox_status
    ;;
  logs)
    _require_command journalctl
    exec journalctl --user -n 50 -f -o cat -u hifox-watch.path -u hifox-deploy.service -u hifox-verify.service
    ;;
  watch)
    sub="${2:-}"
    case "${sub}" in
      install) hifox_watch_install ;;
      remove)  hifox_watch_remove ;;
      status)  hifox_watch_status ;;
      *)       die "usage: hifox watch <install|remove|status>" ;;
    esac
    ;;
  install-systemconfig)
    [[ $# -le 1 ]] || die "install-systemconfig takes no arguments"
    hifox_install_systemconfig
    ;;
  *)
    log "usage: hifox <command>"
    log "  install <--flatpak|--standard>  first-time setup (target required; saves it, deploys, starts watcher)"
    log "  deploy                          deploy hardening to saved target"
    log "  verify                          check hardening integrity (prefs + files + dump)"
    log "  clean                           remove stale remnant files from profiles"
    log "  purge [--flatpak|--standard]    delete all browsing data (irreversible)"
    log "  status                          show sync state between repo and live"
    log "  logs                            follow deploy + verify output"
    log "  watch   install                 auto-deploy on repo file changes"
    log "  watch   remove                  disable auto-deploy"
    log "  watch   status                  show watcher status"
    log "  install-systemconfig            register flatpak extension (autoconfig + policies in sandbox)"
    exit 1
    ;;
esac
