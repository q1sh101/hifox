#!/usr/bin/env bash
# lib/purge.sh - nuclear wipe all browsing data from profiles

hifox_purge() {
  local target="${1:-}"
  local installs
  installs=$(_list_installations)
  [[ -n "$installs" ]] || die "no Firefox found (checked Flatpak + /usr/lib)"

  case "$target" in
    --flatpak)  installs=$(echo "$installs" | grep "^flatpak|" || true) ;;
    --standard) installs=$(echo "$installs" | grep "^standard|" || true) ;;
    "")         ;; # all
    *)          die "usage: hifox purge [--flatpak|--standard]" ;;
  esac
  [[ -n "$installs" ]] || die "no ${target#--} Firefox found"

  # --- confirm ---
  [[ -t 0 ]] || die "purge requires interactive terminal"
  warn "this deletes ALL browsing data (cookies, history, logins, cache, sessions)"
  warn "you will need to re-login everywhere"
  printf '  %b' "${_yellow}continue? [y/N]${_r} "
  local reply=""
  read -r reply || true
  [[ "$reply" == [yY] ]] || { log "aborted"; return 0; }

  # --- kill Firefox ---
  log "killing Firefox..."
  _kill_firefox
  sleep 1
  if pgrep -x firefox &>/dev/null || pgrep -x firefox-esr &>/dev/null; then
    die "Firefox still running - close it manually and retry"
  fi
  ok "Firefox stopped"

  # --- pause verify watcher ---
  local watcher_was_active=false
  if systemctl --user is-active hifox-verify.path &>/dev/null 2>&1 \
    || systemctl --user is-active hifox-verify.timer &>/dev/null 2>&1; then
    systemctl --user stop hifox-verify.path hifox-verify.timer 2>/dev/null || true
    watcher_was_active=true
  fi

  log "purging ALL browsing data..."
  echo ""
  local purged=0 profiles_done=0

  local _type pdir _poldir _sdir
  # shellcheck disable=SC2034
  while IFS='|' read -r _type pdir _poldir _sdir; do
    [[ -d "$pdir" ]] || continue
    log "$_type ($pdir)"

    # --- profile contents (keep only user.js + chrome/) ---
    local profile
    while IFS= read -r profile; do
      [[ -d "$profile" ]] || continue
      local pname count=0
      pname="$(basename "$profile")"

      if _can_sudo_chattr && [[ -f "$profile/user.js" ]]; then
        sudo -n chattr -i "$profile/user.js" 2>/dev/null || true
      fi

      local item base
      for item in "$profile"/* "$profile"/.*; do
        [[ -e "$item" ]] || continue
        base="$(basename "$item")"
        case "$base" in
          .|..)       continue ;;
          user.js)    continue ;;
          chrome)     continue ;;
          *)
            if rm -rf "${item:?}" 2>/dev/null; then
              ((count++)) || true
            else
              warn "cannot remove: $base"
            fi
            ;;
        esac
      done

      if _can_sudo_chattr && [[ -f "$profile/user.js" ]]; then
        sudo -n chattr +i "$profile/user.js" 2>/dev/null || true
      fi

      purged=$((purged + count))
      ((profiles_done++)) || true
      ok "$pname: $count items deleted"
    done < <(_all_profile_paths "$pdir")

    # --- profiles_dir: nuke stale files (keep dirs + ini) ---
    local item base
    for item in "$pdir"/* "$pdir"/.*; do
      [[ -e "$item" ]] || continue
      base="$(basename "$item")"
      case "$base" in
        .|..|profiles.ini|installs.ini) continue ;;
      esac
      [[ -d "$item" ]] && continue
      rm -rf "${item:?}" 2>/dev/null || true
    done

    # --- external: nuke non-config dirs ---
    if [[ "$_type" == "flatpak" ]]; then
      local fp_root="$HOME/.var/app/org.mozilla.firefox"
      local d
      for d in "$fp_root"/*/ "$fp_root"/.*/ ; do
        [[ -d "$d" ]] || continue
        base="$(basename "$d")"
        case "$base" in
          .|..|config) continue ;;
          *)           rm -rf "${d:?}" 2>/dev/null && ok "cleared: $base" ;;
        esac
      done
    else
      [[ -d "$HOME/.cache/mozilla" ]] && rm -rf "$HOME/.cache/mozilla" 2>/dev/null \
        && ok "cleared: ~/.cache/mozilla"
    fi
  done <<< "$installs"

  # --- /tmp: temp profiles (Browser Toolbox, debugging, etc.) ---
  local d
  for d in /tmp/rust_mozprofile* /tmp/.org.mozilla.firefox*; do
    [[ -d "$d" ]] && rm -rf "${d:?}" 2>/dev/null && ok "temp: $(basename "$d")"
  done

  # --- resume watcher ---
  if $watcher_was_active; then
    systemctl --user start hifox-verify.path hifox-verify.timer 2>/dev/null || true
    ok "verify watcher resumed"
  fi

  echo ""
  if (( purged == 0 )); then
    warn "nothing to purge (profiles empty or not found)"
  else
    log "$purged items obliterated across $profiles_done profiles"
    log "next Firefox launch = completely fresh (re-login everywhere)"
  fi
}
