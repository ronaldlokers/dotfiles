# Design notes

Why this repo is built the way it is. [`README.md`](../README.md) covers what to
run; this file covers the decisions behind it, so a change that looks obviously
correct can be checked against the reason the current shape exists.

## The source tree lives in `home/`

`.chezmoiroot` names `home` as the source root, so the repo root holds only
things chezmoi never reads: `README.md`, `CLAUDE.md`, `docs/`, `assets/`,
`setup`, `mise.toml`, `.github/`.

Before it, every one of those was source state that happened to be listed in
`.chezmoiignore`. That made the ignore file load-bearing in a way nothing
checked: adding a new doc, a lint config or a CI helper at the repo root and
forgetting the entry applied it straight into `$HOME`, silently and on every
machine. The failure mode was a new file appearing in someone's home directory,
which no test looks for. `.chezmoiroot` removes the class of mistake instead of
guarding against it — a file outside `home/` cannot be applied, whatever
`.chezmoiignore` says. What is left in `.chezmoiignore` is only what it is
actually for: paths chezmoi *should* see but must not copy.

Two files stayed inside the source tree deliberately. `key.txt.age` and
`ghostty.terminfo` are read through `{{ .chezmoi.sourceDir }}` and `include`,
both of which resolve relative to the source directory, so moving them along
with the tree kept those call sites correct with no edit. Neither is applied:
both are still listed in `.chezmoiignore`.

`--source "$PWD"` is unaffected — chezmoi reads `.chezmoiroot` from the
directory it is pointed at and descends — so `mise run verify`, CI's clean-HOME
bootstrap and `setup` all keep working unchanged. What did break is anything
that assumed the source directory *is* the repo: `dotfiles-update-check` tested
`[ -d "$source_dir/.git" ]`, which is now false, and would have exited 0 on
every timer firing without a word. It asks git instead
(`git -C "$source_dir" rev-parse --is-inside-work-tree`), which walks up to the
repo root.

### The version floor

`.chezmoiversion` sits next to `.chezmoiroot` at the repo root, outside `home/` —
it has to be read before the root is descended into. It names `2.70.5`, the same
version `home/dot_config/mise/config.toml` pins, because that pin is the only
chezmoi CI and every machine actually exercises. A fresh machine satisfies the
floor regardless: `setup` installs latest from `get.chezmoi.io`.

Two files now carry that number, so `mise run lint` asserts they agree. Renovate
bumps the mise pin on its own schedule; the failing assertion is what says "bump
the floor too" rather than letting them drift apart silently.

### `exact_` on two directories, not six

`exact_` makes chezmoi delete anything in the target directory it doesn't
manage, so it only fits directories this repo is the sole writer of. Two
qualify: `home/private_dot_ssh/exact_private_config.d` (whose whole point is
that `~/.ssh/config` includes it and nothing else writes there) and
`home/dot_local/share/exact_devcontainer-template` (a starter this repo
generates in full).

Four were refused, each because something else writes into the target:

- `dot_config/nvim/lua/plugins/` — Omarchy drops `all-themes.lua`, `theme.lua`,
  `omarchy-theme-hotreload.lua` and two more in there, and LazyVim's starter
  leaves `example.lua`. `exact_` would delete all six on the next apply and take
  Omarchy's nvim theming with them.
- `dot_config/television/cable/` — the tv-channels external unpacks into the
  same target.
- `dot_local/bin/` — holds the chezmoi, mise and devpod binaries, none of them
  managed as files.
- `dot_claude/skills/` — holds `omarchy`, installed from outside this repo.

The test before adding `exact_` anywhere is `chezmoi apply --dry-run --verbose
<target>`: if it proposes a deletion, the directory has another writer.

## Packages

Two lists, split by *where* a tool is wanted rather than by what installs it:

| | Where | Goes in |
| --- | --- | --- |
| CLI / TUI tools | host **and** devpod containers | `dot_config/mise/config.toml` |
| Desktop apps | host only | `run_after_20-install-host-packages.sh.tmpl` |

Anything that runs in a terminal belongs in mise, even when a distro package
exists — `yazi` is in Arch's `extra` and `sugarrush` has its own AUR package,
but both are TUIs, wanted inside a container as much as on the host, and a
container has no pacman. mise pins versions and Renovate bumps them; the host
list is unpinned and tracks whatever the distro ships.

Ghostty only looks like it breaks that rule: it runs in a terminal because it
*is* the terminal, and it needs a display, so it's a desktop app. Which terminal
`Super + Return` opens is a separate question, answered by
`dot_config/xdg-terminals.list` — Ghostty first, Alacritty second so the binding
still works on a fresh machine in the window between chezmoi writing files and
the package step running.

`zsh` is a real exception rather than an apparent one: a login shell has to be
listed in `/etc/shells` and already be running before anything gets far enough to
activate mise, so mise can't be what provides it. The host script also sets it as
the login shell, once the package is installed. `setup` tries that too, but on a
fresh machine it runs *before* zsh exists, so its check no-ops — the package step
is what actually lands the change.

### Pruning on evidence

The tool list is pruned by asking atuin how often something is genuinely reached
for, remembering that many tools are invoked indirectly (`bat` through the `cat`
alias, `fd` and `rg` through tv channels, `delta` through git, `rtk` through the
Claude Code hook) and that a count of zero for those means nothing. `superfile`
and `kubeconform` left that way — the first a second file manager next to `yazi`
splitting eight invocations across ~1200 commands, the second already pinned by
the one project that uses it.

The same evidence drove aliasing three coreutils replacements over the commands
they replace (`du`→`dust`, `df`→`duf`, `top`→`btop`): an audit found the aliased
tools (`cat`, `ls`) used 144 times between them while the unaliased replacements
sat at one or two apiece, because using them meant remembering a new name.
Aliases apply only to interactive shells, so `du -sh` in a script still runs
coreutils. `sd` and `gping` are left alone deliberately: `sd` takes entirely
different arguments from `sed`, and `gping` plots a graph rather than standing in
for `ping`.

### The host script's shape

It is deliberately a plain `run_after`, not a `run_onchange`: chezmoi records a
`run_onchange` script's hash as soon as it exits 0, so a run that skipped — no
TTY for sudo, no package manager — would be remembered as done and never
retried. Running every apply costs one `pacman -Q` per package and lets a later
interactive apply finish the job.

It installs nothing when `/.dockerenv` or `/run/.containerenv` exists, when
there's no `pacman` on `PATH`, or when sudo needs a password with no TTY to ask
on. The container test lives in `.chezmoitemplates/is-container`, shared with the
devpod external and `.chezmoiignore`, so the gates can't drift apart.

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

## Shell keys: who owns what

Five pickers coexist because they reach different things: `cd` (zoxide) jumps to
a directory you already know by name, `Alt-C` descends into one you have never
visited, `Ctrl-T` puts a path on the command line rather than changing directory,
`Ctrl-F` switches tmux sessions rather than directories, and `Alt-Y` (yazi) is
for looking around. That last one earns its place from the arrive-look-peek loop
— an audit counted 89 bare `ls` and 48 `cat` against 145 name jumps, and a file
manager with previews collapses the first two without touching the third. `y`
goes through zoxide's `cd` rather than `builtin cd`, so directories reached by
browsing feed the frecency that `cd`, `Alt-C` and `Ctrl-F` all read from.

`Ctrl-R` used to be fzf's; atuin owns it and `Up` exclusively now — nothing else
in either rc file binds either key. fzf itself stays installed regardless,
because zsh's completion menu (fzf-tab) is built on it.

Bash keeps fzf's `**<TAB>` path-completion trigger because `dot_bashrc` sources
the *completion half* of `fzf --bash` and nothing else. Sourcing the whole thing
would also install fzf's `Ctrl-T`, `Alt-C` and `Ctrl-R` bindings; tv and atuin
override most of those, but atuin only binds `Ctrl-R` in the emacs and vi-insert
keymaps, so fzf's would survive in vi-command and `Esc` then `Ctrl-R` would open
the wrong history search. The completion half needs one variable (`__fzf_awk`)
from the other half, which `dot_bashrc` sets itself. The tv widgets are bound
across all three keymaps for the same reason.

### Television channels

Channels come from a pinned archive external rather than `tv update-channels`, so
the host and a container see the same set and Renovate bumps them with everything
else. Several are host-only in practice: `pacman-packages`, `systemd-units`, the
`docker-*` pair and `tldr` have nothing to list inside a container, and the
`k8s-*` channels need a `kubectl` on PATH, which comes from a project's own
`mise.toml`. An empty channel there is the tool missing, not the channel broken.

Three channels in the `Ctrl-T` list — `bash-history`, `git-diff` and `text` —
come from tv itself rather than that set: tv compiles ten defaults into the
binary, and only a same-named channel file can override one.

Two channels are local rather than upstream's. `alias` is a faster rewrite of one
that shipped, and `atuin` has no upstream equivalent: it searches atuin's
database instead of a history file, cycling with `Ctrl-S` between all history,
this directory only, and commands that actually failed. The preview shows when a
command last ran, how it exited, and where. Imported history predates that
bookkeeping and shows `exit=-1` / `unknown`, which is the import having no such
data rather than a failure. `Ctrl-R` is still atuin's own TUI, which does filter
modes, time syntax and stats better than a channel can; the channel is for
reaching history without leaving the picker that is already open.

## Secrets

`[age]` points at `~/.config/chezmoi/identities.txt`, which
`run_before_00-unlock-secrets.sh.tmpl` assembles from whichever identities the
machine has, YubiKey first. It has to be one generated file rather than a list of
paths: **age treats a listed-but-missing identity as fatal**, so naming both
directly breaks any machine with only one — a container has no YubiKey, and a
fresh machine has no `key.txt` until the passphrase step creates it mid-apply.

A missing *plugin* is fine by contrast: age falls through to the next identity,
so containers decrypt via `key.txt` with no YubiKey and no plugin installed.

That script is a plain `run_before` — it re-runs every apply and is a fast no-op
once settled, so a later interactive apply finishes what a non-interactive one
skipped. It skips rather than fails when `age` is absent, because mise installs
`age` only *after* this script runs on a fresh machine.

chezmoi has a built-in age, but built-in age can't load plugins — so driving a
YubiKey-backed identity means pointing `age.command` at a real binary, which is
why `age` is pinned in mise on every machine that decrypts anything.

### Proton Pass is pinned, but not wired into apply

`pass-cli` is installed as a checksummed external and used by hand. It is *not*
a secret source for chezmoi, even though it offers the same `inject`/`run` model
a 1Password-backed setup would use, because a Proton session cannot exist inside
a devpod container or in CI — the same failure mode `chezmoi add --encrypt` is
banned for. The `.age` blobs work offline with no account, and the YubiKey path
needs no session at all.

It is an external rather than a mise pin because Proton publishes it from
`proton.me`, not GitHub, and it isn't in the mise registry — so it follows
`.chezmoiexternals/k9s.toml`: a pinned URL plus a `checksum.sha256`. Bumping
stays manual and Renovate is deliberately not wired up, because a bump of the
version alone would produce an external that fails its own checksum on every
apply. The version and hash come from
`https://proton.me/download/pass-cli/versions.json`, which has to be read as a
pair.

### SSH keys live in Proton Pass, and only in the agent

The three private keys are stored as Proton Pass `ssh-key` items in a dedicated
**Dotfiles vault**, and `~/.local/bin/proton-ssh-load` loads them into the
running ssh-agent with `pass-cli ssh-agent load`. They are never written to
`~/.ssh`.

Two of them — the auth key and the AUR key — were previously backed up
**nowhere**, existing only on this laptop while being load-bearing for container
git and for `devpod up` (whose `DOTFILES_URL` is SSH). The signing key was an
`.age` blob. All three now live together, and no private key sits in git
history, where it would stay for good even after a rotation.

Keeping them out of `~/.ssh` is what makes this simpler than a restore-to-disk
script rather than more complicated. Nothing needs syncing, nothing can drift,
and a stolen disk yields no keys. It works because everything this machine does
with them goes through the agent anyway:

- **git over SSH** — the agent answers.
- **commit signing** — git signs with an agent-held key as long as
  `user.signingkey` names a *public* key file, which `dot_config/git/config.tmpl`
  does. Verified: signing succeeds with only `id_ed25519_signing.pub` present.
- **containers** — DevPod forwards the agent, so they inherit the keys and hold
  no secret of their own.

Loading is lazy. `dot_config/shell/ssh-agent.sh` already hunts for a live agent
on every shell start; it now also asks `ssh-add -l` whether that agent is empty
and, if so, runs the loader. `ssh-add -l` exits 1 for "no identities" and 2 for
"no agent", which is what distinguishes the two cases. Once loaded, every later
shell sees a populated agent and does nothing.

A **personal access token** scoped `viewer` on the Dotfiles vault handles
authentication, so a fresh machine needs no browser. Vault scope rather than
item scope is deliberate: a token granted only individual items cannot resolve
`--vault-name` or `--item-title` at all — it sees no vault listing — which would
force opaque share and item IDs into the repo. The token reaches the loader
through `PROTON_PASS_PERSONAL_ACCESS_TOKEN` and is cached at
`~/.config/pass-cli-bootstrap-pat` (0600) once proven, never passed as
`--personal-access-token` whose value `ps` would expose. It lives in the vault
it unlocks (`bootstrap PAT`), which is circular only in appearance: a fresh
machine reads it from the Proton Pass app, not from the CLI being bootstrapped.

What this trades away is the property the `.age` blobs have: they need no
account, no network and no session. These keys need all three, and the Proton
account now holds both the age passphrase backup and the SSH keys — so a Proton
lockout costs both the break-glass path and day-to-day git. An offline copy is
what closes that, and nothing in this repo can do it for you.

### If a host-only secret ever does come from Proton Pass

chezmoi ships the integration already — 2.70.5 has `protonPass` and
`protonPassJSON`, and both shell out to the `pass-cli` this repo pins, so the
only thing between a working call and a failing one is `pass-cli login`. What
follows is what a spike established about doing that safely; none of it is wired
up, because no secret needs it yet.

An unguarded `protonPass` in a template is a hard failure with no fallback:
chezmoi templates have no try/catch, so a missing session aborts the entire
apply. That kills the container bootstrap (the external is host-only, so
`pass-cli` isn't there at all), CI's clean-HOME run (binary present, session
impossible), and any non-TTY apply on a host whose session has expired. It is
the same failure mode `chezmoi add --encrypt` is banned for.

A gate makes it safe to call. It belongs in `.chezmoitemplates`, rendering
`"true"`/`"false"` like `is-container`:

```
{{- if lookPath "pass-cli" -}}
{{- output "sh" "-c" "pass-cli info >/dev/null 2>&1 && echo true || echo false" | trim -}}
{{- else -}}false{{- end -}}
```

Both halves earn their place. `lookPath` returns `""` rather than failing when
the binary is absent, which is the container case. The `sh -c … && echo true ||
echo false` wrapper is not stylistic: chezmoi's `output` aborts the template on a
non-zero exit, so probing the session with a bare `output "pass-cli" "info"`
would trigger the very failure the gate exists to prevent. Cost is ~11ms
unauthenticated, and whether an authenticated `pass-cli info` reaches the network
was not measured — if it does, the gate can go false while offline, which the
shape below tolerates.

**The gate alone is not enough, and this is the part worth remembering.** Guarding
a *template file* is quietly destructive: gate false renders an empty file, and
chezmoi responds by **removing the target**. Applying once with a session and
again without it deletes the secret from `$HOME` — an expired session or an
offline laptop is enough. The `.age` blobs never behave that way.

So a Proton-sourced secret has to take the same shape the blobs do: a guarded
block in a `run_before` script that writes the file when the session is there and
says so and moves on when it isn't, with the target listed in `.chezmoiignore`.
Absence then leaves an already-written secret untouched, which is the whole
point.

Even with that shape it stays a *host-only* mechanism. A container and CI can
never have a Proton session, so anything a container needs still has to be an
`.age` blob.

## Dev containers

### Arch, not Debian

Two reasons. It matches the host, so package commands and versions are the same
either side of the container boundary. And `debian:trixie` ships no
`libatomic.so.1`, which mise's prebuilt node links against — on Debian
`mise install` failed on node and failed the whole `chezmoi apply` behind it.

The cost is that the image is built from a `Dockerfile` rather than pulled: the
`common-utils` and `git` devcontainer features accept debian, rhel and alpine
only, and exit with `Linux distro arch not supported`. The Dockerfile covers what
those features were actually relied on for — the `dev` user, the sudoers entry,
zsh, generating the `en_US.UTF-8` locale that `dot_zshrc` expects, an `openssh`
client, and a `~/.local/bin` PATH entry. The rest of what `common-utils` bundled
(`bash-completion`, `wget`, `rsync`, an editor, `man-db`, `tree`) is not
reproduced; the mise tool list covers what this setup actually uses.

`openssh` is required, not optional: Arch's git only optdepends on it, DevPod
clones over SSH inside the container, git commit signing shells out to
`ssh-keygen`, and the ssh-agent liveness check needs `ssh` to exist to tell a dead
agent from a missing binary. Without it the dotfiles clone fails with exit 128.

There is deliberately **no compiler**. `base-devel` and `python` used to be
required because `gemini-cli` pulled `node-pty`, whose install script is an
unconditional `node-gyp rebuild` — no prebuilt binary exists for any node
version, so every bootstrap compiled it. Dropping that tool removed the only
thing on the list that builds from source. Add `base-devel` back in a project's
own copy if it needs to build.

mise is installed from Arch's repos rather than as a feature because
`postCreateCommand` runs before DevPod clones the dotfiles — as do
`postStartCommand` and `postAttachCommand` — so the pinned `~/.local/bin/mise`
this repo installs does not exist yet when `post-create.sh` runs `mise install`.
Interactive shells still use the pinned one, because `dot_zshrc` prefers it
explicitly.

### Host-side configuration

`run_onchange_after_30-configure-devpod.sh.tmpl` drives the `devpod` CLI rather
than managing `~/.devpod/config.yaml` directly, because DevPod writes that file
itself — the provider's `initialized` flag and creation timestamp are its own
bookkeeping. A managed copy would be reverted on every apply and show as
permanent drift.

It sets `DOTFILES_SCRIPT=setup` explicitly. Left empty, DevPod guesses — probing
`install.sh`, `install`, `bootstrap.sh`, `bootstrap`, `script/bootstrap` and
`setup.sh` before it reaches `setup`, logging a `Failed to make install script …
not found` line for each miss. Those are all scripts this repo has deliberately
never had, so the six failures reported nothing and only buried the lines that
mattered.

### The GitHub token gap

A cold bootstrap needs a GitHub token. mise resolves a version through the GitHub
API for every `github:`, `vfox:` and `pipx:` tool, and unauthenticated that is 60
requests an hour per IP — less than this repo's tool list, so a cold container
fails partway through with `rate limit exceeded` and takes the whole apply with
it. The host is unaffected because `gh` is authenticated there; a container has
no `gh` session, since `hosts.yml` only decrypts with a TTY.

So `~/.config/devpod/dotfiles-env` holds a **fine-grained** PAT as
`MISE_GITHUB_TOKEN`, and `~/.local/bin/devpod` — a managed wrapper script — hands
that file to `devpod up --dotfiles-script-env-file`. The token carries no
permissions beyond public-repository read, because mise needs it only for the
rate limit — a container that leaks it leaks public-read quota and nothing else.

### Git in a container uses SSH, not a token

The PAT above is scoped to nothing on purpose, which also means it cannot push.
The obvious next step — hand the container the real `gh` token — was built and
then thrown away, because DevPod materialises workspace env as
`/etc/envfile.json` **mode 0644 inside the container**: every process and every
user there could read a token that can push to every repo the account can. A
dependency's postinstall script is enough.

Forwarded SSH avoids the exchange entirely. DevPod turns on
`SSH_AGENT_FORWARDING` by default, and a spike confirmed that a container with
**no token at all** can clone private repos, push (verified with
`git push --dry-run`, which GitHub accepts or rejects on real authorisation),
and sign commits with the host's signing key — the agent socket is all it gets,
so nothing is stored and nothing survives the session.

The one thing missing is that agent forwarding only helps *SSH* remotes, and
project remotes are HTTPS. Inside a container that fails with `could not read
Username for 'https://github.com'`, because the `gh` credential helper has no
authenticated `gh` to ask. `dot_config/git/config.tmpl` therefore rewrites
github HTTPS URLs to SSH **inside containers only** — on the host, HTTPS plus
the helper already works and is what `gh repo clone` produces.

What forwarding does *not* cover is the GitHub API: SSH cannot authenticate it,
so `gh pr create`, `gh api` and the MCP server still need a token. That is what
`~/.config/devpod/project-tokens` is for — `owner/repo=token`, mode 0600, absent
by default, and consulted by the wrapper for the workspace being started. Each
entry should be a fine-grained PAT limited to that one repository. The 0644
exposure still applies to whatever is passed, which is exactly why it is one
repo's worth rather than the whole account's.

Keying is on the **push** remote, not the directory name: a Home Assistant
checkout pushes to your fork, and the fork is what you can mint a token for
without anyone's approval. Org-owned repos are the awkward case — fine-grained
PATs there need the org to permit them and usually an admin to approve each one;
where that is refused, a per-repo deploy key in the host agent gets pushes
working with no token at all.

Two things the forwarding does cost. Every key in the agent is usable from
inside the container while it is connected — the GitHub key, the AUR key and the
signing key — so a container can sign commits as you, though it cannot steal the
keys. And `devpod ssh --command` runs a non-login shell without mise activated,
so `gh` is not on `PATH` there; that is a PATH artefact, not an auth failure.

### Why the wrapper is an executable and not a shell function

It was a `devpod` function in both rc files first, and that version only ever
worked from an interactive shell. `bash -c`, `zsh -c`, scripts, timers and agent
tool calls do not source rc files, so none of them got the token: they fell back
to the anonymous 60/hour quota and failed only on the days it was already spent —
with a `403` from mise that points at GitHub, not at the missing flag. DevPod has
no context option to persist the flag either (v0.6.15 exposes `DOTFILES_URL` and
`DOTFILES_SCRIPT` and nothing else), so the flag has to be added per invocation
by something every caller goes through. That is a file on `PATH`.

The binary therefore moved to `~/.local/libexec/devpod`, off `PATH`, and the
external writes it there; `~/.local/bin/devpod` is the wrapper and `exec`s it.
`~/.local/libexec/dot_keep` exists solely so chezmoi creates that directory — an
external cannot create its own parent, and without it the apply fails with
`stat …/.local/libexec: no such file or directory`. The wrapper is ignored inside
containers and on non-linux-amd64 platforms via the same two templates that gate
the external, so the two cannot drift apart.

The wrapper walks the arguments rather than just checking `$1`, since devpod is a
cobra CLI and global flags are legal before the subcommand (`devpod --debug up .`
is valid). It skips option tokens — including the four value-taking globals
`--context`, `--devpod-home`, `--log-output`, `--provider` — and treats the first
non-option token as the subcommand. A future global flag that takes a separate
value but isn't in that list would be misread as the subcommand and silently skip
the token file. `~/.local/libexec/devpod` runs the binary unwrapped, and a machine
whose age identity is still locked has no token file, so the wrapper passes
straight through and containers bootstrap exactly as they did before.

Two limits worth knowing. The token's expiry is not checked by anything local:
`mise run secrets-restore` only proves the age blob still decrypts, not that the
plaintext PAT is still live. A lapsed PAT looks exactly like the original bug,
with every local check green. And this covers the dotfiles bootstrap only — a
project whose own `mise.toml` pulls `github:`/`vfox:`/`pipx:` tools can still
exhaust the anonymous quota in its `postCreateCommand`, which runs before DevPod
clones the dotfiles and before this token is in scope.

### Quiet bootstraps

The same `up` gets `MISE_QUIET=1`, secret or not. A cold bootstrap otherwise
prints well over a hundred lines of mise install progress through DevPod's
logger; `MISE_QUIET` drops that and keeps the errors — a failing install still
prints `mise ERROR …` and exits non-zero. Deliberately not devpod's own
`--silent`, which suppresses everything short of a panic, including the
`Execution of ./setup was unsuccessful` line that is how a broken bootstrap
announces itself.

`CXXFLAGS=-w` goes along with it. Nothing on the tool list builds from source
today, so this currently silences nothing. It stays because the next tool that
does compile will otherwise dump upstream gcc warnings into every bootstrap, and
`-w` drops warnings only: a real compile error still prints and still fails the
build.

## Co-owned configuration files

Some files under `$HOME` are written by both this repo and by the program that
reads them: DevPod appends a `# DevPod Start <workspace>` … `# DevPod End` block
to `~/.ssh/config` per workspace, and Claude Code writes runtime keys like
`agentPushNotifEnabled` into `~/.claude/settings.json` that this repo has never
heard of. Managing either file the ordinary way — as a static, fully
chezmoi-owned target — means every `chezmoi apply` overwrites whatever the other
writer just wrote, silently reverting it. There are three answers depending on
what the other writer's file supports.

**Own a fragment beside it** when the file supports an include mechanism.
`~/.ssh/config` is deliberately unmanaged; chezmoi owns
`~/.ssh/config.d/10-dotfiles.conf`, and `run_after_12-ensure-ssh-include.sh`
asserts that the real config has an `Include config.d/*.conf` line pointing at it
— prepending one if it's missing or placed below a `Host`/`Match` block — and,
the first time it has to rewrite the file, also migrates away the old three-line
`AddKeysToAgent` block the fragment supersedes. DevPod's blocks live below,
untouched. That script runs on every apply rather than only on `run_onchange`,
because it's re-asserting an invariant about a file chezmoi can't diff: if
something later removed the Include line, a `run_onchange` script would only ever
check once and never notice.

**Merge** when there's no include mechanism and the two sets of keys have to
share one document. `~/.claude/settings.json` has no notion of fragments, so
`dot_claude/modify_settings.json` is a `modify_` script: chezmoi feeds it the
file's current on-disk contents on stdin, and whatever it prints on stdout
becomes the new file. The merge is shallow and managed-wins — `jq -s '.[0] +
.[1]'` with the on-disk contents first — so `enabledPlugins` and
`extraKnownMarketplaces` are replaced wholesale while an unrecognized top-level
key like `agentPushNotifEnabled` passes through untouched.

Being the sole authority over `enabledPlugins` means the baseline is where plugin
state is decided, not `/plugin` — a plugin re-enabled interactively is reverted
by the next apply, so a lasting change is an edit to `modify_settings.json`. The
baseline pins the same way for `skillOverrides` and `permissions.defaultMode`,
which is set to `auto`: routine per-action approvals go to the safety classifier
instead of prompting. That one has to be user-scope — an `auto` default mode in a
project's own settings is ignored as repo-controllable — and it can't lock anyone
out, since an unavailable auto mode falls back to prompting.

**Don't manage it at all** is the third answer. `~/.devpod/config.yaml` is
entirely DevPod's own bookkeeping, so chezmoi doesn't touch it; the
`run_onchange` script drives the CLI instead, and whatever the CLI then writes is
none of chezmoi's business.

`modify_` scripts carry a constraint the other two don't: they run on *every*
apply, not just when their rendered content changes, and CI asserts that a second
`chezmoi apply` produces no managed-file drift. A `modify_` script's output
therefore has to be a fixed point — feeding its own output back in as stdin must
reproduce it byte-for-byte — or the second apply changes the file again and CI
fails. That's what made `modify_settings.json` fiddly: the merge has to stay
stable under jq's own pretty-printing, and it has to behave the same on the
clean-HOME apply where the settings file doesn't exist yet as on the apply right
after, where jq itself isn't installed. A plain `run_after` script re-running is
fine as long as it's idempotent; it never has to reproduce a whole file's bytes.

The screensaver branding is co-owned in the same sense:
`omarchy branding screensaver <image|text|reset>` writes to the exact path
`dot_config/omarchy/branding/` manages, so anything it does is undone by the next
apply. Change the source art in `assets/` and regenerate instead.

## Project checkouts

The `host/owner/repo` layout is more depth than six GitHub repos need, but it's
what stops a third-party clone of the same name — or a second forge — from
colliding later. Depth costs nothing to navigate with zoxide.

`repos-sync` is deliberately **not** part of `chezmoi apply`: a fresh machine
shouldn't be made to pull every repo before it's usable, and a devpod container
has no business holding them.

Clones use **HTTPS**, authenticated by the `gh` credential helper already in
`dot_config/git/config.tmpl`. `gh` itself is configured to prefer SSH for git
operations while this machine has no SSH *auth* key (only the signing key), so
`gh repo clone` would take a path that doesn't work here.

A successful clone is also added to zoxide's database, which is what puts a
brand-new checkout in the `sesh` picker before anyone has ever `cd`'d into it —
zoxide is the only source of directories sesh has.

## Updates

`dotfiles-update-check` **only notifies**; it never pulls and never applies. An
unattended `chezmoi update` would restart services and re-run scripts at an
arbitrary moment, including secret decryption, which now means a YubiKey PIN
prompt with no terminal to answer it. It stays silent when there's nothing to
say, and distinguishes a clean fast-forward from a diverged branch. Enabled by
`run_onchange_after_11-enable-update-check.sh.tmpl`, which skips where no systemd
user session exists — so containers don't get it.
