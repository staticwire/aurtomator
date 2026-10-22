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

@test "validate: github-tag with pattern passes" {
  create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
  tag_pattern: 'v*'"
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

@test "validate: kde-tarball fails with an upstream block" {
  create_test_package "mypkg" "kde-tarball" "upstream:
  project: other-name"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"strategy 'kde-tarball' takes no upstream settings"* ]]
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
  tag_pattern: 'v*'"
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

@test "validate: tag_pattern valid glob accepted" {
  create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
  tag_pattern: 'v*'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: tag_pattern invalid regex rejected" {
  create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
  tag_pattern: '[invalid'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid as regex"* ]]
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
