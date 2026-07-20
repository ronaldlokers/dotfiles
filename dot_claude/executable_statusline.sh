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

# Join the non-empty arguments; empty segments leave no double separator.
join_segments() {
  local sep=$1 s
  local out=
  shift
  for s in "$@"; do
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

# One jq call, not one per field: this runs on every render. One field per
# line (not @tsv) so mapfile preserves empty fields instead of bash's IFS
# whitespace-collapsing shifting every later field left.
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

git_key=${dir//\//_}
line1=$(join_segments '  ' \
  "$(seg_env)" \
  "$(seg_dir "$dir")" \
  "$(cache_get "git$git_key" 10 git_segment "$dir")")
line2=$(join_segments '  ' \
  "$(seg_model "$model")" \
  "$(seg_ctx "$pct")" \
  "$(seg_cost "$cost")" \
  "$(seg_dur "$dur")" \
  "$(seg_style "$style")")

[ -n "$line1" ] && printf '%s\n' "$line1"
printf '%s' "$line2"
