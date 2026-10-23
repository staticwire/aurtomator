#!/usr/bin/env bash
#
# git-tag - Detect latest version from the tags of any git repository
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string
#
# For hosts without a tags API, such as sourcehut, kernel.org and Savannah,
# and for a GitLab or Gitea project with more tags than gitlab-tag and
# gitea-tag read. Reads every tag with git ls-remote, without authentication.
#
# upstream.url: HTTPS URL of the repository

set -euo pipefail

readonly NAME="${1:?Usage: git-tag.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
url=$(pkg_get "$pkg_file" .upstream.url)
tag_version_regex=$(pkg_get "$pkg_file" '.upstream.tag_version_regex // ""')
tag_version_replace=$(pkg_get "$pkg_file" '.upstream.tag_version_replace // ""')

if [[ "$url" != https://* ]]; then
  echo "Only HTTPS URLs supported: $url" >&2
  exit 1
fi

tags=$(remote_tags "$url") || {
  echo "Failed to fetch tags from $url" >&2
  exit 1
}

if [[ -z "$tags" ]]; then
  echo "No tags found at $url" >&2
  exit 1
fi

latest_tag_version "$tags" "$tag_version_regex" "$tag_version_replace"
