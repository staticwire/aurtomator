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
  echo "\$2" >>"$TEST_TMPDIR/clone-urls"
  exec /usr/bin/git clone -q "$AUR_REMOTE" "\$3"
fi
exec /usr/bin/git "\$@"
EOF
  chmod +x "$MOCK_DIR/git"
}

# Helper: makepkg that prints a fixed .SRCINFO, namcap that finds nothing
mock_pkg_tools() {
  printf '#!/usr/bin/env bash\necho "pkgbase = demo"\n' >"$MOCK_DIR/makepkg"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$MOCK_DIR/namcap"
  chmod +x "$MOCK_DIR/makepkg" "$MOCK_DIR/namcap"
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
}

@test "publish-pkg: refuses a prepared PKGBUILD that changes other lines" {
  setup_publish
  sed -i 's|https://example.com/demo|https://evil.example/demo|' "$PREPARED/PKGBUILD"
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.1.0 "$PREPARED"
  [ "$status" -eq 1 ]
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
  [ ! -f "$TEST_TMPDIR/clone-urls" ]
}

@test "publish-pkg: defers when the AUR moved since the update was prepared" {
  setup_publish
  printf '0%.0s' {1..40} >"$PREPARED/base"
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.1.0 "$PREPARED"
  [ "$status" -eq 3 ]
  [ "$(git -C "$AUR_REMOTE" rev-parse HEAD)" = "$AUR_BASE" ]
}

@test "publish-pkg: defers when upstream moved since the update was prepared" {
  setup_publish
  run "$TEST_TMPDIR/scripts/publish-pkg.sh" demo 1.2.0 "$PREPARED"
  [ "$status" -eq 3 ]
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

@test "verify-pkg: accepts checksums that match the sources" {
  setup_verify
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 0 ]
  grep -qx 'https://aur.archlinux.org/demo.git' "$TEST_TMPDIR/clone-urls"
  grep -q -- '--proto =http,https,ftp --proto-redir =http,https,ftp .* https://example.com/demo-1.1.0.tar.gz$' "$TEST_TMPDIR/curl.args"
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
  [ ! -e "$TEST_TMPDIR/git-clone-urls" ]
}

@test "verify-pkg: refuses a git tag that git would read as an option" {
  setup_verify
  make_upstream
  use_source "demo::git+https://example.com/demo.git#tag=-vVER"
  run "$TEST_TMPDIR/scripts/verify-pkg.sh" demo "$PREPARED"
  [ "$status" -eq 1 ]
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
current: '1.0.0'"
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

@test "check-all --publish: publishes with the version upstream reports now and keeps the checked statuses" {
  create_test_package "pkg" "github-release" "upstream:
  project: owner/repo
current: '1.0.0'"
  create_test_package "other" "github-release" "upstream:
  project: owner/repo
current: '2.0.0'"
  checked_status pkg "new_version: 2.0.0"
  checked_status other "up_to_date"
  mkdir -p "$TEST_TMPDIR/out/prepared/pkg"
  stub_script publish-pkg.sh 0
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
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

Auto-created by update workflow. Close after fixing.
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
}

@test "check_prepared_pkgbuild: rejects text after a checksum array" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3' '$H4'); curl evil.example"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
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
}

# bash reads an escaped space there, so the # starts a word, not a comment
@test "check_prepared_pkgbuild: rejects a backslash before a hash sign in a checksum array" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('SKIP' 'SKIP')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('SKIP' \\ # c
            'SKIP')"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
}

# bash starts no comment right after the closing parenthesis
@test "check_prepared_pkgbuild: rejects a hash sign right after a checksum array" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('SKIP' 'SKIP')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('SKIP' 'SKIP')# c"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
}

@test "check_prepared_pkgbuild: rejects a changed number of checksums" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3')"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
}

@test "check_prepared_pkgbuild: rejects a new checksum array" {
  write_pkgbuild "$OLD" 1.0.0 2 "sha256sums=('$H1' '$H2')"
  write_pkgbuild "$NEW" 1.1.0 1 "sha256sums=('$H3' '$H4')
b2sums=('$H3' '$H4')"
  run check_prepared_pkgbuild "$OLD" "$NEW" 1.1.0
  [ "$status" -eq 1 ]
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
}

@test "check_prepared_srcinfo: rejects a NUL byte" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 "$H3" "$H4"
  sed -i $'s/^\tlicense = MIT$/\tlicense = MIT\\x00 extra/' "$TEST_TMPDIR/new.SRCINFO"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
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
}

@test "check_prepared_srcinfo: rejects an arch source that keeps the old version" {
  write_srcinfo_line "$TEST_TMPDIR/old.SRCINFO" 2.0 "source_x86_64 = https://example.com/demo-2.0-x86_64.tar.gz"
  write_srcinfo_line "$TEST_TMPDIR/new.SRCINFO" 2.1 "source_x86_64 = https://example.com/demo-2.0-x86_64.tar.gz"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.1
  [ "$status" -eq 1 ]
}

@test "check_prepared_srcinfo: rejects a line changed beyond the version" {
  write_srcinfo_line "$TEST_TMPDIR/old.SRCINFO" 2.0 "depends = glibc>=2.0.1"
  write_srcinfo_line "$TEST_TMPDIR/new.SRCINFO" 2.1 "depends = glibc>=2.9"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 2.1
  [ "$status" -eq 1 ]
  [[ "$output" == *"changes more than the version"* ]]
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
}

@test "check_prepared_srcinfo: rejects a new URL for a SKIP source" {
  write_srcinfo_nightly "$TEST_TMPDIR/old.SRCINFO" 1.0.0 demo-20261014.tar.gz b2sums=SKIP
  write_srcinfo_nightly "$TEST_TMPDIR/new.SRCINFO" 1.1.0 demo-20261016.tar.gz b2sums=SKIP \
    https://evil.example/demo-linux.tar.gz
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
}

@test "check_prepared_srcinfo: rejects new digits in the name of a hashed source" {
  write_srcinfo_nightly "$TEST_TMPDIR/old.SRCINFO" 1.0.0 demo-20261014.tar.gz "b2sums=$H1"
  write_srcinfo_nightly "$TEST_TMPDIR/new.SRCINFO" 1.1.0 demo-20261016.tar.gz "b2sums=$H3"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
}

@test "check_prepared_srcinfo: rejects new digits when another checksum array has a hash" {
  write_srcinfo_nightly "$TEST_TMPDIR/old.SRCINFO" 1.0.0 demo-20261014.tar.gz "b2sums=SKIP sha256sums=$H1"
  write_srcinfo_nightly "$TEST_TMPDIR/new.SRCINFO" 1.1.0 demo-20261016.tar.gz "b2sums=SKIP sha256sums=$H3"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
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
}

@test "check_prepared_srcinfo: rejects a line turned into an unknown checksum key" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 "$H3" "$H4"
  sed -i $'s/^\tlicense = MIT$/\tlicensesums = abc/' "$TEST_TMPDIR/new.SRCINFO"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
}

@test "check_prepared_srcinfo: rejects a source change beyond the version" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 "$H3" "$H4"
  sed -i 's|https://example.com/demo|https://evil.example/demo|' "$TEST_TMPDIR/new.SRCINFO"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
}

@test "check_prepared_srcinfo: rejects a SKIP where the AUR had a hash" {
  write_srcinfo "$TEST_TMPDIR/old.SRCINFO" 1.0.0 2 "$H1" "$H2"
  write_srcinfo "$TEST_TMPDIR/new.SRCINFO" 1.1.0 1 "SKIP" "$H4"
  run check_prepared_srcinfo "$TEST_TMPDIR/old.SRCINFO" "$TEST_TMPDIR/new.SRCINFO" 1.1.0
  [ "$status" -eq 1 ]
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
}
