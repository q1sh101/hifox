#!/usr/bin/env bash
# lib/clean.sh - remove stale remnant files from profiles

hifox_clean() {
  _require_firefox

  log "scanning for remnants..."
  local removed=0

  local _type pdir _poldir _sdir
  # shellcheck disable=SC2034
  while IFS='|' read -r _type pdir _poldir _sdir; do
    [[ -d "$pdir" ]] || continue
    local ini="$pdir/profiles.ini"
    [[ -f "$ini" ]] || continue

    local profile
    while IFS= read -r profile; do
      [[ -d "$profile" ]] || continue
      local name
      name="$(basename "$profile")"
      # telemetry, suggest DB, experiment data - none should survive hardening
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
        cache2 \
        startupCache \
        storage-sync.sqlite \
        storage-sync.sqlite-wal \
        storage-sync.sqlite-shm \
        weave \
        permissions.sqlite \
        notification-store.json
      do
        if [[ -e "$profile/$target" ]]; then
          rm -rf "${profile:?}/${target:?}"
          ok "removed $name/$target"
          ((removed++)) || true
        fi
      done
    done < <(_list_profile_paths "$pdir")
  done < <(_active_installations)

  if (( removed == 0 )); then
    ok "no remnants found"
  else
    log "$removed items removed"
  fi
}
