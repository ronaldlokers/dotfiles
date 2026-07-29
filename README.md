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
  nothing inside a container, so devpod-provisioned boxes skip it. Its
  configuration follows, from
  `.chezmoiscripts/run_onchange_after_30-configure-devpod.sh.tmpl` — see
  [Dev containers](#dev-containers)
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

The coreutils replacements (`dust`, `duf`, `btop`, `sd`, `jless`) are in mise for
the same reason — a container has no pacman, and reaching for `du` inside one
should not be a worse experience than on the host.

tv's channels come from a pinned archive external rather than `tv
update-channels`, so the host and a container see the same set, and Renovate
bumps them with everything else. Several are host-only in practice:
`pacman-packages`, `systemd-units`, the `docker-*` pair and `tldr` have nothing
to list inside a devpod container, and the `k8s-*` channels need a `kubectl` on
PATH, which comes from a project's own `mise.toml` rather than the global pin.
An empty channel there is the tool missing, not the channel broken.

Three channels in the `Ctrl-T` list — `bash-history`, `git-diff` and `text` —
come from tv itself rather than that set: tv compiles ten defaults into the
binary, and only a same-named channel file can override one. `bash-history`
reads `~/.bash_history`, which is a partial record here (see the keybindings
section) — the `atuin` channel below supersedes it.

Two channels are local rather than upstream's. `alias` is a faster rewrite of
one that shipped (see `dot_config/television/cable/`), and `atuin` has no
upstream equivalent: it searches atuin's database instead of a history file,
cycling with `Ctrl-S` between all history, this directory only, and commands
that actually failed. The preview shows when a command last ran, how it
exited, and where. Imported history predates that bookkeeping and shows
`exit=-1` / `unknown`, which is the import having no such data rather than a
failure. `Ctrl-R` is still atuin's own TUI, which does filter modes, time
syntax and stats better than a channel can; this is for reaching history
without leaving the picker that is already open.

Ghostty is the entry that only looks like it breaks that rule: it runs in a
terminal because it *is* the terminal, and it needs a display, so it's a desktop
app. Which terminal `Super + Return` opens is a separate question, answered by
`dot_config/xdg-terminals.list` — Ghostty first, Alacritty second so the binding
still works on a fresh machine in the window between chezmoi writing files and
the package step running. `omarchy default terminal <name>` writes that same
file, so its effect is reverted by the next apply; switch terminals by editing
the list. The list is ignored inside containers, which have no display to open a
terminal on.

`zsh` is the other exception, and a real one rather than an apparent one: a login
shell has to be listed in `/etc/shells` and already be running before anything
gets far enough to activate mise, so mise can't be what provides it. The host
script also sets it as the login shell, once the package is installed. `setup`
tries that too, but on a fresh machine it runs *before* zsh exists, so its
check no-ops — the package step is what actually lands the change.

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

### Shell keybindings

Both shells get the same set, so a machine where zsh isn't the login shell yet
behaves the same:

| Key | Does |
| --- | --- |
| `Ctrl-R` | atuin history search, all directories |
| `Up` | atuin history search, this directory only |
| `Ctrl-T` | tv channel menu — pick a channel, then pick in it; the result lands on the command line |
| `Alt-C` | tv directory picker, cds this shell |
| `Ctrl-F` | tv sesh channel: tmux sessions + zoxide directories |
| `prefix o` | the same sesh channel, in a tmux popup |
| `Ctrl-S` | *inside* the sesh channel: cycle source (all/tmux/configs/zoxide/dirs) |
| `Ctrl-D` | *inside* the sesh channel: kill the highlighted session and reload |

`Ctrl-R` used to be fzf's; atuin owns it and `Up` exclusively now — nothing
else in either rc file binds either key. fzf itself stays installed
regardless: tv owns the pickers above and atuin owns history search, but
zsh's completion menu (fzf-tab) is built on fzf and still needs it on `PATH`.

Bash keeps fzf's `**<TAB>` path-completion trigger — type a path fragment,
`**`, then Tab for a fuzzy-complete menu — because `dot_bashrc` sources the
*completion half* of `fzf --bash` and nothing else. Sourcing the whole thing
would also install fzf's `Ctrl-T`, `Alt-C` and `Ctrl-R` bindings; tv and atuin
override most of those, but atuin only binds `Ctrl-R` in the emacs and
vi-insert keymaps, so fzf's would survive in vi-command and `Esc` then `Ctrl-R`
would open the wrong history search. The completion half needs one variable
(`__fzf_awk`) from the other half, which `dot_bashrc` sets itself.

atuin history is **local to each machine and each container**: sync is off, so a
rebuilt devpod container starts with an empty database.

## Updates

Tool versions in `dot_config/mise/config.toml` are pinned and bumped by a
self-hosted [Renovate](https://docs.renovatebot.com) run
(`.github/workflows/renovate.yaml`, weekly or via manual dispatch). It
authenticates with the `RENOVATE_TOKEN` repo secret — a PAT with `repo` and
`workflow` scope. Externals (mise binary, zsh plugins, bash-preexec, tv's
channel set) refresh weekly on `chezmoi apply`. CI
(`.github/workflows/ci.yaml`) lints, scans history with gitleaks, and
test-bootstraps the repo into a clean HOME on every push, PR, and a weekly
canary run. Two jobs cover paths the clean-HOME bootstrap can't reach:
`host-ssh-agent` brings up a real systemd user session, and `container-gates`
runs inside an Arch container to prove the host-only gates actually skip there.
Renovate automerges patch/minor bumps once CI is green; majors wait for review.

### Staying current

A user timer (`dotfiles-update-check.timer`, daily with a 4h jitter) fetches and
reports when this machine is behind the remote. It **only notifies** — it never
pulls and never applies. An unattended `chezmoi update` would restart services
and re-run scripts at an arbitrary moment, including secret decryption, which
now means a YubiKey PIN prompt with no terminal to answer it.

It stays silent when there's nothing to say, and distinguishes a clean
fast-forward from a diverged branch. Run it by hand with
`dotfiles-update-check`. Enabled by
`run_onchange_after_11-enable-update-check.sh.tmpl`, which skips where no
systemd user session exists — so containers don't get it.

## Project checkouts

Personal repos live under `$XDG_PROJECTS_DIR` (`~/Projects`, declared in
`~/.config/user-dirs.dirs`) in `host/owner/repo` layout:

```
~/Projects/github.com/ronaldlokers/homelab
```

The host level is more than six GitHub repos need, but it's what stops a
third-party clone of the same name — or a second forge — from colliding later.
Depth costs nothing to navigate with zoxide.

A successful clone is also added to zoxide's database. That is what puts a
brand-new checkout in the `sesh` picker (`Ctrl-F`, or `prefix o` in tmux)
before anyone has ever `cd`'d into it — zoxide is the only source of
directories sesh has.

```sh
repos-sync    # clone whatever isn't checked out yet
```

Deliberately **not** part of `chezmoi apply`: a fresh machine shouldn't be made
to pull every repo before it's usable, and a devpod container has no business
holding them. It only ever clones — an existing checkout is left alone, branch,
remotes and uncommitted work included. Add a repo by editing the list in
`dot_local/bin/executable_repos-sync`.

Clones use **HTTPS**, authenticated by the `gh` credential helper already in
`dot_config/git/config.tmpl`. Note `gh` itself is configured to prefer SSH for
git operations while this machine has no SSH *auth* key (only the signing key),
so `gh repo clone` would take a path that doesn't work here.

## Dev containers

Project work happens in [DevPod](https://devpod.sh) containers, driven by the
docker provider. The host side of that is configured by
`run_onchange_after_30-configure-devpod.sh.tmpl`: it adds and selects the docker
provider, sets the default IDE to `none` (the workflow is a terminal, not an
editor launch), and sets three context options every workspace inherits —
`DOTFILES_URL`, which is what makes a fresh container apply this repo,
`DOTFILES_SCRIPT=setup`, and `GIT_SSH_SIGNATURE_FORWARDING=false`.

`DOTFILES_SCRIPT` names the installer outright. Left empty DevPod guesses,
probing `install.sh`, `install`, `bootstrap.sh`, `bootstrap`,
`script/bootstrap` and `setup.sh` before it reaches `setup` — logging a
`Failed to make install script … not found` line for each miss. Those are all
scripts this repo has deliberately never had, so the six failures reported
nothing and only buried the lines that mattered.

The script drives the `devpod` CLI instead of managing `~/.devpod/config.yaml`
directly, because DevPod writes that file itself — the provider's `initialized`
flag and creation timestamp are its own bookkeeping. A managed copy would be
reverted on every apply and show as permanent drift.

Per-project, the container is defined by a `.devcontainer/` in the repo itself.
Scaffold one from the managed starter:

```sh
cd ~/Projects/github.com/ronaldlokers/someproject
devcontainer-init      # --force to overwrite an existing .devcontainer/
```

It writes `devcontainer.json`, `Dockerfile` and `post-create.sh`, naming the
container after the directory. The starter is deliberately thin — `archlinux:base`
with git, zsh, sudo and mise, a `dev` user at uid 1000 with passwordless sudo, and
a post-create hook that runs `mise install` — because ports, mounts and extra
packages differ per project and belong in the copy. Edit the starter at
`dot_local/share/devcontainer-template/`.

Arch rather than Debian for two reasons. It matches the host, so package
commands and versions are the same either side of the container boundary. And
`debian:trixie` ships no `libatomic.so.1`, which mise's prebuilt node links
against — on Debian `mise install` failed on node, skipped `gemini-cli` as a
dependent, and failed the whole `chezmoi apply` behind it.

The cost is that the image is built from a `Dockerfile` rather than pulled: the
`common-utils` and `git` devcontainer features accept debian, rhel and alpine
only, and exit with `Linux distro arch not supported`. The Dockerfile covers
what those features are actually relied on for — the `dev` user, the sudoers
entry, zsh, generating the `en_US.UTF-8` locale that `dot_zshrc` expects, an
`openssh` client so DevPod's SSH clone and git's commit signing work, and a
compiler toolchain (`base-devel`, `python`) so `gemini-cli`'s `node-pty`
dependency can build. The rest of what `common-utils` used to bundle —
`bash-completion`, `wget`, `rsync`, an editor, `man-db`, `tree`, and more — is
not reproduced; this repo's own mise tool list covers what this setup
actually uses.

mise is installed from Arch's repos rather than as a feature. `postCreateCommand`
runs before DevPod clones the dotfiles — as do `postStartCommand` and
`postAttachCommand` — so the pinned `~/.local/bin/mise` this repo installs does
not exist yet when `post-create.sh` runs `mise install`. Interactive shells still
use the pinned one, because `dot_zshrc` prefers it explicitly.

Nothing installs the dotfiles from inside the container: DevPod clones and
applies them itself, via the `DOTFILES_URL` option above.

That bootstrap needs a GitHub token. mise resolves a version through the
GitHub API for every `github:`, `vfox:` and `pipx:` tool, and unauthenticated
that is 60 requests an hour per IP — less than this repo's tool list, so a
cold container fails partway through with `rate limit exceeded` and takes the
whole apply with it. The host is unaffected because `gh` is authenticated
there; a container has no `gh` session, since `hosts.yml` only decrypts with a
TTY.

So `~/.config/devpod/dotfiles-env` holds a **fine-grained** PAT as
`MISE_GITHUB_TOKEN`, and a `devpod` shell function in both rc files hands that
file to `devpod up --dotfiles-script-env-file`. The wrapper walks the
arguments rather than just checking `$1`, since devpod is a cobra CLI and
global flags are legal before the subcommand; it skips option tokens —
including the four value-taking globals (`--context`, `--devpod-home`,
`--log-output`, `--provider`) — and treats the first non-option token as the
subcommand, appending the token file only when that's `up` and the file is
readable. (A future global flag that takes a separate value but isn't in that
list would be misread as the subcommand and silently skip the token file.)
The token carries no permissions beyond public-repository read because mise
needs it only for the rate limit — a container that leaks it leaks
public-read quota and nothing else. `command devpod` bypasses the wrapper,
and a machine whose age identity is still locked has no such file, so the
wrapper passes straight through and containers bootstrap exactly as they did
before.

The same `up` also gets `MISE_QUIET=1`, secret or not. A cold bootstrap
otherwise prints well over a hundred lines of mise install progress through
DevPod's logger; `MISE_QUIET` drops that and keeps the errors — a failing
install still prints `mise ERROR …` and exits non-zero. Deliberately not
devpod's own `--silent`, which suppresses everything short of a panic,
including the `Execution of ./setup was unsuccessful` line that is how a
broken bootstrap announces itself.

That token's expiry is not checked by anything local: `mise run
secrets-restore` only proves the age blob still decrypts, not that the
plaintext PAT is still live, and `mise run check` doesn't touch it either. A
lapsed fine-grained PAT looks exactly like the original bug — `devpod up`
silently reverts to the rate-limit failure this section exists to fix, with
every local check green. And this covers the dotfiles bootstrap only: a
project whose own `mise.toml` pulls `github:`/`vfox:`/`pipx:` tools can still
exhaust the anonymous quota in its `postCreateCommand`, since that runs
before DevPod clones the dotfiles and this token is nowhere in scope yet.

## Co-owned configuration files

Some files under `$HOME` are written by both this repo and by the program
that reads them: DevPod appends a `# DevPod Start <workspace>` … `# DevPod
End` block to `~/.ssh/config` per workspace, and Claude Code writes runtime
keys like `agentPushNotifEnabled` into `~/.claude/settings.json` that this
repo has never heard of. Managing either file the ordinary way — as a
static, fully chezmoi-owned target — means every `chezmoi apply` overwrites
whatever the other writer just wrote, silently reverting it. This repo
settles on one of two answers depending on what the other writer's file
supports, plus a third for the case where the file shouldn't be managed at
all.

When the file supports an include mechanism, own a fragment beside it
instead of the file itself. `~/.ssh/config` is deliberately unmanaged;
chezmoi owns `~/.ssh/config.d/10-dotfiles.conf`
(`private_dot_ssh/private_config.d/`), and `run_after_12-ensure-ssh-include.sh`
asserts that the real config has an `Include config.d/*.conf` line pointing at
it — prepending one if it's missing or placed below a `Host`/`Match` block —
and, the first time it has to rewrite the file, also migrates away the old
three-line `AddKeysToAgent` block the fragment now supersedes. DevPod's blocks
live below, untouched. That script runs on
every apply rather than only on `run_onchange`, because it's re-asserting an
invariant about a file chezmoi can't diff: if something later removed the
Include line, a `run_onchange` script would only ever check once and never
notice it happening again.

When there's no include mechanism and the two sets of keys have to share one
document, merge instead. `~/.claude/settings.json` has no notion of
fragments, so `dot_claude/modify_settings.json` is a `modify_` script:
chezmoi feeds it the file's current on-disk contents on stdin, and whatever
it prints on stdout becomes the new file. The merge is shallow and
managed-wins — `jq -s '.[0] + .[1]'` with the on-disk contents first — so
`enabledPlugins` and `extraKnownMarketplaces` are replaced wholesale (this
repo stays the sole authority over which plugins are enabled) while an
unrecognized top-level key like `agentPushNotifEnabled`, absent from the
repo's baseline, passes through untouched.

Being the sole authority over `enabledPlugins` means the baseline is where
plugin state is decided, not `/plugin` — a plugin re-enabled interactively is
reverted by the next apply, so a lasting change is an edit to
`modify_settings.json`. The baseline pins the same way for `skillOverrides`
(individual skills switched off) and `permissions.defaultMode`, which is set
to `auto`: routine per-action approvals go to the safety classifier instead
of prompting. That one has to be user-scope — an `auto` default mode in a
project's own settings is ignored as repo-controllable — and it can't lock
anyone out, since an unavailable auto mode falls back to prompting.

The third case is not managing the file at all. `~/.devpod/config.yaml` is
entirely DevPod's own bookkeeping — the provider's `initialized` flag and
creation timestamp included — so chezmoi doesn't touch it directly;
`run_onchange_after_30-configure-devpod.sh.tmpl` drives the `devpod` CLI
instead, and whatever the CLI then writes to the file is none of chezmoi's
business.

`modify_` scripts carry a constraint neither of the other two answers do:
they run on *every* apply, not just when their rendered content changes, and
CI asserts that a second `chezmoi apply` produces no managed-file drift. A
`modify_` script's output therefore has to be a fixed point — feeding its own
output back in as stdin must reproduce it byte-for-byte — or the second
apply changes the file again and CI fails. That's what made
`modify_settings.json` fiddly: the merge has to stay stable under jq's own
pretty-printing, and it has to behave the same on the clean-HOME apply where
the settings file doesn't exist yet as on the apply right after, where jq
itself isn't installed. The fragment approach sidesteps this entirely — the
include check either finds its line already there and does nothing, or adds
it once and is done — because a plain `run_after` script re-running is fine
as long as it's idempotent, but it never has to reproduce a whole file's
bytes.

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

Secrets are stored as plain `<name>.age` blobs — **not** with `chezmoi add
--encrypt` (that `encrypted_` flow decrypts at apply time and breaks the
non-interactive bootstrap; see [`CLAUDE.md`](CLAUDE.md)). Each blob's target path
is listed in `.chezmoiignore` so the raw ciphertext isn't copied into `$HOME`.

Every blob is encrypted to **two recipients**, so either key opens any secret:

| Recipient | Where it lives |
| --- | --- |
| YubiKey (PIV slot 82) | On the key itself; generated on-device, not extractable |
| File identity | `~/.config/chezmoi/key.txt`, committed as `key.txt.age` under a passphrase (backup: Proton Pass) |

Adding a recipient does **not** re-encrypt existing blobs — see
[Rotating the recipient set](#rotating-the-recipient-set).

`[age]` points at `~/.config/chezmoi/identities.txt`, which
`run_before_00-unlock-secrets.sh.tmpl` assembles from whichever identities the
machine has, YubiKey first. It has to be one generated file rather than a list
of paths: **age treats a listed-but-missing identity as fatal**, so naming both
directly breaks any machine with only one — a container has no YubiKey, and a
fresh machine has no `key.txt` until the passphrase step creates it mid-apply.

A missing *plugin* is fine by contrast: age falls through to the next identity,
so containers decrypt via `key.txt` with no YubiKey and no plugin installed.

That script is a plain `run_before` — it re-runs every apply and is a fast no-op
once settled, so a later interactive apply finishes what a non-interactive one
skipped. It skips rather than fails when `age` is absent (mise installs it only
*after* this script runs on a fresh machine).

Currently decrypted by the script:

| Secret | Target | Source blob |
| --- | --- | --- |
| SSH signing key | `~/.ssh/id_ed25519_signing` | `private_dot_ssh/private_id_ed25519_signing.age` |
| sops age keys | `~/.config/sops/age/keys.txt` | `dot_config/private_sops/private_age/private_keys.txt.age` |
| `gh` token | `~/.config/gh/hosts.yml` | `dot_config/private_gh/private_hosts.yml.age` |
| sugarrush config | `~/.config/sugarrush/config.toml` | `dot_config/private_sugarrush/private_config.toml.age` |
| DevPod container token | `~/.config/devpod/dotfiles-env` | `dot_config/private_devpod/private_dotfiles-env.age` |

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

The YubiKey is the other way in, and needs no passphrase — drop its identity in
and apply:

```sh
install -m600 /path/to/yubikey-identity.txt ~/.config/chezmoi/yubikey-identity.txt
chezmoi init && chezmoi apply
```

> [!WARNING]
> The two recipients are only independent if their backups are. Losing the
> passphrase *and* its Proton Pass copy leaves the YubiKey as the sole way in,
> and vice versa. Re-verify the restore path after any key rotation.

### Rotating the recipient set

Adding a recipient does **not** rewrite existing blobs — they stay readable only
by whoever was a recipient when written, so a new key silently can't open old
secrets. After changing `recipients` in `.chezmoi.toml.tmpl`, run `chezmoi init`
to regenerate the live config, then rewrite every blob:

```sh
for blob in $(git ls-files '*.age' | grep -v '^key.txt.age$'); do
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

## YubiKey

A YubiKey 5Ci holds the primary age identity (PIV slot 82, generated on-device,
PIN policy `once`, touch policy `cached` — one touch covers a whole apply rather
than one per secret). Tooling comes from the host package list: `pcsclite`,
`yubikey-manager`, `yubikey-personalization`, `age-plugin-yubikey`, `pam-u2f`.

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

**Scope the `umask` to a subshell** as above. Left set in an interactive shell
it silently follows every later command — a `chezmoi apply` in the same terminal
then writes every managed file at `0600` instead of `0644`, which is how 521
files once ended up needing a re-apply to fix.

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
`.chezmoi.toml.tmpl` and re-encrypt — a new key cannot read existing blobs
otherwise. See [Rotating the recipient set](#rotating-the-recipient-set).

### Touch-to-sudo

`pam-u2f` is installed by the host package list, but the setup is **deliberately
manual** — `/etc/pam.d` is outside `$HOME` so chezmoi can't manage it, and a
script that rewrites the sudo auth stack on every machine is a bad trade: one bad
edit locks you out of sudo everywhere, including the means to fix it.

Register the key. This wants the **FIDO2** PIN, not the PIV one:

```sh
pamu2fcfg > /tmp/u2f.line          # PIN + touch
sudo install -m644 /tmp/u2f.line /etc/u2f_mappings && shred -u /tmp/u2f.line
sudo cut -d: -f1 /etc/u2f_mappings # sanity check: prints your username
```

Do it in two steps like that, not `pamu2fcfg | sudo tee`: `sudo` would truncate
the file before `pamu2fcfg` produces anything, and both processes then compete
for the terminal — one wanting the FIDO2 PIN, the other your sudo password.

**Open a root shell in another terminal and keep it open** (`sudo -i`). It's the
escape hatch if the next step is wrong. Then add one line to `/etc/pam.d/sudo`:

```
#%PAM-1.0
auth		sufficient	pam_u2f.so cue authfile=/etc/u2f_mappings
auth		include		system-auth
...
```

`sufficient`, not `required`, and above the `include`: a touch satisfies auth,
and if the key is absent PAM falls through to the normal password prompt.
`required` would demand both and lock you out whenever the key isn't plugged in.
`cue` prints "Please touch the device" so sudo doesn't hang silently.

Verify both paths before closing the root shell:

```sh
sudo -k && sudo true    # prompts for a touch
                        # then unplug the key and repeat — should ask for a password
```

Registration is host-specific: `pamu2fcfg` defaults to origin `pam://$HOSTNAME`,
so this credential won't work on a second machine. Fixing that means passing a
shared `-o`/`-i` origin at registration time.

This does **not** remove the `sudo needs a password; skipping` message from
automated applies — `sudo -n` can't wait for a touch any more than it can prompt
for a password. What it gives you is `sudo -v` (a touch) followed by a
`chezmoi apply` that works non-interactively for the credential cache window.

## Layout

| Path | Contents |
| --- | --- |
| `dot_zshrc` | zsh: pure prompt, vi mode, mise/direnv, zoxide-backed `cd`, atuin history (`Ctrl-R`), tv pickers (`Ctrl-T`/`Alt-C`/`Ctrl-F`), cached completions, autosuggestions + syntax highlighting, aliases |
| `dot_config/git/` | git defaults, delta pager, global ignores (machine-local bits stay in unmanaged `~/.gitconfig`) |
| `dot_config/lazygit/` | lazygit config: delta as diff pager |
| `dot_bashrc` | bash fallback: hands over to zsh on Omarchy, otherwise mirrors zsh's tv keys, zoxide-backed `cd`, atuin history, `MANPAGER` and aliases — no prompt or plugins. Kept in step with `dot_zshrc` by hand |
| `dot_tmux.conf` | tmux config; `prefix o` opens the tv sesh channel |
| `dot_config/mise/config.toml` | globally installed CLI tools |
| `dot_config/atuin/` | atuin: SQLite shell history, sync deliberately off — container history is local and dies with the container |
| `dot_config/television/` | television: the local channels (`cable/alias.toml`, `cable/atuin.toml`); the rest arrive from a pinned external |
| `dot_config/nvim/` | Neovim config: vendored [LazyVim starter](https://github.com/LazyVim/starter) plus own tweaks |
| `dot_claude/` | Claude Code: global `CLAUDE.md`, statusline, `rtk-rewrite` hook, and `modify_settings.json` — the merged baseline for `~/.claude/settings.json` (see [Co-owned configuration files](#co-owned-configuration-files)) |
| `dot_config/omarchy/branding/` | Omarchy screensaver branding: braille art generated from `assets/lokilabslogo.png`. Host-only — a container has no screensaver to brand |
| `assets/` | Source artwork generated files are derived from, never copied into `$HOME`. See `assets/README.md` for the regeneration command |

Project-specific tooling (kubectl, flux, krew, ...) is intentionally *not*
here — it lives in each project's own `mise.toml`.

Repo-only files (`setup`, `README.md`, `CLAUDE.md`, `assets/`) are listed in
`.chezmoiignore` so chezmoi doesn't copy them into `$HOME`.

The screensaver branding is co-owned in the same sense as the files below:
`omarchy branding screensaver <image|text|reset>` writes to that exact path, so
anything it does is undone by the next `chezmoi apply`. Change the source art in
`assets/` and regenerate instead — the command is in `assets/README.md`.
