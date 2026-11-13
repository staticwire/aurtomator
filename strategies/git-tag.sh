#!/usr/bin/env bash
# git-tag - Print the newest version among the tags of any git repository, see
# https://aurtomator.dev/strategies/#git-tag

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
