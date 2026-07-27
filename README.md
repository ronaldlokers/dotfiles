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
  zsh-autosuggestions / zsh-syntax-highlighting plugins, refreshed weekly.
  The [DevPod](https://devpod.sh) CLI external is host-only — it renders to
  nothing inside a container, so devpod-provisioned boxes skip it
- the **run_onchange script** (`.chezmoiscripts/`) runs `mise install`
  whenever `dot_config/mise/config.toml` changes
- **host packages** (`.chezmoiscripts/run_after_20-install-host-packages.sh.tmpl`)
  install the desktop apps listed below — see [Packages](#packages)

## Packages

Two lists, split by where a tool is wanted rather than by what installs it:

| | Where | Goes in |
| --- | --- | --- |
| CLI / TUI tools | host **and** devpod containers | `dot_config/mise/config.toml` |
| Desktop apps | host only | `run_after_20-install-host-packages.sh.tmpl` |

Anything that runs in a terminal belongs in mise, even when a distro package
exists — `yazi` and `superfile` are in Arch's `extra` and `sugarrush` has its own
AUR package, but all three are TUIs, wanted inside a container as much as on the
host. mise pins versions and Renovate bumps them; the host list is unpinned and
tracks whatever the distro ships.

The host script is deliberately a plain `run_after`, not a `run_onchange`:
chezmoi records a `run_onchange` script's hash as soon as it exits 0, so a run
that skipped — no TTY for sudo, no package manager — would be remembered as done
and never retried. Running every apply costs one `pacman -Q` per package and
lets a later interactive apply finish the job.

It skips cleanly and installs nothing when any of these hold, so containers,
CI, and non-Arch machines are unaffected:

- `/.dockerenv` or `/run/.containerenv` exists (it's a container)
- no `pacman` on `PATH` (it's not an Arch-family distro)
- sudo needs a password and there's no TTY to ask on (`devpod up`, CI)

AUR entries need `yay` or `paru`; without either they're skipped and the repo
packages still install. Failures are reported and the apply continues — one
broken PKGBUILD shouldn't block everything else, and the next apply retries it.

AUR builds run on a **system-only `PATH`**. mise's shims sit ahead of `/usr/bin`,
so a PKGBUILD calling `python` would otherwise get a mise-managed interpreter
that can't see the pacman `makedepends` it just declared — and a build that
survived that would bake mise paths into the packaged files.

A few packages need a group membership they can't grant themselves (chirp needs
`uucp` to open `/dev/ttyUSB*`). Those are listed in `PACKAGE_GROUPS`, applied
only when the package is actually installed, and take effect on the next login.

## Updates

Tool versions in `dot_config/mise/config.toml` are pinned and bumped by a
self-hosted [Renovate](https://docs.renovatebot.com) run
(`.github/workflows/renovate.yaml`, weekly or via manual dispatch). It
authenticates with the `RENOVATE_TOKEN` repo secret — a PAT with `repo` and
`workflow` scope. Externals (mise binary, zsh plugins) refresh weekly on
`chezmoi apply`. CI (`.github/workflows/ci.yaml`) lints, scans history with
gitleaks, and test-bootstraps the repo into a clean HOME on every push, PR, and
a weekly canary run. Two jobs cover paths the clean-HOME bootstrap can't reach:
`host-ssh-agent` brings up a real systemd user session, and `container-gates`
runs inside an Arch container to prove the host-only gates actually skip there.
Renovate automerges patch/minor bumps once CI is green; majors wait for review.

## Working on this repo

`mise.toml` pins the tooling and defines the checks, so local runs and CI use
identical versions:

```sh
mise run check     # lint + gitleaks + clean-HOME bootstrap (what CI runs)
mise run lint      # shellcheck, settings.json, renovate config
mise run verify    # bootstrap into a throwaway HOME, non-interactively
```

`mise run verify` is the one that matters before pushing: it redirects
`/dev/null` into the apply, reproducing the no-TTY conditions of `devpod up` and
CI. Running an apply that inherits your terminal exercises a different path and
will happily hide a script that hangs waiting for input.

Separately, and needing an unlocked identity:

```sh
mise run secrets-restore   # assert every .age blob still decrypts
```

Nothing else exercises the recovery path in [Recovery](#recovery) — a blob
encrypted to the wrong recipient stays silent until the day you need it.

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
| `gh` token | `~/.config/gh/hosts.yml` | `dot_config/private_gh/private_hosts.yml.age` |

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
