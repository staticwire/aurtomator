#!/usr/bin/env bats

load helpers/setup.sh

SETUP_DOC="$BATS_TEST_DIRNAME/../docs/SETUP.md"
RUNNER="$BATS_TEST_DIRNAME/../aurtomator.sh"

# Commits the files of a fake aurtomator to the work tree $1: a sample that
# holds $2, scripts/show-args.sh, which prints what it got and exits with
# SHOW_STATUS, the same script as scripts/setup.sh and scripts/draft.sh,
# documented commands, scripts/lib.sh, a library that is not executable, as
# in aurtomator, and the directory scripts/show
commit_aurtomator() {
  mkdir -p "$1/scripts/show" "$1/packages"
  : >"$1/scripts/show/.keep"
  printf 'name: %s\n' "$2" >"$1/packages/example.yml.sample"
  cat >"$1/scripts/show-args.sh" <<'EOF'
#!/usr/bin/env bash
echo "data: $AURTOMATOR_DATA_DIR"
echo "runner: $AURTOMATOR_RUNNER"
printf 'arg: %s\n' "$@"
exit "${SHOW_STATUS:-0}"
EOF
  chmod +x "$1/scripts/show-args.sh"
  cp -p "$1/scripts/show-args.sh" "$1/scripts/setup.sh"
  cp -p "$1/scripts/show-args.sh" "$1/scripts/draft.sh"
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

  # aurtomator has two releases, and the calling workflow pins the first
  git init -q "$TEST_TMPDIR/work"
  PINNED=$(commit_aurtomator "$TEST_TMPDIR/work" pinned)
  TIP=$(commit_aurtomator "$TEST_TMPDIR/work" tip)
  git -C "$TEST_TMPDIR/work" tag v1.0.0 "$PINNED"
  git -C "$TEST_TMPDIR/work" tag v1.1.0 "$TIP"
  publish staticwire/aurtomator "$TEST_TMPDIR/work"

  REPO="$TEST_TMPDIR/repo"
  mkdir -p "$REPO/.github/workflows" "$REPO/packages"
  # bashcov counts the lines of the runner in the root through this link
  ln -s "$RUNNER" "$REPO/aurtomator.sh"
  pin "staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED"
}

teardown() {
  teardown_test_env
}

@test "runner: aurtomator.sh in the root is the runner, and SETUP.md holds its curl command" {
  [ -x "$RUNNER" ]
  [ "$(head -n 1 "$RUNNER")" = "#!/usr/bin/env bash" ]
  grep -qx 'set -euo pipefail' "$RUNNER"
  run grep -c -x '#!/usr/bin/env bash' "$SETUP_DOC"
  [ "$output" = 0 ]
  grep -qxF 'curl -fsSL -o aurtomator.sh https://raw.githubusercontent.com/staticwire/aurtomator/vX.Y.Z/aurtomator.sh' "$SETUP_DOC"
}

@test "runner: prints the sample of the pinned commit" {
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: pinned" ]
}

@test "runner: runs a script with the repository as the data directory" {
  cd "$REPO/packages"
  run ../aurtomator.sh setup one "two words"
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
  git -C "$TEST_TMPDIR/fork" tag v9.0.0
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
  local pin
  for pin in v0.8.0 "${PINNED}0"; do
    pin "staticwire/aurtomator/.github/workflows/check-updates.yml@$pin"
    run "$REPO/aurtomator.sh" sample
    [ "$status" -eq 1 ]
    [ "$output" = "No commit SHA pinned in .github/workflows/check-updates.yml" ]
  done
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

@test "runner: names yq when it is missing" {
  mkdir "$TEST_TMPDIR/bin"
  ln -s "$(command -v bash)" "$TEST_TMPDIR/bin/"
  run env PATH="$TEST_TMPDIR/bin" "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "$REPO/aurtomator.sh needs yq: https://github.com/mikefarah/yq" ]
}

@test "runner: names a missing check-updates.yml" {
  rm "$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "No .github/workflows/check-updates.yml in $REPO" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

# A hand edit can keep the old pin as a comment, and a pull request can add
# one: the repository and the commit both come from the uses: line
@test "runner: takes the pin from the uses: line, not from a comment" {
  cat >"$REPO/.github/workflows/check-updates.yml" <<EOF
jobs:
  check-updates:
    # was: uses: someone/aurtomator-fork/.github/workflows/check-updates.yml@$TIP # vX.Y.Z
    uses: staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED # vX.Y.Z
    # was: uses: staticwire/aurtomator/.github/workflows/check-updates.yml@$TIP # vX.Y.Z
EOF
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: pinned" ]
  run ls -A "$XDG_CACHE_HOME/aurtomator"
  [ "$output" = "$PINNED" ]
}

@test "runner: stops when two uses: lines pin check-updates.yml" {
  cat >"$REPO/.github/workflows/check-updates.yml" <<EOF
jobs:
  one:
    uses: staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED # vX.Y.Z
  two:
    uses: staticwire/aurtomator/.github/workflows/check-updates.yml@$TIP # vX.Y.Z
EOF
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "More than one uses: line pins check-updates.yml in .github/workflows/check-updates.yml" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

# GitHub reads YAML: a line in a block of text is no uses: line for it, and a
# pin in quotes is one
@test "runner: stops when GitHub reads a pin in quotes beside a uses: line in a text" {
  cat >"$REPO/.github/workflows/check-updates.yml" <<EOF
on:
  workflow_dispatch:
    inputs:
      note:
        description: |
          uses: staticwire/aurtomator/.github/workflows/check-updates.yml@$TIP # vX.Y.Z
jobs:
  check-updates:
    uses: "staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED" # vX.Y.Z
EOF
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "Write the pin of check-updates.yml in .github/workflows/check-updates.yml on one uses: line without quotes. GitHub reads:" ]
  [ "${lines[1]}" = "  staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED" ]
  [ "${#lines[@]}" -eq 2 ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

@test "runner: stops when GitHub reads the pin on the line after uses:" {
  cat >"$REPO/.github/workflows/check-updates.yml" <<EOF
env:
  NOTE: |
    uses: staticwire/aurtomator/.github/workflows/check-updates.yml@$TIP # vX.Y.Z
jobs:
  check-updates:
    uses:
      staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED
EOF
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "${lines[1]}" = "  staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

@test "runner: stops when GitHub reads a pin through an alias" {
  cat >"$REPO/.github/workflows/check-updates.yml" <<EOF
env:
  PIN: &pin staticwire/aurtomator/.github/workflows/check-updates.yml@$TIP
jobs:
  check-updates:
    uses: *pin
  other:
    uses: staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED # vX.Y.Z
EOF
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "${lines[1]}" = "  staticwire/aurtomator/.github/workflows/check-updates.yml@$TIP" ]
  [ "${lines[2]}" = "  staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

@test "runner: stops when GitHub reads no pin of check-updates.yml" {
  cat >"$REPO/.github/workflows/check-updates.yml" <<EOF
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: |
          uses: staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED # vX.Y.Z
EOF
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "Write the pin of check-updates.yml in .github/workflows/check-updates.yml on one uses: line without quotes. GitHub reads:" ]
  [ "${lines[1]}" = "  none" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

# The fetch of each run waits a second, so both find no copy and fetch
@test "runner: two first runs of a pin at once leave one copy" {
  local bin="$TEST_TMPDIR/slow" one two
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\n[[ " $* " != *" fetch "* ]] || sleep 1\nexec %q "$@"\n' "$(command -v git)" >"$bin/git"
  chmod +x "$bin/git"
  PATH="$bin:$PATH" "$REPO/aurtomator.sh" sample >"$TEST_TMPDIR/one.out" 2>&1 &
  one=$!
  PATH="$bin:$PATH" "$REPO/aurtomator.sh" sample >"$TEST_TMPDIR/two.out" 2>&1 &
  two=$!
  wait "$one"
  wait "$two"
  [ "$(cat "$TEST_TMPDIR/one.out")" = "name: pinned" ]
  [ "$(cat "$TEST_TMPDIR/two.out")" = "name: pinned" ]
  run ls -A "$XDG_CACHE_HOME/aurtomator"
  [ "$output" = "$PINNED" ]
  run ls -A "$XDG_CACHE_HOME/aurtomator/$PINNED"
  [[ "$output" != *"$PINNED"* ]]
}

@test "runner: lists the documented commands for a command that names no script" {
  run "$REPO/aurtomator.sh"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "Usage: $REPO/aurtomator.sh <command> [argument...]" ]
  [ "${lines[1]}" = "Commands: setup draft sample validate-pkg check-update update-pkg check-all pin" ]

  local command
  for command in "" nope lib ../scripts/show-args Show-args show-args.sh show/../show-args show-args/x; do
    run "$REPO/aurtomator.sh" "$command"
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "Usage: $REPO/aurtomator.sh <command> [argument...]" ]
    [ "${lines[1]}" = "Commands: setup draft sample validate-pkg check-update update-pkg check-all pin" ]
  done
}

# publish-pkg, verify-pkg and the like are steps of the CI jobs
@test "runner: warns before a script that is no documented command" {
  run "$REPO/aurtomator.sh" show-args one
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Warning: show-args is a step of the CI jobs, not a documented command" ]
  [ "${lines[1]}" = "data: $REPO" ]
  run "$REPO/aurtomator.sh" setup one
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "data: $REPO" ]
  run "$REPO/aurtomator.sh" draft one
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "data: $REPO" ]
}

# GitHub serves the commits of every fork under the name of the parent
@test "runner: warns when no tag of the repository is at the pin" {
  local untagged annotated
  untagged=$(commit_aurtomator "$TEST_TMPDIR/work" untagged)
  annotated=$(commit_aurtomator "$TEST_TMPDIR/work" annotated)
  git -C "$TEST_TMPDIR/work" -c user.name=t -c user.email=t@example.com tag -a v1.2.0 -m release "$annotated"
  publish staticwire/aurtomator "$TEST_TMPDIR/work"

  pin "staticwire/aurtomator/.github/workflows/check-updates.yml@$untagged"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Warning: no tag of staticwire/aurtomator points to $untagged, check where the pin comes from" ]
  [ "${lines[1]}" = "name: untagged" ]
  # The copy is there, and the check runs before a fetch only
  run "$REPO/aurtomator.sh" sample
  [ "$output" = "name: untagged" ]

  pin "staticwire/aurtomator/.github/workflows/check-updates.yml@$annotated"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: annotated" ]
}

@test "runner: the first run of a pin removes the copies made over 30 days ago" {
  local cache="$XDG_CACHE_HOME/aurtomator" old=0000000000000000000000000000000000000001 recent=0000000000000000000000000000000000000002
  mkdir -p "$cache/$old" "$cache/$recent" "$cache/cafe"
  touch -d '40 days ago' "$cache/$old" "$cache/cafe"
  touch -d '10 days ago' "$cache/$recent"

  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ ! -e "$cache/$old" ]
  [ -d "$cache/$recent" ]
  [ -d "$cache/cafe" ]
  [ -d "$cache/$PINNED" ]

  # A run with its copy in place removes nothing
  mkdir "$cache/$old"
  touch -d '40 days ago' "$cache/$old"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ -d "$cache/$old" ]
}

# A run at the same time can remove its directory while find reads, and
# find then fails: the cleanup must not stop the command
@test "runner: a failed cleanup of the cache stops nothing" {
  local cache="$XDG_CACHE_HOME/aurtomator" old=0000000000000000000000000000000000000001 bin="$TEST_TMPDIR/norm"
  mkdir -p "$cache/$old" "$bin"
  touch -d '40 days ago' "$cache/$old"
  printf '#!/bin/sh\ncase "$*" in *%s*) echo "rm: cannot remove" >&2; exit 1 ;; esac\nexec %q "$@"\n' "$old" "$(command -v rm)" >"$bin/rm"
  chmod +x "$bin/rm"

  PATH="$bin:$PATH" run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: pinned" ]
  [ -d "$cache/$old" ]
}

# Writes the two calling workflows with every uses: line at the pin $1 and
# its comment $2, a uses: line of another repository, a comment line and a
# pin one digit too long
calling_workflows() {
  cat >"$REPO/.github/workflows/check-updates.yml" <<EOF
jobs:
  check-updates:
    uses: staticwire/aurtomator/.github/workflows/check-updates.yml@$1 # $2
  other:
    uses: someone/else/.github/workflows/other.yml@$1 # $2
  notify:
    # uses: staticwire/aurtomator/.github/workflows/notify-failure.yml@$1 # $2
    uses: staticwire/aurtomator/.github/workflows/notify-failure.yml@$1 # $2
EOF
  cat >"$REPO/.github/workflows/validate.yml" <<EOF
jobs:
  validate:
    uses: staticwire/aurtomator/.github/workflows/validate.yml@$1 # $2
  typo:
    uses: staticwire/aurtomator/.github/workflows/validate.yml@${1}0 # $2
EOF
}

@test "runner: pin moves every uses: line of aurtomator to the commit of a tag" {
  calling_workflows "$PINNED" v1.0.0
  run "$REPO/aurtomator.sh" pin v1.1.0
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = ".github/workflows/check-updates.yml:3:    uses: staticwire/aurtomator/.github/workflows/check-updates.yml@$TIP # v1.1.0" ]
  [ "${lines[1]}" = ".github/workflows/check-updates.yml:8:    uses: staticwire/aurtomator/.github/workflows/notify-failure.yml@$TIP # v1.1.0" ]
  [ "${lines[2]}" = ".github/workflows/validate.yml:3:    uses: staticwire/aurtomator/.github/workflows/validate.yml@$TIP # v1.1.0" ]
  [ "${#lines[@]}" -eq 3 ]
  grep -qxF "    uses: someone/else/.github/workflows/other.yml@$PINNED # v1.0.0" "$REPO/.github/workflows/check-updates.yml"
  grep -qxF "    # uses: staticwire/aurtomator/.github/workflows/notify-failure.yml@$PINNED # v1.0.0" "$REPO/.github/workflows/check-updates.yml"
  grep -qxF "    uses: staticwire/aurtomator/.github/workflows/validate.yml@${PINNED}0 # v1.0.0" "$REPO/.github/workflows/validate.yml"
  # pin fetches nothing
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

@test "runner: pin needs no aurtomator line in validate.yml, nor the file" {
  calling_workflows "$PINNED" v1.0.0
  printf 'jobs: {}\n' >"$REPO/.github/workflows/validate.yml"
  run "$REPO/aurtomator.sh" pin v1.1.0
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]

  rm "$REPO/.github/workflows/validate.yml"
  run "$REPO/aurtomator.sh" pin v1.0.0
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ ! -e "$REPO/.github/workflows/validate.yml" ]
}

@test "runner: pin takes the commit of an annotated tag" {
  git -C "$TEST_TMPDIR/work" -c user.name=t -c user.email=t@example.com tag -a v1.2.0 -m release "$TIP"
  publish staticwire/aurtomator "$TEST_TMPDIR/work"
  calling_workflows "$PINNED" v1.0.0

  run "$REPO/aurtomator.sh" pin v1.2.0
  [ "$status" -eq 0 ]
  grep -qxF "    uses: staticwire/aurtomator/.github/workflows/validate.yml@$TIP # v1.2.0" "$REPO/.github/workflows/validate.yml"
}

@test "runner: pin stops before it changes a file when GitHub reads a pin it cannot move" {
  calling_workflows "$PINNED" v1.0.0
  cat >"$REPO/.github/workflows/validate.yml" <<EOF
jobs:
  validate:
    uses: "staticwire/aurtomator/.github/workflows/validate.yml@$PINNED" # v1.0.0
EOF
  cp -r "$REPO/.github/workflows" "$TEST_TMPDIR/before"

  run "$REPO/aurtomator.sh" pin v1.1.0
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "Write each pin of staticwire/aurtomator in .github/workflows/validate.yml on one uses: line without quotes. GitHub reads:" ]
  [ "${lines[1]}" = "  staticwire/aurtomator/.github/workflows/validate.yml@$PINNED" ]
  [ "${#lines[@]}" -eq 2 ]
  diff -r "$TEST_TMPDIR/before" "$REPO/.github/workflows"
}

@test "runner: pin stops when GitHub reads a pin of validate.yml through an alias" {
  calling_workflows "$PINNED" v1.0.0
  cat >"$REPO/.github/workflows/validate.yml" <<EOF
env:
  PIN: &pin staticwire/aurtomator/.github/workflows/validate.yml@$PINNED
jobs:
  validate:
    uses: *pin
EOF
  cp -r "$REPO/.github/workflows" "$TEST_TMPDIR/before"

  run "$REPO/aurtomator.sh" pin v1.1.0
  [ "$status" -eq 1 ]
  [ "${lines[1]}" = "  staticwire/aurtomator/.github/workflows/validate.yml@$PINNED" ]
  diff -r "$TEST_TMPDIR/before" "$REPO/.github/workflows"
}

@test "runner: pin refuses a tag that names no commit SHA" {
  calling_workflows "$PINNED" v1.0.0
  cp -r "$REPO/.github/workflows" "$TEST_TMPDIR/before"
  printf '#!/usr/bin/env bash\n[[ "$1" == ls-remote ]] && exec printf "&\\trefs/tags/v1.1.0\\n"\nexec /usr/bin/git "$@"\n' >"$MOCK_DIR/git"
  chmod +x "$MOCK_DIR/git"

  run "$REPO/aurtomator.sh" pin v1.1.0
  [ "$status" -eq 1 ]
  [ "$output" = "Tag v1.1.0 of staticwire/aurtomator names no commit SHA" ]
  diff -r "$TEST_TMPDIR/before" "$REPO/.github/workflows"
}

@test "runner: pin refuses a tag the repository lacks and an argument of another form" {
  calling_workflows "$PINNED" v1.0.0
  cp -r "$REPO/.github/workflows" "$TEST_TMPDIR/before"

  run "$REPO/aurtomator.sh" pin v9.9.9
  [ "$status" -eq 1 ]
  [ "$output" = "No tag v9.9.9 in staticwire/aurtomator" ]
  local args
  for args in "" 1.1.0 "v1.1.0 v1.2.0" v1.1 "v1.1.0x" xv1.1.0; do
    # shellcheck disable=SC2086
    run "$REPO/aurtomator.sh" pin $args
    [ "$status" -eq 1 ]
    [ "$output" = "Usage: $REPO/aurtomator.sh pin vX.Y.Z" ]
  done
  diff -r "$TEST_TMPDIR/before" "$REPO/.github/workflows"
}
