#!/usr/bin/env bash
# lib/base.sh - shared primitives
# shellcheck disable=SC2154  # _dir provided by hifox.sh

# --- colors ---
if [[ -t 1 ]] || [[ -n "${JOURNAL_STREAM:-}" ]]; then
  _R='\033[0m'
  _BLUE='\033[1;34m'
  _GREEN='\033[1;32m'
  _YELLOW='\033[1;33m'
  _RED='\033[1;31m'
else
  _R='' _BLUE='' _GREEN='' _YELLOW='' _RED=''
fi

# --- logging ---
log()  { echo -e "  ${_BLUE}[hifox]${_R} $*"; }
ok()   { echo -e "  ${_GREEN}[  ok ]${_R} $*"; }
warn() { echo -e "  ${_YELLOW}[ warn]${_R} $*" >&2; }
die()  { echo -e "  ${_RED}[error]${_R} $*" >&2; exit 1; }

# --- installation discovery ---
# outputs one line per install: type|profiles_dir|policies_dir|sysconfig_dir
_list_installations() {
  # flatpak
  if command -v flatpak &>/dev/null && flatpak info org.mozilla.firefox &>/dev/null; then
    local arch fp_home pdir sdir
    arch=$(flatpak --default-arch 2>/dev/null || uname -m)
    fp_home="$HOME/.var/app/org.mozilla.firefox"
    sdir="$HOME/.local/share/flatpak/extension/org.mozilla.firefox.systemconfig/${arch}/stable"
    pdir=""
    local cand
    for cand in "$fp_home/.config/mozilla/firefox" "$fp_home/config/mozilla/firefox" "$fp_home/.mozilla/firefox"; do
      [[ -d "$cand" ]] && pdir="$cand" && break
    done
    [[ -n "$pdir" ]] || pdir="$fp_home/.mozilla/firefox"
    echo "flatpak|${pdir}|${sdir}/policies|${sdir}"
  fi

  # standard
  local idir=""
  for cand in ${HIFOX_FIREFOX_DIR:+"$HIFOX_FIREFOX_DIR"} /usr/lib/firefox /usr/lib64/firefox /usr/lib/firefox-esr /opt/firefox; do
    [[ -f "$cand/application.ini" ]] && idir="$cand" && break
  done
  if [[ -n "$idir" ]]; then
    echo "standard|${HOME}/.mozilla/firefox|/etc/firefox/policies|${idir}"
  fi
}

# --- target persistence ---
_target_file() { echo "${XDG_CONFIG_HOME:-${HOME}/.config}/hifox/target"; }

_save_target() {
  local f
  f="$(_target_file)"
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$1" > "$f"
}

_read_target() {
  local f
  f="$(_target_file)"
  [[ -f "$f" ]] && cat "$f" || echo "all"
}

# filtered by saved target (used by all commands)
_active_installations() {
  local target
  target="$(_read_target)"
  if [[ "$target" == "all" ]]; then
    _list_installations
  else
    _list_installations | grep "^${target}|" || true
  fi
}

_require_firefox() {
  local installs
  installs=$(_active_installations)
  if [[ -z "$installs" ]]; then
    local target
    target="$(_read_target)"
    if [[ "$target" == "all" ]]; then
      die "no Firefox found (checked Flatpak + /usr/lib)"
    else
      die "no $target Firefox found - run: hifox install"
    fi
  fi
}
# --- file operations (sudo fallback for system dirs) ---
_ensure_dir() {
  local d="$1"
  [[ -d "$d" ]] && return 0
  # try user first, sudo fallback for system dirs (/etc, /usr/lib)
  mkdir -p "$d" 2>/dev/null && return 0
  if sudo -n mkdir -p "$d" 2>/dev/null; then
    sudo -n chmod 755 "$d" 2>/dev/null || true
    return 0
  fi
  return 1
}

_install_file() {
  local src="$1" dst="$2"
  # try user first, sudo fallback for system dirs (/etc, /usr/lib)
  cp "$src" "$dst" 2>/dev/null && return 0
  if sudo -n cp "$src" "$dst" 2>/dev/null; then
    sudo -n chmod 644 "$dst" 2>/dev/null || true
    return 0
  fi
  return 1
}

# --- paths ---
_desktop_dir() {
  echo "${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
}

_unit_dir() { echo "${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"; }


# --- profiles ---
_find_profile() {
  local profiles_dir="$1"
  [[ -d "$profiles_dir" ]] || return 1

  local ini="$profiles_dir/profiles.ini"
  if [[ -f "$ini" ]]; then
    # 1st priority: [Install*] section - Firefox's actual active profile
    local install_default
    install_default=$(awk -F= '
      /^\[Install/ { inst=1; next }
      /^\[/ { inst=0 }
      inst && /^Default=/ { print $2; exit }
    ' "$ini" 2>/dev/null) || true
    if [[ -n "$install_default" ]]; then
      local resolved="$profiles_dir/$install_default"
      [[ -d "$resolved" ]] && echo "$resolved" && return 0
    fi

    # 2nd priority: [Profile*] section marked Default=1
    local default_path is_rel
    read -r default_path is_rel < <(awk -F= '
      /^\[Profile/ { if(p && d) { print p, r; exit } p=""; d=0; r="1" }
      /^Path=/ { p=$2 }
      /^IsRelative=/ { r=$2 }
      /^Default=1/ { d=1 }
      END { if(p && d) print p, r }
    ' "$ini" 2>/dev/null) || true
    if [[ -n "$default_path" ]]; then
      local resolved
      if [[ "$is_rel" == "0" ]]; then
        resolved="$default_path"
      else
        resolved="$profiles_dir/$default_path"
      fi
      [[ -d "$resolved" ]] && echo "$resolved" && return 0
    fi
  fi

  # fallback: glob standard Firefox naming
  local dir
  for dir in "$profiles_dir"/*.default-release "$profiles_dir"/*.default; do
    [[ -d "$dir" ]] && echo "$dir" && return 0
  done
  return 1
}

# --- profile enumeration (resolves IsRelative + slash paths) ---
_list_profile_paths() {
  local profiles_dir="$1"
  local ini="$profiles_dir/profiles.ini"
  [[ -f "$ini" ]] || return 1
  awk -F= -v pd="$profiles_dir" '
    /^\[Profile/ { if(p!="") print (r=="0" ? p : pd"/"p); p=""; r="1" }
    /^Path=/ { p=$2 }
    /^IsRelative=/ { r=$2 }
    END { if(p!="") print (r=="0" ? p : pd"/"p) }
  ' "$ini"
}

# --- autoconfig generation ---
_generate_autoconfig() {
  cat "${_dir}/config/global_lockprefs.cfg"
  cat "${_dir}/config/generate_pref_dump.cfg"
}

# --- chattr capability (cached, single probe per session) ---
_can_sudo_chattr() {
  if [[ -z "${_CHATTR_PROBED:-}" ]]; then
    _CHATTR_PROBED=1
    _CHATTR_OK=false
    local _out
    _out=$(LC_ALL=C sudo -n chattr 2>&1) || true
    [[ "$_out" == *"Usage"* ]] && _CHATTR_OK=true
  fi
  $_CHATTR_OK
}

# --- profile paths (all: profiles.ini -> glob fallback) ---
_all_profile_paths() {
  local profiles_dir="$1"
  local paths
  paths=$(_list_profile_paths "$profiles_dir" 2>/dev/null) || true
  if [[ -n "$paths" ]]; then
    printf '%s\n' "$paths"
    return
  fi
  _find_profile "$profiles_dir" 2>/dev/null
}

# --- kill all Firefox variants ---
_kill_firefox() {
  pkill firefox 2>/dev/null || true
  pkill firefox-esr 2>/dev/null || true
  flatpak kill org.mozilla.firefox 2>/dev/null || true
}
