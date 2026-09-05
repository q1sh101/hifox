#!/usr/bin/env bash
# shellcheck disable=SC2154  # shared helpers provided by hifox.sh

_purge_unit_state() {
  local unit="$1" state
  state=$(systemctl --user is-active "${unit}" 2>/dev/null) || true
  case "${state}" in
    active|activating|reloading|deactivating|inactive|failed|unknown)
      printf '%s\n' "${state}"
      ;;
    *) return 1 ;;
  esac
}

_purge_restore_watchers() {
  ${_purge_restore_armed:-false} || return 0
  if (( ${#_purge_watch_units[@]} == 0 )); then
    _purge_restore_armed=false
    return 0
  fi

  local start_err
  if ! start_err=$(systemctl --user start "${_purge_watch_units[@]}" 2>&1); then
    warn "verify watcher recovery failed: ${start_err}"
    warn "  start manually: systemctl --user start ${_purge_watch_units[*]}"
    return 1
  fi
  local unit state
  for unit in "${_purge_watch_units[@]}"; do
    state=$(_purge_unit_state "${unit}") || {
      warn "cannot verify watcher recovery: ${unit}"
      return 1
    }
    if [[ "${state}" != active ]]; then
      warn "verify watcher recovery incomplete: ${unit}"
      return 1
    fi
  done
  _purge_restore_armed=false
  ok "verify watcher resumed"
}

_purge_interrupted() {
  local status="$1"
  trap - EXIT INT TERM
  _purge_restore_watchers || true
  warn "purge interrupted; already deleted data cannot be recovered"
  exit "${status}"
}

_purge_profile_roots() {
  local type="$1" selected="$2" root candidate resolved emitted=false invalid=false
  if [[ "${type}" != flatpak ]]; then
    [[ -e "${selected}" || -L "${selected}" ]] || return 0
    resolved=$(_canonical_contained_path "${HOME}" "${selected}" 2>/dev/null) \
      || return 2
    [[ -d "${resolved}" ]] || return 2
    printf '%s\n' "${resolved}"
    return
  fi

  root="${HOME}/.var/app/org.mozilla.firefox"
  [[ -e "${root}" || -L "${root}" ]] || return 0
  root=$(_canonical_contained_path "${HOME}" "${root}" 2>/dev/null) || return 2
  for candidate in \
    "${root}/config/mozilla/firefox" \
    "${root}/.config/mozilla/firefox" \
    "${root}/.mozilla/firefox"; do
    [[ -e "${candidate}" || -L "${candidate}" ]] || continue
    resolved=$(_canonical_contained_path "${root}" "${candidate}" 2>/dev/null) || {
      invalid=true
      continue
    }
    [[ -d "${resolved}" ]] || { invalid=true; continue; }
    if [[ "${candidate}" == "${selected}" || -f "${resolved}/profiles.ini" ]]; then
      printf '%s\n' "${resolved}"
      emitted=true
    fi
  done
  if ! ${emitted} && [[ -e "${selected}" || -L "${selected}" ]]; then
    resolved=$(_canonical_contained_path "${root}" "${selected}" 2>/dev/null) || invalid=true
    if [[ -n "${resolved:-}" && -d "${resolved}" ]]; then
      printf '%s\n' "${resolved}"
    fi
  fi
  if ${invalid}; then
    return 2
  fi
  return 0
}

_purge_capture_layout() {
  local installs="$1" phase="$2" after="" context
  local type pdir _poldir _sdir root_path root_list root_state profile_list profile_state
  [[ "${phase}" != after ]] || after=" after shutdown"
  purge_profile_lists=()
  purge_roots=()
  while IFS='|' read -r type pdir _poldir _sdir; do
    root_state=0
    root_list=$(_purge_profile_roots "${type}" "${pdir}") || root_state=$?
    if (( root_state != 0 )); then
      die "${type}: unsafe Firefox profile root${after}; nothing was deleted"
    fi
    purge_roots["${type}|${pdir}"]="${root_list}"
    while IFS= read -r root_path; do
      [[ -n "${root_path}" ]] || continue
      profile_state=0
      profile_list=$(_all_profile_paths "${root_path}" 2>/dev/null) || profile_state=$?
      if [[ "${phase}" == after ]]; then
        context="after shutdown"
      else
        context="in ${root_path}"
      fi
      case "${profile_state}" in
        0|1) purge_profile_lists["${root_path}"]="${profile_list}" ;;
        2|3|4)
          die "${type}: unsafe, unresolved, or unreadable profile declaration ${context}; nothing was deleted"
          ;;
        *)
          die "${type}: cannot read profiles ${context}; nothing was deleted"
          ;;
      esac
    done <<< "${root_list}"
  done <<< "${installs}"
}

hifox_purge() {
  local target="${1:-}"
  local installs
  installs=$(_list_installations)
  [[ -n "${installs}" ]] || die "no Firefox found (checked Flatpak, HIFOX_FIREFOX_DIR, /usr/lib*, /opt/firefox)"

  case "${target}" in
    --flatpak)  installs=$(printf '%s\n' "${installs}" | grep '^flatpak|' || true) ;;
    --standard) installs=$(printf '%s\n' "${installs}" | grep '^standard|' || true) ;;
    "")         ;;
    *)          die "usage: hifox purge [--flatpak|--standard]" ;;
  esac
  [[ -n "${installs}" ]] || die "no ${target#--} Firefox found"
  _require_command systemctl

  [[ -t 0 ]] || die "purge requires interactive terminal"
  warn "this deletes ALL browsing data (cookies, history, logins, cache, sessions)"
  warn "you will need to re-login everywhere"
  printf '  %b' "${_yellow}continue? [y/N]${_r} "
  local reply=""
  read -r reply || true
  [[ "${reply}" == [yY] ]] || { log "aborted"; return 0; }

  local -A purge_profile_lists=() purge_roots=()
  _purge_capture_layout "${installs}" before

  local _purge_restore_armed=true
  local -a _purge_watch_units=()
  local unit state
  for unit in hifox-verify.path hifox-verify.timer; do
    state=$(_purge_unit_state "${unit}") \
      || die "cannot determine verify watcher state; nothing was deleted"
    case "${state}" in
      active) _purge_watch_units+=("${unit}") ;;
      inactive|failed|unknown) ;;
      *) die "verify watcher is transitioning (${state}); retry purge later" ;;
    esac
  done
  trap '_purge_restore_watchers || true' EXIT
  trap '_purge_interrupted 130' INT
  trap '_purge_interrupted 143' TERM

  if (( ${#_purge_watch_units[@]} > 0 )); then
    local stop_err
    stop_err=$(systemctl --user stop "${_purge_watch_units[@]}" 2>&1) \
      || die "cannot pause verify watcher: ${stop_err}; nothing was deleted"
    for unit in "${_purge_watch_units[@]}"; do
      state=$(_purge_unit_state "${unit}") \
        || die "cannot verify watcher pause: ${unit}; nothing was deleted"
      case "${state}" in
        inactive|failed|unknown) ;;
        *) die "verify watcher still active: ${unit}; nothing was deleted" ;;
      esac
    done
  fi

  log "stopping selected Firefox target..."
  local _type _pdir _poldir _sdir
  while IFS='|' read -r _type _pdir _poldir _sdir; do
    _stop_firefox "${_type}" "${_sdir}" \
      || die "could not stop ${_type} Firefox; nothing was deleted"
  done <<< "${installs}"

  while IFS='|' read -r _type _pdir _poldir _sdir; do
    _wait_firefox_stopped "${_type}" "${_sdir}" \
      || die "selected Firefox target is still running; nothing was deleted"
  done <<< "${installs}"
  ok "selected Firefox target stopped"

  # Firefox rewrites profiles.ini while shutting down, so re-read the layout now
  _purge_capture_layout "${installs}" after

  log "purging ALL browsing data..."
  echo ""
  local purged=0 profiles_done=0 removal_failures=0

  while IFS='|' read -r _type _pdir _poldir _sdir; do
    local selected_pdir="${_pdir}" profile_root
    while IFS= read -r profile_root; do
      [[ -n "${profile_root}" && -d "${profile_root}" ]] || continue
      _pdir="${profile_root}"
      log "${_type} (${_pdir})"

      local profile
      while IFS= read -r profile; do
        [[ -d "${profile}" ]] || continue
        local pname count=0
        pname="$(basename "${profile}")"

        local item base
        # rm does not traverse a symlink, so a symlinked entry loses the link only.
        for item in "${profile}"/* "${profile}"/.*; do
          [[ -e "${item}" || -L "${item}" ]] || continue
          base="$(basename "${item}")"
          case "${base}" in
            .|..|user.js|chrome) continue ;;
          esac
          if rm -rf "${item:?}" 2>/dev/null; then
            ((count++)) || true
          else
            warn "cannot remove: ${pname}/${base}"
            ((removal_failures++)) || true
          fi
        done

        purged=$((purged + count))
        ((profiles_done++)) || true
        ok "${pname}: ${count} items deleted"
      done <<< "${purge_profile_lists[${_pdir}]-}"

      local item base
      for item in "${_pdir}"/* "${_pdir}"/.*; do
        [[ -e "${item}" || -L "${item}" ]] || continue
        base="$(basename "${item}")"
        case "${base}" in
          .|..|profiles.ini|installs.ini) continue ;;
        esac
        [[ -d "${item}" ]] && continue
        rm -rf "${item:?}" 2>/dev/null \
          || { warn "cannot remove Firefox-root item: ${base}"; ((removal_failures++)) || true; }
      done
    done <<< "${purge_roots[${_type}|${selected_pdir}]-}"
    _pdir="${selected_pdir}"

    if [[ "${_type}" == "flatpak" ]]; then
      local fp_root="${HOME}/.var/app/org.mozilla.firefox" d
      for d in "${fp_root}"/* "${fp_root}"/.*; do
        [[ -e "${d}" || -L "${d}" ]] || continue
        base="$(basename "${d}")"
        case "${base}" in
          .|..|config|.config|.mozilla) continue ;;
        esac
        rm -rf "${d:?}" 2>/dev/null && ok "cleared: ${base}" \
          || { warn "cannot clear Flatpak data: ${base}"; ((removal_failures++)) || true; }
      done
    else
      if [[ -d "${HOME}/.cache/mozilla" ]]; then
        rm -rf "${HOME:?}/.cache/mozilla" 2>/dev/null && ok "cleared: ~/.cache/mozilla" \
          || { warn "cannot clear: ~/.cache/mozilla"; ((removal_failures++)) || true; }
      fi
    fi
  done <<< "${installs}"

  local tmpdir
  for tmpdir in /tmp/rust_mozprofile* /tmp/.org.mozilla.firefox*; do
    [[ -d "${tmpdir}" && ! -L "${tmpdir}" && -O "${tmpdir}" ]] || continue
    rm -rf "${tmpdir:?}" 2>/dev/null && ok "temp: $(basename "${tmpdir}")"
  done

  local recovery_failed=false
  _purge_restore_watchers || recovery_failed=true
  trap - INT TERM

  echo ""
  if (( purged == 0 )); then
    warn "nothing to purge (profiles empty or not found)"
  else
    log "${purged} items deleted across ${profiles_done} profiles"
  fi
  if ${recovery_failed}; then
    die "purge completed, but verify watcher recovery failed"
  fi
  trap - EXIT
  (( removal_failures == 0 )) \
    || die "purge partially completed: ${removal_failures} item(s) could not be removed safely"
}
