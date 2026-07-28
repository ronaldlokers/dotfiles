# Daily-friction tooling: shell history, session switching, small utilities

Date: 2026-07-28

## Problem

Three things cost time every day and none of them are managed today.

**Finding old commands.** Both shells use plain history. `Ctrl-R` is fzf's history
widget (`source <(fzf --zsh)` in `dot_zshrc`), which searches a flat list with no
notion of which directory a command was run in, no exit status, and no dedup beyond
what zsh's `HIST_IGNORE_ALL_DUPS` does. History does not survive a devpod container
being rebuilt.

**Switching projects.** Getting to a project means `cd` to it (zoxide helps), then
deciding whether a tmux session already exists, then `tmux new -s` or `tmux attach`.
`repos-sync` clones the repos and `tmux-resurrect`/`tmux-continuum` restore sessions
across reboots, but nothing turns "I want to work on X" into one keystroke.

**Missing small tools.** `du`, `df`, `top`, `sed` and JSON paging come up often
enough to be annoying with the coreutils versions. Inside a devpod container it is
worse: there is no pacman, so whatever mise does not pin does not exist.

## Scope

In: atuin (local-only), sesh, and a fixed set of utilities, wired into zsh, bash and
tmux, on the host and inside containers.

Out, each queued for its own spec: capturing un-managed host state (hypr, waybar,
walker, explicit pacman list) in the repo; a global gitleaks pre-commit hook and a
backup strategy; a shared instruction/MCP layer across Claude, Gemini and Codex.

## Decisions

**History sync is off.** atuin runs local-only: no account, no key blob in the repo,
no network call at shell start, nothing to fail when a container has no route out.
Each devpod container keeps its own database and loses it when the container goes.
That is accepted — the gain being bought here is search quality and directory
awareness, not history that follows the machine.

**sesh over a hand-rolled script.** A ~40-line `tmux-sessionizer` in
`dot_local/bin/` would add no dependency and match the `repos-sync` pattern, but
sesh already unifies live tmux sessions, zoxide's frecency database and a configured
project list behind one picker, and it is a single static binary mise can pin. The
zoxide integration is the deciding factor: zoxide already knows where work happens.

**bash gets full parity.** `dot_bashrc` mirrors `dot_zshrc` (commit a07ea98), and a
history tool that only works in one shell puts a hole in that mirror. atuin's bash
integration requires `bash-preexec`, so that becomes a pinned external.

## Design

### Tool pins

In `dot_config/mise/config.toml`, versions resolved against the registry on
2026-07-28. Each pin gets a comment in the style of the surrounding file where the
reason is not self-evident.

| Tool | Version | Backend | Note |
| --- | --- | --- | --- |
| atuin | 18.17.1 | registry (`aqua:atuinsh/atuin`) | newest release visible under the repo's `minimum_release_age` |
| sesh | 2.28.0 | `github:joshmedeski/sesh` | not in the mise registry; same backend as `sugarrush` |
| dust | 1.2.4 | registry | `du` |
| duf | 0.9.1 | registry | `df` |
| btop | 1.4.7 | registry | `top` |
| sd | 1.1.0 | registry | `sed` for the common substitution case |
| jless | 0.9.0 | registry | JSON pager, complements the pinned `jq`/`yq` |
| hyperfine | 1.20.0 | registry | command benchmarking |
| gping | 1.20.4 | registry | `ping` with a graph |

Pinning in mise rather than the host package list is deliberate: these are wanted
inside devpod containers as much as on the host, the same reasoning already recorded
for `yazi` and `superfile`.

### bash-preexec external

New `.chezmoiexternals/bash-preexec.toml`, pinned to `0.6.0` with a `# renovate:
datasource=github-tags depName=rcaloras/bash-preexec` comment so Renovate tracks it
the way it tracks the zsh plugins. bash-preexec is a single file, so `type = "file"`
pulling the tagged raw file into `~/.bash/bash-preexec.sh`, `refreshPeriod = "168h"`
to match the other externals.

### Configuration files

`dot_config/atuin/config.toml`:

- `auto_sync = false` and no `sync_address` — local-only, as decided above.
- `update_check = false` — mise owns the version; a self-update prompt would fight it.
- `filter_mode_shell_up_key_binding = "directory"` — Up searches this directory's
  history, `Ctrl-R` searches everything.
- `enter_accept = false` — Enter puts the selected command on the command line
  instead of running it, matching what fzf's `Ctrl-R` widget did before atuin
  took the binding.
- inline height rather than fullscreen, so the picker does not blow away the screen.

sesh gets **no** config file. Its list is built from live tmux sessions plus
zoxide's database, and it has no "scan this directory" source to point at
`XDG_PROJECTS_DIR` — so a config file here would carry nothing but defaults. The
gap that leaves is a freshly cloned repo that has never been `cd`'d into and so is
absent from zoxide. `repos-sync` closes it: after a successful clone it runs
`zoxide add` on the new checkout, guarded on zoxide being installed.

### Shell wiring

Keybindings after this change:

```
Ctrl-R    atuin history search           (was: fzf)
Up        atuin, filtered to this dir    (new)
Ctrl-T    fzf file picker                (unchanged)
Alt-C     fzf cd picker                  (unchanged)
Ctrl-F    sesh picker                    (new)
prefix o  sesh popup, inside tmux        (new)
```

`dot_zshrc`: `eval "$(atuin init zsh)"` goes *after* the existing
`source <(fzf --zsh)` block, guarded by `command -v atuin`. Order is load-bearing —
whichever runs last owns `Ctrl-R`. A `sesh-connect` zle widget bound to `Ctrl-F`
runs the picker and attaches, guarded by `command -v sesh`.

`dot_bashrc`: source `~/.bash/bash-preexec.sh` if the file exists, then
`eval "$(atuin init bash)"` behind the same `command -v` guard. `Ctrl-F` via
`bind -x`. The file-exists guard matters: a machine that has not run
`chezmoi apply` since this change, or a container where the external has not been
fetched, must still get a working shell.

`dot_tmux.conf`: `bind o display-popup -E` running the sesh picker, sized like a
picker rather than fullscreen. `o` is not bound in this config today, but it is a
tmux default (`select-pane -t :.+`), so this overrides it. The pane-switching
bindings actually in use are the `C-h/j/k/l` vim-aware ones, so nothing in reach is
lost.

### History import

`.chezmoiscripts/run_onchange_after_zz-atuin-import.sh.tmpl`. If atuin is on `PATH`
and its database does not exist yet, run `atuin import auto` to pull the existing
zsh and bash history in; otherwise do nothing. The database check, not the
`run_onchange` hash, is what makes this safe — the script must never re-import over
a database that already has history in it.

The `zz-` name is load-bearing. chezmoi runs scripts in name order, and atuin is
installed by `run_onchange_after_install_packages.sh.tmpl` (`mise install`). A
numeric prefix such as `40-` sorts *before* `install_packages`, so on a fresh
machine the import would run before atuin existed, find nothing, and — being
`run_onchange` — never run again. `zz-` sorts after it.

## Verification

`mise run check` — shellcheck over the scripts, gitleaks over history, and the
clean-HOME bootstrap that CI runs.

A broken shell init line is invisible to all three: neither rc file is in the
shellcheck list, and the bootstrap never starts a shell. So a fourth repo task,
`mise run shells`, is added and folded into `check`. It starts each installed
shell interactively and fails on any output or non-zero exit:

```sh
zsh -ic true    # must exit 0, no output
bash -ic true   # must exit 0, no output
```

What shipped wraps each of those in `script -qec` and exports
`MISE_TERMINAL_PROGRESS=false` first: without a real pty, both shells print
tty-acquisition noise that has nothing to do with the rc files (zsh's fzf
integration failing to restore `zle`, bash failing to claim a process group),
which would false-FAIL the check, and a pty makes mise's own shell hooks emit
an OSC 9;4 progress escape that has to be silenced the same way. `script` is
optional — the task falls back to the bare form when it is not installed, at
the cost of reintroducing that tty noise as a false-FAIL risk.

It reads the *applied* files in `$HOME`, so it runs after `chezmoi apply`, and it
stays out of CI, which has no applied `$HOME` to start a shell in.

And by hand, once, on the host: `Ctrl-R` opens atuin, `Up` shows only this
directory's commands, `Ctrl-T` and `Alt-C` still open fzf, `Ctrl-F` and `prefix o`
both open the sesh picker and attaching works from each.

## Risks

**Init order.** If the atuin block lands above the fzf block, fzf keeps `Ctrl-R` and
the change silently does nothing visible. Caught by the manual check above.

**Container database is throwaway.** A rebuilt devpod container starts with empty
history. Direct consequence of the local-only decision, documented in the README so
it does not read as a bug later.

**Renovate coverage.** The new external needs the `# renovate:` comment marker the
repo's custom regex manager keys on, or it silently stops being updated. The `sesh`
pin needs nothing extra — Renovate's mise manager supports the `github:` backend
natively.

**bash DEBUG trap collision.** `dot_bashrc` already defines `preexec`/`precmd` and
installs its own `trap ... DEBUG` for xterm titles. bash-preexec takes over the
DEBUG trap and invokes any function named `preexec`, so leaving both in place risks
a lost trap or a double invocation. The title functions get renamed and registered
through bash-preexec's `preexec_functions`/`precmd_functions` arrays instead.

**atuin's default `?` binding.** `atuin init` binds `?` to atuin's account-gated
AI TUI unconditionally, unless told not to. This setup deliberately has no atuin
account, so that binding can only open a dead end — in bash it lands live in
vi-insert (`set -o vi` runs before the atuin init), and in zsh it is dormant on
this host only because omarchy's zoptions already ran `bindkey -e` first, so it
would be live in any container with no such block. Fixed by passing
`--disable-ai` to `atuin init` in both `dot_zshrc` and `dot_bashrc`.

**bash-preexec and the leading-space history escape hatch.** bash-preexec's own
installer rewrites `HISTCONTROL` from `ignoreboth` to `ignoredups:` once, at the
first prompt it draws — it reconstructs the previous command via `history 1`,
which cannot express `ignorespace`. Left alone, a command typed with a leading
space would start landing in `~/.bash_history`, where it did not before this
branch. Fixed by re-asserting `HISTCONTROL=ignoreboth` from a precmd hook (run
before every prompt, not just once) right after sourcing bash-preexec in
`dot_bashrc`. zsh's `setopt hist_ignore_space` is unaffected — the two rc files
were verified to still agree on this point.

## Documentation

README: add the new tools to the Packages section, note the new keybindings, and
record that container history is local and ephemeral. Add the new atuin config
directory to the Layout section — sesh deliberately has no config file of its
own (see Configuration files above), so there is only one to add. bash-preexec
is not a Layout row either: it has no config of its own to describe there, and
is instead mentioned in the Updates section, alongside the other externals it
now refreshes with.
