#!/usr/bin/env bats

# GPG flow tests using REAL GPG keys (no mocks)
# Tests: key detection, passphrase detection, passphrase stripping,
#        setup.sh GPG step, commit signing

load helpers/setup.sh

setup() {
  setup_test_env

  # Isolated GPG keyring for all tests
  export GNUPGHOME="$TEST_TMPDIR/gnupg"
  mkdir -m 0700 "$GNUPGHOME"
  echo "allow-loopback-pinentry" >"$GNUPGHOME/gpg-agent.conf"

  # Generate master key + signing subkey WITHOUT passphrase
  gpg --batch --gen-key <<GPGEOF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Subkey-Type: eddsa
Subkey-Curve: ed25519
Subkey-Usage: sign
Name-Real: Test Nopass
Name-Email: nopass@test
Expire-Date: 0
GPGEOF

  NOPASS_SUBKEY_ID=$(gpg --list-secret-keys --keyid-format long 2>/dev/null | grep "^ssb" | head -1 | awk '{print $2}' | cut -d'/' -f2)
  NOPASS_MASTER_ID=$(gpg --list-secret-keys --keyid-format long 2>/dev/null | grep "^sec" | head -1 | awk '{print $2}' | cut -d'/' -f2)

  # Generate master key + signing subkey WITH passphrase
  gpg --batch --gen-key <<GPGEOF
%echo Generating passphrase-protected key
Key-Type: eddsa
Key-Curve: ed25519
Subkey-Type: eddsa
Subkey-Curve: ed25519
Subkey-Usage: sign
Name-Real: Test Withpass
Name-Email: withpass@test
Passphrase: testpass123
Expire-Date: 0
GPGEOF

  # Extract key IDs for withpass key — use fingerprint matching
  local withpass_fpr
  withpass_fpr=$(gpg --list-secret-keys --keyid-format long 2>/dev/null | grep -B2 "Test Withpass" | grep "^sec" | head -1 | awk '{print $2}' | cut -d'/' -f2)
  WITHPASS_MASTER_ID="$withpass_fpr"
  WITHPASS_SUBKEY_ID=$(gpg --list-secret-keys --keyid-format long 2>/dev/null | grep -A8 "Test Withpass" | grep "^ssb" | head -1 | awk '{print $2}' | cut -d'/' -f2)

  # Git repo for commit signing tests
  AUR_DIR="$TEST_TMPDIR/aur-test-pkg"
  mkdir -p "$AUR_DIR"
  git -C "$AUR_DIR" init -q
  git -C "$AUR_DIR" config user.name "test"
  git -C "$AUR_DIR" config user.email "test@test"
  git -C "$AUR_DIR" config commit.gpgsign false
  cat >"$AUR_DIR/PKGBUILD" <<'EOF'
pkgname=test-pkg
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('any')
license=('MIT')
EOF
  git -C "$AUR_DIR" add . && git -C "$AUR_DIR" commit -q -m "init"

  # Git repo for setup.sh (needs origin remote)
  git -C "$TEST_TMPDIR" init -q
  git config --global --add safe.directory "$TEST_TMPDIR"
  git -C "$TEST_TMPDIR" remote add origin "git@github.com:test/repo.git"

  # SSH key for setup.sh
  mkdir -p "$TEST_TMPDIR/ssh"
  ssh-keygen -t ed25519 -f "$TEST_TMPDIR/ssh/aur.pem" -N "" -q

  # Mock gh and ssh (setup.sh needs them, but we test GPG not secrets)
  cat >"$TEST_TMPDIR/mock-bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  api) echo "testuser"; exit 0 ;;
  secret)
    [[ "$2" == "set" ]] && { cat >/dev/null 2>&1 || true; exit 0; }
    [[ "$2" == "list" ]] && { echo "AUR_SSH_KEY Updated"; echo "AUR_GIT_NAME Updated"; echo "AUR_GIT_EMAIL Updated"; echo "GPG_SIGNING_KEY Updated"; exit 0; }
    ;;
esac
exit 0
MOCKEOF
  chmod +x "$TEST_TMPDIR/mock-bin/gh"

  cat >"$TEST_TMPDIR/mock-bin/ssh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "Welcome to AUR"; exit 1
MOCKEOF
  chmod +x "$TEST_TMPDIR/mock-bin/ssh"
}

teardown() {
  gpgconf --kill gpg-agent 2>/dev/null || true
  unset GNUPGHOME
  teardown_test_env
}

# =============================================================================
# KEY TYPE DETECTION
# =============================================================================

@test "gpg-real: detects subkey with [S] capability" {
  key_info=$(gpg --list-secret-keys --keyid-format long 2>/dev/null)
  echo "$key_info" | grep -q "^ssb"
  echo "$key_info" | grep "^ssb" | grep -q "\[S\]"
}

@test "gpg-real: distinguishes master from subkey" {
  key_info=$(gpg --list-secret-keys --keyid-format long "$NOPASS_SUBKEY_ID" 2>/dev/null)
  # Subkey ID should appear on ssb line, not sec line
  echo "$key_info" | grep "^ssb" | grep -q "$NOPASS_SUBKEY_ID"
  # Master key should be on sec line
  echo "$key_info" | grep "^sec" | grep -q "$NOPASS_MASTER_ID"
}

# =============================================================================
# PASSPHRASE DETECTION (the exact method setup.sh uses)
# =============================================================================

@test "gpg-real: pinentry-mode error succeeds for no-passphrase key" {
  gpgconf --kill gpg-agent 2>/dev/null || true
  echo "test" | gpg --batch --pinentry-mode error --sign --local-user "$NOPASS_SUBKEY_ID" >/dev/null 2>&1
}

@test "gpg-real: pinentry-mode error fails for passphrase key" {
  gpgconf --kill gpg-agent 2>/dev/null || true
  run bash -c "echo test | gpg --batch --pinentry-mode error --sign --local-user '$WITHPASS_SUBKEY_ID' >/dev/null 2>&1"
  [ "$status" -ne 0 ]
}

@test "gpg-real: pinentry-mode error fails for master key with passphrase" {
  gpgconf --kill gpg-agent 2>/dev/null || true
  run bash -c "echo test | gpg --batch --pinentry-mode error --sign --local-user '$WITHPASS_MASTER_ID' >/dev/null 2>&1"
  [ "$status" -ne 0 ]
}

# =============================================================================
# PASSPHRASE STRIPPING (the exact flow setup.sh uses)
# =============================================================================

@test "gpg-real: full passphrase strip flow works" {
  # This replicates setup.sh lines 277-330 exactly
  local tmp_gnupg
  tmp_gnupg=$(mktemp -d)
  chmod 700 "$tmp_gnupg"
  echo "pinentry-program /usr/bin/pinentry" >"$tmp_gnupg/gpg-agent.conf"
  echo "allow-loopback-pinentry" >>"$tmp_gnupg/gpg-agent.conf"

  # Step 1: Export signing subkey (with passphrase, via loopback)
  local exported_key
  exported_key=$(echo "testpass123" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 \
    --export-secret-subkeys --armor "${WITHPASS_SUBKEY_ID}!" 2>/dev/null) || true
  [[ -n "$exported_key" ]]

  # Step 2: Import into temp keyring
  echo "$exported_key" | gpg --homedir "$tmp_gnupg" --batch --import 2>/dev/null

  # Step 3: Get keygrip
  local keygrip
  keygrip=$(gpg --homedir "$tmp_gnupg" --list-secret-keys --with-keygrip 2>/dev/null |
    grep -A1 "\[S\]" | grep Keygrip | awk '{print $3}' || true)
  [[ -n "$keygrip" ]]

  # Step 4: Change passphrase to empty via loopback (simulates pinentry)
  # old pass + empty new pass + empty repeat for each subkey
  printf '%s\n\n\n\n' "testpass123" | gpg --homedir "$tmp_gnupg" --batch --yes \
    --pinentry-mode loopback --command-fd 0 --passwd "${WITHPASS_SUBKEY_ID}" 2>/dev/null || true

  # Step 5: Export clean key (should work with empty passphrase now)
  local clean_key
  clean_key=$(gpg --homedir "$tmp_gnupg" --batch --pinentry-mode loopback \
    --passphrase "" --export-secret-subkeys --armor "${WITHPASS_SUBKEY_ID}!" 2>/dev/null) || true
  [[ -n "$clean_key" ]]
  [[ "$clean_key" == *"BEGIN PGP PRIVATE KEY BLOCK"* ]]

  # Step 6: Verify clean key actually works without passphrase
  local verify_gnupg
  verify_gnupg=$(mktemp -d)
  chmod 700 "$verify_gnupg"
  echo "$clean_key" | gpg --homedir "$verify_gnupg" --batch --import 2>/dev/null
  echo "test" | gpg --homedir "$verify_gnupg" --batch --pinentry-mode error \
    --sign --local-user "$WITHPASS_SUBKEY_ID" >/dev/null 2>&1

  gpgconf --homedir "$tmp_gnupg" --kill gpg-agent 2>/dev/null || true
  gpgconf --homedir "$verify_gnupg" --kill gpg-agent 2>/dev/null || true
  rm -rf "$tmp_gnupg" "$verify_gnupg"
}

@test "gpg-real: no-passphrase key needs no stripping" {
  gpgconf --kill gpg-agent 2>/dev/null || true
  # pinentry-mode error should succeed — key has no passphrase
  echo "test" | gpg --batch --pinentry-mode error --sign --local-user "$NOPASS_SUBKEY_ID" >/dev/null 2>&1
  # This is the "happy path" — setup.sh says "no passphrase, ready for CI"
}

# =============================================================================
# GIT COMMIT SIGNING
# =============================================================================

@test "gpg-real: git commit signing works with subkey" {
  cd "$AUR_DIR"
  sed -i 's/pkgver=1.0.0/pkgver=2.0.0/' PKGBUILD
  git add PKGBUILD
  git config commit.gpgsign false
  git commit -m "update to 2.0.0"

  git -c user.signingkey="$NOPASS_SUBKEY_ID" \
    -c commit.gpgsign=true \
    commit --amend --no-edit

  git log --show-signature -1 2>&1 | grep -qi "good signature\|gpg"
}

@test "gpg-real: git commit signing works with master key" {
  cd "$AUR_DIR"
  sed -i 's/pkgver=1.0.0/pkgver=2.5.0/' PKGBUILD
  git add PKGBUILD
  git config commit.gpgsign false
  git commit -m "update to 2.5.0"

  git -c user.signingkey="$NOPASS_MASTER_ID" \
    -c commit.gpgsign=true \
    commit --amend --no-edit

  git log --show-signature -1 2>&1 | grep -qi "good signature\|gpg"
}

@test "gpg-real: unsigned commit works without GPG" {
  cd "$AUR_DIR"
  sed -i 's/pkgver=1.0.0/pkgver=3.0.0/' PKGBUILD
  git add PKGBUILD
  git config commit.gpgsign false
  git commit -m "update to 3.0.0"
  git log --oneline -1 | grep -q "update to 3.0.0"
}

@test "gpg-real: full update-pkg commit + sign + amend flow" {
  cd "$AUR_DIR"
  sed -i 's/pkgver=1.0.0/pkgver=4.0.0/' PKGBUILD

  git config user.name "aurtomator"
  git config user.email "aurtomator@users.noreply.github.com"
  git config commit.gpgsign false
  git add PKGBUILD
  git commit -m "4.0.0 release from test"

  git -c user.signingkey="$NOPASS_SUBKEY_ID" \
    -c commit.gpgsign=true \
    commit --amend --no-edit

  git log -1 --format=%s | grep -q "4.0.0 release from test"
  git log --show-signature -1 2>&1 | grep -qi "good signature\|gpg"
}

# =============================================================================
# SETUP.SH GPG STEP (with real keys, non-interactive)
# =============================================================================

@test "gpg-real: setup.sh detects no-passphrase subkey" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg \
    --gpg-key "$NOPASS_SUBKEY_ID" --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"no passphrase, ready for CI"* ]]
}

@test "gpg-real: setup.sh detects passphrase subkey in non-interactive" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg \
    --gpg-key "$WITHPASS_SUBKEY_ID" --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"passphrase"* ]]
  [[ "$output" == *"Cannot remove passphrase in non-interactive"* ]]
}

@test "gpg-real: setup.sh warns about master key" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg \
    --gpg-key "$NOPASS_MASTER_ID" --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"master key"* ]]
  [[ "$output" == *"Continuing with master key"* ]]
}

@test "gpg-real: setup.sh detects passphrase on master key" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg \
    --gpg-key "$WITHPASS_MASTER_ID" --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"master key"* ]]
  [[ "$output" == *"passphrase"* ]]
  [[ "$output" == *"Cannot remove passphrase in non-interactive"* ]]
}

@test "gpg-real: setup.sh rejects nonexistent key" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg \
    --gpg-key "NONEXISTENT999" --non-interactive
  [ "$status" -ne 0 ]
  [[ "$output" == *"Key not found"* ]]
}

@test "gpg-real: setup.sh skips GPG in non-interactive without --gpg-key" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"GPG signing skipped"* ]]
}

@test "gpg-real: signing with nonexistent key fails" {
  run bash -c "echo test | gpg --batch --sign --armor --local-user 'NONEXISTENT999' 2>&1"
  [ "$status" -ne 0 ]
}

# =============================================================================
# SETUP.SH FULL FLOW (with real keys)
# =============================================================================

@test "gpg-real: full setup with no-passphrase key" {
  cat >"$TEST_TMPDIR/.aurtomator.conf" <<EOF
GIT_AUTHOR_NAME="Test"
GIT_AUTHOR_EMAIL="test@test.com"
MAINTAINER="Test <test at test dot com>"
AUR_SSH_KEY="$TEST_TMPDIR/ssh/aur.pem"
EOF

  run "$TEST_TMPDIR/scripts/setup.sh" gpg \
    --gpg-key "$NOPASS_SUBKEY_ID" --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"no passphrase, ready for CI"* ]]
  grep -q "GPG_KEY_ID=\"$NOPASS_SUBKEY_ID\"" "$TEST_TMPDIR/.aurtomator.conf"
}

@test "gpg-real: config clears GPG_KEY_ID when passphrase key skipped" {
  cat >"$TEST_TMPDIR/.aurtomator.conf" <<EOF
GIT_AUTHOR_NAME="Test"
GIT_AUTHOR_EMAIL="test@test.com"
MAINTAINER="Test <test at test dot com>"
AUR_SSH_KEY="$TEST_TMPDIR/ssh/aur.pem"
EOF

  run "$TEST_TMPDIR/scripts/setup.sh" gpg \
    --gpg-key "$WITHPASS_SUBKEY_ID" --non-interactive
  [ "$status" -eq 0 ]
  grep -q 'GPG_KEY_ID=""' "$TEST_TMPDIR/.aurtomator.conf"
}
