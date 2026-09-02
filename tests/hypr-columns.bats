#!/usr/bin/env bats
#
# hypr-columns arranges the active workspace into columns.
#
# Every assertion here is about the *order and content of the hyprctl calls*,
# because that is the whole of what this script does -- it has no output and no
# file it writes except the layout rule. The stub records each call, so a test
# reads the transcript the way a person would read over its shoulder.
#
# The ordering assertions are the ones that matter. `colresize` acts on whatever
# column has focus, so a focus and a resize that drift apart silently resize the
# wrong window; and reading window positions before the layout switch rather
# than after reads coordinates that the switch has already invalidated. Neither
# failure is visible in the script's exit code, so only a transcript catches it.

bats_require_minimum_version 1.5.0

setup() {
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_hypr-columns"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"
	HYPR_LOG="$BATS_TEST_TMPDIR/hyprctl.log"
	: >"$HYPR_LOG"
	STATE="$HOME/.local/state/omarchy/workspace-layouts"
	export HOME HYPR_LOG
}

# A fake hyprctl that answers the three queries the script makes and records
# every invocation. Driven by files so a test can describe a workspace without
# touching a compositor:
#
#   WS_ID        what `activeworkspace -j` reports          (default 1)
#   ACTIVE_ADDR  what `activewindow -j` reports             (default 0xaaa)
#   CLIENTS_JSON a file holding the `clients -j` payload
#   EVAL_RC      exit code for `hyprctl eval`               (default 0)
#   FOCUS_FAIL   an address whose focus dispatch fails, to prove one bad
#                window costs its own column and not the whole run
make_hyprctl_stub() {
	cat >"$BIN/hyprctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$HYPR_LOG"
case "$1" in
activeworkspace)
	printf '{"id": %s}\n' "${WS_ID:-1}"
	;;
activewindow)
	printf '{"address": "%s"}\n' "${ACTIVE_ADDR:-0xaaa}"
	;;
clients)
	cat "$CLIENTS_JSON"
	;;
eval)
	exit "${EVAL_RC:-0}"
	;;
dispatch)
	# Fail exactly one address's focus, so a test can prove the loop
	# continues rather than aborting under `set -e`.
	if [ -n "${FOCUS_FAIL:-}" ]; then
		case "$2" in
		*"$FOCUS_FAIL"*) exit 1 ;;
		esac
	fi
	;;
esac
exit 0
STUB
	chmod 755 "$BIN/hyprctl"
	ln -sf "$(command -v jq)" "$BIN/jq"
	ln -sf "$(command -v awk)" "$BIN/awk"
}

# Writes a clients payload: one tiled window per address, laid out left to right
# in the order given, so `sort_by(.at[0])` has something real to sort.
write_clients() {
	local x=0 out="" sep=""
	CLIENTS_JSON="$BATS_TEST_TMPDIR/clients.json"
	for addr in "$@"; do
		out="$out$sep{\"address\":\"$addr\",\"at\":[$x,0],\"floating\":false,\"mapped\":true,\"workspace\":{\"id\":${WS_ID:-1}}}"
		sep=","
		x=$((x + 100))
	done
	printf '[%s]\n' "$out" >"$CLIENTS_JSON"
	export CLIENTS_JSON
}

run_columns() {
	run env -u XDG_STATE_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME \
		PATH="$BIN:/usr/bin:/bin" HOME="$HOME" HYPR_LOG="$HYPR_LOG" \
		CLIENTS_JSON="$CLIENTS_JSON" \
		${WS_ID:+WS_ID="$WS_ID"} ${ACTIVE_ADDR:+ACTIVE_ADDR="$ACTIVE_ADDR"} \
		${EVAL_RC:+EVAL_RC="$EVAL_RC"} ${FOCUS_FAIL:+FOCUS_FAIL="$FOCUS_FAIL"} \
		bash "$SCRIPT"
}

@test "three windows get 25/50/25 in left-to-right order" {
	make_hyprctl_stub
	write_clients 0xleft 0xmid 0xright
	run_columns
	[ "$status" -eq 0 ]
	grep -q 'colresize 0.25' "$HYPR_LOG"
	# The pairing is the point: each resize must follow the focus of the
	# window it is meant to size. Asserting the widths alone would pass even
	# if all three landed on one window.
	grep -A2 'address:0xleft' "$HYPR_LOG" | grep -q 'colresize 0.25'
	grep -A2 'address:0xmid' "$HYPR_LOG" | grep -q 'colresize 0.5'
	grep -A2 'address:0xright' "$HYPR_LOG" | grep -q 'colresize 0.25'
}

@test "windows are ordered by x, not by the order hyprctl returned them" {
	make_hyprctl_stub
	# Deliberately out of order: the rightmost window is listed first, so a
	# script that trusted hyprctl's ordering would give it 0.25 and the
	# leftmost 0.25 while the middle got 0.5 -- wrong window wide.
	CLIENTS_JSON="$BATS_TEST_TMPDIR/clients.json"
	cat >"$CLIENTS_JSON" <<-'EOF'
		[
		 {"address":"0xright","at":[900,0],"floating":false,"mapped":true,"workspace":{"id":1}},
		 {"address":"0xleft","at":[100,0],"floating":false,"mapped":true,"workspace":{"id":1}},
		 {"address":"0xmid","at":[500,0],"floating":false,"mapped":true,"workspace":{"id":1}}
		]
	EOF
	export CLIENTS_JSON
	run_columns
	[ "$status" -eq 0 ]
	grep -A2 'address:0xmid' "$HYPR_LOG" | grep -q 'colresize 0.5'
	grep -A2 'address:0xleft' "$HYPR_LOG" | grep -q 'colresize 0.25'
}

@test "the layout switch happens before the positions are read" {
	make_hyprctl_stub
	write_clients 0xa 0xb 0xc
	run_columns
	[ "$status" -eq 0 ]
	# Converting from dwindle re-flows every window, so coordinates read
	# before the switch describe an arrangement that no longer exists. The
	# `clients` call that feeds the ordering must come after the `eval`.
	eval_line="$(grep -n '^eval ' "$HYPR_LOG" | head -1 | cut -d: -f1)"
	last_clients="$(grep -n '^clients ' "$HYPR_LOG" | tail -1 | cut -d: -f1)"
	[ "$eval_line" -lt "$last_clients" ]
}

@test "four windows are split evenly" {
	make_hyprctl_stub
	write_clients 0xa 0xb 0xc 0xd
	run_columns
	[ "$status" -eq 0 ]
	[ "$(grep -c 'colresize 0.2500' "$HYPR_LOG")" -eq 4 ]
	# No column got the three-window middle width, which is what distinguishes
	# "split evenly" from "applied the 25/50/25 case to the wrong count".
	run grep -cF 'colresize 0.5")' "$HYPR_LOG"
	[ "$status" -ne 0 ]
}

@test "two windows are split evenly" {
	make_hyprctl_stub
	write_clients 0xa 0xb
	run_columns
	[ "$status" -eq 0 ]
	[ "$(grep -c 'colresize 0.5000' "$HYPR_LOG")" -eq 2 ]
}

@test "floating and unmapped windows are not counted" {
	make_hyprctl_stub
	CLIENTS_JSON="$BATS_TEST_TMPDIR/clients.json"
	# Three tiled windows plus one floating and one unmapped. Counting either
	# would make this read as four or five and split evenly instead of
	# 25/50/25 -- the failure is a wrong layout, not an error.
	cat >"$CLIENTS_JSON" <<-'EOF'
		[
		 {"address":"0xleft","at":[100,0],"floating":false,"mapped":true,"workspace":{"id":1}},
		 {"address":"0xfloat","at":[200,0],"floating":true,"mapped":true,"workspace":{"id":1}},
		 {"address":"0xmid","at":[500,0],"floating":false,"mapped":true,"workspace":{"id":1}},
		 {"address":"0xghost","at":[600,0],"floating":false,"mapped":false,"workspace":{"id":1}},
		 {"address":"0xright","at":[900,0],"floating":false,"mapped":true,"workspace":{"id":1}}
		]
	EOF
	export CLIENTS_JSON
	run_columns
	[ "$status" -eq 0 ]
	grep -A2 'address:0xmid' "$HYPR_LOG" | grep -q 'colresize 0.5'
	run grep -c 'address:0xfloat' "$HYPR_LOG"
	[ "$status" -ne 0 ]
}

@test "windows on other workspaces are not touched" {
	make_hyprctl_stub
	CLIENTS_JSON="$BATS_TEST_TMPDIR/clients.json"
	cat >"$CLIENTS_JSON" <<-'EOF'
		[
		 {"address":"0xhere","at":[100,0],"floating":false,"mapped":true,"workspace":{"id":1}},
		 {"address":"0xthere","at":[200,0],"floating":false,"mapped":true,"workspace":{"id":9}}
		]
	EOF
	export CLIENTS_JSON
	run_columns
	[ "$status" -eq 0 ]
	run grep -c 'address:0xthere' "$HYPR_LOG"
	[ "$status" -ne 0 ]
}

@test "focus is returned to the window that had it" {
	make_hyprctl_stub
	ACTIVE_ADDR=0xmid
	export ACTIVE_ADDR
	write_clients 0xleft 0xmid 0xright
	run_columns
	[ "$status" -eq 0 ]
	# The last focus dispatch of the run, not merely a focus somewhere in it.
	last_focus="$(grep 'hl.dsp.focus' "$HYPR_LOG" | tail -1)"
	[[ "$last_focus" == *"address:0xmid"* ]]
}

@test "the layout rule is persisted so a config reload does not lose it" {
	make_hyprctl_stub
	WS_ID=7
	export WS_ID
	write_clients 0xa 0xb 0xc
	run_columns
	[ "$status" -eq 0 ]
	# Hyprland re-reads its config whenever a config file is saved, which a
	# chezmoi apply does. A runtime-only layout drops back to dwindle at that
	# moment and the arrangement stops being maintained.
	[ -f "$STATE/7.lua" ]
	grep -q 'layout = "scrolling"' "$STATE/7.lua"
	grep -q 'workspace = "7"' "$STATE/7.lua"
}

@test "one unfocusable window costs its own column, not the whole run" {
	make_hyprctl_stub
	FOCUS_FAIL=0xmid
	export FOCUS_FAIL
	write_clients 0xleft 0xmid 0xright
	run_columns
	# A window that closed between the read and the loop must not abort the
	# script under `set -e` and leave the other two unarranged.
	[ "$status" -eq 0 ]
	grep -A2 'address:0xleft' "$HYPR_LOG" | grep -q 'colresize 0.25'
	grep -A2 'address:0xright' "$HYPR_LOG" | grep -q 'colresize 0.25'
}

@test "an empty workspace exits 0 without switching the layout" {
	make_hyprctl_stub
	CLIENTS_JSON="$BATS_TEST_TMPDIR/clients.json"
	printf '[]\n' >"$CLIENTS_JSON"
	export CLIENTS_JSON
	run_columns
	[ "$status" -eq 0 ]
	# Nothing to arrange is not a reason to convert the workspace to a
	# different layout behind the user's back.
	run grep -c '^eval ' "$HYPR_LOG"
	[ "$status" -ne 0 ]
}

@test "a failed layout switch stops before resizing anything" {
	make_hyprctl_stub
	EVAL_RC=1
	export EVAL_RC
	write_clients 0xa 0xb 0xc
	run_columns
	[ "$status" -eq 1 ]
	# Widths are meaningless under dwindle, so resizing after a failed switch
	# would move windows around for no reason and report success doing it.
	run grep -c 'colresize' "$HYPR_LOG"
	[ "$status" -ne 0 ]
}
