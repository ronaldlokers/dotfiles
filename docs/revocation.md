# Revocation

What to do when a credential this repo manages has leaked, might have leaked,
or needs replacing anyway.

The point of writing it down is that the moment you need it is the worst
possible moment to be working out which of nine credentials matter, which of
them can be re-issued, and which one takes the others with it. `README.md` says
where each secret lives; this says what to do about it.

## Read this first

**One credential is not like the others.** Everything below can be revoked and
re-minted except **`sops age keys`**. A new age key can be generated at any
time, but nothing already encrypted to the old one can ever be read again — and
in this setup that includes every SOPS-encrypted file in the
[homelab](https://github.com/ronaldlokers/homelab) repository. Losing it is not
an inconvenience, it is data loss. That is what
[the offline copy](../README.md#the-offline-copy) exists for.

**Re-keying is not revocation.** Re-encrypting a file to a new key protects it
from that point on. It does nothing about ciphertext an attacker already holds:
they can still decrypt what they copied, with the old key, forever. If a key is
exposed rather than merely old, the credentials *inside* the files it protected
have to be re-issued at their source too. Those are two separate jobs and the
second is the larger one.

**Assume public means permanent.** Anything that reached a public repository has
been cloned, mirrored and indexed. Rewriting history stops future casual
discovery; it does not un-publish.

## The inventory

Every credential this repo touches, what it opens, and whether it can be
replaced.

| Credential | Lives in | Reaches | Re-issuable? |
| --- | --- | --- | --- |
| **Proton bootstrap PAT** | `~/.config/pass-cli-bootstrap-pat`, vault item `bootstrap PAT` | the whole vault, therefore everything below | yes — see [Renewing the bootstrap PAT](../README.md#renewing-the-bootstrap-pat) |
| **retired bootstrap PATs** | `~/.config/pass-cli-bootstrap-pat.rejected` on any machine that had one refused | whatever that token still opens — the same whole vault, if it was refused for a reason other than revocation | n/a — delete it, or revoke the token it holds |
| **`sops age keys`** | vault, `~/.config/sops/age/keys.txt` | every SOPS-encrypted file in the homelab repo | **no** |
| **git signing key** | vault (ssh-key item), the ssh-agent | commit signatures | yes, with an `allowed_signers` boundary |
| **ssh auth key** | vault (ssh-key item), the ssh-agent | every forge and host that trusts it | yes, painfully — every `authorized_keys` |
| **AUR ssh key** | vault (ssh-key item) | AUR package publishing | yes |
| **`gh` token** | vault item `gh hosts.yml` → `~/.config/gh/hosts.yml` | GitHub as you: `gist, read:org, repo, workflow` | yes |
| **DevPod container PAT** | vault item `devpod dotfiles-env` | GitHub API rate limit only, no scopes | yes |
| **DevPod project tokens** | vault item `devpod project-tokens` | one repo each, fine-grained | yes |
| **sugarrush config** | vault item `sugarrush config` | the sugarrush service | yes |
| **`RENOVATE_TOKEN`** | GitHub Actions secret | this repo, as the Renovate bot | yes |
| **Moshi pairing secret** | `moshi-hook` file store on the host | drives Claude Code on this machine from a paired phone | yes |

`dotfiles-status` tells you the health of the first two. Nothing enumerates the
rest automatically, because nothing can: half of them live in services this
repo has no API to.

## If the Proton bootstrap PAT leaked

This is the worst case that is still recoverable, because that token reads the
entire vault.

1. **Revoke it first**, before anything else. A web login is required — Proton
   refuses `pat` subcommands while the session came from a PAT:
   ```sh
   pass-cli login
   pass-cli pat list
   pass-cli pat delete --personal-access-token-name <name>
   ```
2. Mint a replacement and put it in `~/.config/pass-cli-bootstrap-pat` (0600) on
   each machine, plus the `bootstrap PAT` vault item. Check each machine for a
   `~/.config/pass-cli-bootstrap-pat.rejected` while you are there and delete
   it: `proton-ssh-load` renames rather than deletes a token Proton refused, so
   that a ten-second outage cannot destroy the only copy a machine has — which
   means a refused token can sit there indefinitely, and "refused" is not the
   same as "revoked".
3. Update `bootstrap_pat_expiry` and the README date — `mise run lint` asserts
   they agree.
4. **Then treat everything in the inventory as exposed**, in the order below.
   Whoever had that token had read access to all of it for as long as they had
   the token.

## If the age key leaked

1. Generate replacements: `age-keygen -o new.key`, one per environment.
2. Add the new public keys to `.sops.yaml` **alongside** the old ones and re-key
   every encrypted file. Both keys decrypt, so nothing breaks and this half can
   be merged on its own.
3. Update the consuming cluster's `sops-age` secret; watch a reconcile succeed.
4. Only then remove the old recipients and re-key again.
5. **Re-issue the credentials inside those files.** Step 2 protects them going
   forward; it does nothing about ciphertext already copied.

The full procedure, with the exact commands and the reason `--config` has to
precede the subcommand, is in the homelab repo's `docs/security.md`, under
"Rotating an age key".

## If the git signing key leaked

Covered step by step in
[Rotating the signing key](../README.md#rotating-the-signing-key). The part
worth repeating: keep the old public key in `allowed_signers` with a
`valid-before` boundary. Git checks a signature against the *commit's*
timestamp, so a bounded retired key keeps verifying its own history while being
unable to vouch for anything newer. Removing it outright turns every commit it
ever signed into an unverifiable one.

## If an ssh key leaked

The auth key is the painful one, because nothing here knows where it is
trusted. Mint a new key, add it to the vault, load it, then work through every
`authorized_keys` and every forge that has the old one — GitHub, any server, any
CI. Remove the old key from the vault last, so you are not locked out midway.

## If the Moshi pairing secret leaked

Whoever holds it can drive Claude Code on this machine: approve tool calls,
answer prompts, and read whatever the agent is doing. It is not a vault
credential, but the agent it controls has your shell.

1. **Remove the device from the tailnet first.** sshd answers only on the
   Tailscale address, so this cuts access immediately and takes one click —
   before any key or secret is touched.
2. Revoke the SSH pairing on the host:
   ```sh
   moshi-hook host list             # find the pairing id
   moshi-hook host revoke <id>      # removes its key from authorized_keys
   ```
3. Unpair the host in the Moshi app, which invalidates the daemon secret.
4. Re-pair when you want it back — Easy Pair does both halves at once:
   ```sh
   moshi-hook host setup --host <magicdns-name> --port 22 --user "$USER"
   moshi-hook status
   ```

Losing the phone is the likelier version of this than the secret leaking on
its own, which is why the order above starts with the tailnet rather than with
the credential. Two things get the phone in — the SSH key in
`authorized_keys` and the daemon secret — and they are revoked separately, so
doing only one leaves the other live.

## If a GitHub token leaked

All three are cheap to replace and none of them is worth agonising over:

- **`gh` token** — `gh auth refresh` or mint a new one in GitHub's settings,
  update the `gh hosts.yml` vault item, `chezmoi apply`.
- **DevPod container PAT** — no scopes at all; it exists only to lift the
  anonymous API rate limit. Mint, update `devpod dotfiles-env`, apply.
- **DevPod project tokens** — fine-grained and per-repo. Replace the affected
  line in `devpod project-tokens`, apply.

Revoke the old one at GitHub rather than only replacing it locally. A token that
still works is still a token, wherever the copy you know about went.

## Checking your work

```sh
dotfiles-status                 # recorded health, instant, no network
dotfiles-secrets-check          # the live answer, every item and template
dotfiles-secrets-restore <file> # prove the offline copy still reads back
mise run secrets                # gitleaks over the full history
```

The last one matters after any incident that involved a repository: it is the
check that would have caught the credential being committed in the first place,
and its rules are only as good as the shapes they know. If the leaked thing had
a format `.gitleaks.toml` does not match, add a rule for it while the failure is
fresh.
