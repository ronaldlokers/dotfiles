#!/usr/bin/env bats
#
# dotfiles-secrets-export writes the passphrase-encrypted offline copy of the
# secrets that cannot be re-issued. It is the mechanism behind a sentence the
# README had been addressing to a human's memory: Proton holds the SSH keys,
# the file secrets and the recovery path, so one lockout takes all three, and
# an offline copy is the only thing that closes that.
#
# Everything it touches is stubbed. It reads a real vault and writes real key
# material to a real destination, so a test that used either would be exporting
# this developer's actual age key to a temp directory.
#
# Most cases need a pty: the script refuses to run without a terminal, because
# `age -p` has to ask for a passphrase. That refusal is itself the first test.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_dotfiles-secrets-export"

	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$STUB_LOG"
	make_pass_cli_stub "$BIN"
	make_age_keygen_stub "$BIN"
	make_age_stub "$BIN"

	# The age key the fake vault hands back. A recognisable sentinel, so any
	# test that finds it anywhere it should not be has found a leak.
	ITEMS="$BATS_TEST_TMPDIR/items"
	mkdir -p "$ITEMS"
	printf 'AGE-SECRET-KEY-SENTINEL-PLAINTEXT\n' >"$ITEMS/sops age keys"

	DEST="$BATS_TEST_TMPDIR/stick"
	mkdir -p "$DEST"

	MANIFEST="$HOME/.local/state/dotfiles/secrets-backup"
	export HOME STUB_LOG
}

# `age -p` encrypts stdin under a passphrase it prompts for. The stub cannot
# prompt, so it just consumes stdin and emits an armoured-looking blob — what
# matters to these tests is that the plaintext went in and did not come out.
make_age_stub() {
	local bin="$1"
	mkdir -p "$bin"
	cat >"$bin/age" <<'STUB'
#!/bin/sh
[ -n "${STUB_LOG:-}" ] && printf 'age %s\n' "$*" >>"$STUB_LOG"
cat >/dev/null
[ "${AGE_RC:-0}" -ne 0 ] && exit "${AGE_RC}"
[ -n "${AGE_EMPTY:-}" ] && exit 0
printf -- '-----BEGIN AGE ENCRYPTED FILE-----\n'
printf 'ZmFrZSBjaXBoZXJ0ZXh0\n'
printf -- '-----END AGE ENCRYPTED FILE-----\n'
exit 0
STUB
	chmod 755 "$bin/age"
}

# Runs the export under a pty, so the `[ -t 0 ]` guard sees a terminal.
# Everything before `--` is an env assignment; everything after is a script arg.
run_export() {
	local envs=() args=() past=0 arg
	for arg in "$@"; do
		if [ "$arg" = "--" ]; then past=1; continue; fi
		if [ "$past" = 0 ]; then envs+=("$arg"); else args+=("$arg"); fi
	done

	# -u XDG_STATE_HOME is not optional. This desktop exports it pointing at the
	# real ~/.local/state, and the script writes its manifest to
	# ${XDG_STATE_HOME:-$HOME/.local/state} — so without this the suite writes a
	# fixture manifest into the developer's actual state directory, where the
	# real weekly check would later read it and compare a fake fingerprint
	# against the real vault. Redirecting HOME alone does not cover it. Same
	# hazard, same fix as mise.toml's [tasks.verify].
	local cmd="" word
	for word in env -u XDG_STATE_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
		-u XDG_CACHE_HOME "HOME=$HOME" "STUB_LOG=$STUB_LOG" \
		"PATH=$BIN:$PATH" "PASS_ITEM_DIR=$ITEMS" ${envs[@]+"${envs[@]}"} \
		sh "$SCRIPT" ${args[@]+"${args[@]}"}; do
		cmd="$cmd $(printf '%q' "$word")"
	done
	run script -qec "$cmd" /dev/null </dev/null
}

# --- the guards --------------------------------------------------------------

# No pty here on purpose. `age -p` would block forever on a passphrase prompt
# with nothing to type into, so the script has to refuse first — the same
# reasoning as the host-package script's sudo probe.
@test "refuses to run without a terminal" {
	run env -u XDG_STATE_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" STUB_LOG="$STUB_LOG" \
		PATH="$BIN:$PATH" PASS_ITEM_DIR="$ITEMS" sh "$SCRIPT" "$DEST" </dev/null
	[ "$status" -ne 0 ]
	[[ "$output" == *"needs a terminal"* ]]
	[ -z "$(ls -A "$DEST")" ]
}

@test "refuses without a Proton Pass session" {
	run_export PASS_INFO_RC=1 -- "$DEST"
	[ "$status" -ne 0 ]
	[[ "$output" == *"no Proton Pass session"* ]]
	[ -z "$(ls -A "$DEST")" ]
}

@test "refuses a destination that does not exist" {
	run_export -- "$BATS_TEST_TMPDIR/not-mounted"
	[ "$status" -ne 0 ]
	[[ "$output" == *"no such directory"* ]]
}

@test "wrong argument count gets the usage message" {
	run_export --
	[ "$status" -eq 2 ]
	[[ "$output" == *"usage:"* ]]
}

@test "--help explains itself and exits 0" {
	run_export -- --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage:"* ]]
	# The one instruction that makes the whole thing worth doing: a passphrase
	# kept only in the vault rebuilds the single point of failure this exists
	# to break.
	[[ "$output" == *"Do not keep that passphrase only in Proton"* ]]
}

# --- the happy path ----------------------------------------------------------

@test "writes an encrypted copy and records it" {
	run_export -- "$DEST"
	[ "$status" -eq 0 ]
	[ -s "$DEST/dotfiles-age-key.age" ]
	[ -s "$MANIFEST" ]
}

@test "the copy is ciphertext, not the key" {
	run_export -- "$DEST"
	[ "$status" -eq 0 ]
	grep -q "BEGIN AGE ENCRYPTED FILE" "$DEST/dotfiles-age-key.age"
	! grep -q "SENTINEL-PLAINTEXT" "$DEST/dotfiles-age-key.age"
}

# The manifest is the thing the weekly check reads, and it lives on this
# machine's disk unencrypted. It must carry a fingerprint and nothing else.
@test "the manifest records the public key, the date and the destination" {
	run_export -- "$DEST"
	[ "$status" -eq 0 ]
	grep -q "^age_public_key=age1fakepubkeyfixture$" "$MANIFEST"
	grep -q "^destination=$DEST/dotfiles-age-key.age$" "$MANIFEST"
	grep -q "^date=20" "$MANIFEST"
}

@test "the manifest carries no secret material" {
	run_export -- "$DEST"
	[ "$status" -eq 0 ]
	! grep -q "SENTINEL-PLAINTEXT" "$MANIFEST"
	! grep -q "AGE-SECRET-KEY" "$MANIFEST"
}

# The private key is piped to age-keygen and to age, never written out for
# either of them to read. Nothing in the destination or the state directory may
# hold it.
@test "the plaintext key never reaches disk" {
	run_export -- "$DEST"
	[ "$status" -eq 0 ]
	! grep -rq "SENTINEL-PLAINTEXT" "$DEST" "$HOME/.local/state"
}

@test "encrypts with a passphrase, not to a recipient" {
	run_export -- "$DEST"
	[ "$status" -eq 0 ]
	# -p is the passphrase mode; a -r/--recipient export would need a key to
	# decrypt it, which is the circular dependency this exists to break
	grep -q -- "^age .*-p" "$STUB_LOG"
	! grep -q -- "^age .*-r " "$STUB_LOG"
}

# --- failures leave nothing behind -------------------------------------------

@test "an unreadable vault item writes nothing" {
	run_export PASS_VIEW_RC=1 -- "$DEST"
	[ "$status" -ne 0 ]
	[[ "$output" == *"could not read"* ]]
	[ -z "$(ls -A "$DEST")" ]
	[ ! -e "$MANIFEST" ]
}

@test "an item that is not a usable age identity writes nothing" {
	run_export AGE_KEYGEN_RC=1 -- "$DEST"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not a usable age identity"* ]]
	[ -z "$(ls -A "$DEST")" ]
	[ ! -e "$MANIFEST" ]
}

# The copy being replaced is by definition the only other one, so a failed
# encryption must not leave a truncated file where a good one was — the same
# rule the restore script follows in the other direction.
@test "a failed encryption leaves no partial file and no record" {
	run_export AGE_RC=1 -- "$DEST"
	[ "$status" -ne 0 ]
	[[ "$output" == *"encryption failed"* ]]
	[ -z "$(ls -A "$DEST")" ]
	[ ! -e "$MANIFEST" ]
}

@test "an encryption that silently produces nothing is caught" {
	run_export AGE_EMPTY=1 -- "$DEST"
	[ "$status" -ne 0 ]
	[[ "$output" == *"empty file"* ]]
	[ ! -e "$DEST/dotfiles-age-key.age" ]
	[ ! -e "$MANIFEST" ]
}

@test "a failed run leaves no temp file behind" {
	run_export AGE_RC=1 -- "$DEST"
	[ "$status" -ne 0 ]
	[ -z "$(find "$DEST" -name '.*' -type f -print -quit)" ]
}

# --- re-export ---------------------------------------------------------------

# Rotating the age key is exactly when the check tells you to run this again,
# so replacing an existing copy has to work rather than refuse.
@test "re-exporting replaces the copy and updates the record" {
	run_export -- "$DEST"
	[ "$status" -eq 0 ]
	run_export AGE_PUBKEY="age1rotatedkey" -- "$DEST"
	[ "$status" -eq 0 ]
	grep -q "^age_public_key=age1rotatedkey$" "$MANIFEST"
	[ "$(grep -c "^age_public_key=" "$MANIFEST")" -eq 1 ]
}
