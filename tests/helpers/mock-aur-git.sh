#!/usr/bin/env bash
# Mock git for the bats tests: AUR clones get the repo of aur_srcinfo_remote for the name, or the
# empty repo that the AUR serves for a package it lacks; other arguments run /usr/bin/git

if [[ "${1:-}" == clone ]] && (($# >= 3)) && [[ "${*: -2:1}" == https://aur.archlinux.org/* ]]; then
  name=${*: -2:1}
  name=${name#https://aur.archlinux.org/}
  remote="$TEST_TMPDIR/aur-remote/${name%.git}.git"
  if [[ "$name" == */* || ! -d "$remote" ]]; then
    remote="$TEST_TMPDIR/aur-empty.git"
    [[ -d "$remote" ]] || /usr/bin/git init -q --bare -b master "$remote" || exit 128
  fi
  exec /usr/bin/git clone "${@:2:$#-3}" "file://$remote" "${@: -1}"
fi
exec /usr/bin/git "$@"
