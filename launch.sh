#!/usr/bin/env bash
# launch.sh - Firefox webapp launcher
set -euo pipefail

_find_firefox() {
  # respect saved target (matches base.sh target routing)
  local target_file="${XDG_CONFIG_HOME:-${HOME}/.config}/hifox/target"
  local target="all"
  [[ -f "$target_file" ]] && target=$(<"$target_file")

  # flatpak (skip if target=standard)
  if [[ "$target" != "standard" ]]; then
    if command -v flatpak &>/dev/null && flatpak info org.mozilla.firefox &>/dev/null; then
      echo "flatpak"
      return 0
    fi
  fi
  # standard (skip if target=flatpak)
  if [[ "$target" != "flatpak" ]]; then
    local cand bin
    for cand in ${HIFOX_FIREFOX_DIR:+"$HIFOX_FIREFOX_DIR"} /usr/lib/firefox /usr/lib64/firefox /usr/lib/firefox-esr /opt/firefox; do
      [[ -f "$cand/application.ini" ]] || continue
      for bin in "$cand/firefox" "$cand/firefox-esr"; do
        [[ -x "$bin" ]] && echo "$bin" && return 0
      done
    done
  fi
  return 1
}

_ff=$(_find_firefox) || { echo "error: no Firefox found" >&2; exit 1; }

_run() {
  if [[ "$_ff" == "flatpak" ]]; then
    exec flatpak run org.mozilla.firefox "$@"
  else
    exec "$_ff" "$@"
  fi
}

_clean_stale_locks() {
  # pkill/kill leaves lock files behind - blocks next launch
  # safe: only runs when zero Firefox processes exist
  if pgrep -x firefox >/dev/null 2>&1 || pgrep -x firefox-esr >/dev/null 2>&1; then return; fi
  local base
  if [[ "$_ff" == "flatpak" ]]; then
    base="$HOME/.var/app/org.mozilla.firefox/config/mozilla/firefox"
  else
    base="$HOME/.mozilla/firefox"
  fi
  local lockfile
  for lockfile in "$base"/*/lock; do
    [[ -e "$lockfile" || -h "$lockfile" ]] || continue
    rm -f "$lockfile" "$(dirname "$lockfile")/.parentlock" 2>/dev/null
  done
}

_clean_stale_locks

if [[ "${1:-}" == "--webapp" ]]; then
  _name="${2:?webapp name required}"
  case "$_name" in ''|.*|*[!A-Za-z0-9._-]*) echo "error: invalid webapp name: $_name" >&2; exit 1 ;; esac

  # launcher hook: any external tool can override webapp launch
  _hook="${XDG_CONFIG_HOME:-${HOME}/.config}/hifox/hooks/webapp/${_name}"
  [[ -x "$_hook" ]] && exec "$_hook" "${@:4}"

  _url="${3:-}"
  _args=(--no-remote --new-instance -P "$_name")
  [[ -n "$_url" ]] && _args+=("$_url")
  # separate dock icon: Wayland (app_id) + X11 (WM_CLASS)
  export MOZ_APP_REMOTINGNAME="${_name}-web"
  _args+=(--name "${_name}-web" --class "${_name}-web")
  _run "${_args[@]}"
else
  _run "$@"
fi
