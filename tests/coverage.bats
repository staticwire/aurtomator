#!/usr/bin/env bats

load helpers/setup.sh

setup() {
  setup_test_env
  FIXTURE="$TEST_TMPDIR/fixture"
  mkdir -p "$FIXTURE" "$TEST_TMPDIR/tmp"
}

teardown() {
  teardown_test_env
}

# Helper: skip without bashcov, except in CI, which installs it
require_bashcov() {
  command -v bashcov &>/dev/null && return 0
  if [[ -n "${CI:-}" ]]; then
    echo "bashcov is not installed, and CI installs it" >&2
    return 1
  fi
  skip "bashcov not installed"
}

# Helper: a project with demo.sh and demo.bats. demo.sh runs its line 4
# 2000 times and traces 10 KB each time. The one test of demo.bats links
# demo.sh into its test directory, as the suite links the scripts, and runs
# the body given in $1.
make_fixture() {
  cat >"$FIXTURE/demo.sh" <<'EOF'
#!/usr/bin/env bash
pad=$(printf '%010000d' 0)
for ((i = 0; i < 2000; i++)); do
  : "$pad"
done
EOF
  chmod +x "$FIXTURE/demo.sh"
  cat >"$FIXTURE/demo.bats" <<EOF
load "$PROJECT_DIR/tests/helpers/setup.sh"
setup() {
  setup_test_env
  ln -s "$FIXTURE/demo.sh" "\$TEST_TMPDIR/demo.sh"
}
teardown() {
  teardown_test_env
}
@test "demo" {
  $1
}
EOF
}

# Helper: bashcov through bashcov-bats.sh on the fixture. SimpleCov reads
# .simplecov from the current directory. The suite may itself run under
# bashcov-bats.sh, so the variable it sets for the tests is cleared here.
run_bashcov() {
  run env -u AURTOMATOR_KEEP_TEST_DIRS TMPDIR="$TEST_TMPDIR/tmp" bash -c '
    cd "$1" && timeout 120 bashcov --skip-uncovered --root "$1" -- "$2" demo.bats' \
    _ "$FIXTURE" "$PROJECT_DIR/tests/helpers/bashcov-bats.sh"
}

# Helper: the hits of line $1 of demo.sh in the fixture's coverage results
demo_hits() {
  jq -r --arg file "$(realpath "$FIXTURE/demo.sh")" --argjson index "$(($1 - 1))" \
    '[.[].coverage[$file].lines[$index]] | add' "$FIXTURE/coverage/.resultset.json"
}

@test "teardown_test_env keeps the directory while AURTOMATOR_KEEP_TEST_DIRS is set" {
  AURTOMATOR_KEEP_TEST_DIRS=1 teardown_test_env
  [ -d "$TEST_TMPDIR/scripts" ]
  AURTOMATOR_KEEP_TEST_DIRS='' teardown_test_env
  [ ! -e "$TEST_TMPDIR" ]
}

# Run as a child, demo.sh traces each line once, while bats traces a line
# of the test twice. 20 MB of trace in a burst is more than bashcov reads in
# time from a pipe that Ruby opens in non-blocking mode.
@test "bashcov-bats.sh: bashcov counts every run of a line" {
  require_bashcov
  make_fixture '"$TEST_TMPDIR/demo.sh"'
  run_bashcov
  [ "$status" -eq 0 ]
  run demo_hits 4
  [ "$output" = "2000" ]
}

@test "bashcov-bats.sh: keeps the test directories in its own directory until bashcov exits" {
  require_bashcov
  make_fixture "printf '%s\n' \"\$TMPDIR\" \"\${AURTOMATOR_KEEP_TEST_DIRS:-}\" >'$FIXTURE/env.out'"
  run_bashcov
  [ "$status" -eq 0 ]
  mapfile -t env_out <"$FIXTURE/env.out"
  [ "$(dirname "${env_out[0]}")" = "$TEST_TMPDIR/tmp" ]
  [ "${env_out[1]}" = "1" ]
  # removed by a process that polls for bashcov once a second
  for _ in {1..10}; do
    [[ -e "${env_out[0]}" ]] || break
    sleep 0.5
  done
  [ ! -e "${env_out[0]}" ]
}

@test "bashcov-bats.sh: exits with the status of bats" {
  require_bashcov
  make_fixture 'false'
  run_bashcov
  [ "$status" -eq 1 ]
  [[ "$output" == *"not ok 1 demo"* ]]
}
