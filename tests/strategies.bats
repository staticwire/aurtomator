#!/usr/bin/env bats

load helpers/setup.sh

setup() {
  setup_test_env
  # A strategy needs scripts/lib/common.sh and nothing else of scripts/
  find "$TEST_TMPDIR/scripts" -type l ! -name common.sh -delete
  cp "$TESTS_DIR/helpers/mock-git.sh" "$MOCK_DIR/git"
  chmod +x "$MOCK_DIR/git"
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

# | ends the pattern of a sed s command
@test "github-release: tag_version_regex may hold |" {
  create_test_package "test-regex-bar" "github-release" "upstream:
  project: custom-suffix/repo
  tag_version_regex: '^v?([0-9.]+)(-stable|)$'"

  run "$TEST_TMPDIR/strategies/github-release.sh" "test-regex-bar"
  [ "$status" -eq 0 ]
  [ "$output" = "0.1.8" ]
}

@test "github-release: the capture group alone is the version" {
  create_test_package "test-regex-part" "github-release" "upstream:
  project: custom-suffix/repo
  tag_version_regex: '([0-9.]+)'"

  run "$TEST_TMPDIR/strategies/github-release.sh" "test-regex-part"
  [ "$status" -eq 0 ]
  [ "$output" = "0.1.8" ]
}

@test "github-release: tag_version_regex non-matching fails" {
  create_test_package "test-nomatch" "github-release" "upstream:
  project: custom-suffix/repo
  tag_version_regex: 'docker-v(.*)'"

  run "$TEST_TMPDIR/strategies/github-release.sh" "test-nomatch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tag_version_regex 'docker-v(.*)' did not match tag '0.1.8-stable'"* ]]
}

@test "github-release: tag_version_replace builds the version from the groups" {
  create_test_package "test-replace" "github-release" "upstream:
  project: dated-owner/dated-repo
  tag_version_regex: '^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
  tag_version_replace: '\\1.\\2.\\3'"

  run "$TEST_TMPDIR/strategies/github-release.sh" "test-replace"
  [ "$status" -eq 0 ]
  [ "$output" = "2026.10.21" ]
}

@test "github-release: tag_version_replace fails on a group the regex lacks" {
  create_test_package "test-replace" "github-release" "upstream:
  project: dated-owner/dated-repo
  tag_version_regex: '^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
  tag_version_replace: '\\1.\\4'"

  run "$TEST_TMPDIR/strategies/github-release.sh" "test-replace"
  [ "$status" -eq 1 ]
  [[ "$output" == *'tag_version_replace names \4, a group tag_version_regex does not have'* ]]
  [[ "$output" != *"did not match"* ]]
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

@test "github-tag: tag_version_regex may hold |" {
  create_test_package "test-tag-bar" "github-tag" "upstream:
  project: custom-prefix/repo
  tag_version_regex: '^bun-v([0-9.]+)(-stable|)$'"

  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-tag-bar"
  [ "$status" -eq 0 ]
  [ "$output" = "1.3.11" ]
}

@test "github-tag: tag_version_replace builds the version from the groups" {
  create_test_package "test-tag-replace" "github-tag" "upstream:
  project: dated-owner/dated-repo
  tag_version_regex: '^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
  tag_version_replace: '\\1.\\2.\\3'"

  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-tag-replace"
  [ "$status" -eq 0 ]
  [ "$output" = "2026.09.10" ]
}

@test "github-tag: takes only tags of the form v1.2.3 by default" {
  create_test_package "test-gh-tag" "github-tag" "upstream:
  project: mixed-owner/mixed-repo"

  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-gh-tag"
  [ "$status" -eq 0 ]
  [ "$output" = "2.0.0" ]
}

@test "github-tag: names tag_version_regex when no tag is a release" {
  create_test_package "test-gh-tag" "github-tag" "upstream:
  project: named-owner/named-repo"

  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-gh-tag"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No tag of the form v1.2.3 or 1.2.3; set upstream.tag_version_regex"* ]]
}

@test "github-tag: reads every tag with git ls-remote" {
  create_test_package "test-gh-tag" "github-tag" "upstream:
  project: paged-owner/paged-repo"

  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-gh-tag"
  [ "$status" -eq 0 ]
  [ "$output" = "14" ]
  [ "$(cat "$TEST_TMPDIR/ls-remote.args")" = "ls-remote --tags --refs https://github.com/paged-owner/paged-repo.git" ]
}

@test "github-tag: reads the tags over https only, without a terminal prompt" {
  create_test_package "test-gh-tag" "github-tag" "upstream:
  project: owner/repo"

  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-gh-tag"
  [ "$status" -eq 0 ]
  grep -qx 'GIT_ALLOW_PROTOCOL=https' "$TEST_TMPDIR/ls-remote.env"
  grep -qx 'GIT_TERMINAL_PROMPT=0' "$TEST_TMPDIR/ls-remote.env"
}

@test "github-tag: fails when git cannot read the tags" {
  create_test_package "test-gh-tag" "github-tag" "upstream:
  project: missing-owner/missing-repo"

  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-gh-tag"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to fetch tags for missing-owner/missing-repo"* ]]
}

@test "github-tag: gives GITHUB_TOKEN to git in the environment, never as an argument" {
  create_test_package "test-gh-tag" "github-tag" "upstream:
  project: owner/repo"
  export GITHUB_TOKEN=standin-token
  local basic
  basic=$(printf 'x-access-token:standin-token' | base64 -w0)

  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-gh-tag"
  [ "$status" -eq 0 ]
  grep -qx 'GIT_CONFIG_COUNT=1' "$TEST_TMPDIR/ls-remote.env"
  grep -qx 'GIT_CONFIG_KEY_0=http.https://github.com/.extraHeader' "$TEST_TMPDIR/ls-remote.env"
  grep -qx "GIT_CONFIG_VALUE_0=Authorization: Basic $basic" "$TEST_TMPDIR/ls-remote.env"
  ! grep -q -e standin-token -e "$basic" "$TEST_TMPDIR/ls-remote.args"
}

@test "github-tag: gives git no token without GITHUB_TOKEN" {
  create_test_package "test-gh-tag" "github-tag" "upstream:
  project: owner/repo"
  unset GITHUB_TOKEN

  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-gh-tag"
  [ "$status" -eq 0 ]
  [ -s "$TEST_TMPDIR/ls-remote.env" ]
  ! grep -qE '^GIT_CONFIG_(COUNT|KEY_0|VALUE_0)=' "$TEST_TMPDIR/ls-remote.env"
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

# mesa names its releases mesa-26.2.5
@test "gitlab-tag: tag_version_regex extracts from prefixed tags" {
  create_test_package "test-gl-tag" "gitlab-tag" "upstream:
  host: gitlab.com
  project: prefix-group/prefix-project
  tag_version_regex: '^mesa-([0-9.]+)$'"

  run "$TEST_TMPDIR/strategies/gitlab-tag.sh" "test-gl-tag"
  [ "$status" -eq 0 ]
  [ "$output" = "26.2.5" ]
}

@test "gitlab-tag: tag_version_replace builds the version from the groups" {
  create_test_package "test-gl-tag" "gitlab-tag" "upstream:
  host: gitlab.com
  project: dated-group/dated-project
  tag_version_regex: '^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
  tag_version_replace: '\\1\\2\\3'"

  run "$TEST_TMPDIR/strategies/gitlab-tag.sh" "test-gl-tag"
  [ "$status" -eq 0 ]
  [ "$output" = "20260910" ]
}

@test "gitlab-tag: takes only tags of the form v1.2.3 by default" {
  create_test_package "test-gl-tag" "gitlab-tag" "upstream:
  host: gitlab.com
  project: mixed-group/mixed-project"

  run "$TEST_TMPDIR/strategies/gitlab-tag.sh" "test-gl-tag"
  [ "$status" -eq 0 ]
  [ "$output" = "2.0.0" ]
}

@test "gitlab-tag: names tag_version_regex when no tag is a release" {
  create_test_package "test-gl-tag" "gitlab-tag" "upstream:
  host: gitlab.com
  project: named-group/named-project"

  run "$TEST_TMPDIR/strategies/gitlab-tag.sh" "test-gl-tag"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No tag of the form v1.2.3 or 1.2.3; set upstream.tag_version_regex"* ]]
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

@test "gitea-tag: tag_version_regex extracts from prefixed tags" {
  create_test_package "test-gitea" "gitea-tag" "upstream:
  host: codeberg.org
  project: prefix-owner/prefix-repo
  tag_version_regex: '^mesa-([0-9.]+)$'"

  run "$TEST_TMPDIR/strategies/gitea-tag.sh" "test-gitea"
  [ "$status" -eq 0 ]
  [ "$output" = "26.2.5" ]
}

@test "gitea-tag: tag_version_replace builds the version from the groups" {
  create_test_package "test-gitea" "gitea-tag" "upstream:
  host: codeberg.org
  project: dated-owner/dated-repo
  tag_version_regex: '^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
  tag_version_replace: '\\1.\\2.\\3'"

  run "$TEST_TMPDIR/strategies/gitea-tag.sh" "test-gitea"
  [ "$status" -eq 0 ]
  [ "$output" = "2026.09.10" ]
}

@test "gitea-tag: takes only tags of the form v1.2.3 by default" {
  create_test_package "test-gitea" "gitea-tag" "upstream:
  host: codeberg.org
  project: mixed-owner/mixed-repo"

  run "$TEST_TMPDIR/strategies/gitea-tag.sh" "test-gitea"
  [ "$status" -eq 0 ]
  [ "$output" = "2.0.0" ]
}

@test "gitea-tag: names tag_version_regex when no tag is a release" {
  create_test_package "test-gitea" "gitea-tag" "upstream:
  host: codeberg.org
  project: named-owner/named-repo"

  run "$TEST_TMPDIR/strategies/gitea-tag.sh" "test-gitea"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No tag of the form v1.2.3 or 1.2.3; set upstream.tag_version_regex"* ]]
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

@test "crates: prerelease reads max_version" {
  create_test_package "test-crates" "crates" "upstream:
  registry: pre-crate
  prerelease: true"

  run "$TEST_TMPDIR/strategies/crates.sh" "test-crates"
  [ "$status" -eq 0 ]
  [ "$output" = "1.0.0-beta.24" ]
}

@test "crates: reads max_stable_version without prerelease" {
  local field
  for field in '' 'prerelease: false'; do
    create_test_package "test-crates" "crates" "upstream:
  registry: pre-crate
  $field"

    run "$TEST_TMPDIR/strategies/crates.sh" "test-crates"
    [ "$status" -eq 0 ]
    [ "$output" = "0.15.0" ]
  done
}

# === repology ===

@test "repology: returns newest version from Repology" {
  create_test_package "test-repology" "repology" "upstream:
  repology: testpkg"

  run "$TEST_TMPDIR/strategies/repology.sh" "test-repology"
  [ "$status" -eq 0 ]
  [ "$output" = "5.0.0" ]
}

# For a package of ours, the AUR entry is our own version
@test "repology: takes the highest outdated version when only the AUR is newest" {
  create_test_package "test-repology" "repology" "upstream:
  repology: aur-ahead"

  run "$TEST_TMPDIR/strategies/repology.sh" "test-repology"
  [ "$status" -eq 0 ]
  [ "$output" = "1.140.10" ]
}

@test "repology: takes newest over an outdated version sort -V ranks higher" {
  create_test_package "test-repology" "repology" "upstream:
  repology: rc-order"

  run "$TEST_TMPDIR/strategies/repology.sh" "test-repology"
  [ "$status" -eq 0 ]
  [ "$output" = "1.0" ]
}

# === archpkg ===

@test "archpkg: returns latest version from Arch repos" {
  create_test_package "test-archpkg" "archpkg" "upstream:
  archpkg: qt6-base"

  run "$TEST_TMPDIR/strategies/archpkg.sh" "test-archpkg"
  [ "$status" -eq 0 ]
  [ "$output" = "6.10.2" ]
}

@test "archpkg: prints pkgver without epoch and pkgrel" {
  create_test_package "test-archpkg" "archpkg" "upstream:
  archpkg: ffmpeg"

  run "$TEST_TMPDIR/strategies/archpkg.sh" "test-archpkg"
  [ "$status" -eq 0 ]
  [ "$output" = "9.0.2" ]
}

# === kde-tarball ===

@test "kde-tarball: returns latest version from download.kde.org" {
  create_test_package "test-kde" "kde-tarball" ""

  run "$TEST_TMPDIR/strategies/kde-tarball.sh" "test-kde"
  [ "$status" -eq 0 ]
  [ "$output" = "1.0.1" ]
}

@test "kde-tarball: upstream.project names the tarball and the directory" {
  record_curl
  create_test_package "kdiff3-mine" "kde-tarball" "upstream:
  project: kdiff3"

  run "$TEST_TMPDIR/strategies/kde-tarball.sh" "kdiff3-mine"
  [ "$status" -eq 0 ]
  [ "$output" = "1.12.6" ]
  grep -qx 'https://download.kde.org/stable/kdiff3/' "$TEST_TMPDIR/curl.args"
}

@test "kde-tarball: upstream.path names the directory" {
  record_curl
  create_test_package "alkimia-unstable" "kde-tarball" "upstream:
  project: alkimia
  path: unstable/alkimia"

  run "$TEST_TMPDIR/strategies/kde-tarball.sh" "alkimia-unstable"
  [ "$status" -eq 0 ]
  [ "$output" = "8.1.80" ]
  grep -qx 'https://download.kde.org/unstable/alkimia/' "$TEST_TMPDIR/curl.args"
}

@test "kde-tarball: a dot in the name matches a dot alone" {
  create_test_package "kio.s3" "kde-tarball" ""

  run "$TEST_TMPDIR/strategies/kde-tarball.sh" "kio.s3"
  [ "$status" -eq 0 ]
  [ "$output" = "1.0.0" ]
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

@test "webpage-scrape: a pattern may hold a slash" {
  create_test_package "test-scrape-path" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'download/test-scrape-([0-9.]+)\\.tar\\.gz'"

  run "$TEST_TMPDIR/strategies/webpage-scrape.sh" "test-scrape-path"
  [ "$status" -eq 0 ]
  [ "$output" = "7.0.0" ]
}

# === git-latest ===

# Helper: a repo with 3 commits in $fake_repo, and a git that clones it in
# place of any URL and logs the protocols the strategy allows
fake_git_upstream() {
  fake_repo="$TEST_TMPDIR/fake-upstream"
  mkdir -p "$fake_repo"
  git -C "$fake_repo" init -q
  git -C "$fake_repo" config user.email "test@test"
  git -C "$fake_repo" config user.name "test"
  for i in 1 2 3; do
    echo "$i" >"$fake_repo/file.txt"
    git -C "$fake_repo" add file.txt
    git -C "$fake_repo" commit -q -m "commit $i"
  done

  cat >"$MOCK_DIR/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  echo "\${GIT_ALLOW_PROTOCOL:-unset} \${@: -2:1}" >>"$TEST_TMPDIR/git-clone"
  exec env -u GIT_ALLOW_PROTOCOL /usr/bin/git clone "\${@:2:\$#-3}" "$fake_repo" "\${@: -1}"
fi
exec /usr/bin/git "\$@"
EOF
  chmod +x "$MOCK_DIR/git"
}

@test "git-latest: returns rCOUNT.HASH format from git repo" {
  fake_git_upstream
  create_test_package "test-git" "git-latest" "upstream:
  type: git
  url: https://git.example.com/repo.git"

  run "$TEST_TMPDIR/strategies/git-latest.sh" "test-git"
  [ "$status" -eq 0 ]
  # Should match r3.<7-char-hash>
  [[ "$output" =~ ^r3\.[0-9a-f]{7}$ ]]
  [ "$(cat "$TEST_TMPDIR/git-clone")" = "http:https https://git.example.com/repo.git" ]
}

# fabric-git is r2173.ef2e985d on the AUR: rev-parse --short grows with the
# repository, and r2173.ef2e985 reads as older
@test "git-latest: takes the length of the hash from current" {
  fake_git_upstream
  local len
  for len in 8 12; do
    create_test_package "test-git" "git-latest" "upstream:
  type: git
  url: https://git.example.com/repo.git
current: 'r2.$(printf '%0*d' "$len" 0)'"

    run "$TEST_TMPDIR/strategies/git-latest.sh" "test-git"
    [ "$status" -eq 0 ]
    [ "$output" = "r3.$(git -C "$fake_repo" rev-parse HEAD | cut -c1-"$len")" ]
  done
}

# makepkg checks out the branch of a source pinned to #branch=
@test "git-latest: counts the commits of upstream.branch" {
  fake_git_upstream
  git -C "$fake_repo" switch -q -c feature HEAD~1
  local i
  for i in 4 5; do
    echo "$i" >"$fake_repo/file.txt"
    git -C "$fake_repo" commit -q -am "commit $i"
  done
  git -C "$fake_repo" switch -q -
  create_test_package "test-git" "git-latest" "upstream:
  type: git
  url: https://git.example.com/repo.git
  branch: feature"

  run "$TEST_TMPDIR/strategies/git-latest.sh" "test-git"
  [ "$status" -eq 0 ]
  [ "$output" = "r4.$(git -C "$fake_repo" rev-parse feature | cut -c1-7)" ]
}

@test "git-latest: fails on a branch the repository lacks" {
  fake_git_upstream
  create_test_package "test-git" "git-latest" "upstream:
  type: git
  url: https://git.example.com/repo.git
  branch: nope"

  run "$TEST_TMPDIR/strategies/git-latest.sh" "test-git"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Remote branch nope not found"* ]]
  [[ "$output" == *"Failed to clone https://git.example.com/repo.git"* ]]
}

@test "git-latest: refuses a local repository" {
  git init -q "$TEST_TMPDIR/local-repo"
  git -C "$TEST_TMPDIR/local-repo" -c user.name=test -c user.email=test@test \
    commit -q --allow-empty -m "commit 1"
  create_test_package "test-git-file" "git-latest" "upstream:
  type: git
  url: file://$TEST_TMPDIR/local-repo"

  run "$TEST_TMPDIR/strategies/git-latest.sh" "test-git-file"
  [ "$status" -eq 1 ]
  [[ "$output" == *"transport 'file' not allowed"* ]]
}

@test "git-latest: refuses an ssh URL without connecting" {
  cat >"$MOCK_DIR/ssh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$TEST_TMPDIR/ssh.args"
exit 255
EOF
  chmod +x "$MOCK_DIR/ssh"
  create_test_package "test-git-ssh" "git-latest" "upstream:
  type: git
  url: ssh://git.example.com/repo.git"

  run "$TEST_TMPDIR/strategies/git-latest.sh" "test-git-ssh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"transport 'ssh' not allowed"* ]]
  [ ! -e "$TEST_TMPDIR/ssh.args" ]
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

# Helper: the pages of the releases list that curl fetched
nightly_pages() {
  grep -o 'releases?per_page=100&page=[0-9]*' "$TEST_TMPDIR/curl.args" | cut -d= -f3 | tr '\n' ' '
}

# servo/servo-nightly-builds lists 12 rc releases first, and every release
# carries the created_at of the tagged commit
@test "github-nightly: nightly_tag_regex takes the match published last" {
  record_curl
  create_test_package "test-nightly-regex" "github-nightly" "upstream:
  project: dated-nightly/repo
  nightly_tag_regex: '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  version_source: tag_date
  date_format: '%Y%m%d'"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-regex"
  [ "$status" -eq 0 ]
  [ "$output" = "20261021" ]
  [ "$(nightly_pages)" = "1 " ]
}

@test "github-nightly: nightly_tag_regex reads the next page" {
  record_curl
  create_test_package "test-nightly-regex" "github-nightly" "upstream:
  project: later-nightly/repo
  nightly_tag_regex: '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  version_source: tag_date"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-regex"
  [ "$status" -eq 0 ]
  [ "$output" = "2026.10.21" ]
  [ "$(nightly_pages)" = "1 2 " ]
}

@test "github-nightly: nightly_tag_regex reads 3 pages at most" {
  record_curl
  create_test_package "test-nightly-regex" "github-nightly" "upstream:
  project: no-nightly/repo
  nightly_tag_regex: '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  version_source: tag_date"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-regex"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No nightly release found for no-nightly/repo"* ]]
  [ "$(nightly_pages)" = "1 2 3 " ]
}

@test "github-nightly: nightly_tag_regex stops at the page with a match" {
  record_curl
  create_test_package "test-nightly-regex" "github-nightly" "upstream:
  project: full-nightly/repo
  nightly_tag_regex: '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  version_source: tag_date"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-regex"
  [ "$status" -eq 0 ]
  [ "$output" = "2026.10.21" ]
  [ "$(nightly_pages)" = "1 " ]
}

@test "github-nightly: nightly_tag_regex stops at a page of fewer than 100" {
  record_curl
  create_test_package "test-nightly-regex" "github-nightly" "upstream:
  project: short-nightly/repo
  nightly_tag_regex: '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  version_source: tag_date"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-regex"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No nightly release found for short-nightly/repo"* ]]
  [ "$(nightly_pages)" = "1 " ]
}

@test "github-nightly: nightly_tag_regex stops at an empty page" {
  record_curl
  create_test_package "test-nightly-regex" "github-nightly" "upstream:
  project: empty-nightly/repo
  nightly_tag_regex: '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  version_source: tag_date"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-regex"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No nightly release found for empty-nightly/repo"* ]]
  [ "$(nightly_pages)" = "1 " ]
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

@test "github-nightly: a channel with a double quote matches the release name" {
  create_test_package "test-nightly-quote-d" "github-nightly" "upstream:
  project: owner/quoted-repo
  channel: 'Beta \"b\"'
  version_source: tag"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-quote-d"
  [ "$status" -eq 0 ]
  [ "$output" = "2.0.0" ]
}

@test "github-nightly: a nightly_tag with a double quote matches the tag" {
  create_test_package "test-nightly-quote-b" "github-nightly" "upstream:
  project: owner/quoted-repo
  nightly_tag: 'nightly-\"q\"'
  version_source: tag_date"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-quote-b"
  [ "$status" -eq 0 ]
  [ "$output" = "2026.04.01" ]
}

@test "github-nightly: fails when the tag holds no date" {
  create_test_package "test-nightly-nodate" "github-nightly" "upstream:
  project: owner/repo
  version_source: tag_date"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-nodate"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not extract version from nightly release"* ]]
}

@test "github-nightly: fails when version_pattern matches nothing in the body" {
  create_test_package "test-nightly-nomatch" "github-nightly" "upstream:
  project: owner/repo
  version_source: release_body
  version_pattern: 'NOMATCH v\\K\\S+'"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-nomatch"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not extract version from nightly release"* ]]
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

@test "github-nightly: tag_version_regex may hold |" {
  create_test_package "test-nightly-bar" "github-nightly" "upstream:
  project: custom-nightly/repo
  nightly_tag: nightly
  version_source: tag
  tag_version_regex: '^nightly-v([0-9.]+)(-rc[0-9]+|)$'"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-bar"
  [ "$status" -eq 0 ]
  [ "$output" = "3.5.0" ]
}

# servo-nightly-bin uses 20251213, which vercmp ranks above 2026.10.21
@test "github-nightly: tag_version_replace with version_source=tag" {
  create_test_package "test-nightly-replace" "github-nightly" "upstream:
  project: dated-owner/dated-repo
  nightly_tag: latest
  version_source: tag
  tag_version_regex: '^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
  tag_version_replace: '\\1\\2\\3'"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-replace"
  [ "$status" -eq 0 ]
  [ "$output" = "20261021" ]
}

@test "github-nightly: date_format with tag_date" {
  create_test_package "test-nightly-format" "github-nightly" "upstream:
  project: owner/dated-repo
  nightly_tag: 'nightly-'
  version_source: tag_date
  date_format: '%Y%m%d'"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-format"
  [ "$status" -eq 0 ]
  [ "$output" = "20260326" ]
}

@test "github-nightly: date_format with published_date" {
  create_test_package "test-nightly-format" "github-nightly" "upstream:
  project: dated-owner/dated-repo
  nightly_tag: latest
  version_source: published_date
  date_format: '%Y%m%d'"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-format"
  [ "$status" -eq 0 ]
  [ "$output" = "20261022" ]
}

# Published at 2026-10-22T00:25:00Z, which is still 2026-10-21 at UTC-10
@test "github-nightly: published_date is the date in UTC" {
  create_test_package "test-nightly-utc" "github-nightly" "upstream:
  project: dated-owner/dated-repo
  nightly_tag: latest
  version_source: published_date"

  run env TZ=XXX10 "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-utc"
  [ "$status" -eq 0 ]
  [ "$output" = "2026.10.22" ]
}

@test "github-nightly: fails when the release holds no published_at" {
  create_test_package "test-nightly-nodate" "github-nightly" "upstream:
  project: owner/repo
  nightly_tag: latest
  version_source: published_date"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-nightly-nodate"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not extract version from nightly release"* ]]
}

# === YAML regex fields ===

# In a sed s command a regex field would close the pattern and add the e
# flag, which runs the pattern space as a command
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
  [ ! -e "$TEST_TMPDIR/pwned" ]
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
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

@test "github-asset: fails on a body without assets" {
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

# Helper: one package for each GitHub strategy that calls the API, and a
# curl that appends its arguments to curl.args and its stdin to curl.stdin
# before it answers
setup_github_strategies() {
  create_test_package "gh-release" "github-release" "upstream:
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

# Helper: run every GitHub strategy that calls the API. Stdin is /dev/null,
# so the recording curl does not wait when a strategy gives it nothing to
# read.
run_github_strategies() {
  local strategy
  for strategy in release asset nightly; do
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

@test "github strategies: try a failed request again" {
  setup_github_strategies
  run_github_strategies
  calls=$(wc -l <"$TEST_TMPDIR/curl.args")
  [ "$calls" -gt 0 ]
  [ "$(grep -c -- '--retry 2 --retry-delay 5 --retry-connrefused' "$TEST_TMPDIR/curl.args")" -eq "$calls" ]
}

# A request that goes around http_get makes one attempt
@test "strategies: send every request through http_get" {
  run grep -nE '^[^#]*\bcurl -' "$PROJECT_DIR"/strategies/*.sh
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# === User-Agent ===

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

# Helper: the value of every -A that curl got
curl_agents() {
  grep -x -A1 -- '-A' "$TEST_TMPDIR/curl.args" | grep -vx -e '-A' -e '--'
}

# SourceForge answers a bare Mozilla/5.0 with HTTP 403
@test "strategies: send aurtomator/1.0 as the User-Agent" {
  record_curl
  create_test_package "scrape" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'test-scrape-([0-9.]+)\\.tar\\.gz'"
  create_test_package "release" "github-release" "upstream:
  project: owner/repo"
  create_test_package "rust" "crates" "upstream:
  registry: serde"
  create_test_package "repo" "repology" "upstream:
  repology: firefox"

  run "$TEST_TMPDIR/strategies/webpage-scrape.sh" scrape
  [ "$status" -eq 0 ]
  run "$TEST_TMPDIR/strategies/github-release.sh" release
  [ "$status" -eq 0 ]
  run "$TEST_TMPDIR/strategies/crates.sh" rust
  [ "$status" -eq 0 ]
  run "$TEST_TMPDIR/strategies/repology.sh" repo
  [ "$status" -eq 0 ]
  [ "$(curl_agents | wc -l)" -eq 4 ]
  [ "$(curl_agents | sort -u)" = "aurtomator/1.0" ]
  ! grep -qi 'user-agent' "$TEST_TMPDIR/curl.args"
}

@test "webpage-scrape: sends upstream.user_agent in place of aurtomator/1.0" {
  record_curl
  create_test_package "scrape" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'test-scrape-([0-9.]+)\\.tar\\.gz'
  user_agent: 'Example/2.0 (+https://example.com/bot)'"

  run "$TEST_TMPDIR/strategies/webpage-scrape.sh" scrape
  [ "$status" -eq 0 ]
  [ "$(curl_agents)" = "Example/2.0 (+https://example.com/bot)" ]
}

# === Error handling: unknown package ===

@test "strategy fails gracefully on unknown package" {
  run "$TEST_TMPDIR/strategies/github-release.sh" "nonexistent-package"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Package not found: "*"/packages/nonexistent-package.yml"* ]]
}

# === Error handling: null/empty API responses ===

@test "github-release: fails on a body without tag_name" {
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

@test "repology: fails when only the AUR has a version" {
  create_test_package "test-aur-only" "repology" "upstream:
  repology: aur-only"

  run "$TEST_TMPDIR/strategies/repology.sh" "test-aur-only"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No version found on Repology for aur-only outside the AUR"* ]]
}

@test "repology: names a project Repology does not know" {
  create_test_package "test-missing" "repology" "upstream:
  repology: missing-project"

  run "$TEST_TMPDIR/strategies/repology.sh" "test-missing"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Project missing-project not found on Repology"* ]]
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
  [[ "$output" == *"No versions found at "* ]]
}

@test "webpage-scrape: fails on missing url" {
  create_test_package "test-nourl" "webpage-scrape" "upstream:
  pattern: 'pkg-([0-9.]+)'"

  run "$TEST_TMPDIR/strategies/webpage-scrape.sh" "test-nourl"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Only HTTPS URLs supported: null"* ]]
}

@test "webpage-scrape: fails on missing pattern" {
  create_test_package "test-nopat" "webpage-scrape" "upstream:
  url: https://example.com/releases"

  run "$TEST_TMPDIR/strategies/webpage-scrape.sh" "test-nopat"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No versions matched pattern 'null'"* ]]
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
  [[ "$output" == *"No versions matched pattern "*" at https://example.com/empty-page"* ]]
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

@test "github-nightly: nightly_tag_regex fails on curl network error" {
  create_test_package "test-neterr" "github-nightly" "upstream:
  project: dated-nightly/repo
  nightly_tag_regex: '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  version_source: tag_date"

  cat >"$TEST_TMPDIR/mock-bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl: (7) Failed to connect" >&2
exit 7
EOF
  chmod +x "$TEST_TMPDIR/mock-bin/curl"

  run "$TEST_TMPDIR/strategies/github-nightly.sh" "test-neterr"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to fetch releases for dated-nightly/repo"* ]]
}

@test "repology: fails on curl network error" {
  create_test_package "test-neterr" "repology" "upstream:
  repology: firefox"

  cat >"$TEST_TMPDIR/mock-bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl: (7) Failed to connect" >&2
exit 7
EOF
  chmod +x "$TEST_TMPDIR/mock-bin/curl"

  run "$TEST_TMPDIR/strategies/repology.sh" "test-neterr"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to fetch Repology info for firefox"* ]]
}

@test "github-release: fails on a 404 (curl exit 22)" {
  create_test_package "test-404" "github-release" "upstream:
  project: owner/repo"

  # curl -sf prints nothing on a 404 and exits 22
  cat >"$TEST_TMPDIR/mock-bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
  chmod +x "$TEST_TMPDIR/mock-bin/curl"

  run "$TEST_TMPDIR/strategies/github-release.sh" "test-404"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to fetch latest release for owner/repo"* ]]
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

@test "github-tag: tag_version_regex filters out all tags" {
  create_test_package "test-filter" "github-tag" "upstream:
  project: owner/repo
  tag_version_regex: '^release-(.+)$'"

  # The mock returns v2.0.0, v1.9.0 and v1.0.0, and none matches ^release-
  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-filter"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No matching tags found"* ]]
}

@test "gitlab-tag: tag_version_regex filters out all tags" {
  create_test_package "test-filter" "gitlab-tag" "upstream:
  host: gitlab.com
  project: group/project
  tag_version_regex: '^release-(.+)$'"

  run "$TEST_TMPDIR/strategies/gitlab-tag.sh" "test-filter"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No matching tags found"* ]]
}

@test "gitea-tag: tag_version_regex filters out all tags" {
  create_test_package "test-filter" "gitea-tag" "upstream:
  host: codeberg.org
  project: owner/repo
  tag_version_regex: '^release-(.+)$'"

  run "$TEST_TMPDIR/strategies/gitea-tag.sh" "test-filter"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No matching tags found"* ]]
}

# A pin to one release line leaves out v2.0.0 and the v2.1.0 rc tags
@test "github-tag: tag_version_regex pins a release line" {
  create_test_package "test-pin" "github-tag" "upstream:
  project: mixed-owner/mixed-repo
  tag_version_regex: '^v(1\\.[0-9.]+)$'"

  run "$TEST_TMPDIR/strategies/github-tag.sh" "test-pin"
  [ "$status" -eq 0 ]
  [ "$output" = "1.9.0" ]
}
