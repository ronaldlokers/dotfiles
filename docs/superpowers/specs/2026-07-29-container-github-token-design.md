# A GitHub token for container bootstraps

Date: 2026-07-29

## Problem

A cold `devpod up` fails partway through the dotfiles bootstrap:

```
mise WARN  GitHub rate limit exceeded. Resets at 2026-07-29 00:38:21 +00:00
github auth: no
github rate limit: 0/60 (core)
mise ERROR Failed to install tools: github:joshmedeski/sesh@2.28.0,
  github:ronaldlokers/sugarrush@2026.7.3,
  pipx:git+https://github.com/mischavandenburg/pomo.git@v0.4.0,
  vfox:mise-plugins/vfox-neovim@0.12.4
chezmoi: .chezmoiscripts/install_packages.sh: exit status 1
Execution of ./setup was unsuccessful: exit status 1
```

mise queries the GitHub API to resolve a version for every tool on a
`github:`, `vfox:` or `pipx:` backend. Unauthenticated, that is 60 requests
per hour per IP, and this repo's tool list does not fit — a single cold
bootstrap can exhaust it, and any other machine or container sharing the
egress IP spends from the same budget.

The host escapes this: `gh` is authenticated there, and mise finds a token
through it. A container has no `gh` session — `~/.config/gh/hosts.yml` is an
age blob that only decrypts with a TTY, which a `devpod up` does not have.
So the container is the one place with no token and the largest appetite for
API calls.

This is not new to the Arch template. The Debian one had the identical
exposure and simply had not hit it yet.

## Decisions

**A dedicated PAT with no scopes.** mise needs a token only to lift the
anonymous rate limit; its own documentation says no scopes are required. The
alternative — reusing what `gh` holds — costs nothing to set up but hands
every container, and everything running inside one, a credential carrying
`repo` and `workflow`. `dot_config/shell/github-token.sh` already flags that
blast radius as a deliberate trade for the MCP server on the host; extending
it to containers is a bigger trade than this problem warrants. A leaked
no-scope PAT costs an attacker nothing but public-read quota.

**Delivered as `MISE_GITHUB_TOKEN`, not `GITHUB_TOKEN`.** The narrower name
reaches mise and nothing else, so a container does not quietly acquire a
general-purpose GitHub credential that other tooling might pick up.
`mise.toml`'s `verify` task already uses this variable for the same reason.

**Passed with `--dotfiles-script-env-file`.** DevPod provides flags for
exactly this — `--dotfiles-script-env` and `--dotfiles-script-env-file` put
environment variables into the dotfiles install script, which is the step
that fails. The file form keeps the token out of shell history and out of
`ps` output. The existence of these flags is also the answer to whether
`devcontainer.json`'s `remoteEnv` would do: it would not, or DevPod would
not need them.

**Stored the way every other secret here is.** An age blob in the source
tree, its literal target path in `.chezmoiignore`, decrypted by
`run_before_00-unlock-secrets.sh.tmpl` through the existing `decrypt_to`
helper, mode 600. Nothing new to learn and nothing new to rotate by hand.

**Applied by a shell function wrapping `devpod`.** None of DevPod's context
options persist an env file, so the flag has to be supplied per invocation.
A `devpod()` function in both rc files adds it for the `up` subcommand only
and passes everything else through. The alternative — a separate
`devpod-up` script — cannot be forgotten only if you remember to use it,
which reproduces this bug silently.

## Design

### The secret

| Piece | Value |
| --- | --- |
| Source blob | `dot_config/private_devpod/private_dotfiles-env.age` |
| Target | `~/.config/devpod/dotfiles-env`, mode 600 |
| `.chezmoiignore` entry | `.config/devpod/dotfiles-env.age` |
| Contents | one line: `MISE_GITHUB_TOKEN=<pat>` |

Creating the PAT is a human step and cannot be automated from here: generate
it at <https://github.com/settings/tokens> with **no scopes ticked**, then
produce the blob with the repo's documented command rather than
`chezmoi add --encrypt`, which would break non-interactive apply:

```sh
printf 'MISE_GITHUB_TOKEN=%s\n' "$pat" > /tmp/dotfiles-env
chezmoi encrypt --output dot_config/private_devpod/private_dotfiles-env.age /tmp/dotfiles-env
shred -u /tmp/dotfiles-env
```

The decrypt block mirrors the `gh` one exactly — same `secret_current`
guard, same `mkdir -p` plus `chmod 700` on the directory, same `decrypt_to`
call with a `sha256sum` of the blob as the freshness hash:

```sh
devpod_env="$HOME/.config/devpod/dotfiles-env"
devpod_env_hash='{{ include "dot_config/private_devpod/private_dotfiles-env.age" | sha256sum }}'
if ! secret_current "$devpod_env" "$devpod_env_hash"; then
    mkdir -p "$HOME/.config/devpod"
    chmod 700 "$HOME/.config/devpod"
    decrypt_to "$devpod_env" '{{"{{"}} decrypt (include "dot_config/private_devpod/private_dotfiles-env.age") {{"}}"}}' "$devpod_env_hash"
fi
```

Note the `{{"{{"}}` escaping in the `decrypt_to` argument. That script is
itself a chezmoi template, and the decrypt expression must survive rendering
to be evaluated later — the existing blocks all do this, and writing the
plain `{{ decrypt … }}` form instead produces a file that decrypts nothing.

`~/.config/devpod/` is co-owned: DevPod writes its own `config.yaml` there.
This adds a file to that directory rather than managing the directory, so
the two do not collide.

### Delivery

A function in `dot_zshrc` and `dot_bashrc`, kept in step by hand like the
rest of that pair:

```sh
devpod() {
  if [ "$1" = "up" ] && [ -r "$HOME/.config/devpod/dotfiles-env" ]; then
    command devpod "$@" --dotfiles-script-env-file "$HOME/.config/devpod/dotfiles-env"
  else
    command devpod "$@"
  fi
}
```

Both halves of the guard matter. The subcommand test keeps the flag off
`devpod ssh`, `devpod list` and everything else that would reject it. The
readability test is what makes a machine without the secret behave exactly
as it does today rather than failing on a missing file.

### Degradation

No age identity means no decrypted file, which means the function is a
pass-through and containers bootstrap exactly as they do now — hitting the
cap when the quota is short, succeeding when it is not. That matches how
every other secret-dependent feature here behaves: absent key, feature
quietly off, no new failure mode.

## Risks

**The token is readable inside the container.** Anything running there —
including coding agents — can read the environment. That is the reason for
insisting on zero scopes; the credential is worth nothing beyond quota.

**The dotfiles now shadow a binary.** `devpod` resolves to a function, which
is a surprise when debugging something DevPod-related. `command devpod` is
the escape hatch, and the function is short enough to read in one screen.

**A per-invocation flag is a per-invocation risk.** Anything that calls
`devpod` without going through an interactive shell — a script, a systemd
unit, an editor integration — does not get the function and so does not get
the token. Those paths keep today's behaviour rather than breaking, but they
also keep today's bug.

**One more secret to rotate.** The PAT joins the SSH signing key, the sops
keys, the `gh` token and the sugarrush config. `mise run secrets-restore`
already checks every blob still decrypts, so this one is covered by that the
moment it exists.

## Verification

The regression is a bootstrap that used to fail on quota:

- Scaffold a throwaway project, `devpod up`, and confirm the run completes
  with no `rate limit exceeded` in the log, no `Failed to install tools`,
  and `mise ls --missing` empty inside the container.
- Confirm the token actually arrived: `MISE_GITHUB_TOKEN` is set in the
  dotfiles script's environment, and `github auth:` no longer reports `no`.

The secret handling:

- `mise run secrets-restore` decrypts the new blob.
- `mise run check` passes, gitleaks included — the plaintext token must
  never reach the tree, and the blob must be ciphertext
  (`-----BEGIN AGE ENCRYPTED FILE-----`).
- The token appears in neither `ps` output during a `devpod up` nor the
  DevPod log.

The wrapper:

- `devpod ssh <workspace>` and `devpod list` still work — the flag is not
  passed to them.
- With `~/.config/devpod/dotfiles-env` renamed away, `devpod up` still runs
  and simply omits the flag.
- `mise run shells` stays green: the function must not break shell startup.

## Out of scope

Making mise itself need fewer API calls — pinning by URL rather than
resolving versions, or caching resolutions across containers — is a larger
change to how tools are declared, and this does not attempt it.

Giving containers a real `gh` login is likewise separate: it needs the age
identity inside the container, which the whole secret design deliberately
avoids.
