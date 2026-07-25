#!/usr/bin/env bash
# shellcheck disable=SC2154  # _dir, _find_profile, etc. provided by hifox.sh

_hifox_verify() {
  local all_failures=()

  _check_file() {
    local src="$1" dst="$2" name="$3"
    if [[ ! -f "${dst}" ]]; then
      failures+=("MISSING: ${name}")
    elif ! diff -q "${src}" "${dst}" &>/dev/null; then
      failures+=("DRIFT: ${name}")
    fi
  }

  _older_than_any() {
    local probe="$1"
    shift
    local other
    for other in "$@"; do
      [[ -e "${other}" ]] || continue
      [[ "${probe}" -ot "${other}" ]] && return 0
    done
    return 1
  }

  local type pdir poldir sdir
  while IFS='|' read -r type pdir poldir sdir; do
    log "verifying ${type}..."

    local profile
    profile="$(_find_profile "${pdir}")" || { log "${type}: no profile yet - skipping"; continue; }
    local prefs="${profile}/prefs.js"

    local waited=0
    while [[ ! -s "${prefs}" ]] && (( waited < 15 )); do
      sleep 1
      ((waited++)) || true
    done
    if [[ ! -s "${prefs}" ]]; then
      warn "${type}: prefs.js empty after 15s"
      all_failures+=("${type}: prefs.js empty")
      continue
    fi

    local failures=()
    local ac="${sdir}/autoconfig.cfg"
    local ac_js="${sdir}/defaults/pref/autoconfig.js"
    local main_user_js="${profile}/user.js"
    local dump_src="${profile}/generated_pref_dump.txt"

    _check_file "${_dir}/config/policies.json" "${poldir}/policies.json" "policies.json"
    _check_file "${_dir}/config/autoconfig.js" "${ac_js}" "autoconfig.js"
    if [[ ! -f "${sdir}/autoconfig.cfg" ]]; then
      failures+=("MISSING: autoconfig.cfg")
    elif ! diff -q <(_generate_autoconfig) "${sdir}/autoconfig.cfg" &>/dev/null; then
      failures+=("DRIFT: autoconfig.cfg")
    fi

    local uj_src="${_dir}/config/user.js"
    local _prof_path
    while IFS= read -r _prof_path; do
      [[ -d "${_prof_path}" ]] || continue
      _check_file "${uj_src}" "${_prof_path}/user.js" "user.js ($(basename "${_prof_path}"))"
    done < <(_all_profile_paths "${pdir}")

    # If deployed files are newer than prefs.js or the dump, Firefox has not restarted into this config yet.
    if (( ${#failures[@]} == 0 )); then
      if _older_than_any "${prefs}" "${main_user_js}" "${ac_js}" "${ac}" "${poldir}/policies.json" \
        || { [[ -s "${dump_src}" ]] \
             && _older_than_any "${dump_src}" "${main_user_js}" "${ac_js}" "${ac}" "${poldir}/policies.json"; }; then
        ok "${type}: deploy staged - restart Firefox to apply"
        continue
      fi
    fi

    local checks=(
      '_user_js.canary|"hifox"|canary'
      'privacy.fingerprintingProtection|true|fingerprint protection'
      'privacy.fingerprintingProtection.overrides|"+AllTargets,-CSSPrefersColorScheme"|fingerprint overrides'
      'privacy.fingerprintingProtection.remoteOverrides.enabled|false|remote fingerprint overrides disabled'
      'privacy.resistFingerprinting|false|RFP disabled (using FPP instead)'
      'browser.cache.disk.enable|false|disk cache disabled'
      'security.ssl.require_safe_negotiation|true|safe TLS negotiation'
      'media.peerconnection.enabled|false|WebRTC disabled'
      'network.http.speculative-parallel-limit|0|speculative connections blocked'
      'browser.sessionstore.resume_from_crash|false|crash recovery disk writes'
      'permissions.memory_only|true|permissions RAM-only'
      'privacy.bounceTrackingProtection.mode|1|bounce tracking protection'
      'privacy.query_stripping.enabled|true|query parameter stripping'
      'network.cookie.cookieBehavior|5|dFPI cookie isolation'
      'dom.security.https_only_mode|true|HTTPS-only mode'
      'toolkit.telemetry.enabled|false|telemetry disabled'
      'network.dns.echconfig.enabled|true|encrypted client hello'
      'media.eme.enabled|false|DRM disabled'
      'webgl.disabled|true|WebGL disabled'
      'privacy.sanitize.sanitizeOnShutdown|true|shutdown sanitization'
      'geo.enabled|false|geolocation disabled'
      'app.normandy.enabled|false|remote experiments disabled'
      'security.OCSP.require|true|OCSP hard-fail'
      'security.enterprise_roots.enabled|false|system CA import blocked'
    )

    local check key key_re expected desc actual actual_raw
    if [[ ! -s "${dump_src}" ]]; then
      failures+=("MISSING: pref dump (Firefox didn't generate it)")
    else
      for check in "${checks[@]}"; do
        IFS='|' read -r key expected desc <<< "${check}"
        # escape dots in pref key: pref names contain '.' which is a regex meta-char
        key_re="${key//./\\.}"
        actual_raw=$(sed -n "s/^${key_re} = //p" "${dump_src}" 2>/dev/null | head -1 || true)
        actual="${actual_raw% \[LOCKED\]}"
        expected="${expected%\"}"
        expected="${expected#\"}"
        if [[ -z "${actual}" ]]; then
          failures+=("MISSING: ${desc}")
        elif [[ "${actual}" != "${expected}" ]]; then
          failures+=("WRONG: ${desc} (got: ${actual})")
        elif [[ "${key}" != _user_js.* && "${actual_raw}" == "${actual}" ]]; then
          failures+=("UNLOCKED: ${desc}")
        fi
      done
    fi

    local dump_dst="${_dir}/config/generated_pref_dump.${type}.txt"
    if [[ -s "${dump_src}" ]]; then
      if [[ ! -f "${dump_dst}" ]] || ! diff -q "${dump_src}" "${dump_dst}" &>/dev/null; then
        if cp "${dump_src}" "${dump_dst}" 2>/dev/null; then
          ok "${type}: pref dump updated in repo"
          notify-send "hifox: new prefs detected" \
            "git diff config/generated_pref_dump.${type}.txt" 2>/dev/null || true
        fi
      fi
    fi

    local wdir wname wdump wkey wexp wval wval_raw
    for wdir in "${_dir}/webapp"/*/; do
      [[ -d "${wdir}" ]] || continue
      wname=$(basename "${wdir}")
      [[ "${wname}" == "shared" ]] && continue
      [[ -f "${wdir}/prefs.cfg" ]] || continue
      wdump="${pdir}/${wname}/generated_pref_dump.txt"
      if [[ ! -s "${wdump}" ]]; then
        [[ -s "${pdir}/${wname}/prefs.js" ]] && failures+=("MISSING: ${wname}: pref dump")
        continue
      fi
      while IFS='|' read -r wkey wexp; do
        [[ -n "${wkey}" ]] || continue
        wval_raw=$(sed -n "s/^${wkey//./\\.} = //p" "${wdump}" 2>/dev/null | head -1 || true)
        wval="${wval_raw% \[LOCKED\]}"
        wexp="${wexp%\"}"
        wexp="${wexp#\"}"
        if [[ -z "${wval}" ]]; then
          failures+=("MISSING: ${wname}: ${wkey}")
        elif [[ "${wval}" != "${wexp}" ]]; then
          failures+=("WRONG: ${wname}: ${wkey} (got: ${wval})")
        elif [[ "${wval_raw}" == "${wval}" ]]; then
          failures+=("UNLOCKED: ${wname}: ${wkey}")
        fi
      done < <(sed -n 's/^lockPref("\([^"]*\)", *\(.*\));.*/\1|\2/p' "${wdir}/prefs.cfg")
    done

    local dump_err_file="${profile}/generated_pref_dump.err"
    if [[ -f "${dump_err_file}" && -s "${dump_err_file}" ]]; then
      failures+=("DUMP FAILED: $(<"${dump_err_file}")")
    fi

    if (( ${#failures[@]} == 0 )); then
      ok "${type}: all passed (${#checks[@]} prefs + policies + autoconfig)"
    else
      local msg
      for msg in "${failures[@]}"; do
        warn "${type}: ${msg}"
        all_failures+=("${type}: ${msg}")
      done
    fi
  done < <(_active_installations)

  if (( ${#all_failures[@]} > 0 )); then
    _kill_firefox
    notify-send -u critical "hifox: Firefox stopped - hardening broken" \
      "$(printf '%s\n' "${all_failures[@]}")" 2>/dev/null || true
    die "${#all_failures[@]} check(s) failed - run: hifox deploy"
  fi
}
