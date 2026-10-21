#!/usr/bin/env bash
#
# github-nightly - Detect latest version from GitHub nightly/prerelease builds
#
# Supports 4 patterns:
#   A) Fixed tag (default): nightly tag force-pushed daily (neovim, ghostty, yazi)
#   B) Dated tags: nightly-YYYY-MM-DD (ruffle, servo)
#   C) Separate nightly repo: standard /releases/latest on a different repo (yt-dlp)
#   D) Channel filter: filter releases by name containing channel string (brave)
#
# YAML fields:
#   upstream.project        - owner/repo (required)
#   upstream.nightly_tag    - tag name or pattern (default: "nightly")
#                             use "latest" for pattern C
#                             use prefix like "nightly-" for pattern B
#   upstream.version_source - where to extract version from:
#                             "tag" (default), "release_body", "tag_date", "published_date"
#   upstream.version_pattern - regex for extracting version from release body (pattern A)
#   upstream.channel        - filter releases by name (pattern D)

set -euo pipefail

readonly NAME="${1:?Usage: github-nightly.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib.sh
source "${SCRIPT_DIR}/../scripts/lib.sh"

pkg_file=$(pkg_file "$NAME")
owner_repo=$(pkg_get "$pkg_file" .upstream.project)
nightly_tag=$(pkg_get "$pkg_file" '.upstream.nightly_tag // "nightly"')
version_source=$(pkg_get "$pkg_file" '.upstream.version_source // "tag"')
channel=$(pkg_get "$pkg_file" '.upstream.channel // ""')
version_pattern=$(pkg_get "$pkg_file" '.upstream.version_pattern // ""')
tag_version_regex=$(pkg_get "$pkg_file" '.upstream.tag_version_regex // ""')

api="https://api.github.com/repos/${owner_repo}"

# Fetch release based on pattern. channel and nightly_tag reach yq through
# the environment so that quotes in them cannot break the expression.
if [[ "$nightly_tag" == "latest" ]]; then
  # Pattern C: separate nightly repo, use /releases/latest
  release=$(github_api "${api}/releases/latest") || {
    echo "Failed to fetch latest release for ${owner_repo}" >&2
    exit 1
  }
elif [[ -n "$channel" ]]; then
  # Pattern D: filter by channel name in release name
  releases_json=$(github_api "${api}/releases?per_page=20") || {
    echo "Failed to fetch releases for ${owner_repo}" >&2
    exit 1
  }
  release=$(echo "$releases_json" |
    CHANNEL="$channel" yq -r '[.[] | select(.name | contains(strenv(CHANNEL)))][0]')
elif [[ "$nightly_tag" == *"-"* && "$nightly_tag" != "nightly" ]]; then
  # Pattern B: dated tags with prefix (e.g. "nightly-")
  releases_json=$(github_api "${api}/releases?per_page=20") || {
    echo "Failed to fetch releases for ${owner_repo}" >&2
    exit 1
  }
  release=$(echo "$releases_json" |
    NIGHTLY_TAG="$nightly_tag" yq -r '[.[] | select(.tag_name | contains(strenv(NIGHTLY_TAG)))][0]')
else
  # Pattern A: fixed tag (default)
  release=$(github_api "${api}/releases/tags/${nightly_tag}") || {
    echo "Failed to fetch release tag '${nightly_tag}' for ${owner_repo}" >&2
    exit 1
  }
fi

if [[ -z "$release" || "$release" == "null" ]]; then
  echo "No nightly release found for ${owner_repo}" >&2
  exit 1
fi

# Extract version based on version_source
case "$version_source" in
  tag)
    version=$(echo "$release" | yq -r '.tag_name')
    if [[ -n "$tag_version_regex" ]]; then
      # The regex can close the s command; --sandbox refuses e, r and w
      extracted=$(echo "$version" | sed --sandbox -nE "s|${tag_version_regex}|\\1|p" | head -1)
      if [[ -z "$extracted" ]]; then
        echo "tag_version_regex '${tag_version_regex}' did not match tag '${version}'" >&2
        exit 1
      fi
      version="$extracted"
    else
      version="${version#v}"
    fi
    ;;
  tag_date)
    tag=$(echo "$release" | yq -r '.tag_name')
    version=$(echo "$tag" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tr '-' '.')
    ;;
  release_body)
    if [[ -z "$version_pattern" ]]; then
      echo "version_pattern required for release_body source" >&2
      exit 1
    fi
    body=$(echo "$release" | yq -r '.body')
    version=$(echo "$body" | grep -oP -e "$version_pattern" | head -1)
    # Clean up: replace - with + for pacman compatibility
    version="${version//-/+}"
    ;;
  published_date)
    version=$(echo "$release" | yq -r '.published_at' | cut -dT -f1 | tr '-' '.')
    ;;
  *)
    echo "Unknown version_source: $version_source" >&2
    exit 1
    ;;
esac

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "Could not extract version from nightly release" >&2
  exit 1
fi

echo "$version"
