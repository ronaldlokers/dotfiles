#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_dotfiles-pending"
	HOME="$BATS_TEST_TMPDIR/home"
	STATE="$BATS_TEST_TMPDIR/state"
	mkdir -p "$HOME"
	export HOME XDG_STATE_HOME="$STATE"
}

@test "set records an action without exposing unrelated state" {
	run sh "$SCRIPT" set host-packages "sudo requires a TTY"
	[ "$status" -eq 0 ]
	run sh "$SCRIPT" show
	[ "$status" -eq 0 ]
	[[ "$output" == $'host-packages\tsudo requires a TTY'* ]]
}

@test "setting an action replaces its previous reason" {
	sh "$SCRIPT" set secrets old
	sh "$SCRIPT" set secrets new
	run sh "$SCRIPT" show
	[ "$status" -eq 0 ]
	[[ "$output" == $'secrets\tnew' ]]
}

@test "clear removes one action and leaves the other" {
	sh "$SCRIPT" set secrets one
	sh "$SCRIPT" set host-packages two
	sh "$SCRIPT" clear secrets
	run sh "$SCRIPT" show
	[ "$status" -eq 0 ]
	[[ "$output" == $'host-packages\ttwo' ]]
}
