  <p align="center">
    <img src="hifox.png" alt="hifox" width="181" />
  </p>

<h1 align="center"><code>hifox</code></h1>

<p align="center">Deterministic Firefox hardening and isolated webapp profiles.</p>

## quickstart

```bash
git clone https://github.com/q1sh101/hifox && cd hifox

# standard Firefox
bash hifox.sh install --standard

# Flatpak Firefox
bash hifox.sh install --flatpak
bash hifox.sh install-systemconfig

# auto-detect (standard, Flatpak, or both)
bash hifox.sh install

# install creates ~/.local/bin/hifox
# restart Firefox once so prefs.js is populated
hifox verify  # stops Firefox if drift is detected
hifox status
```

## what it does

- Locks Firefox prefs with `lockPref()` so extensions, websites, and runtime code cannot override them.
- Stops Firefox when deployed prefs or files drift from the repo.
- Turns Firefox updates into reviewable pref diffs through `generated_pref_dump.txt`.
- Runs webapps as isolated Firefox profiles with per-app unlocks for things like microphone, screen share, or DRM.
- Treats the repo as the source of truth: edit config, save, deploy, verify.

## commands

```text
hifox install [--flatpak|--standard]    save target, deploy, install watchers
hifox deploy                            sync repo config to Firefox
hifox verify                            verify live state; stop Firefox on drift
hifox status                            compare repo state with deployed state
hifox clean                             remove stale profile remnants
hifox purge [--flatpak|--standard]      delete profile data after confirmation
hifox logs                              follow deploy and verify logs
hifox watch install|remove|status       manage systemd file watchers
hifox install-systemconfig              register Flatpak systemconfig extension
```

Before install creates the `hifox` command, use `bash hifox.sh <command>`.

## files

```text
config/global_lockprefs.cfg        global Firefox lockPrefs
config/policies.json               Firefox policy controls
config/user.js                     per-profile canary marker
config/autoconfig.js               bootstrap loader for autoconfig.cfg
config/generate_pref_dump.cfg      Firefox pref dump generator
config/generated_pref_dump.txt     reviewed Firefox runtime dump
config/hifox.css                   default profile homepage CSS
webapp/shared/webapp.cfg           shared webapp runtime behavior
webapp/shared/webapp.css           webapp chrome CSS
webapp/<name>/prefs.cfg            per-webapp permission overrides
```

## reference

- [ARCHITECTURE.md](ARCHITECTURE.md) - full system map.
- [MIT License](LICENSE)
