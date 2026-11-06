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
