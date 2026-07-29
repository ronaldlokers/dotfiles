# Container GitHub Token Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give DevPod containers a no-scope GitHub token so `mise install` stops failing on the 60/hour anonymous API rate limit during a cold bootstrap.

**Architecture:** The token lives as an age blob in the source tree and is decrypted to `~/.config/devpod/dotfiles-env` by the existing secret-unlock script, exactly like the `gh` token beside it. A `devpod()` shell function adds `--dotfiles-script-env-file` to `devpod up` so DevPod injects `MISE_GITHUB_TOKEN` into the dotfiles install script — the step that fails.

**Tech Stack:** chezmoi, age, DevPod, mise, zsh, bash.

Spec: `docs/superpowers/specs/2026-07-29-container-github-token-design.md`

## Global Constraints

- Branch is `feat/container-github-token`. Never commit to `main`. Conventional-commit subjects, lowercase imperative.
- **Never** edit a chezmoi-managed file in `$HOME` as a source of truth. Edit the source tree under `/home/ronald/.local/share/chezmoi`, then `chezmoi apply`.
- **Never write the token in plaintext anywhere in the repo**, and never print it. CI runs gitleaks over the full history. If you need to prove the decrypt works, pipe through `sed 's/=.*/=<redacted>/'`.
- The blob already exists at `dot_config/private_devpod/private_dotfiles-env.age` (created before this plan, verified as `-----BEGIN AGE ENCRYPTED FILE-----` ciphertext that round-trips). Do not recreate it.
- The variable is `MISE_GITHUB_TOKEN`, not `GITHUB_TOKEN` — narrower, and matching what `mise.toml`'s `verify` task already uses.
- `.chezmoiscripts/run_before_00-unlock-secrets.sh.tmpl` is itself a chezmoi template. Decrypt expressions must be escaped `'{{"{{"}} decrypt (include "…") {{"}}"}}'` or they render to a file that decrypts nothing.
- `dot_zshrc` and `dot_bashrc` are kept in step by hand; a change to one wants the same change in the other.
- Every shell-integration block is guarded. A missing secret must never break shell startup or `devpod`.
- Comment style explains *why*, not *what*, wrapped near 80 columns.
- `mise run check` must pass before the PR.

## Established facts

Measured while writing the spec — do not re-derive.

1. A cold `devpod up` fails with `github rate limit: 0/60 (core)` and `Failed to install tools: github:joshmedeski/sesh, github:ronaldlokers/sugarrush, pipx:…pomo, vfox:mise-plugins/vfox-neovim`, taking `install_packages.sh` and then `./setup` down with it. After the quota reset, the same container installed everything with nothing missing — so the tools are fine and the quota is the whole problem.
2. Containers have no `gh` session: `~/.config/gh/hosts.yml` is an age blob that only decrypts with a TTY, which `devpod up` does not have.
3. DevPod provides `--dotfiles-script-env` and `--dotfiles-script-env-file` for putting environment variables into the dotfiles install script, plus `--workspace-env`, `--workspace-env-file` and `--init-env`. None of them is a persistable context option — `devpod context options` lists `DOTFILES_URL`, `DOTFILES_SCRIPT`, the SSH/GPG forwarding switches and telemetry, and nothing for environment.
4. The unlock script's helpers are `secret_current TARGET HASH` (freshness check) and `decrypt_to TARGET TEMPLATE HASH` (renders, promotes only if non-empty, `chmod 600`, records the hash). `decrypt_to` already handles the no-TTY case by warning and returning 0 rather than aborting the apply.

## File Structure

**Created:**
- `dot_config/private_devpod/private_dotfiles-env.age` — already present, holding `MISE_GITHUB_TOKEN=<pat>`.

**Modified:**
- `.chezmoiignore` — keep the raw blob out of `$HOME`.
- `.chezmoiscripts/run_before_00-unlock-secrets.sh.tmpl` — one more decrypt block.
- `dot_zshrc`, `dot_bashrc` — the `devpod()` wrapper.
- `README.md` — the Dev containers and Secrets sections.

---

### Task 1: Decrypt the blob to its target

**Files:**
- Modify: `.chezmoiignore`
- Modify: `.chezmoiscripts/run_before_00-unlock-secrets.sh.tmpl` (the `if [ "$secrets_ready" -eq 1 ] && build_identities;` block, after the `gh_hosts` stanza)

**Interfaces:**
- Consumes: the existing blob at `dot_config/private_devpod/private_dotfiles-env.age`.
- Produces: `~/.config/devpod/dotfiles-env`, mode 600, containing one `MISE_GITHUB_TOKEN=…` line. Task 2's shell function reads that path.

- [ ] **Step 1: Keep the raw blob out of `$HOME`**

`.chezmoiignore` already lists the other blobs by their literal target path. Add this one alongside them, next to `.config/gh/hosts.yml.age`:

```
.config/devpod/dotfiles-env.age
```

- [ ] **Step 2: Add the decrypt block**

In `.chezmoiscripts/run_before_00-unlock-secrets.sh.tmpl`, immediately after the `gh_hosts` block and before the closing `fi`:

```sh
    # A no-scope PAT, used only to lift GitHub's 60/hour anonymous API rate
    # limit inside DevPod containers. mise resolves a version through the API
    # for every github:/vfox:/pipx: tool, which a cold bootstrap cannot fit in
    # 60 requests — it fails partway with "rate limit exceeded" and takes the
    # whole apply with it. The host is fine because gh is authenticated there;
    # a container has no gh session, since hosts.yml only decrypts with a TTY.
    #
    # MISE_GITHUB_TOKEN rather than GITHUB_TOKEN: this reaches mise and
    # nothing else, so a container does not silently gain a general-purpose
    # GitHub credential. dot_zshrc's devpod wrapper hands the file to
    # `devpod up --dotfiles-script-env-file`.
    devpod_env="$HOME/.config/devpod/dotfiles-env"
    devpod_env_hash='{{ include "dot_config/private_devpod/private_dotfiles-env.age" | sha256sum }}'
    if ! secret_current "$devpod_env" "$devpod_env_hash"; then
        mkdir -p "$HOME/.config/devpod"
        chmod 700 "$HOME/.config/devpod"
        decrypt_to "$devpod_env" '{{"{{"}} decrypt (include "dot_config/private_devpod/private_dotfiles-env.age") {{"}}"}}' "$devpod_env_hash"
    fi
```

The `{{"{{"}}` escaping is not optional — see Global Constraints.

Note `~/.config/devpod/` is co-owned: DevPod keeps its own `config.yaml` there. `mkdir -p` plus `chmod 700` matches what the `gh` block does to a directory it shares with the tool.

- [ ] **Step 3: Lint**

Run: `mise run lint`
Expected: exit 0. The script is in the shellcheck list.

- [ ] **Step 4: Apply and confirm the file lands**

Run: `chezmoi apply && ls -l ~/.config/devpod/dotfiles-env && cut -d= -f1 ~/.config/devpod/dotfiles-env`
Expected: mode `-rw-------`, and the single field name `MISE_GITHUB_TOKEN`.

Print the field name only. Do not cat the file.

- [ ] **Step 5: Confirm the raw blob did not land in `$HOME`**

Run: `ls ~/.config/devpod/`
Expected: `dotfiles-env` and DevPod's own files, but no `dotfiles-env.age`. If the `.age` file is there, the `.chezmoiignore` entry does not match — fix it rather than deleting the file by hand.

- [ ] **Step 6: Confirm the blob decrypts under the repo's own check**

Run: `mise run secrets-restore 2>&1 | grep devpod`
Expected: an `ok` line for `dot_config/private_devpod/private_dotfiles-env.age`.

- [ ] **Step 7: Commit**

```bash
git add .chezmoiignore .chezmoiscripts/run_before_00-unlock-secrets.sh.tmpl dot_config/private_devpod/
git commit -m "feat: decrypt a no-scope github token for container bootstraps"
```

---

### Task 2: The devpod wrapper

**Files:**
- Modify: `dot_zshrc` — near the other shell integrations, after the tv block
- Modify: `dot_bashrc` — the matching position, after its tv block

**Interfaces:**
- Consumes: `~/.config/devpod/dotfiles-env` from Task 1.
- Produces: a `devpod` shell function in both shells. Nothing else depends on it.

- [ ] **Step 1: Add the function to `dot_zshrc`**

```zsh
# DevPod containers have no gh session — hosts.yml only decrypts with a TTY —
# so mise resolves every github:/vfox:/pipx: tool against GitHub's 60/hour
# anonymous limit and a cold bootstrap runs out partway through. This hands
# `devpod up` a file holding a no-scope PAT, which DevPod injects into the
# dotfiles install script.
#
# Wrapping the binary rather than shipping a `devpod-up` script: the flag has
# to be there every time, and DevPod has no context option to persist it. Use
# `command devpod` to bypass this.
#
# Guarded on both the subcommand and the file: `up` because no other
# subcommand accepts the flag, and readability because a machine whose age
# identity has not been unlocked has no such file and must still run devpod.
if command -v devpod > /dev/null ; then
  devpod() {
    if [ "$1" = "up" ] && [ -r "$HOME/.config/devpod/dotfiles-env" ]; then
      command devpod "$@" --dotfiles-script-env-file "$HOME/.config/devpod/dotfiles-env"
    else
      command devpod "$@"
    fi
  }
fi
```

- [ ] **Step 2: Add the same function to `dot_bashrc`**

Identical body — the function is POSIX-shell shaped and needs no per-shell variation. Use a shorter comment that points at the zsh one, matching how the other mirrored blocks in this file read:

```bash
# DevPod containers have no gh session, so mise hits GitHub's anonymous rate
# limit during a cold bootstrap. Same wrapper as in .zshrc — see the comment
# there for why this wraps the binary and why both guards are needed.
if command -v devpod > /dev/null ; then
  devpod() {
    if [ "$1" = "up" ] && [ -r "$HOME/.config/devpod/dotfiles-env" ]; then
      command devpod "$@" --dotfiles-script-env-file "$HOME/.config/devpod/dotfiles-env"
    else
      command devpod "$@"
    fi
  }
fi
```

- [ ] **Step 3: Apply and check both shells still start clean**

Run: `chezmoi apply && mise run shells`
Expected: `ok    zsh`, `ok    bash`, exit 0.

- [ ] **Step 4: Verify the function exists and passes non-`up` through**

Run: `zsh -ic 'type devpod | head -2; devpod list >/dev/null && echo "list ok"' </dev/null`
Expected: `devpod` reported as a shell function, and `list ok`. If `devpod list` fails, the wrapper is passing the flag to a subcommand that rejects it.

- [ ] **Step 5: Verify the flag is actually added for `up`, without running a build**

Do not run a real `devpod up` here — Task 3 does that. Prove the argument construction instead, by shadowing the binary with a stub that prints its arguments:

```bash
d=$(mktemp -d); printf '#!/bin/sh\necho "ARGS: $*"\n' > "$d/devpod"; chmod +x "$d/devpod"
zsh -ic "PATH=$d:\$PATH; source ~/.zshrc 2>/dev/null; devpod up . 2>&1 | grep ARGS" </dev/null
rm -rf "$d"
```

Expected: an `ARGS:` line containing `up . --dotfiles-script-env-file /home/ronald/.config/devpod/dotfiles-env`.

If the stub is not picked up, the function captured the real path at definition time — report what you observed rather than forcing the test to pass.

- [ ] **Step 6: Verify the no-secret path degrades to a plain pass-through**

```bash
mv ~/.config/devpod/dotfiles-env ~/.config/devpod/dotfiles-env.bak
zsh -ic 'devpod list >/dev/null && echo "still works"' </dev/null
mv ~/.config/devpod/dotfiles-env.bak ~/.config/devpod/dotfiles-env
```

Expected: `still works`. This is the fresh-machine case — no age identity, no file, and `devpod` must behave exactly as it does today.

- [ ] **Step 7: Commit**

```bash
git add dot_zshrc dot_bashrc
git commit -m "feat: hand devpod up a github token for the dotfiles script"
```

---

### Task 3: Documentation and full verification

**Files:**
- Modify: `README.md` — the Dev containers section, and the Secrets section's list of blobs.

**Interfaces:**
- Consumes: everything above.
- Produces: a branch ready for review.

- [ ] **Step 1: Document it in the Dev containers section**

After the paragraph ending "DevPod clones and applies them itself, via the `DOTFILES_URL` option above", add:

```markdown
That bootstrap needs a GitHub token. mise resolves a version through the
GitHub API for every `github:`, `vfox:` and `pipx:` tool, and unauthenticated
that is 60 requests an hour per IP — less than this repo's tool list, so a
cold container fails partway through with `rate limit exceeded` and takes the
whole apply with it. The host is unaffected because `gh` is authenticated
there; a container has no `gh` session, since `hosts.yml` only decrypts with a
TTY.

So `~/.config/devpod/dotfiles-env` holds a **no-scope** PAT as
`MISE_GITHUB_TOKEN`, and a `devpod` shell function in both rc files hands that
file to `devpod up --dotfiles-script-env-file`. The token carries no scopes
because mise needs it only for the rate limit — a container that leaks it
leaks public-read quota and nothing else. `command devpod` bypasses the
wrapper, and a machine whose age identity is still locked has no such file, so
the wrapper passes straight through and containers bootstrap exactly as they
did before.
```

- [ ] **Step 2: Add the blob to the Secrets section's inventory**

The Secrets section has a "Currently decrypted by the script" table. Add a fourth row after the `sugarrush config` one:

```markdown
| DevPod container token | `~/.config/devpod/dotfiles-env` | `dot_config/private_devpod/private_dotfiles-env.age` |
```

Keep the column order and the backtick style of the existing rows.

- [ ] **Step 3: Confirm no plaintext token anywhere in the tree**

Run: `grep -rn "github_pat_" . --exclude-dir=.git --exclude-dir=.superpowers || echo "clean"`
Expected: `clean`.

- [ ] **Step 4: Run the full check**

Run: `mise run check`
Expected: exit 0 — gitleaks over the full history included.

If it fails with `Disk quota exceeded`, that is `/tmp` being a full tmpfs, unrelated to this change: re-run as `TMPDIR=/var/tmp mise run check` and say so in your report.

- [ ] **Step 5: Confirm the diff's scope**

Run: `git diff main --stat`
Expected: the six files this plan names, plus the spec and this plan. The `.age` blob must appear as a new binary-ish file, never as readable text.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: describe the container github token"
```

Stop here. The end-to-end run in Task 4 needs a real terminal, and the push and PR happen after a whole-branch review.

---

### Task 4: End-to-end check (human-run)

An agent must not mark this done. `devpod up` clones the dotfiles over SSH, which needs a forwarded agent a tool session does not have.

**Hand these steps to the human partner.**

- [ ] **Step 1: Scaffold and bring up a throwaway project**

```bash
mkdir -p /var/tmp/tokencheck && cd /var/tmp/tokencheck && git init -q . && devcontainer-init
devpod up . --id tokencheck --ide none 2>&1 | tee /var/tmp/tokencheck.log
```

- [ ] **Step 2: Confirm the token arrived and the quota problem is gone**

```bash
grep -c "rate limit exceeded" /var/tmp/tokencheck.log
grep -c "Failed to install tools" /var/tmp/tokencheck.log
grep -m1 "github auth:" /var/tmp/tokencheck.log
```

Expected: `0`, `0`, and — if mise prints the line at all — `github auth: yes`. Before this change that line read `github auth: no`.

- [ ] **Step 3: Confirm nothing is missing inside the container**

```bash
devpod ssh tokencheck --command 'zsh -ic "mise ls --missing | wc -l"'
```

Expected: `0`.

- [ ] **Step 4: Confirm the token did not leak into the log**

```bash
grep -c "github_pat_" /var/tmp/tokencheck.log
```

Expected: `0`. DevPod should pass the file, not echo its contents. If this is non-zero, stop and report — that is a finding, not a nuisance.

The spec also asks that the token never appear in `ps` output. That holds by construction rather than by test: the flag carries a *path*, so the token cannot reach the process arguments — which is why the file form was chosen over `--dotfiles-script-env KEY=VALUE`. Task 2 Step 5 already prints the constructed arguments and shows the path, not the secret.

- [ ] **Step 5: Tear down**

```bash
devpod delete tokencheck --force && rm -rf /var/tmp/tokencheck /var/tmp/tokencheck.log
```
