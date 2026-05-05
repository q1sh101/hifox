#!/usr/bin/env bash
set -euo pipefail

_find_firefox() {
  local target_file="${XDG_CONFIG_HOME:-${HOME}/.config}/hifox/target"
  local target="all"
  [[ -f "${target_file}" ]] && target=$(<"${target_file}")

  if [[ "${target}" != "standard" ]]; then
    if command -v flatpak &>/dev/null && flatpak info org.mozilla.firefox &>/dev/null; then
      echo "flatpak"
      return 0
    fi
  fi
  if [[ "${target}" != "flatpak" ]]; then
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
    # Flatpak may leave multiple migrated profile roots; prefer the active one.
    local fp="${HOME}/.var/app/org.mozilla.firefox" cand newest=0 m first_existing=""
    base=""
    for cand in "${fp}/config/mozilla/firefox" "${fp}/.config/mozilla/firefox" "${fp}/.mozilla/firefox"; do
      [[ -d "${cand}" ]] || continue
      [[ -z "${first_existing}" ]] && first_existing="${cand}"
      m=$(find "${cand}" -maxdepth 2 -name 'prefs.js' -printf '%T@\n' 2>/dev/null \
          | sort -rn | head -1 | cut -d. -f1)
      [[ -z "${m}" ]] && continue
      if (( m > newest )); then newest=${m}; base="${cand}"; fi
    done
    [[ -n "${base}" ]] || base="${first_existing}"
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
  [[ -x "${_hook}" ]] && exec "${_hook}" "${@:4}"

  _url="${3:-}"
  _args=(--no-remote --new-instance -P "${_name}")
  [[ -n "${_url}" ]] && _args+=("${_url}")
  export MOZ_APP_REMOTINGNAME="${_name}-web"
  _args+=(--name "${_name}-web" --class "${_name}-web")
  _run "${_args[@]}"
else
  _run "$@"
fi
