#!/usr/bin/env bash
# Drives the statusline with fixture JSON on stdin and diffs the
# ANSI-stripped output against the recorded expectation.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
script="$repo/dot_claude/executable_statusline.sh"

# Stubs let a fixture decide whether git/ccusage exist and what they say.
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

fail=0
for fixture in "$here"/fixtures/*.json; do
  name=$(basename "$fixture" .json)
  expected="$here/fixtures/$name.expected"

  # Per-fixture stub setup: fixtures/<name>.stub is sourced if present and
  # may create fake git/ccusage executables in $stub_dir.
  rm -rf "${stub_dir:?}"/*
  if [ -f "$here/fixtures/$name.stub" ]; then
    # shellcheck disable=SC1090
    STUB_DIR="$stub_dir" source "$here/fixtures/$name.stub"
  fi

  actual=$(
    PATH="$stub_dir:$PATH" \
    HOME=/home/tester \
    XDG_RUNTIME_DIR="$stub_dir/cache" \
    DEVPOD_WORKSPACE_ID="" \
      bash "$script" <"$fixture" 2>/dev/null |
      sed $'s/\033\\[[0-9;]*m//g'
  )

  if [ "$actual" = "$(cat "$expected")" ]; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
    printf '  expected: %s\n' "$(cat "$expected" | tr '\n' '|')"
    printf '  actual:   %s\n' "$(printf '%s' "$actual" | tr '\n' '|')"
    fail=1
  fi
done

exit "$fail"
