#!/usr/bin/env bash
# Direct unit tests for cache_get/cache_refresh in executable_statusline.sh.
#
# Sources only the function and variable definitions above the top-level
# `input=$(cat)` line, so this drives cache_get directly instead of forking
# the whole statusline pipeline (which would block reading stdin).
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
script="$repo/dot_claude/executable_statusline.sh"

# shellcheck disable=SC1090 # dynamic: definitions-only slice of the real script
source <(awk '/^input=\$\(cat\)/{exit} {print}' "$script")

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s: %s\n' "$1" "$2"; fail=1; }

# The real callers of cache_get — git_segment and quota_segment — are shell
# FUNCTIONS, not PATH executables, and they call other shell functions
# (worktree_name) and reference globals (the C_* colors, CACHE_DIR).
# cache_refresh's background refresh must drive its command in a context
# that still has all of that available. A fake PATH executable would pass
# even when cache_refresh forks a brand-new `bash -c` that inherits none of
# it, so every case below drives a shell function instead, exactly like
# production does.
fake_helper() { printf 'H'; }

# args: <counter-file> <output-file>
# Appends one line per invocation (proves call count), calls another shell
# function (mirrors git_segment calling worktree_name) and prints the
# current contents of <output-file> as the "rendered" payload, prefixed
# with fake_helper's output so a lost function would also show up here.
fake_segment() {
  local counter=$1 output=$2 h
  printf 'x\n' >>"$counter"
  h=$(fake_helper)
  [ -f "$output" ] && printf '%s%s' "$h" "$(cat "$output")"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

new_case_dir() {
  mktemp -d -p "$work"
}

call_count() {
  [ -f "$1" ] && wc -l <"$1" | tr -d ' ' || printf '0'
}

# payload_is <cache-file> <expected> — used as a poll_until predicate.
# Polling on the counter file changing and then separately re-checking the
# payload is racy: fake_segment increments the counter *before* it produces
# its output, so the counter can flip the instant the refresh starts, well
# before cache_refresh has written and renamed the cache file. Polling on
# the payload's final value directly avoids that gap.
payload_is() {
  [ "$(cache_payload "$1")" = "$2" ]
}

# poll_until <iterations> <sleep-seconds> <predicate...>
poll_until() {
  local n=$1 s=$2 i
  shift 2
  for ((i = 0; i < n; i++)); do
    "$@" && return 0
    sleep "$s"
  done
  return 1
}

cache_payload() {
  local f=$1 raw payload
  [ -f "$f" ] || return 0
  raw=$(<"$f")
  payload=${raw#*$'\n'}
  # Mirror cache_get's own guard: if there was no newline to strip (a
  # single-line file, e.g. a written-but-empty payload with its trailing
  # newline stripped by command substitution), the removal is a no-op and
  # payload still equals raw — that's "no payload", not "payload equal to
  # the timestamp". Without this guard a bare timestamp misreads as the
  # rendered content.
  [ "$payload" = "$raw" ] && payload=
  printf '%s' "$payload"
}

# refresh_ts <cache-file> — the write timestamp currently on disk, or ''.
# Used to detect that a background refresh has finished: cache_refresh
# always rewrites the timestamp on completion (defended, expired, or
# legitimately empty alike), so polling for it to change away from a known
# "before" value is a completion signal that works regardless of which
# branch the refresh took — unlike polling the payload, which can
# legitimately stay the same across a round that defends it.
refresh_ts() {
  local f=$1 raw
  [ -f "$f" ] || { printf ''; return; }
  raw=$(<"$f")
  printf '%s' "${raw%%$'\n'*}"
}

# ---------------------------------------------------------------- case 1 --
# Cold start with an empty cache: runs the command synchronously and prints
# its output.
d=$(new_case_dir)
CACHE_DIR="$d/cache"
counter="$d/counter"
output="$d/output"
printf 'hello' >"$output"
out=$(cache_get "k1" 100 fake_segment "$counter" "$output")
if [ "$out" = "Hhello" ] && [ "$(call_count "$counter")" = "1" ]; then
  ok "cold start runs the command synchronously and prints its output"
else
  bad "cold start runs the command synchronously and prints its output" \
    "out=[$out] calls=$(call_count "$counter")"
fi

# ---------------------------------------------------------------- case 2 --
# Warm hit inside the TTL: cached payload is printed, command is not re-run.
d=$(new_case_dir)
CACHE_DIR="$d/cache"
counter="$d/counter"
output="$d/output"
printf 'A' >"$output"
cache_get "k2" 1000 fake_segment "$counter" "$output" >/dev/null
before=$(call_count "$counter")
out=$(cache_get "k2" 1000 fake_segment "$counter" "$output")
if [ "$out" = "HA" ] && [ "$(call_count "$counter")" = "$before" ]; then
  ok "warm hit inside TTL serves cache without re-running the command"
else
  bad "warm hit inside TTL serves cache without re-running the command" \
    "out=[$out] before=$before after=$(call_count "$counter")"
fi

# ---------------------------------------------------------------- case 3 --
# TTL expired: the stale payload is still what's printed this call, and a
# refresh fires (payload changes once the background refresh lands).
d=$(new_case_dir)
CACHE_DIR="$d/cache"
mkdir -p "$CACHE_DIR"
counter="$d/counter"
output="$d/output"
printf 'NEW' >"$output"
old_ts=$(($(date +%s) - 1000))
printf '%s\nOLD' "$old_ts" >"$CACHE_DIR/k3"
before=$(call_count "$counter")
out=$(cache_get "k3" 5 fake_segment "$counter" "$output")
immediate_ok=1
[ "$out" = "OLD" ] || immediate_ok=0
if poll_until 40 0.05 payload_is "$CACHE_DIR/k3" "HNEW" &&
  [ "$(call_count "$counter")" != "$before" ] && [ "$immediate_ok" = 1 ]; then
  ok "expired TTL still serves the stale payload and refreshes in the background"
else
  bad "expired TTL still serves the stale payload and refreshes in the background" \
    "out=[$out] payload=[$(cache_payload "$CACHE_DIR/k3")]"
fi

# ---------------------------------------------------------------- case 3b -
# The explicit regression assertion: a post-TTL background refresh of a
# shell-function command must write a NON-EMPTY payload. This is the
# assertion that would have caught cache_refresh detaching into a fresh
# `bash -c`, which inherits no shell functions — the refresh's command
# fails "command not found", the failure is swallowed by 2>/dev/null, and
# the pre-fix code still wrote a fresh timestamp with an EMPTY payload,
# permanently blanking the segment. It is kept separate from case 3 above
# so a future change to case 3's exact string can't accidentally weaken
# this guarantee.
d=$(new_case_dir)
CACHE_DIR="$d/cache"
mkdir -p "$CACHE_DIR"
counter="$d/counter"
output="$d/output"
printf 'PAYLOAD' >"$output"
old_ts=$(($(date +%s) - 1000))
# Seed the cache already-blanked (empty payload, expired timestamp) — the
# exact state a prior bad refresh under the bug left behind. A vacuous
# version of this check that seeds a non-empty stale value (like case 3
# does) would trivially "pass" even with no refresh at all, since the
# untouched stale value is itself non-empty; seeding empty here means the
# only way this can pass is if the background refresh actually ran and
# wrote something.
printf '%s\n' "$old_ts" >"$CACHE_DIR/k3b"
out=$(cache_get "k3b" 5 fake_segment "$counter" "$output")
refreshed() { [ -n "$(cache_payload "$CACHE_DIR/k3b")" ]; }
if poll_until 40 0.05 refreshed; then
  ok "post-TTL background refresh of a shell-function command writes a non-empty payload"
else
  bad "post-TTL background refresh of a shell-function command writes a non-empty payload" \
    "payload=[$(cache_payload "$CACHE_DIR/k3b")] (background refresh never produced output)"
fi

# ---------------------------------------------------------------- case 4 --
# Corrupt cache file degrades to empty output, no crash, no stderr.
for variant in zero-byte single-line; do
  d=$(new_case_dir)
  CACHE_DIR="$d/cache"
  mkdir -p "$CACHE_DIR"
  counter="$d/counter"
  output="$d/output"
  printf 'irrelevant' >"$output"
  errfile="$d/err"
  if [ "$variant" = zero-byte ]; then
    : >"$CACHE_DIR/k4"
  else
    printf '123456' >"$CACHE_DIR/k4" # one line, no payload
  fi
  out=$(cache_get "k4" 100000 fake_segment "$counter" "$output" 2>"$errfile")
  if [ -z "$out" ] && [ ! -s "$errfile" ]; then
    ok "corrupt cache ($variant) degrades to empty output, no stderr"
  else
    bad "corrupt cache ($variant) degrades to empty output, no stderr" \
      "out=[$out] err=[$(cat "$errfile")]"
  fi
done

# ---------------------------------------------------------------- case 5 --
# Stale lock: a lock dir older than the grace period is reclaimed and a
# refresh fires.
d=$(new_case_dir)
CACHE_DIR="$d/cache"
mkdir -p "$CACHE_DIR"
counter="$d/counter"
output="$d/output"
printf 'NEW' >"$output"
old_ts=$(($(date +%s) - 1000))
printf '%s\nOLD' "$old_ts" >"$CACHE_DIR/k5"
mkdir -p "$CACHE_DIR/k5.lock"
touch -d "@$(($(date +%s) - 120))" "$CACHE_DIR/k5.lock"
before=$(call_count "$counter")
out=$(cache_get "k5" 5 fake_segment "$counter" "$output")
immediate_ok=1
[ "$out" = "OLD" ] || immediate_ok=0
if poll_until 40 0.05 payload_is "$CACHE_DIR/k5" "HNEW" &&
  [ "$(call_count "$counter")" != "$before" ] && [ "$immediate_ok" = 1 ]; then
  ok "stale lock is reclaimed and a refresh fires"
else
  bad "stale lock is reclaimed and a refresh fires" \
    "out=[$out] payload=[$(cache_payload "$CACHE_DIR/k5")]"
fi

# ---------------------------------------------------------------- case 6 --
# Fresh lock: a lock dir created just now blocks the refresh; the stale
# payload is still what's printed.
d=$(new_case_dir)
CACHE_DIR="$d/cache"
mkdir -p "$CACHE_DIR"
counter="$d/counter"
output="$d/output"
printf 'NEW' >"$output"
old_ts=$(($(date +%s) - 1000))
printf '%s\nOLD' "$old_ts" >"$CACHE_DIR/k6"
mkdir -p "$CACHE_DIR/k6.lock"
before=$(call_count "$counter")
out=$(cache_get "k6" 5 fake_segment "$counter" "$output")
sleep 0.3
if [ "$out" = "OLD" ] && [ "$(call_count "$counter")" = "$before" ] &&
  [ "$(cache_payload "$CACHE_DIR/k6")" = "OLD" ]; then
  ok "fresh lock blocks the refresh, stale payload still served"
else
  bad "fresh lock blocks the refresh, stale payload still served" \
    "out=[$out] payload=[$(cache_payload "$CACHE_DIR/k6")]"
fi

# ---------------------------------------------------------------- case 7 --
# End-to-end: cache_get driving the REAL git_segment (not a fake stand-in),
# across a TTL expiry, against a real throwaway git repo. This is the exact
# production path cache_refresh's `bash -c` bug silently broke: git_segment
# calls worktree_name (another shell function) and references the C_*
# color globals, none of which a freshly spawned `bash -c` inherits.
d=$(new_case_dir)
CACHE_DIR="$d/cache"
mkdir -p "$CACHE_DIR"
repo="$d/repo"
mkdir -p "$repo"
git -c init.defaultBranch=e2e-branch -c commit.gpgsign=false init -q "$repo"
git -C "$repo" -c commit.gpgsign=false -c user.name=Test -c user.email=test@example.com \
  commit -q --allow-empty -m init

old_ts=$(($(date +%s) - 1000))
printf '%s\nOLD' "$old_ts" >"$CACHE_DIR/gite2e"
out=$(cache_get "gite2e" 5 git_segment "$repo")
immediate_ok=1
[ "$out" = "OLD" ] || immediate_ok=0
gitcache_refreshed() {
  case "$(cache_payload "$CACHE_DIR/gite2e")" in *e2e-branch*) return 0 ;; esac
  return 1
}
if poll_until 40 0.05 gitcache_refreshed && [ "$immediate_ok" = 1 ]; then
  ok "real git_segment through cache_get still renders the branch after a TTL-triggered background refresh"
else
  bad "real git_segment through cache_get still renders the branch after a TTL-triggered background refresh" \
    "out=[$out] payload=[$(cache_payload "$CACHE_DIR/gite2e")]"
fi

# ---------------------------------------------------------------- case 8 --
# git_segment's own `timeout 1` on the `git status` call is what stops a
# hung or slow git from blocking a render indefinitely. A fake `git` on
# PATH sleeps past that budget, then would have produced perfectly good
# porcelain output — this is the regression test for a mutation that drops
# `timeout 1` from the git status invocation: without it, this case would
# wait out the full sleep and render a branch instead of staying silent.
# The 2-second assertion budget is well short of the 5-second sleep, so a
# passing run proves the timeout actually fired rather than the fake git
# finishing on its own.
d=$(new_case_dir)
bin="$d/bin"
mkdir -p "$bin"
cat >"$bin/git" <<'EOF'
#!/bin/bash
while [ "${1:-}" = "-C" ]; do shift 2; done
case "$1 ${2:-}" in
  "status --porcelain=v2")
    sleep 5
    printf '# branch.head slow-branch\n'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin/git"
start_ts=$(date +%s)
out=$(PATH="$bin:$PATH" git_segment "$d/repo" 2>"$d/err")
rc=$?
elapsed=$(($(date +%s) - start_ts))
if [ -z "$out" ] && [ "$rc" = 0 ] && [ ! -s "$d/err" ] && [ "$elapsed" -le 2 ]; then
  ok "git_segment: slower-than-timeout git status stays silent well before it would finish"
else
  bad "git_segment: slower-than-timeout git status stays silent well before it would finish" \
    "out=[$out] rc=$rc err=[$(cat "$d/err")] elapsed=${elapsed}s"
fi

# ---------------------------------------------------------------- case 9 --
# dir_hash must not collide across distinct directories. The pre-fix key
# was the naive `${dir//\//_}`, which flattens every "/" to "_" — a
# directory path ".../a/b" and a sibling literally named ".../a_b" both
# flatten to the identical key. This is the regression test for reverting
# dir_hash back to that scheme: it plants exactly that colliding pair, each
# a real git repo with its own distinct branch, and asserts both that the
# hashes differ and that cache_get, keyed on those hashes, serves each
# directory's own branch rather than a collided neighbor's.
d=$(new_case_dir)
dir_ab="$d/a/b"
dir_a_b="$d/a_b"
mkdir -p "$dir_ab" "$dir_a_b"
git -c init.defaultBranch=branch-ab -c commit.gpgsign=false init -q "$dir_ab"
git -C "$dir_ab" -c commit.gpgsign=false -c user.name=Test -c user.email=test@example.com \
  commit -q --allow-empty -m init
git -c init.defaultBranch=branch-a_b -c commit.gpgsign=false init -q "$dir_a_b"
git -C "$dir_a_b" -c commit.gpgsign=false -c user.name=Test -c user.email=test@example.com \
  commit -q --allow-empty -m init

hash_ab=$(dir_hash "$dir_ab")
hash_a_b=$(dir_hash "$dir_a_b")
if [ -n "$hash_ab" ] && [ -n "$hash_a_b" ] && [ "$hash_ab" != "$hash_a_b" ]; then
  ok "dir_hash: sibling paths that collide under the naive scheme hash distinctly"
else
  bad "dir_hash: sibling paths that collide under the naive scheme hash distinctly" \
    "hash_ab=[$hash_ab] hash_a_b=[$hash_a_b]"
fi

CACHE_DIR="$d/cache"
out_ab=$(cache_get "git$hash_ab" 100 git_segment "$dir_ab")
out_a_b=$(cache_get "git$hash_a_b" 100 git_segment "$dir_a_b")
ok_ab=0
ok_a_b=0
case "$out_ab" in *branch-ab*) ok_ab=1 ;; esac
case "$out_a_b" in *branch-a_b*) ok_a_b=1 ;; esac
if [ "$ok_ab" = 1 ] && [ "$ok_a_b" = 1 ]; then
  ok "dir_hash: distinct cache keys serve each directory's own branch, not a collided neighbor's"
else
  bad "dir_hash: distinct cache keys serve each directory's own branch, not a collided neighbor's" \
    "out_ab=[$out_ab] out_a_b=[$out_a_b]"
fi

# --------------------------------------------------------------- case 10 --
# A stale-but-good payload must eventually expire once its underlying data
# is genuinely gone forever, rather than being defended across every
# refresh indefinitely. This is the regression test for two mutations that
# both defeat CACHE_EMPTY_RETRIES: reverting the `misses -lt
# CACHE_EMPTY_RETRIES` guard to `if true` (defends unconditionally), or
# bumping CACHE_EMPTY_RETRIES itself to something enormous (same effect via
# the threshold rather than the comparison). The round count below is
# fixed at 5, deliberately NOT derived from this file's own
# CACHE_EMPTY_RETRIES: driving it from the sourced value would make this
# loop run 100000 times under the "bump the constant" mutation instead of
# catching it quickly. 5 rounds is comfortably more than the real
# CACHE_EMPTY_RETRIES=3 needs to expire, so a correct script always passes
# well within the budget, and a mutated one that needs far more than 5
# misses to expire (or never expires at all) still fails.
d=$(new_case_dir)
CACHE_DIR="$d/cache"
mkdir -p "$CACHE_DIR"
modefile="$d/mode"
fake_expiring_segment() {
  local mf=$1
  if [ -f "$mf" ] && [ "$(<"$mf")" = empty ]; then
    printf ''
  else
    printf 'GOODVAL'
  fi
}

cache_get "k10" 100000 fake_expiring_segment "$modefile" >/dev/null
if [ "$(cache_payload "$CACHE_DIR/k10")" = "GOODVAL" ]; then
  ok "expiry setup: cache seeded with a real value"
else
  bad "expiry setup: cache seeded with a real value" \
    "payload=[$(cache_payload "$CACHE_DIR/k10")]"
fi

# The underlying data is now "gone": every subsequent refresh comes back
# empty. Force TTL expiry on 5 consecutive renders by rewinding the cache
# file's timestamp before each one, mirroring how a real render sees an
# expired cache once the TTL elapses.
printf 'empty' >"$modefile"
for _ in 1 2 3 4 5; do
  old_ts=$(($(date +%s) - 1000))
  cur_payload=$(cache_payload "$CACHE_DIR/k10")
  printf '%s\n%s' "$old_ts" "$cur_payload" >"$CACHE_DIR/k10"
  cache_get "k10" 5 fake_expiring_segment "$modefile" >/dev/null
  round_done() { [ "$(refresh_ts "$CACHE_DIR/k10")" != "$old_ts" ]; }
  poll_until 40 0.05 round_done
done
if [ -z "$(cache_payload "$CACHE_DIR/k10")" ]; then
  ok "stale payload expires after enough consecutive empty refreshes"
else
  bad "stale payload expires after enough consecutive empty refreshes" \
    "payload=[$(cache_payload "$CACHE_DIR/k10")]"
fi

# --------------------------------------------------------------- case 11 --
# join_segments must strip embedded newlines (not just carriage returns)
# from every segment payload. Regression test for deleting the
# `s=${s//$'\n'/}` line: a segment containing an embedded LF (a hostile
# caveman-plugin hook, a directory name that somehow carries one) would
# inject an extra visual line into a statusline that promises exactly two,
# which is asserted here directly via the joined output's line count.
out=$(join_segments '  ' "$(printf 'line1\nline2')" "tail")
lines=$(printf '%s' "$out" | wc -l | tr -d ' ')
if [ "$lines" = 0 ] && [ "$out" = "line1line2  tail" ]; then
  ok "join_segments strips embedded newlines out of a segment payload"
else
  bad "join_segments strips embedded newlines out of a segment payload" \
    "out=[$(printf '%s' "$out" | tr '\n' '|')] lines=$lines"
fi

# --------------------------------------------------------------- case 12 --
# Finding 2: an unwritable `.misses` companion file must not defend a stale
# payload forever just because the miss counter can never be persisted past
# its first read. This reproduces the exact shape of a leftover
# foreign-owned `.misses` file in a shared CACHE_DIR when XDG_RUNTIME_DIR is
# unset — `printf ... >"$missfile" 2>/dev/null` fails silently every round,
# so a version that only guards on `misses -lt CACHE_EMPTY_RETRIES` (without
# also requiring the write to have succeeded) re-reads the same
# never-advanced counter as "still under the limit" forever. The fix fails
# toward expiring instead: the payload must be empty well before 5 rounds.
d=$(new_case_dir)
CACHE_DIR="$d/cache"
mkdir -p "$CACHE_DIR"
fake_empty_segment() { printf ''; }

printf '%s\nGOODVAL' "$(date +%s)" >"$CACHE_DIR/k12"
: >"$CACHE_DIR/k12.misses"
chmod 444 "$CACHE_DIR/k12.misses"

for _ in 1 2 3 4 5; do
  old_ts=$(($(date +%s) - 1000))
  cur_payload=$(cache_payload "$CACHE_DIR/k12")
  printf '%s\n%s' "$old_ts" "$cur_payload" >"$CACHE_DIR/k12"
  cache_get "k12" 5 fake_empty_segment >/dev/null
  round_done() { [ "$(refresh_ts "$CACHE_DIR/k12")" != "$old_ts" ]; }
  poll_until 40 0.05 round_done
done
chmod 644 "$CACHE_DIR/k12.misses" 2>/dev/null || true
if [ -z "$(cache_payload "$CACHE_DIR/k12")" ]; then
  ok "unwritable .misses file fails toward expiring the stale payload, not defending it forever"
else
  bad "unwritable .misses file fails toward expiring the stale payload, not defending it forever" \
    "payload=[$(cache_payload "$CACHE_DIR/k12")]"
fi

exit "$fail"
