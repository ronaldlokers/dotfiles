# Model Routing Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a configurable, mostly-automatic model-routing policy + allowlist to the user's chezmoi-managed Claude Code config, so bounded/creative/mechanical work delegates to cheaper-model subagents while the Opus main loop is reserved for reasoning.

**Architecture:** Soft/native, no proxy. An allowlist + savings knob live in a marker-delimited block inside the global `~/.claude/CLAUDE.md` (auto-loaded, always in context). Routing-policy prose beneath it is a standing instruction the main agent follows when deciding whether to delegate. A `/model-policy` slash command edits that block at chezmoi source and re-applies (persistent); plain chat requests are honoured session-only.

**Tech Stack:** chezmoi (dotfiles), Claude Code settings/commands, markdown.

## Global Constraints

- Repo is chezmoi-managed. Never edit files in `$HOME` directly — edit source, run `chezmoi apply`. (source: `~/.local/share/chezmoi`)
- Never commit to `main`. Work on branch `feat/model-routing-policy` (already checked out).
- Commit subjects: conventional-commit, lowercase, imperative (`feat: ...`).
- Verify against a clean HOME the way CI does before pushing: `HOME="$(mktemp -d)" chezmoi apply --source "$PWD" </dev/null`.
- Model aliases the `Agent` tool accepts: `opus | sonnet | haiku | fable`. Never remove `opus` from the allowlist — it is the main model and ultimate fallback.
- The target of the policy block is the GLOBAL config `~/.claude/CLAUDE.md`, whose chezmoi source is `dot_claude/CLAUDE.md` — NOT the repo-root `CLAUDE.md` (which is chezmoiignored).

---

### Task 1: Add allowlist block + routing policy to global CLAUDE.md

**Files:**
- Modify: `dot_claude/CLAUDE.md` (append a new `## Model routing` section)

**Interfaces:**
- Produces: the `<!-- MODEL-POLICY:START -->` / `<!-- MODEL-POLICY:END -->` marker block with keys `main`, `enabled`, `savings_mode`. Task 2's slash command edits between exactly these markers and depends on these key names.

- [ ] **Step 1: Append the section to `dot_claude/CLAUDE.md`**

Append verbatim to the end of the file:

```markdown

## Model routing
<!-- MODEL-POLICY:START -->
main: opus
enabled: [opus, sonnet, haiku, fable]
savings_mode: balanced   # conservative | balanced | aggressive
<!-- MODEL-POLICY:END -->

Main loop run `main` model. Delegate down to cut usage-limit burn. Only spawn
subagents on models in `enabled`. Preferred model not in `enabled` → step up
quality ladder (haiku→sonnet→opus; fable→opus) to next enabled model.

Route by task class:
- Creative design — spec-writing, design drafts, approach-gen, UI mockups +
  visual/aesthetic direction → **Fable** subagent (fallback Opus).
- Live design dialogue, reasoning, architecture, hard debug → **Opus main**,
  never delegate (can't offload an interactive conversation).
- Routine implementation (incl. UI code), code review, moderate edits →
  **Sonnet** subagent (fallback Opus).
- Mechanical — search, file-locate, format, log-grep, rename → **Haiku**
  subagent (fallback Sonnet→Opus). Prefer existing cheap subagents (`Explore`,
  `cavecrew-investigator`) for read-only location work.

`savings_mode`: conservative = only clearly-mechanical read-only work leaves
Opus; balanced = map above; aggressive = push routine implementation to Haiku
where adequate, keep creative on Fable, Opus only for genuinely hard reasoning.

Overrides: `/model-policy` command edits this block + persists (`chezmoi apply`).
Plain chat requests ("stop using Fable", "save tokens") = session-only, write
nothing.
```

- [ ] **Step 2: Apply to a clean HOME and verify the block lands**

Run:
```bash
H="$(mktemp -d)"; HOME="$H" chezmoi apply --source "$PWD" </dev/null \
  && grep -c "MODEL-POLICY:START" "$H/.claude/CLAUDE.md" \
  && grep -q "savings_mode: balanced" "$H/.claude/CLAUDE.md" && echo OK
```
Expected: prints `1`, then `OK`. Non-interactive apply exits 0.

- [ ] **Step 3: Commit**

```bash
git add dot_claude/CLAUDE.md
git commit -m "feat: add model routing policy + allowlist to global CLAUDE.md"
```

---

### Task 2: Add the `/model-policy` slash command

**Files:**
- Create: `dot_claude/commands/model-policy.md` (applies to `~/.claude/commands/model-policy.md`)

**Interfaces:**
- Consumes: the marker block and key names (`main`, `enabled`, `savings_mode`) produced by Task 1.

- [ ] **Step 1: Create `dot_claude/commands/model-policy.md`**

Write verbatim:

```markdown
---
description: View or change the model routing allowlist / savings mode (persists via chezmoi)
allowed-tools: Bash, Read, Edit
---

Manage the `MODEL-POLICY` block in the user's GLOBAL Claude config
(`~/.claude/CLAUDE.md`). Requested change: $ARGUMENTS

Supported requests:
- `show` — print the current `MODEL-POLICY` block.
- `enable <model>` / `disable <model>` — add or remove a model in `enabled`
  (valid: opus, sonnet, haiku, fable).
- `set savings <conservative|balanced|aggressive>` — set `savings_mode`.

Rules you MUST follow:
1. This config is chezmoi-managed. Edit the SOURCE, never `$HOME` directly.
   Find the source with: `chezmoi source-path ~/.claude/CLAUDE.md`
2. Edit ONLY the lines between `<!-- MODEL-POLICY:START -->` and
   `<!-- MODEL-POLICY:END -->`. Leave everything else untouched.
3. Refuse to disable `opus` — it is the main model and ultimate fallback.
4. After editing the source, run `chezmoi apply` so `~/.claude/CLAUDE.md`
   updates.
5. Print the resulting block to confirm the change.
```

- [ ] **Step 2: Apply to a clean HOME and verify the command lands**

Run:
```bash
H="$(mktemp -d)"; HOME="$H" chezmoi apply --source "$PWD" </dev/null \
  && test -f "$H/.claude/commands/model-policy.md" \
  && grep -q "MODEL-POLICY:START" "$H/.claude/commands/model-policy.md" && echo OK
```
Expected: prints `OK`. Non-interactive apply exits 0.

- [ ] **Step 3: Commit**

```bash
git add dot_claude/commands/model-policy.md
git commit -m "feat: add /model-policy slash command"
```

---

### Task 3: Full clean-HOME verification and PR

**Files:** none (verification + PR only)

- [ ] **Step 1: Full clean-HOME apply (matches CI)**

Run:
```bash
H="$(mktemp -d)"; HOME="$H" chezmoi apply --source "$PWD" </dev/null; echo "exit=$?"
```
Expected: `exit=0`. Confirms non-interactive apply (devpod/CI path) still succeeds with both new pieces present.

- [ ] **Step 2: Sanity-check both artifacts in the applied HOME**

Run:
```bash
grep -q "## Model routing" "$H/.claude/CLAUDE.md" \
  && grep -q "enable <model>" "$H/.claude/commands/model-policy.md" && echo OK
```
Expected: `OK`.

- [ ] **Step 3: Push and open PR**

```bash
git push -u origin feat/model-routing-policy
gh pr create --fill --title "feat: model routing policy + allowlist"
```
Expected: PR URL printed.

---

## Self-Review

**Spec coverage:**
- Allowlist config block → Task 1. ✔
- Routing policy prose + task map + fallback ladder + savings_mode → Task 1. ✔
- `/model-policy` persistent command (edits source + `chezmoi apply`, refuses to drop opus) → Task 2. ✔
- Ephemeral chat overrides → documented in Task 1 policy prose (behavioural, no code). ✔
- Fable for creative design/UI direction with Opus fallback → Task 1 map. ✔
- `.chezmoiignore` gets `docs` → already done in the spec commit. ✔
- Clean-HOME verification → Task 3. ✔

**Placeholder scan:** No TBD/TODO; all file content shown verbatim. ✔

**Type/name consistency:** Marker strings (`MODEL-POLICY:START/END`) and key names (`main`, `enabled`, `savings_mode`) identical across Task 1 (producer) and Task 2 (consumer). Model aliases (`opus/sonnet/haiku/fable`) consistent throughout. ✔
