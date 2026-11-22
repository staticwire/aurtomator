#!/usr/bin/env bash
# Mock git for the bats tests: clones of https://aur.archlinux.org/ URLs get an empty repo of the
# test directory, which the AUR serves for a package it lacks; other arguments run /usr/bin/git

if [[ "${1:-}" == clone ]] && (($# >= 3)) && [[ "${*: -2:1}" == https://aur.archlinux.org/* ]]; then
  empty="$TEST_TMPDIR/aur-empty.git"
  [[ -d "$empty" ]] || /usr/bin/git init -q --bare -b master "$empty" || exit 128
  exec /usr/bin/git clone "${@:2:$#-3}" "file://$empty" "${@: -1}"
fi
exec /usr/bin/git "$@"
