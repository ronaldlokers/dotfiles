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