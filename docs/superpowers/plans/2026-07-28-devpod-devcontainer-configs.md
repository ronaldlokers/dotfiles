# DevPod and devcontainer configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reproduce the host-side DevPod configuration on a fresh machine through `chezmoi apply`, and ship a `devcontainer-init` command that scaffolds a project devcontainer from a managed template.

**Architecture:** DevPod's own config file is written by DevPod, so chezmoi drives the DevPod CLI from a `run_onchange` script rather than owning `~/.devpod/config.yaml`. The devcontainer starter lives as two plain files under `~/.local/share/devcontainer-template/`, and a small POSIX shell script copies them into a project with the name substituted.

**Tech Stack:** chezmoi (templates, `run_onchange_after_` scripts, `.chezmoitemplates`), POSIX `sh`, DevPod CLI v0.6.15, shellcheck 0.11.0 via mise.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-28-devpod-devcontainer-configs-design.md`.
- Never commit to `main`. Work happens on branch `feat/devpod-devcontainer-configs`, which already exists and already carries the spec commit.
- Commit subjects use conventional-commit style, lowercase, imperative.
- Never edit chezmoi-managed files in `$HOME` directly — edit the source and run `chezmoi apply`.
- Shell scripts in `.chezmoiscripts/` must stay parseable by shellcheck **with the Go template directives still in the file**. The established pattern is to assign a template result to a shell variable (`is_container={{ includeTemplate "is-container" . }}`) and branch in shell, never to wrap the file in a bare `{{ if }} ... {{ end }}` block. See `.chezmoiscripts/run_after_20-install-host-packages.sh.tmpl:96`.
- `mise run lint` shellchecks an explicit file list. Any new shell file outside `.chezmoiscripts/*.sh.tmpl` must be added to that list in `mise.toml:22`.
- No new runtime dependencies. In particular the scripts must not need `jq` — it is a mise-managed tool and is not guaranteed to be installed at script time.
- The devpod binary is not on `PATH` during `chezmoi apply` in a clean HOME. Address it by absolute path: `$HOME/.local/bin/devpod`.
- This repo comments heavily and explains *why*, not *what*. Match that. Comments explaining a non-obvious constraint are expected, not optional.

## Verification model

This repo has no unit-test framework; its checks are `mise` tasks. The TDD cycle here
is therefore: run the verification command, watch it fail for the stated reason,
implement, watch it pass. The three commands used throughout:

```sh
mise run lint      # shellcheck + JSON + renovate config
mise run verify    # clean-HOME chezmoi apply, non-interactively (</dev/null)
```

and for DevPod work, a throwaway DevPod home so the real `~/.devpod` is never touched:

```sh
DEVPOD_HOME="$(mktemp -d)" ...
```

## File Structure

| File | Responsibility |
| --- | --- |
| Create `.chezmoiscripts/run_onchange_after_30-configure-devpod.sh.tmpl` | Drive the DevPod CLI so the host's provider, IDE and context options match this repo |
| Create `dot_local/share/devcontainer-template/devcontainer.json` | The starter devcontainer definition, with a `__PROJECT_NAME__` placeholder |
| Create `dot_local/share/devcontainer-template/post-create.sh` | Starter post-create hook: install the repo's mise-pinned toolchain |
| Create `dot_local/bin/executable_devcontainer-init` | Copy the template into `./.devcontainer/`, substituting the project name |
| Modify `mise.toml:22` | Add the two new shell files to the shellcheck list |
| Modify `README.md` | Document the DevPod host config and the scaffold command |

---

### Task 1: DevPod host configuration script

**Files:**
- Create: `.chezmoiscripts/run_onchange_after_30-configure-devpod.sh.tmpl`
- Test: no test file — verified by `mise run lint`, `mise run verify`, and a throwaway `DEVPOD_HOME` run

**Interfaces:**
- Consumes: `.chezmoitemplates/is-container` (renders the literal string `true` or `false`); the `devpod` binary installed by `.chezmoiexternals/devpod.toml` at `~/.local/bin/devpod`
- Produces: nothing later tasks depend on

- [ ] **Step 1: Write the failing check**

Confirm the configuration is not reproducible today. In a throwaway DevPod home,
a bare context has no provider and no options:

```sh
DEVPOD_HOME="$(mktemp -d)" ~/.local/bin/devpod context options
```

Expected: `DOTFILES_URL` and `GIT_SSH_SIGNATURE_FORWARDING` show no user-provided
value, and `~/.local/bin/devpod provider list` in that home lists no providers.
This is the state a fresh machine lands in after `chezmoi apply` today.

- [ ] **Step 2: Write the script**

Create `.chezmoiscripts/run_onchange_after_30-configure-devpod.sh.tmpl`:

```sh
#!/bin/sh
# DevPod's host-side configuration: which provider runs containers, which IDE it
# opens, and the context options every workspace inherits. The binary itself is
# an external (.chezmoiexternals/devpod.toml); this is the setup that used to be
# three manual commands after installing it.
#
# Driven through the CLI rather than by managing ~/.devpod/config.yaml as a file.
# DevPod writes that file itself — `initialized: true` and `creationTimestamp`
# under the provider entry are its own bookkeeping — so a managed copy would be
# reverted on every apply and show as permanent drift in `chezmoi status`.
set -eu

# Same container test as the DevPod external and the host-packages script, from
# .chezmoitemplates/is-container so the three can't drift apart. DevPod belongs
# on the host that starts containers; inside one the binary isn't even installed.
is_container={{ includeTemplate "is-container" . }}
if [ "$is_container" = "true" ]; then
    echo "Inside a container, skipping DevPod configuration." >&2
    exit 0
fi

# Not `command -v`: $HOME/.local/bin is on PATH in an interactive shell but not
# during a clean-HOME apply, where this script runs right after the external has
# put the binary there.
devpod="$HOME/.local/bin/devpod"
if [ ! -x "$devpod" ]; then
    echo "No devpod binary at $devpod, skipping DevPod configuration." >&2
    exit 0
fi

# `provider use` fails when the provider was never added, so it doubles as the
# "is it already there?" test. `provider add` defaults to --use, so the fallback
# path also makes docker the default. The alternative — parsing `provider list
# --output json` — would need jq, which isn't guaranteed to exist yet.
# docker is internal to the binary ("source": {"internal": true}), so adding it
# resolves locally and needs no network.
"$devpod" provider use docker >/dev/null 2>&1 || "$devpod" provider add docker

# Terminal-only workflow: DevPod should start the container and stop, not try to
# launch an editor.
"$devpod" ide use none

# Context options, inherited by every workspace:
# - DOTFILES_URL is what makes a fresh container run this very repo's apply. SSH
#   rather than HTTPS because the container has the agent forwarded in.
# - GIT_SSH_SIGNATURE_FORWARDING off: the forwarded agent holds the auth key, and
#   asking it to sign commits inside the container fails rather than falling back.
"$devpod" context set-options \
    -o DOTFILES_URL=git@github.com:ronaldlokers/dotfiles.git \
    -o GIT_SSH_SIGNATURE_FORWARDING=false
```

- [ ] **Step 3: Lint it**

Run: `mise run lint`
Expected: PASS. `.chezmoiscripts/*.sh.tmpl` is already globbed at `mise.toml:22`, so
no change to the lint list is needed for this file. If shellcheck errors on the
`is_container={{ ... }}` line, the template directive was written somewhere that
breaks shell parsing — fix the placement, don't silence the warning.

- [ ] **Step 4: Prove the command sequence produces the live config**

Run the body against a throwaway DevPod home so the real `~/.devpod` is untouched:

```sh
d="$(mktemp -d)"
DEVPOD_HOME="$d" ~/.local/bin/devpod provider use docker >/dev/null 2>&1 \
  || DEVPOD_HOME="$d" ~/.local/bin/devpod provider add docker
DEVPOD_HOME="$d" ~/.local/bin/devpod ide use none
DEVPOD_HOME="$d" ~/.local/bin/devpod context set-options \
  -o DOTFILES_URL=git@github.com:ronaldlokers/dotfiles.git \
  -o GIT_SSH_SIGNATURE_FORWARDING=false
diff <(sed '/creationTimestamp/d' "$d/config.yaml") \
     <(sed '/creationTimestamp/d' ~/.devpod/config.yaml)
rm -rf "$d"
```

Expected: `diff` prints nothing. The generated config matches the live one apart
from the timestamp.

- [ ] **Step 5: Prove it is idempotent and survives a clean-HOME apply**

Run: `mise run verify`
Expected: ends with `clean-HOME apply succeeded, all configured tools present`.
The script runs for real there — the throwaway HOME is not a container, so the
`is_container` gate is false and the external has put a devpod binary in place.

- [ ] **Step 6: Commit**

```bash
git add .chezmoiscripts/run_onchange_after_30-configure-devpod.sh.tmpl
git commit -m "feat: configure the devpod provider, ide and context options on apply"
```

---

### Task 2: Devcontainer starter template

**Files:**
- Create: `dot_local/share/devcontainer-template/devcontainer.json`
- Create: `dot_local/share/devcontainer-template/post-create.sh`
- Modify: `mise.toml:22` (add `post-create.sh` to the shellcheck list)
- Test: no test file — verified by `mise run lint` and `mise run verify`

**Interfaces:**
- Consumes: nothing
- Produces: two files applied to `~/.local/share/devcontainer-template/`, containing
  the literal placeholder `__PROJECT_NAME__` exactly once (in `devcontainer.json`,
  as the value of the `name` key). Task 3 depends on that exact placeholder spelling
  and on that exact directory path.

- [ ] **Step 1: Confirm the template does not exist yet**

Run: `ls ~/.local/share/devcontainer-template`
Expected: FAIL — `No such file or directory`.

- [ ] **Step 2: Write `devcontainer.json`**

Neither file gets a `.tmpl` suffix. `__PROJECT_NAME__` is not a chezmoi variable;
if chezmoi treated these as templates it would have nothing to substitute, and a
`{{ .ProjectName }}` spelling would make `chezmoi apply` fail outright.

Create `dot_local/share/devcontainer-template/devcontainer.json`:

```jsonc
{
  // Scaffolded by `devcontainer-init`, which replaces __PROJECT_NAME__ with the
  // directory name. Starting point only — ports, mounts and extra features are
  // per-project and belong in the copy, not here.
  "name": "__PROJECT_NAME__",
  "image": "debian:trixie",
  "remoteUser": "dev",
  "updateRemoteUserUID": true,
  // The same pattern the upstream base-debian image uses to create its user:
  // common-utils sets up the account, the sudoers entry and zsh, so there are no
  // manual usermod hacks in post-create.
  "features": {
    "ghcr.io/devcontainers/features/common-utils:2": {
      "username": "dev",
      "userUid": "1000",
      "userGid": "1000",
      "installZsh": true,
      "configureZshAsDefaultShell": true,
      "upgradePackages": true
    },
    "ghcr.io/devcontainers/features/git:1": { "version": "os-provided" },
    "ghcr.io/devcontainers-extra/features/mise:1": {}
  },
  "postCreateCommand": "bash .devcontainer/post-create.sh"
}
```

Note the dotfiles are deliberately absent here: DevPod clones and applies them
itself via the `DOTFILES_URL` context option set in Task 1.

- [ ] **Step 3: Write `post-create.sh`**

Create `dot_local/share/devcontainer-template/post-create.sh`:

```sh
#!/usr/bin/env bash
set -euo pipefail

# Everything the project pins lives in its own mise.toml — same source of truth
# as host-side work, so the container can't drift from it. Trust first, otherwise
# the install prompts and there is no TTY to answer on.
mise trust --quiet
mise install --yes

# Project-specific setup goes below: dependency installs, browser downloads,
# whatever the repo needs. Keep it idempotent — post-create runs again whenever
# the container is rebuilt.
```

The file gets no `executable_` prefix. It is invoked as `bash .devcontainer/post-create.sh`,
so the mode does not matter, and a non-executable file is the honest signal that
it is not meant to be run directly.

- [ ] **Step 4: Add it to the lint list**

Modify `mise.toml:22`, appending the new path to the shellcheck arguments:

```toml
	"shellcheck --severity=warning setup .chezmoiscripts/*.sh.tmpl dot_claude/executable_statusline.sh dot_config/shell/ssh-agent.sh dot_local/share/devcontainer-template/post-create.sh",
```

`devcontainer.json` is deliberately not passed to `jq empty`: it is JSONC, comments
and all, which is legal for devcontainer definitions and matches how the rest of
this repo documents itself.

- [ ] **Step 5: Lint**

Run: `mise run lint`
Expected: PASS, with `post-create.sh` now in the shellcheck argument list.

- [ ] **Step 6: Verify it applies**

Run: `mise run verify`
Expected: PASS. Then confirm the files land where Task 3 expects them:

```sh
chezmoi apply
cat ~/.local/share/devcontainer-template/devcontainer.json | grep __PROJECT_NAME__
```

Expected: one matching line, `  "name": "__PROJECT_NAME__",`.

- [ ] **Step 7: Commit**

```bash
git add dot_local/share/devcontainer-template mise.toml
git commit -m "feat: add a devcontainer starter template"
```

---

### Task 3: `devcontainer-init` scaffold command

**Files:**
- Create: `dot_local/bin/executable_devcontainer-init`
- Modify: `mise.toml:22` (add the script to the shellcheck list)
- Test: no test file — verified by `mise run lint` and a scratch-directory run

**Interfaces:**
- Consumes: `~/.local/share/devcontainer-template/{devcontainer.json,post-create.sh}`
  from Task 2, and the literal placeholder `__PROJECT_NAME__`
- Produces: the command `devcontainer-init [--force]` on `PATH`

- [ ] **Step 1: Confirm the command does not exist**

Run: `command -v devcontainer-init`
Expected: FAIL, no output, non-zero exit.

- [ ] **Step 2: Write the script**

Create `dot_local/bin/executable_devcontainer-init`. Sits next to `repos-sync` and
`dotfiles-update-check`, which are the other things in `dot_local/bin`.

```sh
#!/usr/bin/env bash
set -euo pipefail

# Scaffold a project devcontainer from the managed starter in
# ~/.local/share/devcontainer-template. Exists because the alternative is copying
# .devcontainer/ out of whichever project last had one and deleting its
# project-specific parts by hand — which is how the template drifts.

template="${XDG_DATA_HOME:-$HOME/.local/share}/devcontainer-template"
target=".devcontainer"
force=false

usage() {
	cat >&2 <<'EOF'
usage: devcontainer-init [--force]

Writes .devcontainer/{devcontainer.json,post-create.sh} into the current
directory, naming the container after the directory.

  --force   overwrite an existing .devcontainer/
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--force) force=true ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "unknown argument: $1" >&2
		usage
		exit 2
		;;
	esac
	shift
done

if [ ! -d "$template" ]; then
	echo "no template at $template — run 'chezmoi apply' first" >&2
	exit 1
fi

if [ -e "$target" ] && [ "$force" = false ]; then
	echo "$target already exists; pass --force to overwrite" >&2
	exit 1
fi

# The directory name, verbatim. Casing is left alone: a project called WalkFit
# should show up as WalkFit in `devpod list`, not walkfit.
name="$(basename "$PWD")"

mkdir -p "$target"
# The placeholder is substituted only in devcontainer.json; post-create.sh is
# copied as-is. A plain cp for the latter keeps it obvious that nothing is
# rewritten there.
sed "s/__PROJECT_NAME__/$name/" "$template/devcontainer.json" >"$target/devcontainer.json"
cp "$template/post-create.sh" "$target/post-create.sh"

echo "wrote $target/devcontainer.json"
echo "wrote $target/post-create.sh"
```

- [ ] **Step 3: Add it to the lint list**

Modify `mise.toml:22` again, appending the scaffold script:

```toml
	"shellcheck --severity=warning setup .chezmoiscripts/*.sh.tmpl dot_claude/executable_statusline.sh dot_config/shell/ssh-agent.sh dot_local/share/devcontainer-template/post-create.sh dot_local/bin/executable_devcontainer-init",
```

- [ ] **Step 4: Lint**

Run: `mise run lint`
Expected: PASS.

- [ ] **Step 5: Apply and exercise every path in a scratch directory**

```sh
chezmoi apply
scratch="$(mktemp -d)/SomeProject"
mkdir -p "$scratch"
cd "$scratch"

devcontainer-init
grep '"name"' .devcontainer/devcontainer.json

devcontainer-init
devcontainer-init --force
```

Expected, in order:
1. `wrote .devcontainer/devcontainer.json` and `wrote .devcontainer/post-create.sh`
2. `  "name": "SomeProject",` — the directory name, casing preserved, no leftover placeholder
3. `.devcontainer already exists; pass --force to overwrite`, exit 1
4. both `wrote ...` lines again, exit 0

Clean up the scratch directory afterwards.

- [ ] **Step 6: Commit**

```bash
git add dot_local/bin/executable_devcontainer-init mise.toml
git commit -m "feat: add devcontainer-init to scaffold a project devcontainer"
```

---

### Task 4: Documentation

**Files:**
- Modify: `README.md` — the externals bullet near line 19, and a new section after `## Project checkouts`

**Interfaces:**
- Consumes: everything from Tasks 1-3
- Produces: nothing

- [ ] **Step 1: Extend the externals bullet**

The bullet at `README.md:19-20` currently ends at the host-only external. Note that
the configuration now comes with it. Replace:

```
The [DevPod](https://devpod.sh) CLI external is host-only — it renders to
nothing inside a container, so devpod-provisioned boxes skip it
```

with:

```
The [DevPod](https://devpod.sh) CLI external is host-only — it renders to
nothing inside a container, so devpod-provisioned boxes skip it. Its
configuration follows, from
`.chezmoiscripts/run_onchange_after_30-configure-devpod.sh.tmpl` — see
[Dev containers](#dev-containers)
```

- [ ] **Step 2: Add the section**

Insert after the `## Project checkouts` section and before `## Working on this repo`:

````markdown
## Dev containers

Project work happens in [DevPod](https://devpod.sh) containers, driven by the
docker provider. The host side of that is configured by
`run_onchange_after_30-configure-devpod.sh.tmpl`: it adds and selects the docker
provider, sets the default IDE to `none` (the workflow is a terminal, not an
editor launch), and sets two context options every workspace inherits —
`DOTFILES_URL`, which is what makes a fresh container apply this repo, and
`GIT_SSH_SIGNATURE_FORWARDING=false`.

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

It writes `devcontainer.json` and `post-create.sh`, naming the container after
the directory. The starter is deliberately thin — `debian:trixie`, a `dev` user
with zsh, git, mise, and a post-create hook that runs `mise install` — because
ports, mounts and extra features differ per project and belong in the copy. Edit
the starter at `dot_local/share/devcontainer-template/`.

Nothing installs the dotfiles from inside the container: DevPod clones and
applies them itself, via the `DOTFILES_URL` option above.
````

- [ ] **Step 3: Check the rendered result**

Run: `grep -n "Dev containers" README.md`
Expected: two matches — the anchor reference in the externals bullet and the
heading itself.

- [ ] **Step 4: Full check**

Run: `mise run check`
Expected: PASS — lint, gitleaks and the clean-HOME bootstrap.

- [ ] **Step 5: Commit and open the PR**

```bash
git add README.md
git commit -m "docs: describe the devpod host config and devcontainer-init"
git push -u origin feat/devpod-devcontainer-configs
gh pr create --fill
```
