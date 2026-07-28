# Daily-Friction Tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add atuin (local-only shell history), sesh (tmux/zoxide session picker) and a fixed set of CLI utilities to the dotfiles, wired into zsh, bash and tmux on the host and inside devpod containers.

**Architecture:** Everything is declared in the chezmoi source tree and lands in `$HOME` through `chezmoi apply`. Tools are version-pinned in `dot_config/mise/config.toml` (Renovate bumps them); the one file that is not a mise tool — `bash-preexec.sh` — comes in as a pinned `.chezmoiexternals` entry. Shell integration is added to `dot_zshrc` and `dot_bashrc` as `command -v`-guarded blocks, matching every other tool in those files, so a machine or container missing a tool still gets a working shell.

**Tech Stack:** chezmoi, mise, zsh, bash, tmux, atuin, sesh, fzf, zoxide.

Spec: `docs/superpowers/specs/2026-07-28-daily-friction-tooling-design.md`

## Global Constraints

- Branch is `feat/daily-friction-tooling`. Never commit to `main`. Commit subjects are conventional-commit style, lowercase imperative (`feat: ...`, `fix: ...`, `docs: ...`).
- **Never** edit a chezmoi-managed file in `$HOME`. Edit the source under `/home/ronald/.local/share/chezmoi`, then run `chezmoi apply`.
- Repo-only files must be listed in `.chezmoiignore`. Nothing added by this plan is repo-only except the plan and spec documents, and `/docs` is already ignored.
- Every shell-integration block is guarded (`command -v <tool>` or `[ -r <file> ]`). A missing tool must never break shell startup.
- Exact pinned versions, resolved 2026-07-28 — do not substitute "latest":
  `atuin = "18.17.1"`, `"github:joshmedeski/sesh" = "2.28.0"`, `dust = "1.2.4"`, `duf = "0.9.1"`, `btop = "1.4.7"`, `sd = "1.1.0"`, `jless = "0.9.0"`, `hyperfine = "1.20.0"`, `gping = "1.20.4"`, bash-preexec `0.6.0`.
- Every `.chezmoiexternals` entry needs a `# renovate: datasource=... depName=...` comment on the line above its version variable, and `refreshPeriod = "168h"`.
- Comment style in this repo explains *why*, not *what*, and is wrapped at roughly 80 columns. Match it.
- `mise run check` (lint + secrets + verify) must pass before the PR.

## File Structure

**Created:**
- `.chezmoiexternals/bash-preexec.toml` — pinned fetch of the single-file bash-preexec shim atuin's bash integration needs.
- `dot_config/atuin/config.toml` — atuin settings: sync off, update check off, Up-arrow filtered to the current directory.
- `.chezmoiscripts/run_onchange_after_zz-atuin-import.sh.tmpl` — one-shot import of existing zsh/bash history into a fresh atuin database.

**Modified:**
- `mise.toml` — new `shells` task (interactive-shell smoke check), added to `check`.
- `dot_config/mise/config.toml` — the nine new tool pins.
- `dot_zshrc` — atuin init after the fzf block; `sesh-connect` zle widget on `Ctrl-F`.
- `dot_bashrc` — xterm title functions moved onto bash-preexec's hook arrays; bash-preexec sourced; atuin init; `sesh-connect` on `Ctrl-F`.
- `dot_tmux.conf` — `prefix o` opens the sesh picker in a popup.
- `dot_local/bin/executable_repos-sync` — seed zoxide after a successful clone.
- `README.md` — Packages, Layout and Project-checkouts updates.

---

### Task 1: Interactive-shell smoke check

A broken line in `dot_zshrc` or `dot_bashrc` is invisible to shellcheck (neither file is in the lint list) and invisible to the clean-HOME bootstrap (which never starts a shell). This task adds the check *first*, so every later task has something that fails when it breaks a shell.

**Files:**
- Modify: `mise.toml` (new `[tasks.shells]`, and `[tasks.check]` at the end of the file)

**Interfaces:**
- Consumes: nothing.
- Produces: `mise run shells` — exits 0 when every installed shell starts interactively with no output on stdout or stderr; exits 1 otherwise. Tasks 3, 4 and 6 run it.

- [ ] **Step 1: Write the check task**

Add to `mise.toml`, after `[tasks.verify]` and before `[tasks.secrets-restore]`:

```toml
[tasks.shells]
description = "start each interactive shell and fail on startup noise or errors"
# Neither rc file is in the shellcheck list (they are sourced, not executed, and
# full of shell-specific syntax) and the clean-HOME bootstrap never starts a
# shell — so a typo in an init line ships silently and only shows up the next
# time a terminal is opened. `-i` is the point: the tool integrations this
# guards all live in the interactive path. This reads the *applied* files in
# $HOME, not the source tree, so run `chezmoi apply` first.
run = '''
set -eu
rc=0
# Giving the checked shell a real pty (below, via `script`) has a side effect
# beyond the tty noise it's there to fix: mise's own shell hooks (`eval "$(mise
# activate ...)"` in both rc files) detect that stdout is now a terminal and
# emit an OSC 9;4 progress escape on startup. That's mise reacting to the pty
# this task handed it, not an rc-file regression, so it's silenced the same
# way as the tty noise below — by not producing it in the first place.
export MISE_TERMINAL_PROGRESS=false
for shell in zsh bash; do
	if ! command -v "$shell" >/dev/null 2>&1; then
		echo "skip  $shell (not installed)"
		continue
	fi
	# Both streams are captured: an init line that fails prints to stderr,
	# and one that accidentally echoes prints to stdout. A clean interactive
	# startup says nothing on either.
	#
	# A shell with no controlling terminal on any fd — this task's own
	# subshell, whenever mise itself runs from a context with no pty
	# attached (an agent's tool sandbox, some other headless wrapper) —
	# prints tty-acquisition noise that has nothing to do with the rc
	# files: zsh's fzf integration can't restore the `zle` option on exit,
	# bash can't claim a process group for job control. The whole point of
	# this check is catching rc-file regressions, not tty plumbing, so give
	# the shell a real pty via `script` when one is installed. `-e`
	# (bundled into `-qec`) makes `script` return the wrapped command's own
	# exit code rather than its own, so the non-zero-exit branch below
	# still means what it says. Falls back to the direct, tty-less form
	# when `script` is missing; that fallback can still report tty noise
	# instead of a real rc-file problem.
	if command -v script >/dev/null 2>&1; then
		out="$(script -qec "$shell -ic true" /dev/null 2>&1 </dev/null)" && status=0 || status=$?
	else
		out="$("$shell" -ic true 2>&1 </dev/null)" && status=0 || status=$?
	fi
	if [ "$status" -eq 0 ]; then
		if [ -n "$out" ]; then
			echo "FAIL  $shell started but printed output:" >&2
			printf '%s\n' "$out" >&2
			rc=1
		else
			echo "ok    $shell"
		fi
	else
		echo "FAIL  $shell exited non-zero:" >&2
		printf '%s\n' "$out" >&2
		rc=1
	fi
done
exit "$rc"
'''
```

- [ ] **Step 2: Add it to the aggregate task**

Change the last stanza of `mise.toml` from:

```toml
[tasks.check]
description = "everything CI runs, in one command"
depends = ["lint", "secrets", "verify"]
```

to:

```toml
[tasks.check]
description = "everything CI runs, in one command"
# `shells` is not part of CI — CI has no applied $HOME to start a shell in — but
# it is cheap and catches the one class of breakage the other three miss.
depends = ["lint", "secrets", "verify", "shells"]
```

- [ ] **Step 3: Run it against the unmodified checkout**

Run: `mise run shells`
Expected: `ok    zsh` and `ok    bash`, exit 0.

The check runs each shell under a real pty (via `script`) precisely so that a FAIL here means an actual rc-file regression, not tty-acquisition noise from a headless caller. If it reports FAIL on this unmodified checkout, capture the reported output, fix the offending init line in the chezmoi source (not in `$HOME`), `chezmoi apply`, and re-run until green. Do not proceed to Task 2 with a red baseline. Report what was fixed.

- [ ] **Step 4: Commit**

```bash
git add mise.toml
git commit -m "test: add interactive-shell startup smoke check"
```

---

### Task 2: Pin the utility tools

**Files:**
- Modify: `dot_config/mise/config.toml` (inside `[tools]`)
- Modify: `README.md` (Packages section, the paragraph beginning "Anything that runs in a terminal belongs in mise")

**Interfaces:**
- Consumes: nothing.
- Produces: `dust`, `duf`, `btop`, `sd`, `jless`, `hyperfine`, `gping` on `PATH` via mise shims. No later task depends on them.

- [ ] **Step 1: Add the pins**

In `dot_config/mise/config.toml`, inside `[tools]`, directly after the `yazi`/`superfile` block (they carry the same "wanted inside containers" reasoning):

```toml
# Coreutils replacements. In mise rather than the host package list for the
# same reason as yazi and superfile: a devpod container has no pacman, so
# anything not pinned here simply isn't there.
dust = "1.2.4"       # du, sorted by size
duf = "0.9.1"        # df
btop = "1.4.7"       # top
sd = "1.1.0"         # sed, for the plain-substitution case
jless = "0.9.0"      # JSON pager, next to the pinned jq/yq
hyperfine = "1.20.0" # command benchmarking
gping = "1.20.4"     # ping, plotted
```

- [ ] **Step 2: Install them**

Run: `mise install`
Expected: seven tools install, exit 0.

- [ ] **Step 3: Verify each is actually on PATH**

Run: `for t in dust duf btop sd jless hyperfine gping; do command -v "$t" >/dev/null || echo "MISSING $t"; done; echo done`
Expected: `done`, with no `MISSING` lines.

- [ ] **Step 4: Note the addition in the README**

In `README.md`, in the Packages section, append to the paragraph that begins "Anything that runs in a terminal belongs in mise, even when a distro package exists":

```markdown
The coreutils replacements (`dust`, `duf`, `btop`, `sd`, `jless`) are in mise for
the same reason — a container has no pacman, and reaching for `du` inside one
should not be a worse experience than on the host.
```

- [ ] **Step 5: Commit**

```bash
git add dot_config/mise/config.toml README.md
git commit -m "feat: pin dust, duf, btop, sd, jless, hyperfine and gping"
```

---

### Task 3: atuin, configured and wired into zsh

**Files:**
- Modify: `dot_config/mise/config.toml` (`[tools]`)
- Create: `dot_config/atuin/config.toml`
- Modify: `dot_zshrc` (History section, currently lines 142-152)
- Modify: `README.md` (Layout table)

**Interfaces:**
- Consumes: nothing.
- Produces: `atuin` on `PATH`; `~/.config/atuin/config.toml`; `Ctrl-R` and `Up` bound to atuin in zsh. Task 4 wires the same binary into bash; Task 5 imports history into the database atuin creates at `~/.local/share/atuin/history.db`.

- [ ] **Step 1: Pin atuin**

In `dot_config/mise/config.toml`, inside `[tools]`, next to the other shell-integration tools (`fzf`, `zoxide`, `direnv`):

```toml
# Shell history in SQLite: fuzzy search, exit status, and per-directory
# filtering on the Up arrow. Sync is off (see ~/.config/atuin/config.toml), so
# there is no account and no network call at shell start. 18.17.1 is the newest
# release visible under this repo's minimum_release_age setting.
atuin = "18.17.1"
```

- [ ] **Step 2: Install and confirm the version**

Run: `mise install && atuin --version`
Expected: `atuin 18.17.1`.

- [ ] **Step 3: Write the atuin config**

Create `dot_config/atuin/config.toml`:

```toml
# atuin runs local-only. No account, no sync key in this repo, no network call
# when a shell starts — which also means a devpod container keeps its own
# database and loses it when the container goes. That trade is deliberate: what
# is being bought here is search quality and directory awareness, not history
# that follows the machine.
auto_sync = false

# mise owns the version (dot_config/mise/config.toml) and Renovate bumps it. A
# self-update prompt from atuin itself would be fighting that.
update_check = false

# Up searches only this directory's history; Ctrl-R searches everything. The
# split is the whole reason for the Up binding — reaching for the last command
# run *here* is a different question from searching all history.
filter_mode_shell_up_key_binding = "directory"

# Enter puts the selected command on the command line instead of running it,
# matching what fzf's Ctrl-R widget did before atuin took the binding. A picker
# that executes on Enter turns a misfire into a run command.
enter_accept = false

# Inline rather than fullscreen, so the picker doesn't wipe the scrollback that
# prompted the search in the first place.
style = "compact"
inline_height = 20
```

- [ ] **Step 4: Wire it into zsh**

In `dot_zshrc`, the History section currently ends at the `setopt hist_ignore_space` line (line 152). Append after it, before the `# ~~~ Prompt ~~~` banner:

```zsh
# atuin owns Ctrl-R from here on. Initialisation has to come *after* the fzf
# block above: both bind Ctrl-R explicitly, and whichever runs last wins. fzf
# keeps Ctrl-T (files) and Alt-C (cd). Up is atuin's directory-filtered search,
# configured in ~/.config/atuin/config.toml.
#
# The zsh options above still apply: atuin records into its own database, but
# ~/.zsh_history stays the fallback for any shell where atuin isn't installed.
if command -v atuin > /dev/null ; then
  eval "$(atuin init zsh)"
fi
```

- [ ] **Step 5: Apply and check the shell still starts clean**

Run: `chezmoi apply && mise run shells`
Expected: `ok    zsh`, `ok    bash`, exit 0.

- [ ] **Step 6: Verify the binding actually moved to atuin**

Run: `zsh -ic 'bindkey "^R"; bindkey "^[[A"' </dev/null`
Expected: the `^R` line names an atuin widget (`atuin-search`), **not** `fzf-history-widget`. The Up-arrow line names `atuin-up-search`.

If `^R` still shows fzf, the atuin block landed above the fzf block — move it down.

- [ ] **Step 7: Document it in the Layout table**

In `README.md`, in the Layout table, add a row after the `dot_config/mise/config.toml` row:

```markdown
| `dot_config/atuin/` | atuin: SQLite shell history, sync deliberately off — container history is local and dies with the container |
```

And update the `dot_zshrc` row to mention it, changing:

```markdown
| `dot_zshrc` | zsh: pure prompt, vi mode, mise/direnv, zoxide-backed `cd`, cached completions, autosuggestions + syntax highlighting, aliases |
```

to:

```markdown
| `dot_zshrc` | zsh: pure prompt, vi mode, mise/direnv, zoxide-backed `cd`, atuin history (`Ctrl-R`), cached completions, autosuggestions + syntax highlighting, aliases |
```

(Task 6 adds the sesh picker mention to this same row once sesh actually
lands — see its Step 9. Keeping it out here keeps this task's commit
self-consistent with what it actually ships.)

- [ ] **Step 8: Commit**

```bash
git add dot_config/mise/config.toml dot_config/atuin/config.toml dot_zshrc README.md
git commit -m "feat: add atuin for zsh history search, sync disabled"
```

---

### Task 4: bash-preexec external and bash parity

atuin's bash integration needs `bash-preexec`, and `dot_bashrc` already installs its own `DEBUG` trap plus functions literally named `preexec` and `precmd` for xterm window titles. bash-preexec takes over the `DEBUG` trap and invokes a function named `preexec` if one exists — leaving both in place risks a lost trap or a double invocation. This task converts the title functions to bash-preexec's hook arrays first, then loads the shim.

**Files:**
- Create: `.chezmoiexternals/bash-preexec.toml`
- Modify: `dot_bashrc:150-168` (xterm title block) and the end of the file
- Modify: `README.md` (Layout table, `dot_bashrc` row; Updates section)

**Interfaces:**
- Consumes: `atuin` on `PATH` from Task 3.
- Produces: `~/.bash/bash-preexec.sh`; `Ctrl-R`/`Up` bound to atuin in bash; `preexec_functions` / `precmd_functions` arrays available for any later bash hook.

- [ ] **Step 1: Verify the pinned URL exists before writing the external**

Run: `curl -fsSL -o /dev/null -w '%{http_code}\n' https://raw.githubusercontent.com/rcaloras/bash-preexec/0.6.0/bash-preexec.sh`
Expected: `200`.

- [ ] **Step 2: Write the external**

Create `.chezmoiexternals/bash-preexec.toml`:

```toml
# atuin's bash integration is built on preexec/precmd hooks, which bash has no
# native equivalent of — this shim provides them. It is a single file rather
# than a repo, so `type = "file"` against the tagged raw URL; everything else
# matches the zsh plugin externals next to it.
# renovate: datasource=github-tags depName=rcaloras/bash-preexec
{{ $bashPreexecVersion := "0.6.0" }}
[".bash/bash-preexec.sh"]
type = "file"
url = "https://raw.githubusercontent.com/rcaloras/bash-preexec/{{ $bashPreexecVersion }}/bash-preexec.sh"
refreshPeriod = "168h"
```

- [ ] **Step 3: Apply and confirm the file lands**

Run: `chezmoi apply && head -3 ~/.bash/bash-preexec.sh`
Expected: the file exists and its first lines are bash-preexec's header comment.

- [ ] **Step 4: Move the xterm title functions onto the hook arrays**

In `dot_bashrc`, replace the whole block at lines 150-168 — from `# Check if the terminal is xterm` through the `PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }precmd"` line and its closing `fi` — with:

```bash
# Check if the terminal is xterm
if [[ "$TERM" == "xterm" ]]; then
    # These were plain `preexec`/`precmd` functions driving their own DEBUG
    # trap. bash-preexec (sourced at the end of this file, for atuin) installs
    # *its* DEBUG trap and calls anything named `preexec`, so the old shape
    # would either lose the trap or fire the title twice. Registering renamed
    # functions on bash-preexec's arrays is the supported way to do this, and
    # the arrays are plain variables — appending here, before the shim loads,
    # is fine.
    __title_preexec() {
        local cmd="$1"
        echo -ne "\033]0;${USER}@${HOSTNAME}: ${cmd}\007"
    }

    __title_precmd() {
        echo -ne "\033]0;${USER}@${HOSTNAME}: ${SHELL}\007"
    }

    preexec_functions+=(__title_preexec)
    precmd_functions+=(__title_precmd)
fi
```

Note the argument change: the old `preexec` read `$BASH_COMMAND` (what the `DEBUG` trap exposes); bash-preexec passes the command as `$1`.

- [ ] **Step 5: Source the shim and initialise atuin**

Append to the end of `dot_bashrc`, after the `github-token.sh` line:

```bash
# bash-preexec gives bash the preexec/precmd hooks atuin needs; it is a chezmoi
# external (.chezmoiexternals/bash-preexec.toml). Guarded on the file so a shell
# still starts on a machine that hasn't applied since this change, or in a
# container where the external hasn't been fetched. Sourced this late on
# purpose: it adopts whatever PROMPT_COMMAND already holds, which by now
# includes zoxide's hook.
if [ -r "$HOME/.bash/bash-preexec.sh" ]; then
  . "$HOME/.bash/bash-preexec.sh"
fi

# atuin owns Ctrl-R here too, same as in .zshrc — after the fzf block above,
# since whichever binds last wins. Settings are shared: ~/.config/atuin/config.toml.
if command -v atuin > /dev/null ; then
  eval "$(atuin init bash)"
fi
```

- [ ] **Step 6: Apply and check both shells still start clean**

Run: `chezmoi apply && mise run shells`
Expected: `ok    zsh`, `ok    bash`, exit 0.

- [ ] **Step 7: Verify bash got the binding and the hooks are intact**

Run: `bash -ic 'bind -p 2>/dev/null | grep -i atuin; declare -p preexec_functions' </dev/null`
Expected: at least one binding line mentioning atuin, and `preexec_functions` printed as an array. On a terminal where `$TERM` is not exactly `xterm` the array will not contain `__title_preexec` — that is correct, the title block is `xterm`-only.

- [ ] **Step 8: Update the README**

In the Layout table, change the `dot_bashrc` row to (sesh-free deliberately,
same reasoning as Task 3's `dot_zshrc` row: sesh doesn't exist yet at this
point in the branch — Task 6 adds the mention back once it lands, see its
Step 9):

```markdown
| `dot_bashrc` | bash fallback: hands over to zsh on Omarchy, otherwise mirrors zsh's fzf keys, zoxide-backed `cd`, atuin history, `MANPAGER` and aliases — no prompt or plugins. Kept in step with `dot_zshrc` by hand |
```

In the Updates section, change "Externals (mise binary, zsh plugins) refresh weekly on `chezmoi apply`." to:

```markdown
Externals (mise binary, zsh plugins, bash-preexec) refresh weekly on `chezmoi
apply`.
```

- [ ] **Step 9: Commit**

```bash
git add .chezmoiexternals/bash-preexec.toml dot_bashrc README.md
git commit -m "feat: give bash atuin history via a pinned bash-preexec external"
```

---

### Task 5: One-shot history import

**Files:**
- Create: `.chezmoiscripts/run_onchange_after_zz-atuin-import.sh.tmpl`

**Interfaces:**
- Consumes: `atuin` on `PATH` from Task 3.
- Produces: a populated `~/.local/share/atuin/history.db` on first apply after this lands. Nothing depends on it.

- [ ] **Step 1: Write the script**

Create `.chezmoiscripts/run_onchange_after_zz-atuin-import.sh.tmpl`:

```bash
#!/bin/bash
set -euo pipefail

# Pull existing zsh/bash history into atuin, once. Without this, atuin starts
# empty and the first weeks of Ctrl-R are worse than what it replaced.
#
# The `zz-` name is load-bearing. chezmoi runs scripts in name order, and atuin
# is installed by run_onchange_after_install_packages.sh.tmpl (`mise install`).
# A numeric prefix like `40-` sorts *before* `install_packages`, so on a fresh
# machine this would run before atuin existed, import nothing, and — being
# run_onchange — never run again.
#
# The database check, not chezmoi's run_onchange hash, is what makes this safe
# to re-run: an import over a populated database would duplicate every entry.

# Same PATH fix as the package script: ~/.local/bin isn't on PATH yet during a
# fresh bootstrap, and mise shims live under it.
export PATH="$HOME/.local/bin:$PATH"

if ! command -v atuin > /dev/null 2>&1; then
	echo "atuin-import: atuin not on PATH, skipping" >&2
	exit 0
fi

db="${XDG_DATA_HOME:-$HOME/.local/share}/atuin/history.db"
if [ -e "$db" ]; then
	echo "atuin-import: $db already exists, skipping" >&2
	exit 0
fi

# `atuin import auto` picks an importer from $SHELL, which a script run by
# chezmoi during a devpod bootstrap can't be trusted to have — name both
# shells explicitly instead, each guarded on its history file existing.
if [ -f "$HOME/.zsh_history" ]; then
	echo "atuin-import: importing zsh history" >&2
	atuin import zsh
fi

if [ -f "$HOME/.bash_history" ]; then
	echo "atuin-import: importing bash history" >&2
	atuin import bash
fi
```

- [ ] **Step 2: Lint it**

Run: `mise run lint`
Expected: exit 0. The lint task's `shellcheck .chezmoiscripts/*.sh.tmpl` glob already covers the new file — no change to `mise.toml` is needed.

- [ ] **Step 3: Apply and confirm the import ran**

Run: `chezmoi apply && atuin stats`
Expected: `chezmoi apply` prints the `atuin-import: importing ...` lines, and `atuin stats` reports a non-zero total.

If `atuin stats` reports zero and the apply printed `already exists`, the database was created by a shell start before this script ever ran. That is expected on this machine — atuin has been in use since Task 3. In that case delete it and re-run the script directly to prove the path works:

```bash
rm -f ~/.local/share/atuin/history.db
chezmoi apply --force
atuin stats
```

- [ ] **Step 4: Verify re-running is a no-op**

Run: `chezmoi apply --force 2>&1 | grep atuin-import`
Expected: `atuin-import: ... already exists, skipping`.

- [ ] **Step 5: Commit**

```bash
git add .chezmoiscripts/run_onchange_after_zz-atuin-import.sh.tmpl
git commit -m "feat: import existing shell history into atuin once"
```

---

### Task 6: sesh session picker

**Files:**
- Modify: `dot_config/mise/config.toml` (`[tools]`)
- Modify: `dot_zshrc` (after the `bindkey -v` line, currently line 167)
- Modify: `dot_bashrc` (after the alias block, before the `ssh-agent.sh` line)
- Modify: `dot_tmux.conf`
- Modify: `dot_local/bin/executable_repos-sync:51-58`
- Modify: `README.md` (Project checkouts section, Layout table)

**Interfaces:**
- Consumes: `fzf` and `zoxide`, both already configured in both rc files.
- Produces: `sesh` on `PATH`; a `sesh-connect` shell function bound to `Ctrl-F` in zsh and bash; `prefix o` in tmux.

- [ ] **Step 1: Pin sesh**

In `dot_config/mise/config.toml`, inside `[tools]`, next to `tmux`:

```toml
# One picker over live tmux sessions plus zoxide's frecency list; picking an
# entry attaches or creates. Not in the mise registry, so the github backend
# fetches the release binary directly — same arrangement as sugarrush above.
# Renovate's mise manager understands `github:` pins natively.
"github:joshmedeski/sesh" = "2.28.0"
```

- [ ] **Step 2: Install and smoke-test the binary**

Run: `mise install && sesh --version && sesh list`
Expected: version prints; `sesh list` prints directory/session entries (it reads zoxide, so it is non-empty on this machine).

- [ ] **Step 3: Add the zsh widget**

In `dot_zshrc`, immediately after the `export KEYTIMEOUT=1` line (line 168), before the `# ~~~ Aliases ~~~` banner:

```zsh
# Ctrl-F opens the sesh picker: live tmux sessions and zoxide's directory list
# in one fzf prompt, attaching or creating as needed. Bound here, after
# `bindkey -v` above, and into all three keymaps — vi mode means a binding on
# the emacs keymap alone would be dead.
#
# The stdin/stdout redirection is what lets fzf take over the terminal from
# inside a zle widget; `zle reset-prompt` puts the prompt back afterwards.
if command -v sesh > /dev/null && command -v fzf > /dev/null ; then
  sesh-connect() {
    { exec < /dev/tty; exec <&1; }
    local session
    session="$(sesh list --icons | fzf --ansi --no-sort --prompt='sesh> ')"
    zle reset-prompt > /dev/null 2>&1 || true
    [ -z "$session" ] && return 0
    sesh connect "$session"
  }
  zle -N sesh-connect
  bindkey -M emacs '^F' sesh-connect
  bindkey -M viins '^F' sesh-connect
  bindkey -M vicmd '^F' sesh-connect
fi
```

- [ ] **Step 4: Add the bash equivalent**

In `dot_bashrc`, after the `lsd` alias block and before the `ssh-agent.sh` line:

```bash
# Ctrl-F opens the sesh picker, same as in .zshrc. Bound into both keymaps:
# `set -o vi` at the top of the custom section means an emacs-only binding
# would never fire.
if command -v sesh > /dev/null && command -v fzf > /dev/null ; then
  sesh-connect() {
    local session
    session="$(sesh list --icons | fzf --ansi --no-sort --prompt='sesh> ')"
    [ -z "$session" ] && return 0
    sesh connect "$session"
  }
  bind -m emacs -x '"\C-f": sesh-connect'
  bind -m vi-insert -x '"\C-f": sesh-connect'
fi
```

- [ ] **Step 5: Add the tmux popup binding**

Append to `dot_tmux.conf`:

```tmux
# The sesh picker in a popup — same list as Ctrl-F in the shell. This overrides
# tmux's default `o` (select-pane -t :.+); panes are switched with the
# vim-aware C-h/j/k/l bindings above, so nothing in reach is lost.
bind o display-popup -E -w 60% -h 60% "sesh connect \"\$(sesh list --icons | fzf --ansi --no-sort --prompt='sesh> ')\""
```

- [ ] **Step 6: Seed zoxide from repos-sync**

zoxide is sesh's only source of directories, so a freshly cloned repo nobody has `cd`'d into yet never appears in the picker. In `dot_local/bin/executable_repos-sync`, change:

```bash
	if git clone --quiet "https://$repo.git" "$target"; then
		cloned=$((cloned + 1))
	else
```

to:

```bash
	if git clone --quiet "https://$repo.git" "$target"; then
		cloned=$((cloned + 1))
		# Seed zoxide so a just-cloned checkout shows up in the sesh picker
		# before anyone has cd'd into it — zoxide's database is the only
		# source of directories sesh has.
		if command -v zoxide >/dev/null 2>&1; then
			zoxide add "$target"
		fi
	else
```

Keep the file's existing tab indentation.

- [ ] **Step 7: Lint, apply, and check the shells**

Run: `mise run lint && chezmoi apply && mise run shells`
Expected: exit 0 throughout; `ok    zsh`, `ok    bash`.

- [ ] **Step 8: Verify the bindings exist**

Run: `zsh -ic 'bindkey "^F"' </dev/null; bash -ic 'bind -p 2>/dev/null | grep -F "\\C-f"' </dev/null`
Expected: the zsh line names `sesh-connect`; the bash line binds `\C-f` to `sesh-connect`.

For tmux, reload the applied config in the running server rather than starting a second one with `-f`:

Run: `tmux source-file ~/.tmux.conf && tmux list-keys -T prefix | grep -w o`
Expected: one line, binding `o` to the `display-popup` command. (Outside tmux, `tmux source-file` errors with "no server running" — start one first, or skip to the manual check below.)

Then by hand, in a terminal: `Ctrl-F` opens the picker and attaching works; inside tmux, `prefix o` does the same in a popup.

- [ ] **Step 9: Update the README**

In the Project checkouts section, after the paragraph describing the `host/owner/repo` layout, add:

```markdown
A successful clone is also added to zoxide's database. That is what puts a
brand-new checkout in the `sesh` picker (`Ctrl-F`, or `prefix o` in tmux)
before anyone has ever `cd`'d into it — zoxide is the only source of
directories sesh has.
```

In the Layout table, change the `dot_tmux.conf` row to:

```markdown
| `dot_tmux.conf` | tmux config; `prefix o` opens the sesh session picker |
```

Also in the Layout table, change the `dot_zshrc` row (Task 3 left it
sesh-free deliberately, since sesh didn't exist yet at that point) from:

```markdown
| `dot_zshrc` | zsh: pure prompt, vi mode, mise/direnv, zoxide-backed `cd`, atuin history (`Ctrl-R`), cached completions, autosuggestions + syntax highlighting, aliases |
```

to:

```markdown
| `dot_zshrc` | zsh: pure prompt, vi mode, mise/direnv, zoxide-backed `cd`, atuin history (`Ctrl-R`), sesh picker (`Ctrl-F`), cached completions, autosuggestions + syntax highlighting, aliases |
```

Also in the Layout table, change the `dot_bashrc` row (Task 4 left it
sesh-free deliberately, for the same reason) from:

```markdown
| `dot_bashrc` | bash fallback: hands over to zsh on Omarchy, otherwise mirrors zsh's fzf keys, zoxide-backed `cd`, atuin history, `MANPAGER` and aliases — no prompt or plugins. Kept in step with `dot_zshrc` by hand |
```

to:

```markdown
| `dot_bashrc` | bash fallback: hands over to zsh on Omarchy, otherwise mirrors zsh's fzf keys, zoxide-backed `cd`, atuin history, sesh picker, `MANPAGER` and aliases — no prompt or plugins. Kept in step with `dot_zshrc` by hand |
```

- [ ] **Step 10: Commit**

```bash
git add dot_config/mise/config.toml dot_zshrc dot_bashrc dot_tmux.conf dot_local/bin/executable_repos-sync README.md
git commit -m "feat: add sesh session picker on ctrl-f and tmux prefix o"
```

---

### Task 7: Keybinding documentation and full verification

**Files:**
- Modify: `README.md` (new subsection under Packages)

**Interfaces:**
- Consumes: everything above.
- Produces: a merged PR.

- [ ] **Step 1: Document the keybindings**

In `README.md`, add a new subsection at the end of the Packages section, immediately before `## Updates`:

```markdown
### Shell keybindings

Both shells get the same set, so a machine where zsh isn't the login shell yet
behaves the same:

| Key | Does |
| --- | --- |
| `Ctrl-R` | atuin history search, all directories |
| `Up` | atuin history search, this directory only |
| `Ctrl-T` | fzf file picker |
| `Alt-C` | fzf directory picker |
| `Ctrl-F` | sesh picker: tmux sessions + zoxide directories |
| `prefix o` | the same sesh picker, in a tmux popup |

`Ctrl-R` used to be fzf's. Both tools bind it explicitly, so the one initialised
last in the rc file wins — atuin's block sits below fzf's in both files, and
moving it breaks the binding silently.

atuin history is **local to each machine and each container**: sync is off, so a
rebuilt devpod container starts with an empty database.
```

- [ ] **Step 2: Run the full check**

Run: `mise run check`
Expected: lint, gitleaks, the clean-HOME bootstrap and the shell smoke check all pass.

The clean-HOME run installs every pinned tool from scratch, so it is the real test that the nine new pins resolve on a machine with nothing cached.

- [ ] **Step 3: Confirm no plaintext secret slipped in**

Run: `git diff main --stat`
Expected: only the files this plan names. No `.age` blob was added or changed by this work; `mise run check` already ran gitleaks over history.

- [ ] **Step 4: Commit and open the PR**

```bash
git add README.md
git commit -m "docs: document the new shell keybindings"
git push -u origin feat/daily-friction-tooling
gh pr create --fill
```

- [ ] **Step 5: Wait for CI**

Run: `gh pr checks --watch`
Expected: all checks green. CI covers lint, gitleaks and the clean-HOME bootstrap; it does not run `shells` (there is no applied `$HOME` to start a shell in), which is why Step 2 ran locally.
