#!/usr/bin/env bats

# The runner pastes an expression into a run script before bash parses it,
# so a step reads GitHub context through env: instead.

@test "workflows: no run block expands an expression" {
  local workflow
  for workflow in "$BATS_TEST_DIRNAME"/../.github/workflows/*.yml; do
    echo "$workflow"
    run yq '.jobs[].steps[] | select(has("run")) | .run' "$workflow"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" != *'${{'* ]]
  done
}
