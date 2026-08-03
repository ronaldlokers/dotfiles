#!/usr/bin/env bats
#
# proton-ssh-load is the only path by which a key reaches the agent, and it is
# the one script that handles the bootstrap token. `mise run secrets-check`
# cannot cover it — that needs a live Proton session, so CI never runs it. The
# stub in helpers.bash stands in for pass-cli.
#
# The load-bearing test here is "never passes the token as a flag": the token is
# passed through the environment specifically so its value does not appear in
# `ps`, and nothing else enforces that.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_proton-ssh-load"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$STUB_LOG"
	make_pass_cli_stub "$BIN"
	PAT_FILE="$HOME/.config/pass-cli-bootstrap-pat"

	# Per-test, and not optional. The script's warn-once marker lives in
	# $XDG_RUNTIME_DIR, and this desktop exports the real one — so without this
	# the suite writes markers into /run/user/$UID and every test after the
	# first silently takes the already-warned path. Redirecting HOME does not
	# cover it, the same way it did not for XDG_STATE_HOME in the export tests.
	XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
	mkdir -p "$XDG_RUNTIME_DIR"
	# One marker per condition, not one for the script. A single marker meant
	# whichever fault spoke first silenced every other fault for the rest of the
	# boot — a terminal that said "no session" left a later rejected token, or a
	# load that failed outright, with nothing to say.
	WARN_MARKER="$XDG_RUNTIME_DIR/proton-ssh-load.warned.no-session"
	WARN_MARKER_REJECTED="$XDG_RUNTIME_DIR/proton-ssh-load.warned.rejected"
	WARN_MARKER_LOAD="$XDG_RUNTIME_DIR/proton-ssh-load.warned.load-failed"

	export HOME STUB_LOG XDG_RUNTIME_DIR
}

# Runs the script with only the stub dir plus the real coreutils on PATH.
run_load() {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" "$@" sh "$SCRIPT"
}

# D3: the script refused unknown options with a bare "unknown option" line and
# no usage text at all, so --help got an error message that did not say what the
# options were. Every script in ~/.local/bin answers the question the same way
# now.
@test "--help prints usage and loads nothing" {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		sh "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: proton-ssh-load"* ]]
	[[ "$output" == *"--prompt"* ]]
	[ ! -s "$STUB_LOG" ]
}

@test "-h does the same" {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		sh "$SCRIPT" -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: proton-ssh-load"* ]]
}

# It already refused unknown options; what it did not do was say what the valid
# ones are.
@test "an unknown option gets usage as well as the error" {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		sh "$SCRIPT" --nope
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown option"* ]]
	[[ "$output" == *"usage: proton-ssh-load"* ]]
}

@test "loads keys when the session is already live" {
	run_load
	[ "$status" -eq 0 ]
	grep -q "ssh-agent load" "$STUB_LOG"
	# already authenticated, so no login attempt
	! grep -q "^login" "$STUB_LOG"
}

@test "exits quietly when pass-cli is not installed" {
	# a PATH with coreutils but deliberately no pass-cli
	run env HOME="$HOME" PATH="/usr/bin:/bin" sh "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"pass-cli is not installed"* ]]
}

@test "--quiet suppresses the not-installed message" {
	run env HOME="$HOME" PATH="/usr/bin:/bin" sh "$SCRIPT" --quiet
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# The security property the repo's own docs call out: a flag value is visible in
# `ps`, so the token has to travel in the environment.
@test "never passes the token as a command-line flag" {
	run_load PASS_INFO_RC=1 PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_supersecret_value
	[ "$status" -eq 0 ]
	grep -q "^login" "$STUB_LOG"
	! grep -q -- "--personal-access-token" "$STUB_LOG"
	! grep -q "pst_supersecret_value" "$STUB_LOG"
}

@test "caches a token supplied through the environment" {
	run_load PASS_INFO_RC=1 PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_from_env
	[ "$status" -eq 0 ]
	[ "$(cat "$PAT_FILE")" = "pst_from_env" ]
	[[ "$output" == *"cached the token"* ]]
}

@test "the cached token file is not readable by anyone else" {
	run_load PASS_INFO_RC=1 PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_from_env
	[ "$status" -eq 0 ]
	[ "$(stat -c %a "$PAT_FILE")" = "600" ]
}

# Mirrors "leaves no temp file behind after a failed fetch" in
# restore-secrets.bats: a write that cannot land must not leave a plaintext
# token sitting in a *.tmp.* file forever. The temp write itself must
# succeed here -- only the rename must fail -- so this shadows `mv` with a
# stub that always fails, scoped to this test and removed again right after.
# chmod 500 on the parent directory (tried first) blocks the temp file's
# creation before it ever exists, which cannot distinguish "the cleanup ran"
# from "there was nothing to clean up" -- it passes with the rm -f deleted.
@test "leaves no temp file behind after a failed cache write" {
	cat >"$BIN/mv" <<'EOF'
#!/bin/sh
exit 1
EOF
	chmod 755 "$BIN/mv"

	run_load PASS_INFO_RC=1 PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_from_env

	rm -f "$BIN/mv"

	[ "$status" -eq 0 ]
	[ ! -f "$PAT_FILE" ]
	[ -z "$(find "$(dirname "$PAT_FILE")" -name '*.tmp.*' -print -quit 2>/dev/null)" ]
}

@test "falls back to the cached token when the environment has none" {
	mkdir -p "$(dirname "$PAT_FILE")"
	printf 'pst_cached\n' >"$PAT_FILE"
	run_load PASS_INFO_RC=1
	[ "$status" -eq 0 ]
	grep -q "^login" "$STUB_LOG"
	# read from cache, so it must not announce a fresh caching
	[[ "$output" != *"cached the token"* ]]
}

@test "does not rewrite the cache when the token came from the cache" {
	mkdir -p "$(dirname "$PAT_FILE")"
	printf 'pst_cached\n' >"$PAT_FILE"
	before="$(stat -c %Y.%i "$PAT_FILE")"
	run_load PASS_INFO_RC=1
	[ "$status" -eq 0 ]
	[ "$(stat -c %Y.%i "$PAT_FILE")" = "$before" ]
}

@test "explains what to do when there is no session and no token" {
	run_load PASS_INFO_RC=1
	[ "$status" -eq 0 ]
	[[ "$output" == *"no Proton Pass session"* ]]
	[[ "$output" == *"PROTON_PASS_PERSONAL_ACCESS_TOKEN"* ]]
	# never reached the load
	! grep -q "ssh-agent load" "$STUB_LOG"
}

# Exit 0, not a failure: this runs from a shell rc, and a non-zero exit there
# would surface as a broken login rather than a missing key.
@test "exits zero when authentication fails" {
	run_load PASS_INFO_RC=1 PASS_LOGIN_RC=1 PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_bad
	[ "$status" -eq 0 ]
	[[ "$output" == *"could not authenticate"* ]]
	! grep -q "ssh-agent load" "$STUB_LOG"
}

@test "a failed authentication does not cache the bad token" {
	run_load PASS_INFO_RC=1 PASS_LOGIN_RC=1 PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_bad
	[ "$status" -eq 0 ]
	[ ! -f "$PAT_FILE" ]
}

# Not run_load: this one needs to pass --quiet to the script itself, and
# run_load appends the script after the env assignments.
@test "exits zero when the agent load itself fails, under --quiet" {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" PASS_SSH_RC=1 \
		sh "$SCRIPT" --quiet
	# Exit 0 is the assertion: the shell rc calls this, and a non-zero exit on
	# a startup path is worse than an unloaded key. What it must NOT do is stay
	# silent about it — see below.
	[ "$status" -eq 0 ]
}

# --quiet means "say nothing on success". This line read it as "say nothing".
#
# Every other failure path earns its way to a warn_once; this one — the call
# that actually loads the keys — sent its error to /dev/null and exited 0. So a
# live session whose key load fails, which is the most direct route there is to
# an empty agent, was the single failure a new terminal could never report. That
# is the state where you go and debug a git push instead of reading one line.
@test "a failed load under --quiet still says so, once per boot" {
	run --separate-stderr env HOME="$HOME" STUB_LOG="$STUB_LOG" \
		PATH="$BIN:$PATH" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PASS_SSH_RC=1 \
		sh "$SCRIPT" --quiet </dev/null
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"loading the SSH keys failed"* ]]
	# and it points at the command that shows why, rather than reprinting
	# pass-cli's error at every prompt
	[[ "$stderr" == *"by hand"* ]]
	[ -e "$WARN_MARKER_LOAD" ]

	# the terminal after it stays quiet
	run --separate-stderr env HOME="$HOME" STUB_LOG="$STUB_LOG" \
		PATH="$BIN:$PATH" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PASS_SSH_RC=1 \
		sh "$SCRIPT" --quiet </dev/null
	[ "$status" -eq 0 ]
	[ -z "$stderr" ]
}

# The reason each condition gets its own marker rather than sharing one. These
# are different faults with different fixes, and whichever happened first used
# to silence the rest for the remainder of the boot.
@test "a dead session does not silence a later load failure" {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PASS_INFO_RC=1 \
		sh "$SCRIPT" --quiet </dev/null
	[ -e "$WARN_MARKER" ]

	run --separate-stderr env HOME="$HOME" STUB_LOG="$STUB_LOG" \
		PATH="$BIN:$PATH" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PASS_SSH_RC=1 \
		sh "$SCRIPT" --quiet </dev/null
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"loading the SSH keys failed"* ]]
}

@test "surfaces the agent load failure when not quiet" {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" PASS_SSH_RC=1 \
		sh "$SCRIPT"
	# without --quiet the failing load is not swallowed
	[ "$status" -ne 0 ]
}

@test "rejects an unknown option" {
	run env HOME="$HOME" PATH="$BIN:$PATH" sh "$SCRIPT" --nope
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown option: --nope"* ]]
}

@test "accepts the flags in either order" {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		sh "$SCRIPT" --prompt --quiet </dev/null
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		sh "$SCRIPT" --quiet --prompt </dev/null
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# Guards the harness itself: if script(1) ever stops handing the child a pty,
# every prompt test below would silently pass by never prompting.
@test "the pty harness really presents a terminal" {
	probe="$BATS_TEST_TMPDIR/probe.sh"
	cat >"$probe" <<'EOF'
#!/bin/sh
[ -t 0 ] && echo "harness-tty: yes" || echo "harness-tty: no"
read -r line || true
echo "harness-read: [$line]"
EOF
	SCRIPT="$probe"
	run_load_tty "typed_value"
	[ "$status" -eq 0 ]
	[[ "$output" == *"harness-tty: yes"* ]]
	[[ "$output" == *"harness-read: [typed_value]"* ]]
}

@test "prompts for the token on a terminal and caches it" {
	run_load_tty "pst_typed" PASS_INFO_RC=1 -- --prompt
	[ "$status" -eq 0 ]
	[[ "$output" == *"Proton Pass PAT"* ]]
	grep -q "^login" "$STUB_LOG"
	grep -q "ssh-agent load" "$STUB_LOG"
	[ "$(cat "$PAT_FILE")" = "pst_typed" ]
	# the flag invariant, extended to the typed path
	! grep -q -- "--personal-access-token" "$STUB_LOG"
	! grep -q "pst_typed" "$STUB_LOG"
}

@test "the typed token is cached unreadable to anyone else" {
	run_load_tty "pst_typed" PASS_INFO_RC=1 -- --prompt
	[ "$status" -eq 0 ]
	[ "$(stat -c %a "$PAT_FILE")" = "600" ]
}

# The apply path passes --quiet. A prompt suppressed there is an unexplained
# hang, which is worse than the noise --quiet exists to remove.
@test "the prompt is visible even under --quiet" {
	run_load_tty "pst_typed" PASS_INFO_RC=1 -- --quiet --prompt
	[ "$status" -eq 0 ]
	[[ "$output" == *"Proton Pass PAT"* ]]
}

@test "empty input at the prompt writes no cache" {
	run_load_tty "" PASS_INFO_RC=1 -- --prompt
	[ "$status" -eq 0 ]
	[ ! -f "$PAT_FILE" ]
	[[ "$output" == *"no Proton Pass session"* ]]
	! grep -q "^login" "$STUB_LOG"
}

# This is the whole reason the flag exists: ssh-agent.sh passes bare --quiet
# from dot_zshrc on every new shell with an empty agent.
@test "bare --quiet never prompts, even on a terminal" {
	run_load_tty "pst_typed" PASS_INFO_RC=1 -- --quiet
	[ "$status" -eq 0 ]
	[[ "$output" != *"Proton Pass PAT"* ]]
	[ ! -f "$PAT_FILE" ]
	! grep -q "^login" "$STUB_LOG"
}

# CI, mise run verify and devpod up all apply with stdin closed.
@test "--prompt without a terminal does not prompt" {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" PASS_INFO_RC=1 \
		sh "$SCRIPT" --quiet --prompt </dev/null
	[ "$status" -eq 0 ]
	# Not exact emptiness any more: the no-session explanation is said once per
	# boot even under --quiet. What must not happen is a prompt, which would
	# block forever with no terminal to answer on.
	[[ "$output" != *"Proton Pass PAT"* ]]
	[ ! -f "$PAT_FILE" ]
	! grep -q "^login" "$STUB_LOG"
}

# Pins the gate as -t 0 (stdin), not -t 1 (stdout). stdin stays on the pty
# script(1) provides, but the script's own stdout is redirected to a plain
# file, so -t 0 and -t 1 disagree here. stty and read are bound to fd 0
# regardless of the gate, so a pty-stdout/null-stdin variant of this test
# cannot distinguish the two checks: stty -g fails on a non-tty fd 0 and
# masks a wrong `-t 1` before anything prints. This polarity is the one that
# actually discriminates: a real terminal at the keyboard (stdin) must still
# get prompted even when stdout happens to be piped elsewhere (a log, `| tee`,
# a redirected devpod exec) — that has nothing to do with whether anyone can
# answer. A future edit to `-t 1` would silently stop prompting here even
# though the terminal is genuinely interactive.
@test "the prompt is gated on stdin being a terminal, not stdout" {
	cmd="env HOME=\"$HOME\" STUB_LOG=\"$STUB_LOG\" PATH=\"$BIN:$PATH\" PASS_INFO_RC=1 sh \"$SCRIPT\" --quiet --prompt 1>/dev/null"
	run script -qec "$cmd" /dev/null <<<"pst_typed"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Proton Pass PAT"* ]]
	[ "$(cat "$PAT_FILE")" = "pst_typed" ]
	grep -q "^login" "$STUB_LOG"
}

# No existing test pins that echo is actually off while the token is typed:
# replacing the `stty -echo` line with a no-op still passed every test in this
# file. The reason is run_load_tty (and the herestring shape used two tests
# above): both feed the typed answer through a bash herestring at process
# start, so the bytes are already sitting in the pty's input queue before the
# script has even forked, let alone reached `stty -echo` -- echo state cannot
# affect what those harnesses observe. helpers.bash documents the token
# showing up in $output as an expected artifact of exactly that timing.
#
# This test deliberately does NOT use run_load_tty: it needs the typed answer
# to arrive strictly *after* the prompt is printed and echo has been turned
# off, not before the script even starts. `sleep 1` clears process startup
# comfortably -- the stub `pass-cli info` returns instantly, so a fork and
# exec is the only thing that has to happen before the delayed write lands.
@test "the typed token is never echoed to the terminal" {
	cmd="env HOME=\"$HOME\" STUB_LOG=\"$STUB_LOG\" PATH=\"$BIN:$PATH\" PASS_INFO_RC=1 sh \"$SCRIPT\" --quiet --prompt"
	run script -qec "$cmd" /dev/null < <(sleep 1; printf '%s\n' "pst_typed_secret")
	[ "$status" -eq 0 ]
	[[ "$output" != *"pst_typed_secret"* ]]
}

@test "a rejected cached token re-prompts and the new one replaces it" {
	mkdir -p "$(dirname "$PAT_FILE")"
	printf 'pst_stale\n' >"$PAT_FILE"
	run_load_tty "pst_fresh" PASS_INFO_RC=1 PASS_LOGIN_BAD_TOKEN=pst_stale -- --prompt
	[ "$status" -eq 0 ]
	[[ "$output" == *"was rejected"* ]]
	[ "$(cat "$PAT_FILE")" = "pst_fresh" ]
	grep -q "ssh-agent load" "$STUB_LOG"
}

# Stale beats truncated, the same rule restore() follows. The two extra
# assertions (rejection notice, two distinct login attempts) exist because
# without them this test kept passing even when the retry branch itself was
# deleted outright: the cache-unchanged and final-message checks alone cannot
# tell "never retried" apart from "retried and failed again" — both leave the
# cache untouched and print the same final message.
@test "a rejected cached token survives a rejected replacement" {
	mkdir -p "$(dirname "$PAT_FILE")"
	printf 'pst_stale\n' >"$PAT_FILE"
	run_load_tty "pst_also_bad" PASS_INFO_RC=1 PASS_LOGIN_RC=1 -- --prompt
	[ "$status" -eq 0 ]
	[ "$(cat "$PAT_FILE")" = "pst_stale" ]
	[[ "$output" == *"could not authenticate"* ]]
	! grep -q "ssh-agent load" "$STUB_LOG"
	# The retry actually happened: the rejection notice was printed, and a
	# second login was attempted (the rejected typed replacement), not just
	# the first (the rejected cached token).
	[[ "$output" == *"was rejected"* ]]
	[ "$(grep -c '^login' "$STUB_LOG")" -eq 2 ]
}

# The "prompted already?" guard is what bounds this, not the token's source.
@test "a rejected environment token re-prompts too" {
	run_load_tty "pst_fresh" PASS_INFO_RC=1 \
		PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_env_bad \
		PASS_LOGIN_BAD_TOKEN=pst_env_bad -- --prompt
	[ "$status" -eq 0 ]
	[ "$(cat "$PAT_FILE")" = "pst_fresh" ]
}

# Counted through the stub log rather than the prompt text, because the prompt
# is printed without a trailing newline and does not grep by line.
#
# Feeds TWO lines, not one: a single line hits EOF on the (hypothetical)
# second ask_pat call regardless of whether the "asked already?" guard
# exists, so a one-line feed cannot tell "guarded" apart from "unguarded" —
# both end up with exactly one login attempt. A second line only gets
# consumed, and a second login only gets attempted, if the guard is missing.
@test "prompts at most once" {
	run_load_tty $'pst_first_bad\npst_second' PASS_INFO_RC=1 PASS_LOGIN_RC=1 -- --prompt
	[ "$status" -eq 0 ]
	[ "$(grep -c '^login' "$STUB_LOG")" -eq 1 ]
	[ ! -f "$PAT_FILE" ]
	[[ "$output" == *"could not authenticate"* ]]
}

# A rejected cached token must not nag on every new shell. This is the real
# shell-startup shape: dot_zshrc's ssh-agent.sh calls `proton-ssh-load --quiet`
# on every new terminal with an empty agent, and stdin there is a real tty.
#
# Cannot assert `[ -z "$output" ]` here: run_load_tty's pty echoes the fed
# answer back into $output as soon as it is written, whether or not the
# script ever reads it (see the "Caveat" note on run_load_tty in
# helpers.bash) — and this path never reads stdin at all, since --prompt is
# not passed. Asserting exact emptiness would fail on that echo alone, for a
# reason that has nothing to do with the script's own output. Assert the
# absence of the script's own messages instead, the same way the sibling test
# "bare --quiet never prompts, even on a terminal" (above) already does.
@test "a rejected token warns once and then stops, without --prompt" {
	mkdir -p "$(dirname "$PAT_FILE")"
	printf 'pst_stale\n' >"$PAT_FILE"

	# First terminal after the session died: it explains itself.
	run_load_tty "unused" PASS_INFO_RC=1 PASS_LOGIN_RC=1 -- --quiet
	[ "$status" -eq 0 ]
	[[ "$output" == *"could not authenticate"* ]]
	# but never prompts, which is the thing that would block a shell
	[[ "$output" != *"Proton Pass PAT"* ]]

	# Every terminal after it, for the rest of this boot, says nothing. This is
	# the property the original version of this test was protecting: the rc
	# calls this on every new shell, and a line per prompt is noise nobody
	# reads.
	[ -e "$WARN_MARKER_REJECTED" ]
	run_load_tty "unused" PASS_INFO_RC=1 PASS_LOGIN_RC=1 -- --quiet
	[ "$status" -eq 0 ]
	[[ "$output" != *"could not authenticate"* ]]
	[[ "$output" != *"was rejected"* ]]

	[ "$(cat "$PAT_FILE")" = "pst_stale" ]
	! grep -q "ssh-agent load" "$STUB_LOG"
}

# D2, stated directly. The shell rc runs this on every terminal with an empty
# agent and passes --quiet, so a successful load is silent. The finding was that
# --quiet also silenced the one thing worth saying: that the keys did not load
# and why. Once per boot is the resolution — the first terminal explains itself,
# the rest stay quiet, and a reboot earns the message again because a reboot is
# exactly when you have forgotten.
@test "a dead session explains itself on the first shell of a boot" {
	run --separate-stderr env HOME="$HOME" STUB_LOG="$STUB_LOG" \
		PATH="$BIN:$PATH" PASS_INFO_RC=1 sh "$SCRIPT" --quiet </dev/null
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"no Proton Pass session"* ]]
	[[ "$stderr" == *"SSH keys are not loaded"* ]]
	[[ "$stderr" == *"pass-cli login"* ]]
	# on stderr, so anything capturing this script's output is unaffected
	[ -z "$output" ]
}

@test "and says nothing on the shells after it" {
	for _ in 1 2 3; do
		run --separate-stderr env HOME="$HOME" STUB_LOG="$STUB_LOG" \
			PATH="$BIN:$PATH" PASS_INFO_RC=1 sh "$SCRIPT" --quiet </dev/null
		[ "$status" -eq 0 ]
	done
	# three shells, one message
	[ -z "$stderr" ]
	[ -e "$WARN_MARKER" ]
}

# The marker is per-boot because $XDG_RUNTIME_DIR is: the OS clears it, so there
# is no cleanup to get wrong and no stale marker to outlive the problem.
@test "a new boot earns the message again" {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		PASS_INFO_RC=1 sh "$SCRIPT" --quiet </dev/null
	[ -e "$WARN_MARKER" ]

	# what a reboot does to $XDG_RUNTIME_DIR
	rm -rf "$XDG_RUNTIME_DIR"
	mkdir -p "$XDG_RUNTIME_DIR"

	run --separate-stderr env HOME="$HOME" STUB_LOG="$STUB_LOG" \
		PATH="$BIN:$PATH" PASS_INFO_RC=1 sh "$SCRIPT" --quiet </dev/null
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"no Proton Pass session"* ]]
}

# No runtime dir at all — a container, a stripped environment, a cron-like
# context. Nowhere to record that we spoke, so it speaks every time. That is the
# safe direction: these callers are not the shell rc and are not on a per-prompt
# path, so repeating costs nothing, while staying silent could hide the reason
# an unattended run did nothing.
@test "with no runtime dir it warns every time rather than never" {
	for _ in 1 2; do
		run --separate-stderr env -u XDG_RUNTIME_DIR HOME="$HOME" \
			STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" PASS_INFO_RC=1 \
			sh "$SCRIPT" --quiet </dev/null
		[ "$status" -eq 0 ]
		[[ "$stderr" == *"no Proton Pass session"* ]]
	done
}

# --quiet still has to do its job, or the finding is traded for a worse one.
@test "a successful load stays silent under --quiet" {
	run --separate-stderr env HOME="$HOME" STUB_LOG="$STUB_LOG" \
		PATH="$BIN:$PATH" sh "$SCRIPT" --quiet </dev/null
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ -z "$stderr" ]
	[ ! -e "$WARN_MARKER" ]
}

# The CI / chezmoi-apply shape: stdin is closed, not a tty, so there is no pty
# to echo anything and $output really must be empty. Kept alongside the tty
# version above rather than replacing it — each pins a different invocation
# shape, and neither's coverage substitutes for the other's.
@test "a rejected token warns once and then stops, without --prompt or a tty" {
	mkdir -p "$(dirname "$PAT_FILE")"
	printf 'pst_stale\n' >"$PAT_FILE"

	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" PASS_INFO_RC=1 \
		PASS_LOGIN_RC=1 sh "$SCRIPT" --quiet
	[ "$status" -eq 0 ]
	[[ "$output" == *"could not authenticate"* ]]

	# No pty here, so this shape can assert exact emptiness on the second run —
	# the stronger form the tty sibling above cannot use.
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" PASS_INFO_RC=1 \
		PASS_LOGIN_RC=1 sh "$SCRIPT" --quiet
	[ "$status" -eq 0 ]
	[ -z "$output" ]

	[ "$(cat "$PAT_FILE")" = "pst_stale" ]
}
