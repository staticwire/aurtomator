#!/usr/bin/env bats

load helpers/setup.sh

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

# === test environment ===

@test "setup_test_env: git keeps its global config in the test directory" {
  git config --global --add aurtomator.probe 1
  [ "$(git config -f "$TEST_TMPDIR/gitconfig" aurtomator.probe)" = 1 ]
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
  [[ "$output" == *"Package not found: "*"/packages/nonexistent.yml"* ]]
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

# === audit_pkgbuild ===

@test "audit_pkgbuild: passes normal binary package" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-bin
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/test-${pkgver}.tar.gz")
sha256sums=('abc123')
EOF
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
  [ "$status" -eq 0 ]
}

# The shape of liblinear on the AUR
@test "audit_pkgbuild: passes a split package" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgbase=test-split
pkgname=(test-split python-test-split)
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/$pkgbase-$pkgver.tar.gz")
sha256sums=('abc123')

package_test-split() {
  install -Dm755 test-split "$pkgdir/usr/bin/test-split"
}

package_python-test-split() {
  depends=("test-split=$pkgver")
  install -Dm644 test_split.py "$pkgdir/usr/lib/test_split.py"
}
EOF
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
  [ "$status" -eq 0 ]
}

@test "audit_pkgbuild: blocks pkgver() with non-git-latest strategy" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-git
pkgver=r100.abc1234
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("git+https://example.com/repo.git")
sha256sums=('SKIP')
pkgver() {
  cd "${srcdir}/${pkgname}"
  git describe --long --tags
}
EOF
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pkgver() function"* ]]
}

@test "audit_pkgbuild: allows pkgver() with git-latest strategy" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-git
pkgver=r100.abc1234
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("git+https://example.com/repo.git")
sha256sums=('SKIP')
pkgver() {
  cd "${srcdir}/${pkgname}"
  printf "r%s.%s" "$(git rev-list --count HEAD)" "$(git rev-parse --short=7 HEAD)"
}
EOF
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "git-latest"
  [ "$status" -eq 0 ]
}

@test "audit_pkgbuild: warns on patches in source" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-patched
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/test-${pkgver}.tar.gz"
        "fix-build.patch")
sha256sums=('abc123' 'def456')
EOF
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
  [ "$status" -eq 2 ]
  [[ "$output" == *"patches"* ]]
}

@test "audit_pkgbuild: blocks mixed SKIP and real checksums with remote sources" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-mixed
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("git+https://example.com/repo.git"
        "https://example.com/config-${pkgver}.tar.gz")
sha256sums=('SKIP'
            'abc123')
b2sums=('SKIP'
        'def456')
EOF
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "git-latest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP checksums mixed with real hashes for remote"* ]]
}

@test "audit_pkgbuild: allows SKIP + real checksums for local files (nightly pattern)" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  # Typical nightly-bin pattern: SKIP for the remote nightly binary,
  # real hashes for local files (e.g. .vim, .install) shipped in the AUR repo
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-nightly
pkgver=0.13.0
pkgrel=1
pkgdesc="nightly test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/nightly/app-linux-x86_64.tar.gz"
        "app.desktop"
        "app-sysinit.vim")
b2sums=('SKIP'
        'd0871e240bd9c7de7d898e1fba95364f4c4a12dbb3ac40892bbf93a49eb0e8cc'
        '6ed647c3a4c0907a60060fa61117d484aa091c69c73dda1f0a99aa4e67870ae2')
EOF
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-nightly"
  [ "$status" -eq 0 ]
}

@test "audit_pkgbuild: allows pkgver() with github-nightly strategy" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-nightly-pkgver
pkgver=0.13.0
pkgrel=1
pkgdesc="nightly with pkgver"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/nightly.tar.gz")
b2sums=('SKIP')
pkgver() {
  cd "${srcdir}/app"
  ./bin/app --version | head -1
}
EOF
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-nightly"
  [ "$status" -eq 0 ]
}

@test "audit_pkgbuild: passes VCS package with only SKIP checksums" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-vcs
pkgver=r100.abc1234
pkgrel=1
pkgdesc="test"
arch=('any')
url="https://example.com"
license=('MIT')
source=("git+https://example.com/repo.git")
sha256sums=('SKIP')
EOF
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "git-latest"
  [ "$status" -eq 0 ]
}

@test "audit_pkgbuild: blocks mixed SKIP and real checksums in arch-specific arrays" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-mixed-arch
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source_x86_64=("git+https://example.com/repo.git"
               "https://example.com/data-${pkgver}.tar.gz")
sha256sums_x86_64=('SKIP'
                   'abc123')
EOF
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "git-latest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP checksums mixed with real hashes for remote"* ]]
}

@test "audit_pkgbuild: blocks a real remote hash listed before SKIP" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-mixed-order
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/data-${pkgver}.tar.gz"
        "git+https://example.com/repo.git")
sha256sums=('abc123'
            'SKIP')
EOF
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "git-latest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP checksums mixed with real hashes for remote"* ]]
}

# The tarball and signature pair of lib32-gettext
@test "audit_pkgbuild: allows the SKIP of a signature next to a real hash" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  local ext
  for ext in sig sign asc; do
    cat >"$TEST_TMPDIR/test.PKGBUILD" <<EOF
pkgname=test-signed
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/test-\${pkgver}.tar.gz"{,.$ext})
sha512sums=('abc123'
            'SKIP')
EOF
    run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
    [ "$status" -eq 0 ]
  done
}

@test "audit_pkgbuild: allows a signature saved under a name before ::" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-signed
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/test-${pkgver}.tar.gz"
        "test-${pkgver}.tar.gz.sig::https://example.com/signature?v=${pkgver}")
sha512sums=('abc123'
            'SKIP')
EOF
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
  [ "$status" -eq 0 ]
}

# makepkg reads the name before :: and the whole entry without one
@test "audit_pkgbuild: blocks the SKIP of a source makepkg would hash" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  local sig
  for sig in "test.key::https://example.com/test.sig" "https://example.com/test.sig?raw=1"; do
    cat >"$TEST_TMPDIR/test.PKGBUILD" <<EOF
pkgname=test-signed
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/test-\${pkgver}.tar.gz"
        "$sig")
sha512sums=('abc123'
            'SKIP')
EOF
    run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
    [ "$status" -eq 1 ]
    [[ "$output" == *"SKIP checksums mixed with real hashes for remote"* ]]
  done
}

# === has_skip_checksums ===

@test "has_skip_checksums: finds SKIP in arch-specific arrays" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-arch-skip
pkgver=1.0.0
pkgrel=1
arch=('x86_64' 'aarch64')
source_x86_64=("https://example.com/nightly-x86_64.tar.gz")
source_aarch64=("https://example.com/nightly-aarch64.tar.gz")
b2sums_x86_64=('SKIP')
b2sums_aarch64=('SKIP')
EOF
  run has_skip_checksums "$TEST_TMPDIR/test.PKGBUILD"
  [ "$status" -eq 0 ]
}

@test "has_skip_checksums: finds SKIP after a real hash" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-late-skip
pkgver=1.0.0
pkgrel=1
arch=('any')
source=("app.desktop"
        "https://example.com/nightly.tar.gz")
sha256sums=('abc123'
            'SKIP')
EOF
  run has_skip_checksums "$TEST_TMPDIR/test.PKGBUILD"
  [ "$status" -eq 0 ]
}

@test "has_skip_checksums: returns 1 without SKIP" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-no-skip
pkgver=1.0.0
pkgrel=1
arch=('x86_64')
source=("https://example.com/app-${pkgver}.tar.gz")
source_x86_64=("https://example.com/app-${pkgver}-x86_64.tar.gz")
sha256sums=('abc123')
sha256sums_x86_64=('def456')
EOF
  run has_skip_checksums "$TEST_TMPDIR/test.PKGBUILD"
  [ "$status" -eq 1 ]
}

@test "has_skip_checksums: returns 1 when every SKIP belongs to a signature" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-signed
pkgver=1.0.0
pkgrel=1
arch=('x86_64')
source=("https://example.com/app-${pkgver}.tar.gz"{,.sig})
source_x86_64=("https://example.com/app-${pkgver}-x86_64.tar.gz"{,.asc})
sha256sums=('abc123' 'SKIP')
sha256sums_x86_64=('def456' 'SKIP')
EOF
  run has_skip_checksums "$TEST_TMPDIR/test.PKGBUILD"
  [ "$status" -eq 1 ]
}

@test "has_skip_checksums: finds a VCS SKIP next to the SKIP of a signature" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat > "$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-signed-vcs
pkgver=r100.abc1234
pkgrel=1
arch=('any')
source=("https://example.com/app.tar.gz.sig"
        "git+https://example.com/repo.git")
sha256sums=('SKIP' 'SKIP')
EOF
  run has_skip_checksums "$TEST_TMPDIR/test.PKGBUILD"
  [ "$status" -eq 0 ]
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
  [[ "$output" == *"Package not found: "*"/packages/nonexistent.yml"* ]]
}

# === validate_source_urls ===

@test "lib.sh: validate_source_urls checks every source_<arch> array" {
  cat >"$TEST_TMPDIR/PKGBUILD" <<'EOF'
pkgname=test-arches
pkgver=1.0.0
pkgrel=1
arch=('armv7h' 'riscv64')
source_armv7h=("https://example.com/test-1.0.0-armv7h.tar.gz")
source_riscv64=("https://example.com/test-1.0.0-riscv64.tar.gz")
sha256sums_armv7h=('abc123')
sha256sums_riscv64=('abc123')
EOF

  # HEAD requests get an HTML answer and every URL asked for is logged
  cat >"$MOCK_DIR/curl" <<MOCKCURL
#!/usr/bin/env bash
echo "\${@: -1}" >>"$TEST_TMPDIR/curl-urls.log"
printf '200 text/html; charset=utf-8'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"

  run bash -c 'source "$0/scripts/lib.sh"; validate_source_urls "$1"' "$TEST_TMPDIR" "$TEST_TMPDIR/PKGBUILD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"test-1.0.0-armv7h.tar.gz"* ]]
  [[ "$output" == *"test-1.0.0-riscv64.tar.gz"* ]]
  grep -q "test-1.0.0-armv7h.tar.gz" "$TEST_TMPDIR/curl-urls.log"
  grep -q "test-1.0.0-riscv64.tar.gz" "$TEST_TMPDIR/curl-urls.log"
}

# The server of a source chooses the headers. bash evaluates an operand of
# -ge as arithmetic, and an array subscript there runs a command.
@test "lib.sh: validate_source_urls runs nothing a source server sends" {
  cat >"$TEST_TMPDIR/PKGBUILD" <<'EOF'
pkgname=test-status
pkgver=1.0.0
pkgrel=1
arch=('x86_64')
source=("https://example.com/test-1.0.0.tar.gz")
sha256sums=('abc123')
EOF
  # The payload in both places a status was read from: the first word of
  # curl -w, and the status line of curl -I
  cat >"$MOCK_DIR/curl" <<MOCKCURL
#!/usr/bin/env bash
printf 'BASH_VERSINFO[\$(id>%s)] text/plain\n' "$TEST_TMPDIR/pwned"
printf 'HTTP/1.1 BASH_VERSINFO[\$(id>%s)] OK\n' "$TEST_TMPDIR/pwned"
MOCKCURL
  chmod +x "$MOCK_DIR/curl"

  # Called as update-pkg.sh calls it, where set -e does not apply
  run bash -c 'source "$0/scripts/lib.sh"; validate_source_urls "$1" || exit $?' "$TEST_TMPDIR" "$TEST_TMPDIR/PKGBUILD"
  [ ! -e "$TEST_TMPDIR/pwned" ]
  [ "$status" -eq 1 ]
}

@test "lib.sh: validate_source_urls takes the status and type of the last response" {
  cat >"$TEST_TMPDIR/PKGBUILD" <<'EOF'
pkgname=test-status
pkgver=1.0.0
pkgrel=1
arch=('x86_64')
source=("https://example.com/test-1.0.0.tar.gz")
sha256sums=('abc123')
EOF
  # curl -w prints what curl read from the last response
  cat >"$MOCK_DIR/curl" <<'MOCKCURL'
#!/usr/bin/env bash
[[ " $* " == *" -w %{http_code} %{content_type} "* ]] || exit 99
printf '%s\n' "$CURL_W"
MOCKCURL
  chmod +x "$MOCK_DIR/curl"
  local lib='source "$0/scripts/lib.sh"; validate_source_urls "$1" || exit $?'

  CURL_W="200 application/octet-stream" run bash -c "$lib" "$TEST_TMPDIR" "$TEST_TMPDIR/PKGBUILD"
  [ "$status" -eq 0 ]
  CURL_W="404 application/octet-stream" run bash -c "$lib" "$TEST_TMPDIR" "$TEST_TMPDIR/PKGBUILD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 404"* ]]
  CURL_W="200 Text/HTML; charset=utf-8" run bash -c "$lib" "$TEST_TMPDIR" "$TEST_TMPDIR/PKGBUILD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTML instead of"* ]]
}

# Helper: a PKGBUILD with one source, and a curl that prints $CURL_W and
# exits $CURL_RC. Real curl -s prints the -w text and nothing on stderr
# when it fails.
mock_source_head() {
  cat >"$TEST_TMPDIR/PKGBUILD" <<'EOF'
pkgname=test-status
pkgver=1.0.0
pkgrel=1
arch=('x86_64')
source=("https://example.com/test-1.0.0.tar.gz")
sha256sums=('abc123')
EOF
  cat >"$MOCK_DIR/curl" <<'MOCKCURL'
#!/usr/bin/env bash
printf '%s' "$CURL_W"
exit "$CURL_RC"
MOCKCURL
  chmod +x "$MOCK_DIR/curl"
}

@test "lib.sh: validate_source_urls reports a refused connection (curl exit 7)" {
  mock_source_head
  CURL_RC=7 CURL_W='000 ' run bash -c 'source "$0/scripts/lib.sh"; validate_source_urls "$1" || exit $?' "$TEST_TMPDIR" "$TEST_TMPDIR/PKGBUILD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Source URL unreachable: https://example.com/test-1.0.0.tar.gz"* ]]
}

@test "lib.sh: validate_source_urls reports a timeout (curl exit 28)" {
  mock_source_head
  CURL_RC=28 CURL_W='000 ' run bash -c 'source "$0/scripts/lib.sh"; validate_source_urls "$1" || exit $?' "$TEST_TMPDIR" "$TEST_TMPDIR/PKGBUILD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Source URL unreachable: https://example.com/test-1.0.0.tar.gz"* ]]
}

@test "lib.sh: validate_source_urls reports a redirect loop (curl exit 47)" {
  mock_source_head
  CURL_RC=47 CURL_W='302 text/plain' run bash -c 'source "$0/scripts/lib.sh"; validate_source_urls "$1" || exit $?' "$TEST_TMPDIR" "$TEST_TMPDIR/PKGBUILD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Source URL unreachable: https://example.com/test-1.0.0.tar.gz"* ]]
}

# === http_get ===

@test "lib.sh: http_get tries a transient failure again" {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*"\n' >"$MOCK_DIR/curl"
  chmod +x "$MOCK_DIR/curl"
  source "$TEST_TMPDIR/scripts/lib.sh"
  run http_get https://example.invalid/a --max-redirs 5
  [ "$status" -eq 0 ]
  [ "$output" = "-sfL --max-time 30 --retry 2 --retry-delay 5 --retry-connrefused -A aurtomator/1.0 --max-redirs 5 https://example.invalid/a" ]
}

# script from util-linux runs the command on a terminal of its own
@test "lib.sh: colors the log on a terminal" {
  printf 'source "$1/scripts/lib.sh"\nlog_ok done\n' >"$TEST_TMPDIR/color.sh"
  run script -qec "bash $TEST_TMPDIR/color.sh $TEST_TMPDIR" /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\e[0;32m✓\e[0m done'* ]]
}

@test "lib.sh: writes the log without colors elsewhere" {
  run bash -c 'source "$0/scripts/lib.sh"; log_ok done' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "✓ done" ]
}

# === validate_pkgver ===

@test "lib.sh: validate_pkgver accepts versions the strategies produce" {
  for v in 1.13.8 0.13.0+dev+1321+gb169d9376c r480.f0d1962 20260731 2.50 1.0.0_rc1; do
    run bash -c 'source "$0/scripts/lib.sh"; validate_pkgver "$1"' "$TEST_TMPDIR" "$v"
    [ "$status" -eq 0 ]
  done
}

@test "lib.sh: validate_pkgver rejects shell metacharacters" {
  for v in '1.0$(id)' '1.0`id`' '1.0;id' '1.0|id' '1.0&id' '1.0>x' '1.0 2' "1.0'x" '1.0"x' '1.0\x' $'1.0\nx'; do
    run bash -c 'source "$0/scripts/lib.sh"; validate_pkgver "$1"' "$TEST_TMPDIR" "$v"
    [ "$status" -eq 1 ]
    [[ "$output" == *"rejected"* ]]
  done
}

@test "lib.sh: validate_pkgver rejects what makepkg forbids in pkgver" {
  for v in '1.0-1' '1:2.0' '1.0/2'; do
    run bash -c 'source "$0/scripts/lib.sh"; validate_pkgver "$1"' "$TEST_TMPDIR" "$v"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Version string rejected, only A-Za-z0-9 . _ + are allowed"* ]]
  done
  run bash -c 'source "$0/scripts/lib.sh"; validate_pkgver "$1"' "$TEST_TMPDIR" ''
  [ "$status" -eq 1 ]
  [[ "$output" == *"Version string is empty"* ]]
}

@test "lib.sh: validate_pkgver rejects a version without a digit" {
  for v in nightly latest stable . _+.; do
    run bash -c 'source "$0/scripts/lib.sh"; validate_pkgver "$1"' "$TEST_TMPDIR" "$v"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Version string rejected, it holds no digit: '$v'"* ]]
  done
}

@test "lib.sh: validate_pkgver rejects non-ASCII" {
  run bash -c 'source "$0/scripts/lib.sh"; validate_pkgver "$1"' "$TEST_TMPDIR" '1.0в'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Version string rejected, only A-Za-z0-9 . _ + are allowed"* ]]
}

@test "check-update: rejects an injected version from the strategy" {
  cat >"$TEST_TMPDIR/strategies/injected.sh" <<'EOF'
#!/usr/bin/env bash
echo '1.0$(touch "$AURTOMATOR_DIR/pwned")'
EOF
  chmod +x "$TEST_TMPDIR/strategies/injected.sh"
  create_test_package "mypkg" "injected" "current: '1.0'"

  run "$TEST_TMPDIR/scripts/check-update.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"rejected"* ]]
  [ ! -e "$TEST_TMPDIR/pwned" ]
}

# A tag_pattern, a scraped page or a registry can return a word
@test "check-update: rejects a word from the strategy" {
  cat >"$TEST_TMPDIR/strategies/word.sh" <<'EOF'
#!/usr/bin/env bash
echo latest
EOF
  chmod +x "$TEST_TMPDIR/strategies/word.sh"
  create_test_package "mypkg" "word" "current: '1.0'"

  run "$TEST_TMPDIR/scripts/check-update.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Version string rejected, it holds no digit: 'latest'"* ]]
}

@test "update-pkg: refuses an injected version before any git call" {
  cat >"$TEST_TMPDIR/mock-bin/git" <<'EOF'
#!/usr/bin/env bash
touch "$AURTOMATOR_DIR/git-was-called"
exit 0
EOF
  chmod +x "$TEST_TMPDIR/mock-bin/git"
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
current: '1.0'"

  run "$TEST_TMPDIR/scripts/update-pkg.sh" "mypkg" '1.0$(touch pwned)'
  [ "$status" -eq 1 ]
  [[ "$output" == *"rejected"* ]]
  [ ! -e "$TEST_TMPDIR/git-was-called" ]
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

# === project path with a space ===

# Helper: a project at "$TEST_TMPDIR/my project" with the scripts and
# strategies of the test project and one package, pkg, that is up to date
make_spaced_project() {
  SPACED="$TEST_TMPDIR/my project"
  mkdir -p "$SPACED/packages"
  ln -s "$TEST_TMPDIR/scripts" "$SPACED/scripts"
  ln -s "$TEST_TMPDIR/strategies" "$SPACED/strategies"
  printf '%s\n' "name: pkg" "strategy: github-release" "upstream:" "  project: owner/repo" \
    "current: '2.0.0'" >"$SPACED/packages/pkg.yml"
}

@test "check-all: finds the packages of a project whose path has a space" {
  make_spaced_project
  run "$SPACED/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checked: 1, Updated: 0, Errors: 0"* ]]
  [ "$(cat "$SPACED/.status/pkg")" = "up_to_date" ]
}

@test "update-readme: lists the packages of a project whose path has a space" {
  make_spaced_project
  printf '%s\n' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$SPACED/README.md"
  git -C "$SPACED" init -q
  run "$SPACED/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -q '\[pkg\]' "$SPACED/README.md"
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

# The name in a package YAML is the pkgbase. The AUR shows a split package
# under /pkgbase/<name>, and sends /pkgbase/<name> of any other package to
# /packages/<name>.
@test "update-readme: links each package to its pkgbase on the AUR" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '2.0.0'"
  printf '%s\n' "# test" "<!-- PACKAGES:START -->" "<!-- PACKAGES:END -->" >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF '| [pkg-a](https://aur.archlinux.org/pkgbase/pkg-a) |' "$TEST_TMPDIR/README.md"
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
  # Capture stderr only, stdout stays empty
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

@test "check-all: --help prints the whole header" {
  run "$TEST_TMPDIR/scripts/check-all.sh" --help
  [ "$status" -eq 0 ]
  [ "$output" = "$(awk 'NR > 2 && !/^#/ { exit } NR > 2' "$PROJECT_DIR/scripts/check-all.sh")" ]
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
  [[ "$output" == *"Package not found: "*"/packages/nonexistent.yml"* ]]
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

@test "update-pkg: audit blocks pkgver() with wrong strategy" {
  create_test_package "test-vcs-bad" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"

  aur_dir="$TEST_TMPDIR/aur-test-vcs-bad"
  mkdir -p "$aur_dir"
  git -C "$aur_dir" init -q
  git -C "$aur_dir" config user.name "test"
  git -C "$aur_dir" config user.email "test@test"
  git -C "$aur_dir" config commit.gpgsign false
  cat > "$aur_dir/PKGBUILD" <<'EOF'
# Maintainer: test
pkgname=test-vcs-bad
pkgver=r100.abc1234
pkgrel=1
pkgdesc="VCS with wrong strategy"
arch=('any')
url="https://example.com"
license=('MIT')
source=("git+https://example.com/repo.git")
sha256sums=('SKIP')
pkgver() {
  cd "${srcdir}/${pkgname}"
  printf "r%s.%s" "$(git rev-list --count HEAD)" "$(git rev-parse --short=7 HEAD)"
}
EOF
  git -C "$aur_dir" add . && git -C "$aur_dir" commit -q -m "init"

  cat > "$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  run "$TEST_TMPDIR/scripts/update-pkg.sh" "test-vcs-bad" "2.0.0"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pkgver() function"* ]]
}

@test "update-pkg: audit allows pkgver() with git-latest strategy" {
  create_test_package "test-vcs-ok" "git-latest" "upstream:
  type: gitlab
  host: gitlab.example.com
  project: group/project
current: 'r100.abc1234'"

  aur_dir="$TEST_TMPDIR/aur-test-vcs-ok"
  mkdir -p "$aur_dir"
  git -C "$aur_dir" init -q
  git -C "$aur_dir" config user.name "test"
  git -C "$aur_dir" config user.email "test@test"
  git -C "$aur_dir" config commit.gpgsign false
  cat > "$aur_dir/PKGBUILD" <<'EOF'
# Maintainer: test
pkgname=test-vcs-ok
pkgver=r100.abc1234
pkgrel=1
pkgdesc="VCS with correct strategy"
arch=('any')
url="https://example.com"
license=('MIT')
source=("git+https://example.com/repo.git")
sha256sums=('SKIP')
pkgver() {
  cd "${srcdir}/${pkgname}"
  printf "r%s.%s" "$(git rev-list --count HEAD)" "$(git rev-parse --short=7 HEAD)"
}
EOF
  printf '%s\n' "pkgbase = test-vcs-ok" "pkgname = test-vcs-ok" >"$aur_dir/.SRCINFO"
  git -C "$aur_dir" add . && git -C "$aur_dir" commit -q -m "init"
  # A bare remote, so the push of the copied clone succeeds
  git init --bare -q "$TEST_TMPDIR/aur-bare-test-vcs-ok.git"
  git -C "$aur_dir" remote add origin "$TEST_TMPDIR/aur-bare-test-vcs-ok.git"
  git -C "$aur_dir" push -q -u origin HEAD

  cat > "$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  cat > "$MOCK_DIR/makepkg" <<'EOF'
#!/usr/bin/env bash
echo "pkgbase = test-vcs-ok"
echo "pkgname = test-vcs-ok"
EOF
  chmod +x "$MOCK_DIR/makepkg"

  # pkgver() with the git-latest strategy passes the audit
  run "$TEST_TMPDIR/scripts/update-pkg.sh" "test-vcs-ok" "r200.def5678"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pushed test-vcs-ok r200.def5678 to AUR"* ]]
}

@test "update-pkg: validate_source_urls blocks HTML responses" {
  create_test_package "test-html" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"

  aur_dir="$TEST_TMPDIR/aur-test-html"
  mkdir -p "$aur_dir"
  git -C "$aur_dir" init -q
  git -C "$aur_dir" config user.name "test"
  git -C "$aur_dir" config user.email "test@test"
  git -C "$aur_dir" config commit.gpgsign false
  cat > "$aur_dir/PKGBUILD" <<'EOF'
# Maintainer: test
pkgname=test-html
pkgver=1.0.0
pkgrel=1
pkgdesc="test HTML redirect"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/test-${pkgver}.tar.gz")
sha256sums=('abc123')
EOF
  git -C "$aur_dir" add . && git -C "$aur_dir" commit -q -m "init"

  cat > "$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  # Mock curl to return HTML content-type for HEAD requests
  cat > "$MOCK_DIR/curl" <<'MOCKCURL'
#!/usr/bin/env bash
if [[ "$1" == "-sIL" ]]; then
  printf '200 text/html; charset=utf-8'
  exit 0
fi
# Default mock for other curl calls
echo '{"tag_name": "v2.0.0"}'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"

  run "$TEST_TMPDIR/scripts/update-pkg.sh" "test-html" "2.0.0"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Source URL returns HTML"* ]] || [[ "$output" == *"Source URL validation failed"* ]]
}

# Helper: skip without namcap, except in CI, which installs it
require_namcap() {
  command -v namcap &>/dev/null && return 0
  if [[ -n "${CI:-}" ]]; then
    echo "namcap is not installed, and CI installs it" >&2
    return 1
  fi
  skip "namcap not installed"
}

@test "update-pkg: namcap blocks on real errors (missing pkgdesc)" {
  require_namcap

  create_test_package "test-namcap" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"

  # PKGBUILD missing pkgdesc triggers real namcap E: error
  aur_dir="$TEST_TMPDIR/aur-test-namcap"
  mkdir -p "$aur_dir"
  git -C "$aur_dir" init -q
  git -C "$aur_dir" config user.name "test"
  git -C "$aur_dir" config user.email "test@test"
  git -C "$aur_dir" config commit.gpgsign false
  cat > "$aur_dir/PKGBUILD" <<'EOF'
# Maintainer: test <test@example.com>
pkgname=test-namcap
pkgver=1.0.0
pkgrel=1
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/test-${pkgver}.tar.gz")
sha256sums=('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
EOF
  git -C "$aur_dir" add . && git -C "$aur_dir" commit -q -m "init"

  cat > "$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  # Mock curl for source URL validation
  cat > "$MOCK_DIR/curl" <<'MOCKCURL'
#!/usr/bin/env bash
if [[ "$1" == "-sIL" ]]; then
  printf '200 application/octet-stream'
  exit 0
fi
echo '{}'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"

  cat > "$MOCK_DIR/updpkgsums" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$MOCK_DIR/updpkgsums"

  cat > "$MOCK_DIR/makepkg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--verifysource" ]]; then exit 0; fi
echo "pkgbase = test-namcap"
echo "pkgname = test-namcap"
EOF
  chmod +x "$MOCK_DIR/makepkg"

  # Remove namcap mock so real namcap is found via PATH fallback
  rm -f "$MOCK_DIR/namcap"

  run "$TEST_TMPDIR/scripts/update-pkg.sh" "test-namcap" "2.0.0"
  [ "$status" -eq 1 ]
  [[ "$output" == *"namcap found errors"* ]]
}

@test "update-pkg: namcap passes with real warnings only (missing Maintainer)" {
  require_namcap

  create_test_package "test-namcap-warn" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"

  # PKGBUILD without # Maintainer: triggers real namcap W: warning
  aur_dir="$TEST_TMPDIR/aur-test-namcap-warn"
  mkdir -p "$aur_dir"
  git -C "$aur_dir" init -q
  git -C "$aur_dir" config user.name "test"
  git -C "$aur_dir" config user.email "test@test"
  git -C "$aur_dir" config commit.gpgsign false
  cat > "$aur_dir/PKGBUILD" <<'EOF'
pkgname=test-namcap-warn
pkgver=1.0.0
pkgrel=1
pkgdesc="A valid test package"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/test-${pkgver}.tar.gz")
sha256sums=('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
EOF
  git -C "$aur_dir" add . && git -C "$aur_dir" commit -q -m "init"

  cat > "$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  cat > "$MOCK_DIR/curl" <<'MOCKCURL'
#!/usr/bin/env bash
if [[ "$1" == "-sIL" ]]; then
  printf '200 application/octet-stream'
  exit 0
fi
echo '{}'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"

  cat > "$MOCK_DIR/updpkgsums" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$MOCK_DIR/updpkgsums"

  cat > "$MOCK_DIR/makepkg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--verifysource" ]]; then exit 0; fi
echo "pkgbase = test-namcap-warn"
echo "pkgname = test-namcap-warn"
EOF
  chmod +x "$MOCK_DIR/makepkg"

  # Remove namcap mock so real namcap runs
  rm -f "$MOCK_DIR/namcap"

  # Should continue past namcap (warnings non-fatal), reach .SRCINFO
  run "$TEST_TMPDIR/scripts/update-pkg.sh" "test-namcap-warn" "2.0.0"
  [[ "$output" == *"namcap warnings"* ]]
  [[ "$output" == *"Generating .SRCINFO"* ]]
}

@test "update-pkg: re-anchors on origin/master when HEAD is detached after clone" {
  create_test_package "test-detached" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"

  # Simulate AUR server state after concurrent-push divergence:
  # working copy has a valid refs/remotes/origin/master but HEAD is detached.
  bare_dir="$TEST_TMPDIR/aur-bare-test-detached.git"
  git init --bare -q "$bare_dir"

  aur_dir="$TEST_TMPDIR/aur-test-detached"
  mkdir -p "$aur_dir"
  git -C "$aur_dir" init -q -b master
  git -C "$aur_dir" config user.name "test"
  git -C "$aur_dir" config user.email "test@test"
  git -C "$aur_dir" config commit.gpgsign false
  cat > "$aur_dir/PKGBUILD" <<'EOF'
# Maintainer: test
pkgname=test-detached
pkgver=1.0.0
pkgrel=1
pkgdesc="detached HEAD test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/test-${pkgver}.tar.gz")
sha256sums=('abc123')
EOF
  printf '%s\n' "pkgbase = test-detached" "pkgname = test-detached" >"$aur_dir/.SRCINFO"
  git -C "$aur_dir" add . && git -C "$aur_dir" commit -q -m "init"
  git -C "$aur_dir" remote add origin "$bare_dir"
  git -C "$aur_dir" push -q origin master
  git -C "$aur_dir" fetch -q origin
  git -C "$aur_dir" checkout -q --detach master

  cat > "$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  cat > "$MOCK_DIR/curl" <<'MOCKCURL'
#!/usr/bin/env bash
if [[ "$1" == "-sIL" ]]; then
  printf '200 application/octet-stream'
  exit 0
fi
echo '{}'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"

  cat > "$MOCK_DIR/updpkgsums" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$MOCK_DIR/updpkgsums"

  cat > "$MOCK_DIR/makepkg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--verifysource" ]]; then exit 0; fi
echo "pkgbase = test-detached"
echo "pkgname = test-detached"
EOF
  chmod +x "$MOCK_DIR/makepkg"

  # namcap that finds nothing
  printf '#!/usr/bin/env bash\nexit 0\n' >"$MOCK_DIR/namcap"
  chmod +x "$MOCK_DIR/namcap"

  run "$TEST_TMPDIR/scripts/update-pkg.sh" "test-detached" "2.0.0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Detached HEAD after clone"* ]]
  [[ "$output" == *"Re-basing on origin/master"* ]]
  [[ "$output" == *"Pushed test-detached 2.0.0 to AUR"* ]]
  run git -C "$bare_dir" log -1 --format=%s master
  [[ "$output" == "2.0.0 release from "* ]]
}

@test "update-pkg: fails loudly on detached HEAD when origin/master is absent" {
  create_test_package "test-no-origin" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"

  # Detached HEAD and no origin remote: checkout -B master origin/master
  # fails and set -e ends the script. The safety net fails loudly and
  # leaves the state untouched.
  aur_dir="$TEST_TMPDIR/aur-test-no-origin"
  mkdir -p "$aur_dir"
  git -C "$aur_dir" init -q -b master
  git -C "$aur_dir" config user.name "test"
  git -C "$aur_dir" config user.email "test@test"
  git -C "$aur_dir" config commit.gpgsign false
  cat > "$aur_dir/PKGBUILD" <<'EOF'
# Maintainer: test
pkgname=test-no-origin
pkgver=1.0.0
pkgrel=1
pkgdesc="detached HEAD no origin/master"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/test-${pkgver}.tar.gz")
sha256sums=('abc123')
EOF
  git -C "$aur_dir" add . && git -C "$aur_dir" commit -q -m "init"
  git -C "$aur_dir" checkout -q --detach master

  cat > "$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  run "$TEST_TMPDIR/scripts/update-pkg.sh" "test-no-origin" "2.0.0"
  [ "$status" -ne 0 ]
  # Detection + attempt logged before the failure
  [[ "$output" == *"Detached HEAD after clone"* ]]
  [[ "$output" == *"Re-basing on origin/master"* ]]
  # Must NOT have proceeded past the self-heal (no pkgver bump, no .SRCINFO)
  [[ "$output" != *"Updating pkgver"* ]]
  [[ "$output" != *"Generating .SRCINFO"* ]]
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
  [[ "$output" == *"unknown strategy 'nonexistent'"* ]]
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

  # The source URL answers as a download, so the run reaches the checksums
  printf '#!/usr/bin/env bash\nprintf "200 application/octet-stream"\n' >"$MOCK_DIR/curl"
  chmod +x "$MOCK_DIR/curl"
  # /usr/bin without updpkgsums, as on a system without pacman-contrib
  mkdir "$TEST_TMPDIR/usr-bin"
  ln -s /usr/bin/* "$TEST_TMPDIR/usr-bin/"
  rm -f "$TEST_TMPDIR/usr-bin/updpkgsums"

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

  # update-pkg fails without updpkgsums
  run env PATH="$MOCK_DIR:$TEST_TMPDIR/usr-bin" "$TEST_TMPDIR/scripts/update-pkg.sh" "test-checksums" "2.0.0"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required command not found: updpkgsums"* ]]
}

@test "update-pkg: skips checksums for VCS packages (SKIP pattern)" {
  create_test_package "test-vcs" "git-latest" "upstream:
  type: git
  url: https://example.com/repo.git
current: 'r100.abc1234'"

  # Create a fake AUR repo with VCS PKGBUILD (sha256sums=SKIP)
  aur_dir="$TEST_TMPDIR/aur-test-vcs"
  mkdir -p "$aur_dir"
  git -C "$aur_dir" init -q
  git -C "$aur_dir" config user.name "test"
  git -C "$aur_dir" config user.email "test@test"
  git -C "$aur_dir" config commit.gpgsign false
  cat > "$aur_dir/PKGBUILD" <<'EOF'
pkgname=test-vcs
pkgver=r100.abc1234
pkgrel=1
pkgdesc="test VCS"
arch=('any')
url="https://example.com"
license=('MIT')
source=("git+https://example.com/repo.git")
sha256sums=('SKIP')
EOF
  printf '%s\n' "pkgbase = test-vcs" "pkgname = test-vcs" >"$aur_dir/.SRCINFO"
  git -C "$aur_dir" add . && git -C "$aur_dir" commit -q -m "init"
  # A bare remote, so the push of the copied clone succeeds
  git init --bare -q "$TEST_TMPDIR/aur-bare-test-vcs.git"
  git -C "$aur_dir" remote add origin "$TEST_TMPDIR/aur-bare-test-vcs.git"
  git -C "$aur_dir" push -q -u origin HEAD

  # Mock git clone
  cat > "$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  # Mock makepkg --printsrcinfo
  cat > "$MOCK_DIR/makepkg" <<'EOF'
#!/usr/bin/env bash
echo "pkgbase = test-vcs"
echo "pkgname = test-vcs"
EOF
  chmod +x "$MOCK_DIR/makepkg"

  # Should skip updpkgsums and not fail
  run "$TEST_TMPDIR/scripts/update-pkg.sh" "test-vcs" "r200.def5678"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VCS package, skipping checksums"* ]]
  [[ "$output" == *"Pushed test-vcs r200.def5678 to AUR"* ]]
}

@test "update-pkg: skips checksums for arch-specific SKIP arrays" {
  create_test_package "test-arch-skip" "github-nightly" "upstream:
  project: owner/repo
current: '1.0.0'"

  aur_dir="$TEST_TMPDIR/aur-test-arch-skip"
  mkdir -p "$aur_dir"
  git -C "$aur_dir" init -q
  git -C "$aur_dir" config user.name "test"
  git -C "$aur_dir" config user.email "test@test"
  git -C "$aur_dir" config commit.gpgsign false
  cat > "$aur_dir/PKGBUILD" <<'EOF'
pkgname=test-arch-skip
pkgver=1.0.0
pkgrel=1
pkgdesc="test arch-specific SKIP"
arch=('x86_64' 'aarch64')
url="https://example.com"
license=('MIT')
source_x86_64=("https://example.com/nightly-x86_64.tar.gz")
source_aarch64=("https://example.com/nightly-aarch64.tar.gz")
b2sums_x86_64=('SKIP')
b2sums_aarch64=('SKIP')
EOF
  git -C "$aur_dir" add . && git -C "$aur_dir" commit -q -m "init"

  cat > "$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  cat > "$MOCK_DIR/makepkg" <<'EOF'
#!/usr/bin/env bash
echo "pkgbase = test-arch-skip"
echo "pkgname = test-arch-skip"
EOF
  chmod +x "$MOCK_DIR/makepkg"

  run "$TEST_TMPDIR/scripts/update-pkg.sh" "test-arch-skip" "1.0.1"
  [[ "$output" == *"VCS package, skipping checksums"* ]]
  [[ "$output" != *"Updating checksums"* ]]
}

# === downgrades ===

@test "check-update: detects downgrade when current is newer than latest" {
  # Mock github-release returns v2.0.0. Current 3.0.0 > 2.0.0 = downgrade.
  create_test_package "mypkg" "github-release" "upstream:
  type: github
  project: owner/repo
current: '3.0.0'"

  run "$TEST_TMPDIR/scripts/check-update.sh" "mypkg"
  [ "$status" -eq 0 ]
  # stderr (captured into $output by `run`) carries the DOWNGRADE log line.
  [[ "$output" == *"DOWNGRADE 3.0.0"*"2.0.0"* ]]
  # The version is still printed to stdout; check-all.sh decides on it.
  [[ "$output" == *"2.0.0"* ]]
}

@test "check-update: normal upgrade path does not log DOWNGRADE (regression)" {
  # Mock returns v2.0.0. Current 1.0.0 < 2.0.0 = normal upgrade.
  create_test_package "mypkg" "github-release" "upstream:
  type: github
  project: owner/repo
current: '1.0.0'"

  run "$TEST_TMPDIR/scripts/check-update.sh" "mypkg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"update available 1.0.0"*"2.0.0"* ]]
  [[ "$output" != *"DOWNGRADE"* ]]
  [[ "$output" == *"2.0.0"* ]]
}

@test "check-all: writes 'available_downgrade:' for a package that allows downgrades" {
  # Mock returns v2.0.0. Current 3.0.0 > 2.0.0 = downgrade.
  create_test_package "pkg-down" "github-release" "upstream:
  type: github
  project: owner/repo
current: '3.0.0'
allow_downgrade: true"

  "$TEST_TMPDIR/scripts/check-all.sh" 2>/dev/null || true
  [ -f "$TEST_TMPDIR/.status/pkg-down" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-down")" = "available_downgrade: 2.0.0" ]
}

@test "check-all: skips a downgrade without allow_downgrade" {
  create_test_package "pkg-down" "github-release" "upstream:
  type: github
  project: owner/repo
current: '3.0.0'"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOWNGRADE detected 3.0.0 → 2.0.0, skipped: allow_downgrade is not set"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-down")" = "downgrade_skipped: 2.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "0" ]
}

@test "check-all --update: runs no update to a lower version without allow_downgrade" {
  create_test_package "pkg-down" "github-release" "upstream:
  type: github
  project: owner/repo
current: '3.0.0'"
  rm -f "$TEST_TMPDIR/scripts/update-pkg.sh"
  printf '#!/usr/bin/env bash\necho "$*" >>"%s/update-pkg.args"\n' "$TEST_TMPDIR" >"$TEST_TMPDIR/scripts/update-pkg.sh"
  chmod +x "$TEST_TMPDIR/scripts/update-pkg.sh"

  run "$TEST_TMPDIR/scripts/check-all.sh" --update
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/update-pkg.args" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-down")" = "downgrade_skipped: 2.0.0" ]
}

@test "check-all: writes 'downgrade:' status after successful --update causing downgrade" {
  # A stub update-pkg.sh in the temp workspace always succeeds, so the test
  # covers only how check-all.sh writes the status.
  create_test_package "pkg-down-upd" "github-release" "upstream:
  type: github
  project: owner/repo
current: '3.0.0'
allow_downgrade: true"

  # Replace the symlinked update-pkg.sh with a stub that exits 0.
  rm -f "$TEST_TMPDIR/scripts/update-pkg.sh"
  cat >"$TEST_TMPDIR/scripts/update-pkg.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TEST_TMPDIR/scripts/update-pkg.sh"

  "$TEST_TMPDIR/scripts/check-all.sh" --update 2>/dev/null || true
  [ -f "$TEST_TMPDIR/.status/pkg-down-upd" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-down-upd")" = "downgrade: 2.0.0" ]
}

@test "update-readme: renders downgrade icon and keeps badge green" {
  create_test_package "pkg-down" "github-release" "upstream:
  project: owner/repo
current: '3.0.0'"

  echo "downgrade: 1.0.0" >"$TEST_TMPDIR/.status/pkg-down"

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null

  grep -q "⬇️ downgraded to 1.0.0" "$TEST_TMPDIR/README.md"
  # Downgrades count toward pkg_ok, so the badge stays green.
  grep -q "brightgreen" "$TEST_TMPDIR/README.md"
  ! grep -q "packages-.*-red" "$TEST_TMPDIR/README.md"
}

@test "update-readme: renders available_downgrade icon with (downgrade) suffix" {
  create_test_package "pkg-down" "github-release" "upstream:
  project: owner/repo
current: '3.0.0'"

  echo "available_downgrade: 1.0.0" >"$TEST_TMPDIR/.status/pkg-down"

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null

  grep -q "⬇️ 1.0.0 available (downgrade)" "$TEST_TMPDIR/README.md"
  # Available downgrades count toward pkg_ok too, so the badge stays green.
  grep -q "brightgreen" "$TEST_TMPDIR/README.md"
}

@test "update-readme: renders a skipped downgrade and keeps the badge green" {
  create_test_package "pkg-down" "github-release" "upstream:
  project: owner/repo
current: '3.0.0'"

  echo "downgrade_skipped: 1.0.0" >"$TEST_TMPDIR/.status/pkg-down"

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null

  grep -q "⬇️ 1.0.0 skipped (downgrade)" "$TEST_TMPDIR/README.md"
  grep -q "brightgreen" "$TEST_TMPDIR/README.md"
}

@test "check-all: writes 'updated:' status after --update on normal upgrade (regression)" {
  # Current 1.0.0 < latest 2.0.0: the normal upgrade path.
  # Verifies the is_downgrade=false branch of the new status-writing logic.
  create_test_package "pkg-up" "github-release" "upstream:
  type: github
  project: owner/repo
current: '1.0.0'"

  # Stub update-pkg.sh to always succeed.
  rm -f "$TEST_TMPDIR/scripts/update-pkg.sh"
  cat >"$TEST_TMPDIR/scripts/update-pkg.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TEST_TMPDIR/scripts/update-pkg.sh"

  "$TEST_TMPDIR/scripts/check-all.sh" --update 2>/dev/null || true
  [ -f "$TEST_TMPDIR/.status/pkg-up" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-up")" = "updated: 2.0.0" ]
}
