# dotfiles

Personal dotfiles, managed with [chezmoi](https://chezmoi.io). Arch/Omarchy host
plus [DevPod](https://devpod.sh) containers, one source tree for both.

How to install, restore and use it. Why it is built this way lives in
[`docs/design-notes.md`](docs/design-notes.md).

Everything chezmoi manages is under `home/` (`.chezmoiroot`); source paths here
are relative to it — `dot_zshrc` is `home/dot_zshrc` on disk.

## Fresh machine

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply https://github.com/ronaldlokers/dotfiles.git
chezmoi apply                                             # asks for the PAT if needed
PROTON_PASS_PERSONAL_ACCESS_TOKEN='pst_…' chezmoi apply   # or supply it up front
```

Or run [`setup`](setup), which does the same and makes zsh the login shell. Both
are safe to re-run. The token is in the Dotfiles vault as `bootstrap PAT`; the
first apply installs `pass-cli`, the second derives everything.

Applying pulls in the rest automatically:

- **externals** (`.chezmoiexternals/`) — mise, pure, zsh/tmux plugins, tv
  channels, k9s, pass-cli. Refreshed weekly; devpod and pass-cli are host-only.
- **mise install** whenever `dot_config/mise/config.toml` changes — the pinned
  CLI/TUI tool list, applied to containers too.
- **host packages** (`run_after_20-install-host-packages.sh.tmpl`) — desktop
  apps. Skipped in containers, without `pacman`, and when sudo needs a password
  with no TTY.

## Recovery

Everything hinges on Proton Pass, so a fresh machine needs only the bootstrap
token above. `pass-cli login` works instead if you would rather type a password.

```sh
mise run secrets-check     # assert every vault item is still readable
```

> [!WARNING]
> Proton is the only copy. No account, no secrets — there is no offline or
> account-free path back, and the same account holds the SSH keys. Keep an
> offline copy of anything you cannot re-issue.

## Secrets

Items in the **Dotfiles vault**, written by
`.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl`. Nothing secret is in this
repo.

| Secret | Target | Vault item |
| --- | --- | --- |
| sops age keys | `~/.config/sops/age/keys.txt` | `sops age keys` |
| `gh` token | `~/.config/gh/hosts.yml` | `gh hosts.yml` |
| sugarrush config | `~/.config/sugarrush/config.toml` | `sugarrush config` |
| DevPod container token | `~/.config/devpod/dotfiles-env` | `devpod dotfiles-env` |
| DevPod project tokens | `~/.config/devpod/project-tokens` | `devpod project-tokens` |

Fetched every apply, rewritten only when changed, so a rotation in the vault
propagates. A failed or empty fetch leaves the existing file alone.

**Adding one:** create a note item whose body is the file content, then add a
`restore "<item title>" "<target>" 600` line to the script.

**Checking it still works:** `mise run secrets-check` verifies every item is
readable *and* that every template calling `protonPass` still renders — two
different code paths, and a stale vault reference breaks the second while the
first stays green. The item list isn't maintained by hand: it's derived from
the `restore` lines and the `pass://` URIs the templates themselves use, so a
title can only be wrong here if the consumer naming it is wrong. SSH keys are
counted rather than named, because `proton-ssh-load` loads them by item type,
not by title. `dotfiles-secrets-check.timer` runs it weekly and notifies on
failure.

The token is cached at `~/.config/pass-cli-bootstrap-pat` (0600), which is what
makes unattended applies work — and what means disk access alone now reads the
vault. Pass it via the environment, never as `--personal-access-token`.

## SSH keys

Auth, git signing and AUR keys live in the same vault and are loaded straight
into the ssh-agent by `proton-ssh-load`; nothing is written to `~/.ssh`.
`dot_config/shell/ssh-agent.sh` runs it when a shell finds a live but empty
agent. Run it by hand any time — reloading is a no-op.

| Key | Vault item |
| --- | --- |
| auth | `ssh auth key` |
| git signing | `git signing key` |
| AUR | `aur ssh key` |
| bootstrap token | `bootstrap PAT` |

Commit signing goes through the agent: `user.signingkey` is the literal public
key, resolved by `.chezmoitemplates/signing-pubkey` from Proton, falling back to
`ssh-add -L`. If neither answers, the key is omitted while `commit.gpgsign`
stays on, so the next commit fails loudly rather than going unsigned.

`pass-cli ssh-agent debug` explains why an item is or isn't usable.

## YubiKey

Used for touch-to-sudo. Tooling comes from the host package list; PIV holds
nothing this repo depends on.

The key carries **three unrelated PINs** — PIV, FIDO2 (sudo, passkeys) and
OpenPGP (unused). **FIDO2 has no PUK:** exhausting it forces a reset that
destroys every passkey on the key.

### Touch-to-sudo

Setup is deliberately manual: one bad `/etc/pam.d` edit locks you out of sudo
along with the means to fix it.

Register the key — this wants the **FIDO2** PIN:

```sh
pamu2fcfg > /tmp/u2f.line          # PIN + touch
sudo install -m644 /tmp/u2f.line /etc/u2f_mappings && shred -u /tmp/u2f.line
sudo cut -d: -f1 /etc/u2f_mappings # sanity check: prints your username
```

Two steps, not `pamu2fcfg | sudo tee`: sudo would truncate the file first and
both processes would fight for the terminal.

**Open a root shell elsewhere and keep it open** (`sudo -i`) before editing
`/etc/pam.d/sudo`:

```
#%PAM-1.0
auth		sufficient	pam_u2f.so cue authfile=/etc/u2f_mappings
auth		include		system-auth
...
```

`sufficient` and above the `include`, so a missing key falls through to the
password prompt; `required` would lock you out. `cue` prints the touch prompt.

Verify both paths before closing the root shell:

```sh
sudo -k && sudo true    # prompts for a touch
                        # then unplug the key and repeat — should ask for a password
```

Registration is host-specific (origin `pam://$HOSTNAME`). It does not silence
`sudo needs a password; skipping` in automated applies — `sudo -n` cannot wait
for a touch — but `sudo -v` then a non-interactive apply works.

## Layout

| Path | Contents |
| --- | --- |
| `dot_zshrc` | zsh: pure prompt, vi mode, mise/direnv, zoxide `cd`, atuin, tv pickers, fzf-tab, aliases |
| `dot_bashrc` | bash fallback: hands over to zsh on Omarchy, otherwise mirrors zsh's keys and aliases. Kept in step by hand |
| `dot_tmux.conf` | tmux; `prefix o` opens the tv sesh channel |
| `dot_config/mise/config.toml` | globally installed CLI/TUI tools, pinned |
| `dot_config/git/` | git defaults, delta pager, global ignores |
| `dot_config/lazygit/` | lazygit, delta as diff pager |
| `dot_config/atuin/` | atuin history; sync off |
| `dot_config/television/` | local tv channels; the rest come from an external |
| `dot_config/nvim/` | vendored [LazyVim starter](https://github.com/LazyVim/starter) plus tweaks |
| `dot_claude/` | Claude Code: global `CLAUDE.md`, statusline, `rtk-rewrite` hook, `modify_settings.json` |
| `dot_config/omarchy/branding/` | screensaver branding, generated from `assets/`. Host-only |
| `dot_local/bin/` | own scripts: `repos-sync`, `devcontainer-init`, `dotfiles-update-check`, `proton-ssh-load`, and `devpod` (wrapper for the binary in `~/.local/libexec`) |
| `.chezmoiexternals/` | pinned downloads, checksummed where upstream publishes one |
| `assets/` (repo root) | source artwork; never copied into `$HOME` |

Anything that runs in a terminal goes in `dot_config/mise/config.toml` so
containers get it too; desktop apps go in the host package script.
Project-specific tooling belongs in that project's own `mise.toml`. Repo-only
files sit outside `home/` and need no `.chezmoiignore` entry.

## Keybindings

Both shells get the same set.

| Key | Does |
| --- | --- |
| `Ctrl-R` | atuin history search, all directories |
| `Up` | atuin history search, this directory only |
| `Ctrl-T` | tv channel menu — pick a channel, then pick in it; result lands on the command line |
| `Alt-C` | tv directory picker, cds this shell |
| `Ctrl-F` | tv sesh channel: tmux sessions + zoxide directories |
| `Alt-Y` | yazi; quitting cds this shell to wherever you ended up (`y` by name) |
| `prefix o` | the same sesh channel, in a tmux popup |
| `Ctrl-S` | *inside* sesh: cycle source (all/tmux/configs/zoxide/dirs); inside `atuin`: cycle all/this-dir/failed |
| `Ctrl-D` | *inside* sesh: kill the highlighted session and reload |
| `**` + `Tab` | bash only: fzf path completion |

atuin history is local to each machine and container — sync is off, so a rebuilt
container starts empty.

## Daily use

**Project checkouts** live under `$XDG_PROJECTS_DIR` (`~/Projects`) in
`host/owner/repo` layout:

```sh
repos-sync    # clone whatever isn't checked out yet
```

Clone-only: existing checkouts keep their branch, remotes and uncommitted work.
Add repos by editing the list in `dot_local/bin/executable_repos-sync`. New
clones are registered with zoxide, which puts them in the `Ctrl-F` picker.

**Dev containers** are per-project:

```sh
cd ~/Projects/github.com/ronaldlokers/someproject
devcontainer-init      # --force to overwrite an existing .devcontainer/
devpod up .
```

The starter (`archlinux:base`, git, zsh, sudo, openssh, mise, a `dev` user at
uid 1000, and a post-create hook running `mise install`) is deliberately thin —
ports, mounts and extra packages belong in the per-project copy. Edit it at
`dot_local/share/exact_devcontainer-template/`.

DevPod applies these dotfiles inside the container itself. The host side is
configured by `run_onchange_after_30-configure-devpod.sh.tmpl`, and
`~/.local/bin/devpod` wraps every `devpod up` with a no-scope GitHub token and
quiet-mode env. Run `~/.local/libexec/devpod` to bypass the wrapper.

**Git in a container needs no token**: the ssh-agent is forwarded and github
HTTPS remotes are rewritten to SSH there, so clone, push and signing work with
nothing secret stored. The container can *use* every key in your agent while it
runs, but cannot copy them out.

The GitHub **API** is the exception — `gh pr create` needs a token. Opt in per
project:

Add an `owner/repo=token` line to the **`devpod project-tokens`** note in the
Dotfiles vault, then `chezmoi apply`. Surrounding whitespace is tolerated.

Emptying the note does **not** revoke the last token: a blank fetch trips the
empty-fetch guard ("stale beats truncated") and the existing file — and the
token in it — is left alone on every machine, forever, warning only on each
apply. To drop the last entry, leave a line with no `=` instead, e.g.
`# no entries` — the parser requires an `=` and silently skips anything
without one, so the file restores as effectively empty without ever being
literally empty.

Keyed on the project's **push** remote, so a fork resolves to your fork. Mint
each token fine-grained and limited to that repo. No entry, no token.

> [!WARNING]
> A token passed this way lands in `/etc/envfile.json` inside the container,
> mode `0644` — readable by everything running there. Hence one repo per entry.

**Updates**: tool pins are bumped by a self-hosted
[Renovate](https://docs.renovatebot.com) run (`.github/workflows/renovate.yaml`,
weekly or manual, using the `RENOVATE_TOKEN` secret). Patch/minor automerge once
CI is green, majors wait for review. Externals refresh weekly on apply. A user
timer (`dotfiles-update-check.timer`, daily with 4h jitter) reports when this
machine is behind the remote — it only notifies. Run it by hand with
`dotfiles-update-check`.

## Working on this repo

[`CLAUDE.md`](CLAUDE.md) carries the rules for agents. `mise.toml` pins the
tooling and defines the checks, so local runs and CI use identical versions:

```sh
mise run check     # lint + tests + gitleaks + clean-HOME bootstrap (what CI runs)
mise run lint      # shellcheck, actionlint, renovate config
mise run test      # bats suite over the scripts
mise run verify    # bootstrap into a throwaway HOME, non-interactively
```

`verify` is the one that matters before pushing: it redirects `/dev/null` into
the apply, reproducing the no-TTY conditions of `devpod up` and CI.

`test` covers what `verify` structurally cannot. A clean-HOME apply only ever
walks the empty-machine path, so it never sees an `~/.ssh/config` that already
has a `Host` block above the `Include`, or a context percentage arriving as a
bare fraction. Those branches live in `tests/`.

CI (`.github/workflows/ci.yaml`) runs the same checks on push, PR and a weekly
canary, plus `host-ssh-agent` (a real systemd user session) and
`container-gates` (an Arch container proving the host-only gates skip).

Manual, because each needs something CI hasn't got:

```sh
mise run secrets-check     # needs a Proton session
mise run prune             # needs a human: shows a dry run, then asks
```

## Gotchas

- **Nothing secret goes in the repo.** No `.age` blobs, no `chezmoi add
  --encrypt`, no `encrypted_` files — see [Secrets](#secrets).
- **The bootstrap token expires** 2027-07-29. After that `proton-ssh-load` and
  the secrets script quietly report no session until `pass-cli pat renew`.
- **New repo-only files go outside `home/`.** Anything inside is source state
  and gets applied into `$HOME`.
- **Never edit a managed file in `$HOME`.** Edit the source
  (`chezmoi source-path <file>`) and apply.
- **Some commands write to files this repo owns**, and the next apply reverts
  them: `omarchy default terminal` (`dot_config/xdg-terminals.list`), `omarchy
  branding screensaver` (regenerate from `assets/` — see
  [`assets/README.md`](assets/README.md)), and `/plugin` enable/disable in
  Claude Code (edit `dot_claude/modify_settings.json`). `~/.ssh/config` and
  `~/.devpod/config.yaml` are deliberately unmanaged for the same reason.
- **Aliases don't apply in scripts.** `du`, `df`, `top` are aliased to `dust`,
  `duf`, `btop` in interactive shells only.
- **Never run `omarchy-setup-zsh`.** It replaces `~/.zshrc` and `~/.bashrc`,
  which chezmoi owns.
- **A lapsed DevPod PAT looks like nothing at all.** No local check tests it;
  `devpod up` just hits the rate limit it exists to prevent, with CI green.
