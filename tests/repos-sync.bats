#!/usr/bin/env bats
#
# repos-sync clones the personal repos that aren't checked out yet. It had no
# tests and no argument handling, which combined into the finding this file
# opens with: `repos-sync --help` did not print help, it cloned six
# repositories from GitHub.
#
# git is stubbed. A test that used the real one would clone this developer's
# actual repositories into a temp directory over the network, which is both slow
# and exactly the behaviour under test.

bats_require_minimum_version 1.5.0

setup() {
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_repos-sync"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"
	GIT_LOG="$BATS_TEST_TMPDIR/git.log"
	: >"$GIT_LOG"

	ROOT="$BATS_TEST_TMPDIR/Projects"
	mkdir -p "$ROOT"

	# `git clone <url> <target>` is the only form the script uses. The stub
	# creates the .git directory the script's own "already present" test looks
	# for, so a second run sees what a real clone would have left.
	cat >"$BIN/git" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$GIT_LOG"
if [ "$1" = "clone" ]; then
	target=""
	for a in "$@"; do target="$a"; done
	case " ${CLONE_FAIL:-} " in *" $target "*) exit 1 ;; esac
	case "$(basename "$target")" in
	${CLONE_FAIL_REPO:-__none__}) exit 1 ;;
	esac
	mkdir -p "$target/.git"
fi
exit 0
STUB
	chmod 755 "$BIN/git"

	export HOME GIT_LOG
}

# Everything before a literal `--` is an env assignment; everything after is an
# argument for the script itself.
run_sync() {
	local envs=() args=() past=0 arg
	for arg in "$@"; do
		if [ "$arg" = "--" ]; then past=1; continue; fi
		if [ "$past" = 0 ]; then envs+=("$arg"); else args+=("$arg"); fi
	done
	run env HOME="$HOME" PATH="$BIN:$PATH" GIT_LOG="$GIT_LOG" \
		XDG_PROJECTS_DIR="$ROOT" ${envs[@]+"${envs[@]}"} \
		bash "$SCRIPT" ${args[@]+"${args[@]}"} </dev/null
}

# --- the finding --------------------------------------------------------------

# Asking a command what it does must never be the thing that makes it do it.
@test "--help prints usage and clones nothing" {
	run_sync -- --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: repos-sync"* ]]
	[ ! -s "$GIT_LOG" ]
	[ -z "$(ls -A "$ROOT")" ]
}

@test "-h does the same" {
	run_sync -- -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: repos-sync"* ]]
	[ ! -s "$GIT_LOG" ]
}

# The other half of the same mistake: an unrecognised flag used to be ignored
# and the clone ran anyway, so a typo'd option did the full job silently.
@test "an unknown argument is refused, not ignored" {
	run_sync -- --dry-run
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown argument"* ]]
	[ ! -s "$GIT_LOG" ]
	[ -z "$(ls -A "$ROOT")" ]
}

# --- the job it actually does -------------------------------------------------

@test "clones the repos that are not checked out" {
	run_sync
	[ "$status" -eq 0 ]
	[ -d "$ROOT/github.com/ronaldlokers/homelab/.git" ]
	[ -d "$ROOT/github.com/ronaldlokers/lab/.git" ]
	[[ "$output" == *"6 cloned"* ]]
}

@test "clones over HTTPS, not SSH" {
	run_sync
	[ "$status" -eq 0 ]
	# the gh credential helper authenticates HTTPS, and this machine has no SSH
	# auth key — only a signing key
	grep -q "https://github.com/ronaldlokers/homelab.git" "$GIT_LOG"
	! grep -q "git@" "$GIT_LOG"
}

@test "keeps the host/owner/repo layout" {
	run_sync
	[ "$status" -eq 0 ]
	[ -d "$ROOT/github.com/ronaldlokers" ]
}

# The rule the script leads with: an existing checkout is left alone, branch,
# remotes and uncommitted work included.
@test "an existing checkout is skipped, not touched" {
	mkdir -p "$ROOT/github.com/ronaldlokers/homelab/.git"
	printf 'MINE\n' >"$ROOT/github.com/ronaldlokers/homelab/uncommitted"
	run_sync
	[ "$status" -eq 0 ]
	[ "$(cat "$ROOT/github.com/ronaldlokers/homelab/uncommitted")" = "MINE" ]
	! grep -q "homelab" "$GIT_LOG"
	[[ "$output" == *"1 already present"* ]]
}

@test "a second run clones nothing" {
	run_sync
	[ "$status" -eq 0 ]
	: >"$GIT_LOG"
	run_sync
	[ "$status" -eq 0 ]
	[ ! -s "$GIT_LOG" ]
	[[ "$output" == *"0 cloned, 6 already present"* ]]
}

# --- failure handling ---------------------------------------------------------

@test "a failed clone is reported and exits non-zero" {
	run_sync CLONE_FAIL_REPO="lab" --
	[ "$status" -ne 0 ]
	[[ "$output" == *"failed:"* ]]
	[[ "$output" == *"lab"* ]]
}

# A partial directory would be mistaken for a real checkout by the next run's
# .git test, and then never retried.
@test "a failed clone leaves nothing behind for the next run to skip" {
	run_sync CLONE_FAIL_REPO="lab" --
	[ "$status" -ne 0 ]
	[ ! -e "$ROOT/github.com/ronaldlokers/lab" ]
}

@test "one failed clone does not stop the others" {
	run_sync CLONE_FAIL_REPO="lab" --
	[ "$status" -ne 0 ]
	[ -d "$ROOT/github.com/ronaldlokers/homelab/.git" ]
	[ -d "$ROOT/github.com/ronaldlokers/Zenith/.git" ]
}
