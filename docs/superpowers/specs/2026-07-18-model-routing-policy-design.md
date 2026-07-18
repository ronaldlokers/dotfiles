# Model routing policy + allowlist — design

Date: 2026-07-18
Status: approved (design), pending implementation plan

## Goal

Give Claude Code a configurable, mostly-automatic way to switch models per task
class — optimising usage-limit burn while keeping quality — plus an allowlist of
which models the agent may pick from, editable both persistently and mid-session.

## Constraints (why the design is shaped this way)

- **Auth = Anthropic subscription (Pro/Max, OAuth login).** The OAuth token only
  talks to Anthropic's endpoint. An external router/proxy (claude-code-router,
  LiteLLM) cannot re-auth the subscription to route requests elsewhere, so
  proxy-based routing is out.
- **"Cost" = staying under usage limits, not dollars.** Savings come from keeping
  cheap work off the expensive model, not from per-token price.
- **No native per-task main-model switching.** Claude Code cannot swap the running
  main-loop model mid-conversation. The only native lever is delegating discrete
  work to **subagents** pinned to a chosen model (the `Agent` tool `model` param
  accepts aliases `opus | sonnet | haiku | fable`).
- **Enforcement is soft.** The allowlist is guidance the agent follows, not a wall.
  There is no proxy to reject a disallowed model. Blocking a model = removing it
  from the allowlist; the agent then never spawns a subagent on it.
- **Repo is chezmoi-managed dotfiles.** Managed files are edited at source, then
  `chezmoi apply`. Repo-only files are listed in `.chezmoiignore`. Non-interactive
  `chezmoi apply` (devpod/CI) must keep working.

## Approach

**Delegation policy, Opus main, delegate DOWN.** Main loop stays Opus for maximum
quality on decisions and the interactive conversation. The agent offloads
bounded/mechanical/creative-deliverable work to subagents pinned to the cheapest
adequate enabled model. An allowlist governs which models may be chosen; a
fallback ladder handles disabled models.

## Routing map

| Task class | Preferred model | Fallback ladder |
|---|---|---|
| Creative design deliverables: spec-writing, design drafts, approach generation, UI mockups + visual/aesthetic direction | Fable subagent | Opus |
| Live design/brainstorm dialogue, reasoning, architecture, hard debugging | Opus (main) | — (cannot delegate an interactive conversation) |
| Routine implementation (including UI code), code review, moderate edits | Sonnet subagent | Opus |
| Mechanical: search, file-locate, format, log-grep, rename | Haiku subagent | Sonnet → Opus |

**General fallback rule:** if a task's preferred model is not in `enabled`, step
UP the quality ladder to the next enabled model. Example: `disable fable` →
creative design deliverables route to Opus automatically.

**Prefer existing cheap subagents** for their jobs (e.g. `Explore`,
`cavecrew-investigator` for read-only location work) rather than spawning generic
ones.

### savings_mode knob

- **conservative** — only clearly-mechanical, read-only work leaves Opus (→ Haiku).
  Everything else stays Opus.
- **balanced** (default) — the routing map above as written.
- **aggressive** — push routine implementation to Haiku where adequate; reserve
  Opus for genuinely hard reasoning; keep creative deliverables on Fable.

## Components

### 1. Allowlist config block — in `dot_claude/CLAUDE.md`

Embedded in the global `~/.claude/CLAUDE.md` (auto-loaded every session, so the
current allowlist is always in context — no reliance on the agent proactively
reading a separate file). Delimited by markers so the slash command can edit it
surgically:

```
<!-- MODEL-POLICY:START -->
main: opus
enabled: [opus, sonnet, haiku, fable]
savings_mode: balanced   # conservative | balanced | aggressive
<!-- MODEL-POLICY:END -->
```

### 2. Routing policy prose — same `dot_claude/CLAUDE.md`, under the block

A short standing instruction encoding: the routing map, the general fallback
rule, the savings_mode semantics, "prefer existing cheap subagents", and the
two override behaviours (below). This is what makes the switching automatic —
it is a standing instruction the main agent follows when deciding whether to
delegate.

### 3. In-session control

- **Persistent — `/model-policy` slash command** (`dot_claude/commands/model-policy.md`).
  Supports `show`, `disable <model>`, `enable <model>`, `set savings <mode>`.
  It edits the **source** `dot_claude/CLAUDE.md` (between the markers) and runs
  `chezmoi apply` — never edits `$HOME` directly, per repo rules. Changes persist
  across sessions.
- **Ephemeral — plain chat.** Requests like "stop using Fable" or "save tokens"
  are honoured for the rest of the current session only; nothing is written to
  disk. The policy prose instructs the agent to treat casual chat requests as
  session-scoped and the slash command as persistent.

## Files touched

- `dot_claude/CLAUDE.md` — add the `MODEL-POLICY` marker block + routing policy prose.
- `dot_claude/commands/model-policy.md` — new slash command.
- `.chezmoiignore` — add `docs` (this spec is a repo-only doc). *(done)*

## Honest limitations

- **Soft enforcement only.** If the user keeps everything in the bare main Opus
  loop and never lets work fan out to subagents, nothing is saved. The win is
  real only when tasks actually delegate.
- **No hard block.** The allowlist is guidance, not a proxy-level wall.
- **Interactive work can't be offloaded.** The live design/brainstorm conversation
  necessarily runs on the main model (Opus); only discrete deliverables from it
  (e.g. writing the spec) delegate to Fable.

## Optional v2 (out of scope now)

- A `SessionStart` hook that injects the live config into context and/or logs
  which model each subagent used, for telemetry on actual savings.

## Verification

Before pushing, verify against a clean HOME the way CI does:

```
HOME="$(mktemp -d)" chezmoi apply --source "$PWD" </dev/null
```

Confirm the `MODEL-POLICY` block and `/model-policy` command land correctly and
non-interactive apply still succeeds.
