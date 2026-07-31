# Proton Pass health check — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `mise run secrets-check` from a manual command nobody runs into a two-half check — items readable *and* templates rendering — that a weekly timer runs and notifies about.

**Architecture:** One script, `home/dot_local/bin/executable_dotfiles-secrets-check`, holding the logic currently inline in `mise.toml`. It is deliberately not a `.tmpl`, so `mise` and the bats suite invoke it through `sh` exactly as they already invoke `executable_devpod`. Task 1 builds and rewires it; Task 2 adds the systemd user timer that runs the applied copy.

**Tech Stack:** POSIX `sh`, `chezmoi execute-template`, `pass-cli`, systemd user units, bats, mise tasks.

**Spec:** `docs/superpowers/specs/2026-07-31-secrets-health-check-design.md`

## Global Constraints

- **Branch:** work on `feat/secrets-health-check`. Never commit to `main`.
- **Commit subjects:** conventional-commit style, lowercase imperative.
- **No plaintext secrets in the tree.** CI runs gitleaks over full history. Fixtures use obviously-fake values.
- **The check must never emit secret contents** — to stdout, stderr, or a notification. Titles, template names and byte counts only. This is the one rule that turns a monitoring tool into a leak.
- **Never pass the Proton token as a flag.** `PROTON_PASS_PERSONAL_ACCESS_TOKEN` goes through the environment only; a flag value shows up in `ps`.
- **Scripts under test are not executable in the source tree** — chezmoi runs them itself. Invoke through `sh` in tests; do not `chmod +x` anything under `home/`.
- **Repo-only files live outside `home/`:** `tests/`, `docs/`, `mise.toml`.
- **Every early exit is 0 for ordinary states.** Container, no `pass-cli`, no `chezmoi` — these are normal, not faults. Only a genuine fault exits non-zero.
- **Tooling is pinned via mise.** Run bats as `mise exec -- bats ...`.
- **Full gate:** `mise run check`. Neither task needs a `bats` registration — it auto-discovers `tests/`.

---

### Task 1: The check script, and rewiring `mise run secrets-check` to it

Moves the inline shell block out of `mise.toml`, adds the render half it never had, and tests both.

**Files:**
- Create: `home/dot_local/bin/executable_dotfiles-secrets-check`
- Create: `tests/secrets-check.bats`
- Modify: `mise.toml` — `[tasks.secrets-check]` body, and the shellcheck file list on line 22

**Interfaces:**
- Consumes: the `pass-cli` stub and `make_pass_cli_stub` in `tests/helpers.bash`.
- Produces: the script accepts one optional flag, `--source REPO_ROOT`, naming a repo root to check instead of this machine's configured chezmoi source. Task 2's systemd unit invokes it with no arguments.

- [ ] **Step 1: Write the failing test file**

Create `tests/secrets-check.bats`:

```bash
#!/usr/bin/env bats
#
# dotfiles-secrets-check verifies the Proton Pass path in two halves, because
# they are different code paths: every vault item readable by title, and every
# template calling protonPass rendering non-empty. `mise run secrets-check` was
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

	# Every item the check knows about, all readable by default. The bodies are
	# sentinels: any test that finds one in the output has found a leak.
	ITEMS="$BATS_TEST_TMPDIR/items"
	mkdir -p "$ITEMS"
	for title in "ssh auth key" "git signing key" "aur ssh key" \
		"sops age keys" "gh hosts.yml" "sugarrush config" \
		"devpod dotfiles-env" "devpod project-tokens"; do
		printf 'SENTINEL-SECRET-BODY\n' >"$ITEMS/$title"
	done

	# A fixture source tree. The templates only need to CONTAIN the string
	# protonPass for the grep to find them — calling it for real would need a
	# live vault, which is the thing these tests must not need.
	SRC="$BATS_TEST_TMPDIR/src"
	mkdir -p "$SRC/.chezmoitemplates"
	printf '{{- /* protonPass */ -}}ssh-ed25519 AAAAFAKE\n' \
		>"$SRC/.chezmoitemplates/fake-pubkey"

	export HOME STUB_LOG
}

run_check() {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		PASS_ITEM_DIR="$ITEMS" "$@" sh "$SCRIPT" --source "$SRC"
}

@test "all items readable and all templates rendering exits 0" {
	run_check
	[ "$status" -eq 0 ]
}

@test "reports every item it checked" {
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"ssh auth key"* ]]
	[[ "$output" == *"devpod project-tokens"* ]]
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
	[[ "$output" != *"sops age keys"*"unreadable"* ]]
}

# An empty fetch is a failure that exited 0 — the same trap the restore script
# guards against.
@test "an item that comes back empty fails" {
	: >"$ITEMS/sugarrush config"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"sugarrush config"* ]]
}

# The fault that hid for a whole session: every restore skips and apply exits 0.
@test "a dead session fails and says so, rather than blaming the items" {
	run_check PASS_INFO_RC=1
	[ "$status" -ne 0 ]
	[[ "$output" == *"no Proton Pass session"* ]]
	[[ "$output" != *"unreadable"* ]]
}

@test "a template that renders empty fails and names it" {
	printf '{{- /* protonPass */ -}}\n' >"$SRC/.chezmoitemplates/fake-empty"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"fake-empty"* ]]
}

# A template with no protonPass call is not this check's business.
@test "ignores templates that do not touch proton" {
	printf 'nothing interesting\n' >"$SRC/.chezmoitemplates/unrelated"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" != *"unrelated"* ]]
}

# Ordinary states, not faults. A non-zero here would alarm every container.
@test "exits 0 and silent without pass-cli" {
	rm "$BIN/pass-cli"
	run_check
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec -- bats --print-output-on-failure tests/secrets-check.bats`
Expected: every test FAILS — the script does not exist yet, so `sh` reports "No such file or directory". If any test passes, the harness is not invoking the script and fixing the script will prove nothing.

- [ ] **Step 3: Write the script**

Create `home/dot_local/bin/executable_dotfiles-secrets-check`:

```sh
#!/bin/sh
# Check that the Proton Pass path this machine depends on actually works.
#
# Two halves, because they are two code paths and only one was ever checked:
# every vault item must be readable by title, and every template calling
# protonPass must render non-empty. `mise run secrets-check` was green while
# `chezmoi apply` was failing on a stale pass:// share id — item readability
# said nothing about whether a template could render.
#
# Reports titles, template names and byte counts. Never contents: this runs
# unattended and its output lands in the journal.
#
# Run from dotfiles-secrets-check.timer, and safe to run by hand.
set -eu

# The repo root to check, when it is not this machine's configured chezmoi
# source — the mise task and the bats suite both pass one.
src_root=""
while [ $# -gt 0 ]; do
	case "$1" in
	--source)
		src_root="${2:-}"
		shift 2
		;;
	*)
		echo "usage: dotfiles-secrets-check [--source REPO_ROOT]" >&2
		exit 2
		;;
	esac
done

vault="Dotfiles"

# Containers get nothing from Proton by design. .chezmoiignore keeps the applied
# copy out of one, but the source-tree copy is reachable from a devcontainer
# working on this repo, so probe at runtime as well.
if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
	exit 0
fi

# Neither tool present means this machine was never set up for Proton. An
# ordinary state, not a fault — exit 0 and say nothing.
command -v pass-cli >/dev/null 2>&1 || exit 0
command -v chezmoi >/dev/null 2>&1 || exit 0

# notify-send needs a session bus; a timer firing outside a graphical login has
# none. Fall back to the journal so a failed run still leaves a trace.
alarm() {
	if command -v notify-send >/dev/null 2>&1 && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
		notify-send --app-name=dotfiles --icon=dialog-error \
			"Proton Pass check failed" "$1"
	else
		echo "dotfiles: $1" >&2
	fi
}

# Ask chezmoi to render, with or without an explicit source. A function rather
# than an unquoted variable so the flag cannot word-split.
render() {
	if [ -n "$src_root" ]; then
		chezmoi execute-template --source "$src_root" "$@"
	else
		chezmoi execute-template "$@"
	fi
}

# A dead session is the fault most worth reporting: every restore skips
# silently and the apply still exits 0. Report it as itself — without this the
# next loop would report all eight items unreadable and bury the cause.
if ! pass-cli info >/dev/null 2>&1; then
	echo "FAIL  no Proton Pass session" >&2
	alarm "No Proton Pass session; secrets are not being refreshed."
	exit 1
fi

rc=0

# --- half one: every item readable, on the field its consumer actually uses --
for title in "ssh auth key" "git signing key" "aur ssh key" \
	"sops age keys" "gh hosts.yml" "sugarrush config" \
	"devpod dotfiles-env" "devpod project-tokens"; do
	case "$title" in
	*"ssh"*key | *"signing key") field=private_key ;;
	*) field=note ;;
	esac
	n="$(pass-cli item view --vault-name "$vault" --item-title "$title" \
		--field "$field" 2>/dev/null | wc -c)"
	if [ "$n" -gt 0 ]; then
		printf 'ok    %-22s %s bytes\n' "$title" "$n"
	else
		printf 'FAIL  %-22s unreadable\n' "$title" >&2
		rc=1
	fi
done

# --- half two: every template calling protonPass renders --------------------
# Ask chezmoi where the source dir is rather than assuming: .chezmoiroot puts it
# one level below the repo root, and --source takes the root.
src_dir="$(render '{{ .chezmoi.sourceDir }}')"
tmpl_dir="$src_dir/.chezmoitemplates"

if [ -d "$tmpl_dir" ]; then
	# Derived by grep, not hardcoded, so a new Proton-backed template is covered
	# without anyone remembering to register it. Template names have no spaces.
	for name in $(grep -rl "protonPass" "$tmpl_dir" 2>/dev/null |
		sed 's|.*/||' | sort); do
		out="$(render "{{ includeTemplate \"$name\" . }}" 2>/dev/null || true)"
		if [ -n "$out" ]; then
			printf 'ok    %-22s renders %s bytes\n' \
				"$name" "$(printf '%s' "$out" | wc -c)"
		else
			printf 'FAIL  %-22s renders empty\n' "$name" >&2
			rc=1
		fi
	done
fi

if [ "$rc" -eq 0 ]; then
	echo "every secret readable and every proton template renders"
else
	alarm "The Proton Pass check failed. Run 'mise run secrets-check' for detail."
fi
exit "$rc"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- bats --print-output-on-failure tests/secrets-check.bats`
Expected: all 11 PASS.

- [ ] **Step 5: Rewire the mise task and the shellcheck list**

In `mise.toml`, replace the whole `run = '''…'''` body of `[tasks.secrets-check]` with a call to the script, keeping the description and the comment above it:

```toml
run = "sh home/dot_local/bin/executable_dotfiles-secrets-check --source ."
```

Then add the script to the shellcheck file list on line 22, after `home/dot_local/bin/executable_devpod`:

```
home/dot_local/bin/executable_dotfiles-secrets-check
```

The `home/.chezmoiscripts/*.sh.tmpl` glob already in that list covers Task 2's enable script; this one is a separate path and must be named.

- [ ] **Step 6: Verify lint and the full suite**

Run: `mise run lint`
Expected: clean, exit 0. The `for name in $(grep …)` loop draws SC2013, but that is info-level and `mise run lint` runs `--severity=warning`, which excludes it — verified against the pinned shellcheck before this plan was written. Do not restructure the loop to silence it, and do not add a blanket disable. A `while read -r` loop would be the textbook form but would put `rc` in a subshell, where the render half's failures would be lost.

Run: `mise run test`
Expected: all tests pass, including the pre-existing suite.

- [ ] **Step 7: Verify against the live vault**

Run: `mise run secrets-check`
Expected: exit 0, eight `ok` item rows, and one `ok signing-pubkey renders N bytes` row. That last row is the half that did not exist before — if it is missing, the grep found nothing and the render half is silently doing nothing.

- [ ] **Step 8: Commit**

```bash
git add home/dot_local/bin/executable_dotfiles-secrets-check \
	tests/secrets-check.bats mise.toml
git commit -m "feat: check proton templates render, not just that items are readable"
```

---

### Task 2: The weekly timer

Makes the check run without being remembered.

**Files:**
- Create: `home/dot_config/systemd/user/dotfiles-secrets-check.service`
- Create: `home/dot_config/systemd/user/dotfiles-secrets-check.timer`
- Create: `home/.chezmoiscripts/run_onchange_after_12-enable-secrets-check.sh.tmpl`
- Modify: `home/.chezmoiignore` — add the script to the existing container-gated block
- Modify: `README.md`, `docs/design-notes.md`

**Interfaces:**
- Consumes: `~/.local/bin/dotfiles-secrets-check` from Task 1, invoked with no arguments so it uses this machine's configured chezmoi source.

- [ ] **Step 1: Create the service unit**

Create `home/dot_config/systemd/user/dotfiles-secrets-check.service`:

```ini
# Check that the Proton Pass path still works: every vault item readable, and
# every template calling protonPass still rendering. Read-only — it fetches and
# reports, it never writes a secret or applies anything.
#
# Enabled automatically by
# .chezmoiscripts/run_onchange_after_12-enable-secrets-check.sh.tmpl
[Unit]
Description=Check the Proton Pass secrets path is healthy
# Every check is a network round trip per vault item.
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/dotfiles-secrets-check
# The notification is the signal, not the exit code: a non-zero exit keeps the
# script usable as a gate for `mise run secrets-check`, but systemd mailing a
# unit failure into the journal on top of the notification is just noise.
SuccessExitStatus=0 1
```

- [ ] **Step 2: Create the timer unit**

Create `home/dot_config/systemd/user/dotfiles-secrets-check.timer`:

```ini
# Weekly check of the Proton Pass path. Paired with
# dotfiles-secrets-check.service, which only ever reports.
#
# Weekly rather than the update-check's daily: every run is a network round trip
# per vault item, and a fault here costs a rebuild rather than an outage, so
# weekly detection is proportionate.
[Unit]
Description=Weekly check of the Proton Pass secrets path

[Timer]
OnCalendar=weekly
# Without this every machine hits the vault at the same instant on Monday.
RandomizedDelaySec=12h
# A laptop that was off should still check once it wakes, rather than waiting
# a full week.
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Create the enable script**

Create `home/.chezmoiscripts/run_onchange_after_12-enable-secrets-check.sh.tmpl`:

```sh
#!/bin/sh
# Enable the timer that checks the Proton Pass path. Same shape as the
# update-check enable script next door.
# Re-runs whenever any of the three pieces changes:
# service hash: {{ include "dot_config/systemd/user/dotfiles-secrets-check.service" | sha256sum }}
# timer hash:   {{ include "dot_config/systemd/user/dotfiles-secrets-check.timer" | sha256sum }}
# script hash:  {{ include "dot_local/bin/executable_dotfiles-secrets-check" | sha256sum }}
set -eu

# Only where a systemd user manager is running — hosts, not devpod containers.
# Probe the manager's own socket rather than systemctl's exit code: devcontainer
# images ship a systemctl shim that exits 0 while printing "systemd is not
# running", so trusting the exit code enables a timer that will never fire.
if [ ! -S "${XDG_RUNTIME_DIR:-/nonexistent}/systemd/private" ]; then
    echo "No systemd user session, skipping secrets-check timer." >&2
    exit 0
fi

systemctl --user daemon-reload

# systemctl --user resolves unit paths from the running manager's environment,
# not from whatever HOME this script inherited. Under a redirected HOME (CI's
# clean-HOME bootstrap, any throwaway-HOME test) the unit lands somewhere the
# manager will never look, and `enable` fails with "Unit file ... does not
# exist". That is a property of the test setup, not a broken machine.
if ! systemctl --user cat dotfiles-secrets-check.timer >/dev/null 2>&1; then
    echo "Timer unit not visible to the user manager, skipping enable." >&2
    echo "Expected when applying to a HOME the manager doesn't own." >&2
    exit 0
fi

# The timer, not the service: the service is oneshot and pulled in by the timer.
# Enabling the service itself would run a check on every login instead.
if ! systemctl --user enable --now dotfiles-secrets-check.timer; then
    echo "Could not enable dotfiles-secrets-check.timer; continuing." >&2
    echo "Enable it by hand with: systemctl --user enable --now dotfiles-secrets-check.timer" >&2
fi
```

- [ ] **Step 4: Gate the script out of containers**

In `home/.chezmoiignore`, extend the existing container-gated block that currently holds only `.local/bin/proton-ssh-load` (lines 20-24) so it reads:

```
{{ if eq (includeTemplate "is-container" .) "true" -}}
# The Proton Pass key loader is host-only for the same reason: no pass-cli and
# no session inside a container, which gets the keys from the forwarded agent.
.local/bin/proton-ssh-load
# The health check is host-only for exactly that reason too. It probes for a
# container at runtime as well, because the source-tree copy is reachable from
# a devcontainer working on this repo.
.local/bin/dotfiles-secrets-check
{{ end -}}
```

- [ ] **Step 5: Verify the units and the enable path**

Run: `mise run check`
Expected: exit 0. The clean-HOME verify exercises the enable script's skip paths — it must not fail the apply when the user manager cannot see the unit.

Run: `chezmoi apply`
Expected: completes; the enable script either enables the timer or prints one of its two skip reasons.

Run: `systemctl --user list-timers dotfiles-secrets-check.timer`
Expected: the timer is listed with a next elapse. If it is absent, read the enable script's output rather than enabling by hand — a silent failure here is the same class of fault this whole change exists to remove.

Run: `systemctl --user start dotfiles-secrets-check.service && journalctl --user -u dotfiles-secrets-check.service -n 20 --no-pager`
Expected: the journal shows the item rows and the render row, and no secret contents.

- [ ] **Step 6: Document it**

In `README.md`, in the Secrets section after the table and the "Adding one" line, add:

```markdown
**Checking it still works:** `mise run secrets-check` verifies every item is
readable *and* that every template calling `protonPass` still renders — two
different code paths, and a stale vault reference breaks the second while the
first stays green. `dotfiles-secrets-check.timer` runs it weekly and notifies
on failure.
```

In `docs/design-notes.md`, after the section describing the secrets restore,
add a short section explaining why the check has two halves, using the concrete
history: `secrets-check` returned eight readable items at the same moment
`chezmoi apply` was failing on a stale `pass://` share id, because item
readability and template rendering are different paths. Record the second
instance too — `secrets-check` tests `git signing key` on `private_key` while
`signing-pubkey` reads `public_key` from that same item, so deleting
`public_key` would leave the item check green and `allowed_signers` broken.

- [ ] **Step 7: Commit**

```bash
git add home/dot_config/systemd/user/dotfiles-secrets-check.service \
	home/dot_config/systemd/user/dotfiles-secrets-check.timer \
	home/.chezmoiscripts/run_onchange_after_12-enable-secrets-check.sh.tmpl \
	home/.chezmoiignore README.md docs/design-notes.md
git commit -m "feat: run the proton pass health check on a weekly timer"
```

---

## Two deliberate deviations from the spec

Both are cases where following the spec's literal text would have produced
something that does not work. Flagged here rather than applied silently.

**`SuccessExitStatus=0 1`, where the spec says `SuccessExitStatus=0`.** The spec
copied that line from `dotfiles-update-check.service`, whose script exits 0 on
every path. This script deliberately exits 1 on a real fault so it stays usable
as a gate for `mise run secrets-check`. With `SuccessExitStatus=0` alone,
systemd would mark the unit failed on every genuine fault and mail it into the
journal on top of the notification — the noise the spec explicitly wanted to
avoid. `0 1` delivers the spec's stated intent.

**No bats case for "inside a container → exit 0, silent".** The spec lists one.
Covering it means faking `/.dockerenv`, which needs root, or making the probe
overridable by an environment variable — weakening production code so a test can
reach it. The repo's existing answer to this is
`tests/restore-secrets.bats:46-50`, which *skips* when it detects a container
rather than simulating one. This plan follows that precedent and leaves the
branch uncovered. It is two `[ -f … ]` tests with no logic behind them; the
`.chezmoiignore` gate added in Task 2 Step 4 is the load-bearing half, and that
one is exercised by CI's `container-gates` job.

## Known limits, carried from the spec

- **CI cannot run either half.** Both need a live Proton session. This stays manual-plus-timer.
- **The render half is one template today** (`signing-pubkey`). It is the one that broke, and the list grows by grep, but it is not broad coverage.
- **The bats render tests use a fixture source tree**, so they pin the mechanism rather than the real template. Task 1 Step 7 is what exercises the real one.
- **A machine that is off learns nothing** until it wakes; `Persistent=true` mitigates, it does not remove.
