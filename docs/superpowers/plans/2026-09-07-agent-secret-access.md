# Agent Secret Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an agent session use a Proton Pass secret through a scoped,
expiring, audited agent token, without that secret reaching the agent's
transcript.

**Architecture:** Agent-readable secrets live in a separate `Agents` vault, so
the Proton agent token can be vault-scoped rather than maintained as a per-item
grant list. The agent reaches the secret through `fnox mcp`, an MCP server with
`exec` allowed and `get_secret` denied, rather than through a `Bash` call to
`pass-cli` — which removes the Bash grant entirely.

**Tech Stack:** chezmoi templates, POSIX sh, bats, mise, `pass-cli` 2.2.3,
`fnox` 1.35.1.

**Spec:** `docs/superpowers/specs/2026-09-07-agent-secret-access-design.md`

## Global Constraints

- **`--if-missing error` is mandatory on every fnox invocation.** Both the CLI
  and the MCP server fail *open* by default: a provider that cannot resolve
  produces a warning, the command runs with the variable unset, and the exit
  status is 0. Measured, see the spec's probe results.
- **`fnox check` is not a guard.** Against a broken provider it prints
  `✓ Configuration is healthy` and exits 0. Never use it to gate anything.
- **Permissions are an allow-list.** `allow: ["mcp__fnox__exec"]` is the
  load-bearing half; `deny: ["mcp__fnox__get_secret"]` documents the hazard. A
  deny alone breaks silently the day fnox ships a third tool.
- **The agent token lives in the `Dotfiles` vault, never in `Agents`.** A
  credential must not sit inside the vault it can read.
- **Everything in this repo is gated to the `personal` profile.**
- **Scripts under test are not executable in the source tree.** chezmoi sets the
  bit at apply time. Invoke through `sh`/`bash` in tests, never directly.
- **Every test must be mutation-proved.** Revert the behaviour the test claims to
  cover, re-run, and record the assertion failure you observed. A compile error
  or a missing symbol is not proof.
- **Local `/bin/sh` is bash; CI's is dash.** Local green is not authoritative.

---

## Prerequisites (done by hand, once — not automatable)

These are Ronald's to do, and no task below can be verified until they are.
Recorded here so the plan does not pretend they happen by themselves.

1. Create the `Agents` vault in Proton Pass.
2. Put the fizzy API token in it as an item titled `Fizzy`, with the value in a
   field named `api_token`.
3. Create the agent and scope it to that vault:

   ```sh
   pass-cli agent create fizzy --expiration 1m --vault Agents
   pass-cli agent access grant fizzy --vault-name Agents --role viewer
   ```

4. Put the resulting agent token in the **`Dotfiles`** vault as a note item
   titled `fizzy agent token`, with the token as its body. Task 1 fetches it
   from there.

## File Structure

**This repository (Tasks 1–2):**

- `home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl` — one added
  `restore` line placing the agent token.
- `home/dot_config/mise/config.toml.tmpl` — the `fnox` pin, gated to personal.
- `tests/restore-secrets.bats` — the token is restored, at mode 600.
- `tests/profiles.bats` — `fnox` is in a personal machine's tool list and absent
  from a work one.

**Where the container requirement is satisfied — no task needed.** The spec
requires that a container never gets the token and that the broker fails loudly
there. Both are already true and neither needs code: the restore script exits at
its own container guard (`if [ "$is_container" = "true" ]; then exit 0; fi`)
before reaching any `restore` line, and `--if-missing error` in Task 3's server
args turns a missing secret into an error rather than a command running with an
empty variable. Verified, not assumed — do not add a task for it, and do not
remove either guard thinking the other covers it.

**The consuming project (Task 3), not this repo:**

- `fnox.toml` — the secret reference.
- `.mcp.json` — the fnox MCP server.
- `.claude/settings.json` — the allow and the deny.

---

### Task 1: Restore the agent token

**Files:**
- Modify: `home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl:148` (after the last existing `restore` line)
- Test: `tests/restore-secrets.bats` (both the personal and the work case)

**Interfaces:**
- Consumes: the `restore()` helper already defined in that script —
  `restore "<vault item title>" "<absolute target path>" <mode> [profile]`.
  The fourth argument names the *only* profile that restores the item.
- Produces: the file `~/.config/pass-cli-agent-fizzy` at mode 600 on personal
  machines. Task 3's MCP server authenticates with it.

- [ ] **Step 1: Write the failing test**

Add to `tests/restore-secrets.bats`. The existing `setup()` seeds `$ITEMS` with
one file per vault item title, so the new item needs a fixture there too.

In `setup()`, alongside the other `printf` fixture lines:

```bash
	printf 'pat_agent_fake_token_value\n' >"$ITEMS/fizzy agent token"
```

Then the test itself:

```bash
# The agent token is a credential like any other here, so it gets the same
# treatment: 0600, and personal-only. It lives in the Dotfiles vault rather
# than in Agents deliberately — an agent's own credential must not sit inside
# the vault that credential can read, or a second agent could read the first's
# token and assume its identity.
@test "the fizzy agent token is restored, unreadable to anyone else" {
	run_restore
	[ "$status" -eq 0 ]
	token="$HOME/.config/pass-cli-agent-fizzy"
	[ -s "$token" ]
	[ "$(stat -c '%a' "$token")" = "600" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- bats --print-output-on-failure tests/restore-secrets.bats -f "fizzy agent token"`

Expected: FAIL on `[ -s "$token" ]`, because the script does not yet restore it.
Record the exact failure line.

- [ ] **Step 3: Write minimal implementation**

In `home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl`, immediately after
the `devpod project-tokens` line:

```sh
# The Proton agent token an MCP broker authenticates with. Personal-only for the
# same reason moshi and the tailnet are: an agent that can act with these
# credentials is a different proposition on a machine an employer owns.
#
# Its own vault is Dotfiles, not Agents, and that is the point rather than an
# accident: an agent's credential must not live in the vault that credential can
# read. With one agent that is merely circular; with two, either could read the
# other's token and assume its identity, and the per-agent audit trail stops
# meaning anything.
restore "fizzy agent token" "$HOME/.config/pass-cli-agent-fizzy" 600 personal
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- bats --print-output-on-failure tests/restore-secrets.bats`

Expected: PASS, and the whole file still green — the added fixture must not
disturb "writes every configured secret" or the re-tightening cases.

- [ ] **Step 5: Add the work-machine exclusion test**

**Do not assert on the rendered template text.** The profile marker is a runtime
argument to `restore()`, not a template conditional, so the line
`restore "fizzy agent token" … 600 personal` appears identically in a work render
and a personal one. Only the `profiles="…"` variable at the top differs. A test
grepping the rendered script for the path would pass on both roles and pin
nothing — which is precisely the defect class this repo keeps hitting.

The established pattern for this is render-and-run: `tests/profiles.bats`'s
tailnet pair renders the script for a role and then actually executes it,
asserting on behaviour. Follow that. Add to `tests/restore-secrets.bats`, which
already has the stub and fixtures:

```bash
# A gate that only ever adds is not a gate. The Work vault does not hold this
# item, and dotfiles-secrets-check derives what it watches from these same
# lines — so an ungated line would have a work machine reporting a missing
# secret every week, correctly and uselessly.
#
# Rendered for the work role and then run, because the marker is a runtime
# argument: the line itself is byte-identical in both renders, and only the
# profile set it is tested against differs.
@test "a work machine does not restore the fizzy agent token" {
	mkdir -p "$HOME/.config/chezmoi"
	printf '[data]\n    role = "work"\n' >"$HOME/.config/chezmoi/chezmoi.toml"
	work_script="$BATS_TEST_TMPDIR/restore-work.sh"
	render_template "$TMPL" "$work_script" "$BIN:$PATH"

	# The line is there either way — that is the point of asserting behaviour.
	grep -q 'restore "fizzy agent token"' "$work_script"

	run env HOME="$HOME" STUB_LOG="$STUB_LOG" PATH="$BIN:$PATH" \
		PASS_ITEM_DIR="$ITEMS" sh "$work_script"
	[ "$status" -eq 0 ]
	[ ! -e "$HOME/.config/pass-cli-agent-fizzy" ]
	# ...and the ungated secrets still arrived, so this is a gate rather than a
	# script that fell over before reaching the line.
	[ -s "$HOME/.config/gh/hosts.yml" ]
}
```

- [ ] **Step 6: Mutation-prove both tests**

```bash
# Drop the profile marker and confirm the work-machine test goes red. This is
# the mutation that matters: with the marker gone the line still renders the
# same, so only a behavioural test notices.
sed -i 's|\(restore "fizzy agent token".*600\) personal|\1|' \
  home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl
mise exec -- bats tests/restore-secrets.bats -f "work machine does not restore"
# Expected: FAIL on [ ! -e "$HOME/.config/pass-cli-agent-fizzy" ].
# If it PASSES, the test is vacuous — fix it before continuing.
git checkout -- home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl

# Remove the whole line and confirm the restore test goes red.
sed -i '/fizzy agent token/d' home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl
mise exec -- bats tests/restore-secrets.bats -f "fizzy agent token"
# Expected: FAIL on [ -s "$token" ]. Record it.
git checkout -- home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl
```

If either mutation leaves its test green, the test is not pinning anything — fix
the test before continuing.

- [ ] **Step 7: Verify the derived item list picked it up**

`dotfiles-secrets-check` derives what it watches from the `restore` lines, so
this should need no change. Confirm rather than assume:

Run: `mise exec -- bats tests/secrets-check.bats`

Expected: PASS. If a test asserts an exact item count, it will fail here — update
that count, and note in the commit that the list is derived so the count is the
only hand-kept part.

- [ ] **Step 8: Run lint and the full suite**

Run: `mise run lint && mise run test`

Expected: both green. `check-agreement.sh` reads these lines; a malformed one
surfaces here.

- [ ] **Step 9: Commit**

```bash
git add home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl \
        tests/restore-secrets.bats
git commit -m "feat: restore the fizzy agent token on personal machines"
```

---

### Task 2: Pin fnox

**Files:**
- Modify: `home/dot_config/mise/config.toml.tmpl` (inside a personal gate)
- Test: `tests/profiles.bats`

**Interfaces:**
- Consumes: `.chezmoitemplates/profiles` via
  `{{ if contains " personal " (includeTemplate "profiles" .) -}}`, the gating
  shape the `work`-gated `jira-cli` entry established.
- Produces: `fnox` on `PATH` on personal machines. Task 3's `.mcp.json` invokes
  it by bare name.

- [ ] **Step 1: Write the failing test**

Add to `tests/profiles.bats`, beside the existing `jira-cli` pair which tests the
mirror-image case:

```bash
# The agent secret broker. Personal-only, matching the token it authenticates
# with — a pin that landed everywhere would put the tool on machines that have
# no agent token to use it with.
@test "a personal machine gets fnox" {
	set_role personal
	run render_tools
	[ "$status" -eq 0 ]
	[[ "$output" == *"fnox"* ]]
}

@test "a work machine does not get fnox" {
	set_role work
	run render_tools
	[ "$status" -eq 0 ]
	[[ "$output" != *"fnox"* ]]
	# ...and the ungated tools are still there beside it.
	[[ "$output" == *"ripgrep"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- bats --print-output-on-failure tests/profiles.bats -f fnox`

Expected: the "personal machine gets fnox" case FAILS on the `==` assertion; the
work case passes vacuously for now. Record the failure.

- [ ] **Step 3: Write minimal implementation**

In `home/dot_config/mise/config.toml.tmpl`, following the shape of the existing
`work` gate:

```
{{ if contains " personal " (includeTemplate "profiles" .) -}}
# The secret broker an agent session reaches Proton Pass through. Personal-only,
# matching the agent token in run_after_14-restore-secrets.sh.tmpl — the tool is
# useless without it, and an agent acting with these credentials is a different
# proposition on a machine an employer owns.
#
# Pinned like every other tool here rather than installed by `mise use -g`,
# which would write into the file chezmoi owns.
fnox = "1.35.1"
{{ end -}}
```

Place it so the rendered TOML stays inside the `[tools]` table.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- bats --print-output-on-failure tests/profiles.bats`

Expected: PASS, including the existing "the rendered mise config parses as TOML"
case — which is what catches a gate placed outside the table.

- [ ] **Step 5: Mutation-prove**

```bash
# Remove the gate, keep the tool: the work-machine case must go red.
perl -0pi -e 's/\{\{ if contains " personal " \(includeTemplate "profiles" \.\) -\}\}\n(.*?fnox = "1\.35\.1"\n)\{\{ end -\}\}\n/$1/s' \
  home/dot_config/mise/config.toml.tmpl
mise exec -- bats tests/profiles.bats -f "work machine does not get fnox"
# Expected: FAIL — fnox now appears in a work machine's tool list.
git checkout -- home/dot_config/mise/config.toml.tmpl
```

- [ ] **Step 6: Verify against a clean HOME**

Run: `mise run verify`

Expected: `clean-HOME apply succeeded, all configured tools present`. This
actually installs fnox, so it also proves the pin resolves.

- [ ] **Step 7: Commit**

```bash
git add home/dot_config/mise/config.toml.tmpl tests/profiles.bats
git commit -m "feat: pin fnox on personal machines"
```

---

### Task 3: Wire the broker in the consuming project

**Files (in the fizzy project, not this repo):**
- Create: `fnox.toml`
- Create: `.mcp.json`
- Modify or create: `.claude/settings.json`

**Interfaces:**
- Consumes: `~/.config/pass-cli-agent-fizzy` from Task 1, `fnox` on `PATH` from
  Task 2.
- Produces: an `mcp__fnox__exec` tool available to agent sessions in that
  project, and no `mcp__fnox__get_secret`.

This task has no automated test. Nothing in the dotfiles repo can exercise it,
and the spec's probe results are the evidence for the behaviours it relies on.
Verify by hand, in the order below.

- [ ] **Step 1: Write `fnox.toml`**

```toml
[providers.protonpass]
type = "proton-pass"
agent_reason = "unspecified — caller did not set PROTON_PASS_AGENT_REASON"

[secrets]
FIZZY_API_TOKEN = { provider = "protonpass", value = "pass://Agents/Fizzy/api_token" }
```

The `agent_reason` fallback is deliberately unhelpful. It is what reaches
`pass-cli agent monitor` when a caller does not set
`PROTON_PASS_AGENT_REASON` per invocation, and wording it this way makes a lazy
caller visible in the audit log rather than invisible.

- [ ] **Step 2: Write `.mcp.json`**

```json
{
  "mcpServers": {
    "fnox": {
      "command": "fnox",
      "args": ["--if-missing", "error", "mcp"]
    }
  }
}
```

`--if-missing error` is in `args` rather than at a call site so it cannot be
omitted per-invocation. Without it the server returns `RAN with []` and
`isError: false` when the secret cannot be resolved.

- [ ] **Step 3: Write `.claude/settings.json`**

```json
{
  "permissions": {
    "allow": ["mcp__fnox__exec"],
    "deny": ["mcp__fnox__get_secret"]
  }
}
```

- [ ] **Step 4: Verify the happy path**

Session in that project, then through the MCP tool:

```
exec ["sh","-c","fizzy --version"]
```

Expected: fizzy runs and authenticates. If it reports a missing token, stop —
Task 1's restore has not happened on this machine, or the agent token has
expired.

- [ ] **Step 5: Verify it fails closed**

Temporarily point `fnox.toml`'s `value` at a nonexistent item, then call `exec`
again.

Expected: a JSON-RPC error, **not** a successful call with an empty variable. If
the command runs, `--if-missing error` is not reaching the server — check
`.mcp.json`. Restore the correct reference afterwards.

- [ ] **Step 6: Verify the deny holds**

Attempt `get_secret` for `FIZZY_API_TOKEN`.

Expected: refused by the harness. If it returns the plaintext, the deny is not
in effect and nothing else in this design is worth anything — stop and fix it
before using the broker for real.

- [ ] **Step 7: Verify the audit trail**

```sh
pass-cli agent monitor fizzy
```

Expected: entries for the reads above, carrying whatever `agent_reason` was in
force. If they read `unspecified — caller did not set…`, that is the fallback
working as designed and a prompt to set `PROTON_PASS_AGENT_REASON` per
invocation.

- [ ] **Step 8: Commit, in the fizzy project**

```bash
git add fnox.toml .mcp.json .claude/settings.json
git commit -m "feat: broker the fizzy API token through fnox mcp"
```

---

## After the work ships

Per `CLAUDE.md`, spec and plan pairs are working documents. When Task 3 is
verified:

1. Move the durable reasoning into `docs/design-notes.md` — the `Agents` vault
   boundary and why `Dotfiles` was rejected, why the agent token lives in
   `Dotfiles`, the allow-list-not-deny-list argument, and the probe results
   showing both fnox paths fail open by default.
2. Delete this plan and its spec.
3. Add the user-facing *what* to `README.md`: that agent sessions reach secrets
   through an `Agents` vault and an expiring token, and that the token needs
   renewing monthly with `pass-cli agent renew`.

The expiry is the part most likely to be forgotten. `dotfiles-secrets-check`
already warns on the bootstrap PAT's expiry; extending that warn tier to the
agent token is worth doing at the same time, and is not covered by any task here.
