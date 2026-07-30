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
