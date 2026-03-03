  <p align="center">
    <img src="hifox.png" alt="hifox" width="221" />
  </p>

<h1 align="center"><code>hifox</code></h1>

<p align="center">Deterministic Firefox hardening: from repo to runtime, enforced continuously.</p>

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
  hifox logs                                     follow deploy + verify output
  hifox watch install|remove|status              manage file watcher (systemd)
```

## table of contents

1. [install](#install)
2. [generation](#generation)
3. [deploy](#deploy)
4. [startup](#startup)
5. [automation](#automation)
6. [verify](#verify)
7. [status](#status)
8. [drift detection](#drift-detection)
9. [update detection](#update-detection)
10. [webapp](#webapp)
11. [webapp behavior](#webapp-behavior)
12. [clean](#clean)
13. [debug](#debug)
14. [signaling](#signaling)
15. [notes](#notes)

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
  lockPref > user_pref > pref: nothing can override autoconfig.cfg values.
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

## clean

```
  hardening blocks features via prefs. Firefox still creates files on disk.
  clean removes what prefs can't prevent.

  hifox clean (auto-runs at end of successful deploy)
       │
       └── for each profile:
           │
           ├── telemetry ──── pings, archives, timing, ad categories
           ├── experiments ── shield, experiment store
           ├── caches ─────── disk, startup, sync storage, alt-svc
           ├── crashes ────── reports, minidumps
           ├── plugins ────── Widevine, OpenH264
           └── misc ───────── forms, permissions, suggestions,
                              bookmarks, notifications, sync (weave)
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

## notes

```
  adding a webapp:
    mkdir webapp/myapp
    add myapp.desktop, myapp.png, prefs.cfg (optional)
    hifox deploy

  responding to a pref dump change:
    notification -> git diff config/generated_pref_dump.txt
    threat? -> lockPref in global_lockprefs.cfg -> hifox deploy

  when verify kills Firefox:
    hifox deploy -> restart Firefox
    if persists: hifox status (find what drifted)

  immutable locking:
    needs passwordless sudo (sudo -n chattr)
    without it: everything works, files stay writable

  dependencies:
    bash, systemd (user units), flatpak or standard Firefox
    optional: sudo -n (chattr), python3 (JSON validation)
```
