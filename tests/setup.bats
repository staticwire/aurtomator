#!/usr/bin/env bats

load helpers/setup.sh

setup() {
  setup_test_env

  # Create mock GPG key list output
  MOCK_DIR="$TEST_TMPDIR/mock-bin"

  # Mock gpg: accepts specific key IDs
  cat > "$MOCK_DIR/gpg" <<'MOCKEOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    VALIDKEY123|SUBKEY002)
      if [[ "$*" == *"--list-secret-keys"* ]]; then
        echo "sec   ed25519/MASTERAAA 2026-01-01 [SC]"
        echo "      ABCDEF1234567890"
        echo "uid           [ultimate] Test User <test@test>"
        echo "ssb   ed25519/SUBKEY002 2026-01-01 [S]"
        exit 0
      fi
      if [[ "$*" == *"--sign"* || "$*" == *"--batch"*"--sign"* ]]; then
        echo "-----BEGIN PGP SIGNATURE-----"
        echo "mocked"
        echo "-----END PGP SIGNATURE-----"
        exit 0
      fi
      if [[ "$*" == *"--export-secret-subkeys"* ]]; then
        echo "-----BEGIN PGP PRIVATE KEY BLOCK-----"
        echo "mocked-clean"
        echo "-----END PGP PRIVATE KEY BLOCK-----"
        exit 0
      fi
      exit 0
      ;;
    MASTERKEY001)
      if [[ "$*" == *"--list-secret-keys"* ]]; then
        echo "sec   ed25519/MASTERKEY001 2026-01-01 [SC]"
        echo "      1234567890ABCDEF"
        echo "uid           [ultimate] Master User <master@test>"
        exit 0
      fi
      if [[ "$*" == *"--sign"* || "$*" == *"--batch"*"--sign"* ]]; then
        echo "-----BEGIN PGP SIGNATURE-----"
        echo "mocked"
        echo "-----END PGP SIGNATURE-----"
        exit 0
      fi
      if [[ "$*" == *"--export-secret-subkeys"* ]]; then
        echo "-----BEGIN PGP PRIVATE KEY BLOCK-----"
        echo "mocked-master"
        echo "-----END PGP PRIVATE KEY BLOCK-----"
        exit 0
      fi
      exit 0
      ;;
    PASSKEY003)
      if [[ "$*" == *"--list-secret-keys"* ]]; then
        echo "sec   ed25519/MASTERXXX 2026-01-01 [SC]"
        echo "      FEDCBA0987654321"
        echo "uid           [ultimate] Pass User <pass@test>"
        echo "ssb   ed25519/PASSKEY003 2026-01-01 [S]"
        exit 0
      fi
      if [[ "$*" == *"--batch"*"--sign"* ]]; then
        echo "gpg: signing failed: No secret key" >&2
        exit 2
      fi
      if [[ "$*" == *"--export-secret-subkeys"* ]]; then
        echo "-----BEGIN PGP PRIVATE KEY BLOCK-----"
        echo "mocked-encrypted"
        echo "-----END PGP PRIVATE KEY BLOCK-----"
        exit 0
      fi
      if [[ "$*" == *"--edit-key"* ]]; then
        exit 0
      fi
      exit 0
      ;;
    BADKEY999)
      if [[ "$*" == *"--list-secret-keys"* ]]; then
        echo "gpg: error reading key: No public key" >&2
        exit 2
      fi
      ;;
  esac
done
# Default: pass through for unrecognized calls
exit 0
MOCKEOF
  chmod +x "$MOCK_DIR/gpg"

  # Mock gpgconf (for kill agent)
  cat > "$MOCK_DIR/gpgconf" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
  chmod +x "$MOCK_DIR/gpgconf"

  # Mock ssh
  cat > "$MOCK_DIR/ssh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "$*" == *"aur.archlinux.org"* ]]; then
  echo "Welcome to AUR! Your SSH key is working."
  exit 1  # AUR always exits 1 even on success
fi
exit 1
MOCKEOF
  chmod +x "$MOCK_DIR/ssh"

  # Mock gh
  cat > "$MOCK_DIR/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1" in
  auth)
    echo "Logged in to github.com as testuser"
    exit 0
    ;;
  api)
    if [[ "$*" == *"user"* ]]; then
      echo "testuser"
      exit 0
    fi
    exit 0
    ;;
  secret)
    if [[ "$2" == "set" ]]; then
      cat > /dev/null 2>&1 || true  # drain stdin (piped secrets)
      echo "✓ Set Actions secret $3 for test/repo"
      exit 0
    fi
    if [[ "$2" == "list" ]]; then
      echo "AUR_SSH_KEY    Updated 2026-03-26"
      echo "AUR_GIT_NAME   Updated 2026-03-26"
      echo "AUR_GIT_EMAIL  Updated 2026-03-26"
      echo "GPG_SIGNING_KEY    Updated 2026-03-26"
      exit 0
    fi
    ;;
esac
exit 0
MOCKEOF
  chmod +x "$MOCK_DIR/gh"

  # Create real SSH key (no passphrase)
  mkdir -p "$TEST_TMPDIR/ssh"
  ssh-keygen -t ed25519 -f "$TEST_TMPDIR/ssh/aur.pem" -N "" -q

  # Init git repo with origin (for secrets step)
  git -C "$TEST_TMPDIR" init -q
  git config --global --add safe.directory "$TEST_TMPDIR"
  git -C "$TEST_TMPDIR" remote add origin "git@github.com:test/repo.git"
}

teardown() {
  teardown_test_env
}

# Helper: pre-populate full config for steps that need it
write_full_config() {
  cat >"$TEST_TMPDIR/.aurtomator.conf" <<EOF
GIT_AUTHOR_NAME="Test User"
GIT_AUTHOR_EMAIL="test@test.com"
GPG_KEY_ID="${1:-}"
AUR_SSH_KEY="$TEST_TMPDIR/ssh/aur.pem"
EOF
}

# === Argument parsing ===

@test "setup: --help exits 0" {
  run "$TEST_TMPDIR/scripts/setup.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup.sh"* ]]
}

@test "setup: unknown flag exits 1" {
  run "$TEST_TMPDIR/scripts/setup.sh" --bogus-flag
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
}

# === Identity step ===

@test "setup identity: sets git author via CLI flags" {
  run "$TEST_TMPDIR/scripts/setup.sh" identity \
    --git-name "Jane Doe" --git-email "jane@example.com" \
    --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"Git author: Jane Doe"* ]]
  grep -q 'GIT_AUTHOR_NAME="Jane Doe"' "$TEST_TMPDIR/.aurtomator.conf"
  grep -q 'GIT_AUTHOR_EMAIL="jane@example.com"' "$TEST_TMPDIR/.aurtomator.conf"
}

@test "setup identity: fails without git name in non-interactive" {
  # Override HOME to prevent git config --global detection
  HOME="$TEST_TMPDIR/emptyhome" run "$TEST_TMPDIR/scripts/setup.sh" identity \
    --git-email "jane@example.com" \
    --non-interactive
  [ "$status" -ne 0 ]
}

@test "setup identity: fails without git email in non-interactive" {
  HOME="$TEST_TMPDIR/emptyhome" run "$TEST_TMPDIR/scripts/setup.sh" identity \
    --git-name "Jane Doe" \
    --non-interactive
  [ "$status" -ne 0 ]
}

@test "setup identity: fails on invalid email" {
  run "$TEST_TMPDIR/scripts/setup.sh" identity \
    --git-name "Jane Doe" --git-email "invalid" \
    --non-interactive
  [ "$status" -ne 0 ]
  [[ "$output" == *"must contain @"* ]]
}


# === GPG step ===

@test "setup gpg: valid key accepted" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg --gpg-key VALIDKEY123 --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"GPG key: VALIDKEY123"* ]]
}

@test "setup gpg: invalid key rejected" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg --gpg-key BADKEY999 --non-interactive
  [ "$status" -ne 0 ]
  [[ "$output" == *"Key not found"* ]]
}

@test "setup gpg: skip when no key in non-interactive" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"GPG signing skipped"* ]]
}

@test "setup gpg: subkey without passphrase accepted" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg --gpg-key SUBKEY002 --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"no passphrase, ready for CI"* ]]
}

@test "setup gpg: master key warns in non-interactive" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg --gpg-key MASTERKEY001 --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"master key"* ]]
  [[ "$output" == *"Continuing with master key"* ]]
}

@test "setup gpg: passphrase key skips GPG in non-interactive" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg --gpg-key PASSKEY003 --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"passphrase"* ]]
  [[ "$output" == *"Cannot remove passphrase in non-interactive"* ]]
}

# === SSH step ===

@test "setup ssh: existing key accepted" {
  run "$TEST_TMPDIR/scripts/setup.sh" ssh \
    --ssh-key "$TEST_TMPDIR/ssh/aur.pem" \
    --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"SSH key:"* ]]
}

@test "setup ssh: expands tilde in path" {
  # Create real key in fake home
  mkdir -p "$TEST_TMPDIR/fakehome/keys"
  ssh-keygen -t ed25519 -f "$TEST_TMPDIR/fakehome/keys/aur.pem" -N "" -q

  HOME="$TEST_TMPDIR/fakehome" run "$TEST_TMPDIR/scripts/setup.sh" ssh \
    --ssh-key "~/keys/aur.pem" \
    --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"SSH key:"* ]]
}

@test "setup ssh: nonexistent key rejected" {
  run "$TEST_TMPDIR/scripts/setup.sh" ssh \
    --ssh-key "/nonexistent/path/key.pem" \
    --non-interactive
  [ "$status" -ne 0 ]
  [[ "$output" == *"SSH key not found"* ]]
}

# === Config persistence ===

@test "setup: saves config file" {
  "$TEST_TMPDIR/scripts/setup.sh" gpg --gpg-key VALIDKEY123 --non-interactive 2>/dev/null
  [ -f "$TEST_TMPDIR/.aurtomator.conf" ]
  grep -q "VALIDKEY123" "$TEST_TMPDIR/.aurtomator.conf"
}

@test "setup: second run loads saved config" {
  # First run: save GPG key
  "$TEST_TMPDIR/scripts/setup.sh" gpg --gpg-key VALIDKEY123 --non-interactive 2>/dev/null

  # Second run: should pick up saved key without --gpg-key
  run "$TEST_TMPDIR/scripts/setup.sh" gpg --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"GPG key: VALIDKEY123"* ]]
}

@test "setup: config contains identity fields" {
  "$TEST_TMPDIR/scripts/setup.sh" identity \
    --git-name "Test" --git-email "test@test.com" \
    --non-interactive 2>/dev/null
  grep -q "GIT_AUTHOR_NAME" "$TEST_TMPDIR/.aurtomator.conf"
  grep -q "GIT_AUTHOR_EMAIL" "$TEST_TMPDIR/.aurtomator.conf"
}

# === Verify step ===

@test "setup verify: all green with valid config" {
  write_full_config "VALIDKEY123"

  run "$TEST_TMPDIR/scripts/setup.sh" verify --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"Identity:"* ]]
  [[ "$output" == *"SSH:"*"accessible"* ]]
  [[ "$output" == *"GPG:"*"signing works"* ]]
  [[ "$output" == *"Ready."* ]]
}

@test "setup verify: works without GPG configured" {
  write_full_config ""

  run "$TEST_TMPDIR/scripts/setup.sh" verify --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"GPG: skipped"* ]]
  [[ "$output" == *"Ready."* ]]
}

# === Secrets step ===

@test "setup secrets: sets all secrets via gh" {
  write_full_config "VALIDKEY123"

  run "$TEST_TMPDIR/scripts/setup.sh" secrets --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUR_GIT_NAME"* ]]
  [[ "$output" == *"AUR_GIT_EMAIL"* ]]
  [[ "$output" == *"AUR_SSH_KEY"* ]]
  [[ "$output" == *"GPG_SIGNING_KEY"* ]]
}

@test "setup secrets: shows manual instructions without gh" {
  # Replace mock gh with one that fails auth
  cat >"$TEST_TMPDIR/mock-bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$TEST_TMPDIR/mock-bin/gh"

  write_full_config ""

  run "$TEST_TMPDIR/scripts/setup.sh" secrets --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"Set these secrets"* ]]
  [[ "$output" == *"AUR_GIT_NAME"* ]]
  [[ "$output" == *"AUR_GIT_EMAIL"* ]]
  [[ "$output" == *"AUR_SSH_KEY"* ]]
}

# === ANSI colors ===

@test "setup: no ANSI codes when piped (not a terminal)" {
  # run captures output, which means stdout is not a terminal
  run "$TEST_TMPDIR/scripts/setup.sh" --help
  # Should NOT contain raw escape sequences
  if [[ "$output" == *$'\033'* ]]; then
    echo "Found ANSI escape codes in non-terminal output" >&2
    false
  fi
}

@test "setup: color variables use dollar-single-quote syntax" {
  # Verify the fix: $'\033[...' not '\033[...'
  grep -q "\\\$'\\\\033" "$TEST_TMPDIR/scripts/setup.sh"
}

# === Non-interactive GPG skip ===

@test "setup gpg: non-interactive without --gpg-key skips cleanly" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"GPG signing skipped"* ]]
  [[ "$output" == *"no --gpg-key"* ]]
}

# === GPG prompt format ===

@test "setup gpg: enable prompt uses (y/N) format" {
  # Check the source code directly — prompt text is in the script
  grep -q 'Enable GPG commit signing? (y/N)' "$TEST_TMPDIR/scripts/setup.sh"
}

# === SSH text ===

@test "setup ssh: shows 'ensure' wording for public key" {
  run "$TEST_TMPDIR/scripts/setup.sh" ssh \
    --ssh-key "$TEST_TMPDIR/ssh/aur.pem" \
    --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"ensure it is added to"* ]]
}

# === Unknown option help hint ===

@test "setup: unknown option suggests --help" {
  run "$TEST_TMPDIR/scripts/setup.sh" --bogus-flag
  [ "$status" -eq 1 ]
  [[ "$output" == *"--help"* ]]
}

# === Verify secret counts ===

@test "setup verify: shows 3/3 secrets without GPG" {
  write_full_config ""

  # Mock gh to return 3 secrets (no GPG)
  cat >"$TEST_TMPDIR/mock-bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  api) echo "testuser"; exit 0 ;;
  secret)
    if [[ "$2" == "list" ]]; then
      echo "AUR_SSH_KEY    Updated 2026-03-26"
      echo "AUR_GIT_NAME   Updated 2026-03-26"
      echo "AUR_GIT_EMAIL  Updated 2026-03-26"
      exit 0
    fi ;;
esac
exit 0
EOF
  chmod +x "$TEST_TMPDIR/mock-bin/gh"

  run "$TEST_TMPDIR/scripts/setup.sh" verify --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"3/3 configured"* ]]
}

# === Passphrase-protected SSH key ===

@test "setup ssh: accepts passphrase-protected key" {
  mkdir -p "$TEST_TMPDIR/ssh-pass"
  ssh-keygen -t ed25519 -f "$TEST_TMPDIR/ssh-pass/key" -N "testpass" -q

  run "$TEST_TMPDIR/scripts/setup.sh" ssh \
    --ssh-key "$TEST_TMPDIR/ssh-pass/key" \
    --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"passphrase-protected"* ]]
}
