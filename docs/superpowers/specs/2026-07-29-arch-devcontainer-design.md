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

**mise comes from pacman, not the feature.** Ordering forces this:
`postCreateCommand` runs *before* DevPod clones the dotfiles, and
`post-create.sh` calls `mise trust`/`mise install` for the project's own
`mise.toml` — so mise has to exist before `chezmoi apply` ever runs. Arch's
`extra` repo has it (2026.7.10 at time of writing).

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

**`base-devel` is not installed.** The prototype included it, but nothing in the
verified path needs a compiler: mise installs prebuilt binaries. Projects that
need to build add it in their own copy of the Dockerfile — the template is a
starting point, not a shared base image.

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
