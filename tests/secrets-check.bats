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

	# Every alarm() call goes through this stub instead of a real notify-send,
	# so the suite never pops a real desktop notification, and its argv is
	# captured so the alarm path itself can be asserted on.
	NOTIFY_LOG="$BATS_TEST_TMPDIR/notify.log"
	: >"$NOTIFY_LOG"
	make_notify_send_stub "$BIN"

	# Every item the check knows about, all readable by default. The bodies are
	# sentinels: any test that finds one in the output has found a leak.
	ITEMS="$BATS_TEST_TMPDIR/items"
	mkdir -p "$ITEMS"
	for title in "ssh auth key" "git signing key" "aur ssh key" \
		"sops age keys" "gh hosts.yml" "fixture signing key"; do
		printf 'SENTINEL-SECRET-BODY\n' >"$ITEMS/$title"
	done

	# A fixture source tree. The templates only need to CONTAIN the string
	# protonPass for the grep to find them — calling it for real would need a
	# live vault, which is the thing these tests must not need.
	SRC="$BATS_TEST_TMPDIR/src"
	mkdir -p "$SRC/.chezmoitemplates"
	printf '{{- /* protonPass */ -}}ssh-ed25519 AAAAFAKE\n' \
		>"$SRC/.chezmoitemplates/fake-pubkey"

	# Derivation source A: restore "<title>" lines, exactly the shape of
	# run_after_14-restore-secrets.sh.tmpl. Only the lines matter, not the rest.
	mkdir -p "$SRC/.chezmoiscripts"
	cat >"$SRC/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl" <<'RESTORE'
#!/bin/sh
restore "sops age keys" "$HOME/.config/sops/age/keys.txt" 600
restore "gh hosts.yml" "$HOME/.config/gh/hosts.yml" 600
RESTORE

	# Derivation source B: a pass:// URI naming both title and field. The
	# comment line is the regression guard for the false positive found while
	# writing the spec — grepping for the bare scheme matches prose.
	cat >"$SRC/.chezmoitemplates/fake-signing" <<'TMPL'
{{- /* protonPass — a stale pass:// share id once broke this */ -}}
{{- protonPass "pass://Dotfiles/fixture signing key/public_key" | trim -}}
TMPL

	export HOME STUB_LOG NOTIFY_LOG
}

run_check() {
	# -u XDG_*: without this, `chezmoi execute-template` picks up this
	# developer's real ~/.config/chezmoi/chezmoi.toml (HOME is redirected, but
	# XDG_CONFIG_HOME is not), so the render half runs against a different
	# config locally than it does in CI, and a typo in a personal config fails
	# the suite with an unrelated message. Same hazard, same fix as
	# mise.toml's [tasks.verify].
	# DBUS_SESSION_BUS_ADDRESS: set to a fixed fake value so alarm() always
	# takes the notify-send branch (and hits the stub) regardless of whether
	# the host running the suite has a real session bus.
	run env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME \
		HOME="$HOME" STUB_LOG="$STUB_LOG" NOTIFY_LOG="$NOTIFY_LOG" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=$BATS_TEST_TMPDIR/fake-bus" \
		PATH="$BIN:$PATH" PASS_ITEM_DIR="$ITEMS" "$@" sh "$SCRIPT" --source "$SRC"
}

@test "all items readable and all templates rendering exits 0" {
	run_check
	[ "$status" -eq 0 ]
}

@test "reports every item it checked" {
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"ssh auth key"* ]]
	[[ "$output" == *"sops age keys"* ]]
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
	: >"$ITEMS/sops age keys"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"sops age keys"* ]]
}

@test "checks every title named by a restore line" {
	run_check
	grep -q -- "--item-title sops age keys" "$STUB_LOG"
	grep -q -- "--item-title gh hosts.yml" "$STUB_LOG"
}

# The whole point: the field comes from the URI, not from a guess. A hand-kept
# list said `private_key` for the signing key while the template reads
# `public_key`, so the check passed on a field nothing consumed.
@test "checks a URI-named title on the field the URI names" {
	run_check
	grep -q -- "--item-title fixture signing key" "$STUB_LOG"
	grep -q -- "--field public_key" "$STUB_LOG"
}

# Regression guard for a real false positive: the script's own comment about a
# "stale pass:// share id" matches a bare-scheme grep, and the check would then
# try to fetch an item named "share id".
@test "a pass:// mention in prose is not treated as an item" {
	run_check
	! grep -q -- "--item-title share id" "$STUB_LOG"
}

@test "a derived title missing from the vault fails and names it" {
	rm "$ITEMS/sops age keys"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"sops age keys"* ]]
	[[ "$output" == *"unreadable"* ]]
}

# The general rule: derived-and-empty must not look like checked-and-fine.
@test "deriving zero titles is a fault" {
	rm -rf "$SRC/.chezmoiscripts"
	rm -f "$SRC/.chezmoitemplates/fake-signing"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"no vault items"* ]]
}

# Parsing a vault out of a URI and then querying a different one would check the
# wrong thing and report success.
@test "a URI naming another vault is a fault, not a silent wrong-vault query" {
	cat >"$SRC/.chezmoitemplates/fake-other" <<'TMPL'
{{- /* protonPass */ -}}
{{- protonPass "pass://Elsewhere/some item/note" | trim -}}
TMPL
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"Elsewhere"* ]]
}

# The fault that hid for a whole session: every restore skips and apply exits 0.
@test "a dead session fails and says so, rather than blaming the items" {
	run_check PASS_INFO_RC=1
	[ "$status" -ne 0 ]
	[[ "$output" == *"no Proton Pass session"* ]]
	[[ "$output" != *"unreadable"* ]]
}

# Reproduces the reviewer's exact trigger: an unparsable chezmoi.toml makes
# `chezmoi execute-template` exit non-zero. The `src_dir` render call is the
# only one not wrapped in `|| true`, so under `set -eu` this used to kill the
# script right there — before the summary, before alarm(), and before rc=1
# from half one could ever be reported. Both halves of the fix are exercised
# here at once: the guard turns the abort into a normal fault, and even if it
# didn't, the EXIT trap below would still have caught it.
@test "an unparsable chezmoi config fails cleanly instead of aborting the script" {
	mkdir -p "$HOME/.config/chezmoi"
	printf 'this is not valid toml [[[\n' >"$HOME/.config/chezmoi/chezmoi.toml"
	run_check
	[ "$status" -ne 0 ]
	# Half one still ran and was reported — proof the script did not die
	# before reaching the render half, it handled the render half's failure.
	[[ "$output" == *"ssh auth key"* ]]
	[ -s "$NOTIFY_LOG" ]
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
# silently checks zero templates. `chezmoi execute-template --source
# /nonexistent` exits 0 and echoes the path straight back, so a moved source
# tree reproduces this exact case — a zero count must be a fault, not a
# lookalike for "checked everything, all fine".
@test "a zero template count is a fault, not a silent pass" {
	# fake-signing (added in setup for URI derivation) also lives under
	# .chezmoitemplates and also calls protonPass, so it has to go too for the
	# template count to reach zero.
	rm "$SRC/.chezmoitemplates/fake-pubkey"
	rm "$SRC/.chezmoitemplates/fake-signing"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"0 proton template"* ]]
	# The message has to explain why zero is suspicious, not just report it.
	[[ "$output" == *"moved"* ]]
	[[ "$output" == *"renamed"* ]]
}

@test "a missing templates directory is its own fault, not a silently-skipped half" {
	rm -rf "$SRC/.chezmoitemplates"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"templates directory missing"* ]]
}

# Same subdirectory shape chezmoi itself uses to address a nested partial:
# includeTemplate takes the path relative to .chezmoitemplates, not a bare
# basename. A basename-only lookup asks chezmoi for a file at the *source
# root*, not inside .chezmoitemplates, which fails, has its stderr eaten by
# the `|| true` guard, and gets reported as "renders empty" — a false failure
# for a template that never had a chance to run.
@test "a protonPass template nested under .chezmoitemplates is found and rendered by its full relative name" {
	mkdir -p "$SRC/.chezmoitemplates/nested"
	printf '{{- /* protonPass */ -}}nested-fake\n' \
		>"$SRC/.chezmoitemplates/nested/deep"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"nested/deep"* ]]
	[[ "$output" == *"3 proton template"* ]]
}

# .chezmoitemplates only holds partials reached through includeTemplate. A
# template that calls protonPass directly, anywhere else in the tree, is real
# and must count too — otherwise "every template calling protonPass renders"
# is only true for templates that happen to live in one particular directory.
@test "a protonPass call in an ordinary .tmpl file outside .chezmoitemplates is found and rendered" {
	mkdir -p "$SRC/dot_config"
	printf '{{- /* protonPass */ -}}direct-fake\n' \
		>"$SRC/dot_config/fake-secret.conf.tmpl"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"dot_config/fake-secret.conf.tmpl"* ]]
	[[ "$output" == *"3 proton template"* ]]
}

@test "the template count reflects how many actually rendered" {
	printf '{{- /* protonPass */ -}}second-fake\n' \
		>"$SRC/.chezmoitemplates/fake-second"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"3 proton template"* ]]
}

# The spec lists this case and nothing implemented it: notify-send prints
# nothing, so without a stub capturing its argv, nothing ever proved alarm()
# was reached at all — only that the script's own stdout/stderr stayed clean.
@test "a failure alarms, and the alarm text carries no secret content" {
	: >"$ITEMS/sops age keys"
	run_check
	[ "$status" -ne 0 ]
	[ -s "$NOTIFY_LOG" ]
	notify_text="$(cat "$NOTIFY_LOG")"
	[[ "$notify_text" != *"SENTINEL-SECRET-BODY"* ]]
	[[ "$notify_text" != *"AAAAFAKE"* ]]
}

@test "a fully successful run raises no alarm" {
	run_check
	[ "$status" -eq 0 ]
	[ ! -s "$NOTIFY_LOG" ]
}

# Ordinary states, not faults. A non-zero here would alarm every container.
@test "exits 0 and silent without pass-cli" {
	# Restricted PATH rather than deleting the stub: this machine has a real
	# pass-cli on the ambient PATH, which would otherwise answer instead.
	# Same approach as tests/proton-ssh-load.bats.
	run env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME \
		HOME="$HOME" PATH="/usr/bin:/bin" sh "$SCRIPT" --source "$SRC"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# MINOR 8: `src_root="${2:-}"` used to succeed even with nothing after
# --source, then `shift 2` with one argument left died with a raw shell error
# ("shift count out of range", exit 1) instead of this script's own usage
# message and exit 2.
@test "a bare --source with no value gets the usage message, not a shell error" {
	run env HOME="$HOME" PATH="$BIN:$PATH" sh "$SCRIPT" --source
	[ "$status" -eq 2 ]
	[[ "$output" == *"usage:"* ]]
	[[ "$output" != *"shift count"* ]]
}
