#!/usr/bin/env bash
# gitea-tag - Print the newest version among the tags of a Gitea or Forgejo project, see
# https://aurtomator.dev/strategies/#gitea-tag

set -euo pipefail

readonly NAME="${1:?Usage: gitea-tag.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
host=$(pkg_get "$pkg_file" .upstream.host)
owner_repo=$(pkg_get "$pkg_file" .upstream.project)
tag_version_regex=$(pkg_get "$pkg_file" '.upstream.tag_version_regex // ""')
tag_version_replace=$(pkg_get "$pkg_file" '.upstream.tag_version_replace // ""')

tags=$(http_get_json "https://${host}/api/v1/repos/${owner_repo}/tags?limit=50" |
  yq -r '.[].name') || {
  echo "Failed to fetch tags from ${host}/${owner_repo}" >&2
  exit 1
}

if [[ -z "$tags" ]]; then
  echo "No tags found for ${host}/${owner_repo}" >&2
  exit 1
fi

latest_tag_version "$tags" "$tag_version_regex" "$tag_version_replace"
