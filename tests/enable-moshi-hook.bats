#!/usr/bin/env bats
#
# run_after_22-enable-moshi-hook.sh.tmpl starts the daemon that carries Claude
# Code's approvals and completions to the phone.
#
# Every branch here is a refusal, and that is the point. The hooks fire whether
# or not the daemon is listening, so a machine that is not paired, or has no
# user manager, looks identical to a working one until you notice the phone has
# gone quiet. Each refusal has to say which of those it is.
#
# The pairing gate is the load-bearing one: `service install` on an unpaired
# host would leave a unit retrying against a gateway that will never accept it,
# in the same `systemctl --user --failed` this repo depends on meaning
# something.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	TMPL="$BATS_TEST_DIRNAME/../home/.chezmoiscripts/run_after_22-enable-moshi-hook.sh.tmpl"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.local/bin"
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"
	LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$LOG"

	# The script puts $HOME/.local/bin first on PATH, so the stub lives there.
	cat >"$HOME/.local/bin/moshi-hook" <<'STUB'
#!/bin/sh
printf 'moshi-hook %s\n' "$*" >>"$LOG"
case "$1" in
status) printf 'status: %s\n' "${MOSHI_PAIRED:-unpaired}" ;;
service) [ -n "${MOSHI_INSTALL_RC:-}" ] && exit "$MOSHI_INSTALL_RC" ;;
esac
exit 0
STUB

	cat >"$BIN/systemctl" <<'STUB'
#!/bin/sh
printf 'systemctl %s\n' "$*" >>"$LOG"
for a in "$@"; do
	case "$a" in
	is-active) exit "${MOSHI_ACTIVE_RC:-1}" ;;
	show) printf 'Environment=%s\n' "${MOSHI_ENV:-PATH=/usr/local/bin:/usr/bin:/bin}" ;;
	esac
done
exit 0
STUB
	chmod 755 "$HOME/.local/bin/moshi-hook" "$BIN/systemctl"

	# A directory shaped like a live user-manager runtime dir.
	RUNTIME="$(make_fake_runtime_dir "$BATS_TEST_TMPDIR/run")"

	SANDBOX="$BATS_TEST_TMPDIR/sandbox"
	mkdir -p "$SANDBOX"
	for t in sh grep printf env tr sed head; do
		src="$(type -P "$t" 2>/dev/null)" || continue
		[ -n "$src" ] && ln -sf "$src" "$SANDBOX/$t"
	done

	SCRIPT="$BATS_TEST_TMPDIR/moshi.sh"
	render_template "$TMPL" "$SCRIPT" "$PATH"
	export HOME LOG
}

run_script() {
	run env HOME="$HOME" LOG="$LOG" PATH="$BIN:$SANDBOX" \
		XDG_RUNTIME_DIR="$RUNTIME" "$@" sh "$SCRIPT"
}

# --- the pairing gate --------------------------------------------------------

@test "an unpaired host does not install the service" {
	run_script
	[ "$status" -eq 0 ]
	[[ "$output" == *"not paired"* ]]
	! grep -q "service install" "$LOG"
}

# A refusal that does not say what to type is a refusal nobody acts on.
@test "it says how to pair" {
	run_script
	[[ "$output" == *"moshi-hook pair --token"* ]]
	[[ "$output" == *"--store file"* ]]
}

@test "a paired host starts the daemon" {
	run_script MOSHI_PAIRED=paired
	[ "$status" -eq 0 ]
	grep -q "moshi-hook service install" "$LOG"
}

# --- idempotence -------------------------------------------------------------

# A settled machine does nothing at all. `service install` is idempotent, but
# running it on every apply would restart the daemon on every apply.
@test "an already-running daemon is left alone" {
	run_script MOSHI_PAIRED=paired MOSHI_ACTIVE_RC=0
	[ "$status" -eq 0 ]
	! grep -q "service install" "$LOG"
}

# --- the guards --------------------------------------------------------------

@test "no moshi-hook binary is a skip, not a failure" {
	rm "$HOME/.local/bin/moshi-hook"
	run_script
	[ "$status" -eq 0 ]
	[[ "$output" == *"not installed"* ]]
}

# The socket probe, not systemctl's exit code: devcontainer images ship a shim
# that exits 0 while printing "systemd is not running".
@test "no user manager is a skip, and the pairing check is never reached" {
	run env HOME="$HOME" LOG="$LOG" PATH="$BIN:$SANDBOX" \
		XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/empty" sh "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"no systemd user session"* ]]
	! grep -q "moshi-hook status" "$LOG"
}

@test "an unset XDG_RUNTIME_DIR is a skip too" {
	run env -u XDG_RUNTIME_DIR HOME="$HOME" LOG="$LOG" PATH="$BIN:$SANDBOX" sh "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"no systemd user session"* ]]
}

# Report and continue: a phone-notification daemon must not decide whether the
# machine finishes provisioning.
@test "a failed install does not abort the apply" {
	run_script MOSHI_PAIRED=paired MOSHI_INSTALL_RC=1
	[ "$status" -eq 0 ]
	[[ "$output" == *"could not start it"* ]]
}

# --- the herdr path (2026-08-08) ---------------------------------------------
#
# `moshi-hook service install` generates a unit hardcoding
# `Environment=PATH=/usr/local/bin:/usr/bin:/bin`, and herdr is a mise shim in
# ~/.local/share/mise/shims. The daemon therefore cannot resolve `herdr` at all.
#
# Nothing errors. Moshi simply reports no workspaces, which reads like herdr
# being unsupported rather than not being found — so this is worth a test even
# though the fix is one Environment= line: the symptom points away from the
# cause.

@test "a daemon without the herdr path is restarted to pick it up" {
	run_script MOSHI_PAIRED=paired MOSHI_ACTIVE_RC=0
	[ "$status" -eq 0 ]
	[[ "$output" == *"picking up the herdr path"* ]]
	grep -q "daemon-reload" "$LOG"
	grep -q "restart moshi-hook.service" "$LOG"
}

# ...and once it has it, nothing happens. Restarting the daemon on every apply
# would drop the gateway connection each time.
@test "a daemon that already has it is left alone" {
	run_script MOSHI_PAIRED=paired MOSHI_ACTIVE_RC=0 \
		MOSHI_ENV="MOSHI_HERDR_PATH=$HOME/.local/share/mise/shims/herdr"
	[ "$status" -eq 0 ]
	! grep -q "restart" "$LOG"
}

# The drop-in is what supplies the value, and it has to be a drop-in rather
# than an edit to the unit: `service install` runs on every apply once paired
# and regenerates the unit, which would discard anything written into it.
@test "the value comes from a drop-in, not from the generated unit" {
	f="$BATS_TEST_DIRNAME/../home/dot_config/systemd/user/moshi-hook.service.d/10-herdr-path.conf"
	[ -f "$f" ]
	grep -q "^Environment=MOSHI_HERDR_PATH=" "$f"
	# %h, not a hardcoded home: the unit is applied to whatever machine runs it.
	grep -q "%h/" "$f"
	! grep -q "/home/" "$f"
}
