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

# A stub `git` emulating git < 2.31: it recognizes -C and rev-parse
# --git-dir/--git-common-dir, but not --path-format, which real git echoes
# back verbatim as its own output line (and still exits 0) for any
# unrecognized long option, rather than failing. Everything else is
# delegated to the real git so repo setup above and the fallback's
# --absolute-git-dir call both keep working.
real_git=$(command -v git)
oldgit_dir=$(mktemp -d)
trap 'rm -rf "$work" "$xdg" "$oldgit_dir"' EXIT
cat >"$oldgit_dir/git" <<STUB
#!/usr/bin/env bash
set -u
real_git="$real_git"
dir="."
prev=""
for arg in "\$@"; do
  [ "\$prev" = "-C" ] && dir=\$arg
  prev=\$arg
done
case " \$* " in
  *" rev-parse --path-format=absolute --git-dir --git-common-dir "*)
    gd=\$("\$real_git" -C "\$dir" rev-parse --absolute-git-dir 2>/dev/null)
    printf '%s\n%s\n%s\n' '--path-format=absolute' "\$gd" '.git'
    exit 0
    ;;
esac
exec "\$real_git" "\$@"
STUB
chmod +x "$oldgit_dir/git"

fail=0

# run_statusline <dir-under-test> [extra-path-prefix]
# Feeds JSON with workspace.current_dir=<dir-under-test> to the real script
# and prints ANSI-stripped output. A fresh XDG_RUNTIME_DIR per call keeps
# the git-segment cache from bleeding a marker (or its absence) between
# assertions that use the same cache key would otherwise collide on. An
# optional extra PATH prefix lets a case run against the old-git stub.
run_statusline() {
  local dir=$1 extra_path=${2:-} case_xdg
  case_xdg=$(mktemp -d -p "$xdg")
  jq -n --arg dir "$dir" \
    '{model: {display_name: "Opus"}, workspace: {current_dir: $dir}, context_window: {remaining_percentage: 50}}' |
    XDG_RUNTIME_DIR="$case_xdg" PATH="${extra_path:+$extra_path:}$PATH" bash "$script" 2>/dev/null |
    sed $'s/\033\\[[0-9;]*m//g'
}

assert_no_marker() {
  local label=$1 dir=$2 extra_path=${3:-} out
  out=$(run_statusline "$dir" "$extra_path")
  if [[ "$out" == *"⑂"* ]]; then
    printf 'FAIL %s: unexpected worktree marker\n  dir: %s\n  out: %s\n' \
      "$label" "$dir" "$(printf '%s' "$out" | tr '\n' '|')"
    fail=1
  else
    printf 'ok   %s\n' "$label"
  fi
}

assert_marker_named() {
  local label=$1 dir=$2 name=$3 extra_path=${4:-} out
  out=$(run_statusline "$dir" "$extra_path")
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

# git < 2.31 has no --path-format, so it echoes that unrecognized option
# back as a literal output line ahead of --git-dir/--git-common-dir and
# still exits 0. The pre-fix code trusted the exit status, not the shape of
# the output, so it mistook the echoed flag text for the git-dir and
# rendered it as a fabricated worktree marker on every invocation. The
# fixed code validates the output shape (exactly two absolute paths) and
# falls back to --absolute-git-dir detection when it is not met.
assert_no_marker "old-git emulation in normal checkout shows no marker" \
  "$main_repo" "$oldgit_dir"
assert_marker_named "old-git emulation in linked worktree shows a named marker via fallback" \
  "$wt" "$wt_name" "$oldgit_dir"

exit "$fail"
