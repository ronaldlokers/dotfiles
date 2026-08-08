#!/usr/bin/env bats
#
# repos-sync clones the personal repos that aren't checked out yet. It had no
# tests and no argument handling, which combined into the finding this file
# opens with: `repos-sync --help` did not print help, it cloned six
# repositories from GitHub.
#
# git is stubbed. A test that used the real one would clone this developer's
# actual repositories into a temp directory over the network, which is both slow
# and exactly the behaviour under test.

bats_require_minimum_version 1.5.0

setup() {
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_repos-sync"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"
	GIT_LOG="$BATS_TEST_TMPDIR/git.log"
	: >"$GIT_LOG"

	ROOT="$BATS_TEST_TMPDIR/Projects"
	mkdir -p "$ROOT"

	# `git clone <url> <target>` is the only form the script uses. The stub
	# creates the .git directory the script's own "already present" test looks
	# for, so a second run sees what a real clone would have left.
	cat >"$BIN/git" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$GIT_LOG"
if [ "$1" = "clone" ]; then
	target=""
	for a in "$@"; do target="$a"; done
	case " ${CLONE_FAIL:-} " in *" $target "*) exit 1 ;; esac
	case "$(basename "$target")" in
	${CLONE_FAIL_REPO:-__none__}) exit 1 ;;
	esac
	mkdir -p "$target/.git"
fi
exit 0
STUB
	chmod 755 "$BIN/git"

	# zoxide, stubbed for the reason git is: the real one writes a database,
	# and the database it writes is this developer's. The stub models the leak
	# faithfully — the file lands wherever XDG_DATA_HOME points, exactly like
	# the real `zoxide add` — so a test can assert where that is.
	ZOXIDE_LOG="$BATS_TEST_TMPDIR/zoxide.log"
	: >"$ZOXIDE_LOG"
	cat >"$BIN/zoxide" <<'STUB'
#!/bin/sh
[ -n "${ZOXIDE_LOG:-}" ] && printf '%s\n' "$*" >>"$ZOXIDE_LOG"
db="${XDG_DATA_HOME:-$HOME/.local/share}/zoxide"
mkdir -p "$db"
printf '%s\n' "$*" >>"$db/db.zo"
exit 0
STUB
	chmod 755 "$BIN/zoxide"

	export HOME GIT_LOG ZOXIDE_LOG
}

# Everything before a literal `--` is an env assignment; everything after is an
# argument for the script itself.
run_sync() {
	local envs=() args=() past=0 arg
	for arg in "$@"; do
		if [ "$arg" = "--" ]; then past=1; continue; fi
		if [ "$past" = 0 ]; then envs+=("$arg"); else args+=("$arg"); fi
	done
	# -u XDG_DATA_HOME is the load-bearing one: repos-sync seeds zoxide after a
	# clone, and zoxide's database lives under XDG_DATA_HOME. This desktop
	# exports it, so the suite wrote entries into the developer's real zoxide
	# database — every fixture path from every run, in the picker afterwards.
	# Redirecting HOME does not cover it, the same way it did not for
	# XDG_STATE_HOME in the export tests or XDG_RUNTIME_DIR in the Proton ones.
	# The rest go with it so nothing else reaches past the test HOME.
	run env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME \
		HOME="$HOME" PATH="$BIN:$PATH" GIT_LOG="$GIT_LOG" \
		ZOXIDE_LOG="$ZOXIDE_LOG" \
		XDG_PROJECTS_DIR="$ROOT" ${envs[@]+"${envs[@]}"} \
		bash "$SCRIPT" ${args[@]+"${args[@]}"} </dev/null
}

# --- the finding --------------------------------------------------------------

# Asking a command what it does must never be the thing that makes it do it.
@test "--help prints usage and clones nothing" {
	run_sync -- --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: repos-sync"* ]]
	[ ! -s "$GIT_LOG" ]
	[ -z "$(ls -A "$ROOT")" ]
}

@test "-h does the same" {
	run_sync -- -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: repos-sync"* ]]
	[ ! -s "$GIT_LOG" ]
}

# The other half of the same mistake: an unrecognised flag used to be ignored
# and the clone ran anyway, so a typo'd option did the full job silently.
@test "an unknown argument is refused, not ignored" {
	run_sync -- --dry-run
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown argument"* ]]
	[ ! -s "$GIT_LOG" ]
	[ -z "$(ls -A "$ROOT")" ]
}

# --- the job it actually does -------------------------------------------------

@test "clones the repos that are not checked out" {
	run_sync
	[ "$status" -eq 0 ]
	[ -d "$ROOT/github.com/ronaldlokers/homelab/.git" ]
	[ -d "$ROOT/github.com/ronaldlokers/lab/.git" ]
	[[ "$output" == *"6 cloned"* ]]
}

@test "clones over HTTPS, not SSH" {
	run_sync
	[ "$status" -eq 0 ]
	# the gh credential helper authenticates HTTPS, and this machine has no SSH
	# auth key — only a signing key
	grep -q "https://github.com/ronaldlokers/homelab.git" "$GIT_LOG"
	! grep -q "git@" "$GIT_LOG"
}

@test "keeps the host/owner/repo layout" {
	run_sync
	[ "$status" -eq 0 ]
	[ -d "$ROOT/github.com/ronaldlokers" ]
}

# The rule the script leads with: an existing checkout is left alone, branch,
# remotes and uncommitted work included.
@test "an existing checkout is skipped, not touched" {
	mkdir -p "$ROOT/github.com/ronaldlokers/homelab/.git"
	printf 'MINE\n' >"$ROOT/github.com/ronaldlokers/homelab/uncommitted"
	run_sync
	[ "$status" -eq 0 ]
	[ "$(cat "$ROOT/github.com/ronaldlokers/homelab/uncommitted")" = "MINE" ]
	! grep -q "homelab" "$GIT_LOG"
	[[ "$output" == *"1 already present"* ]]
}

@test "a second run clones nothing" {
	run_sync
	[ "$status" -eq 0 ]
	: >"$GIT_LOG"
	run_sync
	[ "$status" -eq 0 ]
	[ ! -s "$GIT_LOG" ]
	[[ "$output" == *"0 cloned, 6 already present"* ]]
}

# --- failure handling ---------------------------------------------------------

@test "a failed clone is reported and exits non-zero" {
	run_sync CLONE_FAIL_REPO="lab" --
	[ "$status" -ne 0 ]
	[[ "$output" == *"failed:"* ]]
	[[ "$output" == *"lab"* ]]
}

# A partial directory would be mistaken for a real checkout by the next run's
# .git test, and then never retried.
@test "a failed clone leaves nothing behind for the next run to skip" {
	run_sync CLONE_FAIL_REPO="lab" --
	[ "$status" -ne 0 ]
	[ ! -e "$ROOT/github.com/ronaldlokers/lab" ]
}

@test "one failed clone does not stop the others" {
	run_sync CLONE_FAIL_REPO="lab" --
	[ "$status" -ne 0 ]
	[ -d "$ROOT/github.com/ronaldlokers/homelab/.git" ]
	[ -d "$ROOT/github.com/ronaldlokers/Zenith/.git" ]
}

# --- what it seeds, and where it does not write (M16) -------------------------
#
# repos-sync seeds zoxide after each clone, so a fresh checkout is in the sesh
# picker before anyone has cd'd into it. That was untested, and the way it was
# untested had teeth: zoxide's database lives under $XDG_DATA_HOME, this desktop
# exports that variable, and the suite passed it straight through. Every run
# wrote its fixture paths — /tmp/bats-run-*/Projects/… — into the developer's
# real zoxide database, where they stayed, in the picker.
#
# Redirecting HOME does not cover it. Same trap as XDG_STATE_HOME in the
# secrets-export tests and XDG_RUNTIME_DIR in the Proton ones: a variable that
# outranks HOME, for the third time.

@test "a fresh clone is seeded into zoxide" {
	run_sync --
	[ "$status" -eq 0 ]
	grep -q "add $ROOT/github.com/ronaldlokers/homelab" "$ZOXIDE_LOG"
}

# A repo that is already checked out is skipped entirely, seeding included:
# zoxide already knows about a directory you have been working in.
@test "a repo that was already there is not re-seeded" {
	mkdir -p "$ROOT/github.com/ronaldlokers/homelab/.git"
	run_sync --
	[ "$status" -eq 0 ]
	! grep -q "add $ROOT/github.com/ronaldlokers/homelab$" "$ZOXIDE_LOG"
}

# The leak itself. XDG_DATA_HOME is exported into the suite's own environment
# here, standing in for the developer's, and nothing under it may be touched.
@test "the suite writes no zoxide database outside its own HOME" {
	canary="$BATS_TEST_TMPDIR/canary"
	mkdir -p "$canary"
	export XDG_DATA_HOME="$canary"
	run_sync --
	[ "$status" -eq 0 ]
	[ -z "$(ls -A "$canary")" ]
	# ...and it did seed one, somewhere that belongs to the test.
	[ -f "$HOME/.local/share/zoxide/db.zo" ]
}
