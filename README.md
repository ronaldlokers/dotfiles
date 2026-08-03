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
are safe to re-run. The first apply installs `pass-cli`, the second derives
everything.

<a name="bootstrapping"></a>
**Where the token comes from.** It is a Proton Pass personal access token,
scoped `viewer` on the Dotfiles vault, minted from your Proton account and
renewed with `pass-cli pat renew`. The vault holds a copy as `bootstrap PAT`,
which is a record for renewal and *not* where a fresh machine gets it — a
machine with no token cannot read the vault to find the token. That copy is
convenience; the one that bootstraps a new machine has to come from somewhere
you can reach without the vault. Once an apply has succeeded it is cached at
`~/.config/pass-cli-bootstrap-pat` (0600) and you are not asked again until it
expires.

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
> Proton is the only copy unless you make another. No account, no secrets —
> there is no account-free path back, and the same account holds the SSH keys.

### The offline copy

One item cannot be re-issued: **`sops age keys`**. A new age key can be
generated, but nothing already encrypted to the old one can be read again. The
`gh` token, both DevPod tokens, the sugarrush config and the git signing key
can all be revoked and re-minted; SSH keys can too, painfully.

So the offline copy is one small file:

```sh
dotfiles-secrets-export /run/media/you/STICK                    # asks for a passphrase
dotfiles-secrets-restore /run/media/you/STICK/dotfiles-age-key.age   # read it back
```

The second line is not optional, and it used to be `age -d`, which prints the
private key into your scrollback — and your terminal's buffer, and quite
possibly your multiplexer's save file. `dotfiles-secrets-restore` decrypts it,
confirms it is a usable age identity, compares it against the recorded
fingerprint and prints only the *public* half. It writes nothing unless asked:

```sh
dotfiles-secrets-restore --write <file>   # put the key back, on the bad day
```

Run the verify occasionally. The weekly check confirms a *record* exists and
that the vault's key has not rotated since — it never opens the backup, so it
cannot tell you the passphrase is the one you think it is, or that the medium
is still readable. Those are the questions that matter on the day it is needed.

Keep the passphrase somewhere that is **not** Proton Pass — in your head, or
wherever you keep things you cannot look up. A passphrase stored in the vault
rebuilds exactly the single point of failure the copy exists to break.

The export records what it wrote (a date, a destination and the *public* half
of the key — no secret material) at
`~/.local/state/dotfiles/secrets-backup`. `dotfiles-secrets-check` reads that
record on its weekly run and tells you if no copy was ever made, or if the
vault's age key has rotated since. The backup medium does not need to be
plugged in for that: the check compares fingerprints, not files.

Staleness is a fingerprint mismatch, not an age in days. An untouched key means
a two-year-old copy is still a good copy.

<a name="renewing-the-bootstrap-pat"></a>

### Renewing the bootstrap PAT

The weekly check warns for 60 days before the token expires, and says this is
the cause if the session is already dead. It is three commands, not one:

```sh
pass-cli login                      # web login — see below, this step matters
pass-cli pat list                   # find the token's name
pass-cli pat renew --personal-access-token-name <name> --expiration 1y
```

The web login is not optional. Proton refuses every `pat` subcommand while the
session itself came from a personal access token — *"Cannot manage or act on
personal access tokens while logged in with a personal access token"* — and on
this machine that is always how the session was made, because the cached
bootstrap PAT is what creates it. `pass-cli login` replaces that session with
one that may manage tokens.

Then move the date, in both places that hold it:

- `bootstrap_pat_expiry` in `home/dot_local/bin/executable_dotfiles-secrets-check`
- the **bootstrap token expires** line under [Gotchas](#gotchas)

`mise run lint` asserts the two agree, so a half-done renewal fails there rather
than silently leaving a warning that never fires again. Commit, and
`chezmoi apply`. If the renewal hands back a new token value, write it to
`~/.config/pass-cli-bootstrap-pat` (0600) and update the `bootstrap PAT` vault
item too.

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
readable *and* that every template naming a `pass://` URI still renders — two
different code paths, and a stale vault reference breaks the second while the
first stays green. Neither list is maintained by hand: both are derived from
the `restore` lines and the `pass://` URIs the templates themselves use, so a
title can only be wrong here if the consumer naming it is wrong. SSH keys are
counted rather than named, because `proton-ssh-load` loads them by item type,
not by title. `dotfiles-secrets-check.timer` runs it weekly and notifies on
failure.

The token is cached at `~/.config/pass-cli-bootstrap-pat` (0600), which is what
makes unattended applies work — and what means disk access alone now reads the
vault. Pass it via the environment, never as `--personal-access-token`.

If Proton refuses that cached token, `proton-ssh-load` retires it to
`…-bootstrap-pat.rejected` rather than deleting it. A revoked token is not going
to start working, and leaving it in place means every new terminal presents the
same dead credential forever — but a failed login does not distinguish "revoked"
from "Proton was unreachable for ten seconds", and deleting on the second would
destroy the only copy on a machine that cannot read the vault to get another.
Delete the `.rejected` file once a working token is cached again.

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

The `bootstrap PAT` item used to be listed here too, and is not an SSH key: it
is the Proton Pass token that gets you *to* the vault, never goes near the
agent, and is the one credential the vault cannot hand you. See
[Bootstrapping](#bootstrapping).

Commit signing goes through the agent: `user.signingkey` is the literal public
key, resolved by `.chezmoitemplates/signing-pubkey` from Proton, falling back to
`ssh-add -L`. If neither answers, the key is omitted while `commit.gpgsign`
stays on, so the next commit fails loudly rather than going unsigned.

`pass-cli ssh-agent debug` explains why an item is or isn't usable.

### Rotating the signing key

> [!WARNING]
> The key currently in the vault **needs rotating**, and this is not
> hypothetical. Its private half is in this repository's public history, at
> `private_dot_ssh/encrypted_private_id_ed25519_signing.age`. That blob is
> age-encrypted, but only to an identity whose own private half — `key.txt.age`
> — sat at the repository root, in the same public history, wrapped by a single
> passphrase. Anyone who cracks that passphrase has the key that signs these
> commits.

`allowed_signers` carries the retired key with a `valid-before` boundary, so
the commits it already signed keep verifying while it cannot vouch for anything
newer. git compares against the *commit's* timestamp, which is what makes that
work. Do the steps in this order:

1. Mint the replacement, and do not write it to disk:
   ```sh
   ssh-keygen -t ed25519 -C git-signing -f /dev/stdout -N '' -q
   ```
   Or generate it wherever you normally would — what matters is that it lands
   in the vault and nowhere else.
2. Replace the **`git signing key`** item in the Dotfiles vault with it.
   `signing-pubkey` reads `public_key` from that item, so nothing in this repo
   names the key itself.
3. Set `$retiredBefore` in `home/dot_config/git/allowed_signers.tmpl` to the
   day you are doing this, then `chezmoi apply`. Both entries should now
   render — check with
   `chezmoi execute-template < home/dot_config/git/allowed_signers.tmpl`.
4. Add the new public key to GitHub under **Settings → SSH and GPG keys → New
   SSH key**, type *Signing Key*, and remove the old one. Removing it there
   does not un-verify past commits: GitHub keeps the verification it already
   recorded.
5. Verify both directions:
   ```sh
   git log --show-signature -1              # a new commit, new key
   git log --show-signature -1 <old-sha>    # an old commit, retired key
   ```

Until step 2 is done the template deliberately emits only the bounded entry —
the vault still returns the retired key, and listing it twice, once unbounded,
would give back exactly the forgery window the boundary closes.

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
| `.chezmoiexternals/` | pinned downloads, every one checksummed |
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

Three things **never** automerge, for one reason: they are code that runs as
you, and a green pipeline proves the new version installs, not that it is the
version the maintainer published. `.chezmoiexternals/` (fetched binaries and
shell plugins), the two mise tool lists (`dot_config/mise/config.toml` and this
repo's `mise.toml`), and the graphify package, whose vendored skill has to be
re-vendored by hand alongside any bump. Each is a PR to click rather than one
to read.

`.github/workflows/keepalive.yaml` exists because GitHub disables a
repository's scheduled workflows after 60 days of inactivity — which would stop
the weekly CI canary and the Renovate run without stopping anything that
reports on them. It force-pushes an empty commit to an orphan `keepalive`
branch every ten days. Nothing on that branch is meant to be merged or read.

## Working on this repo

[`CLAUDE.md`](CLAUDE.md) carries the rules for agents. `mise.toml` pins the
tooling and defines the checks, so local runs and CI use identical versions:

```sh
mise run check     # lint + test + gitleaks + verify + shells
mise run lint      # shellcheck, actionlint, renovate config, agreement checks
mise run test      # bats suite over the scripts
mise run verify    # bootstrap into a throwaway HOME, non-interactively
```

Some facts are stated in more than one place on purpose — the vault name, the
bootstrap PAT's expiry, the chezmoi version, the two container markers, the
vendored graphify skill's version. Hoisting any of them into a shared file
would be worse than the duplication (the scripts that have to work when other
things do not would gain a runtime dependency on each other; a date hoisted out
of the README is a date nobody reads). `scripts/check-agreement.sh`, run by
`mise run lint`, asserts they still agree, and `tests/check-agreement.bats`
drives each check against a tree with the drift deliberately introduced —
because a checker nobody has watched fail is not a checker.

`check` overlaps CI without matching it, in both directions. It also runs
`shells`, which CI cannot — there is no applied `$HOME` on a runner to start an
interactive shell in. And CI runs two jobs `check` has no way to: `host-ssh-agent`
brings up a real systemd user session, and `container-gates` runs inside an Arch
container to prove the host-only gates skip. A green `check` is the strongest
signal available locally, not a guarantee the pipeline will pass.

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
  the secrets script quietly report no session until it is renewed — which takes
  a web login first, and is written out under [Renewing the bootstrap
  PAT](#renewing-the-bootstrap-pat). The weekly check warns for 60 days
  beforehand *without* failing the unit, and if the session is already dead it
  says the expiry is why rather than leaving you to work it out. That date is
  asserted against the one in `dotfiles-secrets-check` by `mise run lint`, so
  the two cannot drift.
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
- **A lapsed DevPod PAT fails a long way from the cause.** `devpod up` dies
  partway through a container build with `rate limit exceeded`, which looks
  exactly like the anonymous-quota bug the token exists to fix. The weekly check
  now asks GitHub directly whether the token is still accepted, so it is caught
  before a build is. Readable in the vault is not the same as live, and every
  other check only proves the first.
