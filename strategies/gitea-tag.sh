#!/usr/bin/env bash
#
# gitea-tag — Detect latest version from Gitea/Forgejo/Codeberg tags
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string
#
# Works with any Gitea/Forgejo instance (codeberg.org, etc.)

set -euo pipefail

readonly NAME="${1:?Usage: gitea-tag.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TIMEOUT=30

# shellcheck source=../scripts/lib.sh
source "${SCRIPT_DIR}/../scripts/lib.sh"

pkg_file=$(pkg_file "$NAME")
host=$(pkg_get "$pkg_file" .upstream.host)
owner_repo=$(pkg_get "$pkg_file" .upstream.project)
tag_pattern=$(pkg_get "$pkg_file" '.upstream.tag_pattern // ""')

tags=$(curl -sfL --max-time "$TIMEOUT" \
  "https://${host}/api/v1/repos/${owner_repo}/tags?limit=50" |
  yq -r '.[].name') || {
  echo "Failed to fetch tags from ${host}/${owner_repo}" >&2
  exit 1
}

if [[ -z "$tags" ]]; then
  echo "No tags found for ${host}/${owner_repo}" >&2
  exit 1
fi

# Filter by pattern if set
if [[ -n "$tag_pattern" ]]; then
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
