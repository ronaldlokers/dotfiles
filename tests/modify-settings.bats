#!/usr/bin/env bats
#
# modify_settings.json merges this repo's baseline into whatever Claude Code has
# already written to ~/.claude/settings.json. Two properties matter and neither
# is obvious from reading it:
#
#   1. Managed-wins on shared top-level keys, so deleting a plugin here actually
#      deletes it on the machine — but unknown keys Claude Code invented survive.
#   2. The output is a fixed point. It runs on every apply and CI asserts a
#      second apply produces no drift, so feeding its own output back in has to
#      reproduce byte-identical output.
#
# The first two tests here replace a pair of one-liners that used to live inside
# mise.toml's lint task.

# `run --separate-stderr` below is a 1.5.0+ feature; declaring the floor is what
# stops bats warning about it on every run.
bats_require_minimum_version 1.5.0

setup() {
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_claude/modify_settings.json"
}

# A scratch PATH holding only the binaries named, used to simulate a machine
# where jq is not installed yet.
path_with() {
	local d="$BATS_TEST_TMPDIR/bin-$RANDOM"
	mkdir -p "$d"
	local tool
	for tool in "$@"; do ln -sf "$(command -v "$tool")" "$d/$tool"; done
	printf '%s' "$d"
}

@test "emits valid JSON when merging into existing settings" {
	run bash -c "printf '%s' '{\"agentPushNotifEnabled\": true}' | bash '$SCRIPT'"
	[ "$status" -eq 0 ]
	printf '%s' "$output" | jq empty
}

# On a clean-HOME first apply, managed files are written before the script that
# installs mise's tools, so jq is genuinely absent. Passing the input through is
# the expected behaviour there, not an error path.
@test "passes input through unchanged when jq is absent" {
	local bin
	# bash as well as cat: the scratch PATH has to be able to start the script,
	# not just let it run. jq is the only thing deliberately missing.
	bin="$(path_with cat bash)"
	run bash -c "printf '%s' '{\"agentPushNotifEnabled\": true}' | PATH='$bin' bash '$SCRIPT'"
	[ "$status" -eq 0 ]
	printf '%s' "$output" | jq empty
	[[ "$output" == *"agentPushNotifEnabled"* ]]
}

@test "emits the baseline verbatim when there is no file on disk yet" {
	run bash -c "printf '' | bash '$SCRIPT'"
	[ "$status" -eq 0 ]
	printf '%s' "$output" | jq empty
	[ "$(printf '%s' "$output" | jq -r '.includeCoAuthoredBy')" = "false" ]
}

# The formatting trap the script's header calls out: a first apply with no jq
# and a second apply with jq must not disagree byte-for-byte, or CI sees drift.
@test "output is a fixed point — feeding it back in reproduces it" {
	first="$(printf '' | bash "$SCRIPT")"
	second="$(printf '%s' "$first" | bash "$SCRIPT")"
	[ "$first" = "$second" ]
	third="$(printf '%s' "$second" | bash "$SCRIPT")"
	[ "$second" = "$third" ]
}

@test "keeps top-level keys the repo has never heard of" {
	run bash -c "printf '%s' '{\"agentPushNotifEnabled\": true, \"someFutureKey\": 42}' | bash '$SCRIPT'"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.agentPushNotifEnabled')" = "true" ]
	[ "$(printf '%s' "$output" | jq -r '.someFutureKey')" = "42" ]
}

# The merge is shallow on purpose. A deep merge would let a plugin removed from
# the baseline linger on the machine forever, because nothing would ever delete
# a key nested inside enabledPlugins.
@test "replaces enabledPlugins wholesale rather than deep-merging it" {
	run bash -c "printf '%s' '{\"enabledPlugins\": {\"ghost@nowhere\": true}}' | bash '$SCRIPT'"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.enabledPlugins["ghost@nowhere"]')" = "null" ]
	[ "$(printf '%s' "$output" | jq -r '.enabledPlugins["superpowers@claude-plugins-official"]')" = "true" ]
}

@test "the baseline wins on a shared top-level key" {
	run bash -c "printf '%s' '{\"theme\": \"light\"}' | bash '$SCRIPT'"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.theme')" = "dark" ]
}

# Loud and stuck-until-fixed beats silently discarding whatever the user had:
# there is no managed version of a key absent from the baseline, so there is
# nothing safe to merge a corrupt file into.
@test "fails rather than emitting anything when stdin is not valid JSON" {
	# --separate-stderr so jq's parse error does not count as output: the claim
	# is that nothing lands on stdout for chezmoi to write.
	run --separate-stderr bash -c "printf '%s' 'not json at all' | bash '$SCRIPT'"
	[ "$status" -ne 0 ]
	[ -z "$output" ]
	[ -n "$stderr" ]
}

# --- the marketplace pins that were not pins (2026-08-08) --------------------
#
# The three third-party marketplaces carried a `ref` pinning each to a commit.
# Nothing enforced it: after Claude Code's plugin sweep wiped them, the
# supported repair (`claude plugin marketplace add <repo>`) has no way to
# express a ref, and every restored clone came back on branch `main` at
# upstream HEAD. A config field that reads as supply-chain control while
# enforcing nothing is worse than an honest absence, so they were removed.
#
# This pins the removal: a ref reappearing means someone believes it does
# something, and that belief needs re-testing against Claude Code rather than
# assuming.
@test "no marketplace declares a ref it cannot enforce" {
	run bash "$SCRIPT" </dev/null
	[ "$status" -eq 0 ]
	refs="$(printf '%s' "$output" | jq -r '[.extraKnownMarketplaces[].source.ref // empty] | length')"
	[ "$refs" -eq 0 ]
}

# The marketplaces themselves must survive: dropping the ref must not drop the
# declaration, or the plugins stop resolving entirely.
@test "all four marketplaces are still declared" {
	run bash "$SCRIPT" </dev/null
	[ "$status" -eq 0 ]
	for m in claude-plugins-official caveman impeccable karpathy-skills; do
		printf '%s' "$output" | jq -e --arg m "$m" '.extraKnownMarketplaces[$m].source.repo' >/dev/null
	done
}

# --- Moshi's hooks live in the baseline, not on disk (2026-08-08) ------------
#
# `moshi-hook install` writes its hooks straight into ~/.claude/settings.json.
# The merge here is managed-wins on every top-level key, and `hooks` is one of
# them — so the next `chezmoi apply` would delete them, silently, and Moshi
# would simply stop reporting anything with nothing to say why.
#
# The resolution is the one the merge was designed for: the repo is the sole
# authority, so the hooks belong in the baseline. These pin that, because the
# failure mode is invisible — everything keeps working except the phone.

@test "the Moshi hooks survive an apply" {
	run bash "$SCRIPT" </dev/null
	[ "$status" -eq 0 ]
	n="$(printf '%s' "$output" | jq -r '[..|.command? // empty]|map(select(test("moshi-hook")))|length')"
	[ "$n" -eq 9 ]
}

# Merging over a settings.json that has them must not drop them either — that
# is the actual apply, and the case that would regress.
@test "they survive merging over an on-disk copy that already has them" {
	baseline="$(bash "$SCRIPT" </dev/null)"
	run bash "$SCRIPT" <<<"$baseline"
	[ "$status" -eq 0 ]
	n="$(printf '%s' "$output" | jq -r '[..|.command? // empty]|map(select(test("moshi-hook")))|length')"
	[ "$n" -eq 9 ]
}

# All seven categories, named. A partial set is the shape a bad merge leaves
# behind, and it would look like "mostly working".
@test "every hook category Moshi installs is present" {
	run bash "$SCRIPT" </dev/null
	for k in PermissionRequest PostToolUse PreToolUse SessionEnd SessionStart Stop UserPromptSubmit; do
		printf '%s' "$output" | jq -e --arg k "$k" '.hooks[$k]' >/dev/null
	done
}

# The rtk-rewrite hook was here first and shares PreToolUse with two of Moshi's.
# Adding them must not have displaced it.
@test "the rtk-rewrite hook still runs on Bash" {
	run bash "$SCRIPT" </dev/null
	printf '%s' "$output" | jq -e '.hooks.PreToolUse[]|select(.matcher=="Bash")|.hooks[]|select(.command|test("rtk-rewrite"))' >/dev/null
}

# moshi-hook install bakes in an absolute /home/<user>/ path. The baseline is
# applied to whatever machine runs it, so the path has to be $HOME-relative or
# it is wrong everywhere except the machine it was captured on.
@test "no hook command hardcodes a home directory" {
	run bash "$SCRIPT" </dev/null
	[[ "$output" != *"/home/ronald"* ]]
	printf '%s' "$output" | jq -e '[..|.command? // empty]|map(select(test("moshi-hook")))|all(test("\\$HOME"))' >/dev/null
}
