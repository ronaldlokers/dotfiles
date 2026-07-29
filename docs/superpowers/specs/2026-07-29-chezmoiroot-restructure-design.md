# Source-tree restructure and cleanup: what to take from twpayne/dotfiles

**Date:** 2026-07-29
**Status:** approved

## Context

[twpayne/dotfiles](https://github.com/twpayne/dotfiles) is the chezmoi author's
own repo. Reading it against this one turned up four transferable ideas, three
non-transferable ones worth recording so they aren't re-proposed, and one gap
found while looking that is not his at all.

### Transferable

| Idea | What it buys here |
| --- | --- |
| `.chezmoiroot` | Repo-only files live outside the source tree, so they need no `.chezmoiignore` entry and can't leak into `$HOME` |
| `.chezmoiversion` | A clear "your chezmoi is too old" error instead of confusing template failures |
| `exact_` directories | A file deleted from the repo actually disappears from `$HOME` |
| `.chezmoiremove` | Already present with one entry; use it for tools already dropped |

### Not transferable, and why

- **`gitHubLatestReleaseAssetURL` externals.** Floating "latest" plus a GitHub
  API call per apply. That API quota is exactly what broke cold devpod
  containers here (see `docs/design-notes.md`). Pinning plus Renovate stays.
- **Feature tags in `[data]`** (`ephemeral`, `headless`, `personal`, `work`).
  Config data renders only at `chezmoi init`, so a value goes stale when the
  machine changes. `.chezmoitemplates/is-container` re-renders every apply,
  which is the correct behaviour for the one axis this repo has.
- **Multi-OS script directories, oh-my-zsh, powerlevel10k.** Single-OS repo;
  the prompt is pure.

### The 1Password question

twpayne's secrets are fetched from 1Password at apply time; nothing encrypted
lives in his repo. Proton Pass ships an equivalent CLI — `pass-cli`, with
`inject` and `run` — and it is already installed on this host, unmanaged and
unpinned.

It is **not** adopted for secrets. A Proton Pass session cannot exist inside a
devpod container or in CI, so any apply-time fetch reintroduces exactly the
failure mode that `chezmoi add --encrypt` was banned for: a non-interactive
`chezmoi apply` that cannot complete. The `.age` blobs work offline, with no
account and no network, and the YubiKey path needs no session at all.

`pass-cli` is pinned in mise so it stops being an unmanaged 39 MB binary. That
is the whole of its role.

### Found while looking

mise never prunes. `gemini-cli`, `superfile` and `kubeconform` are gone from
`dot_config/mise/config.toml` but their installs are still under
`~/.local/share/mise/installs`, and `~/.config/superfile`,
`~/.local/share/superfile` and `~/.gemini` are still in `$HOME`.

## Delivery

Two PRs, in order. PR 1 is a pure move so it can be reviewed as "did anything
change besides paths?" — content edits mixed into a large rename are invisible.

---

## PR 1 — `.chezmoiroot`

### Goal

Repo-only files stop being part of the chezmoi source state, so forgetting a
`.chezmoiignore` entry stops being a way to leak a file into `$HOME`.

### The move

A new `.chezmoiroot` at repo root containing the single line `home`.

Moves into `home/` (`git mv`, preserving history):

```
.chezmoi.toml.tmpl  .chezmoiignore  .chezmoiremove
.chezmoiexternals/  .chezmoiscripts/  .chezmoitemplates/
dot_bashrc  dot_zshrc  dot_tmux.conf  dot_claude/  dot_config/  dot_local/
private_dot_ssh/  key.txt.age  ghostty.terminfo
```

Stays at repo root:

```
README.md  CLAUDE.md  docs/  assets/  setup  mise.toml
.github/  .claude/  .superpowers/  .gitignore  .chezmoiroot
```

`key.txt.age` and `ghostty.terminfo` move *with* the source tree even though
they are repo-only in the sense that they are never applied. Both are read
through `{{ .chezmoi.sourceDir }}` and `include`, which resolve relative to the
source directory; moving them keeps those call sites correct without edits.
They keep their `.chezmoiignore` entries.

### What breaks and gets fixed here

1. **`.chezmoiignore`** drops six now-unnecessary entries: `setup`, `README.md`,
   `CLAUDE.md`, `mise.toml`, `/docs`, `/assets`. It keeps `ghostty.terminfo`,
   `key.txt.age`, the five `.age` target paths, and the container-gated block.

2. **CI template paths.** `.github/workflows/ci.yaml` executes specific source
   files by path — `chezmoi execute-template --source "$PWD" <
   .chezmoiexternals/devpod.toml` and three similar. Each needs the `home/`
   prefix. `--source "$PWD"` itself is unchanged and stays correct: chezmoi
   reads `.chezmoiroot` from the source directory and descends.

3. **The blob loop.** `git ls-files '*.age' | grep -v '^key.txt.age$'` no longer
   excludes anything, because the path is now `home/key.txt.age`. It appears in
   `.github/workflows/ci.yaml` (the recipient-rotation job) and in `README.md`.
   Both anchors become `^home/key\.txt\.age$`.

4. **`dotfiles-update-check`.** `dot_local/bin/executable_dotfiles-update-check.tmpl`
   sets `source_dir="{{ .chezmoi.sourceDir }}"` and runs git in it. That still
   works from a subdirectory of the worktree, but it now means something
   different from what it says; it becomes `{{ .chezmoi.workingTree }}`.

5. **Docs.** `README.md`'s Layout table and `.chezmoiignore` sentence, plus
   `CLAUDE.md`'s source-editing rule, both describe the old shape.

### Verification

- `mise run check` (lint + gitleaks + clean-HOME bootstrap + idempotence).
- `mise run verify` non-interactively, which is what CI's clean-HOME job does.
- A real `devpod up . --recreate` against a merged `main`. This is the only
  thing that exercises `DOTFILES_URL` — DevPod clones the repo fresh inside the
  container and runs `setup`, a path the clean-HOME bootstrap never touches.
  Because DevPod clones from `main`, this check happens after merge, not on the
  branch.

---

## PR 2 — the small items

### `.chezmoiversion`

A file at repo root — *outside* `home/`, alongside `.chezmoiroot`, which is
where twpayne's sits and is evidence that it is read before the root is
descended into — containing `2.70.5`, matching the chezmoi pin in
`dot_config/mise/config.toml`. That is the only version CI exercises, and
`setup` installs latest from `get.chezmoi.io`, so a fresh machine always
satisfies it. A host running an older distro-packaged chezmoi gets a clear
refusal instead of template errors.

Two places now hold a chezmoi version, so they can drift. `mise run lint` gains
an assertion that `.chezmoiversion` equals the `chezmoi = "…"` pin in
`home/dot_config/mise/config.toml`, failing with both values when they differ.
Renovate bumps the mise pin; the lint failure is what says "bump the other one
too".

### `exact_` directories

Three, all of which this repo is the sole writer of:

| Directory | Why |
| --- | --- |
| `private_dot_ssh/exact_private_config.d/` | A dropped fragment should stop being pulled in by the `Include config.d/*.conf` line |
| `dot_local/share/exact_devcontainer-template/` | A file removed from the starter should stop being scaffolded |
| `dot_config/nvim/lua/exact_plugins/` | A plugin spec deleted from the repo currently keeps loading forever |

Explicitly **not** `exact_`:

- `dot_config/television/cable/` — the `tv-channels` external unpacks into that
  same target directory.
- `dot_local/bin/` — holds the chezmoi, mise and devpod binaries, none managed
  as files.
- `dot_claude/skills/` — `~/.claude/skills/omarchy` is installed from outside
  this repo.

### `.chezmoiremove`

Gains three paths left behind by tools already dropped:

```
.config/superfile
.local/share/superfile
.gemini
```

`~/.local/bin/gemini` is deliberately left alone: it is one of a family of
hand-written wrapper scripts (`codex`, `copilot`, `opencode`, `pi`, …) that this
repo does not manage and did not create.

### `mise run prune`

A new task in `mise.toml`. It runs `mise prune --dry-run` first, prints what
would be removed, then prompts `Continue? [y/N]` and only runs `mise prune` on
an explicit `y`. Anything other than `y` exits 0 having changed nothing, so an
accidental invocation is harmless. Never invoked from a `chezmoi apply`: on a
machine that has not opened a project recently, pruning throws away that
project's tools and forces a re-download. Deliberate invocation only.

### `pass-cli`

Pinned in `dot_config/mise/config.toml`. It is not in the mise registry, so the
backend is `github:` or `aqua:` — whichever resolves the Proton Pass release
assets on linux — following the same pattern as the existing `github:` pins for
sesh and sugarrush. Verify Renovate's existing mise manager picks it up; add a
rule only if it does not.

No chezmoi integration, no secret moves, no `run_before` block.

### Docs

- `README.md`: Layout table reflects `home/`; the rotation snippet's `git
  ls-files` anchor; a Gotchas line that repo-only files now go outside `home/`.
- `docs/design-notes.md`: why `.chezmoiroot` (the leak class it closes), why
  `exact_` is used on three directories and refused on three others, and the
  Proton Pass reasoning above.

### Verification

`mise run check`. No container run needed — none of PR 2 touches the bootstrap
path.

## Out of scope

- Migrating any secret to Proton Pass.
- Feature tags (`ephemeral`, `headless`, `personal`) in config data.
- Switching externals to `gitHubLatestRelease*`.
- Multi-OS support.
