#!/usr/bin/env bash
set -euo pipefail

_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
_pass=0
_fail=0

_test() {
  local name="$1"; shift
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if (( rc == 0 )); then
    echo "  PASS  ${name}"
    ((_pass++)) || true
  else
    echo "  FAIL  ${name}"
    [[ -n "${out}" ]] && printf '%s\n' "${out}" | sed 's/^/        /'
    ((_fail++)) || true
  fi
}

_test_fail() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  FAIL  ${name} (should have failed)"
    ((_fail++)) || true
  else
    echo "  PASS  ${name}"
    ((_pass++)) || true
  fi
}

_section() { printf '\n=== %s ===\n' "$1"; }

_fake_runtime_dump() {
  sed -n 's/^lockPref("\([^"]*\)", *\(.*\));.*/\1 = \2 [LOCKED]/p' \
    "${_dir}/config/global_lockprefs.cfg" \
    | sed 's/ = "\(.*\)" \[LOCKED\]$/ = \1 [LOCKED]/'
  printf '_user_js.canary = hifox\n'
}

_fake_webapp_dump() {
  local app="$1" line key value
  local -A overrides=() emitted=()
  while IFS='|' read -r key value; do
    [[ -n "${key}" ]] && overrides["${key}"]="${value}"
  done < <(sed -n 's/^lockPref("\([^"]*\)", *\(.*\));.*/\1|\2/p' \
    "${_dir}/webapp/${app}/prefs.cfg")
  while IFS= read -r line; do
    key="${line%% = *}"
    if [[ -n "${overrides[${key}]+set}" ]]; then
      value="${overrides[${key}]}"; value="${value%\"}"; value="${value#\"}"
      printf '%s = %s [LOCKED]\n' "${key}" "${value}"
      emitted["${key}"]=1
    else
      printf '%s\n' "${line}"
    fi
  done < <(_fake_runtime_dump)
  for key in "${!overrides[@]}"; do
    [[ -n "${emitted[${key}]+set}" ]] && continue
    value="${overrides[${key}]}"; value="${value%\"}"; value="${value#\"}"
    printf '%s = %s [LOCKED]\n' "${key}" "${value}"
  done
}

_cli_contract() {
  local out cmd name
  local -a argv=()
  for cmd in "" badcmd "deploy extra" "install" "install --garbage" \
    "purge --garbage" "watch" "watch evil" "install-systemconfig extra"; do
    argv=(); read -r -a argv <<< "${cmd}" || true
    bash "${_dir}/hifox.sh" "${argv[@]}" >/dev/null 2>&1 && return 1
  done
  bash "${_dir}/launch.sh" --target garbage >/dev/null 2>&1 && return 1
  out=$(bash "${_dir}/hifox.sh" 2>&1 || true)
  for name in install deploy verify clean purge status logs watch install-systemconfig; do
    grep -qE " ${name}( |$)" <<< "${out}" || return 1
  done
  source "${_dir}/lib/base.sh"
  for name in app web-app web_app org.example a; do _is_valid_webapp_name "${name}" || return 1; done
  for name in '' 'evil;cmd' 'foo/bar' 'a b' 'a$b' 'foo|bar'; do
    ! _is_valid_webapp_name "${name}" || return 1
  done
  XDG_CONFIG_HOME="${_tmpdir}/target" _save_target flatpak
  [[ "$(XDG_CONFIG_HOME="${_tmpdir}/target" _read_target)" == flatpak ]]
  XDG_CONFIG_HOME="${_tmpdir}/target" _save_target standard
  [[ "$(XDG_CONFIG_HOME="${_tmpdir}/target" _read_target)" == standard ]]
}

_profile_contract() {
  local root="$1" out rc
  source "${_dir}/lib/base.sh"

  mkdir -p "${root}/install/a.default" "${root}/install/b.default"
  printf '[InstallA]\nDefault=a.default\n\n[Profile0]\nIsRelative=1\nPath=b.default\nDefault=1\n' \
    > "${root}/install/profiles.ini"
  [[ "$(_find_profile "${root}/install")" == "${root}/install/a.default" ]] || return 1

  mkdir -p "${root}/orphan/real.default"
  printf '[InstallA]\nDefault=missing.default\n\n[Profile0]\nIsRelative=1\nPath=real.default\nDefault=1\n' \
    > "${root}/orphan/profiles.ini"
  [[ "$(_find_profile "${root}/orphan")" == "${root}/orphan/real.default" ]] || return 1

  mkdir -p "${root}/bad-install/real.default" "${root}/outside.default"
  printf '[InstallA]\nDefault=../outside.default\n\n[Profile0]\nIsRelative=1\nPath=real.default\nDefault=1\n' \
    > "${root}/bad-install/profiles.ini"
  rc=0; _find_profile "${root}/bad-install" >/dev/null || rc=$?; (( rc == 2 )) || return 1

  mkdir -p "${root}/absolute/inside.default"
  printf '[Profile0]\nIsRelative=0\nPath=%s\nDefault=1\n' "${root}/absolute/inside.default" \
    > "${root}/absolute/profiles.ini"
  [[ "$(_find_profile "${root}/absolute")" == "${root}/absolute/inside.default" ]] || return 1
  printf '[Profile0]\nIsRelative=0\nPath=%s\nDefault=1\n' "${root}/outside.default" \
    > "${root}/absolute/profiles.ini"
  rc=0; _list_profile_paths "${root}/absolute" >/dev/null || rc=$?; (( rc == 2 )) || return 1

  mkdir -p "${root}/mixed/good.default" "${root}/mixed/foo" "${root}/mixed/bar"
  printf '[Profile0]\nIsRelative=1\nPath=good.default\n\n[Profile1]\nIsRelative=1\nPath=foo/../bar\n' \
    > "${root}/mixed/profiles.ini"
  rc=0; out=$(_list_profile_paths "${root}/mixed") || rc=$?
  (( rc == 2 )) && [[ "${out}" == "${root}/mixed/good.default" ]] || return 1

  mkdir -p "${root}/symlink"; ln -s "${root}/outside.default" "${root}/symlink/evil.default"
  printf '[Profile0]\nIsRelative=1\nPath=evil.default\nDefault=1\n' > "${root}/symlink/profiles.ini"
  rc=0; _find_profile "${root}/symlink" >/dev/null || rc=$?; (( rc == 2 )) || return 1

  for kind in directory fifo dangling; do
    mkdir -p "${root}/${kind}/fallback.default"
    case "${kind}" in
      directory) mkdir "${root}/${kind}/profiles.ini" ;;
      fifo) mkfifo "${root}/${kind}/profiles.ini" ;;
      dangling) ln -s "${root}/missing.ini" "${root}/${kind}/profiles.ini" ;;
    esac
    rc=0; _all_profile_paths "${root}/${kind}" >/dev/null || rc=$?; (( rc == 2 )) || return 1
  done

  mkdir -p "${root}/glob/x.default-release"
  [[ "$(_all_profile_paths "${root}/glob")" == "${root}/glob/x.default-release" ]]
}

_autoconfig_contract() {
  local output="$1" second marker app tail name
  source "${_dir}/lib/base.sh"; _dir="${_dir}"
  _generate_autoconfig > "${output}"
  second=$(_generate_autoconfig | sha256sum)
  [[ "$(sha256sum < "${output}")" == "${second}" ]] || return 1
  grep -q '_autoconfig.loaded' "${output}" && grep -q 'generated_pref_dump' "${output}" || return 1
  marker=$(grep -n 'per-webapp overrides' "${output}" | head -1 | cut -d: -f1)
  app=$(grep -n 'profileDir === ' "${output}" | head -1 | cut -d: -f1)
  tail=$(grep -n 'if (isWebapp)' "${output}" | head -1 | cut -d: -f1)
  (( marker < app && app < tail )) || return 1
  for name in "${_webapps[@]}"; do
    _is_valid_webapp_name "${name}" || return 1
    grep -q "profileDir === \"${name}\"" "${output}" || return 1
    [[ -s "${_dir}/webapp/${name}/prefs.cfg" \
      && -f "${_dir}/webapp/${name}/${name}.desktop" ]] || return 1
    grep -q '__LAUNCH_SH__' "${_dir}/webapp/${name}/${name}.desktop" || return 1
  done
}

_policy_contract() {
  python3 - "${_dir}/config/policies.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))["policies"]
assert p["ExtensionSettings"]["*"]["installation_mode"] == "blocked"
assert p["ExtensionSettings"]["uBlock0@raymondhill.net"]["installation_mode"] == "force_installed"
assert p["SSLVersionMin"] == "tls1.2"
assert p["DisableSafeMode"] and p["DisableMasterPasswordCreation"]
PY
}

_desktop_contract() {
  local root="$1"
  local home="${root}/home" apps pixmaps standard_home standard_apps name icon hash outside rc=0
  apps="${home}/.local/share/applications"; pixmaps="${home}/.local/share/pixmaps"
  mkdir -p "${apps}"
  (
    source "${_dir}/lib/base.sh"; source "${_dir}/lib/deploy.sh"; _dir="${_dir}"
    HOME="${home}"; XDG_DATA_HOME="${home}/.local/share"
    _deploy_desktop_entries 'flatpak|/unused|/unused|/unused' >/dev/null
  )
  grep -q -- '--target flatpak %u' "${apps}/org.mozilla.firefox.desktop" || return 1
  for name in "${_webapps[@]}"; do
    [[ -f "${apps}/org.mozilla.firefox.${name}-web.desktop" ]] || return 1
    grep -q -- "--target flatpak --webapp ${name}" \
      "${apps}/org.mozilla.firefox.${name}-web.desktop" || return 1
  done

  standard_home="${root}/standard-home"; standard_apps="${standard_home}/.local/share/applications"
  (
    source "${_dir}/lib/base.sh"; source "${_dir}/lib/deploy.sh"; _dir="${_dir}"
    HOME="${standard_home}"; XDG_DATA_HOME="${standard_home}/.local/share"
    _deploy_desktop_entries 'standard|/unused|/unused|/unused' >/dev/null
  )
  grep -q -- '--target standard %u' "${standard_apps}/firefox.desktop" || return 1

  outside="${root}/outside"; mkdir -p "${outside}"
  printf 'firefox\n' > "${outside}/firefox"; printf 'app\n' > "${outside}/app"; printf 'icon\n' > "${outside}/icon"
  rm -f "${apps}/org.mozilla.firefox.desktop" "${apps}/org.mozilla.firefox.discord-web.desktop"
  ln -s "${outside}/firefox" "${apps}/org.mozilla.firefox.desktop"
  ln -s "${outside}/app" "${apps}/org.mozilla.firefox.discord-web.desktop"
  hash=$(cksum "${_dir}/webapp/discord/discord.png" | awk '{print $1}')
  icon="${pixmaps}/discord-${hash}.png"; rm -f "${icon}"; ln -s "${outside}/icon" "${icon}"
  (
    source "${_dir}/lib/base.sh"; source "${_dir}/lib/deploy.sh"; _dir="${_dir}"
    HOME="${home}"; XDG_DATA_HOME="${home}/.local/share"
    _deploy_desktop_entries 'flatpak|/unused|/unused|/unused' >/dev/null
  ) || rc=$?
  # a pre-existing symlink is replaced by the deployed file, never written through
  (( rc == 0 )) && grep -qx firefox "${outside}/firefox" \
    && grep -qx app "${outside}/app" && grep -qx icon "${outside}/icon" \
    && [[ ! -L "${apps}/org.mozilla.firefox.desktop" && ! -L "${icon}" ]]
}

_deploy_profile_safety() {
  local root="$1"
  local home="${root}/home" pdir profile outside rc=0
  pdir="${home}/.mozilla/firefox"; profile="${pdir}/main.default"; outside="${root}/outside"
  mkdir -p "${profile}/chrome" "${pdir}/discord/chrome" "${outside}"
  printf '[General]\nStartWithLastProfile=0\n' > "${pdir}/profiles.ini"
  for file in home logo app; do printf '%s\n' "${file}" > "${outside}/${file}"; done
  # a pre-existing symlink is replaced by the deployed file, never written through
  ln -s "${outside}/home" "${profile}/chrome/userContent.css"
  ln -s "${outside}/logo" "${profile}/chrome/hifox.png"
  ln -s "${outside}/app" "${pdir}/discord/chrome/userChrome.css"
  (
    source "${_dir}/lib/base.sh"; source "${_dir}/lib/deploy.sh"; _dir="${_dir}"
    _deploy_homepage "${pdir}"; _deploy_webapp_profiles "${pdir}"; _deploy_webapp_profiles "${pdir}"
  ) >/dev/null 2>&1
  grep -qx home "${outside}/home" && grep -qx logo "${outside}/logo" \
    && grep -qx app "${outside}/app" || return 1
  [[ ! -L "${profile}/chrome/userContent.css" && ! -L "${pdir}/discord/chrome/userChrome.css" ]] || return 1
  grep -qx 'StartWithLastProfile=1' "${pdir}/profiles.ini" || return 1
  [[ "$(grep -c '^Name=discord$' "${pdir}/profiles.ini")" == 1 ]] || return 1

  # a profiles.ini declaration pointing outside the profile root stops deploy
  printf '\n[Profile9]\nIsRelative=0\nPath=%s\n' "${outside}" >> "${pdir}/profiles.ini"
  (
    source "${_dir}/lib/base.sh"; source "${_dir}/lib/clean.sh"; source "${_dir}/lib/deploy.sh"
    _dir="${_dir}"; HOME="${home}"; _require_firefox() { :; }
    _active_installations() { printf 'standard|%s|/unused|/unused\n' "${pdir}"; }
    hifox_deploy
  ) >/dev/null 2>&1 || rc=$?
  (( rc != 0 )) && grep -qx home "${outside}/home"
}

_make_verify_fixture() {
  local root="$1"
  local target="${2:-flatpak}" repo="${root}/repo" home="${root}/home" pdir profile poldir sdir
  pdir="${home}/.mozilla/firefox"; profile="${pdir}/main.default"
  poldir="${root}/policies"; sdir="${root}/firefox"
  mkdir -p "${repo}" "${profile}" "${poldir}" "${sdir}/defaults/pref"
  cp -a "${_dir}/config" "${repo}/config"; cp -a "${_dir}/webapp" "${repo}/webapp"
  cp "${repo}/config/policies.json" "${poldir}/policies.json"
  cp "${repo}/config/autoconfig.js" "${sdir}/defaults/pref/autoconfig.js"
  cp "${repo}/config/user.js" "${profile}/user.js"
  printf '[Profile0]\nName=main\nIsRelative=1\nPath=main.default\nDefault=1\n' > "${pdir}/profiles.ini"
  _fake_runtime_dump > "${profile}/generated_pref_dump.txt"
  REPO="${repo}" SOURCE="${_dir}" bash -c \
    'source "${SOURCE}/lib/base.sh"; _dir="${REPO}"; _generate_autoconfig' > "${sdir}/autoconfig.cfg"
  printf 'user_pref("_user_js.canary", "hifox");\n' > "${profile}/prefs.js"
  touch -t 200001010000 "${poldir}/policies.json" "${sdir}/defaults/pref/autoconfig.js" \
    "${sdir}/autoconfig.cfg" "${profile}/user.js"
  cp "${profile}/generated_pref_dump.txt" "${repo}/config/generated_pref_dump.${target}.txt"
  git -C "${repo}" init -q
  printf '%s|%s|%s|%s|%s\n' "${repo}" "${pdir}" "${profile}" "${poldir}" "${sdir}"
}

_verify_case() {
  local root="$1" mode="$2" target="${3:-flatpak}" repo pdir profile poldir sdir baseline dump stop_marker calls log
  local rc=0 before="" expect_stop=false pattern=""
  IFS='|' read -r repo pdir profile poldir sdir < <(_make_verify_fixture "${root}" "${target}")
  baseline="${repo}/config/generated_pref_dump.${target}.txt"; dump="${profile}/generated_pref_dump.txt"
  stop_marker="${root}/stopped"; calls="${root}/calls"; log="${root}/verify.log"
  case "${mode}" in
    pass) ;;
    drift)
      sed -i 's/^privacy\.fingerprintingProtection = true \[LOCKED\]$/privacy.fingerprintingProtection = false [LOCKED]/' "${dump}"
      touch -t 203001010000 "${profile}/prefs.js"; expect_stop=true; pattern='fingerprint protection'
      ;;
    unlocked)
      sed -i 's/^dom\.security\.https_only_mode = true \[LOCKED\]$/dom.security.https_only_mode = true/' "${dump}"
      expect_stop=true; pattern=UNLOCKED
      ;;
    missing) rm -f "${dump}"; pattern='awaiting a Firefox restart' ;;
    malformed) printf 'not a dump\n' > "${dump}"; pattern='MALFORMED EVIDENCE' ;;
    oversized) head -c 8388609 /dev/zero > "${dump}"; pattern='MALFORMED EVIDENCE' ;;
    symlink) mv "${dump}" "${root}/outside-dump"; ln -s "${root}/outside-dump" "${dump}"; pattern='MALFORMED EVIDENCE' ;;
    producer) printf 'producer failed\n' > "${profile}/generated_pref_dump.err"; pattern='DUMP FAILED' ;;
    staged) touch -t 203001010000 "${sdir}/autoconfig.cfg"; pattern='awaiting a Firefox restart' ;;
    no-profile) rm -rf "${pdir}"; pattern='runtime checks not applicable' ;;
    file-drift) rm -rf "${pdir}"; printf '\n' >> "${poldir}/policies.json"; expect_stop=true; pattern='DRIFT: policies.json' ;;
    unsafe-default)
      mkdir -p "${root}/external.default"
      printf '[Profile0]\nIsRelative=0\nPath=%s\nDefault=1\n' "${root}/external.default" > "${pdir}/profiles.ini"
      pattern='UNSAFE/UNRESOLVED PROFILE DECLARATION'
      ;;
    baseline-dirty)
      printf 'operator.note = keep\n' >> "${baseline}"; git -C "${repo}" add config/generated_pref_dump.flatpak.txt
      printf 'runtime.new = true\n' >> "${dump}"; pattern='pref dump updated in repo'
      ;;
    git-fail) printf 'runtime.new = true\n' >> "${dump}"; pattern='pref dump updated in repo' ;;
    baseline-accept)
      git -C "${repo}" add -A && git -C "${repo}" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm base
      printf 'runtime.new = true [LOCKED]\n' >> "${dump}"
      ;;
    compare-error) pattern='UNREADABLE: policies.json comparison' ;;
    reader-error) pattern='UNSAFE/UNRESOLVED PROFILE DECLARATION' ;;
    no-install) pattern='cannot determine active Firefox installation' ;;
    baseline-missing) rm -f "${baseline}" ;;
    webapp-na) mkdir -p "${pdir}/discord"; pattern='not yet initialized' ;;
    webapp-missing)
      mkdir -p "${pdir}/discord"; printf 'user_pref("x", 1);\n' > "${pdir}/discord/prefs.js"
      pattern='awaiting a Firefox restart - discord'
      ;;
    webapp-pass|webapp-error|webapp-drift)
      mkdir -p "${pdir}/discord"; cp "${repo}/config/user.js" "${pdir}/discord/user.js"
      printf 'user_pref("_user_js.canary", "hifox");\n' > "${pdir}/discord/prefs.js"
      _fake_webapp_dump discord > "${pdir}/discord/generated_pref_dump.txt"
      touch -t 200001010000 "${pdir}/discord/user.js"
      if [[ "${mode}" == webapp-error ]]; then
        printf 'producer failed\n' > "${pdir}/discord/generated_pref_dump.err"; pattern='DUMP FAILED: discord'
      elif [[ "${mode}" == webapp-drift ]]; then
        sed -i 's/^geo\.enabled = false \[LOCKED\]$/geo.enabled = true [LOCKED]/' \
          "${pdir}/discord/generated_pref_dump.txt"
        expect_stop=true; pattern='discord: geolocation disabled'
      fi
      ;;
    *) return 1 ;;
  esac
  [[ ! -e "${baseline}" ]] || before=$(sha256sum "${baseline}")

  (
    source "${_dir}/lib/base.sh"; source "${_dir}/lib/deploy.sh"; source "${_dir}/lib/verify.sh"
    _dir="${repo}"; HOME="${root}/home"
    _active_installations() {
      [[ "${mode}" != no-install ]] || return 1
      printf 'x\n' >> "${calls}"; printf '%s|%s|%s|%s\n' "${target}" "${pdir}" "${poldir}" "${sdir}"
    }
    _stop_firefox() { : > "${stop_marker}"; }; _wait_firefox_stopped() { :; }; notify-send() { :; }
    if [[ "${mode}" == git-fail ]]; then git() { return 1; }; fi
    if [[ "${mode}" == compare-error ]]; then
      cmp() { local arg; for arg in "$@"; do [[ "${arg}" != "${repo}/config/policies.json" ]] || return 2; done; command cmp "$@"; }
    fi
    if [[ "${mode}" == reader-error ]]; then
      awk() { local arg; for arg in "$@"; do [[ "${arg}" != "${pdir}/profiles.ini" ]] || return 1; done; command awk "$@"; }
    fi
    _hifox_verify
  ) > "${log}" 2>&1 || rc=$?

  if [[ "${mode}" == no-install ]]; then [[ ! -e "${calls}" ]] || return 1
  else [[ "$(wc -l < "${calls}")" == 1 ]] || return 1; fi
  case "${mode}" in
    pass|no-profile|baseline-missing|baseline-accept|baseline-dirty|git-fail|webapp-na|webapp-pass|missing|staged|webapp-missing)
      (( rc == 0 )) ;;
    *) (( rc != 0 )) ;;
  esac || return 1
  if ${expect_stop}; then [[ -e "${stop_marker}" ]] || return 1; else [[ ! -e "${stop_marker}" ]] || return 1; fi
  [[ -z "${pattern}" ]] || grep -q "${pattern}" "${log}" || return 1
  case "${mode}" in
    baseline-missing|baseline-accept|baseline-dirty|git-fail) cmp -s "${dump}" "${baseline}" ;;
    *) [[ "${before}" == "$(sha256sum "${baseline}")" ]] ;;
  esac
}

_verify_atomic_contract() {
  local root="$1" source_file replacement snapshot src baseline rc=0
  mkdir -p "${root}"; source "${_dir}/lib/verify.sh"; _dir="${root}"
  source_file="${root}/source"; replacement="${root}/replacement"; snapshot="${root}/snapshot"
  printf 'first.pref = true [LOCKED]\n' > "${source_file}"; printf 'second.pref = false [LOCKED]\n' > "${replacement}"
  head() { command head "$@"; mv -f "${replacement}" "${source_file}"; }
  ! _verify_snapshot_dump "${source_file}" "${snapshot}" || return 1; unset -f head

  # the baseline is replaced atomically, leaving no temporary file behind
  src="${root}/runtime"; baseline="${root}/config.txt"; printf 'new\n' > "${src}"
  printf 'old\n' > "${baseline}"
  _verify_write_baseline "${src}" "${baseline}" || return 1
  cmp -s "${src}" "${baseline}" && [[ -z "$(find "${root}" -name 'config.txt.tmp.*')" ]]
}

_clean_case() {
  local root="$1" mode="$2"
  local home="${root}/home" pdir profile evidence rc=0
  pdir="${home}/.mozilla/firefox"; profile="${pdir}/main.default"
  mkdir -p "${profile}/datareporting/archived"
  evidence="${profile}/datareporting/archived/canary"; printf 'preserve\n' > "${evidence}"
  printf '[Profile0]\nIsRelative=1\nPath=main.default\nDefault=1\n' > "${pdir}/profiles.ini"
  case "${mode}" in
    pass|running) ;;
    external)
      mkdir -p "${root}/external.default"
      printf '\n[Profile1]\nIsRelative=0\nPath=%s\n' "${root}/external.default" >> "${pdir}/profiles.ini"
      ;;
    root-symlink) mkdir -p "${root}/outside"; mv "${pdir}" "${root}/outside/firefox"; ln -s "${root}/outside/firefox" "${pdir}" ;;
    ini-dangling|ini-directory|ini-fifo)
      rm -f "${pdir}/profiles.ini"
      case "${mode}" in
        ini-dangling) ln -s "${root}/missing.ini" "${pdir}/profiles.ini" ;;
        ini-directory) mkdir "${pdir}/profiles.ini" ;;
        ini-fifo) mkfifo "${pdir}/profiles.ini" ;;
      esac
      ;;
    alias)
      mkdir -p "${profile}/chrome/archived"; mv "${evidence}" "${profile}/chrome/archived/canary"
      rm -rf "${profile}/datareporting"; ln -s "${profile}/chrome" "${profile}/datareporting"
      evidence="${profile}/chrome/archived/canary"
      ;;
    dangling-remnant) rm -rf "${profile}/datareporting"; ln -s "${root}/missing" "${profile}/suggest.sqlite" ;;
    *) return 1 ;;
  esac
  (
    source "${_dir}/lib/base.sh"; source "${_dir}/lib/clean.sh"; _dir="${_dir}"; HOME="${home}"
    _require_firefox() { :; }; _active_installations() { printf 'standard|%s|/unused|/selected\n' "${pdir}"; }
    if [[ "${mode}" == running ]]; then _firefox_running() { return 0; }; else _firefox_running() { return 1; }; fi
    hifox_clean >/dev/null
  ) 2>/dev/null || rc=$?
  case "${mode}" in
    pass) (( rc == 0 )) && [[ ! -e "${evidence}" ]] ;;
    # a nested remnant is never deleted through a symlinked parent directory
    alias) (( rc != 0 )) && grep -qx preserve "${evidence}" ;;
    # a top-level remnant is unlinked directly: rm does not follow the last component
    dangling-remnant) (( rc == 0 )) && [[ ! -L "${profile}/suggest.sqlite" ]] ;;
    *) (( rc != 0 )) && grep -qx preserve "${evidence}" ;;
  esac
}

_systemconfig_case() {
  local root="$1" mode="$2"
  (
    source "${_dir}/lib/base.sh"; source "${_dir}/lib/deploy.sh"; source "${_dir}/lib/systemconfig.sh"
    _dir="${_dir}"; HOME="${root}/home"; XDG_DATA_HOME="${root}/data"; mkdir -p "${HOME}"
    _can_sudo_chattr() { return 1; }
    timeout() { [[ "$1" == -k && "$2" == 2s && "$3" == 15s ]] || return 1; shift 3; "$@"; }
    flatpak() {
      case "$1" in
        info) printf 'app/org.mozilla.firefox/x86_64/beta\n' ;;
        run)
          [[ "${mode}" == visible ]] || return 1
          local path="${*: -1}"
          cat "${XDG_DATA_HOME}/flatpak/extension/org.mozilla.firefox.systemconfig/x86_64/beta/${path#/app/etc/firefox/}"
          ;;
        *) return 1 ;;
      esac
    }
    hifox_install_systemconfig >/dev/null
  )
}

_flatpak_contract() {
  local root="$1" mode=good out
  source "${_dir}/lib/base.sh"; HOME="${root}/home"; XDG_DATA_HOME="${root}/data"
  flatpak() { [[ "$1" == info ]] || return 1; [[ "${mode}" == good ]] && printf 'app/org.mozilla.firefox/aarch64/beta\n' || printf 'bad-ref\n'; }
  out=$(_list_installations 2>/dev/null)
  grep -Fq '/org.mozilla.firefox.systemconfig/aarch64/beta/policies|' <<< "${out}" || return 1
  mkdir -p "${root}/standard"; : > "${root}/standard/application.ini"; HIFOX_FIREFOX_DIR="${root}/standard"; mode=bad
  out=$(_list_installations 2>/dev/null); [[ "${out}" == standard* ]] || return 1
  flatpak() { [[ "$1" != ps ]]; }; ! _stop_firefox flatpak /unused
}

_watch_contract() {
  local root="$1"
  local repo="${root}/repo" home="${root}/home" unit
  unit="${home}/.config/systemd/user/hifox-watch.path"
  mkdir -p "${repo}"; cp -a "${_dir}/config" "${repo}/config"; cp -a "${_dir}/webapp" "${repo}/webapp"
  (
    source "${_dir}/lib/base.sh"; source "${_dir}/lib/watch.sh"; _dir="${repo}"; HOME="${home}"; XDG_CONFIG_HOME="${home}/.config"
    _require_firefox() { :; }; _active_installations() { printf 'flatpak|%s|/unused|/unused\n' "${root}/profiles"; }
    systemctl() { return 0; }; hifox_watch_install >/dev/null
  )
  # a reviewed baseline written by verify must not re-trigger deploy
  [[ -f "${unit}" ]] && ! grep -q generated_pref_dump "${unit}" || return 1
  grep -q 'profiles.ini' "${unit}" || return 1
  (
    source "${_dir}/lib/base.sh"; source "${_dir}/lib/purge.sh"
    _purge_restore_armed=true; _purge_watch_units=(hifox-verify.path); calls="${root}/calls"
    systemctl() { printf '%s\n' "$*" >> "${calls}"; [[ "$*" != *is-active* ]] || printf 'active\n'; }
    _purge_restore_watchers >/dev/null
    grep -qx -- '--user start hifox-verify.path' "${calls}"
  )
}

_status_contract() {
  local root="$1"
  local home="${root}/home" pdir profile mode out
  pdir="${home}/.mozilla/firefox"; profile="${pdir}/main.default"
  mkdir -p "${profile}/chrome" "${home}/.config/hifox"
  cp "${_dir}/config/user.js" "${profile}/user.js"; cp "${_dir}/config/hifox.css" "${profile}/chrome/userContent.css"
  cp "${_dir}/docs/hifox.png" "${profile}/chrome/hifox.png"
  printf '[Profile0]\nIsRelative=1\nPath=main.default\nDefault=1\n' > "${pdir}/profiles.ini"
  printf 'standard\n' > "${home}/.config/hifox/target"
  for mode in clean drift; do
    [[ "${mode}" == clean ]] || printf '/* drift */\n' >> "${profile}/chrome/userContent.css"
    out=$(HOME="${home}" XDG_CONFIG_HOME="${home}/.config" SOURCE="${_dir}" PDIR="${pdir}" bash -c '
      source "${SOURCE}/lib/base.sh"; source "${SOURCE}/lib/status.sh"; _dir="${SOURCE}"
      _active_installations() { printf "standard|%s|/unused|/unused\n" "${PDIR}"; }; hifox_status 2>&1')
    if [[ "${mode}" == clean ]]; then grep -q 'main.default.*synced' <<< "${out}" || return 1
    else grep -q 'DRIFT userContent' <<< "${out}" || return 1; fi
  done
}

_source_contract() {
  grep -q '@mozilla.org/network/safe-file-output-stream;1' "${_dir}/config/generate_pref_dump.cfg" || return 1
  grep -q 'flock -w 15' "${_dir}/hifox.sh" || return 1
  source "${_dir}/lib/verify.sh"
  _verify_dump_valid "${_dir}/config/generated_pref_dump.standard.txt"
  _verify_dump_valid "${_dir}/config/generated_pref_dump.flatpak.txt"
  local fn count
  local -a funcs=()
  mapfile -t funcs < <(grep -hE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "${_sh[@]}" | sed -E 's/\(\).*//' | sort -u)
  for fn in "${funcs[@]}"; do
    count=$(grep -hE "(^|[^A-Za-z0-9_])${fn}([^A-Za-z0-9_]|$)" "${_sh[@]}" | wc -l)
    (( count > 1 )) || { printf '%s\n' "${fn}"; return 1; }
  done
}

_tmpdir=$(mktemp -d)
trap 'rm -rf "${_tmpdir}"' EXIT
mapfile -t _sh < <(printf '%s\n' "${_dir}/hifox.sh" "${_dir}/launch.sh" "${_dir}"/lib/*.sh)
mapfile -t _webapps < <(for d in "${_dir}"/webapp/*/; do n=$(basename "${d}"); [[ "${n}" == shared ]] || printf '%s\n' "${n}"; done)

_section syntax
_test "all shell sources parse" bash -c 'for f; do bash -n "$f" || exit; done' _ "${_sh[@]}"
if command -v shellcheck &>/dev/null; then
  _test "shellcheck" shellcheck -x "${_sh[@]}"
else
  echo "  SKIP  shellcheck not installed"
fi

_section interfaces
_test "CLI grammar, names, and target state" _cli_contract
_test "profile discovery and containment" _profile_contract "${_tmpdir}/profiles"
_test "autoconfig and auto-discovered webapps" _autoconfig_contract "${_tmpdir}/autoconfig.cfg"
_test "policy invariants" _policy_contract
_test "desktop generation replaces symlinked entries" _desktop_contract "${_tmpdir}/desktop"
_test "profile deployment containment" _deploy_profile_safety "${_tmpdir}/deploy"

_section verification
while IFS='|' read -r mode label; do
  _test "${label}" _verify_case "${_tmpdir}/verify-${mode}" "${mode}"
done <<'EOF'
pass|accepts current deployed state
drift|fresh runtime drift stops selected target
unlocked|unlocked critical pref stops selected target
missing|missing evidence is pending, not failure
malformed|malformed evidence does not stop target
oversized|oversized evidence is bounded
symlink|symlink evidence is unavailable
producer|producer error is unavailable
staged|staged deployment is pending, not failure
no-profile|deployed files pass without a profile
file-drift|deployed drift is enforced without a profile
unsafe-default|unsafe profile declaration is unavailable
baseline-dirty|dirty baseline is still refreshed
git-fail|baseline refresh does not depend on git
compare-error|comparison failure is unavailable
reader-error|profile reader failure is unavailable
no-install|installation discovery failure does not stop a target
baseline-missing|missing baseline is published atomically
baseline-accept|clean baseline accepts new runtime prefs
webapp-na|uninitialized webapp is not applicable
webapp-missing|initialized webapp without evidence is pending
webapp-pass|webapp overrides compose with global checks
webapp-error|webapp producer error does not stop target
webapp-drift|webapp global drift stops selected target
EOF
_test "standard target publishes its own baseline" \
  _verify_case "${_tmpdir}/verify-standard" baseline-missing standard
_test "snapshot and baseline write discipline" _verify_atomic_contract "${_tmpdir}/atomic"

_section mutation
for mode in pass running external root-symlink ini-dangling ini-directory ini-fifo alias dangling-remnant; do
  _test "clean: ${mode}" _clean_case "${_tmpdir}/clean-${mode}" "${mode}"
done
_test "Flatpak branch and process-state semantics" _flatpak_contract "${_tmpdir}/flatpak"
_test "systemconfig is visible inside sandbox" _systemconfig_case "${_tmpdir}/systemconfig-pass" visible
_test_fail "systemconfig rejects host-only publication" _systemconfig_case "${_tmpdir}/systemconfig-fail" hidden
_test "watch publication and exact recovery" _watch_contract "${_tmpdir}/watch"

_section consistency
_test "status distinguishes sync from drift" _status_contract "${_tmpdir}/status"
_test "runtime dump, lock, and source invariants" _source_contract

printf '\n===============================\n'
printf '  PASS: %d  FAIL: %d\n' "${_pass}" "${_fail}"
printf '===============================\n'
(( _fail == 0 ))
