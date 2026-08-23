#!/usr/bin/env bats
#
# agent-status prints one Waybar JSON object for the bar widget that says
# whether this machine can actually sign and push right now.
#
# The failure it exists for is silent: an empty ssh-agent surfaces as a git
# push that cannot authenticate, with the real cause -- a lapsed Proton
# session, a corrupt pass-cli database -- reported once per boot on the stderr
# of whichever terminal happened to be first, and nowhere else.
#
# Two stubs are the whole seam. `ssh-add` stands in for the agent, because the
# real one answers for the developer's own session; `pass-cli` stands in for
# Proton, because the real one needs a live vault. Both are already the way the
# rest of this suite tests these paths.

bats_require_minimum_version 1.5.0

SIGNING_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMj1CJnE/kvOEVs8B8AWfDSKAtICy8fP45R0QYAZdhbf"
OTHER_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"

setup() {
	load 'helpers'
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_agent-status"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$STUB_LOG"
	make_ssh_add_stub "$BIN"
	make_pass_cli_stub "$BIN"

	# Real git against a fixture config, not a stub: reading the signing key is
	# the script's own logic and worth exercising for real.
	GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
	cat >"$GIT_CONFIG_GLOBAL" <<-EOF
		[user]
			signingkey = key::$SIGNING_KEY git-signing
	EOF

	RUNTIME="$BATS_TEST_TMPDIR/runtime"
	mkdir -p "$RUNTIME"
}

run_status() {
	run env HOME="$HOME" PATH="$BIN:$PATH" STUB_LOG="$STUB_LOG" \
		GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" XDG_RUNTIME_DIR="$RUNTIME" \
		"$@" sh "$SCRIPT"
}

json_field() {
	printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

@test "reports ok when the agent holds the signing key" {
	run_status SSH_ADD_KEYS="$SIGNING_KEY git-signing"
	[ "$status" -eq 0 ]
	[ "$(json_field class)" = "ok" ]
}

# A count alone would call this green. It is not: the agent can hold the host
# and AUR keys while the one git signs with is missing, which is exactly the
# shape the 2026-08-23 outage took -- three keys in the vault, none of them
# loaded, and a commit that would not sign.
@test "reports warn when keys are loaded but the signing key is not among them" {
	run_status SSH_ADD_KEYS="$OTHER_KEY aur@sugarrush"
	[ "$status" -eq 0 ]
	[ "$(json_field class)" = "warn" ]
}

@test "an empty agent with a live Proton session blames the load, not the session" {
	run_status SSH_ADD_KEYS="" PASS_INFO_RC=0
	[ "$status" -eq 0 ]
	[ "$(json_field class)" = "empty" ]
	[[ "$(json_field tooltip)" == *"session is alive"* ]]
}

@test "an empty agent with no Proton session says to log in" {
	run_status SSH_ADD_KEYS="" PASS_INFO_RC=1
	[ "$(json_field class)" = "empty" ]
	[[ "$(json_field tooltip)" == *"no Proton Pass session"* ]]
}

# The 2026-08-23 fault: `pass-cli info` fails, but not because the session
# lapsed -- the local sqlcipher database will not decrypt. Logging in again does
# nothing for it, and reading the two as the same fault sent a whole debugging
# session down the wrong path.
@test "a pass-cli database that will not decrypt is not reported as a lapsed session" {
	run_status SSH_ADD_KEYS="" PASS_INFO_RC=1 \
		PASS_INFO_STDERR="Error: Failed to open encrypted database: file is not a database. The encryption key may not match"
	[ "$(json_field class)" = "empty" ]
	[[ "$(json_field tooltip)" == *"logout --force"* ]]
	[[ "$(json_field tooltip)" != *"no Proton Pass session"* ]]
}

# `ssh-add` exits 2 when it cannot reach an agent at all, which is a different
# fault with a different fix -- the systemd unit, not Proton -- and asking the
# vault about it wastes a network round trip on a question it cannot answer.
@test "a dead agent socket is not reported as an empty agent" {
	run_status SSH_ADD_RC=2
	[ "$(json_field class)" = "no-agent" ]
	[[ "$(json_field tooltip)" == *"ssh-agent.service"* ]]
	[ ! -s "$STUB_LOG" ]
}

# The steady state. This runs on every bar tick, forever; if a healthy agent
# cost a call to Proton the widget would be a background network load.
@test "a healthy agent never calls pass-cli" {
	run_status SSH_ADD_KEYS="$SIGNING_KEY git-signing"
	[ "$(json_field class)" = "ok" ]
	[ ! -s "$STUB_LOG" ]
}

# The bar ticks far more often than Proton's answer changes, and the answer
# only matters while the agent is empty -- which can last as long as it takes
# to notice the widget. Without a cache that is one network call per tick for
# the whole time the fault is visible.
@test "the Proton probe is cached, so a second tick inside the TTL does not call pass-cli" {
	run_status SSH_ADD_KEYS="" PASS_INFO_RC=1
	[ "$(grep -c '^info' "$STUB_LOG")" -eq 1 ]
	first="$output"

	run_status SSH_ADD_KEYS="" PASS_INFO_RC=1
	[ "$(grep -c '^info' "$STUB_LOG")" -eq 1 ]
	[ "$output" = "$first" ]
}

@test "an expired cache probes again" {
	run_status SSH_ADD_KEYS="" PASS_INFO_RC=1 AGENT_STATUS_PROBE_TTL=0
	run_status SSH_ADD_KEYS="" PASS_INFO_RC=1 AGENT_STATUS_PROBE_TTL=0
	[ "$(grep -c '^info' "$STUB_LOG")" -eq 2 ]
}

# Without the cached bootstrap PAT there is nothing for proton-ssh-load to log
# in with, so the click that fixes every other empty-agent case cannot fix this
# one -- it needs a token typed in. Saying so in the tooltip is the difference
# between one click and a confused detour.
@test "no cached bootstrap PAT is called out, since clicking alone cannot fix it" {
	run_status SSH_ADD_KEYS="" PASS_INFO_RC=1
	[[ "$(json_field tooltip)" == *"no cached bootstrap PAT"* ]]
}

@test "a cached bootstrap PAT is not mentioned" {
	mkdir -p "$HOME/.config"
	printf 'fake-token-value\n' >"$HOME/.config/pass-cli-bootstrap-pat"
	run_status SSH_ADD_KEYS="" PASS_INFO_RC=1
	[[ "$(json_field tooltip)" != *"bootstrap PAT"* ]]
}

# This output goes to the bar, and the bar's tooltip is on screen. The script
# reads the PAT file's presence and must never read its contents.
@test "the bootstrap PAT never reaches the output" {
	mkdir -p "$HOME/.config"
	printf 'pat-secret-do-not-print\n' >"$HOME/.config/pass-cli-bootstrap-pat"
	run_status SSH_ADD_KEYS="" PASS_INFO_RC=1
	[[ "$output" != *"pat-secret-do-not-print"* ]]
}

# A cached diagnosis outlives the fault it describes: load the keys and the
# widget goes green, but the stale line is still on disk, ready to be served to
# the next empty-agent tick inside the TTL and blame a session that was fixed
# ten minutes ago.
@test "a healthy agent drops a cached diagnosis" {
	run_status SSH_ADD_KEYS="" PASS_INFO_RC=1
	[ -r "$RUNTIME/agent-status.probe" ]

	run_status SSH_ADD_KEYS="$SIGNING_KEY git-signing"
	[ "$(json_field class)" = "ok" ]
	[ ! -e "$RUNTIME/agent-status.probe" ]
}

# The widget's Process does not always carry SSH_AUTH_SOCK -- the bar showed
# "no ssh-agent reachable" while the very same command in a terminal reported
# three keys. The socket systemd's ssh-agent.service listens on is at a known
# path, so a caller with no SSH_AUTH_SOCK is recoverable rather than a fault.
@test "finds the session socket when the caller's environment does not name it" {
	touch "$RUNTIME/ssh-agent.socket"
	run_status SSH_AUTH_SOCK="" SSH_ADD_GOOD_SOCK="$RUNTIME/ssh-agent.socket" \
		SSH_ADD_KEYS="$SIGNING_KEY git-signing"
	[ "$(json_field class)" = "ok" ]
}

@test "still reports no-agent when there is no socket to fall back to" {
	run_status SSH_AUTH_SOCK="" SSH_ADD_GOOD_SOCK="$RUNTIME/ssh-agent.socket" \
		SSH_ADD_KEYS="$SIGNING_KEY git-signing"
	[ "$(json_field class)" = "no-agent" ]
}
