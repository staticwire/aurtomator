#!/usr/bin/env bats

load helpers/setup.sh

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

# === Valid configs (should all pass) ===

@test "validate: github-release minimal config passes" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: github-tag with tag_version_regex passes" {
  create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
  tag_version_regex: '^v(1\\.[0-9.]+)$'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: gitlab-tag passes" {
  create_test_package "mypkg" "gitlab-tag" "upstream:
  host: gitlab.com
  project: group/project"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: gitea-tag passes" {
  create_test_package "mypkg" "gitea-tag" "upstream:
  host: codeberg.org
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: git-latest github type passes" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: git-latest gitlab type passes" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: gitlab
  host: invent.kde.org
  project: group/project"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: git-latest git type passes" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: git
  url: https://git.example.com/repo.git"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: git-latest passes with a current of the form r<count>.<hash>" {
  local current
  for current in r504.42cd4ac r2173.ef2e985d; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
current: '$current'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ]
  done
}

# vercmp reads 1.4.0.r47.g0bbf5ad, 1.2.3 and 0 as newer than every
# r<count>.<hash>, and r1234.g42cd4ac as older than r1234.42cd4ac of the
# same commit
@test "validate: git-latest fails on a current of another form" {
  local current
  for current in 1.4.0.r47.g0bbf5ad 1.2.3 r1234.g42cd4ac 0; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
current: '$current'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"current must be r<count>.<hash> for git-latest, the form the strategy prints: $current"* ]]
  done
}

@test "validate: git-latest branch passes" {
  local branch
  for branch in feature/x release-0.11; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
  branch: '$branch'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ]
  done
}

# git clone would read -x as an option
@test "validate: git-latest branch git refuses rejected" {
  local branch
  for branch in -x 'a b' a..b HEAD; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
  branch: '$branch'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream.branch is not a valid branch name: $branch"* ]]
  done
}

@test "validate: git-latest describe passes" {
  local describe
  for describe in tags annotated; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
  describe: $describe
  tag_prefix: release/
current: '1.2.0.rc1.r47.g0bbf5ad'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ]
  done
}

@test "validate: git-latest describe of another value rejected" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
  describe: 'yes'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.describe must be tags or annotated: yes"* ]]
}

@test "validate: describe for another strategy rejected" {
  create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
  describe: tags"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.describe applies to the git-latest strategy only"* ]]
}

@test "validate: git-latest tag_prefix without describe rejected" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
  tag_prefix: v"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.tag_prefix applies with upstream.describe only"* ]]
}

@test "validate: git-latest tag_prefix outside the characters of a tag rejected" {
  local prefix
  for prefix in 'a b' 'v*' ''; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
  describe: tags
  tag_prefix: '$prefix'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream.tag_prefix may hold A-Za-z0-9._+/- only: $prefix"* ]]
  done
}

# vercmp reads r504.42cd4ac as older than every 1.2.0.r47.g0bbf5ad
@test "validate: git-latest describe fails on a current of another form" {
  local current
  for current in r504.42cd4ac 1.2.0 1.2.0.r47.0bbf5ad; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
  describe: tags
current: '$current'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"current must be <tag>.r<count>.g<hash> for git-latest with upstream.describe, the form the strategy prints: $current"* ]]
  done
}

@test "validate: branch for another strategy rejected" {
  create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
  branch: main"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.branch applies to the git-latest strategy only"* ]]
}

@test "validate: git-latest git type fails on a URL without HTTPS" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: git
  url: file:///srv/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.url must use HTTPS: file:///srv/repo"* ]]
}

@test "validate: git-latest git type fails on an HTTP URL" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: git
  url: http://git.example.com/repo.git"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.url must use HTTPS: http://git.example.com/repo.git"* ]]
}

@test "validate: pypi passes" {
  create_test_package "mypkg" "pypi" "upstream:
  registry: requests"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: npm passes" {
  create_test_package "mypkg" "npm" "upstream:
  registry: express"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: crates passes" {
  create_test_package "mypkg" "crates" "upstream:
  registry: serde"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: archpkg passes (no extra fields)" {
  create_test_package "mypkg" "archpkg" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: repology passes (no extra fields)" {
  create_test_package "mypkg" "repology" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: kde-tarball passes (no extra fields)" {
  create_test_package "mypkg" "kde-tarball" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: kde-tarball project and path pass" {
  create_test_package "mypkg" "kde-tarball" "upstream:
  project: alkimia
  path: unstable/alkimia"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: kde-tarball project outside the characters of a name rejected" {
  local project
  for project in 'a/b' 'a b' '-a' "a'b"; do
    create_test_package "mypkg" "kde-tarball" "upstream:
  project: \"$project\""
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream.project must be a tarball name of A-Za-z0-9@._+-: $project"* ]]
  done
}

# The path ends up in https://download.kde.org/<path>/
@test "validate: kde-tarball path that is not a directory on the server rejected" {
  local path
  for path in ../etc stable/../x /stable/x stable//x 'stable/x?y' stable/x/ 'stable/a b'; do
    create_test_package "mypkg" "kde-tarball" "upstream:
  path: '$path'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream.path must be a directory on download.kde.org, such as unstable/alkimia: $path"* ]]
  done
}

@test "validate: webpage-scrape passes" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'pkg-([0-9.]+)\\.tar\\.gz'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: github-asset passes" {
  create_test_package "mypkg" "github-asset" "upstream:
  project: owner/repo
  tag: models
  assets:
    - voice-a.tar.bz2"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

# === Missing core fields ===

@test "validate: fails on missing name" {
  cat >"$TEST_TMPDIR/packages/bad.yml" <<'EOF'
strategy: github-release
upstream:
  project: owner/repo
EOF
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required field 'name'"* ]]
}

@test "validate: fails on missing strategy" {
  cat >"$TEST_TMPDIR/packages/bad.yml" <<'EOF'
name: bad
upstream:
  project: owner/repo
EOF
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required field 'strategy'"* ]]
}

@test "validate: fails on unknown strategy" {
  create_test_package "mypkg" "nonexistent-strat" "upstream:
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown strategy"* ]]
}

@test "validate: accepts a strategy that has a script in strategies/" {
  printf '#!/usr/bin/env bash\necho 1.0.0\n' >"$TEST_TMPDIR/strategies/forgejo-release.sh"
  chmod +x "$TEST_TMPDIR/strategies/forgejo-release.sh"
  create_test_package "mypkg" "forgejo-release" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: fails on a strategy path outside strategies/" {
  create_test_package "mypkg" "../scripts/check-all" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown strategy '../scripts/check-all'"* ]]
}

# === Strategy-specific field errors ===

@test "validate: github-release fails without upstream.project" {
  create_test_package "mypkg" "github-release" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.project'"* ]]
}

@test "validate: github-tag fails without upstream.project" {
  create_test_package "mypkg" "github-tag" "upstream:
  tag_version_regex: '^v(.+)$'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.project'"* ]]
}

@test "validate: github-asset fails without upstream.project" {
  create_test_package "mypkg" "github-asset" "upstream:
  tag: models
  assets:
    - voice-a.tar.bz2"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.project'"* ]]
}

@test "validate: github-asset fails without upstream.tag" {
  create_test_package "mypkg" "github-asset" "upstream:
  project: owner/repo
  assets:
    - voice-a.tar.bz2"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.tag'"* ]]
}

@test "validate: github-asset fails without upstream.assets" {
  create_test_package "mypkg" "github-asset" "upstream:
  project: owner/repo
  tag: models"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.assets'"* ]]
}

@test "validate: github-asset fails when upstream.assets is not a list" {
  create_test_package "mypkg" "github-asset" "upstream:
  project: owner/repo
  tag: models
  assets: voice-a.tar.bz2"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.assets'"* ]]
}

@test "validate: github-asset fails when upstream.assets is empty" {
  create_test_package "mypkg" "github-asset" "upstream:
  project: owner/repo
  tag: models
  assets: []"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.assets'"* ]]
}

@test "validate: gitlab-tag fails without upstream.host" {
  create_test_package "mypkg" "gitlab-tag" "upstream:
  project: group/project"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.host'"* ]]
}

@test "validate: gitlab-tag fails without upstream.project" {
  create_test_package "mypkg" "gitlab-tag" "upstream:
  host: gitlab.com"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.project'"* ]]
}

@test "validate: gitea-tag fails without upstream.host" {
  create_test_package "mypkg" "gitea-tag" "upstream:
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.host'"* ]]
}

@test "validate: git-tag passes" {
  create_test_package "mypkg" "git-tag" "upstream:
  url: https://git.example.org/~owner/repo
  tag_version_regex: '^release-(.+)$'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: git-tag fails without upstream.url" {
  create_test_package "mypkg" "git-tag" "upstream:
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"strategy 'git-tag' requires 'upstream.url'"* ]]
}

@test "validate: git-tag fails with a URL other than HTTPS" {
  create_test_package "mypkg" "git-tag" "upstream:
  url: http://git.example.org/~owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.url must use HTTPS: http://git.example.org/~owner/repo"* ]]
}

@test "validate: git-latest fails without upstream.type" {
  create_test_package "mypkg" "git-latest" "upstream:
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.type'"* ]]
}

@test "validate: git-latest github fails without project" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: github"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.project'"* ]]
}

@test "validate: git-latest gitlab fails without host" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: gitlab
  project: group/project"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.host'"* ]]
}

@test "validate: git-latest git fails without url" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: git"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.url'"* ]]
}

@test "validate: git-latest fails on unknown type" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: bitbucket
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown type 'bitbucket'"* ]]
}

@test "validate: pypi fails without upstream.registry" {
  create_test_package "mypkg" "pypi" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.registry'"* ]]
}

@test "validate: npm fails without upstream.registry" {
  create_test_package "mypkg" "npm" "upstream:
  foo: bar"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.registry'"* ]]
}

@test "validate: crates fails without upstream.registry" {
  create_test_package "mypkg" "crates" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.registry'"* ]]
}

@test "validate: webpage-scrape passes with upstream.user_agent" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'pkg-([0-9.]+)\\.tar\\.gz'
  user_agent: 'Example/2.0 (+https://example.com/bot)'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

# curl would send the text after a line break as a header of its own
@test "validate: webpage-scrape fails on a user_agent with a control character" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'pkg-([0-9.]+)\\.tar\\.gz'
  user_agent: \"Example/2.0\\r\\nX-Extra: 1\""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.user_agent must hold printable ASCII only: \$'Example/2.0\\r\\nX-Extra: 1'"* ]]
}

@test "validate: webpage-scrape fails on a user_agent outside ASCII" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'pkg-([0-9.]+)\\.tar\\.gz'
  user_agent: 'Exämple/2.0'"
  run env LC_ALL=C.UTF-8 "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.user_agent must hold printable ASCII only"* ]]
}

@test "validate: webpage-scrape fails without upstream.url" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  pattern: 'pkg-([0-9.]+)'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.url'"* ]]
}

@test "validate: webpage-scrape fails without upstream.pattern" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.pattern'"* ]]
}

@test "validate: webpage-scrape fails on non-HTTPS url" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: http://example.com
  pattern: 'pkg-([0-9.]+)'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must use HTTPS"* ]]
}

# === --all mode ===

@test "validate --all: passes with all valid packages" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo"
  create_test_package "pkg-b" "pypi" "upstream:
  registry: requests"

  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 2 packages valid"* ]]
}

@test "validate --all: fails when any package invalid" {
  create_test_package "good" "github-release" "upstream:
  project: owner/repo"
  create_test_package "bad" "nonexistent-strat" ""

  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -ne 0 ]
  [[ "$output" == *"Validation failed"* ]]
}

@test "validate --all: handles empty packages dir" {
  rm -f "$TEST_TMPDIR/packages/"*.yml
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"No packages found"* ]]
}

@test "validate: fails on nonexistent package" {
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "nonexistent"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Package not found: "*"/packages/nonexistent.yml"* ]]
}

# === Regex validation ===

@test "validate: webpage-scrape accepts valid regex pattern" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'pkg-([0-9]+\\.[0-9]+)\\.tar\\.gz'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: webpage-scrape accepts a pattern that starts with a dash" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: '-([0-9]+\\.[0-9]+)\\.tar\\.gz'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

# grep -E takes these and bash refuses them
@test "validate: webpage-scrape rejects a pattern that bash cannot compile" {
  local pattern
  for pattern in '(?:v)?pkg-([0-9.]+)' '*pkg-([0-9.]+)' 'pkg-([0-9]{1)'; do
    create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: '$pattern'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not valid ERE regex"* ]]
  done
}

@test "validate: webpage-scrape accepts a pattern with a slash" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'download/pkg-([0-9.]+)\\.tar\\.gz'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: webpage-scrape rejects invalid regex pattern" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'pkg-([0-9+'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid ERE regex"* ]]
}

@test "validate: allow_downgrade true passes" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
allow_downgrade: true"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: allow_downgrade that is not a boolean rejected" {
  local value
  for value in yes '"true"' 1; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
allow_downgrade: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"allow_downgrade must be true or false"* ]]
  done
}

@test "validate: allow_version_jump true passes" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
allow_version_jump: true"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: allow_version_jump that is not a boolean rejected" {
  local value
  for value in yes '"true"' 1; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
allow_version_jump: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"allow_version_jump must be true or false"* ]]
  done
}

@test "validate: pkgver_dash _ or . passes" {
  local value
  for value in _ .; do
    create_test_package "mypkg" "npm" "upstream:
  registry: cli-pride-flags
pkgver_dash: '$value'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ]
  done
}

@test "validate: pkgver_dash other than _ or . rejected" {
  local value
  for value in "'+'" "'-'" "'__'" "''" 1; do
    create_test_package "mypkg" "npm" "upstream:
  registry: cli-pride-flags
pkgver_dash: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pkgver_dash must be _ or ."* ]]
  done
}

@test "validate: pkgver_format with %s once passes" {
  create_test_package "mypkg" "repology" "current: '4.4215'
pkgver_format: '4.%s'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: pkgver_format without %s once or with other characters rejected" {
  local value
  for value in "'4.'" "'%s.%s'" "'4-%s'" "'4 %s'" "'4:%s'" "''" 4; do
    create_test_package "mypkg" "repology" "pkgver_format: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pkgver_format must hold %s once, with only A-Za-z0-9 . _ + around it"* ]]
  done
}

@test "validate: current outside pkgver_format rejected" {
  create_test_package "mypkg" "repology" "current: '3.4215'
pkgver_format: '4.%s'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"current 3.4215 does not fit pkgver_format 4.%s"* ]]
}

# === crates prerelease validation ===

@test "validate: crates prerelease with pkgver_dash passes" {
  create_test_package "mypkg" "crates" "upstream:
  registry: pijul
  prerelease: true
pkgver_dash: ."
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

# A semver pre-release always holds a dash
@test "validate: crates prerelease without pkgver_dash rejected" {
  create_test_package "mypkg" "crates" "upstream:
  registry: pijul
  prerelease: true"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.prerelease needs pkgver_dash"* ]]
}

@test "validate: crates prerelease false without pkgver_dash passes" {
  create_test_package "mypkg" "crates" "upstream:
  registry: serde
  prerelease: false"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: prerelease for another strategy rejected" {
  create_test_package "mypkg" "npm" "upstream:
  registry: cli-pride-flags
  prerelease: true
pkgver_dash: _"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.prerelease applies to the crates strategy only"* ]]
}

@test "validate: prerelease that is not a boolean rejected" {
  local value
  for value in yes '"true"' 1; do
    create_test_package "mypkg" "crates" "upstream:
  registry: pijul
  prerelease: $value
pkgver_dash: _"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"upstream.prerelease must be true or false"* ]]
  done
}

# === tag_version_regex validation ===

@test "validate: tag_version_regex valid with capture group passes" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: 'MeshLab-(.*)'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

# | ends the pattern of a sed s command
@test "validate: tag_version_regex may hold |" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: '^v?([0-9.]+)(-stable|)$'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: tag_version_regex invalid regex rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: '([invalid)'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid ERE regex"* ]]
}

# In a sed s command the field would close the pattern and add the e flag,
# which runs the pattern space as a command. bash reads it as an ERE.
@test "validate: tag_version_regex runs no command" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: '.*|touch $TEST_TMPDIR/pwned|e;s|(x)|y|;#'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/pwned" ]
}

@test "validate: tag_version_regex without capture group rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: 'MeshLab-.*'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"capture group"* ]]
}

# === tag_version_replace validation ===

@test "validate: tag_version_replace with the groups of the regex passes" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: '^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
  tag_version_replace: '\\1.\\2.\\3'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: tag_version_replace without tag_version_regex rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_replace: '\\1'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.tag_version_replace needs upstream.tag_version_regex"* ]]
}

@test "validate: tag_version_replace with a character a version lacks rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: '^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
  tag_version_replace: '\\1-\\2'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *'upstream.tag_version_replace may hold only A-Za-z0-9 . _ + and \1 to \9'* ]]
}

@test "validate: tag_version_replace naming a group the regex lacks rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: '^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
  tag_version_replace: '\\1.\\4'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.tag_version_replace names a group tag_version_regex does not have"* ]]
}

# === nightly_tag_regex validation ===

@test "validate: nightly_tag_regex passes" {
  create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  nightly_tag_regex: '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  version_source: tag_date"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: nightly_tag_regex for another strategy rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  nightly_tag_regex: '^nightly-'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.nightly_tag_regex applies to the github-nightly strategy only"* ]]
}

@test "validate: nightly_tag_regex next to nightly_tag or channel rejected" {
  local field
  for field in 'nightly_tag: nightly-' 'channel: Nightly'; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  nightly_tag_regex: '^nightly-'
  $field"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream.nightly_tag_regex takes the place of nightly_tag and channel"* ]]
  done
}

@test "validate: nightly_tag_regex invalid regex rejected" {
  create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  nightly_tag_regex: '([0-9]'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.nightly_tag_regex is not valid ERE regex: ([0-9]"* ]]
}

# === date_format validation ===

@test "validate: date_format with a date version_source passes" {
  local source
  for source in tag_date published_date; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  version_source: $source
  date_format: '%Y%m%d'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ]
  done
}

# Without version_source the strategy reads the tag
@test "validate: date_format with another version_source rejected" {
  local source
  for source in 'version_source: tag' 'version_source: release_body' ''; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  $source
  version_pattern: 'v\\K\\S+'
  date_format: '%Y%m%d'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"upstream.date_format applies to version_source tag_date and published_date only"* ]]
  done
}

@test "validate: date_format that gives no valid version rejected" {
  create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  version_source: tag_date
  date_format: '%Y-%m-%d'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.date_format must give a valid version, it gives '2026-01-02'"* ]]
}
