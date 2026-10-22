#!/usr/bin/env bash
#
# gitlab-tag - Detect latest version from GitLab tags
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string
#
# Works with any GitLab instance (invent.kde.org, gitlab.com, etc.)

set -euo pipefail

readonly NAME="${1:?Usage: gitlab-tag.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
host=$(pkg_get "$pkg_file" .upstream.host)
project=$(pkg_get "$pkg_file" .upstream.project)
tag_pattern=$(pkg_get "$pkg_file" '.upstream.tag_pattern // ""')
tag_version_regex=$(pkg_get "$pkg_file" '.upstream.tag_version_regex // ""')

# URL-encode the project path (e.g., group/project → group%2Fproject)
project_encoded="${project//\//%2F}"

tags=$(http_get "https://${host}/api/v4/projects/${project_encoded}/repository/tags?per_page=100" |
  yq -r '.[].name') || {
  echo "Failed to fetch tags from ${host}/${project}" >&2
  exit 1
}

if [[ -z "$tags" ]]; then
  echo "No tags found for ${host}/${project}" >&2
  exit 1
fi

latest_tag_version "$tags" "$tag_pattern" "$tag_version_regex"
