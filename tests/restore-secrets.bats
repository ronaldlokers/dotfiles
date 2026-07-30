#!/usr/bin/env bats
#
# run_after_14-restore-secrets.sh.tmpl writes the file-shaped secrets. Its whole
# design is "stale beats truncated" — a failed or empty fetch must leave the
# existing file alone rather than replace it with nothing. That is the rule most
# worth pinning, because getting it wrong destroys the only copy of a secret on
# the machine and nothing would say so.
#
# The template is rendered with the pass-cli stub on PATH: has-proton-session
# shells out to `pass-cli info` at render time, so the stub is what makes the
# rendered script take the session-is-live branch.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	TMPL="$BATS_TEST_DIRNAME/../home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$STUB_LOG"
	make_pass_cli_stub "$BIN"

	ITEMS="$BATS_TEST_TMPDIR/items"
	mkdir -p "$ITEMS"
	printf 'AGE-SECRET-KEY-FAKE\n' >"$ITEMS/sops age keys"
	printf 'github.com:\n  oauth_token: fake\n' >"$ITEMS/gh hosts.yml"
	printf '[sugarrush]\nkey = "fake"\n' >"$ITEMS/sugarrush config"
	printf 'TOKEN=fake\n' >"$ITEMS/devpod dotfiles-env"

	SCRIPT="$BATS_TEST_TMPDIR/restore.sh"
	render_template "$TMPL" "$SCRIPT" "$BIN:$PATH"

	AGE="$HOME/.config/sops/age/keys.txt"
	export HOME STUB_LOG
}

run_restore() {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		PASS_ITEM_DIR="$ITEMS" "$@" sh "$SCRIPT"
}

# The rendered script is only meaningful off a container — the container branch
# exits before any restore happens.
setup_file() {
	if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
		skip "runs inside a container; the script's container branch exits early"
	fi
}

@test "writes every configured secret" {
	run_restore
	[ "$status" -eq 0 ]
	[ -s "$AGE" ]
	[ -s "$HOME/.config/gh/hosts.yml" ]
	[ -s "$HOME/.config/sugarrush/config.toml" ]
	[ -s "$HOME/.config/devpod/dotfiles-env" ]
}

@test "writes the fetched content, not something else" {
	run_restore
	[ "$status" -eq 0 ]
	[ "$(cat "$AGE")" = "AGE-SECRET-KEY-FAKE" ]
}

@test "secrets are written unreadable to anyone else" {
	run_restore
	[ "$status" -eq 0 ]
	for f in "$AGE" "$HOME/.config/gh/hosts.yml" \
		"$HOME/.config/sugarrush/config.toml" "$HOME/.config/devpod/dotfiles-env"; do
		[ "$(stat -c %a "$f")" = "600" ]
	done
}

@test "reports what it wrote" {
	run_restore
	[ "$status" -eq 0 ]
	[[ "$output" == *"wrote keys.txt"* ]]
}

# The core rule. A read failure must not touch the file that is already there.
@test "a failed fetch leaves the existing secret alone" {
	run_restore
	[ "$status" -eq 0 ]
	original="$(cat "$AGE")"
	run_restore PASS_VIEW_RC=1
	[ "$status" -eq 0 ]
	[ "$(cat "$AGE")" = "$original" ]
	[[ "$output" == *"could not read"* ]]
}

# An empty fetch is a failure that exited 0; writing it through would truncate
# the file to nothing.
@test "an empty fetch leaves the existing secret alone" {
	run_restore
	[ "$status" -eq 0 ]
	original="$(cat "$AGE")"
	empty="$BATS_TEST_TMPDIR/empty-items"
	mkdir -p "$empty"
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		PASS_ITEM_DIR="$empty" sh "$SCRIPT"
	[ "$status" -eq 0 ]
	[ -s "$AGE" ]
	[ "$(cat "$AGE")" = "$original" ]
	[[ "$output" == *"came back empty"* ]]
}

@test "a failed fetch creates nothing when there was no file to begin with" {
	run_restore PASS_VIEW_RC=1
	[ "$status" -eq 0 ]
	[ ! -e "$AGE" ]
}

@test "leaves no temp file behind after a failed fetch" {
	run_restore PASS_VIEW_RC=1
	[ "$status" -eq 0 ]
	[ -z "$(find "$HOME/.config" -name '*.tmp.*' -print -quit 2>/dev/null)" ]
}

# Fetched every apply, rewritten only on change: CI asserts a second apply
# produces no drift, so an unconditional rewrite would show up as churn.
@test "an unchanged secret is not rewritten" {
	run_restore
	[ "$status" -eq 0 ]
	before="$(stat -c %Y.%i "$AGE")"
	run_restore
	[ "$status" -eq 0 ]
	[ "$(stat -c %Y.%i "$AGE")" = "$before" ]
	[[ "$output" != *"wrote keys.txt"* ]]
}

@test "a rotated secret propagates" {
	run_restore
	[ "$status" -eq 0 ]
	printf 'AGE-SECRET-KEY-ROTATED\n' >"$ITEMS/sops age keys"
	run_restore
	[ "$status" -eq 0 ]
	[ "$(cat "$AGE")" = "AGE-SECRET-KEY-ROTATED" ]
	[[ "$output" == *"wrote keys.txt"* ]]
}

@test "a rotated secret keeps its restrictive mode" {
	run_restore
	printf 'AGE-SECRET-KEY-ROTATED\n' >"$ITEMS/sops age keys"
	run_restore
	[ "$status" -eq 0 ]
	[ "$(stat -c %a "$AGE")" = "600" ]
}

@test "reads each secret from the Dotfiles vault by title" {
	run_restore
	[ "$status" -eq 0 ]
	grep -q -- "--vault-name Dotfiles" "$STUB_LOG"
	grep -q -- "--item-title sops age keys" "$STUB_LOG"
	grep -q -- "--item-title devpod dotfiles-env" "$STUB_LOG"
}

# The apply path is the one caller that should prompt. ssh-agent.sh must not,
# so this pins which flags cross the boundary.
@test "hands the prompt flag to proton-ssh-load" {
	PSL_LOG="$BATS_TEST_TMPDIR/psl.log"
	cat >"$BIN/proton-ssh-load" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$PSL_LOG"
STUB
	chmod 755 "$BIN/proton-ssh-load"

	# has-proton-session runs `pass-cli info` at render time; it has to come
	# back non-zero here or the rendered script skips the whole branch.
	export PASS_INFO_RC=1 PSL_LOG
	render_template "$TMPL" "$SCRIPT" "$BIN:$PATH"

	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		PSL_LOG="$PSL_LOG" PASS_INFO_RC=1 sh "$SCRIPT" </dev/null
	[ "$status" -eq 0 ]
	grep -q -- "--quiet --prompt" "$PSL_LOG"
}

# The other half of the boundary above, and the higher-consequence one: this
# runs on every new terminal with an empty agent, so --prompt here would block
# every shell startup on a hung read. Only a comment enforced this before —
# nothing failed if someone added the flag. A static check on the invocation
# is enough; sourcing the whole rc would need a live shell and a real or faked
# agent, for no more coverage than reading the line it calls proton-ssh-load
# from.
@test "ssh-agent.sh never passes --prompt to proton-ssh-load" {
	rc="$BATS_TEST_DIRNAME/../home/dot_config/shell/ssh-agent.sh"
	line="$(grep -n 'proton-ssh-load' "$rc")"
	[ -n "$line" ]
	[[ "$line" == *"--quiet"* ]]
	[[ "$line" != *"--prompt"* ]]
}
