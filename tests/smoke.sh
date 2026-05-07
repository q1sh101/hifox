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

_in_base()   { bash -c "source '${_dir}/lib/base.sh'; _dir='${_dir}'; $1"; }
_in_deploy() { bash -c "source '${_dir}/lib/base.sh'; source '${_dir}/lib/deploy.sh'; _dir='${_dir}'; $1"; }

_ac_grep()   { _test "$1" _in_base "_generate_autoconfig | grep -q '$2'"; }
_pol_q()     { python3 -c "import json,sys; d=json.load(open('${_dir}/config/policies.json')); sys.exit(0 if $1 else 1)"; }
_with_xdg()  { bash -c "export XDG_CONFIG_HOME='$1'; source '${_dir}/lib/base.sh'; $2"; }

_launcher_check() {
  local _name="$1"
  case "${_name}" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

_validate() {
  bash -c 'source "$1/lib/base.sh"; _is_valid_webapp_name "$2"' _ "${_dir}" "$1"
}

_make_pdir() {
  local d="$1" ini="$2"; shift 2
  mkdir -p "${d}"
  printf '%s' "${ini}" > "${d}/profiles.ini"
  for sub in "$@"; do mkdir -p "${d}/${sub}"; done
}

_fresh_ini() {
  local d="$1"
  rm -rf "${d}"; mkdir -p "${d}"
  cat > "${d}/profiles.ini" << 'EOF'
[Profile0]
Name=default
IsRelative=1
Path=aaa.default
Default=1
EOF
}

_make_verify_repo() {
  local repo="$1"
  mkdir -p "${repo}"
  cp -a "${_dir}/config" "${repo}/config"
  cp -a "${_dir}/webapp" "${repo}/webapp"
}

_gen_autoconfig_for() {
  bash -c 'source "$1/lib/base.sh"; _dir="$2"; _generate_autoconfig' _ "${_dir}" "$1"
}

_make_verify_fixture() {
  local root="$1" repo="$2" dump="${3:-fixture.pref = true}"
  local profile="${root}/profile"
  local poldir="${root}/policies"
  local sdir="${root}/sys"

  mkdir -p "${profile}" "${poldir}" "${sdir}/defaults/pref"
  cp "${repo}/config/policies.json" "${poldir}/policies.json"
  cp "${repo}/config/autoconfig.js" "${sdir}/defaults/pref/autoconfig.js"
  cp "${repo}/config/user.js" "${profile}/user.js"
  printf '%s\n' "${dump}" > "${profile}/generated_pref_dump.txt"
  _gen_autoconfig_for "${repo}" > "${sdir}/autoconfig.cfg"
  printf 'user_pref("_user_js.canary", "hifox");\n' > "${profile}/prefs.js"
  touch -t 200001010000 \
    "${poldir}/policies.json" \
    "${sdir}/defaults/pref/autoconfig.js" \
    "${sdir}/autoconfig.cfg" \
    "${profile}/user.js"
  touch -t 200001020000 "${profile}/prefs.js"

  printf '%s|%s|%s\n' "${profile}" "${poldir}" "${sdir}"
}

_verify_fixture() {
  local root="$1"
  local repo="${root}/repo"
  local profile poldir sdir
  _make_verify_repo "${repo}"
  IFS='|' read -r profile poldir sdir < <(_make_verify_fixture "${root}/flatpak" "${repo}")
  cp "${profile}/generated_pref_dump.txt" "${repo}/config/generated_pref_dump.flatpak.txt"

  (
    verify_repo="${repo}"
    verify_root="${root}/flatpak"
    verify_profile="${profile}"
    verify_poldir="${poldir}"
    verify_sdir="${sdir}"
    source "${_dir}/lib/base.sh"
    source "${_dir}/lib/deploy.sh"
    source "${_dir}/lib/verify.sh"
    _dir="${verify_repo}"
    _active_installations() { printf 'flatpak|%s|%s|%s\n' "${verify_root}" "${verify_poldir}" "${verify_sdir}"; }
    _find_profile() { printf '%s\n' "${verify_profile}"; }
    _all_profile_paths() { printf '%s\n' "${verify_profile}"; }
    _kill_firefox() { :; }
    notify-send() { :; }
    _hifox_verify
  )
}

_verify_rejects_pref_drift() {
  local root="$1"
  local repo="${root}/repo"
  local profile poldir sdir
  _make_verify_repo "${repo}"
  IFS='|' read -r profile poldir sdir < <(_make_verify_fixture "${root}/flatpak" "${repo}")
  cp "${profile}/generated_pref_dump.txt" "${repo}/config/generated_pref_dump.flatpak.txt"
  cat >> "${profile}/prefs.js" << 'EOF'
user_pref("privacy.fingerprintingProtection", false);
user_pref("privacy.resistFingerprinting", true);
EOF
  touch -t 200001020001 "${profile}/prefs.js"

  (
    verify_repo="${repo}"
    verify_root="${root}/flatpak"
    verify_profile="${profile}"
    verify_poldir="${poldir}"
    verify_sdir="${sdir}"
    source "${_dir}/lib/base.sh"
    source "${_dir}/lib/deploy.sh"
    source "${_dir}/lib/verify.sh"
    _dir="${verify_repo}"
    _active_installations() { printf 'flatpak|%s|%s|%s\n' "${verify_root}" "${verify_poldir}" "${verify_sdir}"; }
    _find_profile() { printf '%s\n' "${verify_profile}"; }
    _all_profile_paths() { printf '%s\n' "${verify_profile}"; }
    _kill_firefox() { :; }
    notify-send() { :; }
    _hifox_verify
  ) > "${root}/verify.out" 2>&1
  local rc=$?
  if (( rc == 0 )); then
    cat "${root}/verify.out"
    return 1
  fi
}

_verify_writes_per_target_dumps() {
  local root="$1"
  local repo="${root}/repo"
  local f_profile f_poldir f_sdir s_profile s_poldir s_sdir
  _make_verify_repo "${repo}"
  IFS='|' read -r f_profile f_poldir f_sdir < <(_make_verify_fixture "${root}/flatpak" "${repo}" "target = flatpak")
  IFS='|' read -r s_profile s_poldir s_sdir < <(_make_verify_fixture "${root}/standard" "${repo}" "target = standard")
  rm -f \
    "${repo}/config/generated_pref_dump.txt" \
    "${repo}/config/generated_pref_dump.flatpak.txt" \
    "${repo}/config/generated_pref_dump.standard.txt"

  (
    verify_repo="${repo}"
    verify_f_root="${root}/flatpak"
    verify_s_root="${root}/standard"
    verify_f_profile="${f_profile}"
    verify_s_profile="${s_profile}"
    verify_f_poldir="${f_poldir}"
    verify_s_poldir="${s_poldir}"
    verify_f_sdir="${f_sdir}"
    verify_s_sdir="${s_sdir}"
    source "${_dir}/lib/base.sh"
    source "${_dir}/lib/deploy.sh"
    source "${_dir}/lib/verify.sh"
    _dir="${verify_repo}"
    _active_installations() {
      printf 'flatpak|%s|%s|%s\n' "${verify_f_root}" "${verify_f_poldir}" "${verify_f_sdir}"
      printf 'standard|%s|%s|%s\n' "${verify_s_root}" "${verify_s_poldir}" "${verify_s_sdir}"
    }
    _find_profile() {
      case "$1" in
        "${verify_f_root}") printf '%s\n' "${verify_f_profile}" ;;
        "${verify_s_root}") printf '%s\n' "${verify_s_profile}" ;;
        *) return 1 ;;
      esac
    }
    _all_profile_paths() { _find_profile "$1"; }
    _kill_firefox() { :; }
    notify-send() { :; }
    _hifox_verify
  )

  grep -qx 'target = flatpak' "${repo}/config/generated_pref_dump.flatpak.txt" \
    && grep -qx 'target = standard' "${repo}/config/generated_pref_dump.standard.txt" \
    && [[ ! -e "${repo}/config/generated_pref_dump.txt" ]]
}

_tmpdir=$(mktemp -d)
trap 'rm -rf "${_tmpdir}"' EXIT

mapfile -t _sh < <(printf '%s\n' "${_dir}/hifox.sh" "${_dir}/launch.sh" "${_dir}"/lib/*.sh)

mapfile -t _webapps < <(
  for d in "${_dir}/webapp"/*/; do
    [[ -d "${d}" ]] || continue
    wn=$(basename "${d}")
    [[ "${wn}" == "shared" ]] && continue
    printf '%s\n' "${wn}"
  done
)

echo ""
echo "=== syntax ==="
for f in "${_sh[@]}"; do
  _test "bash -n ${f#${_dir}/}" bash -n "${f}"
done

echo ""
echo "=== shellcheck ==="
if command -v shellcheck &>/dev/null; then
  for f in "${_sh[@]}"; do
    # hifox.sh sources its lib/ siblings; -x follows them
    if [[ "${f##*/}" == "hifox.sh" ]]; then
      _test "shellcheck ${f#${_dir}/}" shellcheck -x "${f}"
    else
      _test "shellcheck ${f#${_dir}/}" shellcheck "${f}"
    fi
  done
else
  echo "  SKIP  shellcheck not installed"
fi

echo ""
echo "=== usage / dispatch ==="
_test_fail "no args"            bash "${_dir}/hifox.sh"
_test_fail "bad command"        bash "${_dir}/hifox.sh" badcmd
_test_fail "deploy with arg"    bash "${_dir}/hifox.sh" deploy extra
_test_fail "install no flag"    bash "${_dir}/hifox.sh" install
_test_fail "install bad flag"   bash "${_dir}/hifox.sh" install --garbage
_test_fail "purge bad flag"     bash "${_dir}/hifox.sh" purge --garbage
_test_fail "watch no sub"       bash "${_dir}/hifox.sh" watch
_test_fail "watch bad sub"      bash "${_dir}/hifox.sh" watch evil
_test_fail "install-systemconfig with arg" bash "${_dir}/hifox.sh" install-systemconfig extra
_test_fail "launch.sh rejects bad --target" bash "${_dir}/launch.sh" --target garbage

for cmd in install deploy verify clean purge status logs watch install-systemconfig; do
  _test "usage lists: ${cmd}" bash -c "bash '${_dir}/hifox.sh' 2>&1 | grep -qE ' ${cmd}( |$)'"
done

echo ""
echo "=== webapp name validation (_is_valid_webapp_name) ==="
for n in app web-app web_app org.example a; do
  _test "accept: ${n}" _validate "${n}"
done
for n in '' 'evil;cmd' 'foo/bar' 'a b' 'a$b' 'foo|bar'; do
  _test_fail "reject: ${n:-<empty>}" _validate "${n}"
done

echo ""
echo "=== launcher name guard (rejects dot-prefix too) ==="
for n in app web-app web.app a; do
  _test "accept: ${n}" _launcher_check "${n}"
done
for n in '' .bad ../etc 'evil;cmd' 'foo/bar' .; do
  _test_fail "reject: ${n:-<empty>}" _launcher_check "${n}"
done

echo ""
echo "=== target persistence ==="
_test "save+read round-trip"   _with_xdg "${_tmpdir}/x1" "_save_target flatpak;  [[ \$(_read_target) == flatpak ]]"
_test "persists standard"      _with_xdg "${_tmpdir}/x2" "_save_target standard; [[ \$(_read_target) == standard ]]"
_test "default empty"          _with_xdg "${_tmpdir}/x3" "[[ -z \$(_read_target) ]]"
_test "overwrite previous"     _with_xdg "${_tmpdir}/x4" "_save_target flatpak; _save_target standard; [[ \$(_read_target) == standard ]]"

echo ""
echo "=== profile detection ==="
_p_inst="${_tmpdir}/p_inst"
_make_pdir "${_p_inst}" "[Install4F96D1932A9F858E]
Default=abcd1234.default-release
Locked=1

[Profile1]
Name=default
IsRelative=1
Path=wxyz5678.default
Default=1

[Profile0]
Name=default-release
IsRelative=1
Path=abcd1234.default-release
" abcd1234.default-release wxyz5678.default
_test "Install section preferred"  _in_base "[[ \$(_find_profile '${_p_inst}') == '${_p_inst}/abcd1234.default-release' ]]"

_p_def="${_tmpdir}/p_def"
_make_pdir "${_p_def}" "[Profile0]
Name=default
IsRelative=1
Path=efgh.default
Default=1
" efgh.default
_test "Default=1 picked when no Install" _in_base "[[ \$(_find_profile '${_p_def}') == '${_p_def}/efgh.default' ]]"

_p_orph="${_tmpdir}/p_orph"
_make_pdir "${_p_orph}" "[InstallDEAD]
Default=missing.profile
Locked=1

[Profile0]
Name=default
IsRelative=1
Path=real.default
Default=1
" real.default
_test "orphan Install falls through" _in_base "[[ \$(_find_profile '${_p_orph}') == '${_p_orph}/real.default' ]]"

_p_abs="${_tmpdir}/p_abs"
mkdir -p "${_p_abs}" "${_tmpdir}/abs-profile"
cat > "${_p_abs}/profiles.ini" << EOF
[Profile0]
Name=default
IsRelative=0
Path=${_tmpdir}/abs-profile
Default=1
EOF
_test "IsRelative=0 absolute path" _in_base "[[ \$(_find_profile '${_p_abs}') == '${_tmpdir}/abs-profile' ]]"

_p_glob="${_tmpdir}/p_glob"
mkdir -p "${_p_glob}/zzzz.default-release"
_test "glob fallback no ini"       _in_base "[[ \$(_find_profile '${_p_glob}') == '${_p_glob}/zzzz.default-release' ]]"

_test_fail "fails on missing dir"  _in_base "_find_profile '${_tmpdir}/no-such'"

echo ""
echo "=== adversarial profile inputs ==="
_p_sym="${_tmpdir}/p_sym"
mkdir -p "${_p_sym}"
_outside="${_tmpdir}/outside-file"
: > "${_outside}"
ln -sf "${_outside}" "${_p_sym}/evil.default-release"
cat > "${_p_sym}/profiles.ini" << 'EOF'
[Profile0]
Name=default
IsRelative=1
Path=evil.default-release
Default=1
EOF
_test_fail "_find_profile rejects symlink-to-file" _in_base "_find_profile '${_p_sym}'"

_p_emp="${_tmpdir}/p_emp"
mkdir -p "${_p_emp}"
: > "${_p_emp}/profiles.ini"
_test_fail "_find_profile fails on empty ini" _in_base "_find_profile '${_p_emp}'"

echo ""
echo "=== profile enumeration ==="
_p_lp="${_tmpdir}/p_lp"
_make_pdir "${_p_lp}" "[Profile0]
Name=default
IsRelative=1
Path=aaa.default
Default=1

[Profile1]
Name=app-one
IsRelative=1
Path=bbb.app-one

[Profile2]
Name=app-two
IsRelative=1
Path=ccc.app-two
" aaa.default bbb.app-one ccc.app-two
_test "emits all 3 profiles"   _in_base "(( \$(_list_profile_paths '${_p_lp}' | wc -l) == 3 ))"
_test "emits absolute paths"   _in_base "_list_profile_paths '${_p_lp}' | grep -qx '${_p_lp}/aaa.default'"
_test "includes extra profile" _in_base "_list_profile_paths '${_p_lp}' | grep -qx '${_p_lp}/bbb.app-one'"

_p_adv="${_tmpdir}/p_adv"
_make_pdir "${_p_adv}" "[Profile0]
Name=ok
IsRelative=1
Path=ok.profile

[Profile1]
Name=evil-prefix
IsRelative=1
Path=../../etc

[Profile2]
Name=evil-external
IsRelative=0
Path=/etc

[Profile3]
Name=evil-middle
IsRelative=1
Path=foo/../bar
" ok.profile
_test "skips ../-prefix path"        _in_base "! _list_profile_paths '${_p_adv}' | grep -q '\\.\\.'"
_test "skips IsRelative=0 to /etc"   _in_base "! _list_profile_paths '${_p_adv}' | grep -qx /etc"
_test "skips foo/../bar middle"      _in_base "! _list_profile_paths '${_p_adv}' | grep -q '/foo/'"
_test "still emits good entries"     _in_base "_list_profile_paths '${_p_adv}' | grep -qx '${_p_adv}/ok.profile'"

_test_fail "fails when ini missing"  _in_base "_list_profile_paths '${_tmpdir}/no-such'"

_p_ap="${_tmpdir}/p_ap"
mkdir -p "${_p_ap}/aaa.default-release"
_test "_all_profile_paths glob fallback" _in_base "[[ \$(_all_profile_paths '${_p_ap}') == '${_p_ap}/aaa.default-release' ]]"

echo ""
echo "=== autoconfig generation ==="
_ac_grep "base lockPref present"        '_autoconfig.loaded'
_ac_grep "fingerprint protection lock"  'privacy.fingerprintingProtection'
_ac_grep "webapp marker"                'per-webapp overrides'
_ac_grep "pref dump tail appended"      'generated_pref_dump'

if (( ${#_webapps[@]} > 0 )); then
  _test "ordering: marker < first webapp < shared tail" _in_base "
    out=\$(_generate_autoconfig)
    m=\$(printf '%s\n' \"\${out}\" | grep -n 'per-webapp overrides' | head -1 | cut -d: -f1)
    d=\$(printf '%s\n' \"\${out}\" | grep -n 'profileDir === ' | head -1 | cut -d: -f1)
    s=\$(printf '%s\n' \"\${out}\" | grep -n 'if (isWebapp)' | head -1 | cut -d: -f1)
    (( m < d && d < s ))
  "
fi

_test "deterministic across runs" _in_base "
  a=\$(_generate_autoconfig | sha256sum)
  b=\$(_generate_autoconfig | sha256sum)
  [[ \"\${a}\" == \"\${b}\" ]]
"

_test "validates webapp names before injection" \
  bash -c "awk '/_generate_autoconfig\\(\\)/,/^}$/' '${_dir}/lib/base.sh' | grep -q '_is_valid_webapp_name'"

echo ""
echo "=== webapps (auto-discovered) ==="
declare -A _wpass _wfail
_wtrack() {
  local wn="$1"; shift
  local b_p=${_pass} b_f=${_fail}
  "$@"
  if (( _pass > b_p )); then ((_wpass[${wn}]++)) || true; fi
  if (( _fail > b_f )); then ((_wfail[${wn}]++)) || true; fi
}
for _wn in "${_webapps[@]}"; do
  _w="${_dir}/webapp/${_wn}"
  _wpass[${_wn}]=0
  _wfail[${_wn}]=0
  _wtrack "${_wn}" _ac_grep "${_wn}: injected into autoconfig" "profileDir === \"${_wn}\""
  _wtrack "${_wn}" _test "${_wn}: prefs.cfg present"           test -s "${_w}/prefs.cfg"
  _wtrack "${_wn}" _test "${_wn}: .desktop present"            test -f "${_w}/${_wn}.desktop"
  _wtrack "${_wn}" _test "${_wn}: .desktop has __LAUNCH_SH__"  grep -q '__LAUNCH_SH__' "${_w}/${_wn}.desktop"
  _wtrack "${_wn}" _test "${_wn}: name passes validation"      _validate "${_wn}"
done

echo ""
echo "=== .desktop generation (single-target shadow) ==="

_dt_home="${_tmpdir}/desktop_home"
_dapp="${_dt_home}/.local/share/applications"

_dt_run() {
  local target="$1"
  rm -rf "${_dt_home}"
  mkdir -p "${_dapp}"
  HOME="${_dt_home}" XDG_DATA_HOME="${_dt_home}/.local/share" \
    _DT_DIR="${_dir}" _DT_TARGET="${target}" \
    bash -c '
      set -e
      source "${_DT_DIR}/lib/base.sh"
      source "${_DT_DIR}/lib/deploy.sh"
      _dir="${_DT_DIR}"
      _active_installations() { printf "%s|/tmp/p|/tmp/pol|/tmp/sd\n" "${_DT_TARGET}"; }
      _deploy_desktop_entries > /dev/null
    '
}

_dt_run flatpak
_test "flatpak shadow exists"           test -f "${_dapp}/org.mozilla.firefox.desktop"
_test "flatpak shadow Name=Firefox"     grep -qx 'Name=Firefox' "${_dapp}/org.mozilla.firefox.desktop"
_test "flatpak shadow Exec"             grep -q -- '--target flatpak %u' "${_dapp}/org.mozilla.firefox.desktop"
_test "flatpak shadow not hidden"       bash -c "! grep -qE '^(Hidden|NoDisplay)=true' '${_dapp}/org.mozilla.firefox.desktop'"
_test "no hifox-flatpak alias"          bash -c "! test -f '${_dapp}/org.mozilla.firefox.hifox-flatpak.desktop'"
_test "no hifox-standard alias"         bash -c "! test -f '${_dapp}/org.mozilla.firefox.hifox-standard.desktop'"
for _wn in "${_webapps[@]}"; do
  _wn_name=$(grep -m1 '^Name=' "${_dir}/webapp/${_wn}/${_wn}.desktop" | cut -d= -f2-)
  _wtrack "${_wn}" _test "${_wn}: webapp .desktop exists"  test -f "${_dapp}/org.mozilla.firefox.${_wn}-web.desktop"
  _wtrack "${_wn}" _test "${_wn}: no @-suffix"             bash -c "! test -f '${_dapp}/org.mozilla.firefox.${_wn}-web@flatpak.desktop'"
  _wtrack "${_wn}" _test "${_wn}: Exec --target"           grep -q -- "--target flatpak --webapp ${_wn}" "${_dapp}/org.mozilla.firefox.${_wn}-web.desktop"
  _wtrack "${_wn}" _test "${_wn}: Name=${_wn_name}"        grep -qx "Name=${_wn_name}" "${_dapp}/org.mozilla.firefox.${_wn}-web.desktop"
done

_dt_run standard
_test "standard shadow exists"          test -f "${_dapp}/firefox.desktop"
_test "standard shadow Exec"            grep -q -- '--target standard %u' "${_dapp}/firefox.desktop"
_test "standard no flatpak-named entry" bash -c "! test -f '${_dapp}/org.mozilla.firefox.desktop'"

echo ""
echo "=== profiles.ini mutation ==="
_rp="${_tmpdir}/rp"
_sample_webapp="sample-webapp"
_fresh_ini "${_rp}"
_test "register appends new profile"  _in_deploy "_register_profile '${_rp}' '${_sample_webapp}'; grep -q '^Name=${_sample_webapp}$' '${_rp}/profiles.ini'"
_test "register picks [Profile1]"     grep -qE '^\[Profile1\]$' "${_rp}/profiles.ini"
_test "register Path matches name"    grep -qx "Path=${_sample_webapp}" "${_rp}/profiles.ini"

_fresh_ini "${_rp}"
_test "register idempotent" _in_deploy "
  _register_profile '${_rp}' '${_sample_webapp}'
  _register_profile '${_rp}' '${_sample_webapp}'
  count=\$(grep -c '^Name=${_sample_webapp}$' '${_rp}/profiles.ini')
  (( count == 1 ))
"

_fx="${_tmpdir}/fx"
mkdir -p "${_fx}"
cat > "${_fx}/profiles.ini" << 'EOF'
[General]
StartWithLastProfile=0

[Profile0]
Name=default
IsRelative=1
Path=aaa
Default=1
EOF
_test "fix flips 0 to 1" _in_deploy "_fix_start_with_last_profile '${_fx}'; grep -q '^StartWithLastProfile=1$' '${_fx}/profiles.ini'"

cat > "${_fx}/profiles.ini" << 'EOF'
[General]
StartWithLastProfile=1

[Profile0]
Name=default
EOF
_test "fix no-op when already 1" _in_deploy "
  before=\$(sha256sum '${_fx}/profiles.ini')
  _fix_start_with_last_profile '${_fx}'
  after=\$(sha256sum '${_fx}/profiles.ini')
  [[ \"\${before}\" == \"\${after}\" ]]
"

_test "watch.sh wires profiles.ini path" \
  grep -q 'PathChanged=.*profiles.ini' "${_dir}/lib/watch.sh"

echo ""
echo "=== policies.json ==="
_test "valid JSON"               python3 -c "import json,sys; json.load(open('${_dir}/config/policies.json'))"
_test "blocks unknown extensions" _pol_q "d['policies']['ExtensionSettings']['*']['installation_mode']=='blocked'"
_test "force-installs uBlock"     _pol_q "d['policies']['ExtensionSettings']['uBlock0@raymondhill.net']['installation_mode']=='force_installed'"
_test "minimum TLS 1.2"           _pol_q "d['policies']['SSLVersionMin']=='tls1.2'"
_test "disables safe mode"        _pol_q "d['policies']['DisableSafeMode']==True"
_test "disables master password"  _pol_q "d['policies']['DisableMasterPasswordCreation']==True"

echo ""
echo "=== code patterns ==="
for f in lib/purge.sh lib/clean.sh; do
  _test "${f} uses \${var:?} on rm -rf" grep -qE 'rm -rf "\$\{[a-z_]+:\?\}' "${_dir}/${f}"
done

_test "deploy.sh trap rm tmp"        grep -q 'trap.*rm.*tmp.*EXIT'   "${_dir}/lib/deploy.sh"
_test "systemconfig.sh trap rm stage" grep -q 'trap.*rm.*stage.*EXIT' "${_dir}/lib/systemconfig.sh"

_test "deploy.sh keeps re-lock warn string" grep -q 're-lock failed' "${_dir}/lib/deploy.sh"
_test "install case calls hifox_install_systemconfig" \
  bash -c "awk '/^  install\\)/,/^    ;;/' '${_dir}/hifox.sh' | grep -q 'hifox_install_systemconfig'"

_test "verify accepts deployed fixture"  _verify_fixture "${_tmpdir}/verify-pass"
_test "verify rejects pref drift"        _verify_rejects_pref_drift "${_tmpdir}/verify-fail"
_test "verify writes per-target pref dumps" _verify_writes_per_target_dumps "${_tmpdir}/verify-dumps"

_test "log brackets aligned" bash -c "
  out=\$( { unset JOURNAL_STREAM; source '${_dir}/lib/base.sh'; log x; ok x; warn x; die x; } 2>&1 || true)
  printf '%s\n' \"\${out}\" | awk '
    match(\$0, /\\[[^]]+\\]/) {
      tag = substr(\$0, RSTART, RLENGTH)
      if (length(tag) != 7) exit 1
      seen++
    }
    END { exit(seen == 4 ? 0 : 1) }
  '
"

_test "no dead shell functions" bash -c '
  files=("$@")
  mapfile -t funcs < <(
    grep -hE "^[A-Za-z_][A-Za-z0-9_]*\(\)" "${files[@]}" \
      | sed -E "s/\(\).*//" \
      | sort -u
  )
  for fn in "${funcs[@]}"; do
    count=$(grep -hE "(^|[^A-Za-z0-9_])${fn}([^A-Za-z0-9_]|$)" "${files[@]}" | wc -l)
    (( count > 1 )) || { printf "%s\n" "${fn}"; exit 1; }
  done
' _ "${_sh[@]}"

if (( ${#_webapps[@]} > 0 )); then
  _gen_fail=$(_in_base "_generate_autoconfig 2>/dev/null" >/dev/null 2>&1 && echo 0 || echo 1)
  _gen_size=$(_in_base "_generate_autoconfig 2>/dev/null | wc -c" 2>/dev/null || echo 0)
  _min_gen_size=$((
    $(wc -c < "${_dir}/config/global_lockprefs.cfg") +
    $(wc -c < "${_dir}/webapp/shared/webapp.cfg")
  ))
  echo ""
  echo "=== webapp matrix ==="
  if (( _gen_fail == 1 )) || (( _gen_size < _min_gen_size )); then
    echo "  ! _generate_autoconfig broken (size=${_gen_size}, expected>=${_min_gen_size}) - 'injected' FAILs below are downstream"
    for _wn in "${_webapps[@]}"; do
      _t=$(( ${_wpass[${_wn}]:-0} + ${_wfail[${_wn}]:-0} ))
      printf "  %-12s %d/%d  (generator)\n" "${_wn}:" "${_wpass[${_wn}]:-0}" "${_t}"
    done
  else
    for _wn in "${_webapps[@]}"; do
      _t=$(( ${_wpass[${_wn}]:-0} + ${_wfail[${_wn}]:-0} ))
      if (( ${_wfail[${_wn}]:-0} == 0 )); then
        printf "  %-12s %d/%d  ok\n" "${_wn}:" "${_wpass[${_wn}]:-0}" "${_t}"
      else
        printf "  %-12s %d/%d  FAIL\n" "${_wn}:" "${_wpass[${_wn}]:-0}" "${_t}"
      fi
    done
  fi
fi

echo ""
echo "==============================="
echo "  PASS: ${_pass}  FAIL: ${_fail}"
echo "==============================="

[[ "${_fail}" -eq 0 ]]
