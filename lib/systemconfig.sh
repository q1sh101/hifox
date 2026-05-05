#!/usr/bin/env bash
# shellcheck disable=SC2154  # _dir provided by hifox.sh

# Firefox Flatpak only loads these files through the systemconfig extension inside its sandbox.

hifox_install_systemconfig() {
  _require_command flatpak

  flatpak info org.mozilla.firefox &>/dev/null \
    || die "org.mozilla.firefox flatpak not found"

  local builder=""
  if _check_command flatpak-builder; then
    builder="flatpak-builder"
  elif flatpak info org.flatpak.Builder &>/dev/null; then
    builder="flatpak run --filesystem=host org.flatpak.Builder"
  else
    die "flatpak-builder missing - install: flatpak install --user flathub org.flatpak.Builder"
  fi

  local ff_runtime ff_branch sdk_ver
  ff_runtime=$(flatpak info org.mozilla.firefox 2>/dev/null \
    | awk -F': *' '/^[[:space:]]*Runtime:/ {print $2}')
  ff_branch=$(flatpak info org.mozilla.firefox 2>/dev/null \
    | awk -F': *' '/^[[:space:]]*Branch:/ {print $2}')
  sdk_ver="${ff_runtime##*/}"
  [[ -n "${sdk_ver}" && -n "${ff_branch}" ]] || die "could not parse Firefox flatpak metadata"

  [[ -f "${_dir}/config/policies.json" ]] || die "policies.json not found"
  [[ -f "${_dir}/config/autoconfig.js" ]] || die "autoconfig.js not found"
  [[ -f "${_dir}/config/global_lockprefs.cfg" ]] || die "global_lockprefs.cfg not found"
  [[ -f "${_dir}/config/generate_pref_dump.cfg" ]] || die "generate_pref_dump.cfg not found"
  [[ -f "${_dir}/webapp/shared/webapp.cfg" ]] || die "webapp.cfg not found"

  log "building org.mozilla.firefox.systemconfig (sdk ${sdk_ver}, branch ${ff_branch})..."

  local stage
  stage=$(mktemp -d "${XDG_CACHE_HOME:-${HOME}/.cache}/hifox-build.XXXXXX")
  trap 'rm -rf "${stage:?}"' EXIT

  mkdir -p "${stage}/content"
  _generate_autoconfig > "${stage}/content/autoconfig.cfg"
  cp "${_dir}/config/policies.json" "${stage}/content/policies.json"
  cp "${_dir}/config/autoconfig.js" "${stage}/content/autoconfig.js"

  cat > "${stage}/manifest.yml" <<EOF
id: org.mozilla.firefox.systemconfig
runtime: org.mozilla.firefox
runtime-version: ${ff_branch}
sdk: org.freedesktop.Sdk//${sdk_ver}
branch: ${ff_branch}
build-extension: true
separate-locales: false
modules:
  - name: hifox-config
    buildsystem: simple
    sources:
      - type: dir
        path: content
    build-commands:
      - install -Dm 644 autoconfig.cfg "\${FLATPAK_DEST}/autoconfig.cfg"
      - install -Dm 644 autoconfig.js  "\${FLATPAK_DEST}/defaults/pref/autoconfig.js"
      - install -Dm 644 policies.json  "\${FLATPAK_DEST}/policies/policies.json"
EOF

  # --disable-rofiles-fuse: avoid fuse (works under sandboxed flatpak run org.flatpak.Builder)
  # --state-dir: keep flatpak-builder's cache inside the temp stage (no .flatpak-builder/ in cwd)
  # shellcheck disable=SC2086  # builder may be multi-word (flatpak run ...)
  ${builder} --user --install --force-clean --install-deps-from=flathub \
    --disable-rofiles-fuse \
    --state-dir="${stage}/state" \
    --repo="${stage}/repo" "${stage}/build" "${stage}/manifest.yml" \
    || die "extension build failed"

  flatpak info org.mozilla.firefox.systemconfig &>/dev/null \
    || die "extension built but flatpak does not see it"

  trap - EXIT
  rm -rf "${stage:?}"

  ok "systemconfig extension installed (branch ${ff_branch})"
  log "restart Firefox - autoconfig.cfg + policies.json now load in sandbox"
  log "re-run after extension uninstall or Firefox runtime changes"
}
