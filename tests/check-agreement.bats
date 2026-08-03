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
		>"$TREE/home/dot_config/mise/config.toml"
	printf 'chezmoi = "2.70.5"\n' >"$TREE/mise.toml"
	printf '0.9.30' >"$TREE/home/dot_claude/skills/graphify/dot_graphify_version"

	printf 'vault="Dotfiles"\n' >"$TREE/home/.chezmoiscripts/restore.sh.tmpl"
	printf 'vault="Dotfiles"\n' >"$TREE/home/dot_local/bin/executable_a"
	printf 'pass://Dotfiles/some item/public_key\n' \
		>"$TREE/home/.chezmoitemplates/signing-pubkey"

	# Three files probing both markers: the template and the two scripts that
	# re-ask at run time.
	for f in "$TREE/home/.chezmoitemplates/is-container" \
		"$TREE/home/dot_local/bin/executable_b" \
		"$TREE/home/dot_local/bin/executable_c"; do
		printf 'if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then :; fi\n' >"$f"
	done

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
		>"$TREE/home/dot_config/mise/config.toml"
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

@test "a rename that misses one script is caught" {
	printf 'vault="Personal"\n' >"$TREE/home/dot_local/bin/executable_a"
	run_check vault-name
	[ "$status" -ne 0 ]
	[[ "$output" == *"disagrees"* ]]
}

@test "a rename that misses the pass:// URI is caught" {
	printf 'pass://Personal/some item/public_key\n' \
		>"$TREE/home/.chezmoitemplates/signing-pubkey"
	run_check vault-name
	[ "$status" -ne 0 ]
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
		>"$TREE/home/dot_config/mise/config.toml"
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
		>"$TREE/home/dot_config/mise/config.toml"
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
