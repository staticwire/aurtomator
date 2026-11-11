#!/usr/bin/env bash
# Shared BATS test setup
# Creates temp package dir, injects mock curl into PATH

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# CI sets it for the repository of aurtomator, and update-readme.sh reads it
unset GITHUB_REPOSITORY

# Create temp workspace
setup_test_env() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR

  # Create mock package dir structure
  mkdir -p "$TEST_TMPDIR/packages"
  mkdir -p "$TEST_TMPDIR/strategies"
  mkdir -p "$TEST_TMPDIR/scripts/lib"
  mkdir -p "$TEST_TMPDIR/.status"

  # Symlink all scripts and strategies for bashcov coverage tracking
  ln -sf "$PROJECT_DIR/scripts/"*.sh "$TEST_TMPDIR/scripts/"
  ln -sf "$PROJECT_DIR/scripts/lib/"*.sh "$TEST_TMPDIR/scripts/lib/"
  ln -sf "$PROJECT_DIR/strategies/"*.sh "$TEST_TMPDIR/strategies/"

  # Put mock curl first in PATH
  MOCK_DIR="$TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_DIR"
  cp "$TESTS_DIR/helpers/mock-curl.sh" "$MOCK_DIR/curl"
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"

  # Override AURTOMATOR_DIR and AURTOMATOR_DATA_DIR so all scripts use our
  # temp workspace
  export AURTOMATOR_DIR="$TEST_TMPDIR"
  export AURTOMATOR_DATA_DIR="$TEST_TMPDIR"

  # No pause before an AUR clone, between attempts or before a second check
  export AURTOMATOR_CLONE_DELAY=0 AURTOMATOR_RETRY_DELAY=0 AURTOMATOR_RECHECK_DELAY=0

  # git reads and writes no global config of the user running the tests
  export GIT_CONFIG_GLOBAL="$TEST_TMPDIR/gitconfig"
}

# bashcov-bats.sh sets AURTOMATOR_KEEP_TEST_DIRS: bashcov reads the trace
# of a test after the test, and needs the links in $TEST_TMPDIR then
teardown_test_env() {
  if [[ -z "${AURTOMATOR_KEEP_TEST_DIRS:-}" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

# Create a test package YAML
# Usage: create_test_package <name> <strategy> <yaml-body>
create_test_package() {
  local name="$1"
  local strategy="$2"
  local extra="$3"
  cat >"$TEST_TMPDIR/packages/${name}.yml" <<EOF
name: ${name}
strategy: ${strategy}
${extra}
EOF
}

# Write to $1 the .SRCINFO of a package with an archive per arch, as
# makepkg --printsrcinfo prints it, at version $2 (default 28+22)
arch_srcinfo() {
  local ver="${2:-28+22}" arch file
  local url="https://github.com/adoptium/temurin28-binaries/releases/download/jdk-${ver}-ea-beta"
  {
    printf '%s\n' "pkgbase = jdk-temurin-ea-bin" $'\tpkgdesc = Eclipse Temurin early access JDK' \
      $'\tpkgver = '"$ver" $'\tpkgrel = 1' $'\turl = https://adoptium.net/'
    printf '\tarch = %s\n' x86_64 aarch64 powerpc64le riscv64
    printf '%s\n' $'\tlicense = GPL-2.0-only WITH Classpath-exception-2.0' $'\tdepends = java-runtime-common'
    for arch in x86_64 aarch64 powerpc64le riscv64; do
      file=$arch
      [[ "$arch" != x86_64 ]] || file=x64
      [[ "$arch" != powerpc64le ]] || file=ppc64le
      printf '\tsource_%s = %s/OpenJDK-jdk_%s_linux_hotspot_%s-ea.tar.gz\n' "$arch" "$url" "$file" "${ver/+/_}"
      [[ "$arch" != aarch64 ]] || printf '\tdepends_aarch64 = zlib\n'
      printf '\tsha256sums_%s = %s\n' "$arch" "$(printf '%s' "$arch$ver" | sha256sum | cut -d' ' -f1)"
    done
    printf '\npkgname = jdk-temurin-ea-bin\n'
  } >"$1"
}

# Prints how many status files of directory $1 hold check_failed or
# update_failed
failed_statuses() {
  local file count=0
  for file in "$1"/*; do
    [[ -f "$file" && "${file##*/}" != _* ]] || continue
    case "$(<"$file")" in
      check_failed:* | update_failed:*) count=$((count + 1)) ;;
    esac
  done
  echo "$count"
}
