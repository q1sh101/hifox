#!/usr/bin/env bash
# lib/deploy.sh - deploy policies + user.js + autoconfig + webapp profiles
# shellcheck disable=SC2154  # _dir provided by hifox.sh

# --- policies.json ---
_deploy_policies() {
  local policies_dir="$1"
  local src="${_dir}/config/policies.json"
  [[ -f "$src" ]] || die "policies.json not found in ${_dir}/config"

  # validate JSON syntax
  if command -v python3 &>/dev/null; then
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$src" 2>/dev/null \
      || die "policies.json: invalid JSON"
  fi

  _ensure_dir "$policies_dir" || die "cannot create $policies_dir"

  # immutable (requires passwordless sudo)
  local can_chattr=false
  _can_sudo_chattr && can_chattr=true

  if [[ -f "${policies_dir}/policies.json" ]] && $can_chattr; then
    sudo -n chattr -i "${policies_dir}/policies.json" 2>/dev/null || true
  fi
  # re-lock even on failure - never leave policies.json writable
  if ! _install_file "$src" "${policies_dir}/policies.json"; then
    if $can_chattr && [[ -f "${policies_dir}/policies.json" ]]; then
      sudo -n chattr +i "${policies_dir}/policies.json" 2>/dev/null || true
    fi
    die "cannot write ${policies_dir}/policies.json"
  fi
  local immutable=""
  if $can_chattr && sudo -n chattr +i "${policies_dir}/policies.json" 2>/dev/null; then
    immutable=", immutable"
  fi

  local count="?"
  if command -v python3 &>/dev/null; then
    count=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('policies',{})))" \
      "$src" 2>/dev/null || echo "?")
  fi
  ok "policies.json (${count} policies${immutable})"
}

# --- user.js ---
_deploy_userjs() {
  local profiles_dir="$1"
  local src="${_dir}/config/user.js"
  [[ -f "$src" ]] || die "user.js not found in ${_dir}/config"

  local count deployed=0
  count=$(grep -c 'user_pref' "$src" 2>/dev/null || echo "?")

  # malware can inject user_pref() - lockPref wins, but why leave the door open
  local can_chattr=false
  _can_sudo_chattr && can_chattr=true

  # deploy to all known profiles (matches status.sh coverage)
  local profile target
  while IFS= read -r profile; do
    [[ -d "$profile" ]] || continue
    target="${profile}/user.js"
    if [[ -f "$target" ]] && $can_chattr; then
      sudo -n chattr -i "$target" 2>/dev/null || true
    fi
    # re-lock even on failure - never leave user.js writable
    if ! cp "$src" "$target" 2>/dev/null; then
      if $can_chattr && [[ -f "$target" ]]; then
        sudo -n chattr +i "$target" 2>/dev/null || true
      fi
      warn "cannot copy user.js to $(basename "$profile")"; continue
    fi
    if $can_chattr; then sudo -n chattr +i "$target" 2>/dev/null || true; fi
    ((deployed++)) || true
  done < <(_all_profile_paths "$profiles_dir")

  if (( deployed == 0 )); then
    warn "no profile in $profiles_dir - launch Firefox first"
    return 0
  fi
  local immutable=""
  $can_chattr && immutable=", immutable"
  ok "user.js -> ${deployed} profiles (${count} prefs${immutable})"
}

# --- autoconfig ---
_deploy_autoconfig() {
  local sysconfig_dir="$1"

  # validate source files before creating tmpfile
  [[ -f "${_dir}/config/autoconfig.js" ]] || die "autoconfig.js not found"
  [[ -f "${_dir}/config/global_lockprefs.cfg" ]] || die "global_lockprefs.cfg not found"
  [[ -f "${_dir}/webapp/shared/webapp.cfg" ]] || die "webapp.cfg not found"
  [[ -f "${_dir}/config/generate_pref_dump.cfg" ]] || die "generate_pref_dump.cfg not found"

  _ensure_dir "$sysconfig_dir/defaults/pref" || die "cannot create $sysconfig_dir/defaults/pref"

  # bootstrap loader
  _install_file "${_dir}/config/autoconfig.js" "$sysconfig_dir/defaults/pref/autoconfig.js" \
    || die "cannot write autoconfig.js to $sysconfig_dir"

  # generate autoconfig.cfg from head + per-webapp prefs + tail
  local tmp
  tmp=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT  # scoped to deploy subshell
  _generate_autoconfig > "$tmp"
  _install_file "$tmp" "$sysconfig_dir/autoconfig.cfg" \
    || { rm -f "$tmp"; die "cannot write autoconfig.cfg to $sysconfig_dir"; }
  rm -f "$tmp"

  ok "autoconfig.cfg (generated)"
}

# --- register webapp profile in profiles.ini ---
_register_profile() {
  local profiles_dir="$1" wname="$2"
  local ini="$profiles_dir/profiles.ini"
  [[ -f "$ini" ]] || return 0

  # already registered?
  if grep -q "^Name=${wname}$" "$ini" 2>/dev/null; then
    return 0
  fi

  # find next free [ProfileN] index
  local idx=0
  while grep -q "^\[Profile${idx}\]$" "$ini" 2>/dev/null; do
    idx=$((idx + 1))
  done

  # append profile entry
  printf '\n[Profile%d]\nName=%s\nIsRelative=1\nPath=%s\n' \
    "$idx" "$wname" "$wname" >> "$ini"
}

# --- fix StartWithLastProfile ---
_fix_start_with_last_profile() {
  local profiles_dir="$1"
  local ini="$profiles_dir/profiles.ini"
  [[ -f "$ini" ]] || return 0

  if grep -q "^StartWithLastProfile=0$" "$ini" 2>/dev/null; then
    sed -i 's/^StartWithLastProfile=0$/StartWithLastProfile=1/' "$ini"
    ok "profiles.ini: StartWithLastProfile -> 1"
  fi
}

# --- webapp profiles (per-installation) ---
_deploy_webapp_profiles() {
  local profiles_dir="$1"
  [[ -d "$profiles_dir" ]] || return 0
  [[ -f "$profiles_dir/profiles.ini" ]] || return 0

  _fix_start_with_last_profile "$profiles_dir"

  local userjs_src="${_dir}/config/user.js"
  local css_src="${_dir}/webapp/shared/webapp.css"

  local can_chattr=false
  _can_sudo_chattr && can_chattr=true

  local wdir wname wprofile
  for wdir in "${_dir}/webapp"/*/; do
    [[ -d "$wdir" ]] || continue
    wname=$(basename "$wdir")
    [[ "$wname" == "shared" ]] && continue
    if ! _is_valid_webapp_name "$wname"; then
      warn "skipping invalid webapp name: $wname"
      continue
    fi

    wprofile="$profiles_dir/$wname"
    [[ -d "$wprofile" ]] || mkdir -p "$wprofile"
    _register_profile "$profiles_dir" "$wname"

    if [[ -d "$wprofile" ]]; then
      # unlock before overwrite (same protection as main profiles)
      if [[ -f "$wprofile/user.js" ]] && $can_chattr; then
        sudo -n chattr -i "$wprofile/user.js" 2>/dev/null || true
      fi
      if mkdir -p "$wprofile/chrome" \
        && cp "$css_src" "$wprofile/chrome/userChrome.css" \
        && cp "$userjs_src" "$wprofile/user.js"; then
        if $can_chattr; then sudo -n chattr +i "$wprofile/user.js" 2>/dev/null || true; fi
        ok "$wname: profile ready"
      else
        # re-lock even on failure
        if $can_chattr && [[ -f "$wprofile/user.js" ]]; then
          sudo -n chattr +i "$wprofile/user.js" 2>/dev/null || true
        fi
        warn "$wname: file copy failed"
      fi
    else
      warn "$wname: profile creation failed"
    fi
  done
}

# --- webapp .desktop + icons (once globally) ---
_deploy_webapp_desktop() {
  local launcher="${_dir}/launch.sh"
  local desktop_dir
  desktop_dir="$(_desktop_dir)"
  local pixmap_dir="$HOME/.local/share/pixmaps"

  local wdir wname
  for wdir in "${_dir}/webapp"/*/; do
    [[ -d "$wdir" ]] || continue
    wname=$(basename "$wdir")
    [[ "$wname" == "shared" ]] && continue
    _is_valid_webapp_name "$wname" || continue

    # icon (cache-bust via checksum)
    local icon_target=""
    if [[ -f "$wdir/$wname.png" ]]; then
      mkdir -p "$pixmap_dir"
      local icon_hash
      icon_hash=$(cksum "$wdir/$wname.png" | awk '{print $1}')
      icon_target="$pixmap_dir/${wname}-${icon_hash}.png"
      command rm -f "$pixmap_dir"/"${wname}".png "$pixmap_dir"/"${wname}"-*.png 2>/dev/null || true
      cp "$wdir/$wname.png" "$icon_target"
      chmod 644 "$icon_target" 2>/dev/null || true
    fi

    # .desktop entry (quote launcher path for Desktop Entry spec)
    if [[ -f "$wdir/$wname.desktop" ]]; then
      mkdir -p "$desktop_dir"
      local desktop_file="$desktop_dir/org.mozilla.firefox.${wname}-web.desktop"
      local desktop_content launcher_quoted
      desktop_content=$(<"$wdir/$wname.desktop")
      launcher_quoted="\"${launcher}\""
      printf '%s\n' "${desktop_content//__LAUNCH_SH__/$launcher_quoted}" > "$desktop_file"
      if [[ -n "$icon_target" ]]; then
        sed -i "s|^Icon=.*$|Icon=$icon_target|" "$desktop_file"
      fi
      chmod 644 "$desktop_file" 2>/dev/null || true
      ok "$wname: .desktop -> $(basename "$desktop_file")"
    fi
  done

  # prune orphaned desktop entries (webapp removed from repo)
  local entry
  for entry in "$desktop_dir"/org.mozilla.firefox.*-web.desktop; do
    [[ -f "$entry" ]] || continue
    local entry_wname
    entry_wname=$(basename "$entry")
    entry_wname="${entry_wname#org.mozilla.firefox.}"
    entry_wname="${entry_wname%-web.desktop}"
    if [[ ! -d "${_dir}/webapp/$entry_wname" ]]; then
      rm -f "$entry"
      command rm -f "$pixmap_dir"/"${entry_wname}".png "$pixmap_dir"/"${entry_wname}"-*.png 2>/dev/null || true
      ok "pruned orphan: $entry_wname"
    fi
  done
}

# --- orchestrator ---
hifox_deploy() {
  _require_firefox

  log "deploying browser hardening..."
  echo ""
  local had_error=false
  local type pdir poldir sdir
  while IFS='|' read -r type pdir poldir sdir; do
    log "$type"
    # subshell: die exits here, not the main loop
    if (
      _deploy_policies "$poldir"
      _deploy_userjs "$pdir"
      _deploy_autoconfig "$sdir"
      _deploy_webapp_profiles "$pdir"
    ); then :; else
      warn "$type: deploy failed"
      had_error=true
    fi
  done < <(_active_installations)

  _deploy_webapp_desktop
  echo ""
  # auto-refresh watcher if active (picks up new webapp dirs)
  if systemctl --user is-active hifox-watch.path &>/dev/null; then
    (hifox_watch_install) 2>/dev/null || warn "watcher refresh failed - run: hifox watch install"
  fi

  if $had_error; then
    die "some installations failed - see above"
  fi
  hifox_clean
  log "done - restart Firefox -> hifox verify"
}
