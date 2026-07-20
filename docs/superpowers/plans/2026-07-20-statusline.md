# Statusline Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-line Claude Code statusline with a two-line, cached, fail-silent statusline that shows location on line 1 and session meters on line 2.

**Architecture:** One bash file, `dot_claude/executable_statusline.sh`, with one function per segment. The core reads stdin once, extracts every JSON field in a single `jq` call, and composes two lines. Slow segments (git, ccusage) go through a cache helper that prints the stale value immediately and refreshes in a detached background process.

**Tech Stack:** bash 5, `jq` (pinned in mise), `git`, `ccusage` (npm, via mise), plain-bash test harness, GitHub Actions.

Spec: `docs/superpowers/specs/2026-07-20-statusline-design.md`

## Global Constraints

- Source of truth is `dot_claude/executable_statusline.sh` in the chezmoi source tree. Never edit `~/.claude/statusline.sh` directly; run `chezmoi apply` to install.
- Every segment hides silently when data is missing, unavailable, or times out. No placeholder text, no error output on stdout or stderr.
- Every external command is wrapped in `timeout 1`.
- The script must pass `shellcheck --severity=warning` — CI already lints this exact path.
- The script must never exit non-zero and never write to stderr; Claude Code renders whatever lands on stdout.
- Repo-only paths (`tests`, `docs`) must be listed in `.chezmoiignore`.
- Branch: `feat/statusline`. Conventional-commit subjects, lowercase imperative. Never commit to `main`.
- Cache directory: `${XDG_RUNTIME_DIR:-/tmp}/claude-statusline`.
- Cache file format: line 1 is the epoch seconds of the write, the remainder is the rendered segment.
- Read multi-field `jq` output one field per line via `mapfile`, indexed as
  `${fields[N]-}`. Never `IFS=$'\t' read` from `@tsv`: tab is IFS-whitespace in
  bash, so consecutive tabs collapse and every field after an empty one shifts
  left. Task 1's review caught this producing a fabricated `ctx 1200%`.
- `export LC_ALL=C` is set near the top of the script so `printf '%.2f'` always
  emits a dot separator; the cost segment does integer math on that string.

---

### Task 1: Test harness, core rewrite, CI wiring

Establishes the two-line skeleton with the segments that need no subprocess (model, dir, ctx, cost) and the harness every later task extends.

**Files:**
- Create: `tests/statusline/run.sh`
- Create: `tests/statusline/fixtures/basic.json`
- Create: `tests/statusline/fixtures/basic.expected`
- Create: `tests/statusline/fixtures/fraction-ctx.json`
- Create: `tests/statusline/fixtures/fraction-ctx.expected`
- Create: `tests/statusline/fixtures/empty-fields.json`
- Create: `tests/statusline/fixtures/empty-fields.expected`
- Modify: `dot_claude/executable_statusline.sh` (full rewrite)
- Modify: `.chezmoiignore`
- Modify: `.github/workflows/ci.yaml` (add a `statusline` job)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `shorten_path <abs-path>` → prints the display path.
  - `seg_model <name>`, `seg_dir <abs-path>`, `seg_ctx <pct>`, `seg_cost <usd>` → each prints a colored segment or nothing.
  - `join_segments <sep> <segment>...` → prints non-empty arguments joined by `<sep>`.
  - Globals `C_RESET C_DIM C_CYAN C_MAGENTA C_GREEN C_YELLOW C_RED C_BLUE`.
  - Test harness contract: `tests/statusline/run.sh` pipes each `fixtures/<name>.json` into the script with a stubbed `PATH`, strips ANSI, and diffs against `fixtures/<name>.expected`.

- [ ] **Step 1: Write the failing test harness**

Create `tests/statusline/run.sh`:

```bash
#!/usr/bin/env bash
# Drives the statusline with fixture JSON on stdin and diffs the
# ANSI-stripped output against the recorded expectation.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
script="$repo/dot_claude/executable_statusline.sh"

# Stubs let a fixture decide whether git/ccusage exist and what they say.
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

fail=0
for fixture in "$here"/fixtures/*.json; do
  name=$(basename "$fixture" .json)
  expected="$here/fixtures/$name.expected"

  # Per-fixture stub setup: fixtures/<name>.stub is sourced if present and
  # may create fake git/ccusage executables in $stub_dir.
  rm -rf "${stub_dir:?}"/*
  if [ -f "$here/fixtures/$name.stub" ]; then
    # shellcheck disable=SC1090
    STUB_DIR="$stub_dir" source "$here/fixtures/$name.stub"
  fi

  actual=$(
    PATH="$stub_dir:$PATH" \
    HOME=/home/tester \
    XDG_RUNTIME_DIR="$stub_dir/cache" \
    DEVPOD_WORKSPACE_ID="" \
      bash "$script" <"$fixture" 2>/dev/null |
      sed $'s/\033\\[[0-9;]*m//g'
  )

  if [ "$actual" = "$(cat "$expected")" ]; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
    printf '  expected: %s\n' "$(cat "$expected" | tr '\n' '|')"
    printf '  actual:   %s\n' "$(printf '%s' "$actual" | tr '\n' '|')"
    fail=1
  fi
done

exit "$fail"
```

Make it executable: `chmod +x tests/statusline/run.sh`

- [ ] **Step 2: Write the three core fixtures**

`tests/statusline/fixtures/basic.json`:

```json
{
  "model": { "display_name": "Opus 4.8" },
  "workspace": { "current_dir": "/home/tester/src/api" },
  "output_style": { "name": "default" },
  "context_window": { "remaining_percentage": 62.4 },
  "cost": { "total_cost_usd": 1.8412, "total_duration_ms": 0 }
}
```

`tests/statusline/fixtures/basic.expected`:

```
~/src/api
Opus 4.8  ctx 62%  $1.84
```

`tests/statusline/fixtures/fraction-ctx.json` — a bare fraction must floor to `0`, not error and not vanish:

```json
{
  "model": { "display_name": "Haiku 4.5" },
  "workspace": { "current_dir": "/home/tester" },
  "context_window": { "remaining_percentage": 0.5 },
  "cost": { "total_cost_usd": 0.004, "total_duration_ms": 0 }
}
```

`tests/statusline/fixtures/fraction-ctx.expected` — cost below $0.01 hides:

```
~
Haiku 4.5  ctx 0%
```

`tests/statusline/fixtures/empty-fields.json` — every optional field absent:

```json
{ "model": { "display_name": "Sonnet 5" }, "workspace": { "current_dir": "/home/tester/deep/nested/tree/leaf" } }
```

`tests/statusline/fixtures/empty-fields.expected` — deep paths elide the middle:

```
~/…/tree/leaf
Sonnet 5
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `tests/statusline/run.sh`
Expected: three `FAIL` lines, exit status 1 — the current script prints one line in the old format.

- [ ] **Step 4: Rewrite the statusline core**

Replace `dot_claude/executable_statusline.sh` entirely:

```bash
#!/bin/bash
# Claude Code statusline.
#   line 1: where you are   — env, dir, worktree, branch
#   line 2: session meters  — model, context, cost, duration, style, quota
# Every segment renders nothing when its data is missing, unavailable, or
# times out; a statusline that lies is worse than one that is short.
set -u

# Keep printf's decimal separator a dot regardless of the user's locale; the
# cost segment does integer math on the formatted string.
export LC_ALL=C

CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/claude-statusline"

C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_RED=$'\033[31m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_BLUE=$'\033[34m'
C_MAGENTA=$'\033[35m'
C_CYAN=$'\033[36m'

# Collapse $HOME to ~ and keep at most the root plus the final two
# components, so a deep checkout does not push the meters off screen.
shorten_path() {
  local d=$1 n
  [ -n "$d" ] || return 0
  case "$d" in
    "$HOME") printf '~'; return 0 ;;
    "$HOME"/*) d="~/${d#"$HOME"/}" ;;
  esac
  local IFS=/
  local -a parts=()
  read -ra parts <<<"$d"
  n=${#parts[@]}
  if [ "$n" -le 3 ]; then
    printf '%s' "$d"
  else
    printf '%s/…/%s/%s' "${parts[0]}" "${parts[n - 2]}" "${parts[n - 1]}"
  fi
}

seg_model() {
  [ -n "$1" ] || return 0
  printf '%s%s%s' "$C_CYAN" "$1" "$C_RESET"
}

seg_dir() {
  local p
  p=$(shorten_path "$1")
  [ -n "$p" ] || return 0
  printf '%s%s%s' "$C_DIM" "$p" "$C_RESET"
}

# remaining_percentage arrives as a float. A bare fraction like .5 floors to
# 0, which is the honest reading: almost no context left, paint it red.
seg_ctx() {
  local pct=$1 p c
  case "$pct" in '' | *[!0-9.]* | *.*.*) return 0 ;; esac
  p=${pct%%.*}
  case "$p" in '' | *[!0-9]*) p=0 ;; esac
  if [ "$p" -le 20 ]; then
    c=$C_RED
  elif [ "$p" -le 40 ]; then
    c=$C_YELLOW
  else
    c=$C_GREEN
  fi
  printf '%sctx %s%%%s' "$c" "$p" "$C_RESET"
}

# Sub-cent costs are noise; hide them. Cents are compared as integers so no
# external tool is needed for the float comparison.
seg_cost() {
  local cost=$1 rounded cents
  case "$cost" in '' | *[!0-9.]* | *.*.*) return 0 ;; esac
  printf -v rounded '%.2f' "$cost"
  cents=${rounded/./}
  [ $((10#$cents)) -ge 1 ] || return 0
  printf '%s$%s%s' "$C_DIM" "$rounded" "$C_RESET"
}

# Join the non-empty arguments; empty segments leave no double separator.
join_segments() {
  local sep=$1 out= s
  shift
  for s in "$@"; do
    [ -n "$s" ] || continue
    if [ -z "$out" ]; then out=$s; else out="$out$sep$s"; fi
  done
  printf '%s' "$out"
}

input=$(cat)

# One jq call, not one per field: this runs on every render. One field per
# line rather than @tsv — tab is IFS-whitespace, so a tab-separated read
# collapses empty fields and shifts everything after them.
fields=()
mapfile -t fields < <(
  timeout 1 jq -r '
    (.model.display_name // ""),
    (.workspace.current_dir // ""),
    (.output_style.name // ""),
    (.context_window.remaining_percentage // "" | tostring),
    (.cost.total_cost_usd // "" | tostring),
    (.cost.total_duration_ms // "" | tostring)
  ' <<<"$input" 2>/dev/null
)
model=${fields[0]-}
dir=${fields[1]-}
style=${fields[2]-}
pct=${fields[3]-}
cost=${fields[4]-}
dur=${fields[5]-}

line1=$(join_segments '  ' "$(seg_dir "$dir")")
line2=$(join_segments '  ' \
  "$(seg_model "$model")" \
  "$(seg_ctx "$pct")" \
  "$(seg_cost "$cost")")

[ -n "$line1" ] && printf '%s\n' "$line1"
printf '%s' "$line2"
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `tests/statusline/run.sh`
Expected: `ok basic`, `ok fraction-ctx`, `ok empty-fields`, exit status 0.

- [ ] **Step 6: Lint**

Run: `shellcheck --severity=warning dot_claude/executable_statusline.sh tests/statusline/run.sh`
Expected: no output, exit status 0.

- [ ] **Step 7: Keep repo-only files out of $HOME**

Append to `.chezmoiignore`:

```
/tests
```

Verify: `HOME="$(mktemp -d)" chezmoi apply --source "$PWD" </dev/null && echo applied`
Expected: `applied`, and no `tests` directory in that temporary HOME.

- [ ] **Step 8: Wire the suite into CI**

In `.github/workflows/ci.yaml`, add a job alongside `lint`:

```yaml
  statusline:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6
      - name: statusline tests
        run: tests/statusline/run.sh
```

Also extend the existing `shellcheck` line in the `lint` job to cover the harness:

```yaml
        run: shellcheck --severity=warning setup .chezmoiscripts/*.sh.tmpl dot_claude/executable_statusline.sh dot_config/shell/ssh-agent.sh tests/statusline/run.sh
```

- [ ] **Step 9: Commit**

```bash
git add dot_claude/executable_statusline.sh tests/statusline .chezmoiignore .github/workflows/ci.yaml
git commit -m "feat(statusline): two-line layout with tested core segments"
```

---

### Task 2: Cache helper and git segment

**Files:**
- Modify: `dot_claude/executable_statusline.sh`
- Create: `tests/statusline/fixtures/git-dirty.json`
- Create: `tests/statusline/fixtures/git-dirty.expected`
- Create: `tests/statusline/fixtures/git-dirty.stub`
- Create: `tests/statusline/fixtures/git-absent.json`
- Create: `tests/statusline/fixtures/git-absent.expected`
- Create: `tests/statusline/fixtures/git-absent.stub`

**Interfaces:**
- Consumes: `join_segments`, the `C_*` globals, `CACHE_DIR` from Task 1.
- Produces:
  - `cache_get <key> <ttl-seconds> <command> [args...]` → prints the cached payload, refreshing in the background when stale.
  - `git_segment <dir>` → prints `branch*↑2↓1`, or the short SHA when detached, or nothing outside a repo.

- [ ] **Step 1: Write the failing tests**

`tests/statusline/fixtures/git-dirty.json`:

```json
{
  "model": { "display_name": "Opus 4.8" },
  "workspace": { "current_dir": "/home/tester/src/api" },
  "context_window": { "remaining_percentage": 62.4 }
}
```

`tests/statusline/fixtures/git-dirty.stub` — a fake `git` that answers the exact calls the segment makes:

```bash
cat >"$STUB_DIR/git" <<'STUB'
#!/bin/bash
# Fake git: -C <dir> is skipped, then the subcommand decides the reply.
while [ "${1:-}" = "-C" ]; do shift 2; done
case "$1 ${2:-}" in
  "status --porcelain=v2")
    printf '# branch.head main\n# branch.ab +2 -1\n1 .M N... 100644 100644 100644 abc def file.txt\n'
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB_DIR/git"
```

`tests/statusline/fixtures/git-dirty.expected`:

```
~/src/api  main*↑2↓1
Opus 4.8  ctx 62%
```

`tests/statusline/fixtures/git-absent.json`:

```json
{
  "model": { "display_name": "Opus 4.8" },
  "workspace": { "current_dir": "/home/tester/notarepo" },
  "context_window": { "remaining_percentage": 62.4 }
}
```

`tests/statusline/fixtures/git-absent.stub` — git exists but the directory is not a repo:

```bash
cat >"$STUB_DIR/git" <<'STUB'
#!/bin/bash
exit 128
STUB
chmod +x "$STUB_DIR/git"
```

`tests/statusline/fixtures/git-absent.expected`:

```
~/notarepo
Opus 4.8  ctx 62%
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/statusline/run.sh`
Expected: `FAIL git-dirty` (no branch rendered), `ok git-absent` already passes because nothing renders a branch yet.

- [ ] **Step 3: Add the cache helper**

Insert after `join_segments` in `dot_claude/executable_statusline.sh`:

```bash
# Print a cached segment immediately, then refresh it out of band when it is
# older than the TTL. The freshest value the *next* render sees is worth more
# than blocking this one on a subprocess.
# Cache file layout: line 1 is the write timestamp, the rest is the payload.
cache_get() {
  local key=$1 ttl=$2
  shift 2
  local f="$CACHE_DIR/$key" lock="$CACHE_DIR/$key.lock" now raw ts payload
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  printf -v now '%(%s)T' -1

  if [ -f "$f" ]; then
    raw=$(<"$f")
    ts=${raw%%$'\n'*}
    payload=${raw#*$'\n'}
    [ "$payload" = "$raw" ] && payload=
    printf '%s' "$payload"
    case "$ts" in '' | *[!0-9]*) ts=0 ;; esac
    if [ $((now - ts)) -ge "$ttl" ] && mkdir "$lock" 2>/dev/null; then
      cache_refresh "$f" "$lock" "$@"
    fi
    return 0
  fi

  # Cold cache: pay for one synchronous attempt so the first render is not
  # blank, but never wait longer than the command's own timeout.
  mkdir "$lock" 2>/dev/null || return 0
  payload=$("$@" 2>/dev/null)
  printf '%s\n%s' "$now" "$payload" >"$f.tmp" 2>/dev/null &&
    mv "$f.tmp" "$f" 2>/dev/null
  rmdir "$lock" 2>/dev/null
  printf '%s' "$payload"
}

# Detached so the refresh survives this render exiting.
cache_refresh() {
  local f=$1 lock=$2
  shift 2
  local runner=()
  command -v setsid >/dev/null 2>&1 && runner=(setsid)
  (
    "${runner[@]}" bash -c '
      f=$1; lock=$2; shift 2
      printf -v now "%(%s)T" -1
      payload=$("$@" 2>/dev/null)
      printf "%s\n%s" "$now" "$payload" >"$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
      rmdir "$lock" 2>/dev/null
    ' _ "$f" "$lock" "$@"
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
```

- [ ] **Step 4: Add the git segment**

Insert after `cache_refresh`:

```bash
# One `git status --porcelain=v2 --branch` yields branch name, ahead/behind,
# and dirtiness together — three questions, one process.
git_segment() {
  local dir=$1 status line head= ab= dirty=0 ahead=0 behind=0 out
  command -v git >/dev/null 2>&1 || return 0
  status=$(timeout 1 git -C "$dir" status --porcelain=v2 --branch 2>/dev/null) || return 0
  while IFS= read -r line; do
    case "$line" in
      '# branch.head '*) head=${line#'# branch.head '} ;;
      '# branch.ab '*) ab=${line#'# branch.ab '} ;;
      '#'* | '') ;;
      *) dirty=1 ;;
    esac
  done <<<"$status"
  [ -n "$head" ] || return 0

  if [ "$head" = "(detached)" ]; then
    head=$(timeout 1 git -C "$dir" rev-parse --short HEAD 2>/dev/null) || return 0
    [ -n "$head" ] || return 0
  fi

  out="$head"
  [ "$dirty" = 1 ] && out="$out*"
  if [ -n "$ab" ]; then
    ahead=${ab%% *}
    behind=${ab##* }
    ahead=${ahead#+}
    behind=${behind#-}
    [ "$ahead" != 0 ] && out="$out↑$ahead"
    [ "$behind" != 0 ] && out="$out↓$behind"
  fi
  printf '%s%s%s' "$C_MAGENTA" "$out" "$C_RESET"
}
```

- [ ] **Step 5: Render it on line 1**

Replace the `line1=` assignment with:

```bash
git_key=${dir//\//_}
line1=$(join_segments '  ' \
  "$(seg_dir "$dir")" \
  "$(cache_get "git$git_key" 10 git_segment "$dir")")
```

`cache_get` calls `git_segment` as a plain function, so it must be defined before this line — it is.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `tests/statusline/run.sh`
Expected: `ok git-dirty`, `ok git-absent`, and the three Task 1 fixtures still `ok`. Exit status 0.

- [ ] **Step 7: Verify the cache actually caches**

Run:

```bash
XDG_RUNTIME_DIR=$(mktemp -d) bash -c '
  printf "%s" "$(cat tests/statusline/fixtures/basic.json)" | bash dot_claude/executable_statusline.sh >/dev/null
  ls "$XDG_RUNTIME_DIR/claude-statusline"'
```

Expected: one `git_home_tester_src_api` file listed.

- [ ] **Step 8: Lint and commit**

```bash
shellcheck --severity=warning dot_claude/executable_statusline.sh
git add dot_claude/executable_statusline.sh tests/statusline
git commit -m "feat(statusline): cached git branch, dirty, and ahead/behind"
```

---

### Task 3: Environment and worktree segments

**Files:**
- Modify: `dot_claude/executable_statusline.sh`
- Create: `tests/statusline/fixtures/devpod.json`
- Create: `tests/statusline/fixtures/devpod.expected`
- Create: `tests/statusline/fixtures/worktree.json`
- Create: `tests/statusline/fixtures/worktree.expected`
- Create: `tests/statusline/fixtures/worktree.stub`
- Modify: `tests/statusline/run.sh` (allow a fixture to set `DEVPOD_WORKSPACE_ID`)

**Interfaces:**
- Consumes: `join_segments`, `cache_get`, `git_segment` from Tasks 1–2.
- Produces:
  - `seg_env` → prints the devpod workspace or container hostname, or nothing on the bare host.
  - `worktree_name <dir>` → prints the linked-worktree name, or nothing in a normal checkout. Called from inside `git_segment`'s cached payload.

- [ ] **Step 1: Let fixtures set environment variables**

In `tests/statusline/run.sh`, replace the hardcoded `DEVPOD_WORKSPACE_ID=""` line so a stub file can export it:

```bash
  actual=$(
    PATH="$stub_dir:$PATH" \
    HOME=/home/tester \
    XDG_RUNTIME_DIR="$stub_dir/cache" \
    DEVPOD_WORKSPACE_ID="${FIXTURE_DEVPOD:-}" \
      bash "$script" <"$fixture" 2>/dev/null |
      sed $'s/\033\\[[0-9;]*m//g'
  )
```

And reset it per fixture, immediately before the stub is sourced:

```bash
  FIXTURE_DEVPOD=""
```

- [ ] **Step 2: Write the failing tests**

`tests/statusline/fixtures/devpod.json`:

```json
{
  "model": { "display_name": "Opus 4.8" },
  "workspace": { "current_dir": "/home/tester/src/api" },
  "context_window": { "remaining_percentage": 62.4 }
}
```

`tests/statusline/fixtures/devpod.stub`:

```bash
FIXTURE_DEVPOD="api"
cat >"$STUB_DIR/git" <<'STUB'
#!/bin/bash
exit 128
STUB
chmod +x "$STUB_DIR/git"
```

`tests/statusline/fixtures/devpod.expected`:

```
devpod:api  ~/src/api
Opus 4.8  ctx 62%
```

`tests/statusline/fixtures/worktree.json`:

```json
{
  "model": { "display_name": "Opus 4.8" },
  "workspace": { "current_dir": "/home/tester/src/api-wt" },
  "context_window": { "remaining_percentage": 62.4 }
}
```

`tests/statusline/fixtures/worktree.stub` — git reports a linked worktree:

```bash
cat >"$STUB_DIR/git" <<'STUB'
#!/bin/bash
while [ "${1:-}" = "-C" ]; do shift 2; done
case "$1 ${2:-}" in
  "status --porcelain=v2")
    printf '# branch.head feature\n'
    ;;
  "rev-parse --git-dir")
    printf '/home/tester/src/api/.git/worktrees/api-wt\n/home/tester/src/api/.git\n'
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB_DIR/git"
```

`tests/statusline/fixtures/worktree.expected`:

```
~/src/api-wt ⑂api-wt  feature
Opus 4.8  ctx 62%
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `tests/statusline/run.sh`
Expected: `FAIL devpod` and `FAIL worktree`; all earlier fixtures still `ok`.

- [ ] **Step 4: Add the environment segment**

Insert after `seg_dir`:

```bash
# Only meaningful away from the host: on Omarchy this renders nothing.
seg_env() {
  local name=${DEVPOD_WORKSPACE_ID:-} label
  if [ -n "$name" ]; then
    label="devpod:$name"
  elif [ -f /.dockerenv ]; then
    label=${HOSTNAME:-}
    [ -n "$label" ] || return 0
  else
    return 0
  fi
  printf '%s%s%s' "$C_YELLOW" "$label" "$C_RESET"
}
```

- [ ] **Step 5: Add worktree detection to the git segment**

Insert before `git_segment`:

```bash
# A linked worktree has a --git-dir under the main repo's
# .git/worktrees/<name>; a normal checkout has --git-dir == --git-common-dir.
worktree_name() {
  local dir=$1 out gitdir common
  out=$(timeout 1 git -C "$dir" rev-parse --git-dir --git-common-dir 2>/dev/null) || return 0
  gitdir=${out%%$'\n'*}
  common=${out##*$'\n'}
  [ "$gitdir" != "$common" ] || return 0
  printf '%s' "${gitdir##*/}"
}
```

Then, inside `git_segment`, immediately after the `[ -n "$head" ] || return 0` line:

```bash
  local wt
  wt=$(worktree_name "$dir")
```

and change the final `printf` to prepend the worktree marker:

```bash
  if [ -n "$wt" ]; then
    printf '%s⑂%s%s  %s%s%s' "$C_DIM" "$wt" "$C_RESET" "$C_MAGENTA" "$out" "$C_RESET"
  else
    printf '%s%s%s' "$C_MAGENTA" "$out" "$C_RESET"
  fi
```

- [ ] **Step 6: Render the environment segment**

Update the `line1=` assignment:

```bash
line1=$(join_segments '  ' \
  "$(seg_env)" \
  "$(seg_dir "$dir")" \
  "$(cache_get "git$git_key" 10 git_segment "$dir")")
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `tests/statusline/run.sh`
Expected: every fixture `ok`, exit status 0.

- [ ] **Step 8: Lint and commit**

```bash
shellcheck --severity=warning dot_claude/executable_statusline.sh tests/statusline/run.sh
git add dot_claude/executable_statusline.sh tests/statusline
git commit -m "feat(statusline): container and worktree indicators"
```

---

### Task 4: Duration and output-style segments

**Files:**
- Modify: `dot_claude/executable_statusline.sh`
- Create: `tests/statusline/fixtures/long-session.json`
- Create: `tests/statusline/fixtures/long-session.expected`
- Modify: `tests/statusline/fixtures/basic.json` and `basic.expected` (add a short duration that must stay hidden)

**Interfaces:**
- Consumes: the `dur` and `style` variables already extracted by the Task 1 `jq` call.
- Produces:
  - `seg_dur <milliseconds>` → prints `47m` or `1h12m`, nothing at or under 60s.
  - `seg_style <name>` → prints `⌘ <name>`, nothing for empty, `null`, or `default`.

- [ ] **Step 1: Write the failing test**

`tests/statusline/fixtures/long-session.json`:

```json
{
  "model": { "display_name": "Opus 4.8" },
  "workspace": { "current_dir": "/home/tester" },
  "output_style": { "name": "explanatory" },
  "context_window": { "remaining_percentage": 62.4 },
  "cost": { "total_cost_usd": 1.84, "total_duration_ms": 4340000 }
}
```

`tests/statusline/fixtures/long-session.expected` — 4,340,000 ms is 1h12m:

```
~
Opus 4.8  ctx 62%  $1.84  1h12m  ⌘ explanatory
```

Add a sub-minute duration to `tests/statusline/fixtures/basic.json` so the hide rule is covered:

```json
  "cost": { "total_cost_usd": 1.8412, "total_duration_ms": 45000 }
```

`basic.expected` is unchanged — 45s must not render.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/statusline/run.sh`
Expected: `FAIL long-session`; `basic` still `ok`.

- [ ] **Step 3: Add both segments**

Insert after `seg_cost`:

```bash
# Anything under a minute is noise on a line that is already busy.
seg_dur() {
  local ms=${1%%.*} s h m
  case "$ms" in '' | *[!0-9]*) return 0 ;; esac
  s=$((ms / 1000))
  [ "$s" -gt 60 ] || return 0
  h=$((s / 3600))
  m=$(((s % 3600) / 60))
  if [ "$h" -gt 0 ]; then
    printf '%s%dh%dm%s' "$C_DIM" "$h" "$m" "$C_RESET"
  else
    printf '%s%dm%s' "$C_DIM" "$m" "$C_RESET"
  fi
}

# The default style is the assumption; only a deviation is worth screen space.
seg_style() {
  local s=$1
  case "$s" in '' | null | default) return 0 ;; esac
  printf '%s⌘ %s%s' "$C_BLUE" "$s" "$C_RESET"
}
```

- [ ] **Step 4: Render them on line 2**

Update the `line2=` assignment:

```bash
line2=$(join_segments '  ' \
  "$(seg_model "$model")" \
  "$(seg_ctx "$pct")" \
  "$(seg_cost "$cost")" \
  "$(seg_dur "$dur")" \
  "$(seg_style "$style")")
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `tests/statusline/run.sh`
Expected: every fixture `ok`, exit status 0.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck --severity=warning dot_claude/executable_statusline.sh
git add dot_claude/executable_statusline.sh tests/statusline
git commit -m "feat(statusline): session duration and output style"
```

---

### Task 5: ccusage quota segment and caveman badge

**Files:**
- Modify: `dot_claude/executable_statusline.sh`
- Modify: `dot_config/mise/config.toml`
- Create: `tests/statusline/fixtures/quota.json`
- Create: `tests/statusline/fixtures/quota.expected`
- Create: `tests/statusline/fixtures/quota.stub`
- Create: `tests/statusline/fixtures/quota-missing.json`
- Create: `tests/statusline/fixtures/quota-missing.expected`
- Create: `tests/statusline/fixtures/quota-missing.stub`

**Interfaces:**
- Consumes: `cache_get`, `join_segments`, the `C_*` globals.
- Produces:
  - `quota_segment` → prints `5h NN%` (percentage of the active 5-hour block remaining), or nothing.
  - `seg_caveman` → prints the caveman plugin badge, or nothing.

- [ ] **Step 1: Discover the ccusage JSON shape**

`ccusage`'s active-block payload is the one field this task cannot be written blind. Install and inspect it:

```bash
mise use -g "npm:ccusage@latest"
ccusage blocks --active --json | jq '.blocks[0] | keys'
```

Record the actual key names. The implementation below reads `.blocks[0].startTime` and `.blocks[0].endTime` and derives remaining percentage from the clock, which needs no token-accounting fields. If those two keys are absent under different names, substitute the real ones in the `jq` filter in Step 3 and adjust `quota.stub` to match. Everything else in this task is unaffected.

Pin the resolved version in `dot_config/mise/config.toml` next to the other tools, matching the existing `"pipx:..."` quoting style:

```toml
"npm:ccusage" = "<version printed by `mise ls ccusage`>"
```

- [ ] **Step 2: Write the failing tests**

`tests/statusline/fixtures/quota.json`:

```json
{
  "model": { "display_name": "Opus 4.8" },
  "workspace": { "current_dir": "/home/tester" },
  "context_window": { "remaining_percentage": 62.4 }
}
```

`tests/statusline/fixtures/quota.stub` — the block ends far in the future, so a fixed percentage is asserted by pinning both ends relative to a frozen `now` the stub also controls:

```bash
cat >"$STUB_DIR/ccusage" <<'STUB'
#!/bin/bash
# A five-hour block that is 62% remaining: started 6840s ago, ends 11160s out.
now=$(date +%s)
printf '{"blocks":[{"startTime":%s,"endTime":%s}]}\n' "$((now - 6840))" "$((now + 11160))"
STUB
chmod +x "$STUB_DIR/ccusage"
cat >"$STUB_DIR/git" <<'STUB'
#!/bin/bash
exit 128
STUB
chmod +x "$STUB_DIR/git"
```

`tests/statusline/fixtures/quota.expected`:

```
~
Opus 4.8  ctx 62%  5h 62%
```

`tests/statusline/fixtures/quota-missing.json`: same body as `quota.json`.

`tests/statusline/fixtures/quota-missing.stub` — no `ccusage` on PATH at all:

```bash
cat >"$STUB_DIR/git" <<'STUB'
#!/bin/bash
exit 128
STUB
chmod +x "$STUB_DIR/git"
```

Because the harness prepends `$STUB_DIR` rather than replacing `PATH`, this fixture must also mask a real installation. Add to the same stub file:

```bash
cat >"$STUB_DIR/ccusage" <<'STUB'
#!/bin/bash
exit 127
STUB
chmod +x "$STUB_DIR/ccusage"
```

`tests/statusline/fixtures/quota-missing.expected`:

```
~
Opus 4.8  ctx 62%
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `tests/statusline/run.sh`
Expected: `FAIL quota`; `ok quota-missing` (nothing renders it yet).

- [ ] **Step 4: Add the quota segment**

Insert after `seg_style`:

```bash
# Remaining wall-clock in the active five-hour block, colored on the same
# thresholds as context so the two meters read the same way.
quota_segment() {
  local json start end now left pct c
  command -v ccusage >/dev/null 2>&1 || return 0
  json=$(timeout 1 ccusage blocks --active --json 2>/dev/null) || return 0
  # One field per line, read with mapfile: a tab-separated read collapses
  # consecutive tabs, which silently shifts every field after an empty one.
  local fields=()
  mapfile -t fields < <(
    timeout 1 jq -r '
      (.blocks[0].startTime // "" | tostring),
      (.blocks[0].endTime // "" | tostring)
    ' <<<"$json" 2>/dev/null
  )
  start=${fields[0]-}
  end=${fields[1]-}
  start=${start%%.*}
  end=${end%%.*}
  case "$start$end" in '' | *[!0-9]*) return 0 ;; esac
  [ "$end" -gt "$start" ] || return 0
  printf -v now '%(%s)T' -1
  left=$((end - now))
  [ "$left" -gt 0 ] || return 0
  pct=$((left * 100 / (end - start)))
  if [ "$pct" -le 20 ]; then
    c=$C_RED
  elif [ "$pct" -le 40 ]; then
    c=$C_YELLOW
  else
    c=$C_GREEN
  fi
  printf '%s5h %s%%%s' "$c" "$pct" "$C_RESET"
}
```

- [ ] **Step 5: Move the caveman badge into a segment**

Insert after `quota_segment`:

```bash
# The caveman plugin ships its own renderer; it prints nothing when the mode
# is off, which is exactly this file's contract.
seg_caveman() {
  local hook
  hook=$(ls -td "$HOME"/.claude/plugins/cache/caveman/caveman/*/src/hooks/caveman-statusline.sh 2>/dev/null | head -1)
  [ -n "$hook" ] || return 0
  timeout 1 bash "$hook" </dev/null 2>/dev/null
}
```

- [ ] **Step 6: Render both on line 2**

Update the `line2=` assignment:

```bash
line2=$(join_segments '  ' \
  "$(seg_model "$model")" \
  "$(seg_ctx "$pct")" \
  "$(seg_cost "$cost")" \
  "$(seg_dur "$dur")" \
  "$(seg_style "$style")" \
  "$(cache_get quota 30 quota_segment)" \
  "$(seg_caveman)")
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `tests/statusline/run.sh`
Expected: every fixture `ok`, exit status 0. If `quota` is off by one percent, the stub's arithmetic straddled a second boundary — widen the block in the stub rather than loosening the assertion.

- [ ] **Step 8: Lint and commit**

```bash
shellcheck --severity=warning dot_claude/executable_statusline.sh
git add dot_claude/executable_statusline.sh dot_config/mise/config.toml tests/statusline
git commit -m "feat(statusline): usage-block quota and caveman badge"
```

---

### Task 6: End-to-end verification and pull request

**Files:**
- Modify: `README.md` (statusline description, if one exists there)

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: a merged-ready branch.

- [ ] **Step 1: Verify a clean-HOME apply, the way CI does**

Run: `HOME="$(mktemp -d)" chezmoi apply --source "$PWD" </dev/null && echo applied`
Expected: `applied`, exit status 0.

- [ ] **Step 2: Verify the real statusline renders**

Run:

```bash
printf '{"model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"%s"},"context_window":{"remaining_percentage":62.4},"cost":{"total_cost_usd":1.84,"total_duration_ms":4340000}}' "$PWD" |
  bash dot_claude/executable_statusline.sh; echo
```

Expected: two lines, the first showing `chezmoi` and the `feat/statusline` branch, the second showing model, context, cost, and duration.

- [ ] **Step 3: Verify render cost**

Run:

```bash
fixture=$(printf '{"model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"%s"},"context_window":{"remaining_percentage":62.4}}' "$PWD")
printf '%s' "$fixture" | bash dot_claude/executable_statusline.sh >/dev/null  # warm the caches
time (for _ in $(seq 20); do printf '%s' "$fixture" | bash dot_claude/executable_statusline.sh >/dev/null; done)
```

Expected: real time well under 2s for 20 renders, i.e. under 100ms each. If it is slower, a segment is bypassing the cache — find it before continuing.

- [ ] **Step 4: Update the README if it documents the statusline**

Run: `grep -n statusline README.md`
If there are hits, update the description to the two-line layout. If there are none, skip this step.

- [ ] **Step 5: Full local check, then open the PR**

```bash
shellcheck --severity=warning setup .chezmoiscripts/*.sh.tmpl dot_claude/executable_statusline.sh dot_config/shell/ssh-agent.sh tests/statusline/run.sh
jq empty dot_claude/settings.json
tests/statusline/run.sh
git push -u origin feat/statusline
gh pr create --title "feat(statusline): two-line cached statusline" --body "Implements docs/superpowers/specs/2026-07-20-statusline-design.md"
```

Expected: all three checks silent or `ok`, then a PR URL.
