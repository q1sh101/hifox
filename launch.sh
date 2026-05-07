#!/usr/bin/env bash
set -euo pipefail

_pinned_target=""
if [[ "${1:-}" == "--target" ]]; then
  case "${2:-}" in
    flatpak|standard) _pinned_target="${2}"; shift 2 ;;
    *) echo "error: --target requires flatpak or standard" >&2; exit 1 ;;
  esac
fi

_find_firefox() {
  local target="${_pinned_target}"
  if [[ -z "${target}" ]]; then
    local target_file="${XDG_CONFIG_HOME:-${HOME}/.config}/hifox/target"
    [[ -f "${target_file}" ]] && target=$(<"${target_file}")
  fi

  if [[ "${target}" == "flatpak" ]]; then
    command -v flatpak &>/dev/null && flatpak info org.mozilla.firefox &>/dev/null \
      && { echo "flatpak"; return 0; }
  fi
  if [[ "${target}" == "standard" || -z "${target}" ]]; then
    local cand bin
    for cand in ${HIFOX_FIREFOX_DIR:+"${HIFOX_FIREFOX_DIR}"} /usr/lib/firefox /usr/lib64/firefox /usr/lib/firefox-esr /opt/firefox; do
      [[ -f "${cand}/application.ini" ]] || continue
      for bin in "${cand}/firefox" "${cand}/firefox-esr"; do
        [[ -x "${bin}" ]] && echo "${bin}" && return 0
      done
    done
  fi
  return 1
}

_ff=$(_find_firefox) || { echo "error: no Firefox found" >&2; exit 1; }

_run() {
  # shellcheck disable=SC2086  # word-split intentional
  if [[ -z "${_pinned_target}" && -n "${HIFOX_LAUNCHER:-}" ]]; then
    exec ${HIFOX_LAUNCHER} "$@"
  fi
  if [[ "${_ff}" == "flatpak" ]]; then
    exec flatpak run org.mozilla.firefox "$@"
  else
    exec "${_ff}" "$@"
  fi
}

_run_direct() {
  # webapp/menu paths skip HIFOX_LAUNCHER; per-webapp hooks own that wrapping
  if [[ "${_ff}" == "flatpak" ]]; then
    exec flatpak run org.mozilla.firefox "$@"
  else
    exec "${_ff}" "$@"
  fi
}

_clean_stale_locks() {
  # Stale lock files can block relaunch after an unclean Firefox exit.
  if pgrep -x 'firefox(-esr)?(-bin)?' >/dev/null 2>&1; then return; fi
  local base
  if [[ "${_ff}" == "flatpak" ]]; then
    # Flatpak migration may leave multiple profile roots; prefer modern path over mtime.
    local fp="${HOME}/.var/app/org.mozilla.firefox" cand
    local cands=("${fp}/config/mozilla/firefox" "${fp}/.config/mozilla/firefox" "${fp}/.mozilla/firefox")
    base=""
    for cand in "${cands[@]}"; do
      [[ -d "${cand}" && -f "${cand}/profiles.ini" ]] && base="${cand}" && break
    done
    if [[ -z "${base}" ]]; then
      for cand in "${cands[@]}"; do
        [[ -d "${cand}" ]] && base="${cand}" && break
      done
    fi
    [[ -n "${base}" ]] || base="${fp}/.mozilla/firefox"
  else
    base="${HOME}/.mozilla/firefox"
  fi
  local lockfile
  for lockfile in "${base}"/*/lock; do
    [[ -e "${lockfile}" || -h "${lockfile}" ]] || continue
    rm -f "${lockfile}" "$(dirname "${lockfile}")/.parentlock" 2>/dev/null
  done
}

_clean_stale_locks

if [[ "${1:-}" == "--webapp" ]]; then
  _name="${2:?webapp name required}"
  case "${_name}" in ''|.*|*[!A-Za-z0-9._-]*) echo "error: invalid webapp name: ${_name}" >&2; exit 1 ;; esac

  _hook="${XDG_CONFIG_HOME:-${HOME}/.config}/hifox/hooks/webapp/${_name}"
  [[ -x "${_hook}" ]] && exec "${_hook}" "${@:3}"

  _url="${3:-}"
  _args=(--no-remote --new-instance -P "${_name}")
  [[ -n "${_url}" ]] && _args+=("${_url}")
  export MOZ_APP_REMOTINGNAME="${_name}-web"
  _args+=(--name "${_name}-web" --class "${_name}-web")
  _run_direct "${_args[@]}"
else
  _run "$@"
fi
