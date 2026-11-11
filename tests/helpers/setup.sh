#!/usr/bin/env bash
# Shared BATS test setup
# Creates temp package dir, injects mock curl into PATH

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# CI sets it for the repository of aurtomator, and update-readme.sh reads it
unset GITHUB_REPOSITORY

# Create temp workspace
setup_test_env() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR

  # Create mock package dir structure
  mkdir -p "$TEST_TMPDIR/packages"
  mkdir -p "$TEST_TMPDIR/strategies"
  mkdir -p "$TEST_TMPDIR/scripts/lib"
  mkdir -p "$TEST_TMPDIR/.status"

  # Symlink all scripts and strategies for bashcov coverage tracking
  ln -sf "$PROJECT_DIR/scripts/"*.sh "$TEST_TMPDIR/scripts/"
  ln -sf "$PROJECT_DIR/scripts/lib/"*.sh "$TEST_TMPDIR/scripts/lib/"
  ln -sf "$PROJECT_DIR/strategies/"*.sh "$TEST_TMPDIR/strategies/"

  # Put mock curl first in PATH
  MOCK_DIR="$TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_DIR"
  cp "$TESTS_DIR/helpers/mock-curl.sh" "$MOCK_DIR/curl"
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"

  # Override AURTOMATOR_DIR and AURTOMATOR_DATA_DIR so all scripts use our
  # temp workspace
  export AURTOMATOR_DIR="$TEST_TMPDIR"
  export AURTOMATOR_DATA_DIR="$TEST_TMPDIR"

  # No pause before an AUR clone, between attempts or before a second check
  export AURTOMATOR_CLONE_DELAY=0 AURTOMATOR_RETRY_DELAY=0 AURTOMATOR_RECHECK_DELAY=0

  # git reads and writes no global config of the user running the tests
  export GIT_CONFIG_GLOBAL="$TEST_TMPDIR/gitconfig"
}

# bashcov-bats.sh sets AURTOMATOR_KEEP_TEST_DIRS: bashcov reads the trace
# of a test after the test, and needs the links in $TEST_TMPDIR then
teardown_test_env() {
  if [[ -z "${AURTOMATOR_KEEP_TEST_DIRS:-}" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

# Create a test package YAML
# Usage: create_test_package <name> <strategy> <yaml-body>
create_test_package() {
  local name="$1"
  local strategy="$2"
  local extra="$3"
  cat >"$TEST_TMPDIR/packages/${name}.yml" <<EOF
name: ${name}
strategy: ${strategy}
${extra}
EOF
}

# Usage: make_aur_remote <pkg> <PKGBUILD> <.SRCINFO> [file]...; sets AUR_REMOTE
# and AUR_BASE. git clones it for an AUR URL and fetches upstream.git for https.
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
  # shellcheck disable=SC2034
  AUR_BASE=$(git -C "$AUR_REMOTE" rev-parse HEAD)
  cat >"$MOCK_DIR/git" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" fetch "* && "\${@: -2:1}" == https://* ]]; then
  echo "\${@: -2:1}" >>"$TEST_TMPDIR/git-clone-urls"
  echo "\${GIT_ALLOW_PROTOCOL:-unset}" >>"$TEST_TMPDIR/git-allow"
  echo "\$*" >>"$TEST_TMPDIR/git-fetch-args"
  exec env -u GIT_ALLOW_PROTOCOL /usr/bin/git "\${@:1:\$#-2}" "file://$TEST_TMPDIR/upstream.git" "\${@: -1}"
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

# The packages of arch_pkgbuild and arch_srcinfo build these arches, in this
# order, each from an archive of its own, as jdk-temurin-ea-bin does
ARCH_ALL=(x86_64 aarch64 powerpc64le riscv64)

# Print the URL of the archive of arch $1 at version $2
arch_source_url() {
  local file=$1
  [[ "$1" != x86_64 ]] || file=x64
  [[ "$1" != powerpc64le ]] || file=ppc64le
  printf 'https://github.com/adoptium/temurin28-binaries/releases/download/jdk-%s-ea-beta/OpenJDK-jdk_%s_linux_hotspot_%s-ea.tar.gz\n' "$2" "$file" "${2/+/_}"
}

# Print the checksum of the archive of arch $1 at version $2
arch_sum() {
  printf '%s' "$1$2" | sha256sum | cut -d' ' -f1
}

# Write to $1 the .SRCINFO of the package at version $2 (default 28+22) for
# the arches after it (default all), as makepkg --printsrcinfo prints it
arch_srcinfo() {
  local ver="${2:-28+22}" arch
  local -a arches=("${@:3}")
  ((${#arches[@]} > 0)) || arches=("${ARCH_ALL[@]}")
  {
    printf '%s\n' "pkgbase = jdk-temurin-ea-bin" $'\tpkgdesc = Eclipse Temurin early access JDK' \
      $'\tpkgver = '"$ver" $'\tpkgrel = 1' $'\turl = https://adoptium.net/'
    printf '\tarch = %s\n' "${arches[@]}"
    printf '%s\n' $'\tlicense = GPL-2.0-only WITH Classpath-exception-2.0' $'\tdepends = java-runtime-common'
    for arch in "${arches[@]}"; do
      printf '\tsource_%s = %s\n' "$arch" "$(arch_source_url "$arch" "$ver")"
      [[ "$arch" != aarch64 ]] || printf '\tdepends_aarch64 = zlib\n'
      printf '\tsha256sums_%s = %s\n' "$arch" "$(arch_sum "$arch" "$ver")"
    done
    printf '\npkgname = jdk-temurin-ea-bin\n'
  } >"$1"
}

# Write to $1 the PKGBUILD of the package at version $2 (default 28+22) with
# the arches after it (default all) in arch=() and a checksum array each
arch_pkgbuild() {
  local ver="${2:-28+22}" arch quoted=""
  local -a arches=("${@:3}")
  ((${#arches[@]} > 0)) || arches=("${ARCH_ALL[@]}")
  for arch in "${arches[@]}"; do
    quoted+="${quoted:+ }'$arch'"
  done
  {
    # shellcheck disable=SC2016
    printf '%s\n' 'pkgname=jdk-temurin-ea-bin' "pkgver=$ver" 'pkgrel=1' \
      'pkgdesc="Eclipse Temurin early access JDK"' "arch=($quoted)" 'url="https://adoptium.net/"' \
      "license=('GPL-2.0-only WITH Classpath-exception-2.0')" "depends=('java-runtime-common')" \
      "depends_aarch64=('zlib')" \
      '_release="https://github.com/adoptium/temurin28-binaries/releases/download/jdk-${pkgver}-ea-beta"' \
      '_file="linux_hotspot_${pkgver/+/_}-ea.tar.gz"' \
      'source_x86_64=("${_release}/OpenJDK-jdk_x64_${_file}")' \
      'source_aarch64=("${_release}/OpenJDK-jdk_aarch64_${_file}")' \
      'source_powerpc64le=("${_release}/OpenJDK-jdk_ppc64le_${_file}")' \
      'source_riscv64=("${_release}/OpenJDK-jdk_riscv64_${_file}")'
    for arch in "${arches[@]}"; do
      printf "sha256sums_%s=('%s')\n" "$arch" "$(arch_sum "$arch" "$ver")"
    done
    # shellcheck disable=SC2016
    printf '\n%s\n' 'package() {' '  install -d "$pkgdir/usr/lib/jvm"' '}'
  } >"$1"
}

# Commit the files of arch_pkgbuild and arch_srcinfo for version $1 and the
# arches after it to the AUR repo of jdk-temurin-ea-bin, and print the commit
aur_arch_commit() {
  local work="$TEST_TMPDIR/aur-work-jdk-temurin-ea-bin"
  arch_pkgbuild "$work/PKGBUILD" "$@"
  arch_srcinfo "$work/.SRCINFO" "$@"
  git -C "$work" add -A
  git -C "$work" -c user.name=aur -c user.email=aur@example.invalid \
    -c commit.gpgsign=false commit -qm "$1"
  git -C "$work" push -q "$AUR_REMOTE" master
  git -C "$AUR_REMOTE" rev-parse HEAD
}

# The archive of arch $1 at version $2 answers 404 to the curl of mock_heads
archive_missing() {
  arch_source_url "$1" "$2" >>"$TEST_TMPDIR/missing"
}

# A curl that answers a HEAD request with 404 for a URL in $TEST_TMPDIR/missing,
# with no status for one in silent and with a file otherwise; logs to heads.log
mock_heads() {
  cat >"$MOCK_DIR/curl" <<EOF
#!/usr/bin/env bash
url="\${@: -1}"
echo "\$url" >>"$TEST_TMPDIR/heads.log"
if grep -qxF -e "\$url" "$TEST_TMPDIR/silent" 2>/dev/null; then
  printf '000 '
  exit 28
fi
if grep -qxF -e "\$url" "$TEST_TMPDIR/missing" 2>/dev/null; then
  printf '404 text/html; charset=utf-8'
else
  printf '200 application/octet-stream'
fi
EOF
  chmod +x "$MOCK_DIR/curl"
}

# Prints how many status files of directory $1 hold check_failed or
# update_failed
failed_statuses() {
  local file count=0
  for file in "$1"/*; do
    [[ -f "$file" && "${file##*/}" != _* ]] || continue
    case "$(<"$file")" in
      check_failed:* | update_failed:*) count=$((count + 1)) ;;
    esac
  done
  echo "$count"
}
