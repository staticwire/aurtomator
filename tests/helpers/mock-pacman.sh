#!/usr/bin/env bash
# Mock pacman for the bats tests: answers -Si python with MOCK_PYTHON_VERSION or fails with
# MOCK_PYTHON_FAIL set, -Fx from MOCK_PACMAN_FILES, -Sddp and -Si from MOCK_PACMAN_SYNC
set -euo pipefail

# Print "name version repo provides" of the line of MOCK_PACMAN_SYNC for name $1, or for a word
# of its provides; fail when no line names it
sync_line() {
  local name version repo provides pass
  for pass in name provides; do
    while read -r name version repo provides; do
      if [[ "$pass" == name && "$name" == "$1" ]] || [[ "$pass" == provides && " $provides " == *" $1 "* ]]; then
        printf '%s %s %s %s\n' "$name" "$version" "$repo" "$provides"
        return 0
      fi
    done <"${MOCK_PACMAN_SYNC:-/dev/null}"
  done
  return 1
}

case "$*" in
  "-Si python" | "-Fx --machinereadable "* | "-Sddp --print-format "*) ;;
  -Si\ *) [[ -n "${MOCK_PACMAN_SYNC:-}" ]] || exec /usr/bin/pacman "$@" ;;
  *) exec /usr/bin/pacman "$@" ;;
esac
# Tests that count the questions to pacman name a file for them in PACMAN_ARGS_LOG
[[ -z "${PACMAN_ARGS_LOG:-}" ]] || printf '%s\n' "$*" >>"$PACMAN_ARGS_LOG"

# Lines of MOCK_PACMAN_FILES are repo, pkgname, pkgver and path, split by tabs; pacman matches
# the path without regard to case and splits the fields of an answer by NUL
if [[ "$1" == -Fx ]]; then
  if [[ -n "${MOCK_PACMAN_NO_FILES:-}" ]]; then
    echo "warning: database file for 'core' does not exist (use '-Fy' to download)" >&2
    echo "warning: database file for 'extra' does not exist (use '-Fy' to download)" >&2
    exit 1
  fi
  found=1
  shopt -s nocasematch
  while IFS=$'\t' read -r repo pkgname pkgver path; do
    if [[ "$path" =~ $3 ]]; then
      printf '%s\0%s\0%s\0%s\n' "$repo" "$pkgname" "$pkgver" "$path"
      found=0
    fi
  done <"${MOCK_PACMAN_FILES:-/dev/null}"
  exit "$found"
fi

if [[ "$1" == -Sddp ]]; then
  if ! line=$(sync_line "${*: -1}"); then
    echo "error: target not found: ${*: -1}" >&2
    exit 1
  fi
  read -r name version repo _ <<<"$line"
  out=${3//%n/$name}
  out=${out//%v/$version}
  printf '%s\n' "${out//%r/$repo}"
  exit 0
fi

if [[ "$2" != python ]]; then
  if ! line=$(sync_line "$2"); then
    echo "error: package '$2' was not found" >&2
    exit 1
  fi
  read -r name version repo provides <<<"$line"
  printf '%s\n' "Repository      : $repo" "Name            : $name" "Version         : $version" \
    "Provides        : ${provides:-None}"
  exit 0
fi
if [[ -n "${MOCK_PYTHON_FAIL:-}" ]]; then
  echo "error: package 'python' was not found" >&2
  exit 1
fi
printf '%s\n' "Repository      : core" "Name            : python" \
  "Version         : ${MOCK_PYTHON_VERSION:-3.14.10-1}" "Description     : The Python programming language"
