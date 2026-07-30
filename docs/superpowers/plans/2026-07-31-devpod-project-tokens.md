# DevPod project-tokens from Proton Pass — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore `~/.config/devpod/project-tokens` from the Proton Pass Dotfiles vault like the other file-shaped secrets, and make the wrapper's lookup tolerant of the stray whitespace a web-edited note invites.

**Architecture:** Two independent changes. First, `project_token()` in the devpod wrapper gets a whitespace-tolerant parser plus the repo's first test of that wrapper, driven by a stub binary standing in for DevPod. Second, one `restore` line moves the file's authorship into the vault, with the matching fixture, `secrets-check` entry and documentation updates.

**Tech Stack:** POSIX `sh`, `awk`, chezmoi script templates, bats, mise tasks.

**Spec:** `docs/superpowers/specs/2026-07-31-devpod-project-tokens-design.md`

## Global Constraints

- **Branch:** work on `feat/devpod-project-tokens`. Never commit to `main`.
- **Commit subjects:** conventional-commit style, lowercase imperative — `feat: ...`, `fix: ...`, `docs: ...`, `test: ...`.
- **No plaintext secrets anywhere in the tree.** CI runs gitleaks over full history. Test fixtures use obviously-fake values like `tok-clean`, never a real or realistic `github_pat_` string.
- **Never pass the Proton token as a flag.** `PROTON_PASS_PERSONAL_ACCESS_TOKEN` goes through the environment only; a flag value shows up in `ps`.
- **Scripts under test are not executable in the source tree** — chezmoi runs them itself. Invoke them through `sh`/`bash` in a test, never directly.
- **Repo-only files live outside `home/`.** `tests/` and `docs/` are outside; anything inside `home/` is source state.
- **Full gate:** `mise run check` (lint + test + gitleaks + clean-HOME verify). `bats` auto-discovers `tests/`, and `mise run lint` already shellchecks `home/dot_local/bin/executable_devpod`, so neither task needs a `mise.toml` change to be covered.
- **Vault prerequisite is already satisfied.** The `devpod project-tokens` note exists, titled exactly that, holding one `ronaldlokers/homelab` entry. Do not create, edit or read vault items during implementation.

---

### Task 1: Whitespace-tolerant token lookup in the devpod wrapper

The wrapper matches with `awk -F= '$1 == k'`, which fails on a line with a leading space and fails *silently* — the container starts fine and only `gh` breaks inside it. Nothing tests this wrapper today, so the test file is new.

**Files:**
- Create: `tests/devpod-wrapper.bats`
- Modify: `home/dot_local/bin/executable_devpod:73`
- Modify: `docs/design-notes.md:400` (append one paragraph after the keying paragraph)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `project_token()` keeps its existing contract — prints the token on stdout and exits 0 when the push remote's `owner/repo` has a non-empty entry; prints nothing otherwise. Task 2 depends on that contract being unchanged, only more forgiving about spacing.

- [ ] **Step 1: Write the failing test file**

Create `tests/devpod-wrapper.bats`:

```bash
#!/usr/bin/env bats
#
# executable_devpod wraps the pinned DevPod binary and, for `up`, looks up an
# optional per-project GitHub token in ~/.config/devpod/project-tokens. That
# file is authored in the Proton Pass web UI now, where a stray leading space
# is invisible — and a missed match is silent, because the container comes up
# fine and only `gh` fails inside it. These pin the parse.
#
# The seam is the wrapper's exec of ~/.local/libexec/devpod: a stub there
# records argv and the contents of any --workspace-env-file before the wrapper
# deletes it.

bats_require_minimum_version 1.5.0

setup() {
	WRAPPER="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_devpod"

	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.local/libexec" "$HOME/.config/devpod"

	# The wrapper writes its workspace env file here. Point it at the test's
	# own directory so nothing lands in the real runtime dir.
	XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
	mkdir -p "$XDG_RUNTIME_DIR"

	STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$STUB_LOG"

	cat >"$HOME/.local/libexec/devpod" <<'STUB'
#!/bin/sh
printf 'ARGV: %s\n' "$*" >>"$STUB_LOG"
# Copy out the workspace env file while it still exists; the wrapper removes
# it as soon as this returns.
prev=""
for a in "$@"; do
	if [ "$prev" = "--workspace-env-file" ]; then
		sed 's/^/ENVFILE: /' "$a" >>"$STUB_LOG"
	fi
	prev="$a"
done
exit 0
STUB
	chmod 755 "$HOME/.local/libexec/devpod"

	# project_token() keys on the push remote, not the directory name.
	PROJ="$BATS_TEST_TMPDIR/proj"
	mkdir -p "$PROJ"
	git -C "$PROJ" init -q
	git -C "$PROJ" remote add origin git@github.com:ronaldlokers/homelab.git

	TOKENS="$HOME/.config/devpod/project-tokens"
	export HOME STUB_LOG XDG_RUNTIME_DIR
}

# Writes $1 as the project-tokens file, interpreting backslash escapes so the
# cases can write `\n` rather than embedding real newlines in the source.
write_tokens() {
	printf '%b' "$1" >"$TOKENS"
	chmod 600 "$TOKENS"
}

run_up() {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" \
		XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" sh "$WRAPPER" up "$PROJ"
}

# Asserts the wrapper handed DevPod a workspace env file carrying exactly $1.
assert_token() {
	[ "$status" -eq 0 ]
	grep -qx -- "ENVFILE: GH_TOKEN=$1" "$STUB_LOG"
}

assert_no_token() {
	[ "$status" -eq 0 ]
	! grep -q -- '--workspace-env-file' "$STUB_LOG"
}

@test "a clean entry is passed as GH_TOKEN" {
	write_tokens 'ronaldlokers/homelab=tok-clean\n'
	run_up
	assert_token tok-clean
}

# The fault that prompted this: a note edited in a browser picked up a leading
# space, and `$1 == k` silently stopped matching.
@test "a leading space on the line still matches" {
	write_tokens '   ronaldlokers/homelab=tok-lead\n'
	run_up
	assert_token tok-lead
}

@test "a trailing space after the value is stripped" {
	# Built from a variable on purpose: literal trailing spaces in a source
	# file are invisible, and most editors strip them on save — which would
	# make this test pass without ever testing anything.
	pad="   "
	write_tokens "ronaldlokers/homelab=tok-trail${pad}\n"
	run_up
	assert_token tok-trail
}

@test "spaces either side of the equals still match" {
	write_tokens 'ronaldlokers/homelab = tok-spaced\n'
	run_up
	assert_token tok-spaced
}

# Regression guard, not a driver: the current `-F=` implementation already gets
# this right, and the rewrite must not lose it. Splitting on the first `=` only.
@test "a value containing an equals sign comes back intact" {
	write_tokens 'ronaldlokers/homelab=tok=with=equals\n'
	run_up
	assert_token 'tok=with=equals'
}

@test "an entry with an empty value passes no token" {
	write_tokens 'ronaldlokers/homelab=\n'
	run_up
	assert_no_token
}

@test "a non-matching repo passes no token" {
	write_tokens 'someone/other=tok-other\n'
	run_up
	assert_no_token
}

@test "an absent project-tokens file passes no token" {
	rm -f "$TOKENS"
	run_up
	assert_no_token
}
```

- [ ] **Step 2: Run the tests to verify the whitespace cases fail**

Run: `mise exec -- bats --print-output-on-failure tests/devpod-wrapper.bats`

Expected: **5 pass, 3 fail.** Exactly these three FAIL against the current `awk -F= '$1 == k'`:
- `a leading space on the line still matches`
- `a trailing space after the value is stripped`
- `spaces either side of the equals still match`

The other five pass already, and that is correct. In particular `a value containing an equals sign comes back intact` passes now — `sub(/^[^=]*=/, "")` strips only up to the first `=`. It is in the suite as a regression guard on the rewrite, not as a driver of it.

If any of the three *passes* here, stop: the harness is not reaching the parser, and changing the parser will prove nothing.

- [ ] **Step 3: Replace the lookup in the wrapper**

In `home/dot_local/bin/executable_devpod`, replace line 73:

```sh
	awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$tokens"
```

with:

```sh
	# Tolerate the spacing a web-edited vault note invites. Splitting on the
	# first `=` by hand keeps a value containing `=` intact, and the fields are
	# never assigned to: assigning to $1 rebuilds $0 joined by OFS, which would
	# turn the separators into spaces and corrupt the value.
	awk -v k="$key" '
	{
		line = $0
		sub(/^[[:space:]]+/, "", line)
		sub(/[[:space:]]+$/, "", line)
		eq = index(line, "=")
		if (eq == 0) next
		lk = substr(line, 1, eq - 1)
		val = substr(line, eq + 1)
		sub(/[[:space:]]+$/, "", lk)
		sub(/^[[:space:]]+/, "", val)
		if (lk == k && val != "") { print val; exit }
	}' "$tokens"
```

The awk-side key is `lk`, not `key`, purely so it stays visibly distinct from the shell's `$key` that arrives as `k`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- bats --print-output-on-failure tests/devpod-wrapper.bats`
Expected: all 8 PASS.

- [ ] **Step 5: Run shellcheck over the modified wrapper**

Run: `mise run lint`
Expected: clean. The wrapper is already in the shellcheck file list at `mise.toml:22`; no list change is needed.

- [ ] **Step 6: Record the reasoning in the design notes**

In `docs/design-notes.md`, after the paragraph ending `...gets pushes working with no token at all.` (the keying paragraph beginning at line 400), insert:

```markdown
The lookup tolerates surrounding whitespace, which strictness would not have
bought anything. Once the file comes from a vault note it is authored in a web
textarea, where a leading space is invisible — and the resulting failure is
silent, because `devpod up` succeeds, the container comes up, and only `gh`
fails inside it with a credentials error pointing at GitHub rather than at a
space in a note. The parse splits on the first `=` so a value containing one
survives, and skips lines without an `=`, which drops blank lines.
```

- [ ] **Step 7: Commit**

```bash
git add tests/devpod-wrapper.bats home/dot_local/bin/executable_devpod docs/design-notes.md
git commit -m "fix: tolerate whitespace in devpod project-tokens entries"
```

---

### Task 2: Restore project-tokens from the vault

One `restore` line, plus everything that must move with it so the change does not drift: the fixture, the `secrets-check` list, and the three places that currently describe the file as hand-made.

**Files:**
- Modify: `home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl` (append after the last `restore` line)
- Modify: `home/dot_local/bin/executable_devpod:50-53` (comment only)
- Modify: `mise.toml:152-153` and `mise.toml:160,162`
- Modify: `tests/restore-secrets.bats:30,58,71,156`
- Modify: `README.md:59` and `README.md:224-227`
- Modify: `docs/design-notes.md:394-395`

**Interfaces:**
- Consumes: `project_token()` from Task 1, contract unchanged.
- Produces: no new functions. The vault item title `devpod project-tokens` becomes a string three places must agree on — the restore script, the `secrets-check` list in `mise.toml`, and the bats fixture filename. A typo in any one of them is the failure mode this task's tests exist to catch.

- [ ] **Step 1: Write the failing test changes**

In `tests/restore-secrets.bats`, add the fixture after line 30:

```bash
	printf 'ronaldlokers/homelab=fake-token\n' >"$ITEMS/devpod project-tokens"
```

Add the assertion to `@test "writes every configured secret"`, after the `dotfiles-env` line:

```bash
	[ -s "$HOME/.config/devpod/project-tokens" ]
```

Extend the loop in `@test "secrets are written unreadable to anyone else"` so it reads:

```bash
	for f in "$AGE" "$HOME/.config/gh/hosts.yml" \
		"$HOME/.config/sugarrush/config.toml" \
		"$HOME/.config/devpod/dotfiles-env" \
		"$HOME/.config/devpod/project-tokens"; do
		[ "$(stat -c %a "$f")" = "600" ]
	done
```

Add to `@test "reads each secret from the Dotfiles vault by title"`, after the `dotfiles-env` grep:

```bash
	grep -q -- "--item-title devpod project-tokens" "$STUB_LOG"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec -- bats --print-output-on-failure tests/restore-secrets.bats`
Expected: FAIL on `writes every configured secret`, `secrets are written unreadable to anyone else`, and `reads each secret from the Dotfiles vault by title` — the file is never written because no `restore` line asks for it.

- [ ] **Step 3: Add the restore line**

In `home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl`, after the existing `devpod dotfiles-env` line at the end of the file:

```sh
restore "devpod project-tokens" "$HOME/.config/devpod/project-tokens" 600
```

Nothing else in the script changes: `restore()` already creates `~/.config/devpod` at 0700, writes 0600, rewrites only on change, and leaves the existing file alone on a failed or empty fetch.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- bats --print-output-on-failure tests/restore-secrets.bats`
Expected: all PASS.

- [ ] **Step 5: Add the item to secrets-check**

In `mise.toml`, extend the title list at lines 152-153:

```sh
for title in "ssh auth key" "git signing key" "aur ssh key" \
             "sops age keys" "gh hosts.yml" "sugarrush config" \
             "devpod dotfiles-env" "devpod project-tokens"; do
```

`devpod project-tokens` is 21 characters and the report column is `%-20s`, so widen both format strings in the same task or the new row breaks the alignment. Lines 160 and 162 become:

```sh
		printf 'ok    %-22s %s bytes\n' "$title" "$n"
```

```sh
		printf 'FAIL  %-22s unreadable\n' "$title" >&2
```

- [ ] **Step 6: Correct the wrapper's comment**

In `home/dot_local/bin/executable_devpod`, lines 52-53 currently say the file is `0600, absent by default`. Replace that clause so the comment block reads:

```sh
# Opt-in per-project GitHub token, for projects whose workflow needs the GitHub
# API (`gh pr create`). Git itself needs none — containers use the forwarded
# agent. ~/.config/devpod/project-tokens is `owner/repo=token`, 0600, restored
# from the Proton Pass vault and empty on a machine with no entries yet; each
# entry should be fine-grained and limited to that one repo.
```

- [ ] **Step 7: Update the README**

Add a fifth row to the secrets table, after line 59:

```markdown
| DevPod project tokens | `~/.config/devpod/project-tokens` | `devpod project-tokens` |
```

Replace the opt-in instructions at lines 224-227. The current block tells you to create the file locally and append to it, which the next apply now overwrites. Delete the fenced `sh` block and its `install`/`printf` lines, and replace them with:

```markdown
Add an `owner/repo=token` line to the **`devpod project-tokens`** note in the
Dotfiles vault, then `chezmoi apply`. Surrounding whitespace is tolerated; a
blank note is not — it trips the empty-fetch guard and warns on every apply.
```

Leave the `Keyed on the project's **push** remote...` paragraph and the `[!WARNING]` block below it exactly as they are.

- [ ] **Step 8: Update the design notes**

In `docs/design-notes.md`, lines 394-395 read `— `owner/repo=token`, mode 0600, absent by default, and consulted by the wrapper for the workspace being started.` Replace the `absent by default` clause so the sentence reads:

```markdown
`~/.config/devpod/project-tokens` is for — `owner/repo=token`, mode 0600,
restored from the vault like the other file-shaped secrets and holding no
entries on a machine that has minted none, and consulted by the wrapper for the
workspace being started.
```

- [ ] **Step 9: Run the full gate**

Run: `mise run check`
Expected: lint, the whole bats suite, gitleaks and the clean-HOME verify all pass.

The clean-HOME verify runs with no Proton session, so the new `restore` line takes the "no session" branch and exits before fetching — it proves the script still parses and applies, not that the fetch works. Step 10 is what proves the fetch.

- [ ] **Step 10: Verify against the real vault**

Run: `mise run secrets-check`
Expected: an `ok` row for `devpod project-tokens` alongside the other seven, and `every secret in the Dotfiles vault is readable`.

This needs a live Proton session. If it reports `unreadable`, the title in `mise.toml` does not match the vault item exactly — check for a trailing space before changing anything else.

- [ ] **Step 11: Commit**

```bash
git add home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl \
	home/dot_local/bin/executable_devpod mise.toml \
	tests/restore-secrets.bats README.md docs/design-notes.md
git commit -m "feat: restore devpod project-tokens from proton pass"
```

---

## Out of scope

`pass-cli` can hold local state claiming an active session while every request
fails with `non-existent session`, in which case *every* secret restore silently
no-ops and `chezmoi apply` still exits 0. This change adds a fifth secret to
that same silent path. Nothing automated would report it — `secrets-check` is
the only thing that catches it and it is manual. Recorded in the spec's "Not in
scope" section; worth its own piece of work, not this one's.
