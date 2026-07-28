# DevPod and devcontainer configuration in chezmoi

Date: 2026-07-28

## Problem

The DevPod CLI binary is already managed (`.chezmoiexternals/devpod.toml`, host-only),
but nothing else about the DevPod setup is. A fresh Omarchy host gets the binary and
then needs three manual steps before `devpod up` works the way it does today:

1. `devpod provider add docker`
2. set the context options `DOTFILES_URL` and `GIT_SSH_SIGNATURE_FORWARDING`
3. set the default IDE to `none`

Separately, every project that gets a devcontainer starts by copy-pasting an existing
`.devcontainer/` from another repo. Today the only real example is `WalkFit`, whose
config is heavily project-specific (D-Bus mount for Web Bluetooth, wrangler port
forwards, a `NODE_OPTIONS` DNS workaround). Copying it means inheriting all of that
and deleting it by hand.

## Scope

In scope:

- reproducing the host-side DevPod configuration on a fresh machine
- a reusable devcontainer starter, scaffolded by a command

Out of scope — this is machine state, not configuration, and is deliberately left
unmanaged:

- `~/.devpod/contexts/*/workspaces/` and `~/.devpod/contexts/*/locks/`
- `~/.devpod/agent/`
- `~/.devpod/contexts/*/providers/docker/provider.json` (DevPod regenerates it from
  the internal provider definition)

## Design

### 1. Host configuration: `.chezmoiscripts/run_onchange_after_30-configure-devpod.sh.tmpl`

DevPod writes `~/.devpod/config.yaml` itself — `initialized: true` and
`creationTimestamp` under the provider entry are set by the CLI, not by hand.
Managing that file directly would put chezmoi and DevPod in a write loop: every
`chezmoi apply` would revert DevPod's own edits, and `chezmoi status` would report
perpetual drift.

So the configuration is expressed as CLI calls instead, leaving DevPod as the sole
writer of its config file:

```sh
devpod provider use docker >/dev/null 2>&1 || devpod provider add docker
devpod ide use none
devpod context set-options \
  -o DOTFILES_URL=git@github.com:ronaldlokers/dotfiles.git \
  -o GIT_SSH_SIGNATURE_FORWARDING=false
```

Notes on the shape:

- `provider use` first, `provider add` as the fallback. `add` defaults to `--use true`,
  so the fallback path also sets the default provider. This avoids parsing
  `provider list --output json`, which would need `jq` — a mise-managed tool whose
  availability at script time is not guaranteed.
- The docker provider is internal to the DevPod binary (`provider list --output json`
  reports `"source": {"internal": true, "raw": "docker"}`), so `provider add` resolves
  it locally rather than fetching a provider spec over the network.
- `DOCKER_PATH=docker` is present in the current config but is the provider default,
  so it is not set explicitly.

Gating and ordering:

- Wrapped in the `is-container` template check, exactly like `.chezmoiexternals/devpod.toml`.
  DevPod belongs on the host that starts containers, not inside one, and inside a
  container the binary is not installed at all.
- Numbered `30`, so it runs after `run_after_20-install-host-packages`. `run_after_`
  scripts run once externals have been applied, so the `devpod` binary exists by then.
- `run_onchange_` rather than plain `run_after_`: a settled rerun costs three
  invocations of an 82 MB static binary — measured at 2.2s — on every single
  apply, and `run_onchange` only pays that cost when the rendered script
  changes. The trade-off: unlike the plain-`run_after` host-packages script,
  this one does not reconverge. `rm -rf ~/.devpod` followed by `chezmoi apply`
  restores nothing, because the rendered script is unchanged; recovery needs
  `chezmoi state delete-bucket` or a no-op edit to the script.

The script runs during CI's clean-HOME bootstrap. The runner is not a container, so
the `is-container` gate is false there and the script executes for real against the
throwaway `HOME`. This is intentional: it is the only automated coverage the script
gets. Because the docker provider is internal, this adds no network dependency to the
bootstrap job.

### 2. Template body: `dot_local/share/devcontainer-template/`

Two plain files, applied to `~/.local/share/devcontainer-template/`:

- `devcontainer.json`
- `post-create.sh`

**These files must not carry a `.tmpl` suffix.** The project name placeholder is not a
chezmoi variable; if chezmoi treated these as templates it would fail to render them.
The placeholder is the literal string `__PROJECT_NAME__`, substituted by the scaffold
script at scaffold time.

`devcontainer.json` is the WalkFit config with every project-specific element removed —
no `runArgs` hostname, no D-Bus `mounts` entry, no `containerEnv`, no `forwardPorts` or
`portsAttributes`:

```jsonc
{
  "name": "__PROJECT_NAME__",
  "image": "debian:trixie",
  "remoteUser": "dev",
  "updateRemoteUserUID": true,
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

`post-create.sh` installs the repo's pinned toolchain and nothing else:

```sh
#!/usr/bin/env bash
set -euo pipefail

mise trust --quiet
mise install --yes
```

The dotfiles themselves are not installed here — DevPod handles that via the
`DOTFILES_URL` context option set in part 1.

### 3. Scaffold: `dot_local/bin/executable_devcontainer-init`

Applied to `~/.local/bin/devcontainer-init`, alongside the existing
`dotfiles-update-check` and `repos-sync`.

Behaviour:

- Project name is `basename "$PWD"`, used verbatim (so `WalkFit` stays `WalkFit`).
- Copies both template files into `./.devcontainer/`, substituting `__PROJECT_NAME__`.
- Refuses with a clear message if `./.devcontainer/` already exists; `--force`
  overwrites both files.
- Errors if `~/.local/share/devcontainer-template/` is missing, pointing at
  `chezmoi apply`.
- Prints each file it wrote.

```
$ cd ~/Repositories/github.com/ronaldlokers/newproj
$ devcontainer-init
wrote .devcontainer/devcontainer.json
wrote .devcontainer/post-create.sh
```

### 4. Documentation

`README.md` gains a short note next to the existing DevPod external section: the host
config is applied by the configure-devpod script, and `devcontainer-init` scaffolds a
project starter.

## Verification

- `mise run lint` (shellcheck over the new script and the scaffold).
- `HOME="$(mktemp -d)" chezmoi apply --source "$PWD" </dev/null`, then a second apply,
  asserting no managed-file drift — the same check CI's bootstrap job runs.
- On the real host, confirm `~/.devpod/config.yaml` still holds `defaultProvider: docker`,
  `defaultIde: none`, and both context options after an apply.
- `devcontainer-init` in a scratch directory: correct name substitution, refusal on
  rerun, overwrite with `--force`.
