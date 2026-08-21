#!/usr/bin/env bats
#
# .chezmoitemplates/profiles answers "what kind of machine is this", as a set
# rather than a single label. A laptop is `host personal linux`; a devcontainer
# for a TypeScript web app is `container typescript web linux`. Anything that
# should not be installed or applied everywhere gates on a member of that set.
#
# The set is assembled on every apply and never stored, so it cannot go stale —
# which matters most for the part that comes from the environment: a project
# changes its DOTFILES_PROFILES and the next apply simply reflects it.
#
# Three sources, and the split is deliberate. What a machine can work out about
# itself is never asked (container-ness, OS). What no machine can work out —
# whether it is a personal or a work machine — is asked once at init and
# remembered. What belongs to a project rather than to a machine arrives in the
# environment, where the project already configures everything else.

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	REPO="$BATS_TEST_DIRNAME/.."
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.config/chezmoi"
	export HOME
}

# chezmoi reads its data from $HOME/.config/chezmoi/chezmoi.toml, so a test
# picks a role by writing one. No role at all is its own case below.
set_role() {
	printf '[data]\n    role = %s\n' "\"$1\"" >"$HOME/.config/chezmoi/chezmoi.toml"
}

profiles() {
	run env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME "$@" HOME="$HOME" \
		chezmoi execute-template --source "$REPO" \
		'{{ includeTemplate "profiles" . }}'
	[ "$status" -eq 0 ]
}

@test "a machine that is not a container is a host" {
	set_role personal
	profiles
	[[ "$output" == *" host "* ]]
	[[ "$output" != *" container "* ]]
}

@test "the OS is a profile, and it is not asked for" {
	set_role personal
	profiles
	[[ "$output" == *" linux "* ]]
}

@test "the role that was answered is a profile" {
	set_role work
	profiles
	[[ "$output" == *" work "* ]]
	[[ "$output" != *" personal "* ]]
}

# A machine that has never been asked is a personal one. The prompt only runs
# on an interactive init; CI, `mise run verify` and `devpod up` have no TTY and
# must land somewhere sensible rather than on an empty role.
@test "a machine that was never asked is personal" {
	rm -f "$HOME/.config/chezmoi/chezmoi.toml"
	profiles
	[[ "$output" == *" personal "* ]]
}

# The project half. A devcontainer.json sets this; nothing else does.
@test "project profiles arrive from the environment" {
	set_role personal
	profiles DOTFILES_PROFILES=typescript,web
	[[ "$output" == *" typescript "* ]]
	[[ "$output" == *" web "* ]]
}

@test "spaces around a project profile are not part of its name" {
	set_role personal
	profiles "DOTFILES_PROFILES=typescript, web"
	[[ "$output" == *" typescript "* ]]
	[[ "$output" == *" web "* ]]
}

@test "an unset DOTFILES_PROFILES adds nothing" {
	set_role personal
	profiles
	[[ "$output" != *"  "* ]]
}

@test "an empty DOTFILES_PROFILES adds nothing either" {
	set_role personal
	profiles DOTFILES_PROFILES=
	[[ "$output" != *"  "* ]]
}

@test "a trailing comma does not become an empty profile" {
	set_role personal
	profiles DOTFILES_PROFILES=go,
	[[ "$output" == *" go "* ]]
	[[ "$output" != *"  "* ]]
}

# The padding is the whole reason a caller can write `contains " host "`. Without
# it, a profile named `ghost` would answer to a test for `host`, and a gate that
# silently matches the wrong machine is worse than one that does not match at
# all.
@test "the set is padded, so a substring cannot pass for a profile" {
	set_role personal
	profiles DOTFILES_PROFILES=ghost
	[[ "$output" == " "* ]]
	[[ "$output" == *" " ]]
	# What a caller actually writes, both ways round.
	[[ "$output" == *" ghost "* ]]
	[[ "$output" == *" host "* ]]
	# ...and the one that must not be fooled: a machine with only `ghost` and
	# no `host` is the case this padding exists for.
	set_role personal
	run env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME DOTFILES_PROFILES=ghost HOME="$HOME" \
		chezmoi execute-template --source "$REPO" \
		'{{ if contains " nothost " (includeTemplate "profiles" .) }}matched{{ else }}no{{ end }}'
	[ "$output" = "no" ]
}

# --- what the set is actually used for ---------------------------------------

render_tools() {
	env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" chezmoi execute-template \
		--source "$REPO" <"$REPO/home/dot_config/mise/config.toml.tmpl"
}

@test "a work-only tool is in a work machine's tool list" {
	set_role work
	run render_tools
	[ "$status" -eq 0 ]
	[[ "$output" == *"jira-cli"* ]]
	# ...and the tools nobody gated are still there beside it.
	[[ "$output" == *"ripgrep"* ]]
}

# The half that matters: a gate that only ever adds is not a gate.
@test "a personal machine does not get the work tool" {
	set_role personal
	run render_tools
	[ "$status" -eq 0 ]
	[[ "$output" != *"jira-cli"* ]]
	[[ "$output" == *"ripgrep"* ]]
}

# The rendered file has to be valid TOML whichever way the gates fall — a
# template that renders a stray blank section or an unclosed table would only
# show up as a mise parse error on the machine it broke.
@test "the rendered mise config parses as TOML" {
	set_role personal
	rendered="$BATS_TEST_TMPDIR/config.toml"
	env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" chezmoi execute-template \
		--source "$REPO" \
		"$(cat "$REPO/home/dot_config/mise/config.toml.tmpl")" >"$rendered"
	run yq -p toml -o json '.' "$rendered"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"pipx.uvx"'* ]] || [[ "$output" == *'pipx'* ]]
}

# --- the run_onchange trap ----------------------------------------------------
#
# chezmoi re-runs a run_onchange script when its *rendered* contents change, and
# run_onchange_after_install_packages is what runs `mise install`. Its hash line
# reads the tool list with `include`, which returns the file unrendered — so
# switching a machine from personal to work, or a container from go to
# typescript, rewrites the tool list chezmoi applies while the script's own
# contents never move. The install would not re-run, and the new profile's tools
# would simply never be installed.
#
# That is M12 in a different place: a skip that records itself as done. The
# profile set is part of what the script hashes for exactly this reason.

render_install_script() {
	env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME "$@" HOME="$HOME" \
		chezmoi execute-template --source "$REPO" \
		<"$REPO/home/.chezmoiscripts/run_onchange_after_install_packages.sh.tmpl"
}

@test "changing the role re-runs the install script" {
	set_role personal
	personal="$(render_install_script)"
	set_role work
	work="$(render_install_script)"
	[ "$personal" != "$work" ]
}

@test "changing a project's profiles re-runs it too" {
	set_role personal
	plain="$(render_install_script)"
	tagged="$(render_install_script DOTFILES_PROFILES=typescript)"
	[ "$plain" != "$tagged" ]
}

# --- what a work machine does not get ----------------------------------------
#
# Three things belong to one life rather than to one form factor, and each is
# gated in the place that actually stops it: repos-sync and the moshi shim never
# land at all (.chezmoiignore), while the tailnet and moshi scripts render a
# gate and exit. Cheap to get wrong in one place and right in the others, which
# is why all three are asserted here rather than trusted to review.

render_ignore() {
	env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" chezmoi execute-template \
		--source "$REPO" <"$REPO/home/.chezmoiignore"
}

@test "a work machine is not given repos-sync, which clones personal repos" {
	set_role work
	run render_ignore
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qx '.local/bin/repos-sync'
}

@test "a personal machine keeps it" {
	set_role personal
	run render_ignore
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -qx '.local/bin/repos-sync'
}

@test "the tailnet sshd script exits early on a work machine" {
	set_role work
	rendered="$BATS_TEST_TMPDIR/tailnet.sh"
	env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" chezmoi execute-template --source "$REPO" \
		<"$REPO/home/.chezmoiscripts/run_after_21-ssh-over-tailnet.sh.tmpl" >"$rendered"
	grep -qx 'is_personal=false' "$rendered"
	# ...and it is a real exit, not a variable nobody reads.
	run bash "$rendered"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "and runs its checks on a personal one" {
	set_role personal
	rendered="$BATS_TEST_TMPDIR/tailnet-personal.sh"
	env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" chezmoi execute-template --source "$REPO" \
		<"$REPO/home/.chezmoiscripts/run_after_21-ssh-over-tailnet.sh.tmpl" >"$rendered"
	grep -qx 'is_personal=true' "$rendered"
}

@test "the moshi external fetches nothing on a work machine" {
	set_role work
	run env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" chezmoi execute-template --source "$REPO" \
		<"$REPO/home/.chezmoiexternals/moshi-hook.toml"
	[ "$status" -eq 0 ]
	[ -z "$(printf '%s' "$output" | tr -d '[:space:]')" ]
}

# --- a work machine has no age key -------------------------------------------
#
# The Work vault holds `gh hosts.yml` and `sugarrush config` and nothing else.
# The three it does not hold are not "missing" — they were never meant to be
# there — so every consumer has to agree about that, or the weekly report fills
# up with faults nobody can act on and stops being read.
#
# Four places have to agree: the restore list, the item list the check derives
# from it, the offline-copy half of that check, and what dotfiles-status says
# about a backup. Getting three of four right is how a check ends up crying
# wolf.

# The list is one list, marked rather than branched: a fourth field names the
# single profile an item belongs to. So the assertion is not about which lines
# are present — they all are — but about which ones a run would act on.
restore_titles_for() {
	set_role "$1"
	local rendered="$BATS_TEST_TMPDIR/restore-$1.sh"
	env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
		-u XDG_CACHE_HOME HOME="$HOME" chezmoi execute-template --source "$REPO" \
		<"$REPO/home/.chezmoiscripts/run_after_14-restore-secrets.sh.tmpl" >"$rendered"
	# Replace the real restore() with one that only prints, then run the list.
	{
		sed -n '/^profiles=/p' "$rendered"
		printf 'restore() {\n'
		printf '\tonly="${4:-}"\n'
		printf '\t[ -z "$only" ] || case " $profiles " in *" $only "*) ;; *) return 0 ;; esac\n'
		printf '\tprintf "%%s\\n" "$1"\n'
		printf '}\n'
		grep '^restore "' "$rendered"
	} >"$rendered.list"
	sh "$rendered.list"
}

@test "a work machine restores only what the Work vault holds" {
	run restore_titles_for work
	[ "$status" -eq 0 ]
	[[ "$output" == *"gh hosts.yml"* ]]
	[[ "$output" == *"sugarrush config"* ]]
	[[ "$output" != *"sops age keys"* ]]
	[[ "$output" != *"devpod dotfiles-env"* ]]
	[[ "$output" != *"devpod project-tokens"* ]]
}

@test "a personal machine still restores all five" {
	run restore_titles_for personal
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | grep -c .)" -eq 5 ]
}

@test "the offline export and its counterpart are not installed on a work machine" {
	set_role work
	run render_ignore
	printf '%s\n' "$output" | grep -qx '.local/bin/dotfiles-secrets-export'
	printf '%s\n' "$output" | grep -qx '.local/bin/dotfiles-secrets-restore'
}

@test "and both are installed on a personal one" {
	set_role personal
	run render_ignore
	! printf '%s\n' "$output" | grep -qx '.local/bin/dotfiles-secrets-export'
	! printf '%s\n' "$output" | grep -qx '.local/bin/dotfiles-secrets-restore'
}
