# Working in this repo

Personal dotfiles managed with [chezmoi](https://chezmoi.io). See `README.md` for
full layout. This file cover one thing easy get wrong: secrets.

## Secrets

Secrets live in the **Dotfiles vault in Proton Pass**, not in this repo. There
are no `.age` blobs, no age identity, no `encrypted_` files. Two scripts derive
everything:

- `run_after_13`-era `~/.local/bin/proton-ssh-load` — loads the three SSH keys
  into the ssh-agent. They never touch disk.
- `.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl` — writes the file-shaped
  secrets (`sops age keys`, `gh hosts.yml`, `sugarrush config`,
  `devpod dotfiles-env`) to their targets at `0600`, fetching every apply and
  rewriting only on change so a rotation in the vault propagates.

**Adding a secret:** create a note item in the Dotfiles vault whose body is the
file content, then add one `restore "<item title>" "<target>" 600` line to
`run_after_14`. Nothing goes in `.chezmoiignore` — there is no ciphertext in the
tree to hide.

**Auth is a scoped token.** `PROTON_PASS_PERSONAL_ACCESS_TOKEN` (viewer on the
Dotfiles vault only) reaches the scripts through the environment and is cached at
`~/.config/pass-cli-bootstrap-pat`, `0600`. Pass it through the environment,
never as `--personal-access-token` — a flag value shows up in `ps`. This is what
makes non-interactive apply work, and it is also why disk access alone now reads
the vault: state it plainly, do not paper over it.

Containers get nothing from Proton by design — no `pass-cli`, no session. Git
there uses the forwarded ssh-agent; the DevPod token arrives as an env file.

## Rules

- Never commit a plaintext secret. CI runs gitleaks on history. Nothing secret
  belongs in the tree at all now — if a secret needs to exist, it goes in the
  vault.
- Never edit chezmoi-managed file in `$HOME` direct — edit source
  (`chezmoi source-path <file>`), run `chezmoi apply`. Source tree sit under
  `home/` (`.chezmoiroot`), so `source-path` return path below `home/`.
- Repo-only files (docs, `setup`, `mise.toml`, this file) live *outside*
  `home/`. Anything inside `home/` is source state and get applied into `$HOME`
  unless `.chezmoiignore` say otherwise.
- Verify changes against clean HOME way CI does before pushing:
  `HOME="$(mktemp -d)" chezmoi apply --source "$PWD" </dev/null`.