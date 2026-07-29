# chezmoiroot Restructure and Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the chezmoi source tree into `home/` so repo-only files can't leak into `$HOME`, then apply four small correctness fixes derived from reading twpayne/dotfiles.

**Architecture:** Two independent PRs. PR 1 (Tasks 1–3) is the `.chezmoiroot` move plus every reference that breaks because of it — a path-only change, reviewable as "did anything change besides paths?". PR 2 (Tasks 4–8) adds `.chezmoiversion`, three `exact_` directories, `.chezmoiremove` entries, a `mise run prune` task, and a pinned `pass-cli` external. PR 2 depends on PR 1 only for path prefixes.

**Tech Stack:** chezmoi 2.70.5, mise tasks, GitHub Actions, bash/sh, Go templates.

**Spec:** `docs/superpowers/specs/2026-07-29-chezmoiroot-restructure-design.md`

## Global Constraints

- Never commit to `main`. PR 1 on branch `feat/chezmoiroot`, PR 2 on branch `feat/chezmoi-cleanup`. Open PRs with `gh`.
- Commit subjects are conventional-commit style, lowercase, imperative: `feat: …`, `fix: …`, `docs: …`, `refactor: …`.
- Never use `chezmoi add --encrypt`. Secrets are plain `<name>.age` blobs whose target path is listed in `.chezmoiignore`.
- Never commit a plaintext secret. Any `.age` file must begin `-----BEGIN AGE ENCRYPTED FILE-----`.
- `mise run check` must pass before each PR is opened. It runs `lint`, `secrets`, `verify`, `shells`.
- The clean-HOME check is `HOME="$(mktemp -d)" chezmoi apply --source "$PWD" </dev/null` — `</dev/null` is mandatory, it reproduces the no-TTY conditions of `devpod up` and CI.
- `.chezmoiversion` value is exactly `2.70.5`, matching the `chezmoi = "2.70.5"` pin in `dot_config/mise/config.toml`.
- `.chezmoiroot` contains exactly one line: `home`.
- Renovate's `managerFilePatterns` use `(^|/)` anchors, so they keep matching after the move. Do not edit `.github/renovate.json` in PR 1.
- Use `git mv` for every move and rename so history follows the file.

---

## File Structure

**PR 1 creates:**
- `.chezmoiroot` — one line, `home`. Tells chezmoi the source state starts at `home/`.

**PR 1 moves into `home/` (unchanged content):**
`.chezmoi.toml.tmpl`, `.chezmoiignore`, `.chezmoiremove`, `.chezmoiexternals/`, `.chezmoiscripts/`, `.chezmoitemplates/`, `dot_bashrc`, `dot_zshrc`, `dot_tmux.conf`, `dot_claude/`, `dot_config/`, `dot_local/`, `private_dot_ssh/`, `key.txt.age`, `ghostty.terminfo`

**PR 1 modifies:**
- `home/.chezmoiignore` — six entries become unnecessary
- `mise.toml` — shellcheck path list, `secrets-restore` blob-exclusion anchor
- `.github/workflows/ci.yaml` — five source-relative paths
- `home/dot_local/bin/executable_dotfiles-update-check.tmpl` — `sourceDir` → `workingTree`
- `README.md`, `CLAUDE.md`, `docs/design-notes.md`

**PR 2 creates:**
- `.chezmoiversion` — one line, `2.70.5`
- `home/.chezmoiexternals/pass-cli.toml` — pinned, checksummed, host-only

**PR 2 modifies:**
- `mise.toml` — version-drift lint assertion, `prune` task, shellcheck path for the renamed template dir
- `home/.chezmoiremove` — three stale target paths
- Three directory renames to `exact_`
- `README.md`, `docs/design-notes.md`

---

# PR 1 — `.chezmoiroot`

### Task 1: Move the source tree into `home/` and fix every broken reference

**Files:**
- Create: `.chezmoiroot`
- Move: 15 top-level entries into `home/`
- Modify: `home/.chezmoiignore`, `mise.toml`, `.github/workflows/ci.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: source root is `<repo>/home`. `{{ .chezmoi.sourceDir }}` now resolves to `<repo>/home`. Every later task references source files as `home/<path>`. `--source "$PWD"` remains correct and unchanged — chezmoi reads `.chezmoiroot` from the source directory and descends.

- [ ] **Step 1: Create the branch**

```bash
git checkout main && git pull
git checkout -b feat/chezmoiroot
```

- [ ] **Step 2: Record the pre-move target state**

This is the regression baseline. The move must not change a single byte of what lands in `$HOME`.

`clean_env` is mandatory, not decoration. This desktop exports `XDG_CONFIG_HOME` and friends pointing back at the real `~/.config`, so chezmoi keeps reading — and writing — the live config even with `HOME` redirected. A previous drill regenerated the real `~/.config/chezmoi/chezmoi.toml` that way. `mise.toml`'s `verify` task carries the same guard.

```bash
clean_env="env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME"
before="$(mktemp -d)"
$clean_env HOME="$before" chezmoi init --source "$PWD" </dev/null >/dev/null
$clean_env HOME="$before" chezmoi apply --source "$PWD" </dev/null
( cd "$before" && find . -type f | sort ) > /tmp/before-files.txt
wc -l /tmp/before-files.txt
echo "$before" > /tmp/before-home.txt
```

Expected: several hundred paths. Keep `$before` around until Step 8.

- [ ] **Step 3: Do the move**

```bash
mkdir home
git mv .chezmoi.toml.tmpl .chezmoiignore .chezmoiremove \
       .chezmoiexternals .chezmoiscripts .chezmoitemplates \
       dot_bashrc dot_zshrc dot_tmux.conf \
       dot_claude dot_config dot_local private_dot_ssh \
       key.txt.age ghostty.terminfo \
       home/
printf 'home\n' > .chezmoiroot
git add .chezmoiroot
```

`key.txt.age` and `ghostty.terminfo` move *with* the tree deliberately. Both are read through `{{ .chezmoi.sourceDir }}` and `include`, which resolve relative to the source directory — moving them keeps those three call sites correct with no edit.

- [ ] **Step 4: Trim `home/.chezmoiignore`**

Six entries existed only to keep repo-only files out of `$HOME`. Those files now live outside the source tree, so chezmoi never sees them. Replace the file's head — everything above the `{{ if eq (includeTemplate "is-container" .) "true" -}}` line — with:

```
ghostty.terminfo
key.txt.age
.ssh/id_ed25519_signing.age
.config/sops/age/keys.txt.age
.config/gh/hosts.yml.age
.config/devpod/dotfiles-env.age
.config/sugarrush/config.toml.age
```

Removed: `setup`, `README.md`, `CLAUDE.md`, `mise.toml`, `/docs`, `/assets`. Kept: `ghostty.terminfo` and `key.txt.age` (in the source tree, but never applied), and the five `.age` blob target paths. Leave the container-gated block at the bottom exactly as it is.

- [ ] **Step 5: Fix `mise.toml`**

Two edits.

The `lint` task's shellcheck line — every path needs the `home/` prefix:

```
	"shellcheck --severity=warning setup home/.chezmoiscripts/*.sh.tmpl home/.chezmoiscripts/run_after_12-ensure-ssh-include.sh home/dot_claude/executable_statusline.sh home/dot_claude/modify_settings.json home/dot_config/shell/ssh-agent.sh home/dot_config/shell/github-token.sh home/dot_local/share/devcontainer-template/post-create.sh home/dot_local/bin/executable_devcontainer-init",
```

`setup` keeps no prefix — it stays at the repo root.

The same `lint` task pipes `./dot_claude/modify_settings.json` twice (once for the jq path, once for the no-jq fallback). Both become `./home/dot_claude/modify_settings.json`.

The `secrets-restore` task's blob loop — the exclusion anchor no longer matches, because the path is now `home/key.txt.age`:

```sh
for blob in $(git ls-files '*.age' | grep -v '^home/key\.txt\.age$'); do
```

- [ ] **Step 6: Fix `.github/workflows/ci.yaml`**

Five source-relative paths. Every `--source "$PWD"` stays as-is.

| Line | Was | Becomes |
| --- | --- | --- |
| ~152 | `cp dot_config/systemd/user/ssh-agent.service \` | `cp home/dot_config/systemd/user/ssh-agent.service \` |
| ~155 | `< .chezmoiscripts/run_onchange_after_10-enable-ssh-agent.sh.tmpl \` | `< home/.chezmoiscripts/run_onchange_after_10-enable-ssh-agent.sh.tmpl \` |
| ~213 | `< .chezmoiexternals/devpod.toml)` | `< home/.chezmoiexternals/devpod.toml)` |
| ~223 | `< .chezmoiscripts/run_after_20-install-host-packages.sh.tmpl > /tmp/pkgs.sh` | `< home/.chezmoiscripts/run_after_20-install-host-packages.sh.tmpl > /tmp/pkgs.sh` |
| ~244 | `< .chezmoiscripts/run_onchange_after_30-configure-devpod.sh.tmpl > /tmp/devpod-configure.sh` | `< home/.chezmoiscripts/run_onchange_after_30-configure-devpod.sh.tmpl > /tmp/devpod-configure.sh` |

And the recipient-rotation job's two blob loops (~303 and ~310), same anchor fix as `mise.toml`:

```sh
for blob in $(git ls-files '*.age' | grep -v '^home/key\.txt\.age$'); do
```
```sh
echo "rewrote $(git ls-files '*.age' | grep -cv '^home/key\.txt\.age$') blobs"
```

Verify none were missed:

```bash
grep -nE '< \.chezmoi|cp dot_|\^key\.txt' .github/workflows/ci.yaml
```

Expected: no output.

- [ ] **Step 7: Verify the target state is byte-identical**

```bash
clean_env="env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME"
after="$(mktemp -d)"
$clean_env HOME="$after" chezmoi init --source "$PWD" </dev/null >/dev/null
$clean_env HOME="$after" chezmoi apply --source "$PWD" </dev/null
( cd "$after" && find . -type f | sort ) > /tmp/after-files.txt
diff /tmp/before-files.txt /tmp/after-files.txt && echo "FILE LISTS IDENTICAL"
diff -r "$(cat /tmp/before-home.txt)" "$after" && echo "CONTENTS IDENTICAL"
```

Expected: both lines print. Any difference is a bug in this task — most likely a `.chezmoiignore` entry removed that was doing real work, or a file left behind at the repo root.

- [ ] **Step 8: Run the full check**

```bash
mise run check
```

Expected: PASS. `lint`, `secrets`, `verify` and `shells` all green.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: move the source tree under .chezmoiroot"
```

---

### Task 2: Point `dotfiles-update-check` at the working tree

**Files:**
- Modify: `home/dot_local/bin/executable_dotfiles-update-check.tmpl:8` and its `.git` guard

**Interfaces:**
- Consumes: the `home/` source root from Task 1.
- Produces: nothing later tasks depend on.

This is a real regression introduced by Task 1, not a tidy-up. The script does `[ -d "$source_dir/.git" ] || exit 0`, and after the move `sourceDir` is `<repo>/home`, which has no `.git`. Every run would exit 0 silently and the update timer would stop reporting — with no error anywhere.

- [ ] **Step 1: Reproduce the break**

```bash
chezmoi execute-template --source "$PWD" \
  < home/dot_local/bin/executable_dotfiles-update-check.tmpl \
  | grep -n 'source_dir='
```

Expected: `source_dir="/home/ronald/.local/share/chezmoi/home"` — a directory with no `.git` in it.

- [ ] **Step 2: Fix the variable**

In `home/dot_local/bin/executable_dotfiles-update-check.tmpl`, replace line 8:

```sh
repo_dir="{{ .chezmoi.workingTree }}"
```

Then replace every later `$source_dir` with `$repo_dir` — the `[ -d ... ]` guard and each `git -C` call. Update the comment above it to say the working tree, not the source directory.

- [ ] **Step 3: Verify the rendered path is the repo root**

```bash
chezmoi execute-template --source "$PWD" \
  < home/dot_local/bin/executable_dotfiles-update-check.tmpl \
  | grep -n 'repo_dir='
```

Expected: `repo_dir="/home/ronald/.local/share/chezmoi"` — no `/home` suffix.

- [ ] **Step 4: Run it end to end**

```bash
chezmoi apply
dotfiles-update-check; echo "exit=$?"
```

Expected: `exit=0`. It prints nothing when the machine is up to date — that is the designed behaviour. To prove it is not silently short-circuiting, confirm the guard now passes:

```bash
test -d "$(chezmoi execute-template '{{ .chezmoi.workingTree }}')/.git" && echo "guard passes"
```

Expected: `guard passes`.

- [ ] **Step 5: Commit**

```bash
git add home/dot_local/bin/executable_dotfiles-update-check.tmpl
git commit -m "fix: resolve the update check against the working tree, not the source dir"
```

---

### Task 3: Update the docs for the new tree shape

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `docs/design-notes.md`

**Interfaces:**
- Consumes: the layout from Tasks 1–2.
- Produces: nothing.

- [ ] **Step 1: Fix the `README.md` rotation snippet**

In the Secrets section, the blob-rewrite loop excludes the wrong path:

```sh
for blob in $(git ls-files '*.age' | grep -v '^home/key\.txt\.age$'); do
  chezmoi decrypt "$blob" | chezmoi encrypt --output "$blob.new" && mv "$blob.new" "$blob"
done
mise run secrets-restore   # every blob still opens with the current identity
```

- [ ] **Step 2: Update the `README.md` Layout section**

Add a sentence before the table stating that everything chezmoi manages lives under `home/`, and that the table's paths are relative to it. Then replace the trailing `.chezmoiignore` sentence — repo-only files no longer need listing:

```markdown
Everything chezmoi manages lives under `home/` (`.chezmoiroot`); paths in the
table are relative to it. Repo-only files — `README.md`, `CLAUDE.md`, `docs/`,
`assets/`, `setup`, `mise.toml` — sit outside `home/`, so chezmoi never sees
them and they need no `.chezmoiignore` entry.
```

- [ ] **Step 3: Add the Gotchas entry**

```markdown
- **New repo-only files go outside `home/`.** Anything inside it is source
  state and will be applied into `$HOME` unless `.chezmoiignore` says
  otherwise. Docs, CI config and repo tooling belong at the repo root.
```

- [ ] **Step 4: Update `CLAUDE.md`**

Its Rules section says repo-only files "must list in `.chezmoiignore`". Replace that bullet with the `home/` rule, and update the source-path line to mention that `chezmoi source-path` now returns a path under `home/`.

- [ ] **Step 5: Add the rationale to `docs/design-notes.md`**

New section explaining what `.chezmoiroot` closes: before it, every repo-only file needed an `.chezmoiignore` entry, and forgetting one applied it into `$HOME`. Note that `key.txt.age` and `ghostty.terminfo` stayed in the source tree because they are read through `sourceDir`, and that `--source "$PWD"` is unaffected.

- [ ] **Step 6: Verify no doc still describes the old shape**

```bash
grep -rn 'chezmoiignore' README.md CLAUDE.md docs/design-notes.md
```

Expected: no line claims repo-only files need an ignore entry.

- [ ] **Step 7: Commit and open the PR**

```bash
git add README.md CLAUDE.md docs/design-notes.md
git commit -m "docs: describe the home/ source root"
git push -u origin feat/chezmoiroot
gh pr create --title "refactor: move the source tree under .chezmoiroot" \
  --body "Source tree moves to home/. Repo-only files sit outside it and need no .chezmoiignore entry. Target state verified byte-identical before and after the move."
```

- [ ] **Step 8: After merge, verify the container bootstrap**

DevPod clones from `main`, so this cannot run on the branch. After the PR merges:

```bash
cd "$(dirname "$(ls -d ~/Projects/github.com/ronaldlokers/*/.devcontainer | head -1)")"
devpod up . --recreate
```

Expected: a clean bootstrap. This is the only check that exercises `DOTFILES_URL` against the restructured tree — CI's clean-HOME apply uses `--source`, which is a different code path from DevPod's fresh clone plus `setup`. If it fails, that is a `main` regression and takes priority over PR 2.

---

# PR 2 — the small items

### Task 4: Add `.chezmoiversion` with a drift assertion

**Files:**
- Create: `.chezmoiversion`
- Modify: `mise.toml` (the `lint` task)

**Interfaces:**
- Consumes: `home/` source root from PR 1.
- Produces: nothing.

- [ ] **Step 1: Create the branch**

```bash
git checkout main && git pull
git checkout -b feat/chezmoi-cleanup
```

- [ ] **Step 2: Write the file**

```bash
printf '2.70.5\n' > .chezmoiversion
```

At the repo root, *outside* `home/`, alongside `.chezmoiroot` — that is where twpayne's sits, which is the evidence that it is read before the root is descended into.

- [ ] **Step 3: Verify chezmoi accepts it**

```bash
chezmoi status --source "$PWD" >/dev/null && echo "accepted"
```

Expected: `accepted`. A version floor above the installed chezmoi errors with `source state requires version 2.70.5 or later`.

- [ ] **Step 4: Add the drift assertion to the `lint` task**

Two files now carry a chezmoi version and can drift apart. Append this element to the `run` array in `[tasks.lint]`, as a single-quoted TOML literal string so nothing needs escaping:

```toml
	'''v="$(cat .chezmoiversion)"; p="$(sed -n 's/^chezmoi = "\(.*\)"$/\1/p' home/dot_config/mise/config.toml)"; [ "$v" = "$p" ] || { echo ".chezmoiversion ($v) and the mise chezmoi pin ($p) disagree" >&2; exit 1; }''',
```

A TOML *multi-line literal* (`'''`) is required here. A single-quoted literal can't contain the `'` characters the `sed` script needs, and a basic (double-quoted) string would need every `"` and `\` escaped.

Renovate bumps the mise pin; this failure is what says "bump `.chezmoiversion` too".

- [ ] **Step 5: Verify the assertion passes, then prove it can fail**

```bash
mise run lint
printf '2.99.0\n' > .chezmoiversion
mise run lint; echo "exit=$?"
printf '2.70.5\n' > .chezmoiversion
mise run lint
```

Expected: pass, then a non-zero exit printing `.chezmoiversion (2.99.0) and the mise chezmoi pin (2.70.5) disagree`, then pass again. A check that cannot fail is not a check.

- [ ] **Step 6: Commit**

```bash
git add .chezmoiversion mise.toml
git commit -m "feat: declare a minimum chezmoi version and assert it matches the pin"
```

---

### Task 5: Make three directories `exact_`

**Files:**
- Rename: `home/private_dot_ssh/private_config.d`, `home/dot_local/share/devcontainer-template`, `home/dot_config/nvim/lua/plugins`
- Modify: `mise.toml` (shellcheck path)

**Interfaces:**
- Consumes: `home/` source root.
- Produces: target paths in `$HOME` are unchanged (`~/.ssh/config.d/`, `~/.local/share/devcontainer-template/`, `~/.config/nvim/lua/plugins/`). Only the source names change.

`exact_` makes chezmoi delete files in the target directory that it doesn't manage. Applied only to directories this repo is the sole writer of.

- [ ] **Step 1: Rename**

```bash
git mv home/private_dot_ssh/private_config.d \
       home/private_dot_ssh/exact_private_config.d
git mv home/dot_local/share/devcontainer-template \
       home/dot_local/share/exact_devcontainer-template
git mv home/dot_config/nvim/lua/plugins \
       home/dot_config/nvim/lua/exact_plugins
```

Attribute order for directories is `exact_` before `private_`, hence `exact_private_config.d`.

- [ ] **Step 2: Fix the shellcheck path in `mise.toml`**

The `lint` task lints `home/dot_local/share/devcontainer-template/post-create.sh`, which no longer exists under that name:

```
home/dot_local/share/exact_devcontainer-template/post-create.sh
```

- [ ] **Step 3: Verify the target paths are unchanged**

```bash
chezmoi source-path ~/.ssh/config.d/10-dotfiles.conf
chezmoi managed | grep -E '^\.(ssh/config\.d|local/share/devcontainer-template|config/nvim/lua/plugins)'
```

Expected: the source path shows `exact_private_config.d`, while `chezmoi managed` lists the same three *target* paths as before — `.ssh/config.d`, `.local/share/devcontainer-template`, `.config/nvim/lua/plugins`. The `exact_` prefix is a source attribute and must not appear in any target path.

- [ ] **Step 4: Prove `exact_` actually removes a stray file**

```bash
clean_env="env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME"
t="$(mktemp -d)"
$clean_env HOME="$t" chezmoi init --source "$PWD" </dev/null >/dev/null
$clean_env HOME="$t" chezmoi apply --source "$PWD" </dev/null
touch "$t/.local/share/devcontainer-template/stray.txt"
$clean_env HOME="$t" chezmoi apply --source "$PWD" </dev/null
test ! -e "$t/.local/share/devcontainer-template/stray.txt" && echo "exact_ removed the stray file"
rm -rf "$t"
```

Expected: `exact_ removed the stray file`.

- [ ] **Step 5: Run the full check**

```bash
mise run check
```

Expected: PASS. In particular `verify` must still find the SSH include fragment and the devcontainer starter in place.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: mark the three repo-owned directories exact_"
```

---

### Task 6: Retire dropped tools

**Files:**
- Modify: `home/.chezmoiremove`, `mise.toml`

**Interfaces:**
- Consumes: `home/` source root.
- Produces: a `mise run prune` task.

- [ ] **Step 1: Add the stale target paths to `home/.chezmoiremove`**

The file currently holds one line. Append three, each left behind by a tool already removed from `dot_config/mise/config.toml`:

```
.config/superfile
.local/share/superfile
.gemini
```

`~/.local/bin/gemini` is deliberately **not** listed: it is one of a family of hand-written wrapper scripts (`codex`, `copilot`, `opencode`, `pi`, …) that this repo neither manages nor created.

- [ ] **Step 2: Verify chezmoi plans the removals**

```bash
chezmoi status --source "$PWD" | grep -E 'superfile|gemini'
```

Expected: three lines. Do not apply yet.

- [ ] **Step 3: Add the `prune` task to `mise.toml`**

```toml
[tasks.prune]
description = "remove mise tool installs no longer referenced by any tracked config"
# Deliberately never run from a chezmoi apply. `mise prune` removes tools no
# tracked config asks for, and a machine that hasn't opened a project recently
# has not tracked that project's mise.toml — pruning there throws away tools it
# will re-download on the next visit. Manual invocation only, and it shows the
# dry run before touching anything.
run = '''
set -eu
mise prune --dry-run
printf 'Continue? [y/N] '
read -r reply
case "$reply" in
y|Y) mise prune ;;
*) echo "nothing removed" ;;
esac
'''
```

- [ ] **Step 4: Verify the task is safe to invoke accidentally**

```bash
echo n | mise run prune
```

Expected: prints the dry-run listing, then `nothing removed`, exit 0. Nothing is deleted.

- [ ] **Step 5: Apply and confirm the stale paths are gone**

```bash
chezmoi apply
test ! -e ~/.config/superfile && test ! -e ~/.local/share/superfile && test ! -e ~/.gemini \
  && echo "stale paths removed"
```

Expected: `stale paths removed`.

- [ ] **Step 6: Commit**

```bash
git add home/.chezmoiremove mise.toml
git commit -m "feat: retire the superfile and gemini leftovers and add a prune task"
```

---

### Task 7: Pin `pass-cli` as a checksummed external

**Files:**
- Create: `home/.chezmoiexternals/pass-cli.toml`

**Interfaces:**
- Consumes: `home/` source root, `.chezmoitemplates/is-container`.
- Produces: `~/.local/bin/pass-cli` at a pinned version on hosts; nothing inside containers.

**Deviation from the spec, and why.** The spec assumed a mise pin via a `github:` or `aqua:` backend. Neither exists: `pass-cli` is not in the mise registry, and Proton does not publish it on GitHub — it is distributed from `https://proton.me/download/pass-cli/versions.json`. The repo already has the right pattern for that case in `.chezmoiexternals/k9s.toml`: a pinned URL plus a `checksum.sha256`, bumped by hand. Use it.

Bumping is manual and stays manual: the checksum has to change with the version, and a Renovate rule that bumped the version alone would produce an external that fails its own checksum on every apply.

- [ ] **Step 1: Confirm the pinned version and hash against the manifest**

```bash
curl -fsSL https://proton.me/download/pass-cli/versions.json \
  | jq -r '.passCliVersions | .version, .urls.linux.x86_64.hash'
```

Expected at time of writing: `2.2.3` and `7188f02a7c1e79a860f7166ad2c34f7a2e6c961265b70677e2704f216dd176d9`. If the manifest has moved on, use the values it prints now in Step 2 — pin whatever is current, never a stale pair.

- [ ] **Step 2: Write `home/.chezmoiexternals/pass-cli.toml`**

```
{{- /* Proton Pass CLI. Host-only, for the same reason the dotfiles do not
       fetch secrets from it: a Proton session cannot exist inside a devpod
       container or in CI, so a container would download 39MB it can never
       log in to. The container test is shared with the host-packages script
       via .chezmoitemplates/is-container.

       Proton publishes this from proton.me, not GitHub, and it is not in the
       mise registry — so it is an external rather than a mise pin, following
       .chezmoiexternals/k9s.toml. Bump by hand: read the version and the
       linux/x86_64 hash out of
       https://proton.me/download/pass-cli/versions.json and update both
       below. Renovate is deliberately not wired up here, because bumping the
       version without the matching hash yields an external that fails its own
       checksum on every apply. */ -}}
{{- if and (eq (includeTemplate "is-container" .) "false") (eq .chezmoi.os "linux") (eq .chezmoi.arch "amd64") -}}
{{ $passCliVersion := "2.2.3" }}
[".local/bin/pass-cli"]
type = "file"
executable = true
url = "https://proton.me/download/pass-cli/{{ $passCliVersion }}/pass-cli-linux-x86_64"
checksum.sha256 = "7188f02a7c1e79a860f7166ad2c34f7a2e6c961265b70677e2704f216dd176d9"
refreshPeriod = "168h"
{{- end -}}
```

- [ ] **Step 3: Verify the external renders on the host**

```bash
chezmoi execute-template --source "$PWD" < home/.chezmoiexternals/pass-cli.toml
```

Expected: the four-key TOML block with the version substituted into the URL.

- [ ] **Step 4: Verify it renders to nothing in a container**

```bash
docker run --rm -v "$PWD:/repo:ro" -w /repo archlinux:base sh -c '
  pacman -Sy --noconfirm --needed curl >/dev/null 2>&1
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /usr/local/bin >/dev/null
  out="$(chezmoi execute-template --source /repo < home/.chezmoiexternals/pass-cli.toml)"
  if [ -n "$(printf "%s" "$out" | tr -d "[:space:]")" ]; then
    echo "FAIL: non-empty inside a container"; printf "%s\n" "$out"; exit 1
  fi
  echo "correctly empty inside a container"'
```

Expected: `correctly empty inside a container`. This mirrors CI's existing devpod-external assertion.

- [ ] **Step 5: Apply and verify the binary**

```bash
chezmoi apply
pass-cli --version
```

Expected: `Proton Pass CLI 2.2.3 …`. This replaces the unmanaged 0.9.1 binary that was on the host; the version jump means the existing session is gone regardless, so `pass-cli login` is needed before it is usable. A checksum mismatch fails the apply loudly, which is the point of pinning the hash.

- [ ] **Step 6: Run the full check**

```bash
mise run check
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add home/.chezmoiexternals/pass-cli.toml
git commit -m "feat: pin the Proton Pass CLI as a checksummed external"
```

---

### Task 8: Document PR 2

**Files:**
- Modify: `README.md`, `docs/design-notes.md`

**Interfaces:**
- Consumes: Tasks 4–7.
- Produces: nothing.

- [ ] **Step 1: Add the `prune` task to the README**

In "Working on this repo", beside `secrets-restore` — both are deliberate, manual, non-CI tasks:

```markdown
```sh
mise run prune             # drop mise tool installs no config asks for
```

It shows a dry run and asks before removing anything. Deliberately not part of
`check`: a machine that hasn't opened a project recently hasn't tracked that
project's `mise.toml`, and pruning there just forces a re-download.
```

- [ ] **Step 2: Add `pass-cli` to the README Layout table**

A row for `home/.chezmoiexternals/` if none exists, naming `pass-cli` as host-only and pinned by version plus checksum.

- [ ] **Step 3: Write the design-notes sections**

Three additions:

1. **Why `.chezmoiversion` matches the mise pin.** It is the only version CI exercises; `setup` installs latest from `get.chezmoi.io`, so a fresh machine always satisfies it; the lint assertion exists because two files now hold the number.
2. **Why `exact_` on three directories and not six.** List the three that got it, then the three refused and why: `dot_config/television/cable/` has the tv-channels external unpacking into the same target; `dot_local/bin/` holds the chezmoi, mise and devpod binaries, none managed as files; `dot_claude/skills/` holds `omarchy`, installed from outside this repo.
3. **Why Proton Pass is pinned but not wired into apply.** twpayne fetches secrets from 1Password at apply time; `pass-cli` offers the same `inject`/`run` model, and it is still refused for secrets because a Proton session cannot exist in a devpod container or in CI — the same failure mode `chezmoi add --encrypt` was banned for. The `.age` blobs work offline with no account; the YubiKey path needs no session at all.

- [ ] **Step 4: Verify the docs match what shipped**

```bash
mise run lint
grep -n 'pass-cli\|chezmoiversion\|exact_\|prune' README.md docs/design-notes.md
```

Expected: every item above appears in at least one of the two files.

- [ ] **Step 5: Commit and open the PR**

```bash
git add README.md docs/design-notes.md
git commit -m "docs: cover the version floor, exact_ dirs, prune task and pass-cli pin"
git push -u origin feat/chezmoi-cleanup
gh pr create --title "feat: version floor, exact_ directories, cleanup task and pass-cli pin" \
  --body "Four small items from the twpayne/dotfiles read: a .chezmoiversion floor asserted against the mise pin, exact_ on the three directories this repo solely owns, .chezmoiremove entries plus a manual mise run prune task, and pass-cli pinned as a checksummed host-only external."
```

---

## Rollback

PR 1 is a rename plus reference updates; `git revert` of the squashed merge restores the old layout completely. Nothing in it changes the target state, which Task 1 Step 7 proves.

PR 2's only destructive element is `.chezmoiremove`. Reverting stops further deletions but does not restore `~/.config/superfile`, `~/.local/share/superfile` or `~/.gemini` — those are config directories for tools no longer installed, and losing them is the intent.
