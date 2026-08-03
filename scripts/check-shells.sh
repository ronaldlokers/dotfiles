#!/bin/sh
# Start each interactive shell and fail on startup noise or a non-zero exit.
#
# Neither rc file is in the shellcheck list — they are sourced, not executed,
# and full of shell-specific syntax — and a clean-HOME bootstrap never starts a
# shell. So a typo in an init line ships silently and shows up the next time a
# terminal is opened. `-i` is the point: the tool integrations this guards all
# live in the interactive path.
#
# It reads the *applied* files in $HOME, not the source tree, so an apply has to
# have happened first. Both `mise run shells` and CI's bootstrap job call this,
# which is why it is a file rather than an inline task: CI used to run its own
# weaker version — `zsh -ic 'echo ...'`, which asserts an exit code and nothing
# about output, and never started bash at all.
#
# Repo-only. Not under home/, never applied.
set -eu

usage() {
	cat <<'USAGE'
usage: scripts/check-shells.sh

Starts zsh and bash interactively against the applied $HOME and fails if either
exits non-zero or prints anything. Takes no options.
USAGE
}

case "${1:-}" in
-h | --help)
	usage
	exit 0
	;;
"") ;;
*)
	echo "check-shells: unknown argument: $1" >&2
	usage >&2
	exit 2
	;;
esac

rc=0

# Giving the checked shell a real pty (below, via `script`) has a side effect
# beyond the tty noise it is there to fix: mise's own shell hooks (`eval "$(mise
# activate ...)"` in both rc files) detect that stdout is now a terminal and emit
# an OSC 9;4 progress escape on startup. That is mise reacting to the pty this
# script handed it, not an rc-file regression, so it is silenced the same way as
# the tty noise below — by not producing it in the first place.
export MISE_TERMINAL_PROGRESS=false

# Run from $HOME, and this is the whole reason the check could not go in CI.
#
# mise merges a config from every ancestor of the working directory, so a shell
# started inside this checkout finds the repo's own mise.toml — and if that file
# is not in mise's trust store, `mise activate` draws an interactive "Trust
# them? Yes / No / All" widget and blocks forever waiting for a keypress. On a
# pty there is nobody to press one. That is the ten-minute hang this check was
# excluded from CI over, misread at the time as mise resolving the tool list on
# first start; it is not slow, it is waiting. It survives locally only because
# this developer's trust store already has an entry for the repo.
#
# $HOME is also simply the right subject: a terminal opens there, not inside a
# checkout whose mise.toml describes the tooling for working *on* this repo
# rather than the tooling the rc files activate.
cd "$HOME" || {
	echo "check-shells: cannot enter \$HOME ($HOME)" >&2
	exit 1
}

for shell in zsh bash; do
	if ! command -v "$shell" >/dev/null 2>&1; then
		echo "skip  $shell (not installed)"
		continue
	fi
	# Both streams captured: a failing init line prints to stderr, a noisy but
	# successful one to stdout. Either is a finding.
	if command -v script >/dev/null 2>&1; then
		out="$(script -qec "$shell -ic true" /dev/null 2>&1 </dev/null)" && status=0 || status=$?
	else
		out="$("$shell" -ic true 2>&1 </dev/null)" && status=0 || status=$?
	fi
	if [ "$status" -eq 0 ]; then
		if [ -n "$out" ]; then
			echo "FAIL  $shell started but printed output:" >&2
			printf '%s\n' "$out" >&2
			rc=1
		else
			echo "ok    $shell"
		fi
	else
		echo "FAIL  $shell exited non-zero:" >&2
		printf '%s\n' "$out" >&2
		rc=1
	fi
done

exit "$rc"
