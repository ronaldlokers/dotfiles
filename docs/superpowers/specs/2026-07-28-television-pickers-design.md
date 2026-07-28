# Television: pickers and a pinned channel set

Date: 2026-07-28

## Problem

Every picker in this setup is fzf behind a hand-written widget. `Ctrl-T` and
`Alt-C` come from `source <(fzf --zsh)`; the sesh picker is `sesh list --icons |
fzf` repeated at three call sites, kept in step by hand across `dot_zshrc`,
`dot_bashrc` and `dot_tmux.conf`. Each one is a shell pipeline plus a comment
explaining its quoting.

That works, but it only ever produces the pickers someone wrote a pipeline for.
Reaching a git branch, a Kubernetes pod, a systemd unit or an open PR means
either a TUI dedicated to that one thing or typing the command out.

[television](https://github.com/alexpasmantier/television) (`tv`) is a fuzzy
finder built around *channels*: a channel is a TOML file naming a source
command, a preview command, and keybindings that run actions on the selection.
Upstream ships around 100 of them. The same binary also reads stdin and prints
the selection, so it drops into a pipeline where fzf sits today.

## Decisions

**fzf stays pinned.** `fzf-tab` — the zsh completion menu — requires the fzf
binary. Replacing fzf outright is not on the table while fzf-tab is in use, and
this spec does not try. What it removes is fzf's *widgets*, not fzf.

**`source <(fzf --zsh)` goes away.** That line binds `Ctrl-T`, `Alt-C` and
`Ctrl-R`. atuin already took `Ctrl-R`; once tv takes the other two, the line is
dead weight, and so are the `FZF_CTRL_T_COMMAND`, `FZF_CTRL_T_OPTS` and
`FZF_ALT_C_COMMAND` exports that feed it. `FZF_DEFAULT_COMMAND` stays — fzf-tab
inherits it. Net effect: this change removes more shell wiring than it adds.

**`Ctrl-R` is not in scope.** atuin owns history search, decided in
`2026-07-28-daily-friction-tooling-design.md`. tv ships `zsh-history` and
`bash-history` channels; both are deliberately not vendored.

**Channels arrive as a pinned archive external, not `tv update-channels`.** That
subcommand pulls TOMLs from GitHub at runtime into `$HOME` — unpinned content
arriving outside chezmoi, contradicting how every other dependency here works.

The alternative first considered was committing a curated set of TOMLs into the
repo. That is reproducible but invisible to Renovate, so the set would silently
rot. Instead the channels come from a `.chezmoiexternals` archive pinned to
upstream tag `0.15.9`, with an `include` list naming exactly the channels wanted
— the same mechanism as the zsh plugins, tracked by the repo's existing custom
regex manager, so Renovate bumps it like everything else.

One channel needs local changes (see `alias` below). A chezmoi-managed file can
live *inside* an external's target directory: verified against chezmoi 2.70.5 in
a scratch HOME, where a managed `alias.toml` survived both the initial apply and
a forced `--refresh-externals`. So the override ships as a normal managed file
and is simply left out of the external's `include` list.

**The hand-built `Ctrl-X` sesh kill is superseded.** Upstream's `sesh` channel
already binds `Ctrl-D` to kill-and-reload, alongside source cycling (`Ctrl-S`
between All / Tmux / Configs / Zoxide / Directories) and a `sesh preview` pane.
That is strictly more than the `Ctrl-X` binding added in PR #91, so that binding
is removed rather than carried forward under a second name.

## Design

### Tool pin

`television = "0.15.9"` in `dot_config/mise/config.toml`, alongside the other
shell-integration tools. Registry-backed, so Renovate tracks it.

### Pickers

| Key | Today | After |
| --- | --- | --- |
| `Ctrl-T` | fzf file widget | tv channel menu: pick a channel, then pick in it |
| `Alt-C` | fzf directory widget | `tv dirs` |
| `Ctrl-F` | `sesh list --icons \| fzf` | `tv sesh` |
| `prefix o` | the same pipeline in a popup | `tv sesh` in a popup |
| `Ctrl-R` | atuin | atuin, unchanged |

Bindings stay where they are today: all three zsh keymaps (`emacs`, `viins`,
`vicmd`), and both bash keymaps (`emacs`, `vi-insert`), because `bindkey -v` and
`set -o vi` are both active.

`Alt-C` must `cd` in the *calling* shell. The `dirs` channel ships an
`[actions.cd]` that runs `cd {} && $SHELL`, which spawns a nested shell — not
what the binding should do. The widget therefore takes tv's printed path and
runs `cd` itself, ignoring that action.

`Ctrl-T` becomes the channel menu rather than a file picker: pick a channel,
then pick inside it, and the result lands on the command line. Files are one
entry in that list, so the old `Ctrl-T` behaviour costs one extra keystroke and
every other channel becomes reachable without its own binding. No new key is
needed, which matters — `Ctrl-G` is not free (`send-break` in zsh's emacs
keymap, `list-expand` in `viins` and `vicmd`) and `Ctrl-Space` is this machine's
tmux prefix.

**The menu is two `tv` calls, not the `channels` meta-channel.** Upstream ships
a `channels` channel whose `enter` action runs `tv {}`. Bound to a key, it does
not work for this purpose: the inner picker writes its selection to the
terminal, so `sel="$(tv channels)"` returns empty — verified by pty transcript,
where the chosen filename appeared on screen while the capture stayed `[]`. The
widget therefore runs `tv list-channels | tv` to choose a channel and then
`tv "$channel"` to choose within it, both in the calling process, both captured.
That channel is consequently not installed.

Channels whose `enter` action *does* something rather than printing — sesh
connects, git-branch checks out — insert nothing, which is correct: the action
already happened.

### Channel set

Extracted into `~/.config/television/cable/` by `.chezmoiexternals/tv-channels.toml`,
from upstream's `cable/unix/` at tag `0.15.9`, selected by an `include` list.
Requirements below are upstream's own `requirements` field.

| Group | Channels | Needs |
| --- | --- | --- |
| Pickers and navigation | `files`, `dirs`, `zoxide`, `sesh`, `tmux-sessions`, `tmux-windows` | fd, bat, zoxide, sesh, tmux — all pinned |
| Git and GitHub | `git-branch`, `git-log`, `git-stash`, `git-worktrees`, `git-repos`, `gh-prs`, `gh-issues` | git, fd, gh, jq — all pinned |
| Kubernetes | `k8s-contexts`, `k8s-pods`, `k8s-services`, `k8s-deployments` | kubectl — **not pinned globally** |
| Arch host and system | `pacman-packages`, `systemd-units`, `ports`, `procs`, `mounts` | pacman, systemctl, ss, ps, df, awk — **host only** |
| Reference and containers | `man-pages`, `tldr`, `env`, `path`, `alias`, `docker-containers`, `docker-images` | apropos/man, tldr, docker — **host packages, not pinned** |

### Configuration file

`dot_config/television/config.toml` holds only the settings this setup deviates
on. tv's shipped default is 7.3K of commented-out defaults; committing it whole
would bury the two or three lines that matter and would conflict on every
upstream default change.

That directory is co-owned: `tv update-channels` writes into it. The pattern from
commit 339a033 (stopping chezmoi reverting what other programs write to co-owned
files) applies — the design must not leave a chezmoi apply fighting tv.

## Verification

`mise run check` — lint, gitleaks, the clean-HOME bootstrap, and the `shells`
smoke check that catches rc-file breakage.

Per binding, driven through a real pty the way the sesh binding was verified in
PR #91, because none of the above starts an interactive picker:

- `Ctrl-T` lists the installed channels; picking `files` and then a file puts
  that path on the command line.
- `Alt-C` changes the directory of the calling shell, not a nested one — `$SHLVL`
  is unchanged afterwards.
- `Ctrl-F` and `prefix o` connect to a session; `Ctrl-D` inside kills one and
  the list reloads.

Plus one negative check that matters more than it looks: with `fzf --zsh` gone,
`Ctrl-T` and `Alt-C` must be tv's and fzf-tab must still complete on `Tab`.

## Risks

**The one overridden channel does not follow upstream.** The external's tag moves
with Renovate, but `alias.toml` is ours and will not — an upstream improvement to
that channel arrives only if someone notices. That is the price of the override
and it applies to exactly one file; if upstream ever fixes the interactive-shell
source command, the override should be dropped and the channel returned to the
`include` list.

**Several channels are inert where their tool is absent.** `pacman-packages`,
`systemd-units`, `docker-*`, `tldr` and the `k8s-*` set list nothing inside a
devpod container, and `kubectl` resolves through a mise shim rather than a global
pin, so the k8s channels depend on the project you are standing in. This is
correct behaviour that looks like breakage; it belongs in the README rather than
in a guard.

**The `alias` channel needs editing, not just copying.** Upstream's source
command is `$SHELL -ic 'alias'`, which starts a full interactive shell — here
that means mise, atuin, tv, zoxide, the plugins, and on this host bash's omarchy
handoff exec'ing zsh — every time the channel opens, to print a list of aliases.
Vendoring makes it ours to fix; the fix belongs in this change rather than being
left as a slow surprise.

**Three pickers verified last week are being replaced.** `Ctrl-T`, `Alt-C` and
the sesh picker all currently work. The `shells` smoke check catches a broken rc
file but cannot tell a working binding from a silently wrong one, which is why
every binding above gets a pty check rather than a "it sources cleanly".

**`Ctrl-X` disappears.** It shipped hours before this spec, and the README
documents it. Removing it is deliberate — `Ctrl-D` from upstream's channel does
the same job with a reload — but the README table and the plan/spec documents
that describe `Ctrl-X` must be updated in the same change, not left contradicting
the shell.

## Documentation

README: update the keybindings table (`Ctrl-T` is now the channel menu, `Alt-C`
and `Ctrl-F` are tv, `Ctrl-X` becomes the channel's own `Ctrl-D`, `Ctrl-S`
cycles sesh sources), add `dot_config/television/` to the Layout table, and state
plainly which channels are host-only.
