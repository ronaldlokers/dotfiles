#!/usr/bin/env bats
#
# executable_devpod wraps the pinned DevPod binary and, for `up`, looks up an
# optional per-project GitHub token in ~/.config/devpod/project-tokens. That
# file is authored in the Proton Pass web UI now, where a stray leading space
# is invisible — and a missed match is silent, because the container comes up
# fine and only `gh` fails inside it. These pin the parse.
#
# The seam is the wrapper's exec of ~/.local/libexec/devpod: a stub there
# records argv and the contents of any --workspace-env-file before the wrapper
# deletes it.

bats_require_minimum_version 1.5.0

setup() {
	WRAPPER="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_devpod"

	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.local/libexec" "$HOME/.config/devpod"

	# The wrapper writes its workspace env file here. Point it at the test's
	# own directory so nothing lands in the real runtime dir.
	XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
	mkdir -p "$XDG_RUNTIME_DIR"

	# Isolate from this machine's global/system git config. `git remote
	# get-url --push` expands insteadOf/pushInsteadOf rewrites from it, and a
	# rewrite touching the owner/repo portion would change the derived key —
	# breaking every positive test here for a reason nowhere near the test.
	GIT_CONFIG_GLOBAL=/dev/null
	GIT_CONFIG_SYSTEM=/dev/null

	STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$STUB_LOG"

	cat >"$HOME/.local/libexec/devpod" <<'STUB'
#!/bin/sh
printf 'ARGV: %s\n' "$*" >>"$STUB_LOG"
# Copy out the workspace env file, and record its mode, while it still
# exists; the wrapper removes it as soon as this returns.
prev=""
for a in "$@"; do
	if [ "$prev" = "--workspace-env-file" ]; then
		sed 's/^/ENVFILE: /' "$a" >>"$STUB_LOG"
		printf 'MODE: %s\n' "$(stat -c %a "$a")" >>"$STUB_LOG"
	fi
	prev="$a"
done
exit 0
STUB
	chmod 755 "$HOME/.local/libexec/devpod"

	# project_token() keys on the push remote, not the directory name.
	PROJ="$BATS_TEST_TMPDIR/proj"
	mkdir -p "$PROJ"
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$PROJ" init -q
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
		git -C "$PROJ" remote add origin git@github.com:ronaldlokers/homelab.git

	TOKENS="$HOME/.config/devpod/project-tokens"
	export HOME STUB_LOG XDG_RUNTIME_DIR GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
}

# Writes $1 as the project-tokens file, interpreting backslash escapes so the
# cases can write `\n` rather than embedding real newlines in the source.
write_tokens() {
	printf '%b' "$1" >"$TOKENS"
	chmod 600 "$TOKENS"
}

run_up() {
	# Same isolation as setup(): the wrapper itself shells out to `git remote
	# get-url --push`.
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" \
		XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
		GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" GIT_CONFIG_SYSTEM="$GIT_CONFIG_SYSTEM" \
		sh "$WRAPPER" up "$PROJ"
}

# Asserts the wrapper handed DevPod a workspace env file carrying exactly $1.
assert_token() {
	[ "$status" -eq 0 ]
	grep -qx -- "ENVFILE: GH_TOKEN=$1" "$STUB_LOG"
}

assert_no_token() {
	[ "$status" -eq 0 ]
	! grep -q -- '--workspace-env-file' "$STUB_LOG"
}

@test "a clean entry is passed as GH_TOKEN" {
	write_tokens 'ronaldlokers/homelab=tok-clean\n'
	run_up
	assert_token tok-clean
}

# The fault that prompted this: a note edited in a browser picked up a leading
# space, and `$1 == k` silently stopped matching.
@test "a leading space on the line still matches" {
	write_tokens '   ronaldlokers/homelab=tok-lead\n'
	run_up
	assert_token tok-lead
}

@test "a trailing space after the value is stripped" {
	# Built from a variable on purpose: literal trailing spaces in a source
	# file are invisible, and most editors strip them on save — which would
	# make this test pass without ever testing anything.
	pad="   "
	write_tokens "ronaldlokers/homelab=tok-trail${pad}\n"
	run_up
	assert_token tok-trail
}

@test "spaces either side of the equals still match" {
	write_tokens 'ronaldlokers/homelab = tok-spaced\n'
	run_up
	assert_token tok-spaced
}

# Regression guard, not a driver: the current `-F=` implementation already gets
# this right, and the rewrite must not lose it. Splitting on the first `=` only.
@test "a value containing an equals sign comes back intact" {
	write_tokens 'ronaldlokers/homelab=tok=with=equals\n'
	run_up
	assert_token 'tok=with=equals'
}

@test "an entry with an empty value passes no token" {
	write_tokens 'ronaldlokers/homelab=\n'
	run_up
	assert_no_token
}

@test "a non-matching repo passes no token" {
	write_tokens 'someone/other=tok-other\n'
	run_up
	assert_no_token
}

# A prefix match would hand the private repo's PAT to the public repo's
# container: ronaldlokers/homelab is a prefix of ronaldlokers/homelab-private,
# and this fixture's project is the shorter of the two.
@test "a key that is a prefix-superset of the repo passes no token" {
	write_tokens 'ronaldlokers/homelab-private=tok-other\n'
	run_up
	assert_no_token
}

@test "an absent project-tokens file passes no token" {
	rm -f "$TOKENS"
	run_up
	assert_no_token
}

@test "the workspace env file is written mode 0600" {
	write_tokens 'ronaldlokers/homelab=tok-clean\n'
	run_up
	assert_token tok-clean
	grep -qx -- "MODE: 600" "$STUB_LOG"
}

@test "no workspace env file is left behind in XDG_RUNTIME_DIR" {
	write_tokens 'ronaldlokers/homelab=tok-clean\n'
	run_up
	assert_token tok-clean
	[ -z "$(find "$XDG_RUNTIME_DIR" -name 'devpod-workspace-env.*' -print -quit)" ]
}
