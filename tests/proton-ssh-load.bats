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
	export HOME STUB_LOG
}

# Runs the script with only the stub dir plus the real coreutils on PATH.
run_load() {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" "$@" sh "$SCRIPT"
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
	[ "$status" -eq 0 ]
	[ -z "$output" ]
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
	[ -z "$output" ]
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

@test "a rejected cached token re-prompts and the new one replaces it" {
	mkdir -p "$(dirname "$PAT_FILE")"
	printf 'pst_stale\n' >"$PAT_FILE"
	run_load_tty "pst_fresh" PASS_INFO_RC=1 PASS_LOGIN_BAD_TOKEN=pst_stale -- --prompt
	[ "$status" -eq 0 ]
	[[ "$output" == *"was rejected"* ]]
	[ "$(cat "$PAT_FILE")" = "pst_fresh" ]
	grep -q "ssh-agent load" "$STUB_LOG"
}

# Stale beats truncated, the same rule restore() follows.
@test "a rejected cached token survives a rejected replacement" {
	mkdir -p "$(dirname "$PAT_FILE")"
	printf 'pst_stale\n' >"$PAT_FILE"
	run_load_tty "pst_also_bad" PASS_INFO_RC=1 PASS_LOGIN_RC=1 -- --prompt
	[ "$status" -eq 0 ]
	[ "$(cat "$PAT_FILE")" = "pst_stale" ]
	[[ "$output" == *"could not authenticate"* ]]
	! grep -q "ssh-agent load" "$STUB_LOG"
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
@test "prompts at most once" {
	run_load_tty "pst_bad_typed" PASS_INFO_RC=1 PASS_LOGIN_RC=1 -- --prompt
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
@test "a rejected token is silent without --prompt" {
	mkdir -p "$(dirname "$PAT_FILE")"
	printf 'pst_stale\n' >"$PAT_FILE"
	run_load_tty "unused" PASS_INFO_RC=1 PASS_LOGIN_RC=1 -- --quiet
	[ "$status" -eq 0 ]
	[[ "$output" != *"Proton Pass PAT"* ]]
	[[ "$output" != *"was rejected"* ]]
	[ "$(cat "$PAT_FILE")" = "pst_stale" ]
	! grep -q "ssh-agent load" "$STUB_LOG"
}

# The CI / chezmoi-apply shape: stdin is closed, not a tty, so there is no pty
# to echo anything and $output really must be empty. Kept alongside the tty
# version above rather than replacing it — each pins a different invocation
# shape, and neither's coverage substitutes for the other's.
@test "a rejected token is silent without --prompt and without a tty" {
	mkdir -p "$(dirname "$PAT_FILE")"
	printf 'pst_stale\n' >"$PAT_FILE"
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" PASS_INFO_RC=1 \
		PASS_LOGIN_RC=1 sh "$SCRIPT" --quiet
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ "$(cat "$PAT_FILE")" = "pst_stale" ]
}
