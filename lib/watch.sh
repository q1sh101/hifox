#!/usr/bin/env bash
# lib/watch.sh - systemd automation for auto-deploy
# shellcheck disable=SC2154  # _dir provided by hifox.sh

hifox_watch_install() {
  command -v systemctl &>/dev/null || die "systemctl not found"
  systemctl --user status >/dev/null 2>&1 || die "systemd --user not running"

  local udir
  udir="$(_unit_dir)"
  local exe="${_dir}/hifox.sh"
  mkdir -p "$udir"

  cat > "${udir}/hifox-deploy.service" <<EOF
[Unit]
Description=hifox auto-deploy

[Service]
Type=oneshot
ExecStart="${exe}" deploy
EOF

  # path: watch repo files for changes
  {
    echo "[Unit]"
    echo "Description=Watch hifox repo for config changes"
    echo ""
    echo "[Path]"
    echo "PathModified=${_dir}/hifox.sh"
    echo "PathModified=${_dir}/config/user.js"
    echo "PathModified=${_dir}/config/policies.json"
    # tool source
    for f in "${_dir}/lib"/*.sh; do
      [[ -f "$f" ]] && echo "PathModified=$f"
    done
    # detect new profile/app dirs
    # global autoconfig source files (exclude generated artifacts)
    local f
    for f in "${_dir}/config"/*; do
      [[ -f "$f" ]] || continue
      [[ "$(basename "$f")" == "generated_pref_dump.txt" ]] && continue
      echo "PathModified=$f"
    done
    done
    echo "Unit=hifox-deploy.service"
  } > "${udir}/hifox-watch.path"
  cat >> "${udir}/hifox-watch.path" <<EOF

[Install]
WantedBy=default.target
EOF

  # verify service: integrity check (triggered by path + timer)
  cat > "${udir}/hifox-verify.service" <<EOF
[Unit]
Description=hifox verify Firefox hardening integrity

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart="${exe}" verify
EOF

  # verify path: watch deployed files in Firefox directories (live detection)
  {
    echo "[Unit]"
    echo "Description=Watch Firefox for hardening drift"
    echo ""
    echo "[Path]"
    local _type _pdir poldir sdir
    while IFS='|' read -r _type _pdir poldir sdir; do
      echo "PathChanged=${sdir}/autoconfig.cfg"
      echo "PathChanged=${sdir}/defaults/pref/autoconfig.js"
      echo "PathChanged=${poldir}/policies.json"
      # profile files (all profiles)
      local _prof_path
      while IFS= read -r _prof_path; do
        [[ -d "$_prof_path" ]] || continue
        echo "PathChanged=${_prof_path}/generated_pref_dump.txt"
        echo "PathChanged=${_prof_path}/user.js"
      done < <(_all_profile_paths "$_pdir")
    done < <(_active_installations)
    echo "Unit=hifox-verify.service"
  } > "${udir}/hifox-verify.path"
  cat >> "${udir}/hifox-verify.path" <<EOF

[Install]
WantedBy=default.target
EOF

  # verify timer: fallback periodic check (catches file deletion)
  cat > "${udir}/hifox-verify.timer" <<EOF
[Unit]
Description=hifox periodic hardening check

[Timer]
OnBootSec=60
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now hifox-watch.path \
    || die "failed to enable hifox-watch.path"
  systemctl --user enable --now hifox-verify.path \
    || die "failed to enable hifox-verify.path"
  systemctl --user enable --now hifox-verify.timer \
    || die "failed to enable hifox-verify.timer"

  ok "watch installed - repo changes auto-deploy"
  ok "verify installed - live drift detection + 30min fallback"
}

hifox_watch_remove() {
  command -v systemctl &>/dev/null || die "systemctl not found"
  local udir
  udir="$(_unit_dir)"

  systemctl --user disable --now hifox-watch.path 2>/dev/null || true
  systemctl --user disable --now hifox-verify.path 2>/dev/null || true
  systemctl --user disable --now hifox-verify.timer 2>/dev/null || true
  rm -f "${udir}/hifox-deploy.service"
  rm -f "${udir}/hifox-watch.path"
  rm -f "${udir}/hifox-verify.service"
  rm -f "${udir}/hifox-verify.path"
  rm -f "${udir}/hifox-verify.timer"
  systemctl --user daemon-reload

  ok "watch + verify removed"
}

hifox_watch_status() {
  command -v systemctl &>/dev/null || die "systemctl not found"
  systemctl --user status hifox-watch.path 2>&1 || true
  echo ""
  systemctl --user status hifox-verify.path 2>&1 || true
  echo ""
  systemctl --user status hifox-verify.timer 2>&1 || true
}
