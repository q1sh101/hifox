#!/usr/bin/env bash
# shellcheck disable=SC2154  # _dir provided by hifox.sh

if [[ -t 1 ]] || [[ -n "${JOURNAL_STREAM:-}" ]]; then
  _r='\033[0m'
  _blue='\033[1;34m'
  _green='\033[1;32m'
  _yellow='\033[1;33m'
  _red='\033[1;31m'
else
  _r='' _blue='' _green='' _yellow='' _red=''
fi

log()  { echo -e "  ${_blue}[hifox]${_r} $*"; }
ok()   { echo -e "  ${_green}[  ok ]${_r} $*"; }
warn() { echo -e "  ${_yellow}[ warn]${_r} $*" >&2; }
die()  { echo -e "  ${_red}[error]${_r} $*" >&2; exit 1; }

_require_command() {
  local name="$1"
  command -v "${name}" &>/dev/null || die "required command not found: ${name}"
}

_check_command() {
  local name="$1"
  command -v "${name}" &>/dev/null
}

_list_installations() {
  local cand
  if _check_command flatpak; then
    local arch branch ref data_home fp_home pdir sdir
    if ref=$(_flatpak_firefox_ref); then
      IFS='|' read -r arch branch <<< "${ref}"
      fp_home="${HOME}/.var/app/org.mozilla.firefox"
      data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
      sdir="${data_home}/flatpak/extension/org.mozilla.firefox.systemconfig/${arch}/${branch}"
      pdir=""
      local cands=("${fp_home}/config/mozilla/firefox" "${fp_home}/.config/mozilla/firefox" "${fp_home}/.mozilla/firefox")
      # Flatpak migration may leave multiple profile roots; prefer modern path over mtime.
      for cand in "${cands[@]}"; do
        [[ -d "${cand}" && -f "${cand}/profiles.ini" ]] && pdir="${cand}" && break
      done
      if [[ -z "${pdir}" ]]; then
        for cand in "${cands[@]}"; do
          [[ -d "${cand}" ]] && pdir="${cand}" && break
        done
      fi
      [[ -n "${pdir}" ]] || pdir="${fp_home}/.mozilla/firefox"
      echo "flatpak|${pdir}|${sdir}/policies|${sdir}"
    else
      if flatpak info org.mozilla.firefox &>/dev/null; then
        warn "cannot determine Firefox Flatpak architecture or branch - skipping Flatpak target"
      fi
    fi
  fi

  local idir=""
  for cand in ${HIFOX_FIREFOX_DIR:+"${HIFOX_FIREFOX_DIR}"} /usr/lib/firefox /usr/lib64/firefox /usr/lib/firefox-esr /opt/firefox; do
    [[ -f "${cand}/application.ini" ]] && idir="${cand}" && break
  done
  if [[ -n "${idir}" ]]; then
    echo "standard|${HOME}/.mozilla/firefox|/etc/firefox/policies|${idir}"
  fi
}

_flatpak_firefox_ref() {
  local ref kind app arch branch extra
  ref=$(LC_ALL=C flatpak info --show-ref org.mozilla.firefox 2>/dev/null) || return 1
  IFS='/' read -r kind app arch branch extra <<< "${ref}"
  [[ "${kind}" == app && "${app}" == org.mozilla.firefox && -z "${extra}" ]] || return 1
  [[ -n "${arch}" && "${arch}" != *[!A-Za-z0-9._-]* ]] || return 1
  [[ -n "${branch}" && "${branch}" != *[!A-Za-z0-9._-]* ]] || return 1
  printf '%s|%s\n' "${arch}" "${branch}"
}

_target_file() { echo "${XDG_CONFIG_HOME:-${HOME}/.config}/hifox/target"; }

_save_target() {
  local f tmp
  f="$(_target_file)"
  mkdir -p "$(dirname "${f}")"
  tmp="${f}.tmp.$$"
  if printf '%s\n' "$1" > "${tmp}" && mv -f "${tmp}" "${f}"; then
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

_read_target() {
  local f
  f="$(_target_file)"
  [[ -f "${f}" ]] && cat "${f}" || echo ""
}

_active_installations() {
  local target
  target="$(_read_target)"
  case "${target}" in
    flatpak|standard) _list_installations | awk -F'|' -v target="${target}" '$1 == target' ;;
    "") return 0 ;;
    *) warn "invalid saved target: ${target}"; return 1 ;;
  esac
}

_require_firefox() {
  local installs target
  target="$(_read_target)"
  [[ -n "${target}" ]] || die "hifox not installed - run: hifox install <--flatpak|--standard>"
  installs=$(_active_installations)
  [[ -n "${installs}" ]] || die "no ${target} Firefox found - run: hifox install <--flatpak|--standard>"
}

_ensure_dir() {
  local d="$1"
  [[ -d "${d}" ]] && return 0
  sudo -n test -d "${d}" 2>/dev/null && return 0
  mkdir -p "${d}" 2>/dev/null && return 0
  if sudo -n mkdir -p "${d}" 2>/dev/null; then
    sudo -n chmod 755 "${d}" 2>/dev/null || true
    return 0
  fi
  return 1
}

_file_matches() {  # <src> <dst> - 0 if a regular, non-symlink dst matches src
  [[ -f "$2" && ! -L "$2" ]] && cmp -s "$1" "$2" 2>/dev/null
}

_install_file() {
  local src="$1" dst="$2" dir base tmp
  dir="$(dirname "${dst}")"
  base="$(basename "${dst}")"
  tmp="${dir}/.${base}.tmp.$$"
  if cp "${src}" "${tmp}" 2>/dev/null \
    && chmod 644 "${tmp}" 2>/dev/null \
    && mv -f "${tmp}" "${dst}" 2>/dev/null; then
    return 0
  fi
  rm -f "${tmp}" 2>/dev/null || true
  if sudo -n cp "${src}" "${tmp}" 2>/dev/null \
    && sudo -n chmod 644 "${tmp}" 2>/dev/null \
    && sudo -n mv -f "${tmp}" "${dst}" 2>/dev/null; then
    return 0
  fi
  sudo -n rm -f "${tmp}" 2>/dev/null || true
  return 1
}

_desktop_dir() {
  echo "${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
}

_unit_dir() { echo "${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"; }

# only for paths declared by profiles.ini; hifox's own literal paths need no check
_canonical_contained_path() {
  local root="${1%/}" candidate="${2%/}" root_real resolved
  [[ -n "${root}" && -n "${candidate}" ]] || return 1
  root_real=$(readlink -f -- "${root}" 2>/dev/null) || return 1
  [[ -d "${root_real}" ]] || return 1
  resolved=$(readlink -f -- "${candidate}" 2>/dev/null) || return 1
  case "${resolved}" in
    "${root_real}"/*) printf '%s\n' "${resolved}" ;;
    *) return 1 ;;
  esac
}

_canonical_profile_path() {
  local profiles_dir="$1" candidate="$2"
  [[ -d "${candidate}" && ! -L "${candidate}" ]] || return 1
  _canonical_contained_path "${profiles_dir}" "${candidate}"
}

_profile_records() {
  local profiles_dir="$1" mode="$2" ini="${1}/profiles.ini"
  [[ ! -L "${ini}" ]] || return 2
  [[ -e "${ini}" ]] || return 1
  [[ -f "${ini}" ]] || return 2
  awk -F= -v pd="${profiles_dir}" -v mode="${mode}" '
    BEGIN { OFS="\t" }
    function emit_profile(  candidate) {
      if (!in_profile || path == "") return
      candidate = (relative == "0" ? path : pd "/" path)
      if (mode == "all") print "P", candidate
      else if (is_default && default_path == "") default_path = candidate
    }
    /^\[/ {
      emit_profile()
      in_profile = ($0 ~ /^\[Profile/)
      in_install = ($0 ~ /^\[Install/)
      path = ""; relative = "1"; is_default = 0
      next
    }
    in_install && /^Default=/ {
      if (mode == "all") print "I", $2
      else if (!install_seen) { install_path = $2; install_seen = 1 }
      next
    }
    in_profile && /^Path=/ { path = $2; next }
    in_profile && /^IsRelative=/ { relative = $2; next }
    in_profile && /^Default=1/ { is_default = 1 }
    END {
      emit_profile()
      if (mode == "default") {
        if (install_path != "") print "I", install_path
        if (default_path != "") print "P", default_path
      }
    }
  ' "${ini}" 2>/dev/null || return 4
}

_resolve_profile_record() {
  local profiles_dir="$1" kind="$2" path="$3" candidate
  case "${kind}" in
    I) [[ "${path}" != /* ]] || return 2; candidate="${profiles_dir}/${path}" ;;
    P) candidate="${path}" ;;
    *) return 2 ;;
  esac
  case "/${candidate}/" in */../*) return 2 ;; esac
  [[ -e "${candidate}" || -L "${candidate}" ]] || return 3
  _canonical_profile_path "${profiles_dir}" "${candidate}" || return 2
}

_find_profile() {
  local profiles_dir="$1" records state=0 kind path resolved declared=false
  [[ -d "${profiles_dir}" ]] || return 1
  records=$(_profile_records "${profiles_dir}" default) || state=$?
  case "${state}" in
    0) ;;
    1) records="" ;;
    2|4) return "${state}" ;;
    *) return 4 ;;
  esac

  while IFS=$'\t' read -r kind path; do
    [[ -n "${path}" ]] || continue
    declared=true
    state=0
    resolved=$(_resolve_profile_record "${profiles_dir}" "${kind}" "${path}") || state=$?
    case "${state}" in
      0) printf '%s\n' "${resolved}"; return 0 ;;
      2) return 2 ;;
      3) ;;
      *) return 4 ;;
    esac
  done <<< "${records}"

  # A broken declaration must not be hidden by an unrelated glob fallback.
  ${declared} && return 2
  local dir
  for dir in "${profiles_dir}"/*.default-release "${profiles_dir}"/*.default; do
    dir=$(_canonical_profile_path "${profiles_dir}" "${dir}") \
      && printf '%s\n' "${dir}" && return 0
  done
  return 1
}

_list_profile_paths() {
  local profiles_dir="$1" records kind path resolved state
  local invalid=false unresolved=false
  local -A emitted=()
  records=$(_profile_records "${profiles_dir}" all) || return $?
  while IFS=$'\t' read -r kind path; do
    [[ -n "${path}" ]] || continue
    state=0
    resolved=$(_resolve_profile_record "${profiles_dir}" "${kind}" "${path}") || state=$?
    case "${state}" in
      0)
        if [[ -z "${emitted[${resolved}]+set}" ]]; then
          printf '%s\n' "${resolved}"
          emitted["${resolved}"]=1
        fi
        ;;
      2) invalid=true ;;
      3) [[ "${kind}" == I ]] || unresolved=true ;;
      *) return 4 ;;
    esac
  done <<< "${records}"
  ${invalid} && return 2
  ${unresolved} && return 3
  return 0
}

_all_profile_paths() {
  local profiles_dir="$1"
  local paths list_state=0
  paths=$(_list_profile_paths "${profiles_dir}" 2>/dev/null) || list_state=$?
  if (( list_state == 2 || list_state == 3 || list_state == 4 )); then
    [[ -z "${paths}" ]] || printf '%s\n' "${paths}"
    return "${list_state}"
  fi
  if [[ -n "${paths}" ]]; then
    printf '%s\n' "${paths}"
    return
  fi
  _find_profile "${profiles_dir}" 2>/dev/null
}

_standard_firefox_pids() {
  local install_dir="$1" install_real pid exe candidates rc=0
  install_real=$(readlink -f -- "${install_dir}" 2>/dev/null) || return 1
  candidates=$(pgrep -x 'firefox(-esr)?(-bin)?' 2>/dev/null) || rc=$?
  (( rc <= 1 )) || return 1
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    exe=$(readlink -- "/proc/${pid}/exe" 2>/dev/null) || continue
    exe="${exe% (deleted)}"
    case "${exe}" in
      "${install_real}"/*) printf '%s\n' "${pid}" ;;
    esac
  done <<< "${candidates}"
}

_firefox_running() {
  local target="$1" install_dir="${2:-}"
  case "${target}" in
    flatpak)
      _check_command flatpak || return 1
      local applications
      applications=$(flatpak ps --columns=application 2>/dev/null) || return 2
      grep -Fxq 'org.mozilla.firefox' <<< "${applications}"
      ;;
    standard)
      [[ -n "${install_dir}" ]] || return 1
      local pids
      pids=$(_standard_firefox_pids "${install_dir}") || return 2
      [[ -n "${pids}" ]]
      ;;
    *) return 1 ;;
  esac
}

_stop_firefox() {
  local target="$1" install_dir="${2:-}" pids
  case "${target}" in
    flatpak)
      local running_rc
      _firefox_running flatpak && running_rc=0 || running_rc=$?
      (( running_rc == 1 )) && return 0
      (( running_rc == 0 )) || return 1
      flatpak kill org.mozilla.firefox 2>/dev/null
      ;;
    standard)
      pids=$(_standard_firefox_pids "${install_dir}") || return 1
      [[ -n "${pids}" ]] || return 0
      # shellcheck disable=SC2086  # pids contains only numeric lines from pgrep
      kill ${pids} 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

_wait_firefox_stopped() {
  local target="$1" install_dir="${2:-}" attempts="${3:-5}" attempt running_rc
  for ((attempt = 0; attempt < attempts; attempt++)); do
    _firefox_running "${target}" "${install_dir}" && running_rc=0 || running_rc=$?
    (( running_rc == 1 )) && return 0
    (( running_rc == 0 )) || return 1
    sleep 1
  done
  _firefox_running "${target}" "${install_dir}" && running_rc=0 || running_rc=$?
  (( running_rc == 1 ))
}

_can_sudo_chattr() {
  if [[ -z "${_chattr_probed:-}" ]]; then
    _chattr_probed=1
    _chattr_ok=false
    # LC_ALL=C: chattr usage text is locale-dependent, force English
    local _out
    _out=$(LC_ALL=C sudo -n chattr 2>&1) || true
    [[ "${_out}" == *"Usage"* ]] && _chattr_ok=true
  fi
  ${_chattr_ok}
}

_is_immutable() {
  [[ ! -L "$1" ]] && lsattr "$1" 2>/dev/null | awk '{print $1}' | grep -q i
}

_chattr_unlock() {
  local f="$1"
  [[ -L "${f}" ]] && return 0
  [[ -f "${f}" ]] || return 0
  if _can_sudo_chattr; then
    sudo -n chattr -i "${f}" 2>/dev/null
    return
  fi
  if lsattr "${f}" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
    warn "sudo required to unlock immutable: $(basename "${f}")"
    if (exec </dev/tty) 2>/dev/null; then
      # shellcheck disable=SC2024  # redirect is intentional for tty input
      sudo chattr -i "${f}" </dev/tty || return 1
    else
      warn "no terminal for sudo - run manually: sudo chattr -i ${f}"
      return 1
    fi
  fi
  return 0
}

_is_valid_webapp_name() {
  local name="$1"
  case "${name}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

_generate_autoconfig() {
  local wcfg="${_dir}/webapp/shared/webapp.cfg"
  # Guard the webapp.cfg split marker; awk generation depends on exactly one.
  local _mn
  _mn=$(grep -c 'per-webapp overrides' "${wcfg}" 2>/dev/null) || _mn=0
  (( _mn == 1 )) || die "webapp.cfg: 'per-webapp overrides' marker count=${_mn}, expected 1"

  cat "${_dir}/config/global_lockprefs.cfg" || return 1

  awk '{print} /per-webapp overrides/{exit}' "${wcfg}" || return 1

  local wdir wn
  for wdir in "${_dir}/webapp"/*/; do
    [[ -d "${wdir}" ]] || continue
    wn=$(basename "${wdir}")
    [[ "${wn}" == "shared" ]] && continue
    _is_valid_webapp_name "${wn}" || continue
    echo "  if (profileDir === \"${wn}\") {"
    echo "    isWebapp = true;"
    if [[ -f "${wdir}/prefs.cfg" ]]; then
      sed 's/^/    /' "${wdir}/prefs.cfg" || return 1
    fi
    echo "  }"
    echo ""
  done

  awk 'p; /per-webapp overrides/{p=1}' "${wcfg}" || return 1

  cat "${_dir}/config/generate_pref_dump.cfg" || return 1
}
