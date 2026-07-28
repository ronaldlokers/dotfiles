# Co-owned config files Implementation Plan

**Goal:** Stop `chezmoi apply` from destroying what other programs write into two files it manages statically — DevPod's workspace blocks in `~/.ssh/config`, and Claude Code's runtime keys in `~/.claude/settings.json`.

**Architecture:** Two different answers to the same root cause. For SSH, chezmoi stops owning the file DevPod writes to and owns a fragment beside it instead, pulled in by an `Include`. For `settings.json`, chezmoi keeps owning the file but through a `modify_` script that merges its managed keys into whatever is on disk.

**Tech Stack:** chezmoi (`modify_` scripts, `run_after_` scripts), POSIX `sh`, `jq` 1.8.2 via mise, shellcheck 0.11.0 via mise.

## Global Constraints

- Never commit to `main`. Work happens on branch `fix/co-owned-config-files`.
- Commit subjects use conventional-commit style, lowercase, imperative.
- Never edit chezmoi-managed files in `$HOME` directly — edit the source and run `chezmoi apply`.
- `mise run lint` shellchecks an explicit file list at `mise.toml:22`. Every new shell file must be added to it.
- The clean-HOME bootstrap (`mise run verify`, and CI's equivalent) applies with `</dev/null`, no TTY, no unlocked age identity. Nothing may hang waiting for input.
- **A second `chezmoi apply` must produce no managed-file drift.** CI asserts this, and it is the single hardest constraint in this plan — both deliverables are code that generates file content, so unstable output means a red CI.
- `jq` is mise-managed. On a first clean-HOME apply, files are written *before* the run script that installs mise tools, so `jq` is **not** available then. Any use of it must degrade rather than fail.
- This repo comments heavily and explains *why*, not *what*.

## Verification model

No unit-test framework; the checks are mise tasks.

```sh
mise run lint      # shellcheck + JSON + renovate config
mise run verify    # clean-HOME chezmoi apply, non-interactively, plus second-apply drift assertion
mise run check     # both of the above plus gitleaks
```

A bare `chezmoi apply` against the live `$HOME` is fine on this machine once the work is done, but scope it to specific paths while iterating.

## File Structure

| File | Responsibility |
| --- | --- |
| Delete `private_dot_ssh/config` | chezmoi stops owning the file DevPod appends to |
| Create `private_dot_ssh/private_config.d/private_10-dotfiles.conf` | The SSH settings this repo actually manages |
| Create `.chezmoiscripts/run_after_12-ensure-ssh-include.sh` | Seed `Include config.d/*.conf` at the top of `~/.ssh/config`; migrate the old inline block away |
| Delete `dot_claude/settings.json` | Replaced by the script below |
| Create `dot_claude/modify_settings.json` | Emit managed keys merged over whatever is on disk |
| Modify `mise.toml:22` | Add both new shell files to the shellcheck list |
| Modify `README.md` | Explain the co-owned-file pattern once, covering both |

---

### Task 1: SSH config fragment and Include seeding

**Files:**
- Delete: `private_dot_ssh/config`
- Create: `private_dot_ssh/private_config.d/private_10-dotfiles.conf`
- Create: `.chezmoiscripts/run_after_12-ensure-ssh-include.sh`
- Modify: `mise.toml:22`

**Interfaces:**
- Consumes: nothing
- Produces: `~/.ssh/config.d/10-dotfiles.conf` (mode 0600) inside `~/.ssh/config.d/` (mode 0700), and the invariant that `Include config.d/*.conf` is the first non-comment line of `~/.ssh/config`

- [ ] **Step 1: Reproduce the failure**

Confirm the bug before fixing it. `~/.ssh/config` currently holds a DevPod block:

```sh
grep -c "DevPod Start" ~/.ssh/config
chezmoi diff ~/.ssh/config
```

Expected: the grep finds at least one block, and the diff shows chezmoi wants to **delete** every `# DevPod Start` … `# DevPod End` section. That deletion is the bug.

- [ ] **Step 2: Move the managed content into a fragment**

Create `private_dot_ssh/private_config.d/private_10-dotfiles.conf` with the content of the file being deleted, plus a note about why it lives here now:

```
# Managed by chezmoi. ~/.ssh/config itself is deliberately NOT managed: DevPod
# appends a `# DevPod Start <workspace>` … `# DevPod End` block per workspace,
# and a chezmoi-owned config would delete every one of them on each apply.
# OpenSSH takes the first value it sees for any keyword, so the Include that
# pulls this file in has to stay above DevPod's blocks — see
# .chezmoiscripts/run_after_12-ensure-ssh-include.sh.

# First ssh use loads the key into the agent, so no manual ssh-add
# after login/reboot
AddKeysToAgent yes
```

Then `git rm private_dot_ssh/config`. Deleting a source file does not delete the target, which is what we want here: `~/.ssh/config` must survive with its DevPod blocks intact.

- [ ] **Step 3: Write the seeding script**

Create `.chezmoiscripts/run_after_12-ensure-ssh-include.sh`. Requirements, in order:

1. A plain `run_after_`, not a `run_onchange_`. This asserts an invariant about a file chezmoi does not manage, so it has to re-check on every apply — a `run_onchange_` would be recorded as done and stop noticing if the line were lost. Say this in a comment.
2. If `~/.ssh/config` does not exist, create it containing just the Include line, mode 0600, and create `~/.ssh` mode 0700 if needed.
3. If it exists and already contains the Include line, do nothing and print nothing. This is the common path and it runs on every apply.
4. If it exists without the Include line, prepend it. Preserve the file's existing mode and content, including the DevPod blocks. Write via a temporary file in the same directory and `mv` into place, so an interrupted run cannot truncate an existing SSH config.
5. **One-time migration.** The old managed content is exactly these three lines:

```
# First ssh use loads the key into the agent, so no manual ssh-add
# after login/reboot
AddKeysToAgent yes
```

   If that exact three-line block is present in `~/.ssh/config`, remove it — the fragment now provides it, and leaving both means a duplicate `AddKeysToAgent`. Match the whole block exactly; never delete a lone `AddKeysToAgent` line that the user may have written themselves with a different value.

The Include line to use, verbatim: `Include config.d/*.conf`. Relative paths in `Include` resolve against `~/.ssh`, so this needs no `$HOME` interpolation.

- [ ] **Step 4: Add the script to the lint list**

Append `.chezmoiscripts/run_after_12-ensure-ssh-include.sh` to the shellcheck arguments at `mise.toml:22`. Note this file has no `.tmpl` suffix, so the existing `.chezmoiscripts/*.sh.tmpl` glob does **not** cover it.

- [ ] **Step 5: Verify**

```sh
mise run lint
mise run verify
```

Then exercise every branch of the script in a scratch `HOME` (`mktemp -d`), never against the real one:
- no `~/.ssh` at all → creates `~/.ssh` 0700, `~/.ssh/config` 0600 containing only the Include line
- config exists with the Include line → unchanged, no output
- config exists without it, holding a DevPod block → Include prepended, DevPod block byte-identical afterwards, mode unchanged
- config exists holding the exact old three-line block → block removed, Include present, everything else untouched
- config exists holding a lone `AddKeysToAgent no` written by hand → that line survives untouched

Finally, on the real `$HOME`, confirm the fix: `chezmoi apply ~/.ssh` then `grep -c "DevPod Start" ~/.ssh/config` still finds the block.

- [ ] **Step 6: Commit**

```bash
git add -A private_dot_ssh .chezmoiscripts/run_after_12-ensure-ssh-include.sh mise.toml
git commit -m "fix: stop chezmoi deleting devpod's ssh config blocks"
```

---

### Task 2: `modify_` script for Claude Code settings

**Files:**
- Delete: `dot_claude/settings.json`
- Create: `dot_claude/modify_settings.json`
- Modify: `mise.toml:22`

**Interfaces:**
- Consumes: nothing from Task 1
- Produces: `~/.claude/settings.json`, whose managed keys come from this repo and whose unmanaged keys survive whatever Claude Code wrote

- [ ] **Step 1: Reproduce the failure**

```sh
chezmoi diff ~/.claude/settings.json
```

Expected: the diff shows chezmoi removing `"agentPushNotifEnabled": true` — a key Claude Code wrote at runtime that the source does not know about — and reordering others. That removal is the bug.

- [ ] **Step 2: Write the modify script**

Create `dot_claude/modify_settings.json`. chezmoi runs it with the file's current contents on stdin; whatever it prints on stdout becomes the new file.

The merge rule is **shallow, managed wins**: `jq -s '.[0] + .[1]'` with the on-disk contents first and the managed baseline second. Shallow is deliberate and must be explained in a comment — `enabledPlugins` and `extraKnownMarketplaces` are replaced wholesale so this repo stays authoritative over which plugins are on, while a top-level key the repo has never heard of (`agentPushNotifEnabled`) passes straight through.

Structure:

1. Managed baseline in a quoted heredoc, so nothing in the JSON is shell-expanded. Its content is the current `dot_claude/settings.json`, unchanged.
2. If stdin is empty — no file yet, the clean-HOME case — emit the baseline as-is.
3. If `jq` is not on `PATH`, emit stdin unchanged when there was stdin, and the baseline when there wasn't. Losing the merge is acceptable; failing the apply is not. Explain in a comment that a first clean-HOME apply writes files before the run script that installs mise's tools, so this path is normal rather than exceptional.
4. Otherwise merge with `jq` and print the result.

- [ ] **Step 3: The formatting trap — read this before testing**

CI asserts that a second `chezmoi apply` produces no drift. This script runs on every apply, so its output must be a fixed point: feeding its own output back in must produce a byte-identical result.

Two failure modes to prove absent:

- **jq vs heredoc.** In CI's clean HOME the first apply has no `jq` and writes the heredoc verbatim; the second apply has `jq` and re-emits the merge. If the heredoc's formatting differs from jq's output by even one space, CI goes red. Guarantee it by generating the heredoc content with `jq . dot_claude/settings.json` and pasting that, then assert byte-identity explicitly:

```sh
printf '' | ./dot_claude/modify_settings.json > /tmp/pass1.json
./dot_claude/modify_settings.json < /tmp/pass1.json > /tmp/pass2.json
diff /tmp/pass1.json /tmp/pass2.json   # must be empty
```

- **Key order.** `jq`'s `+` keeps the left operand's key order and appends keys only the right operand has. Feeding the merged output back in must therefore reproduce the same order. The byte-identity check above covers this; run it with a realistic input that has an extra runtime key, not just with the baseline.

- [ ] **Step 4: Add the script to the lint list**

Append `dot_claude/modify_settings.json` to the shellcheck arguments at `mise.toml:22`. shellcheck reads the shebang, so the `.json` extension does not stop it.

Also check whether `mise.toml:23`'s `jq empty dot_claude/settings.json` still refers to a file that exists. It will not — the source file is being deleted. Replace that check with one that validates the script's *output* is JSON, which is what actually matters now.

- [ ] **Step 5: Verify**

```sh
mise run lint
mise run verify
```

Plus, by hand:
- empty stdin, no `jq` on `PATH` → baseline emitted, valid JSON
- empty stdin, `jq` present → baseline emitted, byte-identical to the previous case
- stdin holding the live file with `agentPushNotifEnabled` → that key survives, `theme` and `skipDangerousModePermissionPrompt` take the managed values
- stdin holding a file whose `enabledPlugins` lists a plugin the repo does not → that plugin is gone, because the managed object replaces it wholesale
- the fixed-point check from Step 3, on all of the above

Finally, on the real `$HOME`: `chezmoi apply ~/.claude/settings.json`, then confirm `agentPushNotifEnabled` is still `true` in the applied file.

- [ ] **Step 6: Commit**

```bash
git add -A dot_claude mise.toml
git commit -m "fix: preserve claude code's runtime keys in settings.json"
```

---

### Task 3: Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Write the section**

Add a short section explaining the pattern once, since it now applies twice and will apply again. Place it after `## Dev containers` and before `## Working on this repo`. Cover, in continuous prose matching the README's voice:

- The problem: some files in `$HOME` are written by both this repo and by the program that reads them. Managing such a file statically means every `chezmoi apply` reverts the program's own writes.
- The two answers and when each applies. Owning a fragment beside the file (`~/.ssh/config.d/`) is right when the program appends to a file that supports includes. A `modify_` script is right when the file has no include mechanism and the two sets of keys have to share one document.
- The third case already in the repo, for contrast: `~/.devpod/config.yaml` is not managed at all, and `run_onchange_after_30-configure-devpod.sh.tmpl` drives the DevPod CLI instead.
- The constraint that binds `modify_` scripts here: they run on every apply, so their output must be a fixed point or CI's second-apply drift assertion fails.

- [ ] **Step 2: Verify and commit**

```sh
mise run check
git add README.md
git commit -m "docs: explain the co-owned config file pattern"
```

Do not push and do not open a pull request — that is the user's call.
