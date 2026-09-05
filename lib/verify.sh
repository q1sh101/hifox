#!/usr/bin/env bash
# shellcheck disable=SC2154  # shared helpers and _dir provided by hifox.sh

_verify_dump_valid() {
  local dump="$1" size
  [[ -s "${dump}" ]] || return 1
  size=$(wc -c < "${dump}" 2>/dev/null) || return 1
  (( size <= 8388608 )) || return 1
  # a truncated or foreign file must not read as "this pref is missing"
  LC_ALL=C awk '
    {
      sep = index($0, " =")
      if (sep < 2) exit 1
      # Firefox uses punctuation such as @ and * in legitimate pref names.
      if (substr($0, 1, sep - 1) !~ /^[!-<>-~]+$/) exit 1
    }
    END { if (NR == 0) exit 1 }
  ' "${dump}"
}

_verify_dump_value() {
  local dump="$1" wanted="$2"
  awk -v wanted="${wanted}" '
    {
      sep = index($0, " =")
      if (sep > 1 && substr($0, 1, sep - 1) == wanted) {
        value = substr($0, sep + 2)
        sub(/^ /, "", value)
        print value
        exit
      }
    }
  ' "${dump}" 2>/dev/null
}

_verify_pref_issue() {
  local dump="$1" key="$2" expected="$3" desc="$4" actual_raw actual
  actual_raw=$(_verify_dump_value "${dump}" "${key}")
  actual="${actual_raw% \[LOCKED\]}"
  expected="${expected%\"}"
  expected="${expected#\"}"
  if [[ -z "${actual_raw}" ]]; then
    printf 'MISSING: %s\n' "${desc}"
  elif [[ "${actual}" != "${expected}" ]]; then
    printf 'WRONG: %s (got: %s)\n' "${desc}" "${actual}"
  elif [[ "${key}" != _user_js.* && "${actual_raw}" == "${actual}" ]]; then
    printf 'UNLOCKED: %s\n' "${desc}"
  else
    return 1
  fi
}

_verify_snapshot_dump() {
  local src="$1" dst="$2" before after _device _inode _size mtime
  [[ -f "${src}" && ! -L "${src}" ]] || return 1
  before=$(stat -Lc '%d|%i|%s|%y' -- "${src}" 2>/dev/null) || return 1
  head -c 8388609 -- "${src}" > "${dst}" 2>/dev/null || return 1
  after=$(stat -Lc '%d|%i|%s|%y' -- "${src}" 2>/dev/null) || return 1
  [[ "${before}" == "${after}" ]] || return 1
  IFS='|' read -r _device _inode _size mtime <<< "${before}"
  touch -d "${mtime}" "${dst}" 2>/dev/null || return 1
  _verify_dump_valid "${dst}"
}

_verify_older_than_any() {
  local probe="$1"
  shift
  local other
  for other in "$@"; do
    [[ -e "${other}" ]] || continue
    [[ "${probe}" -ot "${other}" ]] && return 0
  done
  return 1
}

_verify_file_state() {
  local src="$1" dst="$2" state=0
  [[ ! -L "${dst}" ]] || return 3
  [[ -f "${dst}" ]] || return 2
  cmp -s "${src}" "${dst}" 2>/dev/null || state=$?
  (( state <= 1 )) || return 4
  return "${state}"
}

_verify_runtime_snapshot() {
  local profile="$1" snapshot="$2"
  shift 2
  [[ ! -s "${profile}/generated_pref_dump.err" ]] || return 1
  [[ -s "${profile}/generated_pref_dump.txt" ]] || return 2
  _verify_snapshot_dump "${profile}/generated_pref_dump.txt" "${snapshot}" || return 3
  _verify_older_than_any "${snapshot}" "$@" && return 4
  return 0
}

# git makes an accepted baseline reviewable; uncommitted edits are not, so keep them
_verify_baseline_writable() {
  local dst="$1" rel status
  [[ ! -L "${dst}" ]] || return 3
  [[ ! -e "${dst}" || -f "${dst}" ]] || return 3
  git -C "${_dir}" rev-parse --is-inside-work-tree &>/dev/null || return 2
  rel="${dst#"${_dir}"/}"
  status=$(git -C "${_dir}" status --porcelain=v1 --untracked-files=all -- "${rel}" 2>/dev/null) \
    || return 2
  [[ -z "${status}" ]]
}

_verify_write_baseline() {
  local src="$1" dst="$2" tmp
  tmp=$(mktemp "${dst}.tmp.XXXXXX") || return 1
  if cp "${src}" "${tmp}" 2>/dev/null \
    && chmod 644 "${tmp}" 2>/dev/null \
    && mv -f "${tmp}" "${dst}" 2>/dev/null; then
    return 0
  fi
  rm -f "${tmp}" 2>/dev/null || true
  return 1
}

_hifox_verify() {
  local verify_tmp
  verify_tmp=$(mktemp -d) || die "cannot create verification workspace"
  trap 'rm -rf "${verify_tmp:?}"' EXIT

  local installations
  installations=$(_active_installations) \
    || die "cannot determine active Firefox installation; verification unavailable"
  [[ -n "${installations}" ]] \
    || die "no active Firefox installation; verification unavailable"

  local expected_ac="${verify_tmp}/autoconfig.cfg"
  _generate_autoconfig > "${expected_ac}" \
    || die "cannot generate expected autoconfig; verification unavailable"

  local -a all_confirmed=() all_unavailable=() all_pending=()
  local -a baseline_types=() baseline_sources=() baseline_destinations=()
  local -a checks=(
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

  local -A check_keys=()
  local check_spec check_key
  for check_spec in "${checks[@]}"; do
    IFS='|' read -r check_key _ _ <<< "${check_spec}"
    check_keys["${check_key}"]=1
  done

  local type pdir poldir sdir
  while IFS='|' read -r type pdir poldir sdir; do
    [[ -n "${type}" ]] || continue
    log "verifying ${type}..."

    local -a confirmed=() unavailable=() pending=()
    local compare_state file_spec expected_file deployed_file file_label
    local ac="${sdir}/autoconfig.cfg"
    local ac_js="${sdir}/defaults/pref/autoconfig.js"
    local policy="${poldir}/policies.json"
    for file_spec in \
      "${_dir}/config/policies.json|${policy}|policies.json" \
      "${_dir}/config/autoconfig.js|${ac_js}|autoconfig.js" \
      "${expected_ac}|${ac}|autoconfig.cfg"; do
      IFS='|' read -r expected_file deployed_file file_label <<< "${file_spec}"
      compare_state=0
      _verify_file_state "${expected_file}" "${deployed_file}" || compare_state=$?
      case "${compare_state}" in
        0) ;;
        1) confirmed+=("DRIFT: ${file_label}") ;;
        2) confirmed+=("MISSING: ${file_label}") ;;
        3) confirmed+=("UNSAFE: ${file_label} is a symlink") ;;
        *) unavailable+=("UNREADABLE: ${file_label} comparison") ;;
      esac
    done

    local profile_paths="" profile_paths_state=0
    profile_paths=$(_all_profile_paths "${pdir}" 2>/dev/null) || profile_paths_state=$?
    if (( profile_paths_state == 2 || profile_paths_state == 3 || profile_paths_state == 4 )); then
      unavailable+=("UNSAFE/UNRESOLVED PROFILE DECLARATION: profiles.ini")
    fi

    local profile_path profile_name
    while IFS= read -r profile_path; do
      [[ -d "${profile_path}" ]] || continue
      profile_name=$(basename "${profile_path}")
      if [[ -L "${profile_path}/user.js" ]]; then
        confirmed+=("UNSAFE: user.js symlink (${profile_name})")
      elif [[ ! -f "${profile_path}/user.js" ]]; then
        confirmed+=("MISSING: user.js (${profile_name})")
      else
        compare_state=0
        cmp -s "${_dir}/config/user.js" "${profile_path}/user.js" 2>/dev/null || compare_state=$?
        case "${compare_state}" in
          0) ;;
          1) confirmed+=("DRIFT: user.js (${profile_name})") ;;
          *) unavailable+=("UNREADABLE: user.js comparison (${profile_name})") ;;
        esac
      fi
    done <<< "${profile_paths}"

    local profile="" profile_state=0 runtime_state=0
    profile=$(_find_profile "${pdir}" 2>/dev/null) || profile_state=$?
    if (( profile_state == 2 || profile_state == 4 )); then
      if (( profile_paths_state != 2 && profile_paths_state != 3 && profile_paths_state != 4 )); then
        unavailable+=("UNSAFE/UNRESOLVED/UNREADABLE DEFAULT PROFILE: profiles.ini declaration")
      fi
    elif [[ -z "${profile}" ]]; then
      log "${type}: no default profile; runtime checks not applicable"
    else
      local dump_snapshot="${verify_tmp}/${type}.main.dump"
      local main_ready=false
      runtime_state=0
      _verify_runtime_snapshot "${profile}" "${dump_snapshot}" \
        "${profile}/user.js" "${ac_js}" "${ac}" "${policy}" || runtime_state=$?
      case "${runtime_state}" in
        0) main_ready=true ;;
        1) unavailable+=("DUMP FAILED: default profile (see generated_pref_dump.err)") ;;
        2) pending+=("default profile") ;;
        3) unavailable+=("MALFORMED EVIDENCE: default profile pref dump") ;;
        4) pending+=("default profile") ;;
      esac

      if ${main_ready}; then
        local check key expected desc issue
        for check in "${checks[@]}"; do
          IFS='|' read -r key expected desc <<< "${check}"
          if issue=$(_verify_pref_issue "${dump_snapshot}" "${key}" "${expected}" "${desc}"); then
            confirmed+=("${issue}")
          fi
        done
        baseline_types+=("${type}")
        baseline_sources+=("${dump_snapshot}")
        baseline_destinations+=("${_dir}/config/generated_pref_dump.${type}.txt")
      fi
    fi

    local wdir wname wprofile wsnapshot
    for wdir in "${_dir}/webapp"/*/; do
      [[ -d "${wdir}" ]] || continue
      wname=$(basename "${wdir}")
      [[ "${wname}" == "shared" || ! -f "${wdir}/prefs.cfg" ]] && continue
      [[ -d "${pdir}/${wname}" ]] || continue
      # an unresolvable profile is not drift, so it must not stop the browser
      wprofile=$(_canonical_profile_path "${pdir}" "${pdir}/${wname}") || {
        unavailable+=("UNRESOLVED PROFILE: ${wname}")
        continue
      }
      if [[ ! -s "${wprofile}/prefs.js" ]]; then
        log "${type}: ${wname}: not yet initialized; runtime checks not applicable"
        continue
      fi

      wsnapshot="${verify_tmp}/${type}.${wname}.dump"
      runtime_state=0
      _verify_runtime_snapshot "${wprofile}" "${wsnapshot}" \
        "${wprofile}/user.js" "${ac_js}" "${ac}" "${policy}" || runtime_state=$?
      case "${runtime_state}" in
        0) ;;
        1) unavailable+=("DUMP FAILED: ${wname} (see generated_pref_dump.err)"); continue ;;
        2) pending+=("${wname}"); continue ;;
        3) unavailable+=("MALFORMED EVIDENCE: ${wname}: pref dump"); continue ;;
        4) pending+=("${wname}"); continue ;;
      esac

      local -A overrides=()
      local wkey wexp
      while IFS='|' read -r wkey wexp; do
        [[ -n "${wkey}" ]] || continue
        overrides["${wkey}"]="${wexp}"
      done < <(sed -n 's/^lockPref("\([^"]*\)", *\(.*\));.*/\1|\2/p' "${wdir}/prefs.cfg")

      local check key expected desc issue
      for check in "${checks[@]}"; do
        IFS='|' read -r key expected desc <<< "${check}"
        if [[ -n "${overrides[${key}]+set}" ]]; then
          expected="${overrides[${key}]}"
        fi
        if issue=$(_verify_pref_issue "${wsnapshot}" "${key}" "${expected}" "${wname}: ${desc}"); then
          confirmed+=("${issue}")
        fi
      done

      for wkey in "${!overrides[@]}"; do
        # already reported by its global description above; do not report twice
        [[ -z "${check_keys[${wkey}]+set}" ]] || continue
        wexp="${overrides[${wkey}]}"
        if issue=$(_verify_pref_issue "${wsnapshot}" "${wkey}" "${wexp}" "${wname}: ${wkey}"); then
          confirmed+=("${issue}")
        fi
      done
    done

    local msg
    for msg in "${confirmed[@]}"; do
      warn "${type}: ${msg}"
      all_confirmed+=("${type}: ${msg}")
    done
    for msg in "${unavailable[@]}"; do
      warn "${type}: ${msg}"
      all_unavailable+=("${type}: ${msg}")
    done
    if (( ${#pending[@]} > 0 )); then
      log "${type}: awaiting a Firefox restart - ${pending[*]}"
      all_pending+=("${pending[@]}")
    fi
    if (( ${#confirmed[@]} == 0 && ${#unavailable[@]} == 0 && ${#pending[@]} == 0 )); then
      ok "${type}: all applicable checks passed"
    fi
  done <<< "${installations}"

  if (( ${#all_confirmed[@]} == 0 && ${#all_unavailable[@]} == 0 )); then
    local i writable_state
    for ((i = 0; i < ${#baseline_sources[@]}; i++)); do
      cmp -s "${baseline_sources[i]}" "${baseline_destinations[i]}" 2>/dev/null && continue
      writable_state=0
      _verify_baseline_writable "${baseline_destinations[i]}" || writable_state=$?
      case "${writable_state}" in
        1) warn "${baseline_types[i]}: baseline has uncommitted changes - preserved"; continue ;;
        2) warn "${baseline_types[i]}: baseline state cannot be proven - preserved"; continue ;;
        3) warn "${baseline_types[i]}: baseline is not a plain file - preserved"; continue ;;
      esac
      if _verify_write_baseline "${baseline_sources[i]}" "${baseline_destinations[i]}"; then
        ok "${baseline_types[i]}: pref dump updated in repo"
        notify-send "hifox: new prefs detected" \
          "git diff config/generated_pref_dump.${baseline_types[i]}.txt" 2>/dev/null || true
      else
        warn "${baseline_types[i]}: baseline update failed"
      fi
    done
  fi

  if (( ${#all_confirmed[@]} > 0 )); then
    local -A stopped=()
    while IFS='|' read -r type pdir poldir sdir; do
      [[ -n "${stopped[${type}]+set}" ]] && continue
      local failure
      for failure in "${all_confirmed[@]}"; do
        [[ "${failure}" == "${type}: "* ]] || continue
        if _stop_firefox "${type}" "${sdir}" \
          && _wait_firefox_stopped "${type}" "${sdir}"; then
          stopped["${type}"]=1
        else
          warn "${type}: failed to stop selected Firefox target"
        fi
        break
      done
    done <<< "${installations}"
    local notice
    notice=$(printf '%s\n' "${all_confirmed[@]}" | head -n 32 | head -c 4000) || true
    notify-send -u critical "hifox: confirmed Firefox hardening drift" \
      "${notice}" 2>/dev/null || true
  fi

  rm -rf "${verify_tmp:?}"
  trap - EXIT
  if (( ${#all_confirmed[@]} > 0 || ${#all_unavailable[@]} > 0 )); then
    die "verify failed: ${#all_confirmed[@]} confirmed drift, ${#all_unavailable[@]} unreadable"
  fi
  if (( ${#all_pending[@]} > 0 )); then
    # no evidence is not drift: report the pending restart, do not fail
    log "no drift found; ${#all_pending[@]} profile(s) still need a Firefox restart"
  fi
}
