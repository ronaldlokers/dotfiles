#!/bin/bash
# Claude Code statusline.
#   line 1: where you are   — env, dir, worktree, branch
#   line 2: session meters  — model, context, cost, duration, style, quota
# Every segment renders nothing when its data is missing, unavailable, or
# times out; a statusline that lies is worse than one that is short.
set -u

# Keep printf's decimal separator a dot regardless of the user's locale;
# the cost segment does integer math on the formatted string.
export LC_ALL=C

CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/claude-statusline"
# No refresh outlives its own `timeout 1`, so a lock directory older than
# this is definitionally abandoned (its owner was killed between mkdir and
# rmdir) rather than legitimately held.
LOCK_STALE_SECS=60
# A background refresh that comes back empty while the cache holds a good
# value must not blank it on the strength of one transient failure — but it
# must also not defend a value that is genuinely gone forever. This bounds
# how many *consecutive* empty refreshes a good value survives before it is
# finally allowed to expire; see cache_refresh's `.misses` companion file.
CACHE_EMPTY_RETRIES=3

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
  # shellcheck disable=SC2088 # literal ~ is wanted below, not expansion
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

# Anything under a minute is noise on a line that is already busy.
seg_dur() {
  local ms=${1%%.*} s h m
  case "$ms" in '' | *[!0-9]*) return 0 ;; esac
  # Compare whole milliseconds, not the truncated-to-seconds value: flooring
  # ms/1000 first would make 60001ms read as exactly 60s and wrongly hide.
  [ "$ms" -gt 60000 ] || return 0
  s=$((ms / 1000))
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

# Remaining wall-clock in the active five-hour block, colored on the same
# thresholds as context so the two meters read the same way. ccusage reports
# startTime/endTime as ISO-8601 strings (with fractional seconds), not epoch
# numbers, so the fractional part is stripped before fromdateiso8601 parses
# them; a value that fails to parse (missing block, malformed string) is
# caught and becomes "", which the numeric guard below then hides.
quota_segment() {
  local json start end now left pct c
  command -v ccusage >/dev/null 2>&1 || return 0
  json=$(timeout 1 ccusage blocks --active --json 2>/dev/null) || return 0
  # NUL-separated, read with `mapfile -d ''`: jq -r's newline delimiter is
  # not safe here on principle (these two fields are epoch numbers, but the
  # same parse shape as the top-level stdin parse below is used
  # deliberately so this can never regress independently) — a delimiter
  # that cannot appear inside the data is the only one that preserves
  # empty fields without shifting anything later.
  local fields=()
  mapfile -d '' -t fields < <(
    timeout 1 jq -j '
      (.blocks[0].startTime // "" | tostring | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch ""), ([0] | implode),
      (.blocks[0].endTime // "" | tostring | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch ""), ([0] | implode)
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
  # ccusage --active should only ever return a block that contains now, so
  # this should be unreachable — but a block that has not started yet
  # (now < start) would otherwise push left above (end - start) and pct
  # past 100. Defensive clamp, not a load-bearing guard.
  if [ "$pct" -gt 100 ]; then
    pct=100
  elif [ "$pct" -lt 0 ]; then
    pct=0
  fi
  if [ "$pct" -le 20 ]; then
    c=$C_RED
  elif [ "$pct" -le 40 ]; then
    c=$C_YELLOW
  else
    c=$C_GREEN
  fi
  printf '%s5h %s%%%s' "$c" "$pct" "$C_RESET"
}

# The caveman plugin ships its own renderer; it prints nothing when the mode
# is off, which is exactly this file's contract.
seg_caveman() {
  local hook
  hook=$(ls -td "$HOME"/.claude/plugins/cache/caveman/caveman/*/src/hooks/caveman-statusline.sh 2>/dev/null | head -1)
  [ -n "$hook" ] || return 0
  timeout 1 bash "$hook" </dev/null 2>/dev/null
}

# Join the non-empty arguments; empty segments leave no double separator.
# Every segment is sanitized here, centrally, rather than at each call site:
# a segment payload that contains a raw CR or LF (a hostile caveman-plugin
# hook, a directory name with a newline surviving from upstream) would
# otherwise inject an extra visual line into a statusline that promises
# exactly two. This is the composition-layer half of the same fix as the
# NUL-delimited stdin parse above — it also covers seg_style and any future
# segment for free, without patching each one individually.
join_segments() {
  local sep=$1 s
  local out=
  shift
  for s in "$@"; do
    s=${s//$'\r'/}
    s=${s//$'\n'/}
    [ -n "$s" ] || continue
    if [ -z "$out" ]; then out=$s; else out="$out$sep$s"; fi
  done
  printf '%s' "$out"
}

# Print a cached segment immediately, then refresh it out of band when it is
# older than the TTL. The freshest value the *next* render sees is worth more
# than blocking this one on a subprocess.
# Cache file layout: line 1 is the write timestamp, the rest is the payload.
cache_get() {
  local key=$1 ttl=$2
  shift 2
  local f="$CACHE_DIR/$key" lock="$CACHE_DIR/$key.lock" now raw ts payload lock_ts
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  printf -v now '%(%s)T' -1

  if [ -f "$f" ]; then
    raw=$(<"$f")
    ts=${raw%%$'\n'*}
    payload=${raw#*$'\n'}
    [ "$payload" = "$raw" ] && payload=
    printf '%s' "$payload"
    case "$ts" in '' | *[!0-9]*) ts=0 ;; esac
    if [ $((now - ts)) -ge "$ttl" ]; then
      if ! mkdir "$lock" 2>/dev/null; then
        # A refresh killed between mkdir and rmdir would otherwise wedge this
        # key forever; no refresh outlives its own timeout, so a lock this old
        # is abandoned rather than held. The stale payload above is already
        # printed, so bailing out here still serves it — winning the lock is
        # only about whether a refresh gets kicked off.
        lock_ts=$(timeout 1 stat -c %Y "$lock" 2>/dev/null || echo 0)
        case "$lock_ts" in '' | *[!0-9]*) lock_ts=0 ;; esac
        [ $((now - lock_ts)) -ge "$LOCK_STALE_SECS" ] || return 0
        rmdir "$lock" 2>/dev/null || return 0
        mkdir "$lock" 2>/dev/null || return 0
      fi
      cache_refresh "$f" "$lock" "$@"
    fi
    return 0
  fi

  # Cold cache: pay for one synchronous attempt so the first render is not
  # blank, but never wait longer than the command's own timeout.
  if ! mkdir "$lock" 2>/dev/null; then
    # Same stale-lock break as the warm path above.
    lock_ts=$(timeout 1 stat -c %Y "$lock" 2>/dev/null || echo 0)
    case "$lock_ts" in '' | *[!0-9]*) lock_ts=0 ;; esac
    [ $((now - lock_ts)) -ge "$LOCK_STALE_SECS" ] || return 0
    rmdir "$lock" 2>/dev/null || return 0
    mkdir "$lock" 2>/dev/null || return 0
  fi
  payload=$("$@" 2>/dev/null)
  printf '%s\n%s' "$now" "$payload" >"$f.tmp" 2>/dev/null &&
    mv "$f.tmp" "$f" 2>/dev/null
  rmdir "$lock" 2>/dev/null
  printf '%s' "$payload"
}

# Detached so the refresh survives this render exiting. Backgrounds a
# subshell of *this* shell instead of a fresh `bash -c`: a `bash -c`
# inherits no shell functions and none of this shell's non-exported
# variables, but both real callers of cache_get (git_segment,
# quota_segment) are shell functions that call other shell functions
# (worktree_name) and reference globals (the C_* colors, CACHE_DIR) — a
# `bash -c` refresh silently fails "command not found" for every one of
# them. A plain subshell inherits all of that for free. `trap '' HUP`
# lets it keep running after this render's shell exits.
#
# An empty result must never simply overwrite a cache that already holds
# something: a real command failure must never blank a segment that was
# previously rendering fine — that overwrite (fresh timestamp, empty
# payload) is exactly how the bash-c bug turned one bad refresh into a
# permanently blanked segment. So an empty result re-writes the *previous*
# payload rather than the empty one — but the timestamp is written every
# time regardless, expired or not: a version that instead left the file
# untouched (as this once did) never clears the TTL, so every subsequent
# render sees a still-expired cache and forks a brand new background
# refresh forever, even though nothing will ever change (e.g. the repo
# that was cached is gone for good). Writing a fresh timestamp on the
# no-op path is what stops that.
#
# But "keep serving the stale value forever" is also wrong for a value
# that is genuinely gone (branch cached, then `.git` deleted): a companion
# `.misses` file counts *consecutive* empty results, and once it reaches
# CACHE_EMPTY_RETRIES the stale payload is finally allowed to expire to
# empty, rather than being defended indefinitely. Any non-empty result
# resets the counter to zero.
#
# A segment that is legitimately empty (no git repo, ccusage not
# installed) produces the same empty result, but its cache already holds
# an empty payload from the attempt before — `prev` is empty too, so the
# branch below just writes empty-over-empty with a fresh timestamp, which
# is what stops it from re-running the command on every single render.
cache_refresh() {
  local f=$1 lock=$2
  shift 2
  (
    trap '' HUP
    local now payload prev_raw misses missfile="$f.misses" prev=
    printf -v now '%(%s)T' -1
    payload=$("$@" 2>/dev/null)
    if [ -n "$payload" ]; then
      rm -f "$missfile" 2>/dev/null
    else
      if [ -f "$f" ]; then
        prev_raw=$(<"$f")
        prev=${prev_raw#*$'\n'}
        [ "$prev" = "$prev_raw" ] && prev=
      fi
      if [ -n "$prev" ]; then
        misses=
        [ -f "$missfile" ] && misses=$(<"$missfile")
        case "$misses" in '' | *[!0-9]*) misses=0 ;; esac
        misses=$((misses + 1))
        # The write must succeed for the stale payload to be defended: a
        # `.misses` file that cannot be persisted (e.g. left behind
        # foreign-owned, or the cache dir gone read-only) must never be
        # read back as "still under the limit" forever — that reproduces
        # the exact lie-forever bug the retry counter exists to prevent,
        # just one layer down. Fail toward expiring, not toward defending.
        if [ "$misses" -lt "$CACHE_EMPTY_RETRIES" ] &&
          printf '%s' "$misses" >"$missfile" 2>/dev/null; then
          payload=$prev
        else
          rm -f "$missfile" 2>/dev/null
        fi
      fi
    fi
    printf '%s\n%s' "$now" "$payload" >"$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null
    rmdir "$lock" 2>/dev/null
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# The git cache key must not collide across distinct directories. A naive
# `${dir//\//_}` maps both `/x/a/b` and `/x/a_b` to the key `_x_a_b` —
# verified live: standing in one repo, the statusline printed a
# neighbouring repo's branch. sha1 of the repo path (per the design spec's
# Caching section) does not have that collision. Wrapped in `timeout 1`
# like every other external command; if no hashing tool is available the
# caller gets an empty key and hides the segment rather than falling back
# to the collision-prone key.
dir_hash() {
  local d=$1 h
  if command -v sha1sum >/dev/null 2>&1; then
    h=$(timeout 1 sha1sum <<<"$d" 2>/dev/null) || return 1
  elif command -v shasum >/dev/null 2>&1; then
    h=$(timeout 1 shasum -a 1 <<<"$d" 2>/dev/null) || return 1
  else
    return 1
  fi
  [ -n "$h" ] || return 1
  printf '%s' "${h%% *}"
}

# A linked worktree has a --git-dir under the main repo's
# .git/worktrees/<name>; a normal checkout has --git-dir == --git-common-dir.
# Both paths must be compared in the same format: from any directory other
# than the repo root, git prints --git-dir absolute but --git-common-dir
# relative, so a plain string compare falsely flags every ordinary checkout.
# --path-format=absolute (git >= 2.31) normalizes both; older git falls back
# to recognizing the .git/worktrees/<name> layout directly.
#
# Detecting "older git" cannot rely on the command's exit status: git
# rev-parse does not fail on an unrecognized long option, it echoes the
# option back as a literal output line and still exits 0. So a pre-2.31 git
# asked for --path-format=absolute succeeds with three lines (the echoed
# flag plus the two dirs), not two — trust the output only when its shape
# is exactly the two absolute paths that were asked for.
worktree_name() {
  local dir=$1 out lines=() gitdir common
  out=$(timeout 1 git -C "$dir" rev-parse \
    --path-format=absolute --git-dir --git-common-dir 2>/dev/null)
  mapfile -t lines <<<"$out"
  if [ "${#lines[@]}" -eq 2 ] &&
    [ "${lines[0]#/}" != "${lines[0]}" ] && [ "${lines[1]#/}" != "${lines[1]}" ]; then
    gitdir=${lines[0]}
    common=${lines[1]}
    [ "$gitdir" != "$common" ] || return 0
    printf '%s' "${gitdir##*/}"
    return 0
  fi
  # git < 2.31: no --path-format. Linked worktrees live in
  # <main-repo>/.git/worktrees/<name>, so fall back to that layout.
  gitdir=$(timeout 1 git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  case "$gitdir" in */worktrees/*) printf '%s' "${gitdir##*/}" ;; esac
}

# One `git status --porcelain=v2 --branch` yields branch name, ahead/behind,
# and dirtiness together — three questions, one process.
git_segment() {
  local dir=$1 status line dirty=0 ahead=0 behind=0 out
  local head='' ab=''
  # git -C "" silently falls back to the caller's cwd instead of failing,
  # which would leak whatever repo this process happens to be running in.
  [ -n "$dir" ] || return 0
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

  local wt
  wt=$(worktree_name "$dir")

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
  if [ -n "$wt" ]; then
    printf '%s⑂%s%s  %s%s%s' "$C_DIM" "$wt" "$C_RESET" "$C_MAGENTA" "$out" "$C_RESET"
  else
    printf '%s%s%s' "$C_MAGENTA" "$out" "$C_RESET"
  fi
}

input=$(cat)

# One jq call, not one per field: this runs on every render. NUL-separated
# output, read with `mapfile -d ''`: `jq -r` emits raw newlines inside
# string values (a directory containing a newline is enough), and a
# newline delimiter silently shifts every field after it — the same class
# of bug the tab-collapsing read was fixed for once already. NUL cannot
# appear in a jq string value, so it is the only delimiter that is both
# unambiguous and preserves empty fields. `([0] | implode)` builds the NUL
# byte from its codepoint rather than embedding one literally in the jq
# program text.
mapfile -d '' -t fields < <(
  timeout 1 jq -j '
    (.model.display_name // ""), ([0] | implode),
    (.workspace.current_dir // ""), ([0] | implode),
    (.output_style.name // ""), ([0] | implode),
    (.context_window.remaining_percentage // "" | tostring), ([0] | implode),
    (.cost.total_cost_usd // "" | tostring), ([0] | implode),
    (.cost.total_duration_ms // "" | tostring), ([0] | implode)
  ' <<<"$input" 2>/dev/null
)
model=${fields[0]-}
dir=${fields[1]-}
style=${fields[2]-}
pct=${fields[3]-}
cost=${fields[4]-}
dur=${fields[5]-}

git_key=
git_out=
if [ -n "$dir" ]; then
  git_key=$(dir_hash "$dir")
  [ -n "$git_key" ] && git_out=$(cache_get "git$git_key" 10 git_segment "$dir")
fi
line1=$(join_segments '  ' \
  "$(seg_env)" \
  "$(seg_dir "$dir")" \
  "$git_out")
line2=$(join_segments '  ' \
  "$(seg_model "$model")" \
  "$(seg_ctx "$pct")" \
  "$(seg_cost "$cost")" \
  "$(seg_dur "$dur")" \
  "$(seg_style "$style")" \
  "$(cache_get quota 30 quota_segment)" \
  "$(seg_caveman)")

[ -n "$line1" ] && printf '%s\n' "$line1"
printf '%s' "$line2"
