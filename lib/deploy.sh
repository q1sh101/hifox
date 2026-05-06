#!/usr/bin/env bash
# shellcheck disable=SC2154  # _dir provided by hifox.sh

_deploy_policies() {
  local policies_dir="$1" install_dir="${2:-}"
  local src="${_dir}/config/policies.json"
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

  local can_chattr=false
  _can_sudo_chattr && can_chattr=true

  _chattr_unlock "${policies_dir}/policies.json" \
    || die "cannot unlock ${policies_dir}/policies.json (immutable)"
  if ! _install_file "${src}" "${policies_dir}/policies.json"; then
    if ${can_chattr} && [[ -f "${policies_dir}/policies.json" ]]; then
      sudo -n chattr +i "${policies_dir}/policies.json" 2>/dev/null \
        || warn "policies.json: re-lock failed - file remains writable"
    fi
    die "cannot write ${policies_dir}/policies.json"
  fi
  local immutable=""
  if ${can_chattr} && sudo -n chattr +i "${policies_dir}/policies.json" 2>/dev/null; then
    immutable=", immutable"
  fi

  local count="?"
  if _check_command python3; then
    count=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('policies',{})))" \
      "${src}" 2>/dev/null || echo "?")
  fi
  ok "policies.json (${count} policies${immutable})"
}

_deploy_userjs() {
  local profiles_dir="$1"
  local src="${_dir}/config/user.js"
  [[ -f "${src}" ]] || die "user.js not found in ${_dir}/config"

  local count deployed=0
  count=$(grep -c 'user_pref' "${src}" 2>/dev/null || echo "?")

  local can_chattr=false
  _can_sudo_chattr && can_chattr=true

  local profile target found=0
  while IFS= read -r profile; do
    [[ -d "${profile}" ]] || continue
    ((found++)) || true
    target="${profile}/user.js"
    if ! _chattr_unlock "${target}"; then
      warn "cannot unlock user.js in $(basename "${profile}") (immutable)"; continue
    fi
    if ! cp "${src}" "${target}" 2>/dev/null; then
      if ${can_chattr} && [[ -f "${target}" ]]; then
        sudo -n chattr +i "${target}" 2>/dev/null \
          || warn "$(basename "${profile}"): user.js re-lock failed - file remains writable"
      fi
      warn "cannot copy user.js to $(basename "${profile}")"; continue
    fi
    if ${can_chattr}; then
      sudo -n chattr +i "${target}" 2>/dev/null \
        || warn "$(basename "${profile}"): user.js chattr +i failed - file remains writable"
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
  local logo_src="${_dir}/hifox.png"
  if [[ ! -f "${css_src}" || ! -f "${logo_src}" ]]; then
    warn "homepage: assets missing"
    return 0
  fi

  local profile
  profile="$(_find_profile "${profiles_dir}")" || return 0
  mkdir -p "${profile}/chrome"
  if cp "${css_src}" "${profile}/chrome/userContent.css" \
    && cp "${logo_src}" "${profile}/chrome/hifox.png"; then
    ok "homepage: hifox branding"
  else
    warn "homepage: copy failed"
  fi
}

_deploy_autoconfig() {
  local sysconfig_dir="$1"

  # Flatpak Firefox only loads this dir after the systemconfig extension is registered.
  if [[ "${sysconfig_dir}" == *"/org.mozilla.firefox.systemconfig/"* ]]; then
    if _check_command flatpak && ! flatpak info org.mozilla.firefox.systemconfig &>/dev/null; then
      warn "flatpak: org.mozilla.firefox.systemconfig extension not registered"
      warn "  run: hifox install-systemconfig"
    fi
  fi

  [[ -f "${_dir}/config/autoconfig.js" ]] || die "autoconfig.js not found"
  [[ -f "${_dir}/config/global_lockprefs.cfg" ]] || die "global_lockprefs.cfg not found"
  [[ -f "${_dir}/webapp/shared/webapp.cfg" ]] || die "webapp.cfg not found"
  [[ -f "${_dir}/config/generate_pref_dump.cfg" ]] || die "generate_pref_dump.cfg not found"

  _ensure_dir "${sysconfig_dir}/defaults/pref" || die "cannot create ${sysconfig_dir}/defaults/pref"

  _install_file "${_dir}/config/autoconfig.js" "${sysconfig_dir}/defaults/pref/autoconfig.js" \
    || die "cannot write autoconfig.js to ${sysconfig_dir}"

  local tmp
  tmp=$(mktemp)
  trap 'rm -f "${tmp:?}"' EXIT
  _generate_autoconfig > "${tmp}"
  _install_file "${tmp}" "${sysconfig_dir}/autoconfig.cfg" \
    || { rm -f "${tmp:?}"; die "cannot write autoconfig.cfg to ${sysconfig_dir}"; }
  rm -f "${tmp:?}"
  trap - EXIT

  ok "autoconfig.cfg (generated)"
}

_register_profile() {
  local profiles_dir="$1" wname="$2"
  local ini="${profiles_dir}/profiles.ini"
  [[ -f "${ini}" ]] || return 0

  if grep -q "^Name=${wname}$" "${ini}" 2>/dev/null; then
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
  [[ -d "${profiles_dir}" ]] || return 0
  [[ -f "${profiles_dir}/profiles.ini" ]] || return 0

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
    [[ -d "${wprofile}" ]] || mkdir -p "${wprofile}"
    _register_profile "${profiles_dir}" "${wname}"

    if [[ -d "${wprofile}" ]]; then
      if mkdir -p "${wprofile}/chrome" \
        && cp "${css_src}" "${wprofile}/chrome/userChrome.css"; then
        ok "${wname}: profile ready"
      else
        warn "${wname}: file copy failed"
      fi
    else
      warn "${wname}: profile creation failed"
    fi
  done
}

_deploy_webapp_desktop() {
  local launcher="${_dir}/launch.sh"
  local desktop_dir
  desktop_dir="$(_desktop_dir)"
  local pixmap_dir="${HOME}/.local/share/pixmaps"

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
      cp "${wdir}/${wname}.png" "${icon_target}"
      chmod 644 "${icon_target}" 2>/dev/null || true
    fi

    if [[ -f "${wdir}/${wname}.desktop" ]]; then
      mkdir -p "${desktop_dir}"
      local desktop_file="${desktop_dir}/org.mozilla.firefox.${wname}-web.desktop"
      local desktop_content launcher_quoted
      desktop_content=$(<"${wdir}/${wname}.desktop")
      launcher_quoted="\"${launcher}\""
      printf '%s\n' "${desktop_content//__LAUNCH_SH__/${launcher_quoted}}" > "${desktop_file}"
      if [[ -n "${icon_target}" ]]; then
        sed -i "s|^Icon=.*$|Icon=${icon_target}|" "${desktop_file}"
      fi
      chmod 644 "${desktop_file}" 2>/dev/null || true
      ok "${wname}: .desktop -> $(basename "${desktop_file}")"
    fi
  done

  local entry
  for entry in "${desktop_dir}"/org.mozilla.firefox.*-web.desktop; do
    [[ -f "${entry}" ]] || continue
    local entry_wname
    entry_wname=$(basename "${entry}")
    entry_wname="${entry_wname#org.mozilla.firefox.}"
    entry_wname="${entry_wname%-web.desktop}"
    if [[ ! -d "${_dir}/webapp/${entry_wname}" ]]; then
      rm -f "${entry}"
      command rm -f "${pixmap_dir}/${entry_wname}.png" "${pixmap_dir}/${entry_wname}"-[0-9]*.png 2>/dev/null || true
      ok "pruned orphan: ${entry_wname}"
    fi
  done
}

hifox_deploy() {
  _require_firefox

  log "deploying browser hardening..."
  echo ""
  local had_error=false
  local type pdir poldir sdir
  while IFS='|' read -r type pdir poldir sdir; do
    log "${type}"
    if (
      _deploy_policies "${poldir}" "${sdir}"
      _deploy_autoconfig "${sdir}"
      _deploy_homepage "${pdir}"
      _deploy_webapp_profiles "${pdir}"
      _deploy_userjs "${pdir}"
    ); then :; else
      warn "${type}: deploy failed"
      had_error=true
    fi
  done < <(_active_installations)

  _deploy_webapp_desktop
  echo ""
  if systemctl --user is-active hifox-watch.path &>/dev/null; then
    (hifox_watch_install) 2>/dev/null || warn "watcher refresh failed - run: hifox watch install"
  fi

  if ${had_error}; then
    die "some installations failed - see above"
  fi
  hifox_clean
  log "done - restart Firefox -> hifox verify"
}
