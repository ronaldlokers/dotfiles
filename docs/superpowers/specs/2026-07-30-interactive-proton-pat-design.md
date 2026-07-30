# Interactive Proton Pass PAT prompt on apply

**Date:** 2026-07-30
**Status:** approved, not yet implemented
**Touches:** `home/dot_local/bin/executable_proton-ssh-load`,
`home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl`,
`tests/proton-ssh-load.bats`, `README.md`

## Problem

A fresh host needs `PROTON_PASS_PERSONAL_ACCESS_TOKEN` in the environment on its
first `chezmoi apply`, as `README.md` documents. Nothing asks for it, and
nothing fails when it is missing: `run_after_14-restore-secrets` prints guidance
and exits 0 by design, because it also runs from contexts where a non-zero exit
would be worse than a missing key.

The cost of that silence showed up on `mahony`. The token was never set, so
`pass-cli` never authenticated, so the SSH keys — which live only in the agent
and never on disk — were never loaded. The apply looked successful. The failure
surfaced much later and in an unrelated place: `devpod up` on the Zenith
devcontainer could not clone `git@github.com:ronaldlokers/dotfiles.git` inside
the container, so DevPod ran no dotfiles setup and the container came up bare.

The distance between cause and symptom is the actual defect. An interactive
apply is the one moment where the machine can simply ask.

## Goal

On an interactive apply, ask for the PAT instead of silently continuing without
one.

## Non-goals

- Making a forgotten PAT impossible. A piped or automated apply on a fresh host
  still finishes without keys. This narrows the window; it does not close it.
- Changing what happens in containers. They get keys from the forwarded agent
  and hold no Proton session by design.
- Storing the PAT anywhere new. The existing cache at
  `~/.config/pass-cli-bootstrap-pat` is the only on-disk copy, unchanged.

## Verified findings

Both established by experiment on this host, not assumed:

1. **chezmoi passes its own stdin through to `run_` scripts.** With chezmoi
   2.70.5, a `run_after_` script sees `[ -t 0 ]` true when apply runs under a
   pty, and false under `chezmoi apply </dev/null`. This is what makes a
   script-level prompt viable and what keeps CI safe.
2. **`/dev/tty` is readable even when stdin is redirected.** A prompt that read
   `/dev/tty` would therefore fire during `chezmoi apply </dev/null`. The gate
   must be `[ -t 0 ]` and the read must come from stdin. This rules out the
   `/dev/tty` variant.
3. **`mise trust` and `mise install --yes` both exit 0 with no config file**
   (mise 2026.7.14), so the missing `mise.toml` in Zenith was not the container
   failure. Recorded here only to keep the next investigation from re-testing
   it.

## Decisions

**A no-TTY apply keeps today's behaviour.** Prompt when there is a terminal;
otherwise print the existing guidance and exit 0. `mise run verify`, `mise run
check` and CI are unaffected without needing an opt-out variable. Accepted cost:
a piped apply can still complete half-configured.

**The prompt lives behind a new `--prompt` flag on `proton-ssh-load`.** All
login logic stays in the one script that already owns it, as
`run_after_14-restore-secrets.sh.tmpl:19` asserts. The alternative — prompting
inside `run_after_14` — would split login across two files and falsify that
comment.

A flag is required rather than a bare TTY check because `dot_config/shell/ssh-agent.sh:39`
calls `proton-ssh-load --quiet` from `dot_zshrc` and `dot_bashrc` on every new
shell with a live-but-empty agent. Both existing callers pass `--quiet`, so
`--quiet` cannot distinguish them. A TTY check alone would block every terminal
opened after a reboot until someone typed a token.

**A rejected cached token re-prompts once.** A token rotated in the vault then
self-heals on the next interactive apply. The cache is overwritten only after
`pass-cli login` succeeds, so a failed attempt leaves the old file intact — the
same "stale beats truncated" rule `restore()` already follows. The cache is
never deleted on failure: a login can fail for transient network reasons, and
that file may be the only copy on the machine.

## Design

### Prompt conditions

A prompt happens only when all four hold:

1. `--prompt` was passed
2. `[ -t 0 ]`
3. `pass-cli info` reports no live session
4. no usable token — either none was found, or the one found was rejected

**At most one prompt per run.** No retry loop.

| caller | invocation | prompts? |
| --- | --- | --- |
| `run_after_14-restore-secrets` | `--quiet --prompt` | on a terminal |
| `ssh-agent.sh`, every new shell | `--quiet` | never |
| by hand | `--prompt` | on a terminal |
| CI, `mise run verify`, `apply </dev/null` | `--quiet --prompt` | never — `[ -t 0 ]` false |
| containers | any | never — returns at `executable_proton-ssh-load:20-22` |

### Argument parsing

`[ "${1:-}" = "--quiet" ] && quiet=1` inspects only `$1`. Replace with a
`while`/`case` loop accepting `--quiet` and `--prompt` in any order.

An unrecognised option becomes a hard error (exit 2). A silently-ignored typo'd
`--prompt` is precisely the class of failure this spec exists to remove. This is
a behaviour change to a script on the shell-startup path, so the implementation
must confirm no caller passes stray arguments. Current callers pass `--quiet`
and nothing else; no test passes an unknown flag.

### The prompt

`executable_proton-ssh-load` is `#!/bin/sh`, so `read -s` is unavailable.

- Save `stty -g`, set `stty -echo`, `read -r`, restore.
- Trap `INT TERM HUP` to restore echo, so Ctrl-C cannot leave the terminal
  echo-less.
- `read -r` needs `|| true`: it returns non-zero at EOF and the script runs
  under `set -eu`.
- Assign to a script-level variable rather than capturing `$( )`, so the trap is
  not confined to a subshell.
- Empty input is treated as "no token": print the existing guidance, exit 0,
  write no cache.

**Prompt text goes to stderr unconditionally, bypassing `say` and `--quiet`.**
The apply path passes `--quiet`, and a silent hang is worse than a visible
question. The same applies to the "cached token was rejected" line that precedes
a re-prompt. Every other message keeps its current `--quiet` behaviour, so
`tests/proton-ssh-load.bats:47` and `:121` — both asserting empty output under
`--quiet` — continue to hold, since neither passes `--prompt` nor runs on a
terminal.

Prompt wording names the vault item, matching the existing guidance at
`executable_proton-ssh-load:41-42`:

```
Proton Pass PAT (Dotfiles vault, item "bootstrap PAT"):
```

### Token flow

Precedence is unchanged, with one new terminal step:

```
env PROTON_PASS_PERSONAL_ACCESS_TOKEN
  -> cached ~/.config/pass-cli-bootstrap-pat
    -> prompt            (new: --prompt + tty only)
```

Then:

```
token found?  no  -> guidance, exit 0
              yes -> pass-cli login (token via environment)
                       ok       -> cache if it did not come from the cache
                       rejected -> prompted already?  yes -> warn, exit 0
                                                      no  -> notice, prompt once,
                                                             login again
                                                               ok       -> overwrite cache
                                                               rejected -> warn, exit 0
```

The token still reaches `pass-cli` through the environment and never as
`--personal-access-token`, so `tests/proton-ssh-load.bats:55` keeps holding. It
never enters shell history either, because the script reads it rather than the
user typing it on a command line — which is a small improvement over the
documented `PROTON_PASS_PERSONAL_ACCESS_TOKEN='pst_…' chezmoi apply` form.

Cache file handling is untouched: `umask 077`, mode 600, written only after a
successful login.

### Caller change

`run_after_14-restore-secrets.sh.tmpl:23` becomes:

```sh
proton-ssh-load --quiet --prompt || true
```

Nothing else in that script changes. Its own guidance block at lines 25-30 still
covers the no-session outcome, including the no-TTY case where
`proton-ssh-load` stays silent under `--quiet`.

`dot_config/shell/ssh-agent.sh` is deliberately **not** changed.

## Testing

New cases in `tests/proton-ssh-load.bats`:

| case | expected |
| --- | --- |
| `--prompt`, no TTY, no token anywhere | no prompt, exit 0, guidance printed, no cache |
| `--prompt`, TTY, no token anywhere | prompts, logs in, caches, loads keys |
| `--prompt`, TTY, empty input at the prompt | guidance, exit 0, no cache written |
| `--prompt`, TTY, cached token rejected, typed one accepted | notice, one re-prompt, cache overwritten |
| `--prompt`, TTY, cached token rejected, typed one also rejected | exit 0, cache left byte-identical |
| `--prompt`, TTY, env token rejected, typed one accepted | notice, one re-prompt, cache written |
| `--prompt`, TTY, typed token rejected (nothing cached) | exit 0, no cache created, exactly one prompt |
| bare `--quiet`, TTY, no token anywhere | never prompts |
| unknown option | exit 2 |

Note the sixth row: a bad token in the environment re-prompts on the same terms
as a bad cached one. The "prompted already?" guard, not the token's source, is
what bounds it to one prompt.

**Harness limitation, and the main implementation risk.** `run_load` at
`tests/proton-ssh-load.bats:28` appends `sh "$SCRIPT"` after the env
assignments, so it cannot pass flags to the script — the file already notes this
at lines 119-120, where two tests bypass it. TTY cases additionally need a pty.
The implementation therefore needs a second helper that both takes script flags
and runs under a pty, with the typed token fed to it. `script -qec` is the
mechanism used to verify finding 1 above and is the obvious candidate; whether
it can supply stdin content while still presenting a TTY needs checking early,
before the rest of the tests are written. If it cannot, the fallback is a small
`expect`-free pty helper, and `expect` must not become a new test dependency
without a decision.

The token-never-in-argv assertion must be extended to the prompt path: a typed
token must not appear in `$STUB_LOG` either.

## Docs

`README.md:16` shows:

```
PROTON_PASS_PERSONAL_ACCESS_TOKEN='pst_…' chezmoi apply   # secrets + ssh keys
```

The environment variable becomes optional. The line should note that an
interactive apply asks for the token, and that the environment form remains for
scripted first-runs.

`CLAUDE.md` needs no change. The "never pass the token as a flag" rule is
preserved, and "containers get nothing from Proton by design" still holds.

## Accepted limitations

- A piped or automated apply on a fresh host still completes without keys. By
  choice: hard-failing would break `mise run verify` without an opt-out
  variable.
- The gap between "no keys" and the symptom (a DevPod container that cannot
  clone) is narrowed, not removed. If it recurs on a non-interactive path, the
  next step is a check on the DevPod side rather than more logic here.
