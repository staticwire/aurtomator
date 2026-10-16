#!/usr/bin/env bats

load helpers/setup.sh

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

# === github-release ===

@test "github-release: returns latest version" {
  create_test_package "test-gh-release" "github-release" "upstream:
  type: github
  project: owner/repo"

  run "$TEST_TMPDIR/strategies/github-release.sh" "test-gh-release"
  [ "$status" -eq 0 ]
  [ "$output" = "2.0.0" ]
}

@test "github-release: tag_version_regex strips prefix" {
  create_test_package "test-regex-prefix" "github-release" "upstream:
  project: custom-prefix/repo
  tag_version_regex: 'MeshLab-(.*)'"

  run "$TEST_TMPDIR/strategies/github-release.sh" "test-regex-prefix"
  [ "$status" -eq 0 ]
  [ "$output" = "2025.07" ]
}

@test "github-release: tag_version_regex strips suffix" {
  create_test_package "test-regex-suffix" "github-release" "upstream:
  project: custom-suffix/repo
  tag_version_regex: '(.+)-stable'"

  run "$TEST_TMPDIR/strategies/github-release.sh" "test-regex-suffix"
  [ "$status" -eq 0 ]
  [ "$output" = "0.1.8" ]
}

@test "github-release: tag_version_regex non-matching fails" {
  create_test_package "test-nomatch" "github-release" "upstream:
  project: custom-suffix/repo
  tag_version_regex: 'docker-v(.*)'"

  run "$TEST_TMPDIR/strategies/github-release.sh" "test-nomatch"
  [ "$status" -ne 0 ]
}

# === github-tag ===

@test "github-tag: returns latest tag sorted by semver" {
  create_test_package "test-gh-tag" "github-tag" "upstream:
  type: github
  project: owner/repo"

  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-gh-tag"
  [ "$status" -eq 0 ]
  [ "$output" = "2.0.0" ]
}

@test "github-tag: tag_version_regex extracts from prefixed tags" {
  create_test_package "test-tag-regex" "github-tag" "upstream:
  project: custom-prefix/repo
  tag_version_regex: 'bun-v(.*)'"

  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-tag-regex"
  [ "$status" -eq 0 ]
  [ "$output" = "1.3.11" ]
}

# === gitlab-tag ===

@test "gitlab-tag: returns latest tag from GitLab" {
  create_test_package "test-gl-tag" "gitlab-tag" "upstream:
  type: gitlab
  host: gitlab.com
  project: group/project"

  run "$TEST_TMPDIR/strategies/gitlab-tag.sh" "test-gl-tag"
  [ "$status" -eq 0 ]
  [ "$output" = "3.1.0" ]
}

# === gitea-tag ===

@test "gitea-tag: returns latest tag from Gitea/Codeberg" {
  create_test_package "test-gitea" "gitea-tag" "upstream:
  type: gitea
  host: codeberg.org
  project: owner/repo"

  run "$TEST_TMPDIR/strategies/gitea-tag.sh" "test-gitea"
  [ "$status" -eq 0 ]
  [ "$output" = "1.5.0" ]
}

# === pypi ===

@test "pypi: returns latest version from PyPI" {
  create_test_package "test-pypi" "pypi" "upstream:
  registry: requests"

  run "$TEST_TMPDIR/strategies/pypi.sh" "test-pypi"
  [ "$status" -eq 0 ]
  [ "$output" = "3.2.1" ]
}

# === npm ===

@test "npm: returns latest version from npm registry" {
  create_test_package "test-npm" "npm" "upstream:
  registry: express"

  run "$TEST_TMPDIR/strategies/npm.sh" "test-npm"
  [ "$status" -eq 0 ]
  [ "$output" = "4.0.0" ]
}

# === crates ===

@test "crates: returns latest stable version from crates.io" {
  create_test_package "test-crates" "crates" "upstream:
  registry: serde"

  run "$TEST_TMPDIR/strategies/crates.sh" "test-crates"
  [ "$status" -eq 0 ]
  [ "$output" = "1.0.204" ]
}

# === repology ===

@test "repology: returns newest version from Repology" {
  create_test_package "test-repology" "repology" "upstream:
  repology: testpkg"

  run "$TEST_TMPDIR/strategies/repology.sh" "test-repology"
  [ "$status" -eq 0 ]
  [ "$output" = "5.0.0" ]
}

# === archpkg ===

@test "archpkg: returns latest version from Arch repos" {
  create_test_package "test-archpkg" "archpkg" "upstream:
  archpkg: qt6-base"

  run "$TEST_TMPDIR/strategies/archpkg.sh" "test-archpkg"
  [ "$status" -eq 0 ]
  [ "$output" = "6.10.2" ]
}

# === kde-tarball ===

@test "kde-tarball: returns latest version from download.kde.org" {
  create_test_package "test-kde" "kde-tarball" "upstream:
  type: kde
  project: test-kde"

  run "$TEST_TMPDIR/strategies/kde-tarball.sh" "test-kde"
  [ "$status" -eq 0 ]
  [ "$output" = "1.0.1" ]
}

# === webpage-scrape ===

@test "webpage-scrape: returns version matched by pattern" {
  create_test_package "test-scrape" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'test-scrape-([0-9]+\\.[0-9]+\\.[0-9]+)\\.tar\\.gz'"

  run "$TEST_TMPDIR/strategies/webpage-scrape.sh" "test-scrape"
  [ "$status" -eq 0 ]
  [ "$output" = "7.0.0" ]
}

# === git-latest ===

@test "git-latest: returns rCOUNT.HASH format from git repo" {
  # Create a fake bare repo with some commits
  fake_repo="$TEST_TMPDIR/fake-upstream"
  mkdir -p "$fake_repo"
  git -C "$fake_repo" init -q
  git -C "$fake_repo" config user.email "test@test"
  git -C "$fake_repo" config user.name "test"
  for i in 1 2 3; do
    echo "$i" > "$fake_repo/file.txt"
    git -C "$fake_repo" add file.txt
    git -C "$fake_repo" commit -q -m "commit $i"
  done

  create_test_package "test-git" "git-latest" "upstream:
  type: git
  url: ${fake_repo}"

  run "$TEST_TMPDIR/strategies/git-latest.sh" "test-git"
  [ "$status" -eq 0 ]
  # Should match r3.<7-char-hash>
  [[ "$output" =~ ^r3\.[0-9a-f]{7}$ ]]
}

# === github-nightly ===

@test "github-nightly: pattern A, fixed tag, version from body" {
  create_test_package "test-nightly-a" "github-nightly" "upstream:
  project: owner/nightly-repo
  nightly_tag: nightly
  version_source: release_body
  version_pattern: 'NVIM v\\K\\S+'"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0.12.0"* ]]
}

@test "github-nightly: pattern B, dated tags" {
  create_test_package "test-nightly-b" "github-nightly" "upstream:
  project: owner/dated-repo
  nightly_tag: 'nightly-'
  version_source: tag_date"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-b"
  [ "$status" -eq 0 ]
  [ "$output" = "2026.03.26" ]
}

@test "github-nightly: pattern C, separate nightly repo" {
  create_test_package "test-nightly-c" "github-nightly" "upstream:
  project: owner/nightly-builds
  nightly_tag: latest
  version_source: tag"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-c"
  [ "$status" -eq 0 ]
  [ "$output" = "2.0.0" ]
}

@test "github-nightly: pattern D, channel filter" {
  create_test_package "test-nightly-d" "github-nightly" "upstream:
  project: owner/multi-channel
  channel: Nightly
  version_source: tag"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-d"
  [ "$status" -eq 0 ]
  [[ "$output" == "nightly-2026-03-26" ]]
}

@test "github-nightly: published_date version source" {
  create_test_package "test-nightly-date" "github-nightly" "upstream:
  project: owner/nightly-repo
  nightly_tag: nightly
  version_source: published_date"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-date"
  [ "$status" -eq 0 ]
  [ "$output" = "2026.03.27" ]
}

@test "github-nightly: tag_version_regex with version_source=tag" {
  create_test_package "test-nightly-regex" "github-nightly" "upstream:
  project: custom-nightly/repo
  nightly_tag: nightly
  version_source: tag
  tag_version_regex: 'nightly-v([0-9]+\\.[0-9]+\\.[0-9]+).*'"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-regex"
  [ "$status" -eq 0 ]
  [ "$output" = "3.5.0" ]
}

# === YAML regex fields ===

# A regex field closes the s command of sed and adds the e flag, which
# runs the pattern space as a command
@test "github-release: tag_version_regex runs no command" {
  create_test_package "test-regex-exec" "github-release" "upstream:
  project: custom-prefix/repo
  tag_version_regex: '.*|touch $TEST_TMPDIR/pwned|e;s|(x)|y|;#'"

  run "$TEST_TMPDIR/strategies/github-release.sh" "test-regex-exec"
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_TMPDIR/pwned" ]
}

@test "github-tag: tag_version_regex runs no command" {
  create_test_package "test-regex-exec" "github-tag" "upstream:
  project: custom-prefix/repo
  tag_version_regex: '.*|touch $TEST_TMPDIR/pwned|e;s|(x)|y|;#'"

  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-regex-exec"
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_TMPDIR/pwned" ]
}

@test "github-nightly: tag_version_regex runs no command" {
  create_test_package "test-regex-exec" "github-nightly" "upstream:
  project: custom-nightly/repo
  nightly_tag: nightly
  version_source: tag
  tag_version_regex: '.*|touch $TEST_TMPDIR/pwned|e;s|(x)|y|;#'"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-regex-exec"
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_TMPDIR/pwned" ]
}

@test "webpage-scrape: pattern runs no command" {
  create_test_package "test-scrape-exec" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'test-scrape-(7)|/touch pwned/e;s/(x)'"

  cd "$TEST_TMPDIR"
  run "$TEST_TMPDIR/strategies/webpage-scrape.sh" "test-scrape-exec"
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_TMPDIR/pwned" ]
}

@test "webpage-scrape: a pattern may start with a dash" {
  create_test_package "test-scrape-dash" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: '-([0-9]+\\.[0-9]+\\.[0-9]+)\\.tar\\.gz'"

  run "$TEST_TMPDIR/strategies/webpage-scrape.sh" "test-scrape-dash"
  [ "$status" -eq 0 ]
  [ "$output" = "7.0.0" ]
}

@test "github-nightly: a version_pattern may start with a dash" {
  create_test_package "test-nightly-dash" "github-nightly" "upstream:
  project: owner/nightly-repo
  nightly_tag: nightly
  version_source: release_body
  version_pattern: '-\\K[a-z]+'"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-dash"
  [ "$status" -eq 0 ]
  [ "$output" = "dev" ]
}

# === github-asset ===

@test "github-asset: single asset, version is its updated_at as YYYYMMDD" {
  create_test_package "test-asset-one" "github-asset" "upstream:
  project: owner/models-repo
  tag: models
  assets:
    - voice-a.tar.bz2"

  run "$TEST_TMPDIR/strategies/github-asset.sh" "test-asset-one"
  [ "$status" -eq 0 ]
  [ "$output" = "20251202" ]
}

@test "github-asset: several assets, newest updated_at wins" {
  create_test_package "test-asset-many" "github-asset" "upstream:
  project: owner/models-repo
  tag: models
  assets:
    - voice-a.tar.bz2
    - voice-c.tar.bz2
    - voice-b.tar.bz2"

  run "$TEST_TMPDIR/strategies/github-asset.sh" "test-asset-many"
  [ "$status" -eq 0 ]
  [ "$output" = "20260115" ]
}

@test "github-asset: fails when a listed asset is missing from the release" {
  create_test_package "test-asset-missing" "github-asset" "upstream:
  project: owner/models-repo
  tag: models
  assets:
    - voice-a.tar.bz2
    - voice-x.tar.bz2"

  run "$TEST_TMPDIR/strategies/github-asset.sh" "test-asset-missing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"voice-x.tar.bz2"* ]]
  [[ "$output" == *"not found"* ]]
}

@test "github-asset: fails when the release tag does not exist" {
  create_test_package "test-asset-404" "github-asset" "upstream:
  project: null-owner/null-repo
  tag: models
  assets:
    - voice-a.tar.bz2"

  run "$TEST_TMPDIR/strategies/github-asset.sh" "test-asset-404"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No release found"* ]]
}

@test "github-asset: fails without upstream.tag" {
  create_test_package "test-asset-notag" "github-asset" "upstream:
  project: owner/models-repo
  assets:
    - voice-a.tar.bz2"

  run "$TEST_TMPDIR/strategies/github-asset.sh" "test-asset-notag"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.tag"* ]]
}

@test "github-asset: fails without upstream.assets" {
  create_test_package "test-asset-noassets" "github-asset" "upstream:
  project: owner/models-repo
  tag: models"

  run "$TEST_TMPDIR/strategies/github-asset.sh" "test-asset-noassets"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.assets"* ]]
}

@test "github-asset: fails on malformed updated_at" {
  create_test_package "test-asset-baddate" "github-asset" "upstream:
  project: owner/models-repo
  tag: models
  assets:
    - voice-a.tar.bz2
    - voice-d.tar.bz2"

  run "$TEST_TMPDIR/strategies/github-asset.sh" "test-asset-baddate"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unexpected updated_at"* ]]
  [[ "$output" == *"voice-d.tar.bz2"* ]]
}

# === GITHUB_TOKEN ===

# Helper: one package for each GitHub strategy, and a curl that appends its
# arguments to curl.args and its stdin to curl.stdin before it answers
setup_github_strategies() {
  create_test_package "gh-release" "github-release" "upstream:
  project: owner/repo"
  create_test_package "gh-tag" "github-tag" "upstream:
  project: owner/repo"
  create_test_package "gh-asset" "github-asset" "upstream:
  project: owner/models-repo
  tag: models
  assets:
    - voice-a.tar.bz2"
  create_test_package "gh-nightly" "github-nightly" "upstream:
  project: owner/nightly-repo
  nightly_tag: nightly
  version_source: release_body
  version_pattern: 'NVIM v\\K\\S+'"

  mv "$MOCK_DIR/curl" "$MOCK_DIR/curl-answer"
  cat >"$MOCK_DIR/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$TEST_TMPDIR/curl.args"
cat >>"$TEST_TMPDIR/curl.stdin"
exec "$MOCK_DIR/curl-answer" "\$@"
EOF
  chmod +x "$MOCK_DIR/curl"
}

# Helper: run every GitHub strategy. Stdin is /dev/null, so the recording
# curl does not wait when a strategy gives it nothing to read.
run_github_strategies() {
  local strategy
  for strategy in release tag asset nightly; do
    run "$TEST_TMPDIR/strategies/github-${strategy}.sh" "gh-${strategy}" </dev/null
    [ "$status" -eq 0 ]
  done
}

@test "github strategies: send GITHUB_TOKEN on stdin, never as an argument" {
  setup_github_strategies
  export GITHUB_TOKEN=standin-token
  run_github_strategies
  calls=$(wc -l <"$TEST_TMPDIR/curl.args")
  [ "$(grep -c -- '-H @-' "$TEST_TMPDIR/curl.args")" -eq "$calls" ]
  [ "$(grep -cx 'Authorization: Bearer standin-token' "$TEST_TMPDIR/curl.stdin")" -eq "$calls" ]
  ! grep -q standin-token "$TEST_TMPDIR/curl.args"
}

@test "github strategies: send no Authorization header without GITHUB_TOKEN" {
  setup_github_strategies
  unset GITHUB_TOKEN
  run_github_strategies
  ! grep -q -- '-H' "$TEST_TMPDIR/curl.args"
}

# === Error handling: unknown package ===

@test "strategy fails gracefully on unknown package" {
  run "$TEST_TMPDIR/strategies/github-release.sh" "nonexistent-package"
  [ "$status" -ne 0 ]
}

# === Error handling: null/empty API responses ===

@test "github-release: fails on null tag_name (404 response)" {
  create_test_package "test-null" "github-release" "upstream:
  project: null-owner/null-repo"

  run "$TEST_TMPDIR/strategies/github-release.sh" "test-null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No releases found"* ]]
}

@test "github-tag: fails on empty tags array" {
  create_test_package "test-empty" "github-tag" "upstream:
  project: empty-owner/empty-repo"

  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-empty"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No tags found"* ]]
}

@test "gitlab-tag: fails on empty tags array" {
  create_test_package "test-empty" "gitlab-tag" "upstream:
  host: gitlab.com
  project: empty-group/empty-project"

  run "$TEST_TMPDIR/strategies/gitlab-tag.sh" "test-empty"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No tags found"* ]]
}

@test "gitea-tag: fails on empty tags array" {
  create_test_package "test-empty" "gitea-tag" "upstream:
  host: codeberg.org
  project: empty-owner/empty-repo"

  run "$TEST_TMPDIR/strategies/gitea-tag.sh" "test-empty"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No tags found"* ]]
}

@test "pypi: fails on null version" {
  create_test_package "test-null" "pypi" "upstream:
  registry: null-package"

  run "$TEST_TMPDIR/strategies/pypi.sh" "test-null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No version found"* ]]
}

@test "npm: fails on null version" {
  create_test_package "test-null" "npm" "upstream:
  registry: null-package"

  run "$TEST_TMPDIR/strategies/npm.sh" "test-null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No version found"* ]]
}

@test "crates: fails on null version" {
  create_test_package "test-null" "crates" "upstream:
  registry: null-crate"

  run "$TEST_TMPDIR/strategies/crates.sh" "test-null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No version found"* ]]
}

@test "repology: fails when no newest status" {
  create_test_package "test-nonew" "repology" "upstream:
  repology: no-newest"

  run "$TEST_TMPDIR/strategies/repology.sh" "test-nonew"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No version found"* ]]
}

@test "archpkg: fails on empty results" {
  create_test_package "test-empty" "archpkg" "upstream:
  archpkg: no-such-pkg"

  run "$TEST_TMPDIR/strategies/archpkg.sh" "test-empty"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "kde-tarball: fails when no versions in listing" {
  create_test_package "no-versions-here" "kde-tarball" ""

  run "$TEST_TMPDIR/strategies/kde-tarball.sh" "no-versions-here"
  [ "$status" -ne 0 ]
}

@test "webpage-scrape: fails on missing url" {
  create_test_package "test-nourl" "webpage-scrape" "upstream:
  pattern: 'pkg-([0-9.]+)'"

  run "$TEST_TMPDIR/strategies/webpage-scrape.sh" "test-nourl"
  [ "$status" -ne 0 ]
}

@test "webpage-scrape: fails on missing pattern" {
  create_test_package "test-nopat" "webpage-scrape" "upstream:
  url: https://example.com/releases"

  run "$TEST_TMPDIR/strategies/webpage-scrape.sh" "test-nopat"
  [ "$status" -ne 0 ]
}

@test "webpage-scrape: fails on non-HTTPS url" {
  create_test_package "test-http" "webpage-scrape" "upstream:
  url: http://example.com/insecure
  pattern: 'pkg-([0-9.]+)'"

  run "$TEST_TMPDIR/strategies/webpage-scrape.sh" "test-http"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Only HTTPS"* ]]
}

@test "webpage-scrape: fails when pattern matches nothing" {
  create_test_package "test-nomatch" "webpage-scrape" "upstream:
  url: https://example.com/empty-page
  pattern: 'nonexistent-([0-9.]+)\\.tar\\.gz'"

  run "$TEST_TMPDIR/strategies/webpage-scrape.sh" "test-nomatch"
  [ "$status" -ne 0 ]
}

@test "git-latest: fails on unknown upstream type" {
  create_test_package "test-badtype" "git-latest" "upstream:
  type: bitbucket
  project: owner/repo"

  run "$TEST_TMPDIR/strategies/git-latest.sh" "test-badtype"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown upstream type"* ]]
}

@test "git-latest: fails when clone fails" {
  create_test_package "test-badurl" "git-latest" "upstream:
  type: git
  url: /nonexistent/repo/path"

  run "$TEST_TMPDIR/strategies/git-latest.sh" "test-badurl"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to clone"* ]]
}

@test "git-latest: clone failure keeps the git error message" {
  create_test_package "test-throttled" "git-latest" "upstream:
  type: gitlab
  host: gitlab.example.com
  project: group/project"

  cat >"$MOCK_DIR/git" <<'EOF'
#!/usr/bin/env bash
echo "fatal: unable to access 'https://gitlab.example.com/group/project.git/': The requested URL returned error: 429" >&2
exit 128
EOF
  chmod +x "$MOCK_DIR/git"

  run "$TEST_TMPDIR/strategies/git-latest.sh" "test-throttled"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to clone"* ]]
  [[ "$output" == *"The requested URL returned error: 429"* ]]
}

# === Error handling: curl network failure ===

@test "github-release: fails on curl network error" {
  create_test_package "test-neterr" "github-release" "upstream:
  project: owner/repo"

  # Override mock curl to simulate network failure
  cat >"$TEST_TMPDIR/mock-bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl: (7) Failed to connect" >&2
exit 7
EOF
  chmod +x "$TEST_TMPDIR/mock-bin/curl"

  run "$TEST_TMPDIR/strategies/github-release.sh" "test-neterr"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to fetch"* ]]
}

@test "github-asset: fails on curl network error" {
  create_test_package "test-asset-neterr" "github-asset" "upstream:
  project: owner/models-repo
  tag: models
  assets:
    - voice-a.tar.bz2"

  cat >"$TEST_TMPDIR/mock-bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl: (7) Failed to connect" >&2
exit 7
EOF
  chmod +x "$TEST_TMPDIR/mock-bin/curl"

  run "$TEST_TMPDIR/strategies/github-asset.sh" "test-asset-neterr"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to fetch release tag 'models'"* ]]
}

@test "github-tag: tag_pattern filters out all tags" {
  create_test_package "test-filter" "github-tag" "upstream:
  project: owner/repo
  tag_pattern: 'release-*'"

  # The mock returns v2.0.0, v1.9.0 and v1.0.0, and none matches ^release-.*
  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-filter"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No matching tags"* ]]
}

@test "gitlab-tag: tag_pattern filters out all tags" {
  create_test_package "test-filter" "gitlab-tag" "upstream:
  host: gitlab.com
  project: group/project
  tag_pattern: 'release-*'"

  run "$TEST_TMPDIR/strategies/gitlab-tag.sh" "test-filter"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No matching tags"* ]]
}

@test "gitea-tag: tag_pattern filters out all tags" {
  create_test_package "test-filter" "gitea-tag" "upstream:
  host: codeberg.org
  project: owner/repo
  tag_pattern: 'release-*'"

  run "$TEST_TMPDIR/strategies/gitea-tag.sh" "test-filter"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No matching tags"* ]]
}
