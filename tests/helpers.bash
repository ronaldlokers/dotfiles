# Shared fixtures for the tests that exercise paths a real apply cannot be asked
# to take: the Proton Pass path, and the systemd user session.
#
# The Proton scripts cannot be tested against the real vault — that needs a live
# session and would put real secrets in a test's output. Both talk to Proton
# through one binary, `pass-cli`, so a stub on PATH is the whole seam.
#
# The systemd scripts cannot be tested against the real user manager either, for
# the mirror-image reason: it would work, and reconfigure the developer's own
# machine while doing so. `systemctl` is the seam there.

# Writes a fake pass-cli into $1 (a directory placed first on PATH) and records
# every invocation to $STUB_LOG, one argv per line. Behaviour is driven by
# environment variables so a test can pick the failure it wants:
#
#   PASS_INFO_RC   exit code for `pass-cli info`      (default 0 — session live)
#   PASS_INFO_RC_AFTER_LOGIN  exit code for `info` once a `login` has been
#                         recorded in $STUB_LOG, so a test can model a session
#                         being repaired rather than merely absent
#   PASS_LOGIN_RC  exit code for `pass-cli login`     (default 0)
#   PASS_LOGIN_BAD_TOKEN  a token value that `pass-cli login` rejects; any
#                         other token falls through to PASS_LOGIN_RC
#   PASS_VIEW_RC   exit code for `pass-cli item view` (default 0)
#   PASS_SSH_RC    exit code for `pass-cli ssh-agent` (default 0)
#   PASS_SSH_VALID        `ssh-agent debug` valid SSH keys, both the header
#                         count and the Summary count unless overridden by
#                         PASS_SSH_HEADER_VALID              (default 3)
#   PASS_SSH_HEADER_VALID overrides just the "✓ Valid SSH Keys (N):" header
#                         count, independently of the Summary count — lets a
#                         test prove the parser reads the Summary line, not
#                         the header (default: same as PASS_SSH_VALID)
#   PASS_SSH_INVALID      a reason string; when set, debug reports one invalid
#                         item with that reason
#   PASS_SSH_INVALID_TYPE the invalid item's type, shown as "title (Type)"
#                         above its Reason line                (default Note)
#   PASS_SSH_BAD_WORDING  when set, the Summary block's valid-count line uses
#                         different wording ("Valid keys (ssh): N" instead of
#                         "Valid SSH keys: N"), simulating a pass-cli release
#                         that changes the string the check parses, while
#                         still exiting 0 — the hazard is silent, not loud
#   PASS_SSH_DEBUG_RC     exit code for `ssh-agent debug`       (default 0)
#   PASS_ITEM_DIR  directory of files named after item titles; the matching
#                  file's contents are what `item view` prints. A title with no
#                  file prints nothing, which is the "came back empty" case.
#   PASS_HANG_SECS how long every call sleeps before answering — Proton
#                  unreachable, or answering far too slowly to wait for, which
#                  is the same thing to a caller on a shell startup path
#   PASS_HANG_ONLY restricts the sleep to one verb (`info`, `login`,
#                  `ssh-agent`), so a test can prove the bound is on every call
#                  rather than only the first one
make_pass_cli_stub() {
	local bin="$1"
	mkdir -p "$bin"
	cat >"$bin/pass-cli" <<'STUB'
#!/bin/sh
# The UTF-8 marks below (✓, •, ✗) are written as octal escapes
# (\NNN), never \xHH: this script's own shebang is #!/bin/sh, and on
# Ubuntu (the CI runner) that's dash, whose printf builtin has no \xHH —
# it prints the four characters literally instead of the byte. \NNN
# octal is POSIX and dash honours it; \xHH only ever worked here because
# this developer's /bin/sh happens to be bash. Confirmed by hand: dash
# turned '\xe2\x9c\x93' into the literal text "\xe2\x9c\x93", which is
# exactly why the real pass-cli output this stub imitates never carried
# the marker in CI, and everything downstream that keyed off it silently
# saw nothing to match.
# Record the full argv. The token-never-in-argv assertion reads this.
[ -n "${STUB_LOG:-}" ] && printf '%s\n' "$*" >>"$STUB_LOG"

# Proton not answering. The call is logged first, on purpose: a test asserting
# which calls were bounded needs to see that this one was attempted.
if [ -n "${PASS_HANG_SECS:-}" ] &&
	{ [ -z "${PASS_HANG_ONLY:-}" ] || [ "${PASS_HANG_ONLY}" = "$1" ]; }; then
	sleep "$PASS_HANG_SECS"
fi

case "$1" in
info)
	# A session that can be *repaired* needs two answers, not one: dead before
	# a login and live after it. Without that, a test cannot tell "the check
	# established a session" apart from "the check gave up", which is the whole
	# distinction dotfiles-secrets-check now turns on. The marker is a file
	# because the stub is a fresh process each time.
	if [ -n "${PASS_INFO_RC_AFTER_LOGIN:-}" ] && [ -n "${STUB_LOG:-}" ] &&
		grep -q '^login' "$STUB_LOG" 2>/dev/null; then
		exit "$PASS_INFO_RC_AFTER_LOGIN"
	fi
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
	# produce the real report shape byte-for-byte — verified against a live
	# `pass-cli ssh-agent debug --vault-name Dotfiles` run: a "✓ Valid SSH
	# Keys (N):" block (one "• title" / "Algorithm:" / "Fingerprint:" group
	# per key, no "(Type)" suffix on a valid key's bullet line), a
	# "✗ Invalid Items (N):" block (one "• title (Type)" / "Reason:" group
	# per invalid item), then a trailing "Summary:" block — in that order,
	# Valid then Invalid then Total. Earlier versions of this stub only ever
	# emitted the Summary block, so a parser reading the wrong line (the
	# header's "Valid SSH Keys" instead of the summary's "Valid SSH keys")
	# had nothing here to catch it. PASS_SSH_RC still covers the non-debug
	# forms.
	if [ "${2:-}" = "debug" ]; then
		valid_n="${PASS_SSH_VALID:-3}"
		header_valid_n="${PASS_SSH_HEADER_VALID:-$valid_n}"
		invalid_type="${PASS_SSH_INVALID_TYPE:-Note}"
		if [ -n "${PASS_SSH_INVALID:-}" ]; then
			invalid_n=1
		else
			invalid_n=0
		fi
		total_n=$((valid_n + invalid_n))

		printf 'SSH Agent Debug Report\n'
		printf 'Vault: Dotfiles (FAKE-SHARE-ID)\n\n'

		printf '\342\234\223 Valid SSH Keys (%s):\n' "$header_valid_n"
		i=1
		while [ "$i" -le "$valid_n" ]; do
			printf '  \342\200\242 ssh key %s\n' "$i"
			printf '    Algorithm: Ed25519\n'
			printf '    Fingerprint: SHA256:SENTINEL-FINGERPRINT-%s\n\n' "$i"
			i=$((i + 1))
		done

		printf '\342\234\227 Invalid Items (%s):\n' "$invalid_n"
		if [ -n "${PASS_SSH_INVALID:-}" ]; then
			printf '  \342\200\242 invalid item (%s)\n' "$invalid_type"
			printf '    Reason: %s\n\n' "$PASS_SSH_INVALID"
		fi

		printf 'Summary:\n'
		if [ -n "${PASS_SSH_BAD_WORDING:-}" ]; then
			printf '  Valid keys (ssh): %s\n' "$valid_n"
		else
			printf '  Valid SSH keys: %s\n' "$valid_n"
		fi
		printf '  Invalid items: %s\n' "$invalid_n"
		printf '  Total items checked: %s\n' "$total_n"
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

# Writes a fake dotfiles-status into $1 (a directory placed first on PATH).
# dotfiles-update-check runs it to decide whether to notify, and the real one
# reads recorded state that a test cannot arrange without also arranging the
# thing that wrote it. Two knobs, which is all the caller reads:
#
#   DS_RC      exit code                        (default 0 — nothing is broken)
#   DS_OUTPUT  what it prints on stdout, `\n` honoured, so a test can hand it
#              the mix of ok/warn/FAIL lines the real one produces
#
# The stub must shadow a real dotfiles-status on the developer's PATH, so put
# its directory first — and clear XDG_STATE_HOME while you are there, or the
# caller's own state file lands in the real ~/.local/state.
make_dotfiles_status_stub() {
	local bin="$1"
	mkdir -p "$bin"
	cat >"$bin/dotfiles-status" <<'STUB'
#!/bin/sh
[ -n "${DS_OUTPUT:-}" ] && printf '%b\n' "$DS_OUTPUT"
exit "${DS_RC:-0}"
STUB
	chmod 755 "$bin/dotfiles-status"
}

# Writes a fake systemctl into $1 (a directory placed first on PATH) and records
# every invocation to $SYSTEMCTL_LOG, one argv per line. The enable scripts all
# decide what to do from systemctl's exit codes, so those are what a test needs
# to drive:
#
#   SYSTEMCTL_CAT_RC     exit code for `systemctl --user cat ...`  (default 0 —
#                        the unit is visible to the running manager)
#   SYSTEMCTL_ENABLE_RC  exit code for `systemctl --user enable ...`(default 0)
#   SYSTEMCTL_RELOAD_RC  exit code for `systemctl --user daemon-reload`
#                                                                  (default 0)
make_systemctl_stub() {
	local bin="$1"
	mkdir -p "$bin"
	cat >"$bin/systemctl" <<'STUB'
#!/bin/sh
[ -n "${SYSTEMCTL_LOG:-}" ] && printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"

# Skip --user and friends to find the verb, so the stub does not care where in
# the argv it sits.
for arg in "$@"; do
	case "$arg" in
	--*) continue ;;
	esac
	case "$arg" in
	cat) exit "${SYSTEMCTL_CAT_RC:-0}" ;;
	enable) exit "${SYSTEMCTL_ENABLE_RC:-0}" ;;
	daemon-reload) exit "${SYSTEMCTL_RELOAD_RC:-0}" ;;
	esac
	break
done
exit 0
STUB
	chmod 755 "$bin/systemctl"
}

# Creates a directory shaped like a live $XDG_RUNTIME_DIR and prints its path:
# the enable scripts test for a *socket* at systemd/private, so an ordinary file
# will not do — `[ -S ]` is the whole point of the probe, since it is what tells
# a real user manager apart from a devcontainer's systemctl shim.
make_fake_runtime_dir() {
	local dir="$1"
	mkdir -p "$dir/systemd"
	python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
		"$dir/systemd/private"
	printf '%s\n' "$dir"
}

# Writes a fake age-keygen into $1 (a directory placed first on PATH). Only
# `-y -` is implemented, which is the one form both the export and the check
# use: derive the public half of an age identity read from stdin.
#
# The mapping is deliberately dumb — it echoes AGE_PUBKEY — so a test can say
# "the vault now holds a different key" by changing one variable, without
# needing real age keys or the real binary. AGE_KEYGEN_RC=1 covers the input
# that is not a usable identity at all.
make_age_keygen_stub() {
	local bin="$1"
	mkdir -p "$bin"
	cat >"$bin/age-keygen" <<'STUB'
#!/bin/sh
# Drain stdin so the writer upstream never sees EPIPE.
cat >/dev/null
[ "${AGE_KEYGEN_RC:-0}" -ne 0 ] && exit "${AGE_KEYGEN_RC}"
printf '%s\n' "${AGE_PUBKEY:-age1fakepubkeyfixture}"
exit 0
STUB
	chmod 755 "$bin/age-keygen"
}

# Writes a fake curl into $1. Only the `--config -` form the check uses is
# implemented: it reads the header off stdin (which is the point — a header
# passed as an argument would be visible in `ps`) and answers with whatever the
# test asked for.
#
#   CURL_HTTP_CODE   status to report                        (default 200)
#   CURL_RATE_LIMIT  x-ratelimit-limit to report              (default 5000)
#                    5000 = the token was accepted, 60 = GitHub answered
#                    anonymously, empty = no header at all
#   CURL_LOG         file to record the stdin config in, so a test can prove
#                    the token was sent and prove it never reached argv
make_curl_stub() {
	local bin="$1"
	mkdir -p "$bin"
	cat >"$bin/curl" <<'STUB'
#!/bin/sh
if [ -n "${CURL_LOG:-}" ]; then
	printf 'argv: %s\n' "$*" >>"$CURL_LOG"
	# The config arrives on stdin; record it so a test can assert the token
	# travelled that way and not as an argument.
	sed 's/^/stdin: /' >>"$CURL_LOG"
else
	cat >/dev/null
fi
printf '%s %s' "${CURL_HTTP_CODE:-200}" "${CURL_RATE_LIMIT-5000}"
exit 0
STUB
	chmod 755 "$bin/curl"
}

# Writes a fake date into $1, so a test can decide what "now" is. Only the two
# forms the check uses are implemented: `date -u -d <when> +%s` and `date -u
# +%s`. NOW_EPOCH moves the clock; without it the real time is used.
#
# Stubbing the clock rather than the expiry constant keeps the test-only
# plumbing out of the script: the constant stays a plain literal that `mise run
# lint` can compare against the README.
make_date_stub() {
	local bin="$1"
	mkdir -p "$bin"
	cat >"$bin/date" <<'STUB'
#!/bin/sh
real_date=/usr/bin/date
for arg in "$@"; do
	case "$arg" in
	-d) want_date=1 ;;
	esac
done
if [ -n "${want_date:-}" ]; then
	exec "$real_date" "$@"
fi
# Crash injection. `date -u +%s` is the one call dotfiles-secrets-check makes
# unguarded, so failing it aborts that script mid-run under `set -e` — which is
# the only way to exercise its EXIT trap from outside. Scoped to +%s so
# record_status can still stamp its own ISO date while the run is dying.
if [ -n "${DATE_EPOCH_FAILS:-}" ]; then
	for arg in "$@"; do
		if [ "$arg" = "+%s" ]; then
			exit 1
		fi
	done
fi
if [ -n "${NOW_EPOCH:-}" ]; then
	printf '%s\n' "$NOW_EPOCH"
	exit 0
fi
exec "$real_date" "$@"
STUB
	chmod 755 "$bin/date"
}

# Renders a chezmoi script template to a runnable sh file. $2 is the PATH the
# render runs under: has-proton-session calls `pass-cli info` at render time, so
# the stub has to be visible here for the rendered script to take the
# session-is-live branch.
# The XDG clearing is not tidiness. This desktop exports XDG_CONFIG_HOME
# pointing at the real ~/.config, and chezmoi reads its config from there — so
# every caller of this function was rendering against this developer's personal
# chezmoi.toml while believing it had redirected HOME. Four suites went through
# here, and the failure mode is the worst kind: green locally for a reason that
# does not exist in CI, or red for a typo in a config the suite has nothing to
# do with. Same hazard, same fix as [tasks.verify] and the export suite.
# $4 is an optional source tree to render against, for templates that bake in a
# path — dotfiles-update-check interpolates .chezmoi.sourceDir and then operates
# on it, so pointing it at a fixture is the only way to test the behaviour
# rather than the argument parsing. Defaults to this repo.
render_template() {
	local tmpl="$1" out="$2" render_path="$3"
	local source="${4:-$BATS_TEST_DIRNAME/..}"
	env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME \
		PATH="$render_path" chezmoi execute-template \
		--source "$source" <"$tmpl" >"$out"
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
