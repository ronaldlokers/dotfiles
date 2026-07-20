# Claude Code statusline redesign

Date: 2026-07-20
Source file: `dot_claude/executable_statusline.sh`

## Problem

The current statusline renders one line — `model | dirname | branch | ctx% | $cost`
plus a caveman badge. Three gaps:

1. **Missing information.** No git dirty/ahead-behind state, no session duration,
   no active output style, no indication of which container or worktree the
   session runs in, and no view of usage-limit burn.
2. **Flat presentation.** A single undifferentiated row; location and session
   meters compete for the same space.
3. **Robustness.** Every render spawns `git` synchronously with no timeout, and
   `jq` is invoked four separate times on the same input.

## Design

### Layout

Two lines, ANSI colors and Nerd Font icons, no powerline separators. Nerd Fonts
are present on the host (196 matches) and render client-side, so glyphs work
inside devpod containers too.

Line 1 — location:

```
 devpod:api   ~/src/api ⑂feature   main*↑2↓1
```

Line 2 — session meters:

```
 Opus 4.8  ctx 62%  $1.84  47m  ⌘ explanatory  5h 38%  CAVE
```

### Segments

Every segment hides silently when its data is missing, unavailable, or times
out. No placeholders — a segment that cannot produce a value produces nothing.

**Line 1**

| Segment | Source | Shown when |
| --- | --- | --- |
| env | `$DEVPOD_WORKSPACE_ID`, else `$HOSTNAME` when `/.dockerenv` exists | Not on the bare host |
| dir | `.workspace.current_dir`, `$HOME` collapsed to `~`, last two path components | Always |
| worktree | `git rev-parse --git-common-dir` differs from `--git-dir` → `⑂<name>` | In a linked worktree |
| branch | `git` branch name, `*` when dirty, `↑n↓m` against upstream, short SHA when detached | In a git repo |

**Line 2**

| Segment | Source | Shown when |
| --- | --- | --- |
| model | `.model.display_name` | Always |
| ctx | `.context_window.remaining_percentage`, green >40, yellow >20, red ≤20 | Value present and parses as an integer |
| cost | `.cost.total_cost_usd` | ≥ $0.01 |
| duration | `.cost.total_duration_ms` as `47m` / `1h12m` | > 60s |
| output style | `.output_style.name` | Name is neither empty nor `default` |
| quota | `ccusage` 5-hour block remaining, colored like ctx | `ccusage` installed and returns data |
| caveman badge | existing plugin hook | Plugin present and mode active |

### Implementation

Single file, `dot_claude/executable_statusline.sh`, one shell function per
segment (`seg_env`, `seg_dir`, `seg_git`, `seg_ctx`, `seg_quota`, …). The core
reads stdin once and extracts every field in a **single** `jq` call, then
composes the two lines. Keeping one file keeps `chezmoi apply` trivial; the
functions provide the separation a `statusline.d/` loader would, without the
loader.

### Caching

Cache directory: `${XDG_RUNTIME_DIR:-/tmp}/claude-statusline/`

| Key | Contents | TTL |
| --- | --- | --- |
| sha1 of repo path | rendered git segment | 10s |
| `quota` | rendered quota segment | 30s |

Read pattern per cached segment:

1. Cache file exists → print its contents immediately.
2. Also older than TTL → fork a detached refresh (`setsid … &`) that writes a
   temp file and `mv`s it into place atomically. The stale value is still what
   this render prints.
3. No cache file at all → one synchronous `timeout 1` attempt; empty on failure.

Steady-state render cost is therefore one `jq` plus two file reads, with no
blocking subprocess. A `mkdir`-based lockfile prevents concurrent renders from
stampeding the same refresh.

### Robustness

- `timeout 1` wraps every external call (`git`, `ccusage`).
- All git invocations use `-C "$dir"` with stderr discarded; outside a repo the
  git segments vanish rather than erroring.
- `ccusage` absence is detected with `command -v`; the quota segment vanishes.
- Numeric fields are validated before integer comparison, extending the existing
  guard that handles bare-fraction values like `.5`.

### Dependency

`ccusage` is pinned through mise (`npm:ccusage` in
`~/.config/mise/config.toml`) so the dotfiles bootstrap installs it. The
statusline degrades cleanly when it is absent, so this is not a hard dependency.

### Testing

`tests/statusline/` drives the script with fixture JSON on stdin and asserts on
ANSI-stripped output. Cases:

- no git repo
- clean repo, dirty repo, ahead/behind upstream, detached HEAD
- linked worktree
- `ccusage` missing
- garbage `remaining_percentage` (`.5`, empty, non-numeric)
- missing `cost` and `output_style` fields

The suite runs in CI alongside the existing checks. `tests` is added to
`.chezmoiignore` so it is never applied into `$HOME`.
