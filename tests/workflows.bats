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

# ci.yml checks out its own commit. A called workflow checks out the pinned
# commit, so its pin check and the repository and ref of its checkout are
# left out of the comparison.
@test "workflows: the image job is the same in every workflow" {
  local workflow expected count=0
  run yq '.jobs.image' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  expected="$output"
  for workflow in "$GITHUB_DIR"/workflows/*.yml; do
    run yq '.jobs | has("image")' "$workflow"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ] || continue
    echo "$workflow"
    run yq '.jobs.image | del(.steps[] | select(.name == "Check the pin")) |
      del(.steps[] | select(.uses | test("^actions/checkout@")) | .with | (.repository, .ref))' "$workflow"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
    count=$((count + 1))
  done
  # ci.yml and at least one called workflow
  [ "$count" -gt 1 ]
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

@test "workflows: actionlint ignores only the two job.workflow properties" {
  local config="$GITHUB_DIR/actionlint.yaml" expected key keys
  run yq '. | keys | join(" ")' "$config"
  [ "$status" -eq 0 ]
  [ "$output" = "paths" ]
  expected=$(cd "$GITHUB_DIR/.." && grep -lF '${{ job.workflow_' .github/workflows/*.yml | sort)
  [ -n "$expected" ]
  run yq '.paths | keys | .[]' "$config"
  [ "$status" -eq 0 ]
  [ "$(sort <<<"$output")" = "$expected" ]
  keys=("${lines[@]}")
  for key in "${keys[@]}"; do
    echo "$key"
    run yq -o=json -I=0 ".paths[\"$key\"]" "$config"
    [ "$status" -eq 0 ]
    [ "$output" = '{"ignore":["property \"workflow_(repository|sha)\" is not defined in object type"]}' ]
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

@test "ci: the lint job checks the runner of SETUP.md with shellcheck and shfmt" {
  run yq '.jobs.lint.steps[] | select(.name == "shellcheck and shfmt the runner") | .run' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'bash tests/helpers/runner-script.sh >"$RUNNER_TEMP/aurtomator.sh"' ]
  [ "${lines[1]}" = 'shellcheck "$RUNNER_TEMP/aurtomator.sh"' ]
  [ "${lines[2]}" = 'shfmt -d -i 2 -ci "$RUNNER_TEMP/aurtomator.sh"' ]
}

@test "runner-script: fails when SETUP.md holds no runner" {
  local dir="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$dir/tests/helpers" "$dir/docs"
  cp "$BATS_TEST_DIRNAME/helpers/runner-script.sh" "$dir/tests/helpers/"
  printf '# Setup\n\n```bash\necho hi\n```\n' >"$dir/docs/SETUP.md"
  run bash "$dir/tests/helpers/runner-script.sh"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
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

@test "ci: shellcheck checks every test helper" {
  local root="$GITHUB_DIR/.." expected
  expected=$(cd "$root" && find tests/helpers -name '*.sh' | sort)
  [ -n "$expected" ]
  run yq '.jobs.lint.steps[] | select(.name == "shellcheck") | .run' "$GITHUB_DIR/workflows/ci.yml"
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

@test "ci: the test job runs no validate step and the validate job calls the reusable workflow" {
  local ci="$GITHUB_DIR/workflows/ci.yml"
  run yq '.jobs.test.steps[] | select(has("run")) | .run' "$ci"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" != *"validate-pkg.sh"* ]]
  run yq '.jobs.validate.uses' "$ci"
  [ "$status" -eq 0 ]
  [ "$output" = "./.github/workflows/validate.yml" ]
  run yq -o=json -I=0 '.jobs.validate.permissions' "$ci"
  [ "$status" -eq 0 ]
  [ "$output" = '{"contents":"read"}' ]
}

@test "ci: the pipeline job calls check-updates for pushes and same-repository pull requests" {
  local ci="$GITHUB_DIR/workflows/ci.yml"
  run yq '.jobs.pipeline.uses' "$ci"
  [ "$status" -eq 0 ]
  [ "$output" = "./.github/workflows/check-updates.yml" ]
  run yq '.jobs.pipeline.if' "$ci"
  [ "$status" -eq 0 ]
  [ "$output" = "github.event_name == 'push' || github.event.pull_request.head.repo.full_name == github.repository" ]
  run yq -o=json -I=0 '.jobs.pipeline.permissions' "$ci"
  [ "$status" -eq 0 ]
  [ "$output" = '{"contents":"write","issues":"write"}' ]
  run yq '.jobs.validate.secrets' "$ci"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
  run yq '.jobs.pipeline.secrets' "$ci"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "merge-image: runs only after lint, test, validate and pipeline" {
  run yq '.jobs["merge-image"].needs | sort | join(" ")' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "lint pipeline test validate" ]
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

# A job missing from the needs could fail and still merge
@test "ci-ok: needs every job of ci.yml but merge-image" {
  local ci="$GITHUB_DIR/workflows/ci.yml"
  run yq '.jobs | keys | map(select(. != "ci-ok" and . != "merge-image")) | sort | join(" ")' "$ci"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local jobs="$output"
  run yq '.jobs["ci-ok"].needs | sort | join(" ")' "$ci"
  [ "$status" -eq 0 ]
  [ "$output" = "$jobs" ]
}

# Without always() a failed need skips ci-ok, and the ruleset counts a
# skipped check as passed
@test "ci-ok: runs after a failed need" {
  run yq '.jobs["ci-ok"].if' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "always()" ]
}

# A skipped need passes, as pipeline is skipped for a pull request from a fork
@test "ci-ok: fails only when a need failed or was canceled" {
  local ci="$GITHUB_DIR/workflows/ci.yml"
  run yq '.jobs["ci-ok"].steps | length' "$ci"
  [ "$output" = "1" ]
  run yq '.jobs["ci-ok"].steps[0].if' "$ci"
  [ "$output" = "contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')" ]
  yq '.jobs["ci-ok"].steps[0].run' "$ci" >"$BATS_TEST_TMPDIR/step.sh"
  run bash "$BATS_TEST_TMPDIR/step.sh"
  [ "$status" -ne 0 ]
}

@test "ci-ok: holds no permissions and has a time limit" {
  local ci="$GITHUB_DIR/workflows/ci.yml"
  run yq '.jobs["ci-ok"].permissions' "$ci"
  [ "$output" = "{}" ]
  run yq '.jobs["ci-ok"]["timeout-minutes"]' "$ci"
  [ "$output" = "5" ]
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
  [ "$output" = '{"release-type":"simple","version-file":"VERSION","changelog-type":"github","skip-changelog":true,"bump-minor-pre-major":true,"include-component-in-tag":false}' ]
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

@test "check-updates: runs only when called, with the four secrets optional" {
  run yq -o=json -I=0 '.on' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [ "$output" = '{"workflow_call":{"secrets":{"AUR_SSH_KEY":{"required":false},"GPG_SIGNING_KEY":{"required":false},"AUR_GIT_NAME":{"required":false},"AUR_GIT_EMAIL":{"required":false}}}}' ]
  run yq '.concurrency' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "check-updates: every job checks out aurtomator at the SHA of the called workflow" {
  local jobs job path repo='${{ job.workflow_repository }}' sha='${{ job.workflow_sha }}'
  mapfile -t jobs < <(yq '.jobs | keys | .[]' "$CHECK_UPDATES")
  [ "${#jobs[@]}" -eq 6 ]
  for job in "${jobs[@]}"; do
    echo "$job"
    path=aurtomator
    [ "$job" != image ] || path=null
    run yq ".jobs.$job.steps[] | select(.uses | test(\"^actions/checkout@\")) |
      select(.with.repository == \"$repo\" and .with.ref == \"$sha\" and .with[\"persist-credentials\"] == false) |
      .with.path" "$CHECK_UPDATES"
    [ "$status" -eq 0 ]
    [ "$output" = "$path" ]
  done
}

@test "check-updates: check, prepare, verify and publish check out the caller first and aurtomator second" {
  local job
  for job in check prepare verify publish; do
    echo "$job"
    run yq -o=json -I=0 "[.jobs.$job.steps[] | select(.uses | test(\"^actions/checkout@\")) | .with | [has(\"repository\"), .path]]" "$CHECK_UPDATES"
    [ "$status" -eq 0 ]
    [ "$output" = '[[false,null],[true,"aurtomator"]]' ]
  done
  run yq -o=json -I=0 '[.jobs.issues.steps[] | select(.uses | test("^actions/checkout@")) | .with | [has("repository"), .path]]' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [ "$output" = '[[true,"aurtomator"]]' ]
}

@test "check-updates: the image job checks the pin before its checkout" {
  local step="$BATS_TEST_TMPDIR/step.sh"
  run yq -o=json -I=0 '.jobs.image.steps[0] | [.name, .env.SHA]' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [ "$output" = '["Check the pin","${{ job.workflow_sha }}"]' ]
  run yq '.jobs.image.steps[1].uses' "$CHECK_UPDATES"
  [[ "$output" == actions/checkout@* ]]
  step_run image "Check the pin" >"$step"
  run env SHA= bash --noprofile --norc -eo pipefail "$step"
  [ "$status" -eq 1 ]
  [ "$output" = "::error::job.workflow_sha is not a commit SHA: ''" ]
  run env SHA=abc bash --noprofile --norc -eo pipefail "$step"
  [ "$status" -eq 1 ]
  [ "$output" = "::error::job.workflow_sha is not a commit SHA: 'abc'" ]
  run env SHA=0123456789abcdef0123456789abcdef01234567 bash --noprofile --norc -eo pipefail "$step"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check-updates: the check job decides the run and executes no PKGBUILD" {
  run yq '[.jobs.check.steps[] | select(.uses == "./aurtomator/.github/actions/run-as-builder") | .with.args // ""] | @json' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [ "$output" = '[""]' ]
  run yq '.jobs.check.steps[] | select(has("run")) | .run' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--prepare"* ]]
  [[ "$output" != *"update-pkg.sh"* ]]
  run yq '.jobs.check.outputs | keys | join(" ")' "$CHECK_UPDATES"
  [ "$output" = "prepare work" ]
}

# Runs the Decide step in a workspace whose statuses/ holds the statuses that
# Hand over wrote, given as name=status pairs, beside the README of the
# checkout. The copy of the README in $RESULTS differs from it when
# $README_CHANGED is set and is missing when $NO_README_COPY is set. sudo and
# git fail. Prints the step outputs.
run_decide_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin" results="$BATS_TEST_TMPDIR/results" pair
  mkdir -p "$ws/statuses" "$bin" "$results"
  for pair in "$@"; do
    printf '%s\n' "${pair#*=}" >"$ws/statuses/${pair%%=*}"
  done
  echo "table" >"$ws/README.md"
  if [[ -z "${NO_README_COPY:-}" ]]; then
    echo "${README_CHANGED:+new }table" >"$results/README.md"
  fi
  printf '#!/bin/sh\nexit 97\n' >"$bin/sudo"
  printf '#!/bin/sh\nexit 97\n' >"$bin/git"
  chmod +x "$bin/sudo" "$bin/git"
  step_run check Decide >"$BATS_TEST_TMPDIR/step.sh"
  : >"$BATS_TEST_TMPDIR/output"
  (cd "$ws" && PATH="$bin:$PATH" RESULTS="$results" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" \
    bash -e "$BATS_TEST_TMPDIR/step.sh") >/dev/null
  cat "$BATS_TEST_TMPDIR/output"
}

@test "check-updates: Decide prepares when a package is outdated" {
  run run_decide_step pkg="new_version: 2.0.0" other=up_to_date
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

@test "check-updates: Decide publishes only a change of the package table" {
  README_CHANGED=1 run run_decide_step pkg="check_failed: API down"
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=true' ]
  README_CHANGED=1 run run_decide_step pkg="downgrade_skipped: 1.0.0"
  [ "$output" = $'prepare=false\nwork=true' ]
}

@test "check-updates: Decide does nothing when nothing changed" {
  run run_decide_step pkg=up_to_date
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=false' ]
}

@test "check-updates: Decide counts a missing copy of the README as unchanged" {
  NO_README_COPY=1 run run_decide_step pkg=up_to_date
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=false' ]
}

# Decide and the commit step read the copies of Hand over
@test "check-updates: Hand over, Decide and the commit step name the same directory of root" {
  run yq '[.jobs[].steps[] | select(.env.RESULTS) | .name + " " + .env.RESULTS] | sort | unique | join(",")' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [ "$output" = "Commit changes via API /results,Decide /results,Hand over /results" ]
}

@test "check-updates: update-readme.sh runs as builder after check-all.sh, in check and publish" {
  run yq -o=json -I=0 '[.jobs[].steps[] | select(.uses == "./aurtomator/.github/actions/run-as-builder") | .with.readme // "false"]' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [ "$output" = '["true","false","false","true"]' ]
  run run_blocks "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [[ "$output" != *"update-readme.sh"* ]]
  [[ "${output//"./aurtomator/scripts/"/}" != *"./scripts/"* ]]
}

@test "check-updates: prepare runs only for outdated packages and decides nothing" {
  run yq '.jobs.prepare.if' "$CHECK_UPDATES"
  [ "$output" = "needs.check.outputs.prepare == 'true'" ]
  run yq '.jobs.prepare.outputs' "$CHECK_UPDATES"
  [ "$output" = "null" ]
}

@test "check-updates: Stop builder, Hand over and Drop the checkouts run nothing from the workspace" {
  local step
  for step in "Stop builder" "Hand over" "Drop the checkouts"; do
    echo "$step"
    run step_run prepare "$step"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" != *"./scripts/"* ]]
    [[ "$output" != *"GITHUB_OUTPUT"* ]]
    # Hand over only reads files as builder
    [[ "${output//"sudo -u builder cat -- "/}" != *"sudo"* ]]
  done
}

# Prints the index of step $2 of job $1
step_index() {
  yq ".jobs.$1.steps | to_entries | map(select(.value.name == \"$2\")) | .[0].key" "$CHECK_UPDATES"
}

# Root reads what builder wrote only once no process of builder runs, and
# the post step of a checkout comes after the last step of the job
@test "check-updates: Stop builder and Hand over follow the step of builder, and the checkouts go last" {
  local job builder
  for job in check prepare verify publish; do
    echo "$job"
    builder=$(yq ".jobs.$job.steps | to_entries | map(select(.value.uses == \"./aurtomator/.github/actions/run-as-builder\")) | .[0].key" "$CHECK_UPDATES")
    run yq -o=json -I=0 "[.jobs.$job.steps[$((builder + 1))], .jobs.$job.steps[$((builder + 2))], .jobs.$job.steps[-1]] | map([.name, .if])" "$CHECK_UPDATES"
    [ "$status" -eq 0 ]
    [ "$output" = '[["Stop builder","always()"],["Hand over","always()"],["Drop the checkouts","always()"]]' ]
    [ "$(step_run "$job" "Stop builder")" = "$(step_run check "Stop builder")" ]
    [ "$(step_run "$job" "Hand over")" = "$(step_run check "Hand over")" ]
    [ "$(step_run "$job" "Drop the checkouts")" = "$(step_run check "Drop the checkouts")" ]
    # Nothing after the stop runs as builder, but the reads of Hand over
    run yq ".jobs.$job.steps[$((builder + 1)):] | .[] | select(has(\"run\")) | .run" "$CHECK_UPDATES"
    [ "$status" -eq 0 ]
    [[ "${output//"sudo -u builder cat -- "/}" != *"sudo -u builder"* ]]
    run yq ".jobs.$job.steps[$((builder + 1)):] | .[] | .uses // \"\"" "$CHECK_UPDATES"
    [[ "$output" != *run-as-builder* ]]
  done
}

# Runs Drop the checkouts in a workspace that holds README.md and the git
# directory of the caller's checkout, and aurtomator/ unless it exists
run_drop_step() {
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/.git"
  echo "[core]" >"$ws/.git/config"
  echo "readme" >"$ws/README.md"
  if [[ ! -e "$ws/aurtomator" && ! -L "$ws/aurtomator" ]]; then
    mkdir -p "$ws/aurtomator/.git"
    echo "[core]" >"$ws/aurtomator/.git/config"
  fi
  step_run check "Drop the checkouts" >"$BATS_TEST_TMPDIR/step.sh"
  run env -C "$ws" bash --noprofile --norc -eo pipefail "$BATS_TEST_TMPDIR/step.sh"
}

@test "check-updates: Drop the checkouts removes .git and aurtomator, and nothing else" {
  run_drop_step
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/ws/.git" ]
  [ ! -e "$BATS_TEST_TMPDIR/ws/aurtomator" ]
  [ "$(cat "$BATS_TEST_TMPDIR/ws/README.md")" = "readme" ]
}

@test "check-updates: Drop the checkouts removes a link named aurtomator, not what it points to" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere/.git" "$BATS_TEST_TMPDIR/ws"
  echo "[core]" >"$BATS_TEST_TMPDIR/elsewhere/.git/config"
  ln -s ../elsewhere "$BATS_TEST_TMPDIR/ws/aurtomator"
  run_drop_step
  [ "$status" -eq 0 ]
  [ ! -L "$BATS_TEST_TMPDIR/ws/aurtomator" ]
  [ -f "$BATS_TEST_TMPDIR/elsewhere/.git/config" ]
}

BUILDER_ACTION="$GITHUB_DIR/actions/run-as-builder/action.yml"

# builder never writes the checkout, so git there runs as root, and only in
# the commit step. builder's global config holds its name and key for the AUR.
@test "check-updates: git runs only in the commit step, as root, in the checkout" {
  local job steps step line count=0 git_re='(^|[[:space:];&|(!$])git[[:space:]]' ws_git='git -c safe.directory="$PWD" '
  for job in check prepare verify publish; do
    mapfile -t steps < <(yq ".jobs.$job.steps[] | select(has(\"run\") and .name != \"Install dependencies\") | .name" "$CHECK_UPDATES")
    for step in "${steps[@]}"; do
      run step_run "$job" "$step"
      [ "$status" -eq 0 ]
      for line in "${lines[@]}"; do
        [[ ! "$line" =~ ^[[:space:]]*# && "$line" =~ $git_re ]] || continue
        echo "$job, $step: $line"
        [[ "$line" != *"sudo -u builder git config --global "* ]] || continue
        [ "$job $step" = "publish Commit changes via API" ]
        [[ "${line//"$ws_git"/}" != *"git "* ]]
        count=$((count + 1))
      done
    done
  done
  [ "$count" -gt 0 ]
  run yq '.runs.steps[] | .run' "$BUILDER_ACTION"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ $git_re ]]
}

# The workspace stays root's: builder gets its own directory and its SSH key
@test "check-updates: nothing gives the workspace to builder" {
  local line count=0
  run bash -c 'yq ".jobs[].steps[] | select(has(\"run\")) | .run" "$1"; yq ".runs.steps[] | .run" "$2"' _ "$CHECK_UPDATES" "$BUILDER_ACTION"
  [ "$status" -eq 0 ]
  for line in "${lines[@]}"; do
    [[ "$line" == *chown* && ! "$line" =~ ^[[:space:]]*# ]] || continue
    echo "$line"
    [[ "$line" == *'chown -R builder:builder "$SSH_DIR"' || "$line" == *'chown -R builder:builder "$WORK"' ]]
    count=$((count + 1))
  done
  [ "$count" -eq 2 ]
}

# Prints job and step name, tab-separated, of every step that runs
# check-all.sh as builder through the run-as-builder action
builder_steps() {
  yq '.jobs | to_entries[] | .key as $job | .value.steps[] |
    select(.uses == "./aurtomator/.github/actions/run-as-builder") | $job + "\t" + .name' "$CHECK_UPDATES"
}

@test "check-updates: check-all.sh runs only through the run-as-builder action" {
  run run_blocks "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [[ "$output" != *"scripts/check-all.sh"* ]]
  run builder_steps
  [ "${#lines[@]}" -eq 4 ]
}

@test "run-as-builder: takes its inputs through the environment" {
  run yq -o=json -I=0 '.runs.steps[0].env' "$BUILDER_ACTION"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ARGS":"${{ inputs.args }}","KEEP_ENV":"${{ inputs.keep-env }}","README_TOO":"${{ inputs.readme }}","WORK":"/work"}' ]
  run yq '.inputs.readme.default' "$BUILDER_ACTION"
  [ "$output" = "false" ]
}

# Runs the run-as-builder action with the inputs of step $2 of job $1, in
# the shell the action names, from the workspace $BATS_TEST_TMPDIR/ws, with
# $BATS_TEST_TMPDIR/work as the directory of builder. sudo answers its
# check that builder can run check-all.sh with $TEST_X_RC, and for any other
# command records its arguments and directory on one line and its
# environment in $SUDO_LOG, prints $SUDO_OUT on stdout and stderr, leaves two
# processes behind that print $LATE_OUT after it exits, one holding only
# stdout and one only stderr, and exits with $SUDO_RC. chown and git log
# their arguments to chown.log and git.log in the test directory. The action
# sits in aurtomator/ of the workspace, and GITHUB_ACTION_PATH names its
# directory, or $ACTION_PATH when it is set.
run_builder_step() {
  local bin="$BATS_TEST_TMPDIR/bin" ws="$BATS_TEST_TMPDIR/ws" step=".jobs.$1.steps[] | select(.name == \"$2\")" args keep readme
  local action_dir="$BATS_TEST_TMPDIR/ws/aurtomator/.github/actions/run-as-builder"
  mkdir -p "$bin" "$action_dir"
  printf '#!/bin/sh\necho "$*" >>"$CALL_LOGS/chown.log"\n' >"$bin/chown"
  printf '#!/bin/sh\necho "$*" >>"$CALL_LOGS/git.log"\n' >"$bin/git"
  rm -f "$BATS_TEST_TMPDIR/chown.log" "$BATS_TEST_TMPDIR/git.log"
  cat >"$bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2 $3" == "-u builder test" ]]; then
  exit "${TEST_X_RC:-0}"
fi
{ printf '%s cwd=%s\n' "$*" "$PWD"; env; } >>"$SUDO_LOG"
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
  readme=$(yq "$step | .with.readme // \"false\"" "$CHECK_UPDATES")
  rm -f "$SUDO_LOG"
  run env -C "$ws" PATH="$bin:$PATH" GITHUB_WORKSPACE="$ws" CALL_LOGS="$BATS_TEST_TMPDIR" \
    GITHUB_ACTION_PATH="${ACTION_PATH:-$action_dir}" SUDO_LOG="$SUDO_LOG" TEST_X_RC="${TEST_X_RC:-0}" \
    ARGS="$args" KEEP_ENV="$keep" README_TOO="$readme" WORK="$BATS_TEST_TMPDIR/work" \
    bash --noprofile --norc -eo pipefail "$BATS_TEST_TMPDIR/step.sh"
}

# Prints the command lines that sudo recorded, without the environments
sudo_commands() {
  grep -E ' cwd=/' "$SUDO_LOG"
}

@test "check-updates: each builder step runs check-all.sh in its mode, with only the variables it needs" {
  local expected entry job name code="$BATS_TEST_TMPDIR/ws/aurtomator/scripts" work="$BATS_TEST_TMPDIR/work" tab=$'\t'
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  expected=(
    "check${tab}Check updates${tab}--preserve-env=GITHUB_REPOSITORY,GITHUB_TOKEN -u builder $code/check-all.sh cwd=$work${tab}--preserve-env=GITHUB_REPOSITORY,GITHUB_TOKEN -u builder $code/update-readme.sh cwd=$work"
    "prepare${tab}Prepare updates${tab}--preserve-env=GITHUB_REPOSITORY -u builder $code/check-all.sh --prepare handoff cwd=$work${tab}"
    "verify${tab}Verify checksums${tab}--preserve-env=GITHUB_REPOSITORY -u builder $code/check-all.sh --verify handoff cwd=$work${tab}"
    "publish${tab}Publish updates${tab}--preserve-env=GITHUB_REPOSITORY,GPG_KEY_ID,GIT_AUTHOR_NAME,GIT_AUTHOR_EMAIL -u builder $code/check-all.sh --publish handoff cwd=$work${tab}--preserve-env=GITHUB_REPOSITORY,GPG_KEY_ID,GIT_AUTHOR_NAME,GIT_AUTHOR_EMAIL -u builder $code/update-readme.sh cwd=$work"
  )
  for entry in "${expected[@]}"; do
    IFS=$'\t' read -r job name want readme <<<"$entry"
    echo "$job: $name"
    rm -rf "$BATS_TEST_TMPDIR/work"
    SUDO_OUT=ok run_builder_step "$job" "$name"
    [ "$status" -eq 0 ]
    run sudo_commands
    [ "${lines[0]}" = "$want" ]
    [ "${lines[1]:-}" = "$readme" ]
    [ "${#lines[@]}" -le 2 ]
  done
}

@test "run-as-builder: runs update-readme.sh only after a successful check-all.sh" {
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  SUDO_OUT=boom SUDO_RC=3 run_builder_step check "Check updates"
  [ "$status" -eq 3 ]
  run sudo_commands
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"/check-all.sh cwd="* ]]
}

@test "run-as-builder: gives builder its own directory and runs no git" {
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  SUDO_OUT=ok run_builder_step check "Check updates"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/chown.log")" = "-R builder:builder $BATS_TEST_TMPDIR/work" ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/work")" = "700" ]
  [ ! -e "$BATS_TEST_TMPDIR/git.log" ]
}

# Writes the inputs that a job hands to builder into the workspace, with
# files of other names and links beside them
make_builder_inputs() {
  local ws="$BATS_TEST_TMPDIR/ws"
  echo secret >"$BATS_TEST_TMPDIR/secret"
  mkdir -p "$ws/packages/sub" "$ws/.status" "$ws/handoff/prepared/foo" "$ws/handoff/status"
  echo "name: foo" >"$ws/packages/foo.yml"
  echo "name: _x" >"$ws/packages/_x.yml"
  echo "notes" >"$ws/packages/notes.txt"
  echo "name: x" >"$ws/packages/sub/x.yml"
  echo "name: bad" >"$ws/packages/bad name.yml"
  ln -s "$BATS_TEST_TMPDIR/secret" "$ws/packages/link.yml"
  echo "readme" >"$ws/README.md"
  echo "other" >"$ws/other.md"
  echo "new_version: 2.0" >"$ws/.status/foo"
  echo "newer: 0.9.0" >"$ws/.status/_upstream"
  echo "x" >"$ws/.status/.hidden"
  echo "x" >"$ws/.status/-dash"
  ln -s "$BATS_TEST_TMPDIR/secret" "$ws/.status/link"
  echo pkgbuild >"$ws/handoff/prepared/foo/PKGBUILD"
  echo srcinfo >"$ws/handoff/prepared/foo/.SRCINFO"
  echo base >"$ws/handoff/prepared/foo/base"
  echo notes >"$ws/handoff/prepared/foo/notes.txt"
  ln -s "$BATS_TEST_TMPDIR/secret" "$ws/handoff/prepared/foo/link"
  echo "update_failed: boom" >"$ws/handoff/status/foo"
  mkdir -p "$ws/handoff/status/sub"
  echo x >"$ws/handoff/status/sub/x"
  echo other >"$ws/handoff/other"
}

@test "run-as-builder: copies the regular files of the expected names into the directory of builder" {
  local work="$BATS_TEST_TMPDIR/work"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  make_builder_inputs
  SUDO_OUT=ok run_builder_step check "Check updates"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && find . -mindepth 1 | LC_ALL=C sort' _ "$work"
  [ "$output" = "$(printf '%s\n' ./.status ./.status/_upstream ./.status/foo ./README.md ./handoff ./handoff/prepared \
    ./handoff/prepared/foo ./handoff/prepared/foo/.SRCINFO ./handoff/prepared/foo/PKGBUILD ./handoff/prepared/foo/base \
    ./handoff/status ./handoff/status/foo ./packages ./packages/_x.yml ./packages/foo.yml)" ]
  [ "$(cat "$work/packages/foo.yml")" = "name: foo" ]
  [ "$(cat "$work/handoff/status/foo")" = "update_failed: boom" ]
  [ "$(stat -c %a "$work/handoff/prepared/foo/PKGBUILD")" = "644" ]
}

# verify gets no status/ from a prepare in which no update failed
@test "run-as-builder: copies a handoff without statuses" {
  local ws="$BATS_TEST_TMPDIR/ws" work="$BATS_TEST_TMPDIR/work"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  make_builder_inputs
  rm -r "$ws/handoff/status"
  SUDO_OUT=ok run_builder_step verify "Verify checksums"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1/handoff" && find . -type f | LC_ALL=C sort' _ "$work"
  [ "$output" = $'./prepared/foo/.SRCINFO\n./prepared/foo/PKGBUILD\n./prepared/foo/base' ]
}

@test "run-as-builder: copies nothing from an input that is a link" {
  local ws="$BATS_TEST_TMPDIR/ws" work="$BATS_TEST_TMPDIR/work" input
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  make_builder_inputs
  for input in packages .status handoff README.md; do
    mv "$ws/$input" "$BATS_TEST_TMPDIR/real-$input"
    ln -s "$BATS_TEST_TMPDIR/real-$input" "$ws/$input"
  done
  SUDO_OUT=ok run_builder_step check "Check updates"
  [ "$status" -eq 0 ]
  [ -d "$work" ]
  [ -z "$(ls -A "$work")" ]
}

# A directory left by an earlier step could hold files that builder chose
@test "run-as-builder: refuses a directory of builder that exists already" {
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  mkdir -p "$BATS_TEST_TMPDIR/work"
  SUDO_OUT=ok run_builder_step check "Check updates"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::$BATS_TEST_TMPDIR/work exists already"* ]]
  [ ! -e "$SUDO_LOG" ]
  rmdir "$BATS_TEST_TMPDIR/work"
  ln -s "$BATS_TEST_TMPDIR/missing" "$BATS_TEST_TMPDIR/work"
  SUDO_OUT=ok run_builder_step check "Check updates"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::$BATS_TEST_TMPDIR/work exists already"* ]]
  [ ! -e "$SUDO_LOG" ]
}

@test "run-as-builder: stops when builder cannot run check-all.sh" {
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  TEST_X_RC=1 SUDO_OUT=ok run_builder_step check "Check updates"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::builder cannot run $BATS_TEST_TMPDIR/ws/aurtomator/scripts/check-all.sh"* ]]
  [[ "$output" != *"::stop-commands::"* ]]
  [ ! -e "$SUDO_LOG" ]
}

# A wrong GITHUB_ACTION_PATH fails the step before it stops the workflow
# commands and before builder runs anything
@test "run-as-builder: fails at once when its checkout is missing" {
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  ACTION_PATH="$BATS_TEST_TMPDIR/missing/.github/actions/run-as-builder" SUDO_OUT=ok \
    run_builder_step check "Check updates"
  [ "$status" -eq 1 ]
  [[ "$output" != *"::stop-commands::"* ]]
  [ ! -e "$SUDO_LOG" ]
}

@test "check-updates: no line of builder reaches the runner as a command" {
  local steps step token runs
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  mapfile -t steps < <(builder_steps)
  [ "${#steps[@]}" -eq 4 ]
  for step in "${steps[@]}"; do
    echo "$step"
    rm -rf "$BATS_TEST_TMPDIR/work"
    runs=1
    [ "$(yq ".jobs.${step%%$'\t'*}.steps[] | select(.name == \"${step#*$'\t'}\") | .with.readme // \"false\"" "$CHECK_UPDATES")" = false ] || runs=2
    SUDO_OUT=$'::add-mask::true\nfatal: ##[add-mask]true' LATE_OUT="::error::late" \
      run_builder_step "${step%%$'\t'*}" "${step#*$'\t'}"
    [ "$status" -eq 0 ]
    # stop, then for each run two lines on stdout, two on stderr and the
    # late lines, then resume
    [ "${#lines[@]}" -eq $((2 + 6 * runs)) ]
    [[ "${lines[0]}" =~ ^::stop-commands::([0-9a-f]{32})$ ]]
    token="${BASH_REMATCH[1]}"
    [ "${lines[-3]}" = "::error::late" ]
    [ "${lines[-2]}" = "::error::late" ]
    [ "${lines[-1]}" = "::$token::" ]
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
    rm -rf "$BATS_TEST_TMPDIR/work"
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

# Runs the Stop builder step in an empty workspace. builder has uid 1000,
# and no uid when $NO_BUILDER is set. ps lists the processes in $PS_LINES
# until pkill ran and those in $PS_AFTER_KILL after it, as
# "<uid> <ruid> <state>" separated by commas, with the uid of ps itself,
# and exits with $PS_RC. pgrep matches any process of builder, zombies
# included, as the real one does. pkill and sleep only log their calls. A
# step still running after 20 s fails.
run_stop_builder_step() {
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
  printf '#!/bin/sh\n[ "$*" = "-u builder" ] && [ -z "$NO_BUILDER" ] && echo 1000\n' >"$bin/id"
  printf '#!/bin/sh\necho "$*" >>"$CALLS/pkill"\n' >"$bin/pkill"
  printf '#!/bin/sh\necho x >>"$CALLS/sleep"\n' >"$bin/sleep"
  chmod +x "$bin/ps" "$bin/pgrep" "$bin/id" "$bin/pkill" "$bin/sleep"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$CALLS"
  step_run check "Stop builder" >"$BATS_TEST_TMPDIR/step.sh"
  run timeout 20 env -C "$ws" PATH="$bin:$PATH" CALLS="$CALLS" PS_LINES="${PS_LINES:-}" \
    PS_AFTER_KILL="${PS_AFTER_KILL:-}" PS_RC="${PS_RC:-0}" NO_BUILDER="${NO_BUILDER:-}" \
    bash -e "$BATS_TEST_TMPDIR/step.sh"
}

@test "check-updates: Stop builder goes on when builder runs nothing" {
  PS_LINES="0 0 S" run_stop_builder_step
  [ "$status" -eq 0 ]
  [ ! -e "$CALLS/pkill" ]
}

# A job that failed before useradd has no builder and no checkout
@test "check-updates: Stop builder does nothing when the job has no builder" {
  NO_BUILDER=1 PS_RC=1 run_stop_builder_step
  [ "$status" -eq 0 ]
  [ ! -e "$CALLS/pkill" ]
}

@test "check-updates: Stop builder kills builder and goes on when its processes end" {
  PS_LINES="1000 1000 S,1000 1000 R" PS_AFTER_KILL="" run_stop_builder_step
  [ "$status" -eq 0 ]
  grep -qx -- "-KILL -u builder" "$CALLS/pkill"
  grep -qx -- "-KILL -U builder" "$CALLS/pkill"
}

@test "check-updates: Stop builder does not wait for zombies" {
  PS_LINES="1000 1000 S" PS_AFTER_KILL="1000 1000 Z,1000 1000 Z+" run_stop_builder_step
  [ "$status" -eq 0 ]
}

@test "check-updates: Stop builder fails when a process of builder survives" {
  PS_LINES="1000 1000 S" PS_AFTER_KILL="1000 1000 Z,1000 1000 D" run_stop_builder_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [ "$(wc -l <"$CALLS/sleep")" -le 30 ]
}

@test "check-updates: Stop builder counts a process whose real user is builder" {
  PS_LINES="0 1000 S" PS_AFTER_KILL="0 1000 S" run_stop_builder_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "check-updates: Stop builder fails when the process list cannot be read" {
  PS_RC=1 run_stop_builder_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

# Runs the Hand over step of prepare in the workspace $BATS_TEST_TMPDIR/ws,
# with $BATS_TEST_TMPDIR/work as the directory of builder and
# $BATS_TEST_TMPDIR/results as the directory of root, and the commands of
# $BATS_TEST_TMPDIR/bin first on PATH. sudo logs its arguments to $SUDO_LOG
# and runs the command of -u builder as the test user.
run_hand_over_step() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BATS_TEST_TMPDIR/ws" "$bin"
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
  step_run prepare "Hand over" >"$BATS_TEST_TMPDIR/step.sh"
  run env -C "$BATS_TEST_TMPDIR/ws" PATH="$bin:$PATH" SUDO_LOG="$SUDO_LOG" WORK="$BATS_TEST_TMPDIR/work" \
    RESULTS="$BATS_TEST_TMPDIR/results" bash -e "$BATS_TEST_TMPDIR/step.sh"
}

# Writes the files that prepare hands over for the package foo into the
# directory of builder
make_handoff() {
  local dir="$BATS_TEST_TMPDIR/work/handoff"
  mkdir -p "$dir/prepared/foo" "$dir/status"
  echo pkgbuild >"$dir/prepared/foo/PKGBUILD"
  echo srcinfo >"$dir/prepared/foo/.SRCINFO"
  echo base >"$dir/prepared/foo/base"
  echo "updated: 2.0" >"$dir/status/foo"
}

@test "check-updates: Hand over copies the prepared files and the statuses, nothing else" {
  local ws="$BATS_TEST_TMPDIR/ws" work="$BATS_TEST_TMPDIR/work"
  make_handoff
  chmod 0755 "$work/handoff/prepared/foo/PKGBUILD"
  echo notes >"$work/handoff/prepared/foo/notes.txt"
  mkdir -p "$work/handoff/prepared/.x" "$work/handoff/status/sub"
  echo hidden >"$work/handoff/prepared/.x/PKGBUILD"
  echo x >"$work/handoff/status/sub/x"
  echo other >"$work/handoff/other"
  run_hand_over_step
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1/upload" && find . -type f | LC_ALL=C sort' _ "$ws"
  [ "$output" = $'./prepared/foo/.SRCINFO\n./prepared/foo/PKGBUILD\n./prepared/foo/base\n./status/foo' ]
  [ "$(stat -c %a "$ws/upload/prepared/foo/PKGBUILD")" = "644" ]
  [ "$(cat "$ws/upload/status/foo")" = "updated: 2.0" ]
}

# A link would put a file that root can read into an artifact anyone with
# read access to the repository can download
@test "check-updates: Hand over copies no link, also one that find lists" {
  local ws="$BATS_TEST_TMPDIR/ws" work="$BATS_TEST_TMPDIR/work" bin="$BATS_TEST_TMPDIR/bin" round
  echo secret >"$BATS_TEST_TMPDIR/secret"
  for round in real listed; do
    echo "$round"
    rm -rf "$ws" "$work"
    make_handoff
    ln -sf "$BATS_TEST_TMPDIR/secret" "$work/handoff/prepared/foo/PKGBUILD"
    if [[ "$round" == listed ]]; then
      mkdir -p "$bin"
      # Lists links too, as a link swapped in after the listing would be
      printf '#!/usr/bin/env bash\nexec %q prepared status -print0\n' "$(command -v find)" >"$bin/find"
      chmod +x "$bin/find"
    fi
    run_hand_over_step
    [ "$status" -eq 0 ]
    [ ! -e "$ws/upload/prepared/foo/PKGBUILD" ]
    [ -f "$ws/upload/prepared/foo/base" ]
  done
}

@test "check-updates: Hand over copies nothing from a directory that is a link" {
  local ws="$BATS_TEST_TMPDIR/ws" work="$BATS_TEST_TMPDIR/work" dir
  for dir in handoff .status packages work; do
    echo "$dir"
    rm -rf "$ws" "$work" "$BATS_TEST_TMPDIR/results" "$BATS_TEST_TMPDIR/elsewhere"
    make_handoff
    mkdir -p "$work/.status" "$work/packages"
    echo "updated: 2.0" >"$work/.status/foo"
    echo "current: 2.0" >"$work/packages/foo.yml"
    if [[ "$dir" == work ]]; then
      mv "$work" "$BATS_TEST_TMPDIR/elsewhere"
      ln -s "$BATS_TEST_TMPDIR/elsewhere" "$work"
    else
      mv "$work/$dir" "$BATS_TEST_TMPDIR/elsewhere"
      ln -s "$BATS_TEST_TMPDIR/elsewhere" "$work/$dir"
    fi
    run_hand_over_step
    [ "$status" -eq 0 ]
    run find "$ws/upload" "$ws/statuses" "$BATS_TEST_TMPDIR/results/packages" -type f
    [ "$status" -eq 0 ]
    case "$dir" in
      handoff) [[ "$output" != *"/upload/"* && "$output" == *"/statuses/foo"* ]] ;;
      .status) [[ "$output" != *"/statuses/"* && "$output" == *"/upload/"* ]] ;;
      packages) [[ "$output" != *"/results/packages/"* && "$output" == *"/upload/"* ]] ;;
      work) [ -z "$output" ] ;;
    esac
  done
}

@test "check-updates: Hand over copies the statuses, README and YAMLs of builder into directories of root" {
  local ws="$BATS_TEST_TMPDIR/ws" work="$BATS_TEST_TMPDIR/work" results="$BATS_TEST_TMPDIR/results"
  echo secret >"$BATS_TEST_TMPDIR/secret"
  mkdir -p "$work/.status/dir" "$work/packages/sub"
  printf '%s\n' "updated: 2.0" >"$work/.status/foo"
  printf '%s\n' $'foo\tnotice\tNote' >"$work/.status/_alerts"
  printf '%s\n' "newer: 0.9.0" >"$work/.status/_upstream"
  echo x >"$work/.status/.hidden"
  echo x >"$work/.status/-dash"
  ln -s "$BATS_TEST_TMPDIR/secret" "$work/.status/link"
  echo "new table" >"$work/README.md"
  echo "current: 2.0" >"$work/packages/foo.yml"
  echo notes >"$work/packages/notes.txt"
  echo "current: 1.0" >"$work/packages/sub/x.yml"
  echo "current: 1.0" >"$work/packages/bad name.yml"
  ln -s "$BATS_TEST_TMPDIR/secret" "$work/packages/link.yml"
  run_hand_over_step
  [ "$status" -eq 0 ]
  run env LC_ALL=C ls -A "$ws/statuses"
  [ "$output" = $'_alerts\n_upstream\nfoo' ]
  [ "$(<"$ws/statuses/foo")" = "updated: 2.0" ]
  [ "$(<"$results/README.md")" = "new table" ]
  run env LC_ALL=C ls -A "$results/packages"
  [ "$output" = "foo.yml" ]
  [ "$(stat -c %a "$results")" = "700" ]
}

# builder no longer runs, and it reads each file, so a link swapped in
# after the test reaches nothing that builder cannot read
@test "check-updates: Hand over reads every file as builder" {
  local work="$BATS_TEST_TMPDIR/work"
  make_handoff
  mkdir -p "$work/.status" "$work/packages"
  echo "updated: 2.0" >"$work/.status/foo"
  echo "new table" >"$work/README.md"
  echo "current: 2.0" >"$work/packages/foo.yml"
  run_hand_over_step
  [ "$status" -eq 0 ]
  run env LC_ALL=C sort "$SUDO_LOG"
  [ "$output" = "$(printf -- "-u builder cat -- $work/%s\n" .status/foo README.md handoff/prepared/foo/.SRCINFO \
    handoff/prepared/foo/PKGBUILD handoff/prepared/foo/base handoff/status/foo packages/foo.yml | LC_ALL=C sort)" ]
}

# prepare hands over no status/ when no update failed
@test "check-updates: Hand over copies a handoff without statuses" {
  local ws="$BATS_TEST_TMPDIR/ws"
  make_handoff
  rm -r "$BATS_TEST_TMPDIR/work/handoff/status"
  run_hand_over_step
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1/upload" && find . -type f | LC_ALL=C sort' _ "$ws"
  [ "$output" = $'./prepared/foo/.SRCINFO\n./prepared/foo/PKGBUILD\n./prepared/foo/base' ]
}

@test "check-updates: Hand over copies nothing without a directory of builder" {
  local ws="$BATS_TEST_TMPDIR/ws"
  run_hand_over_step
  [ "$status" -eq 0 ]
  [ -d "$ws/upload" ]
  [ -d "$ws/statuses" ]
  [ -z "$(ls -A "$ws/upload")" ]
  [ -z "$(ls -A "$ws/statuses")" ]
  [ ! -s "$SUDO_LOG" ]
}

# Runs the issue step of the issues job in a workspace with the statuses
# given as name=status pairs. gh lists the titles in $GH_TITLES, one per
# line, that start with the emoji of the --label it asks for, the first 30
# unless --limit says otherwise, answers has_issues with $GH_HAS_ISSUES (true
# by default) or fails it when $GH_API_FAIL is set, and logs every call to
# $GH_LOG. aurtomator/scripts/lib.sh of the workspace writes the body "body"
# and logs the function and its arguments to $BODY_LOG. sudo fails.
run_issue_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin" pair
  mkdir -p "$ws/.status" "$ws/aurtomator/scripts" "$bin"
  cat >"$ws/aurtomator/scripts/lib.sh" <<'EOF'
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
    RUN_URL=https://example.invalid/run bash -e "$BATS_TEST_TMPDIR/step.sh"
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
# $GH_FAIL is set and logs every call to $GH_LOG. aurtomator/scripts/lib.sh
# of the workspace writes the comment "comment" and logs the function and
# its arguments to $BODY_LOG.
run_close_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin" pair
  mkdir -p "$ws/.status" "$ws/aurtomator/scripts" "$bin"
  cat >"$ws/aurtomator/scripts/lib.sh" <<'EOF'
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
    GH_HAS_ISSUES="${GH_HAS_ISSUES:-}" GITHUB_REPOSITORY=owner/fork RUN_OK="${RUN_OK:-true}" \
    RUN_URL=https://example.invalid/run bash -e "$BATS_TEST_TMPDIR/step.sh"
}

# A git repository at $BATS_TEST_TMPDIR/ws whose HEAD holds README.md,
# packages/foo.yml and packages/bar.yml, and the copies that Hand over took
# from builder in $BATS_TEST_TMPDIR/results, with the edits given as
# file=text pairs
make_commit_repo() {
  local ws="$BATS_TEST_TMPDIR/ws" results="$BATS_TEST_TMPDIR/results" pair
  mkdir -p "$ws/packages" "$results/packages"
  git -C "$ws" init -q -b main
  echo "readme" >"$ws/README.md"
  echo "current: 1.0" >"$ws/packages/foo.yml"
  echo "current: 1.0" >"$ws/packages/bar.yml"
  git -C "$ws" add .
  git -C "$ws" -c user.name=t -c user.email=t@example.invalid commit -q -m init
  cp "$ws/README.md" "$results/README.md"
  cp "$ws/packages/"*.yml "$results/packages/"
  for pair in "$@"; do
    mkdir -p "$(dirname "$results/${pair%%=*}")"
    printf '%s\n' "${pair#*=}" >"$results/${pair%%=*}"
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
  cat >"$bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SUDO_LOG"
[[ "$1 $2" == "-u builder" ]] || exit 97
shift 2
exec "$@"
EOF
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
  chmod +x "$bin/gh" "$bin/sudo"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  : >"$GH_LOG"
  : >"$SUDO_LOG"
  step_run publish "Commit changes via API" >"$BATS_TEST_TMPDIR/step.sh"
  run env -C "$ws" PATH="$bin:$PATH" GH_LOG="$GH_LOG" SUDO_LOG="$SUDO_LOG" REPO=owner/fork BRANCH=main \
    GH_HEAD="${GH_HEAD:-$(git -C "$ws" rev-parse HEAD)}" GH_TREE_FAIL="${GH_TREE_FAIL:-}" \
    GH_TREE="${GH_TREE:-$(git -C "$ws" ls-tree -r HEAD | awk '{ print $4 " " $3 }')}" \
    RESULTS="$BATS_TEST_TMPDIR/results" GIT_TEST_ASSUME_DIFFERENT_OWNER=1 bash -e "$BATS_TEST_TMPDIR/step.sh"
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

# The copies of Hand over hold what builder wrote, and the checkout is root's
@test "check-updates: the commit step commits the copies of builder and runs nothing as builder" {
  make_commit_repo README.md="new table" packages/foo.yml="current: 2.0"
  GH_HEAD=$MOVED GH_TREE="$(moved_tree packages/bar.yml)" run_commit_step
  [ "$status" -eq 0 ]
  [ ! -s "$SUDO_LOG" ]
  grep -qxF "api repos/owner/fork/git/blobs -f content=$(printf 'new table\n' | base64 -w0) -f encoding=base64 --jq .sha" "$GH_LOG"
  grep -qxF "api repos/owner/fork/git/blobs -f content=$(printf 'current: 2.0\n' | base64 -w0) -f encoding=base64 --jq .sha" "$GH_LOG"
  run grep -c "git/blobs" "$GH_LOG"
  [ "$output" = "2" ]
  [ "$(cat "$BATS_TEST_TMPDIR/ws/README.md")" = "readme" ]
}

# The step commits with contents: write, and the job writes only the README
# and the package YAMLs of the checkout
@test "check-updates: the commit step commits only README.md and the package YAMLs of the checkout" {
  local file ws="$BATS_TEST_TMPDIR/ws"
  for file in aurtomator.sh packages/new.yml packages/sub/x.yml .github/workflows/check-updates.yml; do
    echo "$file"
    rm -rf "$ws" "$BATS_TEST_TMPDIR/results"
    make_commit_repo README.md="new table" "$file=new"
    run_commit_step
    [ "$status" -eq 0 ]
    run grep -c "git/blobs" "$GH_LOG"
    [ "$output" = "1" ]
    grep -qxF "api repos/owner/fork/git/blobs -f content=$(printf 'new table\n' | base64 -w0) -f encoding=base64 --jq .sha" "$GH_LOG"
  done
}

# A blob would turn a tracked link into a file
@test "check-updates: the commit step leaves a tracked link alone" {
  local ws="$BATS_TEST_TMPDIR/ws"
  make_commit_repo
  ln -sf foo.yml "$ws/packages/bar.yml"
  git -C "$ws" add packages/bar.yml
  git -C "$ws" -c user.name=t -c user.email=t@example.invalid commit -q -m link
  echo "current: 2.0" >"$BATS_TEST_TMPDIR/results/packages/bar.yml"
  run_commit_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes to commit"* ]]
}

@test "check-updates: the commit step commits nothing when the copies match the checkout" {
  make_commit_repo
  run_commit_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes to commit"* ]]
  [ ! -s "$GH_LOG" ]
  rm -rf "$BATS_TEST_TMPDIR/results"
  run_commit_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes to commit"* ]]
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

# A change that leaves the package table alone skips publish and still opens
# or closes an issue
@test "check-updates: the issues job runs in every run that checked, after publish" {
  run yq '.jobs.issues.needs | join(" ")' "$CHECK_UPDATES"
  [ "$output" = "image check prepare verify publish" ]
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
  run yq '.jobs.publish.steps[] | select(.name == "Hand over") | .if' "$CHECK_UPDATES"
  [ "$output" = "always()" ]
  run yq -o=json -I=0 '.jobs.check.steps[] | select(.name == "Upload statuses") | [.with.name, .with.path, .with["if-no-files-found"]]' "$CHECK_UPDATES"
  [ "$output" = '["checked","statuses/","error"]' ]
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
    run_close_step foo=up_to_date bar="new_version: 2.0.0"
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
  GH_OPEN=$'12 ❌ foo-bar: check failed\n13 ❌ Check AUR Package Updates failed' RUN_OK=false \
    run_close_step foo=up_to_date
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: a run without a failed job closes the issue of a failed run" {
  GH_OPEN=$'12 ❌ foo: check failed\n13 ❌ Check AUR Package Updates failed' \
    run_close_step foo="check_failed: API down"
  [ "$status" -eq 0 ]
  grep -qx 'issue close 13 --comment Run https://example.invalid/run succeeded.' "$GH_LOG"
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "1" ]
}

@test "check-updates: keeps the issue of a failed run after a failed prepare or verify" {
  GH_OPEN=$'13 ❌ Check AUR Package Updates failed' RUN_OK=false run_close_step foo=up_to_date
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "0" ]
}

# The close step runs only after a publish that succeeded or was skipped, and
# the issues job runs only after a check that succeeded
@test "check-updates: the close step knows whether prepare and verify failed" {
  run yq '.jobs.issues.steps[] | select(.name == "Close resolved issues") | .env.RUN_OK' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [ "$output" = "\${{ (needs.prepare.result == 'success' || needs.prepare.result == 'skipped') && (needs.verify.result == 'success' || needs.verify.result == 'skipped') }}" ]
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
  [ "$output" = "./aurtomator/.github/actions/run-as-builder --verify handoff" ]
  [ "$(step_run verify "Hand over")" = "$(step_run prepare "Hand over")" ]
  run yq '[.jobs.verify.steps[].name] | join(",")' "$CHECK_UPDATES"
  [[ "$output" == *"Verify checksums,Stop builder,Hand over,Upload verified handoff"* ]]
  run yq '[.jobs.prepare.steps[].name] | join(",")' "$CHECK_UPDATES"
  [[ "$output" == *"Prepare updates,Stop builder,Hand over,Upload handoff"* ]]
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

@test "check-updates: Setup AUR SSH fails on an empty key" {
  local step="$BATS_TEST_TMPDIR/step.sh" bin="$BATS_TEST_TMPDIR/bin" ssh_dir="$BATS_TEST_TMPDIR/ssh" block
  block=$(step_run publish "Setup AUR SSH")
  run grep -o -F /home/builder/.ssh <<<"$block"
  [ "${#lines[@]}" -eq 1 ]
  printf '%s\n' "${block//"/home/builder/.ssh"/"$ssh_dir"}" >"$step"
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 0\n' >"$bin/chown"
  chmod +x "$bin/chown"
  run env AUR_SSH_KEY= PATH="$bin:$PATH" bash --noprofile --norc -eo pipefail "$step"
  [ "$status" -eq 1 ]
  [ "$output" = "::error::The secret AUR_SSH_KEY is empty" ]
  [ ! -e "$ssh_dir" ]
  run env AUR_SSH_KEY=key-text PATH="$bin:$PATH" bash --noprofile --norc -eo pipefail "$step"
  [ "$status" -eq 0 ]
  [ "$(cat "$ssh_dir/aur")" = "key-text" ]
  [ -f "$ssh_dir/known_hosts" ]
}

# A run before setup secrets pushes nothing and commits the README
@test "check-updates: publish sets up SSH and GPG only for a package to push" {
  local find
  find=$(step_index publish "Find packages to push")
  [ "$find" -gt "$(step_index publish "Download verified handoff")" ]
  [ "$find" -lt "$(step_index publish "Setup AUR SSH")" ]
  [ "$find" -lt "$(step_index publish "Setup GPG")" ]
  run yq '.jobs.publish.steps[] | select(.name == "Find packages to push") | .id' "$CHECK_UPDATES"
  [ "$output" = "handoff" ]
  run yq -o=json -I=0 '[.jobs.publish.steps[] | select(.name == "Setup AUR SSH" or .name == "Setup GPG") | .if]' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [ "$output" = "[\"steps.handoff.outputs.packages == 'true'\",\"steps.handoff.outputs.packages == 'true'\"]" ]
}

# Runs Find packages to push in $BATS_TEST_TMPDIR/ws and prints its outputs
run_find_packages_step() {
  mkdir -p "$BATS_TEST_TMPDIR/ws"
  step_run publish "Find packages to push" >"$BATS_TEST_TMPDIR/step.sh"
  : >"$BATS_TEST_TMPDIR/output"
  (cd "$BATS_TEST_TMPDIR/ws" && GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" bash -e "$BATS_TEST_TMPDIR/step.sh")
  cat "$BATS_TEST_TMPDIR/output"
}

@test "check-updates: the issues job writes the run summary before it touches an issue" {
  local write
  write=$(step_index issues "Write the run summary")
  [ "$write" -gt "$(step_index issues "Download statuses of publish")" ]
  [ "$write" -lt "$(step_index issues "Close resolved issues")" ]
}

# Runs Write the run summary in a workspace with the statuses given as
# name=status pairs and aurtomator/ linked to this repository; prints the
# summary
run_summary_step() {
  local ws="$BATS_TEST_TMPDIR/ws" pair
  mkdir -p "$ws"
  ln -sfn "$BATS_TEST_DIRNAME/.." "$ws/aurtomator"
  for pair in "$@"; do
    mkdir -p "$ws/.status"
    printf '%s\n' "${pair#*=}" >"$ws/.status/${pair%%=*}"
  done
  step_run issues "Write the run summary" >"$BATS_TEST_TMPDIR/step.sh"
  : >"$BATS_TEST_TMPDIR/summary"
  (cd "$ws" && GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary" bash -e "$BATS_TEST_TMPDIR/step.sh")
  cat "$BATS_TEST_TMPDIR/summary"
}

@test "check-updates: the summary step writes the summary of the statuses" {
  run run_summary_step foo="updated: 1.2.0" bar=up_to_date
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2 packages, 1 up to date." ]
  [[ "$output" == *'| `foo` | 📦 updated to 1.2.0 |'* ]]
}

@test "check-updates: the summary step writes nothing without statuses" {
  run run_summary_step
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check-updates: Find packages to push counts a prepared package only" {
  local dir="$BATS_TEST_TMPDIR/ws/handoff"
  run run_find_packages_step
  [ "$status" -eq 0 ]
  [ "$output" = "packages=false" ]
  mkdir -p "$dir/status" "$dir/prepared"
  echo "update_failed: bad checksum" >"$dir/status/foo"
  echo stray >"$dir/prepared/notes.txt"
  run run_find_packages_step
  [ "$status" -eq 0 ]
  [ "$output" = "packages=false" ]
  mkdir "$dir/prepared/foo"
  echo pkgbuild >"$dir/prepared/foo/PKGBUILD"
  run run_find_packages_step
  [ "$status" -eq 0 ]
  [ "$output" = "packages=true" ]
}

NOTIFY="$GITHUB_DIR/workflows/notify-failure.yml"

@test "notify-failure: runs when called, after the caller's condition" {
  run yq -o=json -I=0 '.on' "$NOTIFY"
  [ "$status" -eq 0 ]
  [ "$output" = '{"workflow_call":null}' ]
  run yq '.jobs.notify.if' "$NOTIFY"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
  run yq '.concurrency' "$NOTIFY"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "notify-failure: names the run it is called from" {
  run yq -o=json -I=0 '.jobs.notify.steps[0].env' "$NOTIFY"
  [ "$status" -eq 0 ]
  [ "$output" = '{"GH_TOKEN":"${{ github.token }}","GH_REPO":"${{ github.repository }}","RUN_ID":"${{ github.run_id }}","RUN_URL":"${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}","RUN_BRANCH":"${{ github.ref_name }}"}' ]
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
# ones (an empty $GH_JOBS lists no failed job) or fails that when
# $GH_JOBS_FAIL is set, fails the list of issues when $GH_FAIL is set and
# logs every call to $GH_LOG.
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
    RUN_URL=https://example.invalid/runs/7 RUN_BRANCH="${RUN_BRANCH:-main}" bash -e "$BATS_TEST_TMPDIR/step.sh"
}

# git takes backticks in a branch name, and a mention after a backtick that
# closes the code span would render in the issue
@test "notify-failure: keeps a branch name with backticks inside its code span" {
  RUN_BRANCH='fix`@owner``' GH_JOBS=check run_notify_step
  [ "$status" -eq 0 ]
  grep -qF 'on ``` fix`@owner`` ``` failed in check' "$GH_LOG"
}

@test "notify-failure: opens an issue that names the run and its failed jobs" {
  GH_JOBS="check, publish" run_notify_step
  [ "$status" -eq 0 ]
  grep -q '^issue create --title ❌ Check AUR Package Updates failed --label auto-update --body ' "$GH_LOG"
  grep -q 'https://example.invalid/runs/7' "$GH_LOG"
  grep -q 'failed in check, publish' "$GH_LOG"
  grep -q 'until a run succeeds, and that run closes this issue\.$' "$GH_LOG"
}

@test "notify-failure: opens the issue when the jobs cannot be listed" {
  GH_JOBS_FAIL=1 run_notify_step
  [ "$status" -eq 0 ]
  grep -q '^issue create --title ❌ Check AUR Package Updates failed ' "$GH_LOG"
  grep -q 'failed in jobs that could not be listed' "$GH_LOG"
}

@test "notify-failure: opens nothing when no job failed" {
  GH_JOBS="" run_notify_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::No job of the run failed, so the canceled run gets no issue"* ]]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
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

VALIDATE="$GITHUB_DIR/workflows/validate.yml"

# A caller job `validate` shows them as `validate / image` and
# `validate / packages`
@test "validate: has the jobs image and packages" {
  run yq '.jobs | keys | join(" ")' "$VALIDATE"
  [ "$status" -eq 0 ]
  [ "$output" = "image packages" ]
}

@test "validate: runs validate-pkg.sh --all of the pinned checkout without a secret" {
  run yq -o=json -I=0 '.on' "$VALIDATE"
  [ "$status" -eq 0 ]
  [ "$output" = '{"workflow_call":null}' ]
  run yq -o=json -I=0 '.permissions' "$VALIDATE"
  [ "$status" -eq 0 ]
  [ "$output" = '{"contents":"read"}' ]
  run grep -c secrets "$VALIDATE"
  [ "$output" = "0" ]
  run yq -o=json -I=0 '[.jobs.packages.steps[] | select(.uses | test("^actions/checkout@")) | .with]' "$VALIDATE"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"persist-credentials":false},{"repository":"${{ job.workflow_repository }}","ref":"${{ job.workflow_sha }}","path":"aurtomator","persist-credentials":false}]' ]
  run yq '.jobs.packages.steps[] | select(has("run")) | .run' "$VALIDATE"
  [ "$status" -eq 0 ]
  grep -qxF './aurtomator/scripts/validate-pkg.sh --all' <<<"$output"
}

# The loop test of the image job leaves out the pin check and the
# repository and ref of the checkout, so this test compares the whole job
# with the one of check-updates.yml
@test "validate: the image job is the one of check-updates" {
  local expected
  run yq '.jobs.image' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  expected="$output"
  run yq '.jobs.image' "$VALIDATE"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "validate: the packages job runs in the image, after it" {
  run yq '.jobs.packages.needs' "$VALIDATE"
  [ "$status" -eq 0 ]
  [ "$output" = "image" ]
  run yq '.jobs.packages.container' "$VALIDATE"
  [ "$status" -eq 0 ]
  [ "$output" = '${{ needs.image.outputs.ref }}' ]
  run yq '.jobs.packages["timeout-minutes"]' "$VALIDATE"
  [ "$status" -eq 0 ]
  [ "$output" = "10" ]
}

SETUP_DOC="$BATS_TEST_DIRNAME/../docs/SETUP.md"

# Prints the inside of fenced yaml block $1, 1 or 2, of the section "The
# calling workflows" in docs/SETUP.md
calling_workflow() {
  local text
  text=$(sed -n '/^## The calling workflows$/,/^## /p' "$SETUP_DOC")
  if [ "$1" -eq 2 ]; then
    text=$(sed '0,/^```yaml$/d' <<<"$text" | sed '0,/^```$/d')
  fi
  sed -n '/^```yaml$/,/^```$/{/^```$/q;/^```yaml$/d;p}' <<<"$text"
}

# The template repository is created from these two blocks, with the pin
# of a release in place of <sha> and vX.Y.Z
@test "template: the calling workflows in SETUP.md pin the three files and grant what the jobs need" {
  local check="$BATS_TEST_TMPDIR/check-updates.yml" validate="$BATS_TEST_TMPDIR/validate.yml"
  local workflows=staticwire/aurtomator/.github/workflows
  calling_workflow 1 >"$check"
  calling_workflow 2 >"$validate"
  [ -s "$check" ]
  [ -s "$validate" ]

  run yq '.name' "$check"
  [ "$status" -eq 0 ]
  [ "$output" = "Check AUR Package Updates" ]
  run yq '.on.schedule[0].cron' "$check"
  [ "$output" = "17 * * * *" ]
  run yq '.on | has("workflow_dispatch")' "$check"
  [ "$output" = "true" ]
  run yq '.concurrency.group' "$check"
  [ "$output" = "check-updates" ]
  run yq '.concurrency.cancel-in-progress' "$check"
  [ "$output" = "false" ]
  run yq 'has("permissions")' "$check"
  [ "$output" = "false" ]
  run yq '.jobs.check-updates.uses' "$check"
  [ "$output" = "$workflows/check-updates.yml@<sha>" ]
  run yq '.jobs.check-updates.uses | line_comment' "$check"
  [ "$output" = "vX.Y.Z" ]
  run yq -o=json -I=0 '.jobs.check-updates.permissions' "$check"
  [ "$output" = '{"contents":"write","issues":"write"}' ]
  run yq -o=json -I=0 '.jobs.check-updates.secrets | keys | sort' "$check"
  [ "$output" = '["AUR_GIT_EMAIL","AUR_GIT_NAME","AUR_SSH_KEY","GPG_SIGNING_KEY"]' ]
  run yq '.jobs.check-updates.secrets | to_entries | .[] | select(.value != "${{ secrets." + .key + " }}") | .key' "$check"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run yq '.jobs.notify.needs' "$check"
  [ "$output" = "check-updates" ]
  run yq '.jobs.notify.if' "$check"
  [ "$output" = "\${{ always() && needs.check-updates.result != 'success' }}" ]
  run yq '.jobs.notify.uses' "$check"
  [ "$output" = "$workflows/notify-failure.yml@<sha>" ]
  run yq '.jobs.notify.uses | line_comment' "$check"
  [ "$output" = "vX.Y.Z" ]
  run yq -o=json -I=0 '.jobs.notify.permissions' "$check"
  [ "$output" = '{"actions":"read","issues":"write"}' ]

  run yq '.name' "$validate"
  [ "$status" -eq 0 ]
  [ "$output" = "Validate packages" ]
  run yq -o=json -I=0 '.on.push.branches' "$validate"
  [ "$output" = '["main"]' ]
  run yq '.on | has("pull_request")' "$validate"
  [ "$output" = "true" ]
  run yq -o=json -I=0 '.permissions' "$validate"
  [ "$output" = '{"contents":"read"}' ]
  run yq '.jobs.validate.uses' "$validate"
  [ "$output" = "$workflows/validate.yml@<sha>" ]
  run yq '.jobs.validate.uses | line_comment' "$validate"
  [ "$output" = "vX.Y.Z" ]
}
