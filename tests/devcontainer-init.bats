#!/usr/bin/env bats
#
# devcontainer-init scaffolds a project .devcontainer from the managed template.
# It had no tests, and it is almost entirely edge cases: it refuses names that
# cannot go into JSON, refuses to write through a symlink, stages into a scratch
# directory on the same filesystem and moves it into place as one rename, and
# substitutes the project name with bash pattern substitution rather than sed so
# a name containing `&` or `\` cannot corrupt the output.
#
# Every one of those is a decision someone made on purpose and nothing was
# holding in place.

bats_require_minimum_version 1.5.0

setup() {
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_devcontainer-init"
	HOME="$BATS_TEST_TMPDIR/home"
	TEMPLATE="$HOME/.local/share/devcontainer-template"
	mkdir -p "$TEMPLATE"
	printf '{\n  "name": "__PROJECT_NAME__",\n  "image": "x"\n}\n' \
		>"$TEMPLATE/devcontainer.json"
	printf '#!/bin/sh\necho post-create\n' >"$TEMPLATE/post-create.sh"
	printf 'FROM archlinux:base\n' >"$TEMPLATE/Dockerfile"
	export HOME
}

# The project directory the tool is run from; its basename becomes the
# container name, which is most of what there is to get wrong.
in_project() {
	local name="$1"
	shift
	local dir="$BATS_TEST_TMPDIR/projects/$name"
	mkdir -p "$dir"
	run env HOME="$HOME" bash -c "cd \"\$1\" && shift && bash \"\$@\"" _ \
		"$dir" "$SCRIPT" "$@"
	PROJECT="$dir"
}

# --- arguments ---------------------------------------------------------------

@test "--help prints usage and writes nothing" {
	in_project myproj --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: devcontainer-init"* ]]
	[ ! -e "$PROJECT/.devcontainer" ]
}

@test "-h does the same" {
	in_project myproj -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: devcontainer-init"* ]]
	[ ! -e "$PROJECT/.devcontainer" ]
}

@test "an unknown argument is refused and writes nothing" {
	in_project myproj --nope
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown argument"* ]]
	[[ "$output" == *"usage:"* ]]
	[ ! -e "$PROJECT/.devcontainer" ]
}

# --- the template ------------------------------------------------------------

@test "a missing template is refused with the command that fixes it" {
	rm -rf "$TEMPLATE"
	in_project myproj
	[ "$status" -eq 1 ]
	[[ "$output" == *"no template"* ]]
	[[ "$output" == *"chezmoi apply"* ]]
	[ ! -e "$PROJECT/.devcontainer" ]
}

# A half-applied template must not produce a half-written project, so every
# piece is checked before anything is written.
@test "an incomplete template writes nothing at all" {
	: >"$TEMPLATE/Dockerfile"
	in_project myproj
	[ "$status" -eq 1 ]
	[[ "$output" == *"incomplete template"* ]]
	[ ! -e "$PROJECT/.devcontainer" ]
}

@test "a template missing a file entirely is refused too" {
	rm "$TEMPLATE/post-create.sh"
	in_project myproj
	[ "$status" -eq 1 ]
	[[ "$output" == *"incomplete template"* ]]
	[ ! -e "$PROJECT/.devcontainer" ]
}

# --- the happy path ----------------------------------------------------------

@test "writes all three files" {
	in_project myproj
	[ "$status" -eq 0 ]
	[ -s "$PROJECT/.devcontainer/devcontainer.json" ]
	[ -s "$PROJECT/.devcontainer/post-create.sh" ]
	[ -s "$PROJECT/.devcontainer/Dockerfile" ]
}

@test "names the container after the directory" {
	in_project myproj
	[ "$status" -eq 0 ]
	grep -q '"name": "myproj"' "$PROJECT/.devcontainer/devcontainer.json"
	! grep -q "__PROJECT_NAME__" "$PROJECT/.devcontainer/devcontainer.json"
}

# Casing is left alone on purpose: a project called WalkFit should show up as
# WalkFit in `devpod list`, not walkfit.
@test "the directory's casing is preserved" {
	in_project WalkFit
	[ "$status" -eq 0 ]
	grep -q '"name": "WalkFit"' "$PROJECT/.devcontainer/devcontainer.json"
}

# The reason the substitution is bash pattern substitution and not sed: in a
# `sed "s/.../$name/"` an `&` in the replacement expands to the whole match, so
# a project called `a&b` would silently get the wrong name.
@test "an ampersand in the name stays literal" {
	in_project 'a&b'
	[ "$status" -eq 0 ]
	grep -q '"name": "a&b"' "$PROJECT/.devcontainer/devcontainer.json"
}

@test "post-create.sh and the Dockerfile are copied verbatim" {
	in_project myproj
	[ "$status" -eq 0 ]
	[ "$(cat "$PROJECT/.devcontainer/post-create.sh")" = "$(cat "$TEMPLATE/post-create.sh")" ]
	[ "$(cat "$PROJECT/.devcontainer/Dockerfile")" = "$(cat "$TEMPLATE/Dockerfile")" ]
}

@test "leaves no staging directory behind" {
	in_project myproj
	[ "$status" -eq 0 ]
	[ -z "$(find "$PROJECT" -maxdepth 1 -name '.devcontainer-init.*' -print -quit)" ]
}

# --- names that cannot go into JSON ------------------------------------------

# Refusing is the decision: escaping would be the alternative, the case is rare,
# and renaming the directory is the real fix. What matters is that it refuses
# rather than emitting broken JSON.
@test "a name with a double quote is refused" {
	in_project 'we"ird'
	[ "$status" -eq 1 ]
	[[ "$output" == *"can't go into JSON"* ]]
	[ ! -e "$PROJECT/.devcontainer" ]
}

@test "a name with a backslash is refused" {
	in_project 'back\slash'
	[ "$status" -eq 1 ]
	[[ "$output" == *"can't go into JSON"* ]]
	[ ! -e "$PROJECT/.devcontainer" ]
}

# --- an existing target ------------------------------------------------------

@test "an existing .devcontainer is not overwritten without --force" {
	in_project myproj
	[ "$status" -eq 0 ]
	printf 'MINE\n' >"$PROJECT/.devcontainer/devcontainer.json"

	in_project myproj
	[ "$status" -eq 1 ]
	[[ "$output" == *"--force"* ]]
	[ "$(cat "$PROJECT/.devcontainer/devcontainer.json")" = "MINE" ]
}

@test "--force overwrites it" {
	in_project myproj
	[ "$status" -eq 0 ]
	printf 'MINE\n' >"$PROJECT/.devcontainer/devcontainer.json"
	printf 'stale\n' >"$PROJECT/.devcontainer/leftover"

	in_project myproj --force
	[ "$status" -eq 0 ]
	grep -q '"name": "myproj"' "$PROJECT/.devcontainer/devcontainer.json"
	# the whole directory is replaced, not merged into
	[ ! -e "$PROJECT/.devcontainer/leftover" ]
}

@test "a plain file where .devcontainer goes is replaced with --force" {
	in_project myproj
	rm -rf "$PROJECT/.devcontainer"
	printf 'not a directory\n' >"$PROJECT/.devcontainer"

	in_project myproj --force
	[ "$status" -eq 0 ]
	[ -d "$PROJECT/.devcontainer" ]
	[ -s "$PROJECT/.devcontainer/Dockerfile" ]
}

# The sharpest one. Following a symlink would write straight through into
# whatever it points at, silently, outside the project — so it is refused
# outright, --force or not.
@test "a symlinked .devcontainer is refused" {
	in_project myproj
	rm -rf "$PROJECT/.devcontainer"
	mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
	ln -s "$BATS_TEST_TMPDIR/elsewhere" "$PROJECT/.devcontainer"

	in_project myproj
	[ "$status" -eq 1 ]
	[[ "$output" == *"symlink"* ]]
	[ -z "$(ls -A "$BATS_TEST_TMPDIR/elsewhere")" ]
}

@test "a symlinked .devcontainer is refused even with --force" {
	in_project myproj
	rm -rf "$PROJECT/.devcontainer"
	mkdir -p "$BATS_TEST_TMPDIR/elsewhere2"
	ln -s "$BATS_TEST_TMPDIR/elsewhere2" "$PROJECT/.devcontainer"

	in_project myproj --force
	[ "$status" -eq 1 ]
	[[ "$output" == *"symlink"* ]]
	[ -z "$(ls -A "$BATS_TEST_TMPDIR/elsewhere2")" ]
	# and the link itself is untouched
	[ -L "$PROJECT/.devcontainer" ]
}
