#!/bin/sh
# ~/.ssh/config is deliberately NOT managed by chezmoi: DevPod appends a
# `# DevPod Start <workspace>` … `# DevPod End` block to it per workspace, and
# a chezmoi-owned config would delete every one of them on each apply (that
# was the original bug). Instead chezmoi owns a fragment at
# ~/.ssh/config.d/10-dotfiles.conf (see private_dot_ssh/private_config.d) and
# this script only asserts that ~/.ssh/config includes it.
#
# Deliberately a plain `run_after`, not `run_onchange`: this is re-asserting
# an invariant about a file chezmoi does not manage and cannot diff, so it has
# to re-check on every apply. A run_onchange script is recorded as done as
# soon as it exits 0 — if something later removed the Include line (a human
# edit, a tool that rewrites the file wholesale), a run_onchange would never
# notice again. Running every apply and no-opping in the common case costs one
# grep. Same reasoning as the host-packages and secrets-unlock scripts being
# plain run_before/run_after.
set -eu

# `set -u` only catches an *unset* HOME (e.g. `env -u HOME`), not `HOME=""` —
# an empty-but-set HOME sails through and turns every path below into a
# filesystem-root path (`/.ssh/config`). A container provisioning step
# running as root with a not-yet-populated HOME is exactly the kind of
# DevPod-style bootstrap this fix exists to accommodate, so this has to fail
# loudly rather than quietly writing outside anyone's home.
if [ -z "${HOME:-}" ]; then
	echo "[ssh-include] \$HOME is empty; refusing to guess where ~/.ssh/config lives." >&2
	exit 1
fi

ssh_dir="$HOME/.ssh"
config="$ssh_dir/config"
include_line="Include config.d/*.conf"

# A symlinked ~/.ssh/config isn't a setup this repo has, but the choice needs
# to be deliberate rather than accidental: refuse rather than silently
# replacing the link with a regular file (which is what the `mv` further down
# would otherwise do — content and mode would survive, the link wouldn't).
if [ -L "$config" ]; then
	echo "[ssh-include] $config is a symlink; refusing to rewrite it in place." >&2
	exit 1
fi

# Same "fail loud, don't silently no-op" reasoning for anything else that
# isn't a plain file (a directory, a socket, ...): moving a temp file onto a
# directory target would move it *into* that directory instead, leaving temp
# debris behind while looking like a clean, successful no-op.
if [ -e "$config" ] && [ ! -f "$config" ]; then
	echo "[ssh-include] $config exists but is not a regular file; refusing to touch it." >&2
	exit 1
fi

if [ ! -e "$config" ]; then
	# No ~/.ssh/config at all yet: create both it and ~/.ssh with the modes
	# OpenSSH insists on (it silently ignores a config it considers group/
	# world-readable, and refuses to use the directory at all otherwise).
	mkdir -p "$ssh_dir"
	chmod 700 "$ssh_dir"
	echo "$include_line" >"$config"
	chmod 600 "$config"
	exit 0
fi

if grep -qxF "$include_line" "$config"; then
	# Common path, runs on every apply: already in place, nothing to do and
	# nothing to say.
	exit 0
fi

# From here the file needs rewriting: the Include is missing, so it has to be
# prepended (OpenSSH takes the first value it sees for any keyword, so this
# has to end up above DevPod's blocks). Preserve the mode before touching
# anything.
mode="$(stat -c %a "$config" 2>/dev/null || stat -f %Lp "$config")"

# Temp files live alongside the real config, not in /tmp, so the final `mv`
# is a same-filesystem rename: atomic, and an interrupted run leaves either
# the untouched original or the complete replacement, never a truncated file.
migrated="$(mktemp "$ssh_dir/config.tmp.XXXXXX")"
# Registered right after the first mktemp, with $final pre-declared empty:
# if the second mktemp below fails, the trap still fires with both variables
# bound (rm -f on an empty string is a harmless no-op) instead of leaking
# $migrated while the trap itself dies on an unset variable under `set -u`.
final=""
trap 'rm -f "$migrated" "$final"' EXIT
final="$(mktemp "$ssh_dir/config.tmp.XXXXXX")"

# One-time migration: drop the old managed three-line AddKeysToAgent block if
# it's still there verbatim — the fragment now provides that setting, and
# leaving both would mean a duplicate `AddKeysToAgent`. Matched as one exact
# contiguous block (never a bare `grep -v AddKeysToAgent`), so a lone
# `AddKeysToAgent no` a user wrote themselves, with a different value, is
# never touched. A no-op when the block isn't present, which lets this run
# unconditionally as part of the same rewrite.
awk '
	BEGIN {
		l1 = "# First ssh use loads the key into the agent, so no manual ssh-add"
		l2 = "# after login/reboot"
		l3 = "AddKeysToAgent yes"
	}
	{ line[NR] = $0 }
	END {
		for (i = 1; i <= NR; i++) {
			if (i + 2 <= NR && line[i] == l1 && line[i + 1] == l2 && line[i + 2] == l3) {
				drop[i] = 1; drop[i + 1] = 1; drop[i + 2] = 1
			}
		}
		for (i = 1; i <= NR; i++) if (!(i in drop)) print line[i]
	}
' "$config" >"$migrated"

{
	echo "$include_line"
	cat "$migrated"
} >"$final"

chmod "$mode" "$final"
mv "$final" "$config"
