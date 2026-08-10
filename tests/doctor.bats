#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_dotfiles-doctor"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.config/mise" "$HOME/.local/bin" "$HOME/.config/sops/age" "$HOME/.local/state/dotfiles"
	export HOME
	# The doctor is intentionally tested with a minimal PATH: missing host tools
	# must be reported, never satisfied by the developer's own machine.
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"
	export PATH="$BIN:/usr/bin:/bin"
}

@test "help is local and documents live mode" {
	run sh "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"dotfiles-doctor"* ]]
	[[ "$output" == *"--live"* ]]
}

@test "unknown options are refused" {
	run sh "$SCRIPT" --fix
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown argument"* ]]
}

@test "missing prerequisites produce actionable faults" {
	printf '[tools]\n' >"$HOME/.config/mise/config.toml"
	run env -u XDG_STATE_HOME sh "$SCRIPT"
	[ "$status" -ne 0 ]
	[[ "$output" == *"chezmoi: command not found"* ]]
	[[ "$output" == *"pass-cli: command not found"* ]]
}

@test "live mode is bounded and does not print credentials" {
	cat >"$BIN/pass-cli" <<'STUB'
#!/bin/sh
sleep 30
STUB
	chmod +x "$BIN/pass-cli"
	# The command is expected to return promptly because the live probe has a
	# five-second timeout. The rest of the report remains useful.
	printf '[tools]\n' >"$HOME/.config/mise/config.toml"
	run timeout 8 sh "$SCRIPT" --live
	[ "$status" -ne 124 ]
	[[ "$output" == *"Proton Pass: live session unavailable"* ]]
	[[ "$output" != *"pst_"* ]]
}
