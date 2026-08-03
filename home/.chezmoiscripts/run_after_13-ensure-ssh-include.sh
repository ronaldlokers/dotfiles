#!/bin/sh
# ~/.ssh/config is co-owned with DevPod, so chezmoi does not manage it. chezmoi
# owns ~/.ssh/config.d/10-dotfiles.conf instead; this script only asserts the
# Include line is present.
#
# A plain run_after, not run_onchange: it re-asserts an invariant about a file
# chezmoi cannot diff, so it has to check every apply.
#
# 13 and not 12: chezmoi strips the run_/onchange_/after_ attributes and orders
# what is left, so every script here shares one numbering regardless of prefix.
# This was 12 while run_onchange_after_12-enable-secrets-check also existed, and
# which of the two ran first came down to alphabetics after the number rather
# than to anyone's intent. See docs/design-notes.md, "One numbering, not two".
set -eu

# `set -u` catches an unset HOME but not HOME="", which would turn every path
# below into /.ssh/config. Fail loudly instead.
if [ -z "${HOME:-}" ]; then
	echo "[ssh-include] \$HOME is empty; refusing to guess where ~/.ssh/config lives." >&2
	exit 1
fi

ssh_dir="$HOME/.ssh"
config="$ssh_dir/config"
include_line="Include config.d/*.conf"

# Refusing to touch the file is right. Exiting non-zero to say so was not.
#
# This is a run_after script, so chezmoi treats a non-zero exit as a failed
# apply and stops: everything numbered after this one — restoring the file
# secrets (14), installing the host packages (20), configuring DevPod (30) —
# never runs. So the two conditions below, both of which mean "someone else
# owns this file and I am deliberately staying out of it", took the whole
# machine down with them. The file this script does not manage is not more
# important than the ones the rest of the apply does.
#
# Report loudly and hand back 0. The Include line is the one thing that does
# not get asserted; the fix is one edit by hand, and it is named here.
refuse() {
	echo "[ssh-include] $1" >&2
	echo "[ssh-include] Add this line above any Host/Match block, by hand:" >&2
	echo "[ssh-include]   $include_line" >&2
	echo "[ssh-include] Continuing — the rest of the apply is unaffected." >&2
	exit 0
}

# A symlinked config: the `mv` below would silently replace the link with a
# regular file.
if [ -L "$config" ]; then
	refuse "$config is a symlink; not rewriting it in place."
fi

# Anything else non-regular: `mv` onto a directory would move the temp file
# into it and look like success.
if [ -e "$config" ] && [ ! -f "$config" ]; then
	refuse "$config exists but is not a regular file; not touching it."
fi

if [ ! -e "$config" ]; then
	# Modes matter: OpenSSH ignores a group/world-readable config.
	mkdir -p "$ssh_dir"
	chmod 700 "$ssh_dir"
	echo "$include_line" >"$config"
	chmod 600 "$config"
	exit 0
fi

# Position is the invariant, not presence: OpenSSH scopes anything below a
# Host/Match line to that block, so an Include underneath one applies only
# there. Compare first-Include against first-Host line numbers. Do not
# "simplify" this to a presence check.
position_ok="$(awk -v inc="$include_line" '
	BEGIN { inc_line = 0; host_line = 0 }
	{
		if (inc_line == 0 && $0 == inc) inc_line = NR
		line = $0
		sub(/^[ \t]+/, "", line)
		if (host_line == 0 && line !~ /^#/ && line ~ /^([Hh][Oo][Ss][Tt]|[Mm][Aa][Tt][Cc][Hh])[ \t]/) host_line = NR
	}
	END {
		if (inc_line > 0 && (host_line == 0 || inc_line < host_line)) print "ok"
		else print "no"
	}
' "$config")"

if [ "$position_ok" = "ok" ]; then
	# Common path: correctly placed already.
	exit 0
fi

# Rewrite: prepend a correct Include above any Host/Match block. A misplaced
# duplicate further down is left alone — OpenSSH is first-value-wins, so it is
# inert, and editing around arbitrary content risks corrupting the file.
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
