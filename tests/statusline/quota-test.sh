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
#
# Checking only output/rc/stderr here is vacuous: it still passes even with
# the `command -v ccusage || return 0` guard deleted entirely, because
# `timeout 1 ccusage ...` invoked against a genuinely absent `ccusage` is
# *also* silent and zero-exit from the caller's side once its own
# `2>/dev/null` swallows timeout's own "failed to run command" message — the
# missing guard was otherwise unfalsifiable by output alone. So this also
# plants a fake `timeout` on PATH that records every invocation. `command -v`
# is a bash BUILTIN — it needs no real `timeout` (or `ccusage`) binary to
# correctly answer "not found" — so with the guard intact, quota_segment
# returns before ever reaching the `timeout 1 ccusage` line and the fake
# `timeout` is never invoked. A deleted guard falls through to that line and
# invokes it at least once, which the counter now catches.
timeout_calls="$bin/timeout_calls"
rm -f "$timeout_calls"
cat >"$bin/timeout" <<EOF
#!/bin/bash
printf 'x\n' >>"$timeout_calls"
exit 127
EOF
chmod +x "$bin/timeout"
out=$(PATH="$bin:$no_ccusage_path" quota_segment 2>"$bin/err")
rc=$?
calls=0
[ -f "$timeout_calls" ] && calls=$(wc -l <"$timeout_calls" | tr -d ' ')
if [ -z "$out" ] && [ "$rc" = 0 ] && [ ! -s "$bin/err" ] && [ "$calls" = 0 ]; then
  ok "ccusage absent: guard returns before ever invoking timeout"
else
  bad "ccusage absent: guard returns before ever invoking timeout" \
    "out=[$out] rc=$rc err=[$(cat "$bin/err")] timeout_calls=$calls"
fi
# The fake `timeout` was only for this case; every later case needs the
# real one (via the /usr/bin:/bin fallback already on PATH).
rm -f "$bin/timeout" "$timeout_calls"

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

# ---------------------------------------------------------------- case 6 --
# ccusage slower than a one-second budget but well inside its real one. The
# real ccusage is a Node CLI that re-reads every session JSONL on each
# invocation; measured cold on this machine it takes ~2.5s, so the
# `timeout 1` this call once carried killed it on *every* render and the
# segment was permanently blank while ccusage was healthy the whole time.
# The whole point of QUOTA_TIMEOUT_SECS is that a merely-slow ccusage still
# renders, so the 3-second sleep below must produce a percentage, not
# silence.
cat >"$bin/ccusage" <<'EOF'
#!/bin/bash
sleep 3
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
  ok "ccusage slow but inside its budget: still renders instead of staying blank"
else
  bad "ccusage slow but inside its budget: still renders instead of staying blank" \
    "out=[$stripped] rc=$rc err=[$(cat "$bin/err")]"
fi

# ---------------------------------------------------------------- case 7 --
# ccusage hangs past QUOTA_TIMEOUT_SECS entirely. Regression test for a
# mutation that drops the `timeout` wrapper from the ccusage invocation:
# without it this case would wait out the full sleep and print a real
# percentage instead of staying silent. The sleep is set well past the
# budget and the elapsed assertion just past it, so a passing run proves
# the timeout actually fired rather than the command finishing on its own.
cat >"$bin/ccusage" <<EOF
#!/bin/bash
sleep $((QUOTA_TIMEOUT_SECS + 15))
now=\$(date +%s)
start=\$(date -u -d "@\$((now - 6840))" +%Y-%m-%dT%H:%M:%S.000Z)
end=\$(date -u -d "@\$((now + 11160))" +%Y-%m-%dT%H:%M:%S.000Z)
printf '{"blocks":[{"startTime":"%s","endTime":"%s"}]}\n' "\$start" "\$end"
EOF
chmod +x "$bin/ccusage"
start_ts=$(date +%s)
out=$(PATH="$bin:/usr/bin:/bin" quota_segment 2>"$bin/err")
rc=$?
elapsed=$(($(date +%s) - start_ts))
if [ -z "$out" ] && [ "$rc" = 0 ] && [ ! -s "$bin/err" ] &&
  [ "$elapsed" -le $((QUOTA_TIMEOUT_SECS + 2)) ]; then
  ok "ccusage hangs past its timeout budget: silent well before it would finish"
else
  bad "ccusage hangs past its timeout budget: silent well before it would finish" \
    "out=[$out] rc=$rc err=[$(cat "$bin/err")] elapsed=${elapsed}s"
fi

exit "$fail"
