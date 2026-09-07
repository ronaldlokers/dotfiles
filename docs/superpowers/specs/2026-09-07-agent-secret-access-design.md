# Giving agents access to Proton Pass secrets

**Status:** design, approved 2026-09-07. Not yet implemented.

**Working document.** Per `CLAUDE.md`, spec and plan pairs are pruned once the
work ships; the reasoning worth keeping moves to `docs/design-notes.md` and what
actually happened stays in the commits. Delete this file when the work lands.

## The problem

An agent session needed the fizzy API token and could not get it. The
investigation is worth recording because the cause was not where anyone looked
first.

Nothing was wrong with Proton Pass, the vault, or the bootstrap PAT. The
bootstrap PAT was present at 0600 with no `.rejected` alongside it, and
`pass-cli info` succeeded from a sibling session on the same host as the same
user at the same moment. There were no `deny` rules in project or user settings.

The cause was the auto-mode classifier. A session running
`permissions.defaultMode: "auto"` has each call adjudicated by a classifier
rather than by a human, and `~/.claude/settings.json`'s `autoMode.environment`
block names Proton Pass as the secrets store and the Dotfiles vault as a
sensitive data location. So anything named `pass-cli` reads as secrets-store
access and is blocked before the process spawns. The tell was that
`pass-cli run --help` was blocked too: a help flag touches no vault, so the
block is on the binary's name rather than on what the command does.

A session in prompting mode is unaffected, because a human approves each call.
That difference — not anything about the vault — is the whole delta.

The naive fix is to grant `Bash(pass-cli run:*)` in the global baseline. That is
rejected here: it is unbounded, allowing any secret from any vault to be
injected into any command in any session, which is a *wider* capability than the
one the classifier blocked.

## What this design does and does not buy

It does not buy concealment. The agent runs as `ronald`. Any secret reachable by
a process it spawns is reachable by it — `/proc/<pid>/environ`, the config file,
the session directory. A wrapper script, `fnox exec` and `pass-cli run` all share
this ceiling. Sold as "the agent cannot see the token", the design would be sold
wrong, and someone would later lean on a guarantee that was never there.

What it buys, in order of value:

1. **Blast radius.** The only credential on this machine today is the bootstrap
   PAT: the entire vault, no expiry. An agent token scoped to a vault that holds
   only agent-readable secrets, expiring monthly, replaces "everything, forever"
   with "the things agents are meant to have, briefly".
2. **Attribution.** `PROTON_PASS_AGENT_REASON` is mandatory on every read through
   an agent token and lands in `pass-cli agent monitor`. After an incident it is
   possible to answer what was read, when, and what reason was given — which is
   not possible for anything today.
3. **Transcript hygiene.** The value goes into a child process's environment
   rather than into the agent's context, so it does not reach a transcript, a
   pasted log, or a PR body. This is the failure that actually happens.
4. **Revocation.** `pass-cli agent access revoke` is one command and does not
   disturb the human session.

The honest summary is least privilege and an audit trail, not a sandbox. Raising
the ceiling — the agent running as its own uid, or in a container with the
credential injected from outside — is a different and much larger design, and is
explicitly out of scope here.

## Why fnox, and why not a wrapper

The first proposal was a wrapper in `~/.local/bin` following the
`executable_devpod` pattern: fetch the token, exec the real binary, never put
the value in argv. That is a sound pattern and it is what this repo already does
for the DevPod tokens.

It was dropped in favour of fnox for three reasons. fnox has a first-class
Proton Pass provider that shells out to `pass-cli`, so the values stay in Proton
Pass and this does not become a second secrets store — which `CLAUDE.md` forbids.
The provider explicitly supports Proton agent tokens and requires
`agent_reason`, so it composes with the agent-token model rather than working
around it. And it removes a bespoke script that would otherwise need writing,
testing, gating and maintaining.

fnox is in the mise registry as `github:jdx/fnox`, MIT, Rust, by the author of
mise — which this repo already depends on throughout. The provider is read-only
(`get`, `exec`, `provider test`), which for this use is a feature.

Proton's `pass-cli run` was the other candidate. It masks secrets on stdout and
stderr by default, which fnox does not document — see the probe results, which
found the CLI does not mask and the MCP tool does.

## Design

### The Agents vault

Agent-readable secrets live in their own vault, `Agents`. The grant is then
vault-scoped, and that is the point: adding a secret an agent may read means
putting it in that vault, with no second step to remember and no per-item grant
to maintain at eleven at night. The boundary is the vault rather than a list
somebody has to keep accurate.

This is the same move as the existing Dotfiles/Work split, on a different axis.
That split separates *machines*; this one separates *who is asking*. The
reasoning in `home/.chezmoitemplates/vault-name` applies unchanged — "same vault,
different items would not prevent it, a vault-scoped PAT reads all of it" — which
is precisely why the boundary has to be a vault and not a convention.

Granting the `Dotfiles` vault instead was considered and rejected. It holds the
`bootstrap PAT` item, whose blast radius `docs/revocation.md` records as "the
whole vault, therefore everything below". An agent that can read it holds a
permanent, unexpiring, full-vault credential, at which point the agent token's
expiry and revocation are decorative. That vault also holds the git signing key's
private half, the sops age keys, `gh hosts.yml`, the devpod PATs, and the SSH
keys — which `proton-ssh-load` selects by *type*, not title, so an agent
enumerating the vault finds them without knowing any names.

An `Agents` vault has no such inhabitant by construction, so expiry and
revocation keep working.

Known limit: this is gated to personal machines, so there is no `Work Agents`
counterpart. If a work machine ever needs agent access, that is a new decision
and a new vault, not a widening of this one.

### Identity: the agent token

Created once, by hand:

    pass-cli agent create fizzy --expiration 1m --vault Agents
    pass-cli agent access grant fizzy --vault-name Agents --role viewer

Scoped to the `Agents` vault, which is safe because of what that vault contains
rather than because the grant is narrow. `--role viewer` is read-only and is also
the default, stated explicitly because `editor` and `manager` would let an agent
write to the vault — and an agent that can write to the vault it reads from can
grant itself things later.

One agent per consumer, not one shared agent. Separate tokens mean
`pass-cli agent monitor` attributes reads to a named caller, and revoking one
does not disturb the others.

Stored the way every other secret here is stored — as a note item, with one line
added to `home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl`.

**In the `Dotfiles` vault, deliberately not in `Agents`.** The agent's own
credential must not sit inside the vault that credential can read. With one agent
this is merely circular; with two it is an escalation, because either agent could
read the other's token and assume its identity, defeating the per-agent
attribution above. Agent tokens are restored by the human session at apply time,
so `Dotfiles` is the right home for them.

    restore "fizzy agent token" "$HOME/.config/pass-cli-agent-fizzy" 600 personal

so it is fetched with the human session at apply time and lands at 0600.
`dotfiles-secrets-check` picks it up with no further work, because its item list
is derived from the `restore` lines rather than hand-kept.

The fizzy secret itself is *not* covered by that check, and should not be: it is
never restored to disk, it is referenced from the project's own `fnox.toml`
rather than from this tree, and its health is the project's concern. What this
repo checks is what this repo places — the agent token.

The fourth argument is the profile gate — `restore()` takes an optional profile
name and returns early when the machine's set does not contain it, which is how
`sops age keys` and the two devpod token files are already restricted to personal
machines. So the gating described below needs no new mechanism, only that
argument.

Each agent gets its own `PROTON_PASS_SESSION_DIR`, as Proton's own agent
instructions call for, so an agent session cannot ride on the human's and is not
invalidated by a human `pass-cli logout`.

A one-month expiry means this token *will* expire, and would otherwise do so
silently. `dotfiles-secrets-check` already warns on the bootstrap PAT's expiry;
the same warn tier covers this, turning a mystery failure into a notification.
Renewal is `pass-cli agent renew`.

One instruction from Proton's own agent guidance is deliberately not followed. It
tells the agent "CRITICAL: Save the PAT token in a safe place", which is an
instruction to persist a credential at the agent's discretion. The token is read
from the restored file per invocation and never stored by the agent.

### Reference and injection

`fnox.toml` lives in the fizzy project, not in this repo. It holds references
only, so it commits:

```toml
[providers.protonpass]
type = "proton-pass"
agent_reason = "unspecified — caller did not set PROTON_PASS_AGENT_REASON"

[secrets]
FIZZY_API_TOKEN = { provider = "protonpass", value = "pass://Agents/Fizzy/api_token" }
```

The static `agent_reason` is a deliberately useless fallback. A fixed string in
config means every audit entry reads the same, which is attribution in name
only. fnox passes Proton's environment variables through, so the caller sets
`PROTON_PASS_AGENT_REASON` per invocation and that is what reaches
`agent monitor`. Wording the fallback as "unspecified" makes a lazy caller
visible in the audit log rather than invisible.

The reference is an explicit `pass://` URI naming the vault, not a bare item
name. Bare references default to the `password` field and depend on a configured
default vault; implicit vault resolution has already caused a bug here once.

This repo's share is two lines: pin `fnox` in
`home/dot_config/mise/config.toml.tmpl`, and add the `restore` line above. The
restore is gated by its fourth argument; the mise pin is gated the way that file
already gates personal-only tools. A work machine opting into this should be a
decision, not a side effect.

### Delivery: the MCP broker, with `get_secret` denied

The agent reaches secrets through `fnox mcp`, a stdio MCP server, rather than
through a `Bash` call. Configured in the consuming project's `.mcp.json`:

```json
{
  "mcpServers": {
    "fnox": { "command": "fnox", "args": ["--if-missing", "error", "mcp"] }
  }
}
```

and in that project's `.claude/settings.json`:

```json
{
  "permissions": {
    "allow": ["mcp__fnox__exec"],
    "deny":  ["mcp__fnox__get_secret"]
  }
}
```

**The allow-list is the load-bearing half, not the deny.** The server exposes two
tools today, `exec` and `get_secret`, and a deny-list naming `get_secret` is
correct until the day fnox ships a third tool — at which point it is available by
default and nobody notices. Allowing only `exec` means anything new arrives
unavailable until somebody decides otherwise. The explicit deny stays anyway,
because it documents which tool is the hazard and why.

`--if-missing error` sits in the server's own `args` rather than at a call site,
so it cannot be omitted per-invocation. The probe results show it is mandatory:
the MCP server has the same fail-open default as the CLI, returning
`RAN with []` and `isError: false` when the secret could not be resolved.

This removes the Bash grant entirely, and with it the classifier problem that
started all of this — not by working around the classifier but by not needing the
`pass-cli` command surface at all. `exec` also takes an argv array and invokes no
shell unless one is passed explicitly, which is a smaller injection surface than
a shell string.

`enableAllProjectMcpServers` is unset, so a project's MCP server requires
approval the first time it is seen. That is a useful gate and should stay unset.

#### What redaction is, and is not

The MCP `exec` tool redacts secret values out of the content it returns. Measured:

    exec ["sh","-c","echo VIA-EXEC: $PROBE_SECRET"]
      -> "VIA-EXEC: [REDACTED]"

The CLI's `fnox exec` does not do this — the same sentinel came back verbatim on
both stdout and stderr — so this is a real advantage of the MCP path and the main
reason to prefer it.

It is literal string matching, and it is not a security control:

    exec ["sh","-c","echo $PROBE_SECRET | rev"]
      -> "b2a3f9-EULAV-lenitnes"

Redaction stops the accident, not the intent. This is the ceiling from the first
section, demonstrated rather than asserted: an agent that wants the value can
have it, and the design's value is scope, expiry and attribution rather than
containment. Anyone tempted to describe this as a sandbox should read that
transcript first.

### What lands where

Most of this design is not in this repository, and the implementation plan should
say so plainly.

**This repo:** the `fnox` mise pin, and the `restore` line placing the agent
token. Two lines, both gated to `personal`.

**The consuming project:** `fnox.toml` with the secret reference, `.mcp.json`
with the server, and `.claude/settings.json` with the allow and deny. None of it
belongs here — a per-project capability configured centrally is the thing this
design is trying not to build.

**Neither, and done by hand once:** creating the `Agents` vault, creating the
agent token, granting it, and putting the token in the `Dotfiles` vault so the
restore line has something to fetch.

### Containers

Containers get nothing from Proton by design, and the `restore` line sits inside
the host-only path, so the token never lands there.

The requirement is that the broker fails loudly there. Silently running fizzy
with `FIZZY_API_TOKEN` unset is the same shape as an empty fetch overwriting a
good file — a wrong answer delivered with exit 0 — which this repo has an
explicit rule against.

This is exactly what `--if-missing error` buys, and the probes confirmed the
default does the wrong thing on both paths: the CLI runs the command and exits 0,
and the MCP server returns `RAN with []` with `isError: false`. Because the flag
lives in the server's `args` rather than at a call site, the container case is
not a special path at all — it is the same guard as an expired agent token or a
revoked grant, and there is no per-invocation way to forget it.

### Testing

This repo's testable surface is small, because most of the design lands
elsewhere. What it can and should cover:

1. The agent token is restored on a personal machine, at mode 600.
2. It is **not** restored on a work machine or in a container — the profile gate
   on the `restore` call.
3. A failed or empty fetch leaves any existing token file alone, which is the
   existing `restore` contract and already covered by
   `tests/restore-secrets.bats`; the new line needs to be shown to inherit it
   rather than assumed to.
4. `dotfiles-secrets-check` includes the new item, which follows from its derived
   item list but should be asserted rather than trusted.

Each mutation-proved: revert the guard the case covers and confirm that specific
assertion fails on output, not on a missing symbol.

What this repo cannot test is the MCP wiring, the deny rule, or fnox's
fail-closed behaviour — those live in the consuming project. The probe results
below are the evidence for the parts no test here will cover, which is why they
are recorded in this document rather than left in a terminal.

## Probe results

Both open questions were answered on 2026-09-07 against fnox 1.35.1, run
ephemerally through `mise x` with a scratch age provider so that neither the
vault nor `$HOME` was involved.

### `fnox exec` fails OPEN, and this is the load-bearing finding

With a provider that cannot resolve, `fnox exec` logs a warning, runs the command
anyway with the variable unset, and exits 0:

    WARN fnox_core::secret_resolver: Error resolving secret 'PROBE_SECRET': ...
    COMMAND-RAN
    var=[]
    rc=0

That is a wrong answer delivered with exit 0 — the same shape as an empty fetch
overwriting a good secret, which this repo has an explicit rule against.

The cause is a default, not a limitation. `--if-missing` is a global flag taking
`error`, `warn` or `ignore`, and the default behaves as `warn`. Measured:

| invocation | broken provider | good provider |
| --- | --- | --- |
| `fnox exec` | runs, `rc=0` | runs, `rc=0` |
| `fnox --if-missing error exec` | **does not run, `rc=1`** | runs, `rc=0` |

**So every invocation in this design must carry `--if-missing error`.** It is not
a nicety; without it the container case degrades to running fizzy with an empty
token and reporting success, and so does an expired agent token.

`fnox check` is **not** a substitute, and this is worth recording because it
looks like one. Against the same broken provider it prints "✓ Configuration is
healthy" and exits 0 — it validates the shape of the config, not whether the
secrets actually resolve. `fnox get <NAME>` does fail closed (`rc=1`) and would
work as a preflight, but `--if-missing error` is one flag rather than a second
fetch.

### Masking: the CLI does not, the MCP tool does

These differ, and the difference is why the MCP path was chosen.

The **CLI** `fnox exec` does not mask. A sentinel value came back verbatim on
both stdout and stderr from the child process, where `pass-cli run` masks by
default.

The **MCP** `exec` tool redacts the value out of the content it returns
(`VIA-EXEC: [REDACTED]`). See the delivery section for the measurement, and for
the demonstration that the redaction is literal string matching and falls to a
one-word transformation.

The design does not depend on masking either way — that is why it was treated as
unverified rather than designed around. The MCP redaction is a genuine
improvement against accidental echo, and nothing more should be claimed for it.

### Noted for later, deliberately out of scope

fnox 1.35.1 also ships `fnox proxy` ("Broker credentials into destination-scoped
HTTPS requests") and `fnox lease` (ephemeral credential leases). `fnox mcp` was
in this list when the probes were run and has since become the design's primary
delivery path.

`proxy` is the thing the first section says is out of scope: it would let an
agent make authenticated HTTPS requests without ever holding the credential,
which raises the ceiling rather than documenting it. It is the natural next step
if the ceiling ever needs raising, and it does not invalidate anything here — the
`Agents` vault, the scoped agent token, and the audit trail all carry over. It
should be its own design, not an amendment to this one.

## Rejected alternatives

**`Bash(pass-cli run:*)` in the global baseline.** Unbounded: any secret, any
vault, any command, any session. Wider than the capability the classifier
blocked.

**A bespoke wrapper in `~/.local/bin`.** Works, and matches the existing
`executable_devpod` pattern, but uses the human's full-vault credentials to fetch
one item, produces no audit trail and no expiry, and adds a script to maintain.
Strictly worse once the Proton agent feature is in play.

**fnox as a replacement secrets store.** Not applicable — the Proton Pass
provider means values stay in Proton Pass and fnox is a reference and injection
layer over it. Had fnox required its own store, it would have been rejected
under the single-store rule.

**The CLI path: `fnox --if-missing error exec -- fizzy`, with a `Bash(fnox exec:*)`
grant.** Viable, and simpler — no MCP config, and no `get_secret` tool to
remember to deny, so forgetting something means it stops working rather than
quietly leaking. Not chosen because it needs a Bash grant, and because the CLI
`exec` does no redaction at all, so an accidental echo goes straight into the
transcript. Recorded as the fallback if the MCP wiring proves awkward.

**A vault-scoped grant on the `Dotfiles` vault.** Rejected for the reason given
under "The Agents vault": it contains the `bootstrap PAT`, so the grant is
self-escalating and makes expiry and revocation meaningless.

**Per-item grants against the `Dotfiles` vault.** Sound, and the first version of
this design. Rejected because the friction is where it decays: every new secret
needs a manual grant, and the second time that is needed under time pressure the
`--vault-name Dotfiles` shortcut is right there. A boundary that depends on
nobody ever taking the shortcut is not a boundary.

**Agent reads the item directly with `pass-cli item view`.** Simplest, and still
gets the audit trail, but the value enters the agent's context and therefore its
transcript — losing the third of the four benefits for no saving.
