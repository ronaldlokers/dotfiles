#!/usr/bin/env bats
#
# scripts/check-shells.sh starts each interactive shell and fails on startup
# noise, a non-zero exit, or a hang. Both CI and `mise run shells` run it.
#
# The hang case is the one with history. An interactive shell in a
# freshly-applied HOME blocks when something in the init path draws a prompt —
# `mise activate` asks whether to trust a config it has not seen, and on a pty
# there is nobody to answer. That was measured once, at "over ten minutes", and
# written down as slowness rather than as a deadlock, which is why this check
# stayed out of CI for a year. A hang has to fail with evidence, or the next
# person to meet it learns exactly as little.
#
# The shells are stubbed. Starting the real ones would test this developer's rc
# files rather than the checker, and the hang case would take as long as it
# says on the tin.

bats_require_minimum_version 1.5.0

setup() {
	SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-shells.sh"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"

	# A curated PATH, not the real one. This machine has a real zsh in
	# /usr/bin, so putting /usr/bin on PATH for coreutils made "a shell that is
	# not installed" untestable — `command -v zsh` found the genuine article
	# and the case passed by testing nothing. Symlink in exactly what the
	# script and the stubs need, and nothing else.
	SANDBOX="$BATS_TEST_TMPDIR/sandbox"
	mkdir -p "$SANDBOX"
	for t in sh mktemp cat rm timeout sleep printf env; do
		src="$(type -P "$t" 2>/dev/null)" || continue
		[ -n "$src" ] && ln -sf "$src" "$SANDBOX/$t"
	done
	export HOME
}

# A stand-in shell. $2 is what it writes, $3 its exit code, $4 seconds to sleep
# before doing either.
fake_shell() {
	local name="$1" out="${2:-}" rc="${3:-0}" delay="${4:-0}"
	# Prints *before* sleeping on purpose. A shell that blocks on a prompt has
	# already drawn most of it, and the evidence surviving the kill is the
	# whole reason the timeout branch writes to a file rather than a variable.
	cat >"$BIN/$name" <<EOF
#!/bin/sh
[ -n "$out" ] && printf '%s\n' "$out"
[ "$delay" -gt 0 ] && sleep $delay
exit $rc
EOF
	chmod 755 "$BIN/$name"
}

# The script prefers \`script\` for a pty. A stub that just runs the command
# keeps these tests about the checker rather than about util-linux.
fake_script() {
	cat >"$BIN/script" <<'EOF'
#!/bin/sh
# script -qec "<command>" /dev/null
cmd=""
while [ $# -gt 0 ]; do
	case "$1" in
	-qec | -ec | -c) cmd="$2"; shift 2 ;;
	*) shift ;;
	esac
done
sh -c "$cmd"
EOF
	chmod 755 "$BIN/script"
}

run_check() {
	run env PATH="$BIN:$SANDBOX" HOME="$HOME" "$@" sh "$SCRIPT"
}

@test "two silent shells pass" {
	fake_script
	fake_shell zsh "" 0
	fake_shell bash "" 0
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok    zsh"* ]]
	[[ "$output" == *"ok    bash"* ]]
}

# The whole point of the check: an rc file that prints on every new terminal is
# a regression even though the shell started fine. CI's old version asserted
# only the exit code and would have passed this.
@test "a shell that starts but prints something fails" {
	fake_script
	fake_shell zsh "warning: something is not right" 0
	fake_shell bash "" 0
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"printed output"* ]]
	[[ "$output" == *"something is not right"* ]]
}

@test "a shell that exits non-zero fails and shows what it said" {
	fake_script
	fake_shell zsh "line 3: command not found" 1
	fake_shell bash "" 0
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"exited non-zero"* ]]
	[[ "$output" == *"command not found"* ]]
}

# The case this file exists for. Output captured into a shell variable is lost
# when the process is killed, so the hang used to explain nothing at all — and
# on a runner it burns the job's whole six-hour default before saying so.
@test "a shell that hangs fails on a timeout rather than waiting" {
	fake_script
	fake_shell zsh "" 0 30
	fake_shell bash "" 0
	run_check CHECK_SHELLS_TIMEOUT=2
	[ "$status" -ne 0 ]
	[[ "$output" == *"did not finish starting within 2s"* ]]
	[[ "$output" == *"waiting on a keypress"* ]]
}

# ...and the evidence survives the kill, which is the only reason the timeout is
# worth anything. A blocked shell has usually printed something first — mise
# renders most of its trust widget before waiting on the answer.
@test "a hang still reports what the shell printed before blocking" {
	fake_script
	fake_shell zsh "mise config files are not trusted. Trust them?" 0 30
	fake_shell bash "" 0
	run_check CHECK_SHELLS_TIMEOUT=2
	[ "$status" -ne 0 ]
	[[ "$output" == *"not trusted"* ]]
}

@test "a hang with no output says so rather than showing a blank" {
	fake_script
	fake_shell zsh "" 0 30
	fake_shell bash "" 0
	run_check CHECK_SHELLS_TIMEOUT=2
	[ "$status" -ne 0 ]
	[[ "$output" == *"blocked before writing anything"* ]]
}

# One shell hanging must not stop the other being checked: bash is
# hand-mirrored from zsh and is the more likely of the two to have drifted.
@test "a failure in the first shell does not skip the second" {
	fake_script
	fake_shell zsh "" 0 30
	fake_shell bash "bash is noisy too" 0
	run_check CHECK_SHELLS_TIMEOUT=2
	[ "$status" -ne 0 ]
	[[ "$output" == *"bash is noisy too"* ]]
}

@test "a shell that is not installed is skipped, not failed" {
	fake_script
	fake_shell bash "" 0
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"skip  zsh"* ]]
}

@test "--help explains itself and starts nothing" {
	fake_script
	fake_shell zsh "SHOULD NOT RUN" 0
	fake_shell bash "SHOULD NOT RUN" 0
	run env PATH="$BIN:$SANDBOX" HOME="$HOME" sh "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: scripts/check-shells.sh"* ]]
	[[ "$output" != *"SHOULD NOT RUN"* ]]
}

@test "an unknown argument is refused" {
	run env PATH="$BIN:$SANDBOX" HOME="$HOME" sh "$SCRIPT" --fix
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown argument"* ]]
}

# The cd is what makes this runnable in CI at all: mise merges a config from
# every ancestor of the working directory, so a shell started inside the
# checkout meets the repo's own mise.toml and, untrusted, waits for a keypress.
@test "the shells are started from HOME, not from the working directory" {
	fake_script
	cat >"$BIN/zsh" <<'EOF'
#!/bin/sh
pwd
EOF
	chmod 755 "$BIN/zsh"
	fake_shell bash "" 0
	run_check
	# zsh printed its cwd, so the run fails — and what it printed is the
	# assertion.
	[ "$status" -ne 0 ]
	[[ "$output" == *"$HOME"* ]]
}
