#!/usr/bin/env bash
# Mock pacman for the bats tests: answers -Si python with MOCK_PYTHON_VERSION or fails with
# MOCK_PYTHON_FAIL set, and runs /usr/bin/pacman for any other arguments
set -euo pipefail

if [[ "$*" != "-Si python" ]]; then
  exec /usr/bin/pacman "$@"
fi
# Tests that count the questions to pacman name a file for them in PACMAN_ARGS_LOG
[[ -z "${PACMAN_ARGS_LOG:-}" ]] || printf '%s\n' "$*" >>"$PACMAN_ARGS_LOG"
if [[ -n "${MOCK_PYTHON_FAIL:-}" ]]; then
  echo "error: package 'python' was not found" >&2
  exit 1
fi
printf '%s\n' "Repository      : core" "Name            : python" \
  "Version         : ${MOCK_PYTHON_VERSION:-3.14.10-1}" "Description     : The Python programming language"
