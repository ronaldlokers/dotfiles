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
  [LazyVim starter](https://github.com/LazyVim/starter) config
  (refreshed weekly where a `refreshPeriod` is set)
- the **run_onchange script** (`.chezmoiscripts/`) runs `mise install`
  whenever `dot_config/mise/config.toml` changes

## Layout

| Path | Contents |
| --- | --- |
| `dot_zshrc` | zsh: pure prompt, vi mode, mise/direnv, cached completions, aliases |
| `dot_bashrc` | bash fallback config |
| `dot_tmux.conf` | tmux config |
| `dot_config/mise/config.toml` | globally installed CLI tools |
| `dot_config/nvim/` | LazyVim tweaks layered over the starter external |

Project-specific tooling (kubectl, flux, krew, ...) is intentionally *not*
here — it lives in each project's own `mise.toml`.

Repo-only files (`setup`, `README.md`, `fixes.md`) are listed in
`.chezmoiignore` so chezmoi doesn't copy them into `$HOME`.
