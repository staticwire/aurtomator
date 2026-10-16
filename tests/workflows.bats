#!/usr/bin/env bats

GITHUB_DIR="$BATS_TEST_DIRNAME/../.github"

# Prints the run blocks of every step in workflow $1
run_blocks() {
  yq '.jobs[].steps[] | select(has("run")) | .run' "$1"
}

# The runner pastes an expression into a run script before bash parses it,
# so a step reads GitHub context through env: instead.
@test "workflows: no run block expands an expression" {
  local workflow
  for workflow in "$GITHUB_DIR"/workflows/*.yml; do
    echo "$workflow"
    run run_blocks "$workflow"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" != *'${{'* ]]
  done
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

# === check-updates.yml: who decides what ===

CHECK_UPDATES="$GITHUB_DIR/workflows/check-updates.yml"

# Prints the run block of step $2 in job $1 of check-updates.yml
step_run() {
  yq ".jobs.$1.steps[] | select(.name == \"$2\") | .run" "$CHECK_UPDATES"
}

@test "check-updates: the check job decides the run and executes no PKGBUILD" {
  run yq '.jobs.check.steps[] | select(has("run")) | .run' "$CHECK_UPDATES"
  [ "$status" -eq 0 ]
  [[ "$output" == *"./scripts/check-all.sh"* ]]
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
  printf '#!/bin/sh\n[ -z "$README_CHANGED" ]\n' >"$bin/git"
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
}

@test "check-updates: Decide publishes only a change of the status table" {
  README_CHANGED=1 run run_decide_step pkg="check_failed: API down"
  [ "$status" -eq 0 ]
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

# Prints job and step name, tab-separated, of every step that runs
# check-all.sh, which runs as builder
builder_steps() {
  yq '.jobs | to_entries[] | .key as $job | .value.steps[] |
    select((.run // "") | test("scripts/check-all.sh")) | $job + "\t" + .name' "$CHECK_UPDATES"
}

# Runs step $2 of job $1 in the shell the step names. sudo records its
# arguments and environment in $SUDO_LOG, prints $SUDO_OUT on stdout and
# stderr, leaves two processes behind that print $LATE_OUT after it exits,
# one holding only stdout and one only stderr, and exits with $SUDO_RC.
# chown and git do nothing.
run_builder_step() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 0\n' >"$bin/chown"
  printf '#!/bin/sh\nexit 0\n' >"$bin/git"
  cat >"$bin/sudo" <<'EOF'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; env; } >>"$SUDO_LOG"
printf '%s\n' "$SUDO_OUT"
printf '%s\n' "$SUDO_OUT" >&2
if [[ -n "${LATE_OUT:-}" ]]; then
  (exec 2>/dev/null && sleep 0.5 && printf '%s\n' "$LATE_OUT") &
  (exec >/dev/null && sleep 1 && printf '%s\n' "$LATE_OUT" >&2) &
fi
exit "${SUDO_RC:-0}"
EOF
  chmod +x "$bin/chown" "$bin/git" "$bin/sudo"
  run yq ".jobs.$1.steps[] | select(.name == \"$2\") | .shell" "$CHECK_UPDATES"
  [ "$output" = "bash" ]
  step_run "$1" "$2" >"$BATS_TEST_TMPDIR/step.sh"
  rm -f "$SUDO_LOG"
  run env PATH="$bin:$PATH" GITHUB_WORKSPACE="$BATS_TEST_TMPDIR" SUDO_LOG="$SUDO_LOG" \
    bash --noprofile --norc -eo pipefail "$BATS_TEST_TMPDIR/step.sh"
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

# Runs the issue step of publish in a workspace with the statuses given as
# name=status pairs. gh lists the titles in $GH_TITLES, one per line, as
# every open issue whatever --search asks for, the first 30 unless --limit
# says otherwise, and logs every call to $GH_LOG.
run_issue_step() {
  local ws="$BATS_TEST_TMPDIR/ws" bin="$BATS_TEST_TMPDIR/bin" pair
  mkdir -p "$ws/.status" "$bin"
  for pair in "$@"; do
    printf '%s\n' "${pair#*=}" >"$ws/.status/${pair%%=*}"
  done
  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
[[ "$1 $2" == "issue list" ]] || exit 0
[[ -z "${GH_FAIL:-}" ]] || exit 1
limit=30 jq_expr=""
while (($#)); do
  case "$1" in
    --limit) limit=$2 && shift ;;
    --jq) jq_expr=$2 && shift ;;
  esac
  shift
done
titles=$(grep -v '^$' <<<"${GH_TITLES:-}" | head -n "$limit")
case "$jq_expr" in
  length) grep -c . <<<"$titles" ;;
  ".[].title") [[ -z "$titles" ]] || printf '%s\n' "$titles" ;;
  *) exit 2 ;;
esac
EOF
  printf '#!/bin/sh\necho body\n' >"$bin/sudo"
  chmod +x "$bin/gh" "$bin/sudo"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : >"$GH_LOG"
  step_run publish "Create issues for failed packages" >"$BATS_TEST_TMPDIR/step.sh"
  run env -C "$ws" PATH="$bin:$PATH" GH_LOG="$GH_LOG" GH_TITLES="${GH_TITLES:-}" \
    GH_FAIL="${GH_FAIL:-}" RUN_URL=https://example.invalid/run sh -e "$BATS_TEST_TMPDIR/step.sh"
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

@test "check-updates: verify runs as builder and hands over as prepare does" {
  run step_run verify "Verify checksums"
  [[ "$output" == *"sudo -u builder ./scripts/check-all.sh --verify handoff"* ]]
  [ "$(step_run verify "Hand over")" = "$(step_run prepare "Hand over")" ]
  run yq '[.jobs.verify.steps[].name] | join(",")' "$CHECK_UPDATES"
  [[ "$output" == *"Verify checksums,Hand over,Upload verified handoff"* ]]
  run yq '.jobs.verify.steps[] | select(.name == "Upload verified handoff") | .with.path' "$CHECK_UPDATES"
  [ "$output" = "upload/" ]
}

@test "check-updates: the publish step gets no GitHub token" {
  run step_run publish "Publish updates"
  [ "$status" -eq 0 ]
  [[ "$output" != *GITHUB_TOKEN* ]]
  run yq '.jobs.publish.steps[] | select(.name == "Publish updates") | .env | has("GITHUB_TOKEN")' "$CHECK_UPDATES"
  [ "$output" = "false" ]
}

@test "check-updates: publish takes the statuses from the check job" {
  run yq '.jobs.publish.steps[] | select(.with.name == "checked") | .with.path' "$CHECK_UPDATES"
  [ "$output" = ".status" ]
  run yq '.jobs.publish.steps[] | select(.with.name == "verified") | .if' "$CHECK_UPDATES"
  [ "$output" = "needs.verify.result == 'success'" ]
}
