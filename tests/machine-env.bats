#!/usr/bin/env bats
#
# ~/.config/dotfiles/machine.env carries the facts a script cannot work out for
# itself: which profiles this machine has, and which Proton Pass vault its
# secrets live in. chezmoi renders it on every apply.
#
# It exists because the profile set is a *template* construct and the scripts
# that need it are not templates. Three of the four vault consumers are plain
# files — `mise run secrets-check` runs one straight out of the source tree —
# so turning them into templates to interpolate a vault name would break the
# way they are run and tested. A file they source instead keeps them plain.
#
# The fallback is the load-bearing part. A machine mid-bootstrap has no
# machine.env yet: the secrets restore runs from the same apply that writes it,
# and a script that read an empty vault name would ask Proton for items in a
# vault called "" and report every one of them missing. Absent means personal,
# which is what every machine was before this file existed.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	REPO="$BATS_TEST_DIRNAME/.."
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.config/chezmoi"
	export HOME
}

set_role() {
	printf '[data]\n    role = %s\n' "\"$1\"" >"$HOME/.config/chezmoi/chezmoi.toml"
}

render_machine_env() {
	env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME "$@" HOME="$HOME" \
		chezmoi execute-template --source "$REPO" \
		<"$REPO/home/dot_config/dotfiles/machine.env.tmpl"
}

@test "a personal machine names the Dotfiles vault" {
	set_role personal
	run render_machine_env
	[ "$status" -eq 0 ]
	[[ "$output" == *'DOTFILES_VAULT="Dotfiles"'* ]]
}

@test "a work machine names the Work vault" {
	set_role work
	run render_machine_env
	[ "$status" -eq 0 ]
	[[ "$output" == *'DOTFILES_VAULT="Work"'* ]]
}

@test "the profile set is carried too, for scripts that cannot see templates" {
	set_role work
	run render_machine_env
	[[ "$output" == *'DOTFILES_PROFILES='* ]]
	[[ "$output" == *" work "* ]]
	[[ "$output" == *" host "* ]]
}

@test "it is sourceable shell, not something a shell will choke on" {
	set_role personal
	render_machine_env >"$BATS_TEST_TMPDIR/machine.env"
	run sh -c ". '$BATS_TEST_TMPDIR/machine.env' && printf '%s' \"\$DOTFILES_VAULT\""
	[ "$status" -eq 0 ]
	[ "$output" = "Dotfiles" ]
}

@test "it carries no secret material, only facts" {
	set_role work
	run render_machine_env
	! grep -qiE 'token|password|pst_|BEGIN .*PRIVATE' <<<"$output"
}

# --- what the consumers do with it -------------------------------------------
#
# Each of these runs the real script with a machine.env in place and asserts the
# vault it asked Proton for. The pass-cli stub records every call, so the vault
# name is read off the argv rather than inferred.

setup_consumer() {
	BIN="$BATS_TEST_TMPDIR/bin"
	STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$STUB_LOG"
	make_pass_cli_stub "$BIN"
	mkdir -p "$HOME/.config/dotfiles"
	export STUB_LOG
}

write_machine_env() {
	printf 'DOTFILES_PROFILES=" host %s linux "\nDOTFILES_VAULT="%s"\n' \
		"$1" "$2" >"$HOME/.config/dotfiles/machine.env"
}

@test "proton-ssh-load loads from the vault the facts file names" {
	setup_consumer
	write_machine_env work Work
	run env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" STUB_LOG="$STUB_LOG" \
		XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run" PATH="$BIN:$PATH" \
		sh "$REPO/home/dot_local/bin/executable_proton-ssh-load" --quiet
	[ "$status" -eq 0 ]
	grep -q -- "--vault-name Work" "$STUB_LOG"
	! grep -q -- "--vault-name Dotfiles" "$STUB_LOG"
}

@test "and falls back to Dotfiles when the facts file is not there yet" {
	setup_consumer
	rm -f "$HOME/.config/dotfiles/machine.env"
	run env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" STUB_LOG="$STUB_LOG" \
		XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run" PATH="$BIN:$PATH" \
		sh "$REPO/home/dot_local/bin/executable_proton-ssh-load" --quiet
	[ "$status" -eq 0 ]
	grep -q -- "--vault-name Dotfiles" "$STUB_LOG"
}

# A facts file that exists but says nothing about the vault — a partial write, a
# hand-edit — must not resolve to the empty vault. Every item would come back
# missing and the report would blame the vault contents rather than the file.
@test "an empty vault name in the facts file is not an empty vault" {
	setup_consumer
	printf 'DOTFILES_PROFILES=" host personal linux "\nDOTFILES_VAULT=""\n' \
		>"$HOME/.config/dotfiles/machine.env"
	run env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" STUB_LOG="$STUB_LOG" \
		XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run" PATH="$BIN:$PATH" \
		sh "$REPO/home/dot_local/bin/executable_proton-ssh-load" --quiet
	[ "$status" -eq 0 ]
	grep -q -- "--vault-name Dotfiles" "$STUB_LOG"
	! grep -q -- '--vault-name  *$' "$STUB_LOG"
}

# The signing key's public half is read by a template rather than a script, so
# it takes the vault from the profile set directly.
@test "the signing-pubkey template reads the work vault on a work machine" {
	set_role work
	run env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" PATH="$BATS_TEST_TMPDIR/nothing:$PATH" \
		chezmoi execute-template --source "$REPO" \
		'{{ includeTemplate "vault-name" . }}'
	[ "$status" -eq 0 ]
	[ "$output" = "Work" ]
}

@test "and the personal vault otherwise" {
	set_role personal
	run env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" \
		chezmoi execute-template --source "$REPO" \
		'{{ includeTemplate "vault-name" . }}'
	[ "$status" -eq 0 ]
	[ "$output" = "Dotfiles" ]
}
