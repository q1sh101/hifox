#!/usr/bin/env bash
# lib/deploy.sh - deploy policies + user.js + autoconfig
# shellcheck disable=SC2154  # _dir provided by hifox.sh

# --- policies.json ---
_deploy_policies() {
  local policies_dir="$1"
  local src="${_dir}/config/policies.json"
  [[ -f "$src" ]] || die "policies.json not found in ${_dir}/config"

  if command -v python3 &>/dev/null; then
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$src" 2>/dev/null \
      || die "policies.json: invalid JSON"
  fi

  _ensure_dir "$policies_dir" || die "cannot create $policies_dir"
  _install_file "$src" "${policies_dir}/policies.json" \
    || die "cannot write ${policies_dir}/policies.json"

  local count="?"
  if command -v python3 &>/dev/null; then
    count=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('policies',{})))" \
      "$src" 2>/dev/null || echo "?")
  fi
  ok "policies.json (${count} policies)"
}

# --- user.js ---
_deploy_userjs() {
  local profiles_dir="$1"
  local src="${_dir}/config/user.js"
  [[ -f "$src" ]] || die "user.js not found in ${_dir}/config"

  local count deployed=0
  count=$(grep -c 'user_pref' "$src" 2>/dev/null || echo "?")

  local profile target
  while IFS= read -r profile; do
    [[ -d "$profile" ]] || continue
    target="${profile}/user.js"
    cp "$src" "$target" 2>/dev/null || { warn "cannot copy user.js to $(basename "$profile")"; continue; }
    ((deployed++)) || true
  done < <(_list_profile_paths "$profiles_dir" 2>/dev/null || _find_profile "$profiles_dir" 2>/dev/null)

  if (( deployed == 0 )); then
    warn "no profile in $profiles_dir - launch Firefox first"
    return 0
  fi
  ok "user.js -> ${deployed} profiles (${count} prefs)"
}

# --- autoconfig ---
_deploy_autoconfig() {
  local sysconfig_dir="$1"

  [[ -f "${_dir}/config/autoconfig.js" ]] || die "autoconfig.js not found"
  [[ -f "${_dir}/config/global_lockprefs.cfg" ]] || die "global_lockprefs.cfg not found"

  _ensure_dir "$sysconfig_dir/defaults/pref" || die "cannot create $sysconfig_dir/defaults/pref"

  _install_file "${_dir}/config/autoconfig.js" "$sysconfig_dir/defaults/pref/autoconfig.js" \
    || die "cannot write autoconfig.js to $sysconfig_dir"

  local tmp
  tmp=$(mktemp)
  trap "rm -f '$tmp'" EXIT
  _generate_autoconfig > "$tmp"
  _install_file "$tmp" "$sysconfig_dir/autoconfig.cfg" \
    || { rm -f "$tmp"; die "cannot write autoconfig.cfg to $sysconfig_dir"; }
  rm -f "$tmp"

  ok "autoconfig.cfg (generated)"
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
    if (
      _deploy_policies "$poldir"
      _deploy_userjs "$pdir"
      _deploy_autoconfig "$sdir"
    ); then :; else
      warn "$type: deploy failed"
      had_error=true
    fi
  done < <(_active_installations)

  echo ""
  if $had_error; then
    die "some installations failed - see above"
  fi
  log "done - restart Firefox"
}
