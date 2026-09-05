#!/usr/bin/env bash
set -euo pipefail

_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
_tmpdir=$(mktemp -d /tmp/hifox-integration.XXXXXX)
_tracked_pids=()

_cleanup() {
  local pid pgid
  for pid in "${_tracked_pids[@]}"; do
    [[ -n "${pid}" ]] || continue
    pgid=$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d ' ') || pgid=""
    if [[ "${pgid}" == "${pid}" ]]; then
      kill -TERM -- "-${pid}" 2>/dev/null || true
    else
      kill -TERM "${pid}" 2>/dev/null || true
    fi
  done
  for pid in "${_tracked_pids[@]}"; do
    wait "${pid}" 2>/dev/null || true
  done
  rm -rf "${_tmpdir:?}"
}
trap _cleanup EXIT INT TERM

_wait_until() {
  local attempts="$1"
  shift
  local attempt
  for ((attempt = 0; attempt < attempts; attempt++)); do
    "$@" && return 0
    sleep 0.05
  done
  "$@"
}

_pid_dead() { ! kill -0 "$1" 2>/dev/null; }
_file_exists() { [[ -e "$1" ]]; }
_line_count_is() { [[ "$(wc -l < "$1" 2>/dev/null || true)" == "$2" ]]; }

_pass() { printf '  PASS  %s\n' "$1"; }

_fixture_env() {
  local home="$1" bin="$2"
  shift 2
  env HOME="${home}" XDG_CONFIG_HOME="${home}/.config" \
    XDG_DATA_HOME="${home}/.local/share" XDG_CACHE_HOME="${home}/.cache" \
    PATH="${bin}:${PATH}" "$@"
}

_test_targeted_stop() {
  local root="${_tmpdir}/target-stop" selected_pid other_pid
  local selected="${_tmpdir}/target-stop/selected" other="${_tmpdir}/target-stop/other"
  mkdir -p "${selected}" "${other}"
  cp "$(command -v python3)" "${selected}/firefox"
  cp "$(command -v python3)" "${other}/firefox"
  "${selected}/firefox" -c 'import time; time.sleep(30)' & selected_pid=$!
  "${other}/firefox" -c 'import time; time.sleep(30)' & other_pid=$!
  _tracked_pids+=("${selected_pid}" "${other_pid}")

  source "${_dir}/lib/base.sh"
  _wait_until 100 bash -c '[[ "$(readlink -f "/proc/$1/exe" 2>/dev/null)" == "$2/firefox" ]]' \
    _ "${selected_pid}" "${selected}"
  _wait_until 100 bash -c '[[ "$(readlink -f "/proc/$1/exe" 2>/dev/null)" == "$2/firefox" ]]' \
    _ "${other_pid}" "${other}"
  rm -f "${selected}/firefox"
  [[ "$(_standard_firefox_pids "${selected}")" == "${selected_pid}" ]]

  _stop_firefox standard "${selected}"
  _wait_until 100 _pid_dead "${selected_pid}"
  kill -0 "${other_pid}" 2>/dev/null
  kill -TERM "${other_pid}"
  _wait_until 100 _pid_dead "${other_pid}"
  wait "${selected_pid}" 2>/dev/null || true
  wait "${other_pid}" 2>/dev/null || true
  _pass "selected deleted-on-upgrade executable stops without touching unrelated Firefox PID (selected=${selected_pid}, other=${other_pid})"
}

_make_runtime_seed() {
  sed -n 's/^lockPref("\([^"]*\)", *\(.*\));.*/\1 = \2 [LOCKED]/p' \
    "${_dir}/config/global_lockprefs.cfg" \
    | sed 's/ = "\(.*\)" \[LOCKED\]$/ = \1 [LOCKED]/'
  printf '_user_js.canary = hifox\n'
}

_run_fixture_verify() {
  local repo="$1" pdir="$2" poldir="$3" sdir="$4"
  VERIFY_REPO="${repo}" VERIFY_PDIR="${pdir}" VERIFY_POLDIR="${poldir}" VERIFY_SDIR="${sdir}" \
    HIFOX_SOURCE="${_dir}" bash -c '
      set -euo pipefail
      source "${HIFOX_SOURCE}/lib/base.sh"
      source "${HIFOX_SOURCE}/lib/deploy.sh"
      source "${HIFOX_SOURCE}/lib/verify.sh"
      _dir="${VERIFY_REPO}"
      _active_installations() {
        printf "standard|%s|%s|%s\n" "${VERIFY_PDIR}" "${VERIFY_POLDIR}" "${VERIFY_SDIR}"
      }
      notify-send() { :; }
      _hifox_verify
    '
}

_test_background_publication() {
  local root="${_tmpdir}/publication" producer_pid verify_rc=0
  local repo="${root}/repo" pdir="${root}/profiles" poldir="${root}/policies" sdir="${root}/firefox"
  local profile="${root}/profiles/main.default" seed="${root}/complete-dump"
  local final="${root}/profiles/main.default/generated_pref_dump.txt"
  local ready="${root}/producer-ready" release="${root}/producer-release"

  mkdir -p "${repo}" "${profile}" "${poldir}" "${sdir}/defaults/pref"
  cp -a "${_dir}/config" "${repo}/config"
  cp -a "${_dir}/webapp" "${repo}/webapp"
  cp "${repo}/config/policies.json" "${poldir}/policies.json"
  cp "${repo}/config/autoconfig.js" "${sdir}/defaults/pref/autoconfig.js"
  cp "${repo}/config/user.js" "${profile}/user.js"
  printf '[Profile0]\nName=main\nIsRelative=1\nPath=main.default\nDefault=1\n' > "${pdir}/profiles.ini"
  _make_runtime_seed > "${seed}"
  cp "${seed}" "${repo}/config/generated_pref_dump.standard.txt"
  REPO="${repo}" SOURCE="${_dir}" bash -c \
    'source "${SOURCE}/lib/base.sh"; _dir="${REPO}"; _generate_autoconfig' \
    > "${sdir}/autoconfig.cfg"
  touch -t 200001010000 "${poldir}/policies.json" \
    "${sdir}/defaults/pref/autoconfig.js" "${sdir}/autoconfig.cfg" "${profile}/user.js"

  cp "$(command -v python3)" "${sdir}/firefox"
  "${sdir}/firefox" -c '
import os, sys, time
seed, final, ready, release = sys.argv[1:]
tmp = final + ".tmp"
def write_synced(payload):
    with open(tmp, "wb") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
data = open(seed, "rb").read()
write_synced(data[:max(1, len(data) // 3)])
with open(ready, "w", encoding="utf-8") as marker:
    marker.write(str(os.getpid()))
deadline = time.monotonic() + 10
while not os.path.exists(release) and time.monotonic() < deadline:
    time.sleep(0.02)
if not os.path.exists(release):
    raise SystemExit(2)
write_synced(data)
os.replace(tmp, final)
' "${seed}" "${final}" "${ready}" "${release}" & producer_pid=$!
  _tracked_pids+=("${producer_pid}")

  _wait_until 100 _file_exists "${ready}"
  [[ -s "${final}.tmp" && ! -e "${final}" ]]
  _run_fixture_verify "${repo}" "${pdir}" "${poldir}" "${sdir}" \
    > "${root}/verify-missing.log" 2>&1 || verify_rc=$?
  # an unfinished dump is pending, not failure: exit 0 and leave the producer alone
  (( verify_rc == 0 ))
  grep -q 'awaiting a Firefox restart' "${root}/verify-missing.log"
  kill -0 "${producer_pid}" 2>/dev/null
  [[ ! -e "${final}" ]]

  : > "${release}"
  _wait_until 100 _file_exists "${final}"
  _wait_until 100 _pid_dead "${producer_pid}"
  wait "${producer_pid}"
  [[ ! -e "${final}.tmp" ]]
  cmp -s "${seed}" "${final}"
  _run_fixture_verify "${repo}" "${pdir}" "${poldir}" "${sdir}" \
    > "${root}/verify-complete.log" 2>&1
  _pass "background producer stays alive on missing evidence and publishes atomically (producer=${producer_pid})"
}

_write_command_stubs() {
  local bin="$1"
  mkdir -p "${bin}"
  cat > "${bin}/command-stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${0##*/}:${1:-}" in
  flatpak:info)
    if [[ -n "${HIFOX_IT_LOG:-}" ]]; then
      printf '%s enter %s\n' "$(date +%s%N)" "$$" >> "${HIFOX_IT_LOG}"
      if mkdir "${HIFOX_IT_HOLDER}" 2>/dev/null; then
        : > "${HIFOX_IT_ENTERED}"
        for ((i = 0; i < 500; i++)); do
          [[ -e "${HIFOX_IT_RELEASE}" ]] && break
          sleep 0.02
        done
        [[ -e "${HIFOX_IT_RELEASE}" ]] || exit 2
      fi
    fi
    printf 'app/org.mozilla.firefox/x86_64/beta\n'
    ;;
  flatpak:ps)
    [[ -z "${HIFOX_IT_STOPPED:-}" || -e "${HIFOX_IT_STOPPED}" ]] \
      || printf 'org.mozilla.firefox\n'
    ;;
  flatpak:kill)
    if [[ -n "${HIFOX_IT_SHUTDOWN_PROFILE:-}" ]]; then
      mkdir -p "${HIFOX_IT_SHUTDOWN_PROFILE}/chrome"
      printf 'keep\n' > "${HIFOX_IT_SHUTDOWN_PROFILE}/user.js"
      printf 'keep\n' > "${HIFOX_IT_SHUTDOWN_PROFILE}/chrome/canary"
      printf 'remove\n' > "${HIFOX_IT_SHUTDOWN_PROFILE}/places.sqlite"
      printf '\n[Profile1]\nName=shutdown\nIsRelative=1\nPath=shutdown.default\n' \
        >> "${HIFOX_IT_PROFILES_INI}"
      : > "${HIFOX_IT_STOPPED}"
    fi
    ;;
  sudo:*)
    [[ -z "${HIFOX_IT_SUDO_LOG:-}" ]] || printf '%s\n' "$*" >> "${HIFOX_IT_SUDO_LOG}"
    exit 1
    ;;
  systemctl:*)
    [[ "$*" != *' is-active '* ]] || { printf 'inactive\n'; exit 3; }
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${bin}/command-stub"
  ln -s command-stub "${bin}/flatpak"
  ln -s command-stub "${bin}/sudo"
  ln -s command-stub "${bin}/systemctl"
}

_run_purge() {
  local home="$1" bin="$2" log="$3" rc
  shift 3
  set +e
  printf 'y\n' | _fixture_env "${home}" "${bin}" "$@" \
    script -qefc "\"${_dir}/hifox.sh\" purge --flatpak" /dev/null \
    > "${log}" 2>&1
  rc=${PIPESTATUS[1]}
  set -e
  return "${rc}"
}

_test_concurrent_cli_and_signal_recovery() {
  local root="${_tmpdir}/locking" first second pgid second_rc=0
  local home="${root}/home" bin="${root}/bin" log="${root}/flatpak.log"
  local entered="${root}/entered" holder="${root}/holder" release="${root}/release"
  local lock_dir="${root}/home/.config/hifox" canary="${root}/operator-owned"
  local -a cli_env
  mkdir -p "${home}/.config/hifox"
  printf 'flatpak\n' > "${home}/.config/hifox/target"
  printf 'preserve\n' > "${canary}"
  ln -s "${canary}" "${lock_dir}/operation.lock"
  : > "${log}"
  _write_command_stubs "${bin}"
  cli_env=(
    "HIFOX_IT_LOG=${log}" "HIFOX_IT_ENTERED=${entered}"
    "HIFOX_IT_HOLDER=${holder}" "HIFOX_IT_RELEASE=${release}"
  )

  _fixture_env "${home}" "${bin}" "${cli_env[@]}" \
    setsid "${_dir}/hifox.sh" deploy > "${root}/first.log" 2>&1 & first=$!
  _tracked_pids+=("${first}")
  _wait_until 100 _file_exists "${entered}"
  grep -qx 'preserve' "${canary}"

  _fixture_env "${home}" "${bin}" "${cli_env[@]}" \
    setsid "${_dir}/hifox.sh" deploy > "${root}/second.log" 2>&1 & second=$!
  _tracked_pids+=("${second}")
  _wait_until 100 bash -c '[[ "$(readlink -f "/proc/$1/fd/9" 2>/dev/null)" == "$2" ]]' \
    _ "${second}" "${lock_dir}"
  kill -0 "${first}" 2>/dev/null
  kill -0 "${second}" 2>/dev/null
  _line_count_is "${log}" 1

  pgid=$(ps -o pgid= -p "${first}" | tr -d ' ')
  [[ "${pgid}" == "${first}" ]]
  kill -TERM -- "-${first}"
  _wait_until 100 _pid_dead "${first}"
  : > "${release}"
  _wait_until 300 _pid_dead "${second}"
  wait "${first}" 2>/dev/null || true
  wait "${second}" || second_rc=$?
  if (( second_rc != 0 )); then
    printf 'second deploy exited %s\n' "${second_rc}" >&2
    sed 's/^/  second: /' "${root}/second.log" >&2
    return 1
  fi
  (( $(wc -l < "${log}") >= 2 ))
  grep -qx 'preserve' "${canary}"
  _pass "directory lock avoids symlink truncation, serializes CLI operations, and recovers after group interruption (first=${first}, second=${second})"
}

_test_purge_boundaries() {
  local root="${_tmpdir}/purge" rc=0
  local home="${root}/home" stopped="${root}/stopped" sudo_log="${root}/sudo.log" bin="${root}/bin"
  local fp_root="${root}/home/.var/app/org.mozilla.firefox"
  local pdir="${fp_root}/.config/mozilla/firefox" migration_pdir="${fp_root}/.mozilla/firefox"
  local profile="${fp_root}/.config/mozilla/firefox/main.default"
  local migration_profile="${fp_root}/.mozilla/firefox/migrated.default"
  local shutdown_profile="${fp_root}/.config/mozilla/firefox/shutdown.default"
  mkdir -p "${profile}/chrome" "${migration_profile}/chrome" "${fp_root}/config" \
    "${fp_root}/cache" "${home}/.config/hifox" "${bin}"
  printf 'flatpak\n' > "${home}/.config/hifox/target"
  printf '[Profile0]\nName=main\nIsRelative=1\nPath=main.default\nDefault=1\n' > "${pdir}/profiles.ini"
  printf 'keep\n' > "${profile}/user.js"
  printf 'keep\n' > "${profile}/chrome/canary"
  printf 'remove\n' > "${profile}/places.sqlite"
  printf '[Profile0]\nName=migrated\nIsRelative=1\nPath=migrated.default\nDefault=1\n' > "${migration_pdir}/profiles.ini"
  printf 'keep\n' > "${migration_profile}/user.js"
  printf 'keep\n' > "${migration_profile}/chrome/canary"
  printf 'remove\n' > "${migration_profile}/cookies.sqlite"
  printf 'keep\n' > "${fp_root}/config/canary"
  printf 'keep\n' > "${fp_root}/.mozilla/canary"
  printf 'remove\n' > "${fp_root}/cache/canary"
  printf 'remove\n' > "${fp_root}/top-level-file"
  ln -s "${fp_root}/config" "${fp_root}/alias-to-config"
  ln -s "${fp_root}/missing-target" "${fp_root}/dangling-alias"

  _write_command_stubs "${bin}"
  _run_purge "${home}" "${bin}" "${root}/purge.log" \
    "HIFOX_IT_STOPPED=${stopped}" "HIFOX_IT_SHUTDOWN_PROFILE=${shutdown_profile}" \
    "HIFOX_IT_PROFILES_INI=${pdir}/profiles.ini" "HIFOX_IT_SUDO_LOG=${sudo_log}" \
    || rc=$?

  (( rc == 0 ))
  # rm unlinks an alias in the data root without following it into protected data
  grep -q 'cleared: alias-to-config' "${root}/purge.log"
  grep -q 'cleared: dangling-alias' "${root}/purge.log"
  [[ -f "${profile}/user.js" && -f "${profile}/chrome/canary" ]]
  [[ ! -e "${profile}/places.sqlite" && ! -e "${fp_root}/cache" \
    && ! -e "${fp_root}/top-level-file" ]]
  [[ -f "${migration_profile}/user.js" && -f "${migration_profile}/chrome/canary" ]]
  [[ ! -e "${migration_profile}/cookies.sqlite" ]]
  [[ -f "${shutdown_profile}/user.js" && -f "${shutdown_profile}/chrome/canary" ]]
  [[ ! -e "${shutdown_profile}/places.sqlite" ]]
  [[ -f "${fp_root}/config/canary" && -f "${fp_root}/.mozilla/canary" ]]
  [[ ! -e "${fp_root}/alias-to-config" && ! -L "${fp_root}/alias-to-config" ]]
  [[ ! -L "${fp_root}/dangling-alias" ]]
  ! grep -q 'chattr.*user.js' "${sudo_log}" 2>/dev/null
  _pass "real PTY purge re-captures shutdown profiles, handles both migration roots, and unlinks aliases without following them"
}

_test_purge_refuses_unsafe_layouts() {
  local root="${_tmpdir}/purge-refusal" bin mode home fp_root pdir outside log expected rc
  bin="${root}/bin"
  _write_command_stubs "${bin}"

  for mode in root-symlink external-profile; do
    home="${root}/${mode}-home"
    fp_root="${home}/.var/app/org.mozilla.firefox"
    mkdir -p "${home}/.config/hifox"
    printf 'flatpak\n' > "${home}/.config/hifox/target"

    if [[ "${mode}" == root-symlink ]]; then
      outside="${root}/root-symlink-outside"
      mkdir -p "${fp_root}/.config/mozilla" "${outside}/main.default"
      ln -s "${outside}" "${fp_root}/.config/mozilla/firefox"
      printf '[Profile0]\nName=main\nIsRelative=1\nPath=main.default\nDefault=1\n' \
        > "${outside}/profiles.ini"
      printf 'preserve\n' > "${outside}/main.default/places.sqlite"
      expected='unsafe Firefox profile root'
    else
      pdir="${fp_root}/.config/mozilla/firefox"
      outside="${root}/external.default"
      mkdir -p "${pdir}/safe.default" "${outside}"
      printf '[Profile0]\nName=safe\nIsRelative=1\nPath=safe.default\nDefault=1\n\n' \
        > "${pdir}/profiles.ini"
      printf '[Profile1]\nName=outside\nIsRelative=0\nPath=%s\n' "${outside}" \
        >> "${pdir}/profiles.ini"
      printf 'preserve-safe\n' > "${pdir}/safe.default/places.sqlite"
      printf 'preserve-outside\n' > "${outside}/places.sqlite"
      expected='unsafe, unresolved, or unreadable profile declaration'
    fi

    log="${root}/${mode}.log"
    rc=0
    _run_purge "${home}" "${bin}" "${log}" || rc=$?
    (( rc != 0 ))
    grep -q "${expected}" "${log}"
    if [[ "${mode}" == root-symlink ]]; then
      grep -qx 'preserve' "${outside}/main.default/places.sqlite"
    else
      grep -qx 'preserve-safe' "${pdir}/safe.default/places.sqlite"
      grep -qx 'preserve-outside' "${outside}/places.sqlite"
    fi
  done
  _pass "real PTY purge refuses root symlinks and external profile declarations before deletion"
}

printf '\n=== real background integration ===\n'
_test_targeted_stop
_test_background_publication
_test_concurrent_cli_and_signal_recovery
_test_purge_boundaries
_test_purge_refuses_unsafe_layouts
printf '\n  PASS: 5  FAIL: 0\n'
