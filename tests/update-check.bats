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

# --- what it actually does (N26) ---------------------------------------------
#
# Everything above tests the argument parsing, and the read-only claim was
# tested by grepping the script's own source — which asserts a string is absent,
# not that a behaviour is. The comparison logic had no coverage at all: the
# ahead/behind arithmetic, the three silent early exits, and the wording of the
# only thing this program ever produces.
#
# The fixture is a real repo with a real upstream, because that is what the
# script reads. The template bakes in .chezmoi.sourceDir, so it is rendered
# against the fixture rather than against this checkout.

# Builds an origin plus a working clone and prints the clone's path. $1 is how
# many upstream commits the clone is missing.
make_tracked_clone() {
	local behind="${1:-0}" root="$BATS_TEST_TMPDIR/fixture" i
	rm -rf "$root"
	mkdir -p "$root"

	# -b main, explicitly. A bare init takes its default branch name from
	# init.defaultBranch, which is `main` on this machine and `master` on the
	# runner — so `push origin main` below found no such local branch and the
	# whole fixture came up empty in CI while passing locally. Nothing about
	# these tests should depend on a git default that varies by host.
	git init -q --bare -b main "$root/origin.git"
	# Same reasoning: name the branch rather than inheriting one. A clone of an
	# empty bare repo takes its branch name from the *local* default too.
	git clone -q "$root/origin.git" "$root/seed"
	git -C "$root/seed" checkout -q -b main
	git -C "$root/seed" config user.email t@example.com
	git -C "$root/seed" config user.name t
	printf 'base\n' >"$root/seed/f"
	git -C "$root/seed" add f
	git -C "$root/seed" commit -qm base
	git -C "$root/seed" push -q origin HEAD:refs/heads/main

	git clone -q -b main "$root/origin.git" "$root/work"
	git -C "$root/work" config user.email t@example.com
	git -C "$root/work" config user.name t

	for ((i = 0; i < behind; i++)); do
		printf 'c%s\n' "$i" >>"$root/seed/f"
		git -C "$root/seed" commit -qam "c$i"
	done
	[ "$behind" -eq 0 ] || git -C "$root/seed" push -q origin HEAD:refs/heads/main

	printf '%s\n' "$root/work"
}

# Renders and runs against the fixture, with a real git — the stub in setup()
# answers everything with exit 0, which is exactly wrong for testing a
# comparison. notify-send stays stubbed.
run_against() {
	local work="$1"
	shift
	local script="$BATS_TEST_TMPDIR/behaviour.sh"
	local realbin="$BATS_TEST_TMPDIR/realbin"
	mkdir -p "$realbin"
	make_notify_send_stub "$realbin"
	make_dotfiles_status_stub "$realbin"
	render_template "$TMPL" "$script" "$PATH" "$work"
	# -u XDG_STATE_HOME is not tidiness. The health block below writes its
	# debounce record to $XDG_STATE_HOME/dotfiles/last-notified, and this
	# desktop exports that variable — so without this a test that makes the
	# check fail writes into the developer's real state directory, and reads
	# back whatever is already there. Clearing it puts the record under the
	# test HOME with everything else.
	#
	# The stub directory goes first for the mirror-image reason: a developer
	# machine has a real dotfiles-status on PATH, which answers from the real
	# machine's recorded state. These tests passed here and skipped the block
	# entirely in CI, where nothing is installed.
	run env -u XDG_STATE_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
		-u XDG_CACHE_HOME \
		HOME="$HOME" NOTIFY_LOG="$NOTIFY_LOG" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=$BATS_TEST_TMPDIR/fake-bus" \
		PATH="$realbin:$PATH" "$@" bash "$script" </dev/null
}

@test "says how many commits are waiting" {
	work="$(make_tracked_clone 2)"
	run_against "$work"
	[ "$status" -eq 0 ]
	[[ "$(cat "$NOTIFY_LOG")" == *"2 new commit(s)"* ]]
}

# Silence is the normal case — this runs on a timer, and a notification that
# fires when there is nothing to do is one you learn to dismiss unread.
@test "says nothing when the checkout is current" {
	work="$(make_tracked_clone 0)"
	run_against "$work"
	[ "$status" -eq 0 ]
	[ ! -s "$NOTIFY_LOG" ]
}

# A diverged branch is not "run chezmoi update": that would be told to
# fast-forward something that cannot fast-forward. The script distinguishes
# them, and the distinction is the whole value of the message.
@test "a diverged branch is reported as diverged, not as an update" {
	work="$(make_tracked_clone 1)"
	printf 'local\n' >>"$work/f"
	git -C "$work" commit -qam local
	run_against "$work"
	[ "$status" -eq 0 ]
	notify_text="$(cat "$NOTIFY_LOG")"
	[[ "$notify_text" == *"diverged"* ]]
	[[ "$notify_text" == *"1 local"* ]]
	[[ "$notify_text" != *"chezmoi update"* ]]
}

# A local-only checkout has no upstream to compare against. An ordinary state
# on a machine that has never pushed, not a fault worth a notification.
@test "a checkout with no tracking branch says nothing" {
	work="$(make_tracked_clone 1)"
	git -C "$work" branch --unset-upstream
	run_against "$work"
	[ "$status" -eq 0 ]
	[ ! -s "$NOTIFY_LOG" ]
}

@test "a detached HEAD says nothing" {
	work="$(make_tracked_clone 1)"
	git -C "$work" checkout -q --detach
	run_against "$work"
	[ "$status" -eq 0 ]
	[ ! -s "$NOTIFY_LOG" ]
}

# The read-only claim, asserted against the repository rather than against the
# script's source text. A grep for `git pull` proves a string is absent; this
# proves the working tree and HEAD are where they started.
@test "leaves the checkout exactly as it found it" {
	work="$(make_tracked_clone 2)"
	before_head="$(git -C "$work" rev-parse HEAD)"
	before_tree="$(git -C "$work" status --porcelain)"
	run_against "$work"
	[ "$status" -eq 0 ]
	[ "$(git -C "$work" rev-parse HEAD)" = "$before_head" ]
	[ "$(git -C "$work" status --porcelain)" = "$before_tree" ]
}

# --- the health report it carries for dotfiles-status (M7) --------------------
#
# This half is not about the repo being behind at all. dotfiles-status --quiet
# is silent and exits 0 unless something is *broken*, and this is the only thing
# on the machine that fires daily and knows how to reach a person — so the daily
# timer runs it and notifies. None of that had a test: the block was added whole
# and the suite that lives next to it never mentioned dotfiles-status.
#
# Worse, on a developer machine the real one is on PATH and answers from the
# real machine's state, so these tests would have exercised something different
# here than in CI, where nothing is installed and the block is skipped outright.
# The stub settles both.

@test "a broken machine is reported, even with nothing to update" {
	work="$(make_tracked_clone 0)"
	run_against "$work" DS_RC=1 DS_OUTPUT='FAIL  secrets check     never ran'
	[ "$status" -eq 0 ]
	[[ "$(cat "$NOTIFY_LOG")" == *"secrets need attention"* ]]
}

@test "a healthy machine is not reported" {
	work="$(make_tracked_clone 0)"
	run_against "$work" DS_RC=0 DS_OUTPUT='ok    secrets check     2 day(s) ago'
	[ "$status" -eq 0 ]
	[ ! -s "$NOTIFY_LOG" ]
}

# H5, pinned. The report used to sit *below* five unconditional `exit 0`s — no
# git, not a work tree, detached HEAD, no upstream, a failed fetch — so an
# offline laptop or a checkout parked on a topic branch silently disabled the
# only automated word that the weekly check had stopped running, while both
# timers kept firing and both units kept passing.
@test "the report survives a checkout the git half gives up on" {
	work="$(make_tracked_clone 1)"
	git -C "$work" branch --unset-upstream
	run_against "$work" DS_RC=1 DS_OUTPUT='FAIL  secrets check     never ran'
	[ "$status" -eq 0 ]
	[[ "$(cat "$NOTIFY_LOG")" == *"secrets need attention"* ]]
}

# The body is the FAIL lines and only those. It used to be `head -2` of whatever
# came out, so a toast titled "needs attention" could open with an `ok` line and
# truncate the actual fault away.
@test "the toast carries the faults, not the first two lines" {
	work="$(make_tracked_clone 0)"
	run_against "$work" DS_RC=1 \
		DS_OUTPUT='ok    offline backup    made 3 day(s) ago\nwarn  something       pending\nFAIL  secrets check     never ran'
	[ "$status" -eq 0 ]
	notify_text="$(cat "$NOTIFY_LOG")"
	[[ "$notify_text" == *"FAIL  secrets check"* ]]
	[[ "$notify_text" != *"offline backup"* ]]
}

# Debounce. A fault that persists is still a fault, but an identical
# notification every day is how the channel stops being read — and it is the
# same channel that carries the ones that matter.
@test "an unchanged fault does not notify again the next day" {
	work="$(make_tracked_clone 0)"
	run_against "$work" DS_RC=1 DS_OUTPUT='FAIL  secrets check     never ran'
	[ -s "$NOTIFY_LOG" ]
	: >"$NOTIFY_LOG"
	run_against "$work" DS_RC=1 DS_OUTPUT='FAIL  secrets check     never ran'
	[ "$status" -eq 0 ]
	[ ! -s "$NOTIFY_LOG" ]
}

# ...but "a different thing is broken now" is exactly the event worth
# interrupting for, which is why the debounce is keyed on the message and not on
# a timestamp alone.
@test "a fault that changes notifies at once" {
	work="$(make_tracked_clone 0)"
	run_against "$work" DS_RC=1 DS_OUTPUT='FAIL  secrets check     never ran'
	: >"$NOTIFY_LOG"
	run_against "$work" DS_RC=1 DS_OUTPUT='FAIL  offline backup    the key rotated'
	[ "$status" -eq 0 ]
	[[ "$(cat "$NOTIFY_LOG")" == *"offline backup"* ]]
}

# The machine that has no dotfiles-status at all — a container, or a host where
# the applied copy has not landed yet. The block is skipped and the update half
# still does its job.
@test "no dotfiles-status installed is not a fault" {
	work="$(make_tracked_clone 2)"
	rm -f "$BATS_TEST_TMPDIR/realbin/dotfiles-status"
	run_against "$work"
	[ "$status" -eq 0 ]
	[[ "$(cat "$NOTIFY_LOG")" == *"2 new commit(s)"* ]]
}
