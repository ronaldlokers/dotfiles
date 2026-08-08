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

# One list, read by the usage text, the argument handling and the default run
# below. It was three, and they had already drifted: the usage text listed six
# checks while the dispatch knew seven.
all_checks="chezmoi-pins vault-name container-markers pat-expiry graphify-pin
pat-path shellcheck-targets"

is_check() {
	for _ic in $all_checks; do
		# `[ … ] && return 0` would be shorter and would exit the script under
		# `set -e` the first time this is called outside a condition.
		if [ "$_ic" = "$1" ]; then
			return 0
		fi
	done
	return 1
}

usage() {
	cat <<USAGE
usage: scripts/check-agreement.sh [root] [check ...]

Asserts the facts this repo states in more than one place still agree.

Checks: $(printf '%s' "$all_checks" | tr '\n' ' ')
With no check named, runs all of them.
USAGE
}

# The first argument is the root only when it is not the name of a check. It was
# taken as the root unconditionally, so the invocation this script's own header
# documents — `check-agreement.sh vault-name`, root defaulting to `.` — died
# with "no such directory: vault-name". Nothing caught it because every caller
# in the tree passes a root first; the broken form was the one a person types.
#
# A directory that happens to share a check's name is still reachable, by naming
# it the way every caller already does: `check-agreement.sh ./vault-name`.
root="."
if [ $# -gt 0 ] && ! is_check "$1"; then
	root="$1"
	shift
fi

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

# --- every shell script is shellchecked --------------------------------------
# The lint task names its targets by hand. That is the right call — a glob wide
# enough to catch `setup` and `tests/helpers.bash` also drags in vendored trees
# — but a hand-kept list is a list that goes stale silently: a script added
# later is simply absent from it, and nothing fails. scripts/check-shells.sh sat
# outside it for its whole life, with a bats file of its own the entire time.
#
# So the list stays hand-kept and this asserts it is complete. A target covers a
# script literally or as a glob, which is how `home/.chezmoiscripts/*.sh.tmpl`
# earns its place.
#
# Discovery prefers `git ls-files`, so an untracked graphify-out/ or a stray
# scratch script cannot fail the repo's own lint; the find fallback is for a
# fixture tree, which is not a checkout.
check_shellcheck_targets() {
	targets="$(sed -n 's/^[[:space:]]*"shellcheck \(.*\)",$/\1/p' \
		"$root/mise.toml" 2>/dev/null | head -1)"
	if [ -z "$targets" ]; then
		fail "mise.toml has no shellcheck invocation to read the target list from"
		return
	fi

	files="$(git -C "$root" ls-files 2>/dev/null ||
		find "$root" -name .git -prune -o -type f -print 2>/dev/null |
		sed "s|^$root/||")"

	scripts=""
	old_ifs="$IFS"
	IFS='
'
	set -f
	for f in $files; do
		case "$f" in
		*.sh | *.bash | *.sh.tmpl) ;;
		*)
			# A shell script is not always named like one: `setup` has no
			# extension and every executable_* in dot_local/bin is a script
			# whose name is the command it becomes.
			head -n 1 "$root/$f" 2>/dev/null |
				grep -qE '^#!.*[ /](ba|da|z|k)?sh$|^#!.*[ /](ba|da|z|k)?sh ' || continue
			;;
		esac
		scripts="$scripts$f
"
	done

	n=0
	missing=""
	for s in $scripts; do
		n=$((n + 1))
		covered=0
		IFS=' '
		for t in $targets; do
			case "$t" in
			-*) continue ;;
			esac
			# Unquoted on purpose: a target is a glob as often as a path.
			# shellcheck disable=SC2254
			case "$s" in
			$t)
				covered=1
				break
				;;
			esac
		done
		IFS='
'
		[ "$covered" = 1 ] || missing="${missing:+$missing }$s"
	done
	set +f
	IFS="$old_ifs"

	# The same floor every other scan here carries: a moved directory must not
	# pass by finding nothing left to disagree with.
	if [ "$n" -lt 3 ]; then
		fail "only $n shell script(s) found in the tree; expected at least 3 — the scan broke, not the tree"
		return
	fi
	if [ -n "$missing" ]; then
		fail "shell script(s) the lint task never shellchecks: $missing"
	fi
}

if [ $# -eq 0 ]; then
	# Unquoted on purpose: the list is whitespace-separated and has no globs.
	# shellcheck disable=SC2086
	set -- $all_checks
fi

for want in "$@"; do
	case "$want" in
	chezmoi-pins) check_chezmoi_pins ;;
	vault-name) check_vault_name ;;
	container-markers) check_container_markers ;;
	pat-expiry) check_pat_expiry ;;
	graphify-pin) check_graphify_pin ;;
	pat-path) check_pat_path ;;
	shellcheck-targets) check_shellcheck_targets ;;
	*)
		echo "check-agreement: unknown check: $want" >&2
		usage >&2
		exit 2
		;;
	esac
done

exit "$rc"
