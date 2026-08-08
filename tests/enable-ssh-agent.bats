#!/usr/bin/env bats
#
# run_after_10-enable-ssh-agent.sh.tmpl enables the systemd user
# ssh-agent. Nothing covered it before: CI's bootstrap job runs where there is
# no user session at all (so only the skip branch runs), and CI's host-ssh-agent
# job runs the happy path against a real session it built for the purpose. The
# branch between those two — a session that exists but cannot see the unit —
# had no coverage anywhere, which is exactly the state a throwaway-HOME apply on
# a developer desktop creates.
#
# systemctl is stubbed rather than real for the reason the Proton tests stub
# pass-cli, mirrored: against the real user manager these tests would pass by
# reconfiguring the machine running them.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	TMPL="$BATS_TEST_DIRNAME/../home/.chezmoiscripts/run_after_10-enable-ssh-agent.sh.tmpl"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
	: >"$SYSTEMCTL_LOG"
	make_systemctl_stub "$BIN"

	RUNTIME="$(make_fake_runtime_dir "$BATS_TEST_TMPDIR/run")"

	SCRIPT="$BATS_TEST_TMPDIR/enable.sh"
	render_template "$TMPL" "$SCRIPT" "$BIN:$PATH"

	export HOME SYSTEMCTL_LOG
}

run_enable() {
	run env HOME="$HOME" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" PATH="$BIN:$PATH" \
		XDG_RUNTIME_DIR="$RUNTIME" "$@" sh "$SCRIPT"
}

@test "enables the unit when the manager is running and can see it" {
	run_enable
	[ "$status" -eq 0 ]
	grep -q -- "--user enable --now ssh-agent.service" "$SYSTEMCTL_LOG"
}

@test "reloads the manager before enabling" {
	run_enable
	[ "$status" -eq 0 ]
	grep -q -- "--user daemon-reload" "$SYSTEMCTL_LOG"
}

# The enable below it was guarded from the start; this call was not, and it is
# the one that runs first. Under `set -eu` a refused reload killed the script
# non-zero, and chezmoi stops applying on a non-zero run_ script — so a user
# manager having a bad day silently cost the file secrets, the host packages and
# the DevPod config, all of which are numbered after this one.
@test "a failed daemon-reload does not abort the apply" {
	run_enable SYSTEMCTL_RELOAD_RC=1
	[ "$status" -eq 0 ]
	[[ "$output" == *"Could not reload"* ]]
	# and it carried on to the thing it was reloading for
	grep -q -- "--user enable --now ssh-agent.service" "$SYSTEMCTL_LOG"
}

# The container/no-session case. The probe is for a socket specifically, because
# devcontainer images ship a systemctl shim that exits 0 while printing
# "systemd is not running" — trusting exit codes enables a unit that never runs.
@test "skips and says so when no user manager is running" {
	run env HOME="$HOME" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" PATH="$BIN:$PATH" \
		XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/empty" sh "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"No systemd user session"* ]]
	[ ! -s "$SYSTEMCTL_LOG" ]
}

@test "skips when XDG_RUNTIME_DIR is unset entirely" {
	run env -u XDG_RUNTIME_DIR HOME="$HOME" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
		PATH="$BIN:$PATH" sh "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"No systemd user session"* ]]
	[ ! -s "$SYSTEMCTL_LOG" ]
}

# The gap this file exists for. A running manager plus a unit it cannot see is
# what a throwaway-HOME apply looks like on a desktop: the socket probe passes
# because $XDG_RUNTIME_DIR still points at the real session, while the unit was
# written into a HOME that manager knows nothing about. Enabling anyway either
# fails the apply or, worse, succeeds against whatever the real session already
# had — reconfiguring the machine the test was only meant to be running on.
#
# Both sibling scripts (11-enable-update-check, 12-enable-secrets-check) already
# check visibility first. This one did not.
@test "does not enable a unit the manager cannot see" {
	run_enable SYSTEMCTL_CAT_RC=1
	[ "$status" -eq 0 ]
	[[ "$output" == *"not visible"* ]]
	! grep -q -- "enable" "$SYSTEMCTL_LOG"
}

# Best-effort, the same rule the rest of the apply chain follows: a failure here
# must cost the ssh-agent unit, not every run_onchange script queued behind it.
@test "a failed enable does not abort the apply" {
	run_enable SYSTEMCTL_ENABLE_RC=1
	[ "$status" -eq 0 ]
	[[ "$output" == *"Could not enable"* ]]
	# and it says how to finish the job by hand
	[[ "$output" == *"systemctl --user enable --now ssh-agent.service"* ]]
}
