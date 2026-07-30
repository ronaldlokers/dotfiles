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
#   PASS_VIEW_RC   exit code for `pass-cli item view` (default 0)
#   PASS_SSH_RC    exit code for `pass-cli ssh-agent` (default 0)
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
	exit "${PASS_LOGIN_RC:-0}"
	;;
ssh-agent)
	exit "${PASS_SSH_RC:-0}"
	;;
item)
	rc="${PASS_VIEW_RC:-0}"
	[ "$rc" -ne 0 ] && exit "$rc"
	# Pull --item-title out of the argument list.
	title=""
	while [ $# -gt 0 ]; do
		[ "$1" = "--item-title" ] && title="$2"
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

# Renders a chezmoi script template to a runnable sh file. $2 is the PATH the
# render runs under: has-proton-session calls `pass-cli info` at render time, so
# the stub has to be visible here for the rendered script to take the
# session-is-live branch.
render_template() {
	local tmpl="$1" out="$2" render_path="$3"
	PATH="$render_path" chezmoi execute-template --source "$BATS_TEST_DIRNAME/.." \
		<"$tmpl" >"$out"
}
