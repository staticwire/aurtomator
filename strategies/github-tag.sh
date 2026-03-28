#!/usr/bin/env bash
#
# github-tag — Detect latest version from GitHub tags
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string
#
# For projects that use tags but not GitHub Releases.
# Uses curl (no gh CLI required). Works with public repos without auth.
# For private repos, set GITHUB_TOKEN env var.

set -euo pipefail

readonly NAME="${1:?Usage: github-tag.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TIMEOUT=30

# shellcheck source=../scripts/lib.sh
source "${SCRIPT_DIR}/../scripts/lib.sh"

pkg_file=$(pkg_file "$NAME")
owner_repo=$(pkg_get "$pkg_file" .upstream.project)
tag_pattern=$(pkg_get "$pkg_file" '.upstream.tag_pattern // ""')
tag_version_regex=$(pkg_get "$pkg_file" '.upstream.tag_version_regex // ""')

# Build auth header if token available
auth_header=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  auth_header=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

tags=$(curl -sfL --max-time "$TIMEOUT" \
  "${auth_header[@]}" \
  "https://api.github.com/repos/${owner_repo}/tags?per_page=100" |
  yq -r '.[].name') || {
  echo "Failed to fetch tags for ${owner_repo}" >&2
  exit 1
}

if [[ -z "$tags" ]]; then
  echo "No tags found for ${owner_repo}" >&2
  exit 1
fi

# Filter by pattern if set
if [[ -n "$tag_pattern" ]]; then
  regex="^${tag_pattern//\*/.*}"
  tags=$(echo "$tags" | grep -E "$regex" || true)
fi

# Extract version from tags
if [[ -n "$tag_version_regex" ]]; then
  version=$(echo "$tags" | sed -nE "s|${tag_version_regex}|\\1|p" | sort -V | tail -1)
else
  # Default: strip v prefix, sort semver, take latest
  version=$(echo "$tags" | sed 's/^v//' | sort -V | tail -1)
fi

if [[ -z "$version" ]]; then
  echo "No matching tags found" >&2
  exit 1
fi

echo "$version"
