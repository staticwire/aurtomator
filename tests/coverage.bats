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

# Helper: a project whose demo.sh runs its line 4 2000 times with 10 KB of trace each, and whose
# one test links demo.sh into its test directory, as the suite links the scripts, and runs $1
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

# Helper: bashcov through bashcov-bats.sh, run in the fixture for its .simplecov and without the
# AURTOMATOR_KEEP_TEST_DIRS that bashcov-bats.sh sets when the suite itself runs under it
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

# 20 MB of trace in a burst is more than bashcov reads in time from a pipe that Ruby opens in
# non-blocking mode. As a child, demo.sh traces each line once; bats traces a test line twice.
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
