#!/usr/bin/env bash
# shellcheck disable=SC2154  # _dir provided by hifox.sh

hifox_status() {
  _require_firefox

  log "active: $(_read_target)"
  echo ""

  local type pdir poldir sdir
  while IFS='|' read -r type pdir poldir sdir; do
    log "${type}"

    log "user.js"
    local _checked_chrome=false
    if [[ -d "${pdir}" ]] && [[ -f "${pdir}/profiles.ini" ]]; then
      _checked_chrome=true
      local default_profile orphan_count=0
      default_profile=$(_find_profile "${pdir}" 2>/dev/null) || default_profile=""
      while IFS= read -r profile; do
        [[ -d "${profile}" ]] || continue
        local name
        name="$(basename "${profile}")"
        if [[ "${profile}" != "${default_profile}" ]] && [[ ! -d "${_dir}/webapp/${name}" ]]; then
          ((orphan_count++)) || true
          continue
        fi
        if [[ ! -f "${profile}/user.js" ]]; then
          warn "${name}  MISSING"
        elif _file_matches "${_dir}/config/user.js" "${profile}/user.js"; then
          ok "${name}  synced"
        else
          warn "${name}  DRIFT"
        fi
      done < <(_list_profile_paths "${pdir}")
      (( orphan_count > 0 )) && log "${orphan_count} unmanaged profiles (user.js deployed, not shown)"
    else
      warn "no profiles directory"
    fi

    if ${_checked_chrome}; then
      log "chrome assets"
      while IFS= read -r profile; do
        [[ -d "${profile}" ]] || continue
        local name
        name="$(basename "${profile}")"
        if [[ -d "${_dir}/webapp/${name}" ]]; then
          local webapp_css="${profile}/chrome/userChrome.css"
          if [[ ! -f "${webapp_css}" ]]; then
            warn "${name}  MISSING userChrome.css"
          elif cmp -s <(
            cat "${_dir}/webapp/shared/webapp.css"
            if [[ -f "${_dir}/webapp/${name}/userChrome.css" ]]; then
              printf '\n'
              cat "${_dir}/webapp/${name}/userChrome.css"
            fi
          ) "${webapp_css}"; then
            ok "${name}  synced"
          else
            warn "${name}  DRIFT userChrome.css"
          fi
        elif [[ "${profile}" == "${default_profile}" ]]; then
          local content_css="${profile}/chrome/userContent.css"
          local logo_png="${profile}/chrome/hifox.png"
          local issues=()
          if [[ ! -f "${content_css}" ]]; then
            issues+=("MISSING userContent.css")
          elif ! _file_matches "${_dir}/config/hifox.css" "${content_css}"; then
            issues+=("DRIFT userContent.css")
          fi
          if [[ ! -f "${logo_png}" ]]; then
            issues+=("MISSING hifox.png")
          elif ! _file_matches "${_dir}/docs/hifox.png" "${logo_png}"; then
            issues+=("DRIFT hifox.png")
          fi
          if (( ${#issues[@]} == 0 )); then
            ok "${name}  synced"
          else
            local issue
            for issue in "${issues[@]}"; do warn "${name}  ${issue}"; done
          fi
        fi
      done < <(_list_profile_paths "${pdir}")
    fi

    log "policies.json"
    if [[ ! -f "${poldir}/policies.json" ]]; then
      warn "MISSING"
    elif _file_matches "${_dir}/config/policies.json" "${poldir}/policies.json"; then
      ok "synced"
    else
      warn "DRIFT"
    fi

    log "autoconfig.cfg"
    if [[ ! -f "${sdir}/autoconfig.cfg" ]]; then
      warn "MISSING"
    elif cmp -s <(_generate_autoconfig) "${sdir}/autoconfig.cfg" 2>/dev/null; then
      ok "synced"
    else
      warn "DRIFT"
    fi

    log "immutability"
    local locked=0 total=0
    if [[ -f "${poldir}/policies.json" ]]; then
      ((total++)) || true
      _is_immutable "${poldir}/policies.json" && ((locked++)) || true
    fi
    while IFS= read -r profile; do
      [[ -f "${profile}/user.js" ]] || continue
      ((total++)) || true
      _is_immutable "${profile}/user.js" && ((locked++)) || true
    done < <(_list_profile_paths "${pdir}")
    if (( total == 0 )); then
      warn "no files to check"
    elif (( locked == total )); then
      ok "chattr +i (${locked}/${total} files)"
    elif (( locked == 0 )); then
      warn "posix-only (chattr unavailable)"
    else
      warn "partial (${locked}/${total} files locked)"
    fi
  done < <(_active_installations)
}
