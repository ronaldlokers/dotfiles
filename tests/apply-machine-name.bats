#!/usr/bin/env bats
#
# run_after_26-apply-machine-name.sh gives a machine the name `chezmoi init`
# recorded — the system hostname and the Tailscale device name both.
#
# One rule decides everything: set what is still a default, warn about what
# somebody chose. A live name that is not on the roster is an installer's
# leftover and gets replaced; a live name that IS on the roster was picked by a
# person, so a disagreement with chezmoi.toml is reported and nothing moves.
#
# That is what makes renaming a first-setup action only. The test that matters
# most here is the one asserting an established machine is NOT renamed: a stale
# chezmoi.toml able to rename a running machine on every apply is the failure
# this shape exists to rule out.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	REPO="$BATS_TEST_DIRNAME/.."
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.config/chezmoi"
	export HOME
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"
	STUB_LOG="$BATS_TEST_TMPDIR/argv.log"
	export STUB_LOG
	SCRIPT="$BATS_TEST_TMPDIR/apply-machine-name.sh"
}

set_name() {
	printf '[data]\n    name = %s\n' "\"$1\"" >"$HOME/.config/chezmoi/chezmoi.toml"
}

# The template bakes .name in at render time, so the config has to be written
# before this runs — not before the script runs.
render() {
	render_template \
		"$REPO/home/.chezmoiscripts/run_after_26-apply-machine-name.sh.tmpl" \
		"$SCRIPT" "$PATH" "$REPO"
}

# Every external the script touches is a stub that logs its argv, so a test can
# assert what was NOT called. `sudo -n true` has to succeed for the mutating
# branches to be reachable at all; sudo_fails() models the opposite.
stub() {
	local name="$1" body="$2"
	cat >"$BIN/$name" <<STUB
#!/bin/sh
printf '%s %s\n' "$name" "\$*" >>"\$STUB_LOG"
$body
STUB
	chmod +x "$BIN/$name"
}

stub_all() {
	local static_hostname="$1" ts_hostname="$2"
	stub hostnamectl "[ \"\$1\" = --static ] && printf '%s\n' '$static_hostname'; exit 0"
	stub sudo 'shift; exec "$@"'
	if [ -n "$ts_hostname" ]; then
		stub tailscale "printf '{\"Self\":{\"HostName\":\"%s\"}}\n' '$ts_hostname'; exit 0"
	else
		stub tailscale "exit 1"
	fi
}

# sudo -n failing is the unattended-apply case: nothing may be changed, and the
# script has to say why rather than silently doing nothing.
sudo_fails() {
	stub sudo 'exit 1'
}

run_script() {
	run --separate-stderr env PATH="$BIN:$PATH" HOME="$HOME" \
		STUB_LOG="$STUB_LOG" sh "$SCRIPT"
}

logged() {
	grep -q "$1" "$STUB_LOG" 2>/dev/null
}

@test "an installer's hostname is replaced by the recorded name" {
	set_name hooks
	render
	stub_all archlinux hooks
	run_script
	[ "$status" -eq 0 ]
	logged "hostnamectl set-hostname hooks"
}

@test "a roster hostname that disagrees is reported, not renamed" {
	set_name hooks
	render
	stub_all mahoney hooks
	run_script
	[ "$status" -eq 0 ]
	! logged "set-hostname"
	[[ "$stderr" == *mahoney* ]]
	[[ "$stderr" == *"not renaming"* ]]
}

@test "a machine already carrying its name changes nothing" {
	set_name hooks
	render
	stub_all hooks hooks
	run_script
	[ "$status" -eq 0 ]
	! logged "set-hostname"
	! logged "tailscale set"
}

@test "an installer's tailnet name is replaced too" {
	set_name hooks
	render
	stub_all hooks archlinux
	run_script
	[ "$status" -eq 0 ]
	logged "tailscale set --hostname=hooks"
}

@test "a roster tailnet name that disagrees is reported, not renamed" {
	set_name hooks
	render
	stub_all hooks mahoney
	run_script
	[ "$status" -eq 0 ]
	! logged "tailscale set"
	[[ "$stderr" == *MagicDNS* ]]
}

@test "sudo needing a password renames nothing and says so" {
	set_name hooks
	render
	stub_all archlinux archlinux
	sudo_fails
	run_script
	[ "$status" -eq 0 ]
	! logged "set-hostname"
	! logged "tailscale set"
	[[ "$stderr" == *"needs a password"* ]]
}

@test "a machine not on the tailnet is left alone rather than joined" {
	set_name hooks
	render
	stub_all hooks ""
	run_script
	[ "$status" -eq 0 ]
	! logged "tailscale set"
	[[ "$stderr" == *"not on the tailnet"* ]]
}

@test "a machine with no recorded name renames nothing" {
	printf '[data]\n    role = "personal"\n' >"$HOME/.config/chezmoi/chezmoi.toml"
	render
	stub_all archlinux archlinux
	run_script
	[ "$status" -eq 0 ]
	! logged "set-hostname"
	! logged "tailscale set"
	[[ "$stderr" == *"chezmoi init"* ]]
}
