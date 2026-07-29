# Arch devcontainer base

Date: 2026-07-29

## Problem

`devpod up` on a project scaffolded by `devcontainer-init` ends with a failed
bootstrap:

```
node: error while loading shared libraries: libatomic.so.1: cannot open shared object file
mise ERROR Failed to install tools: core:node@26.4.0, npm:@google/gemini-cli@0.49.0
chezmoi: .chezmoiscripts/install_packages.sh: exit status 1
Execution of ./setup was unsuccessful: exit status 1
```

The template's base image is `debian:trixie`, which does not ship `libatomic1`
(verified: `docker run --rm debian:trixie ls /usr/lib/x86_64-linux-gnu/libatomic*`
finds nothing). mise's prebuilt glibc node binary links against it, so node fails,
`gemini-cli` is skipped as a dependent, `mise install` exits non-zero, and the
whole `chezmoi apply` — and then `setup` — reports failure. The container is
usable but permanently missing two tools, and every later `chezmoi apply` inside
it fails the same way.

Adding `libatomic1` would fix that one symptom. The deeper mismatch stays: the
host is Arch (Omarchy), the container is Debian, so package commands, versions
and troubleshooting differ between two environments meant to be interchangeable.

## Decisions

**Base becomes `archlinux:base`, built from a Dockerfile.** It carries
`libatomic.so.1` already (verified in the image), so the failure disappears as a
property of the distro rather than as a package bolted on. It also matches the
host: `pacman` in both places, and versions from the same rolling repos.

**The `common-utils` and `git` features go.** Both hard-gate on distro —
`ID`/`ID_LIKE` must be `debian`, `rhel` or `alpine`, otherwise
`Linux distro ${ID} not supported` and `exit 1`. Arch matches none of them.
`common-utils` is what created the `dev` user, the sudoers entry and zsh, so the
Dockerfile takes that over: user and group at 1000, passwordless sudo, zsh as the
login shell.

**mise comes from pacman, not the feature.** Two measured facts force this.

First, *no lifecycle hook runs after the dotfiles arrive*. A throwaway workspace
with markers in all three hooks produced this order:

```
postCreate  → NO-MISE
postStart   → NO-DOTFILES-MISE
postAttach  → NO-DOTFILES-MISE
Cloning dotfiles …
```

DevPod does its dotfiles step last, after the entire devcontainer lifecycle. So
"move the post-create call somewhere later and use the dotfiles' own mise" is not
available — there is no later.

Second, the `devcontainers-extra` mise feature is currently broken, on every
distro. It resolves the latest release of `jdx/mise` and upstream has since
published a non-release tag, so it 404s:

```
no release exists for repo:jdx/mise and tag: vfox-v2026.7.20
ERROR: Feature "Mise" (ghcr.io/devcontainers-extra/features/mise) failed to install!
```

The Zenith bootstrap on 2026-07-28 got v2026.7.15 through the same feature, so
this broke in between — which is the argument against depending on it at all.

Arch's `extra` repo has mise (2026.7.10-1 at time of writing), installed in the
Dockerfile alongside the rest.

A third option was considered and rejected: drop `postCreateCommand` entirely and
have a container-gated chezmoi `run_after` script invoke the project's
`post-create.sh` once, after the global tools are installed. It is genuinely
workable — the workspace is already mounted and the environment carries what a
script needs, verified in a running container:

```
/workspaces/zenith/.devcontainer/post-create.sh
DEVPOD=true
DEVPOD_WORKSPACE_ID=zenith
```

By that point `~/.local/bin/mise` exists, so the pacman package would be
unnecessary. It was rejected for two reasons. It couples the dotfiles to project
layout — they would execute a script out of whatever repo happened to be open,
inverting the dependency direction. And `postCreateCommand` is the hook VS Code
Dev Containers and Codespaces use; dropping it makes the template DevPod-only,
and those environments would get neither mise nor the project's tools. One extra
package in the image is the cheaper trade.

That leaves two mise binaries in the container: pacman's, and the pinned
`~/.local/bin/mise` the dotfiles install via `.chezmoiexternals/mise.toml`.
That is fine and deliberate — `dot_zshrc` prefers `~/.local/bin/mise`
explicitly, so interactive shells get the pinned one, while `post-create.sh`
gets pacman's during the window before the dotfiles exist. The alternative,
pinning the same version in the Dockerfile, would duplicate a version that
Renovate bumps in one place and silently drift.

**The Dockerfile runs `locale-gen`.** Arch base ships only `C`, `C.utf8` and
`POSIX` (verified), while `dot_zshrc` exports `LANG=en_US.UTF-8` — which without
the locale makes every shell print `Cannot set LC_CTYPE to default locale`.
Debian's `common-utils` was generating this silently; on Arch it becomes ours.

**`base-devel` and `python` are installed.** The prototype omitted them on the
theory that mise installs prebuilt binaries, but that theory does not survive
contact with this repo's own tool list: `gemini-cli` pulls in `node-pty`,
which ships no prebuilt binary and compiles through node-gyp at install time.
Without a compiler, `mise install` fails on `gemini-cli` exactly as it failed
on Debian — same script, same exit status — which means the container was
still not fixing the bug it exists to fix. `python` is listed explicitly
rather than left for mise to install alongside `gemini-cli`: node-gyp needs a
python at build time, and relying on mise's own `python` package landing
before `gemini-cli` in the same install batch is an ordering race, not a
guarantee. Verified: `sudo pacman -S base-devel` (with `python` present) in an
otherwise-failing container makes `mise install` exit 0 and `gemini --version`
print `0.49.0`.

**`openssh` is installed.** Arch's `git` package only optdepends on it, so a
bare `git zsh sudo curl ca-certificates which less mise` list leaves `ssh`
missing. That breaks more than DevPod's SSH clone of the dotfiles (which is
how the dotfiles reach the container at all): `dot_config/git/config.tmpl`
sets `gpg.format = ssh` and `commit.gpgsign = true`, so every `git commit`
shells out to `ssh-keygen -Y sign`, and `dot_config/shell/ssh-agent.sh`'s
liveness probe reads a missing binary's exit code (127) as "agent live"
instead of "agent absent" (2).

## Design

`devcontainer-init` writes three files instead of two:

| File | Contents |
| --- | --- |
| `.devcontainer/devcontainer.json` | `build.dockerfile` instead of `image`, `remoteUser: dev`, `updateRemoteUserUID: true`, no features |
| `.devcontainer/Dockerfile` | Arch base, packages, locale, user/sudo/shell |
| `.devcontainer/post-create.sh` | unchanged — `mise trust`, `mise install`, project setup below |

The Dockerfile, in the shape the prototype verified:

```dockerfile
FROM archlinux:base

RUN pacman -Syu --noconfirm --needed \
      git zsh sudo curl ca-certificates which less mise \
      openssh base-devel python \
 && pacman -Scc --noconfirm

# dot_zshrc exports LANG=en_US.UTF-8; Arch ships only C/POSIX, so without this
# every shell in the container complains it cannot set LC_CTYPE.
RUN sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
 && locale-gen

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid "$USER_GID" "$USERNAME" \
 && useradd --uid "$USER_UID" --gid "$USER_GID" -m -s /usr/bin/zsh "$USERNAME" \
 && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$USERNAME" \
 && chmod 0440 /etc/sudoers.d/"$USERNAME"

USER $USERNAME

# common-utils used to put ~/.local/bin on PATH via /etc/*/bashrc and
# /etc/zsh/zshrc; nothing here replaces that otherwise, and on the host it
# comes from omarchy-zsh's shared shell config instead, which a container
# does not have.
ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"
```

## Verified before writing this

Each of these was run, not assumed:

- `debian:trixie` has no `libatomic*`; `archlinux:base` has `libatomic.so.1`.
- `common-utils` and `git` features reject Arch — read from their `install.sh`
  and `main.sh` on `devcontainers/features@main`.
- A prototype image built from the Dockerfile above yields `uid=1000(dev)`,
  login shell `/usr/bin/zsh`, working passwordless sudo, and `libatomic` present.
- In that image, `mise use -g node@26.4.0` then `node -v` prints `v26.4.0` — the
  exact tool that fails on Debian.
- Arch `extra` provides `mise` (2026.7.10-1).
- Arch base locales are `C C.utf8 POSIX` only, and `LANG=en_US.UTF-8` errors
  without `locale-gen`.
- `postCreate`, `postStart` and `postAttach` all run before DevPod's dotfiles
  step — measured with markers in a throwaway workspace, since this decides
  whether the pacman mise is avoidable. It is not.
- The `devcontainers-extra` mise feature fails today with a 404 resolving
  `jdx/mise` `latest`.

Not verified end to end: a full `devpod up` on the Arch template through to a
finished `chezmoi apply`. The throwaway run got as far as the dotfiles clone and
then failed on `git@github.com` SSH auth, because the test shell had no agent
forwarded — an artifact of how it was driven, not of the template. Closing that
gap is the first item under Verification.

## Risks

**User-creation code becomes ours.** `common-utils` is maintained upstream and
handles edge cases (existing UID collisions, `updateRemoteUserUID` interplay).
The Dockerfile handles the straightforward case only. A host user whose UID is
not 1000 is the likely first casualty; `updateRemoteUserUID` is what covers it,
and stays enabled.

**A rolling base drifts.** `archlinux:base` is not pinned to a date, so two
builds a month apart differ. That matches the host's own rolling nature and the
repo's existing choice not to pin host packages, but it does mean a rebuild can
change tool versions underneath a project.

**Existing projects are unaffected until regenerated.** `devcontainer-init`
writes a copy; projects already holding a Debian `.devcontainer/` keep it, and
keep the node failure, until re-scaffolded. That includes the Zenith checkout
this bug surfaced in.

**pacman's mise and the pinned mise coexist.** Documented above as deliberate.
The failure mode to watch is a project whose `mise.toml` needs a feature only in
the newer pinned mise, during the `post-create.sh` window.

## Verification

`mise run check` for the repo itself — the template files are shellchecked and
the JSON validated as part of lint.

Then, end to end, because none of the above builds a container: scaffold a
throwaway project with `devcontainer-init`, run `devpod up`, and confirm the
bootstrap completes with no `mise ERROR` and no failed `setup`. Specifically
`node -v` inside the container must print `v26.4.0` and `gemini-cli` must be
installed — those two are the regression this exists to fix. `locale` must
report `en_US.UTF-8` without warnings, and `id` must show uid 1000.

## Documentation

README's Dev containers section describes a Debian image and three features.
It needs to describe the Arch base, why the features are gone, and the two-mise
arrangement.
