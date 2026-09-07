#!/usr/bin/env bats
#
# dot_config/shell/ssh-agent.sh runs on every interactive shell. It hunts for a
# live agent socket, adopts the first one that answers, and republishes it at
# the stable ~/.ssh/agent.sock so later shells and long-lived sessions find it
# again after a reconnect.
#
# The hunt includes a glob over /tmp, because that is where a devcontainer's
# forwarded agent lands. /tmp is world-writable, and whatever this picks becomes
# the agent that answers signing requests for the git signing key -- for this
# shell, and then for every shell after it, since the pick is republished at a
# stable path. So the search is restricted to sockets this uid owns.
#
# Both halves are pinned here, and they fail differently on a revert:
#
#   - drop `-uid` and the static case goes red, which is what a revert trips;
#   - narrow the predicate wrongly and the behavioural case goes red, because
#     the legitimate socket stops being adopted. A security fix that quietly
#     breaks the thing it guards is the more expensive mistake of the two.
#
# The behavioural case cannot cover the attack directly: proving a socket owned
# by *another* uid is skipped needs a file owned by another uid, and an
# unprivileged test cannot create one. That half is the static assertion, and
# saying so here is better than a test that looks like it covers it.

bats_require_minimum_version 1.5.0

setup() {
	RC="$BATS_TEST_DIRNAME/../home/dot_config/shell/ssh-agent.sh"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"

	# The script globs the real /tmp, so the fixture has to live there. Named
	# after this test run so a stale one from a crashed run is identifiable,
	# and removed in teardown.
	AGENT_DIR="/tmp/auth-agent-bats-$$-${BATS_TEST_NUMBER:-0}"
	SOCK="$AGENT_DIR/listener.sock"

	# A live agent: exit 0 for `-l` (has identities), so the rc's own
	# proton-ssh-load branch at the bottom stays out of this test. Exit 2 for
	# any other socket is what "no agent answers there" looks like.
	cat >"$BIN/ssh-add" <<-'STUB'
		#!/bin/sh
		[ "${SSH_AUTH_SOCK:-}" = "${LIVE_SOCK:-}" ] || exit 2
		exit 0
	STUB
	chmod 755 "$BIN/ssh-add"
	export HOME
}

teardown() {
	[ -n "${AGENT_DIR:-}" ] && rm -rf "$AGENT_DIR"
	return 0
}

make_socket() {
	mkdir -p "$AGENT_DIR"
	python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(1)' "$SOCK"
	[ -S "$SOCK" ]
}

# Sources the rc the way a shell does and reports where SSH_AUTH_SOCK ended up.
source_rc() {
	run env -u SSH_AUTH_SOCK -u XDG_RUNTIME_DIR \
		PATH="$BIN:/usr/bin:/bin" HOME="$HOME" LIVE_SOCK="$SOCK" \
		sh -c ". \"\$1\"; printf '%s\n' \"\${SSH_AUTH_SOCK:-none}\"" sh "$RC"
}

@test "a forwarded socket this uid owns is still adopted" {
	make_socket
	source_rc
	[ "$status" -eq 0 ]
	# Republished at the stable path, which is what the rc exports.
	[[ "$output" == *"$HOME/.ssh/agent.sock"* ]]
	[ -L "$HOME/.ssh/agent.sock" ]
	[ "$(readlink "$HOME/.ssh/agent.sock")" = "$SOCK" ]
}

@test "no socket anywhere leaves SSH_AUTH_SOCK unset rather than guessing" {
	source_rc
	[ "$status" -eq 0 ]
	[[ "$output" == *"none"* ]]
}

# The half an unprivileged test cannot reach behaviourally. Without the
# predicate the glob adopts any uid's socket, and the adopted one is then
# written to ~/.ssh/agent.sock for every later shell.
@test "the /tmp search is restricted to sockets this uid owns" {
	line="$(grep -n "find /tmp" "$RC")"
	[ -n "$line" ]
	[[ "$line" == *"-uid"* ]]
	[[ "$line" == *'$(id -u)'* ]]
	# -type s, not -type f: find does not follow a symlink without -L, so a
	# link planted at a path this uid owns still does not match.
	[[ "$line" == *"-type s"* ]]
}
