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
