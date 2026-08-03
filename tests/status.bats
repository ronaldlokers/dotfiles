#!/usr/bin/env bats
#
# dotfiles-status answers "is anything wrong with this machine's secrets?" from
# recorded state alone.
#
# The gap it closes is narrower and more important than "did the check fail".
# A failing weekly check marks its unit failed, which `systemctl --user
# --failed` surfaces durably. But a unit that has *stopped running* is, from
# there, exactly indistinguishable from one that runs and passes — both are
# simply absent. A timer disabled by a botched apply, a unit whose ExecStart
# moved, a laptop shut for a month: every one of them looks like health.
#
# So the assertions that matter here are the staleness ones, and the boundary
# either side of the threshold.

bats_require_minimum_version 1.5.0

setup() {
	SCRIPT="$BATS_TEST_DIRNAME/../home/dot_local/bin/executable_dotfiles-status"
	HOME="$BATS_TEST_TMPDIR/home"
	STATE="$HOME/.local/state/dotfiles"
	mkdir -p "$STATE"
	CHECK="$STATE/last-check"
	MANIFEST="$STATE/secrets-backup"
	export HOME
}

# Writes a last-check record $1 days old with result $2.
record() {
	local days="$1" result="${2:-ok}" detail="${3:-6 vault item(s), 2 template(s)}"
	# A negative count means the future, which is a case worth being able to
	# build: clock skew at boot produces exactly that.
	printf 'date=%s\nresult=%s\ndetail=%s\n' \
		"$(date -u -d "$days days ago" +%Y-%m-%dT%H:%M:%SZ)" "$result" "$detail" \
		>"$CHECK"
}

backup() {
	printf 'date=%s\ndestination=/mnt/stick/dotfiles-age-key.age\nage_public_key=age1fake\n' \
		"$(date -u -d "${1:-30} days ago" +%Y-%m-%dT%H:%M:%SZ)" >"$MANIFEST"
}

run_status() {
	run env -u XDG_STATE_HOME HOME="$HOME" sh "$SCRIPT" "$@"
}

@test "a recent healthy run and a recorded backup exit 0" {
	record 2 ok
	backup 30
	run_status
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok    secrets check"* ]]
	[[ "$output" == *"ok    offline backup"* ]]
}

# --- the finding this exists for ---------------------------------------------

@test "a check that has not run in weeks is a fault, not silence" {
	record 21 ok
	backup 30
	run_status
	[ "$status" -ne 0 ]
	[[ "$output" == *"timer is not firing"* ]]
	[[ "$output" == *"21 days ago"* ]]
}

# The distinction the rest of the machine cannot make: this last run *passed*.
# Nothing is in `systemctl --user --failed`, no toast ever appeared, and the
# machine has silently been unchecked for three weeks.
@test "a stale run is a fault even though its recorded result was ok" {
	record 30 ok
	backup 30
	run_status
	[ "$status" -ne 0 ]
	[[ "$output" == *"FAIL  secrets check"* ]]
}

# The weekly timer carries a 12h randomised delay, so eight days between runs
# is legitimate on a healthy machine. Crying wolf at eight would train the
# whole thing to be ignored.
@test "eight days is not yet stale" {
	record 8 ok
	backup 30
	run_status
	[ "$status" -eq 0 ]
}

@test "eleven days is" {
	record 11 ok
	backup 30
	run_status
	[ "$status" -ne 0 ]
}

@test "never having recorded a run at all is a fault" {
	rm -f "$CHECK"
	backup 30
	run_status
	[ "$status" -ne 0 ]
	[[ "$output" == *"has never recorded a run"* ]]
	[[ "$output" == *"timer"* ]]
}

# An unparsable date must not read as "checked today", which is what a plain
# arithmetic fallback to 0 would have done.
@test "an unreadable date is a fault, not a fresh run" {
	printf 'date=whenever\nresult=ok\n' >"$CHECK"
	backup 30
	run_status
	[ "$status" -ne 0 ]
	[[ "$output" == *"unreadable"* ]]
}

# --- what the last run said --------------------------------------------------

@test "a recorded failure is reported as one" {
	record 1 fail "see the journal"
	backup 30
	run_status
	[ "$status" -ne 0 ]
	[[ "$output" == *"FAIL  secrets check"* ]]
	[[ "$output" == *"see the journal"* ]]
}

@test "a recorded warning is a warning, not a failure" {
	record 1 warn "bootstrap PAT expires soon"
	backup 30
	run_status
	[ "$status" -eq 0 ]
	[[ "$output" == *"warn  secrets check"* ]]
}

# --- the offline copy --------------------------------------------------------

# A warning, not a fault, and the exit code is the assertion. This condition
# has been true since the machine was built and needs removable media present
# to resolve; as a fault it produced one identical toast per day forever, in
# the same channel as every real failure.
@test "no recorded backup warns and says what to run, without failing" {
	record 1 ok
	rm -f "$MANIFEST"
	run_status
	[ "$status" -eq 0 ]
	[[ "$output" == *"warn  offline backup"* ]]
	[[ "$output" == *"none has ever been recorded"* ]]
	[[ "$output" == *"dotfiles-secrets-export"* ]]
}

# ...and being a warning is only defensible if the thing that notifies stays
# quiet for it. This is the assertion that makes the demotion real.
@test "a never-made backup is silent to the automated caller" {
	record 1 ok
	rm -f "$MANIFEST"
	run_status --quiet
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# Deliberately no age threshold: an untouched key means a two-year-old copy is
# still a good copy, and nagging about its age would only teach you to ignore
# the line. Same reasoning the check itself uses.
@test "a very old backup is not a fault" {
	record 1 ok
	backup 900
	run_status
	[ "$status" -eq 0 ]
	[[ "$output" == *"900 day(s) ago"* ]]
}

@test "it points at the command that proves the backup reads back" {
	record 1 ok
	backup 30
	run_status
	[ "$status" -eq 0 ]
	[[ "$output" == *"dotfiles-secrets-restore"* ]]
}

# --- the contract ------------------------------------------------------------

# The whole point of --quiet: something can call this daily and only hear from
# it when there is something to hear.
@test "--quiet says nothing when everything is fine" {
	record 1 ok
	backup 30
	run_status --quiet
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "--quiet still speaks when something is wrong" {
	record 40 ok
	backup 30
	run_status --quiet
	[ "$status" -ne 0 ]
	[[ "$output" == *"not firing"* ]]
}

# It reads recorded state and nothing else — no vault, no network. A status
# command that could hang is one nobody puts in a loop.
@test "it needs neither pass-cli nor a network" {
	record 1 ok
	backup 30
	run env -u XDG_STATE_HOME HOME="$HOME" PATH="/usr/bin:/bin" sh "$SCRIPT"
	[ "$status" -eq 0 ]
}

@test "--help explains itself" {
	run_status --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage: dotfiles-status"* ]]
}

@test "an unknown argument is refused" {
	run_status --fix
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown argument"* ]]
}

# --- the guards the dates needed (H2, M20, M21) ------------------------------

# `date -u -d "" +%s` SUCCEEDS on GNU coreutils, returning today's midnight. So
# a record missing its date line parsed cleanly as "checked today" — for ever,
# silently, in the one mechanism that exists to notice a check that has stopped
# running.
@test "a record with no date line is a fault, not a fresh run" {
	printf 'result=ok\ndetail=x\n' >"$CHECK"
	backup 30
	run_status
	[ "$status" -ne 0 ]
	[[ "$output" == *"unreadable"* ]]
}

@test "an empty date value is a fault too" {
	printf 'date=\nresult=ok\n' >"$CHECK"
	backup 30
	run_status
	[ "$status" -ne 0 ]
	[[ "$output" == *"unreadable"* ]]
}

# Clock skew at boot — NTP not yet synced while a Persistent=true timer fires —
# is exactly when a future date would otherwise silence the fault this exists
# for, while printing "-400 day(s) ago" as it did so.
@test "a future-dated record is untrustworthy, not young" {
	record -400 ok
	backup 30
	run_status
	[ "$status" -ne 0 ]
	[[ "$output" == *"unreadable"* ]]
	[[ "$output" != *"-400"* ]]
}

# The threshold the comment argues for at length was pinned by nothing: the
# old cases bracketed at 8 and 11, so any value in {9,10,11} and either
# comparison passed. These two are the boundary itself.
@test "exactly ten days is not yet stale" {
	record 10 ok
	backup 30
	run_status
	[ "$status" -eq 0 ]
}

@test "eleven days is stale" {
	record 11 ok
	backup 30
	run_status
	[ "$status" -ne 0 ]
	[[ "$output" == *"not firing"* ]]
}

# A path with a space in it is entirely ordinary on removable media, and this
# line is meant to be pasted.
@test "the destination is quoted in the command it prints" {
	record 1 ok
	printf 'date=2026-07-01T00:00:00Z\ndestination=/run/media/you/My Stick/k.age\n' >"$MANIFEST"
	run_status
	[[ "$output" == *"'/run/media/you/My Stick/k.age'"* ]]
}

# Every producer of these files is kept out of containers by .chezmoiignore;
# this is the sole consumer and was the only one with no gate.
@test "inside a container it says nothing and exits 0" {
	rm -f "$CHECK" "$MANIFEST"
	marker="$BATS_TEST_TMPDIR/dockerenv"
	: >"$marker"
	# The script probes for /.dockerenv directly, so this asserts the gate
	# exists in the source rather than faking the filesystem root.
	grep -q '/\.dockerenv' "$SCRIPT"
	grep -q '/run/\.containerenv' "$SCRIPT"
}
