#!/usr/bin/env bats
#
# The statusline runs on every prompt, so a failure is loud but harmless-looking
# — a garbled line, not an error anyone chases. The arithmetic is the risk:
# it reports context *used* while Claude Code hands it the percentage
# *remaining*, and it does integer comparisons on a value that arrives as a
# float.

setup() {
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_claude/executable_statusline.sh"
	REPO="$BATS_TEST_DIRNAME/.."
}

# Feeds the script one status JSON payload and strips the SGR escapes, so
# assertions read against the text rather than the colouring.
render() {
	local dir="${2:-$REPO}"
	printf '{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"%s"},"context_window":{"remaining_percentage":%s}}' \
		"$dir" "$1" | bash "$SCRIPT" | sed 's/\x1b\[[0-9;]*m//g'
}

# Same, for payloads that are not the happy path.
render_raw() {
	printf '%s' "$1" | bash "$SCRIPT" | sed 's/\x1b\[[0-9;]*m//g'
}

@test "reports context used, not the remaining percentage it is given" {
	run render 90
	[[ "$output" == *"10%"* ]]
	[[ "$output" != *"90%"* ]]
}

@test "the bar fills in proportion to context used" {
	run render 100 # nothing used
	[[ "$output" == *"░░░░░░░░ 0%"* ]]
	run render 0 # all used
	[[ "$output" == *"████████ 100%"* ]]
	run render 50
	[[ "$output" == *"████░░░░ 50%"* ]]
}

@test "the bar is always eight cells wide" {
	for pct in 100 87 62 33 8 0; do
		run render "$pct"
		bar="$(sed 's/[^█░]//g' <<<"$output")"
		[ "${#bar}" -eq 8 ]
	done
}

# The documented trap: a payload like 0.5 strips to an empty string, and the
# integer comparisons then error out with "integer expression expected". The
# script treats any non-integer as 0% remaining, i.e. the worst case.
@test "a bare fractional percentage degrades to full-usage, not an error" {
	run render 0.5
	[ "$status" -eq 0 ]
	[[ "$output" == *"100%"* ]]
	[[ "$output" != *"integer expression"* ]]
}

@test "a float percentage truncates rather than breaking" {
	run render 62.7
	[ "$status" -eq 0 ]
	[[ "$output" == *"38%"* ]]
}

@test "shows the directory basename, not the whole path" {
	run render 50 /tmp/some/deep/workspace
	[[ "$output" == *"workspace"* ]]
	[[ "$output" != *"/tmp/some/deep"* ]]
}

@test "shows the model name" {
	run render 50
	[[ "$output" == *"Opus 5"* ]]
}

@test "omits the context segment entirely when the payload has no percentage" {
	run render_raw '{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp"}}'
	[ "$status" -eq 0 ]
	[[ "$output" != *"%"* ]]
	[[ "$output" == *"Opus 5"* ]]
}

@test "falls back to a placeholder when the payload has no model" {
	run render_raw '{"workspace":{"current_dir":"/tmp"}}'
	[ "$status" -eq 0 ]
	[[ "$output" == *"?"* ]]
}

@test "shows the branch inside a git repo" {
	run render 50
	[[ "$output" == *"$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"* ]]
}

@test "omits the git segment outside a repo" {
	outside="$BATS_TEST_TMPDIR/not-a-repo"
	mkdir -p "$outside"
	run render 50 "$outside"
	[ "$status" -eq 0 ]
	[[ "$output" == *"not-a-repo"* ]]
	# no branch glyph
	[[ "$output" != *"󰘬"* ]]
}

@test "counts dirty files" {
	repo="$BATS_TEST_TMPDIR/dirty"
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" config user.email t@example.com
	git -C "$repo" config user.name t
	printf 'a\n' >"$repo/tracked"
	git -C "$repo" add tracked
	git -C "$repo" commit -qm init
	printf 'b\n' >"$repo/tracked"
	printf 'c\n' >"$repo/untracked"
	run render 50 "$repo"
	# one modified plus one untracked
	[[ "$output" == *"󰏫 2"* ]]
}

@test "emits no trailing newline" {
	out="$(printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"/tmp"}}' | bash "$SCRIPT"; printf 'END')"
	[[ "$out" == *"END" ]]
	[[ "$out" != *$'\n'"END" ]]
}
