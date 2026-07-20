#!/usr/bin/env bash
# Direct unit tests for quota_segment() in executable_statusline.sh.
#
# The fixture-based quota-missing case in run.sh was vacuous, for two
# compounding reasons: (1) run.sh sets HOME=/home/tester, which does not
# exist, so on a machine where ccusage is a mise shim, ccusage fails
# regardless of what the fixture's stub does; and (2) run.sh prepends its
# stub directory to PATH rather than replacing it, and the stub is an
# executable file that exits 127 — `command -v ccusage` still succeeds, so
# quota_segment's real "not installed" guard (`command -v ccusage ... ||
# return 0`) was never exercised by any fixture.
#
# These tests control PATH precisely and drive quota_segment directly,
# sourcing only the definitions-only slice of the script (same technique as
# cache-test.sh), so each scenario below is pinned rather than incidental.
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
script="$repo/dot_claude/executable_statusline.sh"

# shellcheck disable=SC1090 # dynamic: definitions-only slice of the real script
source <(awk '/^input=\$\(cat\)/{exit} {print}' "$script")

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s: %s\n' "$1" "$2"; fail=1; }

bin=$(mktemp -d)
trap 'rm -rf "$bin"' EXIT

strip() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }

# /usr/bin and /bin are enough to resolve `timeout` and `jq` (both real
# system binaries here) but never `ccusage`, which only exists as a mise
# shim elsewhere on PATH — this is "genuinely not installed", unlike
# run.sh's stub-dir prepend, which left a failing stub still satisfying
# `command -v`.
no_ccusage_path=/usr/bin:/bin

# ---------------------------------------------------------------- case 1 --
# ccusage is not resolvable on PATH at all: the actual "not installed" guard.
out=$(PATH="$no_ccusage_path" quota_segment 2>"$bin/err")
rc=$?
if [ -z "$out" ] && [ "$rc" = 0 ] && [ ! -s "$bin/err" ]; then
  ok "ccusage absent: prints nothing, exits 0, no stderr"
else
  bad "ccusage absent: prints nothing, exits 0, no stderr" \
    "out=[$out] rc=$rc err=[$(cat "$bin/err")]"
fi

# ---------------------------------------------------------------- case 2 --
# ccusage resolves but fails (non-zero exit). It also writes to its own
# stderr, the way a real failing tool would, so a regression that drops the
# script's `2>/dev/null` on the ccusage call would leak here and be caught.
cat >"$bin/ccusage" <<'EOF'
#!/bin/bash
echo "ccusage: boom" >&2
exit 1
EOF
chmod +x "$bin/ccusage"
out=$(PATH="$bin:/usr/bin:/bin" quota_segment 2>"$bin/err")
rc=$?
if [ -z "$out" ] && [ "$rc" = 0 ] && [ ! -s "$bin/err" ]; then
  ok "ccusage present but failing: prints nothing, exits 0, no stderr"
else
  bad "ccusage present but failing: prints nothing, exits 0, no stderr" \
    "out=[$out] rc=$rc err=[$(cat "$bin/err")]"
fi

# ---------------------------------------------------------------- case 3 --
# ccusage exits 0 but emits malformed JSON.
cat >"$bin/ccusage" <<'EOF'
#!/bin/bash
echo 'not { valid json'
EOF
chmod +x "$bin/ccusage"
out=$(PATH="$bin:/usr/bin:/bin" quota_segment 2>"$bin/err")
rc=$?
if [ -z "$out" ] && [ "$rc" = 0 ] && [ ! -s "$bin/err" ]; then
  ok "ccusage present but malformed JSON: prints nothing, exits 0, no stderr"
else
  bad "ccusage present but malformed JSON: prints nothing, exits 0, no stderr" \
    "out=[$out] rc=$rc err=[$(cat "$bin/err")]"
fi

# ---------------------------------------------------------------- case 4 --
# ccusage healthy: a block with a pinned start/end gives a pinned pct.
# Window totals 100000s, 76400s remain -> floor(76400*100/100000) = 76.
# Margin to the next-lower percentage boundary (76000s remaining) is 400s,
# far more than the sub-second gap between generating these timestamps and
# quota_segment's own `now`, so this isn't flaky.
cat >"$bin/ccusage" <<'EOF'
#!/bin/bash
now=$(date +%s)
start=$(date -u -d "@$((now - 23600))" +%Y-%m-%dT%H:%M:%S.000Z)
end=$(date -u -d "@$((now + 76400))" +%Y-%m-%dT%H:%M:%S.000Z)
printf '{"blocks":[{"startTime":"%s","endTime":"%s"}]}\n' "$start" "$end"
EOF
chmod +x "$bin/ccusage"
out=$(PATH="$bin:/usr/bin:/bin" quota_segment 2>"$bin/err")
rc=$?
stripped=$(strip "$out")
if [ "$stripped" = "5h 76%" ] && [ "$rc" = 0 ] && [ ! -s "$bin/err" ]; then
  ok "ccusage healthy: renders pinned 76% for a block with 76400s left of 100000s"
else
  bad "ccusage healthy: renders pinned 76% for a block with 76400s left of 100000s" \
    "out=[$stripped] rc=$rc err=[$(cat "$bin/err")]"
fi

# ---------------------------------------------------------------- case 5 --
# Block has not started yet (now < start): raw pct would be
# floor(23000*100/18000) = 127 (the shape the reviewer measured), clamped
# to 100. ccusage --active should only ever return a block containing now,
# so this is believed unreachable in practice, but there is no other test
# for the defensive clamp.
cat >"$bin/ccusage" <<'EOF'
#!/bin/bash
now=$(date +%s)
start=$(date -u -d "@$((now + 5000))" +%Y-%m-%dT%H:%M:%S.000Z)
end=$(date -u -d "@$((now + 23000))" +%Y-%m-%dT%H:%M:%S.000Z)
printf '{"blocks":[{"startTime":"%s","endTime":"%s"}]}\n' "$start" "$end"
EOF
chmod +x "$bin/ccusage"
out=$(PATH="$bin:/usr/bin:/bin" quota_segment 2>"$bin/err")
rc=$?
stripped=$(strip "$out")
if [ "$stripped" = "5h 100%" ] && [ "$rc" = 0 ] && [ ! -s "$bin/err" ]; then
  ok "block not yet started: pct is clamped to 100, not 127"
else
  bad "block not yet started: pct is clamped to 100, not 127" \
    "out=[$stripped] rc=$rc err=[$(cat "$bin/err")]"
fi

exit "$fail"
