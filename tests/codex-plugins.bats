#!/usr/bin/env bats
#
# run_after_25-install-codex-plugins.sh.tmpl installs this repo's Codex plugins
# by driving the Codex CLI.
#
# ~/.codex/config.toml is not managed and cannot be: Codex writes it itself --
# per-project trust levels, and a trusted_hash per hook that changes whenever a
# hook does -- so a managed copy would be permanent drift. The CLI is the
# interface, the same arrangement run_onchange_after_30-configure-devpod has
# with DevPod.
#
# The assertions are against a transcript of the `codex` calls, because that is
# all this script does. Two failures matter and neither shows in an exit code:
# adding the marketplace without its pin (the pin is the only supply-chain
# control on a plugin that injects instructions into every session), and
# re-adding on every apply because the "is it already there?" test reads the
# CLI's output wrong.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	TMPL="$BATS_TEST_DIRNAME/../home/.chezmoiscripts/run_after_25-install-codex-plugins.sh.tmpl"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"
	CODEX_LOG="$BATS_TEST_TMPDIR/codex.log"
	: >"$CODEX_LOG"

	SCRIPT="$BATS_TEST_TMPDIR/codex-plugins.sh"
	render_template "$TMPL" "$SCRIPT" "$PATH"
	export HOME CODEX_LOG
}

# A fake codex recording every call, with output shaped like the real CLI's --
# verified against codex-cli 0.150.1.
#
#   HAS_MARKETPLACE  when set, `marketplace list` already lists ponytail
#   PLUGIN_STATUS    ponytail's STATUS in `plugin list`. The real values,
#                    confirmed by running codex-cli 0.150.1, are
#                    "installed, enabled" and "not installed" -- both two
#                    words, one with a comma. Unset means absent from the list.
#   ADD_MP_RC        exit code for `marketplace add`   (default 0)
#   ADD_RC           exit code for `plugin add`        (default 0)
make_codex_stub() {
	cat >"$BIN/codex" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$CODEX_LOG"
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "marketplace" ]; then
	case "${3:-}" in
	list)
		printf 'MARKETPLACE     ROOT\n'
		printf 'openai-curated  /tmp/plugins\n'
		[ -n "${HAS_MARKETPLACE:-}" ] && printf 'ponytail        /tmp/ponytail\n'
		exit 0
		;;
	add) exit "${ADD_MP_RC:-0}" ;;
	esac
fi
if [ "${1:-}" = "plugin" ]; then
	case "${2:-}" in
	list)
		printf 'PLUGIN                     STATUS         VERSION  PATH\n'
		printf 'linear@openai-curated      not installed           /tmp/linear\n'
		if [ -n "${PLUGIN_STATUS:-}" ]; then
			printf 'ponytail@ponytail          %s           1.0  /tmp/ponytail\n' "$PLUGIN_STATUS"
		fi
		exit 0
		;;
	add) exit "${ADD_RC:-0}" ;;
	esac
fi
exit 0
STUB
	chmod 755 "$BIN/codex"
	# A written stub, not a symlink to the real node. The script only ever
	# runs `command -v node`, so nothing here needs a working interpreter --
	# and `chmod` on a symlink changes its *referent*, which on CI is a
	# root-owned mise install and fails with "Operation not permitted". It
	# passed locally only because this machine's mise tree is user-owned.
	printf '#!/bin/sh\nexit 0\n' >"$BIN/node"
	chmod 755 "$BIN/node"
	ln -sf "$(command -v awk)" "$BIN/awk"
	ln -sf "$(command -v grep)" "$BIN/grep"
	# sh too, so a test can strip PATH down to this directory to make one
	# tool absent without also removing the interpreter running the script.
	ln -sf "$(command -v sh)" "$BIN/sh"
}

run_install() {
	run env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_DATA_HOME \
		PATH="$BIN:/usr/bin:/bin" HOME="$HOME" CODEX_LOG="$CODEX_LOG" \
		${HAS_MARKETPLACE:+HAS_MARKETPLACE="$HAS_MARKETPLACE"} \
		${PLUGIN_STATUS+PLUGIN_STATUS="$PLUGIN_STATUS"} \
		${ADD_MP_RC:+ADD_MP_RC="$ADD_MP_RC"} ${ADD_RC:+ADD_RC="$ADD_RC"} \
		sh "$SCRIPT"
}

@test "adds the marketplace pinned to a commit, not to a branch" {
	make_codex_stub
	run_install
	[ "$status" -eq 0 ]
	# The pin is the only supply-chain control over a plugin that injects
	# instructions into every session. Codex honours `owner/repo@ref`, unlike
	# Claude Code, which is why this side is pinned and that side is not.
	grep -q 'marketplace add DietrichGebert/ponytail@[0-9a-f]\{40\}' "$CODEX_LOG"
}

@test "installs the plugin after adding the marketplace" {
	make_codex_stub
	run_install
	[ "$status" -eq 0 ]
	grep -q 'plugin add ponytail@ponytail' "$CODEX_LOG"
	mp_line="$(grep -n 'marketplace add' "$CODEX_LOG" | head -1 | cut -d: -f1)"
	add_line="$(grep -n 'plugin add ponytail' "$CODEX_LOG" | head -1 | cut -d: -f1)"
	[ "$mp_line" -lt "$add_line" ]
}

@test "does not re-add a marketplace that is already there" {
	make_codex_stub
	HAS_MARKETPLACE=1
	export HAS_MARKETPLACE
	run_install
	[ "$status" -eq 0 ]
	run grep -c 'marketplace add' "$CODEX_LOG"
	[ "$status" -ne 0 ]
}

# The STATUS column is `installed, enabled`, not `installed`. A test written
# against the shorter guess passes while the script reinstalls on every apply.
@test "does not reinstall a plugin that is already installed" {
	make_codex_stub
	HAS_MARKETPLACE=1
	PLUGIN_STATUS="installed, enabled"
	export HAS_MARKETPLACE PLUGIN_STATUS
	run_install
	[ "$status" -eq 0 ]
	run grep -c 'plugin add ponytail' "$CODEX_LOG"
	[ "$status" -ne 0 ]
}

@test "an uninstalled plugin is not mistaken for an installed one" {
	make_codex_stub
	HAS_MARKETPLACE=1
	PLUGIN_STATUS="not installed"
	export HAS_MARKETPLACE PLUGIN_STATUS
	run_install
	[ "$status" -eq 0 ]
	# `not installed` contains `installed`, so a substring test reads every
	# uninstalled plugin as present and this script would never install
	# anything -- silently, since it would exit 0 having done nothing.
	grep -q 'plugin add ponytail@ponytail' "$CODEX_LOG"
}

@test "exits 0 and does nothing when codex is not installed" {
	make_codex_stub
	rm "$BIN/codex"
	run_install
	[ "$status" -eq 0 ]
	[ ! -s "$CODEX_LOG" ]
}

@test "exits 0 and does nothing when node is not on PATH" {
	make_codex_stub
	rm "$BIN/node"
	run env -u XDG_CONFIG_HOME PATH="$BIN" HOME="$HOME" CODEX_LOG="$CODEX_LOG" \
		"$BIN/sh" "$SCRIPT"
	# ponytail's hooks are node scripts. Installing it where they cannot run
	# leaves Codex reporting hook failures every session with nothing saying
	# why.
	[ "$status" -eq 0 ]
	run grep -c 'plugin add' "$CODEX_LOG"
	[ "$status" -ne 0 ]
}

@test "a failed marketplace add does not break the apply chain" {
	make_codex_stub
	ADD_MP_RC=1
	export ADD_MP_RC
	run_install
	# This is a run_after under `set -e`: a non-zero exit here stops chezmoi,
	# so every later script never runs. One network blip must cost this one
	# plugin and nothing else.
	[ "$status" -eq 0 ]
	run grep -c 'plugin add ponytail' "$CODEX_LOG"
	[ "$status" -ne 0 ]
}

@test "a failed plugin add does not break the apply chain" {
	make_codex_stub
	ADD_RC=1
	export ADD_RC
	run_install
	[ "$status" -eq 0 ]
}
