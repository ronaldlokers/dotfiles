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

Everything hinges on Proton Pass. A fresh machine needs one token, and the rest
follows:

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply https://github.com/ronaldlokers/dotfiles.git
PROTON_PASS_PERSONAL_ACCESS_TOKEN='pst_…' chezmoi apply
```

The token is in the Dotfiles vault as `bootstrap PAT`, readable from the Proton
Pass app or web on any device. The first apply installs `pass-cli` as an
external; the second derives every secret. An interactive `pass-cli login`
replaces the token entirely if you would rather type a password.

`mise run secrets-check` asserts every item is still readable — a renamed item
or a lapsed grant otherwise stays silent until the day you rebuild a machine.

> [!WARNING]
> Proton is the only copy. No account, no secrets — there is no offline or
> account-free path back, and the same account holds the SSH keys. Keep an
> offline copy of anything you cannot re-issue.

## Secrets

Stored as items in the **Dotfiles vault**, fetched during `chezmoi apply` by
`.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl`. Nothing secret is in this
repo — no ciphertext, no `encrypted_` files.

| Secret | Target | Vault item |
| --- | --- | --- |
| sops age keys | `~/.config/sops/age/keys.txt` | `sops age keys` |
| `gh` token | `~/.config/gh/hosts.yml` | `gh hosts.yml` |
| sugarrush config | `~/.config/sugarrush/config.toml` | `sugarrush config` |
| DevPod container token | `~/.config/devpod/dotfiles-env` | `devpod dotfiles-env` |

Each is fetched on every apply and rewritten only when it differs, so rotating a
secret in the vault propagates on the next apply. A fetch that fails or comes
back empty leaves the existing file alone — a stale secret beats a truncated one.

**Adding a secret:** create a note item whose body is the file content, then add
one `restore "<item title>" "<target>" 600` line to the script.

Unlike the previous age-encrypted blobs, this works **non-interactively**: the
cached token needs no TTY, so timer- and script-driven applies derive secrets
just like an interactive one. The cost is that `~/.config/pass-cli-bootstrap-pat`
now unlocks the vault, so disk access alone is enough — where before it took the
YubiKey or a passphrase.

## SSH keys

The three private keys — auth (`id_ed25519`), git signing
(`id_ed25519_signing`) and AUR (`aur`) — live in the **Dotfiles vault in Proton
Pass**. They are never written to disk: `proton-ssh-load` hands them straight to
the ssh-agent, and `dot_config/shell/ssh-agent.sh` runs it automatically the
first time a shell finds a live but empty agent.

That covers everything this machine does with them. Git over SSH uses the agent,
and so does commit signing: `user.signingkey` is the *literal* public key rather
than a path, so there is no `.pub` file either — `~/.ssh` holds no key material
at all. The public half comes from the same Proton item as the private one, via
`.chezmoitemplates/signing-pubkey`, falling back to `ssh-add -L` where Proton
isn't reachable. DevPod forwards the agent into containers, so they get the keys
without holding a secret either.

If neither source can supply it, `user.signingkey` is left out while
`commit.gpgsign` stays on — the next commit fails loudly instead of quietly
going unsigned. `proton-ssh-load` then re-apply fixes it.

On a fresh machine, hand it the bootstrap token once — it is in that same vault
under `bootstrap PAT`, readable from the Proton Pass app or web:

```sh
PROTON_PASS_PERSONAL_ACCESS_TOKEN='pst_…' proton-ssh-load
```

The token is scoped **viewer on the Dotfiles vault and nothing else**, and it is
cached at `~/.config/pass-cli-bootstrap-pat` (mode 600) once it works, so later
logins need no interaction. Pass it through the environment, never as a command
argument — a flag value is visible in `ps`. An interactive `pass-cli login` does
the same job without a token.

Run `proton-ssh-load` by hand at any time; loading keys already in the agent is
a no-op. `pass-cli ssh-agent debug` explains why an item is or isn't usable.

| Key | Proton Pass item |
| --- | --- |
| auth | `ssh auth key` |
| git signing | `git signing key` |
| AUR | `aur ssh key` |
| bootstrap token | `bootstrap PAT` |

> [!WARNING]
> The agent is the only place these keys exist on a running machine, and Proton
> is the only place they exist at rest. No Proton account, no keys — and unlike
> the `.age` blobs, no offline or account-free path back. Keep a copy somewhere
> you trust.

## YubiKey

The YubiKey 5Ci no longer holds anything this repo depends on. It used to carry
the primary age identity in PIV slot 82, back when secrets were `.age` blobs;
that identity is unused now that Proton Pass holds them, and the PIV slot can be
left alone or reset at your leisure. `age-plugin-yubikey` and `age` stay in the
host package list only because other tools may want them.

What the key is still used for is **touch-to-sudo** via FIDO2, below.

The key carries **three unrelated PINs** — PIV, FIDO2 (sudo, passkeys) and
OpenPGP (unused here). Mixing them up costs retry attempts. **FIDO2 has no PUK:**
exhausting it forces a reset that destroys every passkey on the key. PIV is more
forgiving, having one.

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

Separately, and needing a Proton session:

```sh
mise run secrets-check     # assert every secret in the vault is readable
```

Nothing else exercises the recovery path in [Recovery](#recovery) — a renamed
vault item or a lapsed grant stays silent until the day you need it. It reports
byte counts only; printing a secret to prove it decrypts would defeat the point.

Also manual, and for the same reason — it needs a human to decide:

```sh
mise run prune             # drop mise tool installs no config asks for
```

It shows a dry run and asks before removing anything. Deliberately not part of
`check`: a machine that hasn't opened a project recently hasn't tracked that
project's `mise.toml`, and pruning there just forces a re-download.

## Gotchas

- **Nothing secret goes in the repo.** No `.age` blobs, no `chezmoi add
  --encrypt`, no `encrypted_` files. Secrets live in the Dotfiles vault and are
  fetched at apply time — see [Secrets](#secrets).
- **The bootstrap token expires.** `bootstrap PAT` is good until 2027-07-29;
  after that `proton-ssh-load` and the secrets script quietly report no session
  until you run `pass-cli pat renew` or log in interactively.
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
