#!/usr/bin/env bats
#
# run_after_24-seed-zen-prefs.sh.tmpl writes this repo's Zen preferences into
# the browser's profile as user.js.
#
# user.js cannot be an ordinary managed file: its path contains a randomly
# generated profile directory name, different on every machine, so chezmoi has
# no static target to map it to. The script resolves the profile and writes
# there.
#
# The resolution order is the part that matters and the part these tests exist
# to pin. profiles.ini's `Default=1` is NOT authoritative -- on the machine
# this was written for it marks an unused 4 KB profile while installs.ini
# names the 277 MB one holding the real session. A reader that trusts
# `Default=1` writes into the wrong profile and silently achieves nothing.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	TMPL="$BATS_TEST_DIRNAME/../home/.chezmoiscripts/run_after_24-seed-zen-prefs.sh.tmpl"
	HOME="$BATS_TEST_TMPDIR/home"
	ZEN="$HOME/.config/zen"
	mkdir -p "$ZEN"

	BIN="$BATS_TEST_TMPDIR/bin"
	make_zen_browser_stub "$BIN"
	ZEN_LOG="$BATS_TEST_TMPDIR/zen.log"

	SCRIPT="$BATS_TEST_TMPDIR/seed.sh"
	render_template "$TMPL" "$SCRIPT" "$PATH"
	export HOME ZEN_LOG
}

run_seed() {
	run env -u XDG_CONFIG_HOME HOME="$HOME" ZEN_LOG="$ZEN_LOG" \
		PATH="$BIN:$PATH" sh "$SCRIPT"
}

# An installs.ini naming one relative profile directory, which is the shape a
# real machine has.
write_installs() {
	mkdir -p "$ZEN/$1"
	cat >"$ZEN/installs.ini" <<-EOF
		[15B76BAA26BA15E7]
		Default=$1
		Locked=1
	EOF
}

@test "writes user.js into the profile installs.ini names" {
	write_installs "abc123.Default (release)"
	run_seed
	[ "$status" -eq 0 ]
	[ -f "$ZEN/abc123.Default (release)/user.js" ]
}

@test "writes all twenty-two preferences" {
	write_installs "abc123.Default (release)"
	run_seed
	n="$(grep -c '^user_pref(' "$ZEN/abc123.Default (release)/user.js")"
	[ "$n" -eq 22 ]
}

@test "string values arrive quoted and intact through templating" {
	write_installs "abc123.Default (release)"
	run_seed
	js="$ZEN/abc123.Default (release)/user.js"
	# The user-agent carries spaces, slashes, parentheses and semicolons --
	# every character that a careless printf or an unquoted heredoc mangles.
	grep -qF 'user_pref("devtools.responsive.userAgent", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1");' "$js"
	grep -qF 'user_pref("browser.translations.neverTranslateLanguages", "nl");' "$js"
	grep -qF 'user_pref("sidebar.visibility", "hide-on-close");' "$js"
	# Numbers and booleans must NOT be quoted, or Zen reads them as strings.
	grep -qF 'user_pref("browser.link.open_newwindow.override.external", 7);' "$js"
	grep -qF 'user_pref("media.eme.enabled", false);' "$js"
	grep -qF 'user_pref("accessibility.typeaheadfind.flashBar", 0);' "$js"
}

@test "does nothing and exits 0 when zen-browser is not installed" {
	write_installs "abc123.Default (release)"
	# A PATH with sh but no zen-browser. Plain /bin:/usr/bin will not do here:
	# this developer's own machine has a real zen-browser installed there, so
	# `command -v zen-browser` would find it and the test would pass for the
	# wrong reason. Symlinking only `sh` into an empty directory (the same
	# trick seed-bar-widget.bats uses for "no jq yet") keeps the shell usable
	# while genuinely removing zen-browser from the search path.
	EMPTY="$BATS_TEST_TMPDIR/empty"
	mkdir -p "$EMPTY"
	ln -sf "$(command -v sh)" "$EMPTY/sh"
	run env -u XDG_CONFIG_HOME HOME="$HOME" PATH="$EMPTY" sh "$SCRIPT"
	[ "$status" -eq 0 ]
	[ ! -f "$ZEN/abc123.Default (release)/user.js" ]
}

@test "resolution prefers installs.ini over a profiles.ini marked Default=1" {
	mkdir -p "$ZEN/wrong.Default Profile" "$ZEN/right.Default (release)"
	# Exactly the shape of the machine this was written for: profiles.ini
	# marks the empty profile default, installs.ini names the real one.
	cat >"$ZEN/profiles.ini" <<-'EOF'
		[Profile1]
		Name=Default Profile
		IsRelative=1
		Path=wrong.Default Profile
		Default=1

		[Profile0]
		Name=Default (release)
		IsRelative=1
		Path=right.Default (release)

		[General]
		StartWithLastProfile=1
		Version=2
	EOF
	cat >"$ZEN/installs.ini" <<-'EOF'
		[15B76BAA26BA15E7]
		Default=right.Default (release)
		Locked=1
	EOF

	run_seed
	[ "$status" -eq 0 ]
	[ -f "$ZEN/right.Default (release)/user.js" ]
	[ ! -f "$ZEN/wrong.Default Profile/user.js" ]
}

@test "falls back to the profiles.ini Install section when installs.ini is absent" {
	mkdir -p "$ZEN/wrong.Default Profile" "$ZEN/right.Default (release)"
	cat >"$ZEN/profiles.ini" <<-'EOF'
		[Profile1]
		Name=Default Profile
		IsRelative=1
		Path=wrong.Default Profile
		Default=1

		[Profile0]
		Name=Default (release)
		IsRelative=1
		Path=right.Default (release)

		[General]
		StartWithLastProfile=1
		Version=2

		[Install15B76BAA26BA15E7]
		Default=right.Default (release)
		Locked=1
	EOF

	run_seed
	[ "$status" -eq 0 ]
	[ -f "$ZEN/right.Default (release)/user.js" ]
	[ ! -f "$ZEN/wrong.Default Profile/user.js" ]
}

@test "falls back to Default=1 only when neither install record exists" {
	mkdir -p "$ZEN/only.Default Profile"
	cat >"$ZEN/profiles.ini" <<-'EOF'
		[Profile0]
		Name=Default Profile
		IsRelative=1
		Path=only.Default Profile
		Default=1

		[General]
		StartWithLastProfile=1
		Version=2
	EOF

	run_seed
	[ "$status" -eq 0 ]
	[ -f "$ZEN/only.Default Profile/user.js" ]
}

@test "falls back to Default=1 when it appears before Path= in the section" {
	mkdir -p "$ZEN/only.Default Profile"
	cat >"$ZEN/profiles.ini" <<-'EOF'
		[Profile0]
		Name=Default Profile
		IsRelative=1
		Default=1
		Path=only.Default Profile

		[General]
		StartWithLastProfile=1
		Version=2
	EOF

	run_seed
	[ "$status" -eq 0 ]
	[ -f "$ZEN/only.Default Profile/user.js" ]
}

@test "honours an absolute Path with IsRelative=0" {
	mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
	cat >"$ZEN/installs.ini" <<-EOF
		[15B76BAA26BA15E7]
		Default=$BATS_TEST_TMPDIR/elsewhere
		Locked=1
	EOF

	run_seed
	[ "$status" -eq 0 ]
	[ -f "$BATS_TEST_TMPDIR/elsewhere/user.js" ]
}

@test "leaves installs.ini and profiles.ini byte-identical" {
	write_installs "abc123.Default (release)"
	cat >"$ZEN/profiles.ini" <<-'EOF'
		[Profile0]
		Name=Default (release)
		IsRelative=1
		Path=abc123.Default (release)

		[General]
		StartWithLastProfile=1
		Version=2
	EOF
	before_i="$(md5sum <"$ZEN/installs.ini")"
	before_p="$(md5sum <"$ZEN/profiles.ini")"

	run_seed
	[ "$status" -eq 0 ]
	[ "$(md5sum <"$ZEN/installs.ini")" = "$before_i" ]
	[ "$(md5sum <"$ZEN/profiles.ini")" = "$before_p" ]
}

@test "writes nothing else into the profile" {
	write_installs "abc123.Default (release)"
	run_seed
	# user.js and nothing besides. A stray temp file left behind is a bug:
	# the profile is Zen's, and this script's whole licence is one file.
	found="$(cd "$ZEN/abc123.Default (release)" && ls -A | tr '\n' ' ')"
	[ "$found" = "user.js " ]
}

@test "a second run leaves the file untouched" {
	write_installs "abc123.Default (release)"
	js="$ZEN/abc123.Default (release)/user.js"
	run_seed
	[ "$status" -eq 0 ]
	# Coarse mtime is enough here and avoids a sleep: set it back a day, then
	# assert the second run did not move it forward.
	touch -d '1 day ago' "$js"
	before="$(stat -c %Y "$js")"
	before_content="$(cat "$js")"

	run_seed
	[ "$status" -eq 0 ]
	[ "$(stat -c %Y "$js")" -eq "$before" ]
	# Not just untouched -- still correct. Without this, a second run that
	# bailed out early for an unrelated reason (say, resolve_profile stopped
	# finding the profile) would leave the mtime unmoved too, and the test
	# above would pass for the wrong reason.
	[ "$(cat "$js")" = "$before_content" ]
	grep -q '^user_pref(' "$js"
}

@test "a changed list is rewritten" {
	write_installs "abc123.Default (release)"
	js="$ZEN/abc123.Default (release)/user.js"
	run_seed
	echo '// stale' >"$js"

	run_seed
	[ "$status" -eq 0 ]
	grep -q '^user_pref(' "$js"
	run grep -c 'stale' "$js"
	[ "$status" -ne 0 ]
}

@test "exits 0 and writes nothing inside a container" {
	write_installs "abc123.Default (release)"
	CONTAINER_SCRIPT="$BATS_TEST_TMPDIR/seed-container.sh"
	# is-container renders to a literal in the script, so flipping that
	# literal is how a host-rendered copy takes the container branch.
	sed 's/^is_container=false$/is_container=true/' "$SCRIPT" >"$CONTAINER_SCRIPT"

	run env -u XDG_CONFIG_HOME HOME="$HOME" PATH="$BIN:$PATH" sh "$CONTAINER_SCRIPT"
	[ "$status" -eq 0 ]
	[ ! -f "$ZEN/abc123.Default (release)/user.js" ]
}

# The known defect this suite exists to pin: under `set -eu`, a failed write
# into $tmp used to abort the script immediately, before the `rm -f "$tmp"`
# that every other early-return path in this script already gets. The stray
# user.js.tmp.$$ that leaves behind sits in the user's real Zen profile
# forever -- this script has no later occasion to clean it up.
#
# Shadowing `cat` (rather than, say, chmod-ing the profile directory
# read-only) is deliberate: the shell's `>"$tmp"` redirection creates
# (truncates) the temp file as part of launching `cat`, before `cat` itself
# ever runs. A directory-permission block would stop that open() from
# succeeding at all, so nothing would exist for `rm -f` to remove -- such a
# test would pass identically whether or not the cleanup code was even
# there, which is exactly the trap called out in proton-ssh-load.bats over
# the equivalent case for `mv`. Failing inside `cat` instead lets the temp
# file genuinely come into existence first, so this test can tell "cleaned
# up" apart from "never created".
@test "removes the temp file when the write into it fails" {
	write_installs "abc123.Default (release)"
	FAILBIN="$BATS_TEST_TMPDIR/failcat"
	mkdir -p "$FAILBIN"
	cat >"$FAILBIN/cat" <<-'EOF'
		#!/bin/sh
		exit 1
	EOF
	chmod 755 "$FAILBIN/cat"

	run env -u XDG_CONFIG_HOME HOME="$HOME" PATH="$FAILBIN:$BIN:$PATH" sh "$SCRIPT"

	[ "$status" -eq 0 ]
	[ ! -f "$ZEN/abc123.Default (release)/user.js" ]
	found="$(find "$ZEN/abc123.Default (release)" -name '*.tmp.*' -print -quit)"
	[ -z "$found" ]
}

@test "creates a profile when the machine has none" {
	# No installs.ini, no profiles.ini, no profile directory: a machine whose
	# Zen has never been launched, which is what a fresh apply meets.
	#
	# $ZEN_LOG is pre-created empty so the grep below can only pass or fail on
	# content -- without this, a script that never invokes zen-browser at all
	# would leave $ZEN_LOG absent, and `grep -q` on a missing file fails with
	# "No such file" (status 2), which reads as a pass-worthy failure but never
	# actually evaluated the assertion it claims to.
	: >"$ZEN_LOG"
	run_seed
	[ "$status" -eq 0 ]
	grep -q '^-CreateProfile ' "$ZEN_LOG"
	[ -f "$ZEN/dotfiles/user.js" ]
}

@test "does not create a profile when one already exists" {
	write_installs "abc123.Default (release)"
	# Pre-created for the same reason as the test above: without it, "the log
	# has no CreateProfile line" and "the log does not exist" both make
	# `grep -c` exit non-zero, and this test cannot tell those apart.
	: >"$ZEN_LOG"
	run_seed
	[ "$status" -eq 0 ]
	run grep -c 'CreateProfile' "$ZEN_LOG"
	[ "$status" -ne 0 ]
}

@test "exits 0 when the profile cannot be created" {
	run env -u XDG_CONFIG_HOME HOME="$HOME" ZEN_LOG="$ZEN_LOG" \
		ZEN_CREATE_RC=1 PATH="$BIN:$PATH" sh "$SCRIPT"
	[ "$status" -eq 0 ]
}
