# Restore `devpod project-tokens` from Proton Pass

2026-07-31

## Problem

`~/.config/devpod/project-tokens` is the only devpod secret still created by
hand. It holds `owner/repo=token` lines, mode 0600, and is read by
`project_token()` in `home/dot_local/bin/executable_devpod` to pass a
per-project `GH_TOKEN` into a container that needs the GitHub API. Today
`README.md` tells you to `install -m600 /dev/null` the file and append to it
locally.

Everything else file-shaped already comes from the Dotfiles vault, including
`devpod dotfiles-env`, the other half of the devpod token story. Leaving this
one out means a rebuilt machine silently loses its project tokens, and a
revoked token stays on disk until somebody remembers to edit the file.

## Decision

Restore the whole file from a single vault note, exactly like the four secrets
already in `run_after_14-restore-secrets.sh.tmpl`.

The alternative considered was keeping the file absent by default and
restoring only onto machines that had already opted in, preserving "no file,
no token" as a per-machine property. Rejected: it adds a conditional to a
`restore()` contract whose value is that it is uniform, in exchange for
protecting a single-host setup from itself.

The accepted cost is that every machine with a Proton session now holds every
project token at 0600, rather than each token living only on the host it was
minted for. The compensating gain is that deletions propagate — `restore()`
writes the whole file, so dropping a line from the vault note removes it
everywhere on the next apply, which hand-editing never did.

One entry per repository, each a fine-grained PAT limited to that repository,
is unchanged and still load-bearing. That rule comes from DevPod materialising
workspace env as `/etc/envfile.json` mode 0644 *inside the container*, which is
a property of what gets handed to a container and is unaffected by where the
file came from.

## Changes

**`home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl`** — one line
after the existing four:

```sh
restore "devpod project-tokens" "$HOME/.config/devpod/project-tokens" 600
```

Nothing else in the script changes. `restore()` already creates
`~/.config/devpod` at 0700, writes 0600, rewrites only when the content
differs, and leaves an existing file alone when the fetch fails or comes back
empty.

**`mise.toml`** — add `"devpod project-tokens"` to the title list in
`[tasks.secrets-check]`. The list is hardcoded; an item missing from it is
unreadable-but-silent until a machine is rebuilt, which is the failure that
task exists to catch.

**`tests/restore-secrets.bats`** — add the item to the `$ITEMS` fixture, to the
loop asserting every target was written, and an `--item-title devpod
project-tokens` assertion against `$STUB_LOG` mirroring the `devpod
dotfiles-env` one. The empty-fetch and failed-fetch branches are already
covered generically by the existing tests; this change introduces no new
branch.

**`README.md`** — a fifth row in the secrets table:

| Secret | Target | Vault item |
| --- | --- | --- |
| DevPod project tokens | `~/.config/devpod/project-tokens` | `devpod project-tokens` |

and the per-project opt-in snippet is replaced. The current instructions —
create the file locally and append to it — become actively wrong once the file
is managed, because the next apply overwrites the local edit. They become: add
an `owner/repo=token` line to the `devpod project-tokens` note in the Dotfiles
vault, then `chezmoi apply`. The `/etc/envfile.json` 0644 warning below it
stays as written.

**`docs/design-notes.md`** — the sentence describing `project-tokens` as
`owner/repo=token`, mode 0600, "absent by default" is now wrong on the last
clause. It becomes restored from the vault like the other file-shaped secrets,
holding no entries on a machine that has minted none.

## Prerequisite

The `devpod project-tokens` note must exist in the Dotfiles vault, with the
current contents of `~/.config/devpod/project-tokens` as its body, before this
lands. It must be non-empty: an empty note trips the "came back empty" guard
and prints a warning on every apply. If there are no project tokens to store
yet, this change waits until there is at least one.

Creating the note is a manual step. Nothing in this repo writes to the vault.

## Verification

- `mise run test` — the bats suite, including the new assertions.
- `mise run check` — lint, tests, gitleaks, clean-HOME verify.
- `mise run secrets-check` — manual, needs a Proton session; proves the new
  item is readable under its exact title.
