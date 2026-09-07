#!/usr/bin/env bats
#
# A machine's name, asked once at init and remembered in chezmoi.toml.
#
# Unlike the role, a name is something a machine can work out about itself, so
# the hostname is the default and a silent apply never asks. The prompt exists
# for the one case detection cannot cover — a fresh install still carrying
# whatever hostname the installer picked — and it carries the roster so the
# answer does not have to be remembered.
#
# The roster is advisory. An off-roster name warns and still renders: a machine
# that has already been named something else is a naming lapse, not a reason to
# refuse to configure it.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	REPO="$BATS_TEST_DIRNAME/.."
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.config/chezmoi"
	export HOME
}

# chezmoi reads its data from $HOME/.config/chezmoi/chezmoi.toml, so a test
# picks a name by writing one. No name at all is its own case below.
set_name() {
	printf '[data]\n    name = %s\n' "\"$1\"" >"$HOME/.config/chezmoi/chezmoi.toml"
}

# The XDG clearing is the same hazard render_template documents: this desktop
# points XDG_CONFIG_HOME at the real ~/.config, so without it the render reads
# this developer's own chezmoi.toml rather than the one the test just wrote.
render_config() {
	run --separate-stderr env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" \
		chezmoi execute-template --init --source "$REPO" \
		<"$REPO/home/.chezmoi.toml.tmpl"
	[ "$status" -eq 0 ]
}

hostname_per_chezmoi() {
	env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" \
		chezmoi execute-template '{{ .chezmoi.hostname }}'
}

@test "an unattended init names the machine after its hostname" {
	render_config
	[[ "$output" == *"name = \"$(hostname_per_chezmoi)\""* ]]
}

@test "a name already answered wins over the hostname" {
	set_name hightower
	render_config
	[[ "$output" == *'name = "hightower"'* ]]
}

@test "a name off the roster still renders, and warns" {
	set_name webserver01
	render_config
	[[ "$output" == *'name = "webserver01"'* ]]
	[[ "$stderr" == *webserver01* ]]
}

@test "a name on the roster warns about nothing" {
	set_name tackleberry
	render_config
	[ -z "$stderr" ]
}
