# Global instructions

## Environment
- Usually work as `vscode` user inside devpod containers; host machine run Omarchy (Arch Linux).
- Dotfiles managed with chezmoi (source: `~/.local/share/chezmoi`, repo: `ronaldlokers/dotfiles`). Never edit chezmoi-managed file in `$HOME` direct — edit source (`chezmoi source-path <file>`), run `chezmoi apply`.
- CLI tools installed through mise, pinned versions (global: `~/.config/mise/config.toml`; per-project tooling goes that project's `mise.toml`). Prefer `mise` over apt, `npm -g`, pip for tool install.

## Git workflow
- Never commit direct to `main`. Use short-lived branches named `fix/<topic>` or `feat/<topic>`, open PRs with `gh`.
- Commit subjects use conventional-commit style: `fix: ...`, `feat: ...` — lowercase, imperative.

## Secrets
- Secrets age-encrypted (chezmoi `--encrypt` with dotfiles keypair, or sops). Never write secrets plaintext to repo; flag if found.

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