# Working in this repo

Personal dotfiles managed with [chezmoi](https://chezmoi.io). See `README.md` for
the full layout. This file covers the one thing that's easy to get wrong: secrets.

## Secrets and encryption

Secrets are age-encrypted with a dedicated dotfiles keypair. The recipient is in
`.chezmoi.toml.tmpl`; the identity lives at `~/.config/chezmoi/key.txt` and is
itself passphrase-protected (committed as `key.txt.age`, backup in Proton Pass).

**Do not use `chezmoi add --encrypt`.** It creates an `encrypted_` source file that
chezmoi decrypts *at apply time*, which needs the age identity. Non-interactive
`chezmoi apply` — `devpod up`, CI's clean-HOME bootstrap — runs with no passphrase
and no TTY, so the identity isn't unlocked and apply fails on the missing key.

**Instead, follow the existing pattern** (used by the SSH signing key, the sops age
keys, and the `gh` token):

1. Store the secret as a plain `<name>.age` blob in the source tree, encrypted to
   the repo's age recipient (e.g. `chezmoi encrypt --output <path>.age <file>`, or
   reuse an existing blob's format). Use a `private_` prefix so the decrypted target
   ends up `0600`.
2. Add the blob's **literal target path** (with the `.age` suffix) to
   `.chezmoiignore`, so chezmoi doesn't copy the raw ciphertext into `$HOME`.
3. Decrypt it in `.chezmoiscripts/run_before_00-unlock-secrets.sh.tmpl`, inside the
   `if [ -f "$key" ]` guard, mirroring the existing blocks. Write to the real target
   and `chmod 600`.

This keeps non-interactive apply working: with no key, the guard is false and the
whole secret step is skipped. A later interactive `chezmoi apply` unlocks the key
and finishes the job. This is intentional — a fresh container has no secrets until
you run `chezmoi apply` from a real shell once.

## Rules

- Never commit a plaintext secret. CI runs gitleaks on history; verify any new `.age`
  blob is ciphertext (`-----BEGIN AGE ENCRYPTED FILE-----`) before committing.
- Never edit a chezmoi-managed file in `$HOME` directly — edit its source
  (`chezmoi source-path <file>`) and run `chezmoi apply`.
- Repo-only files (docs, `setup`, this file) must be listed in `.chezmoiignore` so
  they aren't applied into `$HOME`.
- Verify changes against a clean HOME the way CI does before pushing:
  `HOME="$(mktemp -d)" chezmoi apply --source "$PWD" </dev/null`.
