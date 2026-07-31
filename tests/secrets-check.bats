#!/usr/bin/env bats
#
# dotfiles-secrets-check verifies the Proton Pass path in two halves, because
# they are different code paths: every vault item readable by title, and every
# template calling protonPass rendering non-empty. `mise run secrets-check` was
# green while `chezmoi apply` was failing on a stale pass:// reference — item
# readability said nothing about whether a template could render.
#
# The render half runs against a fixture source tree, not the real one: these
# pin the mechanism (find the templates, render them, judge the result), while
# the real signing-pubkey is exercised by running the check by hand against the
# live vault.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_dotfiles-secrets-check"

	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$STUB_LOG"
	make_pass_cli_stub "$BIN"

	# Every item the check knows about, all readable by default. The bodies are
	# sentinels: any test that finds one in the output has found a leak.
	ITEMS="$BATS_TEST_TMPDIR/items"
	mkdir -p "$ITEMS"
	for title in "ssh auth key" "git signing key" "aur ssh key" \
		"sops age keys" "gh hosts.yml" "sugarrush config" \
		"devpod dotfiles-env" "devpod project-tokens"; do
		printf 'SENTINEL-SECRET-BODY\n' >"$ITEMS/$title"
	done

	# A fixture source tree. The templates only need to CONTAIN the string
	# protonPass for the grep to find them — calling it for real would need a
	# live vault, which is the thing these tests must not need.
	SRC="$BATS_TEST_TMPDIR/src"
	mkdir -p "$SRC/.chezmoitemplates"
	printf '{{- /* protonPass */ -}}ssh-ed25519 AAAAFAKE\n' \
		>"$SRC/.chezmoitemplates/fake-pubkey"

	export HOME STUB_LOG
}

run_check() {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		PASS_ITEM_DIR="$ITEMS" "$@" sh "$SCRIPT" --source "$SRC"
}

@test "all items readable and all templates rendering exits 0" {
	run_check
	[ "$status" -eq 0 ]
}

@test "reports every item it checked" {
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"ssh auth key"* ]]
	[[ "$output" == *"devpod project-tokens"* ]]
}

@test "reports the templates it rendered" {
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"fake-pubkey"* ]]
}

# The rule that turns a monitoring tool into a leak.
@test "never emits secret contents" {
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" != *"SENTINEL-SECRET-BODY"* ]]
	[[ "$output" != *"AAAAFAKE"* ]]
}

@test "an unreadable item fails and names only that item" {
	rm "$ITEMS/gh hosts.yml"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"gh hosts.yml"* ]]
	[[ "$output" == *"unreadable"* ]]
	# One failure, not eight: a broken session or a wrong vault name would
	# make every item unreadable, and that must not look like this case.
	[ "$(printf '%s\n' "$output" | grep -c 'unreadable')" -eq 1 ]
}

# An empty fetch is a failure that exited 0 — the same trap the restore script
# guards against.
@test "an item that comes back empty fails" {
	: >"$ITEMS/sugarrush config"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"sugarrush config"* ]]
}

# The fault that hid for a whole session: every restore skips and apply exits 0.
@test "a dead session fails and says so, rather than blaming the items" {
	run_check PASS_INFO_RC=1
	[ "$status" -ne 0 ]
	[[ "$output" == *"no Proton Pass session"* ]]
	[[ "$output" != *"unreadable"* ]]
}

@test "a template that renders empty fails and names it" {
	printf '{{- /* protonPass */ -}}\n' >"$SRC/.chezmoitemplates/fake-empty"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"fake-empty"* ]]
}

# A template with no protonPass call is not this check's business.
@test "ignores templates that do not touch proton" {
	printf 'nothing interesting\n' >"$SRC/.chezmoitemplates/unrelated"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" != *"unrelated"* ]]
}

# An empty render half must not look like a passing one: if the protonPass
# marker ever gets renamed, or the templates directory moves, or a future
# repo genuinely has none, the for loop over `grep -rl` matches nothing and
# silently checks zero templates. Every other test's fixture always contains
# at least one protonPass template, so this is the one case where "checked
# everything, all fine" and "checked nothing" must not print the same thing.
@test "reports zero templates, distinguishably, when none match" {
	rm "$SRC/.chezmoitemplates/fake-pubkey"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"0 proton template"* ]]
}

@test "the template count reflects how many actually rendered" {
	printf '{{- /* protonPass */ -}}second-fake\n' \
		>"$SRC/.chezmoitemplates/fake-second"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"2 proton template"* ]]
}

# Ordinary states, not faults. A non-zero here would alarm every container.
@test "exits 0 and silent without pass-cli" {
	# Restricted PATH rather than deleting the stub: this machine has a real
	# pass-cli on the ambient PATH, which would otherwise answer instead.
	# Same approach as tests/proton-ssh-load.bats.
	run env HOME="$HOME" PATH="/usr/bin:/bin" sh "$SCRIPT" --source "$SRC"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}
