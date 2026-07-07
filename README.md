# dotfiles

Personal dotfiles, managed with [chezmoi](https://chezmoi.io).

## Fresh machine

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply https://github.com/ronaldlokers/dotfiles.git
```

Or run [`setup`](setup), which does the same and also makes zsh the login
shell. Both are safe to re-run.

Applying pulls in everything else automatically:

- **externals** (`.chezmoiexternals/`) download the mise binary, the
  [pure](https://github.com/sindresorhus/pure) prompt, and the
  zsh-autosuggestions / zsh-syntax-highlighting plugins, refreshed weekly
- the **run_onchange script** (`.chezmoiscripts/`) runs `mise install`
  whenever `dot_config/mise/config.toml` changes

## Updates

Tool versions in `dot_config/mise/config.toml` are pinned and bumped by a
self-hosted [Renovate](https://docs.renovatebot.com) run
(`.github/workflows/renovate.yaml`, weekly or via manual dispatch). It
authenticates with the `RENOVATE_TOKEN` repo secret — a PAT with `repo` and
`workflow` scope. Externals (mise binary, zsh plugins) refresh weekly on
`chezmoi apply`. CI (`.github/workflows/ci.yaml`) shellchecks the scripts,
scans history with gitleaks, and test-bootstraps the repo into a clean HOME
on every push, PR, and a weekly canary run. Renovate automerges patch/minor
bumps once CI is green; majors wait for review.

## Secrets

Files added with `chezmoi add --encrypt` are age-encrypted in the repo with
a dedicated dotfiles keypair (`.chezmoi.toml.tmpl`). The private key is
committed passphrase-protected as `key.txt.age`; on first apply a
`run_once_before` script prompts for the passphrase (backup: Proton Pass)
and decrypts it to `~/.config/chezmoi/key.txt`. Currently encrypted: the
sops age keys (`~/.config/sops/age/keys.txt`).

## Layout

| Path | Contents |
| --- | --- |
| `dot_zshrc` | zsh: pure prompt, vi mode, mise/direnv/zoxide, cached completions, autosuggestions + syntax highlighting, aliases |
| `dot_config/git/` | git defaults, delta pager, global ignores (machine-local bits stay in unmanaged `~/.gitconfig`) |
| `dot_config/lazygit/` | lazygit config: delta as diff pager |
| `dot_bashrc` | bash fallback config |
| `dot_tmux.conf` | tmux config |
| `dot_config/mise/config.toml` | globally installed CLI tools |
| `dot_config/nvim/` | Neovim config: vendored [LazyVim starter](https://github.com/LazyVim/starter) plus own tweaks |

Project-specific tooling (kubectl, flux, krew, ...) is intentionally *not*
here — it lives in each project's own `mise.toml`.

Repo-only files (`setup`, `README.md`, `fixes.md`) are listed in
`.chezmoiignore` so chezmoi doesn't copy them into `$HOME`.
