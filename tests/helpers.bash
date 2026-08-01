# Shared fixtures for the tests that exercise the Proton Pass path.
#
# Neither script can be tested against the real vault: that needs a live session
# and would put real secrets in a test's output. Both talk to Proton through one
# binary, `pass-cli`, so a stub on PATH is the whole seam.

# Writes a fake pass-cli into $1 (a directory placed first on PATH) and records
# every invocation to $STUB_LOG, one argv per line. Behaviour is driven by
# environment variables so a test can pick the failure it wants:
#
#   PASS_INFO_RC   exit code for `pass-cli info`      (default 0 — session live)
#   PASS_LOGIN_RC  exit code for `pass-cli login`     (default 0)
#   PASS_LOGIN_BAD_TOKEN  a token value that `pass-cli login` rejects; any
#                         other token falls through to PASS_LOGIN_RC
#   PASS_VIEW_RC   exit code for `pass-cli item view` (default 0)
#   PASS_SSH_RC    exit code for `pass-cli ssh-agent` (default 0)
#   PASS_SSH_TOTAL        `ssh-agent debug` total items checked (default 3)
#   PASS_SSH_VALID        `ssh-agent debug` valid SSH keys      (default 3)
#   PASS_SSH_INVALID      a reason string; when set, debug reports an invalid item
#   PASS_SSH_DEBUG_RC     exit code for `ssh-agent debug`       (default 0)
#   PASS_ITEM_DIR  directory of files named after item titles; the matching
#                  file's contents are what `item view` prints. A title with no
#                  file prints nothing, which is the "came back empty" case.
make_pass_cli_stub() {
	local bin="$1"
	mkdir -p "$bin"
	cat >"$bin/pass-cli" <<'STUB'
#!/bin/sh
# Record the full argv. The token-never-in-argv assertion reads this.
[ -n "${STUB_LOG:-}" ] && printf '%s\n' "$*" >>"$STUB_LOG"

case "$1" in
info)
	exit "${PASS_INFO_RC:-0}"
	;;
login)
	# Lets a test reject one specific token and accept the next, which
	# PASS_LOGIN_RC cannot express. The token arrives in the environment, so
	# this is also the only place the stub can see it at all.
	if [ -n "${PASS_LOGIN_BAD_TOKEN:-}" ] &&
		[ "${PROTON_PASS_PERSONAL_ACCESS_TOKEN:-}" = "$PASS_LOGIN_BAD_TOKEN" ]; then
		exit 1
	fi
	exit "${PASS_LOGIN_RC:-0}"
	;;
ssh-agent)
	# `ssh-agent debug` reports what `ssh-agent load` would load, without
	# touching the agent. The check parses its summary, so the stub has to
	# produce that shape. PASS_SSH_RC still covers the non-debug forms.
	if [ "${2:-}" = "debug" ]; then
		if [ -n "${PASS_SSH_INVALID:-}" ]; then
			printf '  Invalid items:\n    Reason: %s\n' "$PASS_SSH_INVALID"
		fi
		printf 'Summary:\n  Total items checked: %s\n  Valid SSH keys: %s\n' \
			"${PASS_SSH_TOTAL:-3}" "${PASS_SSH_VALID:-3}"
		exit "${PASS_SSH_DEBUG_RC:-0}"
	fi
	exit "${PASS_SSH_RC:-0}"
	;;
item)
	rc="${PASS_VIEW_RC:-0}"
	[ "$rc" -ne 0 ] && exit "$rc"
	# Pull the title out of the argument list. Real pass-cli accepts either
	# --item-title, or a positional pass://<vault>/<title>/<field> URI — and
	# chezmoi's own protonPass template function uses the latter, so the stub
	# has to understand both shapes, not just the one dotfiles-secrets-check
	# itself happens to use.
	title=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--item-title)
			title="$2"
			;;
		pass://*)
			rest="${1#pass://}"
			rest="${rest#*/}"
			title="${rest%/*}"
			;;
		esac
		shift
	done
	if [ -n "${PASS_ITEM_DIR:-}" ] && [ -f "$PASS_ITEM_DIR/$title" ]; then
		cat "$PASS_ITEM_DIR/$title"
	fi
	exit 0
	;;
esac
exit 0
STUB
	chmod 755 "$bin/pass-cli"
}

# Writes a fake notify-send into $1 (a directory placed first on PATH) and
# records every invocation's argv, one per line, to $NOTIFY_LOG. Without this,
# a test that drives a script's failure path pops a real desktop notification
# (real notify-send, real session bus) on any host that has one — and because
# notify-send prints nothing, the alarm text never reaches bats' $output, so
# nothing ever asserts on what the notification actually says.
make_notify_send_stub() {
	local bin="$1"
	mkdir -p "$bin"
	cat >"$bin/notify-send" <<'STUB'
#!/bin/sh
[ -n "${NOTIFY_LOG:-}" ] && printf '%s\n' "$*" >>"$NOTIFY_LOG"
exit 0
STUB
	chmod 755 "$bin/notify-send"
}

# Renders a chezmoi script template to a runnable sh file. $2 is the PATH the
# render runs under: has-proton-session calls `pass-cli info` at render time, so
# the stub has to be visible here for the rendered script to take the
# session-is-live branch.
render_template() {
	local tmpl="$1" out="$2" render_path="$3"
	PATH="$render_path" chezmoi execute-template --source "$BATS_TEST_DIRNAME/.." \
		<"$tmpl" >"$out"
}

# Runs $SCRIPT under a pty, feeding $1 as the typed answer, so the code behind
# `[ -t 0 ]` is reachable. Everything up to a literal `--` is an env assignment;
# everything after it is a flag for the script itself. run_load cannot do the
# latter, which is why this exists alongside it.
#
# Caveat for anyone writing assertions: the pty echoes the piped input before
# the script gets a chance to turn echo off, so the typed token DOES appear in
# $output. Assert the token's absence against $STUB_LOG (the argv log), never
# against $output.
run_load_tty() {
	local typed="$1"
	shift

	local envs=() flags=() past_marker=0 arg
	for arg in "$@"; do
		if [ "$arg" = "--" ]; then
			past_marker=1
			continue
		fi
		if [ "$past_marker" = 0 ]; then
			envs+=("$arg")
		else
			flags+=("$arg")
		fi
	done

	# script -c takes one string, so every word is quoted individually rather
	# than relying on the caller to have got the quoting right.
	local cmd="" word
	for word in env "HOME=$HOME" "STUB_LOG=$STUB_LOG" "PATH=$BIN:$PATH" \
		${envs[@]+"${envs[@]}"} sh "$SCRIPT" ${flags[@]+"${flags[@]}"}; do
		cmd="$cmd $(printf '%q' "$word")"
	done

	run script -qec "$cmd" /dev/null <<<"$typed"
}
