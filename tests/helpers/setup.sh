#!/usr/bin/env bash
# Shared BATS test setup
# Creates temp package dir, injects mock curl and the mock git of AUR clones into PATH

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# Answers of real services that the mocks serve, see tests/fixtures/pypi/README.md
export FIXTURES_DIR="$TESTS_DIR/fixtures"

# CI sets it for the repository of aurtomator, and update-readme.sh reads it
unset GITHUB_REPOSITORY
# CI sets it to pull_request, and check-pins of aurtomator.sh then compares pins with HEAD^1
unset GITHUB_EVENT_NAME

# Create temp workspace
setup_test_env() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR
  # GitHub Actions sets the run number, which moves the start of the check loop
  unset GITHUB_RUN_NUMBER

  # Create mock package dir structure
  mkdir -p "$TEST_TMPDIR/packages"
  mkdir -p "$TEST_TMPDIR/strategies"
  mkdir -p "$TEST_TMPDIR/scripts/lib"
  mkdir -p "$TEST_TMPDIR/.status"

  # Symlink all scripts and strategies for bashcov coverage tracking
  ln -sf "$PROJECT_DIR/scripts/"*.sh "$TEST_TMPDIR/scripts/"
  ln -sf "$PROJECT_DIR/scripts/lib/"*.sh "$TEST_TMPDIR/scripts/lib/"
  ln -sf "$PROJECT_DIR/scripts/lib/"*.py "$TEST_TMPDIR/scripts/lib/"
  ln -sf "$PROJECT_DIR/scripts/lib/"*.rb "$TEST_TMPDIR/scripts/lib/"
  ln -sf "$PROJECT_DIR/strategies/"*.sh "$TEST_TMPDIR/strategies/"

  # Mock curl first in PATH, the mock git of AUR clones after MOCK_DIR: git mocks that a test writes
  # there answer its scripts, and the test's own git commands keep the git bash found first
  MOCK_DIR="$TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_DIR" "$TEST_TMPDIR/aur-bin"
  cp "$TESTS_DIR/helpers/mock-curl.sh" "$MOCK_DIR/curl"
  chmod +x "$MOCK_DIR/curl"
  cp "$TESTS_DIR/helpers/mock-aur-git.sh" "$TEST_TMPDIR/aur-bin/git"
  chmod +x "$TEST_TMPDIR/aur-bin/git"
  export PATH="$MOCK_DIR:$TEST_TMPDIR/aur-bin:$PATH"

  # Override AURTOMATOR_DIR and AURTOMATOR_DATA_DIR so all scripts use our
  # temp workspace
  export AURTOMATOR_DIR="$TEST_TMPDIR"
  export AURTOMATOR_DATA_DIR="$TEST_TMPDIR"

  # No pause before an AUR clone, between attempts or before a second check
  export AURTOMATOR_CLONE_DELAY=0 AURTOMATOR_RETRY_DELAY=0 AURTOMATOR_RECHECK_DELAY=0

  # Only the tests that ask for it get a memory of hosts
  unset AURTOMATOR_HOSTS_DIR

  # git reads and writes no global config of the user running the tests
  export GIT_CONFIG_GLOBAL="$TEST_TMPDIR/gitconfig"

  # git of the tests reaches no host, except where a script sets GIT_ALLOW_PROTOCOL itself
  export GIT_ALLOW_PROTOCOL=file

  # Files a test writes for mock curl: simple/<project>.json, files.pythonhosted.org files by
  # their name, and aur-rpc.json, a list of the packages AUR RPC knows
  export MOCK_FILES_DIR="$TEST_TMPDIR/mock-files"
  mkdir -p "$MOCK_FILES_DIR"
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

# Put the mock pacman of tests/helpers first in PATH, for markers on the Python of pacman
use_mock_pacman() {
  cp "$TESTS_DIR/helpers/mock-pacman.sh" "$MOCK_DIR/pacman"
  chmod +x "$MOCK_DIR/pacman"
}

# Usage: make_aur_remote <pkg> <PKGBUILD> <.SRCINFO> [file]...; sets AUR_REMOTE
# and AUR_BASE. git clones it for an AUR URL and fetches upstream.git for https.
# Adds a canary to PKGBUILD $1: top-level code, a pkgver() and a line of package() that each
# create a file in $TEST_TMPDIR/canary when the PKGBUILD runs
add_canary() {
  local dir="$TEST_TMPDIR/canary"
  mkdir -p "$dir"
  # The checks refuse a checksum array below a line with more than assignments, so the
  # canary comes after the arrays, before the first package()
  awk -v d="$dir" -v q="'" '
    /^package[a-z_]*\(\) \{$/ && !top {
      print "_canary=\"$(touch " q d "/top" q ")\""
      print "pkgver() { touch " q d "/pkgver" q "; }"
      print ""
      top = 1
    }
    { print }
    /^package[a-z_]*\(\) \{$/ { print "  touch " q d "/package" q }
  ' "$1" >"$1.canary"
  mv "$1.canary" "$1"
  grep -q '^_canary=' "$1"
}

# Succeeds when no code of a PKGBUILD of add_canary ran
canary_untouched() {
  [ -d "$TEST_TMPDIR/canary" ] && [ -z "$(ls -A "$TEST_TMPDIR/canary")" ]
}

# Usage: pypi_fake_file <project> <version> <file> <core-metadata sha256 or false>. Adds a release of
# file <file> of MOCK_FILES_DIR to the simple page of the project in MOCK_FILES_DIR.
pypi_fake_file() {
  local page norm=${1,,}
  norm=$(sed -E 's/[-_.]+/-/g' <<<"$norm")
  page="$MOCK_FILES_DIR/simple/$norm.json"
  mkdir -p "$MOCK_FILES_DIR/simple"
  [[ -f "$page" ]] || printf '{"meta": {"api-version": "1.4"}, "name": "%s", "versions": [], "files": []}\n' "$norm" >"$page"
  V="$2" F="${3##*/}" S="$(sha256sum "$3" | cut -d' ' -f1)" C="$4" yq -i -o json '
    .versions = (.versions + [strenv(V)] | unique) |
    .files += [{"filename": strenv(F), "url": "https://files.pythonhosted.org/packages/fake/" + strenv(F),
      "hashes": {"sha256": strenv(S)}, "core-metadata": (strenv(C) | select(. != "false") | {"sha256": .}) // false,
      "size": 1, "yanked": false}]' "$page"
}

# Usage: pypi_fake_metadata <project> <version> <METADATA text>. Writes a wheel entry of the release
# whose .metadata holds the text, served by mock curl from MOCK_FILES_DIR
pypi_fake_metadata() {
  local wheel="${1//-/_}-$2-py3-none-any.whl"
  printf '%s' "$3" >"$MOCK_FILES_DIR/$wheel.metadata"
  : >"$MOCK_FILES_DIR/$wheel"
  pypi_fake_file "$1" "$2" "$MOCK_FILES_DIR/$wheel" "$(sha256sum "$MOCK_FILES_DIR/$wheel.metadata" | cut -d' ' -f1)"
}

# Usage: pypi_fake <project> <version> [Requires-Dist value]...
pypi_fake() {
  local text req
  text=$(printf 'Metadata-Version: 2.4\nName: %s\nVersion: %s\n' "$1" "$2")$'\n'
  for req in "${@:3}"; do
    text+="Requires-Dist: $req"$'\n'
  done
  pypi_fake_metadata "$1" "$2" "$text"$'\nThe body of the description.\n'
}

# Usage: pypi_fake_sdist <project> <version> <PKG-INFO text>. Writes an sdist of the release that
# holds <name>-<version>/PKG-INFO, with no metadata file of its own
pypi_fake_sdist() {
  local dir="$TEST_TMPDIR/sdist-$1-$2" stem="${1//-/_}-$2"
  mkdir -p "$dir/$stem"
  printf '%s' "$3" >"$dir/$stem/PKG-INFO"
  printf 'print("setup")\n' >"$dir/$stem/setup.py"
  bsdtar -czf "$MOCK_FILES_DIR/$stem.tar.gz" -C "$dir" "$stem"
  pypi_fake_file "$1" "$2" "$MOCK_FILES_DIR/$stem.tar.gz" false
}

# Usage: python_aur <pkgbase>. The AUR serves the package with python in depends, so the requires rules
# run for it, and the mock pacman answers with no files database and no package but python
python_aur() {
  use_mock_pacman
  printf 'pkgbase = %s\n\tpkgver = 1.0\n\tpkgrel = 1\n\tarch = any\n\tdepends = python\n\npkgname = %s\n' "$1" "$1" \
    >"$TEST_TMPDIR/aur-$1.SRCINFO"
  aur_srcinfo_remote "$1" "$TEST_TMPDIR/aur-$1.SRCINFO"
}

# Writes the AUR metadata file that mock-curl.sh serves, with a record of each argument after [ and
# before ], one a line, as aurweb writes it
aur_meta() {
  local IFS=$'\n'
  {
    echo '['
    [[ $# -eq 0 ]] || printf '%s\n' "$(printf '%s,\n' "$@" | sed '$ s/,$//')"
    printf ']'
  } | gzip >"$MOCK_FILES_DIR/packages-meta-ext-v1.json.gz"
}

# Usage: aur_srcinfo_remote <pkgbase> <.SRCINFO>. The mock git of AUR clones then serves a repo
# with that .SRCINFO and a stub PKGBUILD for <pkgbase>; MOCK_DIR keeps its git.
aur_srcinfo_remote() {
  local work="$TEST_TMPDIR/aur-work-$1" remote="$TEST_TMPDIR/aur-remote/$1.git"
  git init -q --bare -b master "$remote"
  git init -q -b master "$work"
  cp "$2" "$work/.SRCINFO"
  printf 'pkgname=%s\n' "$1" >"$work/PKGBUILD"
  git -C "$work" add .
  git -C "$work" -c user.name=aur -c user.email=aur@example.invalid \
    -c commit.gpgsign=false commit -qm "aur state"
  git -C "$work" push -q "$remote" master
}

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
[[ -z "\${GIT_ALLOC_LIMIT:-}" ]] || echo "\$GIT_ALLOC_LIMIT \$*" >>"$TEST_TMPDIR/git-alloc"
[[ " \$* " != *" fetch "* ]] || echo "\$*" >>"$TEST_TMPDIR/git-fetches"
if [[ " \$* " == *" fetch "* && "\${@: -2:1}" == https://* ]]; then
  echo "\${@: -2:1}" >>"$TEST_TMPDIR/git-clone-urls"
  echo "\${GIT_ALLOW_PROTOCOL:-unset}" >>"$TEST_TMPDIR/git-allow"
  echo "\$*" >>"$TEST_TMPDIR/git-fetch-args"
  ulimit -f >>"$TEST_TMPDIR/git-fetch-ulimit"
  trap -p XFSZ >>"$TEST_TMPDIR/git-fetch-traps"
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

# Make the archive of arch $1 at version $2 answer 503
archive_refused() {
  arch_source_url "$1" "$2" >>"$TEST_TMPDIR/refused"
}

# Make the archive of arch $1 at version $2 answer 403
archive_forbidden() {
  arch_source_url "$1" "$2" >>"$TEST_TMPDIR/forbidden"
}

# Mock curl that answers HEAD requests with 404 for URLs in $TEST_TMPDIR/missing, 503 for those in
# refused, 403 for those in forbidden, no status for those in silent and a file otherwise; logs to heads.log
mock_heads() {
  cat >"$MOCK_DIR/curl" <<EOF
#!/usr/bin/env bash
url="\${@: -1}"
echo "\$url" >>"$TEST_TMPDIR/heads.log"
if grep -qxF -e "\$url" "$TEST_TMPDIR/silent" 2>/dev/null; then
  printf '000 '
  exit 28
fi
if grep -qxF -e "\$url" "$TEST_TMPDIR/refused" 2>/dev/null; then
  printf '503 text/html; charset=utf-8'
  exit 0
fi
if grep -qxF -e "\$url" "$TEST_TMPDIR/forbidden" 2>/dev/null; then
  printf '403 application/xml'
  exit 0
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

# The memory of hosts that check-all.sh keeps in a run, in $TEST_TMPDIR/hosts,
# with the given hosts in silent
keep_host_memory() {
  export AURTOMATOR_HOSTS_DIR="$TEST_TMPDIR/hosts"
  mkdir -p "$AURTOMATOR_HOSTS_DIR"
  : >"$AURTOMATOR_HOSTS_DIR/silent"
  : >"$AURTOMATOR_HOSTS_DIR/request"
  if (($#)); then
    printf '%s\n' "$@" >"$AURTOMATOR_HOSTS_DIR/silent"
  fi
}

# Skips a test for the locale this machine lacks, reason $1, and fails it in CI, whose
# test job builds the locales of the tests
locale_needed() {
  if [[ -n "${CI:-}" ]]; then
    echo "$1, and the test job of CI builds it" >&2
    return 1
  fi
  skip "$1"
}
