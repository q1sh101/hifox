# hifox architecture

hifox enforces Firefox hardening from a repo, on both standard and Flatpak
Firefox: prefs, policies, and profile files are deployed from source, runtime
state is verified against the repo, and verify stops the selected target on confirmed drift. This document maps
the deploy pipeline, verification, update detection, and webapp isolation. See
[README.md](../README.md) for usage.

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
  │   verify        confirmed drift ──> stop selected target          │
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
  hifox install <--flatpak|--standard>
       │
       ├── detect Firefox (refuses if the OTHER target is also installed)
       │   ┌─────────────┐     ┌────────────────────────┐
       │   │ Flatpak     │     │ Standard               │
       │   │ org.mozilla │     │ HIFOX_FIREFOX_DIR,     │
       │   │             │     │ /usr/lib*, /opt/firefox│
       │   └──────┬──────┘     └────────┬───────────────┘
       │          └──────────┬──────────┘
       │                     ▼
       ├── save target ── ~/.config/hifox/target
       ├── deploy (may refresh an already-active watcher)
       ├── symlink ── ~/.local/bin/hifox
       └── watch install (systemd units)
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
       │   │  autoconfig ─> generate ──> copy                    │
       │   │  webapp profiles                                    │
       │   │    ├── register in profiles.ini (next [ProfileN])   │
       │   │    ├── fix StartWithLastProfile -> 1                │
       │   │    └── create dir ──> copy shared CSS               │
       │   │  homepage ──> hifox.css + logo (default-named)      │
       │   │  user.js ──> copy to ALL profiles last ──> lock each│
       │   └─────────────────────────────────────────────────────┘
       │
       ├── desktop launchers (single active target)
       │   ┌─────────────────────────────────────────────────────┐
       │   │  shadow ─> firefox.desktop                  (std)   │
       │   │            org.mozilla.firefox.desktop      (fp)    │
       │   │            (matches system entry name to            │
       │   │             preserve the existing dock pin)         │
       │   │  webapps   org.mozilla.firefox.<name>-web.desktop   │
       │   │  Exec ───> launch.sh --target <t> [...]             │
       │   │  icon ───> cache-bust (cksum in filename)           │
       │   │  prune ──> remove unexpected entries                │
       │   └─────────────────────────────────────────────────────┘
       │
       ├── refresh watcher (if active ── picks up new dirs)
       │
       └── auto-clean ──> remove remnants only when Firefox is confirmed stopped
                          (skipped on failed deploy, running target, or unknown state)

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

  lock: every mutating command takes one flock at dispatch, so a manual run and
        a watcher-triggered one cannot overlap. verify and status do not take it.
```

## systemconfig (flatpak)

```
  flatpak Firefox runs sandboxed - configs on host /etc do not reach it.
  Mozilla declares an unmaintained extension point:
  org.mozilla.firefox.systemconfig, mounted as /app/etc/firefox inside the
  sandbox. hifox resolves Firefox's installed branch and populates that
  per-user extension directory directly during ordinary deploy. It does not
  require Flatpak Builder or extension registration.

  hifox install-systemconfig
       │
       ├── flatpak Firefox required
       │
       ├── detect branch ── flatpak info org.mozilla.firefox
       ├── populate $XDG_DATA_HOME/flatpak/extension/
       │       (defaults to ~/.local/share/flatpak/extension/)
       │       org.mozilla.firefox.systemconfig/<arch>/<branch>/
       │         ├── autoconfig.cfg
       │         ├── defaults/pref/autoconfig.js
       │         └── policies/policies.json
       │
       └── /app/etc/firefox now mounted inside sandbox
              ├── autoconfig.cfg
              ├── defaults/pref/autoconfig.js
              └── policies/policies.json

       the explicit command then reads all three back from inside the sandbox
       and fails if what Firefox sees differs from what was written.

  ordinary hifox deploy writes the same extension directory. the explicit
  command runs the same policies and autoconfig deploy steps and is not
  required after each content edit.
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
  │                    atomically publish in profile     │
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
  │  PathChanged ─── profiles.ini (FF first-launch creates   │
  │                  default profile -> auto-redeploy)       │
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
                   pass          nonzero
                                   ├── confirmed drift -> stop selected target
                                   └── unreadable evidence -> Firefox keeps running

  profile paths: only watched if profile exists at install time.
  30min timer covers the gap. deploy auto-refreshes watcher paths.

  Flatpak auto-deploy is user-writable. Standard Firefox touches /etc or the
  install dir, so auto-deploy needs sudo -n; otherwise run hifox deploy manually.
```

## verify

```
  hifox verify
       │
       ├── compare deployed files even when no default profile exists
       └── default profile absent? runtime checks are not applicable

  ┌──────────────────────────────────────────────┐
  │  pref integrity (runtime dump)               │
  │                                              │
  │  single source per check:                    │
  │  generated_pref_dump.txt - what Firefox      │
  │  actually loaded this session                │
  │  read as a frozen, validated snapshot        │
  │  (stale or absent dump ──> pending)          │
  │                                              │
  │  canary, cookieBehavior, HTTPS-only,         │
  │  DRM, shutdown sanitization                  │
  │                                              │
  │  webapps: same checks, with prefs.cfg        │
  │  overrides applied on top                    │
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
  │  after every applicable check passes:        │
  │  profile dump ≠ reviewed repo baseline?      │
  │       └── yes ──> refresh baseline + notify  │
  │  git diff is the review step                 │
  └───────────────────┬──────────────────────────┘
                      ▼
     ┌──────────────┬────────────┴─────┬──────────────────┐
  verified       pending           unreadable         confirmed drift
  exit 0         restart Firefox   malformed dump     stop target
                 exit 0            nonzero            notify + nonzero

  A dump that is absent or older than the deployed config is not drift: hifox
  names the profiles that still need a restart and exits 0. Only a malformed
  dump, or one reporting its own error, counts as unreadable; only a value that
  disagrees stops the browser.
```

## status

```
  repo is single source of truth. byte-exact compare proves sync.

  hifox status
       │
       └── per installation:

           repo                          live
           ┌───────────────────┐         ┌───────────────────┐
           │                   │  cmp -s │                   │
           │ user.js ──────────┼───vs───>│ managed profiles  │  ok/warn/fail
           │ policies.json ────┼───vs───>│ policies dir      │  ok/warn/fail
           │ autoconfig.cfg* ──┼───vs───>│ sysconfig dir     │  ok/warn/fail
           │ chrome assets ────┼───vs───>│ profile chrome/   │  ok/warn/fail
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
                              stop selected target + notify (critical)
                              user runs: hifox deploy -> restart
```

## update detection

```
  every pref is dumped after user.js canary is loaded. Firefox updates silently
  add or change prefs - hifox diffs the full dump, catches meaningful changes,
  and notifies before the new state is accepted.
  (volatile prefs - timestamps, counters, settings cache - skipped for clean signal.)
  Firefox publishes generated_pref_dump.txt atomically inside each profile. Once
  every applicable check passes, verify rewrites the per-target baseline and
  notifies; git diff is the review step and commit is the acceptance. Fresh-
  profile first launch is skipped (no canary yet); the next launch dumps cleanly.

  ┌─────────┐    ┌──────────────────┐     ┌──────────────────┐
  │ Firefox │    │  autoconfig.cfg  │     │     profile/     │
  │ update  │───>│  pref dump runs  │────>│ generated_pref_  │
  │         │    │  after canary    │     │ dump.txt         │
  └─────────┘    └──────────────────┘     └────────┬─────────┘
                                                   │
                 ┌────────────────────────────────┐│
                 │  hifox verify (auto)           ││
                 │                                ▼│
                 │  profile dump ≠ repo dump? <───┘│
                 │       │                         │
                 │       └── yes ──> refresh base  │
                 │                   + notify-send │
                 └────────────────┬────────────────┘
                                  │
                                  ▼
  ┌──────────────────────────────────────────────────────────┐
  │  git diff config/generated_pref_dump.<target>.txt        │
  │                                                          │
  │  + browser.new.feature = true              <── new pref  │
  │  - browser.old.setting = true [LOCKED]                   │
  │  + browser.old.setting = false [LOCKED]    <── changed   │
  │                                                          │
  │  review ──> lockPref new threats ──> deploy              │
  └──────────────────────────────────────────────────────────┘

  full cycle:

  update ──> restart ──> dump ──> verify ──> baseline ──> notify
                                                        │
                                              git diff <┘
                                                │
                                         lock + deploy
```

## webapp

```
  .desktop ──> launch.sh --target <t> ──> find Firefox ──> exec -P <name> <url>
                   │                                              │
                   ├── --target pins flatpak|standard              ▼
                   └── clean stale locks                  separate dock icon
                       (0 Firefox? -> clean)

  .desktop layout (single target only — install refuses if the other target exists):

    Firefox shadow   firefox.desktop                      (standard target)
                     org.mozilla.firefox.desktop          (flatpak target)
                     ── filename matches the system entry it shadows so the
                        existing dock pin keeps working
                     Name=Firefox
                     Exec=launch.sh --target <t> %u

    webapps          org.mozilla.firefox.<name>-web.desktop
                     Name=<DisplayName>
                     Exec=launch.sh --target <t> --webapp <name> <url>

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
  │ netflix  │  DRM (Widevine)                              │
  ├──────────┼──────────────────────────────────────────────┤
  │ prime    │  DRM (Widevine)                              │
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
  │                                                      │
  │  override: webapp/<name>/userChrome.css appended     │
  │            (cascade re-shows e.g. back/forward)      │
  └──────────────────────────────────────────────────────┘
```

## clean + purge

```
  two levels of cleanup. clean removes remnants. purge deletes profile data.

  ┌─────────────────────────────────────────────────────────────────┐
  │  clean                          │  purge                        │
  │  known remnants, stopped target │  destructive, interactive     │
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
  │  attempted after deploy         │  manual only                  │
  └─────────────────────────────────┴───────────────────────────────┘

  hifox clean
       ├── running or unknown target state ──> refuse without mutation
       └── stopped target ──> for each profile: delete known remnant files
                              (gmp-* kept in webapp profiles)

  hifox purge [--flatpak|--standard]
       │
       ├── confirm ──── [y/N] (no piped input)
       ├── record + pause active verify watcher units; confirm each stopped
       ├── stop only selected target(s); verify stopped before deletion
       │
       ├── per profile (main + webapps):
       │   delete profile data EXCEPT user.js + chrome/
       │
       ├── external data (whitelist what to KEEP, not what to delete):
       │   flatpak: delete external data except config/, .config/, .mozilla/
       │   standard: delete ~/.cache/mozilla/
       │
       ├── own leftover Firefox temp dirs under /tmp (owner-checked)
       │
       ├── restore exactly the prior watcher state on success, failure, INT, TERM
       ├── report partial deletion or watcher recovery failure as nonzero
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
  │    _hifox.error.ui_seed (pref)                   <── inner catch │
  │    _hifox.error.seed_block (pref)                <── outer catch │
  │                                                                  │
  │  webapp/shared/webapp.cfg                                        │
  │    lockPref("_autoconfig.profile", <dir>)        <── active dir  │
  │    lockPref("_autoconfig.error", <msg>)          <── JS catch    │
  │                                                                  │
  │  generate_pref_dump.cfg                                          │
  │    generated_pref_dump.txt                       <── success     │
  │    generated_pref_dump.err                       <── failure     │
  │    _hifox.pref_count (line 1 of the dump)        <── summary     │
  │    _hifox.error.dump_setup (pref)                <── observer    │
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
  │  _hifox.ui_seeded       ── diagnostic only (not checked)         │
  │  _hifox.alpenglow_seeded ── diagnostic only (not checked)        │
  │  _hifox.pref_count      ── diagnostic only (not checked)         │
  │  _hifox.error.*         ── diagnostic only (visible in dump)     │
  └──────────────────────────────────────────────────────────────────┘
```
