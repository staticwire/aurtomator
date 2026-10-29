#!/usr/bin/env bats

GITHUB_DIR="$BATS_TEST_DIRNAME/../.github"

# Prints the run blocks of every step in workflow $1
run_blocks() {
  yq '.jobs[].steps[] | select(has("run")) | .run' "$1"
}

# The runner pastes an expression into a run script before bash parses it,
# so a step reads GitHub context through env: instead.
@test "workflows: no run block expands an expression" {
  local workflow count=0
  for workflow in "$GITHUB_DIR"/workflows/*.yml; do
    echo "$workflow"
    run run_blocks "$workflow"
    [ "$status" -eq 0 ]
    [[ "$output" != *'${{'* ]]
    [ -z "$output" ] || count=$((count + 1))
  done
  [ "$count" -gt 2 ]
}

@test "actions: no run block expands an expression" {
  local action count=0
  for action in "$GITHUB_DIR"/actions/*/action.yml; do
    echo "$action"
    run yq '.runs.steps[] | select(has("run")) | .run' "$action"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" != *'${{'* ]]
    count=$((count + 1))
  done
  [ "$count" -gt 0 ]
}

@test "ci-image: the Dockerfile pins archlinux:base-devel by digest" {
  run grep -c '^FROM ' "$GITHUB_DIR/ci-image/Dockerfile"
  [ "$output" = "1" ]
  run grep -Ex 'FROM archlinux:base-devel@sha256:[0-9a-f]{64}' "$GITHUB_DIR/ci-image/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "ci-image: Dependabot updates the Dockerfile" {
  run yq '.updates[] | select(.["package-ecosystem"] == "docker") | .directory' "$GITHUB_DIR/dependabot.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "/.github/ci-image" ]
}

@test "workflows: every container comes from the image job" {
  local workflow line count=0
  for workflow in "$GITHUB_DIR"/workflows/*.yml; do
    run yq '.jobs[] | select(has("container")) | .container + " " + ([.needs] | flatten | contains(["image"]) | tostring)' "$workflow"
    [ "$status" -eq 0 ]
    for line in "${lines[@]}"; do
      echo "$workflow: $line"
      [ "$line" = '${{ needs.image.outputs.ref }} true' ]
      count=$((count + 1))
    done
  done
  [ "$count" -gt 0 ]
}

@test "workflows: the image job is the same in every workflow" {
  run yq '.jobs.image' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  local expected="$output"
  run yq '.jobs.image' "$GITHUB_DIR/workflows/check-updates.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

# A pinned image ages, and an old keyring rejects packages signed with a
# newer packager key
@test "workflows: pacman upgrades the keyring before the system" {
  local workflow
  for workflow in "$GITHUB_DIR"/workflows/*.yml; do
    run run_blocks "$workflow"
    [ "$status" -eq 0 ]
    [[ "$output" != *"pacman -Syu"* ]]
    [[ "$output" != *"pacman -S"* ]] && continue
    echo "$workflow"
    run awk '
      /pacman -Su / {
        if (prev !~ /^ *pacman -Sy --noconfirm --needed archlinux-keyring$/) bad = 1
        n++
      }
      { prev = $0 }
      END { exit bad || !n }' <<<"$output"
    [ "$status" -eq 0 ]
  done
}

@test "workflows: go and gem installs name exact versions" {
  local workflow
  for workflow in "$GITHUB_DIR"/workflows/*.yml; do
    echo "$workflow"
    run run_blocks "$workflow"
    [ "$status" -eq 0 ]
    run awk '
      /go install / && $NF !~ /@v[0-9]+\.[0-9]+\.[0-9]+$/ { bad = 1 }
      /gem install / {
        for (i = 3; i <= NF; i++)
          if ($i !~ /^-/ && $i !~ /:[0-9]+\.[0-9]+\.[0-9]+$/) bad = 1
      }
      END { exit bad }' <<<"$output"
    [ "$status" -eq 0 ]
  done
}

@test "ci: the lint job runs actionlint on the workflows" {
  run yq '[.jobs.lint.steps[] | select(.run == "actionlint")] | length' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# actionlint runs shellcheck on the run blocks of the workflows only
@test "ci: the lint job checks the run blocks of the actions with shellcheck" {
  run yq '.jobs.lint.steps[] | select(.name == "shellcheck the actions") | .run' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *'.github/actions/*/action.yml'* ]]
  [[ "$output" == *'shellcheck -s bash "$RUNNER_TEMP/run.sh"'* ]]
}

# The lint steps check only the files they name: shellcheck -x reads a
# sourced file but reports nothing in it, and shfmt does not read it
@test "ci: shellcheck and shfmt check every script in scripts and strategies" {
  local root="$GITHUB_DIR/.." step expected
  expected=$(cd "$root" && find scripts strategies -name '*.sh' | sort)
  [ -n "$expected" ]
  for step in shellcheck shfmt; do
    run yq ".jobs.lint.steps[] | select(.name == \"$step\") | .run" "$GITHUB_DIR/workflows/ci.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == "$step "* ]]
    run bash -c 'cd "$1" && for word in $2; do if [[ "$word" == scripts/*.sh || "$word" == strategies/*.sh ]]; then printf "%s\n" "$word"; fi; done | sort' _ "$root" "$output"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
  done
}

@test "ci: shfmt checks every test file" {
  local root="$GITHUB_DIR/.." expected
  expected=$(cd "$root" && find tests -name '*.bats' -o -name '*.sh' | sort)
  [ -n "$expected" ]
  run yq '.jobs.lint.steps[] | select(.name == "shfmt") | .run' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && for word in $2; do if [[ "$word" == tests/* ]]; then printf "%s\n" "$word"; fi; done | sort' _ "$root" "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

# Without .shellcheckrc, shellcheck reads a source directive relative to
# the current directory, and -S warning hides the SC1091 it gives for a
# file it cannot follow
@test "ci: every shellcheck source directive names a file next to its script" {
  local root="$GITHUB_DIR/.." file target count=0
  grep -qx 'source-path=SCRIPTDIR' "$root/.shellcheckrc"
  while IFS=: read -r file target; do
    [[ "$target" != /dev/null ]] || continue
    echo "$file: $target"
    [ -f "$root/$(dirname "$file")/$target" ]
    count=$((count + 1))
  done < <(cd "$root" && grep -o '# shellcheck source=[^ ]*' scripts/*.sh scripts/lib/*.sh strategies/*.sh | sed 's/# shellcheck source=//')
  [ "$count" -gt 0 ]
}

@test "ci: the test job runs the suite once, under bashcov, and fails with it" {
  run yq '[.jobs.test.steps[] | select(has("run")) | .run | select(test("tests/"))] | length' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run yq '.jobs.test.steps[] | select(has("run")) | .run | select(test("tests/"))' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == "bashcov -- tests/helpers/bashcov-bats.sh tests/ --recursive"* ]]
  [[ "$output" != *"|| true"* ]]
}

@test "merge-image: runs only after lint and test" {
  run yq '.jobs["merge-image"].needs | sort | join(" ")' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "lint test" ]
}

@test "merge-image: off unless the variable is true and Dependabot opened the pull request" {
  run yq '.jobs["merge-image"].if' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vars.CI_IMAGE_AUTO_MERGE == 'true'"* ]]
  [[ "$output" == *"github.event_name == 'pull_request'"* ]]
  [[ "$output" == *"github.actor == 'dependabot[bot]'"* ]]
  [[ "$output" == *"github.event.pull_request.user.login == 'dependabot[bot]'"* ]]
  [[ "$output" != *"||"* ]]
}

# Runs the merge step of ci.yml with a gh that prints the files in
# $GH_FILES and logs every call to $GH_LOG
run_merge_step() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
if [[ "$1" == "api" ]]; then
  [[ -z "${GH_FAIL:-}" ]] || exit 1
  printf '%s\n' "$GH_FILES"
fi
EOF
  chmod +x "$bin/gh"
  yq '.jobs["merge-image"].steps[] | select(.name == "Merge image update") | .run' \
    "$GITHUB_DIR/workflows/ci.yml" >"$BATS_TEST_TMPDIR/step.sh"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : >"$GH_LOG"
  run env PATH="$bin:$PATH" GH_LOG="$GH_LOG" REPO=owner/repo PR=12 HEAD_SHA=abc123 \
    bash -e "$BATS_TEST_TMPDIR/step.sh"
}

@test "merge-image: merges the tested head when only the Dockerfile changed" {
  GH_FILES=".github/ci-image/Dockerfile" run_merge_step
  [ "$status" -eq 0 ]
  grep -qx 'api repos/owner/repo/pulls/12/files --paginate --jq .\[\].filename' "$GH_LOG"
  grep -qx 'pr merge 12 -R owner/repo --squash --match-head-commit abc123' "$GH_LOG"
}

@test "merge-image: leaves a pull request that changes other files" {
  GH_FILES=$'.github/ci-image/Dockerfile\n.github/workflows/ci.yml' run_merge_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"* ]]
  run grep -c '^pr merge' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "merge-image: fails when the file list cannot be read" {
  GH_FAIL=1 GH_FILES=".github/ci-image/Dockerfile" run_merge_step
  [ "$status" -ne 0 ]
  run grep -c '^pr merge' "$GH_LOG"
  [ "$output" = "0" ]
}

# === release-please.yml ===

RELEASE="$GITHUB_DIR/workflows/release-please.yml"
RELEASE_CONFIG="$GITHUB_DIR/release-please-config.json"

# A fork or a template copy carries the workflow and must not open release PRs
@test "release-please: runs only in the upstream repository" {
  run yq '.jobs[] | .if' "$RELEASE"
  [ "$status" -eq 0 ]
  [ "$output" = "github.repository == 'staticwire/aurtomator'" ]
}

@test "release-please: pins the action by SHA, reads the config in .github and has a time limit" {
  run yq '.jobs[].steps[1].uses' "$RELEASE"
  [[ "$output" =~ ^googleapis/release-please-action@[0-9a-f]{40}$ ]]
  run grep -E '^ +- uses: googleapis/release-please-action@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$' "$RELEASE"
  [ "$status" -eq 0 ]
  run yq '.jobs[].steps[1].with | .["config-file"] + " " + .["manifest-file"]' "$RELEASE"
  [ "$output" = ".github/release-please-config.json .github/.release-please-manifest.json" ]
  run yq '.jobs[]["timeout-minutes"] > 0' "$RELEASE"
  [ "$output" = "true" ]
  run yq -o=json -I=0 '.permissions' "$RELEASE"
  [ "$output" = '{"contents":"read"}' ]
}

# GitHub runs the CI of a pull request opened with the workflow token only
# after someone with write access approves it, and main requires that CI
@test "release-please: opens the release PR with the token of the release App" {
  run yq '.jobs[].steps | length' "$RELEASE"
  [ "$output" = "2" ]
  run yq '.jobs[].steps[0].uses' "$RELEASE"
  [[ "$output" =~ ^actions/create-github-app-token@[0-9a-f]{40}$ ]]
  run grep -E '^ +- uses: actions/create-github-app-token@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$' "$RELEASE"
  [ "$status" -eq 0 ]
  run yq -o=json -I=0 '.jobs[].steps[0] | [.id, .with]' "$RELEASE"
  [ "$output" = '["app-token",{"client-id":"${{ vars.RELEASE_APP_CLIENT_ID }}","private-key":"${{ secrets.RELEASE_APP_PRIVATE_KEY }}","permission-contents":"write","permission-issues":"write","permission-pull-requests":"write"}]' ]
  run yq '.jobs[].steps[1].with.token' "$RELEASE"
  [ "$output" = '${{ steps.app-token.outputs.token }}' ]
  run yq '.jobs[] | has("permissions")' "$RELEASE"
  [ "$output" = "false" ]
}

@test "release-please: writes VERSION, keeps vX.Y.Z tags and GitHub notes, and no CHANGELOG" {
  run yq -o=json -I=0 '.packages["."]' "$RELEASE_CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = '{"release-type":"simple","version-file":"VERSION","changelog-type":"github","skip-changelog":true,"bump-minor-pre-major":true,"include-component-in-tag":false,"extra-files":[{"type":"generic","path":"README.md"}]}' ]
}

# The release PR writes the version line of README.md, so the check run of
# the upstream repository finds nothing to commit to its protected main
@test "release-please: the README holds the version line update-readme.sh writes" {
  local version
  version=$(<"$GITHUB_DIR/../VERSION")
  run grep -cxF "aurtomator $version <!-- x-release-please-version -->" "$GITHUB_DIR/../README.md"
  [ "$output" = "1" ]
}

# release-please updates VERSION in place and does not create it
@test "release-please: the manifest holds the version of VERSION" {
  local version
  version=$(<"$GITHUB_DIR/../VERSION")
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  run yq -r '.["."]' "$GITHUB_DIR/.release-please-manifest.json"
  [ "$output" = "$version" ]
}

# === check-updates.yml: who decides what ===

CHECK_UPDATES="$GITHUB_DIR/workflows/check-updates.yml"

# Prints the run block of step $2 in job $1 of check-updates.yml
step_run() {
  yq ".jobs.$1.steps[] | select(.name == \"$2\") | .run" "$CHECK_UPDATES"
}

# GitHub delays scheduled runs at the start of every hour and drops some
@test "check-updates: runs every hour, off the start of the hour" {
  run yq '.on.schedule[].cron' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^([1-9]|[1-5][0-9])\ \*\ \*\ \*\ \*$ ]]
}

@test "check-updates: the check job decides the run and executes no PKGBUILD" {
  run yq '[.jobs.check.steps[] | select(.uses == "./.github/actions/run-as-builder") | .with.args // ""] | @json' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [ "$output" = '[""]' ]
  run yq '.jobs.check.steps[] | select(has("run")) | .run' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--prepare"* ]]
  [[ "$output" != *"update-pkg.sh"* ]]
  run yq '.jobs.check.outputs | keys | join(" ")' "$CHECK_UPDATES"
  [ "$output" = "prepare work" ]
}

# Runs the Decide step in a workspace with the statuses given as name=status
# pairs, a sudo that does nothing and a git whose diff reports a README
# change when $README_CHANGED is set; prints the step outputs
run_decide_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin" pair
  mkdir -p "$ws/.status" "$bin"
  for pair in "$@"; do
    printf '%s\n' "${pair#*=}" >"$ws/.status/${pair%%=*}"
  done
  printf '#!/bin/sh\nexit 0\n' >"$bin/sudo"
  printf '#!/bin/sh\n[ -z "${README_CHANGED:-}" ]\n' >"$bin/git"
  chmod +x "$bin/sudo" "$bin/git"
  step_run check Decide >"$BATS_TEST_TMPDIR/step.sh"
  : >"$BATS_TEST_TMPDIR/output"
  (cd "$ws" && PATH="$bin:$PATH" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" \
    sh -e "$BATS_TEST_TMPDIR/step.sh") >/dev/null
  cat "$BATS_TEST_TMPDIR/output"
}

@test "check-updates: Decide prepares when a package is outdated" {
  run run_decide_step pkg="new_version: 2.0.0" other=up_to_date _error_count=0
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=true\nwork=true' ]
  run run_decide_step pkg="available_downgrade: 1.0.0"
  [ "$output" = $'prepare=true\nwork=true' ]
  run run_decide_step pkg="new_build: 1.0.0" _assets=$'pkg\t1.0.0-b'
  [ "$output" = $'prepare=true\nwork=true' ]
}

@test "check-updates: Decide prepares nothing while an asset is pending" {
  README_CHANGED=1 run run_decide_step pkg="pending: 2.0.0"
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=true' ]
}

@test "check-updates: Decide publishes only a change of the status table" {
  README_CHANGED=1 run run_decide_step pkg="check_failed: API down"
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=true' ]
  README_CHANGED=1 run run_decide_step pkg="downgrade_skipped: 1.0.0"
  [ "$output" = $'prepare=false\nwork=true' ]
}

@test "check-updates: Decide does nothing when nothing changed" {
  run run_decide_step pkg=up_to_date _error_count=0
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=false' ]
}

@test "check-updates: prepare runs only for outdated packages and decides nothing" {
  run yq '.jobs.prepare.if' "$CHECK_UPDATES"
  [ "$output" = "needs.check.outputs.prepare == 'true'" ]
  run yq '.jobs.prepare.outputs' "$CHECK_UPDATES"
  [ "$output" = "null" ]
}

@test "check-updates: Hand over runs nothing from the workspace" {
  run step_run prepare "Hand over"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" != *"./scripts/"* ]]
  [[ "$output" != *"sudo -u builder"* ]]
  [[ "$output" != *"GITHUB_OUTPUT"* ]]
}

BUILDER_ACTION="$GITHUB_DIR/actions/run-as-builder/action.yml"

# Prints job and step name, tab-separated, of every step that runs
# check-all.sh as builder through the run-as-builder action
builder_steps() {
  yq '.jobs | to_entries[] | .key as $job | .value.steps[] |
    select(.uses == "./.github/actions/run-as-builder") | $job + "\t" + .name' "$CHECK_UPDATES"
}

@test "check-updates: check-all.sh runs only through the run-as-builder action" {
  run run_blocks "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [[ "$output" != *"scripts/check-all.sh"* ]]
  run builder_steps
  [ "${#lines[@]}" -eq 4 ]
}

# The runner reads a local action from the workspace when its step starts.
# builder owns the workspace once check-all.sh ran, so a local action after
# that step in the same job could run code that builder wrote.
@test "check-updates: no local action runs after builder in its job" {
  local job line after
  for job in $(yq '.jobs | keys | .[]' "$CHECK_UPDATES"); do
    after=0
    run yq ".jobs.$job.steps[] | .uses // \"\"" "$CHECK_UPDATES"
    [ "$status" -eq 0 ]
    for line in "${lines[@]}"; do
      echo "$job: $line"
      [[ "$after" -eq 0 || "$line" != ./* ]]
      [[ "$line" != ./.github/actions/run-as-builder ]] || after=1
    done
  done
}

@test "run-as-builder: takes its inputs through the environment" {
  run yq -o=json -I=0 '.runs.steps[0].env' "$BUILDER_ACTION"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ARGS":"${{ inputs.args }}","KEEP_ENV":"${{ inputs.keep-env }}"}' ]
}

# Runs the run-as-builder action with the inputs of step $2 of job $1, in
# the shell the action names. sudo records its arguments on one line and
# its environment in $SUDO_LOG, prints $SUDO_OUT on stdout and stderr,
# leaves two processes behind that print $LATE_OUT after it exits, one
# holding only stdout and one only stderr, and exits with $SUDO_RC. chown
# and git log their arguments to chown.log and git.log in the test
# directory.
run_builder_step() {
  local bin="$BATS_TEST_TMPDIR/bin" step=".jobs.$1.steps[] | select(.name == \"$2\")" args keep
  mkdir -p "$bin"
  printf '#!/bin/sh\necho "$*" >>"$GITHUB_WORKSPACE/chown.log"\n' >"$bin/chown"
  printf '#!/bin/sh\necho "$*" >>"$GITHUB_WORKSPACE/git.log"\n' >"$bin/git"
  rm -f "$BATS_TEST_TMPDIR/chown.log" "$BATS_TEST_TMPDIR/git.log"
  cat >"$bin/sudo" <<'EOF'
#!/usr/bin/env bash
{ printf '%s\n' "$*"; env; } >>"$SUDO_LOG"
printf '%s\n' "$SUDO_OUT"
printf '%s\n' "$SUDO_OUT" >&2
if [[ -n "${LATE_OUT:-}" ]]; then
  (exec 2>/dev/null && sleep 0.5 && printf '%s\n' "$LATE_OUT") &
  (exec >/dev/null && sleep 1 && printf '%s\n' "$LATE_OUT" >&2) &
fi
exit "${SUDO_RC:-0}"
EOF
  chmod +x "$bin/chown" "$bin/git" "$bin/sudo"
  run yq '.runs.steps[0].shell' "$BUILDER_ACTION"
  [ "$output" = "bash" ]
  yq '.runs.steps[0].run' "$BUILDER_ACTION" >"$BATS_TEST_TMPDIR/step.sh"
  args=$(yq "$step | .with.args // \"\"" "$CHECK_UPDATES")
  keep=$(yq "$step | .with[\"keep-env\"] // \"\"" "$CHECK_UPDATES")
  rm -f "$SUDO_LOG"
  run env PATH="$bin:$PATH" GITHUB_WORKSPACE="$BATS_TEST_TMPDIR" SUDO_LOG="$SUDO_LOG" \
    ARGS="$args" KEEP_ENV="$keep" bash --noprofile --norc -eo pipefail "$BATS_TEST_TMPDIR/step.sh"
}

@test "check-updates: each builder step runs check-all.sh in its mode, with only the variables it needs" {
  local expected entry job name
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  expected=(
    $'check\tCheck updates\t--preserve-env=GITHUB_TOKEN -u builder ./scripts/check-all.sh'
    $'prepare\tPrepare updates\t-u builder ./scripts/check-all.sh --prepare handoff'
    $'verify\tVerify checksums\t-u builder ./scripts/check-all.sh --verify handoff'
    $'publish\tPublish updates\t--preserve-env=GPG_KEY_ID,GIT_AUTHOR_NAME,GIT_AUTHOR_EMAIL -u builder ./scripts/check-all.sh --publish handoff'
  )
  for entry in "${expected[@]}"; do
    IFS=$'\t' read -r job name want <<<"$entry"
    echo "$job: $name"
    SUDO_OUT=ok run_builder_step "$job" "$name"
    [ "$status" -eq 0 ]
    [ "$(head -n 1 "$SUDO_LOG")" = "$want" ]
  done
}

# Root's git refuses a repository that another user owns, and Decide and
# the commit step of publish run git as root
@test "run-as-builder: gives the workspace to builder and keeps it safe for root's git" {
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  SUDO_OUT=ok run_builder_step check "Check updates"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/chown.log")" = "-R builder:builder ." ]
  [ "$(cat "$BATS_TEST_TMPDIR/git.log")" = "config --global --add safe.directory $BATS_TEST_TMPDIR" ]
}

@test "check-updates: no line of builder reaches the runner as a command" {
  local steps step token
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  mapfile -t steps < <(builder_steps)
  [ "${#steps[@]}" -eq 4 ]
  for step in "${steps[@]}"; do
    echo "$step"
    SUDO_OUT=$'::add-mask::true\nfatal: ##[add-mask]true' LATE_OUT="::error::late" \
      run_builder_step "${step%%$'\t'*}" "${step#*$'\t'}"
    [ "$status" -eq 0 ]
    # stop, two lines on stdout and two on stderr, the late lines, resume
    [ "${#lines[@]}" -eq 8 ]
    [[ "${lines[0]}" =~ ^::stop-commands::([0-9a-f]{32})$ ]]
    token="${BASH_REMATCH[1]}"
    [ "${lines[5]}" = "::error::late" ]
    [ "${lines[6]}" = "::error::late" ]
    [ "${lines[7]}" = "::$token::" ]
    run grep -c -F "$token" "$SUDO_LOG"
    [ "$output" = "0" ]
  done
}

@test "check-updates: a failing builder run fails its step and resumes commands" {
  local steps step
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  mapfile -t steps < <(builder_steps)
  [ "${#steps[@]}" -eq 4 ]
  for step in "${steps[@]}"; do
    echo "$step"
    SUDO_OUT="boom" SUDO_RC=3 run_builder_step "${step%%$'\t'*}" "${step#*$'\t'}"
    [ "$status" -eq 3 ]
    [[ "${lines[-1]}" =~ ^::[0-9a-f]{32}::$ ]]
  done
}

@test "check-updates: publish runs on the check job's decision, also after a failed prepare or verify" {
  run yq '.jobs.publish.needs | join(" ")' "$CHECK_UPDATES"
  [[ " $output " == *" check "* ]]
  run yq '.jobs.publish.if' "$CHECK_UPDATES"
  [ "$output" = "!cancelled() && needs.check.outputs.work == 'true'" ]
}

# Runs the Hand over step in an empty workspace. builder has uid 1000. ps
# lists the processes in $PS_LINES until pkill ran and those in
# $PS_AFTER_KILL after it, as "<uid> <ruid> <state>" separated by commas,
# with the uid of ps itself, and exits with $PS_RC. pgrep matches any process
# of builder, zombies included, as the real one does. pkill and sleep only
# log their calls. A step still running after 20 s fails.
run_hand_over_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$ws" "$bin"
  cat >"$bin/ps" <<'EOF'
#!/usr/bin/env bash
if [[ -e "$CALLS/pkill" ]]; then lines="$PS_AFTER_KILL"; else lines="$PS_LINES"; fi
[[ "${PS_RC:-0}" -eq 0 ]] || exit "$PS_RC"
echo "0 0 R"
[[ -z "$lines" ]] || tr ',' '\n' <<<"$lines"
EOF
  printf '#!/bin/sh\nps | grep -q " 1000 \\| 1000 "\n' >"$bin/pgrep"
  printf '#!/bin/sh\n[ "$*" = "-u builder" ] && echo 1000\n' >"$bin/id"
  printf '#!/bin/sh\necho "$*" >>"$CALLS/pkill"\n' >"$bin/pkill"
  printf '#!/bin/sh\necho x >>"$CALLS/sleep"\n' >"$bin/sleep"
  chmod +x "$bin/ps" "$bin/pgrep" "$bin/id" "$bin/pkill" "$bin/sleep"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$CALLS"
  step_run prepare "Hand over" >"$BATS_TEST_TMPDIR/step.sh"
  run timeout 20 env -C "$ws" PATH="$bin:$PATH" CALLS="$CALLS" PS_LINES="${PS_LINES:-}" \
    PS_AFTER_KILL="${PS_AFTER_KILL:-}" PS_RC="${PS_RC:-0}" sh -e "$BATS_TEST_TMPDIR/step.sh"
}

@test "check-updates: Hand over goes on when builder runs nothing" {
  PS_LINES="0 0 S" run_hand_over_step
  [ "$status" -eq 0 ]
  [ ! -e "$CALLS/pkill" ]
}

@test "check-updates: Hand over kills builder and goes on when its processes end" {
  PS_LINES="1000 1000 S,1000 1000 R" PS_AFTER_KILL="" run_hand_over_step
  [ "$status" -eq 0 ]
  grep -qx -- "-KILL -u builder" "$CALLS/pkill"
  grep -qx -- "-KILL -U builder" "$CALLS/pkill"
}

@test "check-updates: Hand over does not wait for zombies" {
  PS_LINES="1000 1000 S" PS_AFTER_KILL="1000 1000 Z,1000 1000 Z+" run_hand_over_step
  [ "$status" -eq 0 ]
}

@test "check-updates: Hand over fails when a process of builder survives" {
  PS_LINES="1000 1000 S" PS_AFTER_KILL="1000 1000 Z,1000 1000 D" run_hand_over_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [ "$(wc -l <"$CALLS/sleep")" -le 30 ]
}

@test "check-updates: Hand over counts a process whose real user is builder" {
  PS_LINES="0 1000 S" PS_AFTER_KILL="0 1000 S" run_hand_over_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "check-updates: Hand over fails when the process list cannot be read" {
  PS_RC=1 run_hand_over_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

# Runs the issue step of the issues job in a workspace with the statuses
# given as name=status pairs. gh lists the titles in $GH_TITLES, one per
# line, that start with the emoji of the --label it asks for, the first 30
# unless --limit says otherwise, answers has_issues with $GH_HAS_ISSUES (true
# by default) or fails it when $GH_API_FAIL is set, and logs every call to
# $GH_LOG. scripts/lib.sh of the workspace writes the body "body" and logs
# the function and its arguments to $BODY_LOG. sudo fails.
run_issue_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin" pair
  mkdir -p "$ws/.status" "$ws/scripts" "$bin"
  cat >"$ws/scripts/lib.sh" <<'EOF'
failure_issue_body() { echo "failure_issue_body $*" >>"$BODY_LOG" && echo body; }
alert_issue_body() { echo "alert_issue_body $*" >>"$BODY_LOG" && echo body; }
upstream_issue_body() { echo "upstream_issue_body $*" >>"$BODY_LOG" && echo body; }
EOF
  for pair in "$@"; do
    printf '%s\n' "${pair#*=}" >"$ws/.status/${pair%%=*}"
  done
  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
if [[ "$*" == "api repos/$GITHUB_REPOSITORY --jq .has_issues" ]]; then
  [[ -z "${GH_API_FAIL:-}" ]] || exit 1
  echo "${GH_HAS_ISSUES:-true}"
  exit 0
fi
[[ "$1 $2" == "issue list" ]] || exit 0
[[ -z "${GH_FAIL:-}" ]] || exit 1
limit=30 jq_expr="" emoji=""
while (($#)); do
  case "$1" in
    --limit) limit=$2 && shift ;;
    --jq) jq_expr=$2 && shift ;;
    --label)
      case "$2" in
        auto-update) emoji="❌" ;;
        update-held) emoji="✋" ;;
        update-notice) emoji="🔔" ;;
        aurtomator-update) emoji="🚀" ;;
      esac
      shift
      ;;
  esac
  shift
done
titles=$(grep "^$emoji" <<<"${GH_TITLES:-}" | head -n "$limit") || true
case "$jq_expr" in
  length) grep -c . <<<"$titles" ;;
  ".[].title") [[ -z "$titles" ]] || printf '%s\n' "$titles" ;;
  *) exit 2 ;;
esac
EOF
  printf '#!/bin/sh\nexit 97\n' >"$bin/sudo"
  chmod +x "$bin/gh" "$bin/sudo"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  BODY_LOG="$BATS_TEST_TMPDIR/body.log"
  : >"$GH_LOG"
  : >"$BODY_LOG"
  step_run issues "Create issues" >"$BATS_TEST_TMPDIR/step.sh"
  run env -C "$ws" PATH="$bin:$PATH" GH_LOG="$GH_LOG" BODY_LOG="$BODY_LOG" GH_TITLES="${GH_TITLES:-}" \
    GH_FAIL="${GH_FAIL:-}" GH_HAS_ISSUES="${GH_HAS_ISSUES:-}" GH_API_FAIL="${GH_API_FAIL:-}" \
    GITHUB_REPOSITORY=owner/fork \
    RUN_URL=https://example.invalid/run sh -e "$BATS_TEST_TMPDIR/step.sh"
}

@test "check-updates: an open issue of another package holds back no issue" {
  GH_TITLES="❌ foo-bar: update failed" run_issue_step foo="update_failed: boom"
  [ "$status" -eq 0 ]
  grep -q '^issue create --title ❌ foo: update failed ' "$GH_LOG"
}

@test "check-updates: an open issue of the package holds back another one" {
  GH_TITLES="❌ foo: check failed" run_issue_step foo="update_failed: boom"
  [ "$status" -eq 0 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: the issue step finds an open issue behind 30 others" {
  GH_TITLES="$(printf '❌ pkg%s: check failed\n' {1..30})"$'\n❌ foo: update failed' \
    run_issue_step foo="update_failed: boom"
  [ "$status" -eq 0 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: the issue step fails when the open issues cannot be listed" {
  GH_FAIL=1 run_issue_step foo="update_failed: boom"
  [ "$status" -ne 0 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}

# gh issue list exits 1 in a repository with Issues turned off
@test "check-updates: the issue step gives a notice when Issues are disabled" {
  GH_HAS_ISSUES=false GH_FAIL=1 run_issue_step foo="update_failed: boom"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::Issues are disabled in owner/fork"* ]]
  run grep -c '^issue ' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: the issue step skips issues only when GitHub says Issues are off" {
  GH_HAS_ISSUES=null run_issue_step foo="update_failed: boom"
  [ "$status" -eq 0 ]
  grep -q '^issue create --title ❌ foo: update failed ' "$GH_LOG"
}

@test "check-updates: the issue step fails when it cannot read whether Issues are on" {
  GH_API_FAIL=1 run_issue_step foo="update_failed: boom"
  [ "$status" -ne 0 ]
  run grep -c '^issue ' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: the issue step asks GitHub nothing when no package failed" {
  run_issue_step foo=up_to_date bar="new_version: 2.0.0"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "check-updates: the issue step opens an issue for a held update" {
  run_issue_step foo="held: 29+1" _alerts=$'foo\thold\tRaise makedepends'
  [ "$status" -eq 0 ]
  grep -qx 'label create update-held --color fbca04 --description Update waits for a hand edit' "$GH_LOG"
  grep -qx 'issue create --title ✋ foo: update held --label update-held --body body' "$GH_LOG"
}

@test "check-updates: an open issue of a held update holds back another one" {
  GH_TITLES=$'❌ bar: check failed\n✋ foo: update held' run_issue_step foo="held: 29+2"
  [ "$status" -eq 0 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: the issue step opens an issue for a notice of a published update" {
  run_issue_step foo="updated: 29+1" bar="downgrade: 1.0" \
    _alerts=$'foo\tnotice\tCreate the package for the old major\nbar\tnotice\tCheck the old line'
  [ "$status" -eq 0 ]
  grep -qx 'label create update-notice --color 1d76db --description Published update needs a hand edit' "$GH_LOG"
  grep -qx 'issue create --title 🔔 foo: 29+1 notice --label update-notice --body body' "$GH_LOG"
  grep -qx 'issue create --title 🔔 bar: 1.0 notice --label update-notice --body body' "$GH_LOG"
}

@test "check-updates: an open notice of the version holds back another one" {
  GH_TITLES=$'🔔 foo: 29+1 notice\n✋ foo: update held' \
    run_issue_step foo="updated: 29+1" _alerts=$'foo\tnotice\tCreate the package for the old major'
  [ "$status" -eq 0 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: the issue step opens no notice for an update that was not published or has no notice" {
  run_issue_step foo="new_version: 29+1" bar="updated: 2.0" baz="up_to_date" \
    _alerts=$'foo\tnotice\tNot published\nbarfly\tnotice\tAnother package\nbaz\tnotice\tUp to date'
  [ "$status" -eq 0 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: the issue step opens an issue for a newer aurtomator release" {
  run_issue_step _upstream="newer: 0.7.0"
  [ "$status" -eq 0 ]
  grep -qx 'label create aurtomator-update --color 0e8a16 --description Newer aurtomator release' "$GH_LOG"
  grep -qx 'issue create --title 🚀 aurtomator 0.7.0 available --label aurtomator-update --body body' "$GH_LOG"
}

@test "check-updates: an open issue of the release holds back another one" {
  GH_TITLES=$'🚀 aurtomator 0.7.0 available' run_issue_step _upstream="newer: 0.7.0"
  [ "$status" -eq 0 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: the issue step opens nothing for aurtomator at its latest release" {
  run_issue_step _upstream="current: 0.7.0"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "check-updates: the issue step gives a notice for a newer aurtomator release when Issues are disabled" {
  GH_HAS_ISSUES=false GH_FAIL=1 run_issue_step _upstream="newer: 0.7.0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::Issues are disabled in owner/fork"* ]]
  run grep -c '^issue ' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: the issue step gives a notice for a held update when Issues are disabled" {
  GH_HAS_ISSUES=false GH_FAIL=1 run_issue_step foo="held: 29+1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::Issues are disabled in owner/fork"* ]]
  run grep -c '^issue ' "$GH_LOG"
  [ "$output" = "0" ]
  GH_HAS_ISSUES=false GH_FAIL=1 run_issue_step foo="updated: 29+1" _alerts=$'foo\tnotice\tNote'
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::Issues are disabled in owner/fork"* ]]
}

# Runs the close step of the issues job in a workspace with the statuses given as
# name=status pairs. gh lists the open issues in $GH_OPEN, one
# "<number> <title>" per line, whose title starts with the emoji of the
# --label it asks for, the first 30 unless --limit says otherwise, answers
# has_issues with $GH_HAS_ISSUES (true by default), fails the list when
# $GH_FAIL is set and logs every call to $GH_LOG. scripts/lib.sh of the
# workspace writes the comment "comment" and logs the function and its
# arguments to $BODY_LOG.
run_close_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin" pair
  mkdir -p "$ws/.status" "$ws/scripts" "$bin"
  cat >"$ws/scripts/lib.sh" <<'EOF'
close_comment() { echo "close_comment $*" >>"$BODY_LOG" && echo comment; }
EOF
  for pair in "$@"; do
    printf '%s\n' "${pair#*=}" >"$ws/.status/${pair%%=*}"
  done
  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "api repos/owner/fork") echo "${GH_HAS_ISSUES:-true}" ;;
  "issue list")
    [[ -z "${GH_FAIL:-}" ]] || exit 1
    limit=30 emoji=""
    while (($#)); do
      [[ "$1" != --limit ]] || limit=$2
      if [[ "$1" == --label ]]; then
        case "$2" in
          auto-update) emoji="❌" ;;
          update-held) emoji="✋" ;;
          aurtomator-update) emoji="🚀" ;;
        esac
      fi
      shift
    done
    grep "^[0-9]* $emoji" <<<"${GH_OPEN:-}" | head -n "$limit" || true
    ;;
esac
EOF
  chmod +x "$bin/gh"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  BODY_LOG="$BATS_TEST_TMPDIR/body.log"
  : >"$GH_LOG"
  : >"$BODY_LOG"
  step_run issues "Close resolved issues" >"$BATS_TEST_TMPDIR/step.sh"
  run env -C "$ws" PATH="$bin:$PATH" GH_LOG="$GH_LOG" BODY_LOG="$BODY_LOG" GH_OPEN="${GH_OPEN:-}" GH_FAIL="${GH_FAIL:-}" \
    GH_HAS_ISSUES="${GH_HAS_ISSUES:-}" GITHUB_REPOSITORY=owner/fork \
    RUN_URL=https://example.invalid/run sh -e "$BATS_TEST_TMPDIR/step.sh"
}

# A git repository at $BATS_TEST_TMPDIR/ws whose HEAD holds README.md,
# packages/foo.yml and packages/bar.yml, with the edits given as file=text
# pairs in the work tree
make_commit_repo() {
  local ws="$BATS_TEST_TMPDIR/ws" pair
  mkdir -p "$ws/packages"
  git -C "$ws" init -q -b main
  echo "readme" >"$ws/README.md"
  echo "current: 1.0" >"$ws/packages/foo.yml"
  echo "current: 1.0" >"$ws/packages/bar.yml"
  git -C "$ws" add .
  git -C "$ws" -c user.name=t -c user.email=t@example.invalid commit -q -m init
  for pair in "$@"; do
    printf '%s\n' "${pair#*=}" >"$ws/${pair%%=*}"
  done
}

# The tree of HEAD in the repository of make_commit_repo, as gh lists it,
# with the sha of file $1 replaced, or $1 left out when $2 is "gone"
moved_tree() {
  git -C "$BATS_TEST_TMPDIR/ws" ls-tree -r HEAD | awk -v f="$1" -v how="${2:-}" '
    $4 == f { if (how == "gone") next; $3 = "0123456789012345678901234567890123456789" }
    { print $4 " " $3 }'
}

# Runs the commit step of publish in the repository of make_commit_repo. gh
# answers the head of main with $GH_HEAD (HEAD of the repository by
# default), lists the tree of that head from $GH_TREE as "path sha" lines
# (the tree of HEAD by default) or fails the listing when $GH_TREE_FAIL is
# set, and logs every call to $GH_LOG.
run_commit_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$2" in
  repos/owner/fork/git/ref/heads/main) echo "$GH_HEAD" ;;
  repos/owner/fork/git/commits/*) echo "tree-of-head" ;;
  "repos/owner/fork/git/trees/tree-of-head?recursive=1")
    [[ -z "${GH_TREE_FAIL:-}" ]] || exit 1
    printf '%s\n' "$GH_TREE"
    ;;
  repos/owner/fork/git/blobs) echo "blob" ;;
  repos/owner/fork/git/trees) cat >/dev/null && echo "tree" ;;
  repos/owner/fork/git/commits) echo "commit" ;;
  repos/owner/fork/git/refs/heads/main) echo "{}" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$bin/gh"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : >"$GH_LOG"
  step_run publish "Commit changes via API" >"$BATS_TEST_TMPDIR/step.sh"
  run env -C "$ws" PATH="$bin:$PATH" GH_LOG="$GH_LOG" REPO=owner/fork BRANCH=main \
    GH_HEAD="${GH_HEAD:-$(git -C "$ws" rev-parse HEAD)}" GH_TREE_FAIL="${GH_TREE_FAIL:-}" \
    GH_TREE="${GH_TREE:-$(git -C "$ws" ls-tree -r HEAD | awk '{ print $4 " " $3 }')}" \
    bash -e "$BATS_TEST_TMPDIR/step.sh"
}

MOVED=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# Fails when gh got a call that matches $1. A function, because bats does
# not fail a test on a negated command that is not the last one.
no_call() {
  ! grep -q -e "$1" "$GH_LOG"
}

# Fails when the commit step wrote a blob or moved the branch
no_commit() {
  no_call "git/blobs" && no_call "git/refs/heads/main "
}

@test "check-updates: the commit step commits on the head it checked out" {
  make_commit_repo README.md="new table"
  run_commit_step
  [ "$status" -eq 0 ]
  grep -q "^api repos/owner/fork/git/refs/heads/main " "$GH_LOG"
  no_call "recursive"
}

@test "check-updates: the commit step commits on a moved head that left its files alone" {
  make_commit_repo README.md="new table" packages/foo.yml="current: 2.0"
  GH_HEAD=$MOVED GH_TREE="$(moved_tree packages/bar.yml)" run_commit_step
  [ "$status" -eq 0 ]
  grep -q "^api repos/owner/fork/git/refs/heads/main " "$GH_LOG"
}

@test "check-updates: the commit step stops with a notice when the moved head changed README.md" {
  make_commit_repo README.md="new table"
  GH_HEAD=$MOVED GH_TREE="$(moved_tree README.md)" run_commit_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"*"README.md"* ]]
  no_commit
}

@test "check-updates: the commit step stops with a notice when the moved head changed or removed a YAML" {
  make_commit_repo README.md="new table" packages/foo.yml="current: 2.0"
  GH_HEAD=$MOVED GH_TREE="$(moved_tree packages/foo.yml)" run_commit_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"*"packages/foo.yml"* ]]
  no_commit
  GH_HEAD=$MOVED GH_TREE="$(moved_tree packages/foo.yml gone)" run_commit_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"*"packages/foo.yml"* ]]
  no_commit
}

@test "check-updates: the commit step fails when it cannot list the tree of a moved head" {
  make_commit_repo README.md="new table"
  GH_HEAD=$MOVED GH_TREE_FAIL=1 run_commit_step
  [ "$status" -ne 0 ]
  no_commit
}

@test "check-updates: the close step runs before the issue step, and not after a failed step or publish" {
  run yq '[.jobs.issues.steps[].name] | join(",")' "$CHECK_UPDATES"
  [[ "$output" == *"Close resolved issues,Create issues" ]]
  run yq '.jobs.issues.steps[] | select(.name == "Close resolved issues") | .if' "$CHECK_UPDATES"
  [ "$output" = "needs.publish.result == 'success' || needs.publish.result == 'skipped'" ]
  run yq '.jobs.issues.steps[] | select(.name == "Create issues") | .if' "$CHECK_UPDATES"
  [ "$output" = "always()" ]
}

# A change that leaves the status table alone skips publish and still opens
# or closes an issue
@test "check-updates: the issues job runs in every run that checked, after publish" {
  run yq '.jobs.issues.needs | join(" ")' "$CHECK_UPDATES"
  [ "$output" = "image check publish" ]
  run yq '.jobs.issues.if' "$CHECK_UPDATES"
  [ "$output" = "!cancelled() && needs.check.result == 'success'" ]
  run yq '.jobs.check.steps[] | select(.name == "Upload statuses") | has("if")' "$CHECK_UPDATES"
  [ "$output" = "false" ]
}

# The image has no git, so gh cannot read the repository from the checkout
@test "check-updates: the issues job names the repository for gh" {
  run yq '.jobs.issues.env.GH_REPO' "$CHECK_UPDATES"
  [ "$output" = '${{ github.repository }}' ]
  run yq '.jobs.issues.steps[] | select(.name == "Install dependencies") | .run' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  grep -qx 'pacman -Su --noconfirm --needed github-cli' <<<"$output"
}

@test "check-updates: only the issues job writes issues, and it holds no secret" {
  run yq -o=json -I=0 '.jobs.publish.permissions' "$CHECK_UPDATES"
  [ "$output" = '{"contents":"write"}' ]
  run yq -o=json -I=0 '.jobs.issues.permissions' "$CHECK_UPDATES"
  [ "$output" = '{"contents":"read","issues":"write"}' ]
  run yq '.jobs.issues' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [[ "$output" != *"secrets."* && "$output" != *"sudo"* ]]
}

@test "check-updates: the issues job reads the statuses of publish when it ran, else those of check" {
  run yq -o=json -I=0 '[.jobs.issues.steps[] | select(.uses | test("^actions/download-artifact@")) | [.with.name, .with.path, .if]]' "$CHECK_UPDATES"
  [ "$output" = "[[\"checked\",\".status\",\"needs.publish.result == 'skipped'\"],[\"published\",\".status\",\"needs.publish.result != 'skipped'\"]]" ]
  run yq -o=json -I=0 '.jobs.publish.steps[] | select(.with.name == "published") | [.with.path, .if, .with["if-no-files-found"]]' "$CHECK_UPDATES"
  [ "$output" = '["statuses/","always()","error"]' ]
  run yq '.jobs.publish.steps[] | select(.name == "Hand over statuses") | .if' "$CHECK_UPDATES"
  [ "$output" = "always()" ]
}

# Runs the Hand over statuses step of publish in a workspace whose .status
# holds the statuses given as name=status pairs. sudo logs its arguments to
# $SUDO_LOG and runs the command of -u builder as the test user.
run_status_hand_over() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin" pair
  mkdir -p "$ws/.status" "$bin"
  for pair in "$@"; do
    printf '%s\n' "${pair#*=}" >"$ws/.status/${pair%%=*}"
  done
  cat >"$bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SUDO_LOG"
[[ "$1 $2" == "-u builder" ]] || exit 97
shift 2
exec "$@"
EOF
  chmod +x "$bin/sudo"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  : >"$SUDO_LOG"
  step_run publish "Hand over statuses" >"$BATS_TEST_TMPDIR/step.sh"
  run env -C "$ws" PATH="$bin:$PATH" SUDO_LOG="$SUDO_LOG" bash -e "$BATS_TEST_TMPDIR/step.sh"
}

@test "check-updates: publish hands over the regular status files with a package name" {
  mkdir -p "$BATS_TEST_TMPDIR/ws/.status/dir"
  echo secret >"$BATS_TEST_TMPDIR/secret"
  ln -s "$BATS_TEST_TMPDIR/secret" "$BATS_TEST_TMPDIR/ws/.status/link"
  run_status_hand_over foo="updated: 2.0" _alerts=$'foo\tnotice\tNote' _upstream="newer: 0.7.0" .hidden=x -dash=x
  [ "$status" -eq 0 ]
  run env LC_ALL=C ls -A "$BATS_TEST_TMPDIR/ws/statuses"
  [ "$output" = $'_alerts\n_upstream\nfoo' ]
  [ "$(<"$BATS_TEST_TMPDIR/ws/statuses/foo")" = "updated: 2.0" ]
}

# builder wrote .status, so builder reads it: a link swapped in after the
# test of the name reaches nothing that builder cannot read
@test "check-updates: builder reads every status file that publish hands over" {
  run_status_hand_over foo="updated: 2.0" _alerts=$'foo\tnotice\tNote' _upstream="newer: 0.7.0"
  [ "$status" -eq 0 ]
  run env LC_ALL=C sort "$SUDO_LOG"
  [ "$output" = $'-u builder cat -- .status/_alerts\n-u builder cat -- .status/_upstream\n-u builder cat -- .status/foo' ]
}

@test "check-updates: publish hands over nothing when it has no statuses" {
  mkdir -p "$BATS_TEST_TMPDIR/ws"
  step_run publish "Hand over statuses" >"$BATS_TEST_TMPDIR/step.sh"
  run env -C "$BATS_TEST_TMPDIR/ws" bash -e "$BATS_TEST_TMPDIR/step.sh"
  [ "$status" -eq 0 ]
  run ls -A "$BATS_TEST_TMPDIR/ws/statuses"
  [ -z "$output" ]
}

@test "check-updates: the issue step writes each body with its function of scripts/lib/issue.sh" {
  run_issue_step foo="update_failed: boom" bar="held: 2.0" _alerts=$'bar\thold\tNote' _upstream="newer: 0.7.0"
  [ "$status" -eq 0 ]
  run cat "$BODY_LOG"
  [ "$output" = $'alert_issue_body .status/bar https://example.invalid/run\nfailure_issue_body .status/foo https://example.invalid/run\nupstream_issue_body .status/_upstream https://example.invalid/run' ]
}

@test "check-updates: the close step finds an open issue behind 30 others" {
  local i
  GH_OPEN="$(for i in {1..30}; do echo "$i ❌ pkg$i: check failed"; done)"$'\n31 ❌ foo: check failed' \
    run_close_step foo=up_to_date
  [ "$status" -eq 0 ]
  grep -q '^issue close 31 ' "$GH_LOG"
}

@test "check-updates: closes the check issue of a package whose check passed" {
  GH_OPEN=$'12 ❌ foo: check failed\n13 ❌ bar: check failed' \
    run_close_step foo=up_to_date bar="new_version: 2.0.0" _error_count=0
  [ "$status" -eq 0 ]
  grep -qx 'issue close 12 --comment comment' "$GH_LOG"
  grep -qx 'issue close 13 --comment comment' "$GH_LOG"
  run cat "$BODY_LOG"
  [ "$output" = $'close_comment .status/foo https://example.invalid/run\nclose_comment .status/bar https://example.invalid/run' ]
}

@test "check-updates: closes the update issue of a package that reached the AUR" {
  GH_OPEN=$'12 ❌ foo: update failed\n13 ❌ bar: update failed\n14 ❌ baz: update failed\n15 ❌ qux: update failed' \
    run_close_step foo=up_to_date bar="updated: 2.0.0" baz="downgrade: 1.0.0" qux="rebuilt: 1.0.0"
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "4" ]
}

@test "check-updates: keeps the update issue of a package that has not reached the AUR" {
  GH_OPEN=$'12 ❌ foo: update failed\n13 ❌ bar: update failed\n14 ❌ baz: update failed' \
    run_close_step foo="new_version: 2.0.0" bar="downgrade_skipped: 1.0.0" baz="update_failed: boom"
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: keeps the issues of a package whose check still fails" {
  GH_OPEN=$'12 ❌ foo: check failed\n13 ❌ foo: update failed' \
    run_close_step foo="check_failed: API down"
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: closes no issue of another package" {
  GH_OPEN=$'12 ❌ foo-bar: check failed\n13 ❌ Check AUR Package Updates failed' \
    run_close_step foo=up_to_date
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: closes the issue of a package that is no longer held" {
  GH_OPEN=$'12 ✋ foo: update held\n13 ✋ bar: update held\n14 ❌ baz: check failed' \
    run_close_step foo=up_to_date bar="held: 29+2" baz="held: 3.0"
  [ "$status" -eq 0 ]
  grep -qx 'issue close 12 --comment comment' "$GH_LOG"
  grep -qx 'issue close 14 --comment comment' "$GH_LOG"
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "2" ]
  run cat "$BODY_LOG"
  [ "$output" = $'close_comment .status/baz https://example.invalid/run\nclose_comment .status/foo https://example.invalid/run' ]
}

@test "check-updates: closes the held issue of a package whose version reached the AUR" {
  GH_OPEN=$'12 ✋ foo: update held\n13 ✋ bar: update held\n14 ✋ baz: update held\n15 ✋ qux: update held' \
    run_close_step foo=up_to_date bar="updated: 2.0.0" baz="downgrade: 1.0.0" qux="rebuilt: 1.0.0"
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "4" ]
}

# An outage of upstream or a rate limit must not close the issue, or the next
# held run opens it again under a new number
@test "check-updates: keeps the held issue of a package whose version has not reached the AUR" {
  GH_OPEN=$'12 ✋ foo: update held\n13 ✋ bar: update held\n14 ✋ baz: update held' \
    run_close_step foo="check_failed: API down" bar="update_failed: boom" baz="new_version: 2.0.0"
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: closes the issue of an aurtomator release once VERSION holds it or a newer one is out" {
  GH_OPEN=$'21 🚀 aurtomator 0.7.0 available\n22 🚀 aurtomator 0.8.0 available' run_close_step _upstream="current: 0.8.0"
  [ "$status" -eq 0 ]
  grep -qx 'issue close 21 --comment The aurtomator release status is `current: 0.8.0` in https://example.invalid/run.' "$GH_LOG"
  grep -q '^issue close 22 ' "$GH_LOG"
  GH_OPEN=$'21 🚀 aurtomator 0.7.0 available\n22 🚀 aurtomator 0.8.0 available' run_close_step _upstream="newer: 0.8.0"
  [ "$status" -eq 0 ]
  grep -q '^issue close 21 ' "$GH_LOG"
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "1" ]
}

@test "check-updates: keeps the issue of an aurtomator release when the run could not read the release" {
  GH_OPEN=$'21 🚀 aurtomator 0.7.0 available' run_close_step foo=up_to_date
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: the close step lists nothing when Issues are disabled" {
  GH_HAS_ISSUES=false GH_FAIL=1 run_close_step foo=up_to_date
  [ "$status" -eq 0 ]
  run grep -c '^issue ' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: the close step fails when the open issues cannot be listed" {
  GH_FAIL=1 run_close_step foo=up_to_date
  [ "$status" -ne 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: verify runs as builder and hands over as prepare does" {
  run yq '.jobs.verify.steps[] | select(.name == "Verify checksums") | .uses + " " + .with.args' "$CHECK_UPDATES"
  [ "$output" = "./.github/actions/run-as-builder --verify handoff" ]
  [ "$(step_run verify "Hand over")" = "$(step_run prepare "Hand over")" ]
  run yq '[.jobs.verify.steps[].name] | join(",")' "$CHECK_UPDATES"
  [[ "$output" == *"Verify checksums,Hand over,Upload verified handoff"* ]]
  run yq '.jobs.verify.steps[] | select(.name == "Upload verified handoff") | .with.path' "$CHECK_UPDATES"
  [ "$output" = "upload/" ]
}

@test "check-updates: the publish step gets no GitHub token" {
  run yq '.jobs.publish.steps[] | select(.name == "Publish updates") | .with["keep-env"]' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [[ "$output" != *GITHUB_TOKEN* ]]
  run yq '.jobs.publish.steps[] | select(.name == "Publish updates") | .env | has("GITHUB_TOKEN")' "$CHECK_UPDATES"
  [ "$output" = "false" ]
}

# git refuses an empty author name or email in the environment
@test "check-updates: the publish step names an author when the secrets are empty" {
  run yq '.jobs.publish.steps[] | select(.name == "Publish updates") | .env.GIT_AUTHOR_NAME' "$CHECK_UPDATES"
  [ "$output" = "\${{ secrets.AUR_GIT_NAME || 'aurtomator' }}" ]
  run yq '.jobs.publish.steps[] | select(.name == "Publish updates") | .env.GIT_AUTHOR_EMAIL' "$CHECK_UPDATES"
  [ "$output" = "\${{ secrets.AUR_GIT_EMAIL || 'aurtomator@users.noreply.github.com' }}" ]
}

@test "check-updates: publish takes the statuses from the check job" {
  run yq '.jobs.publish.steps[] | select(.with.name == "checked") | .with.path' "$CHECK_UPDATES"
  [ "$output" = ".status" ]
  run yq '.jobs.publish.steps[] | select(.with.name == "verified") | .if' "$CHECK_UPDATES"
  [ "$output" = "needs.verify.result == 'success'" ]
}

NOTIFY="$GITHUB_DIR/workflows/notify-failure.yml"

@test "notify-failure: runs on a failed run of the update workflow" {
  run yq '.name' "$CHECK_UPDATES"
  local name="$output"
  run yq -o=json -I=0 '.on' "$NOTIFY"
  [ "$status" -eq 0 ]
  [ "$output" = "{\"workflow_run\":{\"workflows\":[\"$name\"],\"types\":[\"completed\"]}}" ]
  run yq '.jobs.notify.if' "$NOTIFY"
  [ "$output" = "github.event.workflow_run.conclusion == 'failure' || github.event.workflow_run.conclusion == 'timed_out'" ]
}

@test "notify-failure: reads the jobs of the run and writes issues, nothing else" {
  run yq -o=json -I=0 '.permissions' "$NOTIFY"
  [ "$output" = '{"actions":"read","issues":"write"}' ]
  run yq '[.jobs[].steps[] | select(has("uses"))] | length' "$NOTIFY"
  [ "$output" = "0" ]
}

# Runs the step of notify-failure for run 7 of owner/fork. gh lists the
# titles in $GH_TITLES as the open issues, answers has_issues with
# $GH_HAS_ISSUES (true by default), lists the jobs in $GH_JOBS as the failed
# ones or fails that when $GH_JOBS_FAIL is set, fails the list of issues
# when $GH_FAIL is set and logs every call to $GH_LOG.
run_notify_step() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "api repos/owner/fork") echo "${GH_HAS_ISSUES:-true}" ;;
  "api repos/owner/fork/actions/runs/7/jobs")
    [[ -z "${GH_JOBS_FAIL:-}" ]] || exit 1
    echo "$GH_JOBS"
    ;;
  "issue list")
    [[ -z "${GH_FAIL:-}" ]] || exit 1
    [[ -z "${GH_TITLES:-}" ]] || printf '%s\n' "$GH_TITLES"
    ;;
esac
EOF
  chmod +x "$bin/gh"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : >"$GH_LOG"
  yq '.jobs.notify.steps[0].run' "$NOTIFY" >"$BATS_TEST_TMPDIR/step.sh"
  run env PATH="$bin:$PATH" GH_LOG="$GH_LOG" GH_TITLES="${GH_TITLES:-}" GH_FAIL="${GH_FAIL:-}" \
    GH_HAS_ISSUES="${GH_HAS_ISSUES:-}" GH_JOBS="${GH_JOBS:-}" GH_JOBS_FAIL="${GH_JOBS_FAIL:-}" \
    GH_REPO=owner/fork RUN_ID=7 \
    RUN_URL=https://example.invalid/runs/7 RUN_BRANCH=main bash -e "$BATS_TEST_TMPDIR/step.sh"
}

@test "notify-failure: opens an issue that names the run and its failed jobs" {
  GH_JOBS="check, publish" run_notify_step
  [ "$status" -eq 0 ]
  grep -q '^issue create --title ❌ Check AUR Package Updates failed --label auto-update --body ' "$GH_LOG"
  grep -q 'https://example.invalid/runs/7' "$GH_LOG"
  grep -q 'failed in check, publish' "$GH_LOG"
}

@test "notify-failure: opens the issue when the jobs cannot be listed" {
  GH_JOBS_FAIL=1 run_notify_step
  [ "$status" -eq 0 ]
  grep -q '^issue create --title ❌ Check AUR Package Updates failed ' "$GH_LOG"
  grep -q 'failed in jobs that could not be listed' "$GH_LOG"
}

@test "notify-failure: opens no second issue while one is open" {
  GH_TITLES="❌ Check AUR Package Updates failed" run_notify_step
  [ "$status" -eq 0 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "notify-failure: gives a notice when Issues are disabled" {
  GH_HAS_ISSUES=false GH_FAIL=1 run_notify_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::Issues are disabled in owner/fork"* ]]
  run grep -c '^issue ' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "notify-failure: fails when the open issues cannot be listed" {
  GH_FAIL=1 run_notify_step
  [ "$status" -ne 0 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}
