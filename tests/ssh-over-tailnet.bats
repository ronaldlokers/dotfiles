#!/usr/bin/env bats
#
# run_after_21-ssh-over-tailnet.sh.tmpl binds sshd to the Tailscale address and
# nothing else, so Moshi can reach the machine from a phone without the port
# being answerable from every café network the laptop joins.
#
# The branch that matters most is the one with no Tailscale address. The
# tempting fallback there — bind every interface so it works anyway — is
# precisely the exposure the script exists to prevent, and it is the kind of
# convenience that gets added later by someone who does not know why it is
# absent. Two cases below pin it.
#
# sudo, systemctl and tailscale are all stubbed. Against the real ones these
# tests would reconfigure the machine running them, which is the same reason
# the systemd and Proton suites stub theirs.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	TMPL="$BATS_TEST_DIRNAME/../home/.chezmoiscripts/run_after_21-ssh-over-tailnet.sh.tmpl"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"
	LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$LOG"
	DROPIN="$BATS_TEST_TMPDIR/10-dotfiles-tailnet.conf"

	# `sudo` that records what it was asked to do and then does it, so the test
	# can both assert on intent and observe the effect.
	cat >"$BIN/sudo" <<'STUB'
#!/bin/sh
printf 'sudo %s\n' "$*" >>"$LOG"
[ -n "${SUDO_RC:-}" ] && exit "$SUDO_RC"
exec "$@"
STUB

	cat >"$BIN/systemctl" <<'STUB'
#!/bin/sh
printf 'systemctl %s\n' "$*" >>"$LOG"
for a in "$@"; do
	case "$a" in
	is-enabled) exit "${SSHD_ENABLED_RC:-1}" ;;
	esac
done
exit 0
STUB

	cat >"$BIN/tailscale" <<'STUB'
#!/bin/sh
printf 'tailscale %s\n' "$*" >>"$LOG"
[ -n "${TS_IP:-}" ] && printf '%s\n' "$TS_IP"
exit 0
STUB

	# Presence-only: the script probes for it with `command -v`.
	printf '#!/bin/sh\nexit 0\n' >"$BIN/sshd"

	chmod 755 "$BIN/sudo" "$BIN/systemctl" "$BIN/tailscale" "$BIN/sshd"

	# A curated PATH, not the real one. Removing a stub from $BIN is meaningless
	# if the genuine binary is still reachable further along — the first run of
	# the "no tailscale" case below picked up this machine's real tailnet
	# address and asserted nothing. Symlink in exactly what the script needs.
	SANDBOX="$BATS_TEST_TMPDIR/sandbox"
	mkdir -p "$SANDBOX"
	for t in sh cat head printf tee chmod env grep; do
		src="$(type -P "$t" 2>/dev/null)" || continue
		[ -n "$src" ] && ln -sf "$src" "$SANDBOX/$t"
	done

	SCRIPT="$BATS_TEST_TMPDIR/ssh-tailnet.sh"
	render_template "$TMPL" "$SCRIPT" "$PATH"
	export HOME LOG
}

run_script() {
	run env HOME="$HOME" LOG="$LOG" SSHD_DROPIN="$DROPIN" \
		PATH="$BIN:$SANDBOX" TS_IP="${TS_IP-100.64.0.1}" "$@" sh "$SCRIPT"
}

# --- the fail-closed branch --------------------------------------------------

@test "no Tailscale address means sshd is not enabled at all" {
	TS_IP="" run_script
	[ "$status" -eq 0 ]
	[[ "$output" == *"no Tailscale address"* ]]
	[ ! -e "$DROPIN" ]
	! grep -q "enable" "$LOG"
}

# The specific thing that must never be added back: falling through to a config
# with no ListenAddress, which is sshd's default of every interface.
@test "no Tailscale address never writes a config without a ListenAddress" {
	TS_IP="" run_script
	[ ! -e "$DROPIN" ]
	! grep -q "sudo tee" "$LOG"
}

@test "it says how to fix it" {
	TS_IP="" run_script
	[[ "$output" == *"tailscale up"* ]]
}

# --- the binding -------------------------------------------------------------

@test "the config binds to the Tailscale address" {
	run_script
	[ "$status" -eq 0 ]
	grep -qx "ListenAddress 100.64.0.1" "$DROPIN"
}

@test "keys only, no passwords, no root" {
	run_script
	grep -qx "PasswordAuthentication no" "$DROPIN"
	grep -qx "KbdInteractiveAuthentication no" "$DROPIN"
	grep -qx "PermitRootLogin no" "$DROPIN"
}

@test "a changed Tailscale address is picked up on the next apply" {
	run_script
	grep -qx "ListenAddress 100.64.0.1" "$DROPIN"
	TS_IP=100.64.0.99 run_script
	grep -qx "ListenAddress 100.64.0.99" "$DROPIN"
}

# --- idempotence -------------------------------------------------------------

# A settled machine must need no sudo at all. An apply that asks for a password
# every time is an apply that stops being run.
@test "an unchanged config touches sudo not at all" {
	run_script
	: >"$LOG"
	run_script
	[ "$status" -eq 0 ]
	! grep -q "sudo tee" "$LOG"
	! grep -q "sudo chmod" "$LOG"
}

@test "an unchanged config does not reload a running daemon" {
	SSHD_ENABLED_RC=0 run_script
	: >"$LOG"
	SSHD_ENABLED_RC=0 run_script
	! grep -q "reload" "$LOG"
}

# --- the unit ----------------------------------------------------------------

@test "sshd is enabled when it is not already" {
	run_script
	grep -q "systemctl enable --now sshd.service" "$LOG"
}

# Reload, not restart: the session running the apply may well be the one that
# would be cut.
@test "a config change under a running daemon reloads rather than restarts" {
	SSHD_ENABLED_RC=0 run_script
	grep -q "systemctl reload sshd.service" "$LOG"
	! grep -q "restart" "$LOG"
}

# --- the guards --------------------------------------------------------------

@test "a machine without openssh is skipped, not failed" {
	rm "$BIN/sshd"
	run_script
	[ "$status" -eq 0 ]
	[[ "$output" == *"openssh not installed"* ]]
	[ ! -e "$DROPIN" ]
}

@test "a machine without tailscale is skipped, not failed" {
	rm "$BIN/tailscale"
	run_script
	[ "$status" -eq 0 ]
	[[ "$output" == *"tailscale not installed"* ]]
}

# Report and continue, the rule the whole apply chain follows: sudo needing a
# password with no TTY must not stop the scripts queued behind this one.
@test "sudo refusing does not abort the apply" {
	SUDO_RC=1 run_script
	[ "$status" -eq 0 ]
	[[ "$output" == *"could not write"* ]]
}
