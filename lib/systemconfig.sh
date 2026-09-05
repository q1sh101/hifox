#!/usr/bin/env bash
# shellcheck disable=SC2154  # deploy helpers and _dir provided by hifox.sh

_flatpak_sandbox_file_matches() {
  local host_file="$1" sandbox_file="$2" snapshot
  snapshot=$(mktemp) || return 1
  if timeout -k 2s 15s flatpak run --command=cat org.mozilla.firefox "${sandbox_file}" \
      > "${snapshot}" 2>/dev/null \
    && cmp -s "${host_file}" "${snapshot}"; then
    rm -f "${snapshot}"
    return 0
  fi
  rm -f "${snapshot}"
  return 1
}

# systemconfig is an unmaintained extension: populating its directory is enough, no Builder
hifox_install_systemconfig() {
  _require_command flatpak
  _require_command timeout
  flatpak info org.mozilla.firefox &>/dev/null \
    || die "org.mozilla.firefox flatpak not found"

  local found=false type _pdir poldir sdir
  while IFS='|' read -r type _pdir poldir sdir; do
    [[ "${type}" == "flatpak" ]] || continue
    found=true
    _deploy_policies "${poldir}" "${sdir}"
    _deploy_autoconfig "${sdir}"
    _flatpak_sandbox_file_matches "${sdir}/autoconfig.cfg" \
      /app/etc/firefox/autoconfig.cfg \
      || die "systemconfig refreshed, but autoconfig.cfg is not visible in the Firefox sandbox"
    _flatpak_sandbox_file_matches "${sdir}/defaults/pref/autoconfig.js" \
      /app/etc/firefox/defaults/pref/autoconfig.js \
      || die "systemconfig refreshed, but autoconfig.js is not visible in the Firefox sandbox"
    _flatpak_sandbox_file_matches "${poldir}/policies.json" \
      /app/etc/firefox/policies/policies.json \
      || die "systemconfig refreshed, but policies.json is not visible in the Firefox sandbox"
    ok "systemconfig refreshed (branch $(basename "${sdir}"))"
  done < <(_list_installations)
  ${found} || die "could not resolve Firefox Flatpak systemconfig path"
}
