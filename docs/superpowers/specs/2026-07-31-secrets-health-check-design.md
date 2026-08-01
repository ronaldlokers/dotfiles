# A scheduled health check for the Proton Pass path

2026-07-31

## Problem

Three ways the vault path broke on one machine in one afternoon, and what
reported each:

| Fault | What happened | What said so |
| --- | --- | --- |
| `pass-cli` session dead | Every restore skipped; `chezmoi apply` exited 0 | One line mid-apply, scrolled past |
| Stale `pass://` share id | Apply aborted at `.config/git/allowed_signers` | A 422 naming a git config file |
| Item title typo in `mise.toml` | Nothing, until a rebuild | Nothing |

`mise run secrets-check` exists to catch the first and third. Nothing runs it.
It is manual, and a check you must remember to run is a check that reports a
fault after it has already cost you something.

The second fault is the interesting one, because `secrets-check` was **green
while the apply was broken**. It was run during this session and returned eight
readable items at the same moment `chezmoi apply` was failing on the 422. It
fetches by vault name and item title; the broken reference was an id-based
`pass://` URI in a template. Different code path, so no signal.

That is the finding worth designing around: a health check that does not
exercise the path it protects gives false confidence. Item readability and
template rendering are separate paths, and only the first has ever been checked.

The same gap has a second instance, independent of the 422. `secrets-check`
tests `git signing key` on its `private_key` field, because that is what the
ssh-key consumers need. `signing-pubkey` reads `public_key` from that same item.
Delete `public_key` and `secrets-check` stays green while
`.config/git/allowed_signers` breaks.

## Decision

One script, checking both paths, run on a timer and reachable by hand.

Rejected: scheduling the existing `secrets-check` unchanged. Cheapest, and by
the evidence above it would have stayed green through the fault that actually
broke the apply.

Rejected: a full `chezmoi diff` dry-run as the render check. It cannot drift out
of date and catches every template fault, not just Proton ones — but that
breadth is the problem. An unrelated template error would raise a notification
saying secrets are broken, and the check hits the vault for every reference on
every run.

## Design

### One implementation, two entry points

The check lives at `home/dot_local/bin/executable_dotfiles-secrets-check`, a
plain file rather than a `.tmpl`, so `mise` and the bats suite can both invoke
it through `sh` exactly as they already invoke `executable_devpod`. A systemd
user timer runs the applied copy; `mise run secrets-check` calls the source-tree
copy, so the repo task never depends on an applied `$HOME`.

The shell block currently inline in `mise.toml`'s `[tasks.secrets-check]` moves
into that script. Two copies of this logic would drift, and the drift would be
invisible for the same reason the original fault was.

### Half one: items readable

The existing loop — for each title, fetch the field its consumer uses and
require a non-empty result. Report byte counts, never contents.

Field selection stays as it is (`private_key` for the ssh and signing keys,
`note` for everything else), because that is what the restore script and
`proton-ssh-load` consume. The `public_key` gap described above is covered by
half two rather than by widening this loop, since rendering the template is a
truer test than fetching a field and hoping the template asks for that one.

### Half two: templates render

Every template calling `protonPass` must render non-empty. The list is derived
by grepping the source tree, not hardcoded — a new Proton-backed template is
covered without anyone remembering to register it.

Today that list has exactly one member, `.chezmoitemplates/signing-pubkey`,
included by `dot_config/git/allowed_signers.tmpl`. This half is narrow on
current code. It is also precisely the half that would have caught the fault
that took the apply down, and it grows on its own.

### Gating

Exit 0 and stay silent where Proton is legitimately absent: inside a container,
and on a host with no `pass-cli`. Both are ordinary states, and the repo already
treats them that way everywhere else.

Container detection is a runtime probe (`/.dockerenv`, `/run/.containerenv`),
not a template gate. The script is deliberately not a `.tmpl`, so it cannot ask
chezmoi at render time the way `is-container` does.

On a host that has `pass-cli` but where `pass-cli info` fails, alarm. That is
the dead-session case. Treating it as ordinary is what let it hide through an
entire session of applies.

### Reporting

Two distinct outputs, which the first draft of this spec conflated:

- **The report** goes to stdout on every run — one row per item with its byte
  count, one per template rendered. This is what makes `mise run secrets-check`
  useful by hand, and under the timer it lands in the journal.
- **The alarm** fires only on failure: `notify-send` when a session bus is
  present, otherwise an echo the journal picks up. Identical to
  `dotfiles-update-check`, including the reason for the fallback.

Titles, template paths and byte counts only. Never contents, in either output.

### Failure semantics

The script exits non-zero on a real fault, so `mise run secrets-check` stays
usable as a gate. The systemd service carries `SuccessExitStatus=0` and treats
the notification as the signal, matching `dotfiles-update-check.service`.

### Scheduling

Weekly with jitter, against the update-check's daily. Every run hits the network
once per vault item. A fault here costs a rebuild, not an outage, so weekly
detection is proportionate. `Persistent=true` so a machine that was off still
checks once it wakes.

## Changes

- **Create** `home/dot_local/bin/executable_dotfiles-secrets-check` — both
  halves, the gating, the reporting.
- **Create** `home/dot_config/systemd/user/dotfiles-secrets-check.service` and
  `.timer` — modelled on the update-check pair.
- **Create** `home/.chezmoiscripts/run_onchange_after_12-enable-secrets-check.sh.tmpl`
  — the same enable script shape as `run_onchange_after_11`, including its
  systemd-user-socket probe and its unit-visibility check, both of which exist
  so a redirected-HOME apply does not fail. Numbered `12` to sit with the other
  two enable scripts at `10` and `11`, not with the `run_after_` sequence.
- **Modify** `mise.toml` — `[tasks.secrets-check]` becomes a call to the script.
- **Create** `tests/secrets-check.bats`.
- **Modify** `README.md` and `docs/design-notes.md` — record the check and, in
  design-notes, why it has two halves.

## Testing

`tests/secrets-check.bats`, reusing the `pass-cli` stub already in
`tests/helpers.bash`, which drives readable, unreadable and empty items through
`PASS_ITEM_DIR` and `PASS_VIEW_RC`.

- every item readable and every template rendering → exit 0, a report on stdout,
  and no alarm raised
- one item unreadable → non-zero, names that title, does not name the others
- an item returning empty → non-zero (empty is a failure that exited 0)
- `pass-cli info` failing on a host → non-zero, reported as a dead session
  rather than as unreadable items
- `pass-cli` absent → exit 0, silent
- inside a container → exit 0, silent
- a `protonPass` template rendering empty → non-zero, names the template
- no contents ever reach stdout, stderr or the notification — assert against a
  fixture whose body is a known sentinel

## Limits, stated rather than discovered later

- **CI still cannot run any of this.** Both halves need a live Proton session.
  This stays manual-plus-timer, unchanged from today.
- **A machine that is off learns nothing.** `Persistent=true` means it checks on
  wake, not that it checked on time.
- **Weekly detection is still detection after the fact.** This shortens the
  window between a vault fault and knowing about it; it does not prevent an
  apply from meeting the fault first.
- **The render half is one template today.** It covers the fault that occurred
  and grows by grep, but it is not broad coverage of the vault path.

## Not in scope

Single-sourcing the item titles, so the `secrets-check` list and the restore
script's `restore` lines cannot disagree. That is the third fault in the table
and the agreed next piece of work after this one. This spec deliberately leaves
the title list where it is; moving it and adding the check in one change would
mix a behavioural change with a structural one.
