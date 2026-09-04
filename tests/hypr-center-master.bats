#!/usr/bin/env bats
#
# hypr-center-master puts the active workspace on the master layout with the
# master centred, which lays it out as 25/50/25.
#
# The script itself is short, and the tests are about the two things that are
# not visible in its exit code: the exact shape of the workspace rule it emits,
# and whether that rule is persisted. A rule missing `orientation = "center"`
# still applies cleanly and still exits 0 -- it just leaves the master on the
# left, which is Hyprland's default and the wrong answer. And a rule that is
# only evaluated at runtime works right up until the next `chezmoi apply` saves
# a config file, at which point Hyprland reloads and the workspace silently
# reverts.
#
# It replaced tests/hypr-columns.bats, which drove a script that read window
# positions and resized every column by hand. The layout does that job, so the
# tests that pinned the hand-rolled ordering went with it.

bats_require_minimum_version 1.5.0

setup() {
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_hypr-center-master"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"
	HYPR_LOG="$BATS_TEST_TMPDIR/hyprctl.log"
	: >"$HYPR_LOG"
	STATE="$HOME/.local/state/omarchy/workspace-layouts"
	export HOME HYPR_LOG
}

# A fake hyprctl recording every call.
#
#   WS_LINE  what `activeworkspace` prints as its first line. Defaults to the
#            real format, verified against Hyprland 0.56.2:
#            `workspace ID 1 (1) on monitor DP-1:`
#   EVAL_RC  exit code for `hyprctl eval`  (default 0)
#   MFACT    what `getoption master:mfact` prints, in Hyprland's own format
#            (default "float: 0.500000"). Set it empty to model an unreadable
#            option.
make_hyprctl_stub() {
	cat >"$BIN/hyprctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$HYPR_LOG"
case "$1" in
activeworkspace)
	printf '%s\n' "${WS_LINE-workspace ID 1 (1) on monitor DP-1:}"
	printf '\tmonitorID: 0\n'
	;;
eval)
	exit "${EVAL_RC:-0}"
	;;
getoption)
	printf '%s\n' "${MFACT-float: 0.500000}"
	printf 'set: true\n'
	;;
esac
exit 0
STUB
	chmod 755 "$BIN/hyprctl"
}

run_center() {
	run env -u XDG_STATE_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME \
		PATH="$BIN:/usr/bin:/bin" HOME="$HOME" HYPR_LOG="$HYPR_LOG" \
		${WS_LINE+WS_LINE="$WS_LINE"} ${EVAL_RC:+EVAL_RC="$EVAL_RC"} \
		${MFACT+MFACT="$MFACT"} \
		bash "$SCRIPT"
}

@test "sets the active workspace to master with the orientation centred" {
	make_hyprctl_stub
	run_center
	[ "$status" -eq 0 ]
	rule="$(grep '^eval ' "$HYPR_LOG")"
	# All three parts in one rule. Asserting only `layout = "master"` would
	# pass on a rule that leaves the master on the left -- Hyprland's default,
	# and a 55/45 split rather than 25/50/25.
	[[ "$rule" == *'workspace = "1"'* ]]
	[[ "$rule" == *'layout = "master"'* ]]
	[[ "$rule" == *'orientation = "center"'* ]]
}

@test "reads the workspace id from hyprctl rather than assuming one" {
	make_hyprctl_stub
	WS_LINE="workspace ID 4 (4) on monitor HDMI-A-1:"
	export WS_LINE
	run_center
	[ "$status" -eq 0 ]
	grep '^eval ' "$HYPR_LOG" | grep -q 'workspace = "4"'
	[ -f "$STATE/4.lua" ]
}

@test "handles a special workspace's negative id" {
	make_hyprctl_stub
	# Special workspaces are negative. A parse that accepted only digits would
	# reject this and report "could not read the active workspace" on a
	# workspace the user is looking at.
	WS_LINE="workspace ID -98 (special:magic) on monitor DP-1:"
	export WS_LINE
	run_center
	[ "$status" -eq 0 ]
	grep '^eval ' "$HYPR_LOG" | grep -q 'workspace = "-98"'
}

@test "persists the rule so a config reload does not lose it" {
	make_hyprctl_stub
	run_center
	[ "$status" -eq 0 ]
	# Hyprland re-reads its config whenever a config file is saved, which a
	# chezmoi apply does. Without this file the workspace reverts at that
	# moment and nothing says why.
	[ -f "$STATE/1.lua" ]
	grep -q 'layout = "master"' "$STATE/1.lua"
	grep -q 'orientation = "center"' "$STATE/1.lua"
}

@test "the persisted rule matches the rule that was evaluated" {
	make_hyprctl_stub
	run_center
	[ "$status" -eq 0 ]
	# Two copies of the same rule that can drift is how a workspace ends up
	# behaving one way now and another way after a reload.
	evaluated="$(grep '^eval ' "$HYPR_LOG" | sed 's/^eval //')"
	[ "$evaluated" = "$(cat "$STATE/1.lua")" ]
}

@test "writes into the directory omarchy's own layout toggle owns" {
	make_hyprctl_stub
	run_center
	[ "$status" -eq 0 ]
	# omarchy-hyprland-workspace-layout-toggle writes <id>.lua here and
	# default/hypr/workspace-layouts.lua reloads the directory. A second store
	# would mean two files disagreeing about one workspace's layout.
	[ "$STATE" = "$HOME/.local/state/omarchy/workspace-layouts" ]
	[ -f "$STATE/1.lua" ]
}

@test "an unreadable workspace id is refused rather than guessed" {
	make_hyprctl_stub
	WS_LINE="something unexpected"
	export WS_LINE
	run_center
	[ "$status" -eq 1 ]
	# Hyprland accepts a rule for a workspace that does not exist, so a bad id
	# would apply silently and do nothing visible.
	run grep -c '^eval ' "$HYPR_LOG"
	[ "$status" -ne 0 ]
}

@test "nothing is persisted when the rule could not be applied" {
	make_hyprctl_stub
	EVAL_RC=1
	export EVAL_RC
	run_center
	[ "$status" -eq 1 ]
	# A file recording a layout the compositor rejected would take effect on
	# the next reload, making a failure look like a success one restart later.
	[ ! -f "$STATE/1.lua" ]
}

@test "sets the workspace's own split from the configured mfact" {
	make_hyprctl_stub
	run_center
	[ "$status" -eq 0 ]
	# Hyprland stores a live mfact per workspace, and the config value only
	# seeds a workspace that has never been laid out. Without this message a
	# workspace used with master before keeps whatever split it had, so the
	# key appears to work on some workspaces and not others.
	grep -q 'mfact exact 0.500000' "$HYPR_LOG"
}

@test "the split is read from the config, not written here a second time" {
	make_hyprctl_stub
	MFACT="float: 0.400000"
	export MFACT
	run_center
	[ "$status" -eq 0 ]
	# looknfeel.lua is the one place the ratio is stated. A hardcoded copy
	# here would drift from it silently -- the layout would simply be wrong.
	grep -q 'mfact exact 0.400000' "$HYPR_LOG"
	run grep -c 'mfact exact 0.5' "$HYPR_LOG"
	[ "$status" -ne 0 ]
}

@test "the split is set after the workspace is on master, not before" {
	make_hyprctl_stub
	run_center
	[ "$status" -eq 0 ]
	# `mfact` is a master-layout message. Sent to a workspace still on dwindle
	# or scrolling it fails with "no such layoutmsg", which is exactly what
	# happened when this was first tried by hand.
	rule_line="$(grep -n '^eval ' "$HYPR_LOG" | head -1 | cut -d: -f1)"
	mfact_line="$(grep -n 'mfact exact' "$HYPR_LOG" | head -1 | cut -d: -f1)"
	[ "$rule_line" -lt "$mfact_line" ]
}

@test "an unreadable mfact still leaves the workspace centred" {
	make_hyprctl_stub
	MFACT=""
	export MFACT
	run_center
	# The centring is the part that matters and it already succeeded; failing
	# the whole run here would undo it for a split that is merely unchanged.
	[ "$status" -eq 0 ]
	grep -q 'orientation = "center"' "$STATE/1.lua"
	run grep -c 'mfact exact' "$HYPR_LOG"
	[ "$status" -ne 0 ]
}
