# Interactive Proton PAT Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an interactive `chezmoi apply` ask for the Proton Pass bootstrap
token when it has no session, instead of silently continuing without SSH keys.

**Architecture:** A new `--prompt` flag on `home/dot_local/bin/executable_proton-ssh-load`,
which already owns all login logic. `run_after_14-restore-secrets.sh.tmpl` passes
it; `dot_config/shell/ssh-agent.sh` deliberately does not, so opening a terminal
never blocks. The prompt is gated on `[ -t 0 ]` and reads stdin, so
`chezmoi apply </dev/null` (CI, `mise run verify`, `devpod up`) never prompts.

**Tech Stack:** POSIX `sh`, chezmoi 2.70.5, bats-core ≥ 1.5.0, shellcheck 0.11.0,
`script(1)` from util-linux for pty-backed tests.

**Spec:** `docs/superpowers/specs/2026-07-30-interactive-proton-pat-design.md`

## Global Constraints

- `executable_proton-ssh-load` is `#!/bin/sh` and must stay POSIX. No `read -s`,
  no `local`, no arrays, no `[[ ]]`.
- The script runs under `set -eu`. Every command whose failure is acceptable
  needs `|| true` or an `if`.
- The token reaches `pass-cli` **through the environment only**, never as
  `--personal-access-token`. `tests/proton-ssh-load.bats` pins this; do not
  weaken it.
- `shellcheck --severity=warning` must pass for both
  `home/dot_local/bin/executable_proton-ssh-load` and `tests/helpers.bash` —
  both are in the `mise run lint` file list (`mise.toml:22`).
- `tests/helpers.bash` is linted as bash (inferred from the extension), so
  `local`, arrays and herestrings are allowed **there** but not in the script.
- Exit 0 on every "could not get a session" path. This script runs from a shell
  rc; a non-zero exit surfaces as a broken login rather than a missing key. The
  only new non-zero exit is code 2 for an unknown option.
- A cached token is overwritten only after a successful `pass-cli login`, and is
  never deleted.
- `mise run check` (lint + test + secrets + verify + shells) must be green before
  the final commit.
- Never commit to `main`. Work continues on the existing branch
  `feat/interactive-proton-pat`. Conventional-commit subjects, lowercase
  imperative.

## File Structure

| File | Change | Responsibility |
| --- | --- | --- |
| `home/dot_local/bin/executable_proton-ssh-load` | Modify | Flag parsing, the prompt, the token/login/cache flow. All login logic stays here. |
| `home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl` | Modify line 23 | Opt the apply path into prompting. One-line change. |
| `tests/helpers.bash` | Modify | Add `run_load_tty` (pty harness) and one stub knob, `PASS_LOGIN_BAD_TOKEN`. |
| `tests/proton-ssh-load.bats` | Modify | All prompt behaviour tests. |
| `tests/restore-secrets.bats` | Modify | Pins that the caller passes `--prompt`. |
| `README.md` | Modify line 16 | The env var becomes optional. |

`dot_config/shell/ssh-agent.sh` is deliberately **not** touched. If a task
suggests editing it, that task is wrong.

---

### Task 1: Argument parsing

Replaces `[ "${1:-}" = "--quiet" ] && quiet=1`, which only inspects `$1`, with a
loop that accepts both flags in any order and rejects anything else.

**Files:**
- Modify: `home/dot_local/bin/executable_proton-ssh-load:7-12`
- Test: `tests/proton-ssh-load.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: two script-level variables, `quiet` (0/1) and `prompt` (0/1), both
  set before `say()` is defined. Later tasks read both.

- [ ] **Step 1: Write the failing tests**

Append to `tests/proton-ssh-load.bats`:

```bash
@test "rejects an unknown option" {
	run env HOME="$HOME" PATH="$BIN:$PATH" sh "$SCRIPT" --nope
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown option: --nope"* ]]
}

@test "accepts the flags in either order" {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		sh "$SCRIPT" --prompt --quiet </dev/null
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		sh "$SCRIPT" --quiet --prompt </dev/null
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise x -- bats --print-output-on-failure --filter 'unknown option|either order' tests/proton-ssh-load.bats`

Expected: FAIL. "rejects an unknown option" gets status 0 instead of 2 (the
current script ignores unknown args). "accepts the flags in either order" fails
on the first invocation, because `--prompt` in `$1` position leaves `quiet=0` and
the "loads keys" path prints output.

- [ ] **Step 3: Implement the loop**

In `home/dot_local/bin/executable_proton-ssh-load`, replace lines 7-12:

```sh
quiet=0
[ "${1:-}" = "--quiet" ] && quiet=1

say() {
	[ "$quiet" = 1 ] || echo "$@"
}
```

with:

```sh
quiet=0
prompt=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	--quiet) quiet=1 ;;
	# Only the apply path passes this. The shell rc must not, or every new
	# terminal with an empty agent would block on the prompt.
	--prompt) prompt=1 ;;
	*)
		echo "proton-ssh-load: unknown option: $1" >&2
		exit 2
		;;
	esac
	shift
done

say() {
	[ "$quiet" = 1 ] || echo "$@"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise x -- bats --print-output-on-failure tests/proton-ssh-load.bats`

Expected: PASS, all tests including the 12 pre-existing ones. Watch
`--quiet suppresses the not-installed message` and
`exits zero when the agent load itself fails, under --quiet` in particular —
both assert empty output and would catch a botched loop.

- [ ] **Step 5: Lint**

Run: `mise run lint`

Expected: clean. If shellcheck flags the `case` indentation, match the existing
file's tab indentation rather than reformatting the file.

- [ ] **Step 6: Commit**

```bash
git add home/dot_local/bin/executable_proton-ssh-load tests/proton-ssh-load.bats
git commit -m "refactor: parse proton-ssh-load options in a loop"
```

---

### Task 2: The pty test harness

The prompt only fires when `[ -t 0 ]`, so testing it needs a pty. `run_load` at
`tests/proton-ssh-load.bats:28` appends `sh "$SCRIPT"` after the env assignments
and therefore cannot pass script flags either — the file already notes this at
lines 119-120. This task adds one helper that solves both.

Verified before writing this plan: `printf 'x\n' | script -qec CMD /dev/null`
gives the child `[ -t 0 ]` true, and `stty -g` / `stty -echo` both work inside
it. No `expect` dependency is needed.

**Files:**
- Modify: `tests/helpers.bash`
- Test: `tests/proton-ssh-load.bats`

**Interfaces:**
- Consumes: `$HOME`, `$STUB_LOG`, `$BIN`, `$SCRIPT` from the bats `setup()`.
- Produces: `run_load_tty <typed-answer> [VAR=val ...] -- [script flags ...]`.
  Sets bats' `$status` and `$output` like `run` does. Tasks 3 and 4 use it.

- [ ] **Step 1: Write the failing test**

Append to `tests/proton-ssh-load.bats`:

```bash
# Guards the harness itself: if script(1) ever stops handing the child a pty,
# every prompt test below would silently pass by never prompting.
@test "the pty harness really presents a terminal" {
	probe="$BATS_TEST_TMPDIR/probe.sh"
	cat >"$probe" <<'EOF'
#!/bin/sh
[ -t 0 ] && echo "harness-tty: yes" || echo "harness-tty: no"
read -r line || true
echo "harness-read: [$line]"
EOF
	SCRIPT="$probe"
	run_load_tty "typed_value"
	[ "$status" -eq 0 ]
	[[ "$output" == *"harness-tty: yes"* ]]
	[[ "$output" == *"harness-read: [typed_value]"* ]]
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise x -- bats --print-output-on-failure --filter 'pty harness' tests/proton-ssh-load.bats`

Expected: FAIL with `run_load_tty: command not found`.

- [ ] **Step 3: Implement the helper**

Append to `tests/helpers.bash`:

```bash
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
```

- [ ] **Step 4: Run it to verify it passes**

Run: `mise x -- bats --print-output-on-failure --filter 'pty harness' tests/proton-ssh-load.bats`

Expected: PASS.

If it fails with `script: command not found`, util-linux is missing — stop and
report rather than substituting a different mechanism, because the choice of
`script(1)` is what avoids adding `expect` as a test dependency.

- [ ] **Step 5: Lint and run the whole suite**

Run: `mise run lint && mise x -- bats --print-output-on-failure tests/`

Expected: clean, all tests pass. `tests/helpers.bash` is in the shellcheck list,
so array syntax errors surface here.

- [ ] **Step 6: Commit**

```bash
git add tests/helpers.bash tests/proton-ssh-load.bats
git commit -m "test: add a pty harness for proton-ssh-load"
```

---

### Task 3: The prompt

**Files:**
- Modify: `home/dot_local/bin/executable_proton-ssh-load:24-60`
- Test: `tests/proton-ssh-load.bats`

**Interfaces:**
- Consumes: `quiet`, `prompt` from Task 1; `run_load_tty` from Task 2.
- Produces: `ask_pat [notice]` — prompts once, assigns the answer to the
  script-level `pat`, returns 0 only if `pat` is non-empty. And
  `try_login <token>` — runs `pass-cli login` with the token in the environment,
  silent, returns its exit status. Task 4 needs neither.

- [ ] **Step 1: Write the failing tests**

Append to `tests/proton-ssh-load.bats`:

```bash
@test "prompts for the token on a terminal and caches it" {
	run_load_tty "pst_typed" PASS_INFO_RC=1 -- --prompt
	[ "$status" -eq 0 ]
	[[ "$output" == *"Proton Pass PAT"* ]]
	grep -q "^login" "$STUB_LOG"
	grep -q "ssh-agent load" "$STUB_LOG"
	[ "$(cat "$PAT_FILE")" = "pst_typed" ]
	# the flag invariant, extended to the typed path
	! grep -q -- "--personal-access-token" "$STUB_LOG"
	! grep -q "pst_typed" "$STUB_LOG"
}

@test "the typed token is cached unreadable to anyone else" {
	run_load_tty "pst_typed" PASS_INFO_RC=1 -- --prompt
	[ "$status" -eq 0 ]
	[ "$(stat -c %a "$PAT_FILE")" = "600" ]
}

# The apply path passes --quiet. A prompt suppressed there is an unexplained
# hang, which is worse than the noise --quiet exists to remove.
@test "the prompt is visible even under --quiet" {
	run_load_tty "pst_typed" PASS_INFO_RC=1 -- --quiet --prompt
	[ "$status" -eq 0 ]
	[[ "$output" == *"Proton Pass PAT"* ]]
}

@test "empty input at the prompt writes no cache" {
	run_load_tty "" PASS_INFO_RC=1 -- --prompt
	[ "$status" -eq 0 ]
	[ ! -f "$PAT_FILE" ]
	[[ "$output" == *"no Proton Pass session"* ]]
	! grep -q "^login" "$STUB_LOG"
}

# This is the whole reason the flag exists: ssh-agent.sh passes bare --quiet
# from dot_zshrc on every new shell with an empty agent.
@test "bare --quiet never prompts, even on a terminal" {
	run_load_tty "pst_typed" PASS_INFO_RC=1 -- --quiet
	[ "$status" -eq 0 ]
	[[ "$output" != *"Proton Pass PAT"* ]]
	[ ! -f "$PAT_FILE" ]
	! grep -q "^login" "$STUB_LOG"
}

# CI, mise run verify and devpod up all apply with stdin closed.
@test "--prompt without a terminal does not prompt" {
	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" PASS_INFO_RC=1 \
		sh "$SCRIPT" --quiet --prompt </dev/null
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ ! -f "$PAT_FILE" ]
	! grep -q "^login" "$STUB_LOG"
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `mise x -- bats --print-output-on-failure --filter 'prompt|typed token' tests/proton-ssh-load.bats`

Expected: FAIL. The prompting tests find no `Proton Pass PAT` text and no
`$PAT_FILE`, because nothing prompts yet. Note that
`bare --quiet never prompts` and `--prompt without a terminal does not prompt`
will **pass already** — they pin behaviour that must not regress.

- [ ] **Step 3: Implement**

In `home/dot_local/bin/executable_proton-ssh-load`, after the existing
`pat_file` assignment (line 25) and before the `if ! pass-cli info` block, add:

```sh
# ask_pat assigns here; declared up front because it is also the flow's
# working variable.
pat=""
asked=0

# Ask for the token on the terminal. Deliberately ignores --quiet: the apply
# path passes it, and a hang with no visible question is worse than noise.
# Refuses without --prompt so the shell rc never blocks a new terminal, and
# without a tty so `chezmoi apply </dev/null` (CI, devpod) never blocks either.
# /dev/tty is readable even when stdin is redirected, so `-t 0` is the gate and
# stdin is what gets read.
ask_pat() {
	[ "$prompt" = 1 ] || return 1
	[ -t 0 ] || return 1
	# One prompt per run: no retry loop.
	[ "$asked" = 0 ] || return 1
	asked=1

	if [ -n "${1:-}" ]; then
		printf '%s\n' "$1" >&2
	fi
	printf 'Proton Pass PAT (Dotfiles vault, item "bootstrap PAT"): ' >&2

	# Echo off around the read, restored on interrupt too — a Ctrl-C here would
	# otherwise leave the terminal with no echo at all.
	stty_save="$(stty -g 2>/dev/null)" || return 1
	trap 'stty "$stty_save" 2>/dev/null; printf "\n" >&2' INT TERM HUP
	stty -echo 2>/dev/null || true
	pat=""
	# read returns non-zero at EOF, which set -e would take as fatal.
	read -r pat || true
	stty "$stty_save" 2>/dev/null || true
	trap - INT TERM HUP
	printf '\n' >&2

	[ -n "$pat" ]
}

# Never as --personal-access-token: a flag value is visible in `ps`.
try_login() {
	PROTON_PASS_PERSONAL_ACCESS_TOKEN="$1" pass-cli login >/dev/null 2>&1
}
```

Then replace the whole body of the `if ! pass-cli info` block (lines 30-60) with:

```sh
if ! pass-cli info >/dev/null 2>&1; then
	pat="${PROTON_PASS_PERSONAL_ACCESS_TOKEN:-}"
	cache_it=1
	if [ -z "$pat" ] && [ -r "$pat_file" ]; then
		pat="$(cat "$pat_file")"
		cache_it=0
	fi

	# Nothing to go on: ask, if this caller is allowed to.
	if [ -z "$pat" ]; then
		if ask_pat; then
			cache_it=1
		fi
	fi

	if [ -z "$pat" ]; then
		say "proton-ssh-load: no Proton Pass session."
		say "proton-ssh-load: run 'pass-cli login', or set"
		say "proton-ssh-load: PROTON_PASS_PERSONAL_ACCESS_TOKEN (Dotfiles vault,"
		say "proton-ssh-load: item 'bootstrap PAT') and run this again."
		exit 0
	fi

	if ! try_login "$pat"; then
		# The token we had was rejected. One more chance on a terminal: this is
		# how a token rotated in the vault heals itself on the next interactive
		# apply. ask_pat prints the notice only when it is actually going to
		# prompt, so the shell-rc path stays silent.
		pat=""
		if ask_pat "proton-ssh-load: that token was rejected." &&
			try_login "$pat"; then
			cache_it=1
		else
			say "proton-ssh-load: could not authenticate to Proton Pass"
			exit 0
		fi
	fi

	# Only after a successful login, so a rejected token never replaces a
	# working cached one.
	if [ "$cache_it" = 1 ]; then
		mkdir -p "$(dirname "$pat_file")"
		(
			umask 077
			printf '%s\n' "$pat" >"$pat_file"
		)
		say "proton-ssh-load: cached the token at ${pat_file#"$HOME"/}"
	fi
	unset pat
fi
```

- [ ] **Step 4: Run the full suite**

Run: `mise x -- bats --print-output-on-failure tests/proton-ssh-load.bats`

Expected: PASS, new and pre-existing. Two pre-existing tests are the ones most
likely to break and both matter:
- `falls back to the cached token when the environment has none` — asserts
  `cached the token` is **absent**, which pins `cache_it=0` surviving the rewrite.
- `a failed authentication does not cache the bad token` — runs without
  `--prompt`, so `ask_pat` must return non-zero and fall through to
  `could not authenticate`.

- [ ] **Step 5: Lint**

Run: `mise run lint`

Expected: clean. The `trap` body is single-quoted on purpose so `$stty_save`
expands when the signal arrives; do not "fix" it to double quotes.

- [ ] **Step 6: Commit**

```bash
git add home/dot_local/bin/executable_proton-ssh-load tests/proton-ssh-load.bats
git commit -m "feat: ask for the Proton PAT on an interactive apply"
```

---

### Task 4: Rejected-token re-prompt

Task 3 wired the re-prompt; this task pins it. It needs one new stub knob,
because the existing `PASS_LOGIN_RC` fails *every* login and cannot express
"this token is stale but the next one is good".

**Files:**
- Modify: `tests/helpers.bash` (stub `login` branch)
- Test: `tests/proton-ssh-load.bats`

**Interfaces:**
- Consumes: `ask_pat` / `try_login` behaviour from Task 3, `run_load_tty` from Task 2.
- Produces: stub knob `PASS_LOGIN_BAD_TOKEN` — when set, `pass-cli login` exits 1
  if the token in the environment equals it, and otherwise falls through to
  `PASS_LOGIN_RC`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/proton-ssh-load.bats`:

```bash
@test "a rejected cached token re-prompts and the new one replaces it" {
	mkdir -p "$(dirname "$PAT_FILE")"
	printf 'pst_stale\n' >"$PAT_FILE"
	run_load_tty "pst_fresh" PASS_INFO_RC=1 PASS_LOGIN_BAD_TOKEN=pst_stale -- --prompt
	[ "$status" -eq 0 ]
	[[ "$output" == *"was rejected"* ]]
	[ "$(cat "$PAT_FILE")" = "pst_fresh" ]
	grep -q "ssh-agent load" "$STUB_LOG"
}

# Stale beats truncated, the same rule restore() follows.
@test "a rejected cached token survives a rejected replacement" {
	mkdir -p "$(dirname "$PAT_FILE")"
	printf 'pst_stale\n' >"$PAT_FILE"
	run_load_tty "pst_also_bad" PASS_INFO_RC=1 PASS_LOGIN_RC=1 -- --prompt
	[ "$status" -eq 0 ]
	[ "$(cat "$PAT_FILE")" = "pst_stale" ]
	[[ "$output" == *"could not authenticate"* ]]
	! grep -q "ssh-agent load" "$STUB_LOG"
}

# The "prompted already?" guard is what bounds this, not the token's source.
@test "a rejected environment token re-prompts too" {
	run_load_tty "pst_fresh" PASS_INFO_RC=1 \
		PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_env_bad \
		PASS_LOGIN_BAD_TOKEN=pst_env_bad -- --prompt
	[ "$status" -eq 0 ]
	[ "$(cat "$PAT_FILE")" = "pst_fresh" ]
}

# Counted through the stub log rather than the prompt text, because the prompt
# is printed without a trailing newline and does not grep by line.
@test "prompts at most once" {
	run_load_tty "pst_bad_typed" PASS_INFO_RC=1 PASS_LOGIN_RC=1 -- --prompt
	[ "$status" -eq 0 ]
	[ "$(grep -c '^login' "$STUB_LOG")" -eq 1 ]
	[ ! -f "$PAT_FILE" ]
	[[ "$output" == *"could not authenticate"* ]]
}

# A rejected cached token must not nag on every new shell.
@test "a rejected token is silent without --prompt" {
	mkdir -p "$(dirname "$PAT_FILE")"
	printf 'pst_stale\n' >"$PAT_FILE"
	run_load_tty "unused" PASS_INFO_RC=1 PASS_LOGIN_RC=1 -- --quiet
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ "$(cat "$PAT_FILE")" = "pst_stale" ]
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `mise x -- bats --print-output-on-failure --filter 'rejected|at most once' tests/proton-ssh-load.bats`

Expected: FAIL. The three `PASS_LOGIN_BAD_TOKEN` tests fail because the stub
ignores the knob, so the stale token logs in fine and no re-prompt happens.
`prompts at most once` and `a rejected token is silent without --prompt` should
pass already, on Task 3's code.

- [ ] **Step 3: Implement the stub knob**

In `tests/helpers.bash`, in the `make_pass_cli_stub` heredoc, replace:

```sh
login)
	exit "${PASS_LOGIN_RC:-0}"
	;;
```

with:

```sh
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
```

Also add the knob to the documentation comment above `make_pass_cli_stub`,
alongside the existing `PASS_LOGIN_RC` line:

```
#   PASS_LOGIN_BAD_TOKEN  a token value that `pass-cli login` rejects; any
#                         other token falls through to PASS_LOGIN_RC
```

- [ ] **Step 4: Run them to verify they pass**

Run: `mise x -- bats --print-output-on-failure tests/`

Expected: PASS, whole suite. `restore-secrets.bats` shares this stub, so a
mistake in the `login` branch shows up there too.

- [ ] **Step 5: Lint**

Run: `mise run lint`

Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add tests/helpers.bash tests/proton-ssh-load.bats
git commit -m "test: pin the rejected-token re-prompt"
```

---

### Task 5: Caller and docs

**Files:**
- Modify: `home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl:23`
- Modify: `README.md:16`
- Test: `tests/restore-secrets.bats`

**Interfaces:**
- Consumes: the `--prompt` flag from Task 1.
- Produces: nothing further.

- [ ] **Step 1: Write the failing test**

Append to `tests/restore-secrets.bats`:

```bash
# The apply path is the one caller that should prompt. ssh-agent.sh must not,
# so this pins which flags cross the boundary.
@test "hands the prompt flag to proton-ssh-load" {
	PSL_LOG="$BATS_TEST_TMPDIR/psl.log"
	cat >"$BIN/proton-ssh-load" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$PSL_LOG"
STUB
	chmod 755 "$BIN/proton-ssh-load"

	# has-proton-session runs `pass-cli info` at render time; it has to come
	# back non-zero here or the rendered script skips the whole branch.
	export PASS_INFO_RC=1 PSL_LOG
	render_template "$TMPL" "$SCRIPT" "$BIN:$PATH"

	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		PSL_LOG="$PSL_LOG" PASS_INFO_RC=1 sh "$SCRIPT" </dev/null
	[ "$status" -eq 0 ]
	grep -q -- "--quiet --prompt" "$PSL_LOG"
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise x -- bats --print-output-on-failure --filter 'prompt flag' tests/restore-secrets.bats`

Expected: FAIL. `$PSL_LOG` contains `--quiet` only.

- [ ] **Step 3: Update the caller**

In `home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl`, change line 23:

```sh
		proton-ssh-load --quiet || true
```

to:

```sh
		proton-ssh-load --quiet --prompt || true
```

And extend the comment above it (line 19) so the reason survives:

```sh
# proton-ssh-load owns the login logic, including the cached token. --prompt is
# what makes an interactive apply ask for the bootstrap PAT instead of quietly
# carrying on without keys; it no-ops without a tty, so CI and devpod are
# unaffected. ssh-agent.sh deliberately does not pass it.
```

- [ ] **Step 4: Run it to verify it passes**

Run: `mise x -- bats --print-output-on-failure tests/restore-secrets.bats`

Expected: PASS, including the pre-existing `stale beats truncated` tests.

- [ ] **Step 5: Update the README**

`README.md:16` currently reads:

```
PROTON_PASS_PERSONAL_ACCESS_TOKEN='pst_…' chezmoi apply   # secrets + ssh keys
```

Replace with:

```
chezmoi apply                                            # asks for the PAT if needed
PROTON_PASS_PERSONAL_ACCESS_TOKEN='pst_…' chezmoi apply   # or supply it up front
```

Check the surrounding lines before editing: if line 16 sits in a fenced block
whose lines are aligned on the `#`, keep that alignment. An interactive apply now
prompts for the token, so the environment form is only needed for a scripted or
piped first run — which is also the case where nothing will ask.

- [ ] **Step 6: Full check**

Run: `mise run check`

Expected: lint, test, secrets, verify and shells all green. `verify` is the
load-bearing one here: it applies into a throwaway HOME with `</dev/null`, which
is exactly the no-tty path, and `mise.toml:54-56` says so explicitly. If
`verify` hangs, the `[ -t 0 ]` gate is wrong — that is the failure this whole
design is built to avoid.

- [ ] **Step 7: Commit and open the PR**

```bash
git add home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl README.md tests/restore-secrets.bats
git commit -m "feat: prompt for the Proton PAT from the apply path"
git push -u origin feat/interactive-proton-pat
gh pr create --fill
gh pr checks --watch
```

---

## Manual verification

The suite cannot prove the real end-to-end path, because it stubs `pass-cli`.
After CI is green, on a host with a live session:

- [ ] `proton-ssh-load --prompt` with a live session: returns without prompting.
- [ ] `mv ~/.config/pass-cli-bootstrap-pat{,.bak}`, `pass-cli logout`, then
  `chezmoi apply` from a terminal: it asks, the typed token is **not** echoed,
  keys land in the agent (`ssh-add -l`), and the cache is recreated 600.
- [ ] Same state, `chezmoi apply </dev/null`: no prompt, no hang, exit 0.
- [ ] Ctrl-C at the prompt: the terminal still echoes afterwards.
- [ ] Open a new terminal with an empty agent: no prompt.
- [ ] Restore `~/.config/pass-cli-bootstrap-pat` from the `.bak` copy.

Then the original symptom, on `mahony`: `devpod up zenith` and confirm the
container has `~/.zshrc` and `~/.local/share/chezmoi`.

## Self-review notes

Spec coverage checked section by section. Every spec requirement maps to a task:
prompt conditions and the caller table → Tasks 1, 3, 5; argument parsing → Task 1;
the prompt mechanics → Task 3; token flow and the one-prompt guard → Tasks 3, 4;
the testing table → Tasks 2, 3, 4, plus the pty risk resolved up front in Task 2;
docs → Task 5.

One spec row needed a home it did not obviously have: "unknown option → exit 2"
is a test-table row, and it landed in Task 1 next to the parsing change it
describes rather than in the later test tasks.
