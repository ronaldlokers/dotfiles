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

# A real executable (not a shell function): cache_refresh's detached refresh
# runs in a brand-new `bash -c`, which does not inherit this shell's
# functions, so the fake command has to be reachable on PATH.
bin_dir=$(mktemp -d)
cat >"$bin_dir/fakecmd" <<'EOF'
#!/usr/bin/env bash
# args: <counter-file> <output-file>
# Appends one line per invocation (proves call count) and prints the
# current contents of <output-file> as the "rendered" payload.
set -euo pipefail
counter=$1
output=$2
printf 'x\n' >>"$counter"
[ -f "$output" ] && cat "$output"
exit 0
EOF
chmod +x "$bin_dir/fakecmd"
PATH="$bin_dir:$PATH"

work=$(mktemp -d)
trap 'rm -rf "$bin_dir" "$work"' EXIT

new_case_dir() {
  mktemp -d -p "$work"
}

call_count() {
  [ -f "$1" ] && wc -l <"$1" | tr -d ' ' || printf '0'
}

count_changed() {
  [ "$(call_count "$1")" != "$2" ]
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
  local f=$1 raw
  [ -f "$f" ] || return 0
  raw=$(<"$f")
  printf '%s' "${raw#*$'\n'}"
}

# ---------------------------------------------------------------- case 1 --
# Cold start with an empty cache: runs the command synchronously and prints
# its output.
d=$(new_case_dir)
CACHE_DIR="$d/cache"
counter="$d/counter"
output="$d/output"
printf 'hello' >"$output"
out=$(cache_get "k1" 100 fakecmd "$counter" "$output")
if [ "$out" = "hello" ] && [ "$(call_count "$counter")" = "1" ]; then
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
cache_get "k2" 1000 fakecmd "$counter" "$output" >/dev/null
before=$(call_count "$counter")
out=$(cache_get "k2" 1000 fakecmd "$counter" "$output")
if [ "$out" = "A" ] && [ "$(call_count "$counter")" = "$before" ]; then
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
out=$(cache_get "k3" 5 fakecmd "$counter" "$output")
immediate_ok=1
[ "$out" = "OLD" ] || immediate_ok=0
if poll_until 40 0.05 count_changed "$counter" "$before" &&
  [ "$(cache_payload "$CACHE_DIR/k3")" = "NEW" ] && [ "$immediate_ok" = 1 ]; then
  ok "expired TTL still serves the stale payload and refreshes in the background"
else
  bad "expired TTL still serves the stale payload and refreshes in the background" \
    "out=[$out] payload=[$(cache_payload "$CACHE_DIR/k3")]"
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
  out=$(cache_get "k4" 100000 fakecmd "$counter" "$output" 2>"$errfile")
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
out=$(cache_get "k5" 5 fakecmd "$counter" "$output")
immediate_ok=1
[ "$out" = "OLD" ] || immediate_ok=0
if poll_until 40 0.05 count_changed "$counter" "$before" &&
  [ "$(cache_payload "$CACHE_DIR/k5")" = "NEW" ] && [ "$immediate_ok" = 1 ]; then
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
out=$(cache_get "k6" 5 fakecmd "$counter" "$output")
sleep 0.3
if [ "$out" = "OLD" ] && [ "$(call_count "$counter")" = "$before" ] &&
  [ "$(cache_payload "$CACHE_DIR/k6")" = "OLD" ]; then
  ok "fresh lock blocks the refresh, stale payload still served"
else
  bad "fresh lock blocks the refresh, stale payload still served" \
    "out=[$out] payload=[$(cache_payload "$CACHE_DIR/k6")]"
fi

exit "$fail"
