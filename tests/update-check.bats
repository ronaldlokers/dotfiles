#!/usr/bin/env bats
#
# dotfiles-update-check notifies when the repo has commits this machine has not
# applied. It had no tests and no argument handling, so `--help` did not print
# help — it reached the network and ran a fetch. Same mistake as repos-sync,
# and the same correction.
#
# These cover the argument handling only. The fetch-and-compare logic wants a
# real repo with a real upstream, which is a bigger fixture than the finding
# this file closes needs.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	TMPL="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_dotfiles-update-check.tmpl"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"
	GIT_LOG="$BATS_TEST_TMPDIR/git.log"
	: >"$GIT_LOG"

	# Records rather than acts. Anything that reaches git here is the bug.
	cat >"$BIN/git" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$GIT_LOG"
exit 0
STUB
	chmod 755 "$BIN/git"
	make_notify_send_stub "$BIN"
	NOTIFY_LOG="$BATS_TEST_TMPDIR/notify.log"
	: >"$NOTIFY_LOG"

	SCRIPT="$BATS_TEST_TMPDIR/update-check.sh"
	render_template "$TMPL" "$SCRIPT" "$BIN:$PATH"

	export HOME GIT_LOG NOTIFY_LOG
}

run_update_check() {
	run env HOME="$HOME" PATH="$BIN:$PATH" GIT_LOG="$GIT_LOG" \
		NOTIFY_LOG="$NOTIFY_LOG" bash "$SCRIPT" "$@" </dev/null
}

@test "--help prints usage and touches no network" {
	run_update_check --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: dotfiles-update-check"* ]]
	[ ! -s "$GIT_LOG" ]
}

@test "-h does the same" {
	run_update_check -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: dotfiles-update-check"* ]]
	[ ! -s "$GIT_LOG" ]
}

@test "an unknown argument is refused, not ignored" {
	run_update_check --pull
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown argument"* ]]
	[ ! -s "$GIT_LOG" ]
}

# The property the script leads with, and the reason it is safe on a timer:
# read-only. `--pull` above is not a real flag, and must never become one by
# accident — but this pins the stronger claim, that no invocation of it applies
# anything.
@test "never pulls or applies" {
	! grep -qE '^[[:space:]]*(git .*pull|chezmoi (apply|update))' "$SCRIPT"
}
