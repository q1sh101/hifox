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

_acquire_operation_lock() {
  local lock_dir
  lock_dir="$(dirname "$(_target_file)")"
  mkdir -p -- "${lock_dir}" || die "cannot create hifox state directory"
  [[ -d "${lock_dir}" ]] || die "hifox state path is not a directory"
  _require_command flock
  # lock the existing directory: a new lock file could be a planted symlink
  exec 9<"${lock_dir}" || die "cannot open hifox state directory for locking"
  flock -w 15 9 || die "another hifox operation is still running"
}

case "${cmd}" in
  install)
    [[ $# -le 2 ]] || die "usage: hifox install <--flatpak|--standard>"
    flag="${2:-}"
    target=""
    other=""
    case "${flag}" in
      --flatpak)  target="flatpak"; other="standard" ;;
      --standard) target="standard"; other="flatpak" ;;
      *)          die "usage: hifox install <--flatpak|--standard>" ;;
    esac
    _acquire_operation_lock
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
    hifox_deploy
    _bin="${HOME}/.local/bin"
    mkdir -p "${_bin}"
    ln -sf "${_dir}/hifox.sh" "${_bin}/hifox"
    [[ ":${PATH}:" == *":${_bin}:"* ]] || warn "add ${_bin} to PATH"
    ok "command: hifox"
    hifox_watch_install
    echo ""
    log "installed - launch Firefox, close it, launch again, then run: hifox verify"
    ;;
  deploy)
    [[ $# -le 1 ]] || die "deploy takes no arguments"
    _acquire_operation_lock
    hifox_deploy
    log "next: restart Firefox, then run: hifox verify"
    ;;
  verify)
    [[ $# -le 1 ]] || die "verify takes no arguments"
    # no lock: verify must stay available mid-deploy, which it reports as staged
    _require_firefox
    source "${_dir}/lib/verify.sh"
    _hifox_verify
    ;;
  clean)
    [[ $# -le 1 ]] || die "clean takes no arguments"
    _acquire_operation_lock
    hifox_clean
    ;;
  purge)
    [[ $# -le 2 ]] || die "usage: hifox purge [--flatpak|--standard]"
    case "${2:-}" in
      ""|--flatpak|--standard) ;;
      *) die "usage: hifox purge [--flatpak|--standard]" ;;
    esac
    _acquire_operation_lock
    hifox_purge "${2:-}"
    ;;
  status)
    [[ $# -le 1 ]] || die "status takes no arguments"
    hifox_status
    ;;
  logs)
    [[ $# -le 1 ]] || die "logs takes no arguments"
    _require_command journalctl
    exec journalctl --user -n 50 -f -o cat -u hifox-watch.path -u hifox-deploy.service -u hifox-verify.service
    ;;
  watch)
    [[ $# -le 2 ]] || die "usage: hifox watch <install|remove|status>"
    sub="${2:-}"
    case "${sub}" in
      install) _acquire_operation_lock; hifox_watch_install ;;
      remove)  _acquire_operation_lock; hifox_watch_remove ;;
      status)  hifox_watch_status ;;
      *)       die "usage: hifox watch <install|remove|status>" ;;
    esac
    ;;
  install-systemconfig)
    [[ $# -le 1 ]] || die "install-systemconfig takes no arguments"
    _acquire_operation_lock
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
    log "  install-systemconfig            refresh Flatpak autoconfig + policies"
    exit 1
    ;;
esac
