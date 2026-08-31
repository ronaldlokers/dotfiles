# Managing Zen Browser preferences from the dotfiles

Date: 2026-08-31
Status: approved, not yet implemented

## Problem

Zen Browser is installed on every machine this repo provisions
(`zen-browser-bin`, in the unconditional package tier), but nothing about its
configuration is managed. A rebuilt machine gets a stock browser, and the
deliberate preferences — DRM off, the built-in password manager off, Mozilla
experiment rollouts off, the responsive-design-mode setup used for mobile
testing, Zen's own layout switches — have to be found and re-set by hand from
memory.

They are also not discoverable. The live profile holds 281 `user_pref` lines,
of which roughly twenty are choices and the rest is machine-written state:
timestamps, migration counters, sync identifiers, telemetry IDs. There is no
record anywhere of which is which.

## Goal

A fresh machine ends up with the deliberate preferences already applied, from
the repo, with no manual `about:config` work. The repo is the source of truth
for the preferences it lists.

## Non-goals

- Managing extensions. Installing an extension declaratively requires
  `policies.json`, which is unavailable here (see "Why not policies.json").
  Firefox Sync already carries them.
- Managing Zen Mods. They are installable only through the browser UI. The
  profile currently has none (`zen-themes.json` is `{}`), so this costs
  nothing today.
- Managing workspaces, essentials or pinned tabs. These live in
  `zen-sessions.jsonlz4`, a compressed session blob with no supported external
  writer. Firefox Sync carries workspaces already.
- Managing bookmarks, passwords, history or containers.
- Migrating or relocating an existing profile.

## Decisions

### `user.js`, and it stays

The preferences are written to `user.js` in the profile directory. Zen reads it
at every startup and its values override `prefs.js`.

The consequence is deliberate and is the main thing to understand about this
design: a preference listed in `user.js` becomes **repo-owned**. Changing it in
the browser UI appears to work and then reverts at the next restart. To change
one, edit the repo and re-apply. This was chosen over a one-shot seed because
the listed preferences are set-once choices, and because a permanent file needs
no retraction phase, no `prefs.js` parsing and no guard against a running
browser.

`user.js` cannot lock a preference — `lockPref()` is rejected in user preference
files by design — so this is enforcement by reassertion at startup, not by
locking. That is sufficient here.

### Why not `policies.json`

`policies.json` is Mozilla's supported management mechanism and can genuinely
lock preferences and install extensions. It is unusable on this machine:

- It lives at `/opt/zen-browser-bin/distribution/policies.json`, inside the
  install directory, not `$HOME`. This repo manages `$HOME`.
- That file is **owned by the `zen-browser-bin` package** and already ships
  content (`DisableAppUpdate`, `DefaultSerialGuardSetting`). Writing to it means
  a root-privileged script overwriting a pacman-owned file, and losing the edit
  on every AUR rebuild.

An autoconfig `.cfg` file (`general.config.filename`) has the same problem for
the same reason: it also lives in the install directory.

### Why the overlap with Firefox Sync is deliberate

The account is signed in, and Sync carries a small allowlist of preferences —
visible locally as the nine `services.sync.prefs.sync-seen.*` entries. Seven of
them are also managed here: `browser.contentblocking.category`,
`browser.ctrlTab.sortByRecentlyUsed`, `browser.tabs.warnOnClose`,
`media.eme.enabled`, `nimbus.rollouts.enabled`,
`privacy.clearOnShutdown_v2.formdata` and `signon.rememberSignons`. The
remaining two — `extensions.activeThemeID` and `general.autoScroll` — are left
to Sync alone.

Managing them anyway is intentional. It makes a machine correct **before** the
account is signed in, and it keeps the machine correct if Sync is ever
abandoned. `user.js` is applied at startup, so where the two disagree the repo
wins; this is the intended precedence, not a conflict to resolve.

### Which preferences are managed

Twenty-two, all of them stable choices:

| Preference | Value |
| --- | --- |
| `accessibility.typeaheadfind.flashBar` | `0` |
| `browser.bookmarks.showMobileBookmarks` | `false` |
| `browser.contentblocking.category` | `"standard"` |
| `browser.ctrlTab.sortByRecentlyUsed` | `true` |
| `browser.link.open_newwindow.override.external` | `7` |
| `browser.ml.linkPreview.enabled` | `true` |
| `browser.newtabpage.activity-stream.system.showWeatherOptIn` | `false` |
| `browser.preferences.experimental.hidden` | `true` |
| `browser.tabs.warnOnClose` | `true` |
| `browser.translations.neverTranslateLanguages` | `"nl"` |
| `devtools.responsive.reloadNotification.enabled` | `false` |
| `devtools.responsive.touchSimulation.enabled` | `true` |
| `devtools.responsive.userAgent` | iPhone / iOS 18.6 Safari UA string |
| `full-screen-api.ignore-widgets` | `true` |
| `media.eme.enabled` | `false` |
| `nimbus.rollouts.enabled` | `false` |
| `privacy.clearOnShutdown_v2.formdata` | `true` |
| `sidebar.visibility` | `"hide-on-close"` |
| `signon.rememberSignons` | `false` |
| `zen.view.compact.enable-at-startup` | `false` |
| `zen.view.use-single-toolbar` | `false` |
| `zen.workspaces.continue-where-left-off` | `true` |

`browser.link.open_newwindow.override.external = 7` is carried across verbatim.
Upstream Firefox documents only `-1`, `1`, `2` and `3` for that preference, so
`7` is Zen-specific and its meaning is not established here. It is the value the
live profile holds and reproducing the machine means reproducing it.

### Which are deliberately excluded, and why

**Geometry that changes as the browser is used.** A permanent `user.js` freezes
whatever it lists, so pinning these would make a resize or a panel drag revert
at the next restart:
`devtools.responsive.viewport.{width,height,pixelRatio}`,
`devtools.toolbox.{footer.height,sidebar.width,splitconsole.open}`,
`devtools.toolsidebar-{height,width}.inspector*`.

**`browser.uiCustomization.state`.** Excluded for the same reason and one more:
the live blob still lists `search_kagi_com-browser-action` in
`unified-extensions-area` and `seen`, for an extension that has been removed.
Pinning the blob would reinstate a dead toolbar entry at every startup and stop
it ever clearing itself.

**Bookkeeping that is not a setting.**
`privacy.globalprivacycontrol.was_ever_enabled` records that Global Privacy
Control has been seen; the switch itself is
`privacy.globalprivacycontrol.enabled`, which the profile does not set. Turning
GPC on is a real decision and is out of scope here.
`browser.settings-redesign.promo.dismissed` is a dismissed-promo marker.

**Machine-local paths and identifiers.** `browser.download.lastDir`,
`browser.search.region`, `doh-rollout.home-region`, every `services.sync.*`
identifier, every `toolkit.telemetry.*` and `datareporting.*` ID,
`identity.fxaccounts.*`. Several of these are account-linked and none of them
belong in a git repository.

## Architecture

### Files

```
home/.chezmoitemplates/zen-user-js                       the preference list
home/.chezmoiscripts/run_after_24-seed-zen-prefs.sh.tmpl the writer
tests/zen-prefs.bats                                     the tests
```

`user.js` cannot be an ordinary managed file. Its path contains a
randomly-generated profile directory name (`a2s1x793.Default (release)` on this
machine), different on every machine, so chezmoi has no static target to map it
to. The template holds the content and the script renders it into the path it
discovers, the same shape as the existing
`run_after_23-seed-bar-widget.sh.tmpl`.

Keeping the list in `.chezmoitemplates` rather than inline in the script means
the preference list is one greppable block, and the script stays about profile
resolution.

### Profile resolution

Resolution order, authoritative first:

1. `~/.config/zen/installs.ini`, the `Default=` key under the install-hash
   section.
2. `~/.config/zen/profiles.ini`, the `Default=` key under its `[InstallXXXX]`
   section.
3. `~/.config/zen/profiles.ini`, the `[ProfileN]` section carrying `Default=1`.
4. Nothing found: create a profile.

**Order 3 must never come first, and this is the trap the script exists to
avoid.** On the current machine `profiles.ini` marks `0rk8j4vs.Default Profile`
with `Default=1` — an unused 4 KB profile — while `installs.ini` correctly names
`a2s1x793.Default (release)`, the 277 MB profile holding the real session. A
naive glob, or a reader that trusts `Default=1`, writes `user.js` into the wrong
profile and silently achieves nothing.

Paths in both files are relative to `~/.config/zen` when `IsRelative=1`.

### Creating a profile

Only reached at order 4, when the machine has no Zen profile at all — the state
a genuinely fresh install is in, since Zen creates its profile on first launch
and `chezmoi apply` runs before that.

The script runs `zen-browser -CreateProfile "<name> <path>"`, then re-runs
resolution to pick the result up.

**Verified 2026-08-31.** `zen-browser -CreateProfile "<name> <path>"` exits 0
without opening a window when a display is present, creating the directory and
registering it in `profiles.ini` with `IsRelative=1` and a relative `Path=`.
Without one it exits 1 with `Error: no DISPLAY environment variable specified`
and creates nothing.

So the creation branch is implemented, and its failure path carries the headless
case: a `chezmoi apply` run from a TTY, over SSH, or in CI cannot create a
profile, reports that it could not, and exits 0 so the rest of the apply chain
survives. On such a machine the fresh-machine path costs one extra apply after
Zen has been launched once, exactly as the print-and-exit alternative would
have.

### Safety rules

- **An existing profile is never re-pointed.** Where resolution succeeds, the
  script writes `user.js` and touches nothing else — never `installs.ini`,
  never `profiles.ini`, never the profile's other contents. Anything else risks
  orphaning a profile that holds the only local copy of a browsing session.
- **No running-browser guard is needed.** `user.js` is read only at startup, so
  writing it while Zen is running is safe; the change takes effect at the next
  start. This is a direct advantage over writing `prefs.js`, which Zen owns and
  rewrites continuously.
- **Write only on difference.** An unchanged `user.js` is left alone, so a
  settled apply costs a comparison.
- **Exit 0 and silent** inside a container (no Zen, gated on the shared
  `is-container` template) and where `zen-browser` is not installed. Neither is
  a failure.
- The script is `run_after`, not `run_onchange`. A `run_onchange` records its
  hash even on a skipped run, so a single apply on a machine that had no Zen
  yet would record the script as done and never seed it. This repeats the
  reasoning already recorded for the three enable scripts.

## Testing

`tests/zen-prefs.bats`, running the script through `sh` against a fake `$HOME`,
never the real profile.

1. **Resolution prefers `installs.ini`.** Given a fixture where `profiles.ini`
   marks profile A with `Default=1` and `installs.ini` names profile B, the file
   lands in B. This is the mutation-proof case: reverting the resolution order
   must fail this test on an assertion about which directory received the file,
   not on a missing symbol.
2. **An existing profile is never re-pointed.** `installs.ini` and
   `profiles.ini` are byte-identical before and after.
3. **Creation fires only when no profile exists**, and not when one does.
4. **All 22 preferences land**, with values intact through templating. The
   user-agent string carries spaces, slashes, parentheses and semicolons, and
   the string values must emerge quoted.
5. **A second run is a no-op** — content unchanged, file not rewritten.
6. **Container path** exits 0 and writes nothing.
7. **Zen absent** exits 0 and writes nothing.

Every test must be shown failing against the code it covers before the
implementation lands, with the observed assertion failure recorded. A compile
or not-found error is not proof.

## Documentation

`README.md` gains what is managed and the one-line consequence that a managed
preference reverts if changed in the UI.

`docs/design-notes.md` gains the reasoning that cannot be recovered from the
code: `user.js` over `policies.json` because the policy file is package-owned
at `/opt` and dies on every AUR rebuild; `installs.ini` over `profiles.ini`
because the latter's `Default=1` points at the wrong profile on this machine;
and that the overlap with Firefox Sync is deliberate so that a machine is
correct before sign-in.

This spec is a working document. Per the repo's rule it is pruned once the work
ships, with the reasoning above migrating into `docs/design-notes.md`.
