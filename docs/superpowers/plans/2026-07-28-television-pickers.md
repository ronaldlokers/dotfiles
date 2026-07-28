# Television Pickers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace fzf's `Ctrl-T` file widget with a television channel menu, move `Alt-C` and the sesh picker onto television, and install a curated channel set as a pinned archive external.

**Architecture:** `television` is pinned in mise like every other CLI tool. Channel definitions arrive as a `.chezmoiexternals` archive pinned to upstream tag `0.15.9` with an `include` list, so Renovate's existing custom manager bumps them; one channel that needs local changes ships as a normal managed file inside the same directory. Shell integration is hand-written `command -v`-guarded widgets — `tv init` emits completions only, not bindings.

**Tech Stack:** chezmoi, mise, television 0.15.9, zsh, bash, tmux, sesh, fzf (retained for fzf-tab).

Spec: `docs/superpowers/specs/2026-07-28-television-pickers-design.md`

## Global Constraints

- Branch is `feat/television-pickers`. Never commit to `main`. Conventional-commit subjects, lowercase imperative.
- **Never** edit a chezmoi-managed file in `$HOME` as a source of truth. Edit the source tree under `/home/ronald/.local/share/chezmoi`, then `chezmoi apply`.
- Exact pin, no substitution: `television = "0.15.9"` in `dot_config/mise/config.toml` — never the repo-root `mise.toml`, which is tooling for working on the repo.
- Channels come from upstream tag `0.15.9`. The external needs a `# renovate: datasource=github-tags depName=alexpasmantier/television` comment above its version variable and `refreshPeriod = "168h"`, or the repo's custom manager will not track it. Upstream tags carry **no** `v` prefix.
- Every shell-integration block is guarded (`command -v tv`). A missing tool must never break shell startup.
- Bindings must reach every live keymap: zsh runs `bindkey -v`, so `emacs`, `viins` and `vicmd`; bash runs `set -o vi`, so `emacs` and `vi-insert`.
- fzf stays pinned. `fzf-tab` requires the binary. Only fzf's *widgets* are removed.
- `Ctrl-R` belongs to atuin and is out of scope. Do not include `zsh-history` or `bash-history`.
- Comment style explains *why*, not *what*, wrapped near 80 columns, in a block above the code.
- `mise run check` must pass before the PR.

## Established facts

These were verified against the real binary and chezmoi 2.70.5 while writing this plan. Do not re-derive them; do not design around contradicting them.

1. **tv captures cleanly.** `sel="$(tv files)"` returns the selection — the TUI goes to `/dev/tty`, the result to stdout.
2. **A nested channel launch does NOT.** `sel="$(tv channels)"`, picking `files` and then a file, returns empty: the meta-channel's `enter` action runs `tv {}` in `execute` mode, and that inner picker writes its selection to the terminal. Confirmed by pty transcript — the filename appeared on screen, the capture was `[]`. **This is why the menu is built from two `tv` calls in our own widget** rather than by binding a key to `tv channels`.
3. **Two sequential calls work.** `ch="$(tv list-channels | tv)"` then `out="$(tv "$ch")"` captured `files` and then `UNIQUEFILE.txt`.
4. **A managed file survives inside an external's directory.** A managed `alias.toml` inside a `type = "archive"` external's target survived both the initial apply and `chezmoi apply --refresh-externals`.
5. **`Ctrl-T` is free to take.** It is fzf's today and nothing else claims it. `Ctrl-G` was rejected — `send-break` in zsh's emacs keymap, `list-expand` in `viins` and `vicmd`. `Ctrl-Space` is the tmux prefix on this machine.

## File Structure

**Created:**
- `.chezmoiexternals/tv-channels.toml` — pinned archive external selecting 29 channels.
- `dot_config/television/cable/alias.toml` — the one locally-modified channel.
- `dot_config/television/config.toml` — only if this setup genuinely deviates from tv's defaults.

**Modified:**
- `dot_config/mise/config.toml` — the television pin.
- `dot_zshrc` — remove the `fzf --zsh` block; add three tv widgets.
- `dot_bashrc` — remove the `fzf --bash` block; add three tv widgets.
- `dot_tmux.conf` — `prefix o` runs `tv sesh`.
- `README.md` — keybindings table, Layout table, host-only channel note.

---

### Task 1: Pin television and install the channel set

**Files:**
- Modify: `dot_config/mise/config.toml`
- Create: `.chezmoiexternals/tv-channels.toml`
- Create: `dot_config/television/cable/alias.toml`
- Create (conditionally): `dot_config/television/config.toml`

**Interfaces:**
- Consumes: nothing.
- Produces: `tv` on PATH, 29 files in `~/.config/television/cable/`, and `tv list-channels` printing **32** names. Tasks 2-4 bind widgets calling `tv list-channels`, `tv <channel>`, `tv dirs` and `tv sesh`.

  The 32 is not a miscount. tv compiles 10 default channels into the binary and merges them with the cable directory, a same-named file overriding a default. The curated set shadows 7 of those 10; `bash-history`, `git-diff` and `text` have no counterpart in the include list and therefore always appear. Only a same-named cable file can shadow a built-in — there is no suppression mechanism — so the Ctrl-T menu will list all three. `git-diff` and `text` are useful and cost nothing; `bash-history` is redundant beside atuin but harmless, and reads `~/.bash_history`, which is a partial record under this setup's `HISTCONTROL`. Accepted and documented in Task 5, not filtered.

- [ ] **Step 1: Pin the tool**

In `dot_config/mise/config.toml`, inside `[tools]`, next to the other shell-integration tools (`fzf`, `zoxide`, `atuin`, `sesh`):

```toml
# Channel-based fuzzy finder. Takes Ctrl-T, Alt-C and the sesh picker off fzf,
# and puts every channel — git branches, k8s pods, systemd units — one
# keystroke away. fzf stays pinned regardless: fzf-tab, the zsh completion
# menu loaded from dot_zshrc, is built on it.
television = "0.15.9"
```

- [ ] **Step 2: Install and confirm**

Run: `mise install && tv --version`
Expected: `television 0.15.9`.

- [ ] **Step 3: Write the channel external**

Create `.chezmoiexternals/tv-channels.toml`. The archive root is `television-0.15.9/`, the channels live at `cable/unix/*.toml`, and `include` patterns match the path **as it appears in the archive**, before `stripComponents` is applied — `stripComponents = 3` then lands the files flat in the target directory. Both were verified in a scratch HOME; keep them in step if you change either.

```toml
# Upstream's channel definitions, pinned rather than pulled at runtime by
# `tv update-channels`, which would drop unversioned files into $HOME outside
# chezmoi's control. The include list is the curated set: everything here has
# a tool behind it on at least one machine (see README for which are
# host-only). `channels` is deliberately absent — the Ctrl-T menu is built
# from `tv list-channels` in the shell widgets, because a channel launched by
# the meta-channel's execute action writes its selection to the terminal
# instead of back to the caller.
# renovate: datasource=github-tags depName=alexpasmantier/television
{{ $televisionVersion := "0.15.9" }}
[".config/television/cable"]
type = "archive"
url = "https://github.com/alexpasmantier/television/archive/refs/tags/{{ $televisionVersion }}.tar.gz"
stripComponents = 3
refreshPeriod = "168h"
include = [
	"*/cable/unix/files.toml",
	"*/cable/unix/dirs.toml",
	"*/cable/unix/zoxide.toml",
	"*/cable/unix/sesh.toml",
	"*/cable/unix/tmux-sessions.toml",
	"*/cable/unix/tmux-windows.toml",
	"*/cable/unix/git-branch.toml",
	"*/cable/unix/git-log.toml",
	"*/cable/unix/git-stash.toml",
	"*/cable/unix/git-worktrees.toml",
	"*/cable/unix/git-repos.toml",
	"*/cable/unix/gh-prs.toml",
	"*/cable/unix/gh-issues.toml",
	"*/cable/unix/k8s-contexts.toml",
	"*/cable/unix/k8s-pods.toml",
	"*/cable/unix/k8s-services.toml",
	"*/cable/unix/k8s-deployments.toml",
	"*/cable/unix/pacman-packages.toml",
	"*/cable/unix/systemd-units.toml",
	"*/cable/unix/ports.toml",
	"*/cable/unix/procs.toml",
	"*/cable/unix/mounts.toml",
	"*/cable/unix/man-pages.toml",
	"*/cable/unix/tldr.toml",
	"*/cable/unix/env.toml",
	"*/cable/unix/path.toml",
	"*/cable/unix/docker-containers.toml",
	"*/cable/unix/docker-images.toml",
]
```

That is 28 patterns. `alias.toml` is deliberately not among them — Step 4 ships a modified copy as a managed file, which brings the total to 29.

- [ ] **Step 4: Write the modified alias channel**

Upstream's `alias.toml` sources from `$SHELL -ic 'alias'`, which starts a *full* interactive shell — mise, atuin, tv, zoxide, every plugin, and on this host bash's omarchy handoff exec'ing zsh — just to print a list. The definitions are already sitting in the rc files.

Create `dot_config/television/cable/alias.toml`:

```toml
# Local override of upstream's alias channel, which is why this file is
# managed directly instead of coming from the external alongside the others:
# upstream sources it from `$SHELL -ic 'alias'`, paying for a whole
# interactive shell — mise, atuin, tv, zoxide, plugins, and bash's omarchy
# handoff exec'ing zsh — every time the channel opens. The definitions are in
# the rc files already, so read those. The 2>/dev/null matters: omarchy's
# shared aliases file does not exist inside a devpod container, and the
# channel must still list the other two there.
[metadata]
name = "alias"
description = "A channel to select from shell aliases"

[source]
command = "grep -hE '^[[:space:]]*alias ' $HOME/.zshrc $HOME/.bashrc /usr/share/omarchy-zsh/shell/aliases 2>/dev/null | sed -E 's/^[[:space:]]*alias //' | sort -u"
output = "{split:=:0}"

[preview]
command = "grep -hE \"^[[:space:]]*alias {}=\" $HOME/.zshrc $HOME/.bashrc /usr/share/omarchy-zsh/shell/aliases 2>/dev/null"
```

- [ ] **Step 5: Apply and confirm the set landed**

Run: `chezmoi apply && ls ~/.config/television/cable | wc -l && tv list-channels | wc -l && tv list-channels | grep -c alias`
Expected: `29`, `32`, `1`. The cable directory holds 29 files; `tv list-channels` reports 32 because three of tv's compiled-in defaults (`bash-history`, `git-diff`, `text`) are not shadowed by the curated set — see this task's Interfaces note.

If the file count is short, the `include` patterns did not match — check them against the archive layout rather than guessing, and report what you found.

- [ ] **Step 6: Confirm the override survives an external refresh**

Run: `chezmoi apply --refresh-externals && grep -c "Local override" ~/.config/television/cable/alias.toml`
Expected: `1`. This is the property the whole design rests on; if it fails, stop and report rather than working around it.

- [ ] **Step 7: Check the alias channel is actually fast and non-empty**

Run: `time tv alias --take-1 --input git`
Expected: an alias printed, in well under a second. If it prints nothing, report what the source command emits on its own — do not leave a silently empty channel.

- [ ] **Step 8: Decide on config.toml**

Read tv's shipped default at `~/.config/television/config.toml` (7.3K, almost all commented-out defaults). Commit `dot_config/television/config.toml` holding **only** genuine deviations, each with a WHY comment.

The cable directory needs no setting — tv already resolves `$XDG_CONFIG_HOME/television/cable`, which is where the external puts the files (verified: there is no cable-dir key in the default config; `--cable-dir` is a CLI flag only).

If nothing genuinely deviates, write no file and say so in your report. An empty file committed for symmetry implies settings live there that do not.

- [ ] **Step 9: Verify chezmoi is not fighting tv**

Run: `chezmoi status | grep television` (expect no output) and confirm `chezmoi apply` twice in a row is quiet.

That directory is co-owned — `tv update-channels` writes into it. If chezmoi reports it perpetually modified, apply the co-ownership pattern from commit `339a033` and record what you did.

- [ ] **Step 10: Commit**

```bash
git add dot_config/mise/config.toml .chezmoiexternals/tv-channels.toml dot_config/television
git commit -m "feat: pin television and install a curated channel set"
```

---

### Task 2: zsh pickers

**Files:**
- Modify: `dot_zshrc` — remove the `fzf --zsh` block (currently lines 111-123) and the sesh widget (currently lines 186-214); add the tv widgets.

**Interfaces:**
- Consumes: `tv` and the channels from Task 1.
- Produces: `Ctrl-T`, `Alt-C`, `Ctrl-F` bound in zsh. Task 3 mirrors them in bash.

- [ ] **Step 1: Replace the fzf widget block**

Delete this block:

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

and put this in its place:

```zsh
# fzf's own widgets are gone: atuin owns Ctrl-R, tv owns Ctrl-T and Alt-C (see
# the tv block further down), and `source <(fzf --zsh)` was left binding
# nothing. fzf itself stays — fzf-tab, the completion menu loaded at the
# bottom of this file, is built on it and reads FZF_DEFAULT_COMMAND.
if command -v fzf > /dev/null && command -v fd > /dev/null ; then
  export FZF_DEFAULT_COMMAND="fd --type f --hidden --exclude .git"
fi
```

- [ ] **Step 2: Replace the sesh widget with the tv widgets**

Delete the whole `if command -v sesh > /dev/null && command -v fzf > /dev/null ; then ... fi` block, its comment block above it, and put this in its place — same location, after `bindkey -v`:

```zsh
# tv's pickers, bound into every keymap that is actually live: `bindkey -v`
# above means an emacs-only binding would be dead in insert mode, which is
# where these are used.
#
# `tv init zsh` is deliberately not sourced — in 0.15.9 it emits completions
# only, no bindings, so these widgets are the whole integration.
if command -v tv > /dev/null ; then
  # Ctrl-T is the channel menu: pick a channel, then pick inside it, and the
  # result lands on the command line. It is two `tv` calls rather than the
  # `channels` meta-channel because that channel's enter action runs `tv {}`
  # in execute mode, and the inner picker then writes its selection to the
  # terminal instead of back here — the command line would stay empty.
  #
  # Channels whose enter action *does* something (sesh connects, git-branch
  # checks out) print nothing, so nothing is inserted. That is correct: the
  # action already happened.
  tv-menu-widget() {
    local channel selection
    channel="$(tv list-channels | tv)" || return 0
    [ -z "$channel" ] && return 0
    selection="$(tv "$channel")" || return 0
    [ -n "$selection" ] && LBUFFER="${LBUFFER}${(q-)selection} "
    zle reset-prompt
  }

  # Alt-C changes directory in *this* shell. The dirs channel ships an
  # `[actions.cd]` running `cd {} && $SHELL`, which would strand the user in a
  # nested shell — so take the printed path and cd here instead.
  tv-dirs-widget() {
    local dir
    dir="$(tv dirs)" || return 0
    [ -z "$dir" ] && return 0
    cd "$dir" || return 0
    zle reset-prompt
  }

  # Ctrl-F is the sesh picker. Unlike the fzf pipeline it replaces, the
  # channel's own enter action runs `sesh connect`, so there is nothing to
  # capture. Ctrl-S cycles sources (all/tmux/configs/zoxide/dirs) and Ctrl-D
  # kills the highlighted session and reloads — both from the channel, which
  # is why the hand-written Ctrl-X kill binding is gone.
  tv-sesh-widget() {
    tv sesh
    zle reset-prompt
  }

  zle -N tv-menu-widget
  zle -N tv-dirs-widget
  zle -N tv-sesh-widget

  for keymap in emacs viins vicmd; do
    bindkey -M "$keymap" '^T' tv-menu-widget
    bindkey -M "$keymap" '^[c' tv-dirs-widget
    bindkey -M "$keymap" '^F' tv-sesh-widget
  done
  unset keymap
fi
```

- [ ] **Step 3: Apply and check the shell still starts clean**

Run: `chezmoi apply && mise run shells`
Expected: `ok    zsh`, `ok    bash`, exit 0.

- [ ] **Step 4: Verify the bindings landed in every keymap**

Run: `zsh -ic 'for k in emacs viins vicmd; do bindkey -M $k "^T"; bindkey -M $k "^[c"; bindkey -M $k "^F"; done' </dev/null`
Expected: nine lines naming `tv-menu-widget`, `tv-dirs-widget`, `tv-sesh-widget`. No line may name `fzf-file-widget` or `fzf-cd-widget`.

- [ ] **Step 5: Verify Ctrl-T inserts a path**

A binding that exists is not a binding that works. Drive real keypresses through a pty: make a scratch directory holding a uniquely-named file, start an interactive zsh under `script -qec`, send `Ctrl-T`, then `files`, `Enter`, then the unique name, `Enter`, and confirm the command line ends up holding that path.

Allow ~1.5s between stages — each picker has to start. Put the transcript in your report; if the keypresses cannot be driven, say so plainly rather than reporting the binding as verified.

- [ ] **Step 6: Verify Alt-C changes this shell's directory**

Same method: send `Alt-C`, select a known subdirectory, then run `pwd` and `echo $SHLVL`. Expected: the directory changed and `$SHLVL` is unchanged — a nested shell means the channel's own cd action ran instead of the widget.

- [ ] **Step 7: Commit**

```bash
git add dot_zshrc
git commit -m "feat: move the zsh pickers from fzf to television"
```

---

### Task 3: bash pickers

**Files:**
- Modify: `dot_bashrc` — remove the `fzf --bash` block (currently lines 182-186) and the sesh widget (currently lines 244-262); add the tv widgets.

**Interfaces:**
- Consumes: `tv` and the channels from Task 1.
- Produces: the same three bindings in bash, mirroring Task 2.

- [ ] **Step 1: Remove the fzf widget block**

Delete:

```bash
# fzf keybindings (fuzzy Ctrl-R etc.), same as in .zshrc, so bash
# stays usable on machines where zsh isn't the login shell yet
if command -v fzf > /dev/null ; then
  eval "$(fzf --bash)"
fi
```

Nothing replaces it. fzf-tab is zsh-only, so after this change bash uses fzf for nothing; the binary stays pinned for zsh's sake. Say that in the commit body, not in a comment that would sit in the file explaining an absence.

- [ ] **Step 2: Replace the sesh widget with the tv widgets**

Delete the `if command -v sesh > /dev/null && command -v fzf > /dev/null ; then ... fi` block and its comment, and put this in its place:

```bash
# tv's pickers, mirroring .zshrc — see the comments there, including why the
# Ctrl-T menu is two `tv` calls rather than the `channels` meta-channel. Bound
# into both keymaps because `set -o vi` at the top of this section means an
# emacs-only binding would never fire.
if command -v tv > /dev/null ; then
  # bash has no zle, so readline's own READLINE_LINE/READLINE_POINT are how a
  # widget edits the line being typed.
  tv-menu-widget() {
    local channel selection quoted
    channel="$(tv list-channels | tv)" || return 0
    [ -z "$channel" ] && return 0
    selection="$(tv "$channel")" || return 0
    [ -z "$selection" ] && return 0
    # Quoted the way zsh's `${(q-)}` does it on the other side: the inserted
    # text has to be one shell word, or a path with a space word-splits into
    # several bogus arguments the moment the line is submitted. READLINE_POINT
    # advances by the *quoted* length — quoting can lengthen the string, and
    # using the raw length puts the cursor in the wrong place.
    printf -v quoted '%q' "$selection"
    READLINE_LINE="${READLINE_LINE:0:$READLINE_POINT}${quoted}${READLINE_LINE:$READLINE_POINT}"
    READLINE_POINT=$((READLINE_POINT + ${#quoted}))
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

  for keymap in emacs vi-insert; do
    bind -m "$keymap" -x '"\C-t": tv-menu-widget'
    bind -m "$keymap" -x '"\ec": tv-dirs-widget'
    bind -m "$keymap" -x '"\C-f": tv-sesh-widget'
  done
  unset keymap
fi
```

- [ ] **Step 3: Apply and check both shells**

Run: `chezmoi apply && mise run shells`
Expected: `ok    zsh`, `ok    bash`, exit 0.

- [ ] **Step 4: Verify the bindings exist**

Run: `bash -ic 'bind -m emacs -X; bind -m vi-insert -X' </dev/null | grep -E "tv-(menu|dirs|sesh)-widget"`
Expected: six lines. `bind -p` will NOT show these — they are function bindings, visible only through `bind -X`.

- [ ] **Step 5: Verify Ctrl-T inserts and Alt-C cds**

Same pty method as Task 2 Steps 5-6, with `bash -i`. Confirm `$SHLVL` is unchanged after Alt-C. Transcripts in the report.

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

Replace the whole existing `if-shell "command -v sesh ..." { ... }` block with:

```tmux
# The sesh picker in a popup — the same channel Ctrl-F opens in the shell, so
# Ctrl-S (cycle sources) and Ctrl-D (kill + reload) work here too. Guarded on
# tv rather than sesh: without tv there is no picker to open, and `o` is then
# left at tmux's own default (select-pane -t :.+).
if-shell "command -v tv > /dev/null 2>&1" {
    bind o display-popup -E -w 60% -h 60% "tv sesh"
}
```

The nested quoting that made the old binding fragile goes with the pipeline — there is nothing left to escape.

- [ ] **Step 2: Verify tmux parses it**

Run: `chezmoi apply && tmux source-file ~/.tmux.conf && tmux list-keys -T prefix | grep -E '^bind-key +-T prefix +o '`
Expected: one line binding `o` to `display-popup -E ... "tv sesh"`.

- [ ] **Step 3: Verify the popup runs the picker**

Create a throwaway detached session and invoke the popup's command against a real attached client under a `script`-allocated pty — the technique used when the sesh popup was first added. Confirm `tv` starts on the sesh channel. Report what you ran.

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

In README's "Shell keybindings" section, these rows:

```markdown
| `Ctrl-T` | fzf file picker |
| `Alt-C` | fzf directory picker |
| `Ctrl-F` | sesh picker: tmux sessions + zoxide directories |
| `prefix o` | the same sesh picker, in a tmux popup |
| `Ctrl-X` | *inside* the picker: kill the highlighted session and redraw |
```

become:

```markdown
| `Ctrl-T` | tv channel menu — pick a channel, then pick in it; the result lands on the command line |
| `Alt-C` | tv directory picker, cds this shell |
| `Ctrl-F` | tv sesh channel: tmux sessions + zoxide directories |
| `prefix o` | the same sesh channel, in a tmux popup |
| `Ctrl-S` | *inside* the sesh channel: cycle source (all/tmux/configs/zoxide/dirs) |
| `Ctrl-D` | *inside* the sesh channel: kill the highlighted session and reload |
```

Then fix the paragraph below the table. It explains that `Ctrl-R` used to be fzf's and that init order decides the winner — still true of atuin, but it now sits under rows that no longer mention fzf. Reword it to describe what ships, and add that fzf stays installed solely for fzf-tab.

- [ ] **Step 2: Update the Layout table**

Add a row after the `dot_config/atuin/` row:

```markdown
| `dot_config/television/` | television: the one locally-modified channel (`cable/alias.toml`); the rest arrive from a pinned external |
```

Then update the `dot_zshrc`, `dot_bashrc` and `dot_tmux.conf` rows, which name the sesh picker and fzf keys, to name tv instead. Change only the picker wording.

- [ ] **Step 3: Document where channels are inert**

Add to the Packages section, after the coreutils sentence:

```markdown
tv's channels come from a pinned archive external rather than `tv
update-channels`, so the host and a container see the same set, and Renovate
bumps them with everything else. Several are host-only in practice:
`pacman-packages`, `systemd-units`, the `docker-*` pair and `tldr` have nothing
to list inside a devpod container, and the `k8s-*` channels need a `kubectl` on
PATH, which comes from a project's own `mise.toml` rather than the global pin.
An empty channel there is the tool missing, not the channel broken.

Three channels in the `Ctrl-T` list — `bash-history`, `git-diff` and `text` —
come from tv itself rather than that set: tv compiles ten defaults into the
binary, and only a same-named channel file can override one. `bash-history`
overlaps atuin and reads `~/.bash_history`, which is a partial record here
(see the keybindings section); atuin's `Ctrl-R` remains the full history.
```

- [ ] **Step 4: Check no stale reference survives**

Run: `grep -rn "Ctrl-X\|ctrl-x\|fzf file picker\|fzf directory picker" README.md dot_zshrc dot_bashrc dot_tmux.conf`
Expected: at most one hit — `dot_zshrc`'s comment on the sesh widget, explaining that the channel's own `Ctrl-D` is why the hand-written `Ctrl-X` kill binding is gone. That is a legitimate explanation of an absence, not a stale reference; leave it.

Anything else is stale and must go: a README row or a comment that still tells the reader to press a key nothing binds.

(The `docs/superpowers/` spec and plan for the earlier work describe `Ctrl-X` as it was then. Those are historical records — leave them.)

- [ ] **Step 5: Run the full check**

Run: `mise run check`
Expected: exit 0. The clean-HOME bootstrap installs television and fetches the channel external from scratch, which is the real test that both resolve on a machine with nothing cached.

- [ ] **Step 6: Confirm the diff's scope**

Run: `git diff main --stat`
Expected: only the files this plan names. No `.age` blob.

- [ ] **Step 7: Commit**

```bash
git add README.md
git commit -m "docs: document the television pickers and channel set"
```

Stop here. The push and the PR happen after a whole-branch review, not as part of this task.
