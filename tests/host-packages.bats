#!/usr/bin/env bats
#
# run_after_20-install-host-packages.sh.tmpl is 220 lines and CI reached line
# 62 of it. The bootstrap job runs on Ubuntu, where the no-pacman branch exits
# early; the container-gates job runs on Arch, where the container gate exits
# earlier still. Everything past those two — the sudo probe, both install
# loops, the failure accounting, and the three side-effect blocks that add a
# group, enable a unit and change the login shell — never ran anywhere.
#
# That is the whole reason this file exists, and why every external command is
# stubbed. The script's job is to install packages and mutate the system with
# sudo; running it for real against the machine under test is not an option,
# and an Arch container buys nothing, because all three side-effect blocks are
# keyed on packages being installed and the real lists are Discord, Obsidian
# and Spotify.
#
# The stubs are local to this file rather than in helpers.bash: pacman, an AUR
# helper, getent and usermod are specific to this one script, and its systemctl
# needs `is-enabled`, which the enable-script tests do not.
#
# IMPORTANT, and learned the hard way while writing this file: the script is run
# with PATH set to a sandbox directory and NOTHING else — not $BIN:$PATH. The
# "absent tool" cases cannot be written by deleting a stub, the way
# proton-ssh-load.bats can get away with, because that trick relies on the real
# binary not being in a system directory. pacman and yay are both in /usr/bin on
# the machine this suite is most likely to run on. Deleting the yay stub and
# leaving the ambient PATH in place does not test the no-AUR-helper branch — it
# hands seven package names to the developer's real AUR helper and builds them.
# Ask me how I know.

bats_require_minimum_version 1.5.0

setup() {
	TMPL="$BATS_TEST_DIRNAME/../home/.chezmoiscripts/run_after_20-install-host-packages.sh.tmpl"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"

	# The real commands the script needs that are not worth faking: they do not
	# touch the system, and reimplementing grep would be its own bug source.
	# Everything else on PATH is a stub, because PATH is only ever this
	# directory — see the note at the top of the file.
	# `true` earns its place: the sudo stub `exec`s it for the `sudo -n true`
	# probe, and exec bypasses the shell builtin and searches PATH. Without it the
	# probe fails, every test takes the no-TTY skip branch, and the ones that
	# assert a command was *not* run pass vacuously.
	REAL_TOOLS=(bash grep tr cut env true)

	# The pretend package database: one installed package per line. The pacman
	# and AUR stubs read and append to it, so "did the install actually take"
	# is answered the same way the script answers it — by querying, not by
	# trusting an exit code.
	PKG_DB="$BATS_TEST_TMPDIR/installed"
	: >"$PKG_DB"

	SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
	PACMAN_LOG="$BATS_TEST_TMPDIR/pacman.log"
	AUR_LOG="$BATS_TEST_TMPDIR/aur.log"
	SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
	USERMOD_LOG="$BATS_TEST_TMPDIR/usermod.log"
	CHSH_LOG="$BATS_TEST_TMPDIR/chsh.log"
	for f in "$SUDO_LOG" "$PACMAN_LOG" "$AUR_LOG" "$SYSTEMCTL_LOG" \
		"$USERMOD_LOG" "$CHSH_LOG"; do : >"$f"; done

	make_stubs

	SCRIPT="$BATS_TEST_TMPDIR/packages.sh"
	chezmoi execute-template --source "$BATS_TEST_DIRNAME/.." \
		<"$TMPL" >"$SCRIPT"

	export HOME PKG_DB SUDO_LOG PACMAN_LOG AUR_LOG SYSTEMCTL_LOG \
		USERMOD_LOG CHSH_LOG
}

# The rendered script bakes in is-container at render time, so on a container
# it renders to the early-exit form and none of this is meaningful. CI's
# container-gates job covers that branch for real.
setup_file() {
	if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
		skip "runs inside a container; the script's container branch exits early"
	fi
}

make_stubs() {
	# `sudo -n true` is the probe; everything else is a real command the script
	# wants run as root, so exec it and let the matching stub answer. SUDO_N_RC
	# drives the probe alone, which is what the no-TTY branch turns on.
	cat >"$BIN/sudo" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$SUDO_LOG"
if [ "$1" = "-n" ]; then
	shift
	[ "${SUDO_N_RC:-0}" -ne 0 ] && exit "${SUDO_N_RC}"
fi
exec "$@"
STUB

	# `pacman -Q` is how the script decides what is missing and, afterwards,
	# whether an install actually landed. `-S` marks packages installed unless
	# the test named them in REPO_FAIL — which is the "pacman exits 0 having
	# skipped a package" case the script explicitly does not trust.
	cat >"$BIN/pacman" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$PACMAN_LOG"
case "$1" in
-Q)
	grep -qxF "$2" "$PKG_DB"
	exit $?
	;;
-S)
	shift
	for pkg in "$@"; do
		case "$pkg" in --*) continue ;; esac
		case " ${REPO_FAIL:-} " in *" $pkg "*) continue ;; esac
		grep -qxF "$pkg" "$PKG_DB" || printf '%s\n' "$pkg" >>"$PKG_DB"
	done
	exit "${PACMAN_S_RC:-0}"
	;;
esac
exit 0
STUB

	# yay and paru are interchangeable to the script; it takes whichever it
	# finds first. AUR_FAIL names packages whose build "fails" — the point
	# being that one bad PKGBUILD must not cost the others.
	cat >"$BIN/yay" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$AUR_LOG"
# Also record the PATH the build ran under: the script deliberately strips
# mise's shims before invoking this, and nothing proved it.
printf 'PATH=%s\n' "$PATH" >>"$AUR_LOG"
for pkg in "$@"; do
	case "$pkg" in -*) continue ;; esac
	case " ${AUR_FAIL:-} " in *" $pkg "*) exit 1 ;; esac
	grep -qxF "$pkg" "$PKG_DB" || printf '%s\n' "$pkg" >>"$PKG_DB"
done
exit 0
STUB

	cat >"$BIN/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
# The unit is the last argument in both forms the script uses
# (`is-enabled --quiet UNIT`, `enable --now UNIT`).
unit=""
for a in "$@"; do unit="$a"; done
case "$1" in
is-enabled)
	case " ${UNITS_ENABLED:-} " in *" $unit "*) exit 0 ;; esac
	exit 1
	;;
esac
exit "${SYSTEMCTL_ENABLE_RC:-0}"
STUB

	cat >"$BIN/getent" <<'STUB'
#!/bin/sh
case "$1" in
group)
	case " ${GROUPS_PRESENT:-} " in *" $2 "*) printf '%s:x:100:\n' "$2"; exit 0 ;; esac
	exit 2
	;;
passwd)
	printf '%s:x:1000:1000::%s:%s\n' "$2" "$HOME" "${CURRENT_SHELL:-/bin/bash}"
	exit 0
	;;
esac
exit 2
STUB

	# id -un names the user the side-effect blocks act on; id -nG is how the
	# script decides the group membership is already there.
	cat >"$BIN/id" <<'STUB'
#!/bin/sh
case "$1" in
-un) printf '%s\n' "${TEST_USER:-tester}" ;;
-nG) printf '%s\n' "${USER_GROUPS:-users}" ;;
*) exit 1 ;;
esac
exit 0
STUB

	cat >"$BIN/usermod" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$USERMOD_LOG"
exit "${USERMOD_RC:-0}"
STUB

	cat >"$BIN/chsh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$CHSH_LOG"
exit "${CHSH_RC:-0}"
STUB

	# A zsh on PATH that is deliberately NOT a path listed in /etc/shells, so
	# the login-shell block resolves the same way on every machine. See the
	# note on the chsh test below.
	printf '#!/bin/sh\nexit 0\n' >"$BIN/zsh"

	chmod 755 "$BIN"/*

	# Link in the handful of real tools, so PATH can be this directory alone.
	# `type -P`, not `command -v`: for `true` the latter answers "true", the
	# shell builtin, and links the name to itself. The sudo stub execs it, exec
	# searches PATH, and the dangling link fails the probe — which silently
	# sends every test down the skip branch.
	local tool path
	for tool in "${REAL_TOOLS[@]}"; do
		path="$(type -P "$tool")"
		[ -n "$path" ] || { echo "missing required tool: $tool" >&2; return 1; }
		ln -sf "$path" "$BIN/$tool"
	done
}

# A copy of the sandbox with the named commands removed, for the branches that
# ask what happens when a tool is absent. A copy, because the answer has to be
# "nothing on PATH provides it" — and the only way to be sure of that is for
# PATH to name one directory whose contents are known.
sandbox_without() {
	local dir="$BATS_TEST_TMPDIR/bin-without-$1"
	rm -rf "$dir"
	cp -a "$BIN" "$dir"
	local cmd
	for cmd in "$@"; do rm -f "$dir/$cmd"; done
	printf '%s\n' "$dir"
}

run_packages() {
	run_packages_in "$BIN" "$@"
}

run_packages_in() {
	local path="$1"
	shift
	run env -i HOME="$HOME" PATH="$path" PKG_DB="$PKG_DB" \
		SUDO_LOG="$SUDO_LOG" PACMAN_LOG="$PACMAN_LOG" AUR_LOG="$AUR_LOG" \
		SYSTEMCTL_LOG="$SYSTEMCTL_LOG" USERMOD_LOG="$USERMOD_LOG" \
		CHSH_LOG="$CHSH_LOG" "$@" bash "$SCRIPT" </dev/null
}

installed() { grep -qxF "$1" "$PKG_DB"; }

# Asserts the run actually got past the pacman and sudo gates. Every test below
# that asserts a command was NOT run needs this: while writing this file, a
# broken stub sent every run down the no-TTY skip branch, and eight tests went
# on passing because nothing had run at all. An assertion of absence is only
# worth anything once you know the code that would have done it was reached.
got_past_the_gates() {
	[ -s "$PACMAN_LOG" ] || {
		echo "run never reached the install stage; absence proves nothing" >&2
		return 1
	}
}

# --- the gates ---------------------------------------------------------------

@test "skips cleanly when there is no pacman" {
	# The branch every non-Arch machine takes. PATH is a sandbox with the
	# pacman stub removed and nothing else on it, so `command -v pacman` really
	# does come back empty — with the ambient PATH still in place this would
	# find /usr/bin/pacman and query the real package database instead.
	run_packages_in "$(sandbox_without pacman)"
	[ "$status" -eq 0 ]
	[[ "$output" == *"no pacman"* ]]
	[ ! -s "$PACMAN_LOG" ]
}

# The no-TTY probe. A password prompt in a non-interactive apply hangs forever,
# so the script has to bail before pacman is ever called — and this is the exact
# condition `devpod up` and CI apply under.
@test "skips when sudo needs a password and there is no TTY" {
	run_packages SUDO_N_RC=1
	[ "$status" -eq 0 ]
	[[ "$output" == *"no TTY"* ]]
	[[ "$output" == *"interactive shell"* ]]
	[ ! -s "$PACMAN_LOG" ]
}

# --- repo packages -----------------------------------------------------------

@test "installs the missing repo packages in one transaction" {
	run_packages
	[ "$status" -eq 0 ]
	# One -S call, not one per package: shared dependencies resolve once and
	# there is a single sudo prompt.
	[ "$(grep -c -- '-S --needed --noconfirm' "$PACMAN_LOG")" -eq 1 ]
	grep -q -- "--needed" "$PACMAN_LOG"
	grep -q -- "--noconfirm" "$PACMAN_LOG"
	installed discord
	installed zsh
}

@test "does not reinstall a package that is already there" {
	printf 'discord\n' >"$PKG_DB"
	run_packages
	[ "$status" -eq 0 ]
	got_past_the_gates
	# discord was already installed, so it must not appear in the -S argv
	! grep -- '-S --needed --noconfirm' "$PACMAN_LOG" | grep -qw discord
}

# pacman can exit 0 having quietly skipped a package, so the script re-queries
# the database rather than trusting the exit code. Without that, a package that
# never installed would be reported as fine.
@test "a package pacman claims to install but does not is reported as failed" {
	run_packages REPO_FAIL="discord"
	[ "$status" -eq 0 ]
	[[ "$output" == *"failed to install"* ]]
	[[ "$output" == *"discord"* ]]
	! installed discord
}

@test "a failed package does not stop the others installing" {
	run_packages REPO_FAIL="discord"
	[ "$status" -eq 0 ]
	installed zsh
	installed signal-desktop
}

# --- AUR packages ------------------------------------------------------------

@test "builds AUR packages one at a time, not as one transaction" {
	run_packages
	[ "$status" -eq 0 ]
	# One -S invocation per package: a single failing PKGBUILD aborts a whole
	# yay transaction, and one broken AUR package must not cost the other six.
	[ "$(grep -c -- '-S --needed --noconfirm' "$AUR_LOG")" -eq 7 ]
	installed spotify
	installed zen-browser-bin
}

# The reason the loop is one-at-a-time, stated as a test.
@test "one failing AUR build does not cost the others" {
	run_packages AUR_FAIL="spotify"
	[ "$status" -eq 0 ]
	! installed spotify
	installed winbox
	installed zen-browser-bin
	[[ "$output" == *"failed to install"* ]]
	[[ "$output" == *"spotify"* ]]
}

# mise's shims shadow /usr/bin, so a PKGBUILD calling python/node/ruby would get
# a mise interpreter that cannot see its own makedepends — or bake mise paths
# into the built package. The script strips PATH back to system directories for
# the build, and nothing proved it until now.
@test "AUR builds run on a system-only PATH with no mise shims" {
	run_packages
	[ "$status" -eq 0 ]
	grep -q '^PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin$' "$AUR_LOG"
	! grep '^PATH=' "$AUR_LOG" | grep -q "$BIN"
}

# Both helpers have to be absent, and absent from the whole of PATH: the script
# takes whichever of yay/paru it finds. This is the test that has to be written
# most carefully — get it wrong and it does not skip the AUR block, it hands
# seven package names to a real AUR helper and starts building.
@test "says so and carries on when there is no AUR helper" {
	run_packages_in "$(sandbox_without yay paru)"
	[ "$status" -eq 0 ]
	[[ "$output" == *"no AUR helper"* ]]
	[ ! -s "$AUR_LOG" ]
	# the repo half still ran
	installed discord
}

# --- group membership --------------------------------------------------------

@test "adds the user to a group its package needs" {
	run_packages GROUPS_PRESENT="uucp" USER_GROUPS="users" TEST_USER="tester"
	[ "$status" -eq 0 ]
	grep -q -- "-aG uucp tester" "$USERMOD_LOG"
	# the change does not apply to an already-open session, and it says so
	[[ "$output" == *"log out and back in"* ]]
}

@test "does not grant device access for a package that is not installed" {
	# chirp-next fails to build, so nothing should hand out its group
	run_packages AUR_FAIL="chirp-next" GROUPS_PRESENT="uucp" USER_GROUPS="users"
	[ "$status" -eq 0 ]
	got_past_the_gates
	[ ! -s "$USERMOD_LOG" ]
}

@test "skips the group when the group does not exist" {
	run_packages GROUPS_PRESENT="" USER_GROUPS="users"
	[ "$status" -eq 0 ]
	got_past_the_gates
	[ ! -s "$USERMOD_LOG" ]
}

@test "does not re-add a user who is already in the group" {
	run_packages GROUPS_PRESENT="uucp" USER_GROUPS="users uucp"
	[ "$status" -eq 0 ]
	got_past_the_gates
	[ ! -s "$USERMOD_LOG" ]
}

@test "a failed usermod reports the manual command instead of aborting" {
	run_packages GROUPS_PRESENT="uucp" USER_GROUPS="users" USERMOD_RC=1 \
		TEST_USER="tester"
	[ "$status" -eq 0 ]
	[[ "$output" == *"sudo usermod -aG uucp tester"* ]]
}

# --- system units ------------------------------------------------------------

@test "enables the units its packages ship disabled" {
	run_packages UNITS_ENABLED=""
	[ "$status" -eq 0 ]
	# the socket, not the service: pcscd is socket-activated, and enabling the
	# service directly would keep the daemon resident for nothing
	grep -q "enable --now pcscd.socket" "$SYSTEMCTL_LOG"
	grep -q "enable --now tailscaled.service" "$SYSTEMCTL_LOG"
}

@test "does not re-enable a unit that is already enabled" {
	run_packages UNITS_ENABLED="pcscd.socket tailscaled.service"
	[ "$status" -eq 0 ]
	got_past_the_gates
	! grep -q "enable --now" "$SYSTEMCTL_LOG"
}

@test "does not enable a unit whose package is not installed" {
	run_packages REPO_FAIL="pcsclite tailscale" UNITS_ENABLED=""
	[ "$status" -eq 0 ]
	got_past_the_gates
	! grep -q "enable --now" "$SYSTEMCTL_LOG"
}

# --- login shell -------------------------------------------------------------

# Only the negative is reachable here, and deliberately so. The script guards
# the chsh on `grep -qxF "$zsh_path" /etc/shells`, an absolute path no test can
# redirect, so the positive branch cannot be exercised without editing a real
# system file. The stub zsh therefore lives somewhere /etc/shells will never
# list, which makes this deterministic on every machine — including a CI runner
# that does have a real zsh in /usr/bin. What is pinned is that the guard holds:
# a shell missing from /etc/shells is never passed to chsh, which is what stops
# the script handing the user a login shell that cannot be set.
@test "never changes the login shell to something not in /etc/shells" {
	run_packages CURRENT_SHELL="/bin/bash"
	[ "$status" -eq 0 ]
	got_past_the_gates
	[ ! -s "$CHSH_LOG" ]
}

@test "does not touch the login shell when zsh is not installed" {
	run_packages REPO_FAIL="zsh" CURRENT_SHELL="/bin/bash"
	[ "$status" -eq 0 ]
	got_past_the_gates
	[ ! -s "$CHSH_LOG" ]
}

# --- overall contract --------------------------------------------------------

# Best-effort by design: a hard failure here would block every later step of the
# apply over one flaky AUR build, and because this is a plain run_after rather
# than a run_onchange, the next apply retries whatever did not land.
@test "exits 0 even when everything fails" {
	run_packages REPO_FAIL="discord ghostty obsidian proton-vpn-gtk-app prusa-slicer rpi-imager signal-desktop tailscale pam-u2f pcsclite yubikey-manager yubikey-personalization zsh" \
		AUR_FAIL="bambustudio-bin chirp-next claude-desktop proton-pass-bin spotify winbox zen-browser-bin"
	[ "$status" -eq 0 ]
	[[ "$output" == *"failed to install"* ]]
	[[ "$output" == *"re-run 'chezmoi apply'"* ]]
}

@test "a fully successful run reports no failures" {
	run_packages
	[ "$status" -eq 0 ]
	[[ "$output" != *"failed to install"* ]]
}
