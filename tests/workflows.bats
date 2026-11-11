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

# The image job is the same in every workflow, so the step of ci.yml stands
# for all of them
@test "ci-image: the image job takes only a digest pin of archlinux:base-devel" {
  local step="$BATS_TEST_TMPDIR/read-image.sh" work="$BATS_TEST_TMPDIR/work" digest from
  digest=$(printf 'a%.0s' {1..64})
  yq '.jobs.image.steps[] | select(.name == "Read image") | .run' "$GITHUB_DIR/workflows/ci.yml" >"$step"
  mkdir -p "$work/.github/ci-image"
  for from in archlinux:base-devel "archlinux:base-devel@sha256:${digest:1}" "archlinux:base-devel@sha256:${digest}a" \
    "archlinux:base-devel@sha256:${digest^^}" "archlinux:base@sha256:$digest" "evil/archlinux:base-devel@sha256:$digest"; do
    echo "FROM $from" >"$work/.github/ci-image/Dockerfile"
    : >"$work/out"
    run env -C "$work" GITHUB_OUTPUT="$work/out" bash --noprofile --norc -eo pipefail "$step"
    echo "$from: $output"
    [ "$status" -eq 1 ]
    [ "$output" = "::error::.github/ci-image/Dockerfile must pin archlinux:base-devel by digest" ]
    [ ! -s "$work/out" ]
  done
  printf '%s\n' "# FROM archlinux:latest" "FROM archlinux:base-devel@sha256:$digest" >"$work/.github/ci-image/Dockerfile"
  run env -C "$work" GITHUB_OUTPUT="$work/out" bash --noprofile --norc -eo pipefail "$step"
  [ "$status" -eq 0 ]
  [ "$(cat "$work/out")" = "ref=archlinux:base-devel@sha256:$digest" ]
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

@test "ci: the lint job checks aurtomator.sh with shellcheck and shfmt" {
  run yq '.jobs.lint.steps[] | select(.name == "shellcheck and shfmt the runner") | .run' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [ "$output" = $'shellcheck aurtomator.sh\nshfmt -d -i 2 -ci aurtomator.sh' ]
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

# gem resolves a dependency to its newest release, so the test job names
# every gem with its version and resolves none
@test "ci: the test job installs each gem at a fixed version and no other gem" {
  run yq '.jobs.test.steps[] | select(has("run")) | .run' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  run grep 'gem install' <<<"$output"
  [ "$status" -eq 0 ]
  [ "$output" = "gem install --no-document --ignore-dependencies bashcov:4.0.0 simplecov-cobertura:4.0.0 simplecov:1.3.2 rexml:3.4.4" ]
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

@test "ci: lint has 10 minutes and test 30" {
  local ci="$GITHUB_DIR/workflows/ci.yml"
  run yq '.jobs.lint["timeout-minutes"]' "$ci"
  [ "$output" = "10" ]
  run yq '.jobs.test["timeout-minutes"]' "$ci"
  [ "$output" = "30" ]
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

# Prints the run block of step $2 in job $1 of check-updates.yml. A job in a
# container runs a step as sh -e {0}, so the tests run it with sh -e as well.
step_run() {
  yq ".jobs.$1.steps[] | select(.name == \"$2\") | .run" "$CHECK_UPDATES"
}

# The commit step writes back to the branch of the run, and a tag is none
@test "check-updates: check stops first thing on a run started from a tag" {
  run yq -o=json -I=0 '.jobs.check.steps[0] | [.name, .if]' "$CHECK_UPDATES"
  [ "$output" = "[\"Require a branch\",\"github.ref_type != 'branch'\"]" ]
  run sh -e -c "$(step_run check "Require a branch")"
  [ "$status" -eq 1 ]
  [ "$output" = "::error::Start the run from a branch: it commits its results to the branch it runs on" ]
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
  [ "$output" = "prepare to-prepare work checked-id" ]
  run yq '.jobs.check.outputs["to-prepare"]' "$CHECK_UPDATES"
  [ "$output" = '${{ steps.decide.outputs.to-prepare }}' ]
}

# Prints the artifact-ids of a download of the artifact that job $1 uploads
# as $2
id_of() {
  printf "\${{ needs.%s.outputs.%s-id || '0' }}" "$1" "$2"
}

@test "check-updates: each job gives the id of its upload as an output" {
  local pair job artifact
  for pair in check=checked verify=verified publish=published; do
    job=${pair%%=*} artifact=${pair#*=}
    echo "$job"
    run yq -o=json -I=0 "[.jobs.$job.steps[] | select(.uses | test(\"^actions/upload-artifact@\")) | [.id, .with.name]]" "$CHECK_UPDATES"
    [ "$status" -eq 0 ]
    [ "$output" = "[[\"upload\",\"$artifact\"]]" ]
    run yq ".jobs.$job.outputs[\"$artifact-id\"]" "$CHECK_UPDATES"
    [ "$output" = '${{ steps.upload.outputs.artifact-id }}' ]
  done
}

# A name takes whichever artifact of that name the run holds, and a job of
# the run can upload one. An empty id would download every artifact of the
# run, so 0, which no artifact has, stands in for it. The jobs of prepare
# give no id each, so verify takes their handoffs by a pattern only they
# upload.
@test "check-updates: each job downloads an artifact by the id the job of its upload gave" {
  run yq '.jobs | to_entries[] | .key as $job | .value.steps[] | select(.uses | test("^actions/download-artifact@")) |
    $job + " " + .with.path + " " + (.with["artifact-ids"] // ("pattern " + .with.pattern + " " + (.with["merge-multiple"] | tostring))) + " " + (.with | has("name") | tostring)' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 7 ]
  [ "${lines[0]}" = "prepare .status $(id_of check checked) false" ]
  [ "${lines[1]}" = "verify .status $(id_of check checked) false" ]
  [ "${lines[2]}" = "verify handoffs pattern handoff-* true false" ]
  [ "${lines[3]}" = "publish .status $(id_of check checked) false" ]
  [ "${lines[4]}" = "publish handoff $(id_of verify verified) false" ]
  [ "${lines[5]}" = "issues .status $(id_of check checked) false" ]
  [ "${lines[6]}" = "issues .status $(id_of publish published) false" ]
}

# verify-pkg.sh takes the version and the asset value of the check run
@test "check-updates: verify downloads the statuses of the check job before it runs as builder" {
  run yq -o=json -I=0 '.jobs.verify.needs' "$CHECK_UPDATES"
  [ "$output" = '["image","check","prepare"]' ]
  [ "$(step_index verify "Download statuses")" -lt "$(step_index verify "Verify checksums")" ]
}

# Runs the Decide step in a workspace whose statuses/ holds the statuses that
# Hand over wrote, given as name=status pairs, beside the README of the
# checkout. The copy of the README in $RESULTS differs from it when
# $README_CHANGED is set and is missing when $NO_README_COPY is set. sudo and
# git fail. The day of the card is 2026-11-10. aurtomator/ links to
# $AURTOMATOR_TREE, this tree by default. Prints the step outputs.
run_decide_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin" results="$BATS_TEST_TMPDIR/results" pair
  mkdir -p "$ws/statuses" "$bin" "$results"
  ln -sfn "${AURTOMATOR_TREE:-$BATS_TEST_DIRNAME/..}" "$ws/aurtomator"
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
    GITHUB_REPOSITORY=owner/aur-packages AURTOMATOR_STATS_DATE=2026-11-10 timeout 60 sh -e "$BATS_TEST_TMPDIR/step.sh") \
    >"$BATS_TEST_TMPDIR/decide.out" 2>"$BATS_TEST_TMPDIR/decide.log"
  cat "$BATS_TEST_TMPDIR/output"
}

@test "check-updates: Decide prepares when a package is outdated" {
  run run_decide_step pkg="new_version: 2.0.0" other=up_to_date
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=true\nwork=true\npackages=false\nto-prepare=["pkg"]' ]
  run run_decide_step pkg="available_downgrade: 1.0.0"
  [ "$output" = $'prepare=true\nwork=true\npackages=false\nto-prepare=["pkg"]' ]
  run run_decide_step pkg="new_build: 1.0.0" _assets=$'pkg\t1.0.0-b'
  [ "$output" = $'prepare=true\nwork=true\npackages=false\nto-prepare=["pkg"]' ]
  run run_decide_step pkg="arch_back: 1.0.0 aarch64" _arches=$'pkg\t1.0.0\t\t'
  [ "$output" = $'prepare=true\nwork=true\npackages=false\nto-prepare=["pkg"]' ]
}

@test "check-updates: Decide prepares nothing while an asset is pending" {
  README_CHANGED=1 run run_decide_step pkg="pending: 2.0.0"
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=true\npackages=false\nto-prepare=[]' ]
}

@test "check-updates: Decide prepares nothing while an update waits for its cooldown" {
  README_CHANGED=1 run run_decide_step pkg="cooldown: 2026-11-12"
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=true\npackages=false\nto-prepare=[]' ]
  run run_decide_step pkg="cooldown: 2026-11-12"
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=false\npackages=false\nto-prepare=[]' ]
}

@test "check-updates: Decide publishes only a change of the README" {
  README_CHANGED=1 run run_decide_step pkg="check_failed: API down"
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=true\npackages=false\nto-prepare=[]' ]
  README_CHANGED=1 run run_decide_step pkg="downgrade_skipped: 1.0.0"
  [ "$output" = $'prepare=false\nwork=true\npackages=false\nto-prepare=[]' ]
}

@test "check-updates: Decide does nothing when nothing changed" {
  run run_decide_step pkg=up_to_date
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=false\npackages=false\nto-prepare=[]' ]
}

@test "check-updates: Decide counts a missing copy of the README as unchanged" {
  NO_README_COPY=1 run run_decide_step pkg=up_to_date
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=false\npackages=false\nto-prepare=[]' ]
}

# aurtomator/aurtomator.sh is the runner of the release, and aurtomator.sh of
# the workspace the runner of the repository
@test "check-updates: Decide publishes a runner of the repository that differs from the runner of the release" {
  mkdir -p "$BATS_TEST_TMPDIR/ws"
  echo "old runner" >"$BATS_TEST_TMPDIR/ws/aurtomator.sh"
  run run_decide_step pkg=up_to_date
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=true\npackages=false\nto-prepare=[]' ]
}

@test "check-updates: Decide leaves an equal runner and a link alone" {
  mkdir -p "$BATS_TEST_TMPDIR/ws"
  cp "$BATS_TEST_DIRNAME/../aurtomator.sh" "$BATS_TEST_TMPDIR/ws/aurtomator.sh"
  run run_decide_step pkg=up_to_date
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=false\npackages=false\nto-prepare=[]' ]
  echo "old runner" >"$BATS_TEST_TMPDIR/old"
  ln -sfn "$BATS_TEST_TMPDIR/old" "$BATS_TEST_TMPDIR/ws/aurtomator.sh"
  run run_decide_step pkg=up_to_date
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=false\npackages=false\nto-prepare=[]' ]
}

@test "check-updates: Decide leaves the runner when the checkout of aurtomator holds none" {
  mkdir -p "$BATS_TEST_TMPDIR/ws" "$BATS_TEST_TMPDIR/bare"
  echo "old runner" >"$BATS_TEST_TMPDIR/ws/aurtomator.sh"
  AURTOMATOR_TREE="$BATS_TEST_TMPDIR/bare" run run_decide_step pkg=up_to_date
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=false\npackages=false\nto-prepare=[]' ]
}

@test "check-updates: Decide lists the outdated packages for the jobs of prepare" {
  run run_decide_step b="new_version: 2.0.0" a="available_downgrade: 1.0.0" c="new_build: 1.0.0" \
    d=up_to_date e="pending: 2.0.0" f="check_failed: down" _assets=$'c\t1.0.0-b'
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=true\nwork=true\npackages=false\nto-prepare=["a","b","c"]' ]
  [ ! -e "$BATS_TEST_TMPDIR/ws/statuses/_deferred" ]
}

@test "check-updates: Decide lists no name that Hand over would not take" {
  run run_decide_step "bad name=new_version: 2.0.0" "-x=new_version: 2.0.0" pkg="new_version: 2.0.0"
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=true\nwork=true\npackages=false\nto-prepare=["pkg"]' ]
}

# GitHub starts at most 256 jobs from one matrix
@test "check-updates: Decide prepares 256 packages and leaves the rest for the next run" {
  local pairs=() i expected=""
  for i in $(seq -w 1 258); do
    pairs+=("p$i=new_version: 2.0.0")
  done
  for i in $(seq -w 1 256); do
    expected+="\"p$i\","
  done
  run run_decide_step "${pairs[@]}"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "prepare=true" ]
  [ "${lines[3]}" = "to-prepare=[${expected%,}]" ]
  [ "$(cat "$BATS_TEST_TMPDIR/ws/statuses/_deferred")" = $'p257\np258' ]
  grep -qxF '::warning::2 outdated packages wait for the next run, which prepares at most 256' "$BATS_TEST_TMPDIR/decide.out"
}

# Puts package a, its journal and the card of day $1 into the workspace of
# run_decide_step
decide_stats() {
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/packages" "$ws/stats"
  echo "name: a" >"$ws/packages/a.yml"
  printf '%s\n' 'time,package,event,version,previous,run' '2026-11-08T05:17:41Z,a,tracked,1.0,,6' >"$ws/stats/events.csv"
  AURTOMATOR_STATS_DATE="$1" "$BATS_TEST_DIRNAME/../scripts/stats-card.sh" --journal "$ws/stats/events.csv" \
    --packages "$ws/packages" --name aur-packages --out "$ws/stats" 2>/dev/null
}

@test "check-updates: Decide publishes when the journal or the card is missing" {
  mkdir -p "$BATS_TEST_TMPDIR/ws/packages"
  echo "name: a" >"$BATS_TEST_TMPDIR/ws/packages/a.yml"
  run run_decide_step a=up_to_date
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=true\npackages=true\nto-prepare=[]' ]
  decide_stats 2026-11-10
  rm "$BATS_TEST_TMPDIR/ws/stats/card.svg"
  run run_decide_step a=up_to_date
  [ "$output" = $'prepare=false\nwork=true\npackages=true\nto-prepare=[]' ]
  decide_stats 2026-11-10
  rm "$BATS_TEST_TMPDIR/ws/stats/events.csv"
  run run_decide_step a=up_to_date
  [ "$output" = $'prepare=false\nwork=true\npackages=true\nto-prepare=[]' ]
}

@test "check-updates: Decide publishes once the windows of the card moved" {
  decide_stats 2026-11-09
  run run_decide_step a=up_to_date
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=true\npackages=true\nto-prepare=[]' ]
  decide_stats 2026-11-10
  run run_decide_step a=up_to_date
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=false\npackages=true\nto-prepare=[]' ]
}

# A journal root cannot read would set work in every run, and publish would
# record nothing
@test "check-updates: Decide warns and leaves the run alone for a journal that is a link or no file" {
  local ws="$BATS_TEST_TMPDIR/ws"
  decide_stats 2026-11-09
  ln -sf /dev/zero "$ws/stats/events.csv"
  run run_decide_step a=up_to_date
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=false\npackages=true\nto-prepare=[]' ]
  grep -qx '::warning::stats/events.csv is a link or no regular file, so this run records no statistics' \
    "$BATS_TEST_TMPDIR/decide.out"
  rm -r "$ws/stats"
  echo x >"$ws/stats"
  run run_decide_step a=up_to_date
  [ "$output" = $'prepare=false\nwork=false\npackages=true\nto-prepare=[]' ]
  grep -qx '::warning::stats is a link or no directory, so this run records no statistics' "$BATS_TEST_TMPDIR/decide.out"
  rm "$ws/stats"
  decide_stats 2026-11-09
  mv "$ws/stats" "$ws/other"
  ln -s other "$ws/stats"
  run run_decide_step a=up_to_date
  [ "$output" = $'prepare=false\nwork=false\npackages=true\nto-prepare=[]' ]
  grep -qx '::warning::stats is a link or no directory, so this run records no statistics' "$BATS_TEST_TMPDIR/decide.out"
}

@test "check-updates: Decide leaves the run alone when it cannot draw the card" {
  decide_stats 2026-11-09
  echo 'time,package' >"$BATS_TEST_TMPDIR/ws/stats/events.csv"
  run run_decide_step a=up_to_date
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=false\npackages=true\nto-prepare=[]' ]
}

# Decide, Record statistics and the commit step read the copies of Hand over
@test "check-updates: the steps that read the copies of Hand over name the same directory of root" {
  run yq '[.jobs[].steps[] | select(.env.RESULTS) | .name + " " + .env.RESULTS] | sort | unique | join(",")' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [ "$output" = "Commit changes via API /results,Decide /results,Hand over /results,Record statistics /results" ]
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

@test "check-updates: prepare runs a job for each outdated package and decides nothing" {
  run yq '.jobs.prepare.if' "$CHECK_UPDATES"
  [ "$output" = "needs.check.outputs.prepare == 'true'" ]
  run yq -o=json -I=0 '.jobs.prepare.strategy' "$CHECK_UPDATES"
  [ "$output" = '{"fail-fast":false,"matrix":{"package":"${{ fromJSON(needs.check.outputs.to-prepare) }}"}}' ]
  run yq -o=json -I=0 '.jobs.prepare.env' "$CHECK_UPDATES"
  [ "$output" = '{"PACKAGE":"${{ matrix.package }}"}' ]
  run yq '.jobs.prepare.steps[] | select(.name == "Prepare updates") | .with.package' "$CHECK_UPDATES"
  [ "$output" = '${{ matrix.package }}' ]
  run yq '.jobs.prepare | has("outputs")' "$CHECK_UPDATES"
  [ "$output" = "false" ]
}

# A job of prepare run again uploads a handoff of its own beside the one of
# the attempt before
@test "check-updates: each job of prepare uploads the handoff of its package and attempt" {
  run yq -o=json -I=0 '[.jobs.prepare.steps[] | select(.uses | test("^actions/upload-artifact@")) | [.id, .with.name, .with.path, .with["if-no-files-found"]]]' "$CHECK_UPDATES"
  [ "$output" = '[[null,"handoff-${{ matrix.package }}-${{ github.run_attempt }}","handoff-out/","error"]]' ]
  run yq '.jobs.prepare.steps[] | select(.name == "Name the attempt") | .env.ATTEMPT' "$CHECK_UPDATES"
  [ "$output" = '${{ github.run_attempt }}' ]
  [ "$(step_index prepare "Name the attempt")" -eq $(($(step_index prepare "Hand over") + 1)) ]
  [ "$(step_index prepare "Upload handoff")" -eq $(($(step_index prepare "Name the attempt") + 1)) ]
}

@test "check-updates: Name the attempt puts the handoff in a directory of the attempt" {
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/upload/prepared/foo"
  echo pkgbuild >"$ws/upload/prepared/foo/PKGBUILD"
  step_run prepare "Name the attempt" >"$BATS_TEST_TMPDIR/step.sh"
  run env -C "$ws" ATTEMPT=3 sh -e "$BATS_TEST_TMPDIR/step.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$ws/handoff-out/3/prepared/foo/PKGBUILD")" = "pkgbuild" ]
  [ ! -e "$ws/upload" ]
}

# Helper: the prepared files of attempt $1 of a job of prepare for package
# $2, each holding $3, as verify downloads them into handoffs/
add_attempt() {
  local dir="$BATS_TEST_TMPDIR/ws/handoffs/$1" file
  mkdir -p "$dir/prepared/$2"
  for file in PKGBUILD .SRCINFO base; do
    echo "$3" >"$dir/prepared/$2/$file"
  done
}

# Runs the step of verify that takes the newest handoffs, and lists every
# file of handoff/ with its content
run_take_step() {
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws"
  step_run verify "Take the newest handoffs" >"$BATS_TEST_TMPDIR/step.sh"
  (cd "$ws" && sh -e "$BATS_TEST_TMPDIR/step.sh") || return
  (cd "$ws/handoff" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(cat "$f")"; done)
}

@test "check-updates: verify takes the handoff of the newest attempt of each package" {
  add_attempt 1 foo old
  add_attempt 1 bar first
  add_attempt 2 foo new
  run run_take_step
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' './prepared/bar/.SRCINFO first' './prepared/bar/PKGBUILD first' './prepared/bar/base first' \
    './prepared/foo/.SRCINFO new' './prepared/foo/PKGBUILD new' './prepared/foo/base new')" ]
}

@test "check-updates: verify takes the failure of a newer attempt over older prepared files" {
  add_attempt 1 foo old
  mkdir -p "$BATS_TEST_TMPDIR/ws/handoffs/2/status"
  echo "update_failed: boom" >"$BATS_TEST_TMPDIR/ws/handoffs/2/status/foo"
  run run_take_step
  [ "$status" -eq 0 ]
  [ "$output" = "./status/foo update_failed: boom" ]
}

@test "check-updates: verify takes no link, no other name and no other attempt directory" {
  local ws="$BATS_TEST_TMPDIR/ws"
  echo secret >"$BATS_TEST_TMPDIR/secret"
  add_attempt 1 foo kept
  ln -sf "$BATS_TEST_TMPDIR/secret" "$ws/handoffs/1/prepared/foo/base"
  add_attempt 01 bar padded
  add_attempt x baz word
  mkdir -p "$ws/handoffs/1/status" "$BATS_TEST_TMPDIR/elsewhere/prepared/foo"
  echo x >"$ws/handoffs/1/status/-x"
  echo linked >"$BATS_TEST_TMPDIR/elsewhere/prepared/foo/PKGBUILD"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$ws/handoffs/9"
  run run_take_step
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' './prepared/foo/.SRCINFO kept' './prepared/foo/PKGBUILD kept')" ]
}

@test "check-updates: verify takes nothing without handoffs" {
  run run_take_step
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -d "$BATS_TEST_TMPDIR/ws/handoff" ]
}

@test "check-updates: verify compares the attempts as numbers" {
  add_attempt 2 foo second
  add_attempt 10 foo tenth
  run run_take_step
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' './prepared/foo/.SRCINFO tenth' './prepared/foo/PKGBUILD tenth' './prepared/foo/base tenth')" ]
}

@test "check-updates: verify takes nothing through a linked directory of an attempt" {
  local ws="$BATS_TEST_TMPDIR/ws" linked="$BATS_TEST_TMPDIR/linked"
  mkdir -p "$linked/prepared/foo" "$linked/bar" "$linked/status" "$ws/handoffs/1" "$ws/handoffs/2/prepared" "$ws/handoffs/3"
  echo linked | tee "$linked/prepared/foo/PKGBUILD" "$linked/bar/PKGBUILD" "$linked/status/baz" >/dev/null
  ln -s "$linked/prepared" "$ws/handoffs/1/prepared"
  ln -s "$linked/bar" "$ws/handoffs/2/prepared/bar"
  ln -s "$linked/status" "$ws/handoffs/3/status"
  add_attempt 4 qux kept
  run run_take_step
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' './prepared/qux/.SRCINFO kept' './prepared/qux/PKGBUILD kept' './prepared/qux/base kept')" ]
}

@test "check-updates: verify takes nothing from handoffs that is a link" {
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere/1/prepared/foo" "$ws"
  echo linked >"$BATS_TEST_TMPDIR/elsewhere/1/prepared/foo/PKGBUILD"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$ws/handoffs"
  run run_take_step
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check-updates: verify also runs after a failed job of prepare" {
  run yq '.jobs.verify.if' "$CHECK_UPDATES"
  [ "$output" = "!cancelled() && needs.check.outputs.prepare == 'true'" ]
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
    # As builder, Stop builder only signals and Hand over only reads files
    output=${output//"sudo -u builder kill -KILL -1 "/}
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
    # Hand over reads nothing while a process of builder may still run
    run yq -o=json -I=0 "[.jobs.$job.steps[$((builder + 1))], .jobs.$job.steps[$((builder + 2))], .jobs.$job.steps[-1]] | map([.name, .if, .id])" "$CHECK_UPDATES"
    [ "$status" -eq 0 ]
    [ "$output" = "[[\"Stop builder\",\"always()\",\"stop\"],[\"Hand over\",\"always() && steps.stop.outcome == 'success'\",null],[\"Drop the checkouts\",\"always()\",null]]" ]
    [ "$(step_run "$job" "Stop builder")" = "$(step_run check "Stop builder")" ]
    [ "$(step_run "$job" "Hand over")" = "$(step_run check "Hand over")" ]
    [ "$(step_run "$job" "Drop the checkouts")" = "$(step_run check "Drop the checkouts")" ]
    # Nothing after the step of builder runs as builder, but the kill of
    # Stop builder and the reads of Hand over
    run yq ".jobs.$job.steps[$((builder + 1)):] | .[] | select(has(\"run\")) | .run" "$CHECK_UPDATES"
    [ "$status" -eq 0 ]
    output=${output//"sudo -u builder kill -KILL -1 "/}
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
  [ "$output" = '{"ARGS":"${{ inputs.args }}","KEEP_ENV":"${{ inputs.keep-env }}","PACKAGE":"${{ inputs.package }}","README_TOO":"${{ inputs.readme }}","WORK":"/work"}' ]
  run yq '.inputs.readme.default' "$BUILDER_ACTION"
  [ "$output" = "false" ]
  run yq '.inputs.package.default' "$BUILDER_ACTION"
  [ "$output" = "" ]
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
# directory, or $ACTION_PATH when it is set. The input package takes
# $MATRIX_PACKAGE, foo by default, for the package of a job of the matrix,
# and $PACKAGE_INPUT in place of the input of the step when it is set.
run_builder_step() {
  local bin="$BATS_TEST_TMPDIR/bin" ws="$BATS_TEST_TMPDIR/ws" step=".jobs.$1.steps[] | select(.name == \"$2\")" args keep readme package
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
  package=$(yq "$step | .with.package // \"\"" "$CHECK_UPDATES")
  # shellcheck disable=SC2016
  package=${package//'${{ matrix.package }}'/${MATRIX_PACKAGE-foo}}
  package=${PACKAGE_INPUT-$package}
  rm -f "$SUDO_LOG"
  run env -C "$ws" PATH="$bin:$PATH" GITHUB_WORKSPACE="$ws" CALL_LOGS="$BATS_TEST_TMPDIR" \
    GITHUB_ACTION_PATH="${ACTION_PATH:-$action_dir}" SUDO_LOG="$SUDO_LOG" TEST_X_RC="${TEST_X_RC:-0}" \
    ARGS="$args" KEEP_ENV="$keep" PACKAGE="$package" README_TOO="$readme" WORK="$BATS_TEST_TMPDIR/work" \
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
  mkdir -p "$ws/handoff/status/sub" "$ws/handoff/prepared/foo/status" "$ws/handoff/prepared/xstatus"
  echo x >"$ws/handoff/status/sub/x"
  echo x >"$ws/handoff/prepared/foo/status/x"
  echo x >"$ws/handoff/prepared/xstatus/x"
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

@test "run-as-builder: gives builder the files of one package when the input names it" {
  local ws="$BATS_TEST_TMPDIR/ws" work="$BATS_TEST_TMPDIR/work"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  make_builder_inputs
  echo "name: bar" >"$ws/packages/bar.yml"
  echo "new_version: 3.0" >"$ws/.status/bar"
  printf 'foo\t2.0-x\nbar\t3.0-x\n' >"$ws/.status/_assets"
  printf 'foo\t2.0\taarch64\t\nbar\t3.0\t\t\n' >"$ws/.status/_arches"
  printf 'bar\tnotice\tNote\n' >"$ws/.status/_alerts"
  PACKAGE_INPUT=foo SUDO_OUT=ok run_builder_step check "Check updates"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && find . -mindepth 1 | LC_ALL=C sort' _ "$work"
  [ "$output" = "$(printf '%s\n' ./.status ./.status/_arches ./.status/_assets ./.status/_upstream ./.status/foo ./packages ./packages/foo.yml)" ]
}

@test "run-as-builder: copies nothing of one package through a link" {
  local ws="$BATS_TEST_TMPDIR/ws" work="$BATS_TEST_TMPDIR/work" input
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  make_builder_inputs
  for input in packages .status; do
    mv "$ws/$input" "$BATS_TEST_TMPDIR/real-$input"
    ln -s "$BATS_TEST_TMPDIR/real-$input" "$ws/$input"
  done
  PACKAGE_INPUT=foo SUDO_OUT=ok run_builder_step check "Check updates"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$work")" ]
}

@test "run-as-builder: refuses a package that is no package name" {
  local name
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  for name in '../x' 'a b' '.x' '-x'; do
    echo "$name"
    rm -rf "$BATS_TEST_TMPDIR/work"
    PACKAGE_INPUT="$name" SUDO_OUT=ok run_builder_step check "Check updates"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::Not a package name: $name"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/work" ]
    [ ! -e "$SUDO_LOG" ]
  done
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

# check requires a branch before it installs anything
@test "check-updates: check, prepare, verify and publish add builder right after the install" {
  local job first
  for job in check prepare verify publish; do
    echo "$job"
    first=0
    [[ "$job" != check ]] || first=1
    run yq -o=json -I=0 "[.jobs.$job.steps[$first].name, .jobs.$job.steps[$((first + 1))].name]" "$CHECK_UPDATES"
    [ "$status" -eq 0 ]
    [ "$output" = '["Install dependencies","Add builder"]' ]
    [ "$(step_run "$job" "Add builder")" = "$(step_run check "Add builder")" ]
  done
}

@test "check-updates: only Add builder adds a user, builder with the uid 2000" {
  local found line
  # has() does not follow an alias, so explode() writes out each one first
  run yq 'explode(.) | .jobs[].steps[] | select(has("run")) | .run' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  mapfile -t found < <(grep -v '^[[:space:]]*#' <<<"$output" | grep useradd)
  [ "${#found[@]}" -eq 4 ]
  for line in "${found[@]}"; do
    [ "$line" = "useradd -m -u 2000 builder" ]
  done
}

# Runs the Add builder step with $RUNNER_TEMP set to /__w/_temp. useradd
# logs its arguments to $CALLS/useradd and exits with $USERADD_RC, id prints
# $BUILDER_UID for builder, and stat prints $TEMP_OWNER as the owner of
# $RUNNER_TEMP. find logs its arguments to $CALLS/find, prints $FOUND and
# exits with $FIND_RC.
run_add_builder_step() {
  local bin="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$bin" "$CALLS"
  printf '#!/bin/sh\necho "$*" >>"$CALLS/useradd"\nexit "$USERADD_RC"\n' >"$bin/useradd"
  printf '#!/bin/sh\n[ "$*" = "-u builder" ] && echo "$BUILDER_UID"\n' >"$bin/id"
  printf '#!/bin/sh\n[ "$*" = "-c %%u $RUNNER_TEMP" ] && [ "$STAT_RC" = 0 ] && echo "$TEMP_OWNER"\nexit "$STAT_RC"\n' >"$bin/stat"
  printf '#!/bin/sh\necho "$*" >>"$CALLS/find"\n[ -z "$FOUND" ] || echo "$FOUND"\nexit "$FIND_RC"\n' >"$bin/find"
  chmod +x "$bin/useradd" "$bin/id" "$bin/stat" "$bin/find"
  step_run check "Add builder" >"$BATS_TEST_TMPDIR/step.sh"
  run env PATH="$bin:$PATH" CALLS="$CALLS" RUNNER_TEMP=/__w/_temp USERADD_RC="${USERADD_RC:-0}" \
    BUILDER_UID="${BUILDER_UID:-2000}" TEMP_OWNER="${TEMP_OWNER:-1001}" STAT_RC="${STAT_RC:-0}" FOUND="${FOUND:-}" \
    FIND_RC="${FIND_RC:-0}" sh -e "$BATS_TEST_TMPDIR/step.sh"
}

@test "check-updates: Add builder adds builder with the uid 2000 when it owns no file of the runner" {
  run_add_builder_step
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$CALLS/useradd")" = "-m -u 2000 builder" ]
  [ "$(cat "$CALLS/find")" = "/__w /__e ( -user builder -o -group builder ) -print -quit" ]
}

@test "check-updates: Add builder fails when the uid of builder is taken" {
  USERADD_RC=4 run_add_builder_step
  [ "$status" -ne 0 ]
  [ ! -e "$CALLS/find" ]
}

@test "check-updates: Add builder fails when builder has the uid of the owner of the runner temp" {
  BUILDER_UID=1001 TEMP_OWNER=1001 run_add_builder_step
  [ "$status" -ne 0 ]
  [[ "$output" == "::error::"* ]]
}

@test "check-updates: Add builder fails when builder owns a file of the runner" {
  FOUND=/__w/_temp/_runner_file_commands/set_env_1 run_add_builder_step
  [ "$status" -ne 0 ]
  [ "$output" = "::error::builder owns /__w/_temp/_runner_file_commands/set_env_1" ]
}

@test "check-updates: Add builder fails when find cannot read the mounts" {
  FIND_RC=1 run_add_builder_step
  [ "$status" -ne 0 ]
  [ "$output" = "::error::find could not search /__w and /__e for the files of builder" ]
}

@test "check-updates: Add builder fails when stat cannot read the owner of the runner temp" {
  STAT_RC=1 run_add_builder_step
  [ "$status" -ne 0 ]
  [ "$output" = "::error::Could not read the owner of /__w/_temp" ]
  [ ! -e "$CALLS/find" ]
}

# Runs the Stop builder step in an empty workspace. builder has uid 2000,
# and no uid when $NO_BUILDER is set. ps lists the processes in $PS_LINES
# until pkill ran, or sudo when $KILL_ENDS is set, and those in
# $PS_AFTER_KILL after it, as "<uid> <ruid> <state>" separated by commas,
# with the uid of ps itself, and exits with $PS_RC. pgrep matches any
# process of builder, zombies included, as the real one does. sudo, pkill
# and sleep only log their calls, sudo and pkill also in their order to
# $CALLS/seq, and sudo exits with $SUDO_RC. A step still running after 20 s
# fails.
run_stop_builder_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$ws" "$bin"
  cat >"$bin/ps" <<'EOF'
#!/usr/bin/env bash
if [[ -e "$CALLS/pkill" || (-n "$KILL_ENDS" && -e "$CALLS/sudo") ]]; then
  lines="$PS_AFTER_KILL"
else
  lines="$PS_LINES"
fi
[[ "${PS_RC:-0}" -eq 0 ]] || exit "$PS_RC"
echo "0 0 R"
[[ -z "$lines" ]] || tr ',' '\n' <<<"$lines"
EOF
  printf '#!/bin/sh\nps | grep -q " 2000 \\| 2000 "\n' >"$bin/pgrep"
  printf '#!/bin/sh\n[ "$*" = "-u builder" ] && [ -z "$NO_BUILDER" ] && echo 2000\n' >"$bin/id"
  printf '#!/bin/sh\necho "$*" >>"$CALLS/sudo"\necho "sudo $*" >>"$CALLS/seq"\nexit "$SUDO_RC"\n' >"$bin/sudo"
  printf '#!/bin/sh\necho "$*" >>"$CALLS/pkill"\necho "pkill $*" >>"$CALLS/seq"\n' >"$bin/pkill"
  printf '#!/bin/sh\necho x >>"$CALLS/sleep"\n' >"$bin/sleep"
  chmod +x "$bin/ps" "$bin/pgrep" "$bin/id" "$bin/sudo" "$bin/pkill" "$bin/sleep"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$CALLS"
  step_run check "Stop builder" >"$BATS_TEST_TMPDIR/step.sh"
  run timeout 20 env -C "$ws" PATH="$bin:$PATH" CALLS="$CALLS" PS_LINES="${PS_LINES:-}" \
    PS_AFTER_KILL="${PS_AFTER_KILL:-}" PS_RC="${PS_RC:-0}" NO_BUILDER="${NO_BUILDER:-}" \
    KILL_ENDS="${KILL_ENDS:-}" SUDO_RC="${SUDO_RC:-0}" sh -e "$BATS_TEST_TMPDIR/step.sh"
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
  [ ! -e "$CALLS/sudo" ]
}

# kill -1 as builder reaches every process builder may signal in one call,
# also one that forks while pkill lists the processes
@test "check-updates: Stop builder first signals every process of builder in one call" {
  KILL_ENDS=1 PS_LINES="2000 2000 S,2000 2000 R" PS_AFTER_KILL="" run_stop_builder_step
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS/sudo")" = "-u builder kill -KILL -1" ]
  [ ! -e "$CALLS/pkill" ]
}

@test "check-updates: Stop builder goes on when the kill of builder fails" {
  SUDO_RC=1 PS_LINES="0 0 S" run_stop_builder_step
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS/sudo")" = "-u builder kill -KILL -1" ]
}

@test "check-updates: Stop builder kills builder and goes on when its processes end" {
  PS_LINES="2000 2000 S,2000 2000 R" PS_AFTER_KILL="" run_stop_builder_step
  [ "$status" -eq 0 ]
  grep -qx -- "-KILL -u builder" "$CALLS/pkill"
  grep -qx -- "-KILL -U builder" "$CALLS/pkill"
  # The one kill -1 comes before the rounds of pkill
  [ "$(head -n 1 "$CALLS/seq")" = "sudo -u builder kill -KILL -1" ]
  [ "$(grep -c '^sudo ' "$CALLS/seq")" -eq 1 ]
}

@test "check-updates: Stop builder does not wait for zombies" {
  PS_LINES="2000 2000 S" PS_AFTER_KILL="2000 2000 Z,2000 2000 Z+" run_stop_builder_step
  [ "$status" -eq 0 ]
}

@test "check-updates: Stop builder fails when a process of builder survives" {
  PS_LINES="2000 2000 S" PS_AFTER_KILL="2000 2000 Z,2000 2000 D" run_stop_builder_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [ "$(wc -l <"$CALLS/sleep")" -le 30 ]
}

@test "check-updates: Stop builder counts a process whose real user is builder" {
  PS_LINES="0 2000 S" PS_AFTER_KILL="0 2000 S" run_stop_builder_step
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
# and runs the command of -u builder as the test user. bash takes the
# options in $HAND_OVER_SHELL, -e by default, as the default shell of a step.
# PACKAGE is $HAND_OVER_PACKAGE, as a job of prepare sets it.
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
  # shellcheck disable=SC2086
  run env -C "$BATS_TEST_TMPDIR/ws" PATH="$bin:$PATH" SUDO_LOG="$SUDO_LOG" WORK="$BATS_TEST_TMPDIR/work" \
    RESULTS="$BATS_TEST_TMPDIR/results" PACKAGE="${HAND_OVER_PACKAGE:-}" sh ${HAND_OVER_SHELL:--e} "$BATS_TEST_TMPDIR/step.sh"
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
  mkdir -p "$work/handoff/prepared/.x" "$work/handoff/status/sub" "$work/handoff/prepared/foo/status" "$work/handoff/prepared/xstatus"
  echo hidden >"$work/handoff/prepared/.x/PKGBUILD"
  echo x >"$work/handoff/status/sub/x"
  echo x >"$work/handoff/prepared/foo/status/x"
  echo x >"$work/handoff/prepared/xstatus/x"
  echo other >"$work/handoff/other"
  run_hand_over_step
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1/upload" && find . -type f | LC_ALL=C sort' _ "$ws"
  [ "$output" = $'./prepared/foo/.SRCINFO\n./prepared/foo/PKGBUILD\n./prepared/foo/base\n./status/foo' ]
  [ "$(stat -c %a "$ws/upload/prepared/foo/PKGBUILD")" = "644" ]
  [ "$(cat "$ws/upload/status/foo")" = "updated: 2.0" ]
}

@test "check-updates: Hand over takes only the package of its job" {
  local ws="$BATS_TEST_TMPDIR/ws" work="$BATS_TEST_TMPDIR/work"
  make_handoff
  mkdir -p "$work/handoff/prepared/bar"
  echo pkgbuild >"$work/handoff/prepared/bar/PKGBUILD"
  echo "update_failed: forged" >"$work/handoff/status/bar"
  HAND_OVER_PACKAGE=foo run_hand_over_step
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1/upload" && find . -type f | LC_ALL=C sort' _ "$ws"
  [ "$output" = $'./prepared/foo/.SRCINFO\n./prepared/foo/PKGBUILD\n./prepared/foo/base\n./status/foo' ]
  rm -rf "$ws"
  run_hand_over_step
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1/upload" && find . -type f | LC_ALL=C sort' _ "$ws"
  [ "$output" = $'./prepared/bar/PKGBUILD\n./prepared/foo/.SRCINFO\n./prepared/foo/PKGBUILD\n./prepared/foo/base\n./status/bar\n./status/foo' ]
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

# prepare hands over no status/ when no update failed. bashcov exports
# SHELLOPTS, so in CI the step runs with pipefail.
@test "check-updates: Hand over copies a handoff without statuses" {
  local ws="$BATS_TEST_TMPDIR/ws" shell
  for shell in "-e" "-eo pipefail"; do
    echo "$shell"
    rm -rf "$ws" "$BATS_TEST_TMPDIR/work"
    make_handoff
    rm -r "$BATS_TEST_TMPDIR/work/handoff/status"
    HAND_OVER_SHELL="$shell" run_hand_over_step
    [ "$status" -eq 0 ]
    run bash -c 'cd "$1/upload" && find . -type f | LC_ALL=C sort' _ "$ws"
    [ "$output" = $'./prepared/foo/.SRCINFO\n./prepared/foo/PKGBUILD\n./prepared/foo/base' ]
  done
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

# A workspace with aurtomator linked in, package a at 1.0 before the run and
# at $1 after it, its status $2, and a journal of one run before
make_stats_ws() {
  local ws="$BATS_TEST_TMPDIR/ws" results="$BATS_TEST_TMPDIR/results"
  mkdir -p "$ws/packages" "$ws/statuses" "$ws/stats" "$results/packages"
  ln -sfn "$BATS_TEST_DIRNAME/.." "$ws/aurtomator"
  printf 'name: a\nstrategy: github-release\nupstream:\n  project: o/a\ncurrent: 1.0\n' >"$ws/packages/a.yml"
  sed "s/^current: .*/current: $1/" "$ws/packages/a.yml" >"$results/packages/a.yml"
  printf '%s\n' "$2" >"$ws/statuses/a"
  printf '%s\n' 'time,package,event,version,previous,run' '2026-11-08T05:17:41Z,a,tracked,1.0,,6' >"$ws/stats/events.csv"
}

# Runs Record statistics in that workspace for the repository $REPO, by
# default owner/aur-packages, at a fixed time and run
run_stats_step() {
  step_run publish "Record statistics" >"$BATS_TEST_TMPDIR/stats-step.sh"
  (cd "$BATS_TEST_TMPDIR/ws" && RESULTS="$BATS_TEST_TMPDIR/results" GITHUB_REPOSITORY="${REPO-owner/aur-packages}" \
    GITHUB_RUN_ID=7 AURTOMATOR_STATS_TIME=2026-11-10T05:17:22Z AURTOMATOR_STATS_DATE=2026-11-10 \
    timeout 60 sh -e "$BATS_TEST_TMPDIR/stats-step.sh")
}

@test "check-updates: Record statistics runs as root between Hand over and the commit step" {
  local at
  at=$(step_index publish "Record statistics")
  [ "$at" = "$(($(step_index publish "Hand over") + 1))" ]
  [ "$(step_index publish "Commit changes via API")" = "$((at + 1))" ]
  run step_run publish "Record statistics"
  [ "$status" -eq 0 ]
  [[ "$output" == *"./aurtomator/scripts/record-events.sh "* ]]
  [[ "$output" != *sudo* ]]
}

@test "check-updates: Record statistics writes the journal and both cards for the commit step" {
  local stats="$BATS_TEST_TMPDIR/results/stats"
  make_stats_ws 1.1 "updated: 1.1"
  run run_stats_step
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$stats/events.csv")" = '2026-11-10T05:17:22Z,a,updated,1.1,1.0,7' ]
  grep -q '>aur-packages</text>' "$stats/card.svg"
  grep -q '>aur-packages</text>' "$stats/card-dark.svg"
  [ "$(ls "$stats")" = $'card-dark.svg\ncard.svg\nevents.csv' ]
}

@test "check-updates: Record statistics warns and leaves stats/ empty when a script fails" {
  local stats="$BATS_TEST_TMPDIR/results/stats"
  make_stats_ws 1.1 "updated: 1.1"
  echo 'time,package' >"$BATS_TEST_TMPDIR/ws/stats/events.csv"
  run run_stats_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::The statistics of this run were not recorded"* ]]
  [ -z "$(ls -A "$stats")" ]
  make_stats_ws 1.1 "updated: 1.1"
  REPO=owner/ run run_stats_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::The statistics of this run were not recorded"* ]]
  [ -z "$(ls -A "$stats")" ]
}

@test "check-updates: Record statistics warns and leaves stats/ empty for a journal that is a link" {
  local stats="$BATS_TEST_TMPDIR/results/stats"
  make_stats_ws 1.1 "updated: 1.1"
  ln -sf /dev/zero "$BATS_TEST_TMPDIR/ws/stats/events.csv"
  run run_stats_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::The statistics of this run were not recorded"* ]]
  [ -z "$(ls -A "$stats")" ]
}

# A stall of a script takes the path of its failure, so the commit lands
@test "check-updates: Record statistics bounds the time of both scripts" {
  run step_run publish "Record statistics"
  [ "$status" -eq 0 ]
  [[ "$output" == *"! timeout 120 ./aurtomator/scripts/record-events.sh "* ]]
  [[ "$output" == *"! timeout 120 ./aurtomator/scripts/stats-card.sh "* ]]
}

@test "check-updates: Record statistics writes nothing without a package or a hand over" {
  local results="$BATS_TEST_TMPDIR/results"
  make_stats_ws 1.0 up_to_date
  rm "$BATS_TEST_TMPDIR/ws/packages/a.yml"
  run run_stats_step
  [ "$status" -eq 0 ]
  [ ! -e "$results/stats" ]
  make_stats_ws 1.0 up_to_date
  rm -r "$results/packages"
  run run_stats_step
  [ "$status" -eq 0 ]
  [ ! -e "$results/stats" ]
}

# Runs the issue step of the issues job in a workspace with the statuses
# given as name=status pairs. gh lists the titles in $GH_TITLES, one per
# line, that start with the emoji of the --label it asks for, the first 30
# unless --limit says otherwise, answers has_issues with $GH_HAS_ISSUES (true
# by default) or fails it when $GH_API_FAIL is set, and logs every call to
# $GH_LOG. A creation fails with an error of two lines when $GH_CREATE_FAIL
# is set. aurtomator/scripts/lib.sh of the workspace takes failed_hosts from
# scripts/lib/issue.sh, writes the body "body" and logs the function and its
# arguments to $BODY_LOG. sudo fails.
run_issue_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin" pair
  mkdir -p "$ws/.status" "$ws/aurtomator/scripts" "$bin"
  printf 'set -euo pipefail\nsource %q\n' "$BATS_TEST_DIRNAME/../scripts/lib/issue.sh" >"$ws/aurtomator/scripts/lib.sh"
  cat >>"$ws/aurtomator/scripts/lib.sh" <<'EOF'
failure_issue_body() { echo "failure_issue_body $*" >>"$BODY_LOG" && echo body; }
alert_issue_body() { echo "alert_issue_body $*" >>"$BODY_LOG" && echo body; }
upstream_issue_body() { echo "upstream_issue_body $*" >>"$BODY_LOG" && echo body; }
host_issue_body() { echo "host_issue_body $*" >>"$BODY_LOG" && echo body; }
arch_issue_body() { echo "arch_issue_body $*" >>"$BODY_LOG" && echo body; }
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
if [[ "$1 $2" == "issue create" && -n "${GH_CREATE_FAIL:-}" ]]; then
  printf 'GraphQL: was submitted too quickly (createIssue)\nsecond line\n' >&2
  exit 1
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
        arch-missing) emoji="⚠️" ;;
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
    GH_CREATE_FAIL="${GH_CREATE_FAIL:-}" GITHUB_REPOSITORY=owner/fork \
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

@test "check-updates: the issue step asks GitHub nothing for an update in its cooldown" {
  run_issue_step foo="cooldown: 2026-11-12"
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

@test "check-updates: the issue step opens an issue for a package published without some arches" {
  run_issue_step foo=up_to_date _without=$'foo\t28+23\taarch64 riscv64'
  [ "$status" -eq 0 ]
  grep -qx 'label create arch-missing --color e99695 --description Published without some arches' "$GH_LOG"
  grep -qx 'issue create --title ⚠️ foo: 28+23 without aarch64 riscv64 --label arch-missing --body body' "$GH_LOG"
  [ "$(cat "$BODY_LOG")" = "arch_issue_body foo 28+23 aarch64 riscv64 https://example.invalid/run" ]
}

@test "check-updates: an open arch issue of the package holds back another one" {
  GH_TITLES='⚠️ foo: 28+22 without aarch64' run_issue_step _without=$'foo\t28+23\taarch64 riscv64'
  [ "$status" -eq 0 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: an open arch issue of another package holds back no issue" {
  GH_TITLES='⚠️ foo-bar: 1.0 without aarch64' run_issue_step _without=$'foo\t28+23\taarch64'
  [ "$status" -eq 0 ]
  grep -q '^issue create --title ⚠️ foo: 28+23 without aarch64 ' "$GH_LOG"
}

@test "check-updates: the issue step gives a notice for arches out when Issues are disabled" {
  GH_HAS_ISSUES=false GH_FAIL=1 run_issue_step _without=$'foo\t28+23\taarch64'
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::Issues are disabled in owner/fork"* ]]
  run grep -c '^issue ' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: the issue step asks GitHub nothing for an empty _without" {
  run_issue_step foo=up_to_date _without=
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

# Prints a name=status pair for each of $1 packages, named $3 and a number,
# whose check failed on host $2
host_failures() {
  local i
  for ((i = 1; i <= $1; i++)); do
    printf '%s\n' "$3$i=check_failed: https://$2/repos/o/$3$i/tags: The requested URL returned error: 503"
  done
}

@test "check-updates: 5 packages whose check failed on one host share one issue" {
  local pairs
  mapfile -t pairs < <(host_failures 5 api.github.com a)
  run_issue_step "${pairs[@]}" b="check_failed: https://github.com/o/b: error: 503" c="update_failed: boom"
  [ "$status" -eq 0 ]
  grep -qx 'issue create --title ❌ api.github.com: 5 packages failed to check --label auto-update --body body' "$GH_LOG"
  grep -q '^issue create --title ❌ b: check failed ' "$GH_LOG"
  grep -q '^issue create --title ❌ c: update failed ' "$GH_LOG"
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "3" ]
  grep -qx 'host_issue_body .status api.github.com https://example.invalid/run a1 a2 a3 a4 a5' "$BODY_LOG"
}

@test "check-updates: 4 packages whose check failed on one host get an issue each" {
  local pairs
  mapfile -t pairs < <(host_failures 4 api.github.com a)
  run_issue_step "${pairs[@]}"
  [ "$status" -eq 0 ]
  run grep -c '^issue create --title ❌ a[1-4]: check failed ' "$GH_LOG"
  [ "$output" = "4" ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "4" ]
}

@test "check-updates: an open issue of the host holds back another one, whatever its count" {
  local pairs
  mapfile -t pairs < <(host_failures 6 api.github.com a)
  GH_TITLES="❌ api.github.com: 9 packages failed to check" run_issue_step "${pairs[@]}"
  [ "$status" -eq 0 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: only the title of the host issue holds it back" {
  local pairs
  mapfile -t pairs < <(host_failures 5 api.github.com a)
  GH_TITLES=$'❌ apixgithubxcom: 9 packages failed to check\n❌ api.github.com: 9 packages failed to check twice\n❌ api.github.com: many packages failed to check' \
    run_issue_step "${pairs[@]}"
  [ "$status" -eq 0 ]
  grep -qx 'issue create --title ❌ api.github.com: 5 packages failed to check --label auto-update --body body' "$GH_LOG"
}

@test "check-updates: the issue step creates each label once and lists its open issues once" {
  local pairs
  mapfile -t pairs < <(host_failures 5 api.github.com a)
  run_issue_step "${pairs[@]}" b="check_failed: boom" c="update_failed: boom" d="held: 1.0" e="held: 2.0"
  [ "$status" -eq 0 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "5" ]
  run grep -c '^label create auto-update ' "$GH_LOG"
  [ "$output" = "1" ]
  run grep -c '^issue list --label auto-update ' "$GH_LOG"
  [ "$output" = "1" ]
  run grep -c '^label create update-held ' "$GH_LOG"
  [ "$output" = "1" ]
  run grep -c '^issue list --label update-held ' "$GH_LOG"
  [ "$output" = "1" ]
}

@test "check-updates: a refused issue gives a warning with the error of gh" {
  GH_CREATE_FAIL=1 run_issue_step foo="update_failed: boom" bar="held: 1.0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Could not create the issue ❌ foo: update failed: GraphQL: was submitted too quickly (createIssue) second line"* ]]
  [[ "$output" == *"::warning::Could not create the issue ✋ bar: update held: GraphQL: was submitted too quickly (createIssue) second line"* ]]
}

# Runs the close step of the issues job in a workspace with the statuses given as
# name=status pairs. gh lists the open issues in $GH_OPEN, one
# "<number> <title>" per line, whose title starts with the emoji of the
# --label it asks for, the first 30 unless --limit says otherwise, answers
# has_issues with $GH_HAS_ISSUES (true by default), fails the list when
# $GH_FAIL is set and logs every call to $GH_LOG. aurtomator/scripts/lib.sh
# of the workspace takes scripts/lib/issue.sh, writes the comment "comment"
# of a package and logs the function and its arguments to $BODY_LOG.
run_close_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin" pair
  mkdir -p "$ws/.status" "$ws/aurtomator/scripts" "$bin"
  printf 'set -euo pipefail\nsource %q\n' "$BATS_TEST_DIRNAME/../scripts/lib/issue.sh" >"$ws/aurtomator/scripts/lib.sh"
  cat >>"$ws/aurtomator/scripts/lib.sh" <<'EOF'
close_comment() { echo "close_comment $*" >>"$BODY_LOG" && echo comment; }
arch_close_comment() { echo "arch_close_comment $*" >>"$BODY_LOG" && echo comment; }
EOF
  for pair in "$@"; do
    printf '%s\n' "${pair#*=}" >"$ws/.status/${pair%%=*}"
  done
  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
cmd="$1 $2" limit=30 emoji="" filter=""
while (($#)); do
  case "$1" in
    --limit) limit=$2 ;;
    --jq) filter=$2 ;;
    --label)
      case "$2" in
        auto-update) emoji="❌" ;;
        update-held) emoji="✋" ;;
        aurtomator-update) emoji="🚀" ;;
        arch-missing) emoji="⚠️" ;;
      esac
      ;;
  esac
  shift
done
# gh answers with the JSON of the API and applies --jq to it
case "$cmd" in
  "api repos/owner/fork") json="{\"has_issues\": ${GH_HAS_ISSUES:-true}}" ;;
  "issue list")
    [[ -z "${GH_FAIL:-}" ]] || exit 1
    json=$({ grep "^[0-9]* $emoji" <<<"${GH_OPEN:-}" || true; } | head -n "$limit" |
      jq -Rn '[inputs | capture("^(?<number>[0-9]+) (?<title>.*)$") | .number |= tonumber]')
    ;;
  *) exit 0 ;;
esac
if [[ -n "$filter" ]]; then
  jq -r "$filter" <<<"$json"
else
  printf '%s\n' "$json"
fi
EOF
  chmod +x "$bin/gh"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  BODY_LOG="$BATS_TEST_TMPDIR/body.log"
  : >"$GH_LOG"
  : >"$BODY_LOG"
  step_run issues "Close resolved issues" >"$BATS_TEST_TMPDIR/step.sh"
  run env -C "$ws" PATH="$bin:$PATH" GH_LOG="$GH_LOG" BODY_LOG="$BODY_LOG" GH_OPEN="${GH_OPEN:-}" GH_FAIL="${GH_FAIL:-}" \
    GH_HAS_ISSUES="${GH_HAS_ISSUES:-}" GITHUB_REPOSITORY=owner/fork RUN_OK="${RUN_OK:-true}" \
    RUN_URL=https://example.invalid/run sh -e "$BATS_TEST_TMPDIR/step.sh"
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
# set, and logs every call to $GH_LOG. It appends the body of each blob to
# $GH_LOG.blobs, one line each. For a new tree it logs the number of
# --input options and keeps the body of the last one in $GH_LOG.tree.
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
endpoint=$2 filter="" inputs=0
while (($#)); do
  case "$1" in
    --jq) filter=$2 ;;
    --input)
      inputs=$((inputs + 1))
      if [[ "$endpoint" == */git/blobs ]]; then
        cat -- "$2" | jq -c . >>"$GH_LOG.blobs"
      else
        cat -- "$2" >"$GH_LOG.tree"
      fi
      ;;
  esac
  shift
done
# gh answers with the JSON of the API and applies --jq to it. A recursive
# tree also lists each directory, as an entry of type tree.
case "$endpoint" in
  repos/owner/fork/git/ref/heads/main) json="{\"object\": {\"sha\": \"$GH_HEAD\", \"type\": \"commit\"}}" ;;
  repos/owner/fork/git/commits/*) json='{"tree": {"sha": "tree-of-head"}}' ;;
  "repos/owner/fork/git/trees/tree-of-head?recursive=1")
    [[ -z "${GH_TREE_FAIL:-}" ]] || exit 1
    json=$(jq -Rn '[inputs | select(length > 0) | capture("^(?<path>.*) (?<sha>[0-9a-f]+)$") | . + {type: "blob"}] as $blobs |
      [$blobs[].path | split("/") | range(1; length) as $i | .[:$i] | join("/")] | unique |
      {sha: "tree-of-head", tree: (map({path: ., type: "tree", sha: "0000000000000000000000000000000000000000"}) + $blobs)}' <<<"$GH_TREE")
    ;;
  repos/owner/fork/git/blobs) json='{"sha": "blob"}' ;;
  repos/owner/fork/git/trees)
    echo "inputs: $inputs" >>"$GH_LOG"
    json='{"sha": "tree"}'
    ;;
  repos/owner/fork/git/commits) json='{"sha": "commit"}' ;;
  repos/owner/fork/git/refs/heads/main) json='{}' ;;
  *) exit 1 ;;
esac
if [[ -n "$filter" ]]; then
  jq -r "$filter" <<<"$json"
else
  printf '%s\n' "$json"
fi
EOF
  chmod +x "$bin/gh" "$bin/sudo"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  : >"$GH_LOG"
  : >"$GH_LOG.blobs"
  : >"$SUDO_LOG"
  step_run publish "Commit changes via API" >"$BATS_TEST_TMPDIR/step.sh"
  run env -C "$ws" PATH="$bin:$PATH" GH_LOG="$GH_LOG" SUDO_LOG="$SUDO_LOG" REPO=owner/fork BRANCH=main \
    GH_HEAD="${GH_HEAD:-$(git -C "$ws" rev-parse HEAD)}" GH_TREE_FAIL="${GH_TREE_FAIL:-}" \
    GH_TREE="${GH_TREE:-$(git -C "$ws" ls-tree -r HEAD | awk '{ print $4 " " $3 }')}" \
    RESULTS="$BATS_TEST_TMPDIR/results" GIT_TEST_ASSUME_DIFFERENT_OWNER=1 sh -e "$BATS_TEST_TMPDIR/step.sh"
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
  # The commit holds the new tree, with the checked out head as its parent
  grep -qxF "api repos/owner/fork/git/commits -f message=chore: update package versions [skip ci] -f tree=tree -f parents[]=$(git -C "$BATS_TEST_TMPDIR/ws" rev-parse HEAD) --jq .sha" "$GH_LOG"
  # Without force=false a push during the run would be overwritten
  grep -qx "api repos/owner/fork/git/refs/heads/main -f sha=commit -F force=false --method PATCH" "$GH_LOG"
  no_call "recursive"
}

# gh sends the body of the last --input and puts a -f field in the query
@test "check-updates: the commit step sends one body for the new tree" {
  make_commit_repo README.md="new table"
  run_commit_step
  [ "$status" -eq 0 ]
  grep -qx "inputs: 1" "$GH_LOG"
  no_call "base_tree="
  jq -e '.base_tree == "tree-of-head" and .tree == [{"path": "README.md", "mode": "100644", "type": "blob", "sha": "blob"}]' "$GH_LOG.tree"
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
  grep -qxF "{\"content\":\"$(printf 'new table\n' | base64 -w0)\",\"encoding\":\"base64\"}" "$GH_LOG.blobs"
  grep -qxF "{\"content\":\"$(printf 'current: 2.0\n' | base64 -w0)\",\"encoding\":\"base64\"}" "$GH_LOG.blobs"
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
    grep -qxF "{\"content\":\"$(printf 'new table\n' | base64 -w0)\",\"encoding\":\"base64\"}" "$GH_LOG.blobs"
  done
}

# Linux refuses one argument over 128 KiB, which a file of 98 KB passes in
# base64, so the body of a blob goes on stdin
@test "check-updates: the commit step sends a file of 200 KB as a blob" {
  local journal="$BATS_TEST_TMPDIR/results/stats/events.csv"
  make_commit_repo stats/events.csv=journal
  head -c 200000 /dev/zero | tr '\0' a >"$journal"
  run_commit_step
  [ "$status" -eq 0 ]
  grep -qx "api repos/owner/fork/git/blobs --jq .sha --method POST -H Content-Type: application/json --input -" "$GH_LOG"
  jq -r 'select(.encoding == "base64") | .content' "$GH_LOG.blobs" | base64 -d | cmp - "$journal"
  jq -e '[.tree[].path] == ["stats/events.csv"]' "$GH_LOG.tree"
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

@test "check-updates: the commit step adds the files of stats/ the checkout does not have yet" {
  make_commit_repo README.md="new table" stats/events.csv=journal stats/card.svg=card stats/card-dark.svg=dark \
    stats/other.svg=other
  run_commit_step
  [ "$status" -eq 0 ]
  jq -e '[.tree[].path] == ["README.md", "stats/events.csv", "stats/card.svg", "stats/card-dark.svg"]' "$GH_LOG.tree"
  grep -qF -- "-f message=chore: update package versions [skip ci] " "$GH_LOG"
}

@test "check-updates: a commit of stats/ alone is a commit of the statistics" {
  local ws="$BATS_TEST_TMPDIR/ws"
  make_commit_repo stats/card.svg="new card"
  mkdir "$ws/stats"
  echo card >"$ws/stats/card.svg"
  echo journal >"$ws/stats/events.csv"
  git -C "$ws" add stats
  git -C "$ws" -c user.name=t -c user.email=t@example.invalid commit -q -m stats
  cp "$ws/stats/events.csv" "$BATS_TEST_TMPDIR/results/stats/events.csv"
  run_commit_step
  [ "$status" -eq 0 ]
  jq -e '[.tree[].path] == ["stats/card.svg"]' "$GH_LOG.tree"
  grep -qF -- "-f message=chore: update package statistics [skip ci] " "$GH_LOG"
}

# make_commit_repo with the pairs from $3 on, and aurtomator.sh committed as
# $1 beside $2 in aurtomator/aurtomator.sh, the runner of the release
make_runner_repo() {
  local ws="$BATS_TEST_TMPDIR/ws"
  make_commit_repo "${@:3}"
  printf '%s\n' "$1" >"$ws/aurtomator.sh"
  git -C "$ws" add aurtomator.sh
  git -C "$ws" -c user.name=t -c user.email=t@example.invalid commit -q -m runner
  mkdir -p "$ws/aurtomator"
  printf '%s\n' "$2" >"$ws/aurtomator/aurtomator.sh"
}

@test "check-updates: the commit step writes the runner of the release over a runner that differs" {
  make_runner_repo "old runner" "new runner"
  run_commit_step
  [ "$status" -eq 0 ]
  jq -e '.tree == [{"path": "aurtomator.sh", "mode": "100755", "type": "blob", "sha": "blob"}]' "$GH_LOG.tree"
  [ "$(jq -r .content "$GH_LOG.blobs" | base64 -d)" = "new runner" ]
  grep -qF -- "-f message=chore: update aurtomator.sh [skip ci] " "$GH_LOG"
}

@test "check-updates: the commit step leaves a runner equal to the runner of the release" {
  make_runner_repo "same runner" "same runner"
  run_commit_step
  [ "$status" -eq 0 ]
  [ "$output" = "No changes to commit" ]
  no_commit
}

@test "check-updates: the commit step adds no runner to a repository without one" {
  make_commit_repo
  mkdir -p "$BATS_TEST_TMPDIR/ws/aurtomator"
  echo "new runner" >"$BATS_TEST_TMPDIR/ws/aurtomator/aurtomator.sh"
  run_commit_step
  [ "$status" -eq 0 ]
  [ "$output" = "No changes to commit" ]
  no_commit
}

@test "check-updates: the commit step leaves the runner when the checkout of aurtomator holds none" {
  make_runner_repo "old runner" "new runner"
  mv "$BATS_TEST_TMPDIR/ws/aurtomator/aurtomator.sh" "$BATS_TEST_TMPDIR/ws/aurtomator/gone"
  run_commit_step
  [ "$status" -eq 0 ]
  [ "$output" = "No changes to commit" ]
  no_commit
}

@test "check-updates: the commit step leaves a runner that is a link" {
  local ws="$BATS_TEST_TMPDIR/ws"
  make_commit_repo
  echo "old runner" >"$ws/runner.txt"
  ln -s runner.txt "$ws/aurtomator.sh"
  git -C "$ws" add runner.txt aurtomator.sh
  git -C "$ws" -c user.name=t -c user.email=t@example.invalid commit -q -m runner
  mkdir -p "$ws/aurtomator"
  echo "new runner" >"$ws/aurtomator/aurtomator.sh"
  run_commit_step
  [ "$status" -eq 0 ]
  [ "$output" = "No changes to commit" ]
  no_commit
}

@test "check-updates: the commit step names the runner beside the package versions" {
  make_runner_repo "old runner" "new runner" README.md="new table"
  run_commit_step
  [ "$status" -eq 0 ]
  jq -e '[.tree[] | [.path, .mode]] == [["README.md", "100644"], ["aurtomator.sh", "100755"]]' "$GH_LOG.tree"
  grep -qF -- "-f message=chore: update package versions and aurtomator.sh [skip ci] " "$GH_LOG"
}

@test "check-updates: a commit of stats/ and the runner names both" {
  local ws="$BATS_TEST_TMPDIR/ws"
  make_runner_repo "old runner" "new runner" stats/card.svg="new card"
  mkdir "$ws/stats"
  echo card >"$ws/stats/card.svg"
  echo journal >"$ws/stats/events.csv"
  git -C "$ws" add stats
  git -C "$ws" -c user.name=t -c user.email=t@example.invalid commit -q -m stats
  cp "$ws/stats/events.csv" "$BATS_TEST_TMPDIR/results/stats/events.csv"
  run_commit_step
  [ "$status" -eq 0 ]
  jq -e '[.tree[].path] == ["stats/card.svg", "aurtomator.sh"]' "$GH_LOG.tree"
  grep -qF -- "-f message=chore: update package statistics and aurtomator.sh [skip ci] " "$GH_LOG"
}

@test "check-updates: the commit step stops with a notice when the moved head changed aurtomator.sh" {
  make_runner_repo "old runner" "new runner"
  GH_HEAD=$MOVED GH_TREE="$(moved_tree aurtomator.sh)" run_commit_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::aurtomator.sh changed on main during the run, so the statuses of this run are not committed"* ]]
  no_commit
}

@test "check-updates: the commit step stops when a new file of stats/ appeared on the moved head" {
  make_commit_repo README.md="new table" stats/card.svg=card
  GH_HEAD=$MOVED GH_TREE="$(moved_tree packages/bar.yml)" run_commit_step
  [ "$status" -eq 0 ]
  jq -e '[.tree[].path] == ["README.md", "stats/card.svg"]' "$GH_LOG.tree"
  GH_HEAD=$MOVED GH_TREE="$(moved_tree packages/bar.yml && echo "stats/card.svg 0123456789012345678901234567890123456789")" \
    run_commit_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::stats/card.svg changed on main during the run"* ]]
  no_commit
}

@test "check-updates: the commit step leaves stats/ alone when it is a tracked link" {
  local ws="$BATS_TEST_TMPDIR/ws"
  make_commit_repo stats/card.svg=card
  ln -s packages "$ws/stats"
  git -C "$ws" add stats
  git -C "$ws" -c user.name=t -c user.email=t@example.invalid commit -q -m link
  run_commit_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes to commit"* ]]
}

# A path under a file would replace that file in the tree, and one under a
# link would write through the link
@test "check-updates: the commit step leaves out stats/ when stats is a file or a link to a directory" {
  local ws="$BATS_TEST_TMPDIR/ws"
  make_commit_repo README.md="new table" stats/events.csv=journal
  echo x >"$ws/stats"
  git -C "$ws" add stats
  git -C "$ws" -c user.name=t -c user.email=t@example.invalid commit -q -m file
  run_commit_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::stats/events.csv is left out of the commit, stats is a link or no directory"* ]]
  jq -e '[.tree[].path] == ["README.md"]' "$GH_LOG.tree"
  rm -rf "$ws" "$BATS_TEST_TMPDIR/results"
  make_commit_repo stats/card.svg="new card"
  mkdir "$ws/other"
  echo card >"$ws/other/card.svg"
  ln -s other "$ws/stats"
  git -C "$ws" add other stats
  git -C "$ws" -c user.name=t -c user.email=t@example.invalid commit -q -m link
  run_commit_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes to commit"* ]]
}

@test "check-updates: the close step runs before the issue step, and not after a failed step or publish" {
  run yq '[.jobs.issues.steps[].name] | join(",")' "$CHECK_UPDATES"
  [[ "$output" == *"Close resolved issues,Create issues" ]]
  run yq '.jobs.issues.steps[] | select(.name == "Close resolved issues") | .if' "$CHECK_UPDATES"
  [ "$output" = "needs.publish.result == 'success' || needs.publish.result == 'skipped'" ]
  run yq '.jobs.issues.steps[] | select(.name == "Create issues") | .if' "$CHECK_UPDATES"
  [ "$output" = "always() && steps.clean.outcome == 'success'" ]
}

# With publish skipped, the statuses come as builder of check wrote them
@test "check-updates: the issues job checks the statuses before any step reads them" {
  run yq -o=json -I=0 '.jobs.issues.steps[] | select(.name == "Check the statuses") | [.id, .if, .run]' "$CHECK_UPDATES"
  [ "$output" = "[\"clean\",null,\"bash -c 'source ./aurtomator/scripts/lib.sh && clean_statuses .status'\"]" ]
  [ "$(step_index issues "Check the statuses")" = "$(($(step_index issues "Download statuses of publish") + 1))" ]
  [ "$(step_index issues "Write the run summary")" = "$(($(step_index issues "Check the statuses") + 1))" ]
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

# The page of the run titles the run summary with the name of the job
@test "check-updates: the issues job is named status" {
  run yq '.jobs.issues.name' "$CHECK_UPDATES"
  [ "$output" = "status" ]
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
  local upload="\${{ steps.decide.outputs.packages == 'true' && 'error' || 'ignore' }}"
  run yq -o=json -I=0 '[.jobs.issues.steps[] | select(.uses | test("^actions/download-artifact@")) | [.with["artifact-ids"], .with.path, .if]]' "$CHECK_UPDATES"
  [ "$output" = "[[\"$(id_of check checked)\",\".status\",\"needs.publish.result == 'skipped' && needs.check.outputs.checked-id != ''\"],[\"$(id_of publish published)\",\".status\",\"needs.publish.result != 'skipped'\"]]" ]
  run yq -o=json -I=0 '.jobs.publish.steps[] | select(.with.name == "published") | [.with.path, .if, .with["if-no-files-found"]]' "$CHECK_UPDATES"
  [ "$output" = '["statuses/","always()","error"]' ]
  run yq '.jobs.publish.steps[] | select(.name == "Hand over") | .if' "$CHECK_UPDATES"
  [ "$output" = "always() && steps.stop.outcome == 'success'" ]
  run yq -o=json -I=0 '.jobs.check.steps[] | select(.name == "Upload statuses") | [.with.name, .with.path, .with["if-no-files-found"]]' "$CHECK_UPDATES"
  [ "$output" = "[\"checked\",\"statuses/\",\"$upload\"]" ]
}

# Runs step $1 of the issues job in a workspace without .status/, as after a
# check that uploaded no status, with a gh that logs its calls
run_bare_issues_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$ws" "$bin"
  ln -sfn "$BATS_TEST_DIRNAME/.." "$ws/aurtomator"
  printf '#!/bin/sh\necho "$*" >>"$GH_LOG"\n' >"$bin/gh"
  chmod +x "$bin/gh"
  step_run issues "$1" >"$BATS_TEST_TMPDIR/step.sh"
  (cd "$ws" && PATH="$bin:$PATH" GH_LOG="$BATS_TEST_TMPDIR/gh.log" GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary" \
    sh -e "$BATS_TEST_TMPDIR/step.sh")
}

@test "check-updates: the issues job runs on without statuses" {
  local step
  for step in "Write the run summary" "Close resolved issues" "Create issues"; do
    run run_bare_issues_step "$step"
    [ "$status" -eq 0 ]
  done
  [ ! -s "$BATS_TEST_TMPDIR/summary" ]
  [ ! -e "$BATS_TEST_TMPDIR/gh.log" ]
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
  GH_OPEN=$'12 ❌ foo: update failed\n13 ❌ bar: update failed\n14 ❌ baz: update failed\n15 ❌ qux: update failed\n16 ❌ quux: update failed' \
    run_close_step foo=up_to_date bar="updated: 2.0.0" baz="downgrade: 1.0.0" qux="rebuilt: 1.0.0" quux="arch_added: 1.0.0 aarch64"
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "5" ]
}

@test "check-updates: keeps the update issue of a package that has not reached the AUR" {
  GH_OPEN=$'12 ❌ foo: update failed\n13 ❌ bar: update failed\n14 ❌ baz: update failed' \
    run_close_step foo="new_version: 2.0.0" bar="downgrade_skipped: 1.0.0" baz="update_failed: boom"
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: an update in its cooldown closes the check issue and keeps the others" {
  GH_OPEN=$'12 ❌ foo: check failed\n13 ❌ bar: update failed\n14 ✋ baz: update held' \
    run_close_step foo="cooldown: 2026-11-12" bar="cooldown: 2026-11-12" baz="cooldown: 2026-11-12"
  [ "$status" -eq 0 ]
  grep -qx 'issue close 12 --comment comment' "$GH_LOG"
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "1" ]
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
  GH_OPEN=$'12 ✋ foo: update held\n13 ✋ bar: update held\n14 ✋ baz: update held\n15 ✋ qux: update held\n16 ✋ quux: update held' \
    run_close_step foo=up_to_date bar="updated: 2.0.0" baz="downgrade: 1.0.0" qux="rebuilt: 1.0.0" quux="arch_added: 1.0.0 aarch64"
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "5" ]
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

@test "check-updates: closes the issue of a host once fewer than 5 of its packages failed to check" {
  local pairs
  mapfile -t pairs < <(host_failures 4 api.github.com a && host_failures 5 apixgithub.com x && host_failures 5 cdn.gitlab.com y)
  GH_OPEN=$'21 ❌ api.github.com: 6 packages failed to check\n22 ❌ apixgithub.com: 5 packages failed to check\n23 ❌ gitlab.com: 7 packages failed to check\n24 ❌ gitlab.com: many packages failed to check' \
    run_close_step "${pairs[@]}"
  [ "$status" -eq 0 ]
  grep -qx 'issue close 21 --comment Fewer than 5 packages of `api.github.com` failed to check in https://example.invalid/run.' "$GH_LOG"
  grep -qx 'issue close 23 --comment Fewer than 5 packages of `gitlab.com` failed to check in https://example.invalid/run.' "$GH_LOG"
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "2" ]
}

@test "check-updates: closes the arch issue of a package that _without of publish lists no more" {
  GH_OPEN=$'12 ⚠️ foo: 28+23 without aarch64\n13 ⚠️ bar: 1.0 without riscv64' \
    run_close_step foo=up_to_date bar=up_to_date _without=$'bar\t1.1\triscv64'
  [ "$status" -eq 0 ]
  grep -qx 'issue close 12 --comment comment' "$GH_LOG"
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "1" ]
  [ "$(cat "$BODY_LOG")" = "arch_close_comment foo https://example.invalid/run" ]
}

@test "check-updates: keeps the arch issues in a run without the _without of publish" {
  GH_OPEN=$'12 ⚠️ foo: 28+23 without aarch64' run_close_step foo=up_to_date
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "0" ]
  run grep -c -- '--label arch-missing' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: closes no arch issue whose title names no package" {
  GH_OPEN=$'12 ⚠️ foo bar: 1.0 without aarch64\n13 ⚠️ `x`: 1.0 without aarch64\n14 ⚠️ no colon' run_close_step _without=
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
  [[ "$output" == *"Prepare updates,Stop builder,Hand over,Name the attempt,Upload handoff"* ]]
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
  run yq '.jobs.publish.steps[] | select(.name == "Download statuses") | .with["artifact-ids"] + " " + .with.path' "$CHECK_UPDATES"
  [ "$output" = "$(id_of check checked) .status" ]
  run yq '.jobs.publish.steps[] | select(.name == "Download verified handoff") | .if' "$CHECK_UPDATES"
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
  (cd "$BATS_TEST_TMPDIR/ws" && GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" sh -e "$BATS_TEST_TMPDIR/step.sh")
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
  (cd "$ws" && GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary" sh -e "$BATS_TEST_TMPDIR/step.sh")
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
# ones (an empty $GH_JOBS lists no failed job), applies the filter of the
# step to the jobs in $GH_JOBS_JSON when it is set, or fails that when
# $GH_JOBS_FAIL is set, fails the list of issues when $GH_FAIL is set and
# logs every call to $GH_LOG.
run_notify_step() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
cmd="$1 $2" filter=""
while (($#)); do
  [[ "$1" != --jq ]] || filter=$2
  shift
done
# gh answers with the JSON of the API and applies --jq to it
case "$cmd" in
  "api repos/owner/fork") json="{\"has_issues\": ${GH_HAS_ISSUES:-true}}" ;;
  "api repos/owner/fork/actions/runs/7/jobs")
    [[ -z "${GH_JOBS_FAIL:-}" ]] || exit 1
    if [[ -z "${GH_JOBS_JSON:-}" ]]; then
      echo "$GH_JOBS"
      exit 0
    fi
    json=$GH_JOBS_JSON
    ;;
  "issue list")
    [[ -z "${GH_FAIL:-}" ]] || exit 1
    json=$(jq -Rn '[inputs | select(length > 0) | {title: .}]' <<<"${GH_TITLES:-}")
    ;;
  *) exit 0 ;;
esac
jq -r "$filter" <<<"$json"
EOF
  chmod +x "$bin/gh"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : >"$GH_LOG"
  yq '.jobs.notify.steps[0].run' "$NOTIFY" >"$BATS_TEST_TMPDIR/step.sh"
  run env PATH="$bin:$PATH" GH_LOG="$GH_LOG" GH_TITLES="${GH_TITLES:-}" GH_FAIL="${GH_FAIL:-}" \
    GH_HAS_ISSUES="${GH_HAS_ISSUES:-}" GH_JOBS="${GH_JOBS:-}" GH_JOBS_FAIL="${GH_JOBS_FAIL:-}" GH_JOBS_JSON="${GH_JOBS_JSON:-}" \
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

# A job that runs into timeout-minutes concludes timed_out
@test "notify-failure: names the jobs that failed or timed out" {
  GH_JOBS_JSON='{"jobs":[{"name":"check","conclusion":"failure"},{"name":"verify","conclusion":"timed_out"},{"name":"publish","conclusion":"skipped"},{"name":"status","conclusion":"success"}]}' run_notify_step
  [ "$status" -eq 0 ]
  grep -q 'failed in check, verify' "$GH_LOG"
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
  GH_JOBS=check GH_TITLES="❌ Check AUR Package Updates failed" run_notify_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue already open, skipping"* ]]
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

PROBE="$GITHUB_DIR/workflows/runner-probe.yml"

@test "runner-probe: runs only by hand, reads the repository only and has time limits" {
  run yq -o=json -I=0 '.on' "$PROBE"
  [ "$status" -eq 0 ]
  [ "$output" = '{"workflow_dispatch":null}' ]
  run yq -o=json -I=0 '.permissions' "$PROBE"
  [ "$output" = '{"contents":"read"}' ]
  run yq -o=json -I=0 '.jobs | keys' "$PROBE"
  [ "$output" = '["runner","image","container"]' ]
  run yq '[.jobs[] | .["timeout-minutes"] > 0] | all' "$PROBE"
  [ "$output" = "true" ]
}

@test "runner-probe: adds builder as check-updates does" {
  run yq -o=json -I=0 '[.jobs.container.steps[].name]' "$PROBE"
  [ "$status" -eq 0 ]
  [ "$output" = '["Install dependencies","Add builder","The mounts","What builder reaches"]' ]
  run yq '.jobs.container.steps[] | select(.name == "Add builder") | .run' "$PROBE"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" = "$(step_run check "Add builder")" ]
}

# The paths that builder may not write, in the order the probe tests them,
# with the file commands under /fc
PROBE_PATHS=(/fc/set_env /fc/add_path /fc/set_output /fc/step_summary /__w/_temp /__w/repo/repo /__w /__w/_actions /__e)

# Runs the step What builder reaches. sudo logs each test it runs as builder
# to $CALLS/sudo and passes those in $REACH, given as "<flag>:<path>"
# separated by spaces. As builder, env prints the names in $BUILDER_ENV.
run_probe_reach_step() {
  local bin="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$bin" "$CALLS"
  cat >"$bin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "-u builder" ]] || exit 97
shift 2
case "$1" in
  test)
    echo "$*" >>"$CALLS/sudo"
    [[ " $REACH " == *" $2:$3 "* ]]
    ;;
  env) tr ' ' '\n' <<<"$BUILDER_ENV" | sed 's/$/=x/' ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$bin/sudo"
  yq '.jobs.container.steps[] | select(.name == "What builder reaches") | .run' "$PROBE" >"$BATS_TEST_TMPDIR/step.sh"
  run env PATH="$bin:$PATH" CALLS="$CALLS" REACH="${REACH:-}" BUILDER_ENV="${BUILDER_ENV:-HOME PATH}" \
    GITHUB_ENV=/fc/set_env GITHUB_PATH=/fc/add_path GITHUB_OUTPUT=/fc/set_output \
    GITHUB_STEP_SUMMARY=/fc/step_summary RUNNER_TEMP=/__w/_temp GITHUB_WORKSPACE=/__w/repo/repo \
    sh -e "$BATS_TEST_TMPDIR/step.sh"
}

@test "runner-probe: passes when builder reaches nothing of the runner" {
  local expected=() path
  run_probe_reach_step
  [ "$status" -eq 0 ]
  [[ "$output" != *"::error::"* ]]
  [[ "$output" == *"The variables of builder: HOME PATH"* ]]
  for path in "${PROBE_PATHS[@]}"; do
    expected+=("test -w $path")
  done
  expected+=("test -r /var/run/docker.sock" "test -w /var/run/docker.sock")
  [ "$(cat "$CALLS/sudo")" = "$(printf '%s\n' "${expected[@]}")" ]
}

@test "runner-probe: fails when builder can write a file of the runner, after every test" {
  local path
  for path in "${PROBE_PATHS[@]}"; do
    echo "$path"
    REACH="-w:$path" run_probe_reach_step
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::builder passes test -w $path"* ]]
    [ "$(grep -c '^builder: test ' <<<"$output")" -eq 11 ]
  done
}

@test "runner-probe: fails when builder can use the Docker socket" {
  local flag
  for flag in -r -w; do
    echo "$flag"
    REACH="$flag:/var/run/docker.sock" run_probe_reach_step
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::builder passes test $flag /var/run/docker.sock"* ]]
  done
}

@test "runner-probe: fails when sudo passes a variable of the runner to builder" {
  local name
  for name in GITHUB_TOKEN ACTIONS_RUNTIME_TOKEN RUNNER_TEMP; do
    echo "$name"
    BUILDER_ENV="HOME $name PATH" run_probe_reach_step
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::sudo passes $name to builder"* ]]
  done
}
