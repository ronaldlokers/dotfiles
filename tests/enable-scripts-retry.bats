#!/usr/bin/env bats
#
# The three enable scripts (ssh-agent, update-check, secrets-check) skip when no
# systemd user manager is running, which is right: containers and CI have none.
#
# What was wrong is what the skip cost. As `run_onchange` scripts, chezmoi
# records the hash the moment they exit 0 — including the exit 0 that means "I
# did nothing" — and never runs them again until their contents change. So a
# machine that applied once without a session (a first apply from a display
# manager that had not started one, a laptop restored from a container image, a
# bootstrap over ssh) had those timers skipped permanently. Nothing fails,
# nothing is logged after that first apply, and `dotfiles-status` reports the
# secrets check has never recorded a run — which is true, and reads as a broken
# timer rather than one that was never enabled.
#
# These drive two real applies into one HOME, because that is where the bug
# lives: not in either script's own logic, both of which are covered next door,
# but in what chezmoi remembers between runs.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	REPO="$BATS_TEST_DIRNAME/.."

	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
	: >"$SYSTEMCTL_LOG"
	make_systemctl_stub "$BIN"

	RUNTIME="$(make_fake_runtime_dir "$BATS_TEST_TMPDIR/run")"
	NO_RUNTIME="$BATS_TEST_TMPDIR/empty"
	mkdir -p "$NO_RUNTIME"

	# A source tree holding only the enable scripts and the files they include:
	# the unit files and the two scripts whose hashes they carry. Applying the
	# whole repo here would drag in Proton, packages and every external.
	SRC="$BATS_TEST_TMPDIR/src"
	mkdir -p "$SRC/.chezmoiscripts" "$SRC/dot_config/systemd/user" \
		"$SRC/dot_local/bin"
	cp "$REPO"/home/.chezmoiscripts/run_*_1[012]-enable-*.sh.tmpl \
		"$SRC/.chezmoiscripts/"
	cp "$REPO"/home/dot_config/systemd/user/ssh-agent.service \
		"$REPO"/home/dot_config/systemd/user/dotfiles-update-check.service \
		"$REPO"/home/dot_config/systemd/user/dotfiles-update-check.timer \
		"$REPO"/home/dot_config/systemd/user/dotfiles-secrets-check.service \
		"$REPO"/home/dot_config/systemd/user/dotfiles-secrets-check.timer \
		"$SRC/dot_config/systemd/user/"
	cp "$REPO"/home/dot_local/bin/executable_dotfiles-secrets-check \
		"$REPO"/home/dot_local/bin/executable_dotfiles-update-check.tmpl \
		"$SRC/dot_local/bin/"
}

# One apply, with the session state the caller asks for. XDG_* is cleared for
# the reason mise.toml's verify task clears it: this desktop exports them, and
# chezmoi would otherwise keep its state — the very thing under test — in the
# developer's real ~/.local/share.
apply() {
	run env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME \
		HOME="$HOME" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" PATH="$BIN:$PATH" \
		XDG_RUNTIME_DIR="$1" \
		chezmoi apply --source "$SRC" --destination "$HOME" </dev/null
}

@test "the first apply without a session enables nothing, and says so" {
	apply "$NO_RUNTIME"
	[ "$status" -eq 0 ]
	[ ! -s "$SYSTEMCTL_LOG" ]
}

# The finding. The second apply is the one that matters: same tree, same
# hashes, a session now — and under run_onchange it did nothing at all.
@test "a session appearing later still gets the timers enabled" {
	apply "$NO_RUNTIME"
	[ "$status" -eq 0 ]
	: >"$SYSTEMCTL_LOG"

	apply "$RUNTIME"
	[ "$status" -eq 0 ]
	grep -q -- "--user enable --now ssh-agent.service" "$SYSTEMCTL_LOG"
	grep -q -- "--user enable --now dotfiles-update-check.timer" "$SYSTEMCTL_LOG"
	grep -q -- "--user enable --now dotfiles-secrets-check.timer" "$SYSTEMCTL_LOG"
}

# The corollary, and the reason the retry is safe to do on every apply: enabling
# a unit that is already enabled is a no-op, so a machine that has had a session
# all along loses nothing by being asked twice.
@test "a machine that already had a session is asked again, harmlessly" {
	apply "$RUNTIME"
	[ "$status" -eq 0 ]
	: >"$SYSTEMCTL_LOG"

	apply "$RUNTIME"
	[ "$status" -eq 0 ]
	grep -q -- "--user enable --now dotfiles-secrets-check.timer" "$SYSTEMCTL_LOG"
}
