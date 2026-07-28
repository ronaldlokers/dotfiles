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
- inline height rather than fullscreen, so the picker does not blow away the screen.

`dot_config/sesh/sesh.toml`: minimal. zoxide and tmux as sources, plus the projects
root read from `XDG_PROJECTS_DIR` (declared in `~/.config/user-dirs.dirs`, the same
place `repos-sync` reads it from, with the same `$HOME/Projects` fallback).

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

`mise run all` — shellcheck over the scripts, gitleaks over history, and the
clean-HOME bootstrap that CI runs.

Then, because a broken shell init line is invisible to all of the above:

```sh
zsh -ic true    # must exit 0, no output
bash -ic true   # must exit 0, no output
```

And by hand, once, on the host: `Ctrl-R` opens atuin, `Up` shows only this
directory's commands, `Ctrl-T` and `Alt-C` still open fzf, `Ctrl-F` and `prefix o`
both open the sesh picker and attaching works from each.

## Risks

**Init order.** If the atuin block lands above the fzf block, fzf keeps `Ctrl-R` and
the change silently does nothing visible. Caught by the manual check above.

**Container database is throwaway.** A rebuilt devpod container starts with empty
history. Direct consequence of the local-only decision, documented in the README so
it does not read as a bug later.

**Renovate coverage.** The `github:` backend pin and the new external both need the
comment markers Renovate keys on, or they silently stop being updated.

## Documentation

README: add the new tools to the Packages section, note the new keybindings, and
record that container history is local and ephemeral. Add the two new config
directories and the new external to the Layout section.
