#!/usr/bin/env bats
#
# scripts/check-agreement.sh asserts the facts this repo states in more than one
# place still agree. It used to be five shell one-liners embedded in TOML
# strings in mise.toml, which meant nothing could test them — and one was wrong.
#
# The container-marker check had no floor on how many files its scan found, so a
# moved directory or a changed spelling would have made it pass by scanning
# nothing at all: reporting agreement for exactly the reason that should have
# alarmed it. The vault-name check right beside it had that guard; this one did
# not, and no test could have noticed either way.
#
# Every case here builds a minimal fixture tree, introduces one drift, and
# asserts the check finds it. A checker that cannot fail is not a checker.

bats_require_minimum_version 1.5.0

setup() {
	SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-agreement.sh"
	TREE="$BATS_TEST_TMPDIR/tree"
	make_tree
}

# The smallest tree that satisfies every check, so each test can break exactly
# one thing and know that is what it is reading.
make_tree() {
	mkdir -p "$TREE/home/dot_config/mise" \
		"$TREE/home/dot_local/bin" \
		"$TREE/home/.chezmoiscripts" \
		"$TREE/home/.chezmoitemplates" \
		"$TREE/home/dot_claude/skills/graphify"

	printf '2.70.5\n' >"$TREE/.chezmoiversion"
	printf 'chezmoi = "2.70.5"\n"pipx:graphifyy" = "0.9.30"\n' \
		>"$TREE/home/dot_config/mise/config.toml.tmpl"
	printf 'chezmoi = "2.70.5"\n' >"$TREE/mise.toml"
	printf '0.9.30' >"$TREE/home/dot_claude/skills/graphify/dot_graphify_version"

	# The vault is named in one place — .chezmoitemplates/vault-name — and every
	# script reads it through the facts file rather than spelling it out.
	printf 'vault="${DOTFILES_VAULT:-Dotfiles}"\n' \
		>"$TREE/home/.chezmoiscripts/restore.sh.tmpl"
	printf 'vault="${DOTFILES_VAULT:-Dotfiles}"\n' \
		>"$TREE/home/dot_local/bin/executable_a"
	printf 'vault="${DOTFILES_VAULT:-Dotfiles}"\n' \
		>"$TREE/home/dot_local/bin/executable_vault_c"
	printf '{{ if contains " work " x }}Work{{ else }}Dotfiles{{ end }}' \
		>"$TREE/home/.chezmoitemplates/vault-name"
	mkdir -p "$TREE/home/dot_config/dotfiles"
	printf 'DOTFILES_VAULT="{{ includeTemplate "vault-name" . }}"\n' \
		>"$TREE/home/dot_config/dotfiles/machine.env.tmpl"
	# The cached bootstrap PAT's path, written by proton-ssh-load and read by
	# dotfiles-secrets-check.
	printf 'pat_file="$HOME/.config/pass-cli-bootstrap-pat"\n' \
		>"$TREE/home/dot_local/bin/executable_pat_a"
	printf 'pat_file="$HOME/.config/pass-cli-bootstrap-pat"\n' \
		>"$TREE/home/dot_local/bin/executable_pat_b"
	# ...and the retirement the second one performs, plus the inventory that
	# has to know about the file it leaves behind.
	printf 'mv -f "$pat_file" "$pat_file.rejected"\n' \
		>>"$TREE/home/dot_local/bin/executable_pat_b"
	mkdir -p "$TREE/docs"
	printf 'a rejected token is left at `~/.config/pass-cli-bootstrap-pat.rejected`\n' \
		>"$TREE/docs/revocation.md"
	printf '{{ includeTemplate "vault-name" . }}/some item/public_key\n' \
		>"$TREE/home/.chezmoitemplates/signing-pubkey"

	# Three files probing both markers: the template and the two scripts that
	# re-ask at run time.
	for f in "$TREE/home/.chezmoitemplates/is-container" \
		"$TREE/home/dot_local/bin/executable_b" \
		"$TREE/home/dot_local/bin/executable_c"; do
		printf 'if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then :; fi\n' >"$f"
	done

	# The lint task's shellcheck invocation, and three files it covers: one by
	# name, one through a glob, and `setup`, which is only recognisable as a
	# shell script by its shebang.
	mkdir -p "$TREE/scripts"
	printf '#!/bin/sh\n' >"$TREE/setup"
	printf '#!/bin/sh\n' >"$TREE/scripts/check-agreement.sh"
	printf '\t"shellcheck --severity=warning setup home/.chezmoiscripts/*.sh.tmpl scripts/check-agreement.sh",\n' \
		>>"$TREE/mise.toml"

	printf 'bootstrap_pat_expiry="2027-07-29"\n' \
		>"$TREE/home/dot_local/bin/executable_dotfiles-secrets-check"
	printf -- '- **The bootstrap token expires** 2027-07-29. After that...\n' \
		>"$TREE/README.md"
}

run_check() {
	run sh "$SCRIPT" "$TREE" "$@"
}

@test "a tree in agreement passes, and passes silently" {
	run_check
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "--help explains itself and checks nothing" {
	run sh "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: scripts/check-agreement.sh"* ]]
}

@test "an unknown check name is refused rather than silently skipped" {
	run_check no-such-check
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown check"* ]]
}

# --- chezmoi pins ------------------------------------------------------------

@test "a machine pin ahead of the version floor is caught" {
	printf 'chezmoi = "2.71.0"\n"pipx:graphifyy" = "0.9.30"\n' \
		>"$TREE/home/dot_config/mise/config.toml.tmpl"
	run_check chezmoi-pins
	[ "$status" -ne 0 ]
	[[ "$output" == *"disagree"* ]]
}

@test "a repo pin nobody moved is caught too" {
	printf 'chezmoi = "2.69.0"\n' >"$TREE/mise.toml"
	run_check chezmoi-pins
	[ "$status" -ne 0 ]
}

# The scan finding nothing must be a failure, not a pass. This is the shape of
# the bug the container check actually had.
@test "a missing chezmoi version file fails rather than passing vacuously" {
	rm "$TREE/.chezmoiversion"
	run_check chezmoi-pins
	[ "$status" -ne 0 ]
	[[ "$output" == *"could not read"* ]]
}

# --- vault name --------------------------------------------------------------

# Was "a rename that misses one script": under one vault per role, a script
# that names any vault at all is the drift, whatever name it picked.
@test "a script that stops reading the facts file is caught" {
	printf 'vault="Personal"\n' >"$TREE/home/dot_local/bin/executable_a"
	run_check vault-name
	[ "$status" -ne 0 ]
	[[ "$output" == *"hardcode"* ]]
}

# The signing key's public half is read by a template rather than a script, so
# it takes the vault from vault-name directly. Spelling a vault into the URI
# instead is the same drift wearing template clothes: it would keep working on a
# personal machine and read the personal signing key on a work one.
@test "a signing-pubkey URI that names a vault itself is caught" {
	printf 'pass://Personal/some item/public_key\n' \
		>"$TREE/home/.chezmoitemplates/signing-pubkey"
	run_check vault-name
	[ "$status" -ne 0 ]
	[[ "$output" == *"signing-pubkey"* ]]
}

@test "finding no vault references at all is a failure, not agreement" {
	rm -rf "$TREE/home/.chezmoiscripts" "$TREE/home/.chezmoitemplates"
	printf 'nothing here\n' >"$TREE/home/dot_local/bin/executable_a"
	run_check vault-name
	[ "$status" -ne 0 ]
	[[ "$output" == *"the scan broke"* ]]
}

# --- container markers -------------------------------------------------------

@test "a file probing only one marker is caught" {
	printf 'if [ -f /.dockerenv ]; then :; fi\n' \
		>"$TREE/home/dot_local/bin/executable_b"
	run_check container-markers
	[ "$status" -ne 0 ]
	[[ "$output" == *"only one container marker"* ]]
}

@test "a new file probing only the podman marker is caught" {
	printf 'if [ -f /run/.containerenv ]; then :; fi\n' \
		>"$TREE/home/dot_local/bin/executable_new"
	run_check container-markers
	[ "$status" -ne 0 ]
}

# The defect this whole file exists for. With no floor, a scan that matches
# nothing runs the loop zero times and reports agreement — so the check passed
# most loudly at the moment it had stopped working. The old inline version did
# exactly this.
@test "a scan that finds nothing is a failure, not agreement" {
	rm "$TREE/home/.chezmoitemplates/is-container" \
		"$TREE/home/dot_local/bin/executable_b" \
		"$TREE/home/dot_local/bin/executable_c"
	run_check container-markers
	[ "$status" -ne 0 ]
	[[ "$output" == *"the scan broke"* ]]
}

@test "losing one of the three probes is a failure too" {
	rm "$TREE/home/dot_local/bin/executable_c"
	run_check container-markers
	[ "$status" -ne 0 ]
	[[ "$output" == *"expected at least 3"* ]]
}

# --- PAT expiry --------------------------------------------------------------

@test "a renewed token recorded in only one place is caught" {
	printf 'bootstrap_pat_expiry="2028-07-29"\n' \
		>"$TREE/home/dot_local/bin/executable_dotfiles-secrets-check"
	run_check pat-expiry
	[ "$status" -ne 0 ]
	[[ "$output" == *"disagrees"* ]]
}

@test "a README that stops naming a date is caught" {
	printf 'no date here\n' >"$TREE/README.md"
	run_check pat-expiry
	[ "$status" -ne 0 ]
	[[ "$output" == *"could not find"* ]]
}

# --- graphify pin ------------------------------------------------------------

@test "a tool bump without re-vendoring the skill is caught" {
	printf 'chezmoi = "2.70.5"\n"pipx:graphifyy" = "0.9.32"\n' \
		>"$TREE/home/dot_config/mise/config.toml.tmpl"
	run_check graphify-pin
	[ "$status" -ne 0 ]
	[[ "$output" == *"re-vendor"* ]]
}

@test "a vendored skill with no version file is caught" {
	rm "$TREE/home/dot_claude/skills/graphify/dot_graphify_version"
	run_check graphify-pin
	[ "$status" -ne 0 ]
}

# --- reporting ---------------------------------------------------------------

# One run tells you everything that drifted. Stopping at the first failure means
# fixing one, running again, finding the next — and this runs in CI, where each
# round trip is minutes.
@test "every drift is reported, not just the first" {
	printf 'chezmoi = "2.71.0"\n"pipx:graphifyy" = "0.9.30"\n' \
		>"$TREE/home/dot_config/mise/config.toml.tmpl"
	printf 'vault="Personal"\n' >"$TREE/home/dot_local/bin/executable_a"
	run_check
	[ "$status" -ne 0 ]
	[ "$(printf '%s\n' "$output" | grep -c '^FAIL')" -eq 2 ]
}

@test "a root that does not exist is an error, not a pass" {
	run sh "$SCRIPT" "$BATS_TEST_TMPDIR/nowhere"
	[ "$status" -eq 2 ]
	[[ "$output" == *"no such directory"* ]]
}

# --- the cached PAT's path ---------------------------------------------------
#
# Two scripts now name it: proton-ssh-load writes it, dotfiles-secrets-check
# reads it to establish a session before calling its absence a fault. A rename
# that missed one would put that check straight back to false-alarming every
# week, which is the bug that made it read the file at all.

@test "a PAT path that disagrees between the two scripts is caught" {
	printf 'pat_file="$HOME/.config/somewhere-else"\n' \
		>"$TREE/home/dot_local/bin/executable_pat_b"
	run_check pat-path
	[ "$status" -ne 0 ]
	[[ "$output" == *"disagrees"* ]]
}

@test "finding no PAT path at all is a failure, not agreement" {
	rm -f "$TREE/home/dot_local/bin/executable_pat_a" \
		"$TREE/home/dot_local/bin/executable_pat_b"
	run_check pat-path
	[ "$status" -ne 0 ]
	[[ "$output" == *"the scan broke"* ]]
}

# --- every shell script is shellchecked --------------------------------------
#
# The lint task names its targets by hand, so a script added later is simply
# absent from it — silently, and with nothing else in the repo to notice.
# scripts/check-shells.sh was exactly that: tested by its own bats file, never
# once shellchecked. The list is worth keeping by hand (globs would drag in
# vendored trees), so this is what stops it going stale.

@test "a shell script nobody shellchecks is caught" {
	printf '#!/bin/sh\n' >"$TREE/scripts/orphan.sh"
	run_check shellcheck-targets
	[ "$status" -ne 0 ]
	[[ "$output" == *"orphan.sh"* ]]
}

# A script is not always recognisable by its name: `setup` has no extension and
# only its shebang says what it is.
@test "a shebang-only script nobody shellchecks is caught too" {
	printf '#!/usr/bin/env bash\n' >"$TREE/scripts/bootstrap"
	run_check shellcheck-targets
	[ "$status" -ne 0 ]
	[[ "$output" == *"bootstrap"* ]]
}

# The same floor every other scan here has: a moved directory must not pass by
# finding nothing to disagree with.
@test "finding almost no shell scripts at all is a failure, not agreement" {
	rm -f "$TREE/setup" "$TREE/scripts/check-agreement.sh"
	run_check shellcheck-targets
	[ "$status" -ne 0 ]
	[[ "$output" == *"the scan broke"* ]]
}

@test "a lint task with no shellcheck invocation is a failure, not agreement" {
	printf 'chezmoi = "2.70.5"\n' >"$TREE/mise.toml"
	run_check shellcheck-targets
	[ "$status" -ne 0 ]
	[[ "$output" == *"no shellcheck invocation"* ]]
}

# --- the arguments it documents (M15) ----------------------------------------
#
# The header says `[root] [check ...]` with root defaulting to the current
# directory, which reads as "naming a check runs only that one". It did not: the
# first argument was taken as the root unconditionally, so
# `scripts/check-agreement.sh vault-name` died with "no such directory:
# vault-name". Every caller in the tree passes a root first, so nothing noticed
# — the broken form was the one a person would type.

@test "a bare check name runs that check against the current directory" {
	run env -C "$TREE" sh "$SCRIPT" vault-name
	[ "$status" -eq 0 ]
}

@test "a bare check name still fails when that check fails" {
	printf 'vault="Personal"\n' >"$TREE/home/dot_local/bin/executable_a"
	run env -C "$TREE" sh "$SCRIPT" vault-name
	[ "$status" -ne 0 ]
	[[ "$output" == *"hardcode"* ]]
}

# ...and naming a check must not silently run every other one as well.
@test "a bare check name runs only that check" {
	printf 'chezmoi = "2.71.0"\n"pipx:graphifyy" = "0.9.30"\n' \
		>"$TREE/home/dot_config/mise/config.toml.tmpl"
	run env -C "$TREE" sh "$SCRIPT" vault-name
	[ "$status" -eq 0 ]
}

# The form every caller in the tree uses keeps working, since a root is not a
# check name and a check name is not a root.
@test "an explicit root still comes first" {
	run sh "$SCRIPT" "$TREE" vault-name
	[ "$status" -eq 0 ]
}

@test "a directory that shares a check's name is still reachable as a root" {
	mkdir -p "$TREE/vault-name"
	run sh "$SCRIPT" "$TREE" vault-name
	[ "$status" -eq 0 ]
}

# --- the retired token the inventory forgot (M8) ------------------------------
#
# proton-ssh-load renames a rejected cached token to `<path>.rejected` rather
# than deleting it, deliberately: a failed login cannot tell "revoked" from
# "Proton was unreachable for ten seconds", and deleting on the second destroys
# the one thing that makes unattended applies work on a machine that cannot read
# the vault to get another copy.
#
# The consequence is a second file on disk holding a vault-wide credential, 0600
# and indefinitely. docs/revocation.md is the file that answers "what do I have
# to revoke", and it listed only the live path — so the copy left behind by the
# mechanism that exists to preserve it was the one the inventory did not know
# about.

@test "a retired-token path the inventory does not name is caught" {
	printf 'nothing about retired copies here\n' >"$TREE/docs/revocation.md"
	run_check pat-path
	[ "$status" -ne 0 ]
	[[ "$output" == *".rejected"* ]]
}

# The assertion has to be about what the code does, not about a string in a
# doc: a tree that stopped retiring tokens should not be asked to document one.
@test "a tree that retires nothing is not asked to document it" {
	printf 'pat_file="$HOME/.config/pass-cli-bootstrap-pat"\n' \
		>"$TREE/home/dot_local/bin/executable_pat_a"
	printf 'pat_file="$HOME/.config/pass-cli-bootstrap-pat"\n' \
		>"$TREE/home/dot_local/bin/executable_pat_b"
	printf 'nothing about retired copies here\n' >"$TREE/docs/revocation.md"
	run_check pat-path
	[ "$status" -eq 0 ]
}

# --- one vault name per role, and nobody spells it out ------------------------
#
# The check used to assert the tree named exactly one vault. A work machine
# reads a different one, so that assertion had to invert rather than relax:
# scripts must not name a vault at all, they read DOTFILES_VAULT out of the
# facts file, and the only literals left are the two branches of
# .chezmoitemplates/vault-name.
#
# What can drift is a script going back to a hardcoded name — which would keep
# working on a personal machine and quietly read the wrong vault on a work one,
# the exact failure the split exists to prevent.

@test "a script that hardcodes a vault name is caught" {
	printf 'vault="Dotfiles"\n' >"$TREE/home/dot_local/bin/executable_a"
	run_check vault-name
	[ "$status" -ne 0 ]
	[[ "$output" == *"hardcode"* ]]
}

@test "a work-vault name hardcoded is caught just the same" {
	printf 'vault="Work"\n' >"$TREE/home/dot_local/bin/executable_a"
	run_check vault-name
	[ "$status" -ne 0 ]
}

# The fallback every script carries has to be the same name the template calls
# personal. If they drift, a machine whose facts file has not been written yet
# reads one vault while every other path reads another.
@test "a fallback that disagrees with the template is caught" {
	printf 'vault="${DOTFILES_VAULT:-Personal}"\n' \
		>"$TREE/home/dot_local/bin/executable_a"
	run_check vault-name
	[ "$status" -ne 0 ]
	[[ "$output" == *"fallback"* ]]
}

@test "a facts file that stopped carrying the vault is caught" {
	printf 'DOTFILES_PROFILES="x"\n' \
		>"$TREE/home/dot_config/dotfiles/machine.env.tmpl"
	run_check vault-name
	[ "$status" -ne 0 ]
	[[ "$output" == *"machine.env"* ]]
}

# Same floor as every other scan here: a moved directory must not pass by
# finding nothing left to disagree with.
@test "finding no vault consumers at all is a failure, not agreement" {
	rm -f "$TREE/home/dot_local/bin/executable_a" \
		"$TREE/home/dot_local/bin/executable_vault_c" \
		"$TREE/home/.chezmoiscripts/restore.sh.tmpl"
	run_check vault-name
	[ "$status" -ne 0 ]
	[[ "$output" == *"the scan broke"* ]]
}
