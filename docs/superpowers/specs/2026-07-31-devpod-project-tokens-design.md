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
everywhere on the next apply, which hand-editing never did. That holds for any
line except the last one: emptying the note entirely trips the empty-fetch
guard, which leaves the existing file — and its one remaining token — in
place rather than writing it through. Revoking the last entry needs a line
with no `=` (e.g. `# no entries`) instead of a blank note.

One entry per repository, each a fine-grained PAT limited to that repository,
is unchanged and still load-bearing. That rule comes from DevPod materialising
workspace env as `/etc/envfile.json` mode 0644 *inside the container*, which is
a property of what gets handed to a container and is unaffected by where the
file came from.

### The file is now edited in a browser

Moving the file into the vault also moves where it is authored. It used to be
produced by `printf` into a local file; it is now a free-text note edited in
the Proton Pass web UI, where a stray leading space is invisible.

This is not hypothetical. The first note created for this change arrived with a
trailing space in its *title* — enough on its own to make both the restore
script and `secrets-check` report the item as unreadable — and a leading space
on its single body line. The leading space defeats `project_token()`'s
`awk -F= '$1 == k'` match, because `" ronaldlokers/homelab"` is not
`"ronaldlokers/homelab"`. Verified against the real note: no match.

The title fault is loud; both consumers print "could not read". The body fault
is silent and lands far from its cause. `devpod up` succeeds, the container
comes up, and only `gh` fails inside it, with a credentials error that points
at GitHub rather than at a space in a note. So the wrapper is made tolerant of
surrounding whitespace as part of this change.

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

**`home/dot_local/bin/executable_devpod`** — make the lookup in
`project_token()` tolerant of surrounding whitespace. The current one-liner is
replaced by a short awk program:

```awk
awk -v k="$key" '
{
	line = $0
	sub(/^[[:space:]]+/, "", line)
	sub(/[[:space:]]+$/, "", line)
	eq = index(line, "=")
	if (eq == 0) next
	lk = substr(line, 1, eq - 1)
	val = substr(line, eq + 1)
	sub(/[[:space:]]+$/, "", lk)
	sub(/^[[:space:]]+/, "", val)
	if (lk == k && val != "") { print val; exit }
}' "$tokens"
```

Three things about this shape are deliberate. It drops `-F=` and splits on the
**first** `=` via `index`/`substr`, so a value containing `=` survives intact.
It never assigns to `$1`, because assigning to a field rebuilds `$0` joined by
`OFS` — which would replace the `=` separators with spaces and corrupt the
value. And a line with no `=` is skipped, which drops blank lines; the awk-side
key is named `lk` rather than `key` only to keep it visibly distinct from the
shell's `$key` passed in as `k`.

Comment lines are not special-cased and do not need to be. One containing no
`=` is skipped outright, and one containing an `=` yields a key beginning with
`#`, which cannot equal an `owner/repo` string.

The value is still required to be non-empty, preserving today's behaviour that
an entry present but valueless passes no token rather than an empty one.

**`mise.toml`** — add `"devpod project-tokens"` to the title list in
`[tasks.secrets-check]`. The list is hardcoded; an item missing from it is
unreadable-but-silent until a machine is rebuilt, which is the failure that
task exists to catch.

**`tests/restore-secrets.bats`** — add the item to the `$ITEMS` fixture, to the
loop asserting every target was written, and an `--item-title devpod
project-tokens` assertion against `$STUB_LOG` mirroring the `devpod
dotfiles-env` one. The empty-fetch and failed-fetch branches are already
covered generically by the existing tests; the restore change introduces no new
branch.

**`tests/devpod-wrapper.bats`** — new file. Nothing currently tests
`executable_devpod`, so this is not an extra case on an existing harness; it
needs its own fixture, and that cost is part of this change rather than a
footnote to it. The setup:

- a fake `$HOME` with a stub at `$HOME/.local/libexec/devpod` that records its
  arguments and, when handed `--workspace-env-file`, copies that file's
  contents to the log before the wrapper deletes it;
- a temporary git repository with a push remote on `origin`, since
  `project_token()` keys on the push remote and not the directory;
- a `project-tokens` file written per case.

Cases: a clean entry matches; a leading space on the line matches; a trailing
space matches; spaces either side of the `=` match; a value containing `=`
comes back whole; an entry with an empty value passes no token; a
non-matching repo passes no token; and an absent `project-tokens` file passes
no token. The last three assert that no `--workspace-env-file` flag reaches the
binary at all.

The stub is what makes this testable without invoking the real DevPod binary or
starting a container. The wrapper's `exec` of `$real` is the seam.

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

**`docs/design-notes.md`** — under "Git in a container uses SSH, not a token",
the sentence describing `project-tokens` as `owner/repo=token`, mode 0600,
"absent by default" is now wrong on the last clause. It becomes restored from
the vault like the other file-shaped secrets, holding no entries on a machine
that has minted none. The whitespace tolerance and its reason — the file is
authored in a web textarea now — belong here too, since this is where the
per-repo token design is explained.

## Prerequisite — satisfied 2026-07-31

The `devpod project-tokens` note must exist in the Dotfiles vault, non-empty,
titled exactly that. An empty note trips the "came back empty" guard and warns
on every apply.

Created and verified. It holds one entry for `ronaldlokers/homelab`; the title
carries no trailing space, the body has no leading space, and the wrapper's
lookup matches it. Both faults described above were found and corrected during
that verification.

Creating the note is a manual step. Nothing in this repo writes to the vault.

## Not in scope

Verifying the note surfaced an unrelated fault on this host: `pass-cli` held
local state claiming an active session while every request failed with
`non-existent session`, so *all* secret restores had been silently no-oping.
`pass-cli logout` (which force-logged-out, reporting `Local encryption key not
found but local data exists`) followed by a fresh login from the cached
bootstrap PAT fixed it.

Nothing in the repo would have reported this: `secrets-check` is the only thing
that would catch it and it is manual. That is a real gap, in the same area, and
it is not this change's job. Left as a separate piece of work.

## Verification

- `mise run test` — the bats suite, including `tests/devpod-wrapper.bats`.
- `mise run lint` — shellcheck over the rewritten `executable_devpod`.
- `mise run check` — lint, tests, gitleaks, clean-HOME verify.
- `mise run secrets-check` — manual, needs a Proton session; proves the new
  item is readable under its exact title.

Not covered by any of the above, and worth stating plainly: nothing verifies
that a token in the file is still *live*. A revoked PAT parses, matches, and is
passed into the container exactly like a good one. This mirrors the existing
limitation on the `dotfiles-env` PAT recorded in `docs/design-notes.md`.
