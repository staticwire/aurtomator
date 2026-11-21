#!/usr/bin/env bats

GITHUB_DIR="$BATS_TEST_DIRNAME/../.github"
CI_IMAGE="$BATS_TEST_DIRNAME/../ci-image/Dockerfile"

# git reads and writes no config of the user running the tests, nor of the system
setup() {
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
}

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

# Prints the permissions of workflow $1 and of each of its jobs, one line each
permission_lines() {
  printf '%s %s\n' "${1##*/}" "$(yq -o=json -I=0 '.permissions' "$1")"
  yq -o=json -I=0 '.jobs | to_entries | .[] | [.key, .value.permissions]' "$1" | sed "s|^|${1##*/} |"
}

# Jobs without permissions take those of their workflow, and steps of builder run in such jobs
@test "workflows: hold the permissions of this table" {
  local workflow
  for workflow in "$GITHUB_DIR"/workflows/*.yml; do
    permission_lines "$workflow"
  done >"$BATS_TEST_TMPDIR/actual"
  printf '%s\n' \
    'check-updates.yml {"contents":"read"}' \
    'check-updates.yml ["image",null]' \
    'check-updates.yml ["check",null]' \
    'check-updates.yml ["prepare",null]' \
    'check-updates.yml ["verify",null]' \
    'check-updates.yml ["publish",{"contents":"write"}]' \
    'check-updates.yml ["issues",{"contents":"read","issues":"write"}]' \
    'ci.yml {"contents":"read"}' \
    'ci.yml ["image",null]' \
    'ci.yml ["lint",null]' \
    'ci.yml ["test",null]' \
    'ci.yml ["validate",{"contents":"read"}]' \
    'ci.yml ["pipeline",{"contents":"write","issues":"write"}]' \
    'ci.yml ["dependency-review",{"contents":"read"}]' \
    'ci.yml ["vulnerability-issue",{"issues":"write"}]' \
    'ci.yml ["merge-image",{"contents":"write","pull-requests":"write","actions":"write"}]' \
    'ci.yml ["ci-ok",{}]' \
    'codeql.yml {"contents":"read"}' \
    'codeql.yml ["analyze",{"contents":"read","security-events":"write"}]' \
    'docs.yml {"contents":"read"}' \
    'docs.yml ["build",null]' \
    'docs.yml ["deploy",{"pages":"write","id-token":"write"}]' \
    'notify-failure.yml {"actions":"read","issues":"write"}' \
    'notify-failure.yml ["notify",null]' \
    'release-please.yml {"contents":"read"}' \
    'release-please.yml ["release-please",{"contents":"read"}]' \
    'release-please.yml ["sign",{"contents":"write","id-token":"write","attestations":"write"}]' \
    'validate.yml {"contents":"read"}' \
    'validate.yml ["image",null]' \
    'validate.yml ["packages",null]' >"$BATS_TEST_TMPDIR/expected"
  diff "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/actual"
}

# Prints workflow $1, job, step and secret for each secrets.<name> in a step, then the
# count of secrets.<name> in the whole file
secret_lines() {
  yq -r '.jobs | to_entries | .[] | .key as $job | .value.steps[] | (.name // .id // .uses) as $step |
    .. | select(tag == "!!str") | match("secrets\.([A-Za-z0-9_]+)"; "g") |
    $job + "/" + $step + " " + .captures[0].string' "$1" | sed "s|^|${1##*/} |"
  printf '%s %s\n' "${1##*/}" "$(yq '[.. | select(tag == "!!str") | match("secrets\.([A-Za-z0-9_]+)"; "g")] | length' "$1")"
}

# The steps of builder see no secret, and each step of publish sees only the secrets it uses
@test "workflows: name each secret in the steps of this table alone" {
  local workflow
  for workflow in "$GITHUB_DIR"/workflows/*.yml; do
    secret_lines "$workflow"
  done >"$BATS_TEST_TMPDIR/actual"
  printf '%s\n' \
    'check-updates.yml publish/Setup workspace AUR_GIT_NAME' \
    'check-updates.yml publish/Setup workspace AUR_GIT_EMAIL' \
    'check-updates.yml publish/Setup AUR SSH AUR_SSH_KEY' \
    'check-updates.yml publish/Setup GPG GPG_SIGNING_KEY' \
    'check-updates.yml publish/Publish updates AUR_GIT_NAME' \
    'check-updates.yml publish/Publish updates AUR_GIT_EMAIL' \
    'check-updates.yml 6' \
    'ci.yml merge-image/Merge image update CI_IMAGE_AUTO_MERGE' \
    'ci.yml 1' \
    'codeql.yml 0' \
    'docs.yml 0' \
    'notify-failure.yml 0' \
    'release-please.yml release-please/app-token RELEASE_APP_PRIVATE_KEY' \
    'release-please.yml 1' \
    'validate.yml 0' >"$BATS_TEST_TMPDIR/expected"
  diff "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/actual"
  for workflow in "$GITHUB_DIR"/actions/*/action.yml; do
    run yq '[.. | select(tag == "!!str") | match("secrets\.")] | length' "$workflow"
    [ "$output" = 0 ]
  done
}

# pull_request_target gives pull requests of forks a write token and the secrets, and its
# github.ref names the base branch, so the deploy job of docs.yml would run for a pull request
@test "workflows: run on the triggers of this table alone" {
  local workflow
  for workflow in "$GITHUB_DIR"/workflows/*.yml; do
    printf '%s %s\n' "${workflow##*/}" "$(yq -o=json -I=0 '.on' "$workflow")"
  done >"$BATS_TEST_TMPDIR/actual"
  printf '%s\n' \
    'check-updates.yml {"workflow_call":{"secrets":{"AUR_SSH_KEY":{"required":false},"GPG_SIGNING_KEY":{"required":false},"AUR_GIT_NAME":{"required":false},"AUR_GIT_EMAIL":{"required":false}}}}' \
    'ci.yml {"push":{"branches":["main"]},"pull_request":{"branches":["main"]},"workflow_dispatch":null}' \
    'codeql.yml {"push":{"branches":["main"]},"pull_request":{"branches":["main"]},"schedule":[{"cron":"41 3 * * 1"}]}' \
    'docs.yml {"push":{"branches":["main"],"paths":["site/**","assets/**","VERSION",".github/workflows/docs.yml"]},"pull_request":{"paths":["site/**","assets/**","VERSION",".github/workflows/docs.yml"]},"workflow_dispatch":null}' \
    'notify-failure.yml {"workflow_call":null}' \
    'release-please.yml {"push":{"branches":["main"]},"workflow_dispatch":null}' \
    'validate.yml {"workflow_call":null}' >"$BATS_TEST_TMPDIR/expected"
  diff "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/actual"
}

# Pinned actions, the base image, the Python packages and the gems of the CI image, and the
# packages of the site move only through the pull requests of Dependabot
@test "dependabot: watches the actions, the CI image, its Python packages and gems, and the site" {
  run yq -o=json -I=0 '[.updates[] | [.["package-ecosystem"], .directory]]' "$GITHUB_DIR/dependabot.yml"
  [ "$status" -eq 0 ]
  [ "$output" = '[["github-actions","/"],["docker","/ci-image"],["uv","/ci-image"],["bundler","/ci-image"],["npm","/site"]]' ]
}

# merge-image merges the updates of ci-image/, and a week gives a hostile release time to be
# found and pulled before it reaches the CI
@test "dependabot: proposes versions of ci-image/ a week after their release, the rest after the default" {
  run yq -o=json -I=0 '[.updates[] | [.["package-ecosystem"], .cooldown]]' "$GITHUB_DIR/dependabot.yml"
  [ "$status" -eq 0 ]
  [ "$output" = '[["github-actions",null],["docker",{"default-days":7}],["uv",{"default-days":7}],["bundler",{"default-days":7}],["npm",null]]' ]
}

# The token a checkout leaves in .git/config would reach builder, which owns the workspace
@test "workflows: no checkout keeps its credentials" {
  local workflow count=0
  for workflow in "$GITHUB_DIR"/workflows/*.yml; do
    echo "$workflow"
    run yq '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@")) | select(.with["persist-credentials"] != false)] | length' "$workflow"
    [ "$output" = 0 ]
    run yq '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@"))] | length' "$workflow"
    count=$((count + output))
  done
  [ "$count" -gt 10 ]
}

# Pull requests build the site, and main alone deploys it, in the environment of GitHub Pages
@test "docs: deploys the site from main alone" {
  local docs="$GITHUB_DIR/workflows/docs.yml"
  run yq '.jobs.deploy.if' "$docs"
  [ "$output" = "github.ref == 'refs/heads/main'" ]
  run yq -o=json -I=0 '[.jobs.deploy.needs, .jobs.deploy.environment.name]' "$docs"
  [ "$output" = '["build","github-pages"]' ]
}

# withastro/action runs npm install, which resolves new versions when the lock lags package.json
@test "docs: checks the lock file of the site before the build" {
  local docs="$GITHUB_DIR/workflows/docs.yml"
  run yq -o=json -I=0 '.jobs.build.steps[] | select(.name == "Check the lock file") | [.["working-directory"], .run]' "$docs"
  [ "$output" = '["site","npm ci --dry-run --ignore-scripts"]' ]
  [ "$(step_index_in "$docs" build "Check the lock file")" -lt "$(step_index_in "$docs" build "Build the site")" ]
  [ "$(step_index_in "$docs" build "Check the lock file")" -gt "$(step_index_in "$docs" build Checkout)" ]
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
  run grep -c '^FROM ' "$CI_IMAGE"
  [ "$output" = "1" ]
  run grep -Ex 'FROM archlinux:base-devel@sha256:[0-9a-f]{64}' "$CI_IMAGE"
  [ "$status" -eq 0 ]
}

# The image job is the same in every workflow, so the step of ci.yml stands
# for all of them
@test "ci-image: the image job takes only a digest pin of archlinux:base-devel" {
  local step="$BATS_TEST_TMPDIR/read-image.sh" work="$BATS_TEST_TMPDIR/work" digest from
  digest=$(printf 'a%.0s' {1..64})
  yq '.jobs.image.steps[] | select(.name == "Read image") | .run' "$GITHUB_DIR/workflows/ci.yml" >"$step"
  mkdir -p "$work/ci-image"
  for from in archlinux:base-devel "archlinux:base-devel@sha256:${digest:1}" "archlinux:base-devel@sha256:${digest}a" \
    "archlinux:base-devel@sha256:${digest^^}" "archlinux:base@sha256:$digest" "evil/archlinux:base-devel@sha256:$digest"; do
    echo "FROM $from" >"$work/ci-image/Dockerfile"
    : >"$work/out"
    run env -C "$work" GITHUB_OUTPUT="$work/out" bash -e "$step"
    echo "$from: $output"
    [ "$status" -eq 1 ]
    [ "$output" = "::error::ci-image/Dockerfile must pin archlinux:base-devel by digest" ]
    [ ! -s "$work/out" ]
  done
  printf '%s\n' "# FROM archlinux:latest" "FROM archlinux:base-devel@sha256:$digest" >"$work/ci-image/Dockerfile"
  run env -C "$work" GITHUB_OUTPUT="$work/out" bash -e "$step"
  [ "$status" -eq 0 ]
  [ "$(cat "$work/out")" = "ref=archlinux:base-devel@sha256:$digest" ]
}

@test "ci-image: Dependabot updates the Dockerfile" {
  run yq '.updates[] | select(.["package-ecosystem"] == "docker") | .directory' "$GITHUB_DIR/dependabot.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "/ci-image" ]
}

# codecov-action downloads the newest CLI unless it gets one, so the test job installs the CLI
# that requirements.txt pins by hash, and Dependabot moves the pins
@test "ci: Codecov uploads with the CLI of ci-image/requirements.txt, which Dependabot updates" {
  local ci="$GITHUB_DIR/workflows/ci.yml"
  run yq '.updates[] | select(.["package-ecosystem"] == "uv") | .directory' "$GITHUB_DIR/dependabot.yml"
  [ "$output" = "/ci-image" ]
  run yq '.jobs.test.steps[] | select(.name == "Install the Codecov CLI") | .run' "$ci"
  [[ "$output" == *"/opt/codecov/bin/pip install --require-hashes --no-deps -r ci-image/requirements.txt"* ]]
  run yq '.jobs.test.steps[] | select(.name == "Upload coverage to Codecov") | .with.binary' "$ci"
  [ "$output" = "/opt/codecov/bin/codecovcli" ]
  grep -q '^codecov-cli==' "$GITHUB_DIR/../ci-image/requirements.txt"
  grep -q -- '--hash=sha256:' "$GITHUB_DIR/../ci-image/requirements.txt"
}

# The search of the CLI takes tests/coverage.bats for a report, by its name
@test "ci: Codecov uploads coverage/coverage.xml alone" {
  run yq -o=json -I=0 '.jobs.test.steps[] | select(.name == "Upload coverage to Codecov") | .with | [.files, .disable_search]' \
    "$GITHUB_DIR/workflows/ci.yml"
  [ "$output" = '["coverage/coverage.xml",true]' ]
}

# Default setup of code scanning skips the pull requests of Dependabot, which move the pins of
# actions, so the workflow of advanced setup analyzes every pull request
@test "codeql: analyzes the workflows on pull requests, pushes to main and once a week" {
  local codeql="$GITHUB_DIR/workflows/codeql.yml"
  run yq -o=json -I=0 '.on | keys' "$codeql"
  [ "$output" = '["push","pull_request","schedule"]' ]
  run yq '.on.push.branches[0] + " " + .on.pull_request.branches[0]' "$codeql"
  [ "$output" = "main main" ]
  run yq -o=json -I=0 '.permissions' "$codeql"
  [ "$output" = '{"contents":"read"}' ]
  run yq -o=json -I=0 '.jobs.analyze.permissions' "$codeql"
  [ "$output" = '{"contents":"read","security-events":"write"}' ]
  run yq '.jobs.analyze.steps[] | select(.uses == "github/codeql-action/init@*") | .with.languages + " " + .with["build-mode"] + " " + .with.queries' "$codeql"
  [ "$output" = "actions none security-extended" ]
  run yq '.jobs.analyze.steps[] | select(.uses == "github/codeql-action/analyze@*") | .with.category' "$codeql"
  [ "$output" = "/language:actions" ]
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

# ci.yml checks out its own commit and a called workflow the pinned one, so the comparison
# leaves out the pin check and the repository and ref of the checkout
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

# Pinned images age, and old keyrings reject packages signed with a
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

# Tags and branches move, so a workflow pins each action by its commit and names the version
@test "workflows: pin every action by a full commit SHA with its version" {
  local file line bad=0
  local own='^ +(- )?uses: \./'
  local pinned='^ +(- )?uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$'
  for file in "$GITHUB_DIR"/workflows/*.yml "$GITHUB_DIR"/actions/*/action.yml; do
    while IFS= read -r line; do
      [[ "$line" =~ $own || "$line" =~ $pinned ]] && continue
      echo "${file##*/}: $line"
      bad=$((bad + 1))
    done < <(grep -E '^ +(- )?uses:' "$file")
  done
  [ "$bad" -eq 0 ]
}

@test "workflows: actionlint ignores only the two job.workflow properties and the queue of concurrency" {
  local config="$GITHUB_DIR/actionlint.yaml" release=.github/workflows/release-please.yml expected key keys
  run yq '. | keys | join(" ")' "$config"
  [ "$status" -eq 0 ]
  [ "$output" = "paths" ]
  expected=$(cd "$GITHUB_DIR/.." && {
    grep -lF '${{ job.workflow_' .github/workflows/*.yml
    echo "$release"
  } | sort)
  [ -n "$expected" ]
  run yq '.paths | keys | .[]' "$config"
  [ "$status" -eq 0 ]
  [ "$(sort <<<"$output")" = "$expected" ]
  keys=("${lines[@]}")
  for key in "${keys[@]}"; do
    [[ "$key" != "$release" ]] || continue
    echo "$key"
    run yq -o=json -I=0 ".paths[\"$key\"]" "$config"
    [ "$status" -eq 0 ]
    [ "$output" = '{"ignore":["property \"workflow_(repository|sha)\" is not defined in object type"]}' ]
  done
  run yq -o=json -I=0 ".paths[\"$release\"]" "$config"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ignore":["unexpected key \"queue\" for \"concurrency\" section"]}' ]
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

# Without .shellcheckrc, shellcheck reads a source directive relative to the current directory,
# and -S warning hides the SC1091 of a file it cannot follow
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
  [[ "$output" == "bundle exec bashcov -- tests/helpers/bashcov-bats.sh tests/ --recursive"* ]]
  [[ "$output" != *"|| true"* ]]
}

# The lock holds every gem at its version with its checksum, and bundler stops on a gem
# whose checksum differs; the bundler of the image runs, whatever version the lock names
@test "ci: the test job installs the gems of ci-image/Gemfile.lock as the lock holds them" {
  local ci="$GITHUB_DIR/workflows/ci.yml" lock="$GITHUB_DIR/../ci-image/Gemfile.lock" gem
  run yq -o=json -I=0 '.jobs.test.env' "$ci"
  [ "$output" = '{"BUNDLE_GEMFILE":"ci-image/Gemfile","BUNDLE_FROZEN":"true","BUNDLE_PATH":"/opt/gems","BUNDLE_VERSION":"system"}' ]
  run yq '[.jobs.test.steps[] | select(has("run")) | .run | select(test("gem install"))] | length' "$ci"
  [ "$output" = 0 ]
  run yq -r '.jobs.test.steps[] | select(.name == "Install the coverage tools") | .run' "$ci"
  [ "$output" = "bundle install" ]
  [ "$(step_index_in "$ci" test "Install the coverage tools")" -gt "$(step_index_in "$ci" test actions/checkout)" ]
  run yq -r '.jobs.test.steps[] | select(.name == "Install dependencies") | .run' "$ci"
  [[ "$output" == *" ruby ruby-erb ruby-bundler"* ]]
  run sed -n '/^  specs:$/,/^$/s/^    \([^ ]*\) (\(.*\))$/\1 \2/p' "$lock"
  [ "${#lines[@]}" -ge 4 ]
  for gem in "${lines[@]}"; do
    grep -qE "^  ${gem% *} \\(${gem#* }\\) sha256=[0-9a-f]{64}$" "$lock" || {
      echo "no checksum: $gem"
      return 1
    }
  done
}

# Prints the index of the step of job $2 in workflow $1 that is named $3 or uses action $3
step_index_in() {
  yq ".jobs.$2.steps | to_entries | map(select(.value.name == \"$3\" or (.value.uses // \"\" | sub(\"@.*\"; \"\")) == \"$3\")) | .[0].key" "$1"
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

# The permissions of the job raise the read-only token of a Dependabot run to write
@test "ci: the pipeline job calls check-updates for pushes and same-repository pull requests not opened by Dependabot" {
  local ci="$GITHUB_DIR/workflows/ci.yml"
  run yq '.jobs.pipeline.uses' "$ci"
  [ "$status" -eq 0 ]
  [ "$output" = "./.github/workflows/check-updates.yml" ]
  run yq '.jobs.pipeline.if' "$ci"
  [ "$status" -eq 0 ]
  [ "$output" = "github.event_name != 'pull_request' || (github.event.pull_request.head.repo.full_name == github.repository && github.event.pull_request.user.login != 'dependabot[bot]')" ]
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

# Dependabot pull requests skip pipeline, which ci-ok counts as passed and merge-image would not
@test "merge-image: runs only after lint, test, validate, the dependency review and ci-ok" {
  run yq '.jobs["merge-image"].needs | sort | join(" ")' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "ci-ok dependency-review lint test validate" ]
  run yq '.jobs["ci-ok"].needs | contains(["pipeline"])' "$GITHUB_DIR/workflows/ci.yml"
  [ "$output" = "true" ]
}

# A skip reaches every later job of the chain unless its if holds a status function, and
# pipeline before ci-ok skips on Dependabot pull requests
@test "merge-image: runs after the skipped pipeline once each job it needs passed" {
  local ci="$GITHUB_DIR/workflows/ci.yml" condition job needs
  condition=$(yq '.jobs["merge-image"].if' "$ci")
  [[ "$condition" == '!cancelled() && '* ]]
  needs=$(yq '.jobs["merge-image"].needs[]' "$ci")
  [ -n "$needs" ]
  for job in $needs; do
    echo "$job"
    [[ "$condition" == *"needs.$job.result == 'success'"* ]]
  done
}

@test "merge-image: runs only for pull requests that Dependabot opened and pushed" {
  run yq '.jobs["merge-image"].if' "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"github.event_name == 'pull_request'"* ]]
  [[ "$output" == *"github.actor == 'dependabot[bot]'"* ]]
  [[ "$output" == *"github.event.pull_request.user.login == 'dependabot[bot]'"* ]]
  [[ "$output" != *"||"* ]]
  [[ "$output" != *"vars."* ]]
}

# Runs that Dependabot starts read Dependabot secrets and no Actions secrets
@test "merge-image: takes the switch from the secret CI_IMAGE_AUTO_MERGE" {
  run yq '.jobs["merge-image"].steps[] | select(.name == "Merge image update") | .env.AUTO_MERGE' \
    "$GITHUB_DIR/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [ "$output" = '${{ secrets.CI_IMAGE_AUTO_MERGE }}' ]
}

@test "merge-image: leaves the pull request open unless the switch is true" {
  local value
  for value in '' false yes; do
    echo "[$value]"
    AUTO_MERGE="$value" GH_FILES="ci-image/Dockerfile" run_merge_step
    [ "$status" -eq 0 ]
    [[ "$output" == *"::notice::"* ]]
    [ ! -s "$GH_LOG" ]
  done
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
[[ "$1 $2" != "pr merge" ]] || exit "${GH_MERGE_RC:-0}"
EOF
  chmod +x "$bin/gh"
  yq '.jobs["merge-image"].steps[] | select(.name == "Merge image update") | .run' \
    "$GITHUB_DIR/workflows/ci.yml" >"$BATS_TEST_TMPDIR/step.sh"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : >"$GH_LOG"
  run env PATH="$bin:$PATH" GH_LOG="$GH_LOG" REPO=owner/repo PR=12 HEAD_SHA=abc123 \
    AUTO_MERGE="${AUTO_MERGE-true}" GH_MERGE_RC="${GH_MERGE_RC:-0}" bash -e "$BATS_TEST_TMPDIR/step.sh"
}

# Merges with the workflow token start no workflow, so the job starts CI and release-please on
# main by dispatch
@test "merge-image: merges the tested head when only files of ci-image/ changed, then starts ci.yml and release-please.yml on main" {
  local files
  for files in ci-image/Dockerfile $'ci-image/Gemfile\nci-image/Gemfile.lock' ci-image/Gemfile.lock \
    $'ci-image/requirements.in\nci-image/requirements.txt' ci-image/requirements.txt; do
    echo "$files"
    GH_FILES="$files" run_merge_step
    [ "$status" -eq 0 ]
    run cat "$GH_LOG"
    [ "$output" = "$(printf '%s\n' 'api repos/owner/repo/pulls/12/files --paginate --jq .[].filename' \
      'pr merge 12 -R owner/repo --squash --match-head-commit abc123' 'workflow run ci.yml -R owner/repo --ref main' \
      'workflow run release-please.yml -R owner/repo --ref main')" ]
  done
}

@test "merge-image: leaves a pull request that changes other files" {
  local files
  for files in $'ci-image/Dockerfile\n.github/workflows/ci.yml' ci-image/setup.sh ci-image/Gemfile.local ''; do
    echo "[$files]"
    GH_FILES="$files" run_merge_step
    [ "$status" -eq 0 ]
    [[ "$output" == *"::notice::"* ]]
    run grep -c -E '^(pr merge|workflow run)' "$GH_LOG"
    [ "$output" = "0" ]
  done
}

@test "merge-image: starts no workflow when the merge fails" {
  GH_MERGE_RC=1 GH_FILES="ci-image/Dockerfile" run_merge_step
  [ "$status" -ne 0 ]
  run grep -c '^workflow run' "$GH_LOG"
  [ "$output" = "0" ]
}

# Dependabot pull requests stop on a version with a published vulnerability of any severity
@test "dependency-review: reviews the pull requests of Dependabot with an action pinned by SHA" {
  local ci="$GITHUB_DIR/workflows/ci.yml"
  run yq '.jobs["dependency-review"].if' "$ci"
  [ "$output" = "github.event_name == 'pull_request' && github.event.pull_request.user.login == 'dependabot[bot]'" ]
  run yq -o=json -I=0 '.jobs["dependency-review"].steps[0] | [.id, .with]' "$ci"
  [ "$output" = '["review",{"fail-on-severity":"low"}]' ]
  run grep -E '^ +uses: actions/dependency-review-action@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$' "$ci"
  [ "$status" -eq 0 ]
  run yq '.jobs["dependency-review"].steps | length' "$ci"
  [ "$output" = "1" ]
  run yq -o=json -I=0 '.jobs["dependency-review"].outputs' "$ci"
  [ "$output" = '{"vulnerable-changes":"${{ steps.review.outputs.vulnerable-changes }}"}' ]
}

# The update of the action runs before review, so the token that writes issues goes to a job
# that runs no action
@test "vulnerability-issue: opens the issue after a failed review and runs no action" {
  local ci="$GITHUB_DIR/workflows/ci.yml"
  run yq -o=json -I=0 '.jobs["vulnerability-issue"] | [.needs, .if]' "$ci"
  [ "$output" = "[\"dependency-review\",\"failure() && needs.dependency-review.result == 'failure'\"]" ]
  run yq '[.jobs["vulnerability-issue"].steps[] | select(has("uses"))] | length' "$ci"
  [ "$output" = "0" ]
  run yq -r '.jobs["vulnerability-issue"].steps[] | .name + "|" + .env.CHANGES' "$ci"
  [ "$output" = "Open an issue for the vulnerabilities|\${{ needs.dependency-review.outputs.vulnerable-changes }}" ]
}

# Runs the issue step of vulnerability-issue for the changes in $CHANGES, with a gh that lists the
# open issues of label dependency-review in $GH_TITLES and others in $GH_OTHERS, and logs every call
run_vulnerability_issue_step() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin" "$BATS_TEST_TMPDIR/temp"
  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
case "$1 $2" in
  "issue list")
    if [[ " $* " == *" --label dependency-review "* ]]; then
      printf '%s\n' "${GH_TITLES:-}"
    else
      printf '%s\n' "${GH_TITLES:-}" "${GH_OTHERS:-}"
    fi
    ;;
  "issue create")
    while (($#)); do
      [[ "$1" != --body-file ]] || cp "$2" "$GH_BODY"
      shift
    done
    ;;
esac
EOF
  chmod +x "$bin/gh"
  yq '.jobs["vulnerability-issue"].steps[] | select(.name == "Open an issue for the vulnerabilities") | .run' \
    "$GITHUB_DIR/workflows/ci.yml" >"$BATS_TEST_TMPDIR/step.sh"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log" GH_BODY="$BATS_TEST_TMPDIR/body.md"
  : >"$GH_LOG"
  rm -f "$GH_BODY"
  run env PATH="$bin:$PATH" GH_LOG="$GH_LOG" GH_BODY="$GH_BODY" GH_TITLES="${GH_TITLES:-}" GH_OTHERS="${GH_OTHERS:-}" \
    REPO=owner/repo PR=12 RUNNER_TEMP="$BATS_TEST_TMPDIR/temp" CHANGES="$CHANGES" bash -e "$BATS_TEST_TMPDIR/step.sh"
}

VULNERABLE_CHANGES='[{"change_type":"added","manifest":"ci-image/Gemfile.lock","ecosystem":"rubygems","name":"rexml","version":"3.4.5","package_url":"pkg:gem/rexml@3.4.5","license":null,"source_repository_url":null,"vulnerabilities":[{"severity":"high","advisory_ghsa_id":"GHSA-aaaa-bbbb-cccc","advisory_summary":"Denial of service | in the parser","advisory_url":"https://github.com/advisories/GHSA-aaaa-bbbb-cccc"}]}]'

@test "vulnerability-issue: opens an issue with a row for each vulnerability" {
  CHANGES="$VULNERABLE_CHANGES" run_vulnerability_issue_step
  [ "$status" -eq 0 ]
  grep -qxF -- 'label create -R owner/repo dependency-review --color d73a4a --description Dependabot update with published vulnerabilities' "$GH_LOG"
  grep -qxF -- 'issue create -R owner/repo --title ❌ Dependabot #12: published vulnerabilities --label dependency-review --body-file '"$BATS_TEST_TMPDIR"'/temp/vulnerabilities.md' "$GH_LOG"
  run cat "$GH_BODY"
  [ "${lines[0]}" = "Dependabot pull request #12 brings versions with published vulnerabilities, so it is not merged by itself." ]
  [ "${lines[1]}" = "| Package | Version | Severity | Advisory |" ]
  [ "${lines[3]}" = '| `rexml` | `3.4.5` | high | [GHSA-aaaa-bbbb-cccc](https://github.com/advisories/GHSA-aaaa-bbbb-cccc) Denial of service   in the parser |' ]
}

@test "vulnerability-issue: opens no issue when the review failed without a vulnerable change" {
  local changes
  for changes in '' '[]' '[{"name":"rexml","version":"3.4.5","vulnerabilities":[]}]'; do
    echo "[$changes]"
    CHANGES="$changes" run_vulnerability_issue_step
    [ "$status" -eq 0 ]
    [ ! -s "$GH_LOG" ]
  done
}

# Dependabot rebases its pull requests, and each push reviews them again
@test "vulnerability-issue: opens no second issue for the same pull request" {
  GH_TITLES=$'❌ pkg: update failed\n❌ Dependabot #12: published vulnerabilities' CHANGES="$VULNERABLE_CHANGES" \
    run_vulnerability_issue_step
  [ "$status" -eq 0 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}

# Labels take triage rights, and anyone can open an issue with the title of the next pull request
@test "vulnerability-issue: counts no issue without its label" {
  GH_OTHERS='❌ Dependabot #12: published vulnerabilities' CHANGES="$VULNERABLE_CHANGES" run_vulnerability_issue_step
  [ "$status" -eq 0 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "1" ]
}

@test "merge-image: fails when the file list cannot be read" {
  GH_FAIL=1 GH_FILES="ci-image/Dockerfile" run_merge_step
  [ "$status" -ne 0 ]
  run grep -c '^pr merge' "$GH_LOG"
  [ "$output" = "0" ]
}

# Jobs missing from the needs could fail and still merge
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

# Skipped needs pass, as pipeline is skipped for pull requests from forks
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

# Forks and template copies carry the workflow and must not open release PRs
@test "release-please: runs only in the upstream repository" {
  run yq '.jobs[] | .if' "$RELEASE"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "github.repository == 'staticwire/aurtomator'" "github.repository == 'staticwire/aurtomator'")" ]
}

# release-please fails on a release that another run created first, and that run then signs nothing
@test "release-please: runs wait for each other, and no waiting run is canceled" {
  run yq -o=json -I=0 '.concurrency' "$RELEASE"
  [ "$status" -eq 0 ]
  [ "$output" = '{"group":"release-please","cancel-in-progress":false,"queue":"max"}' ]
}

@test "release-please: pins the action by SHA, reads the config in .github and has a time limit" {
  run yq '.jobs["release-please"].steps[1].uses' "$RELEASE"
  [[ "$output" =~ ^googleapis/release-please-action@[0-9a-f]{40}$ ]]
  run grep -E '^ +- uses: googleapis/release-please-action@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$' "$RELEASE"
  [ "$status" -eq 0 ]
  run yq '.jobs["release-please"].steps[1].with | .["config-file"] + " " + .["manifest-file"]' "$RELEASE"
  [ "$output" = ".github/release-please-config.json .github/.release-please-manifest.json" ]
  run yq '.jobs[]["timeout-minutes"] > 0' "$RELEASE"
  [ "$output" = $'true\ntrue' ]
  run yq -o=json -I=0 '.permissions' "$RELEASE"
  [ "$output" = '{"contents":"read"}' ]
}

# GitHub runs the CI of a pull request opened with the workflow token only
# after someone with write access approves it, and main requires that CI
@test "release-please: opens the release PR with the token of the release App" {
  run yq '.jobs["release-please"].steps[0].uses' "$RELEASE"
  [[ "$output" =~ ^actions/create-github-app-token@[0-9a-f]{40}$ ]]
  run grep -E '^ +- uses: actions/create-github-app-token@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$' "$RELEASE"
  [ "$status" -eq 0 ]
  run yq -o=json -I=0 '.jobs["release-please"].steps[0] | [.id, .with]' "$RELEASE"
  [ "$output" = '["app-token",{"client-id":"${{ vars.RELEASE_APP_CLIENT_ID }}","private-key":"${{ secrets.RELEASE_APP_PRIVATE_KEY }}","permission-contents":"write","permission-issues":"write","permission-pull-requests":"write"}]' ]
  run yq '.jobs["release-please"].steps[1].with.token' "$RELEASE"
  [ "$output" = '${{ steps.app-token.outputs.token }}' ]
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

# Every action of a job can ask for its OIDC token, so the token and the App token never share
# a job, and the signing job runs after the job that tags the release
@test "release-please: signs an archive of the release in a job of its own after release-please" {
  run yq -r '.jobs["release-please"].steps[] | .name // (.uses | sub("@.*"; ""))' "$RELEASE"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' actions/create-github-app-token googleapis/release-please-action)" ]
  run yq -r '.jobs.sign.needs' "$RELEASE"
  [ "$output" = "release-please" ]
  run yq -r '.jobs.sign.steps[] | .name // (.uses | sub("@.*"; ""))' "$RELEASE"
  [ "$output" = "$(printf '%s\n' actions/checkout 'Find the release to sign' 'Build the archive' actions/attest \
    'Attach the archive')" ]
  run yq '[.jobs.sign | .. | select(tag == "!!str") | select(test("app-token|secrets\."))] | length' "$RELEASE"
  [ "$output" = 0 ]
}

@test "release-please: pins checkout and attest by SHA with the version in a comment" {
  local action
  for action in actions/checkout actions/attest; do
    run grep -E "^ +(- )?uses: $action@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$" "$RELEASE"
    [ "$status" -eq 0 ]
  done
}

@test "release-please: builds, attests and attaches only the archive that the find step names" {
  run yq -o=json -I=0 '.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@")) | .with' "$RELEASE"
  [ "$output" = '{"persist-credentials":false}' ]
  run yq -r '.jobs[].steps[] | select(.uses // "" | test("^actions/attest@")) | .with["subject-path"]' "$RELEASE"
  [ "$output" = 'aurtomator-${{ steps.find.outputs.version }}.tar.gz' ]
  run yq -r '.jobs[].steps[] | select(.name == "Build the archive" or .name == "Attach the archive" or
    (.uses // "" | test("^actions/attest@"))) | .if' "$RELEASE"
  [ "$output" = "$(printf '%s\n' "steps.find.outputs.version != ''" "steps.find.outputs.version != ''" \
    "steps.find.outputs.version != ''")" ]
  run yq -r '.jobs[].steps[] | select(.name == "Find the release to sign" or .name == "Attach the archive") |
    .env.GH_TOKEN' "$RELEASE"
  [ "$output" = "$(printf '%s\n' '${{ github.token }}' '${{ github.token }}')" ]
}

# Runs step $1 of release-please.yml in a checkout whose manifest holds $MANIFEST, with a gh that
# prints $TAG_SHA for the commit of a tag and $ASSETS for the assets of a release
run_release_step() {
  local bin="$BATS_TEST_TMPDIR/bin" ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$bin" "$ws/.github"
  printf '{".": "%s"}\n' "${MANIFEST:-}" >"$ws/.github/.release-please-manifest.json"
  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "api repos/"*)
    [[ -n "${TAG_SHA:-}" ]] || exit 1
    printf '%s\n' "$TAG_SHA"
    ;;
  "release view") printf '%s\n' "${ASSETS:-}" ;;
esac
EOF
  chmod +x "$bin/gh"
  yq ".jobs[].steps[] | select(.name == \"$1\") | .run" "$RELEASE" >"$BATS_TEST_TMPDIR/step.sh"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : >"$GH_LOG"
  : >"$BATS_TEST_TMPDIR/output"
  cd "$ws"
  run env PATH="$bin:$PATH" GH_LOG="$GH_LOG" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" REPO=owner/repo \
    SHA=abc123 TAG_SHA="${TAG_SHA:-}" ASSETS="${ASSETS:-}" VERSION="${VERSION:-}" \
    bash -e "$BATS_TEST_TMPDIR/step.sh"
}

# Reruns of the release job find the release again until it has its archive
@test "release-please: the find step names the release of the commit of the run without an archive" {
  MANIFEST=0.13.1 TAG_SHA=abc123 run_release_step "Find the release to sign"
  [ "$status" -eq 0 ]
  [ "$(<"$BATS_TEST_TMPDIR/output")" = "version=0.13.1" ]
  grep -qxF 'api repos/owner/repo/commits/v0.13.1 --jq .sha' "$GH_LOG"
  grep -qxF 'release view v0.13.1 -R owner/repo --json assets --jq .assets[].name' "$GH_LOG"
}

# Later pushes would sign the code of an older release with the provenance of a newer commit
@test "release-please: the find step leaves the release of another commit" {
  MANIFEST=0.13.0 TAG_SHA=def456 run_release_step "Find the release to sign"
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/output" ]
  run grep -c '^release ' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "release-please: the find step leaves a version without a tag" {
  MANIFEST=0.13.1 TAG_SHA='' run_release_step "Find the release to sign"
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/output" ]
}

@test "release-please: the find step leaves a release that has its archive" {
  MANIFEST=0.13.1 TAG_SHA=abc123 ASSETS=$'notes.txt\naurtomator-0.13.1.tar.gz' run_release_step "Find the release to sign"
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/output" ]
}

@test "release-please: the find step stops on a manifest without a version" {
  MANIFEST='1.0$(touch pwned)' TAG_SHA=abc123 run_release_step "Find the release to sign"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [ ! -s "$BATS_TEST_TMPDIR/output" ]
  [ ! -e pwned ]
  run grep -c . "$GH_LOG"
  [ "$output" = "0" ]
}

@test "release-please: the archive holds the commit of the run under aurtomator-<version>/" {
  local repo="$BATS_TEST_TMPDIR/repo"
  git init -q "$repo"
  echo code >"$repo/file"
  git -C "$repo" add file
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m init
  yq '.jobs[].steps[] | select(.name == "Build the archive") | .run' "$RELEASE" >"$BATS_TEST_TMPDIR/step.sh"
  cd "$repo"
  run env VERSION=0.13.1 bash -e "$BATS_TEST_TMPDIR/step.sh"
  [ "$status" -eq 0 ]
  run tar -tzf aurtomator-0.13.1.tar.gz
  [ "$output" = "$(printf '%s\n' aurtomator-0.13.1/ aurtomator-0.13.1/file)" ]
}

@test "release-please: attaches the archive to the release of its version" {
  VERSION=0.13.1 run_release_step "Attach the archive"
  [ "$status" -eq 0 ]
  grep -qxF 'release upload v0.13.1 aurtomator-0.13.1.tar.gz -R owner/repo' "$GH_LOG"
}

# === check-updates.yml: who decides what ===

CHECK_UPDATES="$GITHUB_DIR/workflows/check-updates.yml"

# Prints the run block of step $2 in job $1 of check-updates.yml. Jobs in a
# container run steps as sh -e {0}, so the tests run them with sh -e as well.
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
  run env SHA= bash -e "$step"
  [ "$status" -eq 1 ]
  [ "$output" = "::error::job.workflow_sha is not a commit SHA: ''" ]
  run env SHA=abc bash -e "$step"
  [ "$status" -eq 1 ]
  [ "$output" = "::error::job.workflow_sha is not a commit SHA: 'abc'" ]
  run env SHA=0123456789abcdef0123456789abcdef01234567 bash -e "$step"
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

# Downloads by name take any artifact of that name in the run and empty ids take them all,
# so 0 stands in for no id; verify takes the handoffs of prepare by a pattern only they upload
@test "check-updates: each job downloads an artifact by the id the job of its upload gave" {
  run yq '.jobs | to_entries[] | .key as $job | .value.steps[] | select(.uses | test("^actions/download-artifact@")) |
    $job + " " + .with.path + " " + (.with["artifact-ids"] // ("pattern " + .with.pattern + " " + (.with["merge-multiple"] | tostring))) + " " + (.with | has("name") | tostring)' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 7 ]
  [ "${lines[0]}" = "prepare /data/status $(id_of check checked) false" ]
  [ "${lines[1]}" = "verify /data/status $(id_of check checked) false" ]
  [ "${lines[2]}" = "verify /data/handoffs pattern handoff-* true false" ]
  [ "${lines[3]}" = "publish /data/status $(id_of check checked) false" ]
  [ "${lines[4]}" = "publish /data/handoff $(id_of verify verified) false" ]
  [ "${lines[5]}" = "issues .status $(id_of check checked) false" ]
  [ "${lines[6]}" = "issues .status $(id_of publish published) false" ]
}

# verify-pkg.sh takes the version and the asset value of the check run
@test "check-updates: verify downloads the statuses of the check job before it runs as builder" {
  run yq -o=json -I=0 '.jobs.verify.needs' "$CHECK_UPDATES"
  [ "$output" = '["image","check","prepare"]' ]
  [ "$(step_index verify "Download statuses")" -lt "$(step_index verify "Verify checksums")" ]
}

# Runs the Decide step with the name=status pairs in $DATA/statuses/ and prints the step outputs;
# $README_CHANGED and $NO_README_COPY change or drop the README copy in $RESULTS
run_decide_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin" results="$BATS_TEST_TMPDIR/results" pair
  local data="$BATS_TEST_TMPDIR/data"
  mkdir -p "$ws" "$data/statuses" "$bin" "$results"
  ln -sfn "${AURTOMATOR_TREE:-$BATS_TEST_DIRNAME/..}" "$ws/aurtomator"
  for pair in "$@"; do
    printf '%s\n' "${pair#*=}" >"$data/statuses/${pair%%=*}"
    # Outdated packages have their YAML, except those named in $NO_YAML
    if [[ "${pair#*=}" =~ ^(new_version|available_downgrade|new_build|arch_back): && " ${NO_YAML:-} " != *" ${pair%%=*} "* ]]; then
      mkdir -p "$ws/packages"
      printf 'name: %s\n' "${pair%%=*}" >"$ws/packages/${pair%%=*}.yml"
    fi
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
  (cd "$ws" && PATH="$bin:$PATH" DATA="$data" RESULTS="$results" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" \
    GITHUB_REPOSITORY=owner/aur-packages AURTOMATOR_STATS_DATE=2026-11-10 timeout 60 sh -e "$BATS_TEST_TMPDIR/step.sh") \
    >"$BATS_TEST_TMPDIR/decide.out" 2>"$BATS_TEST_TMPDIR/decide.log"
  cat "$BATS_TEST_TMPDIR/output"
}

@test "check-updates: Decide prepares when a package is outdated" {
  run run_decide_step pkg="new_version: 2.0.0" other=up_to_date
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=true\nwork=true\npackages=true\nto-prepare=["pkg"]' ]
  run run_decide_step pkg="available_downgrade: 1.0.0"
  [ "$output" = $'prepare=true\nwork=true\npackages=true\nto-prepare=["pkg"]' ]
  run run_decide_step pkg="new_build: 1.0.0" _assets=$'pkg\t1.0.0-b'
  [ "$output" = $'prepare=true\nwork=true\npackages=true\nto-prepare=["pkg"]' ]
  run run_decide_step pkg="arch_back: 1.0.0 aarch64" _arches=$'pkg\t1.0.0\t\t'
  [ "$output" = $'prepare=true\nwork=true\npackages=true\nto-prepare=["pkg"]' ]
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

# Errors of failed checks hold lines of the server, as of a git ERR packet
@test "check-updates: Decide prepares nothing for a failed check whose error holds a version line" {
  mkdir -p "$BATS_TEST_TMPDIR/ws/packages"
  printf 'name: pkg\n' >"$BATS_TEST_TMPDIR/ws/packages/pkg.yml"
  run run_decide_step pkg=$'check_failed: fatal: remote error: access denied\nnew_version: 9.9.9'
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=false\nwork=true\npackages=true\nto-prepare=[]' ]
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
  [ "$output" = $'prepare=true\nwork=true\npackages=true\nto-prepare=["a","b","c"]' ]
  [ ! -e "$BATS_TEST_TMPDIR/data/statuses/_deferred" ]
}

@test "check-updates: Decide lists no name that Hand over would not take" {
  run run_decide_step "bad name=new_version: 2.0.0" "-x=new_version: 2.0.0" "Demo=new_version: 2.0.0" \
    "_x=new_version: 2.0.0" pkg="new_version: 2.0.0"
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=true\nwork=true\npackages=true\nto-prepare=["pkg"]' ]
}

# builder of check writes the statuses, so a name without a package YAML would start a job
@test "check-updates: Decide prepares no name without a package YAML" {
  NO_YAML="ghost a0" run run_decide_step ghost="new_version: 2.0.0" a0="arch_back: 1.0.0 aarch64" pkg="new_version: 2.0.0"
  [ "$status" -eq 0 ]
  [ "$output" = $'prepare=true\nwork=true\npackages=true\nto-prepare=["pkg"]' ]
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
  [ "$(cat "$BATS_TEST_TMPDIR/data/statuses/_deferred")" = $'p257\np258' ]
  grep -qxF '::warning::2 outdated packages wait for the next run, which prepares at most 256' "$BATS_TEST_TMPDIR/decide.out"
}

@test "check-updates: Decide removes the _without and the _deferred of builder" {
  run run_decide_step pkg="new_version: 2.0.0" _without="" _deferred=other
  [ "$status" -eq 0 ]
  [ "${lines[3]}" = 'to-prepare=["pkg"]' ]
  [ ! -e "$BATS_TEST_TMPDIR/data/statuses/_without" ]
  [ ! -e "$BATS_TEST_TMPDIR/data/statuses/_deferred" ]
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

# Journals root cannot read would set work in every run, and publish would
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

# Jobs of prepare run again upload a handoff of their own beside the one of
# the attempt before
@test "check-updates: each job of prepare uploads the handoff of its package and attempt" {
  run yq -o=json -I=0 '[.jobs.prepare.steps[] | select(.uses | test("^actions/upload-artifact@")) | [.id, .with.name, .with.path, .with["if-no-files-found"]]]' "$CHECK_UPDATES"
  [ "$output" = '[[null,"handoff-${{ matrix.package }}-${{ github.run_attempt }}","/data/handoff-out/","error"]]' ]
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
  run env -C "$ws" ATTEMPT=3 DATA="$ws" sh -e "$BATS_TEST_TMPDIR/step.sh"
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
  (cd "$ws" && DATA="$ws" sh -e "$BATS_TEST_TMPDIR/step.sh") || return
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
  add_attempt 1 Demo upper
  add_attempt 1 _x under
  mkdir -p "$ws/handoffs/1/status" "$BATS_TEST_TMPDIR/elsewhere/prepared/foo"
  echo x >"$ws/handoffs/1/status/-x"
  # PKGBUILD code of prepare could write the list that only verify hands publish
  echo foo >"$ws/handoffs/1/status/_unverified"
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

@test "check-updates: verify takes no file of an attempt larger than its limit" {
  local dir="$BATS_TEST_TMPDIR/ws/handoffs/1"
  add_attempt 1 foo kept
  truncate -s $((1024 * 1024 + 1)) "$dir/prepared/foo/PKGBUILD"
  printf '%064d\n' 0 >"$dir/prepared/foo/base"
  mkdir -p "$dir/status"
  truncate -s $((64 * 1024 + 1)) "$dir/status/foo"
  run run_take_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::handoffs/1/prepared/foo/PKGBUILD is larger than 1048576 bytes"* ]]
  [[ "$output" == *"::warning::handoffs/1/prepared/foo/base is larger than 64 bytes"* ]]
  [[ "$output" == *"::warning::handoffs/1/status/foo is larger than 65536 bytes"* ]]
  run bash -c 'cd "$1" && find . -type f' _ "$BATS_TEST_TMPDIR/ws/handoff"
  [ "$output" = "./prepared/foo/.SRCINFO" ]
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
    [[ "${output//'sudo -u builder head -c "$(($3 + 1))" -- '/}" != *"sudo"* ]]
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
    # Nothing after the step of builder runs as builder except the kill of Stop builder and the
    # reads of Hand over
    run yq ".jobs.$job.steps[$((builder + 1)):] | .[] | select(has(\"run\")) | .run" "$CHECK_UPDATES"
    [ "$status" -eq 0 ]
    output=${output//"sudo -u builder kill -KILL -1 "/}
    [[ "${output//'sudo -u builder head -c "$(($3 + 1))" -- '/}" != *"sudo -u builder"* ]]
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
  run env -C "$ws" sh -e "$BATS_TEST_TMPDIR/step.sh"
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
  [ "$output" = '{"ARGS":"${{ inputs.args }}","HANDOFF":"${{ inputs.handoff }}","KEEP_ENV":"${{ inputs.keep-env }}","PACKAGE":"${{ inputs.package }}","README_TOO":"${{ inputs.readme }}","STATUSES":"${{ inputs.statuses }}","WORK":"/work"}' ]
  run yq '.inputs.readme.default' "$BUILDER_ACTION"
  [ "$output" = "false" ]
  local input
  for input in package statuses handoff; do
    run yq ".inputs.$input.default" "$BUILDER_ACTION"
    [ "$output" = "" ]
  done
}

# Runs the run-as-builder action with the inputs of step $2 of job $1 in $BATS_TEST_TMPDIR/ws,
# with /data of the inputs in $BATS_TEST_TMPDIR/data and mocks of sudo, chown and git that log
# their calls
run_builder_step() {
  local bin="$BATS_TEST_TMPDIR/bin" ws="$BATS_TEST_TMPDIR/ws" step=".jobs.$1.steps[] | select(.name == \"$2\")" args keep readme package
  local statuses handoff
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
[[ "$*" != */update-readme.sh ]] || exit "${README_RC:-${SUDO_RC:-0}}"
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
  statuses=$(yq "$step | .with.statuses // \"\"" "$CHECK_UPDATES")
  handoff=$(yq "$step | .with.handoff // \"\"" "$CHECK_UPDATES")
  statuses=${statuses/#\/data\//$BATS_TEST_TMPDIR/data/}
  handoff=${handoff/#\/data\//$BATS_TEST_TMPDIR/data/}
  rm -f "$SUDO_LOG"
  run env -C "$ws" PATH="$bin:$PATH" GITHUB_WORKSPACE="$ws" CALL_LOGS="$BATS_TEST_TMPDIR" \
    GITHUB_ACTION_PATH="${ACTION_PATH:-$action_dir}" SUDO_LOG="$SUDO_LOG" TEST_X_RC="${TEST_X_RC:-0}" \
    ARGS="$args" KEEP_ENV="$keep" PACKAGE="$package" README_TOO="$readme" WORK="$BATS_TEST_TMPDIR/work" \
    STATUSES="$statuses" HANDOFF="$handoff" bash --noprofile --norc -eo pipefail "$BATS_TEST_TMPDIR/step.sh"
}

# Prints the command lines that sudo recorded, without the environments
sudo_commands() {
  grep -E ' cwd=/' "$SUDO_LOG"
}

@test "check-updates: each builder step runs check-all.sh in its mode, with only the variables it needs" {
  local expected entry job name code="$BATS_TEST_TMPDIR/ws/aurtomator/scripts" work="$BATS_TEST_TMPDIR/work" tab=$'\t'
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  expected=(
    "check${tab}Check updates${tab}--preserve-env=GITHUB_REPOSITORY,GITHUB_TOKEN,GITHUB_RUN_NUMBER -u builder $code/check-all.sh cwd=$work${tab}--preserve-env=GITHUB_REPOSITORY -u builder $code/update-readme.sh cwd=$work"
    "prepare${tab}Prepare updates${tab}--preserve-env=GITHUB_REPOSITORY -u builder $code/check-all.sh --prepare handoff cwd=$work${tab}"
    "verify${tab}Verify checksums${tab}--preserve-env=GITHUB_REPOSITORY,GITHUB_RUN_NUMBER -u builder $code/check-all.sh --verify handoff cwd=$work${tab}"
    "publish${tab}Publish updates${tab}--preserve-env=GITHUB_REPOSITORY,GPG_KEY_ID,GIT_AUTHOR_NAME,GIT_AUTHOR_EMAIL -u builder $code/check-all.sh --publish handoff cwd=$work${tab}--preserve-env=GITHUB_REPOSITORY -u builder $code/update-readme.sh cwd=$work"
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

# update-readme.sh ends with 3 when it leaves README.md as it is, and the step warns after
# the token, where the runner reads workflow commands again
@test "run-as-builder: warns and goes on when update-readme.sh leaves the README as it is" {
  local i resumed=-1 warned=-1
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  SUDO_OUT=ok README_RC=3 run_builder_step check "Check updates"
  [ "$status" -eq 0 ]
  for i in "${!lines[@]}"; do
    [[ ! "${lines[i]}" =~ ^::[0-9a-f]{32}::$ ]] || resumed=$i
    [[ "${lines[i]}" != "::warning::README.md stays as it is"* ]] || warned=$i
  done
  ((resumed >= 0 && warned > resumed))
  SUDO_OUT=ok README_RC=1 run_builder_step check "Check updates"
  [ "$status" -eq 1 ]
  [[ "$output" != *"::warning::"* ]]
}

@test "run-as-builder: gives builder its own directory and runs no git" {
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  SUDO_OUT=ok run_builder_step check "Check updates"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/chown.log")" = "-R builder:builder $BATS_TEST_TMPDIR/work" ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/work")" = "700" ]
  [ ! -e "$BATS_TEST_TMPDIR/git.log" ]
}

# Writes the inputs that a job hands to builder into the workspace and into
# $BATS_TEST_TMPDIR/data, with files of other names and links beside them
make_builder_inputs() {
  local ws="$BATS_TEST_TMPDIR/ws" st="$BATS_TEST_TMPDIR/data/status" ho="$BATS_TEST_TMPDIR/data/handoff"
  echo secret >"$BATS_TEST_TMPDIR/secret"
  mkdir -p "$ws/packages/sub" "$st" "$ho/prepared/foo" "$ho/status"
  echo "name: foo" >"$ws/packages/foo.yml"
  echo "name: _x" >"$ws/packages/_x.yml"
  echo "notes" >"$ws/packages/notes.txt"
  echo "name: x" >"$ws/packages/sub/x.yml"
  echo "name: bad" >"$ws/packages/bad name.yml"
  ln -s "$BATS_TEST_TMPDIR/secret" "$ws/packages/link.yml"
  echo "readme" >"$ws/README.md"
  echo "other" >"$ws/other.md"
  echo "new_version: 2.0" >"$st/foo"
  echo "newer: 0.9.0" >"$st/_upstream"
  echo "x" >"$st/.hidden"
  echo "x" >"$st/-dash"
  ln -s "$BATS_TEST_TMPDIR/secret" "$st/link"
  echo pkgbuild >"$ho/prepared/foo/PKGBUILD"
  echo srcinfo >"$ho/prepared/foo/.SRCINFO"
  echo base >"$ho/prepared/foo/base"
  echo notes >"$ho/prepared/foo/notes.txt"
  ln -s "$BATS_TEST_TMPDIR/secret" "$ho/prepared/foo/link"
  echo "update_failed: boom" >"$ho/status/foo"
  echo foo >"$ho/status/_unverified"
  echo x >"$ho/status/_other"
  mkdir -p "$ho/status/sub" "$ho/prepared/foo/status" "$ho/prepared/xstatus"
  echo x >"$ho/status/sub/x"
  echo x >"$ho/prepared/foo/status/x"
  echo x >"$ho/prepared/xstatus/x"
  echo other >"$ho/other"
}

@test "run-as-builder: copies the regular files of the expected names into the directory of builder" {
  local work="$BATS_TEST_TMPDIR/work"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  make_builder_inputs
  SUDO_OUT=ok run_builder_step verify "Verify checksums"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && find . -mindepth 1 | LC_ALL=C sort' _ "$work"
  [ "$output" = "$(printf '%s\n' ./.status ./.status/_upstream ./.status/foo ./README.md ./handoff ./handoff/prepared \
    ./handoff/prepared/foo ./handoff/prepared/foo/.SRCINFO ./handoff/prepared/foo/PKGBUILD ./handoff/prepared/foo/base \
    ./handoff/status ./handoff/status/_unverified ./handoff/status/foo ./packages ./packages/foo.yml ./packages/link.yml)" ]
  [ "$(cat "$work/packages/foo.yml")" = "name: foo" ]
  [ "$(cat "$work/handoff/status/foo")" = "update_failed: boom" ]
  [ "$(stat -c %a "$work/handoff/prepared/foo/PKGBUILD")" = "644" ]
}

# verify gets no status/ from a prepare in which no update failed
@test "run-as-builder: copies a handoff without statuses" {
  local ws="$BATS_TEST_TMPDIR/ws" work="$BATS_TEST_TMPDIR/work"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  make_builder_inputs
  rm -r "$BATS_TEST_TMPDIR/data/handoff/status"
  SUDO_OUT=ok run_builder_step verify "Verify checksums"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1/handoff" && find . -type f | LC_ALL=C sort' _ "$work"
  [ "$output" = $'./prepared/foo/.SRCINFO\n./prepared/foo/PKGBUILD\n./prepared/foo/base' ]
}

@test "run-as-builder: copies no status and no handoff file larger than its limit" {
  local work="$BATS_TEST_TMPDIR/work" data="$BATS_TEST_TMPDIR/data"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  make_builder_inputs
  truncate -s $((1024 * 1024 + 1)) "$data/handoff/prepared/foo/PKGBUILD"
  printf '%064d\n' 0 >"$data/handoff/prepared/foo/base"
  truncate -s $((64 * 1024 + 1)) "$data/handoff/status/foo"
  truncate -s $((16 * 1024 * 1024 + 1)) "$data/status/foo"
  SUDO_OUT=ok run_builder_step verify "Verify checksums"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::handoff/prepared/foo/PKGBUILD is larger than 1048576 bytes"* ]]
  [[ "$output" == *"::warning::handoff/prepared/foo/base is larger than 64 bytes"* ]]
  [[ "$output" == *"::warning::handoff/status/foo is larger than 65536 bytes"* ]]
  [[ "$output" == *"::warning::.status/foo is larger than 16777216 bytes"* ]]
  run bash -c 'cd "$1" && find . -type f | LC_ALL=C sort' _ "$work"
  [ "$output" = "$(printf '%s\n' ./.status/_upstream ./README.md ./handoff/prepared/foo/.SRCINFO \
    ./handoff/status/_unverified ./packages/foo.yml)" ]
}

@test "run-as-builder: copies nothing from an input that is a link" {
  local ws="$BATS_TEST_TMPDIR/ws" work="$BATS_TEST_TMPDIR/work" input
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  make_builder_inputs
  for input in ws/packages data/status data/handoff ws/README.md; do
    mv "$BATS_TEST_TMPDIR/$input" "$BATS_TEST_TMPDIR/real-${input##*/}"
    ln -s "$BATS_TEST_TMPDIR/real-${input##*/}" "$BATS_TEST_TMPDIR/$input"
  done
  SUDO_OUT=ok run_builder_step verify "Verify checksums"
  [ "$status" -eq 0 ]
  [ -d "$work" ]
  [ -z "$(ls -A "$work")" ]
}

# check-all.sh and update-readme.sh then fail the YAML by its file name, so its issues stay open
@test "run-as-builder: gives builder a package YAML that is a link as a link to itself" {
  local work="$BATS_TEST_TMPDIR/work"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  make_builder_inputs
  ln -s "$BATS_TEST_TMPDIR/secret" "$BATS_TEST_TMPDIR/ws/packages/bad link.yml"
  SUDO_OUT=ok run_builder_step check "Check updates"
  [ "$status" -eq 0 ]
  [ -L "$work/packages/link.yml" ]
  [ "$(readlink "$work/packages/link.yml")" = link.yml ]
  [ ! -L "$work/packages/bad link.yml" ]
  [ ! -e "$work/packages/bad link.yml" ]
  run grep -rl secret "$work"
  [ "$status" -eq 1 ]
}

# Pull requests can commit .status/ and handoff/, which the jobs never read
@test "run-as-builder: takes no status and no handoff from the checkout" {
  local ws="$BATS_TEST_TMPDIR/ws" work="$BATS_TEST_TMPDIR/work" entry
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  make_builder_inputs
  rm -rf "$BATS_TEST_TMPDIR/data"
  mkdir -p "$ws/.status" "$ws/handoff/prepared/foo" "$BATS_TEST_TMPDIR/data/status" "$BATS_TEST_TMPDIR/data/handoff"
  printf 'foo\n' >"$ws/.status/_deferred"
  echo "new_version: 2.0" >"$ws/.status/foo"
  echo pkgbuild >"$ws/handoff/prepared/foo/PKGBUILD"
  for entry in "check:Check updates" "prepare:Prepare updates" "verify:Verify checksums" "publish:Publish updates"; do
    echo "$entry"
    rm -rf "$work"
    SUDO_OUT=ok run_builder_step "${entry%%:*}" "${entry#*:}"
    [ "$status" -eq 0 ]
    [ ! -e "$work/.status" ]
    [ ! -e "$work/handoff" ]
  done
}

@test "run-as-builder: gives builder the files of one package when the input names it" {
  local ws="$BATS_TEST_TMPDIR/ws" work="$BATS_TEST_TMPDIR/work"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  make_builder_inputs
  echo "name: bar" >"$ws/packages/bar.yml"
  echo "new_version: 3.0" >"$BATS_TEST_TMPDIR/data/status/bar"
  printf 'foo\t2.0-x\nbar\t3.0-x\n' >"$BATS_TEST_TMPDIR/data/status/_assets"
  printf 'foo\t2.0\taarch64\t\nbar\t3.0\t\t\n' >"$BATS_TEST_TMPDIR/data/status/_arches"
  printf 'bar\tnotice\tNote\n' >"$BATS_TEST_TMPDIR/data/status/_alerts"
  PACKAGE_INPUT=foo SUDO_OUT=ok run_builder_step prepare "Prepare updates"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && find . -mindepth 1 | LC_ALL=C sort' _ "$work"
  [ "$output" = "$(printf '%s\n' ./.status ./.status/_arches ./.status/_assets ./.status/_upstream ./.status/foo ./packages ./packages/foo.yml)" ]
}

# PKGBUILD code of the package runs as builder in prepare
@test "run-as-builder: gives builder only the lines of its package in _arches and _assets" {
  local work="$BATS_TEST_TMPDIR/work"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  make_builder_inputs
  printf 'foo\t2.0-x\nbar\t3.0-x\nfoo2\t4.0-x\n' >"$BATS_TEST_TMPDIR/data/status/_assets"
  printf 'bar\t3.0\t\t\nfoo\t2.0\taarch64\t\n' >"$BATS_TEST_TMPDIR/data/status/_arches"
  PACKAGE_INPUT=foo SUDO_OUT=ok run_builder_step prepare "Prepare updates"
  [ "$status" -eq 0 ]
  [ "$(cat "$work/.status/_assets")" = $'foo\t2.0-x' ]
  [ "$(cat "$work/.status/_arches")" = $'foo\t2.0\taarch64\t' ]
  [ "$(stat -c %a "$work/.status/_assets" "$work/.status/_arches")" = $'644\n644' ]
}

# awk compares two fields that look like numbers as numbers, and 1e2 and 100 are both 100
@test "run-as-builder: gives builder no line of a package that awk reads as the same number" {
  local work="$BATS_TEST_TMPDIR/work"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  make_builder_inputs
  printf '100\t9.9-z\n1e2\t2.0-x\n' >"$BATS_TEST_TMPDIR/data/status/_assets"
  PACKAGE_INPUT=1e2 SUDO_OUT=ok run_builder_step prepare "Prepare updates"
  [ "$status" -eq 0 ]
  [ "$(cat "$work/.status/_assets")" = $'1e2\t2.0-x' ]
}

@test "run-as-builder: copies nothing of one package through a link" {
  local ws="$BATS_TEST_TMPDIR/ws" work="$BATS_TEST_TMPDIR/work" input
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  make_builder_inputs
  for input in ws/packages data/status; do
    mv "$BATS_TEST_TMPDIR/$input" "$BATS_TEST_TMPDIR/real-${input##*/}"
    ln -s "$BATS_TEST_TMPDIR/real-${input##*/}" "$BATS_TEST_TMPDIR/$input"
  done
  PACKAGE_INPUT=foo SUDO_OUT=ok run_builder_step prepare "Prepare updates"
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

# Directories left by an earlier step could hold files that builder chose
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

# Wrong GITHUB_ACTION_PATH values fail the step before it stops the workflow
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

# Runs the Add builder step with $RUNNER_TEMP set to /__w/_temp; useradd and find log to $CALLS,
# id prints $BUILDER_UID and stat prints $TEMP_OWNER as the owner of $RUNNER_TEMP
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
  [ "$(cat "$CALLS/find")" = "/__w /__e /__t ( -user builder -o -group builder ) -print -quit" ]
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
  [ "$output" = "::error::find could not search /__w, /__e and /__t for the files of builder" ]
}

@test "check-updates: Add builder fails when stat cannot read the owner of the runner temp" {
  STAT_RC=1 run_add_builder_step
  [ "$status" -ne 0 ]
  [ "$output" = "::error::Could not read the owner of /__w/_temp" ]
  [ ! -e "$CALLS/find" ]
}

# Runs the Stop builder step in an empty workspace; ps lists $PS_LINES until pkill runs and
# $PS_AFTER_KILL after it, as "<uid> <ruid> <state>" separated by commas. It fails after 20 s.
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

# Jobs that failed before useradd have no builder and no checkout
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

# Runs the Hand over step of prepare in $BATS_TEST_TMPDIR/ws, with work/ of builder, results/
# of root and a new data/ beside it; sudo runs the command of -u builder as the test user
run_hand_over_step() {
  local bin="$BATS_TEST_TMPDIR/bin"
  rm -rf "$BATS_TEST_TMPDIR/data"
  mkdir -p "$BATS_TEST_TMPDIR/ws" "$BATS_TEST_TMPDIR/data" "$bin"
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
    DATA="$BATS_TEST_TMPDIR/data" RESULTS="$BATS_TEST_TMPDIR/results" PACKAGE="${HAND_OVER_PACKAGE:-}" \
    sh ${HAND_OVER_SHELL:--e} "$BATS_TEST_TMPDIR/step.sh"
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
  run bash -c 'cd "$1/upload" && find . -type f | LC_ALL=C sort' _ "$BATS_TEST_TMPDIR/data"
  [ "$output" = $'./prepared/foo/.SRCINFO\n./prepared/foo/PKGBUILD\n./prepared/foo/base\n./status/foo' ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/data/upload/prepared/foo/PKGBUILD")" = "644" ]
  [ "$(cat "$BATS_TEST_TMPDIR/data/upload/status/foo")" = "updated: 2.0" ]
}

@test "check-updates: Hand over takes only the package of its job" {
  local ws="$BATS_TEST_TMPDIR/ws" work="$BATS_TEST_TMPDIR/work"
  make_handoff
  mkdir -p "$work/handoff/prepared/bar"
  echo pkgbuild >"$work/handoff/prepared/bar/PKGBUILD"
  echo "update_failed: forged" >"$work/handoff/status/bar"
  # The list of the packages that verify did not reach goes out of verify alone
  echo foo >"$work/handoff/status/_unverified"
  HAND_OVER_PACKAGE=foo run_hand_over_step
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1/upload" && find . -type f | LC_ALL=C sort' _ "$BATS_TEST_TMPDIR/data"
  [ "$output" = $'./prepared/foo/.SRCINFO\n./prepared/foo/PKGBUILD\n./prepared/foo/base\n./status/foo' ]
  rm -rf "$ws"
  run_hand_over_step
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1/upload" && find . -type f | LC_ALL=C sort' _ "$BATS_TEST_TMPDIR/data"
  [ "$output" = $'./prepared/bar/PKGBUILD\n./prepared/foo/.SRCINFO\n./prepared/foo/PKGBUILD\n./prepared/foo/base\n./status/_unverified\n./status/bar\n./status/foo' ]
}

# Links would put a file that root can read into an artifact anyone with
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
    [ ! -e "$BATS_TEST_TMPDIR/data/upload/prepared/foo/PKGBUILD" ]
    [ -f "$BATS_TEST_TMPDIR/data/upload/prepared/foo/base" ]
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
    run find "$BATS_TEST_TMPDIR/data/upload" "$BATS_TEST_TMPDIR/data/statuses" "$BATS_TEST_TMPDIR/results/packages" -type f
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
  printf '%s\n' "updated: 2.0" >"$work/.status/Demo"
  ln -s "$BATS_TEST_TMPDIR/secret" "$work/.status/link"
  echo "new table" >"$work/README.md"
  echo "current: 2.0" >"$work/packages/foo.yml"
  echo notes >"$work/packages/notes.txt"
  echo "current: 1.0" >"$work/packages/sub/x.yml"
  echo "current: 1.0" >"$work/packages/bad name.yml"
  echo "current: 1.0" >"$work/packages/Demo.yml"
  echo "current: 1.0" >"$work/packages/_x.yml"
  ln -s "$BATS_TEST_TMPDIR/secret" "$work/packages/link.yml"
  run_hand_over_step
  [ "$status" -eq 0 ]
  run env LC_ALL=C ls -A "$BATS_TEST_TMPDIR/data/statuses"
  [ "$output" = $'_alerts\n_upstream\nfoo' ]
  [ "$(<"$BATS_TEST_TMPDIR/data/statuses/foo")" = "updated: 2.0" ]
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
  [ "$output" = "$(printf -- "-u builder head -c %s -- $work/%s\n" 16777217 .status/foo 16777217 README.md \
    1048577 handoff/prepared/foo/.SRCINFO 1048577 handoff/prepared/foo/PKGBUILD 65 handoff/prepared/foo/base \
    65537 handoff/status/foo 16777217 packages/foo.yml | LC_ALL=C sort)" ]
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
    run bash -c 'cd "$1/upload" && find . -type f | LC_ALL=C sort' _ "$BATS_TEST_TMPDIR/data"
    [ "$output" = $'./prepared/foo/.SRCINFO\n./prepared/foo/PKGBUILD\n./prepared/foo/base' ]
  done
}

@test "check-updates: Hand over copies nothing without a directory of builder" {
  local ws="$BATS_TEST_TMPDIR/ws"
  run_hand_over_step
  [ "$status" -eq 0 ]
  [ -d "$BATS_TEST_TMPDIR/data/upload" ]
  [ -d "$BATS_TEST_TMPDIR/data/statuses" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/data/upload")" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/data/statuses")" ]
  [ -z "$(ls -A "$ws")" ]
  [ ! -s "$SUDO_LOG" ]
}

# PKGBUILD code of prepare writes the handoff, and verify copies the files of every package
# three times, so a file past its limit stays out; head reads one byte past the limit alone
@test "check-updates: Hand over skips each file larger than its limit" {
  local work="$BATS_TEST_TMPDIR/work" up="$BATS_TEST_TMPDIR/data/upload"
  make_handoff
  truncate -s $((1024 * 1024 + 1)) "$work/handoff/prepared/foo/PKGBUILD"
  truncate -s $((1024 * 1024)) "$work/handoff/prepared/foo/.SRCINFO"
  printf '%064d\n' 0 >"$work/handoff/prepared/foo/base"
  truncate -s $((64 * 1024 + 1)) "$work/handoff/status/foo"
  mkdir -p "$work/.status" "$work/packages"
  truncate -s $((16 * 1024 * 1024 + 1)) "$work/.status/_upstream"
  echo "updated: 2.0" >"$work/.status/foo"
  truncate -s $((64 * 1024 * 1024)) "$work/README.md"
  truncate -s $((16 * 1024 * 1024)) "$work/packages/foo.yml"
  run_hand_over_step
  [ "$status" -eq 0 ]
  [ ! -e "$up/prepared/foo/PKGBUILD" ]
  [ "$(stat -c %s "$up/prepared/foo/.SRCINFO")" -eq $((1024 * 1024)) ]
  [ ! -e "$up/prepared/foo/base" ]
  [ ! -e "$up/status/foo" ]
  [ ! -e "$BATS_TEST_TMPDIR/data/statuses/_upstream" ]
  [ "$(<"$BATS_TEST_TMPDIR/data/statuses/foo")" = "updated: 2.0" ]
  [ ! -e "$BATS_TEST_TMPDIR/results/README.md" ]
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/results/packages/foo.yml")" -eq $((16 * 1024 * 1024)) ]
  [[ "$output" == *"::warning::handoff/prepared/foo/PKGBUILD is larger than 1048576 bytes"* ]]
  [[ "$output" == *"::warning::handoff/prepared/foo/base is larger than 64 bytes"* ]]
  [[ "$output" == *"::warning::handoff/status/foo is larger than 65536 bytes"* ]]
  [[ "$output" == *"::warning::.status/_upstream is larger than 16777216 bytes"* ]]
  [[ "$output" == *"::warning::README.md is larger than 16777216 bytes"* ]]
}

# Workspace with aurtomator linked in, package a at 1.0 before the run and
# at $1 after it, its status $2 in data/statuses/, and a journal of one run before
make_stats_ws() {
  local ws="$BATS_TEST_TMPDIR/ws" results="$BATS_TEST_TMPDIR/results"
  mkdir -p "$ws/packages" "$BATS_TEST_TMPDIR/data/statuses" "$ws/stats" "$results/packages"
  ln -sfn "$BATS_TEST_DIRNAME/.." "$ws/aurtomator"
  printf 'name: a\nstrategy: github-release\nupstream:\n  project: o/a\ncurrent: 1.0\n' >"$ws/packages/a.yml"
  sed "s/^current: .*/current: $1/" "$ws/packages/a.yml" >"$results/packages/a.yml"
  printf '%s\n' "$2" >"$BATS_TEST_TMPDIR/data/statuses/a"
  printf '%s\n' 'time,package,event,version,previous,run' '2026-11-08T05:17:41Z,a,tracked,1.0,,6' >"$ws/stats/events.csv"
}

# Runs Record statistics in that workspace for the repository $REPO, by
# default owner/aur-packages, at a fixed time and run
run_stats_step() {
  step_run publish "Record statistics" >"$BATS_TEST_TMPDIR/stats-step.sh"
  (cd "$BATS_TEST_TMPDIR/ws" && DATA="$BATS_TEST_TMPDIR/data" RESULTS="$BATS_TEST_TMPDIR/results" GITHUB_REPOSITORY="${REPO-owner/aur-packages}" \
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

# Stalled scripts take the path of their failure, so the commit lands
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

# Runs the issue step of the issues job with the name=status pairs as statuses; gh answers from
# $GH_TITLES and logs to $GH_LOG, and the issue functions log to $BODY_LOG
run_issue_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin" pair
  mkdir -p "$ws/.status" "$ws/aurtomator/scripts" "$bin"
  printf 'set -euo pipefail\nsource %q\n' "$BATS_TEST_DIRNAME/../scripts/lib/issue.sh" >"$ws/aurtomator/scripts/lib.sh"
  cat >>"$ws/aurtomator/scripts/lib.sh" <<'EOF'
failure_issue_body() { echo "failure_issue_body $*" >>"$BODY_LOG" && echo body; }
alert_issue_body() { echo "alert_issue_body $*" >>"$BODY_LOG" && echo body; }
upstream_issue_body() { echo "upstream_issue_body $*" >>"$BODY_LOG" && echo body; }
# BIG_BODY writes 60000 characters of three bytes each
host_issue_body() {
  echo "host_issue_body $*" >>"$BODY_LOG"
  if [[ -n "${BIG_BODY:-}" ]]; then printf '€%.0s' {1..60000}; else echo body; fi
}
arch_issue_body() { echo "arch_issue_body $*" >>"$BODY_LOG" && echo body; }
EOF
  rm -f "$ws/.status/_hosts"
  for pair in "$@"; do
    # Each failed check adds its line to _hosts
    if [[ "${pair%%=*}" == _hosts ]]; then
      printf '%s\n' "${pair#*=}" >>"$ws/.status/_hosts"
    else
      printf '%s\n' "${pair#*=}" >"$ws/.status/${pair%%=*}"
    fi
  done
  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
# The size of a body that comes on stdin, in bytes
if [[ " $* " == *" --body-file - "* ]]; then
  wc -c >>"$GH_BODY_LOG"
fi
if [[ "$*" == "api repos/$GITHUB_REPOSITORY --jq .has_issues" ]]; then
  [[ -z "${GH_API_FAIL:-}" ]] || exit 1
  echo "${GH_HAS_ISSUES:-true}"
  exit 0
fi
if [[ "$1 $2" == "issue create" && -n "${GH_CREATE_FAIL:-}" ]]; then
  printf 'GraphQL: was submitted too quickly (createIssue)\nsecond line\n' >&2
  exit 1
fi
if [[ "$1 $2" == "issue create" && -n "${GH_CREATE_FAIL_HOST:-}" && "$*" == *" packages failed to check "* ]]; then
  printf 'GraphQL: body is too long (maximum is 65536 characters)\n' >&2
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
  ".[].title") [[ -z "$titles" ]] || printf '%s\n' "$titles" ;;
  *) exit 2 ;;
esac
EOF
  printf '#!/bin/sh\nexit 97\n' >"$bin/sudo"
  chmod +x "$bin/gh" "$bin/sudo"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  BODY_LOG="$BATS_TEST_TMPDIR/body.log"
  GH_BODY_LOG="$BATS_TEST_TMPDIR/gh-body.log"
  : >"$GH_LOG"
  : >"$BODY_LOG"
  : >"$GH_BODY_LOG"
  step_run issues "Create issues" >"$BATS_TEST_TMPDIR/step.sh"
  run env -C "$ws" PATH="$bin:$PATH" GH_LOG="$GH_LOG" BODY_LOG="$BODY_LOG" GH_TITLES="${GH_TITLES:-}" \
    GH_FAIL="${GH_FAIL:-}" GH_HAS_ISSUES="${GH_HAS_ISSUES:-}" GH_API_FAIL="${GH_API_FAIL:-}" \
    GH_CREATE_FAIL="${GH_CREATE_FAIL:-}" GH_CREATE_FAIL_HOST="${GH_CREATE_FAIL_HOST:-}" GITHUB_REPOSITORY=owner/fork \
    GH_BODY_LOG="$GH_BODY_LOG" BIG_BODY="${BIG_BODY:-}" RUN_URL=https://example.invalid/run sh -e "$BATS_TEST_TMPDIR/step.sh"
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
  grep -qx 'issue create --title ✋ foo: update held --label update-held --body-file -' "$GH_LOG"
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
  grep -qx 'issue create --title 🔔 foo: 29+1 notice --label update-notice --body-file -' "$GH_LOG"
  grep -qx 'issue create --title 🔔 bar: 1.0 notice --label update-notice --body-file -' "$GH_LOG"
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
  grep -qx 'issue create --title 🚀 aurtomator 0.7.0 available --label aurtomator-update --body-file -' "$GH_LOG"
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
  grep -qx 'issue create --title ⚠️ foo: 28+23 without aarch64 riscv64 --label arch-missing --body-file -' "$GH_LOG"
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
# whose check failed on host $2, and the pair of its line of _hosts
host_failures() {
  local i
  for ((i = 1; i <= $1; i++)); do
    printf '%s\n' "$3$i=check_failed: https://$2/repos/o/$3$i/tags: The requested URL returned error: 503" \
      "_hosts=$3$i"$'\t'"$2"
  done
}

@test "check-updates: 5 packages whose check failed on one host share one issue" {
  local pairs
  mapfile -t pairs < <(host_failures 5 api.github.com a)
  run_issue_step "${pairs[@]}" b="check_failed: https://github.com/o/b: error: 503" c="update_failed: boom"
  [ "$status" -eq 0 ]
  grep -qx 'issue create --title ❌ api.github.com: 5 packages failed to check --label auto-update --body-file -' "$GH_LOG"
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

# Unchecked packages leave fewer failures of the host than HOST_ISSUE_MIN, and its issue stays open
@test "check-updates: opens no issue of a package whose host has an open issue" {
  local pairs
  mapfile -t pairs < <(host_failures 3 api.github.com a)
  GH_TITLES="❌ api.github.com: 5 packages failed to check" run_issue_step "${pairs[@]}" \
    "a4=unchecked: the check ran out of its 20 minutes in this run" "a5=unchecked: the check ran out of its 20 minutes in this run" \
    b="check_failed: https://github.com/o/b: error: 503" c="update_failed: https://api.github.com/x: error: 503"
  [ "$status" -eq 0 ]
  grep -q '^issue create --title ❌ b: check failed ' "$GH_LOG"
  grep -q '^issue create --title ❌ c: update failed ' "$GH_LOG"
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "2" ]
}

@test "check-updates: only the title of the host issue holds it back" {
  local pairs
  mapfile -t pairs < <(host_failures 5 api.github.com a)
  GH_TITLES=$'❌ apixgithubxcom: 9 packages failed to check\n❌ api.github.com: 9 packages failed to check twice\n❌ api.github.com: many packages failed to check' \
    run_issue_step "${pairs[@]}"
  [ "$status" -eq 0 ]
  grep -qx 'issue create --title ❌ api.github.com: 5 packages failed to check --label auto-update --body-file -' "$GH_LOG"
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

# Packages of a refused host issue would get no issue at all
@test "check-updates: the packages of a refused host issue get issues of their own" {
  local pairs
  mapfile -t pairs < <(host_failures 5 api.github.com a)
  GH_CREATE_FAIL_HOST=1 run_issue_step "${pairs[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Could not create the issue ❌ api.github.com: 5 packages failed to check: GraphQL: body is too long"* ]]
  run grep -c '^issue create --title ❌ a[1-5]: check failed ' "$GH_LOG"
  [ "$output" = "5" ]
}

# Linux refuses one argument over 128 KiB, and the 60000 characters of a host issue can take
# three times as many bytes
@test "check-updates: gh gets the body of an issue on stdin" {
  local pairs
  mapfile -t pairs < <(host_failures 5 api.github.com a)
  BIG_BODY=1 run_issue_step "${pairs[@]}"
  [ "$status" -eq 0 ]
  grep -qx 'issue create --title ❌ api.github.com: 5 packages failed to check --label auto-update --body-file -' "$GH_LOG"
  [ "$(cat "$GH_BODY_LOG")" = 180000 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "1" ]
}

# awk compares two fields that look like numbers as numbers, and 1e2 and 100 are both 100
@test "check-updates: opens no notice issue from the alerts of another package" {
  run_issue_step 1e2="updated: 2.0" _alerts=$'100\tnotice\tCheck the old line'
  [ "$status" -eq 0 ]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: a refused issue gives a warning with the error of gh" {
  GH_CREATE_FAIL=1 run_issue_step foo="update_failed: boom" bar="held: 1.0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Could not create the issue ❌ foo: update failed: GraphQL: was submitted too quickly (createIssue) second line"* ]]
  [[ "$output" == *"::warning::Could not create the issue ✋ bar: update held: GraphQL: was submitted too quickly (createIssue) second line"* ]]
}

# Runs the close step of the issues job with the name=status pairs as statuses; gh lists the
# issues of $GH_OPEN and logs to $GH_LOG, and the issue functions log to $BODY_LOG
run_close_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin" pair
  mkdir -p "$ws/.status" "$ws/aurtomator/scripts" "$bin"
  printf 'set -euo pipefail\nsource %q\n' "$BATS_TEST_DIRNAME/../scripts/lib/issue.sh" >"$ws/aurtomator/scripts/lib.sh"
  cat >>"$ws/aurtomator/scripts/lib.sh" <<'EOF'
close_comment() { echo "close_comment $*" >>"$BODY_LOG" && echo comment; }
arch_close_comment() { echo "arch_close_comment $*" >>"$BODY_LOG" && echo comment; }
EOF
  rm -f "$ws/.status/_hosts"
  for pair in "$@"; do
    # Each failed check adds its line to _hosts
    if [[ "${pair%%=*}" == _hosts ]]; then
      printf '%s\n' "${pair#*=}" >>"$ws/.status/_hosts"
    else
      printf '%s\n' "${pair#*=}" >"$ws/.status/${pair%%=*}"
    fi
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
  step_run issues "${CLOSE_STEP:-Close resolved issues}" >"$BATS_TEST_TMPDIR/step.sh"
  run env -C "$ws" PATH="$bin:$PATH" GH_LOG="$GH_LOG" BODY_LOG="$BODY_LOG" GH_OPEN="${GH_OPEN:-}" GH_FAIL="${GH_FAIL:-}" \
    GH_HAS_ISSUES="${GH_HAS_ISSUES:-}" GITHUB_REPOSITORY=owner/fork RUN_OK="${RUN_OK:-true}" \
    RUN_URL=https://example.invalid/run sh -e "$BATS_TEST_TMPDIR/step.sh"
}

# Repository at $BATS_TEST_TMPDIR/ws with README.md and two package YAMLs, and the copies that
# Hand over took from builder in $BATS_TEST_TMPDIR/results, with the given file=text edits
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

# Users can have git sign every commit, which would start their pinentry from these tests
@test "workflows: the commits of the tests read no git config of the user" {
  local home="$BATS_TEST_TMPDIR/user-home"
  mkdir -p "$home"
  printf '[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = false\n' >"$home/.gitconfig"
  HOME="$home" XDG_CONFIG_HOME="$home/.config" make_commit_repo
  [ "$(git -C "$BATS_TEST_TMPDIR/ws" log --format=%s)" = init ]
}

# The tree of HEAD in the repository of make_commit_repo, as gh lists it,
# with the sha of file $1 replaced, or $1 left out when $2 is "gone"
moved_tree() {
  git -C "$BATS_TEST_TMPDIR/ws" ls-tree -r HEAD | awk -v f="$1" -v how="${2:-}" '
    $4 == f { if (how == "gone") next; $3 = "0123456789012345678901234567890123456789" }
    { print $4 " " $3 }'
}

# Runs the commit step of publish in the repository of make_commit_repo; gh takes the head of main
# and its tree from $GH_HEAD and $GH_TREE, or from HEAD without them, and logs to $GH_LOG
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
# gh answers with the JSON of the API and applies --jq to it. Recursive
# trees also list each directory, as an entry of type tree.
case "$endpoint" in
  "repos/owner/fork/git/ref/heads/${GH_REF:-main}") json="{\"object\": {\"sha\": \"$GH_HEAD\", \"type\": \"commit\"}}" ;;
  repos/owner/fork/git/commits/*) json='{"tree": {"sha": "tree-of-head"}}' ;;
  "repos/owner/fork/git/trees/tree-of-head?recursive=1")
    [[ -z "${GH_TREE_FAIL:-}" ]] || exit 1
    json=$(jq -Rn '[inputs | select(length > 0) | capture("^(?<path>.*) (?<sha>[0-9a-f]+)$") | . + {type: "blob"}] as $blobs |
      [$blobs[].path | split("/") | range(1; length) as $i | .[:$i] | join("/")] | unique |
      {sha: "tree-of-head", tree: (map({path: ., type: "tree", sha: "0000000000000000000000000000000000000000"}) + $blobs)}' <<<"$GH_TREE")
    ;;
  repos/owner/fork/git/blobs)
    sha=$(tail -n 1 "$GH_LOG.blobs" | jq -r .content | command -p base64 -d | git hash-object --stdin)
    json="{\"sha\": \"$sha\"}"
    ;;
  repos/owner/fork/git/trees)
    echo "inputs: $inputs" >>"$GH_LOG"
    json='{"sha": "tree"}'
    ;;
  repos/owner/fork/git/commits) json='{"sha": "commit"}' ;;
  "repos/owner/fork/git/refs/heads/${GH_REF:-main}") json='{}' ;;
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
  run env -C "$ws" PATH="$bin:$PATH" GH_LOG="$GH_LOG" SUDO_LOG="$SUDO_LOG" REPO=owner/fork BRANCH="${COMMIT_BRANCH:-main}" GH_REF="${GH_REF:-main}" \
    GH_HEAD="${GH_HEAD:-$(git -C "$ws" rev-parse HEAD)}" GH_TREE_FAIL="${GH_TREE_FAIL:-}" \
    GH_TREE="${GH_TREE:-$(git -C "$ws" ls-tree -r HEAD | awk '{ print $4 " " $3 }')}" \
    RESULTS="$BATS_TEST_TMPDIR/results" GIT_TEST_ASSUME_DIFFERENT_OWNER=1 sh -e "$BATS_TEST_TMPDIR/step.sh"
}

MOVED=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# Fails when gh got a call that matches $1. It is a function, because bats does
# not fail a test on a negated command that is not the last one.
no_call() {
  ! grep -q -e "$1" "$GH_LOG"
}

# Fails when the commit step wrote a blob or moved the branch
no_commit() {
  no_call "git/blobs" && no_call "git/refs/heads/main "
}

@test "check-updates: the commit step commits on the head it checked out" {
  make_commit_repo README.md="new table" packages/foo.yml="current: 2.0"
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
  jq -e --arg sha "$(git hash-object --stdin <"$BATS_TEST_TMPDIR/results/README.md")" '.base_tree == "tree-of-head" and .tree == [{"path": "README.md", "mode": "100644", "type": "blob", "sha": $sha}]' "$GH_LOG.tree"
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

# Without pipefail a failed base64 hands jq no input, and gh writes an empty blob
@test "check-updates: the commit step stops on a blob that differs from the file" {
  make_commit_repo README.md="new table"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/base64"
  chmod +x "$BATS_TEST_TMPDIR/bin/base64"
  run_commit_step
  [ "$status" -ne 0 ]
  no_call "git/trees "
  no_call "git/refs/heads/main "
}

# Blobs would turn a tracked link into a file
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
  grep -qF -- "-f message=chore: update package statuses [skip ci] " "$GH_LOG"
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
  jq -e --arg sha "$(git hash-object --stdin <"$BATS_TEST_TMPDIR/ws/aurtomator/aurtomator.sh")" '.tree == [{"path": "aurtomator.sh", "mode": "100755", "type": "blob", "sha": $sha}]' "$GH_LOG.tree"
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

@test "check-updates: the commit step names the runner beside the package statuses" {
  make_runner_repo "old runner" "new runner" README.md="new table"
  run_commit_step
  [ "$status" -eq 0 ]
  jq -e '[.tree[] | [.path, .mode]] == [["README.md", "100644"], ["aurtomator.sh", "100755"]]' "$GH_LOG.tree"
  grep -qF -- "-f message=chore: update package statuses and aurtomator.sh [skip ci] " "$GH_LOG"
}

@test "check-updates: a commit of README.md alone is a commit of the statuses" {
  make_commit_repo README.md="new table"
  run_commit_step
  [ "$status" -eq 0 ]
  jq -e '[.tree[].path] == ["README.md"]' "$GH_LOG.tree"
  grep -qF -- "-f message=chore: update package statuses [skip ci] " "$GH_LOG"
}

@test "check-updates: a commit with a package YAML is a commit of the versions" {
  make_commit_repo README.md="new table" packages/foo.yml="current: 2.0" stats/events.csv=journal
  run_commit_step
  [ "$status" -eq 0 ]
  grep -qF -- "-f message=chore: update package versions [skip ci] " "$GH_LOG"
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

# Paths under a file would replace that file in the tree, and those under a
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
  [[ "$output" == *"Close resolved issues,Close resolved host issues,Create issues" ]]
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

# Changes that leave the package table alone skip publish and still open
# or close an issue
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

# Publish jobs that fail before the step of builder upload no statuses, and a download of id 0 fails
@test "check-updates: the issues job reads the statuses of publish when it uploaded them, else those of check" {
  local upload="\${{ steps.decide.outputs.packages == 'true' && 'error' || 'ignore' }}"
  run yq -o=json -I=0 '[.jobs.issues.steps[] | select(.uses | test("^actions/download-artifact@")) | [.with["artifact-ids"], .with.path, .if]]' "$CHECK_UPDATES"
  [ "$output" = "[[\"$(id_of check checked)\",\".status\",\"(needs.publish.result == 'skipped' || needs.publish.outputs.published-id == '') && needs.check.outputs.checked-id != ''\"],[\"$(id_of publish published)\",\".status\",\"needs.publish.result != 'skipped' && needs.publish.outputs.published-id != ''\"]]" ]
  run yq -o=json -I=0 '.jobs.publish.steps[] | select(.with.name == "published") | [.with.path, .if, .with["if-no-files-found"]]' "$CHECK_UPDATES"
  [ "$output" = '["/data/statuses/","always()","error"]' ]
  run yq '.jobs.publish.steps[] | select(.name == "Hand over") | .if' "$CHECK_UPDATES"
  [ "$output" = "always() && steps.stop.outcome == 'success'" ]
  run yq -o=json -I=0 '.jobs.check.steps[] | select(.name == "Upload statuses") | [.with.name, .with.path, .with["if-no-files-found"]]' "$CHECK_UPDATES"
  [ "$output" = "[\"checked\",\"/data/statuses/\",\"$upload\"]" ]
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
  for step in "Write the run summary" "Close resolved issues" "Close resolved host issues" "Create issues"; do
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

# Packages without a YAML get no check, so no status of a later run closes their issues
@test "check-updates: the close step closes the issues of a package whose YAML is gone" {
  GH_OPEN=$'1 ❌ gone: update failed\n2 ✋ gone: update held\n3 ⚠️ gone: 1.2 without aarch64\n4 ❌ kept: check failed' \
    run_close_step kept="check_failed: boom" _packages=kept
  [ "$status" -eq 0 ]
  grep -qxF 'issue close 1 --comment `packages/gone.yml` is gone as of https://example.invalid/run.' "$GH_LOG"
  grep -q '^issue close 2 ' "$GH_LOG"
  grep -q '^issue close 3 ' "$GH_LOG"
  run grep -c '^issue close 4 ' "$GH_LOG"
  [ "$output" = "0" ]
}

# The names of the AUR, and titles that only look like those a run writes, names
# the AUR refuses included
@test "check-updates: the close step reads the package of each title exactly" {
  GH_OPEN=$'1 ❌ foo.bar: check failed\n2 ❌ x: update failed\n3 ❌ Foo-Bin: check failed\n4 ✋ c++: update held\n5 ⚠️ a@b_c: 1.0 without aarch64\n6 ❌ foo: check failed\n7 ❌ foo bar: check failed\n8 ❌ gone: check failed again\n9 Re: ❌ gone: check failed\n10 ✋ gone: update held twice\n11 ⚠️ gone: 1.0 without' \
    run_close_step "_packages="$'fooxbar\nfoo-bin'
  [ "$status" -eq 0 ]
  local n
  for n in 1 2 4 6; do
    grep -q "^issue close $n " "$GH_LOG" || {
      echo "kept $n"
      return 1
    }
  done
  run grep -c -E '^issue close (3|5|7|8|9|10|11) ' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: the close step finds an arch issue of a removed package behind 30 others" {
  local i
  GH_OPEN="$(for i in {1..31}; do echo "$i ⚠️ pkg$i: 1.0 without aarch64"; done)" run_close_step _packages=kept
  [ "$status" -eq 0 ]
  grep -q '^issue close 31 ' "$GH_LOG"
}

@test "check-updates: the close step keeps the issues of every package without _packages" {
  GH_OPEN='1 ❌ gone: update failed' run_close_step kept=up_to_date
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "0" ]
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

# Upstream outages and rate limits must not close the issue, or the next
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

# Hundreds of open issues and of packages would make it start programs by the ten thousand
@test "check-updates: the close step starts no program for each pair of open issue and package" {
  local bin="$BATS_TEST_TMPDIR/bin" tool
  mkdir -p "$bin"
  for tool in cat basename; do
    printf '#!/bin/sh\necho %s >>"%s"\nexec /usr/bin/%s "$@"\n' "$tool" "$BATS_TEST_TMPDIR/tools.log" "$tool" >"$bin/$tool"
    chmod +x "$bin/$tool"
  done
  GH_OPEN=$'11 ❌ foo: check failed\n12 ❌ bar: update failed\n13 ✋ baz: update held' \
    run_close_step foo=up_to_date bar=up_to_date baz="updated: 2.0" qux=up_to_date
  [ "$status" -eq 0 ]
  [ "$(grep -c '^issue close' "$GH_LOG")" -eq 3 ]
  [ ! -s "$BATS_TEST_TMPDIR/tools.log" ]
}

@test "check-updates: closes the issue of a host once fewer than 5 of its packages failed to check" {
  local pairs
  mapfile -t pairs < <(host_failures 4 api.github.com a && host_failures 5 apixgithub.com x && host_failures 5 cdn.gitlab.com y)
  GH_OPEN=$'21 ❌ api.github.com: 6 packages failed to check\n22 ❌ apixgithub.com: 5 packages failed to check\n23 ❌ gitlab.com: 7 packages failed to check\n24 ❌ gitlab.com: many packages failed to check' \
    CLOSE_STEP="Close resolved host issues" run_close_step "${pairs[@]}" _packages=a1
  [ "$status" -eq 0 ]
  grep -qx 'issue close 21 --comment Fewer than 5 packages of `api.github.com` failed to check in https://example.invalid/run.' "$GH_LOG"
  grep -qx 'issue close 23 --comment Fewer than 5 packages of `gitlab.com` failed to check in https://example.invalid/run.' "$GH_LOG"
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "2" ]
}

# Packages the check did not reach in this run tell nothing about their host
@test "check-updates: closes no host issue in a run that left a package unchecked" {
  local pairs
  mapfile -t pairs < <(host_failures 4 api.github.com a)
  GH_OPEN=$'21 ❌ api.github.com: 6 packages failed to check\n22 ❌ late: check failed' \
    CLOSE_STEP="Close resolved host issues" run_close_step "${pairs[@]}" _packages=late "late=unchecked: the check ran out of its 20 minutes in this run"
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "check-updates: an unchecked line in the error of a failed check closes host issues all the same" {
  local pairs
  mapfile -t pairs < <(host_failures 4 api.github.com a)
  GH_OPEN=$'21 ❌ api.github.com: 6 packages failed to check' CLOSE_STEP="Close resolved host issues" \
    run_close_step "${pairs[@]}" _packages=b $'b=check_failed: fatal: remote error: access denied\nunchecked: x'
  [ "$status" -eq 0 ]
  grep -qx 'issue close 21 --comment Fewer than 5 packages of `api.github.com` failed to check in https://example.invalid/run.' "$GH_LOG"
}

# Failed publish runs leave the check statuses, and the failing packages of a host under the
# minimum get their issues in the same run once its host issue is closed
@test "check-updates: closes host issues after a failed publish, before the issue step" {
  local pairs
  run yq '.jobs.issues.steps[] | select(.name == "Close resolved host issues") | .if' "$CHECK_UPDATES"
  [ "$output" = "always() && steps.clean.outcome == 'success'" ]
  [ "$(step_index issues "Close resolved host issues")" -lt "$(step_index issues "Create issues")" ]
  run yq '.jobs.issues.steps[] | select(.name == "Close resolved issues") | .run' "$CHECK_UPDATES"
  [[ "$output" != *host_close_comment* ]]
  mapfile -t pairs < <(host_failures 2 api.github.com a)
  GH_OPEN=$'21 ❌ api.github.com: 6 packages failed to check' CLOSE_STEP="Close resolved host issues" run_close_step "${pairs[@]}" _packages=a1
  [ "$status" -eq 0 ]
  grep -qx 'issue close 21 --comment Fewer than 5 packages of `api.github.com` failed to check in https://example.invalid/run.' "$GH_LOG"
}

# check-all.sh writes _packages after its loop, so a publish that its job stops leaves none
@test "check-updates: closes no host issue on statuses without _packages" {
  local pairs
  mapfile -t pairs < <(host_failures 2 api.github.com a)
  GH_OPEN=$'21 ❌ api.github.com: 6 packages failed to check' CLOSE_STEP="Close resolved host issues" run_close_step "${pairs[@]}"
  [ "$status" -eq 0 ]
  run grep -c '^issue close' "$GH_LOG"
  [ "$output" = "0" ]
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

# awk compares two fields that look like numbers as numbers, and 1e2 and 100 are both 100
@test "check-updates: closes the arch issue of a package when _without lists another one alone" {
  GH_OPEN=$'12 ⚠️ 1e2: 2.0 without aarch64' run_close_step 1e2=up_to_date 100=up_to_date _without=$'100\t1.0\taarch64'
  [ "$status" -eq 0 ]
  grep -qx 'issue close 12 --comment comment' "$GH_LOG"
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
  GH_OPEN=$'12 ⚠️ foo bar: 1.0 without aarch64\n13 ⚠️ `x`: 1.0 without aarch64\n14 ⚠️ no colon\n15 ⚠️ Foo: 1.0 without aarch64\n16 ⚠️ _x: 1.0 without aarch64' \
    run_close_step _without=
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
  [ "$output" = "/data/upload/" ]
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
  [ "$output" = "$(id_of check checked) /data/status" ]
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
  run env AUR_SSH_KEY= PATH="$bin:$PATH" sh -e "$step"
  [ "$status" -eq 1 ]
  [ "$output" = "::error::The secret AUR_SSH_KEY is empty" ]
  [ ! -e "$ssh_dir" ]
  run env AUR_SSH_KEY=key-text PATH="$bin:$PATH" sh -e "$step"
  [ "$status" -eq 0 ]
  [ "$(cat "$ssh_dir/aur")" = "key-text" ]
  [ -f "$ssh_dir/known_hosts" ]
}

# Runs Setup AUR SSH with AUR_SSH_KEY=key-text and $BATS_TEST_TMPDIR/ssh in place of its SSH_DIR;
# the test above pins the directory of the step, and this helper reads it from SSH_DIR
run_setup_ssh_step() {
  local step="$BATS_TEST_TMPDIR/step.sh" bin="$BATS_TEST_TMPDIR/bin" block dir
  block=$(step_run publish "Setup AUR SSH")
  dir=$(sed -n 's/^ *SSH_DIR="\(.*\)"$/\1/p' <<<"$block")
  [ -n "$dir" ]
  printf '%s\n' "${block//"$dir"/"$BATS_TEST_TMPDIR/ssh"}" >"$step"
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 0\n' >"$bin/chown"
  chmod +x "$bin/chown"
  run env AUR_SSH_KEY=key-text PATH="$bin:$PATH" sh -e "$step"
}

# ssh waits for a silent host as long as TCP does, minutes past the timeout of a publish
@test "check-updates: Setup AUR SSH gives up a connection after 30 seconds" {
  run_setup_ssh_step
  [ "$status" -eq 0 ]
  grep -qx '  ConnectTimeout 30' "$BATS_TEST_TMPDIR/ssh/config"
}

# https://aur.archlinux.org lists the Ed25519 host key as SHA256:RFzBCUItH9LZS0cKB5UE6ceAYhBD5C8GeOBip8Z11+4
@test "check-updates: Setup AUR SSH trusts the AUR host key alone and keeps the key to builder" {
  local ssh_dir="$BATS_TEST_TMPDIR/ssh"
  run_setup_ssh_step
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$ssh_dir" "$ssh_dir/aur")" = $'700\n600' ]
  run ssh-keygen -lf "$ssh_dir/known_hosts"
  [ "$output" = "256 SHA256:RFzBCUItH9LZS0cKB5UE6ceAYhBD5C8GeOBip8Z11+4 aur.archlinux.org (ED25519)" ]
  grep -qx '  StrictHostKeyChecking yes' "$ssh_dir/config"
}

# Runs before setup secrets push nothing and commit the README
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
  mkdir -p "$BATS_TEST_TMPDIR/ws" "$BATS_TEST_TMPDIR/data"
  step_run publish "Find packages to push" >"$BATS_TEST_TMPDIR/step.sh"
  : >"$BATS_TEST_TMPDIR/output"
  (cd "$BATS_TEST_TMPDIR/ws" && DATA="$BATS_TEST_TMPDIR/data" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" sh -e "$BATS_TEST_TMPDIR/step.sh")
  cat "$BATS_TEST_TMPDIR/output"
}

@test "check-updates: the issues job writes the run summary before it touches an issue" {
  local write
  write=$(step_index issues "Write the run summary")
  [ "$write" -gt "$(step_index issues "Download statuses of publish")" ]
  [ "$write" -lt "$(step_index issues "Close resolved issues")" ]
}

# Runs Write the run summary with the name=status pairs as statuses and aurtomator/ linked to
# this repository, and prints the summary
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
  local dir="$BATS_TEST_TMPDIR/data/handoff"
  # Pull requests can commit handoff/, which publish never reads
  mkdir -p "$BATS_TEST_TMPDIR/ws/handoff/prepared/foo"
  echo pkgbuild >"$BATS_TEST_TMPDIR/ws/handoff/prepared/foo/PKGBUILD"
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

# Writes the step Close files to builder to $BATS_TEST_TMPDIR/step.sh with the mounts of the runner
# it closes under $BATS_TEST_TMPDIR/mnt, so a run in CI changes no mount of its own job
close_files_step() {
  local mnt="$BATS_TEST_TMPDIR/mnt"
  step_run check "Close files to builder" |
    sed -e "s|for dir in /__t /github/home /github/workflow;|for dir in $mnt/t $mnt/home $mnt/workflow;|" \
      -e "s|for dir in /github/home /github/workflow \"\$RUNNER_TEMP\";|for dir in $mnt/home $mnt/workflow $mnt/temp;|" \
      >"$BATS_TEST_TMPDIR/step.sh"
  grep -qF "for dir in $mnt/t $mnt/home $mnt/workflow;" "$BATS_TEST_TMPDIR/step.sh"
  grep -qF "for dir in $mnt/home $mnt/workflow $mnt/temp;" "$BATS_TEST_TMPDIR/step.sh"
}

# PKGBUILD code of prepare runs as builder, which needs aurtomator/ alone
@test "check-updates: Close files to builder leaves rights to others on aurtomator/ alone" {
  local ws="$BATS_TEST_TMPDIR/ws" data="$BATS_TEST_TMPDIR/data" outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$ws/packages" "$ws/.git" "$ws/aurtomator/scripts"
  echo "name: foo" >"$ws/packages/foo.yml"
  echo readme >"$ws/README.md"
  echo code >"$ws/aurtomator/scripts/check-all.sh"
  echo outside >"$outside"
  ln -s "$outside" "$ws/link"
  chmod 0755 "$ws" "$ws/packages" "$ws/.git" "$ws/aurtomator" "$ws/aurtomator/scripts" "$ws/aurtomator/scripts/check-all.sh"
  chmod 0644 "$ws/packages/foo.yml" "$ws/README.md" "$outside"
  close_files_step
  run env -C "$ws" DATA="$data" sh -e "$BATS_TEST_TMPDIR/step.sh"
  [ "$status" -eq 0 ]
  run stat -c '%n %a' "$ws" "$data" "$ws/packages" "$ws/packages/foo.yml" "$ws/README.md" "$ws/.git" \
    "$ws/aurtomator" "$ws/aurtomator/scripts" "$ws/aurtomator/scripts/check-all.sh" "$outside"
  [ "$output" = "$(printf '%s\n' "$ws 711" "$data 700" "$ws/packages 700" "$ws/packages/foo.yml 600" \
    "$ws/README.md 600" "$ws/.git 700" "$ws/aurtomator 755" "$ws/aurtomator/scripts 755" \
    "$ws/aurtomator/scripts/check-all.sh 755" "$outside 644")" ]
}

# The tool cache, the home of the steps and the event files are mounts of the runner
@test "check-updates: Close files to builder takes write access of group and others from the runner mounts" {
  local ws="$BATS_TEST_TMPDIR/ws" mnt="$BATS_TEST_TMPDIR/mnt" outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$ws" "$mnt/t/node/bin" "$mnt/home" "$mnt/workflow"
  echo tool >"$mnt/t/node/bin/node"
  echo event >"$mnt/workflow/event.json"
  echo outside >"$outside"
  ln -s "$outside" "$mnt/home/link"
  chmod 0777 "$mnt/t" "$mnt/t/node" "$mnt/home" "$mnt/workflow"
  chmod 0775 "$mnt/t/node/bin"
  chmod 0666 "$mnt/t/node/bin/node" "$mnt/workflow/event.json" "$outside"
  close_files_step
  run env -C "$ws" DATA="$BATS_TEST_TMPDIR/data" sh -e "$BATS_TEST_TMPDIR/step.sh"
  [ "$status" -eq 0 ]
  run stat -c '%n %a' "$mnt/t" "$mnt/t/node" "$mnt/t/node/bin" "$mnt/t/node/bin/node" "$mnt/home" \
    "$mnt/workflow" "$mnt/workflow/event.json" "$outside"
  [ "$output" = "$(printf '%s\n' "$mnt/t 755" "$mnt/t/node 755" "$mnt/t/node/bin 755" "$mnt/t/node/bin/node 644" \
    "$mnt/home 700" "$mnt/workflow 700" "$mnt/workflow/event.json 644" "$outside 666")" ]
}

# The event of the run, the home of the steps, and the step scripts and file commands in
# RUNNER_TEMP stay with root, which still reads and writes them
@test "check-updates: Close files to builder takes every right of group and others from the event, home and temp" {
  local ws="$BATS_TEST_TMPDIR/ws" mnt="$BATS_TEST_TMPDIR/mnt"
  mkdir -p "$ws" "$mnt/home" "$mnt/workflow" "$mnt/temp/_runner_file_commands"
  echo event >"$mnt/workflow/event.json"
  echo "set -e" >"$mnt/temp/step.sh"
  chmod 0755 "$mnt/home" "$mnt/workflow" "$mnt/temp" "$mnt/temp/_runner_file_commands"
  chmod 0644 "$mnt/workflow/event.json" "$mnt/temp/step.sh"
  close_files_step
  run env -C "$ws" DATA="$BATS_TEST_TMPDIR/data" RUNNER_TEMP="$mnt/temp" sh -e "$BATS_TEST_TMPDIR/step.sh"
  [ "$status" -eq 0 ]
  run stat -c '%n %a' "$mnt/home" "$mnt/workflow" "$mnt/temp" "$mnt/temp/_runner_file_commands" "$mnt/temp/step.sh"
  [ "$output" = "$(printf '%s\n' "$mnt/home 700" "$mnt/workflow 700" "$mnt/temp 700" \
    "$mnt/temp/_runner_file_commands 755" "$mnt/temp/step.sh 644")" ]
}

@test "check-updates: each job with a checkout closes its files before downloads and builder" {
  local job at key
  for job in check prepare verify publish; do
    echo "$job"
    at=$(step_index "$job" "Close files to builder")
    [ "$at" -eq $(($(step_index "$job" "Checkout aurtomator") + 1)) ]
    [ "$(step_run "$job" "Close files to builder")" = "$(step_run check "Close files to builder")" ]
    run yq ".jobs.$job.steps | to_entries[] | select(.value.uses // \"\" | test(\"^actions/download-artifact@|run-as-builder\$\")) | .key" "$CHECK_UPDATES"
    [ "${#lines[@]}" -gt 0 ]
    for key in "${lines[@]}"; do
      [ "$key" -gt "$at" ]
    done
  done
  run yq '[.jobs.issues.steps[] | select(.name == "Close files to builder")] | length' "$CHECK_UPDATES"
  [ "$output" = "0" ]
}

# Pull requests can commit any directory into the checkout, and the jobs that check it out
# read and write the files of the run under /data alone
@test "check-updates: the jobs with a checkout keep the files of the run in /data" {
  run yq '[(.jobs.check, .jobs.prepare, .jobs.verify, .jobs.publish) | .steps[] |
    select(.uses // "" | test("^actions/(up|down)load-artifact@")) | .with.path] |
    (length | tostring) + " " + (map(test("^/data/[a-z-]+/?$")) | all | tostring)' "$CHECK_UPDATES"
  [ "$output" = "9 true" ]
  run yq '[.jobs[].steps[] | select(.uses // "" | test("run-as-builder$")) | .with | (.statuses, .handoff) | select(.)] |
    sort | unique | join(",")' "$CHECK_UPDATES"
  [ "$output" = "/data/handoff,/data/status" ]
  run yq '[.jobs[].steps[] | select(.env.DATA) | .env.DATA] | unique | join(",")' "$CHECK_UPDATES"
  [ "$output" = "/data" ]
}

# Runs Setup GPG with GPG_SIGNING_KEY=$1 in a new keyring; sudo runs the command of
# -u builder as the test user, and the agent has no pinentry
run_setup_gpg_step() {
  local bin="$BATS_TEST_TMPDIR/bin" home="$BATS_TEST_TMPDIR/home"
  rm -rf "$home"
  mkdir -p "$bin" "$home/gnupg"
  chmod 0700 "$home/gnupg"
  echo "pinentry-program /usr/bin/false" >"$home/gnupg/gpg-agent.conf"
  printf '#!/usr/bin/env bash\n[[ "$1 $2" == "-u builder" ]] || exit 97\nshift 2\nexec "$@"\n' >"$bin/sudo"
  chmod +x "$bin/sudo"
  step_run publish "Setup GPG" >"$BATS_TEST_TMPDIR/step.sh"
  : >"$BATS_TEST_TMPDIR/env"
  run env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_CONFIG_HOME -u GIT_CONFIG_GLOBAL PATH="$bin:$PATH" HOME="$home" \
    GNUPGHOME="$home/gnupg" GITHUB_ENV="$BATS_TEST_TMPDIR/env" GPG_SIGNING_KEY="$1" sh -e "$BATS_TEST_TMPDIR/step.sh"
  gpgconf --homedir "$home/gnupg" --kill gpg-agent 2>/dev/null || true
}

# Prints the armored key $2 of a new key: secret, public or protected
make_gpg_key() {
  local dir="$BATS_TEST_TMPDIR/keys-$1" pass=() rc=0
  mkdir -m 0700 "$dir"
  [[ "$1" != protected ]] || pass=(--passphrase secret)
  GNUPGHOME="$dir" gpg --batch --pinentry-mode loopback --passphrase "${pass[1]:-}" \
    --quick-gen-key "Lab <lab@example.invalid>" ed25519 sign never >/dev/null 2>&1 || rc=$?
  if [[ "$1" == public ]]; then
    GNUPGHOME="$dir" gpg --batch --armor --export || rc=$?
  else
    GNUPGHOME="$dir" gpg --batch --pinentry-mode loopback --passphrase "${pass[1]:-}" --armor --export-secret-keys || rc=$?
  fi
  gpgconf --homedir "$dir" --kill gpg-agent 2>/dev/null || true
  return "$rc"
}

@test "check-updates: Setup GPG takes the ID of a secret key that signs" {
  local key
  key=$(make_gpg_key secret)
  run_setup_gpg_step "$key"
  [ "$status" -eq 0 ]
  [[ "$(<"$BATS_TEST_TMPDIR/env")" =~ ^GPG_KEY_ID=[0-9A-F]{16}$ ]]
  [ "$(env -u XDG_CONFIG_HOME -u GIT_CONFIG_GLOBAL HOME="$BATS_TEST_TMPDIR/home" git config --global user.signingkey)" = \
    "$(cut -d= -f2 "$BATS_TEST_TMPDIR/env")" ]
}

# Public key blocks import with no secret key, and git would then sign nothing
@test "check-updates: Setup GPG fails on a secret with no key that can sign" {
  local kind key
  for kind in public protected junk; do
    echo "$kind"
    key=junk
    [[ "$kind" == junk ]] || key=$(make_gpg_key "$kind")
    run_setup_gpg_step "$key"
    [ "$status" -eq 1 ]
    if [[ "$kind" == junk ]]; then
      [[ "$output" == *"::error::gpg could not import GPG_SIGNING_KEY"* ]]
    else
      [[ "$output" == *"::error::GPG_SIGNING_KEY holds no secret key that can sign"* ]]
    fi
    [ ! -s "$BATS_TEST_TMPDIR/env" ]
  done
}

# GPG_KEY_ID goes to GITHUB_ENV, where a value of another form could set other variables
@test "check-updates: Setup GPG takes a key ID of 16 hex digits alone" {
  local id bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat >"$bin/gpg" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "--batch --with-colons --list-secret-keys" ]]; then
  printf 'sec:u:255:22:%s:1700000000::::::scESC:::+:::23::0:\n' "$FAKE_ID"
else
  cat >/dev/null
fi
EOF
  chmod +x "$bin/gpg"
  for id in ABCD 0123456789abcdef 0123456789ABCDEF0 ''; do
    echo "$id"
    export FAKE_ID="$id"
    run_setup_gpg_step key
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::GPG_SIGNING_KEY holds no secret key that can sign"* ]]
    [ ! -s "$BATS_TEST_TMPDIR/env" ]
  done
  export FAKE_ID=0123456789ABCDEF
  run_setup_gpg_step key
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/env")" = GPG_KEY_ID=0123456789ABCDEF ]
}

# Branch names can hold # and %, which a URL path reads as a fragment and an escape
@test "check-updates: the commit step escapes the branch in the paths of the API" {
  make_commit_repo README.md="new table"
  COMMIT_BRANCH='fix/a#b%cü' GH_REF='fix/a%23b%25c%C3%BC' run_commit_step
  [ "$status" -eq 0 ]
  grep -qxF "api repos/owner/fork/git/ref/heads/fix/a%23b%25c%C3%BC --jq .object.sha" "$GH_LOG"
  grep -qxF "api repos/owner/fork/git/refs/heads/fix/a%23b%25c%C3%BC -f sha=commit -F force=false --method PATCH" "$GH_LOG"
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

# Runs the step of notify-failure for run 7 of owner/fork; gh lists the open issues from
# $GH_TITLES and the failed jobs from $GH_JOBS, and logs every call to $GH_LOG
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
  "api repos/owner/fork/actions/runs/7/jobs?per_page=100")
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
  grep -qF 'on ``` fix`@owner`` ``` failed in `check`' "$GH_LOG"
}

@test "notify-failure: opens an issue that names the run and its failed jobs" {
  GH_JOBS=$'check\npublish' run_notify_step
  [ "$status" -eq 0 ]
  grep -q '^issue create --title ❌ Check AUR Package Updates failed --label auto-update --body ' "$GH_LOG"
  grep -q 'https://example.invalid/runs/7' "$GH_LOG"
  grep -qF 'failed in `check`, `publish`' "$GH_LOG"
  grep -q 'until a run succeeds, and that run closes this issue\.$' "$GH_LOG"
}

@test "notify-failure: names the jobs that failed or timed out" {
  GH_JOBS_JSON='{"jobs":[{"name":"check","conclusion":"failure"},{"name":"verify","conclusion":"timed_out"},{"name":"publish","conclusion":"skipped"},{"name":"status","conclusion":"success"}]}' run_notify_step
  [ "$status" -eq 0 ]
  grep -qF 'failed in `check`, `verify`' "$GH_LOG"
}

# GitHub gives a job stopped by timeout-minutes the conclusion `cancelled`, as one canceled by hand
@test "notify-failure: names a canceled job that ran for its timeout-minutes" {
  GH_JOBS_JSON='{"jobs":[
    {"name":"pins","conclusion":"cancelled","runner_name":"GitHub Actions 2","started_at":"2026-11-13T09:55:00Z","completed_at":"2026-11-13T09:59:10Z"},
    {"name":"check-updates / check","conclusion":"cancelled","runner_name":"GitHub Actions 3","started_at":"2026-11-13T10:00:00Z","completed_at":"2026-11-13T10:30:40Z"},
    {"name":"check-updates / prepare (demo)","conclusion":"cancelled","runner_name":"GitHub Actions 4","started_at":"2026-11-13T10:00:00Z","completed_at":"2026-11-13T10:02:00Z"},
    {"name":"check-updates / status","conclusion":"cancelled","runner_name":"GitHub Actions 5","started_at":"2026-11-13T10:00:00Z","completed_at":"2026-11-13T10:09:10Z"}]}' run_notify_step
  [ "$status" -eq 0 ]
  grep -qF 'failed in `pins`, `check-updates / check`, `check-updates / status`.' "$GH_LOG"
  grep -q -- '--paginate' "$GH_LOG"
}

# GitHub can end a run with a job that never got a runner and has no conclusion; the notify job
# itself runs while it reads the list
@test "notify-failure: names a job that never left the queue" {
  GH_JOBS_JSON='{"jobs":[
    {"name":"check-updates / check","status":"completed","conclusion":"success"},
    {"name":"check-updates / status","status":"queued","conclusion":null,"runner_name":null,"started_at":"2026-11-14T10:00:00Z","completed_at":null},
    {"name":"notify / notify","status":"in_progress","conclusion":null,"runner_name":"GitHub Actions 9","started_at":"2026-11-14T10:40:00Z","completed_at":null}]}' run_notify_step
  [ "$status" -eq 0 ]
  grep -qF 'failed in `check-updates / status`.' "$GH_LOG"
}

# The AUR takes a package name that starts with @, which outside a code span mentions a user
@test "notify-failure: names a failed job of a package in a code span" {
  GH_JOBS_JSON='{"jobs":[{"name":"check-updates / prepare (@owner)","conclusion":"failure"}]}' run_notify_step
  [ "$status" -eq 0 ]
  grep -qF 'failed in `check-updates / prepare (@owner)`.' "$GH_LOG"
}

@test "notify-failure: opens nothing for jobs canceled before their timeout-minutes" {
  GH_JOBS_JSON='{"jobs":[{"name":"check-updates / check","conclusion":"cancelled","runner_name":"GitHub Actions 2","started_at":"2026-11-13T10:00:00Z","completed_at":"2026-11-13T10:12:00Z"}]}' run_notify_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::No job of the run failed, so the canceled run gets no issue"* ]]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}

# GitHub gives a job canceled in the queue the time it was created as its start
@test "notify-failure: opens nothing for a job canceled while it waited for a runner" {
  GH_JOBS_JSON='{"jobs":[{"name":"check-updates / check","conclusion":"cancelled","runner_name":null,"created_at":"2026-11-13T10:00:00Z","started_at":"2026-11-13T10:00:00Z","completed_at":"2026-11-13T10:31:00Z"}]}' run_notify_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::No job of the run failed, so the canceled run gets no issue"* ]]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}

# Jobs canceled while they waited for a runner have no start
@test "notify-failure: opens nothing for a job canceled before it started" {
  GH_JOBS_JSON='{"jobs":[{"name":"check-updates / check","conclusion":"cancelled","started_at":null,"completed_at":"2026-11-13T10:40:00Z"}]}' run_notify_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::No job of the run failed, so the canceled run gets no issue"* ]]
  run grep -c '^issue create' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "notify-failure: knows the timeout-minutes of every job of check-updates.yml and of the job pins" {
  local workflow="$GITHUB_DIR/workflows/check-updates.yml" table calling="$BATS_TEST_TMPDIR/calling.yml"
  table=$(yq '.jobs.notify.steps[0].run' "$NOTIFY" | command grep -oE '\{"image": [^}]*\}')
  [ -n "$table" ]
  calling_workflow 1 >"$calling"
  [ "$(jq -cS . <<<"$table")" = "$({ yq -o=json '.jobs' "$workflow" && yq -o=json '{"pins": .jobs.pins}' "$calling"; } |
    jq -cS -s 'add | to_entries | map({(.value.name // .key): .value."timeout-minutes"}) | add')" ]
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

# Caller job `validate` shows them as `validate / image` and
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

# "the image job is the same in every workflow" leaves out the pin check and the repository and
# ref of the checkout, so this test compares the whole job with the one of check-updates.yml
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

SETUP_DOC="$BATS_TEST_DIRNAME/../site/src/content/docs/setup.md"

# Prints the inside of fenced yaml block $1, 1 or 2, of the section "The
# calling workflows" of the Setup page of the site
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
@test "template: the calling workflows of the Setup page pin the three files and grant what the jobs need" {
  local check="$BATS_TEST_TMPDIR/check-updates.yml" validate="$BATS_TEST_TMPDIR/validate.yml"
  local workflows=staticwire/aurtomator/.github/workflows
  calling_workflow 1 >"$check"
  calling_workflow 2 >"$validate"
  [ -s "$check" ]
  [ -s "$validate" ]

  # The job pins checks the pins before a job calls aurtomator
  run yq -o=json -I=0 '.jobs | keys' "$check"
  [ "$output" = '["pins","check-updates","notify"]' ]
  run yq '.jobs.check-updates.needs' "$check"
  [ "$output" = "pins" ]
  run yq -o=json -I=0 '.jobs | keys' "$validate"
  [ "$output" = '["pins","validate"]' ]
  run yq '.jobs.validate.needs' "$validate"
  [ "$output" = "pins" ]
  run yq -o=json -I=0 '.jobs.pins | del(.steps[0].uses)' "$check"
  [ "$output" = '{"runs-on":"ubuntu-latest","timeout-minutes":5,"permissions":{"contents":"read"},"steps":[{"with":{"persist-credentials":false,"fetch-depth":2}},{"run":"./aurtomator.sh check-pins"}]}' ]
  [ "$(yq -o=json -I=0 '.jobs.pins' "$validate")" = "$(yq -o=json -I=0 '.jobs.pins' "$check")" ]
  run yq '.jobs.pins.steps[0].uses' "$check"
  [[ "$output" =~ ^actions/checkout@[0-9a-f]{40}$ ]]
  run yq '.jobs.pins.steps[0].uses | line_comment' "$check"
  [[ "$output" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]]

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

# === check-updates.yml: Check builder ===

@test "check-updates: each job of builder checks what builder reaches right after it closes the files" {
  local job at
  for job in check prepare verify publish; do
    echo "$job"
    at=$(step_index "$job" "Close files to builder")
    run yq ".jobs.$job.steps[$((at + 1))].name" "$CHECK_UPDATES"
    [ "$output" = "Check builder" ]
    [ "$(step_run "$job" "Check builder")" = "$(step_run check "Check builder")" ]
  done
}

# The paths that builder may not write, in the order the step tests them,
# with the file commands under /fc
BUILDER_PATHS=(/fc/set_env /fc/add_path /fc/set_output /fc/step_summary /__w/_temp /__w/repo/repo
  /__w/repo/repo/aurtomator /__w /__w/_actions /__e /__t /github/home /github/workflow)
# The files and directories of the runner that builder may not read, in the order the step tests them
BUILDER_READ_PATHS=(/github/workflow/event.json /github/home /__w/_temp /fc/set_env /fc/add_path /fc/set_output
  /fc/step_summary)

# Runs the step Check builder; sudo logs each command it runs as builder to $CALLS/sudo, passes the
# tests in $REACH, "<flag>:<path>" separated by spaces, and its find prints $WRITABLE and exits $FIND_RC
run_check_builder_step() {
  local bin="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$bin" "$CALLS"
  rm -f "$CALLS/sudo"
  cat >"$bin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "-u builder" ]] || exit 97
shift 2
echo "$*" >>"$CALLS/sudo"
case "$1" in
  true) exit "$TRUE_RC" ;;
  test) [[ " $REACH " == *" $2:$3 "* ]] ;;
  find)
    [[ -z "$WRITABLE" ]] || echo "$WRITABLE"
    exit "$FIND_RC"
    ;;
  env) tr ' ' '\n' <<<"$BUILDER_ENV" | sed 's/$/=x/' ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$bin/sudo"
  step_run check "Check builder" >"$BATS_TEST_TMPDIR/step.sh"
  run env PATH="$bin:$PATH" CALLS="$CALLS" REACH="${REACH:-}" BUILDER_ENV="${BUILDER_ENV:-HOME PATH}" \
    WRITABLE="${WRITABLE:-}" FIND_RC="${FIND_RC:-0}" TRUE_RC="${TRUE_RC:-0}" \
    GITHUB_ENV=/fc/set_env GITHUB_PATH=/fc/add_path GITHUB_OUTPUT=/fc/set_output \
    GITHUB_STEP_SUMMARY=/fc/step_summary RUNNER_TEMP=/__w/_temp GITHUB_WORKSPACE=/__w/repo/repo \
    sh -e "$BATS_TEST_TMPDIR/step.sh"
}

@test "check-updates: Check builder passes when builder reaches nothing of the runner" {
  local expected=(true) path
  run_check_builder_step
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  for path in "${BUILDER_PATHS[@]}"; do
    expected+=("test -w $path")
  done
  expected+=("test -r /var/run/docker.sock" "test -w /var/run/docker.sock")
  expected+=("test -r /__w/repo/repo" "test -r /__w/repo/repo/README.md" "test -r /data")
  for path in "${BUILDER_READ_PATHS[@]}"; do
    expected+=("test -r $path")
  done
  expected+=("find /__w /__e /__t /github /__w/repo/repo/aurtomator ( -writable -print -quit ) -o ( -type d ( ! -readable -o ! -executable ) -prune )")
  expected+=(env)
  [ "$(cat "$CALLS/sudo")" = "$(printf '%s\n' "${expected[@]}")" ]
}

# Every test would pass when sudo itself fails
@test "check-updates: Check builder fails first thing when sudo cannot run a command as builder" {
  TRUE_RC=1 run_check_builder_step
  [ "$status" -eq 1 ]
  [ "$output" = "::error::sudo could not run a command as builder" ]
  [ "$(cat "$CALLS/sudo")" = true ]
}

@test "check-updates: Check builder fails when builder can write a file of the runner, after every test" {
  local path
  for path in "${BUILDER_PATHS[@]}"; do
    echo "$path"
    REACH="-w:$path" run_check_builder_step
    [ "$status" -eq 1 ]
    [ "$output" = "::error::builder passes test -w $path" ]
    [ "$(wc -l <"$CALLS/sudo")" -eq 28 ]
  done
}

# The event names the repository and the sender, and the step scripts and file commands hold
# what the steps before wrote
@test "check-updates: Check builder fails when builder can read the event, the home or the files of the steps" {
  local path
  for path in "${BUILDER_READ_PATHS[@]}"; do
    echo "$path"
    REACH="-r:$path" run_check_builder_step
    [ "$status" -eq 1 ]
    [ "$output" = "::error::builder passes test -r $path" ]
  done
}

@test "check-updates: Check builder fails when builder can read the checkout or the artifacts" {
  local path
  for path in /__w/repo/repo /__w/repo/repo/README.md /data; do
    echo "$path"
    REACH="-r:$path" run_check_builder_step
    [ "$status" -eq 1 ]
    [ "$output" = "::error::builder passes test -r $path" ]
  done
}

@test "check-updates: Check builder fails when builder can use the Docker socket" {
  local flag
  for flag in -r -w; do
    echo "$flag"
    REACH="$flag:/var/run/docker.sock" run_check_builder_step
    [ "$status" -eq 1 ]
    [ "$output" = "::error::builder passes test $flag /var/run/docker.sock" ]
  done
}

# Such as a directory of the tool cache that no test above names
@test "check-updates: Check builder fails when builder can write anything in the runner directories" {
  WRITABLE=/__t/node/22.0.0 run_check_builder_step
  [ "$status" -eq 1 ]
  [ "$output" = "::error::builder can write /__t/node/22.0.0" ]
}

@test "check-updates: Check builder fails when find cannot search the runner directories as builder" {
  FIND_RC=1 run_check_builder_step
  [ "$status" -eq 1 ]
  [ "$output" = "::error::find could not search /__w, /__e, /__t, /github and /__w/repo/repo/aurtomator as builder" ]
}

@test "check-updates: Check builder fails when sudo passes a variable of the runner to builder" {
  local name
  for name in GITHUB_TOKEN ACTIONS_RUNTIME_TOKEN RUNNER_TEMP; do
    echo "$name"
    BUILDER_ENV="HOME $name PATH" run_check_builder_step
    [ "$status" -eq 1 ]
    [ "$output" = "::error::sudo passes $name to builder" ]
  done
}
