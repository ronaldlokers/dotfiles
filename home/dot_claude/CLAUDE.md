# Global instructions

## Environment
- Two environments: directly on the Omarchy (Arch Linux) host as `ronald`, or as `vscode` inside a devpod container. Check which before assuming paths or tooling.
- Dotfiles managed with chezmoi (source: `~/.local/share/chezmoi`, repo: `ronaldlokers/dotfiles`). Never edit chezmoi-managed file in `$HOME` direct — edit source (`chezmoi source-path <file>`), run `chezmoi apply`.
- CLI tools installed through mise, pinned versions (global: `~/.config/mise/config.toml`; per-project tooling goes that project's `mise.toml`). Prefer `mise` over apt, `npm -g`, pip for tool install.

## Git workflow
- Never commit direct to `main`. Use short-lived branches named `fix/<topic>` or `feat/<topic>`, open PRs with `gh`.
- Commit subjects use conventional-commit style: `fix: ...`, `feat: ...` — lowercase, imperative.

## Secrets
- Secrets live in Proton Pass (Dotfiles vault), fetched by `pass-cli` during `chezmoi apply`; SSH keys go straight into the ssh-agent and never hit disk. Nothing secret belongs in the dotfiles repo — no `.age` blobs, no `encrypted_` files. Never write a secret plaintext to a repo; flag if found.

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
Opus; balanced = map above; aggressive = routine implementation's preferred model drops to Haiku where adequate (Sonnet fallback); creative stays Fable; Opus only for genuinely hard reasoning.

Overrides: `/model-policy` command edits this block + persists (`chezmoi apply`).
Plain chat requests ("stop using Fable", "save tokens") = session-only, write
nothing.

## RTK (Rust Token Killer)

Token-optimized CLI proxy (60-90% savings on dev operations). A `PreToolUse`
hook (`~/.claude/hooks/rtk-rewrite.sh`) transparently rewrites Bash commands to
route through `rtk` — e.g. `git status` becomes `rtk git status`, zero token
overhead, no action needed from you. Hook no-ops when `rtk` or `jq` is absent.

Meta commands (run `rtk` directly):

```bash
rtk gain              # token savings analytics
rtk gain --history    # command usage history with savings
rtk discover          # analyze Claude Code history for missed opportunities
rtk proxy <cmd>       # run raw command, unfiltered (debugging)
```

Name collision: if `rtk gain` fails, wrong binary installed
(reachingforthejack/rtk = Rust Type Kit). Correct one is `rtk-ai/rtk`, pinned as
`rtk` in `dot_config/mise/config.toml`.

## Graphify

Turn a codebase into a queryable knowledge graph. `/graphify .` build it, then
`graphify query "..."`, `graphify path A B`, `graphify god-nodes`,
`graphify affected X` against it. `graphify update <path>` re-extract after code
change, no LLM needed. Everything land in `graphify-out/` — gitignore it.

Set up code-only: local AST parsing, no API key, no token cost. Doc/PDF/image
extraction exists but need an LLM key, deliberately not configured.

CLI pinned as `pipx:graphifyy` in `dot_config/mise/config.toml`. Skill vendored
into `dot_claude/skills/graphify/`. Do **not** run `graphify install` — it write
straight into `$HOME`, over chezmoi. Upgrade = bump the mise pin, rerun install
into a scratch HOME, `chezmoi add` the result.

**Interpreter:** the skill's own Python detection fail here. It read the shebang
of `which graphify`, but that is a mise shim — a binary, no shebang. Point it at
the venv directly:
`~/.local/share/mise/installs/pipx-graphifyy/<version>/graphifyy/bin/python3`.

**Evaluated on the dotfiles repo, 2026-07-30 — kept installed but not used
here.** Three reasons, so nobody redo the experiment:

- `.sh.tmpl` is not a detected extension, so every chezmoi script template —
  where the real logic live — is invisible to it.
- Shell get no cross-file AST edges (no imports), so each script become its own
  2-3 node island. 13 of 26 communities were exactly that.
- All real structure came from an LLM reading the 11 markdown files (110k
  tokens), and the "surprising connections" it surfaced were pairs of docs
  saying the same thing.

It earn its keep on a big Python/TypeScript codebase, not on 26 files of shell.
One true finding worth acting on: secrets are documented in four places (this
file, root `CLAUDE.md`, `README.md`, `docs/design-notes.md`).