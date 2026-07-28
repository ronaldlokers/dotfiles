# Television Pickers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the `Ctrl-T`, `Alt-C` and sesh pickers from fzf to television, vendor a curated channel set into the repo, and add `Ctrl-G` for the channel menu.

**Architecture:** `television` is pinned in mise like every other CLI tool. Channel definitions are plain TOML files committed under `dot_config/television/cable/`, copied from upstream at a fixed commit rather than fetched at runtime, so a container and the host see the same set. Shell integration is hand-written `command -v`-guarded widgets in `dot_zshrc` and `dot_bashrc`, matching the existing style — `tv init` provides completions only, not bindings.

**Tech Stack:** chezmoi, mise, television 0.15.9, zsh, bash, tmux, sesh, fzf (retained for fzf-tab).

Spec: `docs/superpowers/specs/2026-07-28-television-pickers-design.md`

## Global Constraints

- Branch is `feat/television-pickers`. Never commit to `main`. Conventional-commit subjects, lowercase imperative.
- **Never** edit a chezmoi-managed file in `$HOME` as a source of truth. Edit the source tree under `/home/ronald/.local/share/chezmoi`, then `chezmoi apply`.
- Exact pin, no substitution: `television = "0.15.9"`, in `dot_config/mise/config.toml` — never the repo-root `mise.toml`, which is tooling for working on the repo.
- Channels are copied from upstream commit `3e74ba4` (2026-07-25). Fetch by that commit SHA, never from `main`, or the set stops being reproducible.
- Every shell-integration block is guarded (`command -v tv`). A missing tool must never break shell startup.
- Bindings must reach every live keymap: zsh runs `bindkey -v`, so `emacs`, `viins` and `vicmd`; bash runs `set -o vi`, so `emacs` and `vi-insert`.
- fzf stays pinned. `fzf-tab` requires the binary. Only fzf's *widgets* are removed.
- `Ctrl-R` belongs to atuin and is out of scope. Do not vendor `zsh-history` or `bash-history`.
- Comment style explains *why*, not *what*, wrapped near 80 columns, in a block above the code — not trailing the line.
- `mise run check` must pass before the PR.

## File Structure

**Created:**
- `dot_config/television/cable/*.toml` — 30 vendored channel definitions.
- `dot_config/television/config.toml` — only the settings this setup deviates on.

**Modified:**
- `dot_config/mise/config.toml` — the television pin.
- `dot_zshrc` — remove the `fzf --zsh` block; add four tv widgets.
- `dot_bashrc` — remove the `fzf --bash` block; add four tv widgets.
- `dot_tmux.conf` — `prefix o` runs `tv sesh`.
- `README.md` — keybindings table, Layout table, host-only channel note.

---

### Task 1: Pin television and vendor the channel set

**Files:**
- Modify: `dot_config/mise/config.toml`
- Create: `dot_config/television/cable/` (30 files)
- Create: `dot_config/television/config.toml`

**Interfaces:**
- Consumes: nothing.
- Produces: `tv` on PATH; `tv list-channels` printing the 30 vendored names. Tasks 2-4 bind widgets that call `tv files`, `tv dirs`, `tv sesh` and `tv channels`.

- [ ] **Step 1: Pin the tool**

In `dot_config/mise/config.toml`, inside `[tools]`, next to the other shell-integration tools (`fzf`, `zoxide`, `atuin`, `sesh`):

```toml
# Channel-based fuzzy finder. Takes over the Ctrl-T, Alt-C and sesh pickers
# from fzf, and adds one key (Ctrl-G) onto every vendored channel — git
# branches, k8s pods, systemd units. fzf stays pinned below regardless:
# fzf-tab, the zsh completion menu, needs the binary.
television = "0.15.9"
```

- [ ] **Step 2: Install and confirm**

Run: `mise install && tv --version`
Expected: `television 0.15.9`.

- [ ] **Step 3: Vendor the channels**

Fetch each channel from the pinned commit. Run from the repo root:

```bash
mkdir -p dot_config/television/cable
REF=3e74ba4
BASE="https://raw.githubusercontent.com/alexpasmantier/television/$REF/cable/unix"
for c in files dirs zoxide sesh tmux-sessions tmux-windows channels \
         git-branch git-log git-stash git-worktrees git-repos gh-prs gh-issues \
         k8s-contexts k8s-pods k8s-services k8s-deployments \
         pacman-packages systemd-units ports procs mounts \
         man-pages tldr env path alias docker-containers docker-images; do
	curl -fsSL "$BASE/$c.toml" -o "dot_config/television/cable/$c.toml" ||
		echo "FAILED: $c" >&2
done
ls dot_config/television/cable | wc -l
```

Expected: `30`, and no `FAILED:` lines. If any file fails, stop and report — a silently missing channel is worse than a failed task.

- [ ] **Step 4: Verify every file is a real channel, not an error page**

Run: `head -2 dot_config/television/cable/*.toml | grep -c '\[metadata\]'`
Expected: `30`.

- [ ] **Step 5: Fix the alias channel's source command**

Upstream's `alias.toml` sources from `$SHELL -ic 'alias'`, which starts a *full* interactive shell — mise, atuin, tv, zoxide, every plugin, and on this host bash's omarchy handoff exec'ing zsh — just to print a list of aliases.

Replace the `[source]` and `[preview]` commands in `dot_config/television/cable/alias.toml` so they read the alias *definitions* out of the rc files directly, with no shell started at all. The aliases in this setup live in three places — `~/.zshrc`, `~/.bashrc`, and omarchy's `/usr/share/omarchy-zsh/shell/aliases` on the host:

```toml
# Deviates from upstream, which sources this from `$SHELL -ic 'alias'`. Here
# that starts a *full* interactive shell — mise, atuin, tv, zoxide, every
# plugin, and bash's omarchy handoff exec'ing zsh — just to print a list. The
# definitions are in the rc files already, so read them.
[source]
command = "grep -hE '^[[:space:]]*alias ' $HOME/.zshrc $HOME/.bashrc /usr/share/omarchy-zsh/shell/aliases 2>/dev/null | sed -E 's/^[[:space:]]*alias //' | sort -u"
output = "{split:=:0}"
```

Give `[preview]` the matching treatment — it has the same `$SHELL -ic 'alias'` problem. The `2>/dev/null` matters: the omarchy file does not exist inside a container, and the channel must still list the other two there.

Run: `tv alias --take-1 --input git`
Expected: an alias line, printed immediately — no perceptible shell-startup delay.

If this produces nothing, do not paper over it: report what the source command actually printed.

- [ ] **Step 6: Write the config file**

Create `dot_config/television/config.toml` holding only what this setup deviates on, each line with a WHY comment. tv's shipped default (`~/.config/television/config.toml`, 7.3K) is almost entirely commented-out defaults — read it for key names, commit nothing that merely restates a default.

The cable directory needs no setting: tv already resolves `$XDG_CONFIG_HOME/television/cable`, which is exactly where chezmoi puts the vendored files (verified — there is no cable-dir key in the default config; `--cable-dir` is a CLI flag only).

If, after reading the default, this setup deviates on nothing, write no config file at all and say so in the report. An empty file committed for symmetry is worse than none: it implies settings live there that do not.

- [ ] **Step 7: Apply and confirm the channels are visible**

Run: `chezmoi apply && tv list-channels | wc -l`
Expected: `30`.

Note this directory is co-owned — `tv update-channels` writes into it. Confirm `chezmoi status` afterwards does not show the directory as perpetually modified; if it does, apply the co-ownership pattern from commit `339a033` and record what you did.

- [ ] **Step 8: Commit**

```bash
git add dot_config/mise/config.toml dot_config/television
git commit -m "feat: pin television and vendor a curated channel set"
```

---

### Task 2: zsh pickers

**Files:**
- Modify: `dot_zshrc` — remove the `fzf --zsh` block (currently lines 111-123); remove the sesh widget (currently lines 194-207); add the tv widgets.

**Interfaces:**
- Consumes: `tv` and the vendored channels from Task 1.
- Produces: `Ctrl-T`, `Alt-C`, `Ctrl-F`, `Ctrl-G` bound in zsh. Task 3 mirrors these in bash.

- [ ] **Step 1: Remove the fzf widget block**

Delete this block from `dot_zshrc` entirely:

```zsh
if command -v fzf > /dev/null ; then
  source <(fzf --zsh)

  if command -v fd > /dev/null ; then
    export FZF_DEFAULT_COMMAND="fd --type f --hidden --exclude .git"
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    export FZF_ALT_C_COMMAND="fd --type d --hidden --exclude .git"
  fi

  if command -v bat > /dev/null ; then
    export FZF_CTRL_T_OPTS="--preview 'bat --color=always --style=numbers --line-range=:200 {}'"
  fi
fi
```

and replace it with:

```zsh
# fzf's own widgets are gone: atuin owns Ctrl-R and tv owns Ctrl-T and Alt-C
# (see the tv block further down), which left `source <(fzf --zsh)` binding
# nothing. fzf itself stays installed — fzf-tab, the completion menu loaded at
# the bottom of this file, is built on it and reads FZF_DEFAULT_COMMAND.
if command -v fzf > /dev/null && command -v fd > /dev/null ; then
  export FZF_DEFAULT_COMMAND="fd --type f --hidden --exclude .git"
fi
```

- [ ] **Step 2: Replace the sesh widget with the tv widgets**

Delete the whole `if command -v sesh > /dev/null && command -v fzf > /dev/null ; then ... fi` block (its comment block above it too) and put this in its place — same location, after `bindkey -v`:

```zsh
# tv's pickers. All four are bound into every keymap that is actually live:
# `bindkey -v` above means a binding on the emacs keymap alone would be dead
# in insert mode, which is where these get used.
#
# `tv init zsh` is deliberately not sourced — in 0.15.9 it emits completions
# only, no bindings, so the widgets below are the whole integration.
if command -v tv > /dev/null ; then
  # Ctrl-T inserts a path at the cursor. `${(q-)…}` quotes it the way zsh
  # would have to for the path to survive a space in a directory name.
  tv-files-widget() {
    local selected
    selected="$(tv files)" || return 0
    [ -z "$selected" ] && return 0
    LBUFFER="${LBUFFER}${(q-)selected} "
    zle reset-prompt
  }

  # Alt-C changes directory in *this* shell. The dirs channel ships an
  # `[actions.cd]` running `cd {} && $SHELL`, which would strand the user in a
  # nested shell — so the widget takes the printed path and cds itself.
  tv-dirs-widget() {
    local dir
    dir="$(tv dirs)" || return 0
    [ -z "$dir" ] && return 0
    cd "$dir" || return 0
    zle reset-prompt
  }

  # Ctrl-F is the sesh picker. Unlike the fzf pipeline it replaces, the
  # channel's own `enter` action runs `sesh connect`, so there is nothing to
  # capture here. Ctrl-S cycles sources (all/tmux/configs/zoxide/dirs) and
  # Ctrl-D kills the highlighted session and reloads — both from the channel.
  tv-sesh-widget() {
    tv sesh
    zle reset-prompt
  }

  # Ctrl-G opens the channel menu: pick a channel, then pick inside it. Every
  # channel vendored later is reachable through this without a new binding.
  tv-channels-widget() {
    tv channels
    zle reset-prompt
  }

  zle -N tv-files-widget
  zle -N tv-dirs-widget
  zle -N tv-sesh-widget
  zle -N tv-channels-widget

  for keymap in emacs viins vicmd; do
    bindkey -M "$keymap" '^T' tv-files-widget
    bindkey -M "$keymap" '^[c' tv-dirs-widget
    bindkey -M "$keymap" '^F' tv-sesh-widget
    bindkey -M "$keymap" '^G' tv-channels-widget
  done
  unset keymap
fi
```

- [ ] **Step 3: Apply and check the shell still starts clean**

Run: `chezmoi apply && mise run shells`
Expected: `ok    zsh`, `ok    bash`, exit 0.

- [ ] **Step 4: Verify the bindings landed in every keymap**

Run: `zsh -ic 'for k in emacs viins vicmd; do bindkey -M $k "^T"; bindkey -M $k "^[c"; bindkey -M $k "^F"; bindkey -M $k "^G"; done' </dev/null`
Expected: twelve lines, each naming a `tv-*-widget`. No line may name `fzf-file-widget` or `fzf-cd-widget`.

- [ ] **Step 5: Verify Ctrl-T actually inserts a path**

A binding that exists is not a binding that works. Drive a real keypress through a pty, the way PR #91's sesh binding was verified: create a scratch directory with a known file, run an interactive zsh in `script -qec`, send `Ctrl-T`, a query matching the file, `Enter`, then a newline, and confirm the resulting command line contained the path.

Put the transcript in your report. If the keypress cannot be driven, say so explicitly rather than reporting the binding as verified.

- [ ] **Step 6: Verify Alt-C changes this shell's directory**

Same method: send `Alt-C`, select a known subdirectory, then run `pwd` and confirm it changed *and* that the shell is the same one (no nested `$SHELL`). Check `$SHLVL` is unchanged.

- [ ] **Step 7: Commit**

```bash
git add dot_zshrc
git commit -m "feat: move the zsh pickers from fzf to television"
```

---

### Task 3: bash pickers

**Files:**
- Modify: `dot_bashrc` — remove the `fzf --bash` block (currently lines 182-186); remove the sesh widget (currently lines 248-262); add the tv widgets.

**Interfaces:**
- Consumes: `tv` and the vendored channels from Task 1.
- Produces: the same four bindings in bash, mirroring Task 2.

- [ ] **Step 1: Remove the fzf widget block**

Delete:

```bash
# fzf keybindings (fuzzy Ctrl-R etc.), same as in .zshrc, so bash
# stays usable on machines where zsh isn't the login shell yet
if command -v fzf > /dev/null ; then
  eval "$(fzf --bash)"
fi
```

Nothing replaces it: fzf-tab is zsh-only, so after this change bash uses fzf for nothing at all. The binary stays pinned for zsh's sake.

- [ ] **Step 2: Replace the sesh widget with the tv widgets**

Delete the `if command -v sesh > /dev/null && command -v fzf > /dev/null ; then ... fi` block and its comment, and put this in its place:

```bash
# tv's pickers, mirroring .zshrc — see the comments there. Bound into both
# keymaps because `set -o vi` at the top of this section means an emacs-only
# binding would never fire.
if command -v tv > /dev/null ; then
  # Ctrl-T splices the selection into the line at the cursor. bash has no zle,
  # so readline's own READLINE_LINE/READLINE_POINT are the equivalent.
  tv-files-widget() {
    local selected
    selected="$(tv files)" || return 0
    [ -z "$selected" ] && return 0
    READLINE_LINE="${READLINE_LINE:0:$READLINE_POINT}${selected}${READLINE_LINE:$READLINE_POINT}"
    READLINE_POINT=$((READLINE_POINT + ${#selected}))
  }

  # Alt-C cds in this shell rather than the nested one the dirs channel's own
  # cd action would spawn.
  tv-dirs-widget() {
    local dir
    dir="$(tv dirs)" || return 0
    [ -z "$dir" ] && return 0
    cd "$dir" || return 0
  }

  tv-sesh-widget() { tv sesh; }
  tv-channels-widget() { tv channels; }

  for keymap in emacs vi-insert; do
    bind -m "$keymap" -x '"\C-t": tv-files-widget'
    bind -m "$keymap" -x '"\ec": tv-dirs-widget'
    bind -m "$keymap" -x '"\C-f": tv-sesh-widget'
    bind -m "$keymap" -x '"\C-g": tv-channels-widget'
  done
  unset keymap
fi
```

- [ ] **Step 3: Apply and check both shells**

Run: `chezmoi apply && mise run shells`
Expected: `ok    zsh`, `ok    bash`, exit 0.

- [ ] **Step 4: Verify the bindings exist**

Run: `bash -ic 'bind -m emacs -X; bind -m vi-insert -X' </dev/null | grep -E "tv-(files|dirs|sesh|channels)-widget"`
Expected: eight lines. Note `bind -p` will NOT show these — they are function bindings, visible only through `bind -X`.

- [ ] **Step 5: Verify Ctrl-T inserts and Alt-C cds**

Same pty method as Task 2, Steps 5-6, but with `bash -i`. Confirm `$SHLVL` is unchanged after Alt-C. Transcripts in the report.

- [ ] **Step 6: Commit**

```bash
git add dot_bashrc
git commit -m "feat: move the bash pickers from fzf to television"
```

---

### Task 4: tmux popup

**Files:**
- Modify: `dot_tmux.conf` — the `prefix o` binding inside the existing `if-shell` guard.

**Interfaces:**
- Consumes: `tv` and the `sesh` channel from Task 1.
- Produces: `prefix o` opening `tv sesh` in a popup.

- [ ] **Step 1: Replace the binding**

The current block guards on sesh and runs a long nested-quoted fzf pipeline. Replace the whole `if-shell` block with:

```tmux
# The sesh picker in a popup — the same channel Ctrl-F opens in the shell, so
# Ctrl-S (cycle sources) and Ctrl-D (kill + reload) work here too. Guarded on
# tv rather than sesh: without tv there is no picker to open, and `o` is left
# at tmux's own default (select-pane -t :.+).
if-shell "command -v tv > /dev/null 2>&1" {
    bind o display-popup -E -w 60% -h 60% "tv sesh"
}
```

The nested quoting that made the old binding fragile is gone with the pipeline — there is nothing left to escape.

- [ ] **Step 2: Verify tmux parses it**

Run: `chezmoi apply && tmux source-file ~/.tmux.conf && tmux list-keys -T prefix | grep -E '^bind-key +-T prefix +o '`
Expected: one line binding `o` to `display-popup -E ... "tv sesh"`.

- [ ] **Step 3: Verify the popup runs the picker**

Create a throwaway detached session, invoke the popup's command directly against a real attached client (the technique used when the sesh popup was first added — `display-popup` with the same command string, driven under a `script`-allocated pty), and confirm `tv` starts with the sesh channel. Report what you ran.

- [ ] **Step 4: Commit**

```bash
git add dot_tmux.conf
git commit -m "feat: open the sesh channel from the tmux popup"
```

---

### Task 5: Documentation and full verification

**Files:**
- Modify: `README.md` — keybindings table, Layout table, host-only channel note.

**Interfaces:**
- Consumes: everything above.
- Produces: a branch ready for review.

- [ ] **Step 1: Update the keybindings table**

In `README.md`'s "Shell keybindings" section, the table currently reads:

```markdown
| `Ctrl-R` | atuin history search, all directories |
| `Up` | atuin history search, this directory only |
| `Ctrl-T` | fzf file picker |
| `Alt-C` | fzf directory picker |
| `Ctrl-F` | sesh picker: tmux sessions + zoxide directories |
| `prefix o` | the same sesh picker, in a tmux popup |
| `Ctrl-X` | *inside* the picker: kill the highlighted session and redraw |
```

Replace those rows with:

```markdown
| `Ctrl-R` | atuin history search, all directories |
| `Up` | atuin history search, this directory only |
| `Ctrl-T` | tv file picker |
| `Alt-C` | tv directory picker, cds this shell |
| `Ctrl-F` | tv sesh channel: tmux sessions + zoxide directories |
| `prefix o` | the same sesh channel, in a tmux popup |
| `Ctrl-G` | tv channel menu — every vendored channel, one keystroke |
| `Ctrl-S` | *inside* the sesh channel: cycle source (all/tmux/configs/zoxide/dirs) |
| `Ctrl-D` | *inside* the sesh channel: kill the highlighted session and reload |
```

Then fix the paragraph below the table: it explains that `Ctrl-R` used to be fzf's and that init order decides the winner. That is still true of atuin, but the sentence sits next to rows that no longer mention fzf — reword it so it describes what ships now, and add that fzf remains installed solely for fzf-tab.

- [ ] **Step 2: Update the Layout table**

Add a row after the `dot_config/atuin/` row:

```markdown
| `dot_config/television/` | television: vendored channel definitions (`cable/`) and the settings that deviate from tv's defaults |
```

And update the `dot_zshrc`, `dot_bashrc` and `dot_tmux.conf` rows, which currently name the sesh picker and fzf keys, to name tv instead. Read each row and change only the picker wording — leave the rest.

- [ ] **Step 3: Document which channels are inert where**

Add a short paragraph to the Packages section, after the coreutils sentence:

```markdown
tv's channels are vendored in `dot_config/television/cable/` rather than pulled
by `tv update-channels`, so the host and a container see the same set. Several
of them are host-only in practice: `pacman-packages`, `systemd-units`, the
`docker-*` pair and `tldr` have nothing to list inside a devpod container, and
the `k8s-*` channels need a `kubectl` on PATH, which comes from a project's own
`mise.toml` rather than the global pin. An empty channel there is the tool
missing, not the channel broken.
```

- [ ] **Step 4: Check no stale Ctrl-X reference survives**

Run: `grep -rn "Ctrl-X\|ctrl-x" README.md dot_zshrc dot_bashrc dot_tmux.conf`
Expected: no output. The binding was removed in Tasks 2-4; a surviving mention documents something that no longer exists.

(The `docs/superpowers/` spec and plan for the earlier work describe `Ctrl-X` as it was at the time. Those are historical records — leave them alone.)

- [ ] **Step 5: Run the full check**

Run: `mise run check`
Expected: exit 0. The clean-HOME bootstrap installs television from scratch, which is the real test that the pin resolves on a machine with nothing cached.

- [ ] **Step 6: Confirm the diff's scope**

Run: `git diff main --stat`
Expected: only the files this plan names, plus the 30 vendored channel TOMLs. No `.age` blob.

- [ ] **Step 7: Commit**

```bash
git add README.md
git commit -m "docs: document the television pickers and vendored channels"
```

Stop here. The push and the PR happen after a whole-branch review, not as part of this task.
