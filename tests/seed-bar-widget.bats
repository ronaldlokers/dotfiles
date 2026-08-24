#!/usr/bin/env bats
#
# run_after_23-seed-bar-widget.sh.tmpl puts the ssh-agent widget on the bar.
#
# ~/.config/omarchy/shell.json is not chezmoi-managed and cannot be: omarchy's
# own `bar`, `theme` and plugin commands write to it, so a managed copy would
# revert whatever the last command did. The widget still has to arrive on a new
# machine without being typed in by hand, which leaves seeding.
#
# What makes that safe is the state file. The script does nothing while the
# recorded spec matches the one it would write, so a widget removed by hand
# stays removed -- the repo has already had its say. Change the spec here and
# the next apply re-seeds. The state file also closes the run_onchange trap
# this repo has been bitten by: a run that could not act (no shell.json yet, no
# jq yet) records nothing and is retried, rather than being marked done on the
# exit 0 that meant "did nothing".

bats_require_minimum_version 1.5.0

setup() {
	load 'helpers'
	TMPL="$BATS_TEST_DIRNAME/../home/.chezmoiscripts/run_after_23-seed-bar-widget.sh.tmpl"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.config/omarchy"
	SHELL_JSON="$HOME/.config/omarchy/shell.json"
	STATE="$HOME/.local/state/dotfiles/bar-widget-seeded"

	SCRIPT="$BATS_TEST_TMPDIR/seed.sh"
	render_template "$TMPL" "$SCRIPT" "$PATH"
	export HOME
}

# A bar with the stock right section and nothing of ours in it.
write_shell_json() {
	cat >"$SHELL_JSON" <<-'EOF'
		{
		  "bar": {
		    "position": "bottom",
		    "layout": {
		      "left": [
		        {
		          "id": "omarchy.menu"
		        },
		        {
		          "id": "omarchy.workspaces"
		        }
		      ],
		      "right": [
		        {
		          "id": "omarchy.network"
		        },
		        {
		          "id": "omarchy.power"
		        }
		      ]
		    }
		  }
		}
	EOF
}

# XDG_CONFIG_HOME and XDG_STATE_HOME are exported on this desktop and point at
# the real ~/.config and ~/.local/state, which the script honours -- correctly,
# and the first run of this suite proved it by seeding the developer's own bar
# instead of the fixture. `mise run verify` clears them for the same reason.
run_seed() {
	run env -u XDG_CONFIG_HOME -u XDG_STATE_HOME HOME="$HOME" "$@" sh "$SCRIPT"
}

left_ids() {
	jq -r '.bar.layout.left[].id' "$SHELL_JSON" | tr '\n' ' '
}

right_ids() {
	jq -r '.bar.layout.right[].id' "$SHELL_JSON" | tr '\n' ' '
}

@test "seeds the widget before the power button" {
	write_shell_json
	run_seed
	[ "$status" -eq 0 ]
	[ "$(right_ids)" = "omarchy.network lokilabs.ssh-agent omarchy.power " ]
}

@test "records the spec it wrote" {
	write_shell_json
	run_seed
	[ -s "$STATE" ]
}

# The reason this is a seed and not a managed file: whatever the bar looks like
# after the first run is the user's business.
@test "a widget removed by hand stays removed" {
	write_shell_json
	run_seed
	jq 'del(.bar.layout.right[] | select(.id == "lokilabs.ssh-agent"))' "$SHELL_JSON" >"$SHELL_JSON.new"
	mv "$SHELL_JSON.new" "$SHELL_JSON"

	run_seed
	[ "$(right_ids)" = "omarchy.network omarchy.power " ]
}

@test "a second run leaves the file byte-identical" {
	write_shell_json
	run_seed
	cp "$SHELL_JSON" "$BATS_TEST_TMPDIR/after-first"

	run_seed
	cmp "$SHELL_JSON" "$BATS_TEST_TMPDIR/after-first"
}

# Changing the spec in the script is the one thing that speaks again.
@test "a changed spec re-seeds" {
	write_shell_json
	run_seed
	jq 'del(.bar.layout.right[] | select(.id == "lokilabs.ssh-agent"))' "$SHELL_JSON" >"$SHELL_JSON.new"
	mv "$SHELL_JSON.new" "$SHELL_JSON"
	printf 'something else entirely\n' >"$STATE"

	run_seed
	[ "$(right_ids)" = "omarchy.network lokilabs.ssh-agent omarchy.power " ]
}

@test "an entry already on the bar is updated, not duplicated" {
	write_shell_json
	jq '.bar.layout.right = [{"id":"lokilabs.ssh-agent"}] + .bar.layout.right' "$SHELL_JSON" >"$SHELL_JSON.new"
	mv "$SHELL_JSON.new" "$SHELL_JSON"

	run_seed
	[ "$(jq '[.bar.layout.right[] | select(.id == "lokilabs.ssh-agent")] | length' "$SHELL_JSON")" -eq 1 ]
	[ "$(jq -r '.bar.layout.right[] | select(.id == "lokilabs.ssh-agent") | .alwaysShow' "$SHELL_JSON")" = "true" ]
}

@test "everything else in shell.json survives" {
	write_shell_json
	run_seed
	[ "$(jq -r '.bar.position' "$SHELL_JSON")" = "bottom" ]
	[ "$(jq -r '.bar.layout.left[0].id' "$SHELL_JSON")" = "omarchy.menu" ]
}

# The run_onchange trap, closed: a run that could not act records nothing, so
# the next apply tries again instead of the machine being marked done forever.
@test "no shell.json yet records nothing and creates nothing" {
	run_seed
	[ "$status" -eq 0 ]
	[ ! -e "$SHELL_JSON" ]
	[ ! -e "$STATE" ]
}

@test "no jq yet records nothing" {
	write_shell_json
	# A PATH with no jq on it. env -i would lose too much; this keeps the shell
	# usable and takes away the one binary.
	EMPTY="$BATS_TEST_TMPDIR/nojq"
	mkdir -p "$EMPTY"
	for tool in sh cat mkdir mv rm printf command sed; do
		[ -x "/usr/bin/$tool" ] && ln -sf "/usr/bin/$tool" "$EMPTY/$tool"
	done

	run_seed PATH="$EMPTY"
	[ "$status" -eq 0 ]
	[ ! -e "$STATE" ]
	[ "$(right_ids)" = "omarchy.network omarchy.power " ]
}

# The workspace widget is a clone of omarchy.workspaces, not an addition to it:
# two of them on one bar would paint the same spaces twice. Replacing in place
# also keeps whatever position the stock one had.
@test "swaps the stock workspaces widget for the clone, in its place" {
	write_shell_json
	run_seed
	[ "$(left_ids)" = "omarchy.menu lokilabs.workspace " ]
}

@test "the swapped-in widget carries its monitor colours" {
	write_shell_json
	run_seed
	[ "$(jq -c '.bar.layout.left[] | select(.id == "lokilabs.workspace") | .monitorColors' "$SHELL_JSON")" = '["bright_green","bright_magenta"]' ]
}

@test "seeds both widgets in one run" {
	write_shell_json
	run_seed
	[ "$(left_ids)" = "omarchy.menu lokilabs.workspace " ]
	[ "$(right_ids)" = "omarchy.network lokilabs.ssh-agent omarchy.power " ]
}

# Each widget's own line, and only it, decides that widget. The design this
# rules out is one combined record for the whole table: under that, editing the
# ssh-agent entry here would invalidate the record wholesale and resurrect a
# workspace widget the user had removed on purpose -- a change to one thing
# undoing a decision about another.
#
# Both widgets are off the bar and only the ssh-agent's record is gone, so the
# two halves have to disagree: one comes back, one stays away.
@test "one widget's record does not decide another's" {
	write_shell_json
	run_seed
	jq 'del(.bar.layout.left[] | select(.id == "lokilabs.workspace"))
		| del(.bar.layout.right[] | select(.id == "lokilabs.ssh-agent"))' \
		"$SHELL_JSON" >"$SHELL_JSON.new"
	mv "$SHELL_JSON.new" "$SHELL_JSON"
	grep -v '^lokilabs.ssh-agent ' "$STATE" >"$STATE.new"
	mv "$STATE.new" "$STATE"

	run_seed
	[ "$(right_ids)" = "omarchy.network lokilabs.ssh-agent omarchy.power " ]
	[ "$(left_ids)" = "omarchy.menu " ]
}

# The format that makes the above possible, asserted directly: a line per
# widget, not one record for the table.
@test "the state file keeps a line per widget" {
	write_shell_json
	run_seed
	[ "$(wc -l <"$STATE")" -eq 2 ]
	grep -q '^lokilabs.ssh-agent ' "$STATE"
	grep -q '^lokilabs.workspace ' "$STATE"
}

@test "appends when neither the clone nor the widget it replaces is on the bar" {
	write_shell_json
	jq 'del(.bar.layout.left[] | select(.id == "omarchy.workspaces"))' "$SHELL_JSON" >"$SHELL_JSON.new"
	mv "$SHELL_JSON.new" "$SHELL_JSON"

	run_seed
	[ "$(left_ids)" = "omarchy.menu lokilabs.workspace " ]
}

@test "a clone already on the bar keeps its position" {
	write_shell_json
	jq '.bar.layout.left = [{"id":"lokilabs.workspace"},{"id":"omarchy.menu"}]' "$SHELL_JSON" >"$SHELL_JSON.new"
	mv "$SHELL_JSON.new" "$SHELL_JSON"

	run_seed
	[ "$(left_ids)" = "lokilabs.workspace omarchy.menu " ]
}
