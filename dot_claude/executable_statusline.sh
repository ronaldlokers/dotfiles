#!/bin/bash
# Claude Code statusline.
#   line 1: where you are   — env, dir, worktree, branch
#   line 2: session meters  — model, context, cost, duration, style, quota
# Every segment renders nothing when its data is missing, unavailable, or
# times out; a statusline that lies is worse than one that is short.
set -u

# shellcheck disable=SC2034 # consumed by the cache helper landing in Task 2
CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/claude-statusline"

C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_RED=$'\033[31m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
# shellcheck disable=SC2034 # part of the shared palette; worktree/quota
# segments in later tasks pick these up
C_BLUE=$'\033[34m'
# shellcheck disable=SC2034 # part of the shared palette; worktree segment
# in Task 3 picks this up
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

input=$(cat)

# One jq call, not one per field: this runs on every render.
IFS=$'\t' read -r model dir style pct cost dur < <(
  jq -r '[
    (.model.display_name // ""),
    (.workspace.current_dir // ""),
    (.output_style.name // ""),
    (.context_window.remaining_percentage // "" | tostring),
    (.cost.total_cost_usd // "" | tostring),
    (.cost.total_duration_ms // "" | tostring)
  ] | @tsv' <<<"$input" 2>/dev/null
)
: "${model:=}" "${dir:=}" "${style:=}" "${pct:=}" "${cost:=}" "${dur:=}"

line1=$(join_segments '  ' "$(seg_dir "$dir")")
line2=$(join_segments '  ' \
  "$(seg_model "$model")" \
  "$(seg_ctx "$pct")" \
  "$(seg_cost "$cost")")

[ -n "$line1" ] && printf '%s\n' "$line1"
printf '%s' "$line2"
