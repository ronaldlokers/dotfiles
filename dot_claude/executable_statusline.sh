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

C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_RED=$'\033[31m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
# shellcheck disable=SC2034 # part of the shared palette; worktree/quota
# segments in later tasks pick these up
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
# shellcheck disable=SC2034 # style segment lands in a later task
style=${fields[2]-}
pct=${fields[3]-}
cost=${fields[4]-}
# shellcheck disable=SC2034 # duration segment lands in a later task
dur=${fields[5]-}

git_key=${dir//\//_}
line1=$(join_segments '  ' \
  "$(seg_dir "$dir")" \
  "$(cache_get "git$git_key" 10 git_segment "$dir")")
line2=$(join_segments '  ' \
  "$(seg_model "$model")" \
  "$(seg_ctx "$pct")" \
  "$(seg_cost "$cost")")

[ -n "$line1" ] && printf '%s\n' "$line1"
printf '%s' "$line2"
