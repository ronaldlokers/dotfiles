# Deriving the vault item list instead of declaring it

2026-08-01

## Problem

`dotfiles-secrets-check` carries a hardcoded list of eight vault item titles.
Six of them are also written down somewhere else, and nothing makes the copies
agree. A typo in the check's copy is invisible: the bats suite stays green,
because only a live `mise run secrets-check` against the real vault would notice,
and nothing in CI runs that.

Investigating turned up that the eight titles are not one list. They are three
different things:

| Titles | Named by a consumer? | Where |
| --- | --- | --- |
| `sops age keys`, `gh hosts.yml`, `sugarrush config`, `devpod dotfiles-env`, `devpod project-tokens` | yes | `restore "…"` lines in `run_after_14-restore-secrets.sh.tmpl` |
| `git signing key` | yes | the `pass://Dotfiles/git signing key/public_key` URI in `.chezmoitemplates/signing-pubkey` |
| `ssh auth key`, `aur ssh key` | **no** | nothing |

The last row is the interesting one. `proton-ssh-load` does not select keys by
title — `executable_proton-ssh-load:172-174` calls
`pass-cli ssh-agent load --vault-name Dotfiles`, which loads every SSH-key-typed
item in the vault. So those two titles are not a duplicated dependency to
reconcile. They are a hand-maintained assertion about vault contents with no
other copy.

That has consequences in both directions. Rename `aur ssh key` in the vault and
`proton-ssh-load` keeps working perfectly while the check reports a failure — a
false alarm. And the check tests a path the consumer never uses: fetching
`private_key` by title, where the consumer asks `pass-cli` for items by type.
That is the same false-confidence shape as the bug the render half was added to
fix.

## Decision

Derive the six that have a consumer. Replace the two that do not with a check of
what the consumer actually does.

### Half one: derive, do not declare

The check builds its title list at runtime from the two places that genuinely
name items:

- **`restore "<title>"` lines** in `run_after_14-restore-secrets.sh.tmpl`, field
  `note`. These are plain text inside the template, so they can be read without
  rendering it.
- **`pass://<vault>/<title>/<field>` URIs**, scanned over exactly the same file
  set the render half already scans — `.tmpl` files plus everything under
  `.chezmoitemplates` — so there is one definition of "the templates" rather
  than two that can diverge. Title and field both come from the URI, so
  `git signing key` is checked on `public_key`, the field the template actually
  asks for, rather than on whichever field a hand-written list happened to guess.

A title can then only be wrong if the consumer that names it is wrong, which is
the property being bought.

Two details that would otherwise be guessed. **The vault segment of the URI is
parsed but not honoured** — every item this repo uses lives in `Dotfiles`, and
the check already hardcodes that vault for the restore-derived titles; parsing a
second vault out of a URI and querying it would be machinery for a case that
does not exist. If a URI ever names a different vault, the check should fault
rather than silently query the wrong one. And **`git signing key` legitimately
appears in both halves** — once here on `public_key`, once in the ssh half as an
SSH-key-typed item. Those are different fields answering different questions, not
a duplicate to collapse.

**The URI pattern must require the whole three-part shape, not the scheme.**
Grepping for `pass://` alone matches prose: the check script's own comment about
a "stale `pass://` share id" is a false positive, found while writing this spec.
The vault segment has no spaces, the title may, and the field is lowercase and
underscores, giving `pass://[^/"[:space:]]+/[^/"]+/[a-z_]+`. A pattern loose
enough to match the comment would make the check try to fetch an item named
`share id` and report a failure that is really a documentation string.

### The ssh half: ask the consumer's question

`pass-cli ssh-agent debug --vault-name Dotfiles` reports `Total items checked`,
`Valid SSH keys`, and any invalid items with a reason. It is non-mutating — it
does not touch the running agent — and its output carries algorithms and
fingerprints but no private key material. Both were verified before this spec
was written.

The check runs it and faults when `Valid SSH keys` is zero or any item is
invalid, reporting the counts rather than the fingerprints so the weekly journal
line stays stable.

This asks the same question `pass-cli ssh-agent load` answers, which is what
`proton-ssh-load` runs.

### Zero derived titles is a fault

If the greps come back empty — the restore script moved, the `restore` helper
was renamed, the template directory shifted — the check must alarm rather than
report success having checked nothing.

This is the third instance of the same pattern in this codebase, after the
render half's zero-template case and the missing-templates-directory case. It is
stated here as a general rule rather than a third special case: **any derived
input that comes back empty is a fault, because a check that checked nothing
must never be indistinguishable from a check that passed.**

## What this deliberately gives up

`ssh auth key` and `aur ssh key` stop being verified by name. If a key were
swapped for a different one, the count stays 2 and the check stays green.

This is accepted because the count is what the consumer depends on:
`pass-cli ssh-agent load` loads by type, so a swapped key loads exactly as well
as the original. Verifying names would be verifying something no code relies on,
which is how the current false alarm exists. Recorded here rather than
discovered later.

## Changes

- **Modify** `home/dot_local/bin/executable_dotfiles-secrets-check` — replace the
  hardcoded title loop with derivation from the two sources; replace the ssh
  titles with the `ssh-agent debug` check; fault on zero derived titles.
- **Modify** `tests/helpers.bash` — the `pass-cli` stub needs an `ssh-agent debug`
  branch returning a canned summary, driven by environment variables the way the
  existing branches are.
- **Modify** `tests/secrets-check.bats` — the fixture grows a fake restore script
  and fake templates to derive from, replacing the fixed eight-item fixture.
- **Modify** `README.md` and `docs/design-notes.md` — record that the list is
  derived and why the ssh keys are counted rather than named.

## Testing

- titles derived from a fixture restore script are all checked
- a title derived from a fixture `pass://` URI is checked **on the field named in
  the URI**, not on `note`
- a `pass://` string in a comment is not mistaken for an item — the specific
  false positive above, as a regression test
- a `pass://` URI naming a vault other than `Dotfiles` faults rather than being
  queried against the wrong vault
- a title present in the restore script but absent from the vault fails, naming it
- zero derived titles faults, with a message saying derivation found nothing
- `Valid SSH keys: 0` faults
- an invalid ssh item faults and reports its reason
- the ssh half emits no key material — sentinel assertion, as elsewhere
- a successful run still raises no alarm

## Limits

- **CI still cannot run the check**, which needs a live Proton session. The bats
  suite covers derivation and parsing against fixtures; only a manual run proves
  it against the real vault. Unchanged by this work.
- **Derivation couples the check to the restore script's shape.** Rename the
  `restore` helper and derivation silently yields nothing — which is exactly why
  the zero-fault rule above is load-bearing rather than defensive.
- **`ssh-agent debug`'s output format is not a stable API.** If a `pass-cli`
  upgrade changes its wording, the parse breaks. It fails closed — a parse that
  finds no counts is zero, which faults — so the failure is loud, but it is a
  real upgrade hazard worth knowing.
