#!/usr/bin/env bash
# lib/verify.sh - Firefox pref integrity check
# shellcheck disable=SC2154  # _dir, _find_profile, etc. provided by hifox.sh

_hifox_verify() {
  local all_failures=()

  _check_file() {
    local src="$1" dst="$2" name="$3"
    if [[ ! -f "$dst" ]]; then
      failures+=("MISSING: $name")
    elif ! diff -q "$src" "$dst" &>/dev/null; then
      failures+=("DRIFT: $name")
    fi
  }

  local type pdir poldir sdir
  while IFS='|' read -r type pdir poldir sdir; do
    log "verifying $type..."

    # --- pref checks (main profile) ---
    local profile
    profile="$(_find_profile "$pdir")" || { log "$type: no profile yet - skipping"; continue; }
    local prefs="${profile}/prefs.js"

    local waited=0
    while [[ ! -s "$prefs" ]] && (( waited < 15 )); do
      sleep 1
      ((waited++))
    done
    if [[ ! -s "$prefs" ]]; then
      warn "$type: prefs.js empty after 15s"
      all_failures+=("$type: prefs.js empty")
      continue
    fi

    local checks=(
      '_user_js.canary|"hifox"|canary'
      'network.cookie.cookieBehavior|5|dFPI cookie isolation'
      'dom.security.https_only_mode|true|HTTPS-only mode'
      'media.eme.enabled|false|DRM disabled'
      'privacy.sanitize.sanitizeOnShutdown|true|shutdown sanitization'
    )

    local failures=()
    local ac="${sdir}/autoconfig.cfg"
    local check key expected desc actual
    for check in "${checks[@]}"; do
      IFS='|' read -r key expected desc <<< "$check"
      # check prefs.js (user_pref) first, then autoconfig.cfg base lockPrefs
      actual=$(grep -oP "user_pref\\(\"${key}\",\\s*\\K[^)]+(?=\\))" "$prefs" 2>/dev/null | tail -1 || true)
      if [[ -z "$actual" ]] && [[ -f "$ac" ]]; then
        actual=$(grep -oP "^lockPref\\(\"${key}\",\\s*\\K[^)]+(?=\\))" "$ac" 2>/dev/null | tail -1 || true)
      fi
      if [[ -z "$actual" ]]; then
        failures+=("MISSING: $desc")
      elif [[ "$actual" != "$expected" ]]; then
        failures+=("WRONG: $desc (got: $actual)")
      fi
    done

    # --- deploy integrity ---
    _check_file "${_dir}/config/policies.json" "${poldir}/policies.json" "policies.json"
    _check_file "${_dir}/config/autoconfig.js" "${sdir}/defaults/pref/autoconfig.js" "autoconfig.js"
    if [[ ! -f "${sdir}/autoconfig.cfg" ]]; then
      failures+=("MISSING: autoconfig.cfg")
    elif ! diff -q <(_generate_autoconfig) "${sdir}/autoconfig.cfg" &>/dev/null; then
      failures+=("DRIFT: autoconfig.cfg")
    fi

    # --- user.js integrity (all profiles) ---
    local uj_src="${_dir}/config/user.js"
    local _prof_path
    while IFS= read -r _prof_path; do
      [[ -d "$_prof_path" ]] || continue
      _check_file "$uj_src" "${_prof_path}/user.js" "user.js ($(basename "$_prof_path"))"
    done < <(_all_profile_paths "$pdir")

    # --- dump monitoring (auto-copy to repo when changed) ---
    local dump_src="${profile}/generated_pref_dump.txt"
    local dump_dst="${_dir}/config/generated_pref_dump.txt"
    if [[ ! -s "$dump_src" ]]; then
      failures+=("MISSING: pref dump (Firefox didn't generate it)")
    else
      if [[ ! -f "$dump_dst" ]] || ! diff -q "$dump_src" "$dump_dst" &>/dev/null; then
        if cp "$dump_src" "$dump_dst" 2>/dev/null; then
          ok "$type: pref dump updated in repo"
          notify-send "hifox: new prefs detected" \
            "git diff config/generated_pref_dump.txt" 2>/dev/null || true
        fi
      fi
    fi

    # --- dump error check ---
    local dump_err
    dump_err=$(grep -oP '_hifox\.pref_dump_error",\s*"\K[^"]+' "$prefs" 2>/dev/null || true)
    if [[ -n "$dump_err" ]]; then
      failures+=("DUMP FAILED: $dump_err")
    fi

    if (( ${#failures[@]} == 0 )); then
      ok "$type: all passed (${#checks[@]} prefs + policies + autoconfig)"
    else
      local msg
      for msg in "${failures[@]}"; do
        warn "$type: $msg"
        all_failures+=("$type: $msg")
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