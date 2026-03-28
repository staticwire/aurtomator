#!/usr/bin/env bats

load helpers/setup.sh

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

# === lib.sh ===

@test "lib.sh: pkg_file resolves existing package" {
  create_test_package "mypkg" "github-release" "upstream:
  type: github
  project: owner/repo"

  source "$TEST_TMPDIR/scripts/lib.sh"
  run pkg_file "mypkg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"packages/mypkg.yml" ]]
}

@test "lib.sh: pkg_file fails for missing package" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  run pkg_file "nonexistent"
  [ "$status" -ne 0 ]
}

@test "lib.sh: pkg_get reads YAML field" {
  create_test_package "mypkg" "github-release" "upstream:
  type: github
  project: owner/repo"

  source "$TEST_TMPDIR/scripts/lib.sh"
  run pkg_get "$TEST_TMPDIR/packages/mypkg.yml" .strategy
  [ "$status" -eq 0 ]
  [ "$output" = "github-release" ]
}

@test "lib.sh: pkg_get reads nested field" {
  create_test_package "mypkg" "github-release" "upstream:
  type: github
  project: owner/repo"

  source "$TEST_TMPDIR/scripts/lib.sh"
  run pkg_get "$TEST_TMPDIR/packages/mypkg.yml" .upstream.project
  [ "$status" -eq 0 ]
  [ "$output" = "owner/repo" ]
}

# === check-update.sh ===

@test "check-update: detects new version" {
  create_test_package "mypkg" "github-release" "upstream:
  type: github
  project: owner/repo
current: '1.0.0'"

  # check-update outputs version to stdout, logs to stderr
  result=$("$TEST_TMPDIR/scripts/check-update.sh" "mypkg" 2>/dev/null)
  [ "$result" = "2.0.0" ]
}

@test "check-update: returns empty when up to date" {
  create_test_package "mypkg" "github-release" "upstream:
  type: github
  project: owner/repo
current: '2.0.0'"

  result=$("$TEST_TMPDIR/scripts/check-update.sh" "mypkg" 2>/dev/null)
  [ -z "$result" ]
}

@test "check-update: fails on nonexistent package" {
  run "$TEST_TMPDIR/scripts/check-update.sh" "nonexistent"
  [ "$status" -ne 0 ]
}

# === check-all.sh ===

@test "check-all: processes multiple packages" {
  create_test_package "pkg-a" "github-release" "upstream:
  type: github
  project: owner/repo
current: '2.0.0'"

  create_test_package "pkg-b" "pypi" "upstream:
  registry: requests
current: '3.2.1'"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checked: 2"* ]]
  [[ "$output" == *"Errors: 0"* ]]
}

@test "check-all: writes status files" {
  create_test_package "pkg-a" "github-release" "upstream:
  type: github
  project: owner/repo
current: '2.0.0'"

  "$TEST_TMPDIR/scripts/check-all.sh" 2>/dev/null || true
  [ -f "$TEST_TMPDIR/.status/pkg-a" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-a")" = "up_to_date" ]
}

@test "check-all: detects available update in status" {
  create_test_package "pkg-a" "github-release" "upstream:
  type: github
  project: owner/repo
current: '1.0.0'"

  "$TEST_TMPDIR/scripts/check-all.sh" 2>/dev/null || true
  [ -f "$TEST_TMPDIR/.status/pkg-a" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-a")" = "new_version: 2.0.0" ]
}

@test "check-all: writes error count" {
  create_test_package "pkg-a" "github-release" "upstream:
  type: github
  project: owner/repo
current: '2.0.0'"

  "$TEST_TMPDIR/scripts/check-all.sh" 2>/dev/null || true
  [ -f "$TEST_TMPDIR/.status/_error_count" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "0" ]
}

@test "check-all: reports errors for broken packages" {
  # Create package with strategy that will fail (nonexistent strategy)
  cat > "$TEST_TMPDIR/packages/broken.yml" <<EOF
name: broken
strategy: nonexistent-strategy
upstream:
  project: nope
EOF

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [[ "$output" == *"Errors: 1"* ]]
}

@test "check-all: handles empty packages dir" {
  rm -f "$TEST_TMPDIR/packages/"*.yml
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checked: 0"* ]]
}

# === update-readme.sh ===

@test "update-readme: generates status table" {
  create_test_package "pkg-a" "github-release" "upstream:
  type: github
  project: owner/repo
current: '2.0.0'"

  # Create minimal README with markers
  cat > "$TEST_TMPDIR/README.md" <<'EOF'
# test
<!-- PACKAGES:START -->
old content
<!-- PACKAGES:END -->
EOF

  # Init git repo for badge detection
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]

  # Check table was generated
  grep -q "pkg-a" "$TEST_TMPDIR/README.md"
  grep -q "github-release" "$TEST_TMPDIR/README.md"
}

@test "update-readme: shows failed status from .status/" {
  create_test_package "pkg-fail" "github-release" "upstream:
  type: github
  project: owner/repo
current: '1.0.0'"

  echo "check_failed: timeout" >"$TEST_TMPDIR/.status/pkg-fail"

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
# test
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF

  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null
  grep -q "failed" "$TEST_TMPDIR/README.md"
}

# === lib.sh: warn_maintainer_line ===

@test "lib.sh: warn_maintainer_line warns when missing" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat >"$TEST_TMPDIR/PKGBUILD" <<'EOF'
pkgname=test
pkgver=1.0.0
EOF
  stderr=$(warn_maintainer_line "$TEST_TMPDIR/PKGBUILD" 2>&1)
  [[ "$stderr" == *"missing"*"Maintainer"* ]]
}

@test "lib.sh: warn_maintainer_line silent when present" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat >"$TEST_TMPDIR/PKGBUILD" <<'EOF'
# Maintainer: Someone <someone at example dot com>
pkgname=test
pkgver=1.0.0
EOF
  stderr=$(warn_maintainer_line "$TEST_TMPDIR/PKGBUILD" 2>&1)
  [[ -z "$stderr" ]]
}

# === lib.sh: additional coverage ===

@test "lib.sh: pkg_set writes field to YAML" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo"

  source "$TEST_TMPDIR/scripts/lib.sh"
  pkg_set "$TEST_TMPDIR/packages/mypkg.yml" .current '"2.0.0"'
  result=$(pkg_get "$TEST_TMPDIR/packages/mypkg.yml" .current)
  [ "$result" = "2.0.0" ]
}

@test "lib.sh: pkg_set overwrites existing field" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"

  source "$TEST_TMPDIR/scripts/lib.sh"
  pkg_set "$TEST_TMPDIR/packages/mypkg.yml" .current '"3.0.0"'
  result=$(pkg_get "$TEST_TMPDIR/packages/mypkg.yml" .current)
  [ "$result" = "3.0.0" ]
}

@test "lib.sh: pkg_get returns null for missing field" {
  create_test_package "mypkg" "github-release" ""

  source "$TEST_TMPDIR/scripts/lib.sh"
  run pkg_get "$TEST_TMPDIR/packages/mypkg.yml" .nonexistent
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "lib.sh: pkg_get with fallback operator" {
  create_test_package "mypkg" "github-release" ""

  source "$TEST_TMPDIR/scripts/lib.sh"
  run pkg_get "$TEST_TMPDIR/packages/mypkg.yml" '.current // ""'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "lib.sh: require_cmd succeeds for existing command" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  # bash always exists
  run require_cmd bash
  [ "$status" -eq 0 ]
}

@test "lib.sh: require_cmd fails for missing command" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  run require_cmd nonexistent_command_xyz_999
  [ "$status" -ne 0 ]
  [[ "$output" == *"Required command not found"* ]]
}

@test "lib.sh: load_config sources variables" {
  cat >"$TEST_TMPDIR/.aurtomator.conf" <<'EOF'
GPG_KEY_ID="TESTKEY123"
MAINTAINER="test user"
EOF

  run bash -c "
    export AURTOMATOR_DIR='$TEST_TMPDIR'
    source '$TEST_TMPDIR/scripts/lib.sh'
    load_config
    echo \"GPG=\$GPG_KEY_ID\"
    echo \"MAINT=\$MAINTAINER\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"GPG=TESTKEY123"* ]]
  [[ "$output" == *"MAINT=test user"* ]]
}

@test "lib.sh: load_config succeeds when no config file" {
  rm -f "$TEST_TMPDIR/.aurtomator.conf"

  run bash -c "
    export AURTOMATOR_DIR='$TEST_TMPDIR'
    source '$TEST_TMPDIR/scripts/lib.sh'
    load_config
    echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "lib.sh: log functions write to stderr" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  # Capture stderr only — stdout should be empty
  stdout=$(log_ok "test message" 2>/dev/null)
  [ -z "$stdout" ]
}

@test "lib.sh: log_ok contains message" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  stderr=$(log_ok "hello world" 2>&1)
  [[ "$stderr" == *"hello world"* ]]
}

@test "lib.sh: log_err contains message" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  stderr=$(log_err "bad thing" 2>&1)
  [[ "$stderr" == *"bad thing"* ]]
}

@test "lib.sh: log_warn contains message" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  stderr=$(log_warn "careful" 2>&1)
  [[ "$stderr" == *"careful"* ]]
}

@test "lib.sh: log_info contains message" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  stderr=$(log_info "doing stuff" 2>&1)
  [[ "$stderr" == *"doing stuff"* ]]
}

# === check-update.sh: additional coverage ===

@test "check-update: fails without arguments" {
  run "$TEST_TMPDIR/scripts/check-update.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "check-update: fails when strategy not executable" {
  create_test_package "badstrat" "nonexistent-strategy" "upstream:
  project: owner/repo"

  run "$TEST_TMPDIR/scripts/check-update.sh" "badstrat"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Strategy not found"* ]]
}

@test "check-update: reports when no current version set" {
  create_test_package "newpkg" "github-release" "upstream:
  project: owner/repo"

  result=$("$TEST_TMPDIR/scripts/check-update.sh" "newpkg" 2>/dev/null)
  [ "$result" = "2.0.0" ]
}

@test "check-update: fails when strategy returns empty" {
  create_test_package "emptystrat" "empty-test" "upstream:
  project: owner/repo"

  # Create a strategy that outputs nothing
  cat >"$TEST_TMPDIR/strategies/empty-test.sh" <<'EOF'
#!/usr/bin/env bash
echo ""
EOF
  chmod +x "$TEST_TMPDIR/strategies/empty-test.sh"

  run "$TEST_TMPDIR/scripts/check-update.sh" "emptystrat"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty version"* ]]
}

@test "check-update: fails when strategy exits non-zero" {
  create_test_package "failstrat" "failing-test" "upstream:
  project: owner/repo"

  cat >"$TEST_TMPDIR/strategies/failing-test.sh" <<'EOF'
#!/usr/bin/env bash
echo "connection timeout" >&2
exit 1
EOF
  chmod +x "$TEST_TMPDIR/strategies/failing-test.sh"

  run "$TEST_TMPDIR/scripts/check-update.sh" "failstrat"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Strategy failed"* ]]
}

# === check-all.sh: additional coverage ===

@test "check-all: --help exits 0" {
  run "$TEST_TMPDIR/scripts/check-all.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"check-all.sh"* ]]
}

@test "check-all: rejects unknown flag" {
  run "$TEST_TMPDIR/scripts/check-all.sh" --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "check-all: continues after one package error" {
  create_test_package "aaa-good" "github-release" "upstream:
  type: github
  project: owner/repo
current: '2.0.0'"

  cat >"$TEST_TMPDIR/packages/bbb-broken.yml" <<EOF
name: bbb-broken
strategy: nonexistent-strategy
upstream:
  project: nope
EOF

  create_test_package "ccc-good" "pypi" "upstream:
  registry: requests
current: '3.2.1'"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [[ "$output" == *"Checked: 3"* ]]
  [[ "$output" == *"Errors: 1"* ]]
  # Both good packages should have status files
  [ -f "$TEST_TMPDIR/.status/aaa-good" ]
  [ -f "$TEST_TMPDIR/.status/ccc-good" ]
}

@test "check-all: writes check_failed status for broken package" {
  cat >"$TEST_TMPDIR/packages/broken.yml" <<EOF
name: broken
strategy: nonexistent-strategy
upstream:
  project: nope
EOF

  "$TEST_TMPDIR/scripts/check-all.sh" 2>/dev/null || true
  [ -f "$TEST_TMPDIR/.status/broken" ]
  [[ "$(cat "$TEST_TMPDIR/.status/broken")" == check_failed:* ]]
}

@test "check-all: resets .status/ dir each run" {
  # Create stale status file
  mkdir -p "$TEST_TMPDIR/.status"
  echo "old" >"$TEST_TMPDIR/.status/stale-pkg"

  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '2.0.0'"

  "$TEST_TMPDIR/scripts/check-all.sh" 2>/dev/null || true
  # Stale file should be gone
  [ ! -f "$TEST_TMPDIR/.status/stale-pkg" ]
  # Current package should exist
  [ -f "$TEST_TMPDIR/.status/pkg-a" ]
}

@test "check-all: error count reflects actual errors" {
  cat >"$TEST_TMPDIR/packages/broken1.yml" <<EOF
name: broken1
strategy: nonexistent1
upstream: {}
EOF
  cat >"$TEST_TMPDIR/packages/broken2.yml" <<EOF
name: broken2
strategy: nonexistent2
upstream: {}
EOF

  "$TEST_TMPDIR/scripts/check-all.sh" 2>/dev/null || true
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "2" ]
}

# === update-readme.sh: additional coverage ===

@test "update-readme: fails if README.md missing" {
  rm -f "$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"README.md not found"* ]]
}

@test "update-readme: fails if START_MARKER missing" {
  cat >"$TEST_TMPDIR/README.md" <<'EOF'
# test
no markers here
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PACKAGES:START"* ]]
}

@test "update-readme: badge is green when all packages ok" {
  create_test_package "pkg-ok" "github-release" "upstream:
  project: owner/repo
current: '2.0.0'"

  echo "up_to_date" >"$TEST_TMPDIR/.status/pkg-ok"

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null
  grep -q "brightgreen" "$TEST_TMPDIR/README.md"
}

@test "update-readme: badge is red when package fails" {
  create_test_package "pkg-bad" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"

  echo "check_failed: error" >"$TEST_TMPDIR/.status/pkg-bad"

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null
  grep -q "red" "$TEST_TMPDIR/README.md"
}

@test "update-readme: shows 'No packages' row when empty" {
  rm -f "$TEST_TMPDIR/packages/"*.yml

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null
  grep -q "No packages configured" "$TEST_TMPDIR/README.md"
}

@test "update-readme: preserves content outside markers" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
# Header Before
some content
<!-- PACKAGES:START -->
old table
<!-- PACKAGES:END -->
# Footer After
more content
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null
  grep -q "# Header Before" "$TEST_TMPDIR/README.md"
  grep -q "# Footer After" "$TEST_TMPDIR/README.md"
  # Old content should be replaced
  ! grep -q "old table" "$TEST_TMPDIR/README.md"
}

@test "update-readme: shows updated status" {
  create_test_package "pkg-upd" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"

  echo "updated: 2.0.0" >"$TEST_TMPDIR/.status/pkg-upd"

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null
  grep -q "updated to 2.0.0" "$TEST_TMPDIR/README.md"
}

@test "update-readme: shows new_version status" {
  create_test_package "pkg-new" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"

  echo "new_version: 3.0.0" >"$TEST_TMPDIR/.status/pkg-new"

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null
  grep -q "3.0.0 available" "$TEST_TMPDIR/README.md"
}

@test "update-readme: shows workflow badge with github origin" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  git -C "$TEST_TMPDIR" remote add origin "https://github.com/myuser/myrepo.git"
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null
  grep -q "actions/workflows" "$TEST_TMPDIR/README.md"
}

# === update-readme.sh: last_updated column ===

@test "update-readme: shows last_updated date in table" {
  create_test_package "pkg-dated" "github-release" "upstream:
  project: owner/repo
current: '2.0.0'
last_updated: '2026-03-28'"

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null
  grep -q "2026-03-28" "$TEST_TMPDIR/README.md"
}

@test "update-readme: shows dash when last_updated missing" {
  create_test_package "pkg-new" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null
  # Table should have 5 columns with dash for missing last_updated
  grep -q "| — |" "$TEST_TMPDIR/README.md"
}

# === update-pkg.sh: argument validation ===

@test "update-pkg: fails without arguments" {
  run "$TEST_TMPDIR/scripts/update-pkg.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "update-pkg: fails without version argument" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/update-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "update-pkg: fails on nonexistent package" {
  run "$TEST_TMPDIR/scripts/update-pkg.sh" "nonexistent" "1.0.0"
  [ "$status" -ne 0 ]
}

@test "update-pkg: fails when AUR clone fails" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo"

  # Mock git to fail on clone (but pass other git operations)
  cat >"$TEST_TMPDIR/mock-bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "$1" == "clone" ]]; then
  echo "fatal: unable to access repo" >&2
  exit 128
fi
exec /usr/bin/git "$@"
MOCKEOF
  chmod +x "$TEST_TMPDIR/mock-bin/git"

  run "$TEST_TMPDIR/scripts/update-pkg.sh" "mypkg" "2.0.0"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to clone"* ]]
}

# === validate-pkg.sh ===

@test "validate-pkg: invoked from check pipeline context" {
  create_test_package "valid-pkg" "github-release" "upstream:
  project: owner/repo"

  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "valid-pkg"
  [ "$status" -eq 0 ]
}

@test "validate-pkg: rejects invalid config from check pipeline context" {
  create_test_package "bad-pkg" "nonexistent" ""

  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "bad-pkg"
  [ "$status" -ne 0 ]
}

# === updpkgsums dependency ===

@test "update-pkg: fails if updpkgsums missing for non-VCS package" {
  create_test_package "test-checksums" "github-release" "upstream:
  type: github
  project: owner/repo
current: '1.0.0'"

  # Create a fake AUR repo with PKGBUILD that has real checksums
  aur_dir="$TEST_TMPDIR/aur-test-checksums"
  mkdir -p "$aur_dir"
  git -C "$aur_dir" init -q
  git -C "$aur_dir" config user.name "test"
  git -C "$aur_dir" config user.email "test@test"
  git -C "$aur_dir" config commit.gpgsign false
  cat > "$aur_dir/PKGBUILD" <<'EOF'
pkgname=test-checksums
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('any')
url="https://example.com"
license=('MIT')
source=("https://example.com/test-1.0.0.tar.gz")
b2sums=('abc123')
EOF
  git -C "$aur_dir" add . && git -C "$aur_dir" commit -q -m "init"

  # Remove updpkgsums from PATH to simulate CI without pacman-contrib
  CLEAN_PATH=$(echo "$PATH" | tr ':' '\n' | grep -v mock | tr '\n' ':')
  
  # Mock git clone to return our fake AUR dir
  mkdir -p "$MOCK_DIR"
  cat > "$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  # Run update-pkg without updpkgsums — should fail
  run env PATH="$MOCK_DIR:/usr/bin" "$TEST_TMPDIR/scripts/update-pkg.sh" "test-checksums" "2.0.0"
  [ "$status" -ne 0 ]
}
