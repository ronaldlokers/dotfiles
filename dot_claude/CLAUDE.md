# Global instructions

## Environment
- I usually work as the `vscode` user inside devpod containers; my host machine runs Omarchy (Arch Linux).
- My dotfiles are managed with chezmoi (source: `~/.local/share/chezmoi`, repo: `ronaldlokers/dotfiles`). Never edit a chezmoi-managed file in `$HOME` directly — edit its source (`chezmoi source-path <file>`) and run `chezmoi apply`.
- CLI tools are installed through mise with pinned versions (global: `~/.config/mise/config.toml`; per-project tooling goes in that project's `mise.toml`). Prefer `mise` over apt, `npm -g`, or pip for installing tools.

## Git workflow
- Never commit directly to `main`. Use short-lived branches named `fix/<topic>` or `feat/<topic>` and open PRs with `gh`.
- Commit subjects use conventional-commit style: `fix: ...`, `feat: ...` — lowercase, imperative.

## Secrets
- Secrets are age-encrypted (chezmoi `--encrypt` with the dotfiles keypair, or sops). Never write secrets in plaintext to a repo; flag it if you find one.
