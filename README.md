# dotfiles

Personal dotfiles, managed with [chezmoi](https://chezmoi.io). Arch/Omarchy host
plus [DevPod](https://devpod.sh) containers, one source tree for both.

This file is the operational half: how to install, restore, and use the setup.
Why it is built the way it is lives in [`docs/design-notes.md`](docs/design-notes.md).

Everything chezmoi manages lives under `home/` (`.chezmoiroot`). Source paths in
this file are written relative to it — `dot_zshrc` is `home/dot_zshrc` on disk.

## Fresh machine

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply https://github.com/ronaldlokers/dotfiles.git
```

Or run [`setup`](setup), which does the same and also makes zsh the login
shell. Both are safe to re-run.

Applying pulls in everything else automatically:

- **externals** (`.chezmoiexternals/`) download the mise binary, the
  [pure](https://github.com/sindresorhus/pure) prompt, the zsh plugins and
  television's channel set, refreshed weekly. The DevPod CLI external is
  host-only.
- a **run_onchange script** runs `mise install` whenever
  `dot_config/mise/config.toml` changes — that file is the CLI/TUI tool list,
  pinned and Renovate-bumped, and it applies to containers as well as the host
- **host packages** (`.chezmoiscripts/run_after_20-install-host-packages.sh.tmpl`)
  install the desktop apps. Host-only: it skips inside containers, without
  `pacman`, and when sudo would need a password with no TTY to ask on.

An interactive apply on a machine with the age identity available also unlocks
the secrets below; a non-interactive one skips them and leaves everything else
working.

## Recovery

Everything hinges on the age identity. On a machine that already has the source
(after `chezmoi init`/`apply` fetched it), an **interactive** `chezmoi apply`
prompts for the passphrase, rebuilds `key.txt`, and re-derives every secret.

To rebuild just the identity by hand:

```sh
chezmoi age decrypt --passphrase \
  --output ~/.config/chezmoi/key.txt \
  "$(chezmoi source-path)/key.txt.age"
chmod 600 ~/.config/chezmoi/key.txt
chezmoi apply        # re-derives the SSH/sops/gh secrets from the identity
```

The YubiKey is the other way in and needs no passphrase — drop its identity in
and apply:

```sh
install -m600 /path/to/yubikey-identity.txt ~/.config/chezmoi/yubikey-identity.txt
chezmoi init && chezmoi apply
```

> [!WARNING]
> The two recipients are only independent if their backups are. Losing the
> passphrase *and* its Proton Pass copy leaves the YubiKey as the sole way in,
> and vice versa. Re-verify the restore path after any key rotation.

## Secrets

Stored as plain `<name>.age` blobs — **not** with `chezmoi add --encrypt`, which
breaks the non-interactive bootstrap (see [Gotchas](#gotchas)). Each blob's
target path is listed in `.chezmoiignore` so the ciphertext isn't copied into
`$HOME`. `run_before_00-unlock-secrets.sh.tmpl` decrypts them on every apply,
and skips cleanly when no identity is available.

| Secret | Target | Source blob (under `home/`) |
| --- | --- | --- |
| sops age keys | `~/.config/sops/age/keys.txt` | `dot_config/private_sops/private_age/private_keys.txt.age` |
| `gh` token | `~/.config/gh/hosts.yml` | `dot_config/private_gh/private_hosts.yml.age` |
| sugarrush config | `~/.config/sugarrush/config.toml` | `dot_config/private_sugarrush/private_config.toml.age` |
| DevPod container token | `~/.config/devpod/dotfiles-env` | `dot_config/private_devpod/private_dotfiles-env.age` |

Every blob is encrypted to **two recipients**, so either key opens any secret:
the YubiKey (PIV slot 82, on the key itself) and a file identity at
`~/.config/chezmoi/key.txt`, committed as `key.txt.age` under a passphrase
(backup: Proton Pass).

**Adding a secret:** encrypt it to the repo recipients as a `<name>.age` blob
(`chezmoi encrypt --output <path>.age <file>`, `private_` prefix for `0600`
targets), add the target path to `.chezmoiignore`, and add a decrypt block to
the `run_before` script.

**Adding a recipient** does *not* rewrite existing blobs, so a new key silently
can't open old secrets. After changing `recipients` in `.chezmoi.toml.tmpl`, run
`chezmoi init` to regenerate the live config, then rewrite every blob:

```sh
for blob in $(git ls-files '*.age' | grep -v '^home/key\.txt\.age$'); do
  chezmoi decrypt "$blob" | chezmoi encrypt --output "$blob.new" && mv "$blob.new" "$blob"
done
mise run secrets-restore   # every blob still opens with the current identity
```

Then confirm the *new* key works, which `secrets-restore` cannot tell you — it
only ever tries the configured identity:

```sh
age -d -i /path/to/new-identity.txt <some-blob> >/dev/null && echo ok
```

`key.txt.age` is excluded throughout: it's passphrase-encrypted rather than
encrypted to a recipient, and it's where the file identity comes from.

## SSH keys

The three private keys — auth (`id_ed25519`), git signing
(`id_ed25519_signing`) and AUR (`aur`) — live in the **Dotfiles vault in Proton
Pass**, not in this repo. `run_after_13-restore-ssh-keys.sh.tmpl` restores
whichever are missing.

On a fresh machine, hand it the bootstrap token — it is in that same vault under
`bootstrap PAT`, readable from the Proton Pass app or web:

```sh
PROTON_PASS_PERSONAL_ACCESS_TOKEN='pst_…' chezmoi apply
```

The token is scoped **viewer on the Dotfiles vault and nothing else**, and it is
cached at `~/.config/pass-cli-bootstrap-pat` (mode 600) on first use, so later
applies re-authenticate on their own when the session lapses. Pass it through
the environment, never as a command argument — a flag value is visible in `ps`.

An interactive `pass-cli login` works just as well and needs no token.

The script only ever *creates* what is absent, so an established machine is a silent
no-op that never touches the network. That means an expired session, an offline
laptop or a Proton outage cannot break a machine that already works — the cost
falls entirely on a fresh one.

On a fresh machine the first apply has no `pass-cli` yet (it arrives as an
external), so the script says what to do and the second apply finishes the job.

Vault item titles, which the script matches on (all in the `Dotfiles` vault):

| Key | Proton Pass item |
| --- | --- |
| `~/.ssh/id_ed25519` | `ssh auth key` |
| `~/.ssh/id_ed25519_signing` | `git signing key` |
| `~/.ssh/aur` | `aur ssh key` |
| bootstrap token | `bootstrap PAT` |

> [!WARNING]
> These keys are reachable only through your Proton account. Unlike the `.age`
> blobs — which need no account, no network and no session — losing Proton
> access loses them. Keep an offline copy somewhere you trust.

## YubiKey

A YubiKey 5Ci holds the primary age identity (PIV slot 82, generated on-device,
PIN policy `once`, touch policy `cached` — one touch covers a whole apply).
Tooling comes from the host package list: `pcsclite`, `yubikey-manager`,
`yubikey-personalization`, `age-plugin-yubikey`, `pam-u2f`.

The key carries **three unrelated PINs** — PIV (secrets), FIDO2 (sudo, passkeys)
and OpenPGP (unused here). Mixing them up costs retry attempts. **FIDO2 has no
PUK:** exhausting it forces a reset that destroys every passkey on the key. PIV
is more forgiving, having one.

### Enrolling the age identity

Needed on a replacement key, or after a PIV reset. PIV is disabled from the
factory on some models, so enable it first — non-destructive, and it leaves
OATH, FIDO2 and OpenPGP alone:

```sh
ykman config usb --enable PIV
( umask 077 && age-plugin-yubikey --generate \
    --name "dotfiles age identity" --pin-policy once --touch-policy cached \
    > ~/.config/chezmoi/yubikey-identity.txt )
```

**Scope the `umask` to a subshell** as above. Left set in an interactive shell it
silently follows every later command — a `chezmoi apply` in the same terminal
then writes every managed file at `0600` instead of `0644`.

Then change the factory credentials, or the hardware backing is decorative —
anyone holding the key can use it:

```sh
ykman piv access change-pin                              # default 123456
ykman piv access change-puk                              # default 12345678
ykman piv access change-management-key --generate --protect
```

`--protect` stores the management key on the card behind the PIN, so there's no
hex string to keep anywhere.

Finally add the new recipient (`age-plugin-yubikey --list`) to
`.chezmoi.toml.tmpl` and re-encrypt every blob — see [Secrets](#secrets). A new
key cannot read existing blobs otherwise.

### Touch-to-sudo

`pam-u2f` is installed by the host package list, but the setup is **deliberately
manual**: `/etc/pam.d` is outside `$HOME`, and one bad edit locks you out of sudo
everywhere, including the means to fix it.

Register the key. This wants the **FIDO2** PIN, not the PIV one:

```sh
pamu2fcfg > /tmp/u2f.line          # PIN + touch
sudo install -m644 /tmp/u2f.line /etc/u2f_mappings && shred -u /tmp/u2f.line
sudo cut -d: -f1 /etc/u2f_mappings # sanity check: prints your username
```

Two steps, not `pamu2fcfg | sudo tee`: `sudo` would truncate the file before
`pamu2fcfg` produces anything, and both processes then compete for the terminal.

**Open a root shell in another terminal and keep it open** (`sudo -i`). It's the
escape hatch if the next step is wrong. Then add one line to `/etc/pam.d/sudo`:

```
#%PAM-1.0
auth		sufficient	pam_u2f.so cue authfile=/etc/u2f_mappings
auth		include		system-auth
...
```

`sufficient`, not `required`, and above the `include`: a touch satisfies auth,
and if the key is absent PAM falls through to the password prompt. `required`
would demand both and lock you out whenever the key isn't plugged in. `cue`
prints "Please touch the device" so sudo doesn't hang silently.

Verify both paths before closing the root shell:

```sh
sudo -k && sudo true    # prompts for a touch
                        # then unplug the key and repeat — should ask for a password
```

Registration is host-specific (`pamu2fcfg` defaults to origin `pam://$HOSTNAME`),
so this credential won't work on a second machine without a shared `-o`/`-i`
origin at registration time. It also does **not** silence `sudo needs a
password; skipping` in automated applies — `sudo -n` can't wait for a touch. What
it buys is `sudo -v` (a touch) followed by a non-interactive `chezmoi apply` for
the credential cache window.

## Layout

Everything chezmoi manages lives under `home/` (`.chezmoiroot`); paths in the
table are relative to it.

| Path | Contents |
| --- | --- |
| `dot_zshrc` | zsh: pure prompt, vi mode, mise/direnv, zoxide-backed `cd`, atuin history, tv pickers, fzf-tab completions, autosuggestions + syntax highlighting, aliases |
| `dot_bashrc` | bash fallback: hands over to zsh on Omarchy, otherwise mirrors zsh's keys and aliases — no prompt or plugins. Kept in step by hand |
| `dot_tmux.conf` | tmux config; `prefix o` opens the tv sesh channel |
| `dot_config/mise/config.toml` | globally installed CLI/TUI tools, pinned |
| `dot_config/git/` | git defaults, delta pager, global ignores (machine-local bits stay in unmanaged `~/.gitconfig`) |
| `dot_config/lazygit/` | lazygit config: delta as diff pager |
| `dot_config/atuin/` | atuin: SQLite shell history, sync deliberately off |
| `dot_config/television/` | television: the local channels (`cable/alias.toml`, `cable/atuin.toml`); the rest arrive from a pinned external |
| `dot_config/nvim/` | Neovim config: vendored [LazyVim starter](https://github.com/LazyVim/starter) plus own tweaks |
| `dot_claude/` | Claude Code: global `CLAUDE.md`, statusline, `rtk-rewrite` hook, and `modify_settings.json` |
| `dot_config/omarchy/branding/` | Omarchy screensaver branding, generated from `assets/`. Host-only |
| `dot_local/bin/` | own scripts: `repos-sync`, `devcontainer-init`, `dotfiles-update-check`, and `devpod` — a wrapper fronting the pinned binary in `~/.local/libexec` |
| `.chezmoiexternals/` | downloads pinned to a version and, where upstream publishes one, a checksum: the mise binary, pure, zsh/tmux plugins, television channels, k9s, and `pass-cli` (host-only, pinned by version + sha256 because Proton ships it from `proton.me` rather than GitHub) |
| `assets/` (repo root, outside `home/`) | source artwork generated files derive from, never copied into `$HOME` |

Adding a tool: anything that runs in a terminal goes in
`dot_config/mise/config.toml`, pinned, so containers get it too; a desktop app
goes in the host package script. Project-specific tooling (kubectl, flux, krew,
...) is intentionally *not* here — it lives in each project's own `mise.toml`.
Repo-only files — `README.md`, `CLAUDE.md`, `docs/`, `assets/`, `setup`,
`mise.toml` — sit outside `home/`, so chezmoi never sees them and they need no
`.chezmoiignore` entry.

## Keybindings

Both shells get the same set, so a machine where zsh isn't the login shell yet
behaves the same:

| Key | Does |
| --- | --- |
| `Ctrl-R` | atuin history search, all directories |
| `Up` | atuin history search, this directory only |
| `Ctrl-T` | tv channel menu — pick a channel, then pick in it; the result lands on the command line |
| `Alt-C` | tv directory picker, cds this shell |
| `Ctrl-F` | tv sesh channel: tmux sessions + zoxide directories |
| `Alt-Y` | yazi; quitting it cds this shell to wherever you ended up (`y` does the same by name) |
| `prefix o` | the same sesh channel, in a tmux popup |
| `Ctrl-S` | *inside* the sesh channel: cycle source (all/tmux/configs/zoxide/dirs) |
| `Ctrl-D` | *inside* the sesh channel: kill the highlighted session and reload |
| `**` + `Tab` | bash only: fzf path completion |

`Ctrl-S` also cycles the `atuin` tv channel between all history, this directory
only, and commands that actually failed.

atuin history is **local to each machine and each container**: sync is off, so a
rebuilt devpod container starts with an empty database.

## Daily use

**Project checkouts** live under `$XDG_PROJECTS_DIR` (`~/Projects`, declared in
`~/.config/user-dirs.dirs`) in `host/owner/repo` layout:

```sh
repos-sync    # clone whatever isn't checked out yet, into ~/Projects/github.com/owner/repo
```

It only ever clones — an existing checkout is left alone, branch, remotes and
uncommitted work included. Add a repo by editing the list in
`dot_local/bin/executable_repos-sync`. A fresh clone is registered with zoxide,
which is what puts it in the `Ctrl-F` picker before anyone has `cd`'d into it.

**Dev containers** are per-project. Scaffold one from the managed starter, then
bring it up:

```sh
cd ~/Projects/github.com/ronaldlokers/someproject
devcontainer-init      # --force to overwrite an existing .devcontainer/
devpod up .
```

`devcontainer-init` writes `devcontainer.json`, `Dockerfile` and `post-create.sh`,
naming the container after the directory. The starter is deliberately thin —
`archlinux:base` with git, zsh, sudo, openssh and mise, a `dev` user at uid 1000
with passwordless sudo, and a post-create hook that runs `mise install` — because
ports, mounts and extra packages differ per project and belong in the copy. Edit
the starter at `dot_local/share/devcontainer-template/`.

DevPod clones and applies these dotfiles inside the container itself; nothing in
the image does it. The host side (provider, IDE, `DOTFILES_URL`) is configured by
`run_onchange_after_30-configure-devpod.sh.tmpl`, and `~/.local/bin/devpod` is a
managed wrapper that passes a no-scope GitHub token and quiet-mode env into every
`devpod up`. The pinned binary itself lives off PATH at `~/.local/libexec/devpod`;
`~/.local/libexec/devpod` runs it unwrapped.

**Git inside a container needs no token.** DevPod forwards the ssh-agent, and the
managed git config rewrites github HTTPS remotes to SSH *inside containers*, so
clone, fetch, push and commit signing all work with nothing secret stored there.
The container can *use* every key in your agent while it runs, though it cannot
copy them out.

The GitHub **API** is the exception — SSH can't authenticate it, so `gh pr create`
and friends need a token. Opt in per project:

```sh
install -m600 /dev/null ~/.config/devpod/project-tokens
printf 'owner/repo=github_pat_...\n' >> ~/.config/devpod/project-tokens
```

Mint each one fine-grained and limited to that single repository. The wrapper
keys on the project's **push** remote — so a fork resolves to *your* fork, not
upstream — and passes it as `GH_TOKEN` for that workspace only. With no entry, no
token is passed.

> [!WARNING]
> A token passed this way lands in `/etc/envfile.json` inside the container, mode
> `0644` — readable by everything running there. That is exactly why entries
> should be scoped to one repo: it bounds what a malicious postinstall script can
> reach.

**Updates** arrive two ways. Tool pins are bumped by a self-hosted
[Renovate](https://docs.renovatebot.com) run (`.github/workflows/renovate.yaml`,
weekly or manual dispatch, authenticating with the `RENOVATE_TOKEN` repo secret —
a PAT with `repo` and `workflow` scope). It automerges patch/minor once CI is
green; majors wait for review. Externals refresh weekly on `chezmoi apply`. Separately,
a user timer (`dotfiles-update-check.timer`, daily with 4h jitter) reports when
this machine is behind the remote — it **only notifies**, never pulls and never
applies. Run it by hand with `dotfiles-update-check`.

## Working on this repo

[`CLAUDE.md`](CLAUDE.md) carries the rules for agents working here (secrets
handling above all). `mise.toml` pins the tooling and defines the checks, so
local runs and CI use identical versions:

```sh
mise run check     # lint + gitleaks + clean-HOME bootstrap (what CI runs)
mise run lint      # shellcheck, settings.json, renovate config
mise run verify    # bootstrap into a throwaway HOME, non-interactively
```

`mise run verify` is the one that matters before pushing: it redirects
`/dev/null` into the apply, reproducing the no-TTY conditions of `devpod up` and
CI. Running an apply that inherits your terminal exercises a different path and
will happily hide a script that hangs waiting for input.

CI (`.github/workflows/ci.yaml`) runs the same checks on every push and PR plus a
weekly canary, and adds two jobs the clean-HOME bootstrap can't reach:
`host-ssh-agent` brings up a real systemd user session, and `container-gates`
runs inside an Arch container to prove the host-only gates actually skip there.

Separately, and needing an unlocked identity:

```sh
mise run secrets-restore   # assert every .age blob still decrypts
```

Nothing else exercises the recovery path in [Recovery](#recovery) — a blob
encrypted to the wrong recipient stays silent until the day you need it.

Also manual, and for the same reason — it needs a human to decide:

```sh
mise run prune             # drop mise tool installs no config asks for
```

It shows a dry run and asks before removing anything. Deliberately not part of
`check`: a machine that hasn't opened a project recently hasn't tracked that
project's `mise.toml`, and pruning there just forces a re-download.

## Gotchas

- **Never `chezmoi add --encrypt`.** It creates an `encrypted_` source file that
  chezmoi decrypts *at apply time*, which needs the age identity — so every
  non-interactive apply (`devpod up`, CI) fails. Use the `.age` blob pattern in
  [Secrets](#secrets) instead.
- **New repo-only files go outside `home/`.** Anything inside it is source
  state and will be applied into `$HOME` unless `.chezmoiignore` says
  otherwise. Docs, CI config and repo tooling belong at the repo root.
- **Never edit a managed file in `$HOME`.** Edit the source
  (`chezmoi source-path <file>`) and apply. The next apply reverts anything else.
- **Some commands write to files this repo owns**, and their effect is reverted
  by the next apply: `omarchy default terminal` (`dot_config/xdg-terminals.list`),
  `omarchy branding screensaver` (regenerate from `assets/` instead — the command
  is in [`assets/README.md`](assets/README.md)), and
  `/plugin` enable/disable in Claude Code (edit `dot_claude/modify_settings.json`).
  `~/.ssh/config` and `~/.devpod/config.yaml` are deliberately *not* managed for
  the same reason — see [design notes](docs/design-notes.md#co-owned-configuration-files).
- **Aliases don't apply in scripts.** `du`, `df` and `top` are aliased to `dust`,
  `duf` and `btop` in interactive shells only; a script gets coreutils.
- **Never run `omarchy-setup-zsh`.** It *replaces* `~/.zshrc` and `~/.bashrc`,
  both of which chezmoi owns. `dot_zshrc` already sources omarchy-zsh's shared
  config from `/usr/share`, and the host package script sets the login shell.
- **A lapsed DevPod PAT looks like nothing at all.** No local check tests it;
  `devpod up` just reverts to the GitHub rate-limit failure it exists to prevent,
  with every check green.
