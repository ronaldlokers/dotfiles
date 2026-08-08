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
	UNIT_DROPIN="$BATS_TEST_TMPDIR/unit.d/10-wait-for-tailnet.conf"

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
	is-active) exit "${SSHD_ACTIVE_RC:-0}" ;;
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
	for t in sh cat head printf tee chmod mkdir env grep; do
		src="$(type -P "$t" 2>/dev/null)" || continue
		[ -n "$src" ] && ln -sf "$src" "$SANDBOX/$t"
	done

	SCRIPT="$BATS_TEST_TMPDIR/ssh-tailnet.sh"
	render_template "$TMPL" "$SCRIPT" "$PATH"
	export HOME LOG
}

run_script() {
	run env HOME="$HOME" LOG="$LOG" SSHD_DROPIN="$DROPIN" \
		SSHD_UNIT_DROPIN="$UNIT_DROPIN" \
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

# --- the boot race -----------------------------------------------------------
#
# `ListenAddress <tailnet ip>` is a bind to an address that does not exist until
# tailscaled has brought the interface up. On 2026-08-08 this machine came up
# from a reboot with sshd dead:
#
#   error: Bind to port 22 on 100.112.124.106 failed: Cannot assign requested
#   address.
#   sshd.service: Start request repeated too quickly.
#
# Five restarts inside one second, the start limit latched, and sshd stayed off
# for the rest of the boot — while the tailnet address appeared moments later.
# Moshi, which reaches this machine over SSH, could not connect at all. The unit
# drop-in below is what stops the config from being self-defeating on every
# reboot, so it is written from the same script and pinned by the same suite.

@test "the unit waits for tailscaled before starting sshd" {
	run_script
	[ "$status" -eq 0 ]
	grep -qx "After=tailscaled.service" "$UNIT_DROPIN"
	grep -qx "Wants=tailscaled.service" "$UNIT_DROPIN"
}

# Ordering after tailscaled is necessary and not sufficient: the unit is up
# before the address is assigned. What sshd actually needs is the address it was
# told to bind, so that — not the interface, not the daemon — is what is waited
# for.
@test "the unit waits for the bound address itself, not merely the daemon" {
	run_script
	grep -q "ExecStartPre=" "$UNIT_DROPIN"
	grep -q "inet 100.64.0.1/" "$UNIT_DROPIN"
}

@test "a changed Tailscale address is picked up by the unit too" {
	run_script
	TS_IP=100.64.0.99 run_script
	grep -q "inet 100.64.0.99/" "$UNIT_DROPIN"
	! grep -q "inet 100.64.0.1/" "$UNIT_DROPIN"
}

# The failure that made this a total outage rather than a slow start: the
# retries burned the start limit, so the one attempt that would have succeeded
# never happened.
@test "the start limit cannot latch sshd off for the boot" {
	run_script
	grep -qx "StartLimitIntervalSec=0" "$UNIT_DROPIN"
	grep -q "^Restart=" "$UNIT_DROPIN"
}

# A wait with no ceiling is a boot that hangs. systemd's own timeout bounds it,
# so the loop needs no counter — and a counter would need a `$` that systemd
# would try to expand as a variable.
@test "the wait is bounded" {
	run_script
	grep -q "^TimeoutStartSec=" "$UNIT_DROPIN"
}

# The drop-in fixes the next boot. This fixes the one that already went wrong,
# which is the machine the apply is running on.
@test "an enabled sshd that is not running is started" {
	SSHD_ENABLED_RC=0 SSHD_ACTIVE_RC=3 run_script
	grep -q "systemctl reset-failed sshd.service" "$LOG"
	grep -q "systemctl start sshd.service" "$LOG"
}

@test "a running sshd is never started or restarted out from under a session" {
	SSHD_ENABLED_RC=0 SSHD_ACTIVE_RC=0 run_script
	! grep -q "systemctl start sshd" "$LOG"
	! grep -q "restart" "$LOG"
}

@test "writing the unit drop-in reloads systemd" {
	run_script
	grep -q "systemctl daemon-reload" "$LOG"
}

@test "an unchanged unit drop-in reloads nothing and needs no sudo" {
	run_script
	: >"$LOG"
	run_script
	[ "$status" -eq 0 ]
	! grep -q "daemon-reload" "$LOG"
	! grep -q "sudo tee" "$LOG"
}

# Fail closed all the way down: with no tailnet address there is no address to
# wait for, and nothing about sshd should be touched.
@test "no Tailscale address writes no unit drop-in either" {
	TS_IP="" run_script
	[ ! -e "$UNIT_DROPIN" ]
	! grep -q "daemon-reload" "$LOG"
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
