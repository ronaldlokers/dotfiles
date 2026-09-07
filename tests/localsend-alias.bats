#!/usr/bin/env bats
#
# modify_shared_preferences.json sets LocalSend's advertised alias to the name
# chezmoi recorded, so the machine shows up on the LAN as `hooks` rather than
# as the "Neat Avocado" LocalSend invents on first launch.
#
# It is a modify_ script for a reason that outranks convenience: the target
# holds LocalSend's RSA private key, its paired devices and its receive
# history. chezmoi pipes the current file through and takes stdout, so the key
# is read and written on the machine and never reaches the source tree. The
# tests that matter most here are the ones asserting everything except the
# alias survives, and that a refusal returns the input unchanged rather than a
# best effort — corrupting this file costs the device its identity.
#
# One honest caveat about the no-jq test below: it does not pin the script's
# `command -v jq` check. Removing that check leaves this whole file green,
# because a missing jq also fails the `jq -e .` validity test and refuses there
# instead. The behaviour is pinned; that particular line is not.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	REPO="$BATS_TEST_DIRNAME/.."
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.config/chezmoi"
	export HOME
	SCRIPT="$BATS_TEST_TMPDIR/modify.sh"
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"
}

set_name() {
	printf '[data]\n    name = %s\n' "\"$1\"" >"$HOME/.config/chezmoi/chezmoi.toml"
}

render() {
	render_template \
		"$REPO/home/dot_local/share/org.localsend.localsend_app/modify_shared_preferences.json.tmpl" \
		"$SCRIPT" "$PATH" "$REPO"
}

modify() {
	run --separate-stderr env PATH="$PATH" HOME="$HOME" sh "$SCRIPT"
}

# A PATH holding only the binaries named, to model a machine where jq is not
# installed yet — the first apply on a fresh machine is exactly that machine.
without_jq() {
	local d="$BATS_TEST_TMPDIR/nojq"
	mkdir -p "$d"
	for b in cat printf command sh; do
		[ -e "$d/$b" ] || ln -sf "$(command -v "$b" 2>/dev/null || true)" "$d/$b" 2>/dev/null || true
	done
	printf '%s' "$d"
}

REAL='{"flutter.ls_version":3,"flutter.ls_alias":"old","flutter.ls_security_context":"{\"privateKey\":\"-----BEGIN RSA PRIVATE KEY-----\"}","flutter.ls_port":53317}'

@test "the alias becomes the recorded name" {
	set_name hooks
	render
	modify <<<"$REAL"
	[ "$(jq -r '.["flutter.ls_alias"]' <<<"$output")" = "hooks" ]
}

@test "the private key and every other key survive untouched" {
	set_name hooks
	render
	modify <<<"$REAL"
	[ "$(jq -r '.["flutter.ls_security_context"]' <<<"$output")" \
		= "$(jq -r '.["flutter.ls_security_context"]' <<<"$REAL")" ]
	[ "$(jq -r '.["flutter.ls_port"]' <<<"$output")" = "53317" ]
	[ "$(jq -r '.["flutter.ls_version"]' <<<"$output")" = "3" ]
}

@test "the output is a fixed point, so a second apply sees no drift" {
	set_name hooks
	render
	modify <<<"$REAL"
	local once="$output"
	modify <<<"$once"
	[ "$output" = "$once" ]
}

@test "the output is compact and newline-free, the way LocalSend writes it" {
	set_name hooks
	render
	local out
	out="$(printf '%s' "$REAL" | sh "$SCRIPT")"
	[ "$(printf '%s' "$out" | wc -l)" -eq 0 ]
	[[ "$out" != *"  "* ]]
}

@test "a machine with no recorded name passes the file straight through" {
	printf '[data]\n    role = "personal"\n' >"$HOME/.config/chezmoi/chezmoi.toml"
	render
	modify <<<"$REAL"
	[ "$output" = "$REAL" ]
}

@test "no jq means the file is returned untouched, not half-edited" {
	set_name hooks
	render
	local out
	out="$(printf '%s' "$REAL" | env PATH="$(without_jq)" sh "$SCRIPT")"
	[ "$out" = "$REAL" ]
}

@test "a file LocalSend has never written gets the alias seeded" {
	set_name hooks
	render
	modify </dev/null
	[ "$(jq -r '.["flutter.ls_alias"]' <<<"$output")" = "hooks" ]
}

@test "a half-written file is left exactly as found" {
	set_name hooks
	render
	local broken='{"flutter.ls_alias":"old её'
	modify <<<"$broken"
	[ "$output" = "$broken" ]
}
