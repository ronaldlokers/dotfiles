#!/usr/bin/env bash
# Real-git integration coverage for worktree_name(). Fixture-based tests in
# run.sh stub git with fixed literal strings, so they never exercise the
# actual absolute-vs-relative path shapes `git rev-parse --git-dir` and
# `--git-common-dir` return depending on cwd — which is exactly the shape
# that broke worktree detection from a subdirectory. This drives the real
# statusline script against a real git repo and a real linked worktree.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
script="$repo/dot_claude/executable_statusline.sh"

work=$(mktemp -d)
xdg=$(mktemp -d)
trap 'rm -rf "$work" "$xdg"' EXIT

export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"

main_repo="$work/main"
mkdir -p "$main_repo"
git -c init.defaultBranch=main -c commit.gpgsign=false init -q "$main_repo"
git -C "$main_repo" -c commit.gpgsign=false commit -q --allow-empty -m "init"
mkdir -p "$main_repo/subdir"

wt="$work/wt"
git -C "$main_repo" worktree add -q "$wt" -b feature-branch >/dev/null
mkdir -p "$wt/subdir"

fail=0

# run_statusline <dir-under-test>
# Feeds JSON with workspace.current_dir=<dir-under-test> to the real script
# and prints ANSI-stripped output. A fresh XDG_RUNTIME_DIR per call keeps
# the git-segment cache from bleeding a marker (or its absence) between
# assertions that use the same cache key would otherwise collide on.
run_statusline() {
  local dir=$1 case_xdg
  case_xdg=$(mktemp -d -p "$xdg")
  jq -n --arg dir "$dir" \
    '{model: {display_name: "Opus"}, workspace: {current_dir: $dir}, context_window: {remaining_percentage: 50}}' |
    XDG_RUNTIME_DIR="$case_xdg" bash "$script" 2>/dev/null |
    sed $'s/\033\\[[0-9;]*m//g'
}

assert_no_marker() {
  local label=$1 dir=$2 out
  out=$(run_statusline "$dir")
  if [[ "$out" == *"⑂"* ]]; then
    printf 'FAIL %s: unexpected worktree marker\n  dir: %s\n  out: %s\n' \
      "$label" "$dir" "$(printf '%s' "$out" | tr '\n' '|')"
    fail=1
  else
    printf 'ok   %s\n' "$label"
  fi
}

assert_marker_named() {
  local label=$1 dir=$2 name=$3 out
  out=$(run_statusline "$dir")
  if [[ "$out" == *"⑂$name"* ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s: expected marker ⑂%s\n  dir: %s\n  out: %s\n' \
      "$label" "$name" "$dir" "$(printf '%s' "$out" | tr '\n' '|')"
    fail=1
  fi
}

assert_no_marker "main repo root shows no worktree marker" "$main_repo"
assert_no_marker "main repo subdirectory shows no worktree marker (regression case)" "$main_repo/subdir"

wt_name=$(basename "$wt")
assert_marker_named "linked worktree root shows a named worktree marker" "$wt" "$wt_name"
assert_marker_named "linked worktree subdirectory shows a named worktree marker" "$wt/subdir" "$wt_name"

exit "$fail"
