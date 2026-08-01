# Deriving the vault item list — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `dotfiles-secrets-check` carrying a hardcoded list of vault item titles — derive the six that a consumer names, and replace the two that nothing names with a check of what the consumer actually does.

**Architecture:** Task 1 replaces half one's hardcoded loop with a list derived from `restore "…"` lines and `pass://` URIs, keeping the three SSH titles hardcoded so coverage is continuous. Task 2 removes those three and adds a non-mutating `pass-cli ssh-agent debug` check in their place, then updates the docs.

**Tech Stack:** POSIX `sh`, `pass-cli`, `chezmoi execute-template`, bats.

**Spec:** `docs/superpowers/specs/2026-08-01-single-source-vault-titles-design.md`

## Global Constraints

- **Branch:** work on `feat/single-source-vault-titles`. Never commit to `main`.
- **Commit subjects:** conventional-commit style, lowercase imperative.
- **The check must never emit secret contents** — stdout, stderr, journal or notification. Titles, template names, byte counts and item counts only.
- **Any derived input that comes back empty is a fault.** A check that checked nothing must never be indistinguishable from a check that passed. This is the spec's general rule and it binds every derivation added here.
- **The check must not mutate anything.** It runs weekly, unattended. It must never load keys into the ssh-agent, write files, or alter vault state.
- No plaintext secrets in the tree; gitleaks runs over full history. Fixtures use obviously-fake values.
- Nothing under `home/` may gain an executable bit.
- `tests/` is repo-only and lives outside `home/`; anything inside `home/` is chezmoi source state.
- The script is POSIX `sh`, not bash. No arrays, no `[[`, no `<<<`.
- Run bats as `mise exec -- bats ...`. Full gate is `mise run check` (a multi-minute cold run).

---

### Task 1: Derive half one's title list from its consumers

Replaces the hardcoded eight-title loop with six derived titles plus the three SSH titles left in place for now, so nothing stops being checked between tasks.

**Files:**
- Modify: `home/dot_local/bin/executable_dotfiles-secrets-check:106-124` (the half-one loop)
- Modify: `tests/secrets-check.bats` (fixture and cases)

**Interfaces:**
- Consumes: the existing `render()` helper, `$src_dir`, `$vault`, `$rc`, and the `reached_end`/`trap` mechanism already in the script.
- Produces: for Task 2, the derived-list machinery and the `$rc` conventions stay exactly as they are; Task 2 only removes the `ssh_titles` loop and adds a new section before the summary.

- [ ] **Step 1: Write the failing tests**

The current fixture creates eight fixed item files and a single fake template. Derivation needs a fixture that *names* items. In `tests/secrets-check.bats`, extend `setup()` — after the existing `SRC` template block — with a fake restore script and a URI-bearing template:

```bash
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
	cat >"$SRC/.chezmoitemplates/fake-signing" <<'TMPL'
{{- /* protonPass — a stale pass:// share id once broke this */ -}}
{{- protonPass "pass://Dotfiles/fixture signing key/public_key" | trim -}}
TMPL
```

Add these cases:

```bash
@test "checks every title named by a restore line" {
	run_check
	grep -q -- "--item-title sops age keys" "$STUB_LOG"
	grep -q -- "--item-title gh hosts.yml" "$STUB_LOG"
}

# The whole point: the field comes from the URI, not from a guess. A hand-kept
# list said `private_key` for the signing key while the template reads
# `public_key`, so the check passed on a field nothing consumed.
@test "checks a URI-named title on the field the URI names" {
	run_check
	grep -q -- "--item-title fixture signing key" "$STUB_LOG"
	grep -q -- "--field public_key" "$STUB_LOG"
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

# The general rule: derived-and-empty must not look like checked-and-fine.
@test "deriving zero titles is a fault" {
	rm -rf "$SRC/.chezmoiscripts"
	rm -f "$SRC/.chezmoitemplates/fake-signing"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"no vault items"* ]]
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
```

The fixture item files must cover the derived titles. Replace the eight-title `for` loop in `setup()` with one creating exactly these:

```bash
	for title in "ssh auth key" "git signing key" "aur ssh key" \
		"sops age keys" "gh hosts.yml" "fixture signing key"; do
		printf 'SENTINEL-SECRET-BODY\n' >"$ITEMS/$title"
	done
```

Existing cases naming `sugarrush config`, `devpod dotfiles-env` or `devpod project-tokens` refer to items the fixture no longer derives — retarget each to `sops age keys`, which the fixture does derive. Do not delete those cases; they cover empty-fetch and sentinel behaviour that still matters.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec -- bats --print-output-on-failure tests/secrets-check.bats`

Expected: the six new cases FAIL. `checks every title named by a restore line` fails because the hardcoded list has no `sops age keys` lookup driven by derivation — note it may *appear* to pass, since the hardcoded list happens to contain that title. If it does pass, that is expected and not a problem; the load-bearing failures are `checks a URI-named title on the field the URI names` (nothing requests `--field public_key`), `deriving zero titles is a fault`, and `a URI naming another vault is a fault`. Confirm those three fail before continuing.

- [ ] **Step 3: Replace the hardcoded loop with derivation**

In `home/dot_local/bin/executable_dotfiles-secrets-check`, the half-one section currently reads:

```sh
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
```

Half one now needs `$src_dir`, which is resolved further down the file. **Move the `src_dir` resolution block** (the `src_dir="$(render …)"` assignment and the `if [ -z "$src_dir" ] …` guard that follows it, currently just under the `half two` banner) to sit immediately after `rc=0`, before half one. Leave its comment with it. Half two then uses the already-resolved value.

Replace the loop above with:

```sh
# --- derive the item list from the consumers that actually name items -------
# No hardcoded list: a title can only be wrong here if the consumer naming it
# is wrong. Two sources, each carrying its own field, because the field matters
# — a hand-kept list said `private_key` for the signing key while the template
# reads `public_key`, so the check passed on a field nothing consumed.
#
# Pairs are "field<TAB>title", one per line. Titles contain spaces, so the loop
# below splits on newlines only; a temp file would need its own cleanup in the
# EXIT trap for no gain.
#
# Accumulate with plain string concatenation and a literal trailing newline, NOT
# `items="$(printf '%s%s\n' "$items" "$new")"` — command substitution strips
# trailing newlines, so that form glues each entry onto the previous title with
# no separator and silently produces one mangled item.
items=""

# (a) restore "<title>" lines in the chezmoi scripts. Read as text, not
# rendered: the lines are literal in the template. The field is always `note` —
# restore() asks for exactly that.
if [ -n "$src_dir" ] && [ -d "$src_dir/.chezmoiscripts" ]; then
	restore_titles="$(grep -rhoE '^restore "[^"]+"' "$src_dir/.chezmoiscripts" 2>/dev/null |
		sed -e 's/^restore "//' -e 's/"$//' | sort -u || true)"
	if [ -n "$restore_titles" ]; then
		items="${items}$(printf '%s\n' "$restore_titles" | sed 's/^/note	/')
"
	fi
fi

# (b) pass://<vault>/<title>/<field> URIs, over the same file set half two
# scans, so "the templates" has one definition rather than two.
#
# The pattern demands all three segments. Grepping for the bare scheme also
# matches prose — this script's own comment about a stale `pass://` share id
# does — and the check would then try to fetch an item called "share id". The
# vault segment has no spaces, the title may, the field is lowercase and
# underscores.
if [ -n "$src_dir" ]; then
	uris="$( { grep -rhoE 'pass://[^/"[:space:]]+/[^/"]+/[a-z_]+' \
		"$src_dir/.chezmoitemplates" 2>/dev/null || true
		find "$src_dir" -type f -name '*.tmpl' -not -path '*/.git/*' 2>/dev/null |
			xargs -r grep -hoE 'pass://[^/"[:space:]]+/[^/"]+/[a-z_]+' 2>/dev/null || true
	} | sort -u)"
	# Newline-only splitting here too. `for uri in $uris` splits on spaces, and
	# titles contain them: `pass://Dotfiles/git signing key/public_key` becomes
	# three words, yielding two bogus "vault" failures and one mangled item.
	# Confirmed against the real source tree before this plan was written.
	old_ifs="$IFS"
	IFS='
'
	for uri in $uris; do
		IFS="$old_ifs"
		rest="${uri#pass://}"
		uri_vault="${rest%%/*}"
		rest="${rest#*/}"
		uri_title="${rest%/*}"
		uri_field="${rest##*/}"
		# Honouring a second vault would mean querying somewhere this repo does
		# not use. Fault rather than silently checking the wrong place.
		if [ "$uri_vault" != "$vault" ]; then
			printf 'FAIL  URI names vault %s, not %s: %s\n' \
				"$uri_vault" "$vault" "$uri" >&2
			rc=1
		else
			items="${items}${uri_field}	${uri_title}
"
		fi
		IFS='
'
	done
	IFS="$old_ifs"
fi

# SSH-key items are not derived: proton-ssh-load loads them by type, never by
# title, so nothing names these. They are an assertion about vault contents.
for t in "ssh auth key" "git signing key" "aur ssh key"; do
	items="${items}private_key	${t}
"
done

items="$(printf '%s' "$items" | grep -v '^$' | sort -u || true)"

if [ -z "$items" ]; then
	printf 'FAIL  derived no vault items to check: the restore script or the templates moved\n' >&2
	rc=1
fi

# --- half one: every derived item readable, on its own field ----------------
# Newline-only splitting: titles contain spaces. IFS is restored inside the
# loop so the body behaves normally, and again after it.
old_ifs="$IFS"
IFS='
'
for pair in $items; do
	IFS="$old_ifs"
	field="${pair%%	*}"
	title="${pair#*	}"
	n="$(pass-cli item view --vault-name "$vault" --item-title "$title" \
		--field "$field" 2>/dev/null | wc -c)"
	if [ "$n" -gt 0 ]; then
		printf 'ok    %-22s %s bytes\n' "$title" "$n"
	else
		printf 'FAIL  %-22s unreadable\n' "$title" >&2
		rc=1
	fi
	IFS='
'
done
IFS="$old_ifs"
```

The two `sed 's/^/note\t/'` and `printf '%s\t%s'` uses need a real tab. Write it as a literal tab character in the file, matching how `${pair%%	*}` above uses one.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- bats --print-output-on-failure tests/secrets-check.bats`
Expected: all cases PASS, including the six new ones.

- [ ] **Step 5: Lint**

Run: `mise run lint`
Expected: clean, exit 0. If shellcheck raises SC2013 on the new `for uri in $uris` loop, that is info-level and `--severity=warning` excludes it, exactly as for the existing loops — do not restructure and do not add a disable directive.

- [ ] **Step 6: Verify against the live vault**

Run: `mise run secrets-check`

Expected: exit 0. The derivation logic in Step 3 was executed against this repo's real source tree before this plan was written, and produced exactly these six pairs:

```
note        devpod dotfiles-env
note        devpod project-tokens
note        gh hosts.yml
note        sops age keys
note        sugarrush config
public_key  git signing key
```

plus the three hardcoded SSH titles on `private_key`. The `git signing key` row must show `public_key` being requested — check `--field public_key` reaches `pass-cli`. If any restore-derived title is missing, derivation is not reading the real restore script; if `git signing key` appears on `private_key`, the URI derivation is not running. Report either rather than accepting the run.

- [ ] **Step 7: Commit**

```bash
git add home/dot_local/bin/executable_dotfiles-secrets-check tests/secrets-check.bats
git commit -m "feat: derive the vault item list from the consumers that name it"
```

---

### Task 2: Replace the SSH titles with the consumer's own question

`proton-ssh-load` runs `pass-cli ssh-agent load --vault-name Dotfiles`, which selects by item type. Checking three titles by name tests something no code relies on, and produces a false alarm when a key is renamed in the vault.

**Files:**
- Modify: `home/dot_local/bin/executable_dotfiles-secrets-check` (remove the SSH title block from Task 1, add the ssh half)
- Modify: `tests/helpers.bash` — new `ssh-agent debug` branch in the `pass-cli` stub
- Modify: `tests/secrets-check.bats`
- Modify: `README.md`, `docs/design-notes.md`

**Interfaces:**
- Consumes: `$rc`, `$vault` and the `alarm()`/`reached_end` conventions from Task 1.
- Produces: nothing later depends on this.

- [ ] **Step 1: Add the stub branch**

The stub's existing `ssh-agent)` branch exits `PASS_SSH_RC` and prints nothing. `ssh-agent debug` needs output. In `tests/helpers.bash`, replace that branch with:

```sh
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
```

Document the four new variables in the helper's header comment block, alongside the existing `PASS_INFO_RC` / `PASS_VIEW_RC` entries:

```
#   PASS_SSH_TOTAL        `ssh-agent debug` total items checked (default 3)
#   PASS_SSH_VALID        `ssh-agent debug` valid SSH keys      (default 3)
#   PASS_SSH_INVALID      a reason string; when set, debug reports an invalid item
#   PASS_SSH_DEBUG_RC     exit code for `ssh-agent debug`       (default 0)
```

- [ ] **Step 2: Write the failing tests**

In `tests/secrets-check.bats`:

```bash
# proton-ssh-load loads by item type, never by title, so the count is what it
# actually depends on. Checking titles tested something no code relies on.
@test "reports the ssh key count" {
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"ssh keys"* ]]
	[[ "$output" == *"3"* ]]
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

# Fails closed: an upgrade that changes pass-cli's wording must not read as a
# healthy zero.
@test "an unparsable ssh debug summary is a fault" {
	run_check PASS_SSH_DEBUG_RC=1
	[ "$status" -ne 0 ]
}

# The ssh half handles key material; it must only ever count.
@test "the ssh half emits no key material" {
	run_check
	[[ "$output" != *"SENTINEL-SECRET-BODY"* ]]
	[[ "$output" != *"PRIVATE KEY"* ]]
}

# The titles are gone: nothing names them, so nothing should look them up.
@test "no longer looks up ssh keys by title" {
	run_check
	! grep -q -- "--item-title aur ssh key" "$STUB_LOG"
	! grep -q -- "--item-title ssh auth key" "$STUB_LOG"
}
```

Remove `ssh auth key` and `aur ssh key` from the fixture's item list in `setup()`, keeping `git signing key` — Task 1's URI derivation does not name it, but the real `signing-pubkey` URI does, and the fixture's `fixture signing key` covers that path.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mise exec -- bats --print-output-on-failure tests/secrets-check.bats`
Expected: the six new cases FAIL — there is no ssh half yet, and `no longer looks up ssh keys by title` fails because Task 1 still adds those three titles.

- [ ] **Step 4: Remove the SSH title block and add the ssh half**

Delete this block, added in Task 1:

```sh
# SSH-key items are not derived: proton-ssh-load loads them by type, never by
# title, so nothing names these. They are an assertion about vault contents.
for t in "ssh auth key" "git signing key" "aur ssh key"; do
	items="${items}private_key	${t}
"
done
```

Then, immediately before the `if [ "$n_tmpl" -eq 0 ]` block near the end, add:

```sh
# --- the ssh half: ask the question proton-ssh-load asks --------------------
# proton-ssh-load runs `pass-cli ssh-agent load --vault-name Dotfiles`, which
# selects by item *type*, never by title. Checking titles tested something no
# code relies on, and reported a failure whenever a key was renamed in the
# vault while proton-ssh-load carried on working.
#
# `ssh-agent debug` answers the same question without touching the agent: this
# script must never mutate anything. Its output carries algorithms and
# fingerprints, never private key material, and only the counts are printed
# here so the weekly journal line stays stable.
ssh_out="$(pass-cli ssh-agent debug --vault-name "$vault" 2>/dev/null || true)"
ssh_valid="$(printf '%s\n' "$ssh_out" |
	sed -n 's/^[[:space:]]*Valid SSH keys:[[:space:]]*\([0-9][0-9]*\).*/\1/p' |
	head -n 1)"
ssh_reason="$(printf '%s\n' "$ssh_out" |
	sed -n 's/^[[:space:]]*Reason:[[:space:]]*\(.*\)$/\1/p' | head -n 1)"

if [ -n "$ssh_reason" ]; then
	printf 'FAIL  %-22s %s\n' "ssh keys" "invalid item: $ssh_reason" >&2
	rc=1
fi

# Fails closed. An empty parse means either no keys or a pass-cli whose output
# format changed; both must be loud, because a silent zero here means git push
# stops working on the next machine that boots without keys.
if [ -z "$ssh_valid" ] || [ "$ssh_valid" -eq 0 ]; then
	printf 'FAIL  %-22s no valid ssh keys (or unparsable debug output)\n' "ssh keys" >&2
	rc=1
elif [ -z "$ssh_reason" ]; then
	printf 'ok    %-22s %s valid ssh keys\n' "ssh keys" "$ssh_valid"
fi
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mise exec -- bats --print-output-on-failure tests/secrets-check.bats`
Expected: all cases PASS.

- [ ] **Step 6: Verify nothing was mutated**

Run: `ssh-add -l > /tmp/agent-before.txt; mise run secrets-check; ssh-add -l > /tmp/agent-after.txt; diff /tmp/agent-before.txt /tmp/agent-after.txt && echo "agent unchanged"`

Expected: `mise run secrets-check` exits 0 reporting `ok  ssh keys  3 valid ssh keys`, and the diff is empty. A non-empty diff means the check loaded keys — a mutation, and a blocking defect. Remove the two temp files afterwards.

- [ ] **Step 7: Full gate**

Run: `mise run lint`, then `mise run check`.
Expected: both exit 0. `mise run check` is a multi-minute cold run; run it in the foreground.

- [ ] **Step 8: Document it**

In `README.md`, in the Secrets section, amend the paragraph describing `mise run secrets-check` so it says the item list is derived from the `restore` lines and the `pass://` URIs rather than maintained by hand, and that SSH keys are counted rather than named because `proton-ssh-load` loads them by type.

In `docs/design-notes.md`, in the section covering the health check, add why the SSH keys are counted rather than named: `proton-ssh-load` calls `pass-cli ssh-agent load --vault-name Dotfiles`, which selects by item type, so a title list asserted something no code relied on and raised a false alarm whenever a key was renamed. Record the accepted cost — a key swapped for a different one keeps the count at 3 and passes — and why that is right: `ssh-agent load` would load the replacement exactly as well.

- [ ] **Step 9: Commit**

```bash
git add home/dot_local/bin/executable_dotfiles-secrets-check tests/helpers.bash \
	tests/secrets-check.bats README.md docs/design-notes.md
git commit -m "feat: count ssh keys the way proton-ssh-load loads them"
```

---

## Known limits, carried from the spec

- **CI cannot run the check** — it needs a live Proton session. The bats suite covers derivation and parsing against fixtures; only a manual run proves it against the real vault.
- **Derivation couples the check to the restore script's shape.** Rename the `restore` helper and derivation silently yields nothing — which is why the zero-derived fault is load-bearing, not defensive.
- **`ssh-agent debug`'s output format is not a stable API.** A `pass-cli` upgrade changing its wording breaks the parse. It fails closed, so the failure is loud, but it is a real upgrade hazard.
- **Coverage is deliberately reduced.** `ssh auth key` and `aur ssh key` stop being verified by name; a key swapped for a different one passes. Accepted in the spec, for the reason recorded there.
