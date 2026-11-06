#!/usr/bin/env bats

load helpers/setup.sh
bats_require_minimum_version 1.5.0

setup() {
  setup_test_env
  mkdir -p "$TEST_TMPDIR/stats"
  J="$TEST_TMPDIR/stats/events.csv"
}

teardown() {
  teardown_test_env
}

# Helper: runs a function of lib.sh with the arguments that follow it
lib() {
  bash -c 'source "$1/scripts/lib.sh" && shift && "$@"' _ "$TEST_TMPDIR" "$@"
}

@test "stats_rows: prints the valid rows and names each invalid line" {
  printf '%s\n' 'time,package,event,version,previous,run' \
    '2026-11-08T05:17:41Z,a,tracked,1.0,,42' \
    '2026-11-08T05:17:41Z,a,exploded,1.0,,42' \
    '2026-11-09T10:17:03Z,a,updated,1.1,1.0,43' >"$J"
  run lib stats_rows "$J"
  [ "$status" -eq 0 ]
  [[ "$output" == *"line 3 of $J is not a journal row"* ]]
  run --separate-stderr lib stats_rows "$J"
  [ "$output" = $'2026-11-08T05:17:41Z,a,tracked,1.0,,42\n2026-11-09T10:17:03Z,a,updated,1.1,1.0,43' ]
}

@test "stats_rows: a wrong header prints nothing and fails" {
  printf '%s\n' 'time,package,event' '2026-11-08T05:17:41Z,a,tracked,1.0,,42' >"$J"
  run --separate-stderr lib stats_rows "$J"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"$J does not start with the line time,package,event,version,previous,run"* ]]
}

@test "stats_rows: each field holds only its alphabet" {
  printf '%s\n' 'time,package,event,version,previous,run' \
    '2026-11-08T05:17:41Z,a,tracked,1.0,,42' \
    '2026-11-08 05:17:41Z,a,tracked,1.0,,42' \
    '2026-11-08T05:17:41Z,.a,tracked,1.0,,42' \
    '2026-11-08T05:17:41Z,a,tracked,1-0,,42' \
    '2026-11-08T05:17:41Z,a,tracked,1.0,1;0,42' \
    '2026-11-08T05:17:41Z,a,tracked,1.0,,4x' \
    '2026-11-08T05:17:41Z,a,tracked,1.0,,42,' \
    '' \
    ' 2026-11-08T05:17:41Z,a,tracked,1.0,,42' \
    '2026-11-08T05:17:41Z,@a_b+c.d-e,tracked,,,' >"$J"
  run --separate-stderr lib stats_rows "$J"
  [ "$status" -eq 0 ]
  [ "$output" = $'2026-11-08T05:17:41Z,a,tracked,1.0,,42\n2026-11-08T05:17:41Z,@a_b+c.d-e,tracked,,,' ]
  for n in 3 4 5 6 7 8 9 10; do
    [[ "$stderr" == *"line $n of $J is not a journal row"* ]]
  done
  [[ "$stderr" != *"line 1 of"* && "$stderr" != *"line 2 of"* && "$stderr" != *"line 11 of"* ]]
}

@test "stats_last_states: the last row of each package, and the last version it was at" {
  printf '%s\n' 'time,package,event,version,previous,run' \
    '2026-11-08T05:17:41Z,b,tracked,2.0,,42' \
    '2026-11-08T05:17:41Z,a,tracked,1.0,,42' \
    '2026-11-09T10:17:03Z,a,check_failed,1.0,,43' \
    '2026-11-09T10:17:03Z,b,pending,2.1,,43' \
    '2026-11-10T05:17:22Z,b,held,2.2,,44' \
    '2026-11-10T05:17:22Z,c,added,,,44' >"$J"
  run --separate-stderr lib stats_last_states "$J"
  [ "$status" -eq 0 ]
  [ "$output" = $'a,check_failed,1.0,1.0\nb,held,2.2,2.0\nc,added,,' ]
}

@test "stats_last_states: lines come sorted by package name" {
  printf '%s\n' 'time,package,event,version,previous,run' >"$J"
  for name in zeta alpha mid b-2 b kio-s3 whodb-bin; do
    printf '2026-11-08T05:17:41Z,%s,tracked,1.0,,42\n' "$name" >>"$J"
  done
  run --separate-stderr lib stats_last_states "$J"
  [ "$(cut -d, -f1 <<<"$output" | paste -sd' ')" = "alpha b b-2 kio-s3 mid whodb-bin zeta" ]
}

@test "stats_last_states: a wrong header fails" {
  printf '%s\n' 'time,package' >"$J"
  run --separate-stderr lib stats_last_states "$J"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "stats_event: final statuses map to events, transient ones to nothing" {
  run lib stats_event "updated: 1.1" 1.0
  [ "$status" -eq 0 ]
  [ "$output" = 'updated,1.1' ]
  run lib stats_event "downgrade: 0.9" 1.0
  [ "$output" = 'downgrade,0.9' ]
  run lib stats_event "rebuilt: 1.0" 1.0
  [ "$output" = 'rebuilt,1.0' ]
  run lib stats_event $'check_failed: API down\nline two' 1.0
  [ "$output" = 'check_failed,1.0' ]
  run lib stats_event "update_failed: no" 1.0
  [ "$output" = 'update_failed,1.0' ]
  run lib stats_event up_to_date 1.0
  [ "$output" = 'up_to_date,1.0' ]
  run lib stats_event "cooldown: 2026-11-12" 1.0
  [ "$output" = 'up_to_date,1.0' ]
  for kind in held jump_skipped downgrade_skipped pending; do
    run lib stats_event "$kind: 2.5.0rc1" 2.4.6
    [ "$output" = "$kind,2.5.0rc1" ]
  done
  for kind in new_version available_downgrade new_build; do
    run lib stats_event "$kind: 2.0" 1.0
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "stats_event: a current version outside the alphabet is left empty" {
  run lib stats_event up_to_date "-"
  [ "$output" = 'up_to_date,' ]
  run lib stats_event "check_failed: x" '1.0;rm'
  [ "$output" = 'check_failed,' ]
}

@test "stats_event: an unknown status or version fails with nothing" {
  run --separate-stderr lib stats_event 'held: 1.0;x' 1.0
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run --separate-stderr lib stats_event 'updated: ' 1.0
  [ "$status" -eq 1 ]
  run --separate-stderr lib stats_event $'updated: 1.1\n2' 1.0
  [ "$status" -eq 1 ]
  run --separate-stderr lib stats_event 'exploded: 1.0' 1.0
  [ "$status" -eq 1 ]
  run --separate-stderr lib stats_event 'up_to_date: 1.0' 1.0
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "stats_class: the six ok events share one class" {
  for event in tracked added up_to_date updated downgrade rebuilt; do
    [ "$(lib stats_class "$event")" = ok ]
  done
  for event in held jump_skipped downgrade_skipped pending check_failed update_failed removed; do
    [ "$(lib stats_class "$event")" = "$event" ]
  done
}

# Helper: package $1 at version $2, before and after the run
pkg() {
  mkdir -p "$TEST_TMPDIR/after"
  printf 'name: %s\nstrategy: github-release\nupstream:\n  project: o/%s\ncurrent: %s\n' "$1" "$1" "$2" |
    tee "$TEST_TMPDIR/packages/$1.yml" >"$TEST_TMPDIR/after/$1.yml"
}

# Helper: version $2 of package $1 after the run
after() {
  sed -i "s/^current: .*/current: $2/" "$TEST_TMPDIR/after/$1.yml"
}

# Helper: final status $2 of package $1
st() {
  mkdir -p "$TEST_TMPDIR/statuses"
  printf '%s\n' "$2" >"$TEST_TMPDIR/statuses/$1"
}

# Helper: the journal with the rows given
journal() {
  printf '%s\n' 'time,package,event,version,previous,run' "$@" >"$J"
}

# Helper: record-events.sh over the test tree, at a fixed time and run
record() {
  mkdir -p "$TEST_TMPDIR/after" "$TEST_TMPDIR/statuses"
  AURTOMATOR_STATS_TIME=2026-11-10T05:17:22Z GITHUB_RUN_ID=44 run --separate-stderr \
    "$TEST_TMPDIR/scripts/record-events.sh" --journal "$J" --statuses "$TEST_TMPDIR/statuses" \
    --before "$TEST_TMPDIR/packages" --after "$TEST_TMPDIR/after" --out "$TEST_TMPDIR/out.csv"
}

# Helper: the rows that record added to the journal
added_rows() {
  tail -n "+$(($(wc -l <"$J") + 1))" "$TEST_TMPDIR/out.csv"
}

@test "record-events: a run without a journal writes a tracked row per package" {
  pkg b 2.0
  pkg a 1.0
  st a up_to_date
  st b up_to_date
  record
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/out.csv")" = $'time,package,event,version,previous,run\n2026-11-10T05:17:22Z,a,tracked,1.0,,44\n2026-11-10T05:17:22Z,b,tracked,2.0,,44' ]
  [ ! -e "$J" ]
}

@test "record-events: a push is written with the version before it" {
  pkg a 1.0
  after a 1.1
  st a "updated: 1.1"
  pkg b 2.0
  after b 1.9
  st b "downgrade: 1.9"
  pkg c 3.0
  st c "rebuilt: 3.0"
  journal '2026-11-08T05:17:41Z,a,tracked,1.0,,42' '2026-11-08T05:17:41Z,b,tracked,2.0,,42' \
    '2026-11-08T05:17:41Z,c,tracked,3.0,,42'
  record
  [ "$status" -eq 0 ]
  [ "$(added_rows)" = $'2026-11-10T05:17:22Z,a,updated,1.1,1.0,44\n2026-11-10T05:17:22Z,b,downgrade,1.9,2.0,44\n2026-11-10T05:17:22Z,c,rebuilt,3.0,3.0,44' ]
}

@test "record-events: a push in the run that creates the journal follows its tracked row" {
  pkg a 1.0
  after a 1.1
  st a "updated: 1.1"
  record
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/out.csv")" = $'time,package,event,version,previous,run\n2026-11-10T05:17:22Z,a,tracked,1.0,,44\n2026-11-10T05:17:22Z,a,updated,1.1,1.0,44' ]
}

@test "record-events: --out holds the journal as it was, with its last line ended" {
  pkg a 1.0
  st a up_to_date
  journal '2026-11-08T05:17:41Z,a,tracked,1.0,,42'
  record
  [ "$status" -eq 0 ]
  cmp "$J" "$TEST_TMPDIR/out.csv"
  printf '%s' "$(cat "$J")" >"$J"
  after a 1.1
  st a "updated: 1.1"
  record
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/out.csv")" = $'time,package,event,version,previous,run\n2026-11-08T05:17:41Z,a,tracked,1.0,,42\n2026-11-10T05:17:22Z,a,updated,1.1,1.0,44' ]
  [ -z "$(tail -c 1 "$TEST_TMPDIR/out.csv")" ]
}

@test "record-events: a wrong option, time or run exits 1 and writes nothing" {
  pkg a 1.0
  st a up_to_date
  mkdir -p "$TEST_TMPDIR/after"
  local args=(--journal "$J" --statuses "$TEST_TMPDIR/statuses" --before "$TEST_TMPDIR/packages"
    --after "$TEST_TMPDIR/after" --out "$TEST_TMPDIR/out.csv")
  run --separate-stderr timeout 10 "$TEST_TMPDIR/scripts/record-events.sh" "${args[@]}" --extra
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Unknown option: --extra"* ]]
  run --separate-stderr timeout 10 "$TEST_TMPDIR/scripts/record-events.sh" "${args[@]:0:8}" --out
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--out needs a value"* ]]
  run --separate-stderr timeout 10 "$TEST_TMPDIR/scripts/record-events.sh" "${args[@]:0:8}"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Usage: record-events.sh"* ]]
  AURTOMATOR_STATS_TIME=2026-11-10 run --separate-stderr "$TEST_TMPDIR/scripts/record-events.sh" "${args[@]}"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"AURTOMATOR_STATS_TIME"* ]]
  GITHUB_RUN_ID=4x run --separate-stderr "$TEST_TMPDIR/scripts/record-events.sh" "${args[@]}"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"GITHUB_RUN_ID"* ]]
  run --separate-stderr "$TEST_TMPDIR/scripts/record-events.sh" "${args[@]/#"$TEST_TMPDIR/packages"/"$TEST_TMPDIR/none"}"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--before is not a directory"* ]]
  [ ! -e "$TEST_TMPDIR/out.csv" ]
}

@test "record-events: a failure is written once, and so is the way back" {
  pkg a 1.0
  st a "check_failed: API down"
  journal '2026-11-08T05:17:41Z,a,tracked,1.0,,42'
  record
  [ "$status" -eq 0 ]
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,check_failed,1.0,,44' ]
  journal '2026-11-08T05:17:41Z,a,tracked,1.0,,42' '2026-11-09T05:17:41Z,a,check_failed,1.0,,43'
  record
  [ "$status" -eq 0 ]
  [ -z "$(added_rows)" ]
  st a "update_failed: no push"
  record
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,update_failed,1.0,,44' ]
  st a up_to_date
  record
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,up_to_date,1.0,,44' ]
}

@test "record-events: a failure in the run that creates the journal follows its tracked row" {
  pkg a 1.0
  st a "check_failed: x"
  record
  [ "$status" -eq 0 ]
  [ "$(tail -n +2 "$TEST_TMPDIR/out.csv")" = $'2026-11-10T05:17:22Z,a,tracked,1.0,,44\n2026-11-10T05:17:22Z,a,check_failed,1.0,,44' ]
}

@test "record-events: a wait is written again only for another version" {
  pkg a 2.4.6
  st a "pending: 2.5.0rc1"
  journal '2026-11-08T05:17:41Z,a,tracked,2.4.6,,42'
  record
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,pending,2.5.0rc1,,44' ]
  journal '2026-11-08T05:17:41Z,a,tracked,2.4.6,,42' '2026-11-09T05:17:41Z,a,pending,2.5.0rc1,,43'
  record
  [ -z "$(added_rows)" ]
  st a "pending: 2.5.0rc2"
  record
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,pending,2.5.0rc2,,44' ]
  st a "held: 2.5.0rc1"
  record
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,held,2.5.0rc1,,44' ]
  st a up_to_date
  record
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,up_to_date,2.4.6,,44' ]
}

@test "record-events: a wait for the cooldown counts as up to date" {
  pkg a r2378.06ea49d
  st a "cooldown: 2026-11-12"
  journal '2026-11-08T05:17:41Z,a,updated,r2378.06ea49d,r2370.0aa1111,42'
  record
  [ "$status" -eq 0 ]
  [ -z "$(added_rows)" ]
  [[ "$stderr" != *"maps to no journal event"* ]]
  journal '2026-11-08T05:17:41Z,a,updated,r2378.06ea49d,r2370.0aa1111,42' '2026-11-09T05:17:41Z,a,check_failed,r2378.06ea49d,,43'
  record
  [ "$status" -eq 0 ]
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,up_to_date,r2378.06ea49d,,44' ]
}

@test "record-events: a version that changed without a push of the run" {
  pkg a 1.1
  st a up_to_date
  journal '2026-11-08T05:17:41Z,a,tracked,1.0,,42'
  record
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,updated,1.1,1.0,44' ]
  pkg a 0.9
  record
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,downgrade,0.9,1.0,44' ]
  pkg a 1.0
  after a 1.1
  record
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,updated,1.1,1.0,44' ]
}

@test "record-events: a push names the version the YAML had before the run" {
  pkg a 1.05
  after a 1.1
  st a "updated: 1.1"
  journal '2026-11-08T05:17:41Z,a,tracked,1.0,,42'
  record
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,updated,1.1,1.05,44' ]
}

@test "record-events: a current version outside the alphabet is unknown" {
  pkg a 1.0
  after a "'1.1;x'"
  st a up_to_date
  journal '2026-11-08T05:17:41Z,a,tracked,1.0,,42'
  record
  [ "$status" -eq 0 ]
  [ -z "$(added_rows)" ]
}

@test "record-events: a version change ends a failure as an update" {
  pkg a 1.1
  st a up_to_date
  journal '2026-11-08T05:17:41Z,a,tracked,1.0,,42' '2026-11-09T05:17:41Z,a,check_failed,1.0,,43'
  record
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,updated,1.1,1.0,44' ]
}

@test "record-events: the first version known of a package is no update" {
  pkg a 1.0
  st a up_to_date
  journal '2026-11-08T05:17:41Z,a,added,,,42'
  record
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,up_to_date,1.0,,44' ]
}

@test "record-events: without a YAML after the run, the version before it counts" {
  pkg a 1.1
  rm "$TEST_TMPDIR/after/a.yml"
  st a up_to_date
  journal '2026-11-08T05:17:41Z,a,tracked,1.0,,42'
  record
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,updated,1.1,1.0,44' ]
}

@test "record-events: a new YAML is added, and a gone one removed once" {
  pkg a 1.0
  st a up_to_date
  pkg new 5.0
  st new up_to_date
  journal '2026-11-08T05:17:41Z,a,tracked,1.0,,42' '2026-11-08T05:17:41Z,gone,tracked,3.0,,42'
  record
  [ "$(added_rows)" = $'2026-11-10T05:17:22Z,gone,removed,3.0,,44\n2026-11-10T05:17:22Z,new,added,5.0,,44' ]
  journal '2026-11-08T05:17:41Z,a,tracked,1.0,,42' '2026-11-09T05:17:41Z,gone,removed,3.0,,43' \
    '2026-11-09T05:17:41Z,new,added,5.0,,43'
  record
  [ -z "$(added_rows)" ]
  pkg gone 3.1
  after gone 3.2
  st gone "updated: 3.2"
  record
  [ "$(added_rows)" = $'2026-11-10T05:17:22Z,gone,added,3.1,,44\n2026-11-10T05:17:22Z,gone,updated,3.2,3.1,44' ]
}

@test "record-events: a status a later run publishes, or no status, writes nothing" {
  pkg a 1.0
  st a "new_version: 1.1"
  pkg b 1.0
  pkg c 1.0
  st c "exploded: 1"
  journal '2026-11-08T05:17:41Z,a,tracked,1.0,,42' '2026-11-08T05:17:41Z,b,tracked,1.0,,42' \
    '2026-11-08T05:17:41Z,c,check_failed,1.0,,42'
  record
  [ "$status" -eq 0 ]
  [ -z "$(added_rows)" ]
  [[ "$stderr" == *"The status of c maps to no journal event"* ]]
  [[ "$stderr" != *"status of a"* && "$stderr" != *"status of b"* ]]
}

@test "record-events: a journal that cannot be copied leaves no file behind" {
  pkg a 1.0
  st a up_to_date
  journal '2026-11-08T05:17:41Z,a,tracked,1.0,,42'
  printf '#!/bin/sh\nexit 1\n' >"$MOCK_DIR/cat"
  chmod +x "$MOCK_DIR/cat"
  record
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_TMPDIR/out.csv" ]
  [ ! -e "$TEST_TMPDIR/out.csv.tmp" ]
}

@test "record-events: a wrong header of the journal writes nothing" {
  pkg a 1.0
  st a up_to_date
  printf '%s\n' 'time,package' '2026-11-08T05:17:41Z,a' >"$J"
  record
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_TMPDIR/out.csv" ]
  [[ "$stderr" == *"does not start with the line"* ]]
}

@test "record-events: an invalid row stays in the journal and counts for nothing" {
  pkg a 1.0
  st a "check_failed: x"
  journal '2026-11-08T05:17:41Z,a,tracked,1.0,,42' 'a hand edit' '2026-11-08T05:17:41Z,a,exploded,1.0,,42'
  record
  [ "$status" -eq 0 ]
  [ "$(added_rows)" = '2026-11-10T05:17:22Z,a,check_failed,1.0,,44' ]
  grep -qx 'a hand edit' "$TEST_TMPDIR/out.csv"
  [[ "$stderr" == *"line 3 of $J is not a journal row"* ]]
}

@test "stats_numbers: the windows count days back from the date, the date included" {
  journal '2025-11-08T10:00:00Z,d,updated,1.1,1.0,1' '2025-11-09T10:00:00Z,c,updated,1.1,1.0,1' \
    '2026-10-09T10:00:00Z,c,downgrade,1.0,1.1,1' '2026-10-10T10:00:00Z,b,updated,1.1,1.0,1' \
    '2026-11-01T23:59:59Z,b,rebuilt,1.1,1.1,1' '2026-11-02T00:00:00Z,a,updated,1.1,1.0,1' \
    '2026-11-08T23:59:59Z,a,updated,1.2,1.1,1' '2026-11-09T00:00:00Z,e,updated,1.1,1.0,1'
  run --separate-stderr lib stats_numbers "$J" 2026-11-08
  [ "$status" -eq 0 ]
  [ "$output" = "pushes 2 4 6
packages 1 2 3
added 0 0 0
failed 0 0 0
failing 0
first 365
day 0 1
day 6 1
day 7 1
day 29 1
day 30 1
day 364 1
day 365 1" ]
}

@test "stats_numbers: new packages, moves into a failure and packages failing now" {
  journal '2026-10-01T10:00:00Z,c,added,1.0,,1' '2026-11-01T10:00:00Z,a,tracked,1.0,,1' \
    '2026-11-02T10:00:00Z,b,added,1.0,,1' '2026-11-03T10:00:00Z,a,check_failed,1.0,,1' \
    '2026-11-04T10:00:00Z,a,up_to_date,1.0,,1' '2026-11-05T10:00:00Z,a,update_failed,1.0,,1' \
    '2026-11-06T10:00:00Z,c,check_failed,1.0,,1' '2026-11-07T10:00:00Z,c,removed,1.0,,1' \
    '2026-11-07T10:00:00Z,d,tracked,1.0,,1' '2026-11-07T11:00:00Z,d,update_failed,1.0,,1' \
    '2026-11-08T10:00:00Z,a,updated,1.1,1.0,1' '2026-11-08T11:00:00Z,a,check_failed,1.1,,1' \
    '2026-11-09T10:00:00Z,b,check_failed,1.0,,1'
  run --separate-stderr lib stats_numbers "$J" 2026-11-08
  [ "$status" -eq 0 ]
  [ "$output" = "pushes 1 1 1
packages 1 1 1
added 1 1 2
failed 5 5 5
failing 2
first 38
day 0 1" ]
}

@test "stats_numbers: a journal without rows has no first day" {
  journal
  run --separate-stderr lib stats_numbers "$J" 2026-11-08
  [ "$status" -eq 0 ]
  [ "$output" = $'pushes 0 0 0\npackages 0 0 0\nadded 0 0 0\nfailed 0 0 0\nfailing 0' ]
}

# Helper: stats-card.sh over the journal and packages/ on day $1
card() {
  mkdir -p "$TEST_TMPDIR/card"
  AURTOMATOR_STATS_DATE="$1" run --separate-stderr "$TEST_TMPDIR/scripts/stats-card.sh" --journal "$J" \
    --packages "$TEST_TMPDIR/packages" --name aur-packages --out "$TEST_TMPDIR/card"
}

# Helper: x and y of each cell in the group of card $1 with fill $2
cells() {
  awk -v fill="fill=\"$2\"" '/^<g / { on = index($0, fill) > 0; next } /^<\/g>/ { on = 0 }
    on { match($0, /x="[^"]*" y="[^"]*"/); print substr($0, RSTART, RLENGTH) }' "$1"
}

# Helper: $2 rows of an update of a package on day $1
pushes() {
  local i
  for ((i = 0; i < $2; i++)); do
    printf '%sT10:00:00Z,p%s,updated,1.1,1.0,1\n' "$1" "$i" >>"$J"
  done
}

@test "stats-card: a year of journal gives the cards of the fixtures" {
  local fixtures="$PROJECT_DIR/tests/fixtures/stats" name
  cp "$fixtures/events.csv" "$J"
  # Every package of the journal but those it removed
  for name in $(awk -F, 'NR > 1 { last[$2] = $3 } END { for (p in last) if (last[p] != "removed") print p }' "$J"); do
    touch "$TEST_TMPDIR/packages/$name.yml"
  done
  card 2026-11-08
  [ "$status" -eq 0 ]
  cmp "$TEST_TMPDIR/card/card.svg" "$fixtures/card.svg"
  cmp "$TEST_TMPDIR/card/card-dark.svg" "$fixtures/card-dark.svg"
}

@test "stats-card: the pushes of a day set the level of its cell" {
  journal '2026-10-28T10:00:00Z,p0,tracked,1.0,,1'
  pushes 2026-11-02 6
  pushes 2026-11-03 5
  pushes 2026-11-04 4
  pushes 2026-11-05 3
  pushes 2026-11-06 2
  pushes 2026-11-07 1
  card 2026-11-07
  [ "$status" -eq 0 ]
  local svg="$TEST_TMPDIR/card/card.svg"
  [ "$(cells "$svg" '#c4e3f5')" = 'x="632" y="310"' ]
  [ "$(cells "$svg" '#74bde6')" = $'x="632" y="288"\nx="632" y="299"' ]
  [ "$(cells "$svg" '#1793d1')" = $'x="632" y="266"\nx="632" y="277"' ]
  [ "$(cells "$svg" '#0e6a9e')" = 'x="632" y="255"' ]
  [ "$(cells "$svg" '#eff2f5')" = $'x="621" y="277"\nx="621" y="288"\nx="621" y="299"\nx="621" y="310"\nx="632" y="244"' ]
  [ "$(cells "$svg" none | wc -l)" -eq 360 ]
  [ "$(cells "$TEST_TMPDIR/card/card-dark.svg" '#62bdf0')" = 'x="632" y="255"' ]
}

@test "stats-card: a column longer than the journal is headed with its first day" {
  journal '2026-11-06T10:00:00Z,a,tracked,1.0,,1'
  card 2026-11-08
  [ "$status" -eq 0 ]
  [ "$(grep -c '>since Nov 6</text>' "$TEST_TMPDIR/card/card.svg")" -eq 3 ]
  [ "$(cells "$TEST_TMPDIR/card/card.svg" none | wc -l)" -eq 362 ]
  journal '2026-11-02T10:00:00Z,a,tracked,1.0,,1'
  card 2026-11-08
  grep -q '>7 days</text>' "$TEST_TMPDIR/card/card.svg"
  [ "$(grep -c '>since Nov 2</text>' "$TEST_TMPDIR/card/card.svg")" -eq 2 ]
  journal '2026-10-10T10:00:00Z,a,tracked,1.0,,1'
  card 2026-11-08
  grep -q '>30 days</text>' "$TEST_TMPDIR/card/card.svg"
  grep -q '>since Oct 10</text>' "$TEST_TMPDIR/card/card.svg"
  journal '2025-11-09T10:00:00Z,a,tracked,1.0,,1'
  card 2026-11-08
  grep -q '>365 days</text>' "$TEST_TMPDIR/card/card.svg"
  run ! grep -q '>since ' "$TEST_TMPDIR/card/card.svg"
}

@test "stats-card: the header counts the packages and those failing now" {
  touch "$TEST_TMPDIR/packages/a.yml" "$TEST_TMPDIR/packages/b.yml" "$TEST_TMPDIR/packages/notes.txt"
  journal '2026-11-01T10:00:00Z,a,tracked,1.0,,1' '2026-11-01T10:00:00Z,b,tracked,1.0,,1'
  card 2026-11-08
  [ "$status" -eq 0 ]
  grep -q '<tspan font-weight="600" fill="#1f2328">2</tspan> packages</text>' "$TEST_TMPDIR/card/card.svg"
  run ! grep -q failing "$TEST_TMPDIR/card/card.svg"
  printf '%s\n' '2026-11-07T10:00:00Z,b,check_failed,1.0,,2' >>"$J"
  rm "$TEST_TMPDIR/packages/a.yml"
  card 2026-11-08
  grep -q '<tspan font-weight="600" fill="#1f2328">1</tspan> package <tspan fill="#cf222e">· 1 failing</tspan></text>' "$TEST_TMPDIR/card/card.svg"
  grep -q '<tspan fill="#f85149">· 1 failing</tspan>' "$TEST_TMPDIR/card/card-dark.svg"
}

@test "stats-card: a month label two weeks after the last one is left out" {
  journal '2025-10-01T10:00:00Z,a,tracked,1.0,,1'
  card 2026-10-20
  [ "$status" -eq 0 ]
  grep -qx '<text x="60" y="238" font-size="11" fill="#818b98">Oct</text>' "$TEST_TMPDIR/card/card.svg"
  run ! grep -q '>Nov</text>' "$TEST_TMPDIR/card/card.svg"
  grep -qx '<text x="137" y="238" font-size="11" fill="#818b98">Dec</text>' "$TEST_TMPDIR/card/card.svg"
}

@test "stats-card: the header names the day of the card" {
  journal '2026-11-01T10:00:00Z,a,tracked,1.0,,1'
  card 2026-11-08
  [ "$status" -eq 0 ]
  grep -qx '<text x="656" y="54" font-size="12" text-anchor="end" fill="#59636e">updated Nov 8, 2026</text>' "$TEST_TMPDIR/card/card.svg"
  grep -qx '<text x="656" y="54" font-size="12" text-anchor="end" fill="#9198a1">updated Nov 8, 2026</text>' "$TEST_TMPDIR/card/card-dark.svg"
  card 2027-01-31
  grep -qx '<text x="656" y="54" font-size="12" text-anchor="end" fill="#59636e">updated Jan 31, 2027</text>' "$TEST_TMPDIR/card/card.svg"
}

@test "stats-card: a long repository name is cut short of the package count" {
  journal '2026-11-01T10:00:00Z,a,tracked,1.0,,1'
  mkdir -p "$TEST_TMPDIR/card"
  local name
  for name in 12345678901234567890123456789012 123456789012345678901234567890123; do
    AURTOMATOR_STATS_DATE=2026-11-08 run --separate-stderr "$TEST_TMPDIR/scripts/stats-card.sh" --journal "$J" \
      --packages "$TEST_TMPDIR/packages" --name "$name" --out "$TEST_TMPDIR/card"
    [ "$status" -eq 0 ]
  done
  grep -q '>123456789012345678901234567890\.\.\.</text>' "$TEST_TMPDIR/card/card.svg"
  AURTOMATOR_STATS_DATE=2026-11-08 run --separate-stderr "$TEST_TMPDIR/scripts/stats-card.sh" --journal "$J" \
    --packages "$TEST_TMPDIR/packages" --name 12345678901234567890123456789012 --out "$TEST_TMPDIR/card"
  grep -q '>12345678901234567890123456789012</text>' "$TEST_TMPDIR/card/card.svg"
}

@test "stats-card: the packages updated come before the pushes" {
  journal '2026-11-01T10:00:00Z,a,tracked,1.0,,1' '2026-11-05T10:00:00Z,a,updated,1.1,1.0,2' \
    '2026-11-06T10:00:00Z,a,updated,1.2,1.1,3'
  card 2026-11-08
  [ "$status" -eq 0 ]
  local svg="$TEST_TMPDIR/card/card.svg"
  grep -qx '<text x="24" y="120" font-size="14" fill="#1f2328">Packages updated</text>' "$svg"
  grep -qx '<text x="436" y="120" font-size="16" font-weight="600" text-anchor="end" fill="#1f2328">1</text>' "$svg"
  grep -qx '<text x="24" y="148" font-size="14" fill="#1f2328">Pushes to AUR</text>' "$svg"
  grep -qx '<text x="436" y="148" font-size="16" font-weight="600" text-anchor="end" fill="#1f2328">2</text>' "$svg"
}

@test "stats-card: numbers above zero take the color of their row" {
  journal '2026-11-01T10:00:00Z,a,tracked,1.0,,1' '2026-11-02T10:00:00Z,b,added,1.0,,1' \
    '2026-11-03T10:00:00Z,a,check_failed,1.0,,1' '2026-11-04T10:00:00Z,a,updated,1.1,1.0,1'
  card 2026-11-08
  [ "$status" -eq 0 ]
  local svg="$TEST_TMPDIR/card/card.svg"
  grep -q '<text x="436" y="120" font-size="16" font-weight="600" text-anchor="end" fill="#1f2328">1</text>' "$svg"
  grep -q '<text x="436" y="148" font-size="16" font-weight="600" text-anchor="end" fill="#1f2328">1</text>' "$svg"
  grep -q '<text x="436" y="176" font-size="16" font-weight="600" text-anchor="end" fill="#1a7f37">1</text>' "$svg"
  grep -q '<text x="436" y="204" font-size="16" font-weight="600" text-anchor="end" fill="#cf222e">1</text>' "$svg"
  journal '2026-11-01T10:00:00Z,a,tracked,1.0,,1'
  card 2026-11-08
  [ "$(grep -c 'font-size="16" font-weight="600" text-anchor="end" fill="#818b98">0</text>' "$svg")" -eq 12 ]
  grep -q '<tspan font-weight="600" fill="#1f2328">0</tspan> pushes in the last year</text>' "$svg"
  pushes 2026-11-08 1
  card 2026-11-08
  grep -q '<tspan font-weight="600" fill="#1f2328">1</tspan> push in the last year</text>' "$svg"
}

@test "stats-card: the same journal and day give the same bytes" {
  journal '2026-11-01T10:00:00Z,a,tracked,1.0,,1'
  pushes 2026-11-05 3
  card 2026-11-08
  [ "$status" -eq 0 ]
  cp "$TEST_TMPDIR/card/card.svg" "$TEST_TMPDIR/first.svg"
  cp "$TEST_TMPDIR/card/card-dark.svg" "$TEST_TMPDIR/first-dark.svg"
  card 2026-11-08
  cmp "$TEST_TMPDIR/card/card.svg" "$TEST_TMPDIR/first.svg"
  cmp "$TEST_TMPDIR/card/card-dark.svg" "$TEST_TMPDIR/first-dark.svg"
  run ! cmp -s "$TEST_TMPDIR/card/card.svg" "$TEST_TMPDIR/card/card-dark.svg"
}

@test "stats-card: a wrong name, day, option or path exits 1 and draws nothing" {
  journal '2026-11-01T10:00:00Z,a,tracked,1.0,,1'
  mkdir -p "$TEST_TMPDIR/card"
  local args=(--journal "$J" --packages "$TEST_TMPDIR/packages" --name aur-packages --out "$TEST_TMPDIR/card")
  local script="$TEST_TMPDIR/scripts/stats-card.sh"
  run --separate-stderr timeout 10 "$script" "${args[@]}" --extra
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Unknown option: --extra"* ]]
  run --separate-stderr timeout 10 "$script" "${args[@]:0:6}" --out
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--out needs a value"* ]]
  run --separate-stderr "$script" "${args[@]:0:6}"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Usage: stats-card.sh"* ]]
  run --separate-stderr "$script" "${args[@]/aur-packages/a/b}"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--name"* ]]
  for day in 2026-11-8 2026-13-01 2026-02-30 tomorrow; do
    AURTOMATOR_STATS_DATE="$day" run --separate-stderr "$script" "${args[@]}"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"AURTOMATOR_STATS_DATE"* ]]
  done
  run --separate-stderr "$script" "${args[@]/#"$J"/"$TEST_TMPDIR/none.csv"}"
  [ "$status" -eq 1 ]
  run --separate-stderr "$script" "${args[@]/#"$TEST_TMPDIR/card"/"$TEST_TMPDIR/none"}"
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$TEST_TMPDIR/card")" ]
}
