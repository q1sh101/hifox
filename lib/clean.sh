#!/usr/bin/env bash
# shellcheck disable=SC2154  # _dir provided by hifox.sh

hifox_clean() {
  _require_firefox

  local installations running_rc
  installations=$(_active_installations)
  local _check_type _check_pdir _check_poldir _check_sdir
  while IFS='|' read -r _check_type _check_pdir _check_poldir _check_sdir; do
    _firefox_running "${_check_type}" "${_check_sdir}" && running_rc=0 || running_rc=$?
    case "${running_rc}" in
      0) warn "clean refused: ${_check_type} Firefox is running"; return 2 ;;
      1) ;;
      *) warn "clean refused: cannot determine ${_check_type} Firefox state"; return 2 ;;
    esac
  done <<< "${installations}"

  local -A clean_profile_lists=()
  local list_type list_pdir list_poldir list_sdir profile_list list_state
  while IFS='|' read -r list_type list_pdir list_poldir list_sdir; do
    [[ -e "${list_pdir}" || -L "${list_pdir}" ]] || continue
    if [[ ! -d "${list_pdir}" ]] \
      || ! _canonical_contained_path "${HOME}" "${list_pdir}" >/dev/null; then
      warn "clean refused: unsafe Firefox profile root: ${list_pdir}"
      return 2
    fi
    [[ -e "${list_pdir}/profiles.ini" || -L "${list_pdir}/profiles.ini" ]] || continue
    list_state=0
    profile_list=$(_list_profile_paths "${list_pdir}" 2>/dev/null) || list_state=$?
    case "${list_state}" in
      0) clean_profile_lists["${list_pdir}"]="${profile_list}" ;;
      2|3|4)
        warn "clean refused: unsafe or unresolved profile declaration in ${list_pdir}"
        return 2
        ;;
      *)
        warn "clean refused: cannot read profiles in ${list_pdir}"
        return 2
        ;;
    esac
  done <<< "${installations}"

  log "scanning for remnants..."
  local removed=0 failures=0

  local _type pdir _poldir _sdir
  # shellcheck disable=SC2034  # _type, _poldir, _sdir intentionally unused (destructuring read)
  while IFS='|' read -r _type pdir _poldir _sdir; do
    [[ -d "${pdir}" ]] || continue
    [[ -n "${clean_profile_lists[${pdir}]+set}" ]] || continue

    local profile
    while IFS= read -r profile; do
      [[ -d "${profile}" ]] || continue
      local name
      name="$(basename "${profile}")"
      local target
      for target in \
        suggest.sqlite \
        suggest.sqlite-wal \
        suggest.sqlite-shm \
        datareporting/archived \
        bookmarkbackups \
        saved-telemetry-pings \
        Telemetry.FailedProfileLocks.txt \
        Telemetry.ShutdownTime.txt \
        ExperimentStoreData.json \
        shield-preference-experiments.json \
        domain_to_categories.sqlite \
        formhistory.sqlite \
        gmp-widevinecdm \
        gmp-gmpopenh264 \
        AlternateServices.bin \
        crashes \
        minidumps \
        storage-sync.sqlite \
        storage-sync.sqlite-wal \
        storage-sync.sqlite-shm \
        weave \
        permissions.sqlite \
        notification-store.json
      do
        if [[ "${target}" == gmp-* && -d "${_dir}/webapp/${name}" ]]; then
          continue
        fi
        if [[ -e "${profile}/${target}" || -L "${profile}/${target}" ]]; then
          # a nested remnant must not be deleted through a symlinked parent
          if [[ "${target}" == */* ]] \
            && [[ "$(readlink -f -- "${profile}/${target%/*}" 2>/dev/null)" \
                  != "${profile}/${target%/*}" ]]; then
            warn "remnant parent is a symlink, skipped: ${name}/${target}"
            ((failures++)) || true
            continue
          fi
          if rm -rf "${profile:?}/${target:?}"; then
            ok "removed ${name}/${target}"
            ((removed++)) || true
          else
            warn "cannot remove ${name}/${target}"
            ((failures++)) || true
          fi
        fi
      done
    done <<< "${clean_profile_lists[${pdir}]-}"
  done <<< "${installations}"

  if (( removed == 0 )); then
    ok "no remnants found"
  else
    log "${removed} items removed"
  fi
  (( failures == 0 )) || return 1
}
