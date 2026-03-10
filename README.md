  <p align="center">
    <img src="hifox.png" alt="hifox" width="221" />
  </p>

<h1 align="center"><code>hifox</code></h1>

<p align="center">Deterministic Firefox hardening framework.<br>Not a config file - an enforcement architecture.</p>

## tl;dr + quickstart

```bash
# lock down Firefox. keep it locked. control everything.
# - no user.js - hardening at a level Firefox itself can't override
# - tamper detection: something changes -> kill Firefox + notify
# - repo is the source of truth: edit, save, auto-deployed
# - webapps: isolated profiles, selective permissions, native feel
#
# quickstart:
bash hifox.sh install
# restart Firefox once so prefs.js is populated
hifox verify
hifox status
```

```
commands:
  bash hifox.sh install [--flatpak|--standard]   first-time setup (deploy + watcher + symlink)
  hifox deploy                                   push hardening to Firefox
  hifox verify                                   check hardening integrity (prefs + files + dump)
  hifox status                                   show sync state (repo vs live)
  hifox clean                                    remove stale remnant files from profiles
  hifox purge [--flatpak|--standard]             nuclear wipe: delete ALL data from profiles
  hifox logs                                     follow deploy + verify output
  hifox watch install|remove|status              manage file watcher (systemd)
```

## table of contents

1. [notes](#notes)
2. [install](#install)
3. [generation](#generation)
4. [deploy](#deploy)
5. [startup](#startup)
6. [automation](#automation)
7. [verify](#verify)
8. [status](#status)
9. [drift detection](#drift-detection)
10. [update detection](#update-detection)
11. [webapp](#webapp)
12. [webapp behavior](#webapp-behavior)
13. [clean + purge](#clean--purge)
14. [debug](#debug)
15. [signaling](#signaling)

## notes

```
  config files define what to lock. the framework guarantees it stays locked.

                          ENFORCEMENT PIPELINE
  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄

       repo (source of truth)
        │
        │  global_lockprefs.cfg ─── your threat model goes here
        │  webapp/*/prefs.cfg ───── per-app overrides
        │  policies.json ────────── policy-only features
        │
        ▼
  ┌─ deploy ──────────────────────────────────────────────────────────┐
  │                                                                   │
  │   generate ──> assemble configs ──> push to Firefox ──> lock 🔒   │
  │                one command. repo to runtime. nothing manual.      │
  │                                                                   │
  └───────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
  ┌─ runtime ─────────────────────────────────────────────────────────┐
  │                                                                   │
  │   lockPref()    highest enforcement. browser, extensions,         │
  │                 websites -nothing overrides. ever.                │
  │                                                                   │
  │   ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐     │
  │   │    main    │ │  discord   │ │  spotify   │ │    ...     │     │
  │   │  🔒 max    │ │  🎤 🎥     │ │  🔑 DRM    │ │  your      │     │
  │   │   locked   │ │  unlocked  │ │  unlocked  │ │  rules     │     │
  │   └────────────┘ └────────────┘ └────────────┘ └────────────┘     │
  │         ╳              ╳              ╳              ╳            │
  │              zero shared cookies, data, or state                  │
  │                                                                   │
  └───────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
  ┌─ integrity ───────────────────────────────────────────────────────┐
  │                                                                   │
  │   verify        drift detected ──> kill Firefox ──> notify        │
  │                 before damage. seconds, not hours.                │
  │                                                                   │
  │   update        new pref appears in Firefox ──> diff ──> notify   │
  │   detection     you know before it runs.                          │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘

  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄

  ships with hundreds of locks. empty it. write your own.
  the architecture is the same. your threat model. your rules.
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
  webapp.cfg is split at a marker - per-webapp prefs injected into the gap.

  ┌───────────────────────────┐
  │  global_lockprefs.cfg     │─────────────────────────┐
  │  (policy-type lockPrefs)  │                         │
  └───────────────────────────┘                         │
                                                        │
  ┌───────────────────────────┐                         │
  │  webapp.cfg               │                         │
  │ ┌──────────────────────┐  │                         │
  │ │ profile detection    │  │ <── HEAD                │
  │ ├┄┄ marker ┄┄┄┄┄┄┄┄┄┄┄┄┤  │ <── split               │
  │ │ shared behavior      │  │ <── TAIL                ├──> autoconfig.cfg
  │ └──────────────────────┘  │                         │
  └───────────────────────────┘                         │
           ▲                                            │
           │ injected between HEAD and TAIL             │
  ┌───────────────────────────┐                         │
  │  webapp/*/prefs.cfg       │                         │
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
  repo                              Firefox
  ┌─────────────────────┐          ┌─────────────────────┐
  │                     │ generate │                     │
  │ config sources ─────┼────────> │ autoconfig.cfg      │
  │ autoconfig.js ──────┼── copy > │ autoconfig.js       │
  │ policies.json ──────┼── copy > │ policies.json  🔒   │
  │ user.js ────────────┼── copy > │ user.js        🔒   │
  │ hifox.css ──────────┼── copy > │ chrome/ (default)   │
  │ webapp.css ─────────┼── copy > │ chrome/ (webapps)   │
  │                     │          │                     │
  └─────────────────────┘          └─────────────────────┘
                                    🔒 = chattr +i (best-effort, requires sudo -n)

  orchestration:

  hifox_deploy
       │
       ├── per installation:
       │   ┌─────────────────────────────────────────────────────┐
       │   │  subshell ── isolated failure                       │
       │   │                                                     │
       │   │  policies ──> validate JSON ──> copy ──> 🔒         │
       │   │  user.js ───> copy to ALL profiles ──> 🔒 each      │
       │   │  autoconfig ─> generate ──> copy                    │
       │   │  homepage ──> hifox.css + logo (default only)       │
       │   │                                                     │
       │   │  webapp profiles                                    │
       │   │    ├── register in profiles.ini (next [ProfileN])   │
       │   │    ├── fix StartWithLastProfile -> 1                │
       │   │    └── create dir ──> copy user.js 🔒 + webapp.css  │
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

  🔒 lock flow:

       ┌────────┐     ┌────────┐     ┌────────┐
       │ unlock │────>│  copy  │────>│  lock  │
       └────────┘     └───┬────┘     └────────┘
                          │              ▲
                          └── fail? ─────┘
                              relock anyway
                              (never leave writable)

  file ops: user-first ──> fail? ──> sudo -n fallback
            (for system dirs: /etc, /usr/lib, chattr)
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
  │  global lockPrefs ── lock everything                 │
  │       │                                              │
  │       ▼                                              │
  │  profile detect ─── which profile?                   │
  │       │                                              │
  │       ├── webapp ──> selective unlock                │
  │       │              + shared behavior               │
  │       │              (keyboard, UI, devtools)        │
  │       │                                              │
  │       └── main ───> skip (max hardening)             │
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
       │             ⚠ runs AFTER autoconfig
       ▼             (can override lockPref values)
  ✅ hardened

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
                   ✅ pass       ❌ fail ──> kill Firefox + notify

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
            ✅ pass       ❌ fail ──> kill Firefox + notify + exit

  pref checks: default only.  user.js diff: ALL profiles.
  fail -> kill Firefox -> notify -> exit (run: hifox deploy).
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
           │ user.js ──────────┼───vs───>│ managed profiles  │  ✅/⚠/❌
           │ policies.json ────┼───vs───>│ policies dir      │  ✅/⚠/❌
           │ autoconfig.cfg* ──┼───vs───>│ sysconfig dir     │  ✅/⚠/❌
           │                   │         │                   │
           └───────────────────┘         └───────────────────┘
           * regenerated on the fly (not a stored copy)
```
## drift detection

```
  ✅ protected                 ❌ drift detected
  ┌──────────────┐            ┌──────────────────┐
  │              │  Firefox   │                  │
  │  all prefs   │  update    │  prefs missing   │
  │  locked      │ ────────>  │  policies drift  │
  │  policies    │  tamper    │  files deleted   │
  │  enforced    │  delete    │  user.js tamper  │
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
                              kill Firefox + notify (critical)
                              user runs: hifox deploy -> restart
```

## update detection

```
  every pref is dumped on every start. Firefox updates silently add or change
  prefs - we diff the full dump, catch every meaningful change, and notify before damage.
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
                       (0 Firefox? -> clean)      (MOZ_APP_REMOTINGNAME)

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
  no control            no control              you control everything

  any webpage can become a webapp - add a folder, get an isolated profile,
  a menu entry, and its own dock icon. full hardening applies automatically.
  override specific permissions per webapp as needed (see selective unlock below).
  looks and works like a native app.

  isolation:

  ┌──────────────────────────────────────────────────────────────────────┐
  │                            Firefox                                   │
  │                                                                      │
  │  ┌────────────┐   ┌────────────┐   ┌────────────┐   ┌────────────┐   │
  │  │    main    │   │  discord   │   │  spotify   │   │  example   │   │
  │  │            │   │            │   │            │   │            │   │
  │  │  all       │   │ allow:     │   │  allow:    │   │  allow:    │   │
  │  │  locked    │   │ 🎤 mic     │   │  🔑 DRM    │   │  whatever  │   │
  │  │            │   │ 🎥 camera  │   │  Widevine  │   │  it needs  │   │
  │  │            │   │ 🔊 autoplay│   │            │   │            │   │
  │  └────────────┘   └────────────┘   └────────────┘   └────────────┘   │
  │        ╳                 ╳                ╳               ╳          │
  │                                                                      │
  │        no shared cookies, data, or permissions                       │
  └──────────────────────────────────────────────────────────────────────┘

  all global lockPrefs apply to every profile - webapps inherit full hardening.
  overrides only unlock what a specific webapp needs. everything else stays locked.

  selective unlock:

  ┌──────────┬──────────────────────────────────────────────┐
  │  main    │  all blocked (maximum hardening)             │
  ├──────────┼──────────────────────────────────────────────┤
  │ discord  │  autoplay, mic, camera                       │
  ├──────────┼──────────────────────────────────────────────┤
  │ spotify  │  DRM (Widevine)                              │
  ├──────────┼──────────────────────────────────────────────┤
  │ example  │  webapp/example/prefs.cfg -> unlock what you │
  │          │  need, everything else stays locked          │
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
  │  shared behavior (webapp.cfg)                        │
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
  │  UI (webapp.css -> userChrome.css)                   │
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
  two levels of cleanup. clean: remove remnants. purge: remove everything.

  ┌─────────────────────────────────────────────────────────────────┐
  │  clean                          │  purge                        │
  │  safe, runs after deploy        │  destructive, interactive     │
  ├─────────────────────────────────┼───────────────────────────────┤
  │  telemetry, crashes,            │  ALL data: cookies, history,  │
  │  experiments, caches,           │  logins, sessions, cache,     │
  │  plugins, forms, sync,          │  certificates, extensions,    │
  │  suggestions, permissions       │  everything                   │
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
       ├── kill Firefox
       ├── pause verify watcher
       │
       ├── per profile (main + webapps):
       │   delete everything EXCEPT user.js + chrome/
       │
       ├── external data (whitelist what to KEEP, not what to delete):
       │   flatpak: nuke ~/.var/app/org.mozilla.firefox/* except config/
       │   standard: nuke ~/.cache/mozilla/
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

  global_lockprefs.cfg            webapp.cfg
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
  internal prefs create a feedback loop between Firefox runtime and shell tools.
  none are real Firefox prefs - they exist only for hifox's self-diagnostics.

  Firefox startup
       │
       ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │  autoconfig.cfg executes inside Firefox                          │
  │                                                                  │
  │  global_lockprefs.cfg                                            │
  │    lockPref("_autoconfig.loaded", true)          <── chain proof │
  │                                                                  │
  │  webapp.cfg                                                      │
  │    lockPref("_autoconfig.profile", <dir>)        <── active dir  │
  │    lockPref("_autoconfig.error", <msg>)          <── JS catch    │
  │                                                                  │
  │  generate_pref_dump.cfg                                          │
  │    lockPref("_hifox.pref_dump", "<N> -> <path>") <── success     │
  │    pref("_hifox.pref_dump_error", <msg>)         <── failure     │
  │                                                                  │
  │  user.js (profile load)                                          │
  │    user_pref("_user_js.canary", "hifox")         <── file proof  │
  │                                                                  │
  └──────────────────────────────────────────────────────────────────┘
       │
       │ persists in prefs.js (user_pref values)
       ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │  hifox verify (shell side)                                       │
  │                                                                  │
  │  prefs.js ──> _user_js.canary == "hifox"?                        │
  │  prefs.js ──> _hifox.pref_dump_error present?  (dump fail)       │
  │                                                                  │
  │  _autoconfig.loaded   ── diagnostic only (not checked)           │
  │  _autoconfig.profile  ── diagnostic only (not checked)           │
  │  _autoconfig.error    ── diagnostic only (not checked)           │
  │  _hifox.pref_dump     ── diagnostic only (not checked)           │
  └──────────────────────────────────────────────────────────────────┘
```
