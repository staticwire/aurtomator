#!/usr/bin/env bats

load helpers/setup.sh
bats_require_minimum_version 1.5.0

SETUP_DOC="$BATS_TEST_DIRNAME/../site/src/content/docs/setup.md"
RUNNER="$BATS_TEST_DIRNAME/../aurtomator.sh"

# Commits a fake aurtomator to the work tree $1: a sample holding $2, scripts/show-args.sh and its
# copies setup.sh and draft.sh, a lib.sh that is not executable, and a directory scripts/show
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

# Writes the calling workflow of the repository with the uses: line $1 and the release $2 after it,
# v1.0.0 by default
pin() {
  printf 'jobs:\n  check-updates:\n    uses: %s # %s\n' "$1" "${2:-v1.0.0}" >"$REPO/.github/workflows/check-updates.yml"
}

# Helper: a stat that shows the directories $@ with the owner that a user namespace gives the
# accounts it does not map
mock_unmapped() {
  local real
  real=$(command -v stat)
  printf '%s\n' "$@" >"$TEST_TMPDIR/unmapped"
  cat >"$MOCK_DIR/stat" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "-c %u %a" ]] && grep -qxF -- "\${@: -1}" "$TEST_TMPDIR/unmapped"; then
  echo "\$(cat /proc/sys/kernel/overflowuid) \$("$real" -c %a -- "\${@: -1}")"
  exit 0
fi
exec "$real" "\$@"
EOF
  chmod +x "$MOCK_DIR/stat"
}

setup() {
  setup_test_env
  export XDG_CACHE_HOME="$TEST_TMPDIR/cache"
  # Directories above the home directory may show an unmapped owner in a user namespace
  export HOME="$TEST_TMPDIR/home"
  mkdir -m 0700 "$HOME"

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

@test "runner: aurtomator.sh in the root is the runner, and the Setup page holds its curl command" {
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

  pin "staticwire/aurtomator/.github/workflows/check-updates.yml@$TIP" v1.1.0
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: tip" ]
  [ -d "$XDG_CACHE_HOME/aurtomator/$PINNED" ]
  [ -d "$XDG_CACHE_HOME/aurtomator/$TIP" ]
  # The copy holds the commit without the history before it
  [ "$(git -C "$XDG_CACHE_HOME/aurtomator/$TIP" rev-list --count HEAD)" -eq 1 ]
}

@test "runner: refuses a pin of another repository, and a fork names its own in aurtomator.sh" {
  git init -q "$TEST_TMPDIR/fork"
  local forked fork_repo="$TEST_TMPDIR/fork-repo"
  forked=$(commit_aurtomator "$TEST_TMPDIR/fork" forked)
  git -C "$TEST_TMPDIR/fork" tag v9.0.0
  publish Someone/Aurtomator-Fork "$TEST_TMPDIR/fork"
  pin "someone/aurtomator-fork/.github/workflows/check-updates.yml@$forked" v9.0.0

  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = ".github/workflows/check-updates.yml pins someone/aurtomator-fork, and this aurtomator.sh runs the pins of staticwire/aurtomator only" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]

  # bashcov finds the file of a traced line by its path after the line ran, so the link
  # stays, and the copy of the fork goes into a repository of its own
  mkdir -p "$fork_repo/.github/workflows"
  cp "$REPO/.github/workflows/check-updates.yml" "$fork_repo/.github/workflows/"
  sed 's|^repo=staticwire/aurtomator$|repo=Someone/Aurtomator-Fork|' "$RUNNER" >"$fork_repo/aurtomator.sh"
  chmod +x "$fork_repo/aurtomator.sh"
  run "$fork_repo/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: forked" ]
  run "$fork_repo/aurtomator.sh" check-pins
  [ "$status" -eq 0 ]
  [ "$output" = ".github/workflows/check-updates.yml:3:    uses: someone/aurtomator-fork/.github/workflows/check-updates.yml@$forked # v9.0.0" ]
}

@test "runner: reads the release after a pin up to its end" {
  pin "staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED" v1.0.0-rc1
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "Write the release after the pin in .github/workflows/check-updates.yml, as ./aurtomator.sh pin vX.Y.Z does: @$PINNED # vX.Y.Z" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

@test "runner: keeps the copy in ~/.cache without XDG_CACHE_HOME" {
  unset XDG_CACHE_HOME
  export HOME="$TEST_TMPDIR/home"

  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ -d "$HOME/.cache/aurtomator/$PINNED" ]
}

@test "runner: a failed fetch leaves nothing in the cache" {
  printf '#!/usr/bin/env bash\nfor a; do [[ "$a" != fetch ]] || exit 1; done\nexec /usr/bin/git "$@"\n' >"$MOCK_DIR/git"
  chmod +x "$MOCK_DIR/git"

  run "$REPO/aurtomator.sh" sample
  [ "$status" -ne 0 ]
  [ -d "$XDG_CACHE_HOME/aurtomator" ]
  [ -z "$(ls -A "$XDG_CACHE_HOME/aurtomator")" ]
}

@test "runner: names the pin GitHub reads when no uses: line shows it" {
  local form
  for form in "\"staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED\"" \
    "'staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED'"; do
    printf '%s\n' 'on: push' 'jobs:' '  check-updates:' "    uses: $form # vX.Y.Z" >"$REPO/.github/workflows/check-updates.yml"
    run "$REPO/aurtomator.sh" sample
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "Write the pin of check-updates.yml in .github/workflows/check-updates.yml on one uses: line without quotes. GitHub reads:" ]
    [ "${lines[1]}" = "  staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED" ]
  done
  printf '%s\n' 'on: push' "x-pin: &pin staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED" \
    'jobs:' '  check-updates:' '    uses: *pin' >"$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "${lines[1]}" = "  staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
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

@test "runner: refuses a mikefarah/yq older than the scripts need" {
  mkdir "$TEST_TMPDIR/bin"
  printf '%s\n' '#!/bin/sh' 'if [ "$1" = --version ]; then' \
    '  echo "yq (https://github.com/mikefarah/yq/) version 4.12.0"' '  exit 0' 'fi' \
    'echo "Error: unknown shorthand flag: '"'"'r'"'"' in -r" >&2' 'exit 1' >"$TEST_TMPDIR/bin/yq"
  chmod +x "$TEST_TMPDIR/bin/yq"
  run env PATH="$TEST_TMPDIR/bin:$PATH" "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "$REPO/aurtomator.sh needs a newer mikefarah/yq, and this yq prints: yq (https://github.com/mikefarah/yq/) version 4.12.0" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

@test "runner: refuses a mikefarah/yq without kind" {
  local real
  real=$(command -v yq)
  mkdir "$TEST_TMPDIR/bin"
  printf '%s\n' '#!/bin/sh' 'if [ "$1" = --version ]; then' \
    '  echo "yq (https://github.com/mikefarah/yq/) version 4.35.2"' '  exit 0' 'fi' \
    'case "$*" in *kind*) echo "Error: unknown operator kind" >&2 && exit 1 ;; esac' \
    "exec $real \"\$@\"" >"$TEST_TMPDIR/bin/yq"
  chmod +x "$TEST_TMPDIR/bin/yq"
  run env PATH="$TEST_TMPDIR/bin:$PATH" "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "$REPO/aurtomator.sh needs a newer mikefarah/yq, and this yq prints: yq (https://github.com/mikefarah/yq/) version 4.35.2" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

@test "runner: refuses a yq that is not mikefarah/yq" {
  mkdir "$TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "yq 3.4.3"\necho "second line"\n' >"$TEST_TMPDIR/bin/yq"
  chmod +x "$TEST_TMPDIR/bin/yq"
  run env PATH="$TEST_TMPDIR/bin:$PATH" "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "$REPO/aurtomator.sh needs mikefarah/yq, go-yq on Arch, and this yq prints: yq 3.4.3" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

@test "runner: names a missing check-updates.yml" {
  rm "$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "No .github/workflows/check-updates.yml in $REPO" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

# Hand edits can keep the old pin as a comment, and pull requests can add
# one: the repository and the commit both come from the uses: line
@test "runner: takes the pin from the uses: line, not from a comment" {
  cat >"$REPO/.github/workflows/check-updates.yml" <<EOF
jobs:
  check-updates:
    # was: uses: someone/aurtomator-fork/.github/workflows/check-updates.yml@$TIP # vX.Y.Z
    uses: staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED # v1.0.0
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

# Writes the calling workflow $1, with GOOD put in for the pin at $PINNED
# and EVIL for a pin of another repository
shape() {
  local good="staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED"
  local evil="evil/aurtomator/.github/workflows/check-updates.yml@eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  sed -e "s|GOOD|$good|g" -e "s|EVIL|$evil|g" <<<"$1" >"$REPO/.github/workflows/check-updates.yml"
}

@test "runner: stops at a merge key before it fetches" {
  shape $'x-base: &e\n  uses: EVIL\njobs:\n  check-updates:\n    <<: *e'
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = ".github/workflows/check-updates.yml holds a merge key (<<)" ]
  shape $'x-base: &e\n  uses: EVIL\njobs:\n  check-updates:\n    uses: "GOOD"\n    <<: *e'
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = ".github/workflows/check-updates.yml holds a merge key (<<)" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

@test "runner: stops at a key twice in one mapping before it fetches" {
  local file
  for file in $'jobs:\n  check-updates:\n    uses: "GOOD"\n    uses: EVIL' \
    $'jobs:\n  check-updates:\n    uses: "GOOD"\n  check-updates:\n    uses: EVIL' \
    $'jobs:\n  check-updates:\n    uses: "GOOD"\njobs:\n  check-updates:\n    uses: EVIL'; do
    shape "$file"
    run "$REPO/aurtomator.sh" sample
    [ "$status" -eq 1 ]
    [ "$output" = ".github/workflows/check-updates.yml holds a key twice in one mapping" ]
  done
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

@test "runner: stops at a second YAML document before it fetches" {
  shape $'jobs:\n  check-updates:\n    uses: EVIL\n---\n- a'
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = ".github/workflows/check-updates.yml holds more than one YAML document" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

@test "runner: prints the error of yq for a file it cannot read" {
  printf 'jobs:\n\tcheck-updates:\n' >"$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "yq cannot read .github/workflows/check-updates.yml:" ]
  [[ "${lines[1]}" == "  Error: "* ]]
  [ "${#lines[@]}" -eq 2 ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

# The top level is a list, and its block of text holds the uses: line, so
# check_shape passes the file and yq fails on .jobs
@test "runner: stops with the error of yq when yq fails to read a pin" {
  printf -- '- |\n  uses: staticwire/aurtomator/.github/workflows/check-updates.yml@%s # vX.Y.Z\n' "$PINNED" \
    >"$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [[ "${lines[0]}" == "Error: "* ]]
  [ "${#lines[@]}" -eq 1 ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]

  pin "staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED"
  printf -- '- |\n  uses: staticwire/aurtomator/.github/workflows/validate.yml@%s # v1.0.0\n' "$PINNED" \
    >"$REPO/.github/workflows/validate.yml"
  cp -r "$REPO/.github/workflows" "$TEST_TMPDIR/before"
  run "$REPO/aurtomator.sh" pin v1.1.0
  [ "$status" -eq 1 ]
  [[ "${lines[0]}" == "Error: "* ]]
  [ "${#lines[@]}" -eq 1 ]
  diff -r "$TEST_TMPDIR/before" "$REPO/.github/workflows"
}

@test "runner: reads a file with an anchor and an alias" {
  printf 'x-secrets: &s\n  KEY: value\njobs:\n  check-updates:\n    uses: %s # v1.0.0\n    secrets: *s\n' \
    "staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED" >"$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: pinned" ]
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
  [ "${lines[1]}" = "Commands: setup draft sample validate-pkg check-update update-pkg check-all pin check-pins" ]

  local command
  for command in "" nope lib ../scripts/show-args Show-args show-args.sh show/../show-args show-args/x; do
    run "$REPO/aurtomator.sh" "$command"
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "Usage: $REPO/aurtomator.sh <command> [argument...]" ]
    [ "${lines[1]}" = "Commands: setup draft sample validate-pkg check-update update-pkg check-all pin check-pins" ]
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
@test "runner: refuses a pin that is not the commit of the release after it" {
  local untagged annotated
  untagged=$(commit_aurtomator "$TEST_TMPDIR/work" untagged)
  annotated=$(commit_aurtomator "$TEST_TMPDIR/work" annotated)
  git -C "$TEST_TMPDIR/work" -c user.name=t -c user.email=t@example.com tag -a v1.2.0 -m release "$annotated"
  publish staticwire/aurtomator "$TEST_TMPDIR/work"

  pin "staticwire/aurtomator/.github/workflows/check-updates.yml@$untagged" v1.0.0
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "The pin $untagged in .github/workflows/check-updates.yml is not the commit of v1.0.0 of staticwire/aurtomator; ./aurtomator.sh pin vX.Y.Z pins the commit of a release" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]

  # The commit of an older release under the name of a newer one
  pin "staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED" v1.1.0
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "The pin $PINNED in .github/workflows/check-updates.yml is not the commit of v1.1.0 of staticwire/aurtomator; ./aurtomator.sh pin vX.Y.Z pins the commit of a release" ]

  pin "staticwire/aurtomator/.github/workflows/check-updates.yml@$annotated" v1.2.0
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: annotated" ]
}

@test "runner: refuses a pin without the release after it" {
  printf 'jobs:\n  check-updates:\n    uses: %s\n' "staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED" \
    >"$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "Write the release after the pin in .github/workflows/check-updates.yml, as ./aurtomator.sh pin vX.Y.Z does: @$PINNED # vX.Y.Z" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

@test "runner: names the repository whose tags it cannot list" {
  rm -rf "$TEST_TMPDIR/github/staticwire/aurtomator"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "Could not list the tags of staticwire/aurtomator" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

# Another repository can still run a copy that it fetched long ago, when a new pin cleans the cache
@test "runner: the cleanup counts the age of a copy from its last run" {
  local cache="$XDG_CACHE_HOME/aurtomator"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  touch -d '40 days ago' "$cache/$PINNED"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  pin "staticwire/aurtomator/.github/workflows/check-updates.yml@$TIP" v1.1.0
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: tip" ]
  [ -d "$cache/$PINNED" ]
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

  # Runs with their copy in place remove nothing
  mkdir "$cache/$old"
  touch -d '40 days ago' "$cache/$old"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ -d "$cache/$old" ]
}

# Runs at the same time can remove their directory while find reads, and
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

# SIGKILL ends a run before its EXIT trap removes the directory of the fetch
@test "runner: the first run of a pin removes the fetch directories of killed runs made over 30 days ago" {
  local cache="$XDG_CACHE_HOME/aurtomator" old=0000000000000000000000000000000000000001
  mkdir -p "$cache/$old.abc123" "$cache/$old.def456"
  touch -d '40 days ago' "$cache/$old.abc123"
  touch -d '10 days ago' "$cache/$old.def456"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ ! -e "$cache/$old.abc123" ]
  [ -d "$cache/$old.def456" ]
}

# Hooks of a linked worktree run with absolute GIT_DIR and GIT_INDEX_FILE of the user repository
@test "runner: a first run with the git variables of a hook leaves their repository as it was" {
  local user="$TEST_TMPDIR/user"
  git init -q "$user"
  echo text >"$user/file"
  git -C "$user" add file
  git -C "$user" -c user.name=t -c user.email=t@example.com commit -q -m init
  cp "$user/.git/config" "$TEST_TMPDIR/config.before"
  cp "$user/.git/index" "$TEST_TMPDIR/index.before"
  GIT_DIR="$user/.git" GIT_INDEX_FILE="$user/.git/index" run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: pinned" ]
  cmp "$user/.git/config" "$TEST_TMPDIR/config.before"
  cmp "$user/.git/index" "$TEST_TMPDIR/index.before"
  [ ! -e "$user/.git/FETCH_HEAD" ]
  [ "$(git -C "$XDG_CACHE_HOME/aurtomator/$PINNED" rev-parse HEAD)" = "$PINNED" ]
}

# Accounts that can write the cache, as with XDG_CACHE_HOME=/tmp, can make the copy during a fetch
@test "runner: runs no copy that another process made during the fetch" {
  local bin="$TEST_TMPDIR/race" copy="$XDG_CACHE_HOME/aurtomator/$PINNED"
  mkdir -p "$bin"
  cat >"$bin/git" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" fetch "* ]]; then
  mkdir -p "$copy/scripts"
  printf '#!/bin/sh\necho planted\n' >"$copy/scripts/setup.sh"
  chmod +x "$copy/scripts/setup.sh"
fi
exec $(command -v git) "\$@"
EOF
  chmod +x "$bin/git"
  PATH="$bin:$PATH" run "$REPO/aurtomator.sh" setup x
  [ "$status" -eq 1 ]
  [[ "$output" != *planted* ]]
  [[ "$output" == *"$copy appeared during the fetch and is no checkout of $PINNED that only you can write; remove it, then run $REPO/aurtomator.sh again"* ]]
}

@test "runner: fetches a damaged copy again" {
  local copy="$XDG_CACHE_HOME/aurtomator/$PINNED" arg
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  # Files deleted by a cleaner, CRLF line ends, and a regular file in place of the copy
  for arg in missing crlf file; do
    case "$arg" in
      missing) rm "$copy/scripts/setup.sh" ;;
      crlf) sed -i 's/$/\r/' "$copy/scripts/setup.sh" ;;
      file) rm -rf "$copy" && echo junk >"$copy" ;;
    esac
    run "$REPO/aurtomator.sh" setup "$arg"
    [ "$status" -eq 0 ] && [[ "$output" == *"The copy of aurtomator in $copy is damaged or writable by others, so it is fetched again"* ]] &&
      [[ "$output" == *"arg: $arg"* ]] || {
      echo "$arg: $output"
      return 1
    }
  done
  [ -d "$copy" ]
}

@test "runner: checks the copy out with LF line ends under core.autocrlf" {
  git config --global core.autocrlf true
  run "$REPO/aurtomator.sh" setup x
  [ "$status" -eq 0 ]
  run ! grep -q $'\r' "$XDG_CACHE_HOME/aurtomator/$PINNED/scripts/setup.sh"
}

# The copy holds the code that runs next with the keys and the gh login of the user
@test "runner: fetches again a copy that others can write and refuses a link in its place" {
  local copy="$XDG_CACHE_HOME/aurtomator/$PINNED"
  run "$REPO/aurtomator.sh" sample
  chmod g+w "$copy/scripts"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [[ "$output" == *"is damaged or writable by others, so it is fetched again"* ]]
  [ -z "$(find "$copy" ! -type l -perm /022)" ]

  rm -rf "$copy"
  mkdir "$TEST_TMPDIR/elsewhere"
  ln -s "$TEST_TMPDIR/elsewhere" "$copy"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "$copy is a link or belongs to another user; remove it, then run $REPO/aurtomator.sh again" ]
}

# Accounts that can rename what a directory holds can swap the copy between its check and its run
@test "runner: runs no copy from a directory that others can write" {
  local dir="$XDG_CACHE_HOME/aurtomator"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  chmod g+w "$dir"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "$dir belongs to another account or lets group or others write it, and they could swap the copy of aurtomator in it before it runs; make it yours with no write access for group and others, or set XDG_CACHE_HOME to another directory" ]

  chmod g-w "$dir"
  chmod o+w "$XDG_CACHE_HOME"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [[ "$output" == "$XDG_CACHE_HOME belongs to another account or lets group or others write it"* ]]

  # The sticky bit of /tmp keeps others from renaming what they do not own
  chmod +t "$XDG_CACHE_HOME"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: pinned" ]
}

# Accounts that can rename what a directory above the cache holds can swap the whole cache
@test "runner: runs no copy below a directory above the cache that others can write" {
  local above="$TEST_TMPDIR/shared"
  mkdir -p "$above/cache"
  chmod 0700 "$above/cache"
  chmod 0777 "$above"
  XDG_CACHE_HOME="$above/cache" run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "$above belongs to another account or lets group or others write it, and they could swap the copy of aurtomator below it before it runs; set XDG_CACHE_HOME to a directory with no such directory above it" ]
  [ ! -e "$above/cache/aurtomator/$PINNED" ]

  chmod +t "$above"
  XDG_CACHE_HOME="$above/cache" run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: pinned" ]
}

# User namespaces show accounts they do not map, root of the host among them, with the overflow
# uid, and whoever can rename what a directory above the home directory holds can swap the home too
@test "runner: takes directories above the home directory that show the owner of a user namespace" {
  local dir=$TEST_TMPDIR above=()
  while [[ "$dir" == /?* ]]; do
    above+=("$dir")
    dir=${dir%/*}
  done
  mock_unmapped "${above[@]}" /
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: pinned" ]
}

@test "runner: names the user namespace for a directory that shows its owner and is not above the home directory" {
  local other="$TEST_TMPDIR/other" uid
  uid=$(cat /proc/sys/kernel/overflowuid)
  mkdir -m 0755 "$other"
  mock_unmapped "$other"
  XDG_CACHE_HOME="$other/cache" run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "$other shows the owner $uid, which a user namespace gives the accounts it does not map, so the script cannot tell whether another account could swap the copy of aurtomator below it; set XDG_CACHE_HOME to a directory below your home directory, or run the script outside the namespace" ]
  [ ! -e "$other/cache/aurtomator/$PINNED" ]
}

@test "runner: runs no copy below a directory above the home directory that shows the owner of a user namespace and others can write" {
  chmod 0777 "$TEST_TMPDIR"
  mock_unmapped "$TEST_TMPDIR"
  run "$REPO/aurtomator.sh" sample
  chmod 0700 "$TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [ "$output" = "$TEST_TMPDIR belongs to another account or lets group or others write it, and they could swap the copy of aurtomator below it before it runs; set XDG_CACHE_HOME to a directory with no such directory above it" ]
}

# The check of the directories above reads the path of a new cache at its target too
@test "runner: makes a new cache below a link to a directory of the user" {
  mkdir -p "$TEST_TMPDIR/real-parent"
  chmod 0700 "$TEST_TMPDIR/real-parent"
  ln -s "$TEST_TMPDIR/real-parent" "$TEST_TMPDIR/link-parent"
  XDG_CACHE_HOME="$TEST_TMPDIR/link-parent/cache" run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: pinned" ]
  [ -d "$TEST_TMPDIR/real-parent/cache/aurtomator/$PINNED" ]
}

# The owner of a link in a directory with the sticky bit can point it elsewhere after the check
@test "runner: runs no copy through a link at the aurtomator directory of the cache" {
  local real="$TEST_TMPDIR/real"
  mkdir -p "$XDG_CACHE_HOME" "$real"
  chmod 0700 "$real"
  chmod 1777 "$XDG_CACHE_HOME"
  ln -s "$real" "$XDG_CACHE_HOME/aurtomator"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = "$XDG_CACHE_HOME/aurtomator is a link, which its owner could point elsewhere before the copy of aurtomator in it runs; make it a directory, or set XDG_CACHE_HOME to another directory" ]
  [ -z "$(ls -A "$real")" ]
}

# Links in the path of the cache count at their target, which the run reads once
@test "runner: takes a cache whose path is a link to a directory of the user" {
  local real="$TEST_TMPDIR/real-cache"
  mkdir -p "$real"
  chmod 0700 "$real"
  ln -s "$real" "$TEST_TMPDIR/link-cache"
  XDG_CACHE_HOME="$TEST_TMPDIR/link-cache" run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$output" = "name: pinned" ]
  [ -d "$real/aurtomator/$PINNED" ]
}

@test "runner: fetches nothing into a directory that others can write" {
  mkdir -p "$XDG_CACHE_HOME/aurtomator"
  chmod 0777 "$XDG_CACHE_HOME/aurtomator"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [[ "$output" == "$XDG_CACHE_HOME/aurtomator belongs to another account or lets group or others write it"* ]]
  [ -z "$(ls -A "$XDG_CACHE_HOME/aurtomator")" ]
}

@test "runner: makes the cache directories with no access for group and others" {
  umask 0002
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$XDG_CACHE_HOME" "$XDG_CACHE_HOME/aurtomator")" = $'700\n700' ]
}

# The XDG Base Directory Specification calls a relative path invalid
@test "runner: ignores a relative XDG_CACHE_HOME" {
  local planted="$TEST_TMPDIR/cwd/rel-cache/aurtomator/$PINNED/scripts"
  mkdir -p "$planted"
  printf '#!/usr/bin/env bash\necho planted\n' >"$planted/setup.sh"
  chmod +x "$planted/setup.sh"
  export HOME="$TEST_TMPDIR/home"
  cd "$TEST_TMPDIR/cwd"
  XDG_CACHE_HOME=rel-cache run "$REPO/aurtomator.sh" setup x
  [ "$status" -eq 0 ]
  [[ "$output" != *planted* ]]
  [[ "$output" == *"arg: x"* ]]
  [ -d "$HOME/.cache/aurtomator/$PINNED" ]
}

@test "runner: names the file and the tag of a job uses: value that is no text" {
  printf 'jobs:\n  check-updates:\n    uses: staticwire/aurtomator/.github/workflows/check-updates.yml@%s # v1.0.0\n  odd:\n    uses: 123\n' \
    "$PINNED" >"$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" sample
  [ "$status" -eq 1 ]
  [ "$output" = ".github/workflows/check-updates.yml holds a uses: value with the tag !!int; write every uses: value as plain text" ]
}

# Writes the two calling workflows with every uses: line at pin $1 and comment $2, plus a uses:
# line of another repository, a comment line and a pin one digit too long
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

# GitHub finds a repository by its name in any case
@test "runner: pin moves a pin of aurtomator spelled in another case" {
  calling_workflows "$PINNED" v1.0.0
  sed -i 's|^    uses: staticwire/aurtomator/\(.github/workflows/notify-failure.yml\)|    uses: StaticWire/Aurtomator/\1|' \
    "$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" pin v1.1.0
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = ".github/workflows/check-updates.yml:3:    uses: staticwire/aurtomator/.github/workflows/check-updates.yml@$TIP # v1.1.0" ]
  [ "${lines[1]}" = ".github/workflows/check-updates.yml:8:    uses: StaticWire/Aurtomator/.github/workflows/notify-failure.yml@$TIP # v1.1.0" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "runner: pin moves the pins of aurtomator in steps and without a path, which check-pins checks" {
  cat >"$REPO/.github/workflows/check-updates.yml" <<EOF
jobs:
  check-updates:
    uses: staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED # v1.0.0
  extra:
    runs-on: ubuntu-latest
    steps:
      - uses: staticwire/aurtomator/.github/actions/run-as-builder@$PINNED # v1.0.0
      - uses: staticwire/aurtomator@$PINNED # v1.0.0
EOF
  run "$REPO/aurtomator.sh" pin v1.1.0
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  grep -qxF "      - uses: staticwire/aurtomator/.github/actions/run-as-builder@$TIP # v1.1.0" "$REPO/.github/workflows/check-updates.yml"
  grep -qxF "      - uses: staticwire/aurtomator@$TIP # v1.1.0" "$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
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

@test "runner: pin stops at a merge key in validate.yml and changes no file" {
  printf 'x: &v\n  uses: %s\njobs:\n  validate:\n    <<: *v\n' \
    "staticwire/aurtomator/.github/workflows/validate.yml@$PINNED" >"$REPO/.github/workflows/validate.yml"
  cp -r "$REPO/.github/workflows" "$TEST_TMPDIR/before"
  run "$REPO/aurtomator.sh" pin v1.1.0
  [ "$status" -eq 1 ]
  [ "$output" = ".github/workflows/validate.yml holds a merge key (<<)" ]
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

# Writes the calling workflows of the template with every pin of aurtomator at $1 and release
# $2: the job pins in both, an action of aurtomator in a step and a pin in a comment
template_workflows() {
  cat >"$REPO/.github/workflows/check-updates.yml" <<EOF
jobs:
  pins:
    steps:
      - uses: actions/checkout@$1 # v7.0.1
      - run: ./aurtomator.sh check-pins
  check-updates:
    needs: pins
    uses: staticwire/aurtomator/.github/workflows/check-updates.yml@$1 # $2
  notify:
    needs: check-updates
    # uses: staticwire/aurtomator/.github/workflows/notify-failure.yml@0000000000000000000000000000000000000000 # $2
    uses: staticwire/aurtomator/.github/workflows/notify-failure.yml@$1 # $2
EOF
  cat >"$REPO/.github/workflows/validate.yml" <<EOF
jobs:
  pins:
    steps:
      - uses: staticwire/aurtomator/.github/actions/check@$1 # $2
  validate:
    needs: pins
    uses: staticwire/aurtomator/.github/workflows/validate.yml@$1 # $2
EOF
}

@test "runner: check-pins prints each pin of aurtomator that is the commit of the release after it" {
  template_workflows "$PINNED" v1.0.0
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = ".github/workflows/check-updates.yml:8:    uses: staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED # v1.0.0" ]
  [ "${lines[1]}" = ".github/workflows/check-updates.yml:12:    uses: staticwire/aurtomator/.github/workflows/notify-failure.yml@$PINNED # v1.0.0" ]
  [ "${lines[2]}" = ".github/workflows/validate.yml:4:      - uses: staticwire/aurtomator/.github/actions/check@$PINNED # v1.0.0" ]
  [ "${lines[3]}" = ".github/workflows/validate.yml:7:    uses: staticwire/aurtomator/.github/workflows/validate.yml@$PINNED # v1.0.0" ]
  [ "${#lines[@]}" -eq 4 ]
  # check-pins fetches nothing
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]

  rm "$REPO/.github/workflows/validate.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

# Commits the workflows of the repository with the pins of $1 and the release $2, as the base
# branch with $1 and $2, then as the head of a pull request with $3 and $4 when they are given
commit_pins() {
  git -C "$REPO" init -q
  template_workflows "$1" "$2"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q -m base
  [[ -n "${3:-}" ]] || return 0
  template_workflows "$3" "$4"
  git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q -am head
}

# The merge commit of a pull request has the base branch as its first parent, and pull requests
# that move a pin back to an older release run the jobs with the secrets on that release
@test "runner: check-pins refuses a pull request that moves a pin back to an older release" {
  commit_pins "$TIP" v1.1.0 "$PINNED" v1.0.0
  GITHUB_EVENT_NAME=pull_request run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "$output" = ".github/workflows/check-updates.yml moves the pin of staticwire/aurtomator from v1.1.0 of the base branch back to v1.0.0; pull requests move pins forward alone" ]
  GITHUB_EVENT_NAME=push run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 0 ]
}

@test "runner: check-pins passes a pull request that keeps the pins or moves them forward" {
  commit_pins "$PINNED" v1.0.0 "$TIP" v1.1.0
  GITHUB_EVENT_NAME=pull_request run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  commit_pins "$PINNED" v1.0.0
  git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m head
  GITHUB_EVENT_NAME=pull_request run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
}

# The pins job of older templates checks out the merge commit alone, and GitHub serves its
# parents by its SHA
@test "runner: check-pins fetches the base of a pull request that the checkout lacks" {
  local shallow="$TEST_TMPDIR/shallow"
  commit_pins "$TIP" v1.1.0 "$PINNED" v1.0.0
  git -C "$REPO" config uploadpack.allowReachableSHA1InWant true
  git clone -q --depth 1 "file://$REPO" "$shallow"
  [ "$(readlink "$shallow/aurtomator.sh")" = "$RUNNER" ]
  run git -C "$shallow" rev-parse --verify -q 'HEAD^1'
  [ "$status" -ne 0 ]
  GITHUB_EVENT_NAME=pull_request run "$shallow/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "$output" = ".github/workflows/check-updates.yml moves the pin of staticwire/aurtomator from v1.1.0 of the base branch back to v1.0.0; pull requests move pins forward alone" ]
}

@test "runner: check-pins of a pull request stops when it cannot fetch the base" {
  commit_pins "$PINNED" v1.0.0
  GITHUB_EVENT_NAME=pull_request run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "$output" = "The checkout holds no parent of the merge commit, and git could not fetch it, so check-pins cannot compare the pins with the base branch; add fetch-depth: 2 to the checkout of the job pins" ]
}

# GitHub serves the commits of every fork under the name of the parent
@test "runner: check-pins refuses a pin of aurtomator that is not the commit of the release after it" {
  local untagged
  untagged=$(commit_aurtomator "$TEST_TMPDIR/work" untagged)
  publish staticwire/aurtomator "$TEST_TMPDIR/work"

  template_workflows "$PINNED" v1.0.0
  sed -i "s|notify-failure.yml@$PINNED|notify-failure.yml@$untagged|" "$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "$output" = "The pin $untagged in .github/workflows/check-updates.yml is not the commit of v1.0.0 of staticwire/aurtomator; ./aurtomator.sh pin vX.Y.Z pins the commit of a release" ]

  # The commit of an older release under the name of a newer one, in a step
  template_workflows "$PINNED" v1.0.0
  sed -i "s|check@$PINNED # v1.0.0|check@$PINNED # v1.1.0|" "$REPO/.github/workflows/validate.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "$output" = "The pin $PINNED in .github/workflows/validate.yml is not the commit of v1.1.0 of staticwire/aurtomator; ./aurtomator.sh pin vX.Y.Z pins the commit of a release" ]

  # GitHub finds a repository by its name in any case
  template_workflows "$PINNED" v1.0.0
  sed -i "s|staticwire/aurtomator/.github/workflows/validate.yml@$PINNED|StaticWire/AURtomator/.github/workflows/validate.yml@$untagged|" "$REPO/.github/workflows/validate.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "$output" = "The pin $untagged in .github/workflows/validate.yml is not the commit of v1.0.0 of staticwire/aurtomator; ./aurtomator.sh pin vX.Y.Z pins the commit of a release" ]
  [ ! -e "$XDG_CACHE_HOME/aurtomator" ]
}

@test "runner: check-pins refuses a pin of aurtomator without the release after it" {
  template_workflows "$PINNED" v1.0.0
  sed -i "s|validate.yml@$PINNED # v1.0.0|validate.yml@$PINNED|" "$REPO/.github/workflows/validate.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "$output" = "Write the release after the pin in .github/workflows/validate.yml, as ./aurtomator.sh pin vX.Y.Z does: @$PINNED # vX.Y.Z" ]
}

@test "runner: check-pins refuses a uses: line of aurtomator that names no commit SHA" {
  local ref
  for ref in main v1.0.0 "${PINNED}0" "${PINNED:0:7}"; do
    template_workflows "$PINNED" v1.0.0
    sed -i "s|validate.yml@$PINNED|validate.yml@$ref|" "$REPO/.github/workflows/validate.yml"
    run "$REPO/aurtomator.sh" check-pins
    [ "$status" -eq 1 ]
    [ "$output" = ".github/workflows/validate.yml runs staticwire/aurtomator/.github/workflows/validate.yml@$ref, which names no commit SHA" ]
  done
}

@test "runner: check-pins stops when GitHub reads a pin of aurtomator off a uses: line" {
  template_workflows "$PINNED" v1.0.0
  sed -i "s|uses: \(staticwire/aurtomator/.github/workflows/validate.yml@$PINNED\)|uses: \"\1\"|" "$REPO/.github/workflows/validate.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "Write each pin of staticwire/aurtomator in .github/workflows/validate.yml on one uses: line without quotes. GitHub reads:" ]
  [ "${lines[1]}" = "  staticwire/aurtomator/.github/actions/check@$PINNED" ]
  [ "${lines[2]}" = "  staticwire/aurtomator/.github/workflows/validate.yml@$PINNED" ]
  [ "${#lines[@]}" -eq 3 ]

  # uses: line in a block of text, which GitHub does not read
  template_workflows "$PINNED" v1.0.0
  printf '    with:\n      text: |\n        uses: staticwire/aurtomator/.github/workflows/validate.yml@%s # v1.0.0\n' "$PINNED" \
    >>"$REPO/.github/workflows/validate.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "Write each pin of staticwire/aurtomator in .github/workflows/validate.yml on one uses: line without quotes. GitHub reads:" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "runner: check-pins stops at a merge key in validate.yml" {
  template_workflows "$PINNED" v1.0.0
  printf 'x: &v\n  a: 1\ny:\n  <<: *v\n' >>"$REPO/.github/workflows/validate.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "$output" = ".github/workflows/validate.yml holds a merge key (<<)" ]
}

@test "runner: check-pins takes no argument and names the repository whose tags it cannot list" {
  template_workflows "$PINNED" v1.0.0
  run "$REPO/aurtomator.sh" check-pins v1.0.0
  [ "$status" -eq 1 ]
  [ "$output" = "Usage: $REPO/aurtomator.sh check-pins" ]

  rm -rf "$TEST_TMPDIR/github/staticwire/aurtomator"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "Could not list the tags of staticwire/aurtomator" ]
}

@test "runner: pin names the repository whose tags it cannot list and changes no file" {
  template_workflows "$PINNED" v1.0.0
  cp "$REPO/.github/workflows/check-updates.yml" "$TEST_TMPDIR/before.yml"
  rm -rf "$TEST_TMPDIR/github/staticwire/aurtomator"
  run "$REPO/aurtomator.sh" pin v1.1.0
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "Could not list the tags of staticwire/aurtomator" ]
  cmp "$TEST_TMPDIR/before.yml" "$REPO/.github/workflows/check-updates.yml"
}

@test "runner: check-pins reads the release after a pin up to its end" {
  template_workflows "$PINNED" v1.0.0
  sed -i "s|validate.yml@$PINNED # v1.0.0|validate.yml@$PINNED # v1.0.0-rc1|" "$REPO/.github/workflows/validate.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "$output" = "Write the release after the pin in .github/workflows/validate.yml, as ./aurtomator.sh pin vX.Y.Z does: @$PINNED # vX.Y.Z" ]
}

# GitHub runs a reusable workflow of any public repository
# GitHub reads a uses: value through an alias, and the line shows only the alias
@test "runner: check-pins reads the uses: values of jobs through an alias" {
  local pin="staticwire/aurtomator/.github/workflows/check-updates.yml@$PINNED # v1.0.0"
  printf '%s\n' 'env:' '  LOCAL: &local ./.github/workflows/local.yml' 'jobs:' '  check-updates:' "    uses: $pin" \
    '  again:' '    uses: *local' >"$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 0 ]

  printf '%s\n' 'env:' "  OTHER: &other someone/else/.github/workflows/x.yml@$PINNED" 'jobs:' '  check-updates:' \
    "    uses: $pin" '  again:' '    uses: *other' >"$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "$output" = ".github/workflows/check-updates.yml runs someone/else/.github/workflows/x.yml@$PINNED, a workflow of another repository than staticwire/aurtomator" ]

  printf '%s\n' 'env:' "  PIN: &pin staticwire/aurtomator/.github/workflows/notify-failure.yml@$PINNED" 'jobs:' '  check-updates:' \
    "    uses: $pin" '  notify:' '    uses: *pin' >"$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "Write each pin of staticwire/aurtomator in .github/workflows/check-updates.yml on one uses: line without quotes. GitHub reads:" ]
}

@test "runner: check-pins refuses a workflow of another repository" {
  template_workflows "$PINNED" v1.0.0
  sed -i "s|uses: staticwire/aurtomator/.github/workflows/notify-failure.yml|uses: statlcwire/aurtomator/.github/workflows/notify-failure.yml|" \
    "$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "$output" = ".github/workflows/check-updates.yml runs statlcwire/aurtomator/.github/workflows/notify-failure.yml@$PINNED, a workflow of another repository than staticwire/aurtomator" ]

  template_workflows "$PINNED" v1.0.0
  sed -i "s|uses: staticwire/aurtomator/.github/workflows/validate.yml@$PINNED # v1.0.0|uses: /statlcwire/aurtomator/.github/workflows/validate.yml@main|" \
    "$REPO/.github/workflows/validate.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "$output" = ".github/workflows/validate.yml runs /statlcwire/aurtomator/.github/workflows/validate.yml@main, a workflow of another repository than staticwire/aurtomator" ]
}

# The uses: value of a job always names a workflow, which gets the secrets the job passes
@test "runner: check-pins refuses a job that runs a workflow of another repository in any spelling" {
  local value
  for value in 'evil/repo/.github//workflows/w.yml@main' 'evil/repo/.github\workflows\w.yml@main' \
    evil/repo/.github/./workflows/w.yml@main evil/repo/.GITHUB/workflows/w.yml@main evil/repo/w.yml@main; do
    template_workflows "$PINNED" v1.0.0
    printf '  extra:\n    needs: pins\n    uses: %s\n    secrets: inherit\n' "$value" >>"$REPO/.github/workflows/check-updates.yml"
    run "$REPO/aurtomator.sh" check-pins
    [ "$status" -eq 1 ]
    [ "$output" = ".github/workflows/check-updates.yml runs $value, a workflow of another repository than staticwire/aurtomator" ]
  done

  # Workflow of the calling repository
  template_workflows "$PINNED" v1.0.0
  printf '  extra:\n    uses: ./.github/workflows/local.yml\n' >>"$REPO/.github/workflows/check-updates.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
}

# Steps run actions of any repository; steps that name a workflow are refused in each
# spelling GitHub reads, and an action of the calling repository passes
@test "runner: check-pins refuses a step that names a workflow of another repository in any spelling" {
  local value
  for value in 'statlcwire\aurtomator\.github\workflows\validate.yml@main' 'evil/repo/.github//workflows/w.yml@main' \
    evil/repo/.github/./workflows/w.yml@main evil/repo/.GITHUB/workflows/w.yml@main; do
    template_workflows "$PINNED" v1.0.0
    printf 'jobs:\n  pins:\n    steps:\n      - uses: %s\n' "$value" >"$REPO/.github/workflows/validate.yml"
    run "$REPO/aurtomator.sh" check-pins
    [ "$status" -eq 1 ]
    [ "$output" = ".github/workflows/validate.yml runs $value, a workflow of another repository than staticwire/aurtomator" ]
  done

  template_workflows "$PINNED" v1.0.0
  printf 'jobs:\n  pins:\n    steps:\n      - uses: ./x/.github/workflows/y.yml\n' >"$REPO/.github/workflows/validate.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

# Case folding of tr_TR turns I into a dotless i, so the names are folded in the C locale
@test "runner: check-pins folds the case of names in the C locale under tr_TR.UTF-8" {
  command -v localedef >/dev/null || locale_needed "no localedef"
  [[ -e /usr/share/i18n/locales/tr_TR ]] || locale_needed "no source of the tr_TR locale"
  mkdir "$TEST_TMPDIR/locale"
  localedef -i tr_TR -f UTF-8 "$TEST_TMPDIR/locale/tr_TR.UTF-8" 2>/dev/null || locale_needed "localedef cannot build tr_TR.UTF-8"
  export LOCPATH="$TEST_TMPDIR/locale"
  [ "$(LC_ALL=tr_TR.UTF-8 bash -c 'x=I; printf %s "${x,,}"')" != i ] || locale_needed "tr_TR.UTF-8 folds I to i"

  template_workflows "$PINNED" v1.0.0
  printf 'jobs:\n  pins:\n    steps:\n      - uses: %s\n' evil/repo/.GITHUB/workflows/w.yml@main >"$REPO/.github/workflows/validate.yml"
  LC_ALL=tr_TR.UTF-8 run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "$output" = ".github/workflows/validate.yml runs evil/repo/.GITHUB/workflows/w.yml@main, a workflow of another repository than staticwire/aurtomator" ]

  template_workflows "$PINNED" v1.0.0
  sed -i 's|uses: staticwire/aurtomator/.github/workflows/notify-failure.yml|uses: STATICWIRE/AURTOMATOR/.github/workflows/notify-failure.yml|' \
    "$REPO/.github/workflows/check-updates.yml"
  LC_ALL=tr_TR.UTF-8 run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 0 ]
}

@test "runner: check-pins checks the release of a pin of aurtomator without a path" {
  template_workflows "$PINNED" v1.0.0
  printf 'jobs:\n  pins:\n    steps:\n      - uses: staticwire/aurtomator@%s # v1.0.0\n' "$PINNED" >"$REPO/.github/workflows/validate.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = ".github/workflows/validate.yml:4:      - uses: staticwire/aurtomator@$PINNED # v1.0.0" ]
  [ "${#lines[@]}" -eq 3 ]

  sed -i 's|# v1.0.0$|# v1.1.0|' "$REPO/.github/workflows/validate.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "$output" = "The pin $PINNED in .github/workflows/validate.yml is not the commit of v1.1.0 of staticwire/aurtomator; ./aurtomator.sh pin vX.Y.Z pins the commit of a release" ]
}

# GitHub splits the path of a uses: value on / and \ and drops the empty parts
@test "runner: check-pins refuses a pin of aurtomator spelled with an extra slash or a backslash" {
  local path
  for path in /staticwire/aurtomator/.github/actions/check staticwire//aurtomator/.github/actions/check \
    'staticwire\aurtomator\.github\actions\check' staticwire/aurtomator//.github/actions/check \
    'staticwire/aurtomator/.github\actions\check'; do
    template_workflows "$PINNED" v1.0.0
    printf 'jobs:\n  pins:\n    steps:\n      - uses: %s@%s # v1.0.0\n' "$path" "$PINNED" >"$REPO/.github/workflows/validate.yml"
    run "$REPO/aurtomator.sh" check-pins
    [ "$status" -eq 1 ]
    [ "$output" = ".github/workflows/validate.yml writes the pin $path@$PINNED of staticwire/aurtomator with an extra slash or a backslash; write it as staticwire/aurtomator/<path>@<sha>" ]
  done
}

# GitHub refuses a workflow with such a tag today, and the check does not rest on that
@test "runner: check-pins refuses a uses: value with a tag" {
  local tag
  for tag in '!foo' '!'; do
    template_workflows "$PINNED" v1.0.0
    sed -i "s|^    uses: staticwire/aurtomator/.github/workflows/notify-failure.yml|    uses: $tag staticwire/aurtomator/.github/workflows/notify-failure.yml|" \
      "$REPO/.github/workflows/check-updates.yml"
    run "$REPO/aurtomator.sh" check-pins
    [ "$status" -eq 1 ]
    [ "$output" = ".github/workflows/check-updates.yml holds a uses: value with the tag $tag; write every uses: value as plain text" ]
  done

  template_workflows "$PINNED" v1.0.0
  sed -i 's|- uses: staticwire/|- uses: !foo staticwire/|' "$REPO/.github/workflows/validate.yml"
  run "$REPO/aurtomator.sh" check-pins
  [ "$status" -eq 1 ]
  [ "$output" = ".github/workflows/validate.yml holds a uses: value with the tag !foo; write every uses: value as plain text" ]
}
