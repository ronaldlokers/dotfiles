#!/usr/bin/env bash
# Regression coverage for one global constraint that spans the whole
# script: "every external command is wrapped in `timeout 1`". Four call
# sites are pinned here — the top-level stdin jq parse, quota_segment's
# ccusage-JSON jq parse, dir_hash's sha1sum, and seg_caveman's invocation
# of the caveman plugin's hook script — because they are all one class of
# mutation (drop the `timeout 1` prefix) and one class of consequence (a
# hung or slow external command blocks the render indefinitely instead of
# the segment just going silent). git_segment's `git status` call and
# quota_segment's `ccusage` call already have this coverage in
# cache-test.sh and quota-test.sh respectively; this file exists so the
# remaining four sites get it too, in one place.
#
# A grep for the literal string `timeout 1` ahead of each command would be
# trivially fooled by reformatting (a line break before the command, the
# duration moved into a variable, `timeout --duration=1`, a helper
# function that wraps timeout once and is called without it at a new call
# site) and only proves the text is present, not that the behavior holds.
# These tests instead plant a stub of the real external binary that sleeps
# well past the 1-second budget and would, if allowed to finish, produce
# perfectly plausible output — then assert the call site returns silently
# and promptly anyway. That is the actual contract ("this segment never
# blocks the render"), and it is what a grep can only ever approximate.
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
script="$repo/dot_claude/executable_statusline.sh"

# shellcheck disable=SC1090 # dynamic: definitions-only slice of the real script
source <(awk '/^input=\$\(cat\)/{exit} {print}' "$script")

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s: %s\n' "$1" "$2"; fail=1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

new_case_dir() {
  mktemp -d -p "$work"
}

# BUDGET is well short of every stub's 5-second sleep below, so a passing
# run proves the `timeout 1` actually fired rather than the stub finishing
# on its own.
BUDGET=2

# ---------------------------------------------------------------- case 1 --
# dir_hash's sha1sum call. Regression test for dropping `timeout 1` from
# the `sha1sum <<<"$d"` invocation: without it, a hung sha1sum would block
# dir_hash (and therefore every render that has a workspace directory) for
# as long as the hang lasts instead of degrading to "no cache key, hide the
# segment" within a bounded time.
d=$(new_case_dir)
cat >"$d/sha1sum" <<'EOF'
#!/bin/bash
sleep 5
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef  -\n'
EOF
chmod +x "$d/sha1sum"
cat >"$d/shasum" <<'EOF'
#!/bin/bash
sleep 5
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef  -\n'
EOF
chmod +x "$d/shasum"
start_ts=$(date +%s)
out=$(PATH="$d:/usr/bin:/bin" dir_hash "/some/dir" 2>"$d/err")
rc=$?
elapsed=$(($(date +%s) - start_ts))
if [ -z "$out" ] && [ "$rc" != 0 ] && [ ! -s "$d/err" ] && [ "$elapsed" -le "$BUDGET" ]; then
  ok "dir_hash: sha1sum slower than its timeout budget stays silent well before it would finish"
else
  bad "dir_hash: sha1sum slower than its timeout budget stays silent well before it would finish" \
    "out=[$out] rc=$rc err=[$(cat "$d/err")] elapsed=${elapsed}s"
fi

# ---------------------------------------------------------------- case 2 --
# quota_segment's own jq parse of ccusage's JSON. Regression test for
# dropping `timeout 1` from that specific jq call: ccusage itself answers
# instantly and healthily here, so a failure can only be attributed to the
# jq invocation, not to ccusage (which already has its own coverage in
# quota-test.sh case 6).
d=$(new_case_dir)
cat >"$d/ccusage" <<'EOF'
#!/bin/bash
now=$(date +%s)
start=$(date -u -d "@$((now - 6840))" +%Y-%m-%dT%H:%M:%S.000Z)
end=$(date -u -d "@$((now + 11160))" +%Y-%m-%dT%H:%M:%S.000Z)
printf '{"blocks":[{"startTime":"%s","endTime":"%s"}]}\n' "$start" "$end"
EOF
chmod +x "$d/ccusage"
cat >"$d/jq" <<'EOF'
#!/bin/bash
sleep 5
EOF
chmod +x "$d/jq"
start_ts=$(date +%s)
out=$(PATH="$d:/usr/bin:/bin" quota_segment 2>"$d/err")
rc=$?
elapsed=$(($(date +%s) - start_ts))
if [ -z "$out" ] && [ "$rc" = 0 ] && [ ! -s "$d/err" ] && [ "$elapsed" -le "$BUDGET" ]; then
  ok "quota_segment: jq slower than its timeout budget stays silent well before it would finish"
else
  bad "quota_segment: jq slower than its timeout budget stays silent well before it would finish" \
    "out=[$out] rc=$rc err=[$(cat "$d/err")] elapsed=${elapsed}s"
fi

# ---------------------------------------------------------------- case 3 --
# seg_caveman's invocation of the caveman plugin's own hook script.
# Regression test for dropping `timeout 1` from `bash "$hook"`: a hostile
# or merely slow third-party plugin hook must not be able to block every
# render just because it is on disk.
d=$(new_case_dir)
orig_home=$HOME
export HOME="$d/home"
hookdir="$HOME/.claude/plugins/cache/caveman/caveman/v1/src/hooks"
mkdir -p "$hookdir"
cat >"$hookdir/caveman-statusline.sh" <<'EOF'
#!/bin/bash
sleep 5
printf 'CAVEMAN'
EOF
chmod +x "$hookdir/caveman-statusline.sh"
start_ts=$(date +%s)
out=$(seg_caveman 2>"$d/err")
rc=$?
elapsed=$(($(date +%s) - start_ts))
export HOME="$orig_home"
# seg_caveman's return value is whatever `timeout 1 bash "$hook"` returns
# (the function has no trailing `return 0`), and a real timeout reports
# 124 — that propagating is correct, not a bug (nothing downstream treats
# it as fatal; the script has no `set -e`). rc is not asserted here, only
# silence and promptness.
if [ -z "$out" ] && [ ! -s "$d/err" ] && [ "$elapsed" -le "$BUDGET" ]; then
  ok "seg_caveman: hook slower than its timeout budget stays silent well before it would finish"
else
  bad "seg_caveman: hook slower than its timeout budget stays silent well before it would finish" \
    "out=[$out] rc=$rc err=[$(cat "$d/err")] elapsed=${elapsed}s"
fi

# ---------------------------------------------------------------- case 4 --
# The top-level stdin jq parse (outside any function, so it is driven
# through the real script as a subprocess rather than the sourced slice).
# Regression test for dropping `timeout 1` from that call: workspace
# current_dir is deliberately empty so dir_hash/git_segment are never
# reached, and ccusage is absent from PATH so quota_segment's own jq call
# is never reached either — the only external command this render can
# invoke is the hanging jq stub, isolating the top-level call.
d=$(new_case_dir)
cat >"$d/jq" <<'EOF'
#!/bin/bash
sleep 5
EOF
chmod +x "$d/jq"
input='{"model":{"display_name":"Opus"},"workspace":{"current_dir":""},"output_style":{"name":"default"},"context_window":{"remaining_percentage":50},"cost":{"total_cost_usd":0,"total_duration_ms":0}}'
xdg="$d/xdg"
mkdir -p "$xdg"
start_ts=$(date +%s)
out=$(printf '%s' "$input" |
  PATH="$d:/usr/bin:/bin" HOME="$d/home" XDG_RUNTIME_DIR="$xdg" bash "$script" 2>"$d/err")
rc=$?
elapsed=$(($(date +%s) - start_ts))
if [ -z "$out" ] && [ "$rc" = 0 ] && [ ! -s "$d/err" ] && [ "$elapsed" -le "$BUDGET" ]; then
  ok "top-level stdin parse: jq slower than its timeout budget leaves the render silent and prompt"
else
  bad "top-level stdin parse: jq slower than its timeout budget leaves the render silent and prompt" \
    "out=[$out] rc=$rc err=[$(cat "$d/err")] elapsed=${elapsed}s"
fi

exit "$fail"
