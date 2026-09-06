#!/usr/bin/env bats
#
# allowed_signers.tmpl decides who git trusts to have signed a commit. It emits
# the retired key bounded with valid-before, then the current key unbounded --
# skipping that second line when the two are the same key, because emitting the
# retired key again without a bound hands back exactly the forgery window the
# first line closes.
#
# The guard is the whole file. It compared whole strings until 28 August 2026,
# and the two sources disagree about the trailing comment: the agent fallback in
# signing-pubkey strips it (`print $1" "$2`) while the vault's public_key field
# carries it. So the vault path returned
#
#     ssh-ed25519 AAAA… git-signing
#
# against a bare $retiredKey, `ne` was true no matter what, and the retired key
# went out a second time with nothing bounding it -- silently, on every machine
# these dotfiles are applied to, for as long as the rotation stayed unfinished.
#
# The first test is the one that pins that. It fails against the pre-fix
# template with:
#
#     not ok 1 the vault's key, comment and all, is recognised as the retired one
#     # (in test file tests/allowed-signers.bats, line 84)
#     #   `[ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]' failed
#
# because the pre-fix template emits two lines where this asserts one.
#
# Both external calls signing-pubkey makes are stubbed. pass-cli through the
# usual helper; ssh-add separately and deliberately -- without it the fallback
# reaches the *real* agent on the developer's machine, and a test whose result
# depends on which keys happen to be loaded proves nothing.

bats_require_minimum_version 1.5.0

# The key the template retires, byte for byte as allowed_signers.tmpl carries
# it: type and base64, no comment. Public material, and already in the tree.
RETIRED="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMj1CJnE/kvOEVs8B8AWfDSKAtICy8fP45R0QYAZdhbf"
OTHER="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

setup() {
	load 'helpers'
	REPO="$BATS_TEST_DIRNAME/.."
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.config/chezmoi"
	export HOME

	STUB_BIN="$BATS_TEST_TMPDIR/bin"
	make_pass_cli_stub "$STUB_BIN"

	# The agent fallback must not reach a real agent. Exit 1 is "no identities",
	# which is what signing-pubkey's awk turns into an empty string.
	cat >"$STUB_BIN/ssh-add" <<-'STUB'
		#!/bin/sh
		[ -n "${FAKE_AGENT_KEY:-}" ] || exit 1
		printf '%s git-signing\n' "$FAKE_AGENT_KEY"
	STUB
	chmod 755 "$STUB_BIN/ssh-add"

	PASS_ITEM_DIR="$BATS_TEST_TMPDIR/items"
	mkdir -p "$PASS_ITEM_DIR"
	export PASS_ITEM_DIR

	printf '[data]\n    email = "signer@example.test"\n    role = "personal"\n' \
		>"$HOME/.config/chezmoi/chezmoi.toml"
}

# The vault answers with whatever this writes, under the title signing-pubkey
# asks for.
vault_holds() {
	printf '%s\n' "$1" >"$PASS_ITEM_DIR/git signing key"
}

render() {
	env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME \
		PATH="$STUB_BIN:$PATH" HOME="$HOME" \
		chezmoi execute-template --source "$REPO" \
		<"$REPO/home/dot_config/git/allowed_signers.tmpl"
}

@test "the vault's key, comment and all, is recognised as the retired one" {
	vault_holds "$RETIRED git-signing"
	run render
	[ "$status" -eq 0 ]
	# One line only. Two means the retired key was emitted again unbounded.
	[ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
	[[ "$output" == *'valid-before="20260811Z"'* ]]
}

@test "no line carries the retired key without a bound on it" {
	vault_holds "$RETIRED git-signing"
	run render
	# The assertion the whole file exists for, stated directly rather than as a
	# line count: every line mentioning the retired key must be bounded.
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		case "$line" in
		*"$RETIRED"*)
			[[ "$line" == *"valid-before="* ]]
			;;
		esac
	done <<<"$output"
}

@test "a genuinely rotated key is emitted unbounded, alongside the bounded retired one" {
	vault_holds "$OTHER new-signing-key"
	run render
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
	[[ "$output" == *"valid-before=\"20260811Z\" $RETIRED"* ]]
	[[ "$output" == *"signer@example.test $OTHER new-signing-key"* ]]
}

@test "the comment is not the identity: a bare retired key is caught too" {
	vault_holds "$RETIRED"
	run render
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}

@test "an unreadable vault falls back to the agent, and the same guard applies" {
	# No item file: `item view` prints nothing, which is the "came back empty"
	# case, so signing-pubkey takes the ssh-add fallback.
	FAKE_AGENT_KEY="$RETIRED" run render
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}

@test "neither vault nor agent still leaves the retired key bounded and trusted" {
	# Nothing anywhere: the current-key line is skipped entirely, but history
	# signed by the retired key must keep verifying.
	run render
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
	[[ "$output" == *'valid-before="20260811Z"'* ]]
}
