#!/usr/bin/env bash
#
# gitlab-tag — Detect latest version from GitLab tags
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string
#
# Works with any GitLab instance (invent.kde.org, gitlab.com, etc.)

set -euo pipefail

readonly NAME="${1:?Usage: gitlab-tag.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TIMEOUT=30

# shellcheck source=../scripts/lib.sh
source "${SCRIPT_DIR}/../scripts/lib.sh"

pkg_file=$(pkg_file "$NAME")
host=$(pkg_get "$pkg_file" .upstream.host)
project=$(pkg_get "$pkg_file" .upstream.project)
tag_pattern=$(pkg_get "$pkg_file" '.upstream.tag_pattern // ""')

# URL-encode the project path (e.g., group/project → group%2Fproject)
project_encoded="${project//\//%2F}"

tags=$(curl -sfL --max-time "$TIMEOUT" \
  "https://${host}/api/v4/projects/${project_encoded}/repository/tags?per_page=100" |
  yq -r '.[].name') || {
  echo "Failed to fetch tags from ${host}/${project}" >&2
  exit 1
}

if [[ -z "$tags" ]]; then
  echo "No tags found for ${host}/${project}" >&2
  exit 1
fi

# Filter by pattern if set
if [[ -n "$tag_pattern" ]]; then
  # Convert glob pattern (v*) to grep regex (^v)
  regex="^${tag_pattern//\*/.*}"
  tags=$(echo "$tags" | grep -E "$regex" || true)
fi

# Strip v prefix, sort semver, take latest
version=$(echo "$tags" | sed 's/^v//' | sort -V | tail -1)

if [[ -z "$version" ]]; then
  echo "No matching tags found" >&2
  exit 1
fi

echo "$version"
