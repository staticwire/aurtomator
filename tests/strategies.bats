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

# === github-tag ===

@test "github-tag: returns latest tag sorted by semver" {
  create_test_package "test-gh-tag" "github-tag" "upstream:
  type: github
  project: owner/repo"

  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-gh-tag"
  [ "$status" -eq 0 ]
  [ "$output" = "2.0.0" ]
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

# === Error handling: curl network failure ===

@test "github-release: fails on curl network error" {
  # Use a host that mock-curl doesn't recognize → exit 1
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

@test "github-tag: tag_pattern filters out all tags" {
  create_test_package "test-filter" "github-tag" "upstream:
  project: owner/repo
  tag_pattern: 'release-*'"

  # Mock returns v2.0.0, v1.9.0, v1.0.0 — none match ^release-.*
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
