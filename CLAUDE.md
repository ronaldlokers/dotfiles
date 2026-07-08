# Working in this repo

Personal dotfiles managed with [chezmoi](https://chezmoi.io). See `README.md` for
full layout. This file cover one thing easy get wrong: secrets.

## Secrets and encryption

Secrets age-encrypted with dedicated dotfiles keypair. Recipient in
`.chezmoi.toml.tmpl`; identity lives at `~/.config/chezmoi/key.txt`, itself
passphrase-protected (committed as `key.txt.age`, backup in Proton Pass).

**Don't use `chezmoi add --encrypt`.** Creates `encrypted_` source file chezmoi
decrypts *at apply time* — needs age identity. Non-interactive `chezmoi apply` —
`devpod up`, CI's clean-HOME bootstrap — runs no passphrase, no TTY, identity
never unlocked, apply fails on missing key.

**Instead, follow existing pattern** (used by SSH signing key, sops age keys,
`gh` token):

1. Store secret as plain `<name>.age` blob in source tree, encrypted to repo's
   age recipient (e.g. `chezmoi encrypt --output <path>.age <file>`, or reuse
   existing blob's format). Use `private_` prefix so decrypted target ends up
   `0600`.
2. Add blob's **literal target path** (with `.age` suffix) to
   `.chezmoiignore`, so chezmoi skip copying raw ciphertext into `$HOME`.
3. Decrypt in `.chezmoiscripts/run_before_00-unlock-secrets.sh.tmpl`, inside
   `if [ -f "$key" ]` guard, mirroring existing blocks. Write to real target,
   `chmod 600`.

Keeps non-interactive apply working: no key → guard false → whole secret step
skipped. Later interactive `chezmoi apply` unlocks key, finishes job.
Intentional — fresh container has no secrets until `chezmoi apply` run from
real shell once.

## Rules

- Never commit plaintext secret. CI runs gitleaks on history; verify any new
  `.age` blob is ciphertext (`-----BEGIN AGE ENCRYPTED FILE-----`) before
  committing.
- Never edit chezmoi-managed file in `$HOME` direct — edit source
  (`chezmoi source-path <file>`), run `chezmoi apply`.
- Repo-only files (docs, `setup`, this file) must list in `.chezmoiignore` so
  they skip apply into `$HOME`.
- Verify changes against clean HOME way CI does before pushing:
  `HOME="$(mktemp -d)" chezmoi apply --source "$PWD" </dev/null`.