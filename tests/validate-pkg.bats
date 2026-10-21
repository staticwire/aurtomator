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

@test "validate: tag_version_regex invalid regex rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: '([invalid)'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid ERE regex"* ]]
}

# The field closes the s command of sed and adds the e flag, which runs the
# pattern space as a command
@test "validate: tag_version_regex runs no command" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: '.*|touch $TEST_TMPDIR/pwned|e;s|(x)|y|;#'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
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
