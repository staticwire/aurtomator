#!/usr/bin/env bats

load helpers/setup.sh

setup() {
  setup_test_env

  # Create mock GPG key list output
  MOCK_DIR="$TEST_TMPDIR/mock-bin"

  # Mock gpg: accepts specific key IDs, with or without "!", and logs its
  # arguments to $TEST_TMPDIR/gpg.args
  cat > "$MOCK_DIR/gpg" <<'MOCKEOF'
#!/usr/bin/env bash
echo "$*" >>"$TEST_TMPDIR/gpg.args"
for arg in "$@"; do
  case "$arg" in
    VALIDKEY123|SUBKEY002|VALIDKEY123!|SUBKEY002!)
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
    MASTERKEY001|FFFFFFFFFFFFFFFFFFFFFFFFMASTERKEY001)
      if [[ "$*" == *"--list-secret-keys"* && "$*" == *"--with-colons"* ]]; then
        echo "sec:u:255:22:MASTERKEY001:1767225600:::u:::scESC:::+:::23::0:"
        echo "fpr:::::::::FFFFFFFFFFFFFFFFFFFFFFFFMASTERKEY001:"
        exit 0
      fi
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

# Helper: gh that fails auth, so the secrets step prints manual instructions
mock_gh_unavailable() {
  cat >"$TEST_TMPDIR/mock-bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$TEST_TMPDIR/mock-bin/gh"
}

# Helper: gpg for the passphrase strip flow on PASSKEY003. The main keyring
# exports the key with its passphrase, the temporary keyring (--homedir)
# exports the copy
mock_gpg_strip_flow() {
  cat >"$TEST_TMPDIR/mock-bin/gpg" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *--with-keygrip*)
    echo "ssb   ed25519/PASSKEY003 2026-01-01 [S]"
    echo "      Keygrip = 0123456789ABCDEF0123456789ABCDEF01234567"
    ;;
  *--homedir*--export-secret-subkeys*)
    echo "-----BEGIN PGP PRIVATE KEY BLOCK-----"
    echo "mocked-passphrase-free"
    echo "-----END PGP PRIVATE KEY BLOCK-----"
    ;;
  *--export-secret-subkeys*)
    echo "-----BEGIN PGP PRIVATE KEY BLOCK-----"
    echo "mocked-encrypted"
    echo "-----END PGP PRIVATE KEY BLOCK-----"
    ;;
  *--import*) cat >/dev/null ;;
  *--list-secret-keys*)
    echo "sec   ed25519/MASTERXXX 2026-01-01 [SC]"
    echo "ssb   ed25519/PASSKEY003 2026-01-01 [S]"
    ;;
  *--sign*) exit 2 ;;
esac
exit 0
EOF
  chmod +x "$TEST_TMPDIR/mock-bin/gpg"
  cat >"$TEST_TMPDIR/mock-bin/gpg-connect-agent" <<'EOF'
#!/usr/bin/env bash
echo "OK"
EOF
  chmod +x "$TEST_TMPDIR/mock-bin/gpg-connect-agent"
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

@test "setup gpg: refuses a primary key" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg --gpg-key MASTERKEY001 --non-interactive
  [ "$status" -eq 1 ]
  [[ "$output" == *"MASTERKEY001 is a primary key"* ]]
  [[ "$output" == *"gpg --quick-add-key"* ]]
  ! grep -q 'export-secret' "$TEST_TMPDIR/gpg.args"
}

@test "setup gpg: refuses a primary key given by its fingerprint" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg --gpg-key FFFFFFFFFFFFFFFFFFFFFFFFMASTERKEY001 --non-interactive
  [ "$status" -eq 1 ]
  [[ "$output" == *"is a primary key"* ]]
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

@test "setup identity: CLI flags override saved config" {
  write_full_config

  run "$TEST_TMPDIR/scripts/setup.sh" identity \
    --git-name "Jane Doe" --git-email "jane@example.com" \
    --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"Git author: Jane Doe <jane@example.com>"* ]]
  grep -q 'GIT_AUTHOR_NAME="Jane Doe"' "$TEST_TMPDIR/.aurtomator.conf"
  grep -q 'GIT_AUTHOR_EMAIL="jane@example.com"' "$TEST_TMPDIR/.aurtomator.conf"
}

@test "setup gpg: --gpg-key overrides saved key" {
  write_full_config "BADKEY999"

  run "$TEST_TMPDIR/scripts/setup.sh" gpg --gpg-key VALIDKEY123 --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"GPG key: VALIDKEY123"* ]]
  grep -q 'GPG_KEY_ID="VALIDKEY123"' "$TEST_TMPDIR/.aurtomator.conf"
}

@test "setup ssh: --ssh-key overrides saved path" {
  cat >"$TEST_TMPDIR/.aurtomator.conf" <<EOF
AUR_SSH_KEY="/nonexistent/path/key.pem"
EOF

  run "$TEST_TMPDIR/scripts/setup.sh" ssh \
    --ssh-key "$TEST_TMPDIR/ssh/aur.pem" \
    --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"SSH key: $TEST_TMPDIR/ssh/aur.pem"* ]]
  grep -q "AUR_SSH_KEY=\"$TEST_TMPDIR/ssh/aur.pem\"" "$TEST_TMPDIR/.aurtomator.conf"
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
  mock_gh_unavailable
  write_full_config ""

  run "$TEST_TMPDIR/scripts/setup.sh" secrets --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"Set these secrets"* ]]
  [[ "$output" == *"AUR_GIT_NAME"* ]]
  [[ "$output" == *"AUR_GIT_EMAIL"* ]]
  [[ "$output" == *"AUR_SSH_KEY"* ]]
}

@test "setup secrets: names the GitHub secrets page as GitHub does" {
  mock_gh_unavailable
  write_full_config ""

  run "$TEST_TMPDIR/scripts/setup.sh" secrets --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"Settings → Secrets and variables → Actions"* ]]
}

@test "setup secrets: skips GPG_SIGNING_KEY for a passphrase key without a copy" {
  write_full_config "PASSKEY003"

  run "$TEST_TMPDIR/scripts/setup.sh" secrets --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"has a passphrase"* ]]
  [[ "$output" == *"./scripts/setup.sh gpg secrets"* ]]
  [[ "$output" != *"Set Actions secret GPG_SIGNING_KEY"* ]]
}

@test "setup secrets: manual path omits a passphrase key without a copy" {
  mock_gh_unavailable
  write_full_config "PASSKEY003"

  run "$TEST_TMPDIR/scripts/setup.sh" secrets --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"has a passphrase"* ]]
  [[ "$output" != *"gpg --export-secret-subkeys"* ]]
}

@test "setup secrets: manual path prints the export command for a key without passphrase" {
  mock_gh_unavailable
  write_full_config "VALIDKEY123"

  run "$TEST_TMPDIR/scripts/setup.sh" secrets --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"gpg --export-secret-subkeys --armor 'VALIDKEY123!'"* ]]
  [[ "$output" != *"has a passphrase"* ]]
}

@test "setup secrets: gh stores only the signing subkey" {
  write_full_config "VALIDKEY123"
  cat >"$TEST_TMPDIR/mock-bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  api) echo "testuser" ;;
  secret) cat >"$TEST_TMPDIR/secret-\$3" ;;
esac
exit 0
EOF
  chmod +x "$TEST_TMPDIR/mock-bin/gh"

  run "$TEST_TMPDIR/scripts/setup.sh" secrets --non-interactive
  [ "$status" -eq 0 ]
  grep -q 'mocked-clean' "$TEST_TMPDIR/secret-GPG_SIGNING_KEY"
  grep -q -- '--export-secret-subkeys --armor VALIDKEY123!$' "$TEST_TMPDIR/gpg.args"
}

@test "setup secrets: stores no empty GPG_SIGNING_KEY" {
  write_full_config "VALIDKEY123"
  # gpg that signs, so the key has no passphrase, and exports nothing
  cat >"$TEST_TMPDIR/mock-bin/gpg" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *--export-secret-subkeys* ]] && exit 0
[[ "$*" == *--sign* ]] && echo "signature"
exit 0
EOF
  cat >"$TEST_TMPDIR/mock-bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  api) echo "testuser" ;;
  secret) cat >"$TEST_TMPDIR/secret-\$3" ;;
esac
exit 0
EOF
  chmod +x "$TEST_TMPDIR/mock-bin/gh"

  run "$TEST_TMPDIR/scripts/setup.sh" secrets --non-interactive
  [[ "$output" == *"GPG_SIGNING_KEY"* ]]
  [ -f "$TEST_TMPDIR/secret-AUR_SSH_KEY" ]
  [ ! -e "$TEST_TMPDIR/secret-GPG_SIGNING_KEY" ]
}

@test "setup gpg: removes the temporary keyring after the passphrase-free copy" {
  mock_gh_unavailable
  mock_gpg_strip_flow
  write_full_config "PASSKEY003"
  mkdir -p "$TEST_TMPDIR/tmp"

  TMPDIR="$TEST_TMPDIR/tmp" run "$TEST_TMPDIR/scripts/setup.sh" gpg <<<"y"
  [ "$status" -eq 0 ]
  [[ "$output" == *"passphrase-free copy created for CI"* ]]
  [ -z "$(ls -A "$TEST_TMPDIR/tmp")" ]
}

@test "setup gpg: removes the temporary keyring when the terminal closes after the passphrase is gone" {
  mock_gh_unavailable
  mock_gpg_strip_flow
  write_full_config "PASSKEY003"
  mkdir -p "$TEST_TMPDIR/tmp"
  # gpg-connect-agent that removes the passphrase, then the terminal of
  # setup.sh closes. The signal goes to the topmost setup.sh process, not
  # to the subshell of the command substitution.
  cat >"$TEST_TMPDIR/mock-bin/gpg-connect-agent" <<'EOF'
#!/usr/bin/env bash
echo "OK"
pid=$PPID
while [[ "$pid" -gt 1 ]] && ps -o args= -p "$pid" | grep -q 'scripts/setup.sh'; do
  target=$pid
  pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
done
kill -HUP "$target"
EOF

  TMPDIR="$TEST_TMPDIR/tmp" run "$TEST_TMPDIR/scripts/setup.sh" gpg <<<"y"
  [ "$status" -eq 129 ]
  [ -z "$(ls -A "$TEST_TMPDIR/tmp")" ]
}

@test "setup gpg secrets: manual path prints the passphrase-free copy" {
  mock_gh_unavailable
  mock_gpg_strip_flow
  write_full_config "PASSKEY003"

  # Answer "y" to "Proceed? (Y/n)"
  run "$TEST_TMPDIR/scripts/setup.sh" gpg secrets <<<"y"
  [ "$status" -eq 0 ]
  [[ "$output" == *"passphrase-free copy created for CI"* ]]
  [[ "$output" == *"mocked-passphrase-free"* ]]
  [[ "$output" != *"mocked-encrypted"* ]]
  [[ "$output" != *"gpg --export-secret-subkeys"* ]]
}

@test "setup gpg secrets: gh stores the passphrase-free copy" {
  mock_gpg_strip_flow
  write_full_config "PASSKEY003"

  # gh that keeps each secret it is given in a file named after the secret
  cat >"$TEST_TMPDIR/mock-bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  api) echo "testuser" ;;
  secret) cat >"$TEST_TMPDIR/secret-\$3" ;;
esac
exit 0
EOF
  chmod +x "$TEST_TMPDIR/mock-bin/gh"

  run "$TEST_TMPDIR/scripts/setup.sh" gpg secrets <<<"y"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GPG_SIGNING_KEY (passphrase-free copy)"* ]]
  grep -q "mocked-passphrase-free" "$TEST_TMPDIR/secret-GPG_SIGNING_KEY"
}

@test "setup gpg secrets: reports a failed upload of the passphrase-free copy" {
  mock_gpg_strip_flow
  write_full_config "PASSKEY003"

  # gh that is logged in but fails to set any secret
  cat >"$TEST_TMPDIR/mock-bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  api) echo "testuser" ;;
  secret) cat >/dev/null; exit 1 ;;
esac
exit 0
EOF
  chmod +x "$TEST_TMPDIR/mock-bin/gh"

  run "$TEST_TMPDIR/scripts/setup.sh" gpg secrets <<<"y"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✗ GPG_SIGNING_KEY"* ]]
  [[ "$output" != *"✓ GPG_SIGNING_KEY"* ]]
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
  # The prompt text is in the script source, so check the source
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

@test "setup ssh: names the AUR key field as aurweb does" {
  run "$TEST_TMPDIR/scripts/setup.sh" ssh \
    --ssh-key "$TEST_TMPDIR/ssh/aur.pem" \
    --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"My Account → SSH Public Key"* ]]
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
