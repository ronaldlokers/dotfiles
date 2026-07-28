# Television: pickers and vendored channels

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

**Channels are vendored, not fetched.** `tv update-channels` pulls TOMLs from
GitHub at runtime into `$HOME`. That is unpinned content arriving outside
chezmoi, which contradicts how every other dependency here works. A curated set
is committed to the repo instead: reviewable, identical on the host and inside a
container, and needing no network at runtime. The cost is that refreshing a
channel from upstream is a manual step — see Risks.

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
| `Ctrl-T` | fzf file widget | `tv files` |
| `Alt-C` | fzf directory widget | `tv dirs` |
| `Ctrl-F` | `sesh list --icons \| fzf` | `tv sesh` |
| `prefix o` | the same pipeline in a popup | `tv sesh` in a popup |
| `Ctrl-G` | — | `tv channels` |
| `Ctrl-R` | atuin | atuin, unchanged |

Bindings stay where they are today: all three zsh keymaps (`emacs`, `viins`,
`vicmd`), and both bash keymaps (`emacs`, `vi-insert`), because `bindkey -v` and
`set -o vi` are both active.

`Alt-C` must `cd` in the *calling* shell. The `dirs` channel ships an
`[actions.cd]` that runs `cd {} && $SHELL`, which spawns a nested shell — not
what the binding should do. The widget therefore takes tv's printed path and
runs `cd` itself, ignoring that action.

`Ctrl-G` opens the `channels` meta-channel: it lists the vendored channels,
previews each one's TOML with `bat`, and its `enter` action runs `tv {}` to drop
into the chosen channel. Every channel added later is reachable through it with
no further binding.

### Channel set

Vendored under `dot_config/television/cable/`, copied from upstream's
`cable/unix/` at commit `3e74ba4` (2026-07-25). Requirements are upstream's own
`requirements` field.

| Group | Channels | Needs |
| --- | --- | --- |
| Pickers and navigation | `files`, `dirs`, `zoxide`, `sesh`, `tmux-sessions`, `tmux-windows`, `channels` | fd, bat, zoxide, sesh, tmux, tv — all pinned |
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

- `Ctrl-T` inserts the selected path on the command line.
- `Alt-C` changes the directory of the calling shell, not a nested one.
- `Ctrl-F` and `prefix o` connect to a session; `Ctrl-D` inside kills one and
  the list reloads.
- `Ctrl-G` lists the vendored channels, previews a TOML, and entering one opens
  it.

Plus one negative check that matters more than it looks: with `fzf --zsh` gone,
`Ctrl-T` and `Alt-C` must be tv's and fzf-tab must still complete on `Tab`.

## Risks

**Vendored channels are invisible to Renovate.** The regex managers cover
`.chezmoiexternals` and mise pins; a TOML copied into `dot_config` matches
neither. Upstream fixes will not arrive on their own. The commit the set was
copied from gets recorded so a refresh is a diff rather than an archaeology
exercise.

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

README: update the keybindings table (`Ctrl-T`, `Alt-C`, `Ctrl-F` now tv;
`Ctrl-X` becomes `Ctrl-D`; `Ctrl-G` added), add `dot_config/television/` to the
Layout table, and state plainly which channels are host-only.
