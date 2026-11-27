#!/usr/bin/env bash
# gitlab-tag - Print the newest version among the tags of a GitLab project, see
# https://aurtomator.dev/strategies/#gitlab-tag

set -euo pipefail

readonly NAME="${1:?Usage: gitlab-tag.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
host=$(pkg_get "$pkg_file" .upstream.host)
project=$(pkg_get "$pkg_file" .upstream.project)
tag_version_regex=$(pkg_get "$pkg_file" '.upstream.tag_version_regex // ""')
tag_version_replace=$(pkg_get "$pkg_file" '.upstream.tag_version_replace // ""')

# GitLab counts the requests of a token apart from those of the address of the runner
tags=$(gitlab_api "$(gitlab_tags_url "$host" "$project")" | yq -r '.[].name') || {
  echo "Failed to fetch tags from ${host}/${project}" >&2
  exit 1
}

if [[ -z "$tags" ]]; then
  echo "No tags found for ${host}/${project}" >&2
  exit 1
fi

latest_tag_version "$tags" "$tag_version_regex" "$tag_version_replace"
