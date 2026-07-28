# Arch Devcontainer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the devcontainer template from `debian:trixie` to an Arch base built from a Dockerfile, so `node` stops failing on a missing `libatomic.so.1` and the container matches the Omarchy host.

**Architecture:** The template gains a `Dockerfile` and loses two devcontainer features. `common-utils` and `git` reject Arch outright, so the Dockerfile takes over what they did: packages, locale, and a `dev` user at UID/GID 1000 with passwordless sudo and zsh. mise is installed from Arch's `extra` repo because `postCreateCommand` runs before DevPod's dotfiles step, so the dotfiles' own pinned mise does not exist yet. `devcontainer-init` copies the third file.

**Tech Stack:** chezmoi, DevPod, docker, devcontainer spec, Arch Linux, mise, bash.

Spec: `docs/superpowers/specs/2026-07-29-arch-devcontainer-design.md`

## Global Constraints

- Branch is `feat/arch-devcontainer`. Never commit to `main`. Conventional-commit subjects, lowercase imperative.
- **Never** edit a chezmoi-managed file in `$HOME` as a source of truth. Edit the source tree under `/home/ronald/.local/share/chezmoi`, then `chezmoi apply`.
- The template lives at `dot_local/share/devcontainer-template/`. It is a *starting point copied per project*, not a shared base image — per-project needs belong in the project's copy.
- `dot_local/bin/executable_devcontainer-init` is shellchecked by `mise run lint`; keep it clean. It uses tab indentation.
- Comment style explains *why*, not *what*, wrapped near 80 columns.
- The container user is `dev`, UID 1000, GID 1000, login shell `/usr/bin/zsh`, passwordless sudo. `remoteUser: dev` and `updateRemoteUserUID: true` stay.
- `base-devel` is deliberately NOT installed — nothing on the verified path needs a compiler.
- `mise run check` must pass before the PR.

## Established facts

Measured while writing the spec. Do not re-derive; do not design around contradicting them.

1. `debian:trixie` has no `libatomic*`; `archlinux:base` ships `/usr/lib/libatomic.so.1`.
2. The `common-utils` and `git` features exit 1 with `Linux distro ${ID} not supported` unless `ID`/`ID_LIKE` is debian, rhel or alpine.
3. A prototype of the exact Dockerfile below produced `uid=1000(dev)`, login shell `/usr/bin/zsh`, working passwordless sudo, and `mise use -g node@26.4.0 && node -v` printing `v26.4.0` — the tool that fails on Debian.
4. Arch base has only `C C.utf8 POSIX` locales. `dot_zshrc` exports `LANG=en_US.UTF-8`, which without `locale-gen` makes every shell print `Cannot set LC_CTYPE to default locale`.
5. `postCreate`, `postStart` and `postAttach` all run **before** DevPod clones the dotfiles — measured with markers. There is no later hook to move `post-create.sh` into.
6. The `devcontainers-extra` mise feature is broken upstream: it resolves `jdx/mise` latest and 404s on a `vfox-*` tag. That is why mise comes from pacman rather than the feature.
7. In a running DevPod container the workspace is at `/workspaces/$DEVPOD_WORKSPACE_ID` and the env carries `DEVPOD=true`.

## File Structure

**Created:**
- `dot_local/share/devcontainer-template/Dockerfile` — the Arch base, packages, locale and user setup.

**Modified:**
- `dot_local/share/devcontainer-template/devcontainer.json` — `build.dockerfile` replaces `image`; features removed.
- `dot_local/bin/executable_devcontainer-init` — validate and copy the third file.
- `README.md` — the Dev containers section describes a Debian image and three features.

**Unchanged:**
- `dot_local/share/devcontainer-template/post-create.sh` — still `mise trust` / `mise install`, still invoked by `postCreateCommand`.

---

### Task 1: The Dockerfile and devcontainer.json

**Files:**
- Create: `dot_local/share/devcontainer-template/Dockerfile`
- Modify: `dot_local/share/devcontainer-template/devcontainer.json`

**Interfaces:**
- Consumes: nothing.
- Produces: a template directory holding three files. Task 2 teaches `devcontainer-init` to copy all three.

- [ ] **Step 1: Write the Dockerfile**

Create `dot_local/share/devcontainer-template/Dockerfile`:

```dockerfile
# Arch, matching the Omarchy host: same package manager, same rolling
# versions, and the same troubleshooting either side of the container
# boundary. It also carries libatomic.so.1, which debian:trixie does not —
# mise's prebuilt node links against it, so on Debian `mise install` failed
# and took gemini-cli and the whole chezmoi apply down with it.
FROM archlinux:base

# mise is here rather than as a devcontainer feature for two reasons. The
# feature (devcontainers-extra) resolves jdx/mise's latest release and
# currently 404s on a non-release tag upstream. And postCreateCommand runs
# before DevPod clones the dotfiles, so the pinned ~/.local/bin/mise this
# repo installs does not exist yet when post-create.sh needs it. Interactive
# shells still get the pinned one: dot_zshrc prefers it explicitly.
#
# base-devel is deliberately absent — mise installs prebuilt binaries, and a
# project that needs a compiler adds it to its own copy of this file.
RUN pacman -Syu --noconfirm --needed \
      git zsh sudo curl ca-certificates which less mise \
 && pacman -Scc --noconfirm

# dot_zshrc exports LANG=en_US.UTF-8. Arch ships only C/C.utf8/POSIX, so
# without this every shell in the container prints "Cannot set LC_CTYPE to
# default locale". Debian's common-utils feature was doing this silently;
# on Arch it is ours to do.
RUN sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
 && locale-gen

# What the common-utils feature used to set up. It refuses to run on Arch
# (it accepts debian, rhel and alpine only), so the user, the sudoers entry
# and the login shell are created here instead. UID/GID 1000 matches the
# usual host user; devcontainer.json's updateRemoteUserUID fixes up the
# case where the host user is not 1000.
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid "$USER_GID" "$USERNAME" \
 && useradd --uid "$USER_UID" --gid "$USER_GID" -m -s /usr/bin/zsh "$USERNAME" \
 && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$USERNAME" \
 && chmod 0440 /etc/sudoers.d/"$USERNAME"

USER $USERNAME
```

- [ ] **Step 2: Rewrite devcontainer.json**

The file currently pins `"image": "debian:trixie"` and three features. Replace its contents with:

```jsonc
{
  // Scaffolded by `devcontainer-init`, which replaces the placeholder name
  // below with the directory name. Starting point only — ports, mounts and
  // extra features are per-project and belong in the copy, not here.
  "name": "__PROJECT_NAME__",
  // Built from the Dockerfile beside this file rather than pulled as an
  // image: the user, sudo, zsh and locale setup that devcontainer features
  // used to provide has to happen somewhere, and those features refuse to
  // run on Arch.
  "build": { "dockerfile": "Dockerfile" },
  "remoteUser": "dev",
  // Keeps the container user's UID in step with the host's, so files
  // written in the workspace are not owned by the wrong id.
  "updateRemoteUserUID": true,
  "postCreateCommand": "bash .devcontainer/post-create.sh"
}
```

Note what is gone: the whole `features` block. `common-utils` and `git` reject Arch, and mise now comes from the Dockerfile.

- [ ] **Step 3: Build the image directly, before involving DevPod**

A `devpod up` failure could come from any of a dozen places; a plain `docker build` isolates this task's output.

```bash
cd dot_local/share/devcontainer-template && docker build -t archdc-plan-test . && cd -
```

Expected: builds successfully.

- [ ] **Step 4: Verify the four things the features used to guarantee**

```bash
docker run --rm archdc-plan-test bash -lc '
  id
  echo "shell: $(getent passwd dev | cut -d: -f7)"
  sudo -n true && echo "sudo: ok"
  ls /usr/lib/libatomic.so.1
  locale -a | grep -i en_US
  command -v mise
'
```

Expected: `uid=1000(dev) gid=1000(dev)`, shell `/usr/bin/zsh`, `sudo: ok`, the libatomic path, an `en_US.utf8` line, and a mise path.

If `locale -a` shows no `en_US`, the `sed` did not match — check the exact comment form in `/etc/locale.gen` for the current Arch base rather than assuming.

- [ ] **Step 5: Verify the regression this whole change exists to fix**

```bash
docker run --rm archdc-plan-test bash -lc 'export MISE_YES=1; mise use -g node@26.4.0 >/dev/null 2>&1; mise exec node@26.4.0 -- node -v'
```

Expected: `v26.4.0`. This is the exact install that fails on `debian:trixie` with `libatomic.so.1: cannot open shared object file`.

- [ ] **Step 6: Clean up the test image**

```bash
docker rmi archdc-plan-test
```

- [ ] **Step 7: Commit**

```bash
git add dot_local/share/devcontainer-template/
git commit -m "feat: build the devcontainer template on an arch base"
```

---

### Task 2: Teach devcontainer-init about the Dockerfile

**Files:**
- Modify: `dot_local/bin/executable_devcontainer-init`

**Interfaces:**
- Consumes: the three-file template from Task 1.
- Produces: `devcontainer-init` writing `devcontainer.json`, `post-create.sh` and `Dockerfile` into `.devcontainer/`.

The script builds the new directory in a staging dir and renames it into place as one atomic move. Three places name the files individually and all three need the Dockerfile: the completeness check, the copy, and the closing output.

- [ ] **Step 1: Extend the completeness check**

The script refuses to write anything unless the template is whole. It currently reads:

```bash
if [ ! -s "$template/devcontainer.json" ] || [ ! -s "$template/post-create.sh" ]; then
	echo "incomplete template at $template — expected devcontainer.json and post-create.sh" >&2
	exit 1
fi
```

Change it to require the Dockerfile too, and say so in the message:

```bash
if [ ! -s "$template/devcontainer.json" ] || [ ! -s "$template/post-create.sh" ] ||
	[ ! -s "$template/Dockerfile" ]; then
	echo "incomplete template at $template — expected devcontainer.json, post-create.sh and Dockerfile" >&2
	exit 1
fi
```

Keep the file's tab indentation.

- [ ] **Step 2: Copy the Dockerfile**

Below the existing `cp` of post-create.sh:

```bash
# post-create.sh is copied as-is; nothing is rewritten there.
cp "$template/post-create.sh" "$staging/post-create.sh"
```

add:

```bash
# The Dockerfile likewise: the image is built per project from this copy, so
# a project that needs an extra package edits its own rather than the
# template.
cp "$template/Dockerfile" "$staging/Dockerfile"
```

- [ ] **Step 3: Report the third file**

The script ends with two `echo` lines. Add the third so the output matches what was written:

```bash
echo "wrote $target/devcontainer.json"
echo "wrote $target/post-create.sh"
echo "wrote $target/Dockerfile"
```

- [ ] **Step 4: Lint**

Run: `mise run lint`
Expected: exit 0. This shellchecks `devcontainer-init`.

- [ ] **Step 5: Verify the incomplete-template guard fires — BEFORE applying**

A guard that never trips is not a guard, and right now you have the ideal fixture for free: Task 1 committed the Dockerfile to the source tree, but until `chezmoi apply` runs, the *applied* template at `~/.local/share/devcontainer-template/` still has only two files. So run the new script against it now.

Run the **edited source file**, not `$HOME/.local/bin/devcontainer-init` — the applied copy is still the pre-change script and has no new guard to test:

```bash
ls -1 ~/.local/share/devcontainer-template/
d=$(mktemp -d) && (cd "$d" && bash "$OLDPWD/dot_local/bin/executable_devcontainer-init"; echo "exit=$?") ; rm -rf "$d"
```

Expected: the listing shows only `devcontainer.json` and `post-create.sh`, and the run prints `incomplete template … expected devcontainer.json, post-create.sh and Dockerfile` with a non-zero exit.

If the applied template already has three files, a `chezmoi apply` happened earlier in this task — skip to Step 6 and note in your report that the guard went unverified rather than faking the result.

- [ ] **Step 6: Apply, then scaffold into a throwaway directory**

```bash
chezmoi apply
d=$(mktemp -d) && (cd "$d" && devcontainer-init && ls -1 .devcontainer/ && grep -c '"build"' .devcontainer/devcontainer.json && grep -c FROM .devcontainer/Dockerfile) && rm -rf "$d"
```

Expected: three `wrote …` lines, the three filenames listed, and `1` from each grep.

- [ ] **Step 7: Commit**

```bash
git add dot_local/bin/executable_devcontainer-init
git commit -m "feat: scaffold the devcontainer dockerfile alongside the rest"
```

---

### Task 3: Documentation and full verification

**Files:**
- Modify: `README.md` — the Dev containers section.

**Interfaces:**
- Consumes: everything above.
- Produces: a branch ready for review.

- [ ] **Step 1: Update the starter description**

In README's Dev containers section, this paragraph is now wrong in three ways — the image, the feature list, and the file count:

```markdown
It writes `devcontainer.json` and `post-create.sh`, naming the container after
the directory. The starter is deliberately thin — `debian:trixie`, a `dev` user
with zsh, git, mise, and a post-create hook that runs `mise install` — because
ports, mounts and extra features differ per project and belong in the copy. Edit
the starter at `dot_local/share/devcontainer-template/`.
```

Replace it with:

```markdown
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
only, and exit with `Linux distro arch not supported`. What they used to do —
the `dev` user, the sudoers entry, zsh, and generating the `en_US.UTF-8` locale
that `dot_zshrc` expects — the Dockerfile now does.

mise is installed from Arch's repos rather than as a feature. `postCreateCommand`
runs before DevPod clones the dotfiles — as do `postStartCommand` and
`postAttachCommand` — so the pinned `~/.local/bin/mise` this repo installs does
not exist yet when `post-create.sh` runs `mise install`. Interactive shells still
use the pinned one, because `dot_zshrc` prefers it explicitly.
```

- [ ] **Step 2: Check no stale Debian reference survives in the template**

What must not survive is anything that still *configures* Debian. Explanatory prose naming it is fine and expected — the Dockerfile's own comments say why Debian was rejected, and so does the README.

Run: `grep -rnE '"image".*debian|^FROM debian' dot_local/share/devcontainer-template/ dot_local/bin/executable_devcontainer-init README.md`
Expected: no output.

Then read the remaining mentions and confirm each is explanation rather than configuration:

Run: `grep -rn "trixie\|debian" dot_local/share/devcontainer-template/ dot_local/bin/executable_devcontainer-init`
Expected: only comment lines in `Dockerfile` explaining the `libatomic` gap and the features refusing to run on Arch. Anything outside a comment is a finding.

- [ ] **Step 3: Run the full check**

Run: `mise run check`
Expected: exit 0.

If the clean-HOME bootstrap fails with `Disk quota exceeded`, that is `/tmp` being a tmpfs with no room, not this change — re-run as `TMPDIR=/var/tmp mise run check` and say so in your report.

- [ ] **Step 4: Confirm the diff's scope**

Run: `git diff main --stat`
Expected: only the four files this plan names, plus the spec and this plan.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: describe the arch devcontainer starter"
```

Stop here. The end-to-end `devpod up` in Task 4 needs a real terminal, and the push and PR happen after a whole-branch review.

---

### Task 4: End-to-end check (human-run)

This task cannot be completed by an agent and must not be marked done by one. `devpod up` clones the dotfiles over SSH, which needs a forwarded agent that a non-interactive tool session does not have — an earlier attempt died exactly there, at `git@github.com` auth.

**Hand these steps to the human partner.**

- [ ] **Step 1: Scaffold a throwaway project**

```bash
mkdir -p /var/tmp/archdc-check && cd /var/tmp/archdc-check && git init -q . && devcontainer-init
```

- [ ] **Step 2: Bring it up**

```bash
devpod up . --id archdc-check --ide none
```

Expected: the build completes, the dotfiles clone and apply, and the run ends without `mise ERROR`, without `Execution of ./setup was unsuccessful`, and without `libatomic`.

- [ ] **Step 3: Check inside the container**

```bash
devpod ssh archdc-check --command 'node -v; command -v gemini; id; locale | head -2; echo $LANG'
```

Expected: `v26.4.0`; a gemini path; `uid=1000(dev)`; no `Cannot set LC_CTYPE` warnings; `LANG=en_US.UTF-8`.

`node` and `gemini-cli` are the two tools that fail on Debian — they are the regression being closed, so both must be present.

- [ ] **Step 4: Tear down**

```bash
devpod delete archdc-check --force && rm -rf /var/tmp/archdc-check
```

- [ ] **Step 5: Re-scaffold Zenith, which still holds a Debian .devcontainer**

The project this bug surfaced in keeps failing until its copy is regenerated:

```bash
cd ~/Projects/github.com/ronaldlokers/Zenith && devcontainer-init --force
```

Then rebuild it: `devpod up . --recreate`. Commit the regenerated `.devcontainer/` in that repo — it is project-local, not part of the dotfiles.
