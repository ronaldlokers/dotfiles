#!/usr/bin/env bash
# Drives the statusline with fixture JSON on stdin and diffs the
# ANSI-stripped output against the recorded expectation.
#
# Output is captured byte-exact, not through a bare `actual=$(...)`: plain
# command substitution strips *every* trailing newline, which made the
# harness blind to trailing-newline mutants (e.g. the final `printf '%s'
# "$line2"` gaining a `\n`) — both sides got stripped equally, so the diff
# vanished. The `printf 'X'` sentinel trick below defeats that: appending a
# non-newline byte after the real output means $(...) only ever strips the
# sentinel's own absence-of-trailing-newline, never a newline that was
# actually part of the output, so trailing newlines (and their absence) are
# preserved for comparison. Line count is asserted explicitly too, so a
# mismatch is diagnosed as a line-structure problem rather than just an
# opaque string diff. stderr is captured separately and asserted empty for
# every fixture, since "no stderr" is part of the script's contract and a
# silenced `2>/dev/null` on the driver would hide any regression that
# leaked to stderr (a dropped `timeout 1`, a removed `command -v` guard, a
# stray debug `echo >&2`).
#
# fixtures/newline-field.json is the regression test for reverting the
# top-level stdin parse from NUL-delimited (`mapfile -d '' -t` + `jq -j`
# with `([0] | implode)` separators) back to newline-delimited (`mapfile
# -t` + `jq -r`): a field value containing a raw embedded newline (here,
# model.display_name) produces one extra physical line, which shifts every
# field read after it — dir becomes the second half of the model name,
# style becomes the empty dir, pct becomes the style string (hidden as
# non-numeric), cost becomes the pct number, and duration is lost
# entirely. No existing fixture's field values contain an embedded
# newline, so this was otherwise unguarded even though it is the exact
# mechanism the NUL-delimited parse exists to fix.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
script="$repo/dot_claude/executable_statusline.sh"

# Stubs let a fixture decide whether git/ccusage exist and what they say.
stub_dir=$(mktemp -d)
err_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir" "$err_dir"' EXIT

# capture_exact <out-var> <fixture> <errfile> — sets <out-var> to
# ANSI-stripped stdout with every trailing newline preserved (see file
# header for why this can't be a plain `$(...)`). Assigns via `printf -v`
# rather than returning through `printf '%s' ...` for the caller to
# recapture with its own `$(...)`: wrapping this function's own output in
# a second layer of command substitution would strip the very trailing
# newline the sentinel trick just went to the trouble of preserving —
# exactly the bug this rewrite exists to avoid, so there must be only one
# `$(...)` between the real output and the variable that holds it.
capture_exact() {
  local -n _capture_out=$1
  local fixture=$2 errfile=$3 raw
  raw=$(
    {
      PATH="$stub_dir:$PATH" \
        HOME=/home/tester \
        XDG_RUNTIME_DIR="$stub_dir/cache" \
        DEVPOD_WORKSPACE_ID="${FIXTURE_DEVPOD:-}" \
        bash "$script" <"$fixture" 2>"$errfile" | sed $'s/\033\\[[0-9;]*m//g'
      printf 'X'
    }
  )
  _capture_out=${raw%X}
}

# Same sentinel trick applied to the expected file, so a difference in
# trailing-newline count between actual and expected can never be masked by
# both sides independently losing theirs to command substitution.
read_expected() {
  local -n _expected_out=$1
  local raw
  raw=$(cat "$2"; printf 'X')
  _expected_out=${raw%X}
}

count_lines() {
  # Number of lines: 0 for empty input, else 1 + number of embedded
  # newlines (a trailing newline does NOT count an extra line — that
  # matches the script's own two-line contract, where line2 never ends in
  # one). Pure parameter expansion, no subprocess: strip every non-newline
  # character and count what is left.
  local s=$1 newlines_only
  [ -n "$s" ] || { printf '0'; return; }
  newlines_only=${s//[^$'\n']/}
  printf '%s' "$((1 + ${#newlines_only}))"
}

fail=0
for fixture in "$here"/fixtures/*.json; do
  name=$(basename "$fixture" .json)
  expected="$here/fixtures/$name.expected"
  errfile="$err_dir/$name.err"

  # Per-fixture stub setup: fixtures/<name>.stub is sourced if present and
  # may create fake git/ccusage executables in $stub_dir.
  rm -rf "${stub_dir:?}"/*
  FIXTURE_DEVPOD=""
  if [ -f "$here/fixtures/$name.stub" ]; then
    # shellcheck disable=SC1090
    STUB_DIR="$stub_dir" source "$here/fixtures/$name.stub"
  fi

  capture_exact actual "$fixture" "$errfile"
  read_expected expected_content "$expected"

  problems=()
  # shellcheck disable=SC2154 # actual/expected_content are set via nameref above
  [ "$actual" = "$expected_content" ] || problems+=("output mismatch")
  if [ -s "$errfile" ]; then
    problems+=("stderr not empty ($(wc -c <"$errfile" | tr -d ' ') bytes)")
  fi
  actual_lines=$(count_lines "$actual")
  expected_lines=$(count_lines "$expected_content")
  [ "$actual_lines" = "$expected_lines" ] ||
    problems+=("line count $actual_lines != expected $expected_lines")

  if [ "${#problems[@]}" -eq 0 ]; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s: %s\n' "$name" "${problems[*]}"
    printf '  expected: %s\n' "$(printf '%s' "$expected_content" | tr '\n' '|')"
    printf '  actual:   %s\n' "$(printf '%s' "$actual" | tr '\n' '|')"
    if [ -s "$errfile" ]; then
      printf '  stderr:   %s\n' "$(tr '\n' '|' <"$errfile")"
    fi
    fail=1
  fi
done

exit "$fail"
