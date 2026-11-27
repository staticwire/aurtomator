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

# The AUR answers a package it lacks with an empty repo, and every check of a new version clones it
@test "setup_test_env: AUR clones get an empty repo of the test directory" {
  git clone --no-checkout -q https://aur.archlinux.org/none-such.git "$TEST_TMPDIR/clone"
  [ "$(git -C "$TEST_TMPDIR/clone" remote get-url origin)" = "file://$TEST_TMPDIR/aur-empty.git" ]
  run ! git -C "$TEST_TMPDIR/clone" rev-parse -q --verify HEAD
}

@test "setup_test_env: git of the tests reaches no host" {
  run git ls-remote https://example.invalid/repo.git
  [ "$status" -eq 128 ]
  [[ "$output" == *"transport 'https' not allowed"* ]]
  run git ls-remote ssh://git@example.invalid/repo.git
  [ "$status" -eq 128 ]
  [[ "$output" == *"transport 'ssh' not allowed"* ]]
}

@test "setup.sh: tests run without the GITHUB_EVENT_NAME of CI" {
  GITHUB_EVENT_NAME=pull_request run bash -c 'source "$1"; echo "${GITHUB_EVENT_NAME-unset}"' _ "$TESTS_DIR/helpers/setup.sh"
  [ "$status" -eq 0 ]
  [ "$output" = unset ]
}

# === test helpers ===

@test "test helpers: FIXTURES_DIR names the fixtures, MOCK_FILES_DIR starts empty" {
  [ "$FIXTURES_DIR" = "$TESTS_DIR/fixtures" ]
  [ -f "$FIXTURES_DIR/pypi/simple/httpx.json" ]
  [ -d "$MOCK_FILES_DIR" ]
  [ -z "$(ls -A "$MOCK_FILES_DIR")" ]
}

@test "test helpers: mock curl writes the answer into the file of -o and -w text to stdout" {
  local url=https://files.pythonhosted.org/packages/x/httpx-0.28.1-py3-none-any.whl.metadata
  run curl -sf -o "$TEST_TMPDIR/out" -w '\n%{url_effective}' "$url"
  [ "$status" -eq 0 ]
  [ "$output" = $'\n'"$url" ]
  cmp "$TEST_TMPDIR/out" "$FIXTURES_DIR/pypi/metadata/httpx-0.28.1-py3-none-any.whl.metadata"
}

@test "test helpers: mock curl answers the simple API of PyPI from the fixtures, 404 for other projects" {
  source "$PROJECT_DIR/scripts/lib/common.sh"
  run http_get_json https://pypi.org/simple/httpx/ -H 'Accept: application/vnd.pypi.simple.v1+json'
  [ "$status" -eq 0 ]
  [ "$output" = "$(<"$FIXTURES_DIR/pypi/simple/httpx.json")" ]
  run http_get_json https://pypi.org/simple/none-such/
  [ "$status" -eq 22 ]
  [[ "$output" == *"https://pypi.org/simple/none-such/: The requested URL returned error: 404"* ]]
}

@test "test helpers: mock curl takes simple pages and files of MOCK_FILES_DIR first" {
  source "$PROJECT_DIR/scripts/lib/common.sh"
  mkdir "$MOCK_FILES_DIR/simple"
  echo '{"name": "httpx", "files": []}' >"$MOCK_FILES_DIR/simple/httpx.json"
  echo demo >"$MOCK_FILES_DIR/demo-1.0-py3-none-any.whl"
  run http_get_json https://pypi.org/simple/httpx/
  [ "$output" = '{"name": "httpx", "files": []}' ]
  run http_get https://files.pythonhosted.org/packages/a/b/demo-1.0-py3-none-any.whl -o "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(<"$TEST_TMPDIR/out")" = demo ]
  run http_get https://files.pythonhosted.org/packages/a/b/none-1.0.tar.gz -o "$TEST_TMPDIR/out"
  [ "$status" -eq 22 ]
  [[ "$output" == *"none-1.0.tar.gz: The requested URL returned error: 404"* ]]
}

@test "test helpers: mock curl answers AUR RPC info with the packages of MOCK_FILES_DIR that the args name" {
  source "$PROJECT_DIR/scripts/lib/common.sh"
  echo '[{"Name": "a", "Version": "1-1"}, {"Name": "b", "Version": "2-1"}, {"Name": "c++", "Version": "3-1"}]' \
    >"$MOCK_FILES_DIR/aur-rpc.json"
  run http_get_json 'https://aur.archlinux.org/rpc/v5/info?arg[]=a&arg%5B%5D=c%2B%2B&arg[]=missing'
  [ "$status" -eq 0 ]
  [ "$(yq -o json -I0 '[.version, .type, .resultcount, [.results[].Name]]' <<<"$output")" = '[5,"multiinfo",2,["a","c++"]]' ]
  rm "$MOCK_FILES_DIR/aur-rpc.json"
  run http_get_json 'https://aur.archlinux.org/rpc/v5/info?arg[]=a'
  [ "$(yq -o json -I0 '[.resultcount, .results]' <<<"$output")" = '[0,[]]' ]
}

@test "test helpers: mock curl answers rubygems.org from MOCK_FILES_DIR, then the fixtures, 404 for others" {
  source "$PROJECT_DIR/scripts/lib/common.sh"
  run http_get_json https://rubygems.org/api/v1/versions/bashcov.json
  [ "$status" -eq 0 ]
  [ "$output" = "$(<"$FIXTURES_DIR/rubygems/versions/bashcov.json")" ]
  run http_get_json https://rubygems.org/api/v2/rubygems/bashcov/versions/4.0.3.json
  [ "$output" = "$(<"$FIXTURES_DIR/rubygems/v2/bashcov-4.0.3.json")" ]
  mkdir -p "$MOCK_FILES_DIR/rubygems/versions" "$MOCK_FILES_DIR/rubygems/v2"
  echo '[{"number": "1.0"}]' >"$MOCK_FILES_DIR/rubygems/versions/bashcov.json"
  echo '{"number": "1.0"}' >"$MOCK_FILES_DIR/rubygems/v2/demo-1.0.json"
  echo gem >"$MOCK_FILES_DIR/demo-1.0.gem"
  run http_get_json https://rubygems.org/api/v1/versions/bashcov.json
  [ "$output" = '[{"number": "1.0"}]' ]
  run http_get_json https://rubygems.org/api/v2/rubygems/demo/versions/1.0.json
  [ "$output" = '{"number": "1.0"}' ]
  run http_get https://rubygems.org/gems/demo-1.0.gem -o "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(<"$TEST_TMPDIR/out")" = gem ]
  for url in https://rubygems.org/api/v1/versions/none-such.json https://rubygems.org/api/v2/rubygems/bashcov/versions/9.9.json \
    https://rubygems.org/gems/none-1.0.gem; do
    run http_get "$url"
    [ "$status" -eq 22 ]
    [[ "$output" == *"$url: The requested URL returned error: 404"* ]]
  done
}

@test "test helpers: aur_srcinfo_remote serves a .SRCINFO to AUR clones of its name alone" {
  printf 'pkgbase = demo\n\tpkgver = 1.0\n\npkgname = demo\n' >"$TEST_TMPDIR/srcinfo"
  aur_srcinfo_remote demo "$TEST_TMPDIR/srcinfo"
  [ ! -e "$MOCK_DIR/git" ]
  git clone -q --depth 1 --no-checkout https://aur.archlinux.org/demo.git "$TEST_TMPDIR/demo"
  [ "$(git -C "$TEST_TMPDIR/demo" show HEAD:.SRCINFO)" = "$(<"$TEST_TMPDIR/srcinfo")" ]
  git -C "$TEST_TMPDIR/demo" cat-file -e HEAD:PKGBUILD
  git clone -q --no-checkout https://aur.archlinux.org/other.git "$TEST_TMPDIR/other"
  run ! git -C "$TEST_TMPDIR/other" rev-parse -q --verify HEAD
}

@test "test helpers: mock pacman answers -Fx --machinereadable from MOCK_PACMAN_FILES" {
  use_mock_pacman
  export PACMAN_ARGS_LOG="$TEST_TMPDIR/pacman-args" MOCK_PACMAN_FILES="$TEST_TMPDIR/pacman-files"
  printf 'extra\tpython-yaml\t6.0.2-2\tusr/lib/python3.13/site-packages/PyYAML-6.0.2.dist-info/METADATA\n' >"$MOCK_PACMAN_FILES"
  printf 'extra\tazure-cli\t2.71.0-1\topt/azure-cli/lib/python3.13/site-packages/PyYAML-6.0.2.dist-info/METADATA\n' >>"$MOCK_PACMAN_FILES"
  run bash -c 'set -o pipefail; pacman -Fx --machinereadable "$1" | tr "\0" "|"' _ '^usr/lib/.*METADATA$'
  [ "$status" -eq 0 ]
  [ "$output" = 'extra|python-yaml|6.0.2-2|usr/lib/python3.13/site-packages/PyYAML-6.0.2.dist-info/METADATA' ]
  [ "$(pacman -Fx --machinereadable 'METADATA$' | tr '\0' '|' | wc -l)" -eq 2 ]
  run pacman -Fx --machinereadable '^usr/bin/none$'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  MOCK_PACMAN_NO_FILES=1 run --separate-stderr pacman -Fx --machinereadable 'METADATA$'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"database file for 'core' does not exist"* ]]
  [ "$(head -1 "$PACMAN_ARGS_LOG")" = "-Fx --machinereadable ^usr/lib/.*METADATA\$" ]
}

@test "test helpers: mock pacman answers -Sddp and -Si from MOCK_PACMAN_SYNC, by name or provides" {
  use_mock_pacman
  export PACMAN_ARGS_LOG="$TEST_TMPDIR/pacman-args" MOCK_PACMAN_SYNC="$TEST_TMPDIR/pacman-sync"
  printf '%s\n' 'python-yaml 6.0.4-1 extra python-pyyaml' 'python-h2 4.3.0-2 extra' >"$MOCK_PACMAN_SYNC"
  run pacman -Sddp --print-format '%n %v %r' python-pyyaml
  [ "$status" -eq 0 ]
  [ "$output" = 'python-yaml 6.0.4-1 extra' ]
  run pacman -Sddp --print-format '%n %v %r' python-h2
  [ "$output" = 'python-h2 4.3.0-2 extra' ]
  run pacman -Sddp --print-format '%n %v %r' python-none
  [ "$status" -eq 1 ]
  [ "$output" = 'error: target not found: python-none' ]
  run pacman -Si python-yaml
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nVersion         : 6.0.4-1\n'* ]]
  [[ "$output" == *$'\nProvides        : python-pyyaml'* ]]
  run pacman -Si python
  [[ "$output" == *"Version         : 3.14.10-1"* ]]
  [ "$(wc -l <"$PACMAN_ARGS_LOG")" -eq 5 ]
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

# Callers read nothing as the default of a flag, true for allow_missing_arch
@test "lib.sh: pkg_bool reads true and false in any case, nothing for no value, and fails on others" {
  local entry
  source "$TEST_TMPDIR/scripts/lib.sh"
  for entry in true:true True:true TRUE:true false:false False:false FALSE:false '~': '': 'null':; do
    printf 'flag: %s\n' "${entry%:*}" >"$TEST_TMPDIR/flag.yml"
    run pkg_bool "$TEST_TMPDIR/flag.yml" .flag
    [ "$status" -eq 0 ]
    [ "$output" = "${entry##*:}" ] || {
      echo "${entry%:*} read as $output"
      return 1
    }
  done
  printf 'other: true\n' >"$TEST_TMPDIR/flag.yml"
  run pkg_bool "$TEST_TMPDIR/flag.yml" .flag
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'a: &x false\nflag: *x\n' >"$TEST_TMPDIR/flag.yml"
  run pkg_bool "$TEST_TMPDIR/flag.yml" .flag
  [ "$status" -eq 0 ]
  [ "$output" = false ]
  for entry in '"false"' no off 0 yes '!!bool yes' '!!bool 1' tRUE '[]'; do
    printf 'flag: %s\n' "$entry" >"$TEST_TMPDIR/flag.yml"
    run pkg_bool "$TEST_TMPDIR/flag.yml" .flag
    [ "$status" -eq 1 ]
    [[ "$output" == *"packages/flag.yml: flag must be true or false" ]] || {
      echo "${entry} read as $output"
      return 1
    }
  done
}

# A YAML that says no to missing arches would publish without them after 24 hours
@test "check-update: fails the check of a package whose flag is no boolean" {
  local flag
  for flag in allow_downgrade allow_version_jump allow_missing_arch; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
$flag: \"false\""
    run "$TEST_TMPDIR/scripts/check-update.sh" mypkg
    [ "$status" -eq 1 ]
    [[ "$output" == *"packages/mypkg.yml: $flag must be true or false" ]]
  done
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
  # nightly-bin package: SKIP for the remote binary, and real hashes for local files of the
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

# Fossil clones are one file, which makepkg -g hashes as a download
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

# The token outlives the run, and only gitlab-tag sends it; other strategies parse upstream answers
@test "check-update: gives the GitLab tokens to gitlab-tag alone" {
  local strategy var
  for strategy in gitlab-tag github-release; do
    # The strategies of the test tree link to those of the checkout
    rm -f "$TEST_TMPDIR/strategies/$strategy.sh"
    # 2.0.0 and one more major for each token in the environment
    printf '#!/usr/bin/env bash\necho "$((2 + $(env | grep -c "^GITLAB_TOKEN_"))).0.0"\n' \
      >"$TEST_TMPDIR/strategies/$strategy.sh"
    chmod +x "$TEST_TMPDIR/strategies/$strategy.sh"
  done
  create_test_package lab gitlab-tag "upstream:
  host: gitlab.com
  project: group/project
current: '1.0.0'"
  create_test_package hub github-release "upstream:
  project: owner/repo
current: '1.0.0'"
  for var in GITLAB_TOKEN_GITLAB_COM GITLAB_TOKEN_GITLAB_GNOME_ORG GITLAB_TOKEN_GITLAB_FREEDESKTOP_ORG \
    GITLAB_TOKEN_INVENT_KDE_ORG GITLAB_TOKEN_SALSA_DEBIAN_ORG GITLAB_TOKEN_GITLAB_ARCHLINUX_ORG; do
    export "$var=glpat-test"
  done
  [ "$("$TEST_TMPDIR/scripts/check-update.sh" lab 2>/dev/null)" = 8.0.0 ]
  [ "$("$TEST_TMPDIR/scripts/check-update.sh" hub 2>/dev/null)" = 2.0.0 ]
}

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

# curl reads {} and [] of a URL as globs and sends one request for each match
@test "scripts: every curl call turns globs off" {
  local root="$BATS_TEST_DIRNAME/.."
  run grep -rnE '(^|[^A-Za-z_./-])curl +-' "$root/scripts" "$root/strategies" "$root/aurtomator.sh"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -ge 5 ]
  run grep -rnE '(^|[^A-Za-z_./-])curl +-' "$root/scripts" "$root/strategies" "$root/aurtomator.sh"
  run grep -vE 'curl (--globoff|-q?g[A-Za-z]*) ' <<<"$output"
  [ -z "$output" ]
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

# curl follows redirects to ftp too unless told otherwise
@test "lib.sh: validate_source_urls asks over http and https alone, redirects included" {
  cat >"$TEST_TMPDIR/PKGBUILD" <<'EOF'
pkgname=test-proto
pkgver=1.0.0
pkgrel=1
arch=('x86_64')
source=("https://example.com/test-1.0.0.tar.gz" "http://example.com/test-1.0.0.patch")
sha256sums=('abc123' 'abc123')
EOF
  cat >"$MOCK_DIR/curl" <<MOCKCURL
#!/usr/bin/env bash
echo "\$*" >>"$TEST_TMPDIR/curl-args.log"
printf '200 application/octet-stream'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"
  run bash -c 'source "$0/scripts/lib.sh"; validate_source_urls "$1"' "$TEST_TMPDIR" "$TEST_TMPDIR/PKGBUILD"
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$TEST_TMPDIR/curl-args.log")" -eq 2 ]
  [ "$(grep -c -v -e ' --proto =http,https --proto-redir =http,https ' "$TEST_TMPDIR/curl-args.log")" -eq 0 ]
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

@test "arch.sh: arch_urls keeps the digits of arch names that hold the old version" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  printf '%s\n' 'pkgbase = demo' $'\tpkgver = 64' $'\tarch = x86_64' $'\tarch = aarch64' \
    $'\tsource_aarch64 = https://example.com/v64/demo-64-aarch64-x86_64.tar.gz' >"$TEST_TMPDIR/.SRCINFO"
  run arch_urls "$TEST_TMPDIR/.SRCINFO" aarch64 64 65 "" "" "" "" ""
  [ "$output" = https://example.com/v65/demo-65-aarch64-x86_64.tar.gz ]
  printf '\tsource_armv7h = %s\n' https://example.com/7/demo-armv7h.tar.gz >"$TEST_TMPDIR/.SRCINFO"
  run arch_urls "$TEST_TMPDIR/.SRCINFO" armv7h 7 8 "" "" "" "" ""
  [ "$output" = https://example.com/8/demo-armv7h.tar.gz ]
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

# 429 and 5xx tell nothing about the archive, and their error pages are HTML
@test "arch.sh: probe_url tells a file from a missing one, from no answer and from another error" {
  local entry rc expected
  local -a cases=(
    "0|0|200 application/octet-stream"
    "0|0|399 application/gzip"
    "0|1|404 text/html; charset=utf-8"
    "0|1|410 application/octet-stream"
    "0|1|200 Text/HTML; charset=utf-8"
    "0|3|400 application/octet-stream"
    "0|3|403 application/xml"
    "0|3|429 text/html; charset=utf-8"
    "0|3|503 text/html"
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
    if ((rc == 3)); then
      [ "$PROBE_CODE" = "${CURL_W%% *}" ]
    fi
  done
  [ ! -e "$TEST_TMPDIR/pwned" ]
  [ "$(head -1 "$TEST_TMPDIR/curl.args")" = "--globoff -sIL -o /dev/null -w %{http_code} %{content_type} --max-time 10 --max-redirs 5 --proto =https --proto-redir =https https://example.com/demo-aarch64.tar.gz" ]
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
  # The answer goes to a file, which curl truncates before a retry
  [ "${output%% -o *}" = '--globoff -sfL --max-time 30 --retry 2 --retry-delay 5 --retry-connrefused --retry-max-time 75 --proto =https --proto-redir =https --max-filesize 50M -A aurtomator/1.0 -w %{onerror}%{stderr}%{url_effective}\t%{errormsg}\t%{http_code}\t%header{cf-mitigated}' ]
  [[ "${output#* -o }" =~ ^/[^\ ]+\ --max-redirs\ 5\ https://example\.invalid/a$ ]]
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
  CURL_RC=3 CURL_STDERR='' run http_get 'https://example.invalid/[bad'
  [ "$status" -eq 3 ]
  [ "$output" = "https://example.invalid/[bad: curl exit 3" ]
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

# curl maps such a host to an ASCII host through IDNA, and url_host gives it none
@test "lib.sh: http_get refuses a host with a character beyond ASCII before curl runs" {
  keep_host_memory
  timeout_curl
  source "$TEST_TMPDIR/scripts/lib.sh"
  local url
  for url in 'https://ＧＩＴＨＵＢ.com/x' 'https://github。com/x' 'https://exÉmple.com/x'; do
    run http_get "$url"
    [ "$status" -ne 0 ]
    [ "$output" = "$url: the host holds a character beyond ASCII" ]
  done
  [ ! -e "$TEST_TMPDIR/curl.log" ]
}

# curl reads a host out of each of these that url_host cannot name, so the host memory cannot hold it
@test "lib.sh: http_get refuses an https URL whose host is no plain name, before curl runs" {
  keep_host_memory
  timeout_curl
  source "$TEST_TMPDIR/scripts/lib.sh"
  local url
  for url in 'https:///example.com/x' 'https:/example.com/x' 'https://api.git%68ub.com/x' 'https://a\@b/x'; do
    run http_get "$url"
    [ "$status" -ne 0 ]
    [ "$output" = "$url: the host is no plain name of ASCII letters, digits, dots and dashes" ]
  done
  [ ! -e "$TEST_TMPDIR/curl.log" ]
  # Ports, and letters beyond ASCII after the host, reach curl
  for url in https://git.example.com:8443/x https://example.com/caf$'\xc3\xa9'; do
    run http_get "$url"
    [ "$status" -eq 0 ]
    grep -qF -- "$url" "$TEST_TMPDIR/curl.log"
  done
}

# curl takes HTTPS in any case, and the port form holds digits right after the host alone
@test "lib.sh: http_get refuses HTTPS in capitals and ports beyond the host, before curl runs" {
  keep_host_memory
  timeout_curl
  source "$TEST_TMPDIR/scripts/lib.sh"
  local url
  for url in 'HTTPS:///example.com/x' 'Https://a\@b/x' 'https:///x:80' 'https://h:' 'https://h:80x' 'https://a\@b:80x'; do
    run http_get "$url"
    [ "$status" -ne 0 ] && [ "$output" = "$url: the host is no plain name of ASCII letters, digits, dots and dashes" ] || {
      echo "taken: $url"
      echo "$output"
      return 1
    }
  done
  [ ! -e "$TEST_TMPDIR/curl.log" ]
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
@test "check-all: checks no package whose name is not its file name, and fails it under the file name" {
  create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo"
  sed -i 's|^name: mypkg$|name: ../escape|' "$TEST_TMPDIR/packages/mypkg.yml"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [[ "$output" == *"packages/mypkg.yml: name '../escape' must equal the file name"* ]]
  [ ! -e "$TEST_TMPDIR/escape" ]
  [ "$(cat "$TEST_TMPDIR/.status/mypkg")" = "check_failed: packages/mypkg.yml: name '../escape' must equal the file name" ]
}

# _packages and the status files carry one name a line, of the characters of an AUR name, and
# the records of a run take the names that start with _
@test "check-all: checks and lists a file only under a stem of an AUR package name" {
  local stem
  local -a stems=($'a\nb' -x _assets Demo @x +x x@y)
  ! locale -a 2>/dev/null | grep -qix 'en_US.utf8' || stems+=(fée)
  stand_in_strategy step 2.0.0
  create_test_package "pkg" "step" "current: '1.0.0'"
  for stem in "${stems[@]}"; do
    printf 'name: %s\nstrategy: step\ncurrent: 1.0.0\n' "${stem@Q}" >"$TEST_TMPDIR/packages/$stem.yml"
  done
  LC_ALL=en_US.UTF-8 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"packages/'_assets'.yml: the name must start with a-z or 0-9 and hold only a-z, 0-9 and . _ + -"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/_packages")" = pkg ]
  [ ! -e "$TEST_TMPDIR/.status/_assets" ]
  [ "$(find "$TEST_TMPDIR/.status" -mindepth 1 -maxdepth 1 ! -name '_*' -printf '%f\n')" = pkg ]
}

@test "check-all: keeps one run cache for the checks of a run and removes it at the end" {
  printf '#!/usr/bin/env bash\necho "$AURTOMATOR_RUN_CACHE" >>"%s/run-cache"\n[[ -d "$AURTOMATOR_RUN_CACHE" ]] || exit 1\necho 1.0.0\n' \
    "$TEST_TMPDIR" >"$TEST_TMPDIR/strategies/cache.sh"
  chmod +x "$TEST_TMPDIR/strategies/cache.sh"
  create_test_package "one" "cache" "current: '1.0.0'"
  create_test_package "two" "cache" "current: '1.0.0'"
  AURTOMATOR_RUN_CACHE="$TEST_TMPDIR/stale" run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(sort -u "$TEST_TMPDIR/run-cache" | wc -l)" -eq 1 ]
  [ "$(wc -l <"$TEST_TMPDIR/run-cache")" -eq 2 ]
  [ "$(<"$TEST_TMPDIR/run-cache")" != "$TEST_TMPDIR/stale"* ]
  [ ! -e "$(head -1 "$TEST_TMPDIR/run-cache")" ]
}

# The records of a run split their lines at tabs, and git prints the error text of a server with tabs
@test "check-all: writes the error of a failed check with a space for each tab and control character" {
  printf '#!/usr/bin/env bash\nprintf "remote error\\n\\tliq\\t2.5.0\\033[1m\\n" >&2\nexit 1\n' >"$TEST_TMPDIR/strategies/fail.sh"
  chmod +x "$TEST_TMPDIR/strategies/fail.sh"
  create_test_package "pkg" "fail" "current: '1.0.0'"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_TMPDIR/.status/pkg")" == "check_failed: "*$'remote error\n liq 2.5.0 [1m\n'* ]]
  ! grep -q $'[\t\033]' "$TEST_TMPDIR/.status/pkg"
}

# The check, the README and publish fail a YAML that YAML cannot read under its file name and go
# on with the other packages, and prepare hands over no status for it
@test "check-all: fails a YAML it cannot read under its file name and goes on with the others" {
  stand_in_strategy step 2.0.0
  create_test_package "pkg" "step" "current: '1.0.0'"
  printf 'name: [broken\n' >"$TEST_TMPDIR/packages/bad.yml"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/bad")" = "check_failed: packages/bad.yml: name '' must equal the file name" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "new_version: 2.0.0" ]

  printf '%s\n' "# test" "<!-- PACKAGES:START -->" "<!-- PACKAGES:END -->" >"$TEST_TMPDIR/README.md"
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF '<tr><td><a href="https://aur.archlinux.org/pkgbase/bad">bad</a></td><td>-</td><td nowrap>-</td><td nowrap>-</td><td nowrap>❌ failed</td></tr>' "$TEST_TMPDIR/README.md"
  grep -qF '<td nowrap>✨ 2.0.0 available</td>' "$TEST_TMPDIR/README.md"

  printf 'up_to_date\n' >"$TEST_TMPDIR/.status/pkg"
  run "$TEST_TMPDIR/scripts/check-all.sh" --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/bad")" = "check_failed: packages/bad.yml: name '' must equal the file name" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "up_to_date" ]

  rm -rf "$TEST_TMPDIR/.status"
  mkdir -p "$TEST_TMPDIR/.status"
  printf 'new_version: 2.0.0\n' >"$TEST_TMPDIR/.status/pkg"
  run "$TEST_TMPDIR/scripts/check-all.sh" --prepare "$TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/out/status/bad" ]
}

# The statuses and the issues of such a YAML go by its file name
@test "update-readme: names the row of a link or of a YAML under another name by its file" {
  printf "name: old-name\nstrategy: github-release\ncurrent: '3.0'\n" >"$TEST_TMPDIR/packages/renamed.yml"
  printf "name: linked\nstrategy: github-release\ncurrent: '1.0'\n" >"$TEST_TMPDIR/outside.yml"
  ln -s "$TEST_TMPDIR/outside.yml" "$TEST_TMPDIR/packages/linked.yml"
  # The jobs hand builder such a YAML as a link to itself
  ln -s loop.yml "$TEST_TMPDIR/packages/loop.yml"
  echo "check_failed: packages/renamed.yml: name 'old-name' must equal the file name" >"$TEST_TMPDIR/.status/renamed"
  echo "check_failed: packages/linked.yml is a link, and the runs read regular files alone" >"$TEST_TMPDIR/.status/linked"
  echo "check_failed: packages/loop.yml is a link, and the runs read regular files alone" >"$TEST_TMPDIR/.status/loop"
  printf '%s\n' "# test" "<!-- PACKAGES:START -->" "<!-- PACKAGES:END -->" >"$TEST_TMPDIR/README.md"
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF '<tr><td><a href="https://aur.archlinux.org/pkgbase/renamed">renamed</a></td><td>-</td><td nowrap>-</td><td nowrap>-</td><td nowrap>❌ failed</td></tr>' "$TEST_TMPDIR/README.md"
  grep -qF '<tr><td><a href="https://aur.archlinux.org/pkgbase/linked">linked</a></td><td>-</td><td nowrap>-</td><td nowrap>-</td><td nowrap>❌ failed</td></tr>' "$TEST_TMPDIR/README.md"
  grep -qF '<tr><td><a href="https://aur.archlinux.org/pkgbase/loop">loop</a></td><td>-</td><td nowrap>-</td><td nowrap>-</td><td nowrap>❌ failed</td></tr>' "$TEST_TMPDIR/README.md"
  run grep -c old-name "$TEST_TMPDIR/README.md"
  [ "$output" = "0" ]
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
  locale -a 2>/dev/null | command grep -qix 'en_US.utf8' || locale_needed "no en_US.UTF-8 locale"
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

@test "lib.sh: a URL with a user name in it remembers no host" {
  keep_host_memory
  source "$TEST_TMPDIR/scripts/lib.sh"
  remember_host 'https://api.github.com@silent.example/a'
  [ ! -s "$AURTOMATOR_HOSTS_DIR/silent" ]
  remember_host 'https://silent.example/a'
  [ "$(cat "$AURTOMATOR_HOSTS_DIR/silent")" = silent.example ]
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

# curl retries a transfer that its time limit cut, and on stdout the retry follows the piece of the cut one
@test "lib.sh: http_get prints the answer of a retry alone" {
  local port i
  port=$(shuf -i 20000-40000 -n 1)
  python3 -I "$TESTS_DIR/helpers/cut-server.py" "$port" "$TEST_TMPDIR/ready" >/dev/null 2>&1 3>&- &
  for i in $(seq 50); do
    [[ ! -e "$TEST_TMPDIR/ready" ]] || break
    sleep 0.1
  done
  printf '#!/bin/sh\nexec /usr/bin/curl "$@"\n' >"$MOCK_DIR/curl"
  source "$TEST_TMPDIR/scripts/lib.sh"
  run http_get "http://127.0.0.1:$port/" --proto =http --proto-redir =http --max-time 2 --retry-delay 1
  wait
  [ "$status" -eq 0 ]
  [ "$output" = BBBBBBBBBB ]
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

# yq reads YAML too, and a YAML map would pass for a JSON object
@test "lib.sh: http_get_json refuses an answer in YAML" {
  cat >"$MOCK_DIR/curl" <<'MOCKCURL'
#!/usr/bin/env bash
printf 'error: rate limited\nretry: later\n\nhttps://example.com/a'
MOCKCURL
  chmod +x "$MOCK_DIR/curl"
  source "$TEST_TMPDIR/scripts/lib.sh"
  run http_get_json https://example.com/a
  [ "$status" -eq 1 ]
  [ "$output" = "https://example.com/a: the answer is not JSON" ]
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
  [ "$(cat "$TEST_TMPDIR/git.log")" = "-c http.lowSpeedLimit=102400 -c http.lowSpeedTime=60 ls-remote --tags --refs https://git.example/repo.git|https://git.example/repo.git https://git.example/repo.git/info/refs?service=git-upload-pack
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
  for rule in "hold: true|alerts[0] must hold exactly one of when, from, match, requires" \
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

# Helper: runs fired_alerts with the arguments $@ and the mock pacman, stderr apart
run_alerts() {
  use_mock_pacman
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$@"' "$TEST_TMPDIR" "$@"
}

# The rules unmet and imports run by default after the listed ones and print lines of their own
@test "lib.sh: fired_alerts fires a requires rule with the change of the requirements as its note" {
  python_aur pkg
  create_test_package "pkg" "pypi" "upstream:
  registry: zensical
alerts:
  - requires: changed
    hold: true"
  run_alerts "$TEST_TMPDIR/packages/pkg.yml" 0.0.74 0.1.3
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'hold\tdrops deepmerge' ]
  create_test_package "pkg" "pypi" "upstream:
  registry: zensical
alerts:
  - requires: changed
    note: Check the depends of the PKGBUILD"
  run_alerts "$TEST_TMPDIR/packages/pkg.yml" 0.0.74 0.1.3
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'notice\tCheck the depends of the PKGBUILD: drops deepmerge' ]
}

@test "lib.sh: fired_alerts leaves a requires rule on matching names and runs it with current alone" {
  python_aur pkg
  create_test_package "pkg" "pypi" "upstream:
  registry: zensical
alerts:
  - requires: changed
    hold: true"
  run_alerts "$TEST_TMPDIR/packages/pkg.yml" 0.1.2 0.1.3
  [ "$status" -eq 0 ]
  [[ "$output" != *adds* && "$output" != *drops* && "$output" != hold* ]]
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run_alerts "$TEST_TMPDIR/packages/pkg.yml" "" 0.1.3
  [ "$status" -eq 0 ]
  [[ "$output" != *adds* && "$output" != *drops* && "$output" != hold* ]]
  ! grep -q 'zensical-0.1.2' "$CURL_ARGS_LOG"
}

@test "lib.sh: fired_alerts offline asks PyPI nothing and evaluates the other rules" {
  create_test_package "pkg" "pypi" "upstream:
  registry: zensical
alerts:
  - requires: changed
    hold: true
  - from: '0.1'
    note: New minor"
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run_requires 'fired_alerts "$1" 0.0.74 0.1.3 offline' "$TEST_TMPDIR/packages/pkg.yml"
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\tNew minor' ]
  [ ! -e "$CURL_ARGS_LOG" ]
}

@test "lib.sh: fired_alerts fails when a request of a requires rule fails" {
  python_aur pkg
  create_test_package "pkg" "pypi" "upstream:
  registry: zensical
alerts:
  - requires: changed
    hold: true"
  run_requires 'fired_alerts "$1" 0.1.3 0.1.4' "$TEST_TMPDIR/packages/pkg.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"zensical: PyPI has no release 0.1.4"* ]]
}

@test "lib.sh: fired_alerts fails on a requires rule other than its values or without a source" {
  create_test_package "pkg" "pypi" "upstream:
  registry: zensical
alerts:
  - requires: always"
  run_requires 'fired_alerts "$1" 0.0.74 0.1.3' "$TEST_TMPDIR/packages/pkg.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"alerts[0].requires must be changed, unmet or imports, got always"* ]]
  create_test_package "pkg" "npm" "upstream:
  registry: express
alerts:
  - requires: changed"
  run_requires 'fired_alerts "$1" 4.0.0 5.0.0' "$TEST_TMPDIR/packages/pkg.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"alerts[0].requires needs strategy pypi or rubygems, python.pypi, python.pyproject or ruby.gem"* ]]
}

@test "lib.sh: fired_alerts asks for quotes around a note that YAML reads as a number" {
  create_test_package "pkg" "github-release" "alerts:
  - from: '0.4.0'
    note: 2024"
  run bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" 0.3 29+1' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/pkg.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"alerts[0].note must be one line of text: put 2024 in quotes"* ]]
}

# === pep440.sh ===

# Helper: checks pep440_cmp on lines of "a b order" in one shell, and prints the lines that fail
check_order() {
  run bash -c 'source "$0/scripts/lib.sh"
    for line in "$@"; do
      read -r a b want <<<"$line"
      if ! pep440_cmp "$a" "$b"; then echo "$line: fails"; elif [[ "$PEP440_ORDER" != "$want" ]]; then echo "$line: $PEP440_ORDER"; fi
    done' "$TEST_TMPDIR" "$@"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Helper: checks pep440_holds on lines of "version spec status" in one shell
check_holds() {
  run bash -c 'source "$0/scripts/lib.sh"
    for line in "$@"; do
      read -r v spec want <<<"$line"
      rc=0
      pep440_holds "$v" "$spec" || rc=$?
      [[ "$rc" == "$want" ]] || echo "$line: $rc"
    done' "$TEST_TMPDIR" "$@"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pep440.sh: pep440_parse sets the parts of a version" {
  run bash -c 'source "$0/scripts/lib.sh"
    for v in "$@"; do
      pep440_parse "$v" || { echo "$v: fails"; continue; }
      echo "$PV_EPOCH|$PV_RELEASE|$PV_PRE_L|$PV_PRE_N|$PV_POST|$PV_DEV|$PV_LOCAL"
    done' "$TEST_TMPDIR" '1!2.0rc3.post4.dev5+Local-7_x' '01.002' 'v1.0-1' '1.0.dev' '1.0a' '1.0c1' 'V1.0.PRE1' \
    '1.0post' '1.0r' '1.0.post-1' ' 2.0 ' '1.0_alpha_1' '1.0-preview-2' '1.0.beta.2'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' '1|2.0|rc|3|4|5|local.7.x' '0|1.2|||||' '0|1.0|||1||' '0|1.0||||0|' \
    '0|1.0|a|0|||' '0|1.0|rc|1|||' '0|1.0|rc|1|||' '0|1.0|||0||' '0|1.0|||0||' '0|1.0|||1||' \
    '0|2.0|||||' '0|1.0|a|1|||' '0|1.0|rc|2|||' '0|1.0|b|2|||')" ]
}

@test "pep440.sh: pep440_parse refuses versions outside PEP 440" {
  local v
  for v in 1.0- a1 1..0 1.0+ r675.70e1dda 1.0+_a '1!' '' '1.0 1' $'1.0\n'; do
    run bash -c 'source "$0/scripts/lib.sh"; pep440_parse "$1"' "$TEST_TMPDIR" "$v"
    [ "$status" -eq 1 ] || {
      echo "${v@Q}: $status"
      return 1
    }
  done
  run bash -c 'source "$0/scripts/lib.sh"; pep440_cmp 1.0 r675.70e1dda' "$TEST_TMPDIR"
  [ "$status" -eq 1 ]
}

@test "pep440.sh: pep440_cmp orders the examples of PEP 440" {
  local -a chain=(1.0.dev456 1.0a1 1.0a2.dev456 1.0a12.dev456 1.0a12 1.0b1.dev456 1.0b2 1.0b2.post345.dev456
    1.0b2.post345 1.0rc1.dev456 1.0rc1 1.0 1.0+abc.5 1.0+abc.7 1.0+5 1.0.post456.dev34 1.0.post456 1.0.15 1.1.dev1)
  local -a lines=()
  local i j
  for ((i = 0; i < ${#chain[@]}; i++)); do
    lines+=("${chain[i]} ${chain[i]} 0")
    for ((j = i + 1; j < ${#chain[@]}; j++)); do
      lines+=("${chain[i]} ${chain[j]} -1" "${chain[j]} ${chain[i]} 1")
    done
  done
  check_order "${lines[@]}"
}

@test "pep440.sh: pep440_cmp reads every spelling and number size" {
  check_order "3.14 3.14.0 0" "1.0a 1.0a0 0" "1.0-1 1.0.post1 0" "1.0.REV2 1.0.post2 0" "v1.0 1.0 0" \
    "1!1.0 2.0 1" "0.66b2 0.66 -1" "2.9.0 2.9.0.post0 -1" "18446744073709551617 18446744073709551616 1" \
    "1.0+abc 1.0+ABC 0" "1.0+1.a 1.0+1.b -1" "1.0+a.1 1.0+1 -1" "1.0+1.0 1.0+1 1" "1.0c1 1.0rc1 0" \
    "1.0.pre1 1.0rc1 0" "1.0-preview-1 1.0rc1 0" "1.0_alpha_1 1.0a1 0" "1.0.dev 1.0.dev0 0" \
    "3.14.10 3.14.9 1" "3.14.0rc2 3.14.0rc10 -1" "03.014 3.14 0" "1.0a1 1.0.0a01 0" "1 1.0.0.0 0" "2 10 -1" \
    "1.0+01 1.0+1 0" "1.0+1.post 1.0+1.post 0"
}

@test "pep440.sh: pep440_holds evaluates every operator as packaging does" {
  check_holds "1.0 ==1.0 0" "1.0.0 ==1.0 0" "1.1 ==1.0 1" "1.0+local.1 ==1.0 0" "1.0+local.1 ==1.0+local.2 1" \
    "1.0+local.1 ==1.0+local.1 0" "1.0 ==1.0+local.1 1" "0.66b2 ==0.66b2 0" "1.0 !=1.0 1" "1.1 !=1.0 0" \
    "1.0+local.1 !=1.0 1" "1.4.5 ==1.4.* 0" "1.4 ==1.4.* 0" "1.4rc1 ==1.4.* 0" "1.4.post1 ==1.4.* 0" \
    "1.5 ==1.4.* 1" "1.40 ==1.4.* 1" "1!1.4 ==1.4.* 1" "1!1.4.2 ==1!1.4.* 0" "1.4 ==1.4.0.* 0" \
    "1.4.5 !=1.4.* 1" "1.5 !=1.4.* 0" "1.0 <1.1 0" "1.1 <1.1 1" "1.1a1 <1.1 1" "1.1.dev1 <1.1 1" \
    "1.0a1 <1.1 0" "1.1a1 <1.1rc1 0" "1.1 <=1.1 0" "1.1+local <=1.1 0" "1.2 <=1.1 1" "1.2 >1.1 0" \
    "1.1 >1.1 1" "1.1.post1 >1.1 1" "1.1+local >1.1 1" "1.1.post2 >1.1.post1 0" "1.2+local >1.1 0" \
    "1.1 >=1.1 0" "1.0 >=1.1 1" "1.1+local >=1.1 0" "1.4.5 ~=1.4 0" "2.0 ~=1.4 1" "1.3 ~=1.4 1" \
    "1.4.5 ~=1.4.2 0" "1.5 ~=1.4.2 1" "1.4.2rc1 ~=1.4.2 1" "1.4.2rc2 ~=1.4.2rc1 0" \
    "1.44.9 <1.45.0,>=1.44.10 1" "1.44.10 <1.45.0,>=1.44.10 0" "1.4.1 <1.4,>=1.1.0 1" "1.0 ===1.0 0" \
    "1.0.0 ===1.0 1" "1.0a1 ===1.0A1 0" "1.2+abc.1 >1.2b0.post0 0" "1.2+abc >1.2 1" "1.2.post1+x >1.2 1" \
    "1.2b0+x >1.2b0 1" "1.2.post1 >1.2b0 0" "1.2.post1 >1.2.dev0 0" "1.2b0.post1 >1.2b0 1" "1.2b1 >1.2b0 0"
  # packaging 26 reads <V as <V.dev0 for a V of no pre-release, and === against the normal form of the version
  check_holds "1.0a1 <1.0.post1 0" "1.0.dev1 <1.0.post0 0" "1.0rc1.post1 <1.0.post1 0" "1.0.post1.dev1 <1.0.post1 1" \
    "1.0.post0.dev5 <1.0.post1 0" "1.0+x <1.0.post1 0" "1.0.post1 <1.0.post1 1" "1.0a1 <1.0 1" "1.0-1 ===1.0.post1 0" \
    "1.0.post1 ===1.0-1 1" "v1.0 ===1.0 0" "1.0+01 ===1.0+1 0" "01.0 ===1.0 0" "1!1.0 ===1!1.0 0" "1.0_alpha_1 ===1.0a1 0"
}

@test "pep440.sh: pep440_holds returns 2 for a clause it cannot read, 0 for no clause" {
  check_holds "2.0 =<1 2" "2.0 ~=1 2" "2.0 <1.0.* 2" "2.0 <1.0+local 2" "2.0 ==1.0a1.* 2" "2.0 ~=1.0+local 2" \
    "2.0 ==1.0.*.* 2" "2.0 >=1.0,, 2" "2.0 >=x 2" "r675.70e1dda >=1.0 2" "2.0 >=1.0,<x 2"
  run bash -c 'source "$0/scripts/lib.sh"; pep440_holds 2.0 ""' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
}

# === gemver.sh ===

# Helper: checks gem_cmp on lines of "a b order" in one shell, both ways, and prints the lines that fail
check_gem_order() {
  run bash -c 'source "$0/scripts/lib.sh"
    for line in "$@"; do
      read -r a b want <<<"$line"
      if ! gem_cmp "$a" "$b"; then echo "$line: fails"; elif [[ "$GEM_ORDER" != "$want" ]]; then echo "$line: $GEM_ORDER"; fi
      if ! gem_cmp "$b" "$a"; then echo "$line: fails back"; elif [[ "$GEM_ORDER" != "$((0 - want))" ]]; then echo "$line back: $GEM_ORDER"; fi
    done' "$TEST_TMPDIR" "$@"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Helper: checks gem_holds on lines of "version|requirements|status" in one shell
check_gem_holds() {
  run bash -c 'source "$0/scripts/lib.sh"
    for line in "$@"; do
      IFS="|" read -r v req want <<<"$line"
      rc=0
      gem_holds "$v" "$req" || rc=$?
      [[ "$rc" == "$want" ]] || echo "$line: $rc"
    done' "$TEST_TMPDIR" "$@"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Orders and answers of Gem::Version and Gem::Requirement of ruby 3.4.13, read on 2026-11-25
@test "gemver.sh: gem_cmp orders versions as Gem::Version does" {
  check_gem_order "4.0.0.rc1 4.0.0 -1" "1.0 1 0" "1.0.a 1.0 -1" "1.0.a 1.0.b -1" "1.0.a10 1.0.a9 1" \
    "1.0.0.pre 1.0.0.beta 1" "2.0.0 1.99 1" "1.0.1 1.0.a 1" "1.0-1 1.0.0 -1" "1.0-1 1.0.pre.1 0" "1.19.7 1.19.10 -1" \
    "1.0.0.rc1 1.0.0.rc10 -1" "1.0a 1.0.a 0" "01.002 1.2 0" "1.0.0.0 1 0" "3.4.0.preview1 3.4.0 -1" \
    "18446744073709551617 18446744073709551616 1" "1.0.b1 1.0.a2 1" "1.0.rc 1.0.rc0 0"
}

@test "gemver.sh: gem_segments gives the canonical segments, and gem_version_valid the versions RubyGems reads" {
  run bash -c 'source "$0/scripts/lib.sh"; for v in 4.0.0.rc1 1.0.0 1.0-1 01.002 1.0a10 1.0.0.0.a; do gem_segments "$v"; echo "${GEM_SEG[*]}"; done' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = $'4 rc 1\n1\n1 pre 1\n1 2\n1 a 10\n1 a' ]
  run bash -c 'source "$0/scripts/lib.sh"; for v in "$@"; do gem_version_valid "$v" && echo "$v: yes" || echo "$v: no"; done' "$TEST_TMPDIR" \
    1.0 1.0-1 1.0-pre-1 1.0.a-1 a1 1..0 '1.0 ' '' 1.0- r675.70e1dda 1.0+1 1.0_1
  [ "$output" = $'1.0: yes\n1.0-1: yes\n1.0-pre-1: yes\n1.0.a-1: yes\na1: no\n1..0: no\n1.0 : no\n: no\n1.0-: no\nr675.70e1dda: no\n1.0+1: no\n1.0_1: no' ]
}

@test "gemver.sh: gem_holds evaluates the requirements of rubygems.org as Gem::Requirement does" {
  check_gem_holds "1.3.2|~> 1.1|0" "1.1.9|~> 1.1|0" "2.0|~> 1.1|1" "1.0.0|~> 1.1|1" "1.1.9|~> 1.1.0|0" "1.3.2|~> 1.1.0|1" \
    "1.3.2|~> 0.21|1" "0.22.0|~> 0.21|0" "1.0.0|~> 1.0.0.rc1|0" "1.1|~> 1.0.0.rc1|1" "1.3.2|~> 1.1, >= 1.2|0" \
    "1.1.5|~> 1.1, >= 1.2|1" "1.0|= 1.0|0" "1.0.0|= 1.0|0" "1.0.1|= 1.0|1" "1.0|!= 1.0|1" "1.1|!= 1.0|0" "1.1|> 1.0|0" \
    "1.0|> 1.0|1" "0.9|< 1.0|0" "1.0|< 1.0|1" "1.0|>= 1.0|0" "0.9|>= 1.0|1" "1.0|<= 1.0|0" "1.1|<= 1.0|1" \
    "3.4.13|>= 3.2.0|0" "3.4.13|>= 3.5|1" "1.0|>= 0|0" "1.0.rc1|>= 0|0" "1.0|1.0|0" "2.0|~>1.0|1" "2.0|>=1.0|0" \
    "4.0.0.rc1|~> 4.0|1" "1.0|~> 1|0" "2.5|~> 2|0" "3.0|~> 2|1"
}

@test "gemver.sh: gem_holds returns 2 for text outside the grammar and names the upper bounds of ~> that fail" {
  check_gem_holds "2.0|=< 1|2" "2.0|>= x|2" "r675.70e1dda|>= 1.0|2" "2.0|>= 1.0,, < 3|2" "2.0||0"
  run bash -c 'source "$0/scripts/lib.sh"
    gem_holds 1.3.2 "~> 0.21" || echo "$GEM_FAILED|$GEM_TILDE_UPPER"
    gem_holds 0.20 "~> 0.21" || echo "$GEM_FAILED|$GEM_TILDE_UPPER"
    gem_holds 1.3.2 "~> 0.21, < 1.0" || echo "$GEM_FAILED|$GEM_TILDE_UPPER"' "$TEST_TMPDIR"
  [ "$output" = $'~> 0.21|1\n~> 0.21|\n~> 0.21, < 1.0|' ]
}

@test "gemver.sh: gem_prerelease names versions with a letter" {
  run bash -c 'source "$0/scripts/lib.sh"; for v in 4.0.0.rc1 4.0.0 1.0-1; do gem_prerelease "$v" && echo "$v: pre" || echo "$v: release"; done' "$TEST_TMPDIR"
  [ "$output" = $'4.0.0.rc1: pre\n4.0.0: release\n1.0-1: pre' ]
}

# === requires.sh ===

# Helper: runs bash code $1 with lib.sh sourced and the mock pacman first in PATH; the other
# arguments become $1 and on. Usage: run_requires <code> [arg]...
run_requires() {
  use_mock_pacman
  run bash -c "source \"\$0/scripts/lib.sh\"; $1" "$TEST_TMPDIR" "${@:2}"
}

# Helper: checks marker_value on pairs of an expected value and a marker, in one shell
# Usage: check_markers <value> <marker> [<value> <marker>]...
check_markers() {
  local -a want=() markers=() got=()
  local i
  while (($# > 1)); do
    want+=("$1")
    markers+=("$2")
    shift 2
  done
  run_requires 'for m in "$@"; do marker_value "$m"; done' "${markers[@]}"
  [ "$status" -eq 0 ]
  mapfile -t got <<<"$output"
  for i in "${!markers[@]}"; do
    [ "${got[i]-}" = "${want[i]}" ] || {
      echo "${markers[i]}: got ${got[i]-nothing}, want ${want[i]}"
      return 1
    }
  done
  [ "${#got[@]}" -eq "${#markers[@]}" ]
}

# Helper: prints the fields that requirement_split sets for requirement $1
run_split() {
  run_requires 'requirement_split "$1" && printf "%s\n" "name=$REQ_NAME" "spec=$REQ_SPEC" "marker=$REQ_MARKER"' "$1"
}

@test "requires.sh: pypi_name gives the PEP 503 form of a name" {
  local name
  for name in Friendly-Bard friendly.bard Friendly_Bard FrIeNdLy-._.-bArD friendly--bard; do
    run_requires 'pypi_name "$1"' "$name"
    [ "$status" -eq 0 ]
    [ "$output" = friendly-bard ] || {
      echo "$name: $output"
      return 1
    }
  done
  run_requires 'pypi_name "$1"' svg.path
  [ "$output" = svg-path ]
  run_requires 'pypi_name "$1"' A
  [ "$output" = a ]
}

@test "requires.sh: pypi_name refuses a name outside the name rule of PyPI" {
  local name
  for name in -x x- .x x_ "a b" "" zensical/ui "$(printf 'caf\xc3\xa9')"; do
    run_requires 'pypi_name "$1"' "$name"
    [ "$status" -eq 1 ] || {
      echo "took: $name"
      return 1
    }
    [ -z "$output" ]
  done
}

@test "requires.sh: requirement_split reads the name, the clauses and the marker" {
  local -a cases=(
    'requests [security,tests] >= 2.8.1, == 2.8.* ; python_version < "3.7"|requests|>=2.8.1,==2.8.*|python_version < "3.7"'
    'zensical-ui==0.0.43|zensical-ui|==0.0.43|'
    'foo (==1.0)|foo|==1.0|'
    'Foo.Bar ( >=1.0 , <2 ) ; os_name == "posix"|foo-bar|>=1.0,<2|os_name == "posix"'
    'pytest!=8.1.*,>=6; extra == "test"|pytest|!=8.1.*,>=6|extra == "test"'
    'pip @ https://example.org/pip-1.3.1.zip ; os_name == "posix"|pip|@|os_name == "posix"'
    'pip@https://example.org/pip-1.3.1.zip|pip|@|'
    'pip @ https://example.org/pip.zip;v=1|pip|@|'
    'jaraco.classes|jaraco-classes||'
    'foo[bar] ; sys_platform == "linux"|foo||sys_platform == "linux"'
    'foo >=1.0,|foo|>=1.0|'
    '  click>=8.1.8  |click|>=8.1.8|'
  )
  local case req name spec marker
  for case in "${cases[@]}"; do
    IFS='|' read -r req name spec marker <<<"$case"
    run_split "$req"
    [ "$status" -eq 0 ] || {
      echo "refused: $req"
      return 1
    }
    [ "$output" = "$(printf '%s\n' "name=$name" "spec=$spec" "marker=$marker")" ] || {
      echo "$req: $output"
      return 1
    }
  done
}

@test "requires.sh: requirement_split reads the extras in PEP 503 form" {
  local -a cases=('requests [security,tests] >= 2.8.1|security,tests' 'httpx[http2]<1.0,>=0.28.0|http2'
    'botocore[CRT] (<2.0a0,>=1.21.0) ; extra == "crt"|crt' 'foo[ a_b , C.d ]|a-b,c-d' 'foo[]|' 'foo|')
  local case req extras
  for case in "${cases[@]}"; do
    IFS='|' read -r req extras <<<"$case"
    run_requires 'requirement_split "$1" && echo "$REQ_EXTRAS"' "$req"
    [ "$status" -eq 0 ] && [ "$output" = "$extras" ] || {
      echo "$req: $status $output"
      return 1
    }
  done
  run_requires 'requirement_split "foo[a b]"'
  [ "$status" -eq 1 ]
}

@test "requires.sh: marker_value takes the extras of MARKER_EXTRAS" {
  export MARKER_EXTRAS=http2,socks
  check_markers \
    1 'extra == "http2"' 1 'extra == "HTTP2"' 0 'extra == "cli"' 1 '"socks" == extra' 0 'extra != "http2"' \
    1 'extra != "cli"' 0 '(platform_python_implementation != "CPython") and extra == "http2"'
}

@test "requires.sh: requirement_split refuses text outside the grammar" {
  local req
  for req in "" "==1.0" "-foo" "foo bar" "foo ==" "foo =1.0" "foo >= 1.0 2.0" "foo,>=1" "foo >=1,," \
    "foo; " "foo ;" "foo (==1.0" "foo ==1.0)" "foo ()" "foo @" "foo @ https://example.org/x.zip ;" \
    "foo @ https://example.org/x.zip junk"; do
    run_split "$req"
    [ "$status" -eq 1 ] || {
      echo "took: $req"
      return 1
    }
  done
}

@test "requires.sh: marker_value gives the string fields their values on Arch" {
  check_markers \
    1 'os_name == "posix"' 0 'os_name == "nt"' \
    1 'sys_platform == "linux"' 0 'sys_platform == "win32"' 0 'sys_platform == "Linux"' \
    1 'platform_system == "Linux"' 0 'platform_system == "Windows"' \
    1 'platform_python_implementation == "CPython"' 0 'platform_python_implementation == "PyPy"' \
    1 'implementation_name == "cpython"' 0 'implementation_name == "pypy"' \
    '?' 'platform_machine == "x86_64"' '?' 'platform_machine != "aarch64"'
}

@test "requires.sh: marker_value compares string fields as the specification says" {
  check_markers \
    1 'sys_platform != "win32"' 0 'sys_platform != "linux"' \
    '?' 'sys_platform ~= "linux"' '?' 'sys_platform === "linux"' \
    1 'sys_platform >= "linux"' 1 'sys_platform <= "linux"' 0 'sys_platform >= "a"' \
    0 'sys_platform > "a"' 0 'sys_platform < "z"' 0 'platform_machine > "a"' 0 'platform_machine < "z"' \
    1 '"lin" in sys_platform' 1 'sys_platform in "linux darwin"' 0 '"win" in sys_platform' \
    1 '"win" not in sys_platform' 0 'sys_platform not in "linux darwin"' '?' '"86" in platform_machine'
}

@test "requires.sh: marker_value compares version fields as PEP 440 does" {
  check_markers \
    1 'python_version >= "3.8"' 0 'python_version < "3.11"' 1 'python_version < "3.15"' \
    1 'python_version == "3.14"' 0 'python_version != "3.14"' 0 'python_version > "3.14"' \
    1 'python_version <= "3.14"' 1 'python_version == "3.14.0"' 1 'python_version == "03.014"' \
    1 'python_full_version == "3.14.10"' 1 'python_full_version >= "3.14.2"' \
    0 'python_full_version < "3.14.9"' 1 'implementation_version == "3.14.10"' \
    1 'python_full_version >= "3.14.0rc1"' 1 'python_full_version < "3.15.0a1"' \
    1 'python_full_version > "3.14.10b2"' 0 'python_full_version >= "3.14.11a1"' \
    1 'python_version < "3.99999999999999999999"' \
    1 'python_full_version === "3.14.10"' 0 'python_version === "3.14.0"' 1 'python_version === "3.14"' \
    1 '"3.14" in python_version' 0 'python_version not in "3.14"' 1 'python_version in "3.14"' \
    0 'python_version in "2.7"' 1 'python_version not in "2.7"' 1 'python_version not in "3.0, 3.1"' \
    1 '"3.1" in python_version' 1 'python_full_version in "3.14.10, 3.15"'
}

@test "requires.sh: marker_value matches version prefixes and compatible releases" {
  check_markers \
    1 'python_version == "3.*"' 1 'python_version == "3.14.*"' 1 'python_full_version == "3.14.*"' \
    0 'python_version == "3.1.*"' 1 'python_version == "3.14.0.*"' 0 'python_version == "3.14.1.*"' \
    0 'python_version != "3.14.*"' 1 'python_full_version != "3.13.*"' \
    1 'python_version ~= "3.10"' 0 'python_version ~= "3.15"' 1 'python_full_version ~= "3.14.0"' \
    0 'python_full_version ~= "3.13.0"' 1 'python_full_version ~= "3.14.0rc1"' \
    '?' 'python_version ~= "3"' '?' 'python_version >= "3.*"' '?' 'python_version == "3.14rc1.*"'
}

@test "requires.sh: marker_value compares every form of PEP 440, and text outside it gives unknown" {
  check_markers \
    0 'python_version >= "3.14.post1"' 1 'python_version < "3.15.dev0"' \
    0 'python_version >= "1!3.0"' 0 'python_version == "3.14+local"' \
    '?' 'python_version >= "foo"' '?' 'python_version >= ""' 1 'python_version >= "v3.14"'
}

@test "requires.sh: marker_value tests the constant against a field on the right" {
  check_markers \
    0 '"3.11" > python_version' 1 '"3.15" > python_version' 1 '"3.14" <= python_version' \
    0 '"3.14" < python_version' 1 '"3.14" == python_version' 0 '"3.14" != python_version' \
    1 '"3.14.10" === python_full_version' '?' '"3.*" == python_version' 0 '"3.10" ~= python_version' \
    1 '"3.14.5" ~= python_version'
}

@test "requires.sh: marker_value reads extra as a field with no extras" {
  check_markers \
    0 'extra == "test"' 0 '"test" == extra' '?' 'extra != "test"' 0 '"test" in extra' 0 'extra > "a"'
}

@test "requires.sh: marker_value gives unknown for fields the check does not know" {
  check_markers \
    '?' 'platform_release >= "5"' '?' '"SMP" in platform_version' '?' 'platform_version == "1"' \
    '?' '"toml" in extras' '?' '"dev" not in dependency_groups' '?' 'foo == "bar"' \
    '?' '"a" == "a"' '?' 'os_name == sys_platform'
}

@test "requires.sh: marker_value joins true, false and unknown with and and or" {
  check_markers \
    1 'sys_platform == "linux" and python_version >= "3.8"' 0 'sys_platform == "linux" and extra == "test"' \
    1 'sys_platform == "win32" or python_version >= "3.8"' 0 'sys_platform == "win32" or os_name == "nt"' \
    0 'platform_machine == "x86_64" and sys_platform == "win32"' \
    '?' 'platform_machine == "x86_64" and sys_platform == "linux"' \
    1 'platform_machine == "x86_64" or sys_platform == "linux"' \
    '?' 'platform_machine == "x86_64" or sys_platform == "win32"' \
    1 'sys_platform == "linux" or sys_platform == "win32" and os_name == "nt"' \
    0 '(sys_platform == "linux" or sys_platform == "win32") and os_name == "nt"' \
    1 '((sys_platform == "linux"))' 0 'sys_platform != "cygwin" and extra == "check"'
}

@test "requires.sh: marker_value reads both quotes and any blanks" {
  check_markers \
    1 "sys_platform == 'linux'" 0 "sys_platform == \"it's\"" 0 "sys_platform == 'say \"hi\"'" \
    1 'sys_platform=="linux"' 1 "$(printf 'sys_platform\t==\t"linux"')" 1 '  sys_platform == "linux"  ' \
    1 '(sys_platform=="linux")and(os_name=="posix")'
}

@test "requires.sh: marker_value gives unknown for text outside the grammar" {
  check_markers \
    '?' '' '?' 'sys_platform' '?' 'sys_platform == "linux' '?' 'sys_platform = "linux"' \
    '?' 'sys_platform == "linux" and' '?' '(sys_platform == "linux"' '?' 'sys_platform == "linux")' \
    '?' 'not sys_platform == "linux"' '?' 'python_version > "3.8" < "3.12"' \
    '?' 'sys_platform == "linux" sys_platform == "linux"' '?' 'Sys_platform == "linux"' \
    '?' 'sys_platform2 == "linux"' '?' 'sys_platform == "linux" or or os_name == "posix"' \
    '?' 'sys_platform notin "linux"'
}

@test "requires.sh: marker_value gives unknown for long, deep and non-ASCII markers" {
  local long='sys_platform == "linux"' deep='sys_platform == "linux"' i
  while ((${#long} + 27 <= 1024)); do long+=' or sys_platform == "linux"'; done
  for ((i = 0; i < 16; i++)); do deep="($deep)"; done
  check_markers \
    1 "$long" '?' "$long or os_name == \"posix\"" 1 "$deep" '?' "($deep)" \
    '?' "$(printf 'sys_platform == "lin\xc3\xbcx"')" '?' "$(printf 'sys_platform == "lin\x01ux"')"
}

@test "requires.sh: marker_value gives unknown for the Python fields without an answer of pacman" {
  export MOCK_PYTHON_FAIL=1
  check_markers \
    '?' 'python_version < "3.11"' '?' 'python_full_version >= "3.8"' \
    0 'python_version < "3.11" and sys_platform == "win32"' '?' '"3" in python_version' 1 'sys_platform == "linux"'
}

@test "requires.sh: marker_value takes the Python of pacman without epoch and pkgrel" {
  export MOCK_PYTHON_VERSION=3.14.0-1
  check_markers 1 'python_full_version == "3.14"' 1 'python_version == "3.14.0"' 0 'python_full_version > "3.14"'
  export MOCK_PYTHON_VERSION=2:3.15.1-3.1
  check_markers 1 'python_version == "3.15"' 1 'python_full_version == "3.15.1"'
  local version
  for version in 3.15.0rc1-1 3.14-1 3.14.10 x; do
    export MOCK_PYTHON_VERSION="$version"
    check_markers '?' 'python_version >= "3"' '?' 'python_full_version >= "3"'
  done
}

@test "requires.sh: requires_names lists the requirements that apply on Arch" {
  run_requires 'requires_names "$(pypi_metadata zensical 0.1.3)" "zensical 0.1.3"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' click jinja2 markdown pathspec pygments pymdown-extensions pyyaml tomli zensical-ui)" ]
  run_requires 'requires_names "$(pypi_metadata zensical 0.0.74)" "zensical 0.0.74"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' click deepmerge jinja2 markdown pathspec pygments pymdown-extensions pyyaml tomli zensical-ui)" ]
  # SecretStorage and jeepney under sys_platform == "linux" stay, pywin32-ctypes and the extras go
  run_requires 'requires_names "$(pypi_metadata keyring 25.7.0)" "keyring 25.7.0"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' jaraco-classes jaraco-context jaraco-functools jeepney secretstorage)" ]
  run_requires 'requires_names "$(pypi_metadata black 26.10.1)" "black 26.10.1"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' click mypy-extensions packaging pathspec platformdirs pytokens)" ]
}

@test "requires.sh: requires_names counts the requirements of an older Python of pacman" {
  export MOCK_PYTHON_VERSION=3.10.12-1
  run_requires 'requires_names "$(pypi_metadata black 26.10.1)" "black 26.10.1"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' click mypy-extensions packaging pathspec platformdirs pytokens tomli typing-extensions)" ]
}

@test "requires.sh: requires_names asks pacman once, and only for a Python field" {
  export PACMAN_ARGS_LOG="$TEST_TMPDIR/pacman-args"
  run_requires 'requires_names "$(pypi_metadata zensical 0.1.3)" "zensical 0.1.3"'
  [ "$status" -eq 0 ]
  [ ! -e "$PACMAN_ARGS_LOG" ]
  run_requires 'requires_names "$(pypi_metadata black 26.10.1)" "black 26.10.1"'
  [ "$status" -eq 0 ]
  [ "$(cat "$PACMAN_ARGS_LOG")" = "-Si python" ]
}

@test "requires.sh: requires_names prints nothing for metadata without Requires-Dist" {
  run_requires 'requires_names "$1" "zensical-ui 0.0.43"' $'Metadata-Version: 2.4\nName: zensical-ui\nVersion: 0.0.43'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# PyPI answers requires_dist null for aws-xray-sdk 2.15.0, and its wheel metadata lists two
@test "requires.sh: requires_names reads the requirements of the metadata of a wheel" {
  run_requires 'requires_names "$(pypi_metadata aws-xray-sdk 2.15.0)" "aws-xray-sdk 2.15.0"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' botocore wrapt)" ]
}

@test "requires.sh: requires_names fails on a requirement it cannot read" {
  local -a cases=(
    $'Requires-Dist: click\nRequires-Dist: jinja2\x01x|demo 1.0: Requires-Dist holds a control character: $'"'"'jinja2\001x'"'"
    $'Requires-Dist: click\nRequires-Dist: foo bar|demo 1.0: cannot read the requirement '"'"'foo bar'"'"
    $'Requires-Dist: click\nRequires-Dist:|demo 1.0: cannot read the requirement '"''"
  )
  local case headers message
  for case in "${cases[@]}"; do
    headers=${case%%|*}
    message=${case#*|}
    run_requires 'requires_names "$1" "demo 1.0"' "$headers"
    [ "$status" -eq 1 ] || {
      echo "took: $headers"
      return 1
    }
    [[ "$output" == *"$message" ]] || {
      echo "$headers: $output"
      return 1
    }
  done
}

@test "requires.sh: metadata_field prints the values of a field in any case of its name" {
  run_requires 'metadata_field "$1" requires-dist; metadata_field "$1" Requires-Python; metadata_field "$1" Summary' \
    $'Requires-Dist: a\nrequires-python: >=3.9\nREQUIRES-DIST: b ; extra == "x"\nRequires-Distx: c'
  [ "$status" -eq 0 ]
  [ "$output" = $'a\nb ; extra == "x"\n>=3.9' ]
}

@test "requires.sh: pypi_release finds a release by PEP 440 and reads the simple page once" {
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run_requires 'pypi_release liblinear-official 2.50 && echo "$PYPI_RELEASE" && cut -f1,5 <<<"$PYPI_FILES" | sort &&
    pypi_release Liblinear_Official 2.50.0 && echo "$PYPI_RELEASE"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' 2.50.0 liblinear_official-2.50.0-cp310-cp310-macosx_15_0_x86_64.whl$'\t'64607 \
    liblinear_official-2.50.0-cp310-cp310-win_amd64.whl$'\t'60279 liblinear_official-2.50.0.tar.gz$'\t'48946 2.50.0)" ]
  [ "$(grep -c pypi.org/simple/ "$CURL_ARGS_LOG")" -eq 1 ]
  [[ "$(<"$CURL_ARGS_LOG")" == *" -H Accept: application/vnd.pypi.simple.v1+json "*" https://pypi.org/simple/liblinear-official/" ]]
}

@test "requires.sh: pypi_release leaves out yanked files and fails with 3 for a missing release" {
  pypi_fake demo 1.0 a
  pypi_fake demo 1.0.post1 b
  yq -i -o json '.files[0].yanked = "broken build"' "$MOCK_FILES_DIR/simple/demo.json"
  run_requires 'pypi_release demo 1.0 && printf "%s\n" "$PYPI_FILES"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_requires 'pypi_release demo 1.0.post1 && cut -f1 <<<"$PYPI_FILES"'
  [ "$output" = demo-1.0.post1-py3-none-any.whl ]
  run_requires 'pypi_release zensical 0.1.4'
  [ "$status" -eq 3 ]
  [[ "$output" == *"zensical: PyPI has no release 0.1.4"* ]]
  run_requires 'pypi_release none-such 1.0'
  [ "$status" -eq 1 ]
  [[ "$output" == *"https://pypi.org/simple/none-such/: The requested URL returned error: 404"* ]]
}

@test "requires.sh: pypi_metadata reads the metadata of a none-any wheel first, then one for linux x86_64" {
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run_requires 'pypi_metadata zensical 0.1.3'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nRequires-Dist: zensical-ui==0.0.43'* ]]
  [ "$(grep -c 'zensical-0.1.3-cp311-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64.whl.metadata$' "$CURL_ARGS_LOG")" -eq 1 ]
  [ "$(grep -c 'metadata$' "$CURL_ARGS_LOG")" -eq 1 ]
  pypi_fake demo 1.0 any-dep
  printf 'Metadata-Version: 2.4\nName: demo\nRequires-Dist: linux-dep\n' >"$MOCK_FILES_DIR/demo-1.0-cp314-cp314-manylinux_2_17_x86_64.whl.metadata"
  : >"$MOCK_FILES_DIR/demo-1.0-cp314-cp314-manylinux_2_17_x86_64.whl"
  pypi_fake_file demo 1.0 "$MOCK_FILES_DIR/demo-1.0-cp314-cp314-manylinux_2_17_x86_64.whl" \
    "$(sha256sum "$MOCK_FILES_DIR/demo-1.0-cp314-cp314-manylinux_2_17_x86_64.whl.metadata" | cut -d' ' -f1)"
  yq -i -o json '.files |= reverse' "$MOCK_FILES_DIR/simple/demo.json"
  run_requires 'metadata_field "$(pypi_metadata demo 1.0)" Requires-Dist'
  [ "$status" -eq 0 ]
  [ "$output" = any-dep ]
}

@test "requires.sh: pypi_metadata stops at the body, joins folded lines and strips CR" {
  pypi_fake_metadata demo 1.0 $'Metadata-Version: 2.4\r\nName: demo\r\nRequires-Dist: a;\r\n  python_version >= "3"\r\nRequires-Dist: b\r\n\r\nRequires-Dist: c\r\n'
  run_requires 'pypi_metadata demo 1.0'
  [ "$status" -eq 0 ]
  [ "$output" = $'Metadata-Version: 2.4\nName: demo\nRequires-Dist: a; python_version >= "3"\nRequires-Dist: b' ]
  run_requires 'metadata_field "$(pypi_metadata zensical 0.1.3)" requires-dist | head -1'
  [ "$output" = "click>=8.1.8" ]
}

@test "requires.sh: pypi_metadata fails on metadata that does not match its sha256 or holds control characters" {
  sed 's/anyio/anyiO/' "$FIXTURES_DIR/pypi/metadata/httpx-0.28.1-py3-none-any.whl.metadata" \
    >"$MOCK_FILES_DIR/httpx-0.28.1-py3-none-any.whl.metadata"
  run_requires 'pypi_metadata httpx 0.28.1'
  [ "$status" -eq 1 ]
  [[ "$output" == *"httpx-0.28.1-py3-none-any.whl.metadata does not match its sha256"* ]]
  pypi_fake_metadata demo 1.0 $'Metadata-Version: 2.4\nName: demo\x1b[31m\n'
  run_requires 'pypi_metadata demo 1.0'
  [ "$status" -eq 1 ]
  [[ "$output" == *"demo-1.0-py3-none-any.whl.metadata holds a control character in Name"* ]]
}

# Build backends copy license files into License, and the license texts of the FSF hold form feeds
@test "requires.sh: pypi_metadata reads control characters of headers that no rule reads as spaces" {
  pypi_fake_metadata demo 1.0 $'Metadata-Version: 2.4\nName: demo\nLicense: GPL\n        \x0c\n        more\xc2\x85\nRequires-Dist: click\n'
  run_requires 'pypi_metadata demo 1.0'
  [ "$status" -eq 0 ]
  [ "$output" = $'Metadata-Version: 2.4\nName: demo\nLicense: GPL  more \nRequires-Dist: click' ]
  local header n=0
  for header in Metadata-Version Name Version Requires-Dist Requires-Python Dynamic; do
    n=$((n + 1))
    pypi_fake_metadata demo 2.$n $'Metadata-Version: 2.4\nName: demo\n'"$header"$': x\n        \x0c\n'
    run_requires 'pypi_metadata demo 2.'$n
    [ "$status" -eq 1 ]
    [[ "$output" == *"demo-2.$n-py3-none-any.whl.metadata holds a control character in $header"* ]]
  done
}

@test "requires.sh: pypi_metadata reads PKG-INFO of an sdist from Metadata-Version 2.2 on" {
  pypi_fake_sdist demo 1.0 $'Metadata-Version: 2.2\nName: demo\nVersion: 1.0\nRequires-Dist: click\nDynamic: Summary\n\nbody\n'
  run_requires 'pypi_metadata demo 1.0'
  [ "$status" -eq 0 ]
  [ "$output" = $'Metadata-Version: 2.2\nName: demo\nVersion: 1.0\nRequires-Dist: click\nDynamic: Summary' ]
}

# Checks that their timeout kills leave their files behind, and check-all.sh removes the run cache at its end
@test "lib.sh: http_get, pypi_metadata and remote_tags download into the run cache" {
  export AURTOMATOR_RUN_CACHE="$TEST_TMPDIR/run-cache" CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  mkdir -p "$AURTOMATOR_RUN_CACHE"
  pypi_fake_sdist demo 1.0 $'Metadata-Version: 2.2\nName: demo\nVersion: 1.0\nRequires-Dist: click\n'
  run_requires 'pypi_metadata demo 1.0'
  [ "$status" -eq 0 ]
  grep -o -- ' -o [^ ]*' "$CURL_ARGS_LOG" | cut -d' ' -f3 >"$TEST_TMPDIR/paths"
  [ "$(wc -l <"$TEST_TMPDIR/paths")" -ge 2 ]
  run grep -cv -- "^$AURTOMATOR_RUN_CACHE/" "$TEST_TMPDIR/paths"
  [ "$output" = 0 ]
  printf '#!/usr/bin/env bash\nreadlink "/proc/$$/fd/1" >>"%s"\nprintf "abc\\trefs/tags/v1.0.0\\n"\n' "$TEST_TMPDIR/refs-path" \
    >"$MOCK_DIR/git"
  chmod +x "$MOCK_DIR/git"
  run_requires 'remote_tags https://git.example/repo.git'
  [ "$status" -eq 0 ]
  [ "$output" = v1.0.0 ]
  [[ "$(<"$TEST_TMPDIR/refs-path")" == "$AURTOMATOR_RUN_CACHE/"* ]]
  # Outside a run the files go to TMPDIR
  : >"$TEST_TMPDIR/refs-path"
  run env -u AURTOMATOR_RUN_CACHE bash -c 'source "$0/scripts/lib.sh"; remote_tags https://git.example/repo.git' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$(dirname "$(<"$TEST_TMPDIR/refs-path")")" = "${TMPDIR:-/tmp}" ]
}

@test "requires.sh: pypi_metadata fails with 4 for an sdist whose requirements are dynamic or unknown" {
  local text
  for text in $'Metadata-Version: 2.2\nName: demo\nDynamic: requires-dist\n' $'Metadata-Version: 2.1\nName: demo\nRequires-Dist: click\n' \
    $'Name: demo\n'; do
    rm -rf "$MOCK_FILES_DIR"/* "$TEST_TMPDIR"/sdist-*
    pypi_fake_sdist demo 1.0 "$text"
    run_requires 'pypi_metadata demo 1.0'
    [ "$status" -eq 4 ] || {
      echo "${text@Q}: $status $output"
      return 1
    }
    [[ "$output" == *"demo 1.0: PyPI holds no metadata that lists the requirements without running code"* ]]
  done
  rm -rf "$MOCK_FILES_DIR"/*
  pypi_fake demo 1.0 a
  yq -i -o json '.files = []' "$MOCK_FILES_DIR/simple/demo.json"
  run_requires 'pypi_metadata demo 1.0'
  [ "$status" -eq 4 ]
}

@test "requires.sh: pypi_metadata checks the sha256 of an sdist and reads PKG-INFO of its top directory alone" {
  pypi_fake_sdist demo 1.0 $'Metadata-Version: 2.4\nName: demo\n'
  printf 'x' >>"$MOCK_FILES_DIR/demo-1.0.tar.gz"
  run_requires 'pypi_metadata demo 1.0'
  [ "$status" -eq 1 ]
  [[ "$output" == *"demo-1.0.tar.gz does not match its sha256"* ]]
  rm -rf "$MOCK_FILES_DIR"/*
  mkdir -p "$TEST_TMPDIR/deep/demo-2.0/sub"
  printf 'Metadata-Version: 2.4\nName: deep\n' >"$TEST_TMPDIR/deep/demo-2.0/sub/PKG-INFO"
  bsdtar -czf "$MOCK_FILES_DIR/demo-2.0.tar.gz" -C "$TEST_TMPDIR/deep" demo-2.0
  pypi_fake_file demo 2.0 "$MOCK_FILES_DIR/demo-2.0.tar.gz" false
  run_requires 'pypi_metadata demo 2.0'
  [ "$status" -eq 4 ]
  # The top directory takes the name of the file
  mkdir -p "$TEST_TMPDIR/other/other-3.0"
  printf 'Metadata-Version: 2.4\nName: other\n' >"$TEST_TMPDIR/other/other-3.0/PKG-INFO"
  bsdtar -czf "$MOCK_FILES_DIR/demo-3.0.tar.gz" -C "$TEST_TMPDIR/other" other-3.0
  pypi_fake_file demo 3.0 "$MOCK_FILES_DIR/demo-3.0.tar.gz" false
  run_requires 'pypi_metadata demo 3.0'
  [ "$status" -eq 4 ]
}

# Helper: runs requires_change for a pypi package of registry $1 from release $2 to $3, with
# the upstream lines $4
run_change() {
  create_test_package "pkg" "pypi" "upstream:
  registry: $1${4:+$'\n'$4}"
  run_requires 'requires_change "$1" "$2" "$3"' "$TEST_TMPDIR/packages/pkg.yml" "$2" "$3"
}

@test "requires.sh: requires_change names the requirements that the new release adds and drops" {
  pypi_fake mixer 1.0 keep old-dep
  pypi_fake mixer 2.0 'keep>=2' 'New_Dep>=1' 'other-new; sys_platform == "linux"' 'win-only; sys_platform == "win32"'
  run_change mixer 1.0 2.0
  [ "$status" -eq 0 ]
  [ "$output" = "adds new-dep, other-new; drops old-dep" ]
  run_change zensical 0.0.74 0.1.3
  [ "$status" -eq 0 ]
  [ "$output" = "drops deepmerge" ]
  run_change zensical 0.1.3 0.0.74
  [ "$status" -eq 0 ]
  [ "$output" = "adds deepmerge" ]
}

@test "requires.sh: requires_change prints nothing when the names that apply on Arch match" {
  local pair registry old new
  # zensical moves its pin of zensical-ui, keyring drops a requirement for Python below 3.9, and
  # black adds one for Windows
  for pair in "zensical 0.1.2 0.1.3" "keyring 25.6.0 25.7.0" "black 26.1.0 26.10.1"; do
    read -r registry old new <<<"$pair"
    run_change "$registry" "$old" "$new"
    [ "$status" -eq 0 ] && [ -z "$output" ] || {
      echo "$pair: $output"
      return 1
    }
  done
}

@test "requires.sh: requires_change notes a release of current that PyPI lacks" {
  pypi_fake gone 0.1.3
  run_change gone 0.1.2 0.1.3
  [ "$status" -eq 0 ]
  [ "$output" = "PyPI has no release 0.1.2 of gone to compare with" ]
}

# Only a publish moves current, so a failure here would stop the package for good
@test "requires.sh: requires_change notes a release of current whose requirements PyPI cannot list" {
  pypi_fake_sdist old 1.0 $'Metadata-Version: 2.1\nName: old\n'
  pypi_fake old 2.0 click
  run_change old 1.0 2.0
  [ "$status" -eq 0 ]
  [ "$output" = "old 1.0: PyPI holds no metadata that lists the requirements without running code" ]
}

@test "requires.sh: requires_change fails when PyPI lacks the new release or its requirements, or answers with an error" {
  run_change zensical 0.1.3 0.1.4
  [ "$status" -eq 1 ]
  [[ "$output" == *"zensical: PyPI has no release 0.1.4"* ]]
  run_change flaky 1.0 2.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"https://pypi.org/simple/flaky/: The requested URL returned error: 503"* ]]
  pypi_fake old 1.0 click
  pypi_fake_sdist old 2.0 $'Metadata-Version: 2.1\nName: old\n'
  run_change old 1.0 2.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"old 2.0: PyPI holds no metadata that lists the requirements without running code"* ]]
}

@test "requires.sh: requires_change reads answers within upstream.max_answer_mb" {
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run_change zensical 0.0.74 0.1.3 "  max_answer_mb: 7"
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '--max-filesize 7M' "$CURL_ARGS_LOG")" -eq 3 ]
  [ "$(grep -c 'pypi.org/simple/zensical/$' "$CURL_ARGS_LOG")" -eq 1 ]
}

@test "requires.sh: requires_change asks for no version outside the characters of PyPI versions" {
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run_change zensical 0.1.2 '0.1.3/../x'
  [ "$status" -eq 1 ]
  [[ "$output" == *"PyPI versions hold A-Za-z0-9._+!- alone: '0.1.3/../x'"* ]]
  [ ! -e "$CURL_ARGS_LOG" ]
}

# === archdb.sh ===

# Helper: runs bash code $1 with lib.sh sourced, the mock pacman first in PATH and a run cache in
# the test directory; the other arguments become $1 and on
run_archdb() {
  use_mock_pacman
  export AURTOMATOR_RUN_CACHE="$TEST_TMPDIR/run-cache"
  mkdir -p "$AURTOMATOR_RUN_CACHE"
  run bash -c "source \"\$0/scripts/lib.sh\"; $1" "$TEST_TMPDIR" "${@:2}"
}

# Helper: writes the files database lines of tests/fixtures to MOCK_PACMAN_FILES: python-yaml,
# python-brotli, python-protobuf and python-gpgme, a copy of PyYAML that azure-cli vendors, and the
# .egg-info distributions of python-setuptools, btrfs-progs and gpsd, a directory or a file
python_files_db() {
  export MOCK_PACMAN_FILES="$TEST_TMPDIR/pacman-files"
  printf 'extra\t%s\t%s\t%s\n' \
    python-yaml 6.0.2-2 usr/lib/python3.13/site-packages/PyYAML-6.0.2.dist-info/METADATA \
    python-setuptools 1:80.0.0-1 usr/lib/python3.13/site-packages/setuptools-80.0.0-py3.13.egg-info/PKG-INFO \
    btrfs-progs 6.14-1 usr/lib/python3.13/site-packages/btrfsutil-6.14-py3.13.egg-info/ \
    btrfs-progs 6.14-1 usr/lib/python3.13/site-packages/btrfsutil-6.14-py3.13.egg-info/PKG-INFO \
    gpsd 3.25-5 usr/lib/python3.13/site-packages/gps-3.25.egg-info \
    python-yaml 6.0.2-2 usr/lib/python3.13/site-packages/yaml/__init__.py \
    python-brotli 1.1.0-3 usr/lib/python3.13/site-packages/Brotli-1.1.0.dist-info/METADATA \
    python-protobuf 30.2-1 usr/lib/python3.13/site-packages/protobuf-6.30.2.dist-info/METADATA \
    python-gpgme 1.24.2-4 usr/lib/python3.13/site-packages/gpg-1.24.2.dist-info/METADATA \
    azure-cli 2.71.0-1 opt/azure-cli/lib/python3.13/site-packages/PyYAML-6.0.2.dist-info/METADATA \
    >"$MOCK_PACMAN_FILES"
}

@test "archdb.sh: srcinfo_pkgnames prints the pkgnames in order" {
  run_archdb 'srcinfo_pkgnames "$1"' "$FIXTURES_DIR/aur/liblinear.SRCINFO"
  [ "$status" -eq 0 ]
  [ "$output" = $'liblinear\npython-liblinear' ]
}

@test "archdb.sh: srcinfo_depends prints the names of depends and optdepends of a pkgname" {
  local aur="$FIXTURES_DIR/aur"
  run_archdb 'srcinfo_depends "$1" ydiskarc depends' "$aur/ydiskarc.SRCINFO"
  [ "$output" = "$(printf '%s\n' python python-typer python-yaml python-requests python-rich python-urllib3 python-tqdm)" ]
  run_archdb 'srcinfo_depends "$1" graphviz2drawio depends' "$aur/graphviz2drawio.SRCINFO"
  [ "$output" = "$(printf '%s\n' python python-puremagic python-pygraphviz python-svg.path)" ]
  run_archdb 'srcinfo_depends "$1" kube-diagrams-git optdepends' "$aur/kube-diagrams-git.SRCINFO"
  [ "$output" = $'helm\nkubectl' ]
  run_archdb 'srcinfo_depends "$1" python-liblinear depends; srcinfo_depends "$1" python-liblinear optdepends' "$aur/liblinear.SRCINFO"
  [ "$output" = "$(printf '%s\n' glibc libgcc libstdc++ python python-numpy python-scipy python-numba)" ]
  run_archdb 'srcinfo_depends "$1" liblinear depends' "$aur/liblinear.SRCINFO"
  [ "$output" = $'glibc\nlibgcc\nlibstdc++' ]
}

@test "archdb.sh: srcinfo_depends takes the pkgbase values unless the pkgname section sets the key" {
  printf '%s\n' 'pkgbase = split' $'\tpkgver = 1.0' $'\tdepends = base-dep>=2' $'\tdepends_x86_64 = base-x86' \
    $'\tdepends_aarch64 = base-arm' $'\toptdepends = base-opt: for docs' '' 'pkgname = one' '' 'pkgname = two' \
    $'\tdepends = own-dep=1.0' $'\toptdepends = ' '' 'pkgname = three' $'\tdepends = ' $'\tdepends_x86_64 = own-x86<3' \
    >"$TEST_TMPDIR/split.SRCINFO"
  run_archdb 'for p in one two three; do echo "$p: $(srcinfo_depends "$1" "$p" depends | paste -sd" ") | $(srcinfo_depends "$1" "$p" optdepends | paste -sd" ")"; done' \
    "$TEST_TMPDIR/split.SRCINFO"
  [ "$status" -eq 0 ]
  [ "$output" = $'one: base-dep base-x86 | base-opt\ntwo: own-dep base-x86 | \nthree: own-x86 | base-opt' ]
}

@test "archdb.sh: aur_srcinfo clones the AUR once per run and prints the path of its .SRCINFO" {
  aur_srcinfo_remote ydiskarc "$FIXTURES_DIR/aur/ydiskarc.SRCINFO"
  printf '#!/usr/bin/env bash\n[[ "$1" != clone ]] || echo "$*" >>"%s/clones"\nexec "%s/aur-bin/git" "$@"\n' \
    "$TEST_TMPDIR" "$TEST_TMPDIR" >"$MOCK_DIR/git"
  chmod +x "$MOCK_DIR/git"
  run_archdb 'aur_srcinfo ydiskarc && aur_srcinfo ydiskarc'
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_TMPDIR/run-cache/aur/ydiskarc.SRCINFO"$'\n'"$TEST_TMPDIR/run-cache/aur/ydiskarc.SRCINFO" ]
  cmp "$TEST_TMPDIR/run-cache/aur/ydiskarc.SRCINFO" "$FIXTURES_DIR/aur/ydiskarc.SRCINFO"
  [ "$(wc -l <"$TEST_TMPDIR/clones")" -eq 1 ]
  # The list of the packages that miss a key clones the AUR repository of each, so stalled clones end
  [[ "$(<"$TEST_TMPDIR/clones")" == "clone --depth 1 --no-checkout -q -c http.lowSpeedLimit=102400 -c http.lowSpeedTime=60 https://aur.archlinux.org/ydiskarc.git "* ]]
  run_archdb 'aur_srcinfo ydiskarc'
  [ "$(wc -l <"$TEST_TMPDIR/clones")" -eq 1 ]
}

@test "archdb.sh: aur_srcinfo returns 3 for a package the AUR lacks, once per run" {
  run_archdb 'aur_srcinfo new-pkg'
  [ "$status" -eq 3 ]
  run_archdb 'aur_srcinfo new-pkg'
  [ "$status" -eq 3 ]
  run_archdb 'aur_srcinfo ../x'
  [ "$status" -eq 1 ]
  [[ "$output" == *"../x is not an AUR package name"* ]]
}

# The list and the metadata reach awk as two inputs, and an empty list is still the first of them
@test "archdb.sh: aur_screen prints no package for an empty list" {
  aur_meta '{"Name":"py","PackageBase":"py","Depends":["python"]}'
  : >"$TEST_TMPDIR/names"
  run_archdb 'aur_screen "$1"' "$TEST_TMPDIR/names"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'py\n' >"$TEST_TMPDIR/names"
  run_archdb 'aur_screen "$1"' "$TEST_TMPDIR/names"
  [ "$status" -eq 0 ]
  [ "$output" = py ]
}

@test "archdb.sh: files_index_python lists the distributions of the repositories once per run" {
  python_files_db
  export PACMAN_ARGS_LOG="$TEST_TMPDIR/pacman-args"
  run_archdb 'files_index_python && files_index_python && echo "$ARCHDB_FILES" && cat "$AURTOMATOR_RUN_CACHE/py-dists"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' files brotli$'\t'python-brotli$'\t'1.1.0 btrfsutil$'\t'btrfs-progs$'\t'6.14 \
    gpg$'\t'python-gpgme$'\t'1.24.2 gps$'\t'gpsd$'\t'3.25 protobuf$'\t'python-protobuf$'\t'6.30.2 \
    pyyaml$'\t'python-yaml$'\t'6.0.2 setuptools$'\t'python-setuptools$'\t'80.0.0)" ]
  [ "$(cat "$PACMAN_ARGS_LOG")" = "-Fx --machinereadable ^usr/lib/python3\\.[0-9]+/site-packages/[^/]+\\.(dist-info/METADATA|egg-info(/PKG-INFO)?)\$" ]
}

@test "archdb.sh: files_index_python writes #none without a files database" {
  python_files_db
  export MOCK_PACMAN_NO_FILES=1
  run_archdb 'files_index_python && echo "$ARCHDB_FILES" && cat "$AURTOMATOR_RUN_CACHE/py-dists" && files_index_python && echo "$ARCHDB_FILES"'
  [ "$status" -eq 0 ]
  [ "$output" = $'none\n#none\nnone' ]
}

@test "archdb.sh: python_dists_of prints the distributions of a package" {
  python_files_db
  run_archdb 'python_dists_of python-yaml; python_dists_of python-none'
  [ "$status" -eq 0 ]
  [ "$output" = pyyaml$'\t'6.0.2 ]
}

@test "archdb.sh: files_index_owner prints the owners of the paths that match" {
  python_files_db
  run_archdb 'files_index_owner "^usr/lib/python3\\.[0-9]+/site-packages/yaml/"'
  [ "$status" -eq 0 ]
  [ "$output" = python-yaml$'\t'usr/lib/python3.13/site-packages/yaml/__init__.py ]
}

# pacman exits 1 for no match and for an error, which only its error line tells apart
@test "archdb.sh: files_index_owner fails on an error of pacman and gives nothing for no match" {
  python_files_db
  run_archdb 'files_index_owner "^nothing$"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  MOCK_PACMAN_NO_FILES=1 run_archdb 'files_index_owner "^usr/"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  MOCK_PACMAN_FX_EXIT=1 run_archdb 'files_index_owner "^usr/"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"pacman -Fx exits 1: error: failed to read file 'extra.files'" ]]
  MOCK_PACMAN_FX_EXIT=126 run_archdb 'files_index_owner "^usr/"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"pacman -Fx exits 126" ]]
}

# Modules that a failed query left out would have no owner for the rest of the run, and Linux
# takes no argument past 128 KiB
@test "pyrules.sh: _python_owners_index asks again after a failed query and splits long queries" {
  python_files_db
  MOCK_PACMAN_FX_EXIT=1 run_archdb '_python_owners_index yaml'
  [ "$status" -eq 1 ]
  [[ "$output" == *"pacman -Fx exits 1: error: failed to read file 'extra.files'" ]]
  [ ! -s "$AURTOMATOR_RUN_CACHE/py-owners-asked" ]
  run_archdb '_python_owners_index yaml && cat "$AURTOMATOR_RUN_CACHE/py-owners-asked" "$AURTOMATOR_RUN_CACHE/py-owners"'
  [ "$status" -eq 0 ]
  [ "$output" = $'yaml\npython-yaml\tyaml/__init__.py' ]
  export PACMAN_ARGS_LOG="$TEST_TMPDIR/pacman-args"
  run_archdb '_python_owners_index $(printf "m%05d\n" {1..15000}) brotli'
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$PACMAN_ARGS_LOG")" -eq 2 ]
  [ "$(awk '{ if (length($0) > max) max = length($0) } END { print (max < 100000) }' "$PACMAN_ARGS_LOG")" -eq 1 ]
  [ "$(wc -l <"$AURTOMATOR_RUN_CACHE/py-owners-asked")" -eq 15002 ]
}

@test "rbrules.sh: _ruby_owners fails on an error of pacman and splits long queries" {
  export MOCK_PACMAN_FILES="$TEST_TMPDIR/pacman-files"
  printf 'extra\truby-rexml\t1-1\tusr/lib/ruby/gems/3.4.0/gems/rexml-3.4.4/lib/rexml/document.rb\n' >"$MOCK_PACMAN_FILES"
  MOCK_PACMAN_FX_EXIT=1 run_archdb '_ruby_owners rexml/document'
  [ "$status" -eq 1 ]
  [[ "$output" == *"pacman -Fx exits 1: error: failed to read file 'extra.files'" ]]
  export PACMAN_ARGS_LOG="$TEST_TMPDIR/pacman-args"
  run_archdb '_ruby_owners $(printf "r%05d\n" {1..15000}) rexml/document'
  [ "$status" -eq 0 ]
  [ "$output" = $'rexml/document\truby-rexml' ]
  [ "$(wc -l <"$PACMAN_ARGS_LOG")" -eq 2 ]
  [ "$(awk '{ if (length($0) > max) max = length($0) } END { print (max < 100000) }' "$PACMAN_ARGS_LOG")" -eq 1 ]
}

@test "archdb.sh: repo_package resolves a name of provides once per run" {
  export MOCK_PACMAN_SYNC="$TEST_TMPDIR/pacman-sync" PACMAN_ARGS_LOG="$TEST_TMPDIR/pacman-args"
  printf '%s\n' 'python-yaml 6.0.4-1 extra python-pyyaml' 'python-epoch 2:1.5-3 core' >"$MOCK_PACMAN_SYNC"
  run_archdb 'for n in python-pyyaml python-pyyaml python-epoch; do repo_package "$n" && echo "$PKG_NAME $PKG_VERSION $PKG_REPO"; done'
  [ "$status" -eq 0 ]
  [ "$output" = $'python-yaml 6.0.4 extra\npython-yaml 6.0.4 extra\npython-epoch 1.5 core' ]
  [ "$(grep -c -- -Sddp "$PACMAN_ARGS_LOG")" -eq 2 ]
  run_archdb 'repo_package python-none || echo "fails $?"; repo_package python-none || echo "fails $?"'
  [ "$output" = $'fails 1\nfails 1' ]
  [ "$(grep -c -- 'python-none' "$PACMAN_ARGS_LOG")" -eq 1 ]
}

@test "archdb.sh: aur_package reads the AUR RPC in one request for the names of aur_packages" {
  cp "$FIXTURES_DIR/aur/rpc.json" "$MOCK_FILES_DIR/aur-rpc.json"
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run_archdb 'aur_packages python-svg.path kube-diagrams-git none-such &&
    for n in python-svg.path kube-diagrams-git none-such; do aur_package "$n" && echo "$PKG_NAME $PKG_VERSION $PKG_REPO" || echo "$n: none"; done'
  [ "$status" -eq 0 ]
  [ "$output" = $'python-svg.path 6.3 aur\nkube-diagrams-git r675.70e1dda aur\nnone-such: none' ]
  [ "$(grep -c aur.archlinux.org/rpc "$CURL_ARGS_LOG")" -eq 1 ]
  [[ "$(<"$CURL_ARGS_LOG")" == *"https://aur.archlinux.org/rpc/v5/info?arg[]=python-svg.path&arg[]=kube-diagrams-git&arg[]=none-such" ]]
}

@test "archdb.sh: aur_package finds a name of provides and asks in batches of 100" {
  printf '[{"Name": "foo-git", "Version": "1:r1.abc-2", "Provides": ["foo=1.0"]}, {"Name": "c++lib", "Version": "2.0-1"}]\n' \
    >"$MOCK_FILES_DIR/aur-rpc.json"
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run_archdb 'aur_packages foo-git; aur_package foo && echo "$PKG_NAME $PKG_VERSION"; aur_package c++lib && echo "$PKG_NAME"'
  [ "$status" -eq 0 ]
  [ "$output" = $'foo-git r1.abc\nc++lib' ]
  [[ "$(<"$CURL_ARGS_LOG")" == *"arg[]=c%2B%2Blib" ]]
  : >"$CURL_ARGS_LOG"
  run_archdb 'aur_packages $(seq -f "pkg%g" 150)'
  [ "$status" -eq 0 ]
  [ "$(grep -c aur.archlinux.org/rpc "$CURL_ARGS_LOG")" -eq 2 ]
}

@test "archdb.sh: aur_packages fails on an AUR version other than epoch, pkgver and pkgrel" {
  local version
  for version in '0.0.41\u0001-1' '0.0.41' '1.0-x' 'abc-1' 'x:1.0-1' "$(printf '1%.0s' {1..65})-1"; do
    rm -rf "$TEST_TMPDIR/run-cache"
    printf '[{"Name": "python-bad", "Version": "%s"}]\n' "$version" >"$MOCK_FILES_DIR/aur-rpc.json"
    run_archdb 'aur_packages python-bad'
    [ "$status" -eq 1 ]
    [[ "$output" == *"python-bad has version "*", not epoch:pkgver-pkgrel"* ]]
  done
  printf '[{"Name": "python-ok", "Version": "2:1.0+r3.ab_c-1.2"}]\n' >"$MOCK_FILES_DIR/aur-rpc.json"
  run_archdb 'aur_packages python-ok && aur_package python-ok && echo "$PKG_VERSION"'
  [ "$status" -eq 0 ]
  [ "$output" = "1.0+r3.ab_c" ]
}

@test "archdb.sh: arch_package takes the repositories first, then the AUR" {
  export MOCK_PACMAN_SYNC="$TEST_TMPDIR/pacman-sync"
  printf '%s\n' 'python-rich 14.2.0-1 extra' >"$MOCK_PACMAN_SYNC"
  cp "$FIXTURES_DIR/aur/rpc.json" "$MOCK_FILES_DIR/aur-rpc.json"
  run_archdb 'for n in python-rich python-svg.path none-such; do arch_package "$n" && echo "$PKG_NAME $PKG_VERSION $PKG_REPO" || echo "$n: none"; done'
  [ "$status" -eq 0 ]
  [ "$output" = $'python-rich 14.2.0 extra\npython-svg.path 6.3 aur\nnone-such: none' ]
}

# === py_imports.py ===

# Helper: writes file $1 under $TEST_TMPDIR/py with the lines after it
py_file() {
  mkdir -p "$(dirname "$TEST_TMPDIR/py/$1")"
  printf '%s\n' "${@:2}" >"$TEST_TMPDIR/py/$1"
}

# Helper: runs py_imports.py on the files $@ of $TEST_TMPDIR/py as the rules run it, the names
# NUL-separated on stdin
run_py_imports() {
  printf '%s\0' "$@" >"$TEST_TMPDIR/py-files"
  run --separate-stderr python3 -I -S "$TEST_TMPDIR/scripts/lib/py_imports.py" "$TEST_TMPDIR/py" <"$TEST_TMPDIR/py-files"
}

@test "py_imports.py: prints the modules of import and from, with their scope" {
  py_file mod.py 'import os' 'import a.b as c, json' 'from x.y import z, w as v' 'from star import *' \
    'def f():' '    import inner' 'async def g():' '    from deep import thing' 'h = lambda: __import__("no")' \
    'class K:' '    import in_class'
  run_py_imports mod.py
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'import\tmod.py\t%s\n' 'os	module' 'a.b	module' 'json	module' 'x.y	module' 'x.y.z	module' \
    'x.y.w	module' 'star	module' 'inner	function' 'deep	function' 'deep.thing	function' 'in_class	module')" ]
}

# Python writes stdout strictly outside the C locales, and releases can hold any byte in a name
@test "py_imports.py: prints file names outside UTF-8 as their bytes" {
  local bad=$'bad\xff.py'
  py_file ok.py 'import json'
  printf 'import os\n' >"$TEST_TMPDIR/py/$bad"
  printf '%s\0' ok.py "$bad" >"$TEST_TMPDIR/py-files"
  run --separate-stderr env PYTHONIOENCODING=utf-8:strict python3 -S "$TEST_TMPDIR/scripts/lib/py_imports.py" "$TEST_TMPDIR/py" \
    <"$TEST_TMPDIR/py-files"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'import\tok.py\tjson\tmodule' ]
  [ "${lines[1]}" = "import"$'\t'"$bad"$'\t'"os"$'\t'"module" ]
}

@test "py_imports.py: reads try, suppress and TYPE_CHECKING as optional and typing scopes" {
  py_file mod.py 'try:' '    import fast' 'except ImportError:' '    import slow' 'try:' '    import a' 'except (ValueError, ModuleNotFoundError):' \
    '    pass' 'try:' '    import b' 'except KeyError:' '    pass' 'try:' '    import c' 'except:' '    pass' \
    'from contextlib import suppress' 'import contextlib' 'with suppress(ImportError):' '    import d' \
    'with contextlib.suppress(Exception):' '    import e' 'with open("x"):' '    import f' \
    'from typing import TYPE_CHECKING' 'if TYPE_CHECKING:' '    import g' 'import typing' 'if typing.TYPE_CHECKING:' '    import h' \
    'def fn():' '    try:' '        import i' '    except ImportError:' '        pass'
  run_py_imports mod.py
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'import\tmod.py\t%s\n' 'fast	optional' 'slow	optional' 'a	optional' 'b	module' 'c	optional' \
    'contextlib	module' 'contextlib.suppress	module' 'contextlib	module' 'd	optional' 'e	optional' 'f	module' \
    'typing	module' 'typing.TYPE_CHECKING	module' 'g	typing' 'typing	module' 'h	typing' 'i	function')" ]
}

@test "py_imports.py: follows the branch that the Python running it takes" {
  py_file mod.py 'import sys, os, platform' 'if sys.version_info >= (3, 11):' '    import tomllib' 'else:' '    import tomli' \
    'if sys.version_info[:2] < (3, 8):' '    import old' 'if sys.platform == "win32":' '    import winreg' \
    'elif sys.platform.startswith(("linux", "freebsd")):' '    import fcntl' 'if os.name != "posix" or not platform.system() == "Linux":' \
    '    import never' 'if sys.version_info >= (3, 11) and unknown():' '    import maybe' 'else:' '    import other'
  run_py_imports mod.py
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'import\tmod.py\t%s\n' 'sys	module' 'os	module' 'platform	module' 'tomllib	module' 'fcntl	module' \
    'maybe	optional' 'other	optional')" ]
}

# jinja2 tests t.TYPE_CHECKING after import typing as t, and requests imports simplejson under a
# flag that a try sets
@test "py_imports.py: reads any TYPE_CHECKING as typing and the branches of an unknown test as optional" {
  py_file mod.py 'import typing as t' 'if t.TYPE_CHECKING:' '    import typing_extensions as te' \
    'if has_simplejson:' '    from simplejson import JSONDecodeError' 'elif sys.platform == "win32":' '    import winreg' \
    'else:' '    import json'
  run_py_imports mod.py
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'import\tmod.py\t%s\n' 'typing	module' 'typing_extensions	typing' 'simplejson	optional' \
    'simplejson.JSONDecodeError	optional' 'json	optional')" ]
}

@test "py_imports.py: resolves relative imports against the path of the file" {
  py_file pkg/__init__.py 'from . import sub' 'from .core import run'
  py_file pkg/sub/mod.py 'from . import x' 'from .m import y' 'from .. import top' 'from ..core import run'
  run_py_imports pkg/__init__.py pkg/sub/mod.py
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'import\t%s\n' 'pkg/__init__.py	pkg	module' 'pkg/__init__.py	pkg.sub	module' \
    'pkg/__init__.py	pkg.core	module' 'pkg/__init__.py	pkg.core.run	module' 'pkg/sub/mod.py	pkg.sub	module' \
    'pkg/sub/mod.py	pkg.sub.x	module' 'pkg/sub/mod.py	pkg.sub.m	module' 'pkg/sub/mod.py	pkg.sub.m.y	module' \
    'pkg/sub/mod.py	pkg	module' 'pkg/sub/mod.py	pkg.top	module' 'pkg/sub/mod.py	pkg.core	module' \
    'pkg/sub/mod.py	pkg.core.run	module')" ]
}

@test "py_imports.py: prints an error line for a file it cannot parse and goes on" {
  py_file bad.py 'def f(:' '    pass'
  py_file good.py 'import json'
  printf '\xff\xfe import x\n' >"$TEST_TMPDIR/py/bytes.py"
  run_py_imports bad.py missing.py bytes.py good.py
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [[ "${lines[0]}" == error$'\t'bad.py$'\t'* ]]
  [[ "${lines[1]}" == error$'\t'missing.py$'\t'* ]]
  [[ "${lines[2]}" == error$'\t'bytes.py$'\t'* ]]
  [ "${lines[3]}" = import$'\t'good.py$'\t'json$'\t'module ]
}

# sys and builtins live in the interpreter, so no file of the files database names them
@test "py_imports.py: --stdlib prints the standard modules of the Python that runs it" {
  run --separate-stderr python3 -I -S "$TEST_TMPDIR/scripts/lib/py_imports.py" --stdlib
  [ "$status" -eq 0 ]
  local name
  for name in sys builtins json os _io; do
    [[ $'\n'"$output"$'\n' == *$'\n'"$name"$'\n'* ]] || {
      echo "missing: $name"
      return 1
    }
  done
  [[ $'\n'"$output"$'\n' != *$'\nnumpy\n'* ]]
}

@test "py_imports.py: exits 2 without a root" {
  run --separate-stderr python3 -I -S "$TEST_TMPDIR/scripts/lib/py_imports.py"
  [ "$status" -eq 2 ]
  run --separate-stderr python3 -I -S "$TEST_TMPDIR/scripts/lib/py_imports.py" "$TEST_TMPDIR/none-such"
  [ "$status" -eq 2 ]
}

# === pyrules.sh ===

# Helper: the mock pacman with the repository packages of the tests, a files database with their
# Python distributions, the AUR packages of tests/fixtures and a run cache in the test directory
unmet_env() {
  use_mock_pacman
  export AURTOMATOR_RUN_CACHE="$TEST_TMPDIR/run-cache" MOCK_PACMAN_SYNC="$TEST_TMPDIR/pacman-sync" \
    MOCK_PACMAN_FILES="$TEST_TMPDIR/pacman-files"
  mkdir -p "$AURTOMATOR_RUN_CACHE"
  printf '%s\n' 'python 3.14.10-1 core python3' 'python-typer 0.20.0-1 extra' 'python-yaml 6.0.4-1 extra python-pyyaml' \
    'python-requests 2.32.5-1 extra' 'python-rich 14.2.0-1 extra' 'python-urllib3 2.5.0-1 extra' \
    'python-tqdm 4.67.1-2 extra' 'python-botocore 1.43.108-1 extra' 'python-jmespath 1.0.1-4 extra' \
    'python-s3transfer 0.19.0-1 extra' 'python-mpmath 1.4.1-1 extra' 'python-httpx 0.28.1-3 extra' \
    'python-protobuf 36.1-1 extra' 'python-puremagic 1.30-1 extra' 'python-pygraphviz 1.14-3 extra' \
    'python-numpy 2.3.4-1 extra' >"$MOCK_PACMAN_SYNC"
  local line
  for line in 'python-yaml PyYAML-6.0.2' 'python-botocore botocore-1.43.108' 'python-httpx httpx-0.28.1' \
    'python-protobuf protobuf-6.33.5' 'python-mpmath mpmath-1.4.1' 'python-requests requests-2.32.5'; do
    printf 'extra\t%s\t1-1\tusr/lib/python3.14/site-packages/%s.dist-info/METADATA\n' "${line% *}" "${line#* }"
  done >"$MOCK_PACMAN_FILES"
  cp "$FIXTURES_DIR/aur/rpc.json" "$MOCK_FILES_DIR/aur-rpc.json"
}

# Helper: writes .SRCINFO $1 of a package of one pkgname, $2, whose depends are the other arguments
unmet_srcinfo() {
  {
    printf 'pkgbase = %s\n\tpkgver = 1.0\n\tpkgrel = 1\n\tarch = any\n' "$2"
    printf '\tdepends = %s\n' "${@:3}"
    printf '\npkgname = %s\n' "$2"
  } >"$1"
}

# Helper: runs python_unmet for package pkg of registry $2 at version $3 with .SRCINFO $1, and the
# lines $4 in the YAML
run_unmet() {
  create_test_package "pkg" "pypi" "upstream:
  registry: $2
${4:-}"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; python_unmet "$@"' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/pkg.yml" "$1" "$2" "$3"
}

@test "pyrules.sh: python_unmet holds a requirement that no entry of depends meets" {
  unmet_env
  grep -v 'python-rich$' "$FIXTURES_DIR/aur/ydiskarc.SRCINFO" | sed 's/pkgrel = 2/pkgrel = 1/' >"$TEST_TMPDIR/rel1.SRCINFO"
  run_unmet "$TEST_TMPDIR/rel1.SRCINFO" ydiskarc 1.1.0
  [ "$status" -eq 0 ]
  [ "$output" = $'hold\trich: not in depends' ]
  run_unmet "$FIXTURES_DIR/aur/ydiskarc.SRCINFO" ydiskarc 1.1.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pyrules.sh: python_unmet holds a lower bound that the version of the distribution fails" {
  unmet_env
  unmet_srcinfo "$TEST_TMPDIR/boto3.SRCINFO" python-boto3 python python-botocore python-jmespath python-s3transfer
  run_unmet "$TEST_TMPDIR/boto3.SRCINFO" boto3 1.44.10
  [ "$status" -eq 0 ]
  [ "$output" = $'hold\tbotocore<1.45.0,>=1.44.10: python-botocore has 1.43.108' ]
}

@test "pyrules.sh: python_unmet gives a notice for an upper cap and names a version of pkgver" {
  unmet_env
  pypi_fake sympy 1.14.0 'mpmath<1.4,>=1.1.0'
  unmet_srcinfo "$TEST_TMPDIR/sympy.SRCINFO" python-sympy python python-mpmath
  run_unmet "$TEST_TMPDIR/sympy.SRCINFO" sympy 1.14.0
  [ "$output" = $'notice\tmpmath<1.4,>=1.1.0: python-mpmath has 1.4.1' ]
  : >"$MOCK_PACMAN_FILES"
  rm -rf "$AURTOMATOR_RUN_CACHE"/*
  run_unmet "$TEST_TMPDIR/sympy.SRCINFO" sympy 1.14.0
  [ "$output" = $'notice\tmpmath<1.4,>=1.1.0: python-mpmath has 1.4.1 (pkgver)' ]
}

@test "pyrules.sh: python_unmet holds the requirements of an extra that depends lacks" {
  unmet_env
  pypi_fake litellm 1.80.0 'httpx[http2]<1.0,>=0.28.0' 'h11; extra == "proxy"'
  unmet_srcinfo "$TEST_TMPDIR/litellm.SRCINFO" python-litellm python python-httpx
  run_unmet "$TEST_TMPDIR/litellm.SRCINFO" litellm 1.80.0
  [ "$status" -eq 0 ]
  [ "$output" = $'hold\thttpx[http2]: h2 not in depends' ]
  printf '%s\n' 'python-h2 4.3.0-2 extra' >>"$MOCK_PACMAN_SYNC"
  rm -rf "$AURTOMATOR_RUN_CACHE"/*
  unmet_srcinfo "$TEST_TMPDIR/litellm.SRCINFO" python-litellm python python-httpx python-h2
  run_unmet "$TEST_TMPDIR/litellm.SRCINFO" litellm 1.80.0
  [ -z "$output" ]
}

@test "pyrules.sh: python_unmet gives a notice when it cannot read the metadata of an extra" {
  unmet_env
  pypi_fake demo 1.0 'zensical[x]>=0.1'
  printf '%s\n' 'python-zensical 0.0.9-1 extra' >>"$MOCK_PACMAN_SYNC"
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python python-zensical
  run_unmet "$TEST_TMPDIR/demo.SRCINFO" demo 1.0
  [ "$output" = $'hold\tzensical>=0.1: python-zensical has 0.0.9 (pkgver)\nnotice\tzensical[x]: cannot read the metadata of zensical 0.0.9' ]
}

@test "pyrules.sh: python_unmet holds a Requires-Python that the python of Arch fails" {
  unmet_env
  pypi_fake_metadata demo 1.0 $'Metadata-Version: 2.4\nName: demo\nRequires-Python: < 3.14\n'
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python
  run_unmet "$TEST_TMPDIR/demo.SRCINFO" demo 1.0
  [ "$output" = $'hold\tRequires-Python <3.14: python has 3.14.10' ]
}

@test "pyrules.sh: python_match counts a package whose provides hold the name of the requirement" {
  unmet_env
  : >"$MOCK_PACMAN_FILES"
  printf '[{"Name": "python-svg-path-git", "Version": "r9.abc-1", "Provides": ["python-svg-path=6.3"]}]\n' \
    >"$MOCK_FILES_DIR/aur-rpc.json"
  create_test_package "pkg" "pypi" "upstream:
  registry: demo"
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python python-yaml python-svg-path-git
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"
    python_match "$1" "$2" python-demo pyyaml PyYAML && echo "$MATCH_PKG $MATCH_VERSION $MATCH_FROM"
    python_match "$1" "$2" python-demo svg-path svg-path && echo "$MATCH_PKG $MATCH_VERSION $MATCH_FROM"
    python_match "$1" "$2" python-demo rich rich || echo none' \
    "$TEST_TMPDIR" "$TEST_TMPDIR/packages/pkg.yml" "$TEST_TMPDIR/demo.SRCINFO"
  [ "$status" -eq 0 ]
  [ "$output" = $'python-yaml 6.0.4 pkgver\npython-svg-path-git r9.abc aur\nnone' ]
}

@test "pyrules.sh: python_unmet compares the version of the distribution, not pkgver" {
  unmet_env
  pypi_fake demo 1.0 'protobuf<8.0.0,>=6.33.5'
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python python-protobuf
  run_unmet "$TEST_TMPDIR/demo.SRCINFO" demo 1.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pyrules.sh: python_unmet matches an AUR package through python.map" {
  unmet_env
  unmet_srcinfo "$TEST_TMPDIR/g.SRCINFO" graphviz2drawio python python-puremagic python-pygraphviz python-svg.path
  run_unmet "$TEST_TMPDIR/g.SRCINFO" graphviz2drawio 1.2.0 "python:
  map:
    svg-path: python-svg.path"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_unmet "$TEST_TMPDIR/g.SRCINFO" graphviz2drawio 1.2.0
  [ "$output" = $'hold\tsvg-path: not in depends' ]
}

@test "pyrules.sh: python_unmet gives a notice for a version outside PEP 440 and a URL" {
  unmet_env
  pypi_fake demo 1.0 'kubediagrams>=0.9' 'pip @ https://example.org/pip.zip'
  printf '%s\n' 'python-pip 25.3-1 extra' >>"$MOCK_PACMAN_SYNC"
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python kube-diagrams-git python-pip
  run_unmet "$TEST_TMPDIR/demo.SRCINFO" demo 1.0 "python:
  map:
    KubeDiagrams: kube-diagrams-git"
  [ "$output" = $'notice\tkubediagrams>=0.9: kube-diagrams-git has r675.70e1dda, which PEP 440 cannot compare\nnotice\tpip @ URL: cannot compare' ]
}

@test "pyrules.sh: python_unmet takes the pin of this release for a package of the repository with pin_from" {
  unmet_env
  pypi_fake zenlike 1.0 'zensical-ui==0.0.43'
  unmet_srcinfo "$TEST_TMPDIR/z.SRCINFO" zenlike python python-zensical-ui
  run_unmet "$TEST_TMPDIR/z.SRCINFO" zenlike 1.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  sed -i 's/"0.0.43-1"/"0.0.41-1"/' "$MOCK_FILES_DIR/aur-rpc.json"
  rm -rf "$AURTOMATOR_RUN_CACHE"/*
  run_unmet "$TEST_TMPDIR/z.SRCINFO" zenlike 1.0
  [ "$output" = $'hold\tzensical-ui==0.0.43: python-zensical-ui has 0.0.41 (AUR pkgver)' ]
  create_test_package "python-zensical-ui" "pypi" "upstream:
  registry: zensical-ui
  pin_from: ZenLike"
  rm -rf "$AURTOMATOR_RUN_CACHE"/*
  run_unmet "$TEST_TMPDIR/z.SRCINFO" zenlike 1.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pyrules.sh: python_unmet names the pkgname in the notes of a split package" {
  unmet_env
  pypi_fake liblinear-official 2.50.0 scipy 'numpy>=3'
  printf '%s\n' 'python-scipy 1.16.3-1 extra' >>"$MOCK_PACMAN_SYNC"
  run_unmet "$FIXTURES_DIR/aur/liblinear.SRCINFO" liblinear-official 2.50.0
  [ "$output" = $'hold\tpython-liblinear: numpy>=3: python-numpy has 2.3.4 (pkgver)' ]
}

@test "pyrules.sh: python_unmet checks nothing for a package without Python in depends" {
  unmet_env
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  unmet_srcinfo "$TEST_TMPDIR/c.SRCINFO" tool glibc
  run_unmet "$TEST_TMPDIR/c.SRCINFO" ydiskarc 1.1.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$CURL_ARGS_LOG" ]
}

# Helper: a pypi package ydiskarc with .SRCINFO $1 on the AUR and the alerts $2
unmet_package() {
  unmet_env
  aur_srcinfo_remote ydiskarc "$1"
  # The rule imports reads the wheel, which the fixture does not hold
  pypi_fake_metadata ydiskarc 1.1.0 "$(<"$FIXTURES_DIR/pypi/metadata/ydiskarc-1.1.0-py2.py3-none-any.whl.metadata")"
  create_test_package "ydiskarc" "pypi" "upstream:
  registry: ydiskarc
alerts:
$2"
}

@test "lib.sh: fired_alerts fires requires: unmet with its notes, hold only for holding notes" {
  grep -v 'python-rich$' "$FIXTURES_DIR/aur/ydiskarc.SRCINFO" >"$TEST_TMPDIR/rel1.SRCINFO"
  unmet_package "$TEST_TMPDIR/rel1.SRCINFO" "  - requires: unmet
    hold: true
    note: Check depends"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" "" 1.1.0' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/ydiskarc.yml"
  [ "$status" -eq 0 ]
  [ "$output" = $'hold\tCheck depends: rich: not in depends' ]
  export MOCK_PACMAN_SYNC="$TEST_TMPDIR/pacman-sync"
  sed -i 's/^python-requests .*/python-requests 2.20.0-1 extra/' "$MOCK_PACMAN_SYNC"
  : >"$MOCK_PACMAN_FILES"
  rm -rf "$AURTOMATOR_RUN_CACHE"/*
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" "" 1.1.0' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/ydiskarc.yml"
  [ "${lines[0]}" = $'hold\tCheck depends: requests>=2.31.0: python-requests has 2.20.0 (pkgver); rich: not in depends' ]
}

@test "lib.sh: fired_alerts fires requires: unmet as a notice under hold for notices alone" {
  pypi_fake ydiskarc 1.2.0 'requests<2' 'rich'
  unmet_package "$FIXTURES_DIR/aur/ydiskarc.SRCINFO" "  - requires: unmet
    hold: true"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" "" 1.2.0' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/ydiskarc.yml"
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\trequests<2: python-requests has 2.32.5' ]
}

@test "lib.sh: fired_alerts fires no requires: unmet without notes, for a new package or offline" {
  unmet_package "$FIXTURES_DIR/aur/ydiskarc.SRCINFO" "  - requires: unmet
    hold: true"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" "" 1.1.0' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/ydiskarc.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  local mode
  for mode in offline held; do
    run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" 1.0.1 1.1.0 "$2"' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/ydiskarc.yml" "$mode"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  [ ! -e "$CURL_ARGS_LOG" ]
  rm -rf "$TEST_TMPDIR/aur-remote" "$AURTOMATOR_RUN_CACHE"/*
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" "" 1.1.0' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/ydiskarc.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Helper: zips directory $3 into a wheel of release $2 of project $1 in MOCK_FILES_DIR and adds it to
# the simple page of the project
pypi_fake_wheel() {
  local wheel="$MOCK_FILES_DIR/${1//-/_}-$2-py3-none-any.whl" entries
  mapfile -t entries < <(ls -A "$3")
  bsdtar --format zip -cf "$wheel" -C "$3" "${entries[@]}"
  pypi_fake_file "$1" "$2" "$wheel" false
}

# Helper: the owners of modules in the files database: tqdm, numba, pandas, the json of python,
# pygraphviz, yaml and diagrams
imports_env() {
  unmet_env
  local line
  for line in 'python-tqdm tqdm/__init__.py' 'python-numba numba/__init__.py' 'python-pandas pandas/__init__.py' \
    'python-pygraphviz pygraphviz/__init__.py' 'python-yaml yaml/__init__.py' 'python-yaml _yaml/__init__.py' \
    'python-diagrams diagrams/__init__.py' 'python-diagrams diagrams/aws/__init__.py'; do
    printf 'extra\t%s\t1-1\tusr/lib/python3.14/site-packages/%s\n' "${line% *}" "${line#* }"
  done >>"$MOCK_PACMAN_FILES"
  printf 'core\tpython\t3.14.10-1\tusr/lib/python3.14/%s\n' json/__init__.py os.py lib-dynload/_json.cpython-314-x86_64-linux-gnu.so \
    >>"$MOCK_PACMAN_FILES"
  printf '%s\n' 'python-numba 0.62.1-1 extra' 'python-pandas 2.3.3-1 extra' 'python-diagrams 0.25.1-1 extra' >>"$MOCK_PACMAN_SYNC"
}

# Helper: a wheel demo 1.0 with a package, an entry point, a plugin that nothing imports and a script
demo_wheel() {
  local w="$TEST_TMPDIR/wheel"
  mkdir -p "$w/demo/plugins" "$w/demo-1.0.dist-info" "$w/demo-1.0.data/scripts"
  printf '%s\n' 'from . import core' >"$w/demo/__init__.py"
  printf '%s\n' 'import json, sys, builtins' >"$w/demo/core.py"
  printf '%s\n' 'import tqdm' 'try:' '    import numba' 'except ImportError:' '    numba = None' 'def main():' '    import yaml' >"$w/demo/cli.py"
  printf '%s\n' 'import pandas' >"$w/demo/plugins/extra.py"
  printf '%s\n' '[console_scripts]' 'demo = demo.cli:main' '[demo.plugins]' 'extra = demo.plugins.extra' >"$w/demo-1.0.dist-info/entry_points.txt"
  printf '%s\n' '#!/usr/bin/python' 'import os' >"$w/demo-1.0.data/scripts/demo-run"
  pypi_fake_wheel demo 1.0 "$w"
}

# Helper: runs python_imports for package pkg of registry $2 at version $3 with .SRCINFO $1
run_imports() {
  create_test_package "pkg" "pypi" "upstream:
  registry: $2
${4:-}"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; python_imports "$@"' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/pkg.yml" "$1" "$2" "$3"
}

@test "pyrules.sh: python_imports notes required and optional imports that depends and optdepends miss" {
  imports_env
  demo_wheel
  {
    printf 'pkgbase = python-demo\n\tpkgver = 1.0\n\tpkgrel = 1\n\tdepends = python\n\tdepends = python-yaml\n'
    printf '\toptdepends = python-numba: faster\n\npkgname = python-demo\n'
  } >"$TEST_TMPDIR/demo.SRCINFO"
  run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 1.0
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\timport pandas (optional): python-pandas in neither depends nor optdepends\nnotice\timport tqdm: python-tqdm not in depends' ]
}

@test "pyrules.sh: python_imports finds the imports of a script of the wheel" {
  imports_env
  local w="$TEST_TMPDIR/wheel"
  mkdir -p "$w/kubediagrams-0.9.0.data/scripts" "$w/kubediagrams-0.9.0.dist-info"
  printf '%s\n' '#!python' 'import argparse' 'import pygraphviz' 'import yaml' 'import diagrams' 'from diagrams.aws.enablement import X' \
    >"$w/kubediagrams-0.9.0.data/scripts/kube-diagrams"
  printf '%s\n' '#!/bin/bash' 'kube-diagrams "$@"' >"$w/kubediagrams-0.9.0.data/scripts/helm-diagrams"
  printf 'Metadata-Version: 2.4\n' >"$w/kubediagrams-0.9.0.dist-info/METADATA"
  pypi_fake_wheel KubeDiagrams 0.9.0 "$w"
  printf 'core\tpython\t3.14.10-1\tusr/lib/python3.14/argparse.py\n' >>"$MOCK_PACMAN_FILES"
  unmet_srcinfo "$TEST_TMPDIR/k.SRCINFO" kube-diagrams bash python python-diagrams python-pygraphviz python-yaml
  run_imports "$TEST_TMPDIR/k.SRCINFO" KubeDiagrams 0.9.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  unmet_srcinfo "$TEST_TMPDIR/k.SRCINFO" kube-diagrams bash python python-diagrams python-yaml
  rm -rf "$AURTOMATOR_RUN_CACHE"/*
  run_imports "$TEST_TMPDIR/k.SRCINFO" KubeDiagrams 0.9.0
  [ "$output" = $'notice\timport pygraphviz: python-pygraphviz not in depends' ]
}

@test "pyrules.sh: python_imports notes a module no package owns and a file that does not parse" {
  imports_env
  local w="$TEST_TMPDIR/wheel"
  mkdir -p "$w/demo"
  printf '%s\n' 'import nowhere' 'import demo.broken' >"$w/demo/__init__.py"
  printf '%s\n' 'def f(:' >"$w/demo/broken.py"
  pypi_fake_wheel demo 1.0 "$w"
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python
  run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 1.0
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = notice$'\t'"import nowhere: no package owns it" ]
  [[ "${lines[1]}" == notice$'\t'"imports: demo/broken.py does not parse: "* ]]
  [ "${#lines[@]}" -eq 2 ]
}

@test "pyrules.sh: python_imports reads an sdist without tests, docs and python.skip, and the modules of src/" {
  imports_env
  local s="$TEST_TMPDIR/sdist" stem=demo-2.0
  mkdir -p "$s/$stem/src/demo" "$s/$stem/tests" "$s/$stem/docs" "$s/$stem/tools" "$s/$stem/bin"
  printf '%s\n' 'import tqdm' 'from demo import util' >"$s/$stem/src/demo/__init__.py"
  printf '%s\n' 'import demo' >"$s/$stem/src/demo/util.py"
  printf '%s\n' 'import pytest' >"$s/$stem/tests/test_a.py"
  printf '%s\n' 'import sphinx' >"$s/$stem/docs/conf.py"
  printf '%s\n' 'import pandas' >"$s/$stem/tools/gen.py"
  printf '%s\n' '#!/usr/bin/env python3' 'import numba' >"$s/$stem/bin/demo"
  printf 'Metadata-Version: 2.4\nName: demo\n' >"$s/$stem/PKG-INFO"
  bsdtar -czf "$MOCK_FILES_DIR/$stem.tar.gz" -C "$s" "$stem"
  pypi_fake_file demo 2.0 "$MOCK_FILES_DIR/$stem.tar.gz" false
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python python-tqdm
  run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 2.0 "python:
  skip:
    - tools"
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\timport numba: python-numba not in depends' ]
}

# Builds and test runners read these files of an sdist, and the build installs none of them
@test "pyrules.sh: python_imports reads no build and test files at the root of an sdist" {
  imports_env
  local s="$TEST_TMPDIR/sdist" stem=demo-2.0
  mkdir -p "$s/$stem/demo"
  printf '%s\n' 'import tqdm' >"$s/$stem/demo/__init__.py"
  printf '%s\n' 'import setuptools' >"$s/$stem/setup.py"
  printf '%s\n' 'import pytest' >"$s/$stem/conftest.py"
  printf '%s\n' 'import nox' >"$s/$stem/noxfile.py"
  printf '%s\n' 'import invoke' >"$s/$stem/tasks.py"
  printf '%s\n' 'import fabric' >"$s/$stem/fabfile.py"
  printf 'Metadata-Version: 2.4\nName: demo\n' >"$s/$stem/PKG-INFO"
  bsdtar -czf "$MOCK_FILES_DIR/$stem.tar.gz" -C "$s" "$stem"
  pypi_fake_file demo 2.0 "$MOCK_FILES_DIR/$stem.tar.gz" false
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python python-tqdm
  run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 2.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Helper: an sdist demo 2.0 whose package imports module evil, a link at the top of the archive to a
# file outside it, with the files database of imports_env
evil_sdist() {
  imports_env
  local s="$TEST_TMPDIR/sdist" stem=demo-2.0
  mkdir -p "$s/$stem/demo"
  printf '%s\n' 'import evil' >"$s/$stem/demo/__init__.py"
  printf '%s\n' 'import secretmod' >"$TEST_TMPDIR/outside.py"
  ln -s "$TEST_TMPDIR/outside.py" "$s/$stem/evil.py"
  printf 'Metadata-Version: 2.4\nName: demo\n' >"$s/$stem/PKG-INFO"
  bsdtar -czf "$MOCK_FILES_DIR/$stem.tar.gz" -C "$s" "$stem"
  pypi_fake_file demo 2.0 "$MOCK_FILES_DIR/$stem.tar.gz" false
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python
}

# Links of an archive could make the rule read any file of the runner, so they count as no module of it
@test "pyrules.sh: python_imports reads no link of the archive" {
  evil_sdist
  run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 2.0
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\timport evil: no package owns it' ]
}

# python.skip names paths in the tree, and rm -rf would take a path outside it
@test "pyrules.sh: python_imports removes no path of python.skip outside the tree" {
  evil_sdist
  mkdir -p "$AURTOMATOR_RUN_CACHE/keep"
  : >"$AURTOMATOR_RUN_CACHE/keep/file"
  run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 2.0 "python:
  skip:
    - ../../../keep
    - $AURTOMATOR_RUN_CACHE/keep"
  [ "$status" -eq 0 ]
  [ -f "$AURTOMATOR_RUN_CACHE/keep/file" ]
}

# Helper: a bsdtar first in PATH that lists 16 MiB with BSDTAR_LIST_BIG set and fails each extraction
# with BSDTAR_EXTRACT_FAIL set, and runs the real one otherwise
mock_bsdtar() {
  local real
  real=$(type -a -P bsdtar | grep -vF -m 1 "$MOCK_DIR/")
  cat >"$MOCK_DIR/bsdtar" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" -tvf "*) [[ -z "\${BSDTAR_LIST_BIG:-}" ]] || { head -c \$((16384 * 1024)) /dev/zero | tr '\0' a; exit 0; } ;;
  *" -xf "*) [[ -z "\${BSDTAR_EXTRACT_FAIL:-}" ]] || { echo "bsdtar: demo/x.py: Can't create 'demo/x.py'" >&2; exit 1; } ;;
esac
exec "$real" "\$@"
EOF
  chmod +x "$MOCK_DIR/bsdtar"
}

# The coverage shims of CI run the helpers without -S and --disable-gems, and bundle exec sets RUBYOPT,
# so this test runs stand-ins of the helpers that print the flags, outside both
@test "pyrules.sh, rbrules.sh: the helpers run without site-packages and RubyGems" {
  unset COVERAGE_FILE SIMPLECOV_HELPER_DIR RUBYOPT
  printf '%s\n' 'import sys' 'if sys.argv[1:] == ["--stdlib"]:' '    sys.exit(0)' \
    'for name in sys.stdin.buffer.read().split(b"\0")[:-1]:' \
    '    print(f"import\t{name.decode()}\tsite{sys.flags.no_site}isolated{sys.flags.isolated}\tmodule")' \
    >"$TEST_TMPDIR/py-stand-in"
  printf '%s\n' 'exit 0 if ARGV == ["--builtin"]' '$stdin.read.split("\0").each do |name|' \
    '  puts "require\t#{name}\trequire\tgems_#{defined?(Gem) ? "on" : "off"}\tmodule"' 'end' >"$TEST_TMPDIR/rb-stand-in"
  cp --remove-destination "$TEST_TMPDIR/py-stand-in" "$TEST_TMPDIR/scripts/lib/py_imports.py"
  cp --remove-destination "$TEST_TMPDIR/rb-stand-in" "$TEST_TMPDIR/scripts/lib/rb_requires.rb"
  imports_env
  demo_wheel
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python
  run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 1.0
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\timport site1isolated1: no package owns it' ]
  gems_env 1.3.2
  bashcov_gem
  unmet_srcinfo "$TEST_TMPDIR/b.SRCINFO" bashcov bash ruby ruby-simplecov
  run_ruby_imports "$TEST_TMPDIR/b.SRCINFO"
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\trequire gems_off: no package owns it' ]
}

# A listing of 16 MiB stops at the limit of its size, and an extraction can fail for one member
@test "pyrules.sh: python_imports reads nothing from a listing of 16 MiB or a failed extraction" {
  evil_sdist
  mock_bsdtar
  BSDTAR_LIST_BIG=1 run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 2.0
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\timports: bsdtar cannot list demo-2.0.tar.gz, not read' ]
  BSDTAR_EXTRACT_FAIL=1 run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 2.0
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\timports: bsdtar cannot extract demo-2.0.tar.gz, not read' ]
}

# Releases can hold files whose parse runs past any limit, and site-packages and RubyGems would
# load code of the runner into the helpers
@test "pyrules.sh, rbrules.sh: the helpers run under timeout 60 with -I -S and --disable-gems" {
  local real
  real=$(type -a -P timeout | grep -vF -m 1 "$MOCK_DIR/")
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexec "%s" "$@"\n' "$TEST_TMPDIR/timeout.log" "$real" \
    >"$MOCK_DIR/timeout"
  chmod +x "$MOCK_DIR/timeout"
  imports_env
  demo_wheel
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python
  run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 1.0
  [ "$status" -eq 0 ]
  gems_env 1.3.2
  bashcov_gem
  unmet_srcinfo "$TEST_TMPDIR/b.SRCINFO" bashcov bash ruby ruby-simplecov
  run_ruby_imports "$TEST_TMPDIR/b.SRCINFO"
  [ "$status" -eq 0 ]
  [ "$(sed 's| /.*||' "$TEST_TMPDIR/timeout.log")" = "$(printf '%s\n' '60 python3 -I -S' '60 python3 -I -S' '60 ruby --disable-gems' \
    '60 ruby --disable-gems')" ]
}

@test "pyrules.sh: python_imports fails on a wheel that does not match its sha256" {
  imports_env
  demo_wheel
  printf 'x' >>"$MOCK_FILES_DIR/demo-1.0-py3-none-any.whl"
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python
  run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 1.0
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"demo-1.0-py3-none-any.whl does not match its sha256"* ]]
}

@test "pyrules.sh: python_imports reads no release past 20 MB of Python files" {
  imports_env
  mkdir -p "$TEST_TMPDIR/wheel/demo"
  truncate -s 21M "$TEST_TMPDIR/wheel/demo/__init__.py"
  pypi_fake_wheel demo 1.0 "$TEST_TMPDIR/wheel"
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python
  run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 1.0
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\timports: the release holds more than 20 MB of Python files, not read' ]
}

# The count takes every member that the extraction takes
@test "pyrules.sh: python_imports counts entry_points.txt and top-level scripts toward the 20 MB" {
  imports_env
  local name
  for name in demo/big_entry_points.txt scripts/huge; do
    rm -rf "$TEST_TMPDIR/wheel" "$MOCK_FILES_DIR"/* "$AURTOMATOR_RUN_CACHE"/*
    cp "$FIXTURES_DIR/aur/rpc.json" "$MOCK_FILES_DIR/aur-rpc.json"
    mkdir -p "$TEST_TMPDIR/wheel/${name%/*}"
    printf 'import os\n' >"$TEST_TMPDIR/wheel/demo.py"
    truncate -s 21M "$TEST_TMPDIR/wheel/$name"
    pypi_fake_wheel demo 1.0 "$TEST_TMPDIR/wheel"
    unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python
    run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 1.0
    [ "$output" = $'notice\timports: the release holds more than 20 MB of Python files, not read' ] || {
      echo "$name: $output"
      return 1
    }
  done
}

# Owner names with spaces shift the columns of bsdtar -tv
@test "pyrules.sh: python_imports reads no sdist past 20 MB of Python files, whatever the owner names of its files" {
  imports_env
  local s="$TEST_TMPDIR/sdist" stem=demo-2.0 owner
  for owner in builder 'a b c'; do
    rm -rf "$s" "$MOCK_FILES_DIR"/* "$AURTOMATOR_RUN_CACHE"/*
    cp "$FIXTURES_DIR/aur/rpc.json" "$MOCK_FILES_DIR/aur-rpc.json"
    mkdir -p "$s/$stem/demo"
    printf 'Metadata-Version: 2.4\nName: demo\n' >"$s/$stem/PKG-INFO"
    truncate -s 21M "$s/$stem/demo/__init__.py"
    bsdtar --uname "$owner" --gname "$owner" -czf "$MOCK_FILES_DIR/$stem.tar.gz" -C "$s" "$stem"
    pypi_fake_file demo 2.0 "$MOCK_FILES_DIR/$stem.tar.gz" false
    unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python
    run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 2.0
    [ "$output" = $'notice\timports: the release holds more than 20 MB of Python files, not read' ] || {
      echo "$owner: $output"
      return 1
    }
  done
}

@test "pyrules.sh: python_imports reads no release of more than 20000 Python files" {
  imports_env
  mkdir -p "$TEST_TMPDIR/wheel/demo"
  (cd "$TEST_TMPDIR/wheel/demo" && touch m{1..20001}.py)
  pypi_fake_wheel demo 1.0 "$TEST_TMPDIR/wheel"
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python
  run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 1.0
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\timports: the release holds more than 20000 Python files and scripts, not read' ]
}

@test "pyrules.sh: python_imports gives one note without python3, within 60 s or without a files database" {
  imports_env
  demo_wheel
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python
  printf '#!/usr/bin/env bash\nexit 127\n' >"$MOCK_DIR/python3"
  chmod +x "$MOCK_DIR/python3"
  run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 1.0
  [ "$output" = $'notice\timports: python3 is not installed, not read' ]
  printf '#!/usr/bin/env bash\nexit 124\n' >"$MOCK_DIR/python3"
  rm -rf "$AURTOMATOR_RUN_CACHE"/*
  run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 1.0
  [ "$output" = $'notice\timports: not read within 60 s' ]
  rm "$MOCK_DIR/python3"
  export MOCK_PACMAN_NO_FILES=1
  rm -rf "$AURTOMATOR_RUN_CACHE"/*
  run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 1.0
  [ "$output" = $'notice\timports: pacman has no files database, not read' ]
}

# Readers block on a FIFO until a writer opens it; the python3 here lists what py_imports.py would meet
@test "pyrules.sh: python_imports drops members of the archive that are no regular file or directory" {
  imports_env
  local s="$TEST_TMPDIR/sdist-demo-1.0/demo-1.0"
  mkdir -p "$s/demo"
  printf 'import tqdm\n' >"$s/demo/__init__.py"
  mkfifo "$s/demo/pipe.py" "$s/demo/pipe"
  pypi_fake_sdist demo 1.0 $'Metadata-Version: 2.2\nName: demo\nVersion: 1.0\n'
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" python-demo python
  printf '#!/usr/bin/env bash\n[[ "$4" == --stdlib ]] || find "$4" ! -type f ! -type d >>"%s/special"\nexec /usr/bin/python3 "$@"\n' \
    "$TEST_TMPDIR" >"$MOCK_DIR/python3"
  chmod +x "$MOCK_DIR/python3"
  run_imports "$TEST_TMPDIR/demo.SRCINFO" demo 1.0
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\timport tqdm: python-tqdm not in depends' ]
  [ -e "$TEST_TMPDIR/special" ]
  [ ! -s "$TEST_TMPDIR/special" ]
}

@test "lib.sh: fired_alerts fires requires: imports as a notice" {
  imports_env
  demo_wheel
  # The rule unmet reads the metadata of the wheel, which lists no requirement
  printf 'Metadata-Version: 2.4\nName: demo\n' >"$MOCK_FILES_DIR/demo-1.0-py3-none-any.whl.metadata"
  S="$(sha256sum "$MOCK_FILES_DIR/demo-1.0-py3-none-any.whl.metadata" | cut -d" " -f1)" \
    yq -i -o json '.files[0]."core-metadata" = {"sha256": strenv(S)}' "$MOCK_FILES_DIR/simple/demo.json"
  {
    printf 'pkgbase = demo\n\tpkgver = 1.0\n\tpkgrel = 1\n\tdepends = python\n\tdepends = python-yaml\n'
    printf '\toptdepends = python-numba: faster\n\npkgname = demo\n'
  } >"$TEST_TMPDIR/demo.SRCINFO"
  aur_srcinfo_remote demo "$TEST_TMPDIR/demo.SRCINFO"
  create_test_package "demo" "pypi" "upstream:
  registry: demo
alerts:
  - requires: imports
    note: Check the imports"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" "" 1.0' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/demo.yml"
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\tCheck the imports: import pandas (optional): python-pandas in neither depends nor optdepends; import tqdm: python-tqdm not in depends' ]
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" 0.9 1.0 offline' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/demo.yml"
  [ -z "$output" ]
  [ ! -e "$CURL_ARGS_LOG" ]
}

# === python sources ===

# Helper: an sdist demo-1.1.0.tar.gz in MOCK_FILES_DIR whose pyproject.toml, at path $2 under its top
# directory, holds text $1, and the .SRCINFO of demo at 1.0.0 whose first source is source $3
pyproject_env() {
  local dir="$TEST_TMPDIR/src/demo-1.1.0"
  unmet_env
  mkdir -p "$dir/$(dirname "$2")"
  printf '%s' "$1" >"$dir/$2"
  printf 'import click\n' >"$dir/demo.py"
  bsdtar -czf "$MOCK_FILES_DIR/demo-1.1.0.tar.gz" -C "$TEST_TMPDIR/src" demo-1.1.0
  {
    printf 'pkgbase = demo\n\tpkgver = 1.0.0\n\tpkgrel = 1\n\tarch = any\n\tdepends = python\n\tdepends = python-click\n'
    printf '\tsource = %s\n\tsource = local.patch\n\npkgname = demo\n' "${3:-demo-1.0.0.tar.gz::https://files.pythonhosted.org/packages/src/demo-1.0.0.tar.gz}"
  } >"$TEST_TMPDIR/demo.SRCINFO"
}

# Helper: runs python_source for package demo with the YAML lines $1, version 1.1.0 and
# $TEST_TMPDIR/demo.SRCINFO, and prints the source, project, version and headers
run_source() {
  create_test_package "demo" "github-release" "upstream:
  project: o/demo
$1"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; python_source "$1" 1.1.0 "$2" &&
    printf "%s\n" "$PY_SOURCE $PY_PROJECT $PY_VERSION" "$PY_HEADERS"' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/demo.yml" \
    "$TEST_TMPDIR/demo.SRCINFO"
}

TOML=$'[build-system]\nrequires = ["setuptools"]\n\n[project]\nname = "demo"\ndescription = """A demo with [brackets],\n"quotes" and # signs."""\nrequires-python = ">=3.10"  # comment\nauthors = [{name = "A", email = "a@example.org"}]\nkeywords = ["a", "b"]\ndependencies = [\n  "click>=8",  # the CLI\n  \'rich\',\n  # a comment line\n]\ndynamic = ["version"]\n\n[project.optional-dependencies]\ndocs = ["sphinx"]\n'

# Helper: _toml_project of the text $1 prints the lines $2
toml_reads() {
  printf '%s' "$1" >"$TEST_TMPDIR/case.toml"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; _toml_project "$1"' "$TEST_TMPDIR" "$TEST_TMPDIR/case.toml"
  [ "$status" -eq 0 ]
  [ "$output" = "$2" ] || {
    echo "read ${1@Q} as ${output@Q}"
    return 1
  }
}

# tomllib reads every one of these forms, and real archives hold CRLF files
@test "pyrules.sh: _toml_project reads CRLF, dotted keys, inline and quoted tables, and brackets in values" {
  local demo=$'name\tdemo\nhas\t\ndep\ta'
  toml_reads $'[project]\r\nname = "demo"\r\ndependencies = ["a",\r\n "b"]\r\n' $'name\tdemo\nhas\t\ndep\ta\ndep\tb'
  toml_reads $'project.name = "demo"\nproject.dependencies = ["a"]\n' "$demo"
  toml_reads $'project = { name = "demo", dependencies = ["a"] }\n' "$demo"
  toml_reads $'["project"]\nname = "demo"\ndependencies = ["a"]\n' "$demo"
  toml_reads $'[ \'project\' ]  # the table\nname = "demo"\ndependencies = ["a"]\n' "$demo"
  toml_reads $'[tool.x]\ndoc = """\n[project]\ndependencies = ["evil"]\n"""\n[project]\nname = "demo"\ndependencies = ["a"]\n' "$demo"
  toml_reads $'[project]\nname = "demo"\ndescription = """\n[tool.other]\nline\n"""\ndependencies = ["a"]\n' "$demo"
  toml_reads $'[project]\nname = "demo"\nkeywords = [\n  ["x"],\n]\ndependencies = ["a"]\n' "$demo"
  toml_reads $'[project]\nname = "demo"\ndependencies = ["a"]\n[[project.authors]]\nname = "x"\n[tool.y]\nname = "y"\n' "$demo"
  toml_reads $'[project.urls]\nhome = "https://x"\n[project]\nname = "demo"\nurls.docs = "https://y"\ndependencies = ["a"]\n' "$demo"
}

# The rules write these values into headers, where an escape or a control character changes their meaning
@test "pyrules.sh: python_source refuses escapes and control characters in pyproject.toml values" {
  local value
  for value in 'demo\u0062' $'demo\x01'; do
    pyproject_env "[project]"$'\n'"name = \"$value\""$'\ndependencies = ["click"]\n' pyproject.toml
    run_source $'python:\n  pyproject: pyproject.toml'
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"a value holds an escape or a control character"* ]]
  done
}

# The rule removes directories under the one of the file, and validate-pkg.sh does not run in a check
@test "pyrules.sh: python_source refuses a python.pyproject path outside the archive" {
  local path
  pyproject_env "$TOML" pyproject.toml
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  for path in ../../x/pyproject.toml /etc/pyproject.toml 'a b.toml' pyproject.json; do
    run_source "python:
  pyproject: '$path'"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"packages/demo.yml: python.pyproject must be a relative path to a .toml file without ..: "* ]]
  done
  [ ! -e "$CURL_ARGS_LOG" ]
}

@test "pyrules.sh: python_source reads the static dependencies of pyproject.toml in the source archive" {
  pyproject_env "$TOML" pyproject.toml
  run_source "python:
  pyproject: pyproject.toml"
  [ "$status" -eq 0 ]
  [ "$output" = $'pyproject demo 1.1.0\nName: demo\nRequires-Python: >=3.10\nRequires-Dist: click>=8\nRequires-Dist: rich' ]
}

@test "pyrules.sh: python_source reads the archive of the new upstream version for a package with pkgver_format" {
  pyproject_env "$TOML" pyproject.toml
  sed -i 's/^\tpkgver = 1\.0\.0$/\tpkgver = 4.1.0.0/' "$TEST_TMPDIR/demo.SRCINFO"
  run_source $'python:\n  pyproject: pyproject.toml\npkgver_format: \'4.%s\''
  [ "$status" -eq 0 ]
  [ "$output" = $'pyproject demo 1.1.0\nName: demo\nRequires-Python: >=3.10\nRequires-Dist: click>=8\nRequires-Dist: rich' ]
}

@test "pyrules.sh: python_source reads a pyproject.toml below the top directory" {
  pyproject_env "$TOML" python/pyproject.toml
  run_source "python:
  pyproject: python/pyproject.toml"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "pyproject demo 1.1.0" ]
}

@test "pyrules.sh: python_source fails on dynamic or missing dependencies and on a source of git" {
  local message="packages/demo.yml: python.pyproject reads no static dependencies from pyproject.toml"
  pyproject_env $'[project]\nname = "demo"\ndynamic = ["version", "dependencies"]\ndependencies = ["x"]\n' pyproject.toml
  run_source $'python:\n  pyproject: pyproject.toml'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"$message"* ]]
  pyproject_env $'[project]\nname = "demo"\n[tool.x]\ndependencies = ["x"]\n' pyproject.toml
  run_source $'python:\n  pyproject: pyproject.toml'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"$message"* ]]
  pyproject_env "$TOML" pyproject.toml 'demo::git+https://github.com/o/demo.git#tag=v1.0.0'
  run_source $'python:\n  pyproject: pyproject.toml'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"$message"* ]]
}

@test "pyrules.sh: python_source refuses a pyproject.toml past 256 KiB or nested past 32 levels" {
  local deep big
  deep=$(printf '[project]\nname = "demo"\ndependencies = []\nx = %s1%s\n' "$(printf '[%.0s' {1..40})" "$(printf ']%.0s' {1..40})")
  pyproject_env "$deep" pyproject.toml
  run_source $'python:\n  pyproject: pyproject.toml'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"python.pyproject reads no static dependencies from pyproject.toml: values nest deeper than 32 levels"* ]]
  big=$(printf '[project]\nname = "demo"\ndependencies = []\ndescription = "%s"\n' "$(head -c 270000 /dev/zero | tr '\0' x)")
  pyproject_env "$big" pyproject.toml
  run_source $'python:\n  pyproject: pyproject.toml'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"python.pyproject reads no static dependencies from pyproject.toml: demo-1.1.0/pyproject.toml holds more than 256 KiB"* ]]
}

@test "pyrules.sh: python_source takes upstream.registry, python.pypi with its release, or none" {
  unmet_env
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" demo python
  run_source $'python:\n  pypi: KubeDiagrams'
  [ "$output" = "pypi KubeDiagrams 1.1.0" ]
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run_source $'python:\n  pypi: KubeDiagrams\n  release: newest'
  [ "$output" = "pypi KubeDiagrams 3.2.1" ]
  grep -q 'pypi.org/pypi/KubeDiagrams/json$' "$CURL_ARGS_LOG"
  run_source 'python: none'
  [ "$output" = "none  " ]
  run_source ''
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"packages/demo.yml: its depends hold Python packages, so set python.pypi, python.pyproject or python: none"* ]]
  create_test_package "demo" "pypi" "upstream:
  registry: zensical"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; python_source "$1" 0.1.3 "$2" && echo "$PY_SOURCE $PY_PROJECT $PY_VERSION"' \
    "$TEST_TMPDIR" "$TEST_TMPDIR/packages/demo.yml" "$TEST_TMPDIR/demo.SRCINFO"
  [ "$output" = "pypi zensical 0.1.3" ]
}

# Releases without metadata that lists the requirements fail the check, and none is the way out
@test "pyrules.sh: python_source takes python: none for strategy pypi too" {
  unmet_env
  unmet_srcinfo "$TEST_TMPDIR/demo.SRCINFO" demo python
  create_test_package "demo" "pypi" "upstream:
  registry: zensical
python: none"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; python_source "$1" 0.1.3 "$2" && echo "$PY_SOURCE $PY_PROJECT $PY_VERSION"' \
    "$TEST_TMPDIR" "$TEST_TMPDIR/packages/demo.yml" "$TEST_TMPDIR/demo.SRCINFO"
  [ "$status" -eq 0 ]
  [ "$output" = "none  " ]
}

@test "rbrules.sh: ruby_source takes ruby: none for strategy rubygems too" {
  create_test_package "demo" "rubygems" "upstream:
  registry: demo
ruby: none"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; ruby_source "$1" 1.0.0 && echo "$RB_SOURCE $RB_GEM $RB_VERSION"' \
    "$TEST_TMPDIR" "$TEST_TMPDIR/packages/demo.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "none  1.0.0" ]
  create_test_package "demo" "rubygems" "upstream:
  registry: demo"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; ruby_source "$1" 1.0.0 && echo "$RB_SOURCE $RB_GEM $RB_VERSION"' \
    "$TEST_TMPDIR" "$TEST_TMPDIR/packages/demo.yml"
  [ "$output" = "gem demo 1.0.0" ]
}

# Helper: package kube-diagrams of a strategy that finds 1.1.0, at current 1.0.0 with the YAML lines
# $1, whose AUR .SRCINFO has the depends after it
python_package() {
  unmet_env
  printf 'python-diagrams 0.25.1-1 extra\n' >>"$MOCK_PACMAN_SYNC"
  stand_in_strategy step 1.1.0
  unmet_srcinfo "$TEST_TMPDIR/k.SRCINFO" kube-diagrams "${@:2}"
  aur_srcinfo_remote kube-diagrams "$TEST_TMPDIR/k.SRCINFO"
  create_test_package "kube-diagrams" "step" "current: '1.0.0'
allow_missing_arch: false
$1"
}

# The status shows in a code block of the issue, where the mark of log_err is noise
@test "check-all: fails the check of a package whose depends hold Python and that names no source" {
  python_package "" bash python python-yaml
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/kube-diagrams")" = "check_failed: packages/kube-diagrams.yml: its depends hold Python packages, so set python.pypi, python.pyproject or python: none" ]
}

# The check job of CI holds the token and writes every status, so the rules that download and
# parse releases run in a job of their own for each package
@test "check-all: --rules-later runs no requires rule and lists the packages that need them in _rules" {
  python_package $'python:\n  pypi: KubeDiagrams\nalerts:\n  - match: "^1[.]1"\n    note: Read the changelog' \
    bash python python-yaml python-diagrams
  pypi_fake KubeDiagrams 1.0.0 PyYAML diagrams
  pypi_fake KubeDiagrams 1.1.0 PyYAML diagrams graphviz2drawio
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run "$TEST_TMPDIR/scripts/check-all.sh" --rules-later
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/kube-diagrams")" = "new_version: 1.1.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/_alerts")" = $'kube-diagrams\tnotice\tRead the changelog' ]
  [ "$(cat "$TEST_TMPDIR/.status/_rules")" = "kube-diagrams" ]
  [[ ! -e "$CURL_ARGS_LOG" ]] || [ "$(grep -c -e pypi.org -e pythonhosted "$CURL_ARGS_LOG")" = 0 ]
  python_package "python: none" bash python python-yaml
  run "$TEST_TMPDIR/scripts/check-all.sh" --rules-later
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/kube-diagrams")" = "new_version: 1.1.0" ]
  [ ! -e "$TEST_TMPDIR/.status/_rules" ]
  run "$TEST_TMPDIR/scripts/check-all.sh" --rules-later --publish "$TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [ "$output" = "--rules-later goes with a check run alone" ]
}

# The issues job keeps one issue for the packages whose next version fails its check for a missing key
@test "check-all: --rules-later lists in _requirements the packages whose YAML names no source of their requirements" {
  local yaml
  aur_meta '{"Name":"kube-diagrams","PackageBase":"kube-diagrams","Depends":["bash","python"]}'
  python_package "" bash python python-yaml
  run "$TEST_TMPDIR/scripts/check-all.sh" --rules-later
  [ "$(cat "$TEST_TMPDIR/.status/_requirements")" = $'kube-diagrams\tpython' ]
  python_package "" bash python ruby-rack
  run "$TEST_TMPDIR/scripts/check-all.sh" --rules-later
  [ "$(cat "$TEST_TMPDIR/.status/_requirements")" = $'kube-diagrams\tpython\nkube-diagrams\truby' ]
  # The keys that python_source and ruby_source take
  for yaml in $'python: none\nruby: none' $'python:\n  pypi: KubeDiagrams\nruby:\n  gem: rack' \
    $'python:\n  pyproject: pyproject.toml\nruby: none'; do
    rm -rf "$TEST_TMPDIR/aur-remote" "$TEST_TMPDIR/aur-work-kube-diagrams"
    python_package "$yaml" bash python ruby-rack
    run "$TEST_TMPDIR/scripts/check-all.sh" --rules-later
    [ -e "$TEST_TMPDIR/.status/_requirements" ] && [ ! -s "$TEST_TMPDIR/.status/_requirements" ] || {
      echo "listed: $yaml"
      return 1
    }
  done
  # Depends of the AUR metadata file without Python or Ruby need no clone of the AUR
  python_package "" bash python
  aur_meta '{"Name":"kube-diagrams","PackageBase":"kube-diagrams","Depends":["bash"]}'
  run "$TEST_TMPDIR/scripts/check-all.sh" --rules-later
  [ ! -s "$TEST_TMPDIR/.status/_requirements" ]
  # Without the metadata file the run cannot tell, so it writes no list and the issue stays
  rm "$MOCK_FILES_DIR/packages-meta-ext-v1.json.gz"
  run "$TEST_TMPDIR/scripts/check-all.sh" --rules-later
  [ ! -e "$TEST_TMPDIR/.status/_requirements" ]
  [[ "$output" == *"Could not read the AUR, so the run lists no packages that miss the source of their requirements"* ]]
  # Runs without --rules-later read no metadata file
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ ! -e "$TEST_TMPDIR/.status/_requirements" ]
  ! grep -q packages-meta "$CURL_ARGS_LOG"
}

# A repository without packages has no package that misses a key, so the issue closes
@test "check-all: --rules-later lists no package and reads no AUR without packages" {
  aur_meta
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run "$TEST_TMPDIR/scripts/check-all.sh" --rules-later
  [ "$status" -eq 0 ]
  [ -e "$TEST_TMPDIR/.status/_requirements" ]
  [ ! -s "$TEST_TMPDIR/.status/_requirements" ]
  [[ "$output" != *"Could not read the AUR"* ]]
  run grep -q packages-meta "$CURL_ARGS_LOG"
  [ "$status" -ne 0 ]
}

# The list runs after the loop in the same 30 minutes of the job, so it takes the share of the budget
# that the loop leaves it, and a run without time for it leaves the issue as it is
@test "check-all: lists the packages that miss a key within the time the loop leaves it" {
  local start
  aur_meta '{"Name":"kube-diagrams","PackageBase":"kube-diagrams","Depends":["bash","python"]}'
  python_package "" bash python python-yaml
  AURTOMATOR_CHECK_BUDGET=0 run "$TEST_TMPDIR/scripts/check-all.sh" --rules-later
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/.status/_requirements" ]
  [[ "$output" == *"The run has no time left to list the packages that miss the source of their requirements"* ]]
  start=$SECONDS
  MOCK_META_SLEEP=10 AURTOMATOR_CHECK_BUDGET=2 AURTOMATOR_REQUIREMENTS_BUDGET=2 run "$TEST_TMPDIR/scripts/check-all.sh" --rules-later
  [ "$status" -eq 0 ]
  ((SECONDS - start < 8))
  [ ! -e "$TEST_TMPDIR/.status/_requirements" ]
  [[ "$output" == *"The run has no time left to list the packages that miss the source of their requirements"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/kube-diagrams")" = "unchecked: the check ran out of its 0 minutes in this run" ]
  AURTOMATOR_CHECK_BUDGET=60 AURTOMATOR_REQUIREMENTS_BUDGET=60 run "$TEST_TMPDIR/scripts/check-all.sh" --rules-later
  [ "$(cat "$TEST_TMPDIR/.status/kube-diagrams")" = "unchecked: the check ran out of its 1 minutes in this run" ]
  [ "$(cat "$TEST_TMPDIR/.status/_requirements")" = $'kube-diagrams\tpython' ]
}

# Writes the GraphQL answer for github-release packages a, at current 1.0.0 with no regex, and b, at
# 1.0.0 with a regex, of owner/a and owner/b; the mock answers REST /releases/latest with v2.0.0
graphql_packages() {
  create_test_package a github-release "upstream:
  project: owner/a
current: '1.0.0'"
  create_test_package b github-release "upstream:
  project: owner/b
  tag_version_regex: '^v([0-9.]+)\$'
current: '1.0.0'"
  local node='{"name":"x","isDraft":false,"isPrerelease":false,"publishedAt":"2026-01-02T00:00:00Z","createdAt":"2026-01-01T00:00:00Z"'
  printf '%s\n' "{\"data\":{\"r0\":{\"latestRelease\":$node,\"tagName\":\"v3.0.0\",\"description\":\"notes\"},\"releases\":{\"totalCount\":0,\"nodes\":[]}},\"r1\":{\"latestRelease\":null,\"releases\":{\"totalCount\":2,\"nodes\":[$node,\"tagName\":\"v5.0.0\"},$node,\"tagName\":\"v4.0.0\"}]}}}}" \
    >"$MOCK_FILES_DIR/graphql.json"
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
}

# 79% of the REST requests of a check run of 3000 packages read /releases/latest, against 1000 an
# hour for GITHUB_TOKEN, and GraphQL answers 50 repositories in one request
@test "check-all: reads the releases of github-release packages over GraphQL with a token" {
  graphql_packages
  GITHUB_TOKEN=test-token run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/a")" = "new_version: 3.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/b")" = "new_version: 5.0.0" ]
  [ "$(grep -c api.github.com/graphql "$CURL_ARGS_LOG")" = 1 ]
  run ! grep -q -e repos/owner/a/releases -e repos/owner/b/releases "$CURL_ARGS_LOG"
  run ! grep -q test-token "$CURL_ARGS_LOG"
  grep -qF 'r0: repository(owner: \"owner\", name: \"a\")' "$MOCK_FILES_DIR/graphql.log"
  grep -qF 'r1: repository(owner: \"owner\", name: \"b\")' "$MOCK_FILES_DIR/graphql.log"
  # Without a token the run asks REST alone
  rm "$CURL_ARGS_LOG"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$(cat "$TEST_TMPDIR/.status/a")" = "new_version: 2.0.0" ]
  ! grep -q api.github.com/graphql "$CURL_ARGS_LOG"
}

# Renamed or removed repositories, lists past one page and failed requests go to REST as without GraphQL
@test "check-all: asks REST for what GraphQL does not answer" {
  graphql_packages
  echo '{"data":{"r0":null,"r1":{"latestRelease":null,"releases":{"totalCount":101,"nodes":[]}}},"errors":[{"type":"NOT_FOUND"}]}' \
    >"$MOCK_FILES_DIR/graphql.json"
  GITHUB_TOKEN=test-token run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/a")" = "new_version: 2.0.0" ]
  grep -qF 'repos/owner/b/releases?per_page=100&page=1' "$CURL_ARGS_LOG"
  # A repository without a release outside pre-releases has no latestRelease, and REST tells why
  rm "$CURL_ARGS_LOG"
  echo '{"data":{"r0":{"latestRelease":null,"releases":{"totalCount":101,"nodes":[]}},"r1":null}}' >"$MOCK_FILES_DIR/graphql.json"
  GITHUB_TOKEN=test-token run "$TEST_TMPDIR/scripts/check-all.sh"
  grep -qF 'repos/owner/a/releases/latest' "$CURL_ARGS_LOG"
  rm "$MOCK_FILES_DIR/graphql.json" "$CURL_ARGS_LOG"
  GITHUB_TOKEN=test-token run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/a")" = "new_version: 2.0.0" ]
  [[ "$output" == *"GraphQL did not answer, so the checks read the GitHub releases over REST"* ]]
  # github-nightly reads the notes of releases in a list, which the answers of GraphQL leave out
  rm "$CURL_ARGS_LOG" "$MOCK_FILES_DIR/graphql.log"
  create_test_package c github-nightly "upstream:
  project: owner/a
  nightly_tag: latest"
  GITHUB_TOKEN=test-token run "$TEST_TMPDIR/scripts/check-all.sh"
  grep -qF 'name: \"b\"' "$MOCK_FILES_DIR/graphql.log"
  ! grep -qF 'name: \"a\"' "$MOCK_FILES_DIR/graphql.log"
}

# The GraphQL fetch counts in the time budget of the loop, so the check job ends within its 30 minutes
@test "check-all: starts no GraphQL request after the time budget of the loop" {
  graphql_packages
  touch "$CURL_ARGS_LOG"
  AURTOMATOR_CHECK_BUDGET=0 GITHUB_TOKEN=test-token run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/a")" = "unchecked: the check ran out of its 0 minutes in this run" ]
  run ! grep -q api.github.com/graphql "$CURL_ARGS_LOG"
}

# yq reads all files in one call, which stops at the first file it cannot read
@test "check-all: a YAML that yq cannot read keeps the fetches and budgets of the other packages" {
  local n
  graphql_packages
  printf 'strategy: [\n' >"$TEST_TMPDIR/packages/0bad.yml"
  GITHUB_TOKEN=test-token run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/a")" = "new_version: 3.0.0" ]
  [ "$(grep -c api.github.com/graphql "$CURL_ARGS_LOG")" = 1 ]
  [[ "$output" == *"yq cannot read 'packages/0bad.yml', so the reads before the checks leave it out"* ]]
  rm "$TEST_TMPDIR"/packages/[ab].yml
  for n in 1 2; do
    create_test_package "r$n" repology "upstream:
  repology: r$n
current: '1.0.0'"
  done
  AURTOMATOR_REPOLOGY_BUDGET=1 GITHUB_RUN_NUMBER=0 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/r2")" = "unchecked: repology.org takes 1 checks a run, so this package gets its check in a later run" ]
}

@test "gitlab_prefetch: a YAML that yq cannot read keeps the fetches of the other packages" {
  local key
  printf 'strategy: [\n' >"$TEST_TMPDIR/packages/0bad.yml"
  create_test_package a gitlab-tag "upstream:
  host: gitlab.com
  project: group/a"
  run bash -c 'source "$0/scripts/lib.sh" && GITLAB_TOKEN_GITLAB_COM=glpat-com gitlab_prefetch "$0/answers" "$0"/packages/*.yml' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"yq cannot read 'packages/0bad.yml', so the reads before the checks leave it out"* ]]
  key=$(printf '%s' 'https://gitlab.com/api/v4/projects/group%2Fa/repository/tags?per_page=100' | sha256sum)
  [ -f "$TEST_TMPDIR/answers/${key%% *}" ]
}

# The issues count a failed check under the host of its own failed request, which check-all.sh reads
# from the memory of hosts after the check
@test "github_prefetch: leaves no failed request to the first check" {
  graphql_packages
  rm "$MOCK_FILES_DIR/graphql.json"
  run bash -c 'source "$0/scripts/lib.sh"
    export AURTOMATOR_HOSTS_DIR AURTOMATOR_RUN_CACHE GITHUB_TOKEN=test-token
    AURTOMATOR_HOSTS_DIR=$(mktemp -d) AURTOMATOR_RUN_CACHE=$(mktemp -d)
    : >"$AURTOMATOR_HOSTS_DIR/silent"
    : >"$AURTOMATOR_HOSTS_DIR/request"
    : >"$AURTOMATOR_HOSTS_DIR/failed"
    github_prefetch "$0"/packages/*.yml 2>/dev/null
    wc -c <"$AURTOMATOR_HOSTS_DIR/failed"
    wc -c <"$AURTOMATOR_HOSTS_DIR/request"' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = $'0\n0' ]
}

# The workflow runs it as root, which parses no answer, so builder parses them without the tokens.
# Each host of the table gets the token of its own variable, and other hosts get none.
@test "gitlab_prefetch: asks each GitLab host of the table with its own token" {
  local key_a key_k
  create_test_package a gitlab-tag "upstream:
  host: gitlab.com
  project: group/a"
  create_test_package b gitlab-tag "upstream:
  host: gitlab.gnome.org
  project: group/b"
  create_test_package c github-release "upstream:
  project: owner/c"
  create_test_package d gitlab-tag "upstream:
  host: gitlab.com
  project: missing-group/d"
  create_test_package e gitlab-tag "upstream:
  host: gitlab.com
  project: group/.."
  create_test_package f gitlab-tag "upstream:
  host: invent-kde.org
  project: group/f"
  create_test_package g gitlab-tag "upstream:
  host: gitlab.example.org
  project: group/g"
  create_test_package k gitlab-tag "upstream:
  host: invent.kde.org
  project: group/k"
  printf '%s\n' 'name: l' 'strategy: gitlab-tag' 'upstream:' '  host: gitlab.com' '  project: group/l' >"$TEST_TMPDIR/l.yml"
  ln -s "$TEST_TMPDIR/l.yml" "$TEST_TMPDIR/packages/l.yml"
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  mv "$MOCK_DIR/curl" "$MOCK_DIR/curl-answer"
  printf '%s\n' '#!/usr/bin/env bash' "cat >>'$TEST_TMPDIR/curl.stdin'" 'exec "${0%/*}/curl-answer" "$@"' >"$MOCK_DIR/curl"
  chmod +x "$MOCK_DIR/curl"
  run bash -c 'source "$0/scripts/lib.sh" &&
    GITLAB_TOKEN_GITLAB_COM=glpat-com GITLAB_TOKEN_INVENT_KDE_ORG=glpat-kde GITLAB_TOKEN_GITLAB_EXAMPLE_ORG=glpat-example \
      gitlab_prefetch "$0/answers" "$0"/packages/*.yml' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing-group%2Fd/repository/tags?per_page=100: The requested URL returned error: 404"* ]]
  key_a=$(printf '%s' 'https://gitlab.com/api/v4/projects/group%2Fa/repository/tags?per_page=100' | sha256sum)
  key_k=$(printf '%s' 'https://invent.kde.org/api/v4/projects/group%2Fk/repository/tags?per_page=100' | sha256sum)
  [ "$(ls -A "$TEST_TMPDIR/answers" | sort)" = "$(printf '%s\n' "${key_a%% *}" "${key_k%% *}" | sort)" ]
  [ "$(cat "$TEST_TMPDIR/answers/${key_a%% *}")" = '[{"name": "v3.1.0"}, {"name": "v3.0.0"}, {"name": "v2.0.0"}]' ]
  # curl reads each header from stdin, for no project with a part . or ..
  [ "$(grep -c -- ' -H @- ' "$CURL_ARGS_LOG")" = 3 ]
  [ "$(wc -l <"$CURL_ARGS_LOG")" = 3 ]
  [ "$(grep -c 'https://gitlab.com/' "$CURL_ARGS_LOG")" = 2 ]
  [ "$(grep -c 'https://invent.kde.org/' "$CURL_ARGS_LOG")" = 1 ]
  [ "$(cat "$TEST_TMPDIR/curl.stdin")" = $'Authorization: Bearer glpat-com\nAuthorization: Bearer glpat-com\nAuthorization: Bearer glpat-kde' ]
  run ! grep -q glpat- "$CURL_ARGS_LOG"
  # Without a token of the table it asks nothing
  rm "$CURL_ARGS_LOG"
  run bash -c 'source "$0/scripts/lib.sh" && GITLAB_TOKEN_GITLAB_EXAMPLE_ORG=glpat-example gitlab_prefetch "$0/none" "$0"/packages/*.yml' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/none" ]
  [ ! -e "$CURL_ARGS_LOG" ]
}

# The time of the step counts in the budget of the checks, which ask gitlab.com for the rest without the token
@test "gitlab_prefetch: starts no request past GITLAB_PREFETCH_BUDGET" {
  create_test_package a gitlab-tag "upstream:
  host: gitlab.com
  project: group/a"
  create_test_package b gitlab-tag "upstream:
  host: gitlab.com
  project: group/b"
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run bash -c 'source "$0/scripts/lib.sh" && GITLAB_TOKEN_GITLAB_COM=glpat-test GITLAB_PREFETCH_BUDGET=0 gitlab_prefetch "$0/answers" "$0"/packages/*.yml' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "::warning::Fetch GitLab tags stopped after 0 s, so the checks ask GitLab without a token for 2 of 2 projects" ]
  [ ! -e "$CURL_ARGS_LOG" ]
  [ -z "$(ls -A "$TEST_TMPDIR/answers")" ]
  run bash -c 'source "$0/scripts/lib.sh" && GITLAB_TOKEN_GITLAB_COM=glpat-test GITLAB_PREFETCH_BUDGET=1.5 gitlab_prefetch "$0/answers" "$0"/packages/*.yml' "$TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GITLAB_PREFETCH_BUDGET must be a whole number of seconds from 0 to 999999: '1.5'"* ]]
  [ ! -e "$CURL_ARGS_LOG" ]
}

# GITHUB_TOKEN allows 1000 REST requests an hour for the repository, and publish and the issues job
# need some after the check job
@test "check-all: leaves the GitHub packages unchecked when 400 REST requests are left" {
  local reason="unchecked: the run keeps its last 400 GitHub API requests of the hour for the jobs after the check"
  create_test_package a github-release "upstream:
  project: owner/a
current: '1.0.0'"
  create_test_package t github-tag "upstream:
  project: owner/t
current: '1.0.0'"
  create_test_package s pypi "upstream:
  registry: s
current: '1.0.0'"
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  MOCK_REST_LEFT=399 GITHUB_TOKEN=test-token run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/a")" = "$reason" ]
  [[ "$(cat "$TEST_TMPDIR/.status/t")" != unchecked:* ]]
  [[ "$(cat "$TEST_TMPDIR/.status/s")" != unchecked:* ]]
  [[ "$output" == *"a: the run keeps its last 400 GitHub API requests of the hour for the jobs after the check"* ]]
  run ! grep -q repos/owner/a/releases "$CURL_ARGS_LOG"
  # github-tag reads tags with git, and its asset over REST
  create_test_package t github-tag "upstream:
  project: owner/t
  asset_regex: 't-.*'
current: '1.0.0'"
  MOCK_REST_LEFT=399 GITHUB_TOKEN=test-token run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$(cat "$TEST_TMPDIR/.status/t")" = "$reason" ]
  MOCK_REST_LEFT=400 GITHUB_TOKEN=test-token run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$(cat "$TEST_TMPDIR/.status/a")" = "new_version: 2.0.0" ]
  # The limit of local runs without a token is theirs to watch, and an unread limit stops nothing
  rm "$CURL_ARGS_LOG"
  MOCK_REST_LEFT=0 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$(cat "$TEST_TMPDIR/.status/a")" = "new_version: 2.0.0" ]
  run ! grep -q rate_limit "$CURL_ARGS_LOG"
  MOCK_REST_LEFT=fail GITHUB_TOKEN=test-token run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$(cat "$TEST_TMPDIR/.status/a")" = "new_version: 2.0.0" ]
}

# The answers of GraphQL in the run cache take no REST request, and the assets of a release take some
@test "check-all: checks the packages whose releases GraphQL answered when 400 REST requests are left" {
  graphql_packages
  create_test_package c github-release "upstream:
  project: owner/a
  asset_regex: 'c-.*'
current: '1.0.0'"
  MOCK_REST_LEFT=399 GITHUB_TOKEN=test-token run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/a")" = "new_version: 3.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/b")" = "new_version: 5.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/c")" = "unchecked: the run keeps its last 400 GitHub API requests of the hour for the jobs after the check" ]
  run ! grep -q -e repos/owner/a/releases -e repos/owner/b/releases "$CURL_ARGS_LOG"
}

# GET /rate_limit counts against no limit, and each check takes a few requests at most
@test "check-all: reads the GitHub REST limit before every tenth GitHub package" {
  local i
  for i in $(seq 10 30); do
    create_test_package "p$i" github-release "upstream:
  project: owner/p$i"
  done
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  GITHUB_TOKEN=test-token run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c api.github.com/rate_limit "$CURL_ARGS_LOG")" = 3 ]
}

# Prints the milliseconds that three requests to URL $1 take to begin in a check run
paced_ms() {
  bash -c 'source "$0/scripts/lib.sh"
    AURTOMATOR_HOSTS_DIR=$(mktemp -d)
    : >"$AURTOMATOR_HOSTS_DIR/silent"
    start=${EPOCHREALTIME/[.,]/}
    for i in 1 2 3; do request_begin "$1/$i"; done
    end=${EPOCHREALTIME/[.,]/}
    echo $(((end - start) / 1000))' "$TEST_TMPDIR" "$1"
}

# rubygems.org takes 10 requests a second, repology.org one, and pypi.org states no limit
@test "request_begin: keeps the pace of each host between its requests" {
  local ms
  ms=$(paced_ms https://rubygems.org/api)
  echo "rubygems.org: $ms ms"
  ((ms >= 200 && ms < 1000))
  ms=$(paced_ms https://example.org/page)
  echo "example.org: $ms ms"
  ((ms >= 400 && ms < 1500))
  ms=$(paced_ms https://pypi.org/pypi)
  echo "pypi.org: $ms ms"
  ((ms < 150))
  ms=$(paced_ms https://repology.org/api/v1/project)
  echo "repology.org: $ms ms"
  ((ms >= 2000 && ms < 3500))
}

# Repology counts more than 1000 requests a day as bulk, and the next run starts where this one stopped
@test "check-all: gives the packages of repology.org the checks of its budget, the next ones in the next run" {
  local reason="unchecked: repology.org takes 2 checks a run, so this package gets its check in a later run" n
  for n in 1 2 3; do
    create_test_package "r$n" repology "upstream:
  repology: r$n
current: '1.0.0'"
  done
  AURTOMATOR_REPOLOGY_BUDGET=2 GITHUB_RUN_NUMBER=0 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/r1")" = "new_version: 5.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/r2")" = "new_version: 5.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/r3")" = "$reason" ]
  AURTOMATOR_REPOLOGY_BUDGET=2 GITHUB_RUN_NUMBER=1 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$(cat "$TEST_TMPDIR/.status/r3")" = "new_version: 5.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/r1")" = "new_version: 5.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/r2")" = "$reason" ]
  # The budget covers the whole run
  AURTOMATOR_REPOLOGY_BUDGET=3 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$(cat "$TEST_TMPDIR/.status/r3")" = "new_version: 5.0.0" ]
  # Runs by hand have no run number, so each hour takes the next packages
  local bin="$BATS_TEST_TMPDIR/bin" real
  real=$(command -v date)
  mkdir -p "$bin"
  printf '#!/bin/sh\n[ "$*" = "-u +%%s" ] && echo "$FAKE_NOW" && exit 0\nexec %s "$@"\n' "$real" >"$bin/date"
  chmod +x "$bin/date"
  PATH="$bin:$PATH" FAKE_NOW=32400 AURTOMATOR_REPOLOGY_BUDGET=2 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$(cat "$TEST_TMPDIR/.status/r3")" = "$reason" ]
  PATH="$bin:$PATH" FAKE_NOW=36000 AURTOMATOR_REPOLOGY_BUDGET=2 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$(cat "$TEST_TMPDIR/.status/r3")" = "new_version: 5.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/r2")" = "$reason" ]
}

# One request holds 50 repositories
@test "check-all: asks GraphQL for 50 repositories a request" {
  local i
  for i in $(seq 1 51); do
    create_test_package "p$i" github-release "upstream:
  project: owner/p$i"
  done
  echo '{"data":{}}' >"$MOCK_FILES_DIR/graphql.json"
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  GITHUB_TOKEN=test-token run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c api.github.com/graphql "$CURL_ARGS_LOG")" = 2 ]
}

# The issues job reads the statuses of publish when it ran
@test "check-all: --prepare and --publish carry the _requirements of the check run" {
  local mode
  create_test_package foo github-release "upstream:
  project: owner/foo
current: '1.0.0'"
  for mode in prepare publish; do
    rm -rf "$TEST_TMPDIR/.status" "$TEST_TMPDIR/out"
    mkdir -p "$TEST_TMPDIR/.status"
    echo up_to_date >"$TEST_TMPDIR/.status/foo"
    printf 'foo\tpython\n' >"$TEST_TMPDIR/.status/_requirements"
    run "$TEST_TMPDIR/scripts/check-all.sh" "--$mode" "$TEST_TMPDIR/out"
    [ "$(cat "$TEST_TMPDIR/.status/_requirements")" = $'foo\tpython' ] || {
      echo "lost by --$mode"
      return 1
    }
    rm -rf "$TEST_TMPDIR/.status" "$TEST_TMPDIR/out"
    mkdir -p "$TEST_TMPDIR/.status"
    echo up_to_date >"$TEST_TMPDIR/.status/foo"
    : >"$TEST_TMPDIR/.status/_requirements"
    run "$TEST_TMPDIR/scripts/check-all.sh" "--$mode" "$TEST_TMPDIR/out"
    [ -e "$TEST_TMPDIR/.status/_requirements" ] && [ ! -s "$TEST_TMPDIR/.status/_requirements" ]
    rm -rf "$TEST_TMPDIR/.status" "$TEST_TMPDIR/out"
    mkdir -p "$TEST_TMPDIR/.status"
    echo up_to_date >"$TEST_TMPDIR/.status/foo"
    run "$TEST_TMPDIR/scripts/check-all.sh" "--$mode" "$TEST_TMPDIR/out"
    [ ! -e "$TEST_TMPDIR/.status/_requirements" ]
  done
}

@test "check-all: --rules-later fails the check of a package whose AUR .SRCINFO it cannot read" {
  python_package $'python:\n  pypi: KubeDiagrams' bash python python-yaml
  # The AUR serves an empty repository for a package it lacks, and git fails to clone this one
  rm -rf "$TEST_TMPDIR/aur-remote/kube-diagrams.git"
  mkdir "$TEST_TMPDIR/aur-remote/kube-diagrams.git"
  run "$TEST_TMPDIR/scripts/check-all.sh" --rules-later
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_TMPDIR/.status/kube-diagrams")" == "check_failed: "* ]]
  [ ! -e "$TEST_TMPDIR/.status/_rules" ]
  # The issues count the failure under the host of the AUR, and the check runs again
  [ "$(cat "$TEST_TMPDIR/.status/_hosts")" = $'kube-diagrams\taur.archlinux.org' ]
  [[ "$output" == *"Checking 1 failed package(s) again"* ]]
}

@test "check-all: --rules writes the requires lines of the version of the check run, or error and the reason" {
  python_package $'python:\n  pypi: KubeDiagrams\nalerts:\n  - match: "^1[.]1"\n    note: Read the changelog' \
    bash python python-yaml python-diagrams
  pypi_fake KubeDiagrams 1.0.0 PyYAML diagrams
  pypi_fake KubeDiagrams 1.1.0 PyYAML diagrams graphviz2drawio
  mkdir -p "$TEST_TMPDIR/.status"
  echo "new_version: 1.1.0" >"$TEST_TMPDIR/.status/kube-diagrams"
  run "$TEST_TMPDIR/scripts/check-all.sh" --rules "$TEST_TMPDIR/rules"
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$TEST_TMPDIR/rules/kube-diagrams")" = $'version\t1.1.0' ]
  grep -qxF $'notice\tadds graphviz2drawio' "$TEST_TMPDIR/rules/kube-diagrams"
  grep -qxF $'notice\tgraphviz2drawio: not in depends' "$TEST_TMPDIR/rules/kube-diagrams"
  run grep -c -e changelog -e '^error' "$TEST_TMPDIR/rules/kube-diagrams"
  [ "$output" = 0 ]
  # The statuses of the check run stay for the steps after it
  [ "$(cat "$TEST_TMPDIR/.status/kube-diagrams")" = "new_version: 1.1.0" ]
  python_package "" bash python python-yaml
  run "$TEST_TMPDIR/scripts/check-all.sh" --rules "$TEST_TMPDIR/rules"
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$TEST_TMPDIR/rules/kube-diagrams")" = error ]
  grep -qF "packages/kube-diagrams.yml: its depends hold Python packages, so set python.pypi, python.pyproject or python: none" \
    "$TEST_TMPDIR/rules/kube-diagrams"
  echo "up_to_date" >"$TEST_TMPDIR/.status/kube-diagrams"
  run "$TEST_TMPDIR/scripts/check-all.sh" --rules "$TEST_TMPDIR/rules"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/rules/kube-diagrams")" = $'error\nno new version from the check run' ]
}

# The rules job gets the YAMLs of the other packages for their upstream.pin_from, and their statuses stay out
@test "check-all: --rules takes the pin of a companion and runs the rules of packages with a status alone" {
  unmet_env
  sed -i 's/"0.0.43-1"/"0.0.41-1"/' "$MOCK_FILES_DIR/aur-rpc.json"
  pypi_fake zenlike 0.9 'zensical-ui==0.0.41'
  pypi_fake zenlike 1.0 'zensical-ui==0.0.43'
  unmet_srcinfo "$TEST_TMPDIR/z.SRCINFO" zenlike python python-zensical-ui
  aur_srcinfo_remote zenlike "$TEST_TMPDIR/z.SRCINFO"
  create_test_package "zenlike" "pypi" "upstream:
  registry: zenlike
current: '0.9'
alerts:
  - requires: unmet
    hold: true"
  mkdir -p "$TEST_TMPDIR/.status"
  echo "new_version: 1.0" >"$TEST_TMPDIR/.status/zenlike"
  run "$TEST_TMPDIR/scripts/check-all.sh" --rules "$TEST_TMPDIR/rules"
  [ "$status" -eq 0 ]
  grep -qxF $'hold\tzensical-ui==0.0.43: python-zensical-ui has 0.0.41 (AUR pkgver)' "$TEST_TMPDIR/rules/zenlike"
  create_test_package "python-zensical-ui" "pypi" "upstream:
  registry: zensical-ui
  pin_from: zenlike
current: 0.0.41"
  rm -rf "$TEST_TMPDIR/rules" "$AURTOMATOR_RUN_CACHE"/*
  run "$TEST_TMPDIR/scripts/check-all.sh" --rules "$TEST_TMPDIR/rules"
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$TEST_TMPDIR/rules/zenlike")" = $'version\t1.0' ]
  run grep -c '^hold' "$TEST_TMPDIR/rules/zenlike"
  [ "$output" = 0 ]
  [ "$(ls "$TEST_TMPDIR/rules")" = zenlike ]
}

@test "check-all: runs no requires rule for python: none or without Python in depends" {
  python_package "python: none" bash python python-yaml
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/kube-diagrams")" = "new_version: 1.1.0" ]
  [ ! -e "$TEST_TMPDIR/.status/_alerts" ]
  python_package "" bash glibc
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$(cat "$TEST_TMPDIR/.status/kube-diagrams")" = "new_version: 1.1.0" ]
  ! grep -q pypi.org "$CURL_ARGS_LOG"
}

@test "check-all: runs every requires rule as a notice for a package with python.pypi" {
  python_package $'python:\n  pypi: KubeDiagrams' bash python python-yaml python-diagrams
  pypi_fake KubeDiagrams 1.0.0 PyYAML diagrams
  pypi_fake KubeDiagrams 1.1.0 PyYAML diagrams graphviz2drawio
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/kube-diagrams")" = "new_version: 1.1.0" ]
  grep -qxF $'kube-diagrams\tnotice\tadds graphviz2drawio' "$TEST_TMPDIR/.status/_alerts"
  grep -qxF $'kube-diagrams\tnotice\tgraphviz2drawio: not in depends' "$TEST_TMPDIR/.status/_alerts"
  [[ "$output" == *"kube-diagrams: update 1.0.0 → 1.1.0 notice: graphviz2drawio: not in depends"* ]]
}

@test "check-all: runs the requires rules on the upstream version of a package with pkgver_format" {
  python_package $'python:\n  pypi: KubeDiagrams\npkgver_format: \'4.%s\'' bash python python-yaml python-diagrams
  sed -i "s/^current: '1.0.0'\$/current: '4.1.0.0'/" "$TEST_TMPDIR/packages/kube-diagrams.yml"
  pypi_fake KubeDiagrams 1.1.0 PyYAML diagrams graphviz2drawio
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/kube-diagrams")" = "new_version: 4.1.1.0" ]
  grep -qxF $'kube-diagrams\tnotice\tgraphviz2drawio: not in depends' "$TEST_TMPDIR/.status/_alerts"
}

@test "lib.sh: fired_alerts fails on a version that does not fit pkgver_format" {
  python_package $'python:\n  pypi: KubeDiagrams\npkgver_format: \'4.%s\'' bash python python-yaml python-diagrams
  pypi_fake KubeDiagrams 1.1.0 PyYAML diagrams graphviz2drawio
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" 4.1.0.0 1.1.0' "$TEST_TMPDIR" \
    "$TEST_TMPDIR/packages/kube-diagrams.yml"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"packages/kube-diagrams.yml: version 1.1.0 does not fit pkgver_format 4.%s"* ]]
}

@test "check-all: holds the update that a listed rule with hold fires on" {
  python_package $'python:\n  pypi: KubeDiagrams\nalerts:\n  - requires: unmet\n    hold: true' bash python python-yaml python-diagrams
  pypi_fake KubeDiagrams 1.0.0 PyYAML diagrams
  pypi_fake KubeDiagrams 1.1.0 PyYAML diagrams graphviz2drawio
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/kube-diagrams")" = "held: 1.1.0" ]
  [[ "$output" == *"kube-diagrams: update 1.0.0 → 1.1.0 held: graphviz2drawio: not in depends"* ]]
}

@test "check-all: python.release newest reads the newest release on PyPI and runs no changed" {
  python_package $'python:\n  pypi: KubeDiagrams\n  release: newest' bash python python-yaml
  pypi_fake KubeDiagrams 3.2.1 PyYAML diagrams
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  grep -qxF $'kube-diagrams\tnotice\tdiagrams: not in depends' "$TEST_TMPDIR/.status/_alerts"
  run grep -q -e adds -e drops -e 'has no release' "$TEST_TMPDIR/.status/_alerts"
  [ "$status" -ne 0 ]
  grep -q 'pypi.org/pypi/KubeDiagrams/json$' "$CURL_ARGS_LOG"
}

@test "lib.sh: fired_alerts runs no default rule in prepare and publish" {
  python_package $'python:\n  pypi: KubeDiagrams' bash python python-yaml
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  local mode
  for mode in held offline; do
    run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" 1.0.0 1.1.0 "$2"' "$TEST_TMPDIR" \
      "$TEST_TMPDIR/packages/kube-diagrams.yml" "$mode"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  [ ! -e "$CURL_ARGS_LOG" ]
}

# === rb_requires.rb ===

# Helper: writes file $1 under $TEST_TMPDIR/rb with the lines after it
rb_file() {
  mkdir -p "$(dirname "$TEST_TMPDIR/rb/$1")"
  printf '%s\n' "${@:2}" >"$TEST_TMPDIR/rb/$1"
}

# Helper: runs rb_requires.rb on the files $@ of $TEST_TMPDIR/rb as the rules run it, the names
# NUL-separated on stdin
run_rb_requires() {
  printf '%s\0' "$@" >"$TEST_TMPDIR/rb-files"
  run --separate-stderr ruby --disable-gems "$TEST_TMPDIR/scripts/lib/rb_requires.rb" "$TEST_TMPDIR/rb" <"$TEST_TMPDIR/rb-files"
}

@test "rb_requires.rb: prints the requires of a file with their kind and scope" {
  rb_file lib/demo.rb 'require "optparse"' "require_relative 'demo/x'" 'load "tasks.rb"' 'Kernel.require "pathname"' \
    'class Demo' '  require "set"' '  def run' '    require "json"' '  end' '  define_method(:go) { require "csv" }' 'end' \
    'require "#{name}"' "text = <<~RUBY" "  require 'fake'" 'RUBY' "list = %w[require nope]" 'other.require "skip"'
  run_rb_requires lib/demo.rb
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'require\tlib/demo.rb\t%s\n' 'require	optparse	module' 'relative	lib/demo/x.rb	module' \
    'load	tasks.rb	module' 'require	pathname	module' 'require	set	module' 'require	json	method' 'require	csv	method')" ]
}

# LoadError descends from ScriptError, so a bare rescue or StandardError leaves the require required
@test "rb_requires.rb: reads requires under a rescue of LoadError as optional" {
  rb_file lib/demo.rb 'begin' '  require "fast"' 'rescue LoadError' '  require "slow"' 'end' 'begin' '  require "a"' \
    'rescue ::ScriptError, Exception' 'end' 'begin' '  require "b"' 'rescue' 'end' 'begin' '  require "c"' 'rescue StandardError' \
    'end' 'def m' '  require "d"' 'rescue LoadError' 'end' 'if ENV["X"]' '  require "e"' 'end'
  run_rb_requires lib/demo.rb
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'require\tlib/demo.rb\trequire\t%s\n' 'fast	optional' 'slow	optional' 'a	optional' 'b	module' \
    'c	module' 'd	method' 'e	module')" ]
}

# nkf requires nkf.jar under JRuby, and mixlib-shellout loads files for Windows under RUBY_PLATFORM
@test "rb_requires.rb: follows the branch of RUBY_ENGINE and RUBY_PLATFORM that Ruby on Arch takes" {
  rb_file lib/demo.rb 'if RUBY_ENGINE == "jruby"' '  require "demo.jar"' 'elsif RUBY_PLATFORM =~ /mswin|mingw|windows/i' \
    '  require "win32/process"' 'else' '  require "demo.so"' 'end' 'require "posix" unless Gem.win_platform?' \
    'require "java" if ::RUBY_PLATFORM.include?("java") || RUBY_ENGINE != "ruby"' 'if !(/darwin/ =~ RUBY_PLATFORM)' \
    '  require "linux"' 'end' 'if RUBY_PLATFORM.start_with?("x86_64") && ENV["X"]' '  require "maybe"' 'else' '  require "other"' 'end' \
    'require "win32/registry" if Gem.win_platform?'
  run_rb_requires lib/demo.rb
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'require\tlib/demo.rb\trequire\t%s\n' 'demo.so	module' 'posix	module' 'linux	module' 'maybe	module' \
    'other	module')" ]
}

# The rules split the lines of the helper at tabs and line breaks
@test "rb_requires.rb: leaves out a require whose feature holds a tab or a line break" {
  rb_file lib/demo.rb 'require "a\tb"' 'require "c\nd"' 'require "e\rf"' 'require "json"'
  run_rb_requires lib/demo.rb
  [ "$status" -eq 0 ]
  [ "$output" = $'require\tlib/demo.rb\trequire\tjson\tmodule' ]
}

# File.expand_path reads a leading ~ as a home directory and fails for an unknown user
@test "rb_requires.rb: keeps a ~ of require_relative as a part of the path" {
  rb_file lib/tilde.rb 'require_relative "~nouser_zz/x"' 'require "json"'
  run_rb_requires lib/tilde.rb
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'require\tlib/tilde.rb\t%s\n' 'relative	lib/~nouser_zz/x.rb	module' 'require	json	module')" ]
}

# SystemStackError is no StandardError, and one file past the stack would end the helper
@test "rb_requires.rb: prints an error line for a file that overflows the stack and goes on" {
  rb_file lib/deep.rb 'require "a"'
  rb_file lib/ok.rb 'require "b"'
  printf '%s\n' 'require "prism"' 'Prism::Visitor.prepend(Module.new do' '  def visit_program_node(node)' \
    '    raise SystemStackError, "stack level too deep" if @file.to_s.include?("deep")' '    super' '  end' 'end)' \
    >"$TEST_TMPDIR/deep.rb"
  printf '%s\0' lib/deep.rb lib/ok.rb >"$TEST_TMPDIR/rb-files"
  run --separate-stderr env -u SIMPLECOV_HELPER_DIR -u RUBYOPT ruby --disable-gems -r "$TEST_TMPDIR/deep.rb" \
    "$TEST_TMPDIR/scripts/lib/rb_requires.rb" "$TEST_TMPDIR/rb" <"$TEST_TMPDIR/rb-files"
  [ "$status" -eq 0 ]
  [ "$output" = $'error\tlib/deep.rb\tstack level too deep\nrequire\tlib/ok.rb\trequire\tb\tmodule' ]
}

@test "rb_requires.rb: prints an error line for a file it cannot read and goes on" {
  rb_file bad.rb 'def x(' 'end end'
  rb_file good.rb 'require "json"'
  run_rb_requires bad.rb missing.rb good.rb
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == error$'\t'bad.rb$'\t'* ]]
  [[ "${lines[1]}" == error$'\t'missing.rb$'\t'* ]]
  [ "${lines[2]}" = require$'\t'good.rb$'\t'require$'\t'json$'\t'module ]
}

# enumerator, thread and fiber live in the interpreter, so no file of the files database names them
@test "rb_requires.rb: --builtin prints the features without a file, and no root exits 2" {
  run --separate-stderr ruby --disable-gems "$TEST_TMPDIR/scripts/lib/rb_requires.rb" --builtin
  [ "$status" -eq 0 ]
  [[ $'\n'"$output"$'\n' == *$'\nenumerator\n'* && $'\n'"$output"$'\n' == *$'\nthread\n'* ]]
  [[ "$output" != *prism* && "$output" != */* ]]
  run --separate-stderr ruby --disable-gems "$TEST_TMPDIR/scripts/lib/rb_requires.rb" "$TEST_TMPDIR/none-such"
  [ "$status" -eq 2 ]
}

# === rbrules.sh ===

# Helper: the mock pacman with the gems of the tests in the files database and the repositories,
# ruby 3.4.13, and a run cache in the test directory
gems_env() {
  use_mock_pacman
  export AURTOMATOR_RUN_CACHE="$TEST_TMPDIR/run-cache" MOCK_PACMAN_SYNC="$TEST_TMPDIR/pacman-sync" \
    MOCK_PACMAN_FILES="$TEST_TMPDIR/pacman-files"
  mkdir -p "$AURTOMATOR_RUN_CACHE"
  export MOCK_PACMAN_DEPENDS="$TEST_TMPDIR/pacman-depends"
  : >"$MOCK_PACMAN_DEPENDS"
  printf '%s\n' 'ruby 3.4.13-1 extra ruby-json ruby-optparse' "ruby-simplecov ${1:-0.22.0}-1 extra" 'ruby-rexml 3.4.4-1 extra' \
    'ruby-erb 4.0.4-9 extra' 'ruby-google-protobuf 36.1-1 extra' 'bash 5.3.9-1 core' >"$MOCK_PACMAN_SYNC"
  local line
  for line in "ruby-simplecov simplecov-${1:-0.22.0}" 'ruby-rexml rexml-3.4.4' 'ruby default/json-2.9.1' 'ruby-erb default/erb-4.0.4' \
    'ruby-google-protobuf google-protobuf-4.36.1'; do
    printf 'extra\t%s\t1-1\tusr/lib/ruby/gems/3.4.0/specifications/%s.gemspec\n' "${line% *}" "${line#* }"
  done >"$MOCK_PACMAN_FILES"
  printf '[]\n' >"$MOCK_FILES_DIR/aur-rpc.json"
}

# Helper: writes the v2 answer of gem $1 at version $2 with the runtime requirements after them, each "name|requirements"
gem_v2() {
  local deps="" dep
  for dep in "${@:4}"; do
    deps+="${deps:+, }{\"name\": \"${dep%%|*}\", \"requirements\": \"${dep#*|}\"}"
  done
  mkdir -p "$MOCK_FILES_DIR/rubygems/v2"
  printf '{"name": "%s", "number": "%s", "platform": "ruby", "ruby_version": "%s", "sha": "%s", "gem_uri": "https://rubygems.org/gems/%s-%s.gem", "dependencies": {"runtime": [%s], "development": [{"name": "rspec", "requirements": "~> 3"}]}}\n' \
    "$1" "$2" "$3" "$(printf '0%.0s' {1..64})" "$1" "$2" "$deps" >"$MOCK_FILES_DIR/rubygems/v2/$1-$2.json"
}

# Helper: runs ruby_unmet for package pkg of strategy rubygems, registry $2 at version $3, with .SRCINFO $1
# and the YAML lines $4
run_ruby_unmet() {
  create_test_package "pkg" "rubygems" "upstream:
  registry: $2
${4:-}"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; ruby_unmet "$@"' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/pkg.yml" "$1" "$2" "$3"
}

@test "rbrules.sh: files_index_gems lists the gems of the repositories, default gems included" {
  gems_env 1.3.2
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; files_index_gems && cat "$AURTOMATOR_RUN_CACHE/gems" && gems_of ruby' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' erb$'\t'ruby-erb$'\t'4.0.4 google-protobuf$'\t'ruby-google-protobuf$'\t'4.36.1 \
    json$'\t'ruby$'\t'2.9.1 rexml$'\t'ruby-rexml$'\t'3.4.4 simplecov$'\t'ruby-simplecov$'\t'1.3.2 json$'\t'2.9.1)" ]
}

@test "rbrules.sh: gem_release reads the runtime requirements of a release, and 3 for one rubygems.org lacks" {
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; gem_release bashcov 4.0.3 && printf "%s\n" "$GEM_RUNTIME" "$GEM_RUBY" "$GEM_SHA" "$GEM_URI"' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = $'simplecov\t~> 1.1\n>= 3.2.0\nbeea63c03617a4ca800e39bd81ca029ec1eb178e9da6d4920bd5130dff5c49b9\nhttps://rubygems.org/gems/bashcov-4.0.3.gem' ]
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; gem_release bashcov 9.9' "$TEST_TMPDIR"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"bashcov: rubygems.org has no release 9.9"* ]]
}

# rubygems.org answers the first platform of a release, java for json 3.2.0, without the query
@test "rbrules.sh: gem_release reads the release of platform ruby of a gem with a java build" {
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; gem_release json 3.2.0 && printf "%s\n" "$GEM_RUBY" "$GEM_URI"' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = $'>= 2.7\nhttps://rubygems.org/gems/json-3.2.0.gem' ]
  grep -q 'https://rubygems.org/api/v2/rubygems/json/versions/3.2.0.json?platform=ruby$' "$CURL_ARGS_LOG"
}

# Links of a gem could make the rule read any file of the runner, so they count as no file of the gem
@test "rbrules.sh: ruby_imports reads no link of the gem" {
  gems_env 1.3.2
  local g="$TEST_TMPDIR/linked"
  mkdir -p "$g/lib"
  printf '%s\n' 'require "evil"' >"$g/lib/bashcov.rb"
  printf '%s\n' 'require "secretgem"' >"$TEST_TMPDIR/outside.rb"
  ln -s "$TEST_TMPDIR/outside.rb" "$g/lib/evil.rb"
  gem_build bashcov 4.0.3 "$g" $'name: bashcov\nrequire_paths:\n- lib\n' 'simplecov|~> 1.1'
  unmet_srcinfo "$TEST_TMPDIR/b.SRCINFO" bashcov bash ruby ruby-simplecov
  run_ruby_imports "$TEST_TMPDIR/b.SRCINFO"
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\trequire evil: no package owns it' ]
}

# rubygems.org writes gem_uri from the name and the version, and the .gem of another URL could be any file
@test "rbrules.sh: gem_release refuses an answer of another platform or gem_uri" {
  local json
  mkdir -p "$MOCK_FILES_DIR/rubygems/v2"
  for json in '"platform": "java", "gem_uri": "https://rubygems.org/gems/demo-1.0.gem"' \
    '"platform": "ruby", "gem_uri": "https://evil.example/demo-1.0.gem"'; do
    printf '{"name": "demo", "number": "1.0", %s, "ruby_version": ">= 3.2", "sha": "%s", "dependencies": {"runtime": []}}\n' \
      "$json" "$(printf '0%.0s' {1..64})" >"$MOCK_FILES_DIR/rubygems/v2/demo-1.0.json"
    run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; gem_release demo 1.0' "$TEST_TMPDIR"
    [ "$status" -eq 1 ]
  done
  [[ "$stderr" == *"demo/versions/1.0.json?platform=ruby: ruby_version, sha or gem_uri is not what RubyGems writes"* ]]
}

@test "rbrules.sh: ruby_unmet holds a requirement that the version of the gem fails, and gives nothing once it holds" {
  gems_env
  unmet_srcinfo "$TEST_TMPDIR/b.SRCINFO" bashcov bash ruby ruby-simplecov
  run_ruby_unmet "$TEST_TMPDIR/b.SRCINFO" bashcov 4.0.3
  [ "$status" -eq 0 ]
  [ "$output" = $'hold\tsimplecov ~> 1.1: ruby-simplecov has 0.22.0' ]
  gems_env 1.3.2
  rm -rf "$AURTOMATOR_RUN_CACHE"/*
  run_ruby_unmet "$TEST_TMPDIR/b.SRCINFO" bashcov 4.0.3
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rbrules.sh: ruby_unmet holds a requirement that no entry of depends meets" {
  gems_env 1.3.2
  unmet_srcinfo "$TEST_TMPDIR/c.SRCINFO" ruby-simplecov-cobertura ruby ruby-rexml ruby-simplecov
  run_ruby_unmet "$TEST_TMPDIR/c.SRCINFO" simplecov-cobertura 4.0.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  unmet_srcinfo "$TEST_TMPDIR/c.SRCINFO" ruby-simplecov-cobertura ruby ruby-simplecov
  run_ruby_unmet "$TEST_TMPDIR/c.SRCINFO" simplecov-cobertura 4.0.0
  [ "$output" = $'hold\trexml: not in depends' ]
}

@test "rbrules.sh: ruby_unmet gives a notice for the upper bound of ~> under ruby.relax" {
  gems_env 1.3.2
  unmet_srcinfo "$TEST_TMPDIR/b.SRCINFO" bashcov bash ruby ruby-simplecov
  run_ruby_unmet "$TEST_TMPDIR/b.SRCINFO" bashcov 3.3.0 $'ruby:\n  relax: true'
  [ "$output" = $'notice\tsimplecov ~> 0.21: ruby-simplecov has 1.3.2' ]
  run_ruby_unmet "$TEST_TMPDIR/b.SRCINFO" bashcov 3.3.0
  [ "$output" = $'hold\tsimplecov ~> 0.21: ruby-simplecov has 1.3.2' ]
}

@test "rbrules.sh: ruby_unmet holds a ruby_version that the ruby of Arch fails" {
  gems_env 1.3.2
  gem_v2 demo 1.0 '>= 3.5'
  unmet_srcinfo "$TEST_TMPDIR/d.SRCINFO" ruby-demo ruby
  run_ruby_unmet "$TEST_TMPDIR/d.SRCINFO" demo 1.0
  [ "$output" = $'hold\truby_version >= 3.5: ruby has 3.4.13' ]
}

@test "rbrules.sh: ruby_unmet leaves out ruby.skip, compares the version of the gem and names pkgver otherwise" {
  gems_env 1.3.2
  gem_v2 demo 1.0 '>= 3.2' 'win32ole|>= 0' 'google-protobuf|>= 4.36, < 5' 'rexml|~> 3.4' 'json|>= 2.9' 'bigx|>= 2'
  printf 'ruby-bigx 1.5-1 extra\n' >>"$MOCK_PACMAN_SYNC"
  unmet_srcinfo "$TEST_TMPDIR/d.SRCINFO" ruby-demo ruby ruby-google-protobuf ruby-rexml ruby-bigx
  run_ruby_unmet "$TEST_TMPDIR/d.SRCINFO" demo 1.0 $'ruby:\n  skip: [win32ole]'
  [ "$status" -eq 0 ]
  [ "$output" = $'hold\tbigx >= 2: ruby-bigx has 1.5 (pkgver)' ]
  run_ruby_unmet "$TEST_TMPDIR/d.SRCINFO" demo 1.0
  [ "${lines[0]}" = $'hold\twin32ole: not in depends' ]
}

@test "rbrules.sh: ruby_change names the gems that the new release adds and drops" {
  gem_v2 demo 1.0 '>= 3.2' 'old|>= 1' 'keep|~> 1'
  gem_v2 demo 2.0 '>= 3.2' 'keep|~> 2' 'new|>= 0'
  create_test_package "pkg" "rubygems" "upstream:
  registry: demo"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; ruby_change "$1" demo 1.0 2.0; ruby_change "$1" bashcov 3.3.0 4.0.3; ruby_change "$1" bashcov 0.1 4.0.3' \
    "$TEST_TMPDIR" "$TEST_TMPDIR/packages/pkg.yml"
  [ "$status" -eq 0 ]
  [ "$output" = $'adds new; drops old\nrubygems.org has no release 0.1 of bashcov to compare with' ]
}

@test "lib.sh: fired_alerts runs listed requires rules on the gems of a package of strategy rubygems" {
  gems_env
  bashcov_gem
  aur_srcinfo_remote bashcov "$FIXTURES_DIR/aur/bashcov.SRCINFO"
  create_test_package "bashcov" "rubygems" "upstream:
  registry: bashcov
alerts:
  - requires: unmet
    hold: true
  - requires: changed"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" 3.3.0 4.0.3' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/bashcov.yml"
  [ "$status" -eq 0 ]
  [ "$output" = $'hold\tsimplecov ~> 1.1: ruby-simplecov has 0.22.0\nnotice\trequire erb (optional): ruby-erb in neither depends nor optdepends' ]
}

# Helper: builds the .gem of gem $1 at version $2 in MOCK_FILES_DIR from the files of directory $3, tarred
# with the options in GEM_TAR_ARGS, and the spec YAML $4, with its v2 answer and the requirements after them
gem_build() {
  local work="$TEST_TMPDIR/gem-$1-$2" sha
  local -a entries
  mkdir -p "$work"
  mapfile -t entries < <(ls -A "$3")
  bsdtar -czf "$work/data.tar.gz" ${GEM_TAR_ARGS[@]+"${GEM_TAR_ARGS[@]}"} -C "$3" "${entries[@]}"
  printf '%s' "$4" | gzip -c >"$work/metadata.gz"
  bsdtar -cf "$MOCK_FILES_DIR/$1-$2.gem" -C "$work" metadata.gz data.tar.gz
  gem_v2 "$1" "$2" '>= 3.2' "${@:5}"
  sha=$(sha256sum "$MOCK_FILES_DIR/$1-$2.gem" | cut -d' ' -f1)
  S=$sha yq -i -o json '.sha = strenv(S)' "$MOCK_FILES_DIR/rubygems/v2/$1-$2.json"
}

# Helper: a gem shaped as bashcov 4.0.3, with a feature file that nothing requires, and the owners of
# its requires in the files database
bashcov_gem() {
  local g="$TEST_TMPDIR/gemsrc"
  mkdir -p "$g/lib/bashcov" "$g/bin" "$g/spec"
  printf '%s\n' 'require "optparse"' 'require "pathname"' 'require "bashcov/runner"' 'require "simplecov"' \
    'require "enumerator"' >"$g/lib/bashcov.rb"
  printf '%s\n' 'require "io/nonblock"' 'require_relative "lexer"' >"$g/lib/bashcov/runner.rb"
  printf '%s\n' 'module Lexer; end' >"$g/lib/bashcov/lexer.rb"
  printf '%s\n' 'require "erb"' >"$g/lib/bashcov/report.rb"
  printf '%s\n' '#!/usr/bin/env ruby' 'require "bashcov"' >"$g/bin/bashcov"
  printf '%s\n' 'require "rspec"' >"$g/spec/spec_helper.rb"
  gem_build bashcov 4.0.3 "$g" $'--- !ruby/object:Gem::Specification\nname: bashcov\nversion: !ruby/object:Gem::Version\n  version: 4.0.3\nbindir: bin\nexecutables:\n- bashcov\nrequire_paths:\n- lib\n' \
    'simplecov|~> 1.1'
  printf 'extra\truby\t3.4.13-1\tusr/lib/ruby/3.4.0/%s\n' optparse.rb pathname.rb x86_64-linux/io/nonblock.so >>"$MOCK_PACMAN_FILES"
  printf 'extra\t%s\t1-1\tusr/lib/ruby/gems/3.4.0/gems/%s\n' ruby-simplecov simplecov-1.3.2/lib/simplecov.rb \
    ruby-erb erb-4.0.4/lib/erb.rb >>"$MOCK_PACMAN_FILES"
}

# Helper: runs ruby_imports for package bashcov at 4.0.3 with .SRCINFO $1
run_ruby_imports() {
  create_test_package "bashcov" "rubygems" "upstream:
  registry: bashcov"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; ruby_imports "$@"' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/bashcov.yml" "$1" bashcov 4.0.3
}

@test "rbrules.sh: ruby_imports notes the requires of a gem that depends and optdepends miss" {
  gems_env 1.3.2
  bashcov_gem
  unmet_srcinfo "$TEST_TMPDIR/b.SRCINFO" bashcov bash ruby ruby-simplecov
  run_ruby_imports "$TEST_TMPDIR/b.SRCINFO"
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\trequire erb (optional): ruby-erb in neither depends nor optdepends' ]
  unmet_srcinfo "$TEST_TMPDIR/b.SRCINFO" bashcov bash ruby ruby-erb
  rm -rf "$AURTOMATOR_RUN_CACHE"/*
  run_ruby_imports "$TEST_TMPDIR/b.SRCINFO"
  [ "$output" = $'notice\trequire simplecov: ruby-simplecov not in depends' ]
}

@test "rbrules.sh: ruby_imports fails on a gem that does not match its sha256, and notes without ruby" {
  gems_env 1.3.2
  bashcov_gem
  unmet_srcinfo "$TEST_TMPDIR/b.SRCINFO" bashcov bash ruby ruby-simplecov
  printf '#!/usr/bin/env bash\nexit 127\n' >"$MOCK_DIR/ruby"
  chmod +x "$MOCK_DIR/ruby"
  run_ruby_imports "$TEST_TMPDIR/b.SRCINFO"
  [ "$output" = $'notice\timports: ruby is not installed, not read' ]
  rm "$MOCK_DIR/ruby"
  printf 'x' >>"$MOCK_FILES_DIR/bashcov-4.0.3.gem"
  run_ruby_imports "$TEST_TMPDIR/b.SRCINFO"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"bashcov-4.0.3.gem does not match its sha256"* ]]
}

# Owner names with spaces shift the columns of bsdtar -tv
@test "rbrules.sh: ruby_imports reads no release past 20 MB of Ruby files, whatever the owner names of its files" {
  gems_env 1.3.2
  local g="$TEST_TMPDIR/big" owner
  for owner in builder 'a b c'; do
    rm -rf "$g" "${AURTOMATOR_RUN_CACHE:?}"/*
    mkdir -p "$g/lib"
    printf '%s\n' 'require "erb"' >"$g/lib/bashcov.rb"
    truncate -s 21M "$g/lib/big.rb"
    GEM_TAR_ARGS=(--uname "$owner" --gname "$owner")
    gem_build bashcov 4.0.3 "$g" $'name: bashcov\nrequire_paths:\n- lib\n' 'simplecov|~> 1.1'
    unmet_srcinfo "$TEST_TMPDIR/b.SRCINFO" bashcov bash ruby ruby-simplecov
    run_ruby_imports "$TEST_TMPDIR/b.SRCINFO"
    [ "$output" = $'notice\timports: the release holds more than 20 MB of Ruby files, not read' ] || {
      echo "$owner: $output"
      return 1
    }
  done
}

@test "rbrules.sh: ruby_imports reads no release of more than 20000 Ruby files" {
  gems_env 1.3.2
  mkdir -p "$TEST_TMPDIR/many/lib"
  (cd "$TEST_TMPDIR/many/lib" && touch m{1..20001}.rb)
  gem_build bashcov 4.0.3 "$TEST_TMPDIR/many" $'name: bashcov\nrequire_paths:\n- lib\n' 'simplecov|~> 1.1'
  unmet_srcinfo "$TEST_TMPDIR/b.SRCINFO" bashcov bash ruby ruby-simplecov
  run_ruby_imports "$TEST_TMPDIR/b.SRCINFO"
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\timports: the release holds more than 20000 Ruby files and executables, not read' ]
}

# The spec of the gem names require_paths and bindir, and .. there leads out of the extracted files
@test "rbrules.sh: ruby_imports reads no file outside the gem through .. in require_paths and bindir" {
  gems_env 1.3.2
  local g="$TEST_TMPDIR/dots"
  mkdir -p "$g/lib" "$TEST_TMPDIR/outside"
  printf '%s\n' 'require "erb"' >"$g/lib/bashcov.rb"
  printf '%s\n' 'require "leakedlib"' >"$TEST_TMPDIR/outside/bashcov.rb"
  printf '%s\n' '#!/usr/bin/env ruby' 'require "leakedexe"' >"$TEST_TMPDIR/outside/evil"
  gem_build bashcov 4.0.3 "$g" $'name: bashcov\nbindir: ../../../outside\nexecutables:\n- evil\nrequire_paths:\n- lib\n- ../../../outside\n' \
    'simplecov|~> 1.1'
  printf 'extra\t%s\t1-1\tusr/lib/ruby/gems/3.4.0/gems/%s\n' ruby-erb erb-4.0.4/lib/erb.rb >>"$MOCK_PACMAN_FILES"
  unmet_srcinfo "$TEST_TMPDIR/b.SRCINFO" bashcov bash ruby ruby-simplecov
  run_ruby_imports "$TEST_TMPDIR/b.SRCINFO"
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\trequire erb: ruby-erb not in depends' ]
}

# ruby.map takes the first part of a require path that no package owns, and a yq expression built
# from it would read the environment of the runner
@test "rbrules.sh: ruby_imports leaves out requires of strings outside the form of a feature path" {
  gems_env 1.3.2
  local g="$TEST_TMPDIR/inject"
  mkdir -p "$g/lib"
  printf '%s\n' 'require "erb"' "require 'z\"], strenv(RB_PROBE), .[\"z'" 'require "two words"' >"$g/lib/bashcov.rb"
  gem_build bashcov 4.0.3 "$g" $'name: bashcov\nrequire_paths:\n- lib\n' 'simplecov|~> 1.1'
  printf 'extra\t%s\t1-1\tusr/lib/ruby/gems/3.4.0/gems/%s\n' ruby-erb erb-4.0.4/lib/erb.rb >>"$MOCK_PACMAN_FILES"
  unmet_srcinfo "$TEST_TMPDIR/b.SRCINFO" bashcov bash ruby ruby-simplecov
  export RB_PROBE=leaked
  run_ruby_imports "$TEST_TMPDIR/b.SRCINFO"
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\trequire erb: ruby-erb not in depends' ]
}

# bigdecimal requires bigdecimal.so, the extension that the gem builds at install, and rubygems comes with ruby
@test "rbrules.sh: ruby_imports reads .so and .jar as features, own extensions, ruby.skip and the depends of ruby" {
  gems_env 1.3.2
  local g="$TEST_TMPDIR/ext"
  mkdir -p "$g/lib" "$g/ext/demo_ext"
  printf '%s\n' 'if RUBY_ENGINE == "jruby"' '  require "demo.jar"' 'else' '  require "demo.so"' 'end' 'require "demo_ext/fast.so"' \
    'require "bigdecimal.so"' 'require "win32/process" if RUBY_PLATFORM =~ /mswin|mingw/' 'require "ffi/win32/extensions"' \
    'require "rubygems/command_manager"' 'require "missing"' >"$g/lib/demo.rb"
  printf '%s\n' 'require "mkmf"' 'create_makefile("demo_ext/fast")' >"$g/ext/demo_ext/extconf.rb"
  gem_build demo 1.0 "$g" $'name: demo\nextensions:\n- ext/demo_ext/extconf.rb\nrequire_paths:\n- lib\n'
  printf 'extra\t%s\t1-1\tusr/lib/ruby/%s\n' ruby-bigdecimal gems/3.4.0/gems/bigdecimal-3.1.9/lib/bigdecimal.rb \
    rubygems 3.4.0/rubygems/command_manager.rb >>"$MOCK_PACMAN_FILES"
  printf 'ruby gmp libyaml rubygems\n' >"$MOCK_PACMAN_DEPENDS"
  unmet_srcinfo "$TEST_TMPDIR/d.SRCINFO" ruby-demo ruby ruby-bigdecimal
  create_test_package "demo" "rubygems" "upstream:
  registry: demo
ruby:
  skip:
    - ffi-win32-extensions"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; ruby_imports "$@"' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/demo.yml" \
    "$TEST_TMPDIR/d.SRCINFO" demo 1.0
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\trequire missing: no package owns it' ]
}

# Entries of extensions: name files of the tree, and .. would name one beside it
@test "rbrules.sh: ruby_imports reads no entry of extensions: with .. in its path" {
  gems_env 1.3.2
  local g="$TEST_TMPDIR/ext"
  mkdir -p "$g/lib" "$g/ext" "$g/ext2"
  printf '%s\n' 'require "evil_ext"' >"$g/lib/demo.rb"
  printf '%s\n' 'x = 1' >"$g/ext/other.rb"
  printf '%s\n' 'create_makefile("evil_ext")' >"$g/ext2/extconf.rb"
  gem_build demo 1.0 "$g" $'name: demo\nextensions:\n- ext/../ext2/extconf.rb\nrequire_paths:\n- lib\n'
  unmet_srcinfo "$TEST_TMPDIR/d.SRCINFO" ruby-demo ruby
  create_test_package "demo" "rubygems" "upstream:
  registry: demo"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; ruby_imports "$@"' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/demo.yml" \
    "$TEST_TMPDIR/d.SRCINFO" demo 1.0
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\trequire evil_ext: no package owns it' ]
}

# Readers block on a FIFO until a writer opens it
@test "rbrules.sh: ruby_imports drops members of the gem that are no regular file or directory" {
  gems_env 1.3.2
  local g="$TEST_TMPDIR/ext"
  mkdir -p "$g/lib" "$g/ext/demo_ext"
  printf '%s\n' 'require "demo_ext.so"' 'require "missing"' >"$g/lib/demo.rb"
  mkfifo "$g/ext/demo_ext/extconf.rb"
  gem_build demo 1.0 "$g" $'name: demo\nextensions:\n- ext/demo_ext/extconf.rb\nrequire_paths:\n- lib\n'
  unmet_srcinfo "$TEST_TMPDIR/d.SRCINFO" ruby-demo ruby
  create_test_package "demo" "rubygems" "upstream:
  registry: demo"
  run --separate-stderr timeout 20 bash -c 'source "$0/scripts/lib.sh"; ruby_imports "$@"' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/demo.yml" \
    "$TEST_TMPDIR/d.SRCINFO" demo 1.0
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\trequire missing: no package owns it' ]
}

@test "rbrules.sh: ruby_map compares the keys of ruby.map with a gem name as written" {
  create_test_package "pkg" "rubygems" 'upstream:
  registry: demo
ruby:
  map:
    rubyXL: ruby-rubyxl
    other: [x]'
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; for key in "${@:2}"; do printf "[%s]\n" "$(ruby_map "$1" "$key")"; done' \
    "$TEST_TMPDIR" "$TEST_TMPDIR/packages/pkg.yml" rubyXL rubyxl other 'z"], strenv(HOME), .["z'
  [ "$status" -eq 0 ]
  [ "$output" = $'[ruby-rubyxl]\n[]\n[]\n[]' ]
}

@test "lib.sh: fired_alerts runs requires: imports on the gem of a package of strategy rubygems" {
  gems_env 1.3.2
  bashcov_gem
  unmet_srcinfo "$TEST_TMPDIR/b.SRCINFO" bashcov bash ruby ruby-simplecov
  aur_srcinfo_remote bashcov "$TEST_TMPDIR/b.SRCINFO"
  create_test_package "bashcov" "rubygems" "upstream:
  registry: bashcov
alerts:
  - requires: imports"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" "" 4.0.3' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/bashcov.yml"
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\trequire erb (optional): ruby-erb in neither depends nor optdepends' ]
}

@test "lib.sh: fired_alerts prints a space for each control character of a requires rule" {
  gems_env 1.3.2
  local g="$TEST_TMPDIR/ctl"
  mkdir -p "$g/lib"
  printf '%s\n' 'require "simplecov"' >"$g/lib/demo.rb"
  printf '$%s = 1\n' "$(printf '\033')" >"$g/lib/bad.rb"
  gem_build demo 1.0 "$g" $'name: demo\nrequire_paths:\n- lib\n' 'simplecov|>= 0'
  printf 'extra\truby-simplecov\t1-1\tusr/lib/ruby/gems/3.4.0/gems/simplecov-1.3.2/lib/simplecov.rb\n' >>"$MOCK_PACMAN_FILES"
  unmet_srcinfo "$TEST_TMPDIR/d.SRCINFO" demo ruby ruby-simplecov
  aur_srcinfo_remote demo "$TEST_TMPDIR/d.SRCINFO"
  create_test_package "demo" "rubygems" "upstream:
  registry: demo
alerts:
  - requires: imports"
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" "" 1.0' "$TEST_TMPDIR" "$TEST_TMPDIR/packages/demo.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == $'notice\timports: lib/bad.rb does not parse: \'$ \' is not allowed as a global variable name'* ]]
  [[ "${output#*$'\t'}" != *[[:cntrl:]]* ]]
}

@test "alerts.sh: _fired_requires prints a space for each byte that publish refuses" {
  export NOTE=$'a\001b\tc\177d\xc2\x9be\xc3\x82'
  run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; _python_rule() { printf "notice\t%s\n" "$NOTE"; }
    offline="" PY_STATE=ready RB_STATE=none; _fired_requires unmet "" ""' "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = $'notice\ta b c d e\xc3\x82' ]
}

# === ruby sources ===

# Helper: package ruby-simplecov-cobertura of a strategy that finds 4.0.0, at current 3.2.0 with the YAML
# lines $1, whose AUR .SRCINFO has the depends after it, and its .gem of 4.0.0 on rubygems.org
ruby_package() {
  gems_env 1.3.2
  stand_in_strategy step 4.0.0
  local g="$TEST_TMPDIR/cobertura"
  mkdir -p "$g/lib"
  printf '%s\n' 'require "simplecov"' 'require "rexml/document"' >"$g/lib/simplecov-cobertura.rb"
  gem_build simplecov-cobertura 4.0.0 "$g" $'name: simplecov-cobertura\nrequire_paths:\n- lib\n' 'rexml|>= 0' 'simplecov|~> 1.0'
  printf 'extra\t%s\t1-1\tusr/lib/ruby/gems/3.4.0/gems/%s\n' ruby-simplecov simplecov-1.3.2/lib/simplecov.rb \
    ruby-rexml rexml-3.4.4/lib/rexml/document.rb >>"$MOCK_PACMAN_FILES"
  unmet_srcinfo "$TEST_TMPDIR/r.SRCINFO" ruby-simplecov-cobertura "${@:2}"
  aur_srcinfo_remote ruby-simplecov-cobertura "$TEST_TMPDIR/r.SRCINFO"
  create_test_package "ruby-simplecov-cobertura" "step" "current: '3.2.0'
allow_missing_arch: false
$1"
}

@test "check-all: fails the check of a package whose depends hold Ruby and that names no gem" {
  ruby_package "" ruby ruby-simplecov
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_TMPDIR/.status/ruby-simplecov-cobertura")" == "check_failed: "*"packages/ruby-simplecov-cobertura.yml: its depends hold Ruby packages, so set ruby.gem or ruby: none"* ]]
}

@test "check-all: runs no requires rule for ruby: none or without Ruby in depends" {
  ruby_package "ruby: none" ruby ruby-simplecov
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/ruby-simplecov-cobertura")" = "new_version: 4.0.0" ]
  [ ! -e "$TEST_TMPDIR/.status/_alerts" ]
  ruby_package "" bash glibc
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$(cat "$TEST_TMPDIR/.status/ruby-simplecov-cobertura")" = "new_version: 4.0.0" ]
  ! grep -q rubygems.org "$CURL_ARGS_LOG"
}

@test "check-all: runs every requires rule as a notice for a package with ruby.gem" {
  ruby_package $'ruby:\n  gem: simplecov-cobertura' ruby ruby-simplecov
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/ruby-simplecov-cobertura")" = "new_version: 4.0.0" ]
  grep -qxF $'ruby-simplecov-cobertura\tnotice\trubygems.org has no release 3.2.0 of simplecov-cobertura to compare with' \
    "$TEST_TMPDIR/.status/_alerts"
  grep -qxF $'ruby-simplecov-cobertura\tnotice\trexml: not in depends' "$TEST_TMPDIR/.status/_alerts"
  grep -qxF $'ruby-simplecov-cobertura\tnotice\trequire rexml/document: ruby-rexml not in depends' "$TEST_TMPDIR/.status/_alerts"
}

@test "check-all: runs no changed rule on gems for a package with pkgver_dash" {
  ruby_package $'ruby:\n  gem: simplecov-cobertura\npkgver_dash: _' ruby ruby-simplecov
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/ruby-simplecov-cobertura")" = "new_version: 4.0.0" ]
  grep -qxF $'ruby-simplecov-cobertura\tnotice\trexml: not in depends' "$TEST_TMPDIR/.status/_alerts"
  ! grep -qF 'to compare with' "$TEST_TMPDIR/.status/_alerts"
}

@test "check-all: runs the requires rules on the upstream version of a gem package with pkgver_format" {
  ruby_package $'ruby:\n  gem: simplecov-cobertura\npkgver_format: \'4.%s\'' ruby ruby-simplecov
  sed -i "s/^current: '3.2.0'\$/current: '4.3.2.0'/" "$TEST_TMPDIR/packages/ruby-simplecov-cobertura.yml"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/ruby-simplecov-cobertura")" = "new_version: 4.4.0.0" ]
  grep -qxF $'ruby-simplecov-cobertura\tnotice\trexml: not in depends' "$TEST_TMPDIR/.status/_alerts"
}

@test "check-all: holds the update that a listed rule on a gem fires on" {
  ruby_package $'ruby:\n  gem: simplecov-cobertura\nalerts:\n  - requires: unmet\n    hold: true' ruby ruby-simplecov
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/ruby-simplecov-cobertura")" = "held: 4.0.0" ]
  [[ "$output" == *"ruby-simplecov-cobertura: update 3.2.0 → 4.0.0 held: rexml: not in depends"* ]]
}

@test "lib.sh: fired_alerts runs no default rule on gems in prepare and publish" {
  ruby_package $'ruby:\n  gem: simplecov-cobertura' ruby ruby-simplecov
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  local mode
  for mode in held offline; do
    run --separate-stderr bash -c 'source "$0/scripts/lib.sh"; fired_alerts "$1" 3.2.0 4.0.0 "$2"' "$TEST_TMPDIR" \
      "$TEST_TMPDIR/packages/ruby-simplecov-cobertura.yml" "$mode"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  [ ! -e "$CURL_ARGS_LOG" ]
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

# GitHub cuts a README past 500 KiB, and a row takes about 198 bytes
@test "update-readme: splits the table into pages by first letter past AURTOMATOR_README_MAX_KIB" {
  local name
  for name in alpha avocado beta 0ad zeta aa0 aa1 aa2 aa3 aa4 aa5 aa6 aa7 aa8 aa9; do
    create_test_package "$name" github-release $'upstream:\n  project: owner/repo\ncurrent: \'1.0.0\''
  done
  mkdir -p "$TEST_TMPDIR/.status" "$TEST_TMPDIR/table"
  echo "check_failed: boom" >"$TEST_TMPDIR/.status/alpha"
  echo "updated: 2.0.0" >"$TEST_TMPDIR/.status/beta"
  echo up_to_date >"$TEST_TMPDIR/.status/avocado"
  echo "an old page" >"$TEST_TMPDIR/table/q.md"
  echo "notes of the user" >"$TEST_TMPDIR/table/notes.txt"
  printf '%s\n' '# Packages' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' 'end' >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q
  AURTOMATOR_README_MAX_KIB=2 run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  # The README keeps the card, the counts, the packages that need attention and the links
  grep -qF 'src="stats/card.svg"' "$TEST_TMPDIR/README.md"
  grep -qxF '15 packages: ✅ 13, ❌ 1, 📦 1' "$TEST_TMPDIR/README.md"
  grep -qF '>alpha</a>' "$TEST_TMPDIR/README.md"
  grep -qF '>beta</a>' "$TEST_TMPDIR/README.md"
  run ! grep -qF '>avocado</a>' "$TEST_TMPDIR/README.md"
  grep -qxF 'Every package: [0-9](table/0-9.md) [a](table/a.md) [b](table/b.md) [z](table/z.md)' "$TEST_TMPDIR/README.md"
  [ "$(tail -n 1 "$TEST_TMPDIR/README.md")" = end ]
  # Each page holds the rows of its letter
  grep -qF '>alpha</a>' "$TEST_TMPDIR/table/a.md"
  grep -qF '>avocado</a>' "$TEST_TMPDIR/table/a.md"
  run ! grep -qF '>beta</a>' "$TEST_TMPDIR/table/a.md"
  grep -qF '>0ad</a>' "$TEST_TMPDIR/table/0-9.md"
  grep -qxF '[Back to the README](../README.md)' "$TEST_TMPDIR/table/z.md"
  [ ! -e "$TEST_TMPDIR/table/q.md" ]
  # The README is written three times here, and each text replaces the one before
  run find "$TEST_TMPDIR" -maxdepth 1 -name 'README.md.*'
  [ -z "$output" ]
  # Under the limit the README holds every row again, and the pages go
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF '>avocado</a>' "$TEST_TMPDIR/README.md"
  [ "$(cd "$TEST_TMPDIR/table" && ls)" = notes.txt ]
}

# Runs where most packages fail, as when the network of the runner is down, put most rows in the
# table of packages that need attention
@test "update-readme: keeps the table of packages that need attention within the limit" {
  local i
  mkdir -p "$TEST_TMPDIR/.status"
  for i in $(seq 10 39); do
    create_test_package "p$i" github-release $'upstream:\n  project: owner/repo\ncurrent: \'1.0.0\''
    echo "check_failed: boom" >"$TEST_TMPDIR/.status/p$i"
  done
  printf '%s\n' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q
  AURTOMATOR_README_MAX_KIB=2 run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  (($(wc -c <"$TEST_TMPDIR/README.md") <= 2048))
  [[ "$(cat "$TEST_TMPDIR/README.md")" =~ $'\n'([0-9]+)" more packages need attention, in the pages below"$'\n' ]]
  [ "$((BASH_REMATCH[1] + $(grep -c '<tr><td>' "$TEST_TMPDIR/README.md")))" = 30 ]
  [ "$(grep -c '<tr><td>' "$TEST_TMPDIR/table/p.md")" = 30 ]
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

# A commit can add README.md.tmp as a link, which a write to that fixed name would follow
@test "update-readme: writes nothing through a README.md.tmp link" {
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
  printf '%s\n' '<!-- BADGES:START -->' '<!-- BADGES:END -->' \
    '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  chmod 0644 "$TEST_TMPDIR/README.md"
  mkdir "$TEST_TMPDIR/outside"
  echo keep >"$TEST_TMPDIR/outside/target"
  ln -s outside/target "$TEST_TMPDIR/README.md.tmp"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/outside/target")" = keep ]
  [ ! -L "$TEST_TMPDIR/README.md" ]
  grep -qF '>pkg-a</a>' "$TEST_TMPDIR/README.md"
  [ "$(stat -c %a "$TEST_TMPDIR/README.md")" = 644 ]
  [ "$(find "$TEST_TMPDIR" -maxdepth 1 -name 'README.md.*' ! -name README.md.tmp)" = "" ]
}

# YAML reaches main without the validator by a direct push or a merge on a red check
@test "update-readme: writes the values of the table as text" {
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo\ncurrent: \'1.0<b>&x\'\nlast_updated: \'"><img src=x>\''
  printf '%s\n' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF '<td>1.0&lt;b&gt;&amp;x</td>' "$TEST_TMPDIR/README.md"
  grep -qF '<td nowrap>&quot;&gt;&lt;img src=x&gt;</td>' "$TEST_TMPDIR/README.md"
  run grep -cE '<b>|<img src=x>' "$TEST_TMPDIR/README.md"
  [ "$output" = 0 ]
}

# Blank lines end the HTML block of the table, and GitHub reads the text after them as Markdown
@test "update-readme: writes a space for each newline and control character of a value" {
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo\ncurrent: "1.0\\n\\n[Sign in](https://evil.example/login)\\t\\e\\n"'
  printf '%s\n' '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 0 ]
  grep -qF '<td>1.0  [Sign in](https://evil.example/login)  </td>' "$TEST_TMPDIR/README.md"
  run sed -n '/^<table>$/,/^<\/table>$/{/^$/p}' "$TEST_TMPDIR/README.md"
  [ -z "$output" ]
}

@test "update-readme: refuses a README.md that is a link" {
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
  mkdir "$TEST_TMPDIR/outside"
  printf '%s\n' secret '<!-- PACKAGES:START -->' '<!-- PACKAGES:END -->' >"$TEST_TMPDIR/outside/readme"
  ln -s outside/readme "$TEST_TMPDIR/README.md"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 3 ]
  [[ "$output" == *"README.md is a symbolic link"* ]]
  [ -L "$TEST_TMPDIR/README.md" ]
}

# === tag_versions ===

@test "lib.sh: tag_versions fills the groups and keeps every other character" {
  run bash -c 'source "$0/scripts/lib.sh"; tag_versions "$1" "$2" <<<"$3"' "$TEST_TMPDIR" \
    '^([0-9]+)-([0-9]+)$' 'r1.\2\1\0' '10-20'
  [ "$status" -eq 0 ]
  [ "$output" = 'r1.2010\0' ]
}

@test "lib.sh: tag_versions fills \\p with the time it gets" {
  run bash -c 'source "$0/scripts/lib.sh"; tag_versions "$1" "$2" "$3" <<<"$4"' "$TEST_TMPDIR" \
    '^v([0-9.]+)-dev\.([0-9a-f]+)$' '\1dev\p+\2' '20261116094825' 'v0.1.0-dev.0f9e8d7c6b5a'
  [ "$status" -eq 0 ]
  [ "$output" = '0.1.0dev20261116094825+0f9e8d7c6b5a' ]
}

@test "lib.sh: tag_versions fails on \\p without a time" {
  run bash -c 'source "$0/scripts/lib.sh"; tag_versions "$1" "$2" <<<"$3"' "$TEST_TMPDIR" \
    '^v([0-9.]+)$' '\1.\p' 'v1.2'
  [ "$status" -eq 1 ]
  [ "$output" = 'tag_version_replace holds \p, which only github-nightly fills' ]
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

# tag_version_regex, scraped pages and registries can return a word
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

# Skipped downgrades are logged with the name of their package
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
  grep -qF '<td nowrap>❌ failed</td></tr>' "$TEST_TMPDIR/README.md"
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
# for the script. Its copy with another value stands in.
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

# setup.sh writes single quotes, and before 0.3.0 wrote double quotes
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

  # Last lines without a newline count
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

# setup.sh writes the file, so a link that a pull request adds would point it outside
@test "lib.sh: load_config refuses a tracked link to a missing file" {
  git -C "$TEST_TMPDIR" init -q
  ln -s ../outside/created "$TEST_TMPDIR/.aurtomator.conf"
  git -C "$TEST_TMPDIR" add -f .aurtomator.conf
  run load_config_values
  [ "$status" -eq 1 ]
  [[ "$output" == "$TEST_TMPDIR/.aurtomator.conf is tracked by git"* ]]
}

@test "lib.sh: load_config refuses a link" {
  printf "GIT_AUTHOR_NAME='a'\nGIT_AUTHOR_EMAIL='b'\nAUR_SSH_KEY='c'\nGPG_KEY_ID='d'\n" >"$TEST_TMPDIR/conf"
  ln -s conf "$TEST_TMPDIR/.aurtomator.conf"
  run load_config_values
  [ "$status" -eq 1 ]
  [ "$output" = "$TEST_TMPDIR/.aurtomator.conf is a symbolic link, so setup.sh would write the file it points to. Remove the link: rm .aurtomator.conf" ]
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
  [ "$status" -eq 3 ]
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
  [ "$status" -eq 3 ]
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
  [ "$status" -eq 3 ]
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
  [ "$status" -eq 3 ]
  [[ "$output" == *"No <!-- PACKAGES:START --> marker found in README.md"* ]]
  cmp "$TEST_TMPDIR/README.orig" "$TEST_TMPDIR/README.md"
}

# Repositories made from the template keep their setup steps until their first
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
  [ "$status" -eq 3 ]
  [[ "$output" == *"No <!-- BADGES:END --> marker found in README.md"* ]]
  cmp "$TEST_TMPDIR/README.orig" "$TEST_TMPDIR/README.md"
}

# Sections are written up to their start marker and from their end marker, so a
# swapped or second marker would copy the README into itself on every run
@test "update-readme: fails and keeps the README with the table markers swapped" {
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
  printf '%s\n' '# test' '<!-- PACKAGES:END -->' 'text' '<!-- PACKAGES:START -->' 'old table' >"$TEST_TMPDIR/README.md"
  cp "$TEST_TMPDIR/README.md" "$TEST_TMPDIR/README.orig"
  git -C "$TEST_TMPDIR" init -q
  run "$TEST_TMPDIR/scripts/update-readme.sh"
  [ "$status" -eq 3 ]
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
  [ "$status" -eq 3 ]
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
  [ "$status" -eq 3 ]
  [[ "$output" == *"README.md has <!-- BADGES:END --> above <!-- BADGES:START -->"* ]]
  cmp "$TEST_TMPDIR/README.orig" "$TEST_TMPDIR/README.md"
}

# The badge rewrite drops the lines between the badge markers, a marker of the table among them
@test "update-readme: fails and keeps the README whose two pairs of markers cross or nest" {
  local order
  create_test_package "pkg-a" "github-release" $'upstream:\n  project: owner/repo'
  git -C "$TEST_TMPDIR" init -q
  for order in 'BADGES:START PACKAGES:START BADGES:END PACKAGES:END' 'PACKAGES:START BADGES:START PACKAGES:END BADGES:END' \
    'BADGES:START PACKAGES:START PACKAGES:END BADGES:END' 'PACKAGES:START BADGES:START BADGES:END PACKAGES:END'; do
    printf '# test\n' >"$TEST_TMPDIR/README.md"
    printf '<!-- %s -->\ntext\n' $order >>"$TEST_TMPDIR/README.md"
    cp "$TEST_TMPDIR/README.md" "$TEST_TMPDIR/README.orig"
    run "$TEST_TMPDIR/scripts/update-readme.sh"
    [ "$status" -eq 3 ] || {
      echo "taken: $order"
      return 1
    }
    [[ "$output" == *"README.md has a marker of one pair between <!-- BADGES:START --> and <!-- BADGES:END --> or between <!-- PACKAGES:START --> and <!-- PACKAGES:END -->; keep the two pairs apart"* ]]
    cmp "$TEST_TMPDIR/README.orig" "$TEST_TMPDIR/README.md"
  done
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
  # Bare remote, so the push of the copied clone succeeds
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
if [[ " $* " == *" -sIL "* ]]; then
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
if [[ " $* " == *" -sIL "* ]]; then
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
if [[ " $* " == *" -sIL "* ]]; then
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
if [[ " $* " == *" -sIL "* ]]; then
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
  # Bare remote, so the push of the copied clone succeeds
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

  run --separate-stderr "$TEST_TMPDIR/scripts/check-update.sh" "mypkg"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"DOWNGRADE 3.0.0"*"2.0.0"* ]]
  # The version goes to stdout alone, and check-all.sh decides on it
  [ "$output" = "2.0.0" ]
}

@test "check-update: normal upgrade path does not log DOWNGRADE (regression)" {
  # Mock returns v2.0.0. Current 1.0.0 < 2.0.0 = normal upgrade.
  create_test_package "mypkg" "github-release" "upstream:
  type: github
  project: owner/repo
current: '1.0.0'"

  run --separate-stderr "$TEST_TMPDIR/scripts/check-update.sh" "mypkg"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"update available 1.0.0"*"2.0.0"* ]]
  [[ "$stderr" != *"DOWNGRADE"* ]]
  [ "$output" = "2.0.0" ]
}

@test "check-all: writes 'available_downgrade:' for a package that allows downgrades" {
  local value
  # Mock returns v2.0.0. Current 3.0.0 > 2.0.0 = downgrade.
  for value in true True TRUE; do
    create_test_package "pkg-down" "github-release" "upstream:
  type: github
  project: owner/repo
current: '3.0.0'
allow_downgrade: $value"

    "$TEST_TMPDIR/scripts/check-all.sh" 2>/dev/null || true
    [ -f "$TEST_TMPDIR/.status/pkg-down" ]
    [ "$(cat "$TEST_TMPDIR/.status/pkg-down")" = "available_downgrade: 2.0.0" ] || {
      echo "allow_downgrade: $value gave $(cat "$TEST_TMPDIR/.status/pkg-down")"
      return 1
    }
  done
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
  # Stub update-pkg.sh in the temp workspace always succeeds, so the test
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
  local value
  stand_in_strategy jump 2026102100
  for value in true True TRUE; do
    create_test_package "pkg-jump" "jump" "current: '13'
allow_version_jump: $value"

    run "$TEST_TMPDIR/scripts/check-all.sh"
    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_TMPDIR/.status/pkg-jump")" = "new_version: 2026102100" ] || {
      echo "allow_version_jump: $value gave $(cat "$TEST_TMPDIR/.status/pkg-jump")"
      return 1
    }
  done
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

@test "check-all: holds an update an alert with hold: true in any case fires on" {
  local value
  stand_in_strategy step 29+1
  for value in true True TRUE; do
    create_test_package "pkg-hold" "step" "current: 28+25
alerts:
  - when: major
    hold: $value
    note: Raise makedepends java-environment to 28"

    run "$TEST_TMPDIR/scripts/check-all.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pkg-hold: update 28+25 → 29+1 held: Raise makedepends java-environment to 28"* ]]
    [ "$(cat "$TEST_TMPDIR/.status/pkg-hold")" = "held: 29+1" ] || {
      echo "hold: $value gave $(cat "$TEST_TMPDIR/.status/pkg-hold")"
      return 1
    }
    [ "$(failed_statuses "$TEST_TMPDIR/.status")" = "0" ]
  done
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

@test "check-all: holds an update that a requires rule fires on" {
  python_aur zensical-bin
  create_test_package "zensical-bin" "pypi" "upstream:
  registry: zensical
current: 0.0.74
alerts:
  - requires: changed
    hold: true"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zensical-bin: update 0.0.74 → 0.1.3 held: drops deepmerge"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/zensical-bin")" = "held: 0.1.3" ]
  [ "$(head -n 1 "$TEST_TMPDIR/.status/_alerts")" = $'zensical-bin\thold\tdrops deepmerge' ]
}

@test "check-all: holds an update whose release of current PyPI lacks, with a note" {
  python_aur gone-bin
  create_test_package "gone-bin" "pypi" "upstream:
  registry: gone
current: 0.1.2
alerts:
  - requires: changed
    hold: true"
  pypi_fake gone 3.2.1

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gone-bin: update 0.1.2 → 3.2.1 held: PyPI has no release 0.1.2 of gone to compare with"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/gone-bin")" = "held: 3.2.1" ]
  [ ! -e "$TEST_TMPDIR/.status/_hosts" ]
}

@test "check-all: a requires rule fires nothing between releases without requirements" {
  python_aur plain
  create_test_package "plain" "pypi" "upstream:
  registry: plain
current: 3.2.0
allow_missing_arch: false
alerts:
  - requires: changed
    hold: true"
  pypi_fake plain 3.2.0
  pypi_fake plain 3.2.1
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/plain")" = "new_version: 3.2.1" ]
}

@test "check-all: a requires rule whose request fails fails the check, names the host and runs again" {
  python_aur flaky-bin
  create_test_package "flaky-bin" "pypi" "upstream:
  registry: flaky
current: '1.0'
alerts:
  - requires: changed
    hold: true"
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$(cat "$TEST_TMPDIR/.status/flaky-bin")" = "check_failed: https://pypi.org/simple/flaky/: The requested URL returned error: 503" ]
  [ "$(cat "$TEST_TMPDIR/.status/_hosts")" = $'flaky-bin\tpypi.org' ]
  [ "$(grep -c 'pypi.org/simple/flaky/$' "$CURL_ARGS_LOG")" -eq 2 ]
}

# Helper: creates zensical-bin at 0.0.74, which the alerts $1 or a requires rule hold at 0.1.3,
# and python-zensical-ui at 0.0.41 with the YAML lines $2, which zensical pins to 0.0.43
create_zensical_pair() {
  create_test_package "zensical-bin" "pypi" "upstream:
  registry: zensical
current: 0.0.74
alerts:
${1:-  - requires: changed
    hold: true}"
  create_test_package "python-zensical-ui" "pypi" "upstream:
  registry: zensical-ui
  pin_from: zensical
current: 0.0.41
${2:-}"
  [[ -n "${1:-}" ]] || python_aur zensical-bin
}

@test "check-all: a package with pin_from waits for the held update of its project" {
  create_zensical_pair

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"python-zensical-ui: update 0.0.41 → 0.0.43 waits for the held update of zensical-bin"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/zensical-bin")" = "held: 0.1.3" ]
  [ "$(cat "$TEST_TMPDIR/.status/python-zensical-ui")" = "held: 0.0.43" ]
  [ "$(head -n 1 "$TEST_TMPDIR/.status/_alerts")" = $'zensical-bin\thold\tdrops deepmerge' ]
  [ "$(tail -n 2 "$TEST_TMPDIR/.status/_alerts")" = $'python-zensical-ui\twait\tWaits for the held update of zensical-bin\nzensical-bin\tnotice\tpython-zensical-ui waits for this update' ]
}

# The pin comes from the newest release of the project, which fits the companion only once the
# package of the project reaches that release
@test "check-all: a package with pin_from waits for its project in a cooldown, a failed check or a skipped downgrade" {
  local project want
  while IFS='|' read -r project want; do
    create_test_package "zensical-bin" "pypi" "upstream:
  registry: zensical
${project//;/$'\n'}
allow_missing_arch: false"
    create_test_package "python-zensical-ui" "pypi" "upstream:
  registry: zensical-ui
  pin_from: zensical
current: 0.0.41
allow_missing_arch: false"
    run "$TEST_TMPDIR/scripts/check-all.sh"
    [ "$status" -eq 0 ] && [[ "$(cat "$TEST_TMPDIR/.status/zensical-bin")" == "$want"* ]] &&
      [ "$(cat "$TEST_TMPDIR/.status/python-zensical-ui")" = "held: 0.0.43" ] &&
      [[ "$output" == *"python-zensical-ui: update 0.0.41 → 0.0.43 waits for the update of zensical-bin"* ]] &&
      [ "$(cat "$TEST_TMPDIR/.status/_alerts")" = $'python-zensical-ui\twait\tWaits for the update of zensical-bin' ] || {
      echo "$want: $output"
      return 1
    }
  done <<EOF
current: 0.0.74;cooldown_days: 7;last_updated: $(date -u +%F)|cooldown:
current: 0.0.74;cooldown_days: soon|check_failed: cooldown_days
current: 9.0.0|downgrade_skipped: 0.1.3
EOF
}

@test "check-all: a package with pin_from goes on when its project is not held or not there" {
  # zensical-bin is a package of the AUR, so neither asks check-arch.sh for its arches there
  create_zensical_pair "  - from: '9.0'
    hold: true
    note: Not reached
allow_missing_arch: false" "allow_missing_arch: false"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/zensical-bin")" = "new_version: 0.1.3" ]
  [ "$(cat "$TEST_TMPDIR/.status/python-zensical-ui")" = "new_version: 0.0.43" ]
  rm "$TEST_TMPDIR/packages/zensical-bin.yml"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/python-zensical-ui")" = "new_version: 0.0.43" ]
}

# The runs read no linked package file, so it can be the package of any project. The jobs hand
# a link to builder as a link to itself.
@test "check-all: a package with pin_from waits while a package file is a link" {
  local link
  create_zensical_pair "  - from: '9.0'
    hold: true
    note: Not reached
allow_missing_arch: false" "allow_missing_arch: false"
  cp "$TEST_TMPDIR/packages/zensical-bin.yml" "$TEST_TMPDIR/project.yml"
  for link in zensical-bin other; do
    rm -f "$TEST_TMPDIR/packages/$link.yml"
    ln -s "$link.yml" "$TEST_TMPDIR/packages/$link.yml"
    run "$TEST_TMPDIR/scripts/check-all.sh"
    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_TMPDIR/.status/$link")" = "check_failed: packages/$link.yml is a link, and the runs read regular files alone" ]
    [ "$(cat "$TEST_TMPDIR/.status/python-zensical-ui")" = "held: 0.0.43" ] || {
      echo "$link: $(cat "$TEST_TMPDIR/.status/python-zensical-ui")"
      return 1
    }
    [[ "$output" == *"python-zensical-ui: update 0.0.41 → 0.0.43 waits for the update of $link"* ]]
    [ "$(cat "$TEST_TMPDIR/.status/_alerts")" = "python-zensical-ui"$'\t'"wait"$'\t'"Waits for the update of $link" ]
    rm "$TEST_TMPDIR/packages/$link.yml"
    cp "$TEST_TMPDIR/project.yml" "$TEST_TMPDIR/packages/zensical-bin.yml"
  done
}

@test "check-all: a package with pin_from takes the project of a registry in another spelling" {
  create_test_package "zensical-bin" "pypi" "upstream:
  registry: Zensical
current: 0.0.74
alerts:
  - from: '0.1'
    hold: true
    note: New minor"
  create_test_package "python-zensical-ui" "pypi" "upstream:
  registry: zensical-ui
  pin_from: zensical
current: 0.0.41"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/zensical-bin")" = "held: 3.2.1" ]
  [ "$(cat "$TEST_TMPDIR/.status/python-zensical-ui")" = "held: 0.0.43" ]
}

@test "check-all: checks packages with pin_from after the others, which the run number rotates" {
  create_zensical_pair
  create_test_package "aaa" "pypi" "upstream:
  registry: requests
current: 3.2.1"
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"

  GITHUB_RUN_NUMBER=1 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/python-zensical-ui")" = "held: 0.0.43" ]
  run grep -o -E 'pypi\.org/(pypi|simple)/[^ ]+' "$CURL_ARGS_LOG"
  [ "$output" = $'pypi.org/pypi/zensical/json\npypi.org/simple/zensical/\npypi.org/simple/zensical/\npypi.org/pypi/requests/json\npypi.org/pypi/zensical/json\npypi.org/simple/zensical/' ]
}

@test "check-all: a package with pin_from waits for the second check of its project" {
  create_zensical_pair "  - from: '0.1'
    hold: true
    note: New minor"
  # zensical-bin fails fast once, so it goes to the second pass
  rm -f "$TEST_TMPDIR/strategies/pypi.sh"
  cat >"$TEST_TMPDIR/strategies/pypi.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == zensical-bin && ! -e "$TEST_TMPDIR/first-try" ]]; then
  touch "$TEST_TMPDIR/first-try"
  echo "upstream did not answer" >&2
  exit 1
fi
[[ "$1" == zensical-bin ]] && echo 0.1.3 || echo 0.0.43
EOF
  chmod +x "$TEST_TMPDIR/strategies/pypi.sh"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"python-zensical-ui waits for the second check of zensical-bin"* ]]
  [[ "$output" == *"Checking 2 failed package(s) again"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/zensical-bin")" = "held: 0.1.3" ]
  [ "$(cat "$TEST_TMPDIR/.status/python-zensical-ui")" = "held: 0.0.43" ]
}

@test "check-all --update: holds a package with pin_from whose project is held and updates neither" {
  create_zensical_pair
  rm -f "$TEST_TMPDIR/scripts/update-pkg.sh"
  printf '#!/usr/bin/env bash\necho "$*" >>"%s/update-pkg.sh.args"\n' "$TEST_TMPDIR" >"$TEST_TMPDIR/scripts/update-pkg.sh"
  chmod +x "$TEST_TMPDIR/scripts/update-pkg.sh"

  run "$TEST_TMPDIR/scripts/check-all.sh" --update
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/python-zensical-ui")" = "held: 0.0.43" ]
  [ ! -e "$TEST_TMPDIR/update-pkg.sh.args" ]
}

@test "check-all: a package with pin_from that a rule of its own holds keeps that hold alone" {
  create_zensical_pair "" "alerts:
  - from: '0.0.42'
    hold: true
    note: Own note"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/python-zensical-ui")" = "held: 0.0.43" ]
  [ "$(grep -c 'python-zensical-ui' "$TEST_TMPDIR/.status/_alerts")" -eq 1 ]
  grep -qxF $'python-zensical-ui\thold\tOwn note' "$TEST_TMPDIR/.status/_alerts"
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

# The write-back of current takes regular files alone, so a linked YAML would find the same
# version new in every run
@test "check-all: fails the check of a package YAML that is a link" {
  stand_in_strategy step 2.0
  create_test_package "pkg-link" "step" "current: 1.0"
  mv "$TEST_TMPDIR/packages/pkg-link.yml" "$TEST_TMPDIR/outside.yml"
  ln -s "$TEST_TMPDIR/outside.yml" "$TEST_TMPDIR/packages/pkg-link.yml"
  # The jobs hand builder such a YAML as a link to itself
  ln -s pkg-loop.yml "$TEST_TMPDIR/packages/pkg-loop.yml"
  # A record of the run keeps its name
  ln -s "$TEST_TMPDIR/outside.yml" "$TEST_TMPDIR/packages/_alerts.yml"
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-link")" = "check_failed: packages/pkg-link.yml is a link, and the runs read regular files alone" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-loop")" = "check_failed: packages/pkg-loop.yml is a link, and the runs read regular files alone" ]
  grep -qx pkg-link "$TEST_TMPDIR/.status/_packages"
  grep -qx pkg-loop "$TEST_TMPDIR/.status/_packages"
  [ ! -e "$TEST_TMPDIR/.status/_alerts" ]
}

@test "check-all: fails the check of a package whose alerts run past the check timeout" {
  stand_in_strategy step 29+1
  create_test_package "pkg-slow" "step" "current: 28+25
alerts:
  - match: '^29'
    note: New major"
  create_test_package "pkg-next" "step" "current: 28+25"
  # The test copy of scripts/ links the files of the repository, so the slow copy replaces the link
  rm -f "$TEST_TMPDIR/scripts/lib/alerts.sh"
  printf '%s\n' "$(cat "$PROJECT_DIR/scripts/lib/alerts.sh")" 'alert_fires() { sleep 15; }' >"$TEST_TMPDIR/scripts/lib/alerts.sh"
  AURTOMATOR_CHECK_TIMEOUT=3 run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-slow")" = "check_failed: alerts: timed out after 3 s" ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-next")" = "new_version: 29+1" ]
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

@test "check-all: --dry-run counts no update and keeps the version to push" {
  create_test_package "pkg-up" "github-release" "upstream:
  type: github
  project: owner/repo
current: '1.0.0'"
  rm -f "$TEST_TMPDIR/scripts/update-pkg.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_TMPDIR/scripts/update-pkg.sh"
  chmod +x "$TEST_TMPDIR/scripts/update-pkg.sh"

  run "$TEST_TMPDIR/scripts/check-all.sh" --update --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checked: 1, Updated: 0, Dry runs: 1, Errors: 0"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-up")" = "new_version: 2.0.0" ]
  run "$TEST_TMPDIR/scripts/check-all.sh" --update
  [[ "$output" == *"Checked: 1, Updated: 1, Errors: 0"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-up")" = "updated: 2.0.0" ]
}

# CI shows only the output of check-all.sh, where the warnings of a pushed update
# such as those of namcap would otherwise be lost
@test "check-all --update: prints the warnings of an update that succeeds" {
  create_test_package "pkg-up" "github-release" "upstream:
  type: github
  project: owner/repo
current: '1.0.0'"
  rm -f "$TEST_TMPDIR/scripts/update-pkg.sh"
  printf '#!/usr/bin/env bash\necho "! namcap warnings: pkg-up W: Missing Maintainer" >&2\n' >"$TEST_TMPDIR/scripts/update-pkg.sh"
  chmod +x "$TEST_TMPDIR/scripts/update-pkg.sh"

  run "$TEST_TMPDIR/scripts/check-all.sh" --update
  [ "$status" -eq 0 ]
  [[ "$output" == *"! namcap warnings: pkg-up W: Missing Maintainer"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-up")" = "updated: 2.0.0" ]
}

@test "check-all: prints the warnings of a check that succeeds" {
  create_test_package "pkg-up" "github-release" "upstream:
  type: github
  project: owner/repo
current: '2.0.0'"
  rm -f "$TEST_TMPDIR/scripts/check-update.sh"
  printf '#!/usr/bin/env bash\necho "! upstream lists no release notes" >&2\n' >"$TEST_TMPDIR/scripts/check-update.sh"
  chmod +x "$TEST_TMPDIR/scripts/check-update.sh"

  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"! upstream lists no release notes"* ]]
  [ "$(cat "$TEST_TMPDIR/.status/pkg-up")" = "up_to_date" ]
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
  # http_get names the URL before the error that curl gives
  [ "${lines[0]}" = "https://api.github.com/repos/asset-owner/asset-repo/releases/tags/v2.5.0-rc1: The requested URL returned error: 500" ]
  [[ "$output" == *"Failed to read the release of tag v2.5.0-rc1 of asset-owner/asset-repo"* ]]
}

@test "check-asset: fails when the commit of a tag without a release cannot be read" {
  liquidsoap_package
  MOCK_COMMIT_STATUS=500 run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc2
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to read the commit of tag v2.5.0-rc2 of asset-owner/asset-repo"* ]]
}

# commits/<ref> also takes a branch of the name of the tag, which can hold newer commits
@test "check-asset: dates a tag without a release by its git ref, through the object of an annotated tag" {
  liquidsoap_package
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  MOCK_TAG_AGE=30 run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc2
  [ "$status" -eq 1 ]
  [[ "$output" == *"tag v2.5.0-rc2 has no release"* ]]
  grep -q 'repos/asset-owner/asset-repo/git/ref/tags/v2.5.0-rc2$' "$CURL_ARGS_LOG"
  grep -q "repos/asset-owner/asset-repo/git/commits/$(printf 'c%.0s' {1..40})\$" "$CURL_ARGS_LOG"
  run grep -c -e '/commits/v2' -e '/git/tags/' "$CURL_ARGS_LOG"
  [ "$output" = 0 ]
  rm "$CURL_ARGS_LOG"
  MOCK_TAG_TYPE=tag MOCK_TAG_AGE=1 run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc2
  [ "$status" -eq 3 ]
  grep -q "repos/asset-owner/asset-repo/git/tags/$(printf 'c%.0s' {1..40})\$" "$CURL_ARGS_LOG"
}

# Annotated tags carry the time they were made, which can come long after their commit
@test "check-asset: dates an annotated tag without a release by its tagger" {
  liquidsoap_package
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  MOCK_TAG_TYPE=tag MOCK_TAG_AGE=48 MOCK_TAGGER_AGE=1 run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc2
  [ "$status" -eq 3 ]
  run grep -c '/git/commits/' "$CURL_ARGS_LOG"
  [ "$output" = 0 ]
  MOCK_TAG_TYPE=tag MOCK_TAG_AGE=1 MOCK_TAGGER_AGE=30 run "$TEST_TMPDIR/scripts/check-asset.sh" liq 2.5.0rc2
  [ "$status" -eq 1 ]
  [[ "$output" == *"tag v2.5.0-rc2 has no release"* ]]
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

# Co-maintainers write the AUR .SRCINFO, and its URLs reach the terminal in the messages
@test "check-arch: refuses a source URL of the AUR that holds a control character" {
  local esc
  esc=$(printf '\033')
  create_test_package jdk-temurin-ea-bin webpage-scrape "upstream:
  url: https://api.adoptium.net/v3/info/release_names
  pattern: 'jdk-([0-9]+)'
current: 28+22"
  arch_pkgbuild "$TEST_TMPDIR/PKGBUILD"
  arch_srcinfo "$TEST_TMPDIR/.SRCINFO"
  sed -i "/^\tsource_aarch64 = /s|\$|${esc}[2K${esc}[1;32mOK|" "$TEST_TMPDIR/.SRCINFO"
  make_aur_remote jdk-temurin-ea-bin "$TEST_TMPDIR/PKGBUILD" "$TEST_TMPDIR/.SRCINFO"
  mock_heads
  run "$TEST_TMPDIR/scripts/check-arch.sh" jdk-temurin-ea-bin 28+23
  [ "$status" -eq 1 ]
  [[ "$output" == *"jdk-temurin-ea-bin 28+23: the AUR .SRCINFO has a source_aarch64 URL with a control character: "* ]]
  [[ "$output" != *"$esc"* ]]
}

@test "check-arch: refuses an AUR pkgver that starts with +" {
  create_test_package jdk-temurin-ea-bin webpage-scrape "upstream:
  url: https://api.adoptium.net/v3/info/release_names
  pattern: 'jdk-([0-9]+)'
current: 28+22"
  arch_pkgbuild "$TEST_TMPDIR/PKGBUILD"
  arch_srcinfo "$TEST_TMPDIR/.SRCINFO"
  sed -i $'s/^\tpkgver = .*/\tpkgver = +1/' "$TEST_TMPDIR/.SRCINFO"
  make_aur_remote jdk-temurin-ea-bin "$TEST_TMPDIR/PKGBUILD" "$TEST_TMPDIR/.SRCINFO"
  mock_heads
  run timeout 20 "$TEST_TMPDIR/scripts/check-arch.sh" jdk-temurin-ea-bin 28+23
  [ "$status" -eq 1 ]
  [[ "$output" == *"The AUR .SRCINFO has pkgver = +1, which aurtomator does not take"* ]]
}

# Redirects to http or ftp would decide whether an arch counts as missing
@test "check-arch: asks for the archives over https alone, redirects included" {
  temurin_package "current: 28+22"
  cat >"$MOCK_DIR/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$TEST_TMPDIR/head-args.log"
printf '200 application/octet-stream'
EOF
  check_arch 28+23
  [ "$ARCH_RC" -eq 0 ]
  [ "$(grep -c . "$TEST_TMPDIR/head-args.log")" -eq "${#ARCH_ALL[@]}" ]
  [ "$(grep -c -v -e ' --proto =https --proto-redir =https ' "$TEST_TMPDIR/head-args.log")" -eq 0 ]
}

# The check job holds the read-only token, and its statuses decide what later jobs do
@test "check-arch: reads the arches of the AUR without running its PKGBUILD" {
  create_test_package jdk-temurin-ea-bin webpage-scrape "upstream:
  url: https://api.adoptium.net/v3/info/release_names
  pattern: 'jdk-([0-9]+)'
current: 28+22"
  arch_pkgbuild "$TEST_TMPDIR/PKGBUILD"
  add_canary "$TEST_TMPDIR/PKGBUILD"
  arch_srcinfo "$TEST_TMPDIR/.SRCINFO"
  make_aur_remote jdk-temurin-ea-bin "$TEST_TMPDIR/PKGBUILD" "$TEST_TMPDIR/.SRCINFO"
  mock_heads
  check_arch 28+23
  [ "$ARCH_RC" -eq 0 ]
  canary_untouched
}

# The functions of pkgbuild.sh source the PKGBUILD they get, and makepkg and updpkgsums run it,
# so no script but update-pkg.sh calls them; warn_epoch only logs
@test "scripts: no script but update-pkg.sh sources a PKGBUILD" {
  local scripts="$BATS_TEST_DIRNAME/../scripts" fns file count=0 cmd dot
  fns=$(grep -o -E '^[a-z_]+\(\)' "$scripts/lib/pkgbuild.sh" | tr -d '()' | grep -v -x warn_epoch | paste -sd '|' -)
  [[ "$fns" == *audit_pkgbuild* && "$fns" == *arch_answers* && "$fns" == *pkgbuild_checksums* ]]
  # Commands start a line or follow ; & | $( { ! or a keyword. The yq filter select(. == 1)
  # holds a dot after a bare parenthesis, and the case label source | source_*) a source
  cmd='(^|[;&|(]|\$\(|\{[[:space:]]|![[:space:]]|(^|[^[:alnum:]_])(if|then|else|elif|do|while|until)[[:space:]])[[:space:]]*'
  dot='(^|[;&|]|\$\(|[({][[:space:]]|![[:space:]]|(^|[^[:alnum:]_])(if|then|else|elif|do|while|until)[[:space:]])[[:space:]]*'
  for file in "$scripts"/*.sh "$scripts"/lib/*.sh; do
    [[ "$file" != */update-pkg.sh && "$file" != */lib/pkgbuild.sh ]] || continue
    echo "${file#"$scripts"/}"
    count=$((count + 1))
    run grep -n -w -E "$fns" "$file"
    [ "$status" -eq 1 ]
    run grep -n -E "${cmd}(makepkg|updpkgsums|eval)[[:space:]]|${cmd}source[[:space:]]+[^|[:space:]]|${dot}\\.[[:space:]]+[^[:space:]]|(ba)?sh[[:space:]]+-c" "$file"
    [ "$status" -le 1 ]
    run grep -v -E '^[0-9]+:[[:space:]]*source "(\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)|\$SCRIPT_DIR)/lib(/[a-z0-9]+)?\.sh"$|^[0-9]+:[[:space:]]*bounded "\$CHECK_TIMEOUT" bash -c .source "\$1/scripts/lib\.sh" && ' <<<"$output"
    [ -z "$output" ]
  done
  [ "$count" -gt 20 ]
}

# Lines of git would enter the error text of a failed check
@test "check-arch: clones the AUR repository with -q" {
  temurin_package "current: 28+22"
  check_arch 28+23
  [ "$ARCH_RC" -eq 0 ]
  [[ " $(cat "$TEST_TMPDIR/clone-opts") " == *" -q "* ]]
}

@test "check-arch: prints two empty lines when every arch answers" {
  temurin_package "current: 28+22"
  check_arch 28+23
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'|\n|' ]
  grep -qx 'https://aur.archlinux.org/jdk-temurin-ea-bin.git' "$TEST_TMPDIR/clone-urls"
  [ "$(sort "$TEST_TMPDIR/heads.log")" = "$(for arch in "${ARCH_ALL[@]}"; do arch_source_url "$arch" 28+23; done | sort)" ]
}

@test "check-arch: asks nothing with allow_missing_arch: false in any case or pkgver_dash: ''" {
  local line
  for line in "allow_missing_arch: false" "allow_missing_arch: False" "allow_missing_arch: FALSE" "pkgver_dash: ''"; do
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
  [ "$(wc -l <"$TEST_TMPDIR/arch.out")" -eq 3 ]
  about_now "$(sed -n 1p "$TEST_TMPDIR/arch.out")"
  # The arches it waits for and the AUR commit that builds them
  [ "$(sed -n 2p "$TEST_TMPDIR/arch.out")" = aarch64 ]
  [ "$(sed -n 3p "$TEST_TMPDIR/arch.out")" = "$(git -C "$AUR_REMOTE" rev-parse HEAD)" ]
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
  [ "$ARCH_OUT" = "$since|"$'\n'"aarch64|"$'\n'"$(git -C "$AUR_REMOTE" rev-parse HEAD)|" ]

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
  about_now "$(sed -n 1p "$TEST_TMPDIR/arch.out")"
}

@test "check-arch: arch_wait of another version starts a new wait" {
  temurin_package "current: 28+22
arch_wait:
  version: 28+21
  since: '$(date -u -d '-25 hours' +%Y-%m-%dT%H:%M:%SZ)'"
  archive_missing aarch64 28+23
  check_arch 28+23
  [ "$ARCH_RC" -eq 3 ]
  about_now "$(sed -n 1p "$TEST_TMPDIR/arch.out")"
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

@test "pkgbuild_assigns_source: takes assignments and leaves comments out" {
  local line
  source "$TEST_TMPDIR/scripts/lib.sh"
  for line in '#source_aarch64=("https://example.com/a.tar.gz")' 'x=1 # source_aarch64=(b)' '_note=source_aarch64=x'; do
    printf '%s\n' 'pkgname=demo' "$line" >"$TEST_TMPDIR/PKGBUILD"
    run pkgbuild_assigns_source "$TEST_TMPDIR/PKGBUILD" aarch64
    [ "$status" -eq 1 ] || {
      echo "taken: $line"
      return 1
    }
  done
  for line in 'source_aarch64=(a)' '  source_aarch64+=(b)' 'x=1; source_aarch64=(b)'; do
    printf '%s\n' 'pkgname=demo' "$line" >"$TEST_TMPDIR/PKGBUILD"
    run pkgbuild_assigns_source "$TEST_TMPDIR/PKGBUILD" aarch64
    [ "$status" -eq 0 ] || {
      echo "refused: $line"
      return 1
    }
  done
}

# Commented-out lines assign no source, so the arch is dropped as well
@test "check-arch: an arch of arch_out whose source line the AUR PKGBUILD comments out stays out" {
  local work="$TEST_TMPDIR/aur-work-jdk-temurin-ea-bin"
  temurin_package "current: 28+23"
  yq -i ".arch_out.aarch64 = \"$AUR_BASE\"" "$TEST_TMPDIR/packages/jdk-temurin-ea-bin.yml"
  aur_arch_commit 28+23 x86_64 powerpc64le riscv64 >/dev/null
  sed -i 's/^source_aarch64=/#&/' "$work/PKGBUILD"
  git -C "$work" -c user.name=aur -c user.email=aur@example.invalid -c commit.gpgsign=false commit -qam "comment out aarch64"
  git -C "$work" push -q "$AUR_REMOTE" master

  check_arch 28+24
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'aarch64|\n|' ]
  grep -q "the AUR PKGBUILD has no source_aarch64, so aarch64 stays out" "$TEST_TMPDIR/arch.err"
}

# Maintainers who drop an arch for good drop its source_<arch>, and the arch can never come back
@test "check-arch: an arch of arch_out without its source in the AUR PKGBUILD stays out unasked" {
  local work="$TEST_TMPDIR/aur-work-jdk-temurin-ea-bin"
  temurin_package "current: 28+23"
  yq -i ".arch_out.aarch64 = \"$AUR_BASE\"" "$TEST_TMPDIR/packages/jdk-temurin-ea-bin.yml"
  aur_arch_commit 28+23 x86_64 powerpc64le riscv64 >/dev/null
  sed -i '/^source_aarch64=/d' "$work/PKGBUILD"
  git -C "$work" -c user.name=aur -c user.email=aur@example.invalid -c commit.gpgsign=false commit -qam "drop aarch64"
  git -C "$work" push -q "$AUR_REMOTE" master

  check_arch 28+24
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'aarch64|\n|' ]
  run ! grep -q "$(arch_source_url aarch64 28+24)" "$TEST_TMPDIR/heads.log"
  grep -q "the AUR PKGBUILD has no source_aarch64, so aarch64 stays out" "$TEST_TMPDIR/arch.err"

  # Versions without x86_64 keep it out as well
  archive_missing x86_64 28+24
  check_arch 28+24
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'aarch64|\n|' ]

  # Assignments in a block of the PKGBUILD keep the arch, which comes back
  : >"$TEST_TMPDIR/missing"
  # shellcheck disable=SC2016
  printf '%s\n' 'if true; then' '  source_aarch64=("${_release}/OpenJDK-jdk_aarch64_${_file}")' 'fi' >>"$work/PKGBUILD"
  git -C "$work" -c user.name=aur -c user.email=aur@example.invalid -c commit.gpgsign=false commit -qam "aarch64 in a block"
  git -C "$work" push -q "$AUR_REMOTE" master
  check_arch 28+24
  [ "$ARCH_RC" -eq 0 ]
  [ "$ARCH_OUT" = $'|\n|' ]
}

@test "check-arch: a wait names each arch it waits for" {
  temurin_package "current: 28+22"
  archive_missing aarch64 28+23
  archive_missing riscv64 28+23
  check_arch 28+23
  [ "$ARCH_RC" -eq 3 ]
  [ "$(sed -n 2p "$TEST_TMPDIR/arch.out")" = "aarch64 riscv64" ]
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

# After 24 h of arch_wait, a 503 taken for a missing archive would publish the version without the arch
@test "check-arch: fails the check on an error status other than 404 or 410" {
  temurin_package "current: 28+22"
  archive_refused aarch64 28+23
  check_arch 28+23
  [ "$ARCH_RC" -eq 1 ]
  grep -qF "$(arch_source_url aarch64 28+23) answered with status 503" "$TEST_TMPDIR/arch.err"
  [[ "$(<"$TEST_TMPDIR/arch.err")" != *S3* ]]
}

# Bot protection and rate limits answer 403 too, so 403 fails the check like 503
@test "check-arch: fails the check on 403 and names S3 in the error" {
  temurin_package "current: 28+22"
  archive_forbidden aarch64 28+23
  check_arch 28+23
  [ "$ARCH_RC" -eq 1 ]
  grep -qF "$(arch_source_url aarch64 28+23) answered with status 403, which S3 also gives for missing files in buckets without public listing" "$TEST_TMPDIR/arch.err"
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

  # New asset values of the version the AUR has are rebuilds of every arch
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
echo https://silent.example/x >"$AURTOMATOR_HOSTS_DIR/failed"
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

@test "check-all: writes pending, the start of the wait, its arches and the AUR commit while an arch is missing" {
  local commit
  commit=$(printf 'c%.0s' {1..40})
  stand_in_strategy step 2.0.0
  create_test_package "pkg" "step" "current: '1.0.0'"
  stand_in_arch $'2026-11-11T10:00:00Z\naarch64 riscv64\n'"$commit"$'\n' 3
  run "$TEST_TMPDIR/scripts/check-all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/.status/pkg")" = "pending: 2.0.0" ]
  [ "$(cat "$TEST_TMPDIR/.status/_arches")" = $'pkg\t2.0.0\taarch64 riscv64\t2026-11-11T10:00:00Z\t'"$commit" ]
  [ "$(cat "$TEST_TMPDIR/check-arch.args")" = "pkg 2.0.0" ]
  [ "$(failed_statuses "$TEST_TMPDIR/.status")" = "0" ]
}

@test "check-all: a wait needs its arches and an AUR commit" {
  local out
  stand_in_strategy step 2.0.0
  create_test_package "pkg" "step" "current: '1.0.0'"
  local commit
  commit=$(printf 'c%.0s' {1..40})
  for out in $'2026-11-11T10:00:00Z\n' $'2026-11-11T10:00:00Z\naarch64\nmain\n' $'2026-11-11T10:00:00Z\nx86_64\n'"$commit"$'\n' \
    $'2026-11-11T10:00:00Z\n\n'"$commit"$'\n' $'2026-11-11T10:00:00Z\naarch64\n'"${commit}c"$'\n' \
    $'2026-11-11T10:00:00Z\nAArch64\n'"$commit"$'\n'; do
    stand_in_arch "$out" 3
    rm -rf "$TEST_TMPDIR/.status"
    run "$TEST_TMPDIR/scripts/check-all.sh"
    [ "$status" -eq 0 ]
    [[ "$(cat "$TEST_TMPDIR/.status/pkg")" == "check_failed: "*"check-arch.sh printed"* ]] || {
      echo "taken: ${out@Q}"
      return 1
    }
  done
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
echo https://silent.example/x >"$AURTOMATOR_HOSTS_DIR/failed"
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

@test "check-all: asks no arch check with allow_missing_arch: false in any case or pkgver_dash: ''" {
  local line version
  for line in "allow_missing_arch: false" "allow_missing_arch: False" "allow_missing_arch: FALSE" "pkgver_dash: ''"; do
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

# validate-pkg.sh refuses the same values, and a date after today would hold every push until then
@test "lib.sh: cooldown_until refuses a last_updated after today or not a date, also without a cooldown" {
  source "$TEST_TMPDIR/scripts/lib.sh"
  local days
  for days in 7 0; do
    create_test_package "pkg-git" "git-latest" "last_updated: '$(utc_day 1)'
cooldown_days: $days"
    run --separate-stderr cooldown_until "$TEST_TMPDIR/packages/pkg-git.yml"
    [ "$status" -eq 1 ]
    [ "$stderr" = "last_updated is later than today: $(utc_day 1)" ]
    create_test_package "pkg-git" "git-latest" "last_updated: 'not-a-date'
cooldown_days: $days"
    run --separate-stderr cooldown_until "$TEST_TMPDIR/packages/pkg-git.yml"
    [ "$status" -eq 1 ]
    [ "$stderr" = "last_updated must be a date YYYY-MM-DD: not-a-date" ]
  done
  create_test_package "pkg-git" "git-latest" "last_updated: '$(utc_day 0)'"
  run cooldown_until "$TEST_TMPDIR/packages/pkg-git.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "$(utc_day 7)" ]
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
