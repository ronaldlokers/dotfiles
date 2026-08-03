#!/usr/bin/env bats
#
# run_after_13-ensure-ssh-include.sh asserts that ~/.ssh/config pulls in
# config.d/*.conf, on a file chezmoi deliberately does not manage. Everything it
# guards is a property of a file this repo never gets to see: whether the
# Include sits above the first Host block, whether the config is a symlink
# DevPod owns, whether a rewrite preserved the mode OpenSSH insists on. None of
# that is reachable from a clean-HOME apply, which only ever exercises the
# "no config yet" branch.

setup() {
	SCRIPT="$BATS_TEST_DIRNAME/../home/.chezmoiscripts/run_after_13-ensure-ssh-include.sh"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.ssh"
	chmod 700 "$HOME/.ssh"
	CONFIG="$HOME/.ssh/config"
	export HOME
}

# Runs the script with the harness's HOME, not the real one. Invoked through
# `sh` because chezmoi scripts carry no executable bit in the source tree —
# chezmoi runs them itself.
run_script() {
	run env HOME="$HOME" sh "$SCRIPT"
}

@test "creates a config with the Include when none exists" {
	rm -rf "$HOME/.ssh"
	run_script
	[ "$status" -eq 0 ]
	[ "$(cat "$CONFIG")" = "Include config.d/*.conf" ]
}

@test "a fresh config and its directory get the modes OpenSSH requires" {
	rm -rf "$HOME/.ssh"
	run_script
	[ "$status" -eq 0 ]
	[ "$(stat -c %a "$CONFIG")" = "600" ]
	[ "$(stat -c %a "$HOME/.ssh")" = "700" ]
}

@test "leaves a correctly placed Include untouched" {
	printf 'Include config.d/*.conf\n\nHost example\n\tUser me\n' >"$CONFIG"
	before="$(cat "$CONFIG")"
	run_script
	[ "$status" -eq 0 ]
	[ "$(cat "$CONFIG")" = "$before" ]
}

# The invariant the script's own comment says not to simplify away: OpenSSH
# scopes anything under a Host block to that block, so an Include below one is
# silently scoped rather than global. A presence check would pass this.
@test "hoists an Include that sits below a Host block" {
	printf 'Host example\n\tUser me\nInclude config.d/*.conf\n' >"$CONFIG"
	run_script
	[ "$status" -eq 0 ]
	[ "$(head -n 1 "$CONFIG")" = "Include config.d/*.conf" ]
}

@test "treats Match like Host when deciding placement" {
	printf 'Match host example\n\tUser me\nInclude config.d/*.conf\n' >"$CONFIG"
	run_script
	[ "$status" -eq 0 ]
	[ "$(head -n 1 "$CONFIG")" = "Include config.d/*.conf" ]
}

@test "a commented-out Host line does not count as a block" {
	printf '# Host commented\nInclude config.d/*.conf\n' >"$CONFIG"
	before="$(cat "$CONFIG")"
	run_script
	[ "$status" -eq 0 ]
	[ "$(cat "$CONFIG")" = "$before" ]
}

@test "an indented Host line still counts as a block" {
	printf '  Host indented\n\tUser me\nInclude config.d/*.conf\n' >"$CONFIG"
	run_script
	[ "$status" -eq 0 ]
	[ "$(head -n 1 "$CONFIG")" = "Include config.d/*.conf" ]
}

# 640, not 600. mktemp creates the replacement at 600 already, so asserting 600
# here passed with `chmod "$mode" "$final"` deleted outright — the test agreed
# with the default rather than with the file it was supposed to be preserving.
# A mode mktemp will never produce is the whole assertion.
@test "rewriting preserves the existing mode" {
	printf 'Host example\nInclude config.d/*.conf\n' >"$CONFIG"
	chmod 640 "$CONFIG"
	run_script
	[ "$status" -eq 0 ]
	[ "$(stat -c %a "$CONFIG")" = "640" ]
}

@test "user content survives a rewrite" {
	printf 'Host example\n\tUser me\n\tPort 2222\n' >"$CONFIG"
	run_script
	[ "$status" -eq 0 ]
	grep -q "Port 2222" "$CONFIG"
	grep -q "User me" "$CONFIG"
}

@test "is idempotent — a second run changes nothing" {
	printf 'Host example\n\tUser me\n' >"$CONFIG"
	run_script
	[ "$status" -eq 0 ]
	after_first="$(cat "$CONFIG")"
	run_script
	[ "$status" -eq 0 ]
	[ "$(cat "$CONFIG")" = "$after_first" ]
}

# The one-time migration: the fragment now sets AddKeysToAgent, so the old
# managed block has to go or the setting appears twice.
@test "drops the old AddKeysToAgent block during a rewrite" {
	printf '%s\n' \
		'# First ssh use loads the key into the agent, so no manual ssh-add' \
		'# after login/reboot' \
		'AddKeysToAgent yes' \
		'Host example' >"$CONFIG"
	run_script
	[ "$status" -eq 0 ]
	[ "$(grep -c AddKeysToAgent "$CONFIG")" -eq 0 ]
}

# Matched as one exact contiguous block, so a value the user chose themselves is
# never quietly deleted.
@test "keeps a hand-written AddKeysToAgent with a different value" {
	printf 'AddKeysToAgent no\nHost example\n' >"$CONFIG"
	run_script
	[ "$status" -eq 0 ]
	grep -q "AddKeysToAgent no" "$CONFIG"
}

# Exit 0, and that is the point of these two, not an incidental detail.
#
# chezmoi stops applying the moment a run_ script exits non-zero, and this one
# is numbered 13. Refusing a config someone else owns used to take out scripts
# 14, 20 and 30 with it — the file secrets, the host packages, the DevPod
# config — so an ssh config this script deliberately does not manage decided
# whether the rest of the machine got provisioned. The refusal stays; only its
# blast radius changes.
@test "refuses a symlinked config rather than replacing the link" {
	printf 'Host example\n' >"$HOME/.ssh/real-config"
	ln -s "$HOME/.ssh/real-config" "$CONFIG"
	run_script
	[ "$status" -eq 0 ]
	[ -L "$CONFIG" ]
	[[ "$output" == *"symlink"* ]]
	# Silence would be the wrong way to keep the apply alive: the invariant is
	# genuinely unasserted now, so it has to say what to type.
	[[ "$output" == *"Include config.d/*.conf"* ]]
}

@test "refuses a config that is not a regular file" {
	mkdir "$CONFIG"
	run_script
	[ "$status" -eq 0 ]
	[ -d "$CONFIG" ]
	[[ "$output" == *"not a regular file"* ]]
	[[ "$output" == *"Include config.d/*.conf"* ]]
}

# The reason both of the above assert 0 rather than "some exit code": a refusal
# must be distinguishable from a success by reading the output, since it is no
# longer distinguishable by the exit status. If the message ever stops naming
# the file, the refusal becomes a silent no-op.
@test "a refusal still names the file it would not touch" {
	ln -s /dev/null "$CONFIG"
	run_script
	[ "$status" -eq 0 ]
	[[ "$output" == *"$CONFIG"* ]]
}

# set -u catches an unset HOME but not an empty one, which would send every
# path in the script to /.ssh/config.
@test "refuses to run with an empty HOME" {
	run env HOME= sh "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ "$output" == *"empty"* ]]
}

@test "leaves no temp files behind after a rewrite" {
	printf 'Host example\n' >"$CONFIG"
	run_script
	[ "$status" -eq 0 ]
	[ -z "$(find "$HOME/.ssh" -name 'config.tmp.*' -print -quit)" ]
}
