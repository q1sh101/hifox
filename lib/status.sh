#!/usr/bin/env bash
# lib/status.sh - show sync state between repo and live
# shellcheck disable=SC2154  # _dir provided by hifox.sh

hifox_status() {
  _require_firefox

  local type pdir poldir sdir
  while IFS='|' read -r type pdir poldir sdir; do
    log "$type"

    # compare repo user.js hash against managed profiles
    log "user.js"
    local repo_hash
    repo_hash=$(sha256sum "${_dir}/config/user.js" | cut -c1-12)
    if [[ -d "$pdir" ]] && [[ -f "$pdir/profiles.ini" ]]; then
      local default_profile orphan_count=0
      default_profile=$(_find_profile "$pdir" 2>/dev/null) || default_profile=""
      while IFS= read -r profile; do
        [[ -d "$profile" ]] || continue
        local name
        name="$(basename "$profile")"
        # separate managed profiles from unmanaged
        if [[ "$profile" != "$default_profile" ]] && [[ ! -d "${_dir}/webapp/$name" ]]; then
          ((orphan_count++)) || true
          continue
        fi
        if [[ -f "$profile/user.js" ]]; then
          local live_hash
          live_hash=$(sha256sum "$profile/user.js" | cut -c1-12)
          if [[ "$repo_hash" == "$live_hash" ]]; then
            ok "$name  synced"
          else
            warn "$name  DRIFT"
          fi
        else
          warn "$name  MISSING"
        fi
      done < <(_list_profile_paths "$pdir")
      (( orphan_count > 0 )) && log "$orphan_count unmanaged profiles (user.js deployed, not shown)"
    else
      warn "no profiles directory"
    fi

    # compare repo policies.json against deployed copy
    log "policies.json"
    local pol="${poldir}/policies.json"
    if [[ -f "$pol" ]]; then
      local pol_repo pol_live
      pol_repo=$(sha256sum "${_dir}/config/policies.json" | cut -c1-12)
      pol_live=$(sha256sum "$pol" | cut -c1-12)
      if [[ "$pol_repo" == "$pol_live" ]]; then
        ok "synced"
      else
        warn "DRIFT"
      fi
    else
      warn "MISSING"
    fi

    # regenerate expected autoconfig and compare against deployed
    log "autoconfig.cfg"
    local ac="${sdir}/autoconfig.cfg"
    if [[ -f "$ac" ]]; then
      local ac_live ac_expected
      ac_live=$(sha256sum "$ac" | cut -c1-12)
      ac_expected=$(_generate_autoconfig | sha256sum | cut -c1-12)
      if [[ "$ac_live" == "$ac_expected" ]]; then
        ok "synced"
      else
        warn "DRIFT"
      fi
    else
      warn "MISSING"
    fi
  done < <(_active_installations)
}
