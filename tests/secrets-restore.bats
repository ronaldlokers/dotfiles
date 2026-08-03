#!/usr/bin/env bats
#
# dotfiles-secrets-restore reads back the passphrase-encrypted copy that
# dotfiles-secrets-export writes.
#
# The gap it closes: the export has been write-only since it was added, and the
# weekly check verifies a *record* — a date and a public key in a local file —
# never the artifact. A fingerprint match proves the vault's key has not
# rotated. It says nothing about whether the copy decrypts, whether the
# passphrase is the one you think it is, or whether the medium is readable.
# Those are the questions that matter on the day it is needed, and until now
# the only way to ask them was `age -d`, which prints the private key into
# scrollback.
#
# age and age-keygen are stubbed, for the reason the export suite stubs them:
# a test that used the real ones would need a real passphrase prompt and would
# be handling this developer's actual key.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_dotfiles-secrets-restore"

	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$STUB_LOG"
	make_age_keygen_stub "$BIN"
	make_age_decrypt_stub "$BIN"

	BACKUP="$BATS_TEST_TMPDIR/dotfiles-age-key.age"
	printf -- '-----BEGIN AGE ENCRYPTED FILE-----\nZmFrZQ==\n-----END AGE ENCRYPTED FILE-----\n' \
		>"$BACKUP"

	# The manifest the export leaves behind. run_restore clears XDG_STATE_HOME,
	# so the script falls back to $HOME/.local/state.
	MANIFEST="$HOME/.local/state/dotfiles/secrets-backup"
	mkdir -p "$(dirname "$MANIFEST")"
	printf 'date=2026-07-01T00:00:00Z\ndestination=/mnt/stick/dotfiles-age-key.age\nage_public_key=age1fakepubkeyfixture\n' \
		>"$MANIFEST"

	KEY_TARGET="$HOME/.config/sops/age/keys.txt"
	export HOME STUB_LOG
}

# `age -d <file>` prints the decrypted plaintext. The stub ignores the file and
# emits a sentinel, so any test finding that sentinel in the output has found
# the leak this script exists to avoid.
#
#   AGE_DECRYPT_RC     exit code                              (default 0)
#   AGE_DECRYPT_EMPTY  when set, exit 0 having printed nothing
make_age_decrypt_stub() {
	local bin="$1"
	mkdir -p "$bin"
	cat >"$bin/age" <<'STUB'
#!/bin/sh
[ -n "${STUB_LOG:-}" ] && printf 'age %s\n' "$*" >>"$STUB_LOG"
[ "${AGE_DECRYPT_RC:-0}" -ne 0 ] && exit "${AGE_DECRYPT_RC}"
[ -n "${AGE_DECRYPT_EMPTY:-}" ] && exit 0
printf 'AGE-SECRET-KEY-SENTINEL-RESTORED\n'
exit 0
STUB
	chmod 755 "$bin/age"
}

# Under a pty, because the script refuses without a terminal — same harness
# shape as the export suite. Everything before `--` is an env assignment,
# everything after is a script argument.
run_restore() {
	local envs=() args=() past=0 arg
	for arg in "$@"; do
		if [ "$arg" = "--" ]; then past=1; continue; fi
		if [ "$past" = 0 ]; then envs+=("$arg"); else args+=("$arg"); fi
	done
	local cmd="" word
	for word in env -u XDG_STATE_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
		-u XDG_CACHE_HOME "HOME=$HOME" "STUB_LOG=$STUB_LOG" \
		"PATH=$BIN:$PATH" ${envs[@]+"${envs[@]}"} \
		sh "$SCRIPT" ${args[@]+"${args[@]}"}; do
		cmd="$cmd $(printf '%q' "$word")"
	done
	run script -qec "$cmd" /dev/null </dev/null
}

# --- the guards --------------------------------------------------------------

@test "refuses to run without a terminal" {
	run env -u XDG_STATE_HOME -u XDG_CONFIG_HOME HOME="$HOME" \
		STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" sh "$SCRIPT" "$BACKUP" </dev/null
	[ "$status" -ne 0 ]
	[[ "$output" == *"needs a terminal"* ]]
}

@test "refuses a backup file that does not exist" {
	run_restore -- "$BATS_TEST_TMPDIR/not-plugged-in.age"
	[ "$status" -ne 0 ]
	[[ "$output" == *"no such file"* ]]
}

@test "refuses an empty backup file" {
	: >"$BACKUP"
	run_restore -- "$BACKUP"
	[ "$status" -ne 0 ]
	[[ "$output" == *"is empty"* ]]
}

@test "no argument gets the usage message" {
	run_restore --
	[ "$status" -eq 2 ]
	[[ "$output" == *"usage:"* ]]
}

@test "--help explains itself and decrypts nothing" {
	run_restore -- --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: dotfiles-secrets-restore"* ]]
	[ ! -s "$STUB_LOG" ]
}

@test "an unknown option is refused rather than treated as a filename" {
	run_restore -- --overwrite "$BACKUP"
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown option"* ]]
}

# --- verifying ---------------------------------------------------------------

@test "verifying a good backup succeeds and writes nothing" {
	run_restore -- "$BACKUP"
	[ "$status" -eq 0 ]
	[[ "$output" == *"usable age identity"* ]]
	[[ "$output" == *"Nothing was written"* ]]
	[ ! -e "$KEY_TARGET" ]
}

# The rule that makes this worth using instead of `age -d`, which was what the
# README suggested and which puts the private key in your scrollback.
@test "the key itself is never printed" {
	run_restore -- "$BACKUP"
	[ "$status" -eq 0 ]
	[[ "$output" != *"AGE-SECRET-KEY-SENTINEL-RESTORED"* ]]
	# ...but its public half is, because that is what identifies it and is safe
	[[ "$output" == *"age1fakepubkeyfixture"* ]]
}

@test "a wrong passphrase fails and says so" {
	run_restore AGE_DECRYPT_RC=1 -- "$BACKUP"
	[ "$status" -ne 0 ]
	[[ "$output" == *"could not decrypt"* ]]
	[[ "$output" == *"Wrong passphrase"* ]]
}

# Decrypting is not the same as being worth anything. This is precisely the
# assertion the weekly fingerprint check cannot make, because it never opens
# the file.
@test "something that decrypts but is not an age identity fails" {
	cat >"$BIN/age-keygen" <<'STUB'
#!/bin/sh
exit 1
STUB
	chmod 755 "$BIN/age-keygen"
	run_restore -- "$BACKUP"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not a usable age identity"* ]]
}

@test "a backup that decrypts to nothing is caught" {
	run_restore AGE_DECRYPT_EMPTY=1 -- "$BACKUP"
	[ "$status" -ne 0 ]
	[[ "$output" == *"could not decrypt"* ]]
}

@test "a key matching the local record says so" {
	run_restore -- "$BACKUP"
	[ "$status" -eq 0 ]
	[[ "$output" == *"matches the copy recorded on 2026-07-01"* ]]
}

# Reported, not fatal: an older backup of a key that has since rotated looks
# exactly like this, and on the day you need it that copy may be the one you
# want.
@test "a key that is not the recorded one warns without failing" {
	printf 'date=2026-07-01T00:00:00Z\nage_public_key=age1somethingelse\n' >"$MANIFEST"
	run_restore -- "$BACKUP"
	[ "$status" -eq 0 ]
	[[ "$output" == *"NOT the key the local record names"* ]]
	[[ "$output" == *"may still be the copy you want"* ]]
}

@test "no local record at all is a warning, not a failure" {
	rm -f "$MANIFEST"
	run_restore -- "$BACKUP"
	[ "$status" -eq 0 ]
	[[ "$output" == *"no local record"* ]]
}

# --- writing -----------------------------------------------------------------

@test "--write puts the key back, owner-only" {
	run_restore -- --write "$BACKUP"
	[ "$status" -eq 0 ]
	[ "$(cat "$KEY_TARGET")" = "AGE-SECRET-KEY-SENTINEL-RESTORED" ]
	[ "$(stat -c %a "$KEY_TARGET")" = "600" ]
}

@test "the directory it creates is owner-only too" {
	run_restore -- --write "$BACKUP"
	[ "$status" -eq 0 ]
	[ "$(stat -c %a "$(dirname "$KEY_TARGET")")" = "700" ]
}

# The key file being restored *into* may be the only copy of a different key.
# Overwriting it silently would be destroying a secret to recover a secret.
@test "--write refuses to replace an existing key file" {
	mkdir -p "$(dirname "$KEY_TARGET")"
	printf 'AGE-SECRET-KEY-ALREADY-HERE\n' >"$KEY_TARGET"
	run_restore -- --write "$BACKUP"
	[ "$status" -ne 0 ]
	[[ "$output" == *"already exists"* ]]
	[ "$(cat "$KEY_TARGET")" = "AGE-SECRET-KEY-ALREADY-HERE" ]
}

@test "--force replaces it" {
	mkdir -p "$(dirname "$KEY_TARGET")"
	printf 'AGE-SECRET-KEY-ALREADY-HERE\n' >"$KEY_TARGET"
	run_restore -- --write --force "$BACKUP"
	[ "$status" -eq 0 ]
	[ "$(cat "$KEY_TARGET")" = "AGE-SECRET-KEY-SENTINEL-RESTORED" ]
}

@test "a failed decrypt in --write mode leaves the existing key alone" {
	mkdir -p "$(dirname "$KEY_TARGET")"
	printf 'AGE-SECRET-KEY-ALREADY-HERE\n' >"$KEY_TARGET"
	run_restore AGE_DECRYPT_RC=1 -- --write --force "$BACKUP"
	[ "$status" -ne 0 ]
	[ "$(cat "$KEY_TARGET")" = "AGE-SECRET-KEY-ALREADY-HERE" ]
}

@test "--write leaves no temp file behind" {
	run_restore -- --write "$BACKUP"
	[ "$status" -eq 0 ]
	[ -z "$(find "$(dirname "$KEY_TARGET")" -name '*.tmp.*' -print -quit)" ]
}

# Verify is the default because restoring is the emergency, and the emergency
# is not when you want to find out the passphrase was mistyped.
@test "the default mode writes nothing" {
	run_restore -- "$BACKUP"
	[ "$status" -eq 0 ]
	[ ! -e "$KEY_TARGET" ]
}
