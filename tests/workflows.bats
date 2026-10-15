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
