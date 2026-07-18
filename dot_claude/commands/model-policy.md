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
4. After making a change (not for `show`), run `chezmoi apply` so `~/.claude/CLAUDE.md`
   updates.
5. Print the resulting block to confirm the change.
