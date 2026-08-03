#!/bin/sh
# The facts this repo states in more than one place, and the assertion that they
# still agree.
#
# Every check here answers the same question: two files say the same thing, and
# hoisting one into the other would be worse than the duplication. A shared
# vault definition would give four scripts a runtime dependency on a fifth, and
# these are the scripts that have to work when other things do not. A date
# hoisted out of the README is a date nobody reads. So they are duplicated on
# purpose, and this is what stops the duplication rotting.
#
# It lives in a file rather than inline in mise.toml for one reason: it can be
# tested. Four multi-line shell one-liners embedded in TOML strings could not
# be, and one of them was wrong — the container-marker check had no guard
# against its own scan returning nothing, so a renamed directory would have made
# it pass by finding zero files to disagree.
#
# Repo-only. Not under home/, never applied.
#
# usage: scripts/check-agreement.sh [root] [check ...]
#
# root defaults to the current directory; naming checks runs only those, which
# is what tests/check-agreement.bats does. Every check reports its own failure
# and the script exits 1 if any failed, so one run tells you everything that
# has drifted rather than only the first thing.
set -eu

root="${1:-.}"
[ $# -eq 0 ] || shift

usage() {
	cat <<'USAGE'
usage: scripts/check-agreement.sh [root] [check ...]

Asserts the facts this repo states in more than one place still agree.

Checks: chezmoi-pins, vault-name, container-markers, pat-expiry, graphify-pin,
        pat-path
With no check named, runs all of them.
USAGE
}

case "$root" in
-h | --help)
	usage
	exit 0
	;;
esac

if [ ! -d "$root" ]; then
	echo "check-agreement: no such directory: $root" >&2
	exit 2
fi

rc=0
fail() {
	echo "FAIL  $1" >&2
	rc=1
}

# --- the three chezmoi versions ---------------------------------------------
# The .chezmoiversion floor, the pin every machine installs, and this repo's own
# pin (the tests render a script template, so they need the binary). Renovate
# bumps the pins; this is what says "bump the floor too".
check_chezmoi_pins() {
	v="$(cat "$root/.chezmoiversion" 2>/dev/null || true)"
	p="$(sed -n 's/^chezmoi = "\(.*\)"$/\1/p' "$root/home/dot_config/mise/config.toml" 2>/dev/null || true)"
	r="$(sed -n 's/^chezmoi = "\(.*\)"$/\1/p' "$root/mise.toml" 2>/dev/null || true)"
	if [ -z "$v" ] || [ -z "$p" ] || [ -z "$r" ]; then
		fail "could not read all three chezmoi versions (floor '$v', machine '$p', repo '$r')"
		return
	fi
	if [ "$v" != "$p" ] || [ "$v" != "$r" ]; then
		fail ".chezmoiversion ($v), the machine pin ($p) and this repo's pin ($r) disagree"
	fi
}

# --- the vault name ----------------------------------------------------------
# Written in five places: `vault="Dotfiles"` in four scripts, and the
# `pass://Dotfiles/...` URI in signing-pubkey. A rename that misses one fails
# here rather than at 3am on a rebuild.
#
# The URI pattern is deliberately narrower than the one dotfiles-secrets-check
# derives items with: this scan reads the source tree, where
# `pass://<vault>/<title>/<field>` appears in prose and `pass://[^/"[:space:]]+/`
# appears as that script's own regex literal. Both match a permissive pattern
# and neither is a vault name.
check_vault_name() {
	names="$( {
		grep -rhoE '^vault="[^"]+"' "$root/home/.chezmoiscripts" "$root/home/dot_local/bin" 2>/dev/null |
			sed 's/^vault="//; s/"$//'
		grep -rhoE 'pass://[A-Za-z0-9._-]+/' "$root/home" 2>/dev/null |
			sed 's|^pass://||; s|/$||'
	} | sort -u)"
	n="$(printf '%s\n' "$names" | grep -c . || true)"
	if [ "$n" -eq 0 ]; then
		fail "found no vault references at all — the scan broke, not the tree"
	elif [ "$n" -ne 1 ]; then
		fail "the vault name disagrees across the tree: $(printf '%s' "$names" | tr '\n' ' ')"
	fi
}

# --- the two container markers ----------------------------------------------
# The container predicate exists twice on purpose and must not be collapsed:
# .chezmoitemplates/is-container answers it at *apply* time for the template
# gates, while proton-ssh-load and dotfiles-secrets-check re-ask it at *run*
# time, because a script's source-tree copy is reachable from a devcontainer
# working on this repo. Two questions, two answers.
#
# What can drift is the marker list — adding a third runtime to the template and
# forgetting the scripts — so the assertion is that anything probing for one
# marker probes for both.
#
# The floor is the part that was missing. With no minimum, a moved directory or
# a changed spelling makes the scan match nothing and the loop pass by having
# nothing to check: the assertion reports success for the one reason that should
# alarm it. Three files probe today; fewer than that means the scan is broken,
# not that the tree got tidier.
check_container_markers() {
	files="$(grep -rl 'dockerenv\|containerenv' "$root/home" 2>/dev/null || true)"
	n="$(printf '%s\n' "$files" | grep -c . || true)"
	if [ "$n" -lt 3 ]; then
		fail "only $n file(s) probe for a container marker; expected at least 3 — the scan broke, not the tree"
		return
	fi
	for f in $files; do
		if ! grep -q '/\.dockerenv' "$f" || ! grep -q '/run/\.containerenv' "$f"; then
			fail "$f probes for only one container marker; is-container tests both"
		fi
	done
}

# --- the bootstrap PAT's expiry ---------------------------------------------
# Written twice: the constant dotfiles-secrets-check warns from, and the README
# gotcha a human reads. A date that has drifted out of the README is a date
# nobody trusts; a date that has drifted out of the check is a warning that
# never fires.
check_pat_expiry() {
	c="$(sed -n 's/^bootstrap_pat_expiry="\(.*\)"$/\1/p' \
		"$root/home/dot_local/bin/executable_dotfiles-secrets-check" 2>/dev/null || true)"
	r="$(grep -oE 'bootstrap token expires\*\* [0-9]{4}-[0-9]{2}-[0-9]{2}' "$root/README.md" 2>/dev/null |
		grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"
	if [ -z "$c" ] || [ -z "$r" ]; then
		fail "could not find the bootstrap PAT expiry in the check ($c) or the README ($r)"
	elif [ "$c" != "$r" ]; then
		fail "bootstrap PAT expiry disagrees: check says $c, README says $r"
	fi
}

# --- the graphify skill and the tool that ships it ---------------------------
# The `/graphify` skill is vendored into dot_claude/skills rather than left to
# `graphify install`, which writes straight into $HOME over chezmoi. Vendoring
# means the copy in this tree has a version of its own, and nothing connected it
# to the pin — so a Renovate bump moved the tool while the skill describing it
# stayed where it was, silently, which is exactly what had happened.
#
# Renovate no longer automerges this package for the same reason: the bump is
# only half the change. The other half is re-vendoring, by hand, into a scratch
# HOME.
check_graphify_pin() {
	s="$(cat "$root/home/dot_claude/skills/graphify/dot_graphify_version" 2>/dev/null || true)"
	p="$(sed -n 's/^"pipx:graphifyy" = "\(.*\)"$/\1/p' \
		"$root/home/dot_config/mise/config.toml" 2>/dev/null || true)"
	if [ -z "$s" ] || [ -z "$p" ]; then
		fail "could not read the graphify versions (vendored skill '$s', mise pin '$p')"
	elif [ "$s" != "$p" ]; then
		fail "the vendored graphify skill ($s) is not the pinned version ($p); re-vendor it or revert the pin"
	fi
}

# --- the cached bootstrap PAT's path ----------------------------------------
# proton-ssh-load writes it; dotfiles-secrets-check now reads it to establish a
# session before calling its absence a fault. Two scripts, one path, and a
# rename that missed one would put the check straight back to false-alarming
# every week — which is the bug that made it read this file at all.
check_pat_path() {
	paths="$(grep -rhoE 'pat_file="[^"]+"' \
		"$root/home/dot_local/bin" 2>/dev/null | sort -u)"
	n="$(printf '%s\n' "$paths" | grep -c . || true)"
	if [ "$n" -eq 0 ]; then
		fail "found no bootstrap-PAT path at all — the scan broke, not the tree"
	elif [ "$n" -ne 1 ]; then
		fail "the cached bootstrap PAT path disagrees: $(printf '%s' "$paths" | tr '\n' ' ')"
	fi
}

if [ $# -eq 0 ]; then
	set -- chezmoi-pins vault-name container-markers pat-expiry graphify-pin pat-path
fi

for want in "$@"; do
	case "$want" in
	chezmoi-pins) check_chezmoi_pins ;;
	vault-name) check_vault_name ;;
	container-markers) check_container_markers ;;
	pat-expiry) check_pat_expiry ;;
	graphify-pin) check_graphify_pin ;;
	pat-path) check_pat_path ;;
	*)
		echo "check-agreement: unknown check: $want" >&2
		usage >&2
		exit 2
		;;
	esac
done

exit "$rc"
