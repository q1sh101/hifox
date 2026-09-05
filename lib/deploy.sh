#!/usr/bin/env bash
# shellcheck disable=SC2154  # _dir provided by hifox.sh

_policy_count() {
  command -v python3 &>/dev/null || { echo "?"; return; }
  python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('policies',{})))" \
    "$1" 2>/dev/null || echo "?"
}

_relock_file() {
  local file="$1" label="$2"
  sudo -n chattr +i "${file}" 2>/dev/null && return 0
  warn "${label}: re-lock failed - file remains writable"
  return 1
}

_deploy_policies() {
  local policies_dir="$1" install_dir="${2:-}"
  local src="${_dir}/config/policies.json"
  local dst="${policies_dir}/policies.json"
  [[ -f "${src}" ]] || die "policies.json not found in ${_dir}/config"

  if _check_command python3; then
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${src}" 2>/dev/null \
      || die "policies.json: invalid JSON"
  fi

  if [[ -n "${install_dir}" && -f "${install_dir}/distribution/policies.json" ]]; then
    warn "${install_dir}/distribution/policies.json shadows hifox policy"
    warn "  remove with: sudo rm ${install_dir}/distribution/policies.json"
  fi

  _ensure_dir "${policies_dir}" || die "cannot create ${policies_dir}"
  if [[ "${policies_dir}" == "/etc/firefox/policies" ]]; then
    sudo -n chmod 755 /etc/firefox "${policies_dir}" 2>/dev/null || true
  fi

  local can_chattr=false
  _can_sudo_chattr && can_chattr=true

  # idempotent: skip chattr cycle when content matches (no-TTY watcher refire safe).
  if _file_matches "${src}" "${dst}"; then
    local tag=""
    if _is_immutable "${dst}"; then
      tag=", immutable"
    elif ${can_chattr}; then
      if _relock_file "${dst}" policies.json; then
        tag=", immutable"
      fi
    fi
    ok "policies.json ($(_policy_count "${src}") policies${tag}, unchanged)"
    return 0
  fi

  _chattr_unlock "${dst}" || die "cannot unlock ${dst} (immutable)"
  if ! _install_file "${src}" "${dst}"; then
    if ${can_chattr} && [[ -f "${dst}" ]]; then
      _relock_file "${dst}" policies.json || true
    fi
    die "cannot write ${dst}"
  fi
  local tag=""
  if ${can_chattr} && _relock_file "${dst}" policies.json; then
    tag=", immutable"
  fi
  ok "policies.json ($(_policy_count "${src}") policies${tag})"
}

_deploy_userjs() {
  local profiles_dir="$1"
  local src="${_dir}/config/user.js"
  [[ -f "${src}" ]] || die "user.js not found in ${_dir}/config"

  local count deployed=0
  count=$(grep -c 'user_pref' "${src}" 2>/dev/null || true)
  count=${count:-0}

  local can_chattr=false
  _can_sudo_chattr && can_chattr=true

  local profile target found=0
  while IFS= read -r profile; do
    [[ -d "${profile}" ]] || continue
    ((found++)) || true
    target="${profile}/user.js"
    # idempotent: skip chattr cycle when user.js matches (no-TTY watcher refire safe).
    if _file_matches "${src}" "${target}"; then
      if ${can_chattr} && ! _is_immutable "${target}"; then
        _relock_file "${target}" "$(basename "${profile}"): user.js" || true
      fi
      ((deployed++)) || true
      continue
    fi
    if ! _chattr_unlock "${target}"; then
      warn "cannot unlock user.js in $(basename "${profile}") (immutable)"; continue
    fi
    if ! _install_file "${src}" "${target}"; then
      if ${can_chattr} && [[ -f "${target}" ]]; then
        _relock_file "${target}" "$(basename "${profile}"): user.js" || true
      fi
      warn "cannot copy user.js to $(basename "${profile}")"; continue
    fi
    if ${can_chattr}; then
      _relock_file "${target}" "$(basename "${profile}"): user.js" || true
    fi
    ((deployed++)) || true
  done < <(_all_profile_paths "${profiles_dir}")

  if (( deployed == 0 )); then
    if (( found == 0 )); then
      warn "no profile in ${profiles_dir} - launch Firefox first"
    else
      warn "user.js: ${found} profiles found but none writable"
    fi
    return 0
  fi
  local immutable=""
  ${can_chattr} && immutable=", immutable"
  ok "user.js -> ${deployed} profiles (${count} prefs${immutable})"
}

_deploy_homepage() {
  local profiles_dir="$1"
  local css_src="${_dir}/config/hifox.css"
  local logo_src="${_dir}/docs/hifox.png"
  if [[ ! -f "${css_src}" || ! -f "${logo_src}" ]]; then
    warn "homepage: assets missing"
    return 0
  fi
  [[ -d "${profiles_dir}" ]] || return 0

  local count=0 candidates=0 p name css_dst logo_dst
  for p in "${profiles_dir}"/*; do
    [[ -d "${p}" ]] || continue
    name=$(basename "${p}")
    case "${name}" in
      default-release|default|*.default-release*|*.default) ;;
      *) continue ;;
    esac
    ((candidates++)) || true
    mkdir -p "${p}/chrome" || { warn "homepage: cannot create chrome dir: ${name}"; continue; }
    css_dst="${p}/chrome/userContent.css"
    logo_dst="${p}/chrome/hifox.png"
    if { _file_matches "${css_src}" "${css_dst}" || _install_file "${css_src}" "${css_dst}"; } \
      && { _file_matches "${logo_src}" "${logo_dst}" || _install_file "${logo_src}" "${logo_dst}"; }; then
      ((count++)) || true
    fi
  done
  if (( count > 0 )); then
    ok "homepage: hifox branding -> ${count} profiles"
  elif (( candidates > 0 )); then
    warn "homepage: copy failed (${candidates} candidates, 0 succeeded)"
  fi
}

_deploy_autoconfig() {
  local sysconfig_dir="$1"

  [[ -f "${_dir}/config/autoconfig.js" ]] || die "autoconfig.js not found"
  [[ -f "${_dir}/config/global_lockprefs.cfg" ]] || die "global_lockprefs.cfg not found"
  [[ -f "${_dir}/webapp/shared/webapp.cfg" ]] || die "webapp.cfg not found"
  [[ -f "${_dir}/config/generate_pref_dump.cfg" ]] || die "generate_pref_dump.cfg not found"

  _ensure_dir "${sysconfig_dir}/defaults/pref" || die "cannot create ${sysconfig_dir}/defaults/pref"

  # idempotent: skip writes when content matches (no-TTY watcher refire safe).
  local js_dst="${sysconfig_dir}/defaults/pref/autoconfig.js"
  if ! _file_matches "${_dir}/config/autoconfig.js" "${js_dst}"; then
    _install_file "${_dir}/config/autoconfig.js" "${js_dst}" \
      || die "cannot write autoconfig.js to ${sysconfig_dir}"
  fi

  local tmp
  tmp=$(mktemp)
  # ${tmp:-} keeps EXIT trap safe after the function-local goes out of scope.
  trap 'rm -f "${tmp:-}"' EXIT
  _generate_autoconfig > "${tmp}" || die "cannot generate autoconfig.cfg"
  local cfg_dst="${sysconfig_dir}/autoconfig.cfg"
  if _file_matches "${tmp}" "${cfg_dst}"; then
    rm -f "${tmp}"
    trap - EXIT
    ok "autoconfig.cfg (unchanged)"
    return 0
  fi
  _install_file "${tmp}" "${cfg_dst}" \
    || die "cannot write autoconfig.cfg to ${sysconfig_dir}"
  rm -f "${tmp}"
  trap - EXIT
  ok "autoconfig.cfg (generated)"
}

_register_profile() {
  local profiles_dir="$1" wname="$2"
  local ini="${profiles_dir}/profiles.ini"
  [[ -f "${ini}" ]] || return 0

  if grep -q "^Name=${wname}$" "${ini}" 2>/dev/null; then
    grep -q "^Path=${wname}$" "${ini}" 2>/dev/null \
      || warn "profiles.ini: ${wname} registered with a different Path - leaving as is"
    return 0
  fi

  local idx=0
  while grep -q "^\[Profile${idx}\]$" "${ini}" 2>/dev/null; do
    idx=$((idx + 1))
  done

  printf '\n[Profile%d]\nName=%s\nIsRelative=1\nPath=%s\n' \
    "${idx}" "${wname}" "${wname}" >> "${ini}"
}

_fix_start_with_last_profile() {
  local profiles_dir="$1"
  local ini="${profiles_dir}/profiles.ini"
  [[ -f "${ini}" ]] || return 0

  if grep -q "^StartWithLastProfile=0$" "${ini}" 2>/dev/null; then
    sed -i 's/^StartWithLastProfile=0$/StartWithLastProfile=1/' "${ini}"
    ok "profiles.ini: StartWithLastProfile -> 1"
  fi
}

_deploy_webapp_profiles() {
  local profiles_dir="$1"
  mkdir -p "${profiles_dir}"
  if [[ ! -f "${profiles_dir}/profiles.ini" ]]; then
    printf '[General]\nStartWithLastProfile=1\nVersion=2\n' > "${profiles_dir}/profiles.ini"
  fi

  _fix_start_with_last_profile "${profiles_dir}"

  local css_src="${_dir}/webapp/shared/webapp.css"

  local wdir wname wprofile
  for wdir in "${_dir}/webapp"/*/; do
    [[ -d "${wdir}" ]] || continue
    wname=$(basename "${wdir}")
    [[ "${wname}" == "shared" ]] && continue
    if ! _is_valid_webapp_name "${wname}"; then
      warn "skipping invalid webapp name: ${wname}"
      continue
    fi

    wprofile="${profiles_dir}/${wname}"
    if ! mkdir -p "${wprofile}/chrome"; then
      warn "${wname}: profile creation failed"
      continue
    fi
    _register_profile "${profiles_dir}" "${wname}"

    local css_dst="${wprofile}/chrome/userChrome.css" css_tmp
    css_tmp=$(mktemp) || die "cannot create temporary webapp stylesheet"
    if {
      cat "${css_src}"
      if [[ -f "${wdir}/userChrome.css" ]]; then
        printf '\n'
        cat "${wdir}/userChrome.css"
      fi
    } > "${css_tmp}" && _install_file "${css_tmp}" "${css_dst}"; then
      ok "${wname}: profile ready"
    else
      warn "${wname}: file copy failed"
    fi
    rm -f "${css_tmp}"
  done
}

_deploy_desktop_entries() {
  local installations="${1:-}" launcher="${_dir}/launch.sh"
  local desktop_dir
  desktop_dir="$(_desktop_dir)"
  local pixmap_dir="${HOME}/.local/share/pixmaps"

  if [[ -z "${installations}" ]]; then
    installations=$(_active_installations) || return 1
  fi
  local t pdir poldir sdir desktop_error=false
  IFS='|' read -r t pdir poldir sdir <<< "${installations%%$'\n'*}"
  [[ -n "${t}" ]] || return 1

  local icon="org.mozilla.firefox"
  if [[ "${t}" == "standard" ]]; then
    icon="firefox"
    [[ -f "${sdir}/browser/chrome/icons/default/default128.png" ]] && \
      icon="${sdir}/browser/chrome/icons/default/default128.png"
  fi

  mkdir -p "${desktop_dir}"
  local expected=()
  local ff_basename="firefox.desktop"
  [[ "${t}" == "flatpak" ]] && ff_basename="org.mozilla.firefox.desktop"
  local ff_entry="${desktop_dir}/${ff_basename}"
  expected+=("${ff_basename}")
  local ff_tmp
  ff_tmp=$(mktemp) || die "cannot create temporary desktop entry"
  printf '%s\n' \
    "[Desktop Entry]" \
    "Name=Firefox" \
    "Comment=hifox-managed Firefox" \
    "Exec=\"${launcher}\" --target ${t} %u" \
    "Icon=${icon}" \
    "Type=Application" \
    "Categories=Network;WebBrowser;" \
    "StartupNotify=true" \
    "StartupWMClass=firefox" > "${ff_tmp}"
  if _install_file "${ff_tmp}" "${ff_entry}"; then
    ok "${t}: Firefox shadow -> ${ff_basename}"
  else
    warn "cannot write desktop entry: ${ff_basename}"
    desktop_error=true
  fi
  rm -f "${ff_tmp}"

  local wdir wname
  for wdir in "${_dir}/webapp"/*/; do
    [[ -d "${wdir}" ]] || continue
    wname=$(basename "${wdir}")
    [[ "${wname}" == "shared" ]] && continue
    _is_valid_webapp_name "${wname}" || continue

    local icon_target=""
    if [[ -f "${wdir}/${wname}.png" ]]; then
      mkdir -p "${pixmap_dir}"
      local icon_hash
      icon_hash=$(cksum "${wdir}/${wname}.png" | awk '{print $1}')
      icon_target="${pixmap_dir}/${wname}-${icon_hash}.png"
      command rm -f "${pixmap_dir}/${wname}.png" "${pixmap_dir}/${wname}"-[0-9]*.png 2>/dev/null || true
      if ! _install_file "${wdir}/${wname}.png" "${icon_target}"; then
        warn "${wname}: icon copy failed"
        desktop_error=true
        icon_target=""
      fi
    fi

    [[ -f "${wdir}/${wname}.desktop" ]] || continue
    local desktop_file="${desktop_dir}/org.mozilla.firefox.${wname}-web.desktop"
    expected+=("$(basename "${desktop_file}")")
    local content desktop_tmp
    content=$(<"${wdir}/${wname}.desktop")
    content="${content//__LAUNCH_SH__/\"${launcher}\" --target ${t}}"
    desktop_tmp=$(mktemp) || die "cannot create temporary desktop entry"
    printf '%s\n' "${content}" > "${desktop_tmp}"
    [[ -z "${icon_target}" ]] || sed -i "s|^Icon=.*$|Icon=${icon_target}|" "${desktop_tmp}"
    if _install_file "${desktop_tmp}" "${desktop_file}"; then
      ok "${wname}: .desktop -> $(basename "${desktop_file}")"
    else
      warn "${wname}: desktop-entry write failed"
      desktop_error=true
    fi
    rm -f "${desktop_tmp}"
  done

  local entry exp keep
  for entry in "${desktop_dir}"/org.mozilla.firefox.*-web.desktop \
    "${desktop_dir}"/org.mozilla.firefox.*-web@*.desktop \
    "${desktop_dir}"/org.mozilla.firefox.hifox-*.desktop \
    "${desktop_dir}"/org.mozilla.firefox.desktop \
    "${desktop_dir}"/firefox.desktop; do
    [[ -f "${entry}" ]] || continue
    grep -qi 'hifox' "${entry}" 2>/dev/null || continue
    keep=false
    for exp in "${expected[@]}"; do
      [[ "$(basename "${entry}")" == "${exp}" ]] && keep=true && break
    done
    ${keep} && continue
    local stripped
    stripped=$(basename "${entry}")
    stripped="${stripped#org.mozilla.firefox.}"
    stripped="${stripped%.desktop}"
    stripped="${stripped%@*}"
    stripped="${stripped%-web}"
    rm -f "${entry}"
    if [[ ! -d "${_dir}/webapp/${stripped}" ]]; then
      command rm -f "${pixmap_dir}/${stripped}.png" "${pixmap_dir}/${stripped}"-[0-9]*.png 2>/dev/null || true
    fi
    ok "pruned: $(basename "${entry}")"
  done
  ! ${desktop_error}
}

hifox_deploy() {
  _require_firefox

  local installations
  installations=$(_active_installations) || die "cannot determine active Firefox installation"
  [[ -n "${installations}" ]] || die "no active Firefox installation"
  local check_type check_pdir check_poldir check_sdir profile_state
  while IFS='|' read -r check_type check_pdir check_poldir check_sdir; do
    [[ -e "${check_pdir}/profiles.ini" || -L "${check_pdir}/profiles.ini" ]] || continue
    profile_state=0
    _list_profile_paths "${check_pdir}" >/dev/null 2>&1 || profile_state=$?
    case "${profile_state}" in
      2) die "${check_type}: profiles.ini contains an unsafe profile path" ;;
      3) warn "${check_type}: profiles.ini contains a profile path that does not exist yet" ;;
      4) die "${check_type}: profiles.ini cannot be read reliably" ;;
    esac
  done <<< "${installations}"

  log "deploying browser hardening..."
  echo ""
  local had_error=false
  local type pdir poldir sdir
  while IFS='|' read -r type pdir poldir sdir; do
    log "${type}"
    if (
      _deploy_policies "${poldir}" "${sdir}"
      _deploy_autoconfig "${sdir}"
      _deploy_webapp_profiles "${pdir}"
      _deploy_homepage "${pdir}"
      _deploy_userjs "${pdir}"
    ); then :; else
      warn "${type}: deploy failed"
      had_error=true
    fi
  done <<< "${installations}"

  if ${had_error}; then
    die "deploy failed - skipping .desktop entries (no orphan icons)"
  fi

  _deploy_desktop_entries "${installations}" || die "desktop entry deployment failed"
  echo ""
  if systemctl --user is-active hifox-watch.path &>/dev/null; then
    (hifox_watch_install) 2>/dev/null || warn "watcher refresh failed - run: hifox watch install"
  fi

  hifox_clean \
    || warn "remnant cleanup skipped - close Firefox and run: hifox clean"
  ok "deploy complete"
}
