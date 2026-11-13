#!/usr/bin/env bash
# github-tag - Print the newest version among the tags of a GitHub repository, see
# https://aurtomator.dev/strategies/#github-tag

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
