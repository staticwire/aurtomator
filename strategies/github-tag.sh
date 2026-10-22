#!/usr/bin/env bash
#
# github-tag - Detect latest version from GitHub tags
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string
#
# For projects that use tags but not GitHub Releases.
# Reads every tag with git ls-remote, outside the API rate limit. Works
# with public repos without auth. For private repos, set GITHUB_TOKEN env var.

set -euo pipefail

readonly NAME="${1:?Usage: github-tag.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
owner_repo=$(pkg_get "$pkg_file" .upstream.project)
tag_pattern=$(pkg_get "$pkg_file" '.upstream.tag_pattern // ""')
tag_version_regex=$(pkg_get "$pkg_file" '.upstream.tag_version_regex // ""')

# The tags API answers 100 tags at most per page. git takes the token from
# the environment: as an argument, it is visible in ps to every local user.
# Args: $1=owner/repo
github_tags() {
  (
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraHeader
      GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)"
      export GIT_CONFIG_VALUE_0
    fi
    GIT_ALLOW_PROTOCOL=https GIT_TERMINAL_PROMPT=0 \
      git ls-remote --tags --refs "https://github.com/$1.git"
  )
}

tags=$(github_tags "$owner_repo" | cut -f2 | sed 's|^refs/tags/||') || {
  echo "Failed to fetch tags for ${owner_repo}" >&2
  exit 1
}

if [[ -z "$tags" ]]; then
  echo "No tags found for ${owner_repo}" >&2
  exit 1
fi

latest_tag_version "$tags" "$tag_pattern" "$tag_version_regex"
