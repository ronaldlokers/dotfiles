#!/usr/bin/env bats
#
# The host package script installs desktop applications, and which ones depends
# on what kind of machine this is. Three lists rather than one: what every host
# gets, what only a personal machine gets, and what only a work machine gets.
#
# The split is not about taste. A work laptop with Signal and the personal
# Proton VPN on it is a machine mixing two lives, and a personal laptop with
# Slack and Teams on it is the same mistake facing the other way. What is
# genuinely shared — the terminal, the shell, the YubiKey stack, Obsidian,
# Spotify — stays in one list, so the profile lists only ever hold the things
# that really do belong to one side.
#
# These render the script for each role and read the arrays out of it, which is
# the only way to see a list that a real run would act on: the script exits
# early on a machine with no pacman, so running it proves nothing about what it
# would have installed.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	REPO="$BATS_TEST_DIRNAME/.."
	TMPL="$REPO/home/.chezmoiscripts/run_after_20-install-host-packages.sh.tmpl"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.config/chezmoi"
	export HOME
}

set_role() {
	printf '[data]\n    role = %s\n' "\"$1\"" >"$HOME/.config/chezmoi/chezmoi.toml"
}

# Renders the script and prints the packages it would install, one per line —
# both arrays together, since a package moving between repo and AUR is not what
# these assert.
packages_for() {
	set_role "$1"
	local rendered="$BATS_TEST_TMPDIR/pkgs.sh"
	env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" \
		chezmoi execute-template --source "$REPO" <"$TMPL" >"$rendered"
	# Source the arrays out of the rendered script rather than parsing them: a
	# quoting mistake that a shell would read differently is exactly the kind of
	# thing this should catch, not step around.
	bash -c '
		set -euo pipefail
		eval "$(sed -n "/^REPO_PACKAGES=(/,/^)/p;/^AUR_PACKAGES=(/,/^)/p" "$1")"
		printf "%s\n" "${REPO_PACKAGES[@]}" "${AUR_PACKAGES[@]}"
	' _ "$rendered"
}

@test "a personal machine gets the personal apps" {
	run packages_for personal
	[ "$status" -eq 0 ]
	[[ "$output" == *"signal-desktop"* ]]
	[[ "$output" == *"proton-vpn-gtk-app"* ]]
	[[ "$output" == *"prusa-slicer"* ]]
	[[ "$output" == *"chirp-next"* ]]
}

@test "and not the work ones" {
	run packages_for personal
	[[ "$output" != *"slack-desktop"* ]]
	[[ "$output" != *"teams-for-linux"* ]]
	[[ "$output" != *"zoom"* ]]
}

@test "a work machine gets the work apps" {
	run packages_for work
	[ "$status" -eq 0 ]
	[[ "$output" == *"slack-desktop"* ]]
	[[ "$output" == *"teams-for-linux"* ]]
	[[ "$output" == *"zoom"* ]]
}

@test "and none of the personal ones" {
	run packages_for work
	[[ "$output" != *"signal-desktop"* ]]
	[[ "$output" != *"proton-vpn-gtk-app"* ]]
	[[ "$output" != *"prusa-slicer"* ]]
	[[ "$output" != *"chirp-next"* ]]
	[[ "$output" != *"rpi-imager"* ]]
	[[ "$output" != *"winbox"* ]]
	[[ "$output" != *"bambustudio-bin"* ]]
	[[ "$output" != *"discord"* ]]
	# Tailscale is personal: the tailnet is a personal mesh, and
	# run_after_21-ssh-over-tailnet opens sshd on it.
	[[ "$output" != *"tailscale"* ]]
}

# The shared list is the point of having three: a machine is not usable without
# these, whichever life it belongs to.
@test "both machines get the shared apps" {
	run packages_for personal
	personal="$output"
	run packages_for work
	work="$output"
	for pkg in ghostty zsh mosh openssh yubikey-manager pcsclite pam-u2f bun \
		obsidian spotify proton-pass-bin zen-browser-bin claude-desktop; do
		[[ "$personal" == *"$pkg"* ]] || {
			echo "missing from personal: $pkg"
			false
		}
		[[ "$work" == *"$pkg"* ]] || {
			echo "missing from work: $pkg"
			false
		}
	done
}

# A package must not be in two lists: one of the two would be dead text, and
# which one is dead depends on the order the arrays are built — the kind of
# thing that is invisible until a package is removed from the wrong one.
@test "no package is listed twice" {
	run packages_for personal
	dupes="$(printf '%s\n' "$output" | sort | uniq -d)"
	[ -z "$dupes" ] || {
		echo "duplicated: $dupes"
		false
	}
	run packages_for work
	dupes="$(printf '%s\n' "$output" | sort | uniq -d)"
	[ -z "$dupes" ] || {
		echo "duplicated: $dupes"
		false
	}
}

# The script has to stay valid shell whichever way the gates fall — a stray
# template line inside an array would only show up as a syntax error mid-apply,
# on the machine that took that branch.
@test "the rendered script parses for either role" {
	for role in personal work; do
		set_role "$role"
		rendered="$BATS_TEST_TMPDIR/parse-$role.sh"
		env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
			-u XDG_CACHE_HOME HOME="$HOME" \
			chezmoi execute-template --source "$REPO" <"$TMPL" >"$rendered"
		run bash -n "$rendered"
		[ "$status" -eq 0 ]
	done
}
