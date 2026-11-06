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
  [ "$output" = $'a\tcheck_failed\t1.0\t1.0\nb\theld\t2.2\t2.0\nc\tadded\t\t' ]
}

@test "stats_last_states: lines come sorted by package name" {
  printf '%s\n' 'time,package,event,version,previous,run' >"$J"
  for name in zeta alpha mid b-2 b kio-s3 whodb-bin; do
    printf '2026-11-08T05:17:41Z,%s,tracked,1.0,,42\n' "$name" >>"$J"
  done
  run --separate-stderr lib stats_last_states "$J"
  [ "$(cut -f1 <<<"$output" | paste -sd' ')" = "alpha b b-2 kio-s3 mid whodb-bin zeta" ]
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
  [ "$output" = $'updated\t1.1' ]
  run lib stats_event "downgrade: 0.9" 1.0
  [ "$output" = $'downgrade\t0.9' ]
  run lib stats_event "rebuilt: 1.0" 1.0
  [ "$output" = $'rebuilt\t1.0' ]
  run lib stats_event $'check_failed: API down\nline two' 1.0
  [ "$output" = $'check_failed\t1.0' ]
  run lib stats_event "update_failed: no" 1.0
  [ "$output" = $'update_failed\t1.0' ]
  run lib stats_event up_to_date 1.0
  [ "$output" = $'up_to_date\t1.0' ]
  for kind in held jump_skipped downgrade_skipped pending; do
    run lib stats_event "$kind: 2.5.0rc1" 2.4.6
    [ "$output" = "$kind"$'\t2.5.0rc1' ]
  done
  for kind in new_version available_downgrade new_build; do
    run lib stats_event "$kind: 2.0" 1.0
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "stats_event: a current version outside the alphabet is left empty" {
  run lib stats_event up_to_date "-"
  [ "$output" = $'up_to_date\t' ]
  run lib stats_event "check_failed: x" '1.0;rm'
  [ "$output" = $'check_failed\t' ]
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
