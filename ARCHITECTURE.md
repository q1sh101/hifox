# hifox architecture

hifox enforces Firefox hardening from a repo, on both standard and Flatpak
Firefox: prefs, policies, and profile files are deployed from source, runtime
state is verified against the repo, and drift stops Firefox. This document maps
the deploy pipeline, verification, update detection, and webapp isolation. See
[README.md](README.md) for usage.

## table of contents

1. [overview](#overview)
2. [install](#install)
3. [generation](#generation)
4. [deploy](#deploy)
5. [systemconfig (flatpak)](#systemconfig-flatpak)
6. [startup](#startup)
7. [automation](#automation)
8. [verify](#verify)
9. [status](#status)
10. [drift detection](#drift-detection)
11. [update detection](#update-detection)
12. [webapp](#webapp)
13. [webapp behavior](#webapp-behavior)
14. [clean + purge](#clean--purge)
15. [debug](#debug)
16. [signaling](#signaling)

## overview

```
  repo config defines desired Firefox state. hifox deploys it,
  verifies runtime state, and reports drift.

                          ENFORCEMENT PIPELINE
  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄

       repo (source of truth)
        │
        │  global_lockprefs.cfg ─── your threat model goes here
        │  webapp/<name>/prefs.cfg ─ per-app overrides
        │  policies.json ────────── policy-only features
        │
        ▼
  ┌─ deploy ──────────────────────────────────────────────────────────┐
  │                                                                   │
  │   generate ──> assemble configs ──> push to Firefox ──> enforce   │
  │                one command. repo to runtime. nothing manual.      │
  │                                                                   │
  └───────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
  ┌─ runtime ─────────────────────────────────────────────────────────┐
  │                                                                   │
  │   lockPref()    prefs normal runtime paths, extensions,           │
  │                 and websites cannot change                        │
  │                                                                   │
  │   ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐     │
  │   │    main    │ │  discord   │ │  spotify   │ │    ...     │     │
  │   │  strict    │ │ mic/cam    │ │   DRM      │ │  your      │     │
  │   │  default   │ │ unlocked   │ │ unlocked   │ │  rules     │     │
  │   └────────────┘ └────────────┘ └────────────┘ └────────────┘     │
  │         ╳              ╳              ╳              ╳            │
  │              no shared cookies, data, or permissions              │
  │                                                                   │
  └───────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
  ┌─ integrity ───────────────────────────────────────────────────────┐
  │                                                                   │
  │   verify        drift detected ──> stop Firefox ──> notify        │
  │                 before drift continues                            │
  │                                                                   │
  │   update        new pref appears in Firefox ──> diff ──> notify   │
  │   detection     review the diff before accepting new state        │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘

  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄

  ships with a default lock set. replace it with your own threat model
  if needed. the architecture stays the same.
```

## install

```
  hifox install [--flatpak|--standard]
       │
       ├── detect Firefox
       │   ┌─────────────┐     ┌────────────────────────┐
       │   │ Flatpak     │     │ Standard               │
       │   │ org.mozilla │     │ HIFOX_FIREFOX_DIR,     │
       │   │             │     │ /usr/lib*, /opt/firefox│
       │   └──────┬──────┘     └────────┬───────────────┘
       │          └──────────┬──────────┘
       │                     ▼
       ├── save target ── ~/.config/hifox/target
       ├── deploy
       ├── watch install (systemd units)
       └── symlink ── ~/.local/bin/hifox
```

## generation

```
  four source files, one assembled output.
  webapp/shared/webapp.cfg is split at a marker - per-webapp prefs
  are injected into the gap.

  ┌───────────────────────────┐
  │  global_lockprefs.cfg     │─────────────────────────┐
  │  (policy-type lockPrefs)  │                         │
  └───────────────────────────┘                         │
                                                        │
  ┌───────────────────────────┐                         │
  │  webapp/shared/webapp.cfg │                         │
  │ ┌──────────────────────┐  │                         │
  │ │ profile detection    │  │ <── HEAD                │
  │ ├┄┄ marker ┄┄┄┄┄┄┄┄┄┄┄┄┤  │ <── split               │
  │ │ shared behavior      │  │ <── TAIL                ├──> autoconfig.cfg
  │ └──────────────────────┘  │                         │
  └───────────────────────────┘                         │
           ▲                                            │
           │ injected between HEAD and TAIL             │
  ┌───────────────────────────┐                         │
  │  webapp/<name>/prefs.cfg  │                         │
  │ if (profileDir=="discord")│                         │
  │    isWebapp = true;       │                         │
  │    <overrides>            │                         │
  └───────────────────────────┘                         │
                                                        │
  ┌───────────────────────────┐                         │
  │  generate_pref_dump.cfg   │─────────────────────────┘
  └───────────────────────────┘
```

## deploy

```
  repo                                      Firefox
  ┌─────────────────────────────┐          ┌─────────────────────┐
  │                             │ generate │                     │
  │ config sources ─────────────┼────────> │ autoconfig.cfg      │
  │ config/autoconfig.js ───────┼── copy > │ autoconfig.js       │
  │ config/policies.json ───────┼── copy > │ policies.json       │
  │ config/user.js ─────────────┼── copy > │ user.js             │
  │ config/hifox.css ───────────┼── copy > │ chrome/ (default)   │
  │ webapp/shared/webapp.css ───┼── copy > │ chrome/ (webapps)   │
  │                             │          │                     │
  └─────────────────────────────┘          └─────────────────────┘
                                           user.js/policies may be made immutable
                                           with chattr +i (best-effort, sudo -n)

  orchestration:

  hifox_deploy
       │
       ├── per installation:
       │   ┌─────────────────────────────────────────────────────┐
       │   │  subshell ── isolated failure                       │
       │   │                                                     │
       │   │  policies ──> validate JSON ──> copy ──> lock       │
       │   │  user.js ───> copy to ALL profiles ──> lock each    │
       │   │  autoconfig ─> generate ──> copy                    │
       │   │  homepage ──> hifox.css + logo (default only)       │
       │   │                                                     │
       │   │  webapp profiles                                    │
       │   │    ├── register in profiles.ini (next [ProfileN])   │
       │   │    ├── fix StartWithLastProfile -> 1                │
       │   │    └── create dir ──> copy user.js + shared CSS     │
       │   └─────────────────────────────────────────────────────┘
       │
       ├── webapp .desktop (once, globally)
       │   ┌─────────────────────────────────────────────────────┐
       │   │  .desktop ──> __LAUNCH_SH__ -> launcher path        │
       │   │  icon ──────> cache-bust (cksum in filename)        │
       │   │  orphans ───> prune removed webapps                 │
       │   └─────────────────────────────────────────────────────┘
       │
       ├── refresh watcher (if active ── picks up new dirs)
       │
       └── auto-clean ──> remove remnants (skipped on failed deploy)

  lock flow:

       ┌────────┐     ┌────────┐     ┌────────┐
       │ unlock │────>│  copy  │────>│  lock  │
       └────────┘     └───┬────┘     └────────┘
                          │              ▲
                          └── fail? ─────┘
                              relock where possible
                              (warn if it remains writable)

  file ops: user-first ──> fail? ──> sudo -n fallback
            (for system dirs: /etc, /usr/lib, chattr)
```

## systemconfig (flatpak)

```
  flatpak Firefox runs sandboxed - configs on host /etc do not reach it.
  Mozilla declares an extension point: org.mozilla.firefox.systemconfig
  mounted as /app/etc/firefox inside the sandbox. this command builds + installs it.

  hifox install-systemconfig
       │
       ├── flatpak Firefox required
       │
       ├── detect runtime ── flatpak info org.mozilla.firefox
       │                     (sdk version + branch, no hardcoding)
       │
       ├── stage ── ~/.cache/hifox-build.XXXX/
       │              ├── manifest.yml         (org.mozilla.firefox.systemconfig)
       │              └── content/
       │                  ├── autoconfig.cfg   (generated)
       │                  ├── autoconfig.js    (copy)
       │                  └── policies.json    (copy)
       │
       ├── flatpak-builder ──> --user --install --force-clean
       │
       └── /app/etc/firefox now mounted inside sandbox
              ├── autoconfig.cfg
              ├── defaults/pref/autoconfig.js
              └── policies/policies.json

  one-time per install. re-run after extension uninstall or Firefox runtime changes.
  hifox deploy writes new content into the registered extension dir
  without rebuild, so plain content edits do not require this command.
```

## startup

```
  Firefox starts
       │
       ▼
  autoconfig.js ──── bootstrap loader
       │              sandbox_enabled=false (chrome access)
       ▼
  autoconfig.cfg
  ┌──────────────────────────────────────────────────────┐
  │                                                      │
  │  global lockPrefs ── apply global locks              │
  │       │              + one-shot UI seed              │
  │       │              (sidebar layout, alpenglow      │
  │       │               theme; gated by markers        │
  │       │               _hifox.ui_seeded /             │
  │       │               _hifox.alpenglow_seeded)       │
  │       ▼                                              │
  │  profile detect ─── which profile?                   │
  │       │                                              │
  │       ├── webapp ──> selective unlock                │
  │       │              + shared behavior               │
  │       │              (keyboard, UI, devtools)        │
  │       │                                              │
  │       └── main ───> keep strict default profile      │
  │       │                                              │
  │       ▼                                              │
  │  pref dump ─────── enumerate all prefs               │
  │                    write to profile                  │
  │                    (skip volatile timestamps)        │
  │                                                      │
  └──────────────────────────────────────────────────────┘
       │
       ▼
  policies.json ── policy-only features (prefs can't control)
       │             runs AFTER autoconfig
       ▼             (can override lockPref values)
  hardened

  user.js is empty (canary only) - all prefs managed by lockPref in autoconfig.cfg.
  pref layer order: lockPref > user_pref > pref.
  policies run after autoconfig and can still override overlapping settings.
```

## automation

```
  two directions: you change repo -> auto-deploy.
                  something changes Firefox -> auto-verify.

  ┌──────────────────────────────────────────────────────────┐
  │  REPO WATCHER                                            │
  │  hifox-watch.path ──> hifox-deploy.service               │
  │                                                          │
  │  PathModified ── content edits (scripts, config)         │
  │  PathChanged ─── new files/dirs (webapp/)                │
  │       │                                                  │
  │       └──> hifox deploy ──> Firefox updated              │
  └──────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────┐
  │  INTEGRITY WATCHER                                       │
  │                                                          │
  │  hifox-verify.path                                       │
  │    deployed files (PathChanged - catches deletion):      │
  │      autoconfig.cfg                                      │
  │      autoconfig.js                                       │
  │      policies.json                                       │
  │                                                          │
  │    profile files (PathChanged - all profiles):           │
  │      generated_pref_dump.txt  <── Firefox start          │
  │      user.js                  <── tamper detection       │
  │                                                          │
  │    5s delay (Firefox finishing writes)                   │
  │       │                                                  │
  │       ├── hifox-verify.timer                             │
  │       │   60s after boot, then every 30min               │
  │       │   (fallback: file deletion, profile not yet      │
  │       │    existing at install time)                     │
  │       │                                                  │
  │       └──> hifox verify                                  │
  └──────────────────────────┬───────────────────────────────┘
                             │
                      ┌──────┴──────┐
                   pass          fail ──> stop Firefox + notify

  profile paths: only watched if profile exists at install time.
  30min timer covers the gap. deploy auto-refreshes watcher paths.
```

## verify

```
  hifox verify
       │
       ├── no profile yet? ──> skip installation
       │
       ▼
  wait for prefs.js (up to 15s)
       │
       ▼
  ┌──────────────────────────────────────────────┐
  │  pref integrity (default profile only)       │
  │                                              │
  │  dual-source per check:                      │
  │  prefs.js (user_pref)                        │
  │       │                                      │
  │       └── miss? ──> autoconfig.cfg (lockPref)│
  │                     (base lockPrefs only,    │
  │                      not webapp overrides)   │
  │                                              │
  │  canary, cookieBehavior, HTTPS-only,         │
  │  DRM, shutdown sanitization                  │
  └───────────────────┬──────────────────────────┘
                      ▼
  ┌──────────────────────────────────────────────┐
  │  deploy integrity                            │
  │                                              │
  │  policies.json  ══ diff repo copy            │
  │  autoconfig.js  ══ diff repo copy            │
  │  autoconfig.cfg ══ diff generated output     │
  │  user.js        ══ diff ALL profiles         │
  └───────────────────┬──────────────────────────┘
                      ▼
  ┌──────────────────────────────────────────────┐
  │  dump monitoring                             │
  │                                              │
  │  profile dump ≠ repo dump?                   │
  │       └── yes ──> cp to repo + notify        │
  │                                              │
  │  dump error? ──> fail                        │
  └───────────────────┬──────────────────────────┘
                      ▼
               ┌──────┴──────┐
            pass          fail ──> stop Firefox + notify + exit

  pref checks: default only.  user.js diff: ALL profiles.
  fail -> stop Firefox -> notify -> exit (run: hifox deploy).
```

## status

```
  repo is single source of truth. sha256 proves sync.

  hifox status
       │
       └── per installation:

           repo                          live
           ┌───────────────────┐         ┌───────────────────┐
           │                   │  sha256 │                   │
           │ user.js ──────────┼───vs───>│ managed profiles  │  ok/warn/fail
           │ policies.json ────┼───vs───>│ policies dir      │  ok/warn/fail
           │ autoconfig.cfg* ──┼───vs───>│ sysconfig dir     │  ok/warn/fail
           │                   │         │                   │
           └───────────────────┘         └───────────────────┘
           * regenerated on the fly (not a stored copy)
```
## drift detection

```
  protected                   drift detected
  ┌──────────────┐            ┌──────────────────┐
  │              │  Firefox   │                  │
  │  managed     │  update    │  prefs missing   │
  │  prefs       │ ────────>  │  policies drift  │
  │  locked      │  tamper    │  files deleted   │
  │  policies    │  delete    │  user.js tamper  │
  │  applied     │            │                  │
  │              │            │                  │
  └──────────────┘            └──────┬───────────┘
                                     │
                              ┌──────┴────────────────────────────┐
                              │  detection layers                 │
                              │                                   │
                              │  verify.path (seconds)            │
                              │    PathChanged: 3 deployed        │
                              │    + 2 per profile (dump, uj)     │
                              │                                   │
                              │  verify.timer (30min fallback)    │
                              │    file deletion, missing profile │
                              └───────────────────────────────────┘
                                     │
                                     ▼
                              stop Firefox + notify (critical)
                              user runs: hifox deploy -> restart
```

## update detection

```
  every pref is dumped on every start. Firefox updates silently add or change
  prefs - hifox diffs the full dump, catches meaningful changes, and notifies
  before the new state is accepted.
  (volatile prefs - timestamps, counters, settings cache - skipped for clean signal.)

  ┌─────────┐    ┌──────────────────┐     ┌──────────────────┐
  │ Firefox │    │  autoconfig.cfg  │     │     profile/     │
  │ update  │───>│  pref dump runs  │────>│ generated_pref_  │
  │         │    │  on every start  │     │ dump.txt         │
  └─────────┘    └──────────────────┘     └────────┬─────────┘
                                                   │
                 ┌────────────────────────────────┐│
                 │  hifox verify (auto)           ││
                 │                                ▼│
                 │  profile dump ≠ repo dump? <───┘│
                 │       │                         │
                 │       └── yes ──> cp to repo    │
                 │                   + notify-send │
                 └────────────────┬────────────────┘
                                  │
                                  ▼
  ┌──────────────────────────────────────────────────────────┐
  │  git diff config/generated_pref_dump.txt                 │
  │                                                          │
  │  + browser.new.feature = true              <── new pref  │
  │  - browser.old.setting = true [LOCKED]                   │
  │  + browser.old.setting = false [LOCKED]    <── changed   │
  │                                                          │
  │  review ──> lockPref new threats ──> deploy              │
  └──────────────────────────────────────────────────────────┘

  full cycle:

  update ──> restart ──> dump ──> verify ──> repo ──> notify
                                                        │
                                              git diff <┘
                                                │
                                         lock + deploy
```

## webapp

```
  .desktop ──> launch.sh ──> find Firefox ──> exec -P <name> <url>
                   │                                    │
                   ├── read saved target                ▼
                   └── clean stale locks         separate dock icon
                       (0 Firefox? -> clean)

  dock icon match chain (so the OS shows <name>, not "Firefox"):

    .desktop                StartupWMClass=<name>-web
        │
        ▼
    launch.sh               --name <name>-web  --class <name>-web
        │                   MOZ_APP_REMOTINGNAME=<name>-web
        ▼
    Firefox window          WM_CLASS=<name>-web
        │
        ▼
    desktop env             matches StartupWMClass --> taskbar shows <name>

  per-webapp extension point:

    ${XDG_CONFIG_HOME}/hifox/hooks/webapp/<name>
        if executable, launch.sh execs it instead of the default flow.
        use for custom wrappers (firejail, bwrap, extra flags, ...).

  global wrapper override:

    HIFOX_LAUNCHER=<cmd>     env var that wraps the main-browser exec
                             (webapp paths skip this; use hooks instead).

  why not tabs or Electron:

  browser tab            Electron               hifox (profile per app)
  ┌──────────────┐      ┌────┐ ┌────┐ ┌────┐   ┌────┐ ┌────┐ ┌────┐
  │  A   B   C   │      │ A  │ │ B  │ │ C  │   │ A  │ │ B  │ │ C  │
  │              │      │    │ │    │ │    │   │    │ │    │ │    │
  │ same cookies │      └────┘ └────┘ └────┘   └────┘ └────┘ └────┘
  │ same perms   │
  │ same profile │      3 × Chromium            1 × Firefox
  └──────────────┘
                        no hardening            lockPrefs + policies
  1 leak = all open     full disk access        least privilege
  no control            no control              repo-controlled policy

  any webpage can become a webapp - add a folder, get an isolated profile,
  a menu entry, and its own dock icon. global policy applies automatically.
  override specific permissions per webapp as needed (see selective unlock below).
  looks and works like a native app.

  isolation:

  ┌──────────────────────────────────────────────────────────────────────┐
  │                            Firefox                                   │
  │                                                                      │
  │  ┌────────────┐   ┌────────────┐   ┌────────────┐   ┌────────────┐   │
  │  │    main    │   │  discord   │   │  spotify   │   │  example   │   │
  │  │            │   │            │   │            │   │            │   │
  │  │  strict    │   │ allow:     │   │  allow:    │   │  allow:    │   │
  │  │  locks     │   │  mic       │   │  DRM       │   │  whatever  │   │
  │  │            │   │  camera    │   │  Widevine  │   │  it needs  │   │
  │  │            │   │  autoplay  │   │            │   │            │   │
  │  └────────────┘   └────────────┘   └────────────┘   └────────────┘   │
  │        ╳                 ╳                ╳               ╳          │
  │                                                                      │
  │        no shared cookies, data, or permissions                       │
  └──────────────────────────────────────────────────────────────────────┘

  global lockPrefs apply to every profile. webapp overrides only unlock what
  a specific app needs.

  selective unlock:

  ┌──────────┬──────────────────────────────────────────────┐
  │  main    │  strict default profile                      │
  ├──────────┼──────────────────────────────────────────────┤
  │ discord  │  autoplay, mic, camera                       │
  ├──────────┼──────────────────────────────────────────────┤
  │ spotify  │  DRM (Widevine)                              │
  ├──────────┼──────────────────────────────────────────────┤
  │ example  │  webapp/example/prefs.cfg -> unlock what you │
  │          │  need                                        │
  └──────────┴──────────────────────────────────────────────┘
```

## webapp behavior

```
  webapps should feel like apps, not browsers.
  three layers strip browser behavior: prefs, keyboard, and UI.

  Firefox window opens (webapp profile)
       │
       ▼
  ┌──────────────────────────────────────────────────────┐
  │  shared behavior (webapp/shared/webapp.cfg)          │
  │                                                      │
  │  prefs ──> no suggestions, no tab restore,           │
  │            no reader mode, no tab manager            │
  │                                                      │
  │  pinned tab cleanup ──> unpins leftover tabs         │
  └──────────────────────────┬───────────────────────────┘
                             ▼
  ┌──────────────────────────────────────────────────────┐
  │  keyboard lockdown (layout-independent via e.code)   │
  │                                                      │
  │  layer 1: XUL key removal                            │
  │           disable browser shortcuts at DOM level     │
  │           (22 always + 8 devtools if !debug)         │
  │                                                      │
  │  layer 2: keydown listener                           │
  │           catch remaining browser combos             │
  │           Ctrl+W: protect first tab, close others    │
  └──────────────────────────┬───────────────────────────┘
                             ▼
  ┌──────────────────────────────────────────────────────┐
  │  UI (webapp/shared/webapp.css -> userChrome.css)     │
  │                                                      │
  │  tab bar ──> minimal chrome                          │
  │              single: clean, no close button          │
  │              multi: first tab = icon only            │
  │                                                      │
  │  nav bar ──> reload + uBlock only                    │
  │              URL text invisible, permissions visible │
  │                                                      │
  │  context menu ──> browser-only actions hidden        │
  └──────────────────────────────────────────────────────┘
```

## clean + purge

```
  two levels of cleanup. clean removes remnants. purge deletes profile data.

  ┌─────────────────────────────────────────────────────────────────┐
  │  clean                          │  purge                        │
  │  safe, runs after deploy        │  destructive, interactive     │
  ├─────────────────────────────────┼───────────────────────────────┤
  │  telemetry, crashes,            │  profile data: cookies,       │
  │  experiments, caches,           │  history, logins, sessions,   │
  │  plugins, forms, sync,          │  cache, certificates,         │
  │  suggestions, permissions       │  extensions, site state       │
  ├─────────────────────────────────┼───────────────────────────────┤
  │  keeps: everything else         │  keeps: user.js, chrome/,     │
  │                                 │  profiles.ini, installs.ini   │
  ├─────────────────────────────────┼───────────────────────────────┤
  │  no confirm needed              │  [y/N] confirm required       │
  │  auto-runs at end of deploy     │  manual only                  │
  └─────────────────────────────────┴───────────────────────────────┘

  hifox clean
       └── for each profile: delete known remnant files

  hifox purge [--flatpak|--standard]
       │
       ├── confirm ──── [y/N] (no piped input)
       ├── stop Firefox
       ├── pause verify watcher
       │
       ├── per profile (main + webapps):
       │   delete profile data EXCEPT user.js + chrome/
       │
       ├── external data (whitelist what to KEEP, not what to delete):
       │   flatpak: delete ~/.var/app/org.mozilla.firefox/* except config/
       │   standard: delete ~/.cache/mozilla/
       │
       ├── /tmp: Browser Toolbox temp profiles
       ├── resume verify watcher
       │
       └── next: hifox deploy ──> hardening reapplied

  purge works with or without hifox hardening installed.
```

## debug

```
  Browser Toolbox (not F12 - Firefox's own internal devtools) is off by default.
  two flags control it independently:

  global_lockprefs.cfg            webapp/shared/webapp.cfg
  ┌────────────────────┐         ┌────────────────────┐
  │ debugBrowser       │         │ debugWebapp        │
  │                    │         │                    │
  │ Browser Toolbox    │         │ Browser Toolbox    │
  │ in main browser    │         │ + keyboard unlock  │
  └────────────────────┘         └────────────────────┘

  set true ──> hifox deploy ──> restart ──> Ctrl+Shift+Alt+I
```

## signaling

```
  hifox-specific prefs and dump files create a feedback loop between
  Firefox runtime and shell tools.

  Firefox startup
       │
       ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │  autoconfig.cfg executes inside Firefox                          │
  │                                                                  │
  │  global_lockprefs.cfg                                            │
  │    lockPref("_autoconfig.loaded", true)          <── chain proof │
  │    setBoolPref("_hifox.ui_seeded", true)         <── UI seed     │
  │    setBoolPref("_hifox.alpenglow_seeded", true)  <── theme seed  │
  │                                                                  │
  │  webapp/shared/webapp.cfg                                        │
  │    lockPref("_autoconfig.profile", <dir>)        <── active dir  │
  │    lockPref("_autoconfig.error", <msg>)          <── JS catch    │
  │                                                                  │
  │  generate_pref_dump.cfg                                          │
  │    lockPref("_hifox.pref_dump", "<N> -> <path>") <── success     │
  │    generated_pref_dump.err                        <── failure    │
  │                                                                  │
  │  user.js (profile load)                                          │
  │    user_pref("_user_js.canary", "hifox")         <── file proof  │
  │                                                                  │
  └──────────────────────────────────────────────────────────────────┘
       │
       │ writes prefs.js canary plus dump status files
       ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │  hifox verify (shell side)                                       │
  │                                                                  │
  │  prefs.js ──> _user_js.canary == "hifox"?                        │
  │  generated_pref_dump.err exists and has content?  (dump fail)    │
  │                                                                  │
  │  _autoconfig.loaded     ── diagnostic only (not checked)         │
  │  _autoconfig.profile    ── diagnostic only (not checked)         │
  │  _autoconfig.error      ── diagnostic only (not checked)         │
  │  _hifox.pref_dump       ── diagnostic only (not checked)         │
  │  _hifox.ui_seeded       ── diagnostic only (not checked)         │
  │  _hifox.alpenglow_seeded ── diagnostic only (not checked)        │
  └──────────────────────────────────────────────────────────────────┘
```
