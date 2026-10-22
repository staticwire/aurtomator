#!/usr/bin/env bash
#
# github-release - Detect latest version from GitHub releases
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string
#
# Uses curl (no gh CLI required). Works with public repos without auth.
# For private repos, set GITHUB_TOKEN env var.

set -euo pipefail

readonly NAME="${1:?Usage: github-release.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
owner_repo=$(pkg_get "$pkg_file" .upstream.project)
tag_version_regex=$(pkg_get "$pkg_file" '.upstream.tag_version_regex // ""')

version=$(github_api "https://api.github.com/repos/${owner_repo}/releases/latest" |
  yq -r '.tag_name') || {
  echo "Failed to fetch latest release for ${owner_repo}" >&2
  exit 1
}

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "No releases found for ${owner_repo}" >&2
  exit 1
fi

# Extract version from tag
if [[ -n "$tag_version_regex" ]]; then
  # The regex can close the s command; --sandbox refuses e, r and w
  extracted=$(echo "$version" | sed --sandbox -nE "s|${tag_version_regex}|\\1|p" | head -1)
  if [[ -z "$extracted" ]]; then
    echo "tag_version_regex '${tag_version_regex}' did not match tag '${version}'" >&2
    exit 1
  fi
  echo "$extracted"
else
  # Default: strip v prefix
  echo "${version#v}"
fi
