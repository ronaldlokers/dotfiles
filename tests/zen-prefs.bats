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
