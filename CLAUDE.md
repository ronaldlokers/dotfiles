# Working in this repo

Personal dotfiles managed with [chezmoi](https://chezmoi.io). See `README.md` for
full layout. This file cover one thing easy get wrong: secrets.

## Secrets

Secrets live in the **Dotfiles vault in Proton Pass**, never in this repo. No
`.age` blobs, no age identity, no `encrypted_` files — there is no ciphertext in
the tree, so nothing about secrets belongs in `.chezmoiignore`.

The rules, which is all this file is for:

- **Never pass the token as a flag.** `PROTON_PASS_PERSONAL_ACCESS_TOKEN` goes
  through the environment, never as `--personal-access-token` — a flag value
  show up in `ps`. `tests/proton-ssh-load.bats` enforce this; do not weaken it.
- **Adding a secret:** note item in the Dotfiles vault whose body is the file
  content, then one `restore "<title>" "<target>" 600` line in
  `run_after_14-restore-secrets.sh.tmpl`.
- **A failed or empty fetch must leave the existing file alone.** Stale beats
  truncated — writing an empty fetch through destroy the only copy on the
  machine, and exit 0 doing it. `tests/restore-secrets.bats` pin both paths.
- **Containers get nothing from Proton by design** — no `pass-cli`, no session.
  Git there use the forwarded ssh-agent; the DevPod token arrive as an env file.
  Do not "fix" a container by reaching for the vault.

Where the detail live, so it is not restated here: `README.md` for which secret
maps to which vault item and target, `docs/design-notes.md` for why it works
this way — including the cost that disk access alone now read the vault, which
was accepted deliberately and should not be papered over.

## Rules

- Never commit a plaintext secret. CI runs gitleaks on history. Nothing secret
  belongs in the tree at all now — if a secret needs to exist, it goes in the
  vault.
- Never edit chezmoi-managed file in `$HOME` direct — edit source
  (`chezmoi source-path <file>`), run `chezmoi apply`. Source tree sit under
  `home/` (`.chezmoiroot`), so `source-path` return path below `home/`.
- Repo-only files (docs, `setup`, `mise.toml`, `tests/`, `scripts/`, this file)
  live *outside* `home/`. Anything inside `home/` is source state and get applied
  into `$HOME` unless `.chezmoiignore` say otherwise.
- Verify changes against clean HOME way CI does before pushing:
  `HOME="$(mktemp -d)" chezmoi apply --source "$PWD" </dev/null`, or
  `mise run verify` which do the same with the XDG vars cleared.
- Run `mise run test` too. Clean-HOME apply only ever walk the empty-machine
  path, so it prove nothing about a script meeting state that already exist — a
  `~/.ssh/config` with a `Host` block above the `Include`, a secret fetch that
  come back empty. Those branch live in `tests/*.bats`.
- Script under test are not executable in the source tree — chezmoi run them
  itself. Invoke through `sh`/`bash` in a test, not directly.
- `mise run check` is all of it: lint, test, gitleaks, verify, shells.
- **Spec and plan pairs are working documents, not records.** If a workflow
  writes them under `docs/superpowers/`, prune both halves once the work ships —
  precedent is 22af1cd, which dropped eight plans and seven specs in one go, and
  1c47f04, which dropped the last three and left the directory empty. They
  describe the tree as it was going to be, so once it is, they can only be
  wrong; the design *reasoning* worth keeping belongs in `docs/design-notes.md`,
  and what actually happened is in the commit. Leaving them is how
  `.chezmoitemplates/signing-pubkey` ended up with three files describing a
  `protonPass` call it no longer makes.
- **Put the reasoning in `docs/design-notes.md`, not only in the commit or the
  code comment.** The README says what, design-notes says why, and a review on
  2026-08-03 found sixteen PRs' worth of design decisions — the warn tier, the
  state file, retirement-rather-than-deletion, assert-agreement-in-a-script —
  with none of them in the file that exists to outlive the code.