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

Secrets are stored as plain `<name>.age` blobs, each encrypted to the repo's
dedicated age recipient (pinned in `.chezmoi.toml.tmpl`) — **not** with
`chezmoi add --encrypt` (that `encrypted_` flow decrypts at apply time and
breaks the non-interactive bootstrap; see [`CLAUDE.md`](CLAUDE.md)). Each blob's
target path is listed in `.chezmoiignore` so the raw ciphertext isn't copied
into `$HOME`.

The age identity that decrypts everything, `~/.config/chezmoi/key.txt`, is
itself passphrase-protected and committed as `key.txt.age` (passphrase backup:
Proton Pass). `.chezmoiscripts/run_before_00-unlock-secrets.sh.tmpl` — a plain
`run_before` that re-runs on every apply and is a fast no-op once unlocked —
first unlocks the identity (this needs a real TTY for the passphrase, so
non-interactive applies like `devpod up` and CI skip it by design), then uses it
to decrypt the secrets below. A later interactive `chezmoi apply` finishes what a
non-interactive one had to skip.

Currently decrypted by the script:

| Secret | Target | Source blob |
| --- | --- | --- |
| SSH signing key | `~/.ssh/id_ed25519_signing` | `private_dot_ssh/private_id_ed25519_signing.age` |
| sops age keys | `~/.config/sops/age/keys.txt` | `dot_config/private_sops/private_age/private_keys.txt.age` |
| `gh` token | `~/.config/gh/hosts.yml` | `dot_config/gh/private_hosts.yml.age` |

To **add** a secret: encrypt it to the repo recipient as a `<name>.age` blob
(`chezmoi encrypt --output <path>.age <file>`, `private_` prefix for `0600`
targets), add the target path to `.chezmoiignore`, and add a decrypt block to
the `run_before` script. Full guidance in [`CLAUDE.md`](CLAUDE.md).

### Recovery

Everything hinges on the age identity. To restore on a machine that has the
source (after `chezmoi init`/`apply` has fetched it) run an **interactive**
`chezmoi apply` — the `run_before` script prompts for the passphrase and rebuilds
`key.txt`, then re-derives every secret. To rebuild just the identity by hand:

```sh
chezmoi age decrypt --passphrase \
  --output ~/.config/chezmoi/key.txt \
  "$(chezmoi source-path)/key.txt.age"
chmod 600 ~/.config/chezmoi/key.txt
chezmoi apply        # re-derives the SSH/sops/gh secrets from the identity
```

> [!WARNING]
> If **both** the passphrase and its Proton Pass backup are lost, `key.txt.age`
> — and therefore every secret encrypted to this recipient — is permanently
> unrecoverable. Keep the passphrase in a second location, and re-verify the
> restore path above after any key rotation.

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

Repo-only files (`setup`, `README.md`, `CLAUDE.md`) are listed in
`.chezmoiignore` so chezmoi doesn't copy them into `$HOME`.
