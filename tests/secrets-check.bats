#!/usr/bin/env bats
#
# dotfiles-secrets-check verifies the Proton Pass path in two halves, because
# they are different code paths: every vault item readable by title, and every
# template naming a pass:// URI rendering non-empty. `mise run secrets-check` was
# green while `chezmoi apply` was failing on a stale pass:// reference — item
# readability said nothing about whether a template could render.
#
# The render half runs against a fixture source tree, not the real one: these
# pin the mechanism (find the templates, render them, judge the result), while
# the real signing-pubkey is exercised by running the check by hand against the
# live vault.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_dotfiles-secrets-check"

	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	BIN="$BATS_TEST_TMPDIR/bin"
	STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$STUB_LOG"
	make_pass_cli_stub "$BIN"

	# Every alarm() call goes through this stub instead of a real notify-send,
	# so the suite never pops a real desktop notification, and its argv is
	# captured so the alarm path itself can be asserted on.
	NOTIFY_LOG="$BATS_TEST_TMPDIR/notify.log"
	: >"$NOTIFY_LOG"
	make_notify_send_stub "$BIN"
	make_age_keygen_stub "$BIN"
	make_curl_stub "$BIN"
	make_date_stub "$BIN"
	CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
	: >"$CURL_LOG"

	# The vault item the devpod liveness probe reads its token out of.
	# SENTINEL so any test that finds it in the output has found a leak.

	# A recorded offline copy, current by default: the key the manifest names is
	# the one the age-keygen stub derives from the vault item, so the offline
	# half passes unless a test deliberately moves one of the two. run_check
	# clears XDG_STATE_HOME, so the script falls back to $HOME/.local/state.
	BACKUP_MANIFEST="$HOME/.local/state/dotfiles/secrets-backup"
	mkdir -p "$(dirname "$BACKUP_MANIFEST")"
	printf 'date=2026-07-01T00:00:00Z\ndestination=/mnt/stick/dotfiles-age-key.age\nage_public_key=age1fakepubkeyfixture\n' \
		>"$BACKUP_MANIFEST"

	# Every item the check knows about, all readable by default. The bodies are
	# sentinels: any test that finds one in the output has found a leak.
	ITEMS="$BATS_TEST_TMPDIR/items"
	mkdir -p "$ITEMS"
	for title in "git signing key" \
		"sops age keys" "gh hosts.yml" "fixture signing key"; do
		printf 'SENTINEL-SECRET-BODY\n' >"$ITEMS/$title"
	done
	printf 'MISE_GITHUB_TOKEN=SENTINEL-DEVPOD-TOKEN\n' >"$ITEMS/devpod dotfiles-env"

	# A fixture source tree. The templates only need to NAME a pass:// URI for
	# the grep to find them — calling the vault for real would need a live
	# session, which is the thing these tests must not need.
	#
	# Every discovery fixture names the same URI on purpose: half one derives
	# items from these same URIs and dedupes them, so adding a template moves
	# the template count without moving the item count. A fixture that needs a
	# distinct item says so explicitly (fake-field, fake-other below).
	URI="pass://Dotfiles/fixture signing key/public_key"
	SRC="$BATS_TEST_TMPDIR/src"
	mkdir -p "$SRC/.chezmoitemplates"
	printf '{{- /* %s */ -}}ssh-ed25519 AAAAFAKE\n' "$URI" \
		>"$SRC/.chezmoitemplates/fake-pubkey"

	# Derivation source A: restore "<title>" lines, exactly the shape of
	# run_after_14-restore-secrets.sh.tmpl. Only the lines matter, not the rest.
	mkdir -p "$SRC/.chezmoiscripts"
	cat >"$SRC/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl" <<'RESTORE'
#!/bin/sh
restore "sops age keys" "$HOME/.config/sops/age/keys.txt" 600
restore "gh hosts.yml" "$HOME/.config/gh/hosts.yml" 600
RESTORE

	# Derivation source B: a pass:// URI naming both title and field. The
	# comment line is the regression guard for the false positive found while
	# writing the spec — grepping for the bare scheme matches prose.
	#
	# This one still calls chezmoi's protonPass for real, deliberately: the
	# repo's own templates no longer do, and discovery must not care which
	# mechanism a template reads the vault through, only that it names one.
	cat >"$SRC/.chezmoitemplates/fake-signing" <<'TMPL'
{{- /* protonPass — a stale pass:// share id once broke this */ -}}
{{- protonPass "pass://Dotfiles/fixture signing key/public_key" | trim -}}
TMPL

	export HOME STUB_LOG NOTIFY_LOG
}

run_check() {
	# -u XDG_*: without this, `chezmoi execute-template` picks up this
	# developer's real ~/.config/chezmoi/chezmoi.toml (HOME is redirected, but
	# XDG_CONFIG_HOME is not), so the render half runs against a different
	# config locally than it does in CI, and a typo in a personal config fails
	# the suite with an unrelated message. Same hazard, same fix as
	# mise.toml's [tasks.verify].
	# DBUS_SESSION_BUS_ADDRESS: set to a fixed fake value so alarm() always
	# takes the notify-send branch (and hits the stub) regardless of whether
	# the host running the suite has a real session bus.
	run env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME \
		HOME="$HOME" STUB_LOG="$STUB_LOG" NOTIFY_LOG="$NOTIFY_LOG" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=$BATS_TEST_TMPDIR/fake-bus" \
		CURL_LOG="$CURL_LOG" \
		PATH="$BIN:$PATH" PASS_ITEM_DIR="$ITEMS" "$@" sh "$SCRIPT" --source "$SRC"
}

@test "all items readable and all templates rendering exits 0" {
	run_check
	[ "$status" -eq 0 ]
}

@test "reports every item it checked" {
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"gh hosts.yml"* ]]
	[[ "$output" == *"sops age keys"* ]]
}

@test "reports the templates it rendered" {
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"fake-pubkey"* ]]
}

# The rule that turns a monitoring tool into a leak.
@test "never emits secret contents" {
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" != *"SENTINEL-SECRET-BODY"* ]]
	[[ "$output" != *"AAAAFAKE"* ]]
}

@test "an unreadable item fails and names only that item" {
	rm "$ITEMS/gh hosts.yml"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"gh hosts.yml"* ]]
	[[ "$output" == *"unreadable"* ]]
	# One failure, not eight: a broken session or a wrong vault name would
	# make every item unreadable, and that must not look like this case.
	[ "$(printf '%s\n' "$output" | grep -c 'unreadable')" -eq 1 ]
}

# An empty fetch is a failure that exited 0 — the same trap the restore script
# guards against.
@test "an item that comes back empty fails" {
	: >"$ITEMS/sops age keys"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"sops age keys"* ]]
}

@test "checks every title named by a restore line" {
	run_check
	grep -q -- "--item-title sops age keys" "$STUB_LOG"
	grep -q -- "--item-title gh hosts.yml" "$STUB_LOG"
}

# B8. The derivation anchored on `^restore "`, so wrapping a call in a
# conditional — that is, indenting it — silently dropped that secret from the
# check. Nothing failed; the item just stopped being watched, which is the exact
# failure the derivation was built to prevent, arriving through the back door.
@test "an indented restore call is still derived" {
	printf 'if [ -n "$x" ]; then\n\trestore "indented secret" "$HOME/x" 600\nfi\n' \
		>>"$SRC/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl"
	printf 'SENTINEL-SECRET-BODY\n' >"$ITEMS/indented secret"
	run_check
	[ "$status" -eq 0 ]
	grep -q -- "--item-title indented secret" "$STUB_LOG"
}

@test "a restore call indented with spaces is derived too" {
	printf '    restore "space indented" "$HOME/y" 600\n' \
		>>"$SRC/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl"
	printf 'SENTINEL-SECRET-BODY\n' >"$ITEMS/space indented"
	run_check
	[ "$status" -eq 0 ]
	grep -q -- "--item-title space indented" "$STUB_LOG"
}

# The other side of widening the pattern: a commented-out call is not a call,
# and must not become a vault item that fails the check forever.
@test "a commented-out restore call is not derived" {
	printf '# restore "commented secret" "$HOME/z" 600\n' \
		>>"$SRC/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl"
	run_check
	[ "$status" -eq 0 ]
	! grep -q -- "--item-title commented secret" "$STUB_LOG"
}

# The whole point: the field comes from the URI, not from a guess. A hand-kept
# list said `private_key` for the signing key while the template reads
# `public_key`, so the check passed on a field nothing consumed.
@test "checks a URI-named title on the field the URI names" {
	run_check
	grep -q -- "--item-title fixture signing key" "$STUB_LOG"
	grep -q -- "--field public_key" "$STUB_LOG"
}

# MINOR 7: `[a-z_]+` alone rejected digits and uppercase, silently truncating
# a field like `api_key2` to `api_key` — a confusing "unreadable" against a
# field nothing consumes, rather than a loud failure. The class now covers
# whatever a field can actually be named.
@test "a URI field containing a digit or an uppercase letter is captured in full, not truncated" {
	cat >"$SRC/.chezmoitemplates/fake-field" <<'TMPL'
{{- /* protonPass */ -}}
{{- protonPass "pass://Dotfiles/fixture signing key/Api_Key2" | trim -}}
TMPL
	run_check
	grep -q -- "--field Api_Key2" "$STUB_LOG"
	! grep -q -- "--field Api_Key " "$STUB_LOG"
}

# Regression guard for a real false positive: the script's own comment about a
# "stale pass:// share id" matches a bare-scheme grep, and the check would then
# try to fetch an item named "share id".
@test "a pass:// mention in prose is not treated as an item" {
	run_check
	! grep -q -- "--item-title share id" "$STUB_LOG"
}

@test "a derived title missing from the vault fails and names it" {
	rm "$ITEMS/sops age keys"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"sops age keys"* ]]
	[[ "$output" == *"unreadable"* ]]
}

# The general rule: derived-and-empty must not look like checked-and-fine. Both
# sources have to go: the restore lines, and every template naming a URI —
# which is now every discovery fixture, fake-pubkey included.
@test "deriving zero titles is a fault" {
	rm -rf "$SRC/.chezmoiscripts"
	rm -f "$SRC/.chezmoitemplates/fake-signing"
	rm -f "$SRC/.chezmoitemplates/fake-pubkey"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"no vault items"* ]]
}

# IMPORTANT 1, part 1: the union check above only fires when *both* sources
# come back empty. Renaming the `restore` helper (rather than removing the
# scripts directory) leaves .chezmoiscripts in place but makes its own scan
# yield nothing — while the URI source still yields "fixture signing key",
# keeping the union non-empty and silent. That is the exact bug: a whole
# derivation source failing without a word.
@test "a restore scripts directory that names no titles is a fault" {
	sed -i 's/^restore /reestore /' \
		"$SRC/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"no restore titles"* ]]
}

# IMPORTANT 1, part 2: symmetric case. The URI scan yielding nothing must be
# its own fault, while the restore titles keep the union non-empty. This
# reproduces the bug the derivation exists to fix: deleting
# `.chezmoitemplates/signing-pubkey` made the public_key check disappear with
# no fault at all.
#
# Both URI-naming fixtures have to go now. Half two keys off the same URI shape
# as half one, so "templates present but no URIs" is no longer a state that can
# exist — a template is found *because* it names one. Removing every URI trips
# both faults at once; this pins half one's, and the zero-template test below
# pins half two's from the same starting point.
@test "a templates directory that names no pass:// URIs is a fault" {
	rm "$SRC/.chezmoitemplates/fake-signing"
	rm "$SRC/.chezmoitemplates/fake-pubkey"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"no pass:// URIs"* ]]
}

# Parsing a vault out of a URI and then querying a different one would check the
# wrong thing and report success.
@test "a URI naming another vault is a fault, not a silent wrong-vault query" {
	cat >"$SRC/.chezmoitemplates/fake-other" <<'TMPL'
{{- /* protonPass */ -}}
{{- protonPass "pass://Elsewhere/some item/note" | trim -}}
TMPL
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"Elsewhere"* ]]
}

# The fault that hid for a whole session: every restore skips and apply exits 0.
@test "a dead session fails and says so, rather than blaming the items" {
	run_check PASS_INFO_RC=1
	[ "$status" -ne 0 ]
	[[ "$output" == *"no Proton Pass session"* ]]
	[[ "$output" != *"unreadable"* ]]
}

# Reproduces the reviewer's exact trigger: an unparsable chezmoi.toml makes
# `chezmoi execute-template` exit non-zero. The `src_dir` render call is the
# only one not wrapped in `|| true`, so under `set -eu` this used to kill the
# script right there — before the summary, before alarm(), and before rc=1
# from half one could ever be reported. Both halves of the fix are exercised
# here at once: the guard turns the abort into a normal fault, and even if it
# didn't, the EXIT trap below would still have caught it.
@test "an unparsable chezmoi config fails cleanly instead of aborting the script" {
	mkdir -p "$HOME/.config/chezmoi"
	printf 'this is not valid toml [[[\n' >"$HOME/.config/chezmoi/chezmoi.toml"
	run_check
	[ "$status" -ne 0 ]
	# The ssh half still ran and was reported — proof the script did not die
	# before reaching it, it handled the render half's failure instead.
	[[ "$output" == *"ssh keys"* ]]
	[ -s "$NOTIFY_LOG" ]
}

@test "a template that renders empty fails and names it" {
	printf '{{- /* %s */ -}}\n' "$URI" >"$SRC/.chezmoitemplates/fake-empty"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"fake-empty"* ]]
}

# A template that names no pass:// URI is not this check's business.
@test "ignores templates that do not touch proton" {
	printf 'nothing interesting\n' >"$SRC/.chezmoitemplates/unrelated"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" != *"unrelated"* ]]
}

# An empty render half must not look like a passing one: if the templates stop
# naming pass:// URIs, or the templates directory moves, or a future repo
# genuinely has none, the loop over `grep -rlE` matches nothing and silently
# checks zero templates. `chezmoi execute-template --source
# /nonexistent` exits 0 and echoes the path straight back, so a moved source
# tree reproduces this exact case — a zero count must be a fault, not a
# lookalike for "checked everything, all fine".
@test "a zero template count is a fault, not a silent pass" {
	# fake-signing (added in setup for URI derivation) also lives under
	# .chezmoitemplates and also names a URI, so it has to go too for the
	# template count to reach zero.
	rm "$SRC/.chezmoitemplates/fake-pubkey"
	rm "$SRC/.chezmoitemplates/fake-signing"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"0 proton template"* ]]
	# The message has to explain why zero is suspicious, not just report it.
	[[ "$output" == *"moved"* ]]
	[[ "$output" == *"pass://"* ]]
}

@test "a missing templates directory is its own fault, not a silently-skipped half" {
	rm -rf "$SRC/.chezmoitemplates"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"templates directory missing"* ]]
}

# Same subdirectory shape chezmoi itself uses to address a nested partial:
# includeTemplate takes the path relative to .chezmoitemplates, not a bare
# basename. A basename-only lookup asks chezmoi for a file at the *source
# root*, not inside .chezmoitemplates, which fails, has its stderr eaten by
# the `|| true` guard, and gets reported as "renders empty" — a false failure
# for a template that never had a chance to run.
@test "a nested proton template under .chezmoitemplates is found and rendered by its full relative name" {
	mkdir -p "$SRC/.chezmoitemplates/nested"
	printf '{{- /* %s */ -}}nested-fake\n' "$URI" \
		>"$SRC/.chezmoitemplates/nested/deep"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"nested/deep"* ]]
	[[ "$output" == *"3 proton template"* ]]
}

# .chezmoitemplates only holds partials reached through includeTemplate. A
# template that names a pass:// URI directly, anywhere else in the tree, is
# real and must count too — otherwise "every template naming a pass:// URI
# renders" is only true for templates in one particular directory.
@test "a pass:// URI in an ordinary .tmpl file outside .chezmoitemplates is found and rendered" {
	mkdir -p "$SRC/dot_config"
	printf '{{- /* %s */ -}}direct-fake\n' "$URI" \
		>"$SRC/dot_config/fake-secret.conf.tmpl"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"dot_config/fake-secret.conf.tmpl"* ]]
	[[ "$output" == *"3 proton template"* ]]
}

@test "the template count reflects how many actually rendered" {
	printf '{{- /* %s */ -}}second-fake\n' "$URI" \
		>"$SRC/.chezmoitemplates/fake-second"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"3 proton template"* ]]
}

# IMPORTANT 1, part 3: half two counted and reported n_tmpl; half one had no
# count anywhere in the summary, which is what let a whole source vanish
# silently ("ok" for six items and "ok" for one item printed the same
# summary). The fixture derives 3 items (2 restore titles, 1 URI title).
@test "the summary reports how many vault items were checked" {
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"3 vault item(s) checked"* ]]
}

# --- the offline half ---------------------------------------------------------
#
# Everything else here asks whether Proton works. These ask whether there is a
# way back if it does not — the question that only matters on the day the rest
# stop mattering, and the one the repo had documented as a warning and enforced
# nowhere.

@test "an offline copy matching the vault passes" {
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"offline backup"* ]]
	[[ "$output" == *"2026-07-01"* ]]
}

# The state the finding is about: the README says "keep an offline copy" and
# nothing ever checked that anyone had.
@test "never having made an offline copy is a fault" {
	rm -f "$BACKUP_MANIFEST"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"no offline copy has ever been recorded"* ]]
	# and it says what to run, because a warning without a next step is what
	# this replaced
	[[ "$output" == *"dotfiles-secrets-export"* ]]
}

# Staleness is a fingerprint mismatch, not an age in days: a rotated age key
# means the copy no longer opens anything, whenever it was made.
@test "a rotated vault key makes the recorded copy stale" {
	run_check AGE_PUBKEY="age1rotatedtosomethingelse"
	[ "$status" -ne 0 ]
	[[ "$output" == *"stale"* ]]
	[[ "$output" == *"2026-07-01"* ]]
}

# The mirror of the above, and the reason the check is worth having at all: an
# old copy of an unchanged key is a good copy. A check that nagged about age
# would train you to ignore it.
@test "an old copy of an unchanged key is not stale" {
	printf 'date=2019-01-01T00:00:00Z\ndestination=/mnt/stick/x.age\nage_public_key=age1fakepubkeyfixture\n' \
		>"$BACKUP_MANIFEST"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" != *"stale"* ]]
}

@test "a manifest naming no key is a fault, not a silent pass" {
	printf 'date=2026-07-01T00:00:00Z\ndestination=/mnt/stick/x.age\n' >"$BACKUP_MANIFEST"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"names no key"* ]]
}

@test "an unusable vault age key is a fault, not a pass" {
	run_check AGE_KEYGEN_RC=1
	[ "$status" -ne 0 ]
	[[ "$output" == *"cannot read the vault age key"* ]]
}

# The check must stay read-only and leak-free: it derives the public half
# through a pipe, so no private key reaches disk and none reaches the journal.
@test "the offline half emits no key material" {
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" != *"SENTINEL-SECRET-BODY"* ]]
	[[ "$output" != *"AGE-SECRET-KEY"* ]]
}

# --- the bootstrap PAT's expiry (I7) -----------------------------------------
#
# The date was in the README and nowhere else, so nothing warned and nothing
# could. The clock is stubbed rather than the constant, which stays a plain
# literal `mise run lint` compares against the README.

@test "an expiry comfortably in the future is reported, not warned about" {
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"bootstrap PAT"* ]]
	[[ "$output" == *"days left"* ]]
	[[ "$output" != *"pass-cli pat renew"* ]]
}

@test "an expiry inside the warning window fails and says how to fix it" {
	# 30 days before 2027-07-29
	run_check NOW_EPOCH=1814227200
	[ "$status" -ne 0 ]
	[[ "$output" == *"expires in 30 days"* ]]
	[[ "$output" == *"pass-cli pat renew"* ]]
}

@test "an expiry already passed fails" {
	# the day after
	run_check NOW_EPOCH=1816905600
	[ "$status" -ne 0 ]
	[[ "$output" == *"expired on 2027-07-29"* ]]
	[[ "$output" == *"pass-cli pat renew"* ]]
}

# The reason the expiry is computed before the session probe rather than after:
# an expired token is the likeliest cause of a dead session, and "no session"
# alone names the symptom. This is the one moment the machine can explain
# itself, because after this it cannot read the vault to find out anything.
@test "a dead session caused by an expired PAT names the cause, not just the symptom" {
	run_check PASS_INFO_RC=1 NOW_EPOCH=1816905600
	[ "$status" -ne 0 ]
	[[ "$output" == *"no Proton Pass session"* ]]
	[[ "$output" == *"bootstrap PAT expired on 2027-07-29"* ]]
	[[ "$output" == *"pass-cli pat renew"* ]]
	notify_text="$(cat "$NOTIFY_LOG")"
	[[ "$notify_text" == *"expired"* ]]
}

@test "a dead session with a live PAT does not blame the expiry" {
	run_check PASS_INFO_RC=1
	[ "$status" -ne 0 ]
	[[ "$output" == *"no Proton Pass session"* ]]
	[[ "$output" != *"expired"* ]]
}

# --- the devpod token's liveness (I6) ----------------------------------------
#
# Readable is not live. A lapsed token fails in the least helpful way there is:
# `devpod up` dies partway through a build with `rate limit exceeded`, which
# looks exactly like the anonymous-quota bug the token exists to fix, with every
# local check green.

@test "a live devpod token passes" {
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"devpod PAT"* ]]
	[[ "$output" == *"live"* ]]
}

@test "a token GitHub rejects is a fault" {
	run_check CURL_HTTP_CODE=401
	[ "$status" -ne 0 ]
	[[ "$output" == *"rejected by GitHub"* ]]
	[[ "$output" == *"401"* ]]
}

# The trap this probe is built around: /rate_limit answers 200 to anonymous
# requests too, so the status code alone proves nothing. If the header were
# dropped or ignored, a naive check would call that success.
@test "a 200 that is actually anonymous is a fault, not a pass" {
	run_check CURL_RATE_LIMIT=60
	[ "$status" -ne 0 ]
	[[ "$output" == *"answered anonymously"* ]]
}

@test "a 200 with no rate-limit header is a fault, not a pass" {
	run_check CURL_RATE_LIMIT=
	[ "$status" -ne 0 ]
	[[ "$output" == *"no rate-limit header"* ]]
}

# Not a fault. Every other check here needs only Proton; this one call needs
# GitHub. Calling the token bad because github.com was unreachable would be a
# lie, and the kind that teaches you to ignore the line.
@test "an unreachable GitHub is skipped, not failed" {
	run_check CURL_HTTP_CODE=000 CURL_RATE_LIMIT=
	[ "$status" -eq 0 ]
	[[ "$output" == *"could not reach GitHub"* ]]
}

@test "a vault item with no MISE_GITHUB_TOKEN is a fault" {
	printf 'SOMETHING_ELSE=x\n' >"$ITEMS/devpod dotfiles-env"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"no MISE_GITHUB_TOKEN"* ]]
}

# The repo's cardinal rule, applied to the one new place a token is handled: a
# header passed as an argument is visible in `ps` to every user on the machine.
# It goes in through a config on stdin instead. Same rule tests/proton-ssh-load
# pins for --personal-access-token.
@test "the devpod token never appears in curl's arguments" {
	run_check
	[ "$status" -eq 0 ]
	grep -q "^argv:" "$CURL_LOG"
	! grep "^argv:" "$CURL_LOG" | grep -q "SENTINEL-DEVPOD-TOKEN"
	# and it did travel, on stdin, or the probe proved nothing
	grep -q "^stdin:.*SENTINEL-DEVPOD-TOKEN" "$CURL_LOG"
}

@test "the liveness probe emits no token" {
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" != *"SENTINEL-DEVPOD-TOKEN"* ]]
}

# The spec lists this case and nothing implemented it: notify-send prints
# nothing, so without a stub capturing its argv, nothing ever proved alarm()
# was reached at all — only that the script's own stdout/stderr stayed clean.
@test "a failure alarms, and the alarm text carries no secret content" {
	: >"$ITEMS/sops age keys"
	run_check
	[ "$status" -ne 0 ]
	[ -s "$NOTIFY_LOG" ]
	notify_text="$(cat "$NOTIFY_LOG")"
	[[ "$notify_text" != *"SENTINEL-SECRET-BODY"* ]]
	[[ "$notify_text" != *"AAAAFAKE"* ]]
}

@test "a fully successful run raises no alarm" {
	run_check
	[ "$status" -eq 0 ]
	[ ! -s "$NOTIFY_LOG" ]
}

# Ordinary states, not faults. A non-zero here would alarm every container.
@test "exits 0 and silent without pass-cli" {
	# Restricted PATH rather than deleting the stub: this machine has a real
	# pass-cli on the ambient PATH, which would otherwise answer instead.
	# Same approach as tests/proton-ssh-load.bats.
	run env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME \
		HOME="$HOME" PATH="/usr/bin:/bin" sh "$SCRIPT" --source "$SRC"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# D3: every script in ~/.local/bin answers --help the same way — usage on
# stdout, exit 0, no work done. This one used to fall through to the catch-all
# and print usage to stderr with exit 2, which is the answer for a *mistake*,
# not for a question.
@test "--help prints usage on stdout and exits 0" {
	run env HOME="$HOME" PATH="$BIN:$PATH" sh "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: dotfiles-secrets-check"* ]]
	# and it explains what the check actually covers
	[[ "$output" == *"--source"* ]]
}

@test "-h does the same" {
	run env HOME="$HOME" PATH="$BIN:$PATH" sh "$SCRIPT" -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: dotfiles-secrets-check"* ]]
}

@test "an unknown argument still gets usage and exit 2" {
	run env HOME="$HOME" PATH="$BIN:$PATH" sh "$SCRIPT" --nope
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown argument"* ]]
	[[ "$output" == *"usage:"* ]]
}

# MINOR 8: `src_root="${2:-}"` used to succeed even with nothing after
# --source, then `shift 2` with one argument left died with a raw shell error
# ("shift count out of range", exit 1) instead of this script's own usage
# message and exit 2.
@test "a bare --source with no value gets the usage message, not a shell error" {
	run env HOME="$HOME" PATH="$BIN:$PATH" sh "$SCRIPT" --source
	[ "$status" -eq 2 ]
	[[ "$output" == *"usage:"* ]]
	[[ "$output" != *"shift count"* ]]
}

# proton-ssh-load loads by item type, never by title, so the count is what it
# actually depends on. Checking titles tested something no code relies on.
@test "reports the ssh key count" {
	run_check
	[ "$status" -eq 0 ]
	# Anchored to the ssh line itself (MINOR 5): an unanchored `*"3"*` passes
	# today only because nothing else in the output happens to contain a 3.
	[[ "$output" == *"ssh keys"*"3 valid ssh keys"* ]]
}

# IMPORTANT 3 / MINOR 8: the report has two count-like lines differing only in
# capitalisation — the header "✓ Valid SSH Keys (N):" and the summary's
# "Valid SSH keys: N". A parser that reads whichever comes first, rather than
# the trailing Summary: block specifically, would report the header's count.
@test "the ssh parser reads the summary count, not a mismatched header count" {
	run_check PASS_SSH_VALID=3 PASS_SSH_HEADER_VALID=99
	[ "$status" -eq 0 ]
	[[ "$output" == *"ssh keys"*"3 valid ssh keys"* ]]
	[[ "$output" != *"99"* ]]
}

@test "no valid ssh keys is a fault" {
	run_check PASS_SSH_VALID=0
	[ "$status" -ne 0 ]
	[[ "$output" == *"ssh"* ]]
}

@test "an invalid ssh item fails and reports the reason" {
	run_check PASS_SSH_INVALID="unsupported key type"
	[ "$status" -ne 0 ]
	[[ "$output" == *"unsupported key type"* ]]
}

# Renamed from "an unparsable ssh debug summary is a fault" (MINOR 4): this
# tests the nonzero-exit branch specifically. It is not the spec's real
# upgrade hazard — see the wording-change test below for that.
@test "a nonzero ssh-agent debug exit is a fault" {
	run_check PASS_SSH_DEBUG_RC=1
	[ "$status" -ne 0 ]
}

# MINOR 4: the real upgrade hazard is not a nonzero exit — it is pass-cli
# changing its wording while still exiting 0, which silently stops matching
# the sed pattern. The stub expresses this with an empty/renamed valid-count
# line rather than the usual "Valid SSH keys: N".
@test "an ssh debug summary with changed wording is a fault, even though pass-cli itself exits 0" {
	run_check PASS_SSH_BAD_WORDING=1
	[ "$status" -ne 0 ]
	[[ "$output" == *"ssh keys"* ]]
}

# The ssh half handles key material; it must only ever count. Regression guard
# for a stub that could not previously prove this (MINOR 3): the old stub only
# ever emitted the Summary block, never a header line or a fingerprint, so a
# script that echoed the raw debug output verbatim would still have passed.
# Now that the stub emits a fingerprint-shaped sentinel, this test can fail.
@test "the ssh half emits no key material" {
	run_check
	[[ "$output" != *"SENTINEL-SECRET-BODY"* ]]
	[[ "$output" != *"SENTINEL-FINGERPRINT"* ]]
}

# The titles are gone: nothing names them, so nothing should look them up.
@test "no longer looks up ssh keys by title" {
	run_check
	! grep -q -- "--item-title aur ssh key" "$STUB_LOG"
	! grep -q -- "--item-title ssh auth key" "$STUB_LOG"
}

# Regression guard for a real false positive found running against the live
# vault: the Dotfiles vault holds the ssh keys alongside every other secret,
# so `ssh-agent debug` reports every non-ssh item (and any trashed item) as
# "invalid" on every ordinary run. Neither is this check's business — only a
# reason outside those two shapes is.
@test "the ordinary non-ssh-item noise in the debug summary is not a fault" {
	run_check PASS_SSH_INVALID="Not an SSH key item (type: Note)"
	[ "$status" -eq 0 ]
}

@test "a trashed non-ssh-key item is ignored" {
	run_check PASS_SSH_INVALID="Item is trashed" PASS_SSH_INVALID_TYPE="Custom"
	[ "$status" -eq 0 ]
}

# The human-chosen resolution to IMPORTANT 2: trashing an item is one click
# and the likeliest way a key is actually lost, and the general "Item is
# trashed" allowance above would otherwise hide exactly that. Only a trashed
# item whose type is SSH Key is this check's business; a trashed item of any
# other type stays ignored (the test above).
@test "a trashed ssh-key item is a fault and says so" {
	run_check PASS_SSH_INVALID="Item is trashed" PASS_SSH_INVALID_TYPE="SSH Key"
	[ "$status" -ne 0 ]
	[[ "$output" == *"trashed"* ]]
	[[ "$output" == *"ssh"* ]]
}
