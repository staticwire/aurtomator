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
tag_version_regex=$(pkg_get "$pkg_file" '.upstream.tag_version_regex // ""')
tag_version_replace=$(pkg_get "$pkg_file" '.upstream.tag_version_replace // ""')

tags=$(github_tags "$owner_repo") || {
  echo "Failed to fetch tags for ${owner_repo}" >&2
  exit 1
}

if [[ -z "$tags" ]]; then
  echo "No tags found for ${owner_repo}" >&2
  exit 1
fi

latest_tag_version "$tags" "$tag_version_regex" "$tag_version_replace"
