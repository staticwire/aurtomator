# shellcheck shell=bash source-path=SCRIPTDIR/../..
# Sourced by draft.tape: the test environment of tests/draft.bats with a made-up
# hello-bin in a local AUR. No errexit, which would end the shell of the recording.

source tests/helpers/setup.sh
setup_test_env
cp "$TESTS_DIR/helpers/mock-git.sh" "$MOCK_DIR/git"
chmod +x "$MOCK_DIR/git"
git config --global url."file://$TEST_TMPDIR/aur/".insteadOf https://aur.archlinux.org/

demo_work="$TEST_TMPDIR/aur-work/hello-bin"
mkdir -p "$demo_work" "$TEST_TMPDIR/aur"
printf '%s\n' 'pkgbase = hello-bin' $'\tpkgver = 1.4.2' $'\tpkgrel = 1' \
  $'\turl = https://github.com/acme/hello' \
  $'\tsource = hello-1.4.2-x86_64.tar.gz::https://github.com/acme/hello/releases/download/v1.4.2/hello-1.4.2-x86_64.tar.gz' \
  '' 'pkgname = hello-bin' >"$demo_work/.SRCINFO"
printf 'true\n' >"$demo_work/PKGBUILD"
git -C "$demo_work" init -q
git -C "$demo_work" add -A
git -C "$demo_work" -c user.name=demo -c user.email=demo@example.invalid commit -q -m init
git clone -q --bare "$demo_work" "$TEST_TMPDIR/aur/hello-bin.git"

# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'command="$1"' 'shift' \
  'AURTOMATOR_RUNNER=./aurtomator.sh exec "$AURTOMATOR_DIR/scripts/$command.sh" "$@"' \
  >"$TEST_TMPDIR/aurtomator.sh"
chmod +x "$TEST_TMPDIR/aurtomator.sh"
cd "$TEST_TMPDIR" || return
PS1='$ '
