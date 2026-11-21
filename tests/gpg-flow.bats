#!/usr/bin/env bats

# Tests of the GPG steps of setup.sh and of commit signing, with real gpg keys. Tests named
# gpg tool: and git tool: run those tools alone, to show the behavior that the code relies on

load helpers/setup.sh
bats_require_minimum_version 1.5.0

# The keys are generated once per file, and every test gets a copy of the
# keyring
setup_file() {
  export GNUPGHOME="$BATS_FILE_TMPDIR/gnupg"
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

  # Extract the key IDs of the withpass key by fingerprint
  local withpass_fpr
  withpass_fpr=$(gpg --list-secret-keys --keyid-format long 2>/dev/null | grep -B2 "Test Withpass" | grep "^sec" | head -1 | awk '{print $2}' | cut -d'/' -f2)
  WITHPASS_MASTER_ID="$withpass_fpr"
  WITHPASS_SUBKEY_ID=$(gpg --list-secret-keys --keyid-format long 2>/dev/null | grep -A8 "Test Withpass" | grep "^ssb" | head -1 | awk '{print $2}' | cut -d'/' -f2)
  export NOPASS_SUBKEY_ID NOPASS_MASTER_ID WITHPASS_MASTER_ID WITHPASS_SUBKEY_ID

  gpgconf --kill gpg-agent
}

setup() {
  setup_test_env

  # Isolated GPG keyring for each test
  export GNUPGHOME="$TEST_TMPDIR/gnupg"
  cp -a "$BATS_FILE_TMPDIR/gnupg" "$GNUPGHOME"

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
  git -C "$TEST_TMPDIR" remote add origin "git@github.com:test/repo.git"

  # SSH key for setup.sh
  mkdir -p "$TEST_TMPDIR/ssh"
  ssh-keygen -t ed25519 -f "$TEST_TMPDIR/ssh/aur.pem" -N "" -q

  # Mock gh and ssh: setup.sh calls them, and this test covers GPG only
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

# Prints the key ID of a new subkey of the key of e-mail address $1, with algorithm $2 and usage $3;
# $4 is the passphrase of the key, if it has one
add_subkey() {
  local fpr
  fpr=$(gpg --batch --with-colons --list-secret-keys "$1" | awk -F: '$1 == "fpr" { print $10; exit }')
  env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE gpg --batch --pinentry-mode loopback \
    --passphrase "${4:-}" --quick-add-key "$fpr" "$2" "$3" never 2>/dev/null
  gpg --batch --with-colons --list-secret-keys "$1" | awk -F: '$1 == "ssb" { id = $5 } END { print id }'
}

# Writes .aurtomator.conf with key ID $1
write_gpg_config() {
  printf '%s\n' 'GIT_AUTHOR_NAME="Test"' 'GIT_AUTHOR_EMAIL="test@test.com"' "GPG_KEY_ID=\"$1\"" \
    "AUR_SSH_KEY=\"$TEST_TMPDIR/ssh/aur.pem\"" >"$TEST_TMPDIR/.aurtomator.conf"
}

# The pinentry of the user answers the three dialogs of setup_gpg: the passphrase twice, then no
# passphrase for the copy
use_fake_pinentry() {
  local fake="$TEST_TMPDIR/fake-pinentry"
  cat >"$fake" <<'EOF'
#!/usr/bin/env bash
desc=""
echo "OK Pleased to meet you"
while IFS= read -r line; do
  case "$line" in
    SETDESC*) desc=$line && echo OK ;;
    GETPIN*)
      if [[ "$desc" == *[Nn]ew* ]]; then
        echo OK
      else
        printf 'D testpass123\nOK\n'
      fi
      ;;
    BYE*) echo "OK closing connection" && exit 0 ;;
    *) echo OK ;;
  esac
done
EOF
  chmod +x "$fake"
  echo "pinentry-program $fake" >>"$GNUPGHOME/gpg-agent.conf"
}

# === Key type detection ===

@test "gpg tool: lists a signing subkey as ssb with [S]" {
  key_info=$(gpg --list-secret-keys --keyid-format long 2>/dev/null)
  echo "$key_info" | grep -q "^ssb"
  echo "$key_info" | grep "^ssb" | grep -q "\[S\]"
}

@test "gpg tool: lists a subkey and its master key apart" {
  key_info=$(gpg --list-secret-keys --keyid-format long "$NOPASS_SUBKEY_ID" 2>/dev/null)
  echo "$key_info" | grep "^ssb" | grep -q "$NOPASS_SUBKEY_ID"
  echo "$key_info" | grep "^sec" | grep -q "$NOPASS_MASTER_ID"
}

# === Passphrase detection as setup.sh does it ===

@test "gpg tool: signs with --pinentry-mode error for a key without passphrase" {
  gpgconf --kill gpg-agent 2>/dev/null || true
  echo "test" | gpg --batch --pinentry-mode error --sign --local-user "$NOPASS_SUBKEY_ID" >/dev/null 2>&1
}

# gpg asks for the passphrase and gets no pinentry, as opposed to a key it
# does not find
@test "gpg tool: fails with No pinentry for a subkey with passphrase" {
  gpgconf --kill gpg-agent 2>/dev/null || true
  run bash -c "echo test | gpg --batch --pinentry-mode error --sign --local-user '$WITHPASS_SUBKEY_ID' 2>&1 >/dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"signing failed: No pinentry"* ]]
}

@test "gpg tool: fails with No pinentry for a master key with passphrase" {
  gpgconf --kill gpg-agent 2>/dev/null || true
  run bash -c "echo test | gpg --batch --pinentry-mode error --sign --local-user '$WITHPASS_MASTER_ID' 2>&1 >/dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"signing failed: No pinentry"* ]]
}

# === Passphrase strip of setup.sh ===

# Without gh, setup.sh prints the copy for the secret
@test "setup gpg: makes a copy of a subkey with a passphrase that signs without one" {
  local verify="$TEST_TMPDIR/verify" key
  use_fake_pinentry
  printf '#!/bin/sh\nexit 1\n' >"$MOCK_DIR/gh"
  chmod +x "$MOCK_DIR/gh"
  ssh-keygen -q -t ed25519 -N "" -f "$TEST_TMPDIR/aur"
  # Should a dialog reach /usr/bin/pinentry, it takes the curses one, which fails without a terminal
  run env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE \
    "$TEST_TMPDIR/scripts/setup.sh" gpg secrets --gpg-key "$WITHPASS_SUBKEY_ID" --ssh-key "$TEST_TMPDIR/aur" <<<y
  [ "$status" -eq 0 ]
  [[ "$output" == *"passphrase-free copy created for CI"* ]]
  key=$(sed -n '/^-----BEGIN PGP PRIVATE KEY BLOCK-----$/,/^-----END PGP PRIVATE KEY BLOCK-----$/p' <<<"$output")
  mkdir -m 0700 "$verify"
  gpg --homedir "$verify" --batch --import <<<"$key"
  gpg --homedir "$verify" --batch --pinentry-mode error --sign --local-user "$WITHPASS_SUBKEY_ID" <<<test >/dev/null
  gpgconf --homedir "$verify" --kill gpg-agent
  # The key of the user keeps its passphrase
  gpgconf --kill gpg-agent
  run ! gpg --batch --pinentry-mode error --sign --local-user "$WITHPASS_SUBKEY_ID" <<<test
  gpgconf --kill gpg-agent
}

# The key gets a second secret subkey without a passphrase, which gpg would export beside the copy
@test "setup gpg secrets: gh gets the secret of the named subkey alone" {
  local packets enc grip
  enc=$(add_subkey withpass@test cv25519 encr testpass123)
  use_fake_pinentry
  grip=$(gpg --batch --with-colons --with-keygrip --list-secret-keys withpass@test |
    awk -F: -v id="$enc" '$1 == "ssb" { mine = $5 == id } $1 == "grp" && mine { print $10; exit }')
  gpgconf --kill gpg-agent
  env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE gpg-connect-agent "PASSWD $grip" /bye
  [[ "$(gpg-connect-agent "KEYINFO $grip" /bye)" == "S KEYINFO $grip D - - - C "* ]]
  gpgconf --kill gpg-agent
  cat >"$MOCK_DIR/gh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  auth) exit 0 ;;
  secret) [[ "\$2" != set ]] || cat >"$TEST_TMPDIR/secret-\$3" ;;
esac
exit 0
EOF
  chmod +x "$MOCK_DIR/gh"
  ssh-keygen -q -t ed25519 -N "" -f "$TEST_TMPDIR/aur"
  run env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE "$TEST_TMPDIR/scripts/setup.sh" gpg secrets \
    --gpg-key "$WITHPASS_SUBKEY_ID" --ssh-key "$TEST_TMPDIR/aur" < <(printf 'y\ny\n')
  [ "$status" -eq 0 ]
  packets=$(gpg --batch --list-packets <"$TEST_TMPDIR/secret-GPG_SIGNING_KEY")
  [ "$(grep -c '^:secret sub key packet:' <<<"$packets")" -eq 1 ]
  [[ "$(awk '/^:secret sub key packet:/ { s = 1 } s && $1 == "keyid:" { print $2; exit }' <<<"$packets")" == "$WITHPASS_SUBKEY_ID" ]]
  gpgconf --kill gpg-agent
}

@test "gpg-real: no-passphrase key needs no stripping" {
  gpgconf --kill gpg-agent 2>/dev/null || true
  # pinentry-mode error succeeds because the key has no passphrase
  echo "test" | gpg --batch --pinentry-mode error --sign --local-user "$NOPASS_SUBKEY_ID" >/dev/null 2>&1
  # The happy path: setup.sh reports "no passphrase, ready for CI"
}

# === Commit signing ===

@test "git tool: signs a commit with a subkey" {
  cd "$AUR_DIR"
  sed -i 's/pkgver=1.0.0/pkgver=2.0.0/' PKGBUILD
  git add PKGBUILD
  git config commit.gpgsign false
  git commit -m "update to 2.0.0"

  git -c user.signingkey="$NOPASS_SUBKEY_ID" \
    -c commit.gpgsign=true \
    commit --amend --no-edit

  git verify-commit HEAD
}

@test "git tool: signs a commit with a master key" {
  cd "$AUR_DIR"
  sed -i 's/pkgver=1.0.0/pkgver=2.5.0/' PKGBUILD
  git add PKGBUILD
  git config commit.gpgsign false
  git commit -m "update to 2.5.0"

  git -c user.signingkey="$NOPASS_MASTER_ID" \
    -c commit.gpgsign=true \
    commit --amend --no-edit

  git verify-commit HEAD
}

@test "git tool: commits without a signature" {
  cd "$AUR_DIR"
  sed -i 's/pkgver=1.0.0/pkgver=3.0.0/' PKGBUILD
  git add PKGBUILD
  git config commit.gpgsign false
  git commit -m "update to 3.0.0"
  git log --oneline -1 | grep -q "update to 3.0.0"
}

@test "git tool: signs a commit with a subkey through --amend" {
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
  git verify-commit HEAD
}

# === aur_commit_push with GPG_KEY_ID ===

# Helper: a bare remote for $AUR_DIR at $TEST_TMPDIR/aur-remote.git, and a
# staged PKGBUILD at 2.0.0
stage_aur_update() {
  git init -q --bare "$TEST_TMPDIR/aur-remote.git"
  git -C "$AUR_DIR" remote add origin "$TEST_TMPDIR/aur-remote.git"
  git -C "$AUR_DIR" push -q -u origin HEAD
  sed -i 's/pkgver=1.0.0/pkgver=2.0.0/' "$AUR_DIR/PKGBUILD"
  git -C "$AUR_DIR" add PKGBUILD
}

@test "aur_commit_push: signs the commit with GPG_KEY_ID" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  stage_aur_update
  GPG_KEY_ID="$NOPASS_SUBKEY_ID" run aur_commit_push "$AUR_DIR" 2.0.0 test
  [ "$status" -eq 0 ]
  [ "$(git -C "$TEST_TMPDIR/aur-remote.git" log -1 --format=%s)" = "2.0.0 release from test" ]
  git -C "$TEST_TMPDIR/aur-remote.git" verify-commit HEAD
}

# gpg-signing.md promises a signature on every commit while a key is set
@test "aur_commit_push: pushes nothing when signing fails" {
  local before
  source "$TEST_TMPDIR/scripts/lib.sh"
  stage_aur_update
  before=$(git -C "$TEST_TMPDIR/aur-remote.git" rev-parse HEAD)
  GPG_KEY_ID=0000000000000000 run aur_commit_push "$AUR_DIR" 2.0.0 test
  [ "$status" -eq 1 ]
  [[ "$output" == *"GPG signing with key 0000000000000000 failed, nothing pushed"* ]]
  [ "$(git -C "$TEST_TMPDIR/aur-remote.git" rev-parse HEAD)" = "$before" ]
}

# === setup.sh GPG step with real keys ===

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

@test "gpg-real: setup.sh refuses a master key" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg \
    --gpg-key "$NOPASS_MASTER_ID" --non-interactive
  [ "$status" -eq 1 ]
  [[ "$output" == *"$NOPASS_MASTER_ID is a primary key"* ]]
}

@test "gpg-real: setup.sh refuses a master key with a passphrase" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg \
    --gpg-key "$WITHPASS_MASTER_ID" --non-interactive
  [ "$status" -eq 1 ]
  [[ "$output" == *"is a primary key"* ]]
  [[ "$output" != *"Cannot remove passphrase"* ]]
}

# gpg selects the primary key for its e-mail address and for its fingerprint with spaces
@test "gpg-real: setup.sh refuses the primary key by its fingerprint with spaces and by e-mail" {
  local fpr
  fpr=$(gpg --list-secret-keys --with-colons "$NOPASS_MASTER_ID" | awk -F: '$1 == "fpr" { print $10; exit }')
  run env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE "$TEST_TMPDIR/scripts/setup.sh" gpg \
    --gpg-key "$(sed -E 's/(.{4})/\1 /g' <<<"$fpr")" --non-interactive
  [ "$status" -eq 1 ]
  [[ "$output" == *"$fpr is a primary key"* ]]
  run env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE "$TEST_TMPDIR/scripts/setup.sh" gpg \
    --gpg-key nopass@test --non-interactive
  [ "$status" -eq 1 ]
  [[ "$output" == *"nopass@test is no key ID or fingerprint in hex"* ]]
}

# gpg makes v5 keys for ed448, and their key IDs are the first 64 bits of the fingerprint
@test "gpg-real: setup.sh refuses the primary key of a v5 key by its key IDs" {
  local keys fpr id
  env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE gpg --batch --compliance=gnupg --pinentry-mode loopback \
    --passphrase '' --quick-gen-key "Test V5 <v5@test>" ed448 sign never 2>/dev/null
  keys=$(gpg --batch --with-colons --list-secret-keys v5@test)
  fpr=$(awk -F: '$1 == "fpr" { print $10; exit }' <<<"$keys")
  id=$(awk -F: '$1 == "sec" { print $5; exit }' <<<"$keys")
  [ "${#fpr}" -eq 64 ]
  [ "$id" = "${fpr:0:16}" ]
  for id in "$id" "${id:0:8}"; do
    run env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE "$TEST_TMPDIR/scripts/setup.sh" gpg \
      --gpg-key "$id" --non-interactive
    [ "$status" -eq 1 ]
    [[ "$output" == *"$id is a primary key"* ]]
  done
}

@test "gpg-real: setup.sh takes a signing subkey of a v5 key by its key IDs" {
  local fpr id
  env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE gpg --batch --compliance=gnupg --pinentry-mode loopback \
    --passphrase '' --quick-gen-key "Test V5 <v5@test>" ed448 cert never 2>/dev/null
  fpr=$(gpg --batch --with-colons --list-secret-keys v5@test | awk -F: '$1 == "fpr" { print $10; exit }')
  env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE gpg --batch --compliance=gnupg --pinentry-mode loopback \
    --passphrase '' --quick-add-key "$fpr" ed448 sign never 2>/dev/null
  id=$(gpg --batch --with-colons --list-secret-keys v5@test | awk -F: '$1 == "ssb" { print $5; exit }')
  for id in "$id" "${id:0:8}"; do
    run env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE "$TEST_TMPDIR/scripts/setup.sh" gpg \
      --gpg-key "$id" --non-interactive
    [ "$status" -eq 0 ]
    [[ "$output" == *"GPG key: $id (no passphrase, ready for CI)"* ]]
  done
}

# gpg signs with another subkey of the key when the ID without ! names a subkey that cannot sign
@test "gpg-real: setup.sh refuses an encryption or authentication subkey" {
  local usage algo id
  for usage in encr auth; do
    algo=ed25519
    [[ "$usage" != encr ]] || algo=cv25519
    id=$(add_subkey nopass@test "$algo" "$usage")
    run env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE "$TEST_TMPDIR/scripts/setup.sh" gpg \
      --gpg-key "$id" --non-interactive
    [ "$status" -eq 1 ]
    [[ "$output" == *"$id cannot sign"* ]]
    [[ "$output" != *"ready for CI"* ]]
  done
}

# secrets alone takes the key ID that the gpg step of an earlier run saved
@test "gpg-real: setup.sh secrets refuses a saved primary key or subkey that cannot sign" {
  local id
  id=$(add_subkey nopass@test cv25519 encr)
  cat >"$MOCK_DIR/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "secret set" ]]; then
  echo "\$3" >>"$TEST_TMPDIR/secrets-set"
  cat >/dev/null
fi
exit 0
EOF
  chmod +x "$MOCK_DIR/gh"

  write_gpg_config "$id"
  run env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE "$TEST_TMPDIR/scripts/setup.sh" secrets --non-interactive
  [ "$status" -eq 1 ]
  [[ "$output" == *"$id cannot sign"* ]]
  write_gpg_config "$NOPASS_MASTER_ID"
  run env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE "$TEST_TMPDIR/scripts/setup.sh" secrets --non-interactive
  [ "$status" -eq 1 ]
  [[ "$output" == *"$NOPASS_MASTER_ID is a primary key"* ]]
  [ ! -e "$TEST_TMPDIR/secrets-set" ]
}

@test "gpg-real: setup.sh verify signs with the saved subkey alone" {
  local id
  id=$(add_subkey nopass@test cv25519 encr)
  write_gpg_config "$id"
  run env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE "$TEST_TMPDIR/scripts/setup.sh" verify --non-interactive
  [[ "$output" == *"GPG: cannot sign with $id"* ]]
  [[ "$output" != *"GPG: signing works"* ]]
}

@test "gpg-real: setup.sh rejects nonexistent key" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg \
    --gpg-key "0000000000000999" --non-interactive
  [ "$status" -ne 0 ]
  [[ "$output" == *"Key not found"* ]]
}

@test "gpg-real: setup.sh skips GPG in non-interactive without --gpg-key" {
  run "$TEST_TMPDIR/scripts/setup.sh" gpg --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"GPG signing skipped"* ]]
}

@test "gpg tool: fails to sign with a key it does not hold" {
  run bash -c "echo test | gpg --batch --sign --armor --local-user 'NONEXISTENT999' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *'skipped "NONEXISTENT999": No secret key'* ]]
}

# === Full setup.sh run with real keys ===

@test "gpg-real: full setup with no-passphrase key" {
  cat >"$TEST_TMPDIR/.aurtomator.conf" <<EOF
GIT_AUTHOR_NAME="Test"
GIT_AUTHOR_EMAIL="test@test.com"
AUR_SSH_KEY="$TEST_TMPDIR/ssh/aur.pem"
EOF

  run "$TEST_TMPDIR/scripts/setup.sh" gpg \
    --gpg-key "$NOPASS_SUBKEY_ID" --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"no passphrase, ready for CI"* ]]
  grep -qx "GPG_KEY_ID='$NOPASS_SUBKEY_ID'" "$TEST_TMPDIR/.aurtomator.conf"
}

@test "gpg-real: config clears GPG_KEY_ID when passphrase key skipped" {
  cat >"$TEST_TMPDIR/.aurtomator.conf" <<EOF
GIT_AUTHOR_NAME="Test"
GIT_AUTHOR_EMAIL="test@test.com"
AUR_SSH_KEY="$TEST_TMPDIR/ssh/aur.pem"
EOF

  run "$TEST_TMPDIR/scripts/setup.sh" gpg \
    --gpg-key "$WITHPASS_SUBKEY_ID" --non-interactive
  [ "$status" -eq 0 ]
  grep -qx "GPG_KEY_ID=''" "$TEST_TMPDIR/.aurtomator.conf"
}
