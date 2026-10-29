#!/usr/bin/env bats

load helpers/setup.sh
bats_require_minimum_version 1.5.0

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

# vercmp puts an empty string above a version of letters only
@test "lib.sh: newest_version skips an empty line" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  run newest_version <<<$'nightly\n\nlatest'
  [ "$status" -eq 0 ]
  [ "$output" = "nightly" ]
}

# vercmp reads a dash as the pkgrel separator and finds 2.5.0-rc1 equal to
# 2.5.0. Dropped, as pkgver_dash: '' does, the dash gives 2.5.0rc1.
@test "lib.sh: newest_version puts a pre-release after a dash below its release" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  run newest_version <<<$'2.5.0\n2.5.0-rc1\n2.4.6'
  [ "$output" = "2.5.0" ]
  run newest_version <<<$'2.5.0-rc1\n2.5.0'
  [ "$output" = "2.5.0" ]
  run newest_version <<<$'2.4.6\n2.5.0-rc1\n2.5.0-rc2'
  [ "$output" = "2.5.0-rc2" ]
  run newest_version <<<$'1.0.0-beta.3\n1.0.0-beta.24'
  [ "$output" = "1.0.0-beta.24" ]
}

@test "lib.sh: newest_version reads a dash before a digit as a dot" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  run newest_version <<<$'2025-12-27\n2026-01-05\n2025-04-03'
  [ "$output" = "2026-01-05" ]
  run newest_version <<<$'1.9.0\n1.9.0-1'
  [ "$output" = "1.9.0-1" ]
  run newest_version <<<$'1.2-3\n1.3'
  [ "$output" = "1.3" ]
}

# === audit_pkgbuild ===

@test "audit_pkgbuild: passes normal binary package" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
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
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
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
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
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

@test "audit_pkgbuild: the pkgver() block says to drop pkgver() or use git-latest" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-nightly-bin
pkgver=20261022
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("test.tar.xz::https://example.com/releases/download/nightly/test.tar.xz")
sha256sums=('SKIP')
pkgver() {
  date +%Y%m%d
}
EOF
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-asset"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Drop pkgver() so that sed sets pkgver, or use 'git-latest' for a package built from git."* ]]
}

# Helper: test.PKGBUILD at 2.2.0 whose pkgver() has the given body
write_pkgver_pkgbuild() {
  # shellcheck disable=SC2016
  printf '%s\n' 'pkgname=test' 'pkgver=2.2.0' 'pkgrel=1' 'arch=(any)' \
    'source=("https://example.com/test-$pkgver.tar.gz")' "sha256sums=('abc123')" \
    'pkgver() {' "$1" '}' >"$TEST_TMPDIR/test.PKGBUILD"
}

# streamrip on the AUR: pkgver holds no dash, so its pkgver() prints the
# pkgver that sed sets
@test "audit_pkgbuild: allows a pkgver() that only prints pkgver" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  local body
  # shellcheck disable=SC2016
  for body in $'  cd streamrip\n  printf "${pkgver//-/.}"' $'  cd "$srcdir/streamrip" || return\n  echo $pkgver' '  echo "${pkgver}"'; do
    write_pkgver_pkgbuild "$body"
    run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-tag"
    [ "$status" -eq 0 ]
  done
}

@test "audit_pkgbuild: blocks a pkgver() that does more than print pkgver" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  local body
  # shellcheck disable=SC2016
  for body in '  printf "${pkgver//_/.}"' '  echo "${pkgver}rc1"' $'  echo "$pkgver"\n  echo "$pkgver"' \
    '  echo "$pkgver" | tr . _' $'  cd streamrip && git pull\n  echo "$pkgver"'; do
    write_pkgver_pkgbuild "$body"
    run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-tag"
    [ "$status" -eq 1 ]
    [[ "$output" == *"BLOCKED: pkgver() function detected with strategy 'github-tag'."* ]]
  done
}

@test "audit_pkgbuild: allows pkgver() with git-latest strategy" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
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
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
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
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-mixed
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("git+https://example.com/repo.git#commit=abc123"
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
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
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
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
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
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
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
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-mixed-arch
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source_x86_64=("git+https://example.com/repo.git#commit=abc123"
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
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-mixed-order
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/data-${pkgver}.tar.gz"
        "git+https://example.com/repo.git#commit=abc123")
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

# makepkg -g writes SKIP for a VCS source without a pin, as for a signature
@test "audit_pkgbuild: allows the SKIP of a VCS source without a pin next to a real hash" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  local vcs
  for vcs in "git+https://example.com/app.git" "app::git+https://example.com/app.git#branch=main" \
    "hg+https://example.com/app" "svn+https://example.com/app/trunk" \
    "bzr+https://example.com/app" "fossil+https://example.com/app"; do
    cat >"$TEST_TMPDIR/test.PKGBUILD" <<EOF
pkgname=test-vcs-data
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("$vcs"
        "https://example.com/data-\${pkgver}.tar.gz")
sha256sums=('SKIP'
            'abc123')
EOF
    run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
    [ "$status" -eq 0 ] || {
      echo "blocked: $vcs"
      return 1
    }
  done
}

# libadwaita-without-adwaita: makepkg -g hashes a local file
@test "audit_pkgbuild: blocks the SKIP of a local file next to a real remote hash" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-local-skip
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/app-${pkgver}.tar.gz"
        "theme.diff")
sha256sums=('abc123'
            'SKIP')
EOF
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP checksums mixed with real hashes for remote"* ]]
}

# makepkg -g hashes a VCS source at a commit, a tag or a revision
@test "audit_pkgbuild: blocks the SKIP of a pinned VCS source next to a real hash" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  local vcs
  for vcs in "git+https://example.com/app.git#commit=abc123" "app::git+https://example.com/app.git?signed#tag=v1" \
    "hg+https://example.com/app#revision=4" "bzr+https://example.com/app#revision=4"; do
    cat >"$TEST_TMPDIR/test.PKGBUILD" <<EOF
pkgname=test-vcs-data
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("$vcs"
        "https://example.com/data-\${pkgver}.tar.gz")
sha256sums=('SKIP'
            'abc123')
EOF
    run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
    [ "$status" -eq 1 ] || {
      echo "allowed: $vcs"
      return 1
    }
    [[ "$output" == *"SKIP checksums mixed with real hashes for remote"* ]]
  done
}

# === has_skip_checksums ===

@test "has_skip_checksums: finds SKIP in arch-specific arrays" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
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
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
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
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
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
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
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
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
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

# makepkg sets CARCH, and neovim-nightly-bin builds its URL from it in a
# case statement. Without CARCH the URL is nvim-linux-.tar.gz, a 404.
@test "lib.sh: validate_source_urls builds the URLs with CARCH" {
  cat >"$TEST_TMPDIR/PKGBUILD" <<'EOF'
pkgname=test-carch
pkgver=1.0.0
pkgrel=1
arch=('x86_64' 'aarch64')
source=("https://example.com/test-1.0.0-${CARCH}.tar.gz")
sha256sums=('SKIP')
EOF

  cat >"$MOCK_DIR/curl" <<MOCKCURL
#!/usr/bin/env bash
echo "\${@: -1}" >>"$TEST_TMPDIR/curl-urls.log"
printf '200 application/octet-stream'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"

  local lib='source "$0/scripts/lib.sh"; validate_source_urls "$1"'
  run env -u CARCH bash -c "$lib" "$TEST_TMPDIR" "$TEST_TMPDIR/PKGBUILD"
  [ "$status" -eq 0 ]
  grep -qx "https://example.com/test-1.0.0-$(uname -m).tar.gz" "$TEST_TMPDIR/curl-urls.log"

  run env CARCH=aarch64 bash -c "$lib" "$TEST_TMPDIR" "$TEST_TMPDIR/PKGBUILD"
  [ "$status" -eq 0 ]
  grep -qx "https://example.com/test-1.0.0-aarch64.tar.gz" "$TEST_TMPDIR/curl-urls.log"
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
  [ "$output" = '-sfL --max-time 30 --retry 2 --retry-delay 5 --retry-connrefused -A aurtomator/1.0 -w %{onerror}%{stderr}%{url_effective}\t%{errormsg}\t%header{cf-mitigated} --max-redirs 5 https://example.invalid/a' ]
}

# Helper: a curl that writes $CURL_STDERR to stderr, as its -w does on a
# failure, and exits $CURL_RC
mock_curl_failure() {
  cat >"$MOCK_DIR/curl" <<'MOCKCURL'
#!/usr/bin/env bash
printf '%b' "$CURL_STDERR" >&2
exit "$CURL_RC"
MOCKCURL
  chmod +x "$MOCK_DIR/curl"
}

@test "lib.sh: http_get names the URL of the last answer and the error" {
  mock_curl_failure
  source "$TEST_TMPDIR/scripts/lib.sh"
  CURL_RC=22 CURL_STDERR='https://example.com/b\tThe requested URL returned error: 404\t' run http_get https://example.com/a
  [ "$status" -eq 22 ]
  [ "$output" = "https://example.com/b: The requested URL returned error: 404" ]
}

# anydesk.com sends this answer to every client without JavaScript,
# whatever its User-Agent
@test "lib.sh: http_get names a Cloudflare challenge" {
  mock_curl_failure
  source "$TEST_TMPDIR/scripts/lib.sh"
  CURL_RC=22 CURL_STDERR='https://example.com/a\tThe requested URL returned error: 403\tchallenge' run http_get https://example.com/a
  [ "$status" -eq 22 ]
  [ "$output" = "https://example.com/a: The requested URL returned error: 403, a Cloudflare challenge, which only a browser passes" ]
}

# curl refuses a malformed URL before -w writes anything
@test "lib.sh: http_get names the URL and the exit code when curl writes nothing" {
  mock_curl_failure
  source "$TEST_TMPDIR/scripts/lib.sh"
  CURL_RC=3 CURL_STDERR='' run http_get 'https://[bad'
  [ "$status" -eq 3 ]
  [ "$output" = "https://[bad: curl exit 3" ]
}

# curl writes its own message for an unknown option, -s or not
@test "lib.sh: http_get passes a message of curl through" {
  mock_curl_failure
  source "$TEST_TMPDIR/scripts/lib.sh"
  CURL_RC=2 CURL_STDERR='curl: option --bad: is unknown\n' run http_get https://example.com/a --bad
  [ "$status" -eq 2 ]
  [ "$output" = "curl: option --bad: is unknown" ]
}

@test "lib.sh: http_get_json asks curl for the URL of the last answer" {
  cat >"$MOCK_DIR/curl" <<MOCKCURL
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$TEST_TMPDIR/curl.args"
printf '[\n  {"name": "v1.0.0"}\n]\n\nhttps://example.com/a'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"
  source "$TEST_TMPDIR/scripts/lib.sh"
  run http_get_json https://example.com/a
  [ "$status" -eq 0 ]
  [ "$output" = $'[\n  {"name": "v1.0.0"}\n]' ]
  [ "$(grep -x -A1 -- -w "$TEST_TMPDIR/curl.args" | tail -1)" = '\n%{url_effective}%{onerror}%{stderr}%{url_effective}\t%{errormsg}\t%header{cf-mitigated}' ]
}

@test "lib.sh: http_get_json stops at a failed request" {
  mock_curl_failure
  source "$TEST_TMPDIR/scripts/lib.sh"
  CURL_RC=22 CURL_STDERR='https://example.com/a\tThe requested URL returned error: 404\t' run http_get_json https://example.com/a
  [ "$status" -eq 22 ]
  [ "$output" = "https://example.com/a: The requested URL returned error: 404" ]
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

# === version_jump ===

@test "lib.sh: version_jump finds a first number two digits longer" {
  local pair
  for pair in "13 2026102100" "4.4215 4215" "1.2 2026.1" "2025.12.13 20261021" "0.9 100.0" "r1.0000000 r504.42cd4ac"; do
    run bash -c 'source "$0/scripts/lib.sh"; version_jump "$1" "$2"' "$TEST_TMPDIR" "${pair% *}" "${pair#* }"
    [ "$status" -eq 0 ] || {
      echo "no jump found: $pair"
      return 1
    }
  done
}

@test "lib.sh: version_jump leaves a usual step" {
  local pair
  for pair in "9 10" "99 100" "0.9 1.0" "1.9 1.10" "2025.12.13 2026.1.2" "r99.abc1234 r100.def5678" "13 14"; do
    run bash -c 'source "$0/scripts/lib.sh"; version_jump "$1" "$2"' "$TEST_TMPDIR" "${pair% *}" "${pair#* }"
    [ "$status" -eq 1 ] || {
      echo "jump found: $pair"
      return 1
    }
  done
}

# === alerts ===

# Helper: the status of alert_fires for a rule on the step from current to latest
# Usage: run_alert_fires <kind> <value> <current> <latest>
run_alert_fires() {
  run bash -c 'source "$0/scripts/lib.sh"; alert_fires "$@"' "$TEST_TMPDIR" "$@"
}

@test "lib.sh: alert_fires on a step to a greater first number for when: major" {
  local pair
  for pair in "28+25 29+1" "9 10" "1.9 2.0" "r9.abc1234 r10.def5678" "2025.12.13 2026.1.2"; do
    run_alert_fires when major "${pair% *}" "${pair#* }"
    [ "$status" -eq 0 ] || {
      echo "did not fire: $pair"
      return 1
    }
  done
}

@test "lib.sh: alert_fires leaves a step within the first number for when: major" {
  local pair
  for pair in "28+25 28+26" "1.9 1.10" "2.0 1.9" "beta 1.0" "1.0 beta"; do
    run_alert_fires when major "${pair% *}" "${pair#* }"
    [ "$status" -eq 1 ] || {
      echo "fired: $pair"
      return 1
    }
  done
}

@test "lib.sh: alert_fires on a step across the version of from" {
  local pair
  for pair in "0.3.0 0.4.0" "0.3.9 0.4.1" "0.3 1.0" "0.4.0rc1 0.4.0"; do
    run_alert_fires from 0.4.0 "${pair% *}" "${pair#* }"
    [ "$status" -eq 0 ] || {
      echo "did not fire: $pair"
      return 1
    }
  done
}

@test "lib.sh: alert_fires leaves a step that does not cross the version of from" {
  local pair
  for pair in "0.4.0 0.4.1" "0.4.1 0.5" "0.2 0.3" "0.4.0 0.3.9"; do
    run_alert_fires from 0.4.0 "${pair% *}" "${pair#* }"
    [ "$status" -eq 1 ] || {
      echo "fired: $pair"
      return 1
    }
  done
}

@test "lib.sh: alert_fires when the new version matches and current does not" {
  run_alert_fires match '^29\+' 28+25 29+1
  [ "$status" -eq 0 ]
  local pair
  for pair in "29+1 29+2" "28+25 28+26" "29+2 28+30"; do
    run_alert_fires match '^29\+' "${pair% *}" "${pair#* }"
    [ "$status" -eq 1 ] || {
      echo "fired: $pair"
      return 1
    }
  done
}

@test "lib.sh: alert_fires never fires without current" {
  run_alert_fires when major "" 29+1
  [ "$status" -eq 1 ]
  run_alert_fires from 0.4.0 "" 0.4.0
  [ "$status" -eq 1 ]
  run_alert_fires match '^29' "" 29+1
  [ "$status" -eq 1 ]
}

@test "lib.sh: alert_fires fails on a match bash does not accept or a condition it does not know" {
  run_alert_fires match '(?:29)' 28+25 29+1
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run_alert_fires until 30 28+25 29+1
  [ "$status" -eq 2 ]
  run_alert_fires match '(?:29)' "" 29+1
  [ "$status" -eq 2 ]
  run_alert_fires until 30 "" 29+1
  [ "$status" -eq 2 ]
}

@test "lib.sh: fired_alerts prints hold or notice and the note of each fired rule in file order" {
  create_test_package "pkg" "github-release" "alerts:
  - when: major
    note: Create the package for the old major
  - from: '0.4.0'
    note: Not reached
  - match: '^29\\+'
    hold: true
    note: Raise makedepends java-environment to 28"
  run bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" 28+25 29+1' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/pkg.yml"
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\tCreate the package for the old major\nhold\tRaise makedepends java-environment to 28' ]
}

@test "lib.sh: fired_alerts prints nothing without alerts or without current" {
  create_test_package "plain" "github-release" "current: '1.0'"
  run bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" 1.0 2.0' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/plain.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  create_test_package "new" "github-release" "alerts:
  - from: '0.1'
    hold: true
    note: First release"
  run bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" "" 2.0' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/new.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lib.sh: fired_alerts fails on a rule it cannot evaluate without current too" {
  create_test_package "new" "github-release" "alerts:
  - match: '(?:1)'
    hold: true
    note: First release"
  run bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" "" 1.0' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/new.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"alerts[0].match must be a non-empty ERE that bash accepts"* ]]
}

@test "lib.sh: fired_alerts fails on a rule it cannot evaluate" {
  local rule message
  for rule in "hold: true|alerts[0] must hold exactly one of when, from, match" \
    "when: minor|alerts[0].when must be major" \
    "match: '(?:29)'|alerts[0].match must be a non-empty ERE that bash accepts"; do
    create_test_package "pkg" "github-release" "alerts:
  - ${rule%%|*}
    note: Something"
    message="${rule#*|}"
    run bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" 28+25 29+1' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/pkg.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$message"* ]] || {
      echo "rule: $rule"
      return 1
    }
  done
}

# === version of aurtomator ===

@test "lib.sh: aurtomator_version prints VERSION, or nothing without it" {
  run bash -c 'source "$0/scripts/lib.sh"; aurtomator_version' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  echo "0.6.0" >"$TEST_TMPDIR/VERSION"
  run bash -c 'source "$0/scripts/lib.sh"; aurtomator_version' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "0.6.0" ]
}

@test "lib.sh: latest_aurtomator_release prints the version of the latest release tag" {
  MOCK_UPSTREAM_TAG=v0.7.0 run bash -c 'source "$0/scripts/lib.sh"; latest_aurtomator_release' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "0.7.0" ]
}

@test "lib.sh: latest_aurtomator_release fails on another tag or a failed request" {
  local tag
  for tag in nightly 0.7.0 v0.7 'v0.7.0 x' xv0.7.0 fail; do
    MOCK_UPSTREAM_TAG="$tag" run bash -c 'source "$0/scripts/lib.sh"; latest_aurtomator_release' "$TEST_TMPDIR"
    [ "$status" -ne 0 ] || {
      echo "passed: $tag"
      return 1
    }
  done
}

@test "lib.sh: upstream_status says newer only for a release above VERSION" {
  local pair
  for pair in "0.6.0 v0.7.0 newer: 0.7.0" "0.6.0 v0.6.0 current: 0.6.0" "0.7.0 v0.6.0 current: 0.6.0" "0.9.0 v0.10.0 newer: 0.10.0"; do
    echo "${pair%% *}" >"$TEST_TMPDIR/VERSION"
    pair="${pair#* }"
    MOCK_UPSTREAM_TAG="${pair%% *}" run bash -c 'source "$0/scripts/lib.sh"; upstream_status' "$TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [ "$output" = "${pair#* }" ]
  done
}

@test "lib.sh: upstream_status fails without VERSION" {
  run bash -c 'source "$0/scripts/lib.sh"; upstream_status' "$TEST_TMPDIR"
  [ "$status" -ne 0 ]
}

@test "check-all: logs the version and records a newer release of aurtomator" {
  echo "0.6.0" >"$TEST_TMPDIR/VERSION"
  MOCK_UPSTREAM_TAG=v0.7.0 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"aurtomator 0.6.0" ]]
  [[ "$output" == *"aurtomator 0.7.0 is out, this repository runs 0.6.0"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/_upstream")" = "newer: 0.7.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "0" ]
}

@test "check-all: records that aurtomator is at its latest release" {
  echo "0.6.0" >"$TEST_TMPDIR/VERSION"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/_upstream")" = "current: 0.6.0" ]
}

@test "check-all: warns and records nothing when the release cannot be read" {
  echo "0.6.0" >"$TEST_TMPDIR/VERSION"
  MOCK_UPSTREAM_TAG=fail run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not read the latest aurtomator release"* ]]
  [ ! -e "$TEST_TMPDIR/.status/_upstream" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "0" ]
}

@test "check-all: asks for no release without VERSION" {
  MOCK_UPSTREAM_TAG=fail run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"aurtomator"* ]]
  [ ! -e "$TEST_TMPDIR/.status/_upstream" ]
}

@test "update-readme: writes the version under the package table" {
  echo "0.6.0" >"$TEST_TMPDIR/VERSION"
  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null

  grep -qx '</table>' "$TEST_TMPDIR/README.md"
  run grep -A2 -x '</table>' "$TEST_TMPDIR/README.md"
  [ "$output" = $'</table>\n\naurtomator 0.6.0 <!-- x-release-please-version -->' ]
}

@test "update-readme: links a newer release of aurtomator" {
  echo "0.6.0" >"$TEST_TMPDIR/VERSION"
  echo "newer: 0.7.0" >"$TEST_TMPDIR/.status/_upstream"
  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null

  grep -qxF 'aurtomator 0.6.0 · [0.7.0 available](https://github.com/staticwire/aurtomator/releases/tag/v0.7.0) <!-- x-release-please-version -->' "$TEST_TMPDIR/README.md"
}

@test "update-readme: links no release for aurtomator at its release or for another _upstream" {
  local upstream
  echo "0.6.0" >"$TEST_TMPDIR/VERSION"
  git -C "$TEST_TMPDIR" init -q
  for upstream in "current: 0.7.0" "xnewer: 0.7.0" "newer: 0.7.0 x"; do
    printf '%s\n' "$upstream" >"$TEST_TMPDIR/.status/_upstream"
    printf '%s\n' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
    "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null
    grep -qxF 'aurtomator 0.6.0 <!-- x-release-please-version -->' "$TEST_TMPDIR/README.md" || {
      echo "linked for: $upstream"
      return 1
    }
  done
}

@test "update-readme: writes no version line without VERSION" {
  echo "current: 0.6.0" >"$TEST_TMPDIR/.status/_upstream"
  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null

  run grep -c 'aurtomator ' "$TEST_TMPDIR/README.md"
  [ "$output" = "0" ]
}

# === tag_versions ===

@test "lib.sh: tag_versions fills the groups and keeps every other character" {
  run bash -c 'source "$0/scripts/lib.sh"; tag_versions "$1" "$2" <<<"$3"' "$TEST_TMPDIR" \
    '^([0-9]+)-([0-9]+)$' 'r1.\2\1\0' '10-20'
  [ "$status" -eq 0 ]
  [ "$output" = 'r1.2010\0' ]
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

# A tag_version_regex, a scraped page or a registry can return a word
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

# npm cli-pride-flags is 1.9.0-1, crates.io pijul 1.0.0-beta.24
@test "check-update: rejects a dash from the strategy without pkgver_dash" {
  cat >"$TEST_TMPDIR/strategies/dash.sh" <<'EOF'
#!/usr/bin/env bash
echo 1.0.0-beta-24
EOF
  chmod +x "$TEST_TMPDIR/strategies/dash.sh"
  create_test_package "mypkg" "dash" "current: '1.0'"

  run "$TEST_TMPDIR/scripts/check-update.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Version string rejected, only A-Za-z0-9 . _ + are allowed: '1.0.0-beta-24'"* ]]
}

@test "check-update: pkgver_dash replaces every dash in the version" {
  cat >"$TEST_TMPDIR/strategies/dash.sh" <<'EOF'
#!/usr/bin/env bash
echo 1.0.0-beta-24
EOF
  chmod +x "$TEST_TMPDIR/strategies/dash.sh"
  local result
  create_test_package "mypkg" "dash" "current: '1.0'
pkgver_dash: _"
  result=$("$TEST_TMPDIR/scripts/check-update.sh" "mypkg" 2>/dev/null)
  [ "$result" = "1.0.0_beta_24" ]

  create_test_package "mypkg" "dash" "current: '1.0'
pkgver_dash: ."
  result=$("$TEST_TMPDIR/scripts/check-update.sh" "mypkg" 2>/dev/null)
  [ "$result" = "1.0.0.beta.24" ]
}

# vercmp puts 1.0.0beta24 below 1.0.0, so the release needs no epoch
@test "check-update: pkgver_dash '' drops every dash in the version" {
  stand_in_strategy dash 1.0.0-beta-24
  create_test_package "mypkg" "dash" "current: '1.0'
pkgver_dash: ''"

  run --separate-stderr "$TEST_TMPDIR/scripts/check-update.sh" "mypkg"
  [ "$status" -eq 0 ]
  [ "$output" = "1.0.0beta24" ]
}

@test "check-update: pkgver_format puts the version of the strategy into pkgver" {
  stand_in_strategy build 4216
  create_test_package "mypkg" "build" "current: '4.4215'
pkgver_format: '4.%s'"

  run --separate-stderr "$TEST_TMPDIR/scripts/check-update.sh" "mypkg"
  [ "$status" -eq 0 ]
  [ "$output" = "4.4216" ]
  [[ "$stderr" == *"mypkg: update available 4.4215 → 4.4216"* ]]
}

@test "check-update: pkgver_format compares the formatted version with current" {
  stand_in_strategy build 4215
  create_test_package "mypkg" "build" "current: '4.4215'
pkgver_format: '4.%s'"

  run --separate-stderr "$TEST_TMPDIR/scripts/check-update.sh" "mypkg"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"mypkg is up to date (4.4215)"* ]]
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
  cat >"$TEST_TMPDIR/packages/broken.yml" <<EOF
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
  grep -qF '>pkg</a>' "$SPACED/README.md"
}

# === update-readme.sh ===

@test "update-readme: generates status table" {
  create_test_package "pkg-a" "github-release" "upstream:
  type: github
  project: owner/repo
current: '2.0.0'"

  # Create minimal README with markers
  cat >"$TEST_TMPDIR/README.md" <<'EOF'
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
  grep -qF '<td><a href="https://aur.archlinux.org/pkgbase/pkg-a">pkg-a</a></td>' "$TEST_TMPDIR/README.md"
}

# GitHub keeps nowrap on an HTML table cell, and a Markdown cell takes none
@test "update-readme: keeps strategy, date and status on one line" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'
last_updated: '2026-10-22'"
  echo "up_to_date" >"$TEST_TMPDIR/.status/pkg-a"
  printf '%s\n' "# test" "<!-- PACKAGES:START -->" "<!-- PACKAGES:END -->" >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q

  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  [ "$(sed -n '/PACKAGES:START/,/PACKAGES:END/p' "$TEST_TMPDIR/README.md" | sed '1,2d')" = '
<table>
<tr><th>Package</th><th>Version</th><th>Strategy</th><th>Updated</th><th>Status</th></tr>
<tr><td><a href="https://aur.archlinux.org/pkgbase/pkg-a">pkg-a</a></td><td>1.0.0</td><td nowrap>github-release</td><td nowrap>2026-10-22</td><td nowrap>✅ up to date</td></tr>
</table>
<!-- PACKAGES:END -->' ]
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

# sed prints nothing from a marker that is missing, so the text after the
# start marker would be lost
@test "update-readme: fails and keeps the README without the end marker of the table" {
  printf '%s\n' '# test' '<!-- BADGES:START -->' '<!-- BADGES:END -->' '<!-- PACKAGES:START -->' \
    'old table' '## License' >"$TEST_TMPDIR/README.md"
  cp "$TEST_TMPDIR/README.md" "$TEST_TMPDIR/README.orig"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No <!-- PACKAGES:END --> marker found in README.md"* ]]
  cmp "$TEST_TMPDIR/README.orig" "$TEST_TMPDIR/README.md"
}

@test "update-readme: fails and keeps the README without the end marker of the badges" {
  printf '%s\n' '# test' '<!-- BADGES:START -->' 'old badges' '## Intro' \
    '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  cp "$TEST_TMPDIR/README.md" "$TEST_TMPDIR/README.orig"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No <!-- BADGES:END --> marker found in README.md"* ]]
  cmp "$TEST_TMPDIR/README.orig" "$TEST_TMPDIR/README.md"
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
  [ "$(sed -n '/<table>/,$p' "$TEST_TMPDIR/README.md")" = '<table>
<tr><th>Package</th><th>Version</th><th>Strategy</th><th>Updated</th><th>Status</th></tr>
<tr><td><em>No packages configured</em></td><td>—</td><td nowrap>—</td><td nowrap>—</td><td nowrap>—</td></tr>
</table>
<!-- PACKAGES:END -->' ]
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
  run ! grep -q "old table" "$TEST_TMPDIR/README.md"
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
  grep -q "📦 updated to 2.0.0" "$TEST_TMPDIR/README.md"
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
  grep -q "✨ 3.0.0 available" "$TEST_TMPDIR/README.md"
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

# Helper: a README with both marker pairs and a line between them
readme_with_badges() {
  printf '%s\n' '# test' '<!-- BADGES:START -->' 'old badges' '<!-- BADGES:END -->' \
    'text between' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
}

@test "update-readme: a public fork gets its own CI and Codecov badges" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  readme_with_badges
  git -C "$TEST_TMPDIR" init -q
  git -C "$TEST_TMPDIR" remote add origin "git@github.com:someone/fork.git"
  cat >"$MOCK_DIR/curl" <<EOF
#!/usr/bin/env bash
echo "\${@: -1}" >>"$TEST_TMPDIR/curl-urls.log"
echo '{"private": false}'
EOF
  chmod +x "$MOCK_DIR/curl"

  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Badges updated (repo: someone/fork)"* ]]
  grep -qx 'https://api.github.com/repos/someone/fork' "$TEST_TMPDIR/curl-urls.log"
  local badges
  badges=$(sed -n '3p' "$TEST_TMPDIR/README.md")
  [[ "$badges" == "[![Lint & Test](https://github.com/someone/fork/actions/workflows/ci.yml/badge.svg)](https://github.com/someone/fork/actions/workflows/ci.yml) [![codecov](https://codecov.io/github/someone/fork/graph/badge.svg)](https://codecov.io/github/someone/fork) [![Bash]"* ]]
  [[ "$badges" == *"[![License](https://img.shields.io/badge/license-BSD--3--Clause-blue)](LICENSE)" ]]
  grep -qx 'text between' "$TEST_TMPDIR/README.md"
  run ! grep -q 'old badges' "$TEST_TMPDIR/README.md"
}

# Codecov shows no tokenless badge for a private repository. mikefarah yq
# prints the "true" of select(...) | "true" whatever the input.
@test "update-readme: a private repo, or a failed API call on a README without a Codecov badge, links the Codecov of aurtomator" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  git -C "$TEST_TMPDIR" init -q
  git -C "$TEST_TMPDIR" remote add origin "https://github.com/someone/private.git"
  local answer
  for answer in "echo '{\"private\": true}'" "exit 22"; do
    readme_with_badges
    printf '#!/usr/bin/env bash\n%s\n' "$answer" >"$MOCK_DIR/curl"
    chmod +x "$MOCK_DIR/curl"

    run "$TEST_TMPDIR/scripts/update-readme.sh"
    [ "$status" -eq 0 ]
    grep -qF '(https://github.com/someone/private/actions/workflows/ci.yml)' "$TEST_TMPDIR/README.md"
    grep -qF '[![codecov](https://codecov.io/github/staticwire/aurtomator/graph/badge.svg)](https://codecov.io/github/staticwire/aurtomator)' "$TEST_TMPDIR/README.md"
  done
}

@test "update-readme: a repo made private gets the Codecov badge of aurtomator in place of its own" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  git -C "$TEST_TMPDIR" init -q
  git -C "$TEST_TMPDIR" remote add origin "https://github.com/someone/fork.git"
  printf '%s\n' '# test' '<!-- BADGES:START -->' \
    '[![codecov](https://codecov.io/github/someone/fork/graph/badge.svg)](https://codecov.io/github/someone/fork)' \
    '<!-- BADGES:END -->' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  printf '#!/usr/bin/env bash\n%s\n' "echo '{\"private\": true}'" >"$MOCK_DIR/curl"
  chmod +x "$MOCK_DIR/curl"

  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF '[![codecov](https://codecov.io/github/staticwire/aurtomator/graph/badge.svg)](https://codecov.io/github/staticwire/aurtomator)' "$TEST_TMPDIR/README.md"
  run ! grep -q 'codecov.io/github/someone' "$TEST_TMPDIR/README.md"
}

# A rate limit of the anonymous API call switched the badge of a public fork
# to aurtomator and back in the next run
@test "update-readme: keeps the Codecov badge of the README without a definite answer from the API" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  git -C "$TEST_TMPDIR" init -q
  git -C "$TEST_TMPDIR" remote add origin "https://github.com/someone/fork.git"
  local answer own='[![codecov](https://codecov.io/github/someone/fork/graph/badge.svg)](https://codecov.io/github/someone/fork)'
  for answer in "exit 22" "echo 'rate limited'" "echo '{}'"; do
    printf '%s\n' '# test' '<!-- BADGES:START -->' "[![Lint & Test](x)](y) $own [![Bash](z)](w)" '<!-- BADGES:END -->' \
      '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
    printf '#!/usr/bin/env bash\n%s\n' "$answer" >"$MOCK_DIR/curl"
    chmod +x "$MOCK_DIR/curl"

    run "$TEST_TMPDIR/scripts/update-readme.sh"
    [ "$status" -eq 0 ]
    grep -qF "(https://github.com/someone/fork/actions/workflows/ci.yml) $own [![Bash]" "$TEST_TMPDIR/README.md"
    run ! grep -q 'codecov.io/github/staticwire' "$TEST_TMPDIR/README.md"
  done
}

@test "update-readme: without a GitHub origin only the static badges remain" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  readme_with_badges
  git -C "$TEST_TMPDIR" init -q

  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Badges updated (repo: unknown)"* ]]
  local badges
  badges=$(sed -n '3p' "$TEST_TMPDIR/README.md")
  [[ "$badges" == *"[![Bash]"*"[![AUR]"*"[![License]"* ]]
  [[ "$badges" != *"Lint & Test"* && "$badges" != *"codecov"* ]]
}

@test "update-readme: an unknown status reads as tracking" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  echo "something_new" >"$TEST_TMPDIR/.status/pkg-a"
  printf '%s\n' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q

  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF '<td>1.0.0</td><td nowrap>github-release</td><td nowrap>—</td><td nowrap>✅ tracking</td>' "$TEST_TMPDIR/README.md"
  grep -qF 'packages-1%2F1-brightgreen' "$TEST_TMPDIR/README.md"
}

@test "update-readme: a package without current is new" {
  create_test_package "pkg-new" "github-release" "upstream:
  project: owner/repo"
  printf '%s\n' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q

  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF '<tr><td><a href="https://aur.archlinux.org/pkgbase/pkg-new">pkg-new</a></td><td>—</td><td nowrap>github-release</td><td nowrap>—</td><td nowrap>✨ new</td></tr>' "$TEST_TMPDIR/README.md"
}

# A package that has not been checked yet has failed nothing
@test "update-readme: a new package counts as ok in the badge" {
  create_test_package "pkg-new" "github-release" "upstream:
  project: owner/repo"
  printf '%s\n' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q

  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF 'packages-1%2F1-brightgreen' "$TEST_TMPDIR/README.md"

  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF 'packages-2%2F2-brightgreen' "$TEST_TMPDIR/README.md"
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
  grep -qF '<td nowrap>github-release</td><td nowrap>—</td>' "$TEST_TMPDIR/README.md"
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
  cat >"$aur_dir/PKGBUILD" <<'EOF'
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

  cat >"$MOCK_DIR/git" <<MOCKGIT
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
  cat >"$aur_dir/PKGBUILD" <<'EOF'
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

  cat >"$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  cat >"$MOCK_DIR/makepkg" <<'EOF'
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
  cat >"$aur_dir/PKGBUILD" <<'EOF'
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

  cat >"$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  # Mock curl to return HTML content-type for HEAD requests
  cat >"$MOCK_DIR/curl" <<'MOCKCURL'
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
  cat >"$aur_dir/PKGBUILD" <<'EOF'
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

  cat >"$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  # Mock curl for source URL validation
  cat >"$MOCK_DIR/curl" <<'MOCKCURL'
#!/usr/bin/env bash
if [[ "$1" == "-sIL" ]]; then
  printf '200 application/octet-stream'
  exit 0
fi
echo '{}'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"

  cat >"$MOCK_DIR/updpkgsums" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$MOCK_DIR/updpkgsums"

  cat >"$MOCK_DIR/makepkg" <<'EOF'
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
  cat >"$aur_dir/PKGBUILD" <<'EOF'
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

  cat >"$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  cat >"$MOCK_DIR/curl" <<'MOCKCURL'
#!/usr/bin/env bash
if [[ "$1" == "-sIL" ]]; then
  printf '200 application/octet-stream'
  exit 0
fi
echo '{}'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"

  cat >"$MOCK_DIR/updpkgsums" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$MOCK_DIR/updpkgsums"

  cat >"$MOCK_DIR/makepkg" <<'EOF'
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
  cat >"$aur_dir/PKGBUILD" <<'EOF'
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

  cat >"$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  cat >"$MOCK_DIR/curl" <<'MOCKCURL'
#!/usr/bin/env bash
if [[ "$1" == "-sIL" ]]; then
  printf '200 application/octet-stream'
  exit 0
fi
echo '{}'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"

  cat >"$MOCK_DIR/updpkgsums" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$MOCK_DIR/updpkgsums"

  cat >"$MOCK_DIR/makepkg" <<'EOF'
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
  cat >"$aur_dir/PKGBUILD" <<'EOF'
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

  cat >"$MOCK_DIR/git" <<MOCKGIT
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
  cat >"$aur_dir/PKGBUILD" <<'EOF'
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
  cat >"$MOCK_DIR/git" <<MOCKGIT
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
  cat >"$aur_dir/PKGBUILD" <<'EOF'
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
  cat >"$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  # Mock makepkg --printsrcinfo
  cat >"$MOCK_DIR/makepkg" <<'EOF'
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
  cat >"$aur_dir/PKGBUILD" <<'EOF'
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

  cat >"$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  cat >"$MOCK_DIR/makepkg" <<'EOF'
#!/usr/bin/env bash
echo "pkgbase = test-arch-skip"
echo "pkgname = test-arch-skip"
EOF
  chmod +x "$MOCK_DIR/makepkg"

  # HEAD requests get a file and every URL asked for is logged
  cat >"$MOCK_DIR/curl" <<MOCKCURL
#!/usr/bin/env bash
echo "\${@: -1}" >>"$TEST_TMPDIR/curl-urls.log"
printf '200 application/octet-stream'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"

  run "$TEST_TMPDIR/scripts/update-pkg.sh" "test-arch-skip" "1.0.1"
  [[ "$output" == *"VCS package, skipping checksums"* ]]
  [[ "$output" != *"Updating checksums"* ]]
  grep -q "nightly-x86_64.tar.gz" "$TEST_TMPDIR/curl-urls.log"
  grep -q "nightly-aarch64.tar.gz" "$TEST_TMPDIR/curl-urls.log"
}

# A source with a SKIP checksum is not downloaded by any later step, so
# without the HEAD request a URL that answers 404 would reach the AUR, as a
# tag built from $pkgver does for a release whose tag never moves.
@test "update-pkg: checks source URLs when every checksum is SKIP" {
  create_test_package "test-skip-url" "github-asset" "upstream:
  project: owner/repo
  tag: continuous
  assets:
    - test.AppImage
current: '20261022'"

  aur_dir="$TEST_TMPDIR/aur-test-skip-url"
  mkdir -p "$aur_dir"
  git -C "$aur_dir" init -q
  git -C "$aur_dir" config user.name "test"
  git -C "$aur_dir" config user.email "test@test"
  git -C "$aur_dir" config commit.gpgsign false
  cat >"$aur_dir/PKGBUILD" <<'EOF'
# Maintainer: test
pkgname=test-skip-url
pkgver=20261022
pkgrel=1
pkgdesc="test SKIP source URL"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("test.AppImage::https://example.com/releases/download/${pkgver}/test.AppImage")
sha256sums=('SKIP')
EOF
  git -C "$aur_dir" add . && git -C "$aur_dir" commit -q -m "init"

  cat >"$MOCK_DIR/git" <<MOCKGIT
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  cp -r "$aur_dir" "\$3" 2>/dev/null || cp -r "$aur_dir/." "\$3" 2>/dev/null
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKGIT
  chmod +x "$MOCK_DIR/git"

  cat >"$MOCK_DIR/curl" <<MOCKCURL
#!/usr/bin/env bash
echo "\${@: -1}" >>"$TEST_TMPDIR/curl-urls.log"
printf '404 text/plain'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"

  run "$TEST_TMPDIR/scripts/update-pkg.sh" "test-skip-url" "20261023"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Source URL returned HTTP 404: https://example.com/releases/download/20261023/test.AppImage"* ]]
  [[ "$output" == *"Source URL validation failed, aborting"* ]]
  [[ "$output" != *"VCS package, skipping checksums"* ]]
  [[ "$output" != *"Pushed"* ]]
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

  grep -q "🔻 downgraded to 1.0.0" "$TEST_TMPDIR/README.md"
  # Downgrades count toward pkg_ok, so the badge stays green.
  grep -q "brightgreen" "$TEST_TMPDIR/README.md"
  run ! grep -q "packages-.*-red" "$TEST_TMPDIR/README.md"
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

  grep -q "🔻 1.0.0 available (downgrade)" "$TEST_TMPDIR/README.md"
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

  grep -q "🔻 1.0.0 skipped (downgrade)" "$TEST_TMPDIR/README.md"
  grep -q "brightgreen" "$TEST_TMPDIR/README.md"
}

# === version jumps ===

# Helper: a strategy that prints the given version
# Usage: stand_in_strategy <name> <version>
stand_in_strategy() {
  printf '#!/usr/bin/env bash\necho %s\n' "$2" >"$TEST_TMPDIR/strategies/$1.sh"
  chmod +x "$TEST_TMPDIR/strategies/$1.sh"
}

# GrapheneOS/hardened_malloc releases 13 and 14 next to OS build tags
@test "check-all: skips a version jump without allow_version_jump" {
  stand_in_strategy jump 2026102100
  create_test_package "pkg-jump" "jump" "current: '13'"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"version jump 13 → 2026102100, skipped: allow_version_jump is not set"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-jump")" = "jump_skipped: 2026102100" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "0" ]
}

@test "check-all: writes 'new_version:' for a version jump the package allows" {
  stand_in_strategy jump 2026102100
  create_test_package "pkg-jump" "jump" "current: '13'
allow_version_jump: true"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-jump")" = "new_version: 2026102100" ]
}

@test "check-all: writes 'new_version:' for a usual step" {
  stand_in_strategy step 100
  create_test_package "pkg-step" "step" "current: '99'"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-step")" = "new_version: 100" ]
}

@test "update-readme: renders a skipped version jump and keeps the badge green" {
  create_test_package "pkg-jump" "github-release" "upstream:
  project: owner/repo
current: '13'"

  echo "jump_skipped: 2026102100" >"$TEST_TMPDIR/.status/pkg-jump"

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null

  grep -q "🔺 2026102100 skipped (version jump)" "$TEST_TMPDIR/README.md"
  grep -q "brightgreen" "$TEST_TMPDIR/README.md"
}

@test "check-all: holds an update an alert with hold: true fires on" {
  stand_in_strategy step 29+1
  create_test_package "pkg-hold" "step" "current: 28+25
alerts:
  - when: major
    hold: true
    note: Raise makedepends java-environment to 28"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pkg-hold: update 28+25 → 29+1 held: Raise makedepends java-environment to 28"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-hold")" = "held: 29+1" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "0" ]
}

@test "check-all: logs the note of an alert without hold and keeps the update" {
  stand_in_strategy step 29+1
  create_test_package "pkg-note" "step" "current: 28+25
alerts:
  - when: major
    note: Create the package for the old major"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pkg-note: update 28+25 → 29+1 notice: Create the package for the old major"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-note")" = "new_version: 29+1" ]
}

@test "check-all: logs every fired alert of a held update" {
  stand_in_strategy step 29+1
  create_test_package "pkg-both" "step" "current: 28+25
alerts:
  - when: major
    note: Create the package for the old major
  - match: '^29\\+'
    hold: true
    note: Raise makedepends java-environment to 28"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [[ "$output" == *"pkg-both: update 28+25 → 29+1 notice: Create the package for the old major"* ]]
  [[ "$output" == *"pkg-both: update 28+25 → 29+1 held: Raise makedepends java-environment to 28"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-both")" = "held: 29+1" ]
}

@test "check-all: records the fired alerts of a package in _alerts" {
  stand_in_strategy step 29+1
  create_test_package "pkg-both" "step" "current: 28+25
alerts:
  - when: major
    note: Create the package for the old major
  - match: '^29\\+'
    hold: true
    note: Raise makedepends java-environment to 28"
  create_test_package "pkg-calm" "step" "current: 29+0
alerts:
  - when: major
    note: Not fired"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/_alerts")" = $'pkg-both\tnotice\tCreate the package for the old major\npkg-both\thold\tRaise makedepends java-environment to 28' ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "0" ]
}

@test "check-all: writes no _alerts when no alert fires" {
  stand_in_strategy step 29+1
  create_test_package "pkg-calm" "step" "current: 29+0
alerts:
  - when: major
    note: Not fired"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/.status/_alerts" ]
}

@test "check-all: a skipped version jump or downgrade wins over a hold" {
  stand_in_strategy jump 2026102100
  create_test_package "pkg-jump" "jump" "current: '13'
alerts:
  - when: major
    hold: true
    note: New major"
  stand_in_strategy older 1.0
  create_test_package "pkg-down" "older" "current: '2.0'
alerts:
  - match: '^1'
    hold: true
    note: Old line"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-jump")" = "jump_skipped: 2026102100" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-down")" = "downgrade_skipped: 1.0" ]
  [[ "$output" != *"held:"* ]]
}

@test "check-all: holds nothing for a package without current" {
  stand_in_strategy step 1.0
  create_test_package "pkg-new" "step" "alerts:
  - from: '0.1'
    hold: true
    note: First release"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-new")" = "new_version: 1.0" ]
}

@test "check-all: fails the check of a package with an alert it cannot evaluate" {
  stand_in_strategy step 29+1
  create_test_package "pkg-bad" "step" "current: 28+25
alerts:
  - match: '(?:29)'
    hold: true
    note: New major"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [[ "$(cat "$TEST_TMPDIR/.status/pkg-bad")" == "check_failed: "*"alerts[0].match must be a non-empty ERE that bash accepts: (?:29)" ]]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "1" ]
}

@test "check-all --update: runs no update of a held version" {
  stand_in_strategy step 29+1
  create_test_package "pkg-hold" "step" "current: 28+25
alerts:
  - when: major
    hold: true
    note: Raise makedepends java-environment to 28"
  rm -f "$TEST_TMPDIR/scripts/update-pkg.sh"
  cat >"$TEST_TMPDIR/scripts/update-pkg.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$TEST_TMPDIR/update-pkg.args"
EOF
  chmod +x "$TEST_TMPDIR/scripts/update-pkg.sh"

  run "$TEST_TMPDIR/scripts/check-all.sh" --update
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/update-pkg.args" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-hold")" = "held: 29+1" ]
}

@test "update-readme: renders a held update and keeps the badge green" {
  create_test_package "pkg-hold" "github-release" "upstream:
  project: owner/repo
current: 28+25"

  echo "held: 29+1" >"$TEST_TMPDIR/.status/pkg-hold"

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null

  grep -q "<td nowrap>✋ 29+1 held</td>" "$TEST_TMPDIR/README.md"
  grep -q "brightgreen" "$TEST_TMPDIR/README.md"
}

@test "check-all: --prepare, --verify and --publish need a directory" {
  local option
  for option in --prepare --verify --publish; do
    run "$TEST_TMPDIR/scripts/check-all.sh" "$option"
    [ "$status" -eq 1 ]
    [ "$output" = "$option needs a directory" ]
  done
}

@test "check-all: --dry-run reaches update-pkg.sh" {
  create_test_package "pkg-up" "github-release" "upstream:
  type: github
  project: owner/repo
current: '1.0.0'"
  rm -f "$TEST_TMPDIR/scripts/update-pkg.sh"
  cat >"$TEST_TMPDIR/scripts/update-pkg.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$TEST_TMPDIR/update-pkg.args"
EOF
  chmod +x "$TEST_TMPDIR/scripts/update-pkg.sh"

  "$TEST_TMPDIR/scripts/check-all.sh" --update --dry-run 2>/dev/null || true
  [ "$(cat "$TEST_TMPDIR/update-pkg.args")" = "pkg-up 2.0.0 --dry-run" ]
}

@test "check-all: writes 'up_to_date' when --update finds the version on the AUR" {
  create_test_package "pkg-up" "github-release" "upstream:
  type: github
  project: owner/repo
current: '1.0.0'"
  rm -f "$TEST_TMPDIR/scripts/update-pkg.sh"
  printf '#!/usr/bin/env bash\nexit 2\n' >"$TEST_TMPDIR/scripts/update-pkg.sh"
  chmod +x "$TEST_TMPDIR/scripts/update-pkg.sh"

  "$TEST_TMPDIR/scripts/check-all.sh" --update 2>/dev/null || true
  [ "$(cat "$TEST_TMPDIR/.status/pkg-up")" = "up_to_date" ]
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

# === check-asset.sh ===

# Helper: the git of tests/helpers/mock-git.sh, which answers ls-remote
mock_tags() {
  cp "$TESTS_DIR/helpers/mock-git.sh" "$MOCK_DIR/git"
  chmod +x "$MOCK_DIR/git"
}

# Helper: liquidsoap-bin on the mock of savonet/liquidsoap, with the given
# asset_regex
# Usage: liquidsoap_package [asset_regex]
liquidsoap_package() {
  mock_tags
  create_test_package "liq" "github-tag" "upstream:
  project: asset-owner/asset-repo
  tag_version_regex: '^v([0-9.]+(-rc[0-9]+)?)\$'
  asset_regex: '${1:-^liquidsoap_([0-9.]+-debian-forky-ocaml5\\.[0-9.]+-[0-9]+)_amd64\\.deb\$}'
  asset_var: _deb
pkgver_dash: ''"
}

@test "check-asset: prints the value of the one asset that matches" {
  liquidsoap_package
  run --separate-stderr "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc1
  [ "$status" -eq 0 ]
  [ "$output" = "2.5.0-debian-forky-ocaml5.5.1-1" ]
}

# The regex of the brief takes the OCaml 4 and the OCaml 5 build of 2.4.6
@test "check-asset: fails when two assets match" {
  liquidsoap_package '^liquidsoap_([0-9.]+-debian-forky-ocaml[0-9.]+-[0-9]+)_amd64\.deb$'
  run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.4.6
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 assets of release v2.4.6 match upstream.asset_regex, expected one: liquidsoap_2.4.6-debian-forky-ocaml4.14.2-3_amd64.deb liquidsoap_2.4.6-debian-forky-ocaml5.4.0-3_amd64.deb"* ]]
}

@test "check-asset: waits for the asset of a release younger than a day" {
  liquidsoap_package
  MOCK_ASSETS="" MOCK_RELEASE_AGE=2 run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc1
  [ "$status" -eq 3 ]
  [[ "$output" == *"liq 2.5.0rc1: no asset of release v2.5.0-rc1 matches upstream.asset_regex"* ]]
}

@test "check-asset: fails for a release older than a day without the asset" {
  liquidsoap_package
  MOCK_ASSETS="liquidsoap_2.5.0-debian-forky-ocaml5.5.1-1_riscv64.deb other.txt" \
    run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc1
  [ "$status" -eq 1 ]
  [[ "$output" == *"liq 2.5.0rc1: no asset of release v2.5.0-rc1 matches upstream.asset_regex"* ]]
  [[ "$output" == *"liquidsoap_2.5.0-debian-forky-ocaml5.5.1-1_riscv64.deb other.txt"* ]]
}

@test "check-asset: waits for the release of a tag younger than a day" {
  liquidsoap_package
  MOCK_TAG_AGE=1 run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc2
  [ "$status" -eq 3 ]
  [[ "$output" == *"liq 2.5.0rc2: tag v2.5.0-rc2 has no release"* ]]
}

@test "check-asset: fails for a tag that has no release after a day" {
  liquidsoap_package
  run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc2
  [ "$status" -eq 1 ]
  [[ "$output" == *"liq 2.5.0rc2: tag v2.5.0-rc2 has no release"* ]]
}

@test "check-asset: fails when the tags cannot be read" {
  mock_tags
  create_test_package "gone" "github-tag" "upstream:
  project: missing-owner/missing-repo
  asset_regex: '^gone-(.+)\\.tar\\.gz\$'
  asset_var: _gone"
  run "$TEST_TMPDIR/scripts/check-asset.sh" gone 1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to fetch tags for missing-owner/missing-repo"* ]]
}

@test "check-asset: fails when no tag gives the version" {
  liquidsoap_package
  run "$TEST_TMPDIR/scripts/check-asset.sh" liq 9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"No tag of asset-owner/asset-repo gives version 9.9.9"* ]]
}

@test "check-asset: fails when two tags give the version" {
  mock_tags
  create_test_package "twin" "github-tag" "upstream:
  project: asset-owner/twin-repo
  asset_regex: '^twin-(.+)\\.tar\\.gz\$'
  asset_var: _twin"
  run "$TEST_TMPDIR/scripts/check-asset.sh" twin 1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tags v1.0.0 1.0.0 of asset-owner/twin-repo all give version 1.0.0"* ]]
}

@test "check-asset: fails when the release cannot be read" {
  liquidsoap_package
  MOCK_RELEASE_STATUS=500 run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc1
  [ "$status" -eq 1 ]
  [[ "$output" == *"The requested URL returned error: 500"* ]]
  [[ "$output" == *"Failed to read the release of tag v2.5.0-rc1 of asset-owner/asset-repo"* ]]
}

@test "check-asset: fails when the commit of a tag without a release cannot be read" {
  liquidsoap_package
  MOCK_COMMIT_STATUS=500 run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc2
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to read the commit of tag v2.5.0-rc2 of asset-owner/asset-repo"* ]]
}

# bash expands a tilde at the start of an assignment
@test "check-asset: refuses a value that starts with a tilde" {
  liquidsoap_package '^liquidsoap_(.+)_amd64\.deb$'
  MOCK_ASSETS="liquidsoap_~root_amd64.deb" run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Asset value rejected"* ]]
}

@test "check-asset: refuses a date of another form" {
  liquidsoap_package
  MOCK_ASSETS="" MOCK_RELEASE_DATE=soon run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unexpected date from the GitHub API: 'soon'"* ]]
}

@test "check-asset: percent-encodes the tag in the URL of its release" {
  mock_tags
  create_test_package "plus" "github-tag" "upstream:
  project: asset-owner/plus-repo
  asset_regex: '^plus_(.+)\\.tar\\.gz\$'
  asset_var: _plus"
  run --separate-stderr "$TEST_TMPDIR/scripts/check-asset.sh" plus 1.0+1
  [ "$status" -eq 0 ]
  [ "$output" = "1.0-build7" ]
}

@test "check-asset: needs upstream.asset_regex" {
  create_test_package "plain" "github-tag" "upstream:
  project: asset-owner/asset-repo"
  run "$TEST_TMPDIR/scripts/check-asset.sh" plain 2.4.6
  [ "$status" -eq 1 ]
  [[ "$output" == *"plain has no upstream.asset_regex"* ]]
}

# === check-all.sh: values from release asset names ===

# Helper: a check-asset.sh that logs its arguments to check-asset.args and
# prints the given value, or exits with 3 for pending and 1 for fail
# Usage: stand_in_asset <value|pending|fail>
stand_in_asset() {
  local body="echo $1"
  case "$1" in
    pending) body='echo "no asset yet" >&2; exit 3' ;;
    fail) body='echo "release unreadable" >&2; exit 1' ;;
  esac
  rm -f "$TEST_TMPDIR/scripts/check-asset.sh"
  printf '#!/usr/bin/env bash\necho "$*" >>%q\n%s\n' "$TEST_TMPDIR/check-asset.args" "$body" >"$TEST_TMPDIR/scripts/check-asset.sh"
  chmod +x "$TEST_TMPDIR/scripts/check-asset.sh"
}

# Helper: pkg on the stand-in strategy step, with asset_regex, at
# <current>, and with <current_asset> when it is given
# Usage: asset_package <current> [current_asset]
asset_package() {
  create_test_package "pkg" "step" "upstream:
  asset_regex: '^x_(.+)\$'
  asset_var: _x
current: '$1'${2:+
current_asset: '$2'}"
}

@test "check-all: records the asset value of a new version" {
  stand_in_strategy step 2.0.0
  asset_package 1.0.0 1.0.0-a
  stand_in_asset 2.0.0-a
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "new_version: 2.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/_assets")" = $'pkg\t2.0.0-a' ]
  [ "$(cat "$TEST_TMPDIR/check-asset.args")" = "pkg 2.0.0" ]
}

@test "check-all: keeps a package up to date while its asset value stays" {
  stand_in_strategy step 1.0.0
  asset_package 1.0.0 1.0.0-a
  stand_in_asset 1.0.0-a
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "up_to_date" ]
  [ "$(cat "$TEST_TMPDIR/check-asset.args")" = "pkg 1.0.0" ]
}

@test "check-all: finds a rebuild in a new asset value of the current version" {
  stand_in_strategy step 1.0.0
  asset_package 1.0.0 1.0.0-a
  stand_in_asset 1.0.0-b
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "new_build: 1.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/_assets")" = $'pkg\t1.0.0-b' ]
  [ "$(cat "$TEST_TMPDIR/check-asset.args")" = "pkg 1.0.0" ]
}

@test "check-all: takes a missing current_asset for another asset value" {
  stand_in_strategy step 1.0.0
  asset_package 1.0.0
  stand_in_asset 1.0.0-a
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "new_build: 1.0.0" ]
}

@test "check-all: writes pending while the asset of a new version is not out" {
  stand_in_strategy step 2.0.0
  asset_package 1.0.0 1.0.0-a
  stand_in_asset pending
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no asset yet"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "pending: 2.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "0" ]
  [ ! -e "$TEST_TMPDIR/.status/_assets" ]
}

@test "check-all: writes pending while the asset of the current version is not out" {
  stand_in_strategy step 1.0.0
  asset_package 1.0.0 1.0.0-a
  stand_in_asset pending
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "pending: 1.0.0" ]
}

@test "check-all: fails the check when the asset value cannot be found, and checks again" {
  stand_in_strategy step 2.0.0
  asset_package 1.0.0 1.0.0-a
  stand_in_asset fail
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "check_failed: release unreadable" ]
  [ "$(cat "$TEST_TMPDIR/check-asset.args")" = $'pkg 2.0.0\npkg 2.0.0' ]
}

@test "check-all: asks no asset value for a held update" {
  stand_in_strategy step 29+1
  create_test_package "pkg" "step" "upstream:
  asset_regex: '^x_(.+)\$'
  asset_var: _x
current: 28+25
alerts:
  - when: major
    hold: true
    note: Raise makedepends java-environment to 28"
  stand_in_asset 29+1-a
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "held: 29+1" ]
  [ ! -e "$TEST_TMPDIR/check-asset.args" ]
}

@test "check-all: asks no asset value for a package without asset_regex" {
  stand_in_strategy step 2.0.0
  create_test_package "pkg" "step" "current: '1.0.0'"
  stand_in_asset 2.0.0-a
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "new_version: 2.0.0" ]
  [ ! -e "$TEST_TMPDIR/check-asset.args" ]
  [ ! -e "$TEST_TMPDIR/.status/_assets" ]
}

# Helper: an update-pkg.sh that logs its arguments to update-pkg.args
log_update_pkg() {
  rm -f "$TEST_TMPDIR/scripts/update-pkg.sh"
  printf '#!/usr/bin/env bash\necho "$*" >>%q\n' "$TEST_TMPDIR/update-pkg.args" >"$TEST_TMPDIR/scripts/update-pkg.sh"
  chmod +x "$TEST_TMPDIR/scripts/update-pkg.sh"
}

@test "check-all --update: passes the asset value to update-pkg" {
  stand_in_strategy step 2.0.0
  asset_package 1.0.0 1.0.0-a
  stand_in_asset 2.0.0-a
  log_update_pkg
  run "$TEST_TMPDIR/scripts/check-all.sh" --update
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/update-pkg.args")" = "pkg 2.0.0 --asset 2.0.0-a" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "updated: 2.0.0" ]
}

@test "check-all --update: pushes a rebuild" {
  stand_in_strategy step 1.0.0
  asset_package 1.0.0 1.0.0-a
  stand_in_asset 1.0.0-b
  log_update_pkg
  run "$TEST_TMPDIR/scripts/check-all.sh" --update
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/update-pkg.args")" = "pkg 1.0.0 --asset 1.0.0-b" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "rebuilt: 1.0.0" ]
}

@test "update-readme: renders a rebuild and a pending asset, and keeps the badge green" {
  local name
  for name in built rebuilt waiting; do
    create_test_package "$name" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  done
  echo "new_build: 1.0.0" >"$TEST_TMPDIR/.status/built"
  echo "rebuilt: 1.0.0" >"$TEST_TMPDIR/.status/rebuilt"
  echo "pending: 2.0.0" >"$TEST_TMPDIR/.status/waiting"
  printf '%s\n' "<!-- PACKAGES:START -->" "<!-- PACKAGES:END -->" >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF '<td nowrap>🔨 1.0.0 rebuild available</td>' "$TEST_TMPDIR/README.md"
  grep -qF '<td nowrap>🔨 1.0.0 rebuilt</td>' "$TEST_TMPDIR/README.md"
  grep -qF '<td nowrap>⏳ 2.0.0 pending</td>' "$TEST_TMPDIR/README.md"
  grep -q "brightgreen" "$TEST_TMPDIR/README.md"
}
