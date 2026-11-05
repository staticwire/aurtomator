#!/usr/bin/env bats

load helpers/setup.sh

setup() {
  setup_test_env
  cp "$TESTS_DIR/helpers/mock-git.sh" "$MOCK_DIR/git"
  chmod +x "$MOCK_DIR/git"
  # https://aur.archlinux.org/<name>.git is $TEST_TMPDIR/aur/<name>.git
  git config --global url."file://$TEST_TMPDIR/aur/".insteadOf https://aur.archlinux.org/
  mkdir -p "$TEST_TMPDIR/aur"
}

teardown() {
  teardown_test_env
}

# Publishes the AUR package $1, whose .SRCINFO holds pkgver $2 and the
# "key = value" lines after it in the pkgbase section. Its PKGBUILD leaves
# a mark when it runs.
aur_package() {
  local name="$1" version="$2" work="$TEST_TMPDIR/aur-work/$1" line
  shift 2
  mkdir -p "$work"
  {
    printf 'pkgbase = %s\n\tpkgver = %s\n\tpkgrel = 1\n' "$name" "$version"
    for line in "$@"; do
      printf '\t%s\n' "$line"
    done
    printf '\npkgname = %s\n' "$name"
  } >"$work/.SRCINFO"
  printf 'touch %q\n' "$TEST_TMPDIR/pkgbuild-ran" >"$work/PKGBUILD"
  git -C "$work" init -q
  git -C "$work" add -A
  git -C "$work" -c user.name=t -c user.email=t@example.invalid commit -q -m init
  git clone -q --bare "$work" "$TEST_TMPDIR/aur/$name.git"
}

# Fails unless packages/$1.yml holds the lines after $1
expect_yaml() {
  local name="$1"
  shift
  [ "$(cat "$TEST_TMPDIR/packages/$name.yml")" = "$(printf '%s\n' "$@")" ]
}

# A git-latest strategy that prints r12.def5678 and clones nothing
stub_git_latest() {
  rm -f "$TEST_TMPDIR/strategies/git-latest.sh"
  printf '#!/bin/sh\necho r12.def5678\n' >"$TEST_TMPDIR/strategies/git-latest.sh"
  chmod +x "$TEST_TMPDIR/strategies/git-latest.sh"
}

@test "draft: a release download on GitHub gives github-release" {
  aur_package demo 1.0.0 'url = https://demo.example.org' \
    'source = demo-1.0.0.tar.gz::https://github.com/o/demo/releases/download/v1.0.0/demo-1.0.0.tar.gz'
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 0 ]
  expect_yaml demo 'name: demo' 'strategy: github-release' 'upstream:' '  project: o/demo' 'current: 1.0.0'
  [[ "$output" == *"packages/demo.yml: github-release from https://github.com/o/demo/releases/download/v1.0.0/demo-1.0.0.tar.gz"$'\n'"  name: demo"$'\n'"  strategy: github-release"* ]]
  [[ "$output" == *"demo: valid"* ]]
  [[ "$output" == *"demo: update available 1.0.0 → 2.0.0"* ]]
}

@test "draft: an archive on GitHub gives github-tag" {
  aur_package demo 1.0.0 'source = https://github.com/o/demo/archive/refs/tags/v1.0.0.tar.gz'
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 0 ]
  expect_yaml demo 'name: demo' 'strategy: github-tag' 'upstream:' '  project: o/demo' 'current: 1.0.0'
}

@test "draft: a git source on GitHub gives git-latest for a -git package, else github-tag" {
  stub_git_latest
  aur_package demo-git r10.abc1234 'source = demo::git+https://github.com/o/demo.git#branch=develop'
  run "$TEST_TMPDIR/scripts/draft.sh" demo-git
  [ "$status" -eq 0 ]
  expect_yaml demo-git 'name: demo-git' 'strategy: git-latest' 'upstream:' '  type: github' '  project: o/demo' '  branch: develop' 'current: r10.abc1234'
  [[ "$output" == *"demo-git: update available r10.abc1234 → r12.def5678"* ]]
  aur_package demo 1.0.0 'source = git+https://github.com/o/demo.git/?signed#tag=v1.0.0'
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 0 ]
  expect_yaml demo 'name: demo' 'strategy: github-tag' 'upstream:' '  project: o/demo' 'current: 1.0.0'
}

@test "draft: an archive path of GitLab gives gitlab-tag with the host and the full project" {
  aur_package demo 1.0.0 'source = https://gitlab.com/group/sub/demo/-/archive/v1.0.0/demo-v1.0.0.tar.gz'
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 0 ]
  expect_yaml demo 'name: demo' 'strategy: gitlab-tag' 'upstream:' '  host: gitlab.com' '  project: group/sub/demo' 'current: 1.0.0'
}

@test "draft: a git source on gitlab.com gives git-latest for a -git package, else gitlab-tag" {
  stub_git_latest
  aur_package demo-git r10.abc1234 'source = git+https://gitlab.com/group/demo.git'
  run "$TEST_TMPDIR/scripts/draft.sh" demo-git
  [ "$status" -eq 0 ]
  expect_yaml demo-git 'name: demo-git' 'strategy: git-latest' 'upstream:' '  type: gitlab' '  host: gitlab.com' '  project: group/demo' 'current: r10.abc1234'
  aur_package demo 1.0.0 'source = git+https://gitlab.com/group/demo.git#tag=v1.0.0'
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 0 ]
  expect_yaml demo 'name: demo' 'strategy: gitlab-tag' 'upstream:' '  host: gitlab.com' '  project: group/demo' 'current: 1.0.0'
}

@test "draft: a release download on Codeberg gives gitea-release" {
  aur_package demo 1.0.0 'source = https://codeberg.org/o/demo/releases/download/v1.0.0/demo-1.0.0.tar.gz'
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 0 ]
  expect_yaml demo 'name: demo' 'strategy: gitea-release' 'upstream:' '  host: codeberg.org' '  project: o/demo' 'current: 1.0.0'
}

@test "draft: an archive on Codeberg gives gitea-tag" {
  aur_package demo 1.0.0 'source = https://codeberg.org/o/demo/archive/v1.0.0.tar.gz'
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 0 ]
  expect_yaml demo 'name: demo' 'strategy: gitea-tag' 'upstream:' '  host: codeberg.org' '  project: o/demo' 'current: 1.0.0'
}

@test "draft: another git source gives git-latest for a -git package, else git-tag" {
  stub_git_latest
  aur_package demo-git r10.abc1234 'source = git+https://git.example.org/~owner/repo#branch=main'
  run "$TEST_TMPDIR/scripts/draft.sh" demo-git
  [ "$status" -eq 0 ]
  expect_yaml demo-git 'name: demo-git' 'strategy: git-latest' 'upstream:' '  type: git' '  url: https://git.example.org/~owner/repo' '  branch: main' 'current: r10.abc1234'
  aur_package demo 0.19 'source = git+https://git.example.org/~owner/repo#tag=v0.19'
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 0 ]
  expect_yaml demo 'name: demo' 'strategy: git-tag' 'upstream:' '  url: https://git.example.org/~owner/repo' 'current: "0.19"'
}

@test "draft: a source on PyPI gives pypi" {
  aur_package python-demo 1.0.0 'source = https://files.pythonhosted.org/packages/source/d/demo/demo-1.0.0.tar.gz'
  run "$TEST_TMPDIR/scripts/draft.sh" python-demo
  [ "$status" -eq 0 ]
  expect_yaml python-demo 'name: python-demo' 'strategy: pypi' 'upstream:' '  registry: demo' 'current: 1.0.0'
  aur_package python-other 1.0.0 'source = https://pypi.io/packages/source/O/Other.Name/Other.Name-1.0.0.tar.gz'
  run "$TEST_TMPDIR/scripts/draft.sh" python-other
  [ "$status" -eq 0 ]
  expect_yaml python-other 'name: python-other' 'strategy: pypi' 'upstream:' '  registry: Other.Name' 'current: 1.0.0'
}

@test "draft: a tarball of npm gives npm, with its scope" {
  aur_package nodejs-demo 1.0.0 'source = https://registry.npmjs.org/demo/-/demo-1.0.0.tgz'
  run "$TEST_TMPDIR/scripts/draft.sh" nodejs-demo
  [ "$status" -eq 0 ]
  expect_yaml nodejs-demo 'name: nodejs-demo' 'strategy: npm' 'upstream:' '  registry: demo' 'current: 1.0.0'
  aur_package nodejs-scoped 1.0.0 'source = https://registry.npmjs.org/@scope/demo/-/demo-1.0.0.tgz'
  run "$TEST_TMPDIR/scripts/draft.sh" nodejs-scoped
  [ "$status" -eq 0 ]
  expect_yaml nodejs-scoped 'name: nodejs-scoped' 'strategy: npm' 'upstream:' "  registry: '@scope/demo'" 'current: 1.0.0'
}

@test "draft: a crate gives crates" {
  aur_package demo 1.0.0 'source = demo-1.0.0.tar.gz::https://static.crates.io/crates/demo-rs/demo-rs-1.0.0.crate'
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 0 ]
  expect_yaml demo 'name: demo' 'strategy: crates' 'upstream:' '  registry: demo-rs' 'current: 1.0.0'
  aur_package other 1.0.0 'source = other-1.0.0.tar.gz::https://crates.io/api/v1/crates/other_rs/1.0.0/download'
  run "$TEST_TMPDIR/scripts/draft.sh" other
  [ "$status" -eq 0 ]
  expect_yaml other 'name: other' 'strategy: crates' 'upstream:' '  registry: other_rs' 'current: 1.0.0'
}

@test "draft: a KDE tarball in a directory of its version or series gives the path above it" {
  aur_package oxygen 6.9.5 'source = https://download.kde.org/stable/plasma/6.9.5/oxygen-6.9.5.tar.xz'
  run "$TEST_TMPDIR/scripts/draft.sh" oxygen
  [ "$status" -eq 0 ]
  expect_yaml oxygen 'name: oxygen' 'strategy: kde-tarball' 'upstream:' '  path: stable/plasma' 'current: 6.9.5'
  [[ "$output" == *"oxygen: update available 6.9.5 → 6.10.0"* ]]
  aur_package kio 6.9.0 'source = https://download.kde.org/stable/frameworks/6.9/kio-6.9.0.tar.xz'
  run "$TEST_TMPDIR/scripts/draft.sh" kio
  [ "$status" -eq 0 ]
  expect_yaml kio 'name: kio' 'strategy: kde-tarball' 'upstream:' '  path: stable/frameworks' 'current: 6.9.0'
  aur_package okular 26.08.1 'source = https://download.kde.org/stable/release-service/26.08.1/src/okular-26.08.1.tar.xz'
  run "$TEST_TMPDIR/scripts/draft.sh" okular
  [ "$status" -eq 0 ]
  expect_yaml okular 'name: okular' 'strategy: kde-tarball' 'upstream:' '  path: stable/release-service' 'current: 26.08.1'
}

@test "draft: a KDE tarball names only the project and the path that differ from the defaults" {
  aur_package kdiff3 1.12.5 'source = https://download.kde.org/stable/kdiff3/kdiff3-1.12.5.tar.xz'
  run "$TEST_TMPDIR/scripts/draft.sh" kdiff3
  [ "$status" -eq 0 ]
  expect_yaml kdiff3 'name: kdiff3' 'strategy: kde-tarball' 'current: 1.12.5'
  aur_package kio-s3 0.9.0 'source = https://download.kde.org/stable/kio.s3/kio.s3-0.9.0.tar.xz'
  run "$TEST_TMPDIR/scripts/draft.sh" kio-s3
  [ "$status" -eq 0 ]
  expect_yaml kio-s3 'name: kio-s3' 'strategy: kde-tarball' 'upstream:' '  project: kio.s3' 'current: 0.9.0'
  aur_package alkimia 8.1.76 'source = https://download.kde.org/unstable/alkimia/alkimia-8.1.76.tar.xz'
  run "$TEST_TMPDIR/scripts/draft.sh" alkimia
  [ "$status" -eq 0 ]
  expect_yaml alkimia 'name: alkimia' 'strategy: kde-tarball' 'upstream:' '  path: unstable/alkimia' 'current: 8.1.76'
}

@test "draft: a KDE tarball needs the pkgver in its name and a directory above its version" {
  local source i=0
  aur_package demo 1.0.0 'source = https://download.kde.org/stable/demo/demo-1.0.1.tar.xz'
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_TMPDIR/packages/demo.yml" ]
  for source in demo-1.0.0.tar.xz 1.0/src/demo-1.0.0.tar.xz src/demo-1.0.0.tar.xz /demo-1.0.0.tar.xz stable/demo/-1.0.0.tar.xz; do
    i=$((i + 1))
    aur_package "demo$i" 1.0.0 "source = https://download.kde.org/$source"
    run "$TEST_TMPDIR/scripts/draft.sh" "demo$i"
    [ "$status" -eq 1 ]
    [ ! -e "$TEST_TMPDIR/packages/demo$i.yml" ]
    [[ "$output" == *"No rule matches"* && "$output" != *"bad array subscript"* ]]
  done
}

@test "draft: the url gives github-tag, gitlab-tag or gitea-tag when no source matches" {
  aur_package demo 1.0.0 'url = https://github.com/o/demo.git#readme' 'source = https://demo.example.org/demo-1.0.0.tar.gz'
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 0 ]
  expect_yaml demo 'name: demo' 'strategy: github-tag' 'upstream:' '  project: o/demo' 'current: 1.0.0'
  [[ "$output" == *"github-tag from the url https://github.com/o/demo.git#readme"* ]]
  aur_package lab 1.0.0 'url = https://gitlab.com/group/sub/lab/-/tree/main'
  run "$TEST_TMPDIR/scripts/draft.sh" lab
  [ "$status" -eq 0 ]
  expect_yaml lab 'name: lab' 'strategy: gitlab-tag' 'upstream:' '  host: gitlab.com' '  project: group/sub/lab' 'current: 1.0.0'
  aur_package tea 1.0.0 'url = https://codeberg.org/o/tea/'
  run "$TEST_TMPDIR/scripts/draft.sh" tea
  [ "$status" -eq 0 ]
  expect_yaml tea 'name: tea' 'strategy: gitea-tag' 'upstream:' '  host: codeberg.org' '  project: o/tea' 'current: 1.0.0'
  aur_package lab2 1.0.0 'url = https://gitlab.com/group/lab2.git/'
  run "$TEST_TMPDIR/scripts/draft.sh" lab2
  [ "$status" -eq 0 ]
  expect_yaml lab2 'name: lab2' 'strategy: gitlab-tag' 'upstream:' '  host: gitlab.com' '  project: group/lab2' 'current: 1.0.0'
  aur_package one 1.0.0 'url = https://gitlab.com/one'
  run "$TEST_TMPDIR/scripts/draft.sh" one
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_TMPDIR/packages/one.yml" ]
}

@test "draft: the first source a rule matches decides, after local files and signatures" {
  aur_package demo 1.0.0 'url = https://codeberg.org/o/other' 'source = demo.patch' \
    'source = https://github.com/o/demo/releases/download/v1.0.0/demo-1.0.0.tar.gz.sig' \
    'source = demo.asc::https://github.com/o/demo/releases/download/v1.0.0/demo-1.0.0.tar.gz.asc?raw=1' \
    'source = https://demo.example.org/demo-1.0.0.tar.gz' \
    'source_x86_64 = https://github.com/o/demo/archive/v1.0.0.tar.gz' \
    'source_x86_64 = https://github.com/o/demo/releases/download/v1.0.0/demo-x86_64.tar.gz'
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 0 ]
  expect_yaml demo 'name: demo' 'strategy: github-tag' 'upstream:' '  project: o/demo' 'current: 1.0.0'
  [[ "$output" == *"github-tag from https://github.com/o/demo/archive/v1.0.0.tar.gz"* ]]
}

@test "draft: reads the pkgbase section of .SRCINFO alone" {
  aur_package demo 1.0.0 'url = https://demo.example.org' 'source = demo.desktop'
  printf '\turl = https://github.com/o/demo\n\tsource = https://github.com/o/demo/archive/v1.0.0.tar.gz\n' \
    >>"$TEST_TMPDIR/aur-work/demo/.SRCINFO"
  git -C "$TEST_TMPDIR/aur-work/demo" -c user.name=t -c user.email=t@example.invalid commit -qam pkgname
  rm -rf "$TEST_TMPDIR/aur/demo.git"
  git clone -q --bare "$TEST_TMPDIR/aur-work/demo" "$TEST_TMPDIR/aur/demo.git"
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_TMPDIR/packages/demo.yml" ]
}

@test "draft: writes no file when no rule matches, and names the url, the sources and the sample" {
  aur_package demo 1.0.0 'url = https://demo.example.org' 'source = https://demo.example.org/demo-1.0.0.tar.gz' 'source = demo.service'
  AURTOMATOR_RUNNER=./aurtomator.sh run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_TMPDIR/packages/demo.yml" ]
  [[ "$output" == *"No rule matches the url or a source of demo"* ]]
  [[ "$output" == *"url: https://demo.example.org"* ]]
  [[ "$output" == *"source: https://demo.example.org/demo-1.0.0.tar.gz"* ]]
  [[ "$output" == *"source: demo.service"* ]]
  [[ "$output" == *"./aurtomator.sh sample > packages/demo.yml"* ]]
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"cp $TEST_TMPDIR/packages/example.yml.sample $TEST_TMPDIR/packages/demo.yml"* ]]
}

@test "draft: stops when packages/ holds the YAML, and leaves it as it is" {
  aur_package demo 1.0.0 'source = https://github.com/o/demo/archive/v1.0.0.tar.gz'
  echo "name: mine" >"$TEST_TMPDIR/packages/demo.yml"
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/demo.yml exists already"* ]]
  [ "$(cat "$TEST_TMPDIR/packages/demo.yml")" = "name: mine" ]
  rm "$TEST_TMPDIR/packages/demo.yml"
  ln -s nowhere "$TEST_TMPDIR/packages/demo.yml"
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 1 ]
  [ "$(readlink "$TEST_TMPDIR/packages/demo.yml")" = nowhere ]
}

@test "draft: makes packages/ when it is missing" {
  aur_package demo 1.0.0 'source = https://github.com/o/demo/archive/v1.0.0.tar.gz'
  rm -rf "$TEST_TMPDIR/packages"
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 0 ]
  expect_yaml demo 'name: demo' 'strategy: github-tag' 'upstream:' '  project: o/demo' 'current: 1.0.0'
}

@test "draft: takes one argument that is a package name" {
  local name
  for name in "" ../demo -demo .demo "de mo" de/mo 'de$mo'; do
    run "$TEST_TMPDIR/scripts/draft.sh" "$name"
    [ "$status" -eq 1 ]
    [ "$output" = "Usage: $TEST_TMPDIR/scripts/draft.sh <pkgbase>" ]
  done
  AURTOMATOR_RUNNER=./aurtomator.sh run "$TEST_TMPDIR/scripts/draft.sh"
  [ "$status" -eq 1 ]
  [ "$output" = "Usage: ./aurtomator.sh draft <pkgbase>" ]
  run "$TEST_TMPDIR/scripts/draft.sh" demo other
  [ "$status" -eq 1 ]
  [ "$output" = "Usage: $TEST_TMPDIR/scripts/draft.sh <pkgbase>" ]
  [ -z "$(ls -A "$TEST_TMPDIR/packages")" ]
}

# A link could read a file of the user as .SRCINFO
@test "draft: reads no .SRCINFO that is a link" {
  aur_package demo 1.0.0 'source = https://github.com/o/demo/archive/v1.0.0.tar.gz'
  local work="$TEST_TMPDIR/aur-work/demo"
  mv "$work/.SRCINFO" "$work/SRCINFO.real"
  ln -s SRCINFO.real "$work/.SRCINFO"
  git -C "$work" add -A
  git -C "$work" -c user.name=t -c user.email=t@example.invalid commit -qm link
  rm -rf "$TEST_TMPDIR/aur/demo.git"
  git clone -q --bare "$work" "$TEST_TMPDIR/aur/demo.git"
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"The .SRCINFO of demo is no regular file"* ]]
  [ ! -e "$TEST_TMPDIR/packages/demo.yml" ]
  ln -sf missing "$work/.SRCINFO"
  git -C "$work" add -A
  git -C "$work" -c user.name=t -c user.email=t@example.invalid commit -qm dangling
  rm -rf "$TEST_TMPDIR/aur/demo.git"
  git clone -q --bare "$work" "$TEST_TMPDIR/aur/demo.git"
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"The .SRCINFO of demo is no regular file"* ]]
}

# The AUR answers an unknown name with an empty repository
@test "draft: stops when the AUR has no such package" {
  git init -q --bare "$TEST_TMPDIR/aur/demo.git"
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"No AUR package demo"* ]]
  [ ! -e "$TEST_TMPDIR/packages/demo.yml" ]
}

@test "draft: writes the values of .SRCINFO into the YAML as text and never runs the PKGBUILD" {
  aur_package demo '1.0.0$(touch pwned)' "source = git+https://git.example.org/~owner/\$(touch pwned)\"x'"
  cd "$TEST_TMPDIR"
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 1 ]
  [ "$(yq '.current' "$TEST_TMPDIR/packages/demo.yml")" = '1.0.0$(touch pwned)' ]
  [ "$(yq '.upstream.url' "$TEST_TMPDIR/packages/demo.yml")" = "https://git.example.org/~owner/\$(touch pwned)\"x'" ]
  [ ! -e "$TEST_TMPDIR/pwned" ]
  [ ! -e "$TEST_TMPDIR/pkgbuild-ran" ]
}

@test "draft: warns about an epoch other than 0" {
  aur_package demo 1.0.0 'epoch = 2' 'source = https://github.com/o/demo/archive/v1.0.0.tar.gz'
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"PKGBUILD sets epoch=2: an update keeps it, and current holds the version without it."* ]]
  expect_yaml demo 'name: demo' 'strategy: github-tag' 'upstream:' '  project: o/demo' 'current: 1.0.0'
  aur_package other 1.0.0 'epoch = 0' 'source = https://github.com/o/other/archive/v1.0.0.tar.gz'
  run "$TEST_TMPDIR/scripts/draft.sh" other
  [ "$status" -eq 0 ]
  [[ "$output" != *"epoch"* ]]
}

@test "draft: keeps the file for an edit when the check fails" {
  aur_package demo 1.0.0 'source = https://invent.kde.org/group/demo/-/archive/v1.0.0/demo-v1.0.0.tar.gz'
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 1 ]
  expect_yaml demo 'name: demo' 'strategy: gitlab-tag' 'upstream:' '  host: invent.kde.org' '  project: group/demo' 'current: 1.0.0'
  [[ "$output" == *"demo: valid"* ]]
  [[ "$output" == *"Fix packages/demo.yml, or delete it"* ]]
}

@test "draft: runs no check of a YAML that validate-pkg refuses" {
  aur_package demo 1.0.0 'source = https://download.kde.org/stable/.hidden/demo-1.0.0.tar.xz'
  run "$TEST_TMPDIR/scripts/draft.sh" demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.path must be a directory on download.kde.org"* ]]
  [[ "$output" != *"Checking demo"* ]]
  [[ "$output" == *"Fix packages/demo.yml, or delete it"* ]]
  [ -e "$TEST_TMPDIR/packages/demo.yml" ]
}
