#!/usr/bin/env bash
# Shared BATS test setup
# Creates temp package dir, injects mock curl into PATH

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# Create temp workspace
setup_test_env() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR

  # Create mock package dir structure
  mkdir -p "$TEST_TMPDIR/packages"
  mkdir -p "$TEST_TMPDIR/strategies"
  mkdir -p "$TEST_TMPDIR/scripts"
  mkdir -p "$TEST_TMPDIR/.status"

  # Symlink all scripts and strategies for bashcov coverage tracking
  ln -sf "$PROJECT_DIR/scripts/"*.sh "$TEST_TMPDIR/scripts/"
  ln -sf "$PROJECT_DIR/strategies/"*.sh "$TEST_TMPDIR/strategies/"

  # Put mock curl first in PATH
  MOCK_DIR="$TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_DIR"
  cp "$TESTS_DIR/helpers/mock-curl.sh" "$MOCK_DIR/curl"
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"

  # Override AURTOMATOR_DIR so all scripts use our temp workspace
  export AURTOMATOR_DIR="$TEST_TMPDIR"
}

teardown_test_env() {
  rm -rf "$TEST_TMPDIR"
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
