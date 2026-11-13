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

# setup_test_env exports AURTOMATOR_DATA_DIR, so env -u removes it
@test "lib.sh: AURTOMATOR_DATA_DIR defaults to the working directory" {
  mkdir -p "$BATS_TEST_TMPDIR/data/packages"
  touch "$BATS_TEST_TMPDIR/data/packages/foo.yml"

  run env -u AURTOMATOR_DATA_DIR bash -c 'cd "$1" && source "$0/scripts/lib.sh" && pkg_file foo' "$TEST_TMPDIR" "$BATS_TEST_TMPDIR/data"
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/data/packages/foo.yml" ]
}

@test "lib.sh: pkg_file and load_config read AURTOMATOR_DATA_DIR" {
  mkdir -p "$BATS_TEST_TMPDIR/data/packages"
  touch "$BATS_TEST_TMPDIR/data/packages/foo.yml"
  echo "GIT_AUTHOR_NAME='x'" >"$BATS_TEST_TMPDIR/data/.aurtomator.conf"

  AURTOMATOR_DATA_DIR="$BATS_TEST_TMPDIR/data" run bash -c 'source "$0/scripts/lib.sh" && load_config && pkg_file foo && echo "$GIT_AUTHOR_NAME"' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$BATS_TEST_TMPDIR/data/packages/foo.yml" ]
  [ "${lines[1]}" = x ]
}

@test "lib.sh: a wrong AURTOMATOR_DATA_DIR stops the script" {
  AURTOMATOR_DATA_DIR="$BATS_TEST_TMPDIR/none" run bash -c 'source "$0/scripts/lib.sh"; echo reached' "$TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [ "$output" = "AURTOMATOR_DATA_DIR is not a directory: $BATS_TEST_TMPDIR/none" ]
}

# Without -- cd takes -P as its option and goes to $HOME
@test "lib.sh: AURTOMATOR_DATA_DIR may start with a dash" {
  mkdir -p "$BATS_TEST_TMPDIR/-P/packages"
  touch "$BATS_TEST_TMPDIR/-P/packages/foo.yml"

  run env AURTOMATOR_DATA_DIR=-P bash -c 'cd "$1" && source "$0/scripts/lib.sh" && pkg_file foo' "$TEST_TMPDIR" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/-P/packages/foo.yml" ]
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

# bash also takes a space before the parentheses, the function keyword and
# an indented header
@test "audit_pkgbuild: blocks pkgver() under every header bash takes" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  local header
  for header in 'pkgver () {' 'function pkgver {' '  pkgver() {'; do
    # shellcheck disable=SC2016
    printf '%s\n' 'pkgname=test' 'pkgver=2.2.0' 'pkgrel=1' 'arch=(any)' \
      'source=("https://example.com/test-$pkgver.tar.gz")' "sha256sums=('abc123')" \
      "$header" '  date +%Y%m%d' '}' >"$TEST_TMPDIR/test.PKGBUILD"
    run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
    echo "$header: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"BLOCKED: pkgver() function detected with strategy 'github-release'."* ]]
  done
}

@test "audit_pkgbuild: keeps the errors of sourcing the PKGBUILD out of its output" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  write_pkgver_pkgbuild '  date +%Y%m%d'
  # shellcheck disable=SC2016
  printf '%s\n' '_tool=$(aurtomator-no-such-tool)' >>"$TEST_TMPDIR/test.PKGBUILD"
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
  [ "$status" -eq 1 ]
  [[ "$output" != *"aurtomator-no-such-tool"* ]]
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

# pacman compares the epoch first, and an update leaves it as it is
@test "audit_pkgbuild: warns on an epoch other than 0" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<'EOF'
pkgname=test-epoch
pkgver=19.7.0
pkgrel=1
epoch=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/test-${pkgver}.tar.gz")
sha256sums=('abc123')
EOF
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
  [ "$status" -eq 2 ]
  [[ "$output" == *"PKGBUILD sets epoch=1: an update keeps it, and current holds the version without it."* ]]
  [[ "$output" == *"pacman does not install a downgrade over the newer version unless epoch is raised by hand."* ]]

  sed -i 's/^epoch=1$/epoch=0/' "$TEST_TMPDIR/test.PKGBUILD"
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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
  # A nightly-bin package: SKIP for the remote binary, and real hashes for local files of the
  # AUR repo, such as .vim and .install
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
    "bzr+https://example.com/app"; do
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
    "hg+https://example.com/app#revision=4" "hg+https://example.com/app#tag=v1" \
    "bzr+https://example.com/app#revision=4"; do
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

# Helper: test.PKGBUILD with the given VCS source at SKIP and a download
# with a real hash
write_vcs_data_pkgbuild() {
  cat >"$TEST_TMPDIR/test.PKGBUILD" <<EOF
pkgname=test-vcs-data
pkgver=1.0.0
pkgrel=1
pkgdesc="test"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("$1"
        "https://example.com/data-\${pkgver}.tar.gz")
sha256sums=('SKIP'
            'abc123')
EOF
}

# update-pkg.sh runs updpkgsums next to a real remote hash, so the fix is the
# hash that updpkgsums writes
@test "audit_pkgbuild: names the source whose SKIP updpkgsums would turn into a hash" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  # shellcheck disable=SC2016
  write_vcs_data_pkgbuild 'git+https://example.org/foo.git#tag=v${pkgver}'
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
  [ "$status" -eq 1 ]
  [[ "$output" == *"updpkgsums runs for the real hashes and would turn the SKIP of these sources into a hash, which the check of the prepared files refuses:"* ]]
  [[ "$output" == *"    git+https://example.org/foo.git#tag=v1.0.0"* ]]
  [[ "$output" == *"Run updpkgsums once and push the PKGBUILD with these hashes to the AUR"* ]]
  [[ "$output" != *"data-1.0.0.tar.gz"* ]]
}

# makepkg 7.1 has no checksum for svn and writes SKIP at any pin
@test "audit_pkgbuild: allows the SKIP of an svn source pinned by revision next to a real hash" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  write_vcs_data_pkgbuild "svn+https://svn.example.org/foo/trunk#revision=1234"
  run audit_pkgbuild "$TEST_TMPDIR/test.PKGBUILD" "github-release"
  [ "$status" -eq 0 ]
}

# A fossil clone is one file, which makepkg -g hashes as a download
@test "audit_pkgbuild: blocks the SKIP of a fossil source next to a real hash" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  local vcs
  for vcs in "fossil+https://example.com/app" "fossil+https://example.com/app#commit=abc123"; do
    write_vcs_data_pkgbuild "$vcs"
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

  # check-update prints the version on stdout and the log on stderr
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

# Helper: a curl that appends its arguments to curl.args, one per line,
# before it answers
record_curl() {
  mv "$MOCK_DIR/curl" "$MOCK_DIR/curl-answer"
  cat >"$MOCK_DIR/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$TEST_TMPDIR/curl.args"
exec "$MOCK_DIR/curl-answer" "\$@"
EOF
  chmod +x "$MOCK_DIR/curl"
}

# Helper: the value of every --max-filesize that curl got, in order
curl_max_filesizes() {
  grep -x -A1 -- '--max-filesize' "$TEST_TMPDIR/curl.args" | grep -vx -e '--max-filesize' -e '--'
}

@test "check-update: gives the strategy the answer limit of the package" {
  record_curl
  create_test_package "release" "github-release" "upstream:
  project: owner/repo
  max_answer_mb: 80
current: '1.0.0'"
  run --separate-stderr "$TEST_TMPDIR/scripts/check-update.sh" release
  [ "$status" -eq 0 ]
  [ "$output" = "2.0.0" ]
  [ "$(curl_max_filesizes | sort -u)" = "80M" ]
}

@test "check-update: refuses an answer limit that is no whole number from 1 to 500" {
  local value
  record_curl
  for value in 0 501 1.5 10M abc; do
    echo "$value"
    create_test_package "release" "github-release" "upstream:
  project: owner/repo
  max_answer_mb: $value
current: '1.0.0'"
    run "$TEST_TMPDIR/scripts/check-update.sh" release
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream.max_answer_mb must be a whole number from 1 to 500"* ]]
  done
  [ ! -e "$TEST_TMPDIR/curl.args" ]
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

@test "lib.sh: validate_source_urls skips the source arrays of the arches it is given" {
  cat >"$TEST_TMPDIR/PKGBUILD" <<'EOF'
pkgname=test-arches
pkgver=1.0.0
pkgrel=1
arch=('armv7h' 'riscv64')
source=("https://example.com/test-1.0.0.tar.gz")
source_armv7h=("https://example.com/test-1.0.0-armv7h.tar.gz")
source_riscv64=("https://example.com/test-1.0.0-riscv64.tar.gz")
sha256sums=('abc123')
sha256sums_armv7h=('abc123')
sha256sums_riscv64=('abc123')
EOF
  cat >"$MOCK_DIR/curl" <<MOCKCURL
#!/usr/bin/env bash
echo "\${@: -1}" >>"$TEST_TMPDIR/curl-urls.log"
printf '200 application/octet-stream'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"
  local lib='source "$0/scripts/lib.sh"; validate_source_urls "$1" "$2"'
  run bash -c "$lib" "$TEST_TMPDIR" "$TEST_TMPDIR/PKGBUILD" "armv7h"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/curl-urls.log")" = $'https://example.com/test-1.0.0.tar.gz\nhttps://example.com/test-1.0.0-riscv64.tar.gz' ]
  rm "$TEST_TMPDIR/curl-urls.log"
  run bash -c "$lib" "$TEST_TMPDIR" "$TEST_TMPDIR/PKGBUILD" "riscv64 armv7h"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/curl-urls.log")" = "https://example.com/test-1.0.0.tar.gz" ]
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

# Helper: a PKGBUILD with one source, and a curl that prints $CURL_W and exits $CURL_RC, as real
# curl -s prints the -w text and nothing on stderr when it fails
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

# === arch.sh ===

@test "arch.sh: srcinfo_arches prints the arches of pkgbase alone" {
  arch_srcinfo "$TEST_TMPDIR/.SRCINFO"
  printf '\npkgname = jdk-temurin-ea-doc\n\tarch = any\n' >>"$TEST_TMPDIR/.SRCINFO"
  source "$TEST_TMPDIR/scripts/lib.sh"
  run srcinfo_arches "$TEST_TMPDIR/.SRCINFO"
  [ "$status" -eq 0 ]
  [ "$output" = $'x86_64\naarch64\npowerpc64le\nriscv64' ]
}

@test "arch.sh: srcinfo_arch_lines prints the lines of one arch in every section, after the section" {
  local url=https://github.com/adoptium/temurin28-binaries/releases/download/jdk-28+22-ea-beta
  local base='pkgbase = jdk-temurin-ea-bin' name='pkgname = jdk-temurin-ea-bin'
  arch_srcinfo "$TEST_TMPDIR/.SRCINFO"
  printf '\tdepends_aarch64 = zlib-ng\n' >>"$TEST_TMPDIR/.SRCINFO"
  source "$TEST_TMPDIR/scripts/lib.sh"
  run srcinfo_arch_lines "$TEST_TMPDIR/.SRCINFO" aarch64
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\t\t%s\n' "$base" 'arch = aarch64' "$base" "source_aarch64 = $url/OpenJDK-jdk_aarch64_linux_hotspot_28_22-ea.tar.gz" \
    "$base" 'depends_aarch64 = zlib' "$base" "sha256sums_aarch64 = $(printf aarch6428+22 | sha256sum | cut -d' ' -f1)" "$name" 'depends_aarch64 = zlib-ng')" ]
  run srcinfo_arch_lines "$TEST_TMPDIR/.SRCINFO" x86_64
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\t\t%s\n' "$base" 'arch = x86_64' "$base" "source_x86_64 = $url/OpenJDK-jdk_x64_linux_hotspot_28_22-ea.tar.gz" \
    "$base" "sha256sums_x86_64 = $(printf x86_6428+22 | sha256sum | cut -d' ' -f1)")" ]
}

@test "arch.sh: srcinfo_pkgver prints the pkgver" {
  arch_srcinfo "$TEST_TMPDIR/.SRCINFO" 28+23
  source "$TEST_TMPDIR/scripts/lib.sh"
  run srcinfo_pkgver "$TEST_TMPDIR/.SRCINFO"
  [ "$status" -eq 0 ]
  [ "$output" = 28+23 ]
}

@test "arch.sh: pkgbuild_arch_words reads the arch line in any quoting" {
  local line
  source "$TEST_TMPDIR/scripts/lib.sh"
  for line in "arch=('x86_64' 'aarch64')" 'arch=("x86_64" "aarch64")' 'arch=(x86_64 aarch64)' "arch=('x86_64'  \"aarch64\")  "; do
    printf 'pkgname=demo\n%s\nsource_x86_64=(demo.tar.gz)\n' "$line" >"$TEST_TMPDIR/PKGBUILD"
    run pkgbuild_arch_words "$TEST_TMPDIR/PKGBUILD"
    [ "$status" -eq 0 ]
    [ "$output" = $'x86_64\naarch64' ] || {
      echo "read: $line"
      return 1
    }
  done
}

@test "arch.sh: pkgbuild_arch_words refuses an arch line it cannot edit" {
  local body
  local -a bodies=(
    "pkgname=demo"
    $'arch=(\'x86_64\')\narch=(\'aarch64\')'
    $'arch=(\'x86_64\')\npackage() {\n  arch=(\'any\')\n}'
    $'arch=(\'x86_64\')\narch+=(\'aarch64\')'
    'arch=("$CARCH")'
    $'arch=(\'x86_64\'\n  \'aarch64\')'
    'arch=()'
    "arch=('x86_64') # all"
    "arch=('x86-64')"
  )
  source "$TEST_TMPDIR/scripts/lib.sh"
  for body in "${bodies[@]}"; do
    printf '%s\n' "$body" >"$TEST_TMPDIR/PKGBUILD"
    run pkgbuild_arch_words "$TEST_TMPDIR/PKGBUILD"
    [ "$status" -eq 1 ] && [ -z "$output" ] || {
      echo "taken: $body"
      return 1
    }
  done
}

@test "arch.sh: arch_line writes the words in the quoting of the first word" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  [ "$(arch_line "arch=('x86_64' \"aarch64\")" x86_64 riscv64)" = "arch=('x86_64' 'riscv64')" ]
  [ "$(arch_line "arch=(\"x86_64\" 'aarch64')" x86_64 riscv64)" = 'arch=("x86_64" "riscv64")' ]
  [ "$(arch_line "arch=(x86_64 'aarch64')" x86_64 riscv64)" = 'arch=(x86_64 riscv64)' ]
}

@test "arch.sh: arch_order puts an arch back at its place" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  [ "$(arch_order 'x86_64 powerpc64le riscv64' aarch64 'x86_64 aarch64 powerpc64le riscv64')" = 'x86_64 aarch64 powerpc64le riscv64' ]
  [ "$(arch_order 'x86_64 riscv64' powerpc64le 'x86_64 aarch64 powerpc64le riscv64')" = 'x86_64 powerpc64le riscv64' ]
  [ "$(arch_order 'aarch64 riscv64' x86_64 'x86_64 aarch64 riscv64')" = 'x86_64 aarch64 riscv64' ]
  [ "$(arch_order 'x86_64 aarch64' aarch64 'x86_64 aarch64')" = 'x86_64 aarch64' ]
}

@test "arch.sh: arch_update_words takes out the listed arches it does not keep and puts each arch back by its commit" {
  local ref="$TEST_TMPDIR/ref"
  mkdir -p "$ref/aarch64" "$ref/powerpc64le"
  arch_srcinfo "$ref/aarch64/.SRCINFO"
  arch_srcinfo "$ref/powerpc64le/.SRCINFO" 28+20 x86_64 powerpc64le aarch64
  source "$TEST_TMPDIR/scripts/lib.sh"
  [ "$(arch_update_words 'x86_64 aarch64 riscv64' aarch64 '' '' "$ref")" = 'x86_64 riscv64' ]
  [ "$(arch_update_words 'x86_64 aarch64 riscv64' 'riscv64 aarch64' aarch64 '' "$ref")" = 'x86_64 aarch64' ]
  [ "$(arch_update_words 'x86_64 riscv64' '' '' aarch64 "$ref")" = 'x86_64 aarch64 riscv64' ]
  [ "$(arch_update_words 'x86_64 riscv64' riscv64 '' 'aarch64 powerpc64le' "$ref")" = 'x86_64 powerpc64le aarch64' ]
}

@test "arch.sh: arch_urls builds the URLs of an arch for a new version" {
  arch_srcinfo "$TEST_TMPDIR/.SRCINFO"
  source "$TEST_TMPDIR/scripts/lib.sh"
  run arch_urls "$TEST_TMPDIR/.SRCINFO" aarch64 28+22 28+23 "" "" "" "" ""
  [ "$status" -eq 0 ]
  [ "$output" = https://github.com/adoptium/temurin28-binaries/releases/download/jdk-28+23-ea-beta/OpenJDK-jdk_aarch64_linux_hotspot_28_23-ea.tar.gz ]
}

@test "arch.sh: arch_urls takes the https downloads alone, after a file name" {
  printf '%s\n' 'pkgbase = demo' $'\tpkgver = 1.2.0' $'\tarch = aarch64' \
    $'\tsource_aarch64 = demo-1.2.0.tar.gz::https://example.com/v1.2.0/demo-aarch64.tar.gz' \
    $'\tsource_aarch64 = git+https://example.com/demo.git#tag=v1.2.0' \
    $'\tsource_aarch64 = http://example.com/v1.2.0/extra.tar.gz' \
    $'\tsource_aarch64 = demo.patch' $'\tsource_x86_64 = https://example.com/v1.2.0/demo-x86_64.tar.gz' >"$TEST_TMPDIR/.SRCINFO"
  source "$TEST_TMPDIR/scripts/lib.sh"
  run arch_urls "$TEST_TMPDIR/.SRCINFO" aarch64 1.2.0 1.3.0 "" "" "" "" ""
  [ "$status" -eq 0 ]
  [ "$output" = https://example.com/v1.3.0/demo-aarch64.tar.gz ]
}

@test "arch.sh: arch_urls replaces an asset value, a dash form and the version in pkgver_format" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  printf '\tsource_aarch64 = %s\n' https://github.com/savonet/liquidsoap/releases/download/v2.4.6/liquidsoap_2.4.6-debian-forky-ocaml5.4.0-3_arm64.deb >"$TEST_TMPDIR/.SRCINFO"
  run arch_urls "$TEST_TMPDIR/.SRCINFO" aarch64 2.4.6 2.5.0 "" "" "" 2.4.6-debian-forky-ocaml5.4.0-3 2.5.0-debian-forky-ocaml5.5.1-1
  [ "$output" = https://github.com/savonet/liquidsoap/releases/download/v2.5.0/liquidsoap_2.5.0-debian-forky-ocaml5.5.1-1_arm64.deb ]
  printf '\tsource_aarch64 = %s\n' https://example.com/0.0.1-rc.20/demo-0.0.1-rc.20-aarch64.tar.gz >"$TEST_TMPDIR/.SRCINFO"
  run arch_urls "$TEST_TMPDIR/.SRCINFO" aarch64 0.0.1_rc.20 0.0.1_rc.21 "" "" _ "" ""
  [ "$output" = https://example.com/0.0.1-rc.21/demo-0.0.1-rc.21-aarch64.tar.gz ]
  printf '\tsource_aarch64 = %s\n' https://example.com/build/4215/demo-aarch64.tar.gz >"$TEST_TMPDIR/.SRCINFO"
  run arch_urls "$TEST_TMPDIR/.SRCINFO" aarch64 4.4215 4.4216 4215 4216 "" "" ""
  [ "$output" = https://example.com/build/4216/demo-aarch64.tar.gz ]
}

# Helper: a curl that logs its arguments, prints $CURL_W and exits $CURL_RC
mock_probe_curl() {
  cat >"$MOCK_DIR/curl" <<MOCKCURL
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TEST_TMPDIR/curl.args"
printf '%s' "\$CURL_W"
exit "\${CURL_RC:-0}"
MOCKCURL
  chmod +x "$MOCK_DIR/curl"
}

@test "arch.sh: probe_url tells a file from a missing one and from no answer" {
  local entry rc expected
  local -a cases=(
    "0|0|200 application/octet-stream"
    "0|0|399 application/gzip"
    "0|1|400 application/octet-stream"
    "0|1|404 text/html; charset=utf-8"
    "0|1|200 Text/HTML; charset=utf-8"
    "0|2|000 "
    "0|2|BASH_VERSINFO[\$(id>$TEST_TMPDIR/pwned)] text/plain"
    "7|2|000 "
    "47|2|302 text/plain"
  )
  mock_probe_curl
  source "$TEST_TMPDIR/scripts/lib.sh"
  for entry in "${cases[@]}"; do
    rc=0
    IFS='|' read -r CURL_RC expected CURL_W <<<"$entry"
    export CURL_RC CURL_W
    probe_url https://example.com/demo-aarch64.tar.gz || rc=$?
    [ "$rc" -eq "$expected" ] || {
      echo "$entry gave $rc"
      return 1
    }
  done
  [ ! -e "$TEST_TMPDIR/pwned" ]
  [ "$(head -1 "$TEST_TMPDIR/curl.args")" = "-sIL -o /dev/null -w %{http_code} %{content_type} --max-time 10 --max-redirs 5 https://example.com/demo-aarch64.tar.gz" ]
}

@test "arch.sh: probe_url names its request while curl runs" {
  keep_host_memory
  timeout_curl
  source "$TEST_TMPDIR/scripts/lib.sh"
  probe_url https://example.com/demo-aarch64.tar.gz || true
  [ "$(cat "$TEST_TMPDIR/curl.log")" = "https://example.com/demo-aarch64.tar.gz|https://example.com/demo-aarch64.tar.gz https://example.com/demo-aarch64.tar.gz" ]
  [ ! -s "$AURTOMATOR_HOSTS_DIR/request" ]
}

@test "arch.sh: probe_url asks a silent host nothing and remembers no host after its timeout" {
  keep_host_memory silent.example
  mock_probe_curl
  source "$TEST_TMPDIR/scripts/lib.sh"
  run probe_url https://silent.example/demo-aarch64.tar.gz
  [ "$status" -eq 2 ]
  [ "$output" = "https://silent.example/demo-aarch64.tar.gz: silent.example did not answer earlier in this run" ]
  [ ! -e "$TEST_TMPDIR/curl.args" ]
  CURL_RC=28 CURL_W="000 " run probe_url https://slow.example/demo-aarch64.tar.gz
  [ "$status" -eq 2 ]
  [ "$(cat "$AURTOMATOR_HOSTS_DIR/silent")" = "silent.example" ]
}

# === http_get ===

@test "lib.sh: http_get tries a transient failure again" {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*"\n' >"$MOCK_DIR/curl"
  chmod +x "$MOCK_DIR/curl"
  source "$TEST_TMPDIR/scripts/lib.sh"
  run http_get https://example.invalid/a --max-redirs 5
  [ "$status" -eq 0 ]
  [ "$output" = '-sfL --max-time 30 --retry 2 --retry-delay 5 --retry-connrefused --proto =https --proto-redir =https --max-filesize 50M -A aurtomator/1.0 -w %{onerror}%{stderr}%{url_effective}\t%{errormsg}\t%{http_code}\t%header{cf-mitigated} --max-redirs 5 https://example.invalid/a' ]
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
  CURL_RC=22 CURL_STDERR='https://example.com/b\tThe requested URL returned error: 404\t404\t' run http_get https://example.com/a
  [ "$status" -eq 22 ]
  [ "$output" = "https://example.com/b: The requested URL returned error: 404" ]
}

# anydesk.com sends this answer to every client without JavaScript,
# whatever its User-Agent
@test "lib.sh: http_get names a Cloudflare challenge" {
  mock_curl_failure
  source "$TEST_TMPDIR/scripts/lib.sh"
  CURL_RC=22 CURL_STDERR='https://example.com/a\tThe requested URL returned error: 403\t403\tchallenge' run http_get https://example.com/a
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

# Helper: a curl that logs its URL and the request in flight to curl.log, and
# answers a host listed in silent-hosts as curl does after a timeout
timeout_curl() {
  cat >"$MOCK_DIR/curl" <<'MOCKCURL'
#!/usr/bin/env bash
url="${*: -1}"
request=$(paste -sd ' ' "${AURTOMATOR_HOSTS_DIR:-/nonexistent}/request" 2>/dev/null)
printf '%s|%s\n' "$url" "$request" >>"$TEST_TMPDIR/curl.log"
host="${url#https://}"
if grep -qxF -e "${host%%/*}" "$TEST_TMPDIR/silent-hosts" 2>/dev/null; then
  printf '%s\tOperation timed out after 30000 milliseconds with 0 bytes received\t000\t' "$url" >&2
  exit 28
fi
echo '{}'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"
}

@test "lib.sh: http_get remembers a host that gave no answer, and asks it no more" {
  keep_host_memory
  timeout_curl
  echo silent.example >"$TEST_TMPDIR/silent-hosts"
  source "$TEST_TMPDIR/scripts/lib.sh"
  run http_get https://silent.example/a
  [ "$status" -eq 28 ]
  [ "$output" = "https://silent.example/a: Operation timed out after 30000 milliseconds with 0 bytes received" ]
  [ "$(cat "$AURTOMATOR_HOSTS_DIR/silent")" = "silent.example" ]
  [ ! -s "$AURTOMATOR_HOSTS_DIR/request" ]
  run http_get https://SILENT.example/b
  [ "$status" -eq 28 ]
  [ "$output" = "https://SILENT.example/b: silent.example did not answer earlier in this run" ]
  [ "$(cat "$TEST_TMPDIR/curl.log")" = "https://silent.example/a|https://silent.example/a https://silent.example/a" ]
}

@test "lib.sh: http_get remembers no host after an answer, a refusal or an HTTP error" {
  keep_host_memory
  mock_curl_failure
  source "$TEST_TMPDIR/scripts/lib.sh"
  CURL_RC=28 CURL_STDERR='https://slow.example/a\tOperation timed out after 30000 milliseconds with 7 out of 100000 bytes received\t200\t' run http_get https://slow.example/a
  [ "$status" -eq 28 ]
  CURL_RC=7 CURL_STDERR='https://refused.example/a\tFailed to connect to refused.example port 443 after 0 ms: Could not connect to server\t000\t' run http_get https://refused.example/a
  [ "$status" -eq 7 ]
  CURL_RC=22 CURL_STDERR='https://gone.example/a\tThe requested URL returned error: 404\t404\t' run http_get https://gone.example/a
  [ "$status" -eq 22 ]
  [ ! -s "$AURTOMATOR_HOSTS_DIR/silent" ]
}

@test "lib.sh: url_host gives no host for a URL with a user name or a port" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  local url
  for url in 'https://api.github.com@127.0.0.1:9/repos/a/b' 'https://user:pw@codeberg.org/api' \
    'https://api.github.com:9/x' 'https://api.github.com:443' 'http://api.github.com/x'; do
    run url_host "$url"
    [ "$status" -eq 1 ] && [ -z "$output" ] || {
      echo "keyed: $url as $output"
      return 1
    }
  done
  run url_host 'https://API.GitHub.com/repos?q=1'
  [ "$output" = api.github.com ]
  run url_host 'https://codeberg.org'
  [ "$output" = codeberg.org ]
}

# check-all.sh runs no validate-pkg.sh, and the name reaches the paths of statuses
@test "check-all: skips a package whose name is not its file name" {
  create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo"
  sed -i 's|^name: mypkg$|name: ../escape|' "$TEST_TMPDIR/packages/mypkg.yml"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [[ "$output" == *"packages/mypkg.yml: name '../escape' must equal the file name"* ]]
  [ ! -e "$TEST_TMPDIR/escape" ]
  [ ! -e "$TEST_TMPDIR/.status/mypkg" ]
}

@test "check-update: refuses a strategy that is no plain name" {
  create_test_package "mypkg" "../../escape" "upstream:
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/check-update.sh" mypkg
  [ "$status" -eq 1 ]
  [[ "$output" == *"mypkg: strategy must be a plain name: '../../escape'"* ]]
}

@test "check-arch: refuses an arch_out that names no full commit id" {
  create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
arch_out:
  aarch64: abc123"
  run "$TEST_TMPDIR/scripts/check-arch.sh" mypkg 1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"mypkg: arch_out must map arch names to commit ids of 40 hex digits"* ]]
}

# Under a UTF-8 locale other than C.UTF-8, [a-z] in [[ =~ ]] takes letters such as é
@test "lib.sh: the name checks take ASCII alone under a UTF-8 locale" {
  locale -a 2>/dev/null | command grep -qix 'en_US.utf8' || skip "no en_US.UTF-8 locale"
  source "$TEST_TMPDIR/scripts/lib.sh"
  LC_ALL=en_US.UTF-8 run url_host 'https://é.example/x'
  [ "$status" -eq 1 ]
  create_test_package "mypkg" "github-asset" "upstream:
  project: owner/repo
  asset_var: _aé
arch_out:
  é: $(printf 'a%.0s' {1..40})"
  LC_ALL=en_US.UTF-8 run pkg_asset_var "$TEST_TMPDIR/packages/mypkg.yml"
  [ "$status" -eq 1 ]
  create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
arch_out:
  é: $(printf 'a%.0s' {1..40})"
  LC_ALL=en_US.UTF-8 run "$TEST_TMPDIR/scripts/check-arch.sh" mypkg 1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"arch_out must map arch names to commit ids of 40 hex digits"* ]]
  LC_ALL=en_US.UTF-8 run "$TEST_TMPDIR/scripts/draft.sh" 'é'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "lib.sh: a request with a user name in its URL remembers no host" {
  keep_host_memory
  timeout_curl
  echo 'api.github.com@silent.example' >"$TEST_TMPDIR/silent-hosts"
  source "$TEST_TMPDIR/scripts/lib.sh"
  run http_get 'https://api.github.com@silent.example/a'
  [ "$status" -eq 28 ]
  [ ! -s "$AURTOMATOR_HOSTS_DIR/silent" ]
}

@test "lib.sh: a silent api.github.com leaves github.com alone" {
  keep_host_memory api.github.com
  timeout_curl
  source "$TEST_TMPDIR/scripts/lib.sh"
  run http_get https://github.com/owner/repo
  [ "$status" -eq 0 ]
  [ "$(cut -d'|' -f1 "$TEST_TMPDIR/curl.log")" = "https://github.com/owner/repo" ]
}

@test "lib.sh: without a memory of hosts http_get asks a host again after a timeout" {
  timeout_curl
  echo silent.example >"$TEST_TMPDIR/silent-hosts"
  source "$TEST_TMPDIR/scripts/lib.sh"
  run http_get https://silent.example/a
  [ "$status" -eq 28 ]
  AURTOMATOR_HOSTS_DIR="$TEST_TMPDIR/none" run http_get https://silent.example/a
  [ "$status" -eq 28 ]
  [ "$(wc -l <"$TEST_TMPDIR/curl.log")" -eq 2 ]
  [ ! -e "$TEST_TMPDIR/none" ]
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
  [ "$(grep -x -A1 -- -w "$TEST_TMPDIR/curl.args" | tail -1)" = '\n%{url_effective}%{onerror}%{stderr}%{url_effective}\t%{errormsg}\t%{http_code}\t%header{cf-mitigated}' ]
}

@test "lib.sh: http_get_json stops at a failed request" {
  mock_curl_failure
  source "$TEST_TMPDIR/scripts/lib.sh"
  CURL_RC=22 CURL_STDERR='https://example.com/a\tThe requested URL returned error: 404\t404\t' run http_get_json https://example.com/a
  [ "$status" -eq 22 ]
  [ "$output" = "https://example.com/a: The requested URL returned error: 404" ]
}

# Helper: a git that logs its arguments and the request in flight to git.log,
# and prints one tag
logging_git() {
  cat >"$MOCK_DIR/git" <<'MOCKGIT'
#!/usr/bin/env bash
request=$(paste -sd ' ' "${AURTOMATOR_HOSTS_DIR:-/nonexistent}/request" 2>/dev/null)
printf '%s|%s\n' "$*" "$request" >>"$TEST_TMPDIR/git.log"
printf 'abc\trefs/tags/v1.0.0\n'
MOCKGIT
  chmod +x "$MOCK_DIR/git"
}

@test "lib.sh: remote_tags and aur_clone name their request and the URL of git for the HEAD check" {
  keep_host_memory
  logging_git
  source "$TEST_TMPDIR/scripts/lib.sh"
  run remote_tags https://git.example/repo.git
  [ "$status" -eq 0 ]
  [ "$output" = "v1.0.0" ]
  [ ! -s "$AURTOMATOR_HOSTS_DIR/request" ]
  run aur_clone https://aur.archlinux.org/pkg.git "$TEST_TMPDIR/aur" --no-checkout
  [ "$status" -eq 0 ]
  [ ! -s "$AURTOMATOR_HOSTS_DIR/request" ]
  [ "$(cat "$TEST_TMPDIR/git.log")" = "ls-remote --tags --refs https://git.example/repo.git|https://git.example/repo.git https://git.example/repo.git/info/refs?service=git-upload-pack
clone --no-checkout https://aur.archlinux.org/pkg.git $TEST_TMPDIR/aur|https://aur.archlinux.org/pkg.git https://aur.archlinux.org/pkg.git/info/refs?service=git-upload-pack" ]
}

@test "lib.sh: remote_tags and aur_clone ask a silent host nothing" {
  keep_host_memory git.example aur.archlinux.org
  logging_git
  source "$TEST_TMPDIR/scripts/lib.sh"
  run remote_tags https://git.example/repo.git
  [ "$status" -eq 1 ]
  [ "$output" = "https://git.example/repo.git: git.example did not answer earlier in this run" ]
  run aur_clone https://aur.archlinux.org/pkg.git "$TEST_TMPDIR/aur"
  [ "$status" -eq 1 ]
  [ "$output" = "https://aur.archlinux.org/pkg.git: aur.archlinux.org did not answer earlier in this run" ]
  [ ! -e "$TEST_TMPDIR/git.log" ]
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

# The log goes to stderr, so check-all.sh 2>run.log on a terminal writes a
# log without color codes, and check-all.sh | less keeps them on the terminal
@test "lib.sh: the colors of the log follow stderr, not stdout" {
  printf 'source "$1/scripts/lib.sh"\nlog_ok done\n' >"$TEST_TMPDIR/color.sh"
  run script -qec "bash $TEST_TMPDIR/color.sh $TEST_TMPDIR 2>$TEST_TMPDIR/err" /dev/null
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/err")" = "✓ done" ]
  run script -qec "bash $TEST_TMPDIR/color.sh $TEST_TMPDIR >/dev/null" /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\e[0;32m✓\e[0m done'* ]]
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

@test "lib.sh: validate_pkgver takes 64 characters and names the length of more" {
  local v64
  v64="$(printf 'a%.0s' {1..63})1"
  run bash -c 'source "$0/scripts/lib.sh"; validate_pkgver "$1"' "$TEST_TMPDIR" "$v64"
  [ "$status" -eq 0 ]
  run bash -c 'source "$0/scripts/lib.sh"; validate_pkgver "$1"' "$TEST_TMPDIR" "${v64}2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Version string rejected, it has 65 characters and at most 64 are allowed"* ]]
  [[ "$output" != *"$v64"* ]]
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
    "when: minor|alerts[0].when must be major, got minor" \
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

# Each line of the note would become a line of _alerts
@test "lib.sh: fired_alerts fails on a note that is not one line of text" {
  local note
  for note in "" "note: ''" "note: |
      Rename the binary
      hold" "note: \"Rename\\rthe binary\"" "note: 42"; do
    echo "$note"
    create_test_package "pkg" "github-release" "alerts:
  - from: '0.4.0'
    $note"
    run bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" 0.3 29+1 2>/dev/null' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/pkg.yml"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" "" 29+1' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/pkg.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"alerts[0].note must be one line of text"* ]]
  done
}

@test "lib.sh: fired_alerts asks for quotes around a note that YAML reads as a number" {
  create_test_package "pkg" "github-release" "alerts:
  - from: '0.4.0'
    note: 2024"
  run bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" 0.3 29+1' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/pkg.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"alerts[0].note must be one line of text: put 2024 in quotes"* ]]
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

# It returns before it asks the API, and says nothing
@test "lib.sh: upstream_status fails without VERSION" {
  run bash -c 'source "$0/scripts/lib.sh"; upstream_status' "$TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "check-all: logs the version and records a newer release of aurtomator" {
  echo "0.6.0" >"$TEST_TMPDIR/VERSION"
  MOCK_UPSTREAM_TAG=v0.7.0 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"aurtomator 0.6.0" ]]
  [[ "$output" == *"aurtomator 0.7.0 is out, this repository runs 0.6.0"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/_upstream")" = "newer: 0.7.0" ]
  [ "$(failed_statuses "$TEST_TMPDIR/.status")" = "0" ]
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
  [ "$(failed_statuses "$TEST_TMPDIR/.status")" = "0" ]
}

@test "check-all: asks for no release without VERSION" {
  MOCK_UPSTREAM_TAG=fail run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"aurtomator"* ]]
  [ ! -e "$TEST_TMPDIR/.status/_upstream" ]
}

@test "update-readme: writes the version under the package table" {
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
  echo "0.6.0" >"$TEST_TMPDIR/VERSION"
  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null

  grep -qx '</table>' "$TEST_TMPDIR/README.md"
  run grep -A2 -x '</table>' "$TEST_TMPDIR/README.md"
  [ "$output" = $'</table>\n\naurtomator 0.6.0' ]
}

@test "update-readme: links a newer release of aurtomator" {
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
  echo "0.6.0" >"$TEST_TMPDIR/VERSION"
  echo "newer: 0.7.0" >"$TEST_TMPDIR/.status/_upstream"
  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null

  grep -qxF 'aurtomator 0.6.0 ([0.7.0 available](https://github.com/staticwire/aurtomator/releases/tag/v0.7.0))' "$TEST_TMPDIR/README.md"
}

@test "update-readme: links no release for aurtomator at its release or for another _upstream" {
  local upstream
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
  echo "0.6.0" >"$TEST_TMPDIR/VERSION"
  git -C "$TEST_TMPDIR" init -q
  for upstream in "current: 0.7.0" "xnewer: 0.7.0" "newer: 0.7.0 x"; do
    printf '%s\n' "$upstream" >"$TEST_TMPDIR/.status/_upstream"
    printf '%s\n' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
    "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null
    grep -qxF 'aurtomator 0.6.0' "$TEST_TMPDIR/README.md" || {
      echo "linked for: $upstream"
      return 1
    }
  done
}

@test "update-readme: writes no version line without VERSION" {
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
  echo "current: 0.6.0" >"$TEST_TMPDIR/.status/_upstream"
  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  "$TEST_TMPDIR/scripts/update-readme.sh" 2>/dev/null

  grep -qx '</table>' "$TEST_TMPDIR/README.md"
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
  [[ "$output" != *"holds a dash"* ]]
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
  [[ "$output" == *"The version holds a dash: set pkgver_dash, or tag_version_regex to leave such tags out"* ]]
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

@test "check-all: logs the number of errors" {
  create_test_package "pkg-a" "github-release" "upstream:
  type: github
  project: owner/repo
current: '2.0.0'"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [[ "$output" == *"Checked: 1, Updated: 0, Errors: 0"* ]]
  [ ! -e "$TEST_TMPDIR/.status/_error_count" ]
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

# A skipped downgrade is logged with the name of its package
@test "check-all: reads the packages of AURTOMATOR_DATA_DIR and runs the strategies of the checkout" {
  mkdir -p "$BATS_TEST_TMPDIR/data/packages"
  cat >"$BATS_TEST_TMPDIR/data/packages/foo.yml" <<EOF
name: foo
strategy: github-release
upstream:
  type: github
  project: owner/repo
current: '3.0.0'
EOF

  AURTOMATOR_DATA_DIR="$BATS_TEST_TMPDIR/data" run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"foo: DOWNGRADE detected"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/data/.status/foo")" = "downgrade_skipped: 2.0.0" ]
  [ ! -e "$TEST_TMPDIR/.status/foo" ]
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
  AURTOMATOR_DATA_DIR="$SPACED" run "$SPACED/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checked: 1, Updated: 0, Errors: 0"* ]]
  [ "$(cat "$SPACED/.status/pkg")" = "up_to_date" ]
}

@test "update-readme: lists the packages of a project whose path has a space" {
  make_spaced_project
  printf '%s\n' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$SPACED/README.md"
  git -C "$SPACED" init -q
  AURTOMATOR_DATA_DIR="$SPACED" run "$SPACED/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF '>pkg</a>' "$SPACED/README.md"
}

# === update-readme.sh ===

@test "update-readme: generates the package table" {
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

  grep -q "pkg-a" "$TEST_TMPDIR/README.md"
  grep -q "github-release" "$TEST_TMPDIR/README.md"
}

# The name in a package YAML is the pkgbase. The AUR shows a split package under /pkgbase/<name>
# and redirects /pkgbase/<name> of any other package to /packages/<name>.
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

@test "update-readme: names the arches out of a package in its status" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '28+23'
arch_out:
  riscv64: '$(printf 'a%.0s' {1..40})'
  aarch64: '$(printf 'b%.0s' {1..40})'"
  echo "up_to_date" >"$TEST_TMPDIR/.status/pkg-a"
  printf '%s\n' "# test" "<!-- PACKAGES:START -->" "<!-- PACKAGES:END -->" >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF '<td nowrap>⚠️ 28+23 without riscv64 aarch64</td></tr>' "$TEST_TMPDIR/README.md"
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
  [ "$(sed -n '/PACKAGES:START/,/PACKAGES:END/p' "$TEST_TMPDIR/README.md" | sed '1,7d')" = '
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

@test "update-readme: writes the README of AURTOMATOR_DATA_DIR from its packages and origin" {
  local data="$BATS_TEST_TMPDIR/data"
  mkdir -p "$data/packages" "$data/.status"
  git -C "$data" init -q
  git -C "$data" remote add origin "https://github.com/owner/data.git"
  cat >"$data/packages/foo.yml" <<EOF
name: foo
strategy: github-release
upstream:
  project: owner/repo
current: '1.0.0'
EOF
  # Without this file the package reads as tracking
  echo "new_version: 3.0.0" >"$data/.status/foo"
  printf '%s\n' '# test' '<!-- BADGES:START -->' '<!-- BADGES:END -->' \
    '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$data/README.md"

  AURTOMATOR_DATA_DIR="$data" run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Badges updated (repo: owner/data)"* ]]
  grep -qF 'https://github.com/owner/data/actions/workflows/validate.yml/badge.svg' "$data/README.md"
  grep -q '>foo</a></td><td>1.0.0</td><td nowrap>github-release</td><td nowrap>-</td><td nowrap>.* 3.0.0 available</td></tr>' "$data/README.md"
  [ ! -e "$TEST_TMPDIR/README.md" ]
}

# version.sh assigns AURTOMATOR_UPSTREAM, so the environment cannot set it
# for the script. A copy of version.sh with another value stands in.
@test "update-readme: the badge block names the two calling workflows of the repository" {
  local data="$BATS_TEST_TMPDIR/data"
  mkdir -p "$data/packages" "$data/.status"
  printf '%s\n' 'name: pkg-a' 'strategy: github-release' 'upstream:' '  project: owner/repo' >"$data/packages/pkg-a.yml"
  git -C "$data" init -q
  git -C "$data" remote add origin "https://github.com/owner/data.git"
  printf '%s\n' '# test' '<!-- BADGES:START -->' 'old badges' '<!-- BADGES:END -->' \
    '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$data/README.md"
  sed 's|^AURTOMATOR_UPSTREAM=.*|AURTOMATOR_UPSTREAM=other/upstream|' "$PROJECT_DIR/scripts/lib/version.sh" >"$BATS_TEST_TMPDIR/version.sh"
  ln -sf "$BATS_TEST_TMPDIR/version.sh" "$TEST_TMPDIR/scripts/lib/version.sh"

  AURTOMATOR_DATA_DIR="$data" run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  [ "$(sed -n '3p' "$data/README.md")" = '[![Validate packages](https://github.com/owner/data/actions/workflows/validate.yml/badge.svg)](https://github.com/owner/data/actions/workflows/validate.yml) [![Check AUR Package Updates](https://github.com/owner/data/actions/workflows/check-updates.yml/badge.svg)](https://github.com/owner/data/actions/workflows/check-updates.yml) [![maintained with aurtomator](https://img.shields.io/badge/maintained%20with-aurtomator-1793d1?logo=archlinux&logoColor=white)](https://github.com/staticwire/aurtomator)' ]
  [ "$(sed -n '4p' "$data/README.md")" = '<!-- BADGES:END -->' ]
  local badges pattern
  badges=$(sed -n '/^<!-- BADGES:START -->$/,/^<!-- BADGES:END -->$/p' "$data/README.md")
  for pattern in codecov ci.yml shields.io/badge/bash aur.archlinux.org; do
    echo "$pattern"
    [[ "$badges" != *"$pattern"* ]]
  done
}

# aurtomator_version reads VERSION from AURTOMATOR_DIR, which is $TEST_TMPDIR here
@test "update-readme: the README of aurtomator is what the script writes for it" {
  local data="$BATS_TEST_TMPDIR/data"
  mkdir -p "$data/packages"
  git -C "$data" init -q
  git -C "$data" remote add origin "https://github.com/staticwire/aurtomator.git"
  cp "$PROJECT_DIR/README.md" "$data/README.md"
  cp "$PROJECT_DIR/VERSION" "$TEST_TMPDIR/VERSION"

  AURTOMATOR_DATA_DIR="$data" run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  run diff -u "$PROJECT_DIR/README.md" "$data/README.md"
  echo "$output"
  [ "$status" -eq 0 ]
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

# extra/yq of Arch is a jq wrapper with other options, and conflicts with
# go-yq
@test "lib.sh: require_cmd yq takes mikefarah/yq and refuses another yq" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  run require_cmd yq
  [ "$status" -eq 0 ]
  printf '#!/bin/sh\necho "yq 3.4.3"\n' >"$MOCK_DIR/yq"
  chmod +x "$MOCK_DIR/yq"
  run require_cmd yq
  [ "$status" -eq 1 ]
  [[ "$output" == *"yq must be mikefarah/yq, go-yq on Arch, and this one prints: yq 3.4.3"* ]]
}

@test "lib.sh: require_cmd yq refuses a mikefarah/yq older than the scripts need" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  printf '%s\n' '#!/bin/sh' 'if [ "$1" = --version ]; then' \
    '  echo "yq (https://github.com/mikefarah/yq/) version 4.12.0"' '  exit 0' 'fi' \
    'echo "Error: unknown shorthand flag: r" >&2' 'exit 1' >"$MOCK_DIR/yq"
  chmod +x "$MOCK_DIR/yq"
  run require_cmd yq
  [ "$status" -eq 1 ]
  [[ "$output" == *"yq is older than the scripts need, and this one prints: yq (https://github.com/mikefarah/yq/) version 4.12.0"* ]]
}

# validate-pkg.sh reads every scalar with the kind operator of yq 4.40.1
@test "lib.sh: require_cmd yq refuses a mikefarah/yq without kind" {
  local real
  real=$(command -v yq)
  source "$TEST_TMPDIR/scripts/lib.sh"
  printf '%s\n' '#!/bin/sh' 'if [ "$1" = --version ]; then' \
    '  echo "yq (https://github.com/mikefarah/yq/) version 4.35.2"' '  exit 0' 'fi' \
    'case "$*" in *kind*) echo "Error: unknown operator kind" >&2 && exit 1 ;; esac' \
    "exec $real \"\$@\"" >"$MOCK_DIR/yq"
  chmod +x "$MOCK_DIR/yq"
  run require_cmd yq
  [ "$status" -eq 1 ]
  [[ "$output" == *"yq is older than the scripts need, and this one prints: yq (https://github.com/mikefarah/yq/) version 4.35.2"* ]]
}

# Prints the four values that load_config of lib.sh reads from the
# .aurtomator.conf of $TEST_TMPDIR, one per line
load_config_values() {
  bash -c 'source "$1/scripts/lib.sh" && load_config && printf "%s\n" "$GIT_AUTHOR_NAME" "$GIT_AUTHOR_EMAIL" "$GPG_KEY_ID" "$AUR_SSH_KEY"' _ "$TEST_TMPDIR"
}

# setup.sh writes ${value@Q}, and before 0.3.0 wrote double quotes
@test "lib.sh: load_config reads the four values as data" {
  cat >"$TEST_TMPDIR/.aurtomator.conf" <<'EOF'
# written by hand
GIT_AUTHOR_NAME='Jane $(touch PWNED) `id` Doe'

GIT_AUTHOR_EMAIL='it'\''s@example.com'
GPG_KEY_ID=''
AUR_SSH_KEY="/srv/keys/aur key"
EOF
  run --keep-empty-lines load_config_values
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'Jane $(touch PWNED) `id` Doe' ]
  [ "${lines[1]}" = "it's@example.com" ]
  [ "${lines[2]}" = "" ]
  [ "${lines[3]}" = "/srv/keys/aur key" ]
  [ ! -e PWNED ]

  # A last line without a newline counts
  printf "GIT_AUTHOR_NAME='a'\nGIT_AUTHOR_EMAIL='b'\nAUR_SSH_KEY='c'\nGPG_KEY_ID='KEY9'" >"$TEST_TMPDIR/.aurtomator.conf"
  run --keep-empty-lines load_config_values
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "KEY9" ]
}

# git puts a tracked file in place of the ignored one at a checkout or a merge
@test "lib.sh: load_config refuses a .aurtomator.conf that git tracks" {
  printf "GIT_AUTHOR_NAME='a'\nGIT_AUTHOR_EMAIL='b'\nAUR_SSH_KEY='c'\nGPG_KEY_ID='d'\n" >"$TEST_TMPDIR/.aurtomator.conf"
  git -C "$TEST_TMPDIR" init -q
  run load_config_values
  [ "$status" -eq 0 ]

  git -C "$TEST_TMPDIR" add -f .aurtomator.conf
  run load_config_values
  [ "$status" -eq 1 ]
  [ "$output" = "$TEST_TMPDIR/.aurtomator.conf is tracked by git, so a commit can set its values. Check them, then take the file out of the repository: git rm --cached .aurtomator.conf" ]
}

# A .aurtomator.conf that a pull request adds runs nothing
@test "lib.sh: load_config refuses any other line and runs nothing" {
  local pwned="$TEST_TMPDIR/pwned" line
  local -a bad=(
    "GIT_AUTHOR_NAME=\$(touch $pwned)"
    "touch $pwned"
    "MAINTAINER='x'"
    "GIT_AUTHOR_NAME='a'; touch $pwned"
    "GIT_AUTHOR_NAME=\"a\"; touch $pwned"
    "GIT_AUTHOR_NAME='a''b'"
    "GIT_AUTHOR_NAME=\"\$(touch $pwned)\""
    "GIT_AUTHOR_NAME=\"\`touch $pwned\`\""
    "GIT_AUTHOR_NAME=\"a\\\"b\""
    "GIT_AUTHOR_NAME=\"a\\\\b\""
    "GIT_AUTHOR_NAME=x'a'"
    "GIT_AUTHOR_NAME=\$'a\\nb'"
    "GIT_AUTHOR_NAME=a"
    "export GIT_AUTHOR_NAME='a'"
    " GIT_AUTHOR_NAME='a'"
  )
  for line in "${bad[@]}"; do
    printf '%s\n' "GPG_KEY_ID='KEY1'" "$line" >"$TEST_TMPDIR/.aurtomator.conf"
    run load_config_values
    echo "$line: $output"
    [ "$status" -eq 1 ]
    [ "$output" = "$TEST_TMPDIR/.aurtomator.conf: line 2 is not NAME='value' for GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GPG_KEY_ID or AUR_SSH_KEY" ]
  done
  [ ! -e "$pwned" ]
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
  [ ! -f "$TEST_TMPDIR/.status/stale-pkg" ]
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
  [ "$(failed_statuses "$TEST_TMPDIR/.status")" = "2" ]
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
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
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
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
  printf '%s\n' '# test' '<!-- BADGES:START -->' '<!-- BADGES:END -->' '<!-- PACKAGES:START -->' \
    'old table' '## License' >"$TEST_TMPDIR/README.md"
  cp "$TEST_TMPDIR/README.md" "$TEST_TMPDIR/README.orig"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No <!-- PACKAGES:END --> marker found in README.md"* ]]
  cmp "$TEST_TMPDIR/README.orig" "$TEST_TMPDIR/README.md"
}

# The README of aurtomator has no package table, and aurtomator has no packages
@test "update-readme: a README without the table markers and without packages stays as it is" {
  printf '%s\n' '# test' 'Some text.' '## License' >"$TEST_TMPDIR/README.md"
  cp "$TEST_TMPDIR/README.md" "$TEST_TMPDIR/README.orig"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"packages/ holds no package, README.md stays as it is"* ]]
  cmp "$TEST_TMPDIR/README.orig" "$TEST_TMPDIR/README.md"
}

@test "update-readme: fails and keeps a README without the table markers while there are packages" {
  printf '%s\n' '# test' 'Some text.' '## License' >"$TEST_TMPDIR/README.md"
  cp "$TEST_TMPDIR/README.md" "$TEST_TMPDIR/README.orig"
  git -C "$TEST_TMPDIR" init -q
  create_test_package "mypkg" "github-release" $'upstream:\n  project: owner/repo'
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No <!-- PACKAGES:START --> marker found in README.md"* ]]
  cmp "$TEST_TMPDIR/README.orig" "$TEST_TMPDIR/README.md"
}

# A repository made from the template keeps its setup steps until its first
# package, whatever runs before it
@test "update-readme: a README with both blocks stays as it is while there are no packages" {
  printf '%s\n' '# test' '<!-- BADGES:START -->' 'setup steps' '<!-- BADGES:END -->' '## Packages' \
    '<!-- PACKAGES:START -->' 'table text' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  cp "$TEST_TMPDIR/README.md" "$TEST_TMPDIR/README.orig"
  touch "$TEST_TMPDIR/packages/.gitkeep"
  echo "0.9.0" >"$TEST_TMPDIR/VERSION"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"packages/ holds no package, README.md stays as it is"* ]]
  cmp "$TEST_TMPDIR/README.orig" "$TEST_TMPDIR/README.md"
}

@test "update-readme: a directory named like a package YAML is no package" {
  printf '%s\n' '<!-- PACKAGES:START -->' 'table text' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  cp "$TEST_TMPDIR/README.md" "$TEST_TMPDIR/README.orig"
  mkdir "$TEST_TMPDIR/packages/sub.yml"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  cmp "$TEST_TMPDIR/README.orig" "$TEST_TMPDIR/README.md"
}

@test "update-readme: fails and keeps the README without the end marker of the badges" {
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
  printf '%s\n' '# test' '<!-- BADGES:START -->' 'old badges' '## Intro' \
    '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  cp "$TEST_TMPDIR/README.md" "$TEST_TMPDIR/README.orig"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No <!-- BADGES:END --> marker found in README.md"* ]]
  cmp "$TEST_TMPDIR/README.orig" "$TEST_TMPDIR/README.md"
}

# A section is written up to its start marker and from its end marker, so a
# swapped or second marker would copy the README into itself on every run
@test "update-readme: fails and keeps the README with the table markers swapped" {
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
  printf '%s\n' '# test' '<!-- PACKAGES:END -->' 'text' '<!-- PACKAGES:START -->' 'old table' >"$TEST_TMPDIR/README.md"
  cp "$TEST_TMPDIR/README.md" "$TEST_TMPDIR/README.orig"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"README.md has <!-- PACKAGES:END --> above <!-- PACKAGES:START -->"* ]]
  cmp "$TEST_TMPDIR/README.orig" "$TEST_TMPDIR/README.md"
}

@test "update-readme: fails and keeps the README with a second start marker" {
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
  printf '%s\n' '# test' '<!-- PACKAGES:START -->' 'text' '<!-- PACKAGES:START -->' 'old table' \
    '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  cp "$TEST_TMPDIR/README.md" "$TEST_TMPDIR/README.orig"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"README.md has the <!-- PACKAGES:START --> line 2 times, it needs it once"* ]]
  cmp "$TEST_TMPDIR/README.orig" "$TEST_TMPDIR/README.md"
}

@test "update-readme: fails and keeps the README with the badge markers swapped" {
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
  printf '%s\n' '# test' '<!-- BADGES:END -->' '<!-- BADGES:START -->' '<!-- PACKAGES:START -->' \
    '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  cp "$TEST_TMPDIR/README.md" "$TEST_TMPDIR/README.orig"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"README.md has <!-- BADGES:END --> above <!-- BADGES:START -->"* ]]
  cmp "$TEST_TMPDIR/README.orig" "$TEST_TMPDIR/README.md"
}

@test "update-readme: leaves a line that quotes the markers in its text" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  local prose='Keep <!-- BADGES:START -->, <!-- BADGES:END -->, <!-- PACKAGES:START --> and <!-- PACKAGES:END --> on lines of their own.'
  printf '%s\n' '# test' "$prose" '<!-- BADGES:START -->' 'old badges' '<!-- BADGES:END -->' \
    '<!-- PACKAGES:START -->' 'old table' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p "$TEST_TMPDIR/README.md")" = "$prose" ]
  [ "$(grep -cxF '<!-- BADGES:START -->' "$TEST_TMPDIR/README.md")" -eq 1 ]
  [ "$(grep -cxF '<!-- PACKAGES:START -->' "$TEST_TMPDIR/README.md")" -eq 1 ]
  run grep -c -e 'old badges' -e 'old table' "$TEST_TMPDIR/README.md"
  [ "$output" = "0" ]
}

@test "update-readme: writes the table when its start marker is the first line" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  printf '%s\n' '<!-- PACKAGES:START -->' 'old table' '<!-- PACKAGES:END -->' '# test' >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -cxF '<!-- PACKAGES:START -->' "$TEST_TMPDIR/README.md")" -eq 1 ]
  ! grep -q 'old table' "$TEST_TMPDIR/README.md"
}

# sed takes 1,/re/ from line 2 for the end of the range
@test "update-readme: writes the badges when their start marker is the first line" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  printf '%s\n' '<!-- BADGES:START -->' 'old badges' '<!-- BADGES:END -->' '# test' '<!-- PACKAGES:START -->' \
    '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -cxF '<!-- BADGES:START -->' "$TEST_TMPDIR/README.md")" -eq 1 ]
  ! grep -q 'old badges' "$TEST_TMPDIR/README.md"
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

# The workflow badges go only into the badge block, so a README without its
# markers, as the one of aurtomator, shows no workflow badge
@test "update-readme: a README without the badge markers gets no workflow badge" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"

  cat >"$TEST_TMPDIR/README.md" <<'EOF'
<!-- PACKAGES:START -->
<!-- PACKAGES:END -->
EOF
  git -C "$TEST_TMPDIR" init -q
  git -C "$TEST_TMPDIR" remote add origin "https://github.com/myuser/myrepo.git"
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  run grep -c "actions/workflows" "$TEST_TMPDIR/README.md"
  [ "$output" = "0" ]
}

@test "update-readme: the package block starts with the statistics card" {
  git -C "$TEST_TMPDIR" init -q
  git -C "$TEST_TMPDIR" remote add origin "https://github.com/owner/data.git"
  printf '%s\n' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  local block

  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  echo "check_failed: error" >"$TEST_TMPDIR/.status/pkg-a"
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  mapfile -t block < <(sed -n '/^<!-- PACKAGES:START -->$/,/^<!-- PACKAGES:END -->$/p' "$TEST_TMPDIR/README.md")
  [ "${block[1]}" = '<a href="stats/events.csv">' ]
  [ "${block[2]}" = '<picture>' ]
  [ "${block[3]}" = '  <source media="(prefers-color-scheme: dark)" srcset="stats/card-dark.svg">' ]
  [ "${block[4]}" = '  <img width="100%" alt="Packages updated, pushes to AUR, new packages and failed checks over 7, 30 and 365 days" src="stats/card.svg">' ]
  [ "${block[5]}" = '</picture>' ]
  [ "${block[6]}" = '</a>' ]
  [ "${block[7]}" = '' ]
  [ "${block[8]}" = '<table>' ]
  run ! grep -q 'img.shields.io/badge/packages' "$TEST_TMPDIR/README.md"
}

# Helper: a README with both marker pairs and a line between them
readme_with_badges() {
  printf '%s\n' '# test' '<!-- BADGES:START -->' 'old badges' '<!-- BADGES:END -->' \
    'text between' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
}

@test "update-readme: without a GitHub origin only the badge of aurtomator remains" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  readme_with_badges
  git -C "$TEST_TMPDIR" init -q

  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Badges updated (repo: unknown)"* ]]
  [ "$(sed -n '3p' "$TEST_TMPDIR/README.md")" = '[![maintained with aurtomator](https://img.shields.io/badge/maintained%20with-aurtomator-1793d1?logo=archlinux&logoColor=white)](https://github.com/staticwire/aurtomator)' ]
}

@test "update-readme: an origin outside GitHub, or a local path, gives only the badge of aurtomator" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  git -C "$TEST_TMPDIR" init -q
  git -C "$TEST_TMPDIR" remote add origin "https://gitlab.com/someone/fork.git"
  local origin
  for origin in "https://gitlab.com/someone/fork.git" "https://notgithub.com/someone/fork.git" "$TEST_TMPDIR/clone"; do
    git -C "$TEST_TMPDIR" remote set-url origin "$origin"
    readme_with_badges
    run "$TEST_TMPDIR/scripts/update-readme.sh"
    echo "$origin: $output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Badges updated (repo: unknown)"* ]]
    run grep -cF -e 'someone/fork' -e "$TEST_TMPDIR" "$TEST_TMPDIR/README.md"
    [ "$output" = "0" ]
    [ "$(sed -n '3p' "$TEST_TMPDIR/README.md")" = '[![maintained with aurtomator](https://img.shields.io/badge/maintained%20with-aurtomator-1793d1?logo=archlinux&logoColor=white)](https://github.com/staticwire/aurtomator)' ]
  done
}

# In CI the data directory is a copy of builder, without .git
@test "update-readme: the badges name GITHUB_REPOSITORY before the origin" {
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
  git -C "$TEST_TMPDIR" init -q
  git -C "$TEST_TMPDIR" remote add origin "https://github.com/owner/data.git"
  readme_with_badges
  GITHUB_REPOSITORY=owner/ci run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Badges updated (repo: owner/ci)"* ]]
  [ "$(sed -n '3p' "$TEST_TMPDIR/README.md")" = '[![Validate packages](https://github.com/owner/ci/actions/workflows/validate.yml/badge.svg)](https://github.com/owner/ci/actions/workflows/validate.yml) [![Check AUR Package Updates](https://github.com/owner/ci/actions/workflows/check-updates.yml/badge.svg)](https://github.com/owner/ci/actions/workflows/check-updates.yml) [![maintained with aurtomator](https://img.shields.io/badge/maintained%20with-aurtomator-1793d1?logo=archlinux&logoColor=white)](https://github.com/staticwire/aurtomator)' ]
}

@test "update-readme: a GITHUB_REPOSITORY that is not owner/repo leaves the origin" {
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
  git -C "$TEST_TMPDIR" init -q
  git -C "$TEST_TMPDIR" remote add origin "https://github.com/owner/data.git"
  local repo
  for repo in "" owner a/b/c "owner/repo x" ../x .owner/repo owner_x/repo 'owner/re$po'; do
    readme_with_badges
    GITHUB_REPOSITORY="$repo" run "$TEST_TMPDIR/scripts/update-readme.sh"
    echo "$repo: $output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Badges updated (repo: owner/data)"* ]]
  done
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
  grep -qF '<td>1.0.0</td><td nowrap>github-release</td><td nowrap>-</td><td nowrap>✅ tracking</td>' "$TEST_TMPDIR/README.md"
}

@test "update-readme: a package without current is new" {
  create_test_package "pkg-new" "github-release" "upstream:
  project: owner/repo"
  printf '%s\n' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q

  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF '<tr><td><a href="https://aur.archlinux.org/pkgbase/pkg-new">pkg-new</a></td><td>-</td><td nowrap>github-release</td><td nowrap>-</td><td nowrap>✨ new</td></tr>' "$TEST_TMPDIR/README.md"
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
  grep -qF '<td nowrap>github-release</td><td nowrap>-</td>' "$TEST_TMPDIR/README.md"
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

  # namcap warnings do not stop the update
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

  # Without an origin remote, checkout -B master origin/master fails and set -e ends the script
  # before the pkgver bump
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
  [[ "$output" == *"Detached HEAD after clone"* ]]
  [[ "$output" == *"Re-basing on origin/master"* ]]
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

# No later step downloads a source with a SKIP checksum, so without the HEAD request a URL that
# answers 404 would reach the AUR
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
  [ "$(failed_statuses "$TEST_TMPDIR/.status")" = "0" ]
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

@test "update-readme: renders downgrade icon" {
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
}

@test "update-readme: renders a skipped downgrade" {
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
}

# === version jumps ===

# Helper: a strategy that prints the given version, in place of the link to
# the strategy of that name in the project
# Usage: stand_in_strategy <name> <version>
stand_in_strategy() {
  rm -f "$TEST_TMPDIR/strategies/$1.sh"
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
  [ "$(failed_statuses "$TEST_TMPDIR/.status")" = "0" ]
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

@test "update-readme: renders a skipped version jump" {
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
  [ "$(failed_statuses "$TEST_TMPDIR/.status")" = "0" ]
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
  [ "$(failed_statuses "$TEST_TMPDIR/.status")" = "0" ]
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
  [ "$(failed_statuses "$TEST_TMPDIR/.status")" = "1" ]
}

@test "check-all: fails the check of a package with an alert note of several lines" {
  stand_in_strategy step 29+1
  create_test_package "pkg-note" "step" "current: 28+25
alerts:
  - when: major
    note: |
      Rename the binary
      hold"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [[ "$(cat "$TEST_TMPDIR/.status/pkg-note")" == "check_failed: "*"alerts[0].note must be one line of text" ]]
  [ ! -e "$TEST_TMPDIR/.status/_alerts" ]
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

@test "update-readme: renders a held update" {
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
  # current 1.0.0 below latest 2.0.0: the normal update, the is_downgrade=false branch
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

# Helper: liquidsoap-bin on the mock of savonet/liquidsoap, with the given asset_regex
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

@test "check-asset: takes the answer limit of the package" {
  liquidsoap_package
  yq -i '.upstream.max_answer_mb = 70' "$TEST_TMPDIR/packages/liq.yml"
  record_curl
  run --separate-stderr "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc1
  [ "$status" -eq 0 ]
  [ "$output" = "2.5.0-debian-forky-ocaml5.5.1-1" ]
  [ "$(curl_max_filesizes | sort -u)" = "70M" ]
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

# git takes any committer date, and a date far ahead would keep the wait
# going in every run
@test "check-asset: fails for a tag whose commit is dated more than a day ahead" {
  local ahead
  liquidsoap_package
  ahead=$(date -u -d "+25 hours" +%Y-%m-%dT%H:%M:%SZ)
  MOCK_TAG_DATE="$ahead" run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc2
  [ "$status" -eq 1 ]
  [[ "$output" == *"liq 2.5.0rc2: tag v2.5.0-rc2 has no release, and its date $ahead is more than 24 h ahead of now"* ]]
  MOCK_TAG_DATE=$(date -u -d "+23 hours" +%Y-%m-%dT%H:%M:%SZ) run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc2
  [ "$status" -eq 3 ]
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
  [[ "$output" == *"Tags v1.0.0 1.0.0 of asset-owner/twin-repo all give version 1.0.0; set upstream.tag_version_regex to match one of them"* ]]
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

# === check-arch.sh ===

# Helper: jdk-temurin-ea-bin at 28+22 on the AUR, its YAML with the given
# lines, and the curl of mock_heads
temurin_package() {
  create_test_package jdk-temurin-ea-bin webpage-scrape "upstream:
  url: https://api.adoptium.net/v3/info/release_names
  pattern: 'jdk-([0-9]+)'
$1"
  arch_pkgbuild "$TEST_TMPDIR/PKGBUILD"
  arch_srcinfo "$TEST_TMPDIR/.SRCINFO"
  make_aur_remote jdk-temurin-ea-bin "$TEST_TMPDIR/PKGBUILD" "$TEST_TMPDIR/.SRCINFO"
  mock_heads
}

# Helper: run check-arch.sh for jdk-temurin-ea-bin; sets ARCH_RC, and
# ARCH_OUT to its stdout with a | at the end of each line
check_arch() {
  ARCH_RC=0
  "$TEST_TMPDIR/scripts/check-arch.sh" jdk-temurin-ea-bin "$@" >"$TEST_TMPDIR/arch.out" 2>"$TEST_TMPDIR/arch.err" || ARCH_RC=$?
  ARCH_OUT=$(sed 's/$/|/' "$TEST_TMPDIR/arch.out")
}

# Helper: succeeds when time $1 lies at most 120 s from now
about_now() {
  local at
  at=$(date -u -d "$1" +%s) || return 1
  ((${at} - $(date -u +%s) < 120 && $(date -u +%s) - ${at} < 120))
}

@test "check-arch: prints two empty lines when every arch answers" {
  temurin_package "current: 28+22"
  check_arch 28+23
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'|\n|' ]
  grep -qx 'https://aur.archlinux.org/jdk-temurin-ea-bin.git' "$TEST_TMPDIR/clone-urls"
  [ "$(sort "$TEST_TMPDIR/heads.log")" = "$(for arch in "${ARCH_ALL[@]}"; do arch_source_url "$arch" 28+23; done | sort)" ]
}

@test "check-arch: asks nothing with allow_missing_arch: false or pkgver_dash: ''" {
  local line
  for line in "allow_missing_arch: false" "pkgver_dash: ''"; do
    temurin_package "current: 28+22
$line"
    archive_missing aarch64 28+23
    check_arch 28+23
    [ "$ARCH_RC" -eq 0 ]
    [ "$ARCH_OUT" = $'|\n|' ]
    [ ! -e "$TEST_TMPDIR/clone-urls" ] && [ ! -e "$TEST_TMPDIR/heads.log" ] || {
      echo "asked with $line"
      return 1
    }
    rm -rf "$TEST_TMPDIR/aur-remote" "$TEST_TMPDIR/aur-work-jdk-temurin-ea-bin" "$TEST_TMPDIR/missing"
  done
}

@test "check-arch: a missing arch waits 24 h from the run that first saw it" {
  temurin_package "current: 28+22"
  archive_missing aarch64 28+23
  check_arch 28+23
  [ "$ARCH_RC" -eq 3 ]
  [ "$(wc -l <"$TEST_TMPDIR/arch.out")" -eq 1 ]
  about_now "$(<"$TEST_TMPDIR/arch.out")"
  grep -q "aarch64" "$TEST_TMPDIR/arch.err"
}

@test "check-arch: the wait counts from arch_wait of the version" {
  local since
  since=$(date -u -d '-23 hours' +%Y-%m-%dT%H:%M:%SZ)
  temurin_package "current: 28+22
arch_wait:
  version: 28+23
  since: '$since'"
  archive_missing aarch64 28+23
  check_arch 28+23
  [ "$ARCH_RC" -eq 3 ]
  [ "$ARCH_OUT" = "$since|" ]

  since=$(date -u -d '-25 hours' +%Y-%m-%dT%H:%M:%SZ)
  yq -i ".arch_wait.since = \"$since\"" "$TEST_TMPDIR/packages/jdk-temurin-ea-bin.yml"
  check_arch 28+23
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = "aarch64|"$'\n'"$since|" ]
}

@test "check-arch: a start of arch_wait after now starts a new wait" {
  temurin_package "current: 28+22
arch_wait:
  version: 28+23
  since: '2099-01-01T00:00:00Z'"
  archive_missing aarch64 28+23
  check_arch 28+23
  [ "$ARCH_RC" -eq 3 ]
  about_now "$(<"$TEST_TMPDIR/arch.out")"
}

@test "check-arch: arch_wait of another version starts a new wait" {
  temurin_package "current: 28+22
arch_wait:
  version: 28+21
  since: '$(date -u -d '-25 hours' +%Y-%m-%dT%H:%M:%SZ)'"
  archive_missing aarch64 28+23
  check_arch 28+23
  [ "$ARCH_RC" -eq 3 ]
  about_now "$(<"$TEST_TMPDIR/arch.out")"
}

@test "check-arch: a missing x86_64 or every arch missing fails the update as today" {
  temurin_package "current: 28+22"
  archive_missing x86_64 28+23
  archive_missing aarch64 28+23
  check_arch 28+23
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'|\n|' ]

  aur_arch_commit 28+22 aarch64 riscv64 >/dev/null
  archive_missing riscv64 28+23
  check_arch 28+23
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'|\n|' ]
}

@test "check-arch: an arch that is out comes back when its archive answers" {
  local out
  temurin_package "current: 28+23"
  out=$AUR_BASE
  aur_arch_commit 28+23 x86_64 powerpc64le riscv64 >/dev/null
  yq -i ".arch_out.aarch64 = \"$out\"" "$TEST_TMPDIR/packages/jdk-temurin-ea-bin.yml"

  check_arch 28+24
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'|\n|' ]
  grep -qx "$(arch_source_url aarch64 28+24)" "$TEST_TMPDIR/heads.log"

  archive_missing aarch64 28+24
  check_arch 28+24
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'aarch64|\n|' ]

  rm "$TEST_TMPDIR/heads.log"
  check_arch 28+23
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'|\n|' ]
  [ "$(cat "$TEST_TMPDIR/heads.log")" = "$(arch_source_url aarch64 28+23)" ]

  archive_missing aarch64 28+23
  check_arch 28+23
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'aarch64|\n|' ]
}

@test "check-arch: an arch the maintainer put back is no longer out" {
  temurin_package "current: 28+22"
  yq -i ".arch_out.aarch64 = \"$AUR_BASE\"" "$TEST_TMPDIR/packages/jdk-temurin-ea-bin.yml"
  archive_missing aarch64 28+22
  check_arch 28+22
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'|\n|' ]
  [ ! -e "$TEST_TMPDIR/heads.log" ]
}

@test "check-arch: a commit of arch_out missing from the AUR fails the check" {
  temurin_package "current: 28+22
arch_out:
  aarch64: '0123456789012345678901234567890123456789'"
  check_arch 28+23
  [ "$ARCH_RC" -eq 1 ]
  grep -q "the commit 0123456789012345678901234567890123456789 of arch_out.aarch64 is not in the AUR repo" "$TEST_TMPDIR/arch.err"

  local head
  head=$(aur_arch_commit 28+23 x86_64 powerpc64le riscv64)
  yq -i ".arch_out.aarch64 = \"$head\"" "$TEST_TMPDIR/packages/jdk-temurin-ea-bin.yml"
  check_arch 28+24
  [ "$ARCH_RC" -eq 1 ]
  grep -q "the commit $head of arch_out.aarch64 does not build aarch64" "$TEST_TMPDIR/arch.err"
}

@test "check-arch: after 24 h line 1 names the arches that leave and those that stay out" {
  temurin_package "current: 28+23
arch_wait:
  version: 28+24
  since: '$(date -u -d '-25 hours' +%Y-%m-%dT%H:%M:%SZ)'"
  yq -i ".arch_out.aarch64 = \"$AUR_BASE\"" "$TEST_TMPDIR/packages/jdk-temurin-ea-bin.yml"
  aur_arch_commit 28+23 x86_64 powerpc64le riscv64 >/dev/null
  archive_missing aarch64 28+24
  archive_missing riscv64 28+24
  check_arch 28+24
  [ "$ARCH_RC" -eq 0 ]
  [ "$(head -1 "$TEST_TMPDIR/arch.out")" = "riscv64 aarch64" ]
}

@test "check-arch: a URL without an answer fails the check" {
  temurin_package "current: 28+22"
  arch_source_url aarch64 28+23 >"$TEST_TMPDIR/silent"
  check_arch 28+23
  [ "$ARCH_RC" -eq 1 ]
  grep -qF "no answer from $(arch_source_url aarch64 28+23)" "$TEST_TMPDIR/arch.err"
}

@test "check-arch: without the AUR the arches out stay out" {
  temurin_package "current: 28+22"
  yq -i ".arch_out.aarch64 = \"$AUR_BASE\"" "$TEST_TMPDIR/packages/jdk-temurin-ea-bin.yml"
  mv "$AUR_REMOTE" "$AUR_REMOTE.gone"
  check_arch 28+23
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'aarch64|\n|' ]
  [ ! -e "$TEST_TMPDIR/heads.log" ]
}

@test "check-arch: with aur.archlinux.org silent the arches out stay out" {
  temurin_package "current: 28+22"
  yq -i ".arch_out.aarch64 = \"$AUR_BASE\"" "$TEST_TMPDIR/packages/jdk-temurin-ea-bin.yml"
  keep_host_memory aur.archlinux.org
  check_arch 28+23
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'aarch64|\n|' ]
  [ ! -e "$TEST_TMPDIR/clone-urls" ]
  grep -qF "https://aur.archlinux.org/jdk-temurin-ea-bin.git: aur.archlinux.org did not answer earlier in this run" "$TEST_TMPDIR/arch.err"
}

@test "check-arch: an arch line it cannot edit leaves the update as it is" {
  local work="$TEST_TMPDIR/aur-work-jdk-temurin-ea-bin"
  temurin_package "current: 28+22"
  sed -i "s/^arch=('x86_64' /arch=('x86_64'\n  /" "$work/PKGBUILD"
  git -C "$work" -c user.name=aur -c user.email=aur@example.invalid -c commit.gpgsign=false commit -qam "two lines"
  git -C "$work" push -q "$AUR_REMOTE" master
  archive_missing aarch64 28+23
  check_arch 28+23
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'|\n|' ]
  [ ! -e "$TEST_TMPDIR/heads.log" ]
}

@test "check-arch: builds the URLs with the asset values of the PKGBUILD and of --asset" {
  create_test_package arch-demo github-release "upstream:
  project: owner/repo
  asset_regex: '^demo-[0-9.]+-([0-9]+)-x86_64\\.tar\\.gz\$'
  asset_var: _build
current: 1.0.0
current_asset: '7'"
  # shellcheck disable=SC2016
  printf '%s\n' 'pkgname=arch-demo' 'pkgver=1.0.0' 'pkgrel=1' '_build=7' "arch=('x86_64' 'aarch64')" \
    'source_x86_64=("https://example.com/demo-${pkgver}-${_build}-x86_64.tar.gz")' \
    'source_aarch64=("https://example.com/demo-${pkgver}-${_build}-aarch64.tar.gz")' >"$TEST_TMPDIR/PKGBUILD"
  printf '%s\n' 'pkgbase = arch-demo' $'\tpkgver = 1.0.0' $'\tpkgrel = 1' $'\tarch = x86_64' $'\tarch = aarch64' \
    $'\tsource_x86_64 = https://example.com/demo-1.0.0-7-x86_64.tar.gz' \
    $'\tsource_aarch64 = https://example.com/demo-1.0.0-7-aarch64.tar.gz' '' 'pkgname = arch-demo' >"$TEST_TMPDIR/.SRCINFO"
  make_aur_remote arch-demo "$TEST_TMPDIR/PKGBUILD" "$TEST_TMPDIR/.SRCINFO"
  mock_heads
  run --separate-stderr "$TEST_TMPDIR/scripts/check-arch.sh" arch-demo 1.1.0 --asset 8
  [ "$status" -eq 0 ]
  [ "$(sort "$TEST_TMPDIR/heads.log")" = $'https://example.com/demo-1.1.0-8-aarch64.tar.gz\nhttps://example.com/demo-1.1.0-8-x86_64.tar.gz' ]

  # A new asset value of the version the AUR has is a rebuild of every arch
  rm "$TEST_TMPDIR/heads.log"
  run --separate-stderr "$TEST_TMPDIR/scripts/check-arch.sh" arch-demo 1.0.0 --asset 8
  [ "$status" -eq 0 ]
  [ "$(sort "$TEST_TMPDIR/heads.log")" = $'https://example.com/demo-1.0.0-8-aarch64.tar.gz\nhttps://example.com/demo-1.0.0-8-x86_64.tar.gz' ]
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

# Helper: pkg on the stand-in strategy step with asset_regex, at <current> and <current_asset>
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
  [ "$(failed_statuses "$TEST_TMPDIR/.status")" = "0" ]
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

@test "check-all: an asset lookup that failed on a silent host gets no second pass" {
  stand_in_strategy step 2.0.0
  asset_package 1.0.0 1.0.0-a
  rm -f "$TEST_TMPDIR/scripts/check-asset.sh"
  cat >"$TEST_TMPDIR/scripts/check-asset.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$TEST_TMPDIR/check-asset.args"
echo silent.example >>"$AURTOMATOR_HOSTS_DIR/silent"
echo "https://silent.example/x: Operation timed out after 30000 milliseconds with 0 bytes received" >&2
exit 1
STUB
  chmod +x "$TEST_TMPDIR/scripts/check-asset.sh"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/check-asset.args")" = "pkg 2.0.0" ]
}

@test "check-all: an asset lookup killed during a request names its URL" {
  stand_in_strategy step 2.0.0
  asset_package 1.0.0 1.0.0-a
  rm -f "$TEST_TMPDIR/scripts/check-asset.sh"
  cat >"$TEST_TMPDIR/scripts/check-asset.sh" <<'STUB'
#!/usr/bin/env bash
source "$TEST_TMPDIR/scripts/lib.sh"
request_begin https://slow.example/x && exec sleep 60
STUB
  chmod +x "$TEST_TMPDIR/scripts/check-asset.sh"
  AURTOMATOR_CHECK_TIMEOUT=1 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "check_failed: https://slow.example/x: timed out after 1 s" ]
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

@test "update-readme: renders a rebuild and a pending asset" {
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
}

# === check-all.sh: arches out ===

# Helper: a check-arch.sh that logs its arguments to check-arch.args, prints <stdout> and exits
# with [exit code], 0 by default; exit 1 comes with a reason on stderr
stand_in_arch() {
  rm -f "$TEST_TMPDIR/scripts/check-arch.sh"
  printf '#!/usr/bin/env bash\necho "$*" >>%q\nprintf %%s %q\n[[ %s != 1 ]] || echo "AUR unreadable" >&2\nexit %s\n' \
    "$TEST_TMPDIR/check-arch.args" "$1" "${2:-0}" "${2:-0}" >"$TEST_TMPDIR/scripts/check-arch.sh"
  chmod +x "$TEST_TMPDIR/scripts/check-arch.sh"
}

@test "check-all: writes pending and the start of the wait while an arch is missing" {
  stand_in_strategy step 2.0.0
  create_test_package "pkg" "step" "current: '1.0.0'"
  stand_in_arch $'2026-11-11T10:00:00Z\n' 3
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "pending: 2.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/_arches")" = $'pkg\t2.0.0\t\t2026-11-11T10:00:00Z' ]
  [ "$(cat "$TEST_TMPDIR/check-arch.args")" = "pkg 2.0.0" ]
  [ "$(failed_statuses "$TEST_TMPDIR/.status")" = "0" ]
}

@test "check-all: records the arches that stay out of a new version" {
  stand_in_strategy step 2.0.0
  create_test_package "pkg" "step" "current: '1.0.0'"
  stand_in_arch $'aarch64 riscv64\n2026-11-10T09:00:00Z\n'
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "new_version: 2.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/_arches")" = $'pkg\t2.0.0\taarch64 riscv64\t2026-11-10T09:00:00Z' ]
}

@test "check-all: records nothing for a version that every arch has" {
  stand_in_strategy step 2.0.0
  create_test_package "pkg" "step" "current: '1.0.0'"
  stand_in_arch $'\n\n'
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "new_version: 2.0.0" ]
  [ ! -e "$TEST_TMPDIR/.status/_arches" ]
}

@test "check-all: fails an arch check that prints something else" {
  local text
  for text in $'aarch64!\n\n' $'aarch64\nsoon\n' $'\n\nextra\n'; do
    stand_in_strategy step 2.0.0
    create_test_package "pkg" "step" "current: '1.0.0'"
    stand_in_arch "$text"
    run "$TEST_TMPDIR/scripts/check-all.sh"
    [ "$status" -eq 0 ]
    [[ "$(cat "$TEST_TMPDIR/.status/pkg")" == "check_failed: check-arch.sh printed "* ]] || {
      echo "taken: ${text@Q}"
      return 1
    }
  done
  stand_in_arch $'soon\n' 3
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "check_failed: check-arch.sh printed 'soon'" ]
  [ ! -e "$TEST_TMPDIR/.status/_arches" ]
}

@test "check-all: passes the asset value of a new version to check-arch" {
  stand_in_strategy step 2.0.0
  asset_package 1.0.0 1.0.0-a
  stand_in_asset 2.0.0-a
  stand_in_arch $'\n\n'
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/check-arch.args")" = "pkg 2.0.0 --asset 2.0.0-a" ]
}

@test "check-all: an arch out whose archive answers comes back at the current version, in a cooldown too" {
  stand_in_strategy step 1.0.0
  create_test_package "pkg" "step" "current: '1.0.0'
last_updated: '$(date -u +%F)'
cooldown_days: 7
arch_out:
  aarch64: '$(printf 'a%.0s' {1..40})'
  riscv64: '$(printf 'b%.0s' {1..40})'"
  stand_in_arch $'riscv64\n\n'
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "arch_back: 1.0.0 aarch64" ]
  [ "$(cat "$TEST_TMPDIR/.status/_arches")" = $'pkg\t1.0.0\triscv64\t' ]
  [ "$(cat "$TEST_TMPDIR/check-arch.args")" = "pkg 1.0.0" ]

  stand_in_arch $'aarch64 riscv64\n\n'
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "up_to_date" ]
  [ "$(cat "$TEST_TMPDIR/.status/_arches")" = $'pkg\t1.0.0\taarch64 riscv64\t' ]

  # Every arch comes back: the line without arches tells prepare so
  stand_in_arch $'\n\n'
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "arch_back: 1.0.0 aarch64 riscv64" ]
  [ "$(cat "$TEST_TMPDIR/.status/_arches")" = $'pkg\t1.0.0\t\t' ]
}

@test "check-all: asks no arch check in the cooldown of a new version" {
  stand_in_strategy step 2.0.0
  create_test_package "pkg" "step" "current: '1.0.0'
last_updated: '$(date -u +%F)'
cooldown_days: 7"
  stand_in_arch $'aarch64\n2026-11-10T09:00:00Z\n'
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_TMPDIR/.status/pkg")" == "cooldown: "* ]]
  [ ! -e "$TEST_TMPDIR/check-arch.args" ]
}

@test "check-all: fails the check when check-arch fails, and checks again" {
  stand_in_strategy step 2.0.0
  create_test_package "pkg" "step" "current: '1.0.0'"
  stand_in_arch "" 1
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "check_failed: AUR unreadable" ]
  [ "$(cat "$TEST_TMPDIR/check-arch.args")" = $'pkg 2.0.0\npkg 2.0.0' ]
}

@test "check-all: an arch check that failed on a silent host gets no second pass" {
  stand_in_strategy step 2.0.0
  create_test_package "pkg" "step" "current: '1.0.0'"
  rm -f "$TEST_TMPDIR/scripts/check-arch.sh"
  cat >"$TEST_TMPDIR/scripts/check-arch.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$TEST_TMPDIR/check-arch.args"
echo silent.example >>"$AURTOMATOR_HOSTS_DIR/silent"
echo "https://silent.example/x: silent.example did not answer earlier in this run" >&2
exit 1
STUB
  chmod +x "$TEST_TMPDIR/scripts/check-arch.sh"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/check-arch.args")" = "pkg 2.0.0" ]
}

@test "check-all: an arch check killed during a request names its URL" {
  stand_in_strategy step 2.0.0
  create_test_package "pkg" "step" "current: '1.0.0'"
  rm -f "$TEST_TMPDIR/scripts/check-arch.sh"
  cat >"$TEST_TMPDIR/scripts/check-arch.sh" <<'STUB'
#!/usr/bin/env bash
source "$TEST_TMPDIR/scripts/lib.sh"
git_request_begin https://aur.archlinux.org/pkg.git && exec sleep 60
STUB
  chmod +x "$TEST_TMPDIR/scripts/check-arch.sh"
  AURTOMATOR_CHECK_TIMEOUT=1 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "check_failed: https://aur.archlinux.org/pkg.git: timed out after 1 s" ]
}

@test "check-all: asks no arch check with allow_missing_arch: false or pkgver_dash: ''" {
  local line version
  for line in "allow_missing_arch: false" "pkgver_dash: ''"; do
    for version in 2.0.0 1.0.0; do
      stand_in_strategy step "$version"
      create_test_package "pkg" "step" "current: '1.0.0'
arch_out:
  aarch64: '$(printf 'a%.0s' {1..40})'
$line"
      stand_in_arch $'\n\n'
      run "$TEST_TMPDIR/scripts/check-all.sh"
      [ "$status" -eq 0 ]
      [ ! -e "$TEST_TMPDIR/check-arch.args" ] || {
        echo "asked with $line at $version"
        return 1
      }
      if [[ "$version" == 1.0.0 ]]; then
        [ "$(cat "$TEST_TMPDIR/.status/pkg")" = up_to_date ]
      else
        [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "new_version: 2.0.0" ]
      fi
    done
  done
}

@test "check-all --update: runs no arch check" {
  stand_in_strategy step 2.0.0
  create_test_package "pkg" "step" "current: '1.0.0'"
  stand_in_arch $'aarch64\n2026-11-10T09:00:00Z\n'
  log_update_pkg
  run "$TEST_TMPDIR/scripts/check-all.sh" --update
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/update-pkg.args")" = "pkg 2.0.0" ]
  [ ! -e "$TEST_TMPDIR/check-arch.args" ]
}

# === cooldown ===

# Helper: the UTC date $1 days from today, negative for the past
utc_day() {
  date -u -d "$1 days" +%F
}

@test "lib.sh: valid_date takes a real date YYYY-MM-DD only" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  run valid_date 2026-11-06
  [ "$status" -eq 0 ]
  local bad
  for bad in 2026-02-30 2026-11-6 20261106 2026-11-06T10:00:00Z ' 2026-11-06' 10000-01-01 'next week' ''; do
    run valid_date "$bad"
    [ "$status" -ne 0 ] || {
      echo "taken: $bad"
      return 1
    }
  done
}

@test "lib.sh: cooldown_until gives git-latest 7 days after the last push" {
  create_test_package "pkg-git" "git-latest" "last_updated: '2026-11-05'"
  source "$TEST_TMPDIR/scripts/lib.sh"
  run cooldown_until "$TEST_TMPDIR/packages/pkg-git.yml"
  [ "$status" -eq 0 ]
  [ "$output" = 2026-11-12 ]
}

@test "lib.sh: cooldown_until takes the days of any strategy from cooldown_days" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
last_updated: '2026-11-05'
cooldown_days: 14"
  source "$TEST_TMPDIR/scripts/lib.sh"
  run cooldown_until "$TEST_TMPDIR/packages/pkg.yml"
  [ "$status" -eq 0 ]
  [ "$output" = 2026-11-19 ]
}

@test "lib.sh: cooldown_until prints nothing for another strategy, cooldown_days: 0 or no last_updated" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
last_updated: '2026-11-05'"
  create_test_package "pkg-off" "git-latest" "last_updated: '2026-11-05'
cooldown_days: 0"
  create_test_package "pkg-new" "git-latest" "current: r1.abc1234"
  source "$TEST_TMPDIR/scripts/lib.sh"
  local name
  for name in pkg pkg-off pkg-new; do
    run cooldown_until "$TEST_TMPDIR/packages/$name.yml"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || {
      echo "$name: $output"
      return 1
    }
  done
}

@test "lib.sh: cooldown_until refuses a cooldown_days or a last_updated that is not valid" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  local value
  for value in -1 366 7.5 010 "'7 days'" "'x[\$(touch $TEST_TMPDIR/ran)]'"; do
    create_test_package "pkg-git" "git-latest" "last_updated: '2026-11-05'
cooldown_days: $value"
    run --separate-stderr cooldown_until "$TEST_TMPDIR/packages/pkg-git.yml"
    [ "$status" -eq 1 ]
    [[ "$stderr" == "cooldown_days must be a whole number from 0 to 365: "* ]]
  done
  [ ! -e "$TEST_TMPDIR/ran" ]
  create_test_package "pkg-git" "git-latest" "last_updated: '2026-02-30'"
  run --separate-stderr cooldown_until "$TEST_TMPDIR/packages/pkg-git.yml"
  [ "$status" -eq 1 ]
  [ "$stderr" = "last_updated must be a date YYYY-MM-DD: 2026-02-30" ]
}

@test "check-all: an update of git-latest waits 7 days after the last push" {
  stand_in_strategy git-latest r2391.1f3c2a7
  create_test_package "pkg-git" "git-latest" "current: r2378.06ea49d
last_updated: '$(utc_day -6)'"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-git")" = "cooldown: $(utc_day 1)" ]
  [[ "$output" == *"pkg-git: r2378.06ea49d → r2391.1f3c2a7 waits until $(utc_day 1)"* ]]
  [ "$(failed_statuses "$TEST_TMPDIR/.status")" = "0" ]
}

@test "check-all: an update of git-latest goes out 7 days after the last push" {
  stand_in_strategy git-latest r2391.1f3c2a7
  create_test_package "pkg-git" "git-latest" "current: r2378.06ea49d
last_updated: '$(utc_day -7)'"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-git")" = "new_version: r2391.1f3c2a7" ]
}

@test "check-all: a package in its cooldown without a newer version is up to date" {
  stand_in_strategy git-latest r2378.06ea49d
  create_test_package "pkg-git" "git-latest" "current: r2378.06ea49d
last_updated: '$(utc_day 0)'"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-git")" = "up_to_date" ]
}

@test "check-all: cooldown_days holds the update of another strategy" {
  stand_in_strategy step 1.1
  create_test_package "pkg-slow" "step" "current: '1.0'
last_updated: '$(utc_day -13)'
cooldown_days: 14"
  create_test_package "pkg-fast" "step" "current: '1.0'
last_updated: '$(utc_day 0)'"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-slow")" = "cooldown: $(utc_day 1)" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-fast")" = "new_version: 1.1" ]
}

@test "check-all: cooldown_days: 0 and a missing last_updated let an update of git-latest out" {
  stand_in_strategy git-latest r2391.1f3c2a7
  create_test_package "pkg-off" "git-latest" "current: r2378.06ea49d
last_updated: '$(utc_day 0)'
cooldown_days: 0"
  create_test_package "pkg-new" "git-latest" "current: r2378.06ea49d"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-off")" = "new_version: r2391.1f3c2a7" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-new")" = "new_version: r2391.1f3c2a7" ]
}

@test "check-all: a skipped version jump or downgrade and a hold win over the cooldown" {
  stand_in_strategy jump 2026102100
  create_test_package "pkg-jump" "jump" "current: '13'
last_updated: '$(utc_day 0)'
cooldown_days: 7"
  stand_in_strategy older 1.0
  create_test_package "pkg-down" "older" "current: '2.0'
last_updated: '$(utc_day 0)'
cooldown_days: 7"
  stand_in_strategy step 29+1
  create_test_package "pkg-hold" "step" "current: 28+25
last_updated: '$(utc_day 0)'
cooldown_days: 7
alerts:
  - when: major
    hold: true
    note: Raise makedepends java-environment to 28"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-jump")" = "jump_skipped: 2026102100" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-down")" = "downgrade_skipped: 1.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-hold")" = "held: 29+1" ]
}

@test "check-all: holds a rebuild and an allowed downgrade in the cooldown" {
  stand_in_strategy step 1.0.0
  asset_package 1.0.0 1.0.0-a
  printf "last_updated: '%s'\ncooldown_days: 7\n" "$(utc_day 0)" >>"$TEST_TMPDIR/packages/pkg.yml"
  stand_in_asset 1.0.0-b
  stand_in_strategy older 1.0
  create_test_package "pkg-down" "older" "current: '2.0'
allow_downgrade: true
last_updated: '$(utc_day 0)'
cooldown_days: 7"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "cooldown: $(utc_day 7)" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-down")" = "cooldown: $(utc_day 7)" ]
}

@test "check-all: asks no asset value for an update in its cooldown" {
  stand_in_strategy step 2.0.0
  asset_package 1.0.0 1.0.0-a
  printf "last_updated: '%s'\ncooldown_days: 7\n" "$(utc_day 0)" >>"$TEST_TMPDIR/packages/pkg.yml"
  stand_in_asset 2.0.0-a
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "cooldown: $(utc_day 7)" ]
  [ ! -e "$TEST_TMPDIR/check-asset.args" ]
}

@test "check-all: fails the check of an update with a last_updated that is not a date" {
  stand_in_strategy git-latest r2391.1f3c2a7
  create_test_package "pkg-git" "git-latest" "current: r2378.06ea49d
last_updated: '2026-02-30'"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-git")" = "check_failed: last_updated must be a date YYYY-MM-DD: 2026-02-30" ]
}

@test "update-readme: renders an update in its cooldown" {
  create_test_package "pkg-git" "git-latest" "upstream:
  type: github
  project: owner/repo
current: r2378.06ea49d"
  echo "cooldown: 2026-11-12" >"$TEST_TMPDIR/.status/pkg-git"
  printf '%s\n' "<!-- PACKAGES:START -->" "<!-- PACKAGES:END -->" >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF '<td nowrap>💤 next update 2026-11-12</td>' "$TEST_TMPDIR/README.md"
}
