#!/usr/bin/env bats

load helpers/setup.sh

SETUP_DOC="$BATS_TEST_DIRNAME/../docs/SETUP.md"

# Prints the script aurtomator.sh of the template: the fenced bash block of
# docs/SETUP.md that starts with a shebang
runner_script() {
  awk '
    /^```bash$/ { start = NR + 1; next }
    NR == start && $0 == "#!/usr/bin/env bash" { inside = 1 }
    inside && /^```$/ { exit }
    inside { print }
  ' "$SETUP_DOC"
}

# Commits the files of a fake aurtomator to the work tree $1: a sample that
# holds $2, scripts/show-args.sh, which prints what it got and exits with
# SHOW_STATUS, and scripts/lib.sh, a library that is not executable, as in
# aurtomator
commit_aurtomator() {
  mkdir -p "$1/scripts" "$1/packages"
  printf 'name: %s\n' "$2" >"$1/packages/example.yml.sample"
  cat >"$1/scripts/show-args.sh" <<'EOF'
#!/usr/bin/env bash
echo "data: $AURTOMATOR_DATA_DIR"
echo "runner: $AURTOMATOR_RUNNER"
printf 'arg: %s\n' "$@"
exit "${SHOW_STATUS:-0}"
EOF
  chmod +x "$1/scripts/show-args.sh"
  echo 'echo "lib.sh ran"' >"$1/scripts/lib.sh"
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@example.com commit -q -m "$2"
  git -C "$1" rev-parse HEAD
}

# Publishes the work tree $2 as the GitHub repository $1
publish() {
  rm -rf "$TEST_TMPDIR/github/$1"
  git clone -q --bare "$2" "$TEST_TMPDIR/github/$1"
}

# Writes the calling workflow of the repository with the uses: line $1
pin() {
  printf 'jobs:\n  check-updates:\n    uses: %s # vX.Y.Z\n' "$1" >"$REPO/.github/workflows/check-updates.yml"
}

setup() {
  setup_test_env
  export XDG_CACHE_HOME="$TEST_TMPDIR/cache"

  # https://github.com/<owner>/<repo> is $TEST_TMPDIR/github/<owner>/<repo>
  git config --global url."file://$TEST_TMPDIR/github/".insteadOf https://github.com/

  # aurtomator has two commits, and the calling workflow pins the first
  git init -q "$TEST_TMPDIR/work"
  PINNED=$(commit_aurtomator "$TEST_TMPDIR/work" pinned)
  TIP=$(commit_aurtomator "$TEST_TMPDIR/work" tip)
  publish staticwire/aurtomator "$TEST_TMPDIR/work"

  REPO="$TEST_TMPDIR/repo"
  mkdir -p "$REPO/.github/workflows" "$REPO/packages"
  runner_script >"$REPO/aurtomator.sh"
  chmod +x "$REPO/aurtomator.sh"
  pin "staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED"
}

teardown() {
  teardown_test_env
}

@test "runner: SETUP.md holds the script once" {
  run grep -A 1 -x '```bash' "$SETUP_DOC"
  [ "$status" -eq 0 ]
  [ "$(grep -c -x '#!/usr/bin/env bash' <<<"$output")" -eq 1 ]
  [ "$(head -n 1 "$REPO/aurtomator.sh")" = "#!/usr/bin/env bash" ]
  grep -qx 'set -euo pipefail' "$REPO/aurtomator.sh"
}

@test "runner: prints the sample of the pinned commit" {
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: pinned" ]
}

@test "runner: runs a script with the repository as the data directory" {
  cd "$REPO/packages"
  run ../aurtomator.sh show-args one "two words"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "data: $REPO" ]
  [ "${lines[1]}" = "runner: ../aurtomator.sh" ]
  [ "${lines[2]}" = "arg: one" ]
  [ "${lines[3]}" = "arg: two words" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "runner: exits with the status of the script" {
  SHOW_STATUS=3 run "$REPO/aurtomator.sh" show-args
  [ "$status" -eq 3 ]
}

@test "runner: fetches a pin once and keeps the copy" {
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$(git -C "$XDG_CACHE_HOME/aurtomator/$PINNED" rev-parse HEAD)" = "$PINNED" ]

  rm -rf "$TEST_TMPDIR/github"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: pinned" ]
}

@test "runner: fetches the commit of a new pin" {
  run "$REPO/aurtomator.sh" sample
  [ "$output" = "name: pinned" ]

  pin "staticwire/aurtomator/.github/workflows/check-updates.yml@$TIP"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: tip" ]
  [ -d "$XDG_CACHE_HOME/aurtomator/$PINNED" ]
  [ -d "$XDG_CACHE_HOME/aurtomator/$TIP" ]
  # The copy holds the commit without the history before it
  [ "$(git -C "$XDG_CACHE_HOME/aurtomator/$TIP" rev-list --count HEAD)" -eq 1 ]
}

@test "runner: fetches from the repository of the uses: line" {
  git init -q "$TEST_TMPDIR/fork"
  local forked
  forked=$(commit_aurtomator "$TEST_TMPDIR/fork" forked)
  publish someone/aurtomator-fork "$TEST_TMPDIR/fork"
  pin "someone/aurtomator-fork/.github/workflows/check-updates.yml@$forked"

  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: forked" ]
}

@test "runner: keeps the copy in ~/.cache without XDG_CACHE_HOME" {
  unset XDG_CACHE_HOME
  export HOME="$TEST_TMPDIR/home"

  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ -d "$HOME/.cache/aurtomator/$PINNED" ]
}

@test "runner: a failed fetch leaves nothing in the cache" {
  pin "staticwire/aurtomator/.github/workflows/check-updates.yml@0123456789abcdef0123456789abcdef01234567"

  run "$REPO/aurtomator.sh" sample
  [ "$status" -ne 0 ]
  [ -d "$XDG_CACHE_HOME/aurtomator" ]
  [ -z "$(ls -A "$XDG_CACHE_HOME/aurtomator")" ]
}

@test "runner: stops when check-updates.yml pins no commit" {
  pin "staticwire/aurtomator/.github/workflows/check-updates.yml@v0.8.0"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "No commit SHA pinned in .github/workflows/check-updates.yml" ]

  rm "$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "No commit SHA pinned in .github/workflows/check-updates.yml" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

@test "runner: lists the commands for a command that names no script" {
  run "$REPO/aurtomator.sh"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "Usage: $REPO/aurtomator.sh <command> [argument...]" ]
  [ "${lines[1]}" = "Commands: sample show-args" ]

  local command
  for command in "" nope lib ../scripts/show-args Show-args show-args.sh; do
    run "$REPO/aurtomator.sh" "$command"
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "Usage: $REPO/aurtomator.sh <command> [argument...]" ]
    [ "${lines[1]}" = "Commands: sample show-args" ]
  done
}
