#!/usr/bin/env bash
# github-release - Print the version of the latest GitHub release, see
# https://aurtomator.dev/strategies/#github-release

set -euo pipefail

readonly NAME="${1:?Usage: github-release.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
owner_repo=$(pkg_get "$pkg_file" .upstream.project)
tag_version_regex=$(pkg_get "$pkg_file" '.upstream.tag_version_regex // ""')
tag_version_replace=$(pkg_get "$pkg_file" '.upstream.tag_version_replace // ""')

api="https://api.github.com/repos/${owner_repo}"

if [[ -n "$tag_version_regex" ]]; then
  # /releases/latest can be a release of another product of the repository, so the regex
  # picks among the releases by version, as the tag strategies do
  release=$(github_release_matching "$api" "$tag_version_regex" 10 stable version "$tag_version_replace") || {
    echo "Failed to fetch releases for ${owner_repo}" >&2
    exit 1
  }
  if [[ -z "$release" ]]; then
    # An empty list says nothing about the regex
    if [[ "$(github_api "${api}/releases?per_page=1" | yq 'length')" == 0 ]]; then
      echo "The release list of ${owner_repo} is empty" >&2
    else
      echo "No release of ${owner_repo} outside pre-releases among the newest 1000 has a tag that tag_version_regex '${tag_version_regex}' matches; github-nightly with nightly_tag_regex reads pre-releases" >&2
    fi
    exit 1
  fi
  version=$(yq -r '.tag_name' <<<"$release")
else
  version=$(github_api "${api}/releases/latest" | yq -r '.tag_name') || {
    # GitHub answers 404 when every release is a pre-release or there is
    # none, and the list tells these apart from a failed request
    releases=$(github_api "${api}/releases?per_page=100") || releases=""
    if [[ -n "$releases" && "$(yq 'length' <<<"$releases")" == 0 ]]; then
      echo "${owner_repo} has no releases; github-tag reads its tags" >&2
    elif [[ -n "$releases" && "$(yq '[.[] | select(.prerelease != true)] | length' <<<"$releases")" == 0 ]]; then
      echo "${owner_repo} has no release outside pre-releases, which /releases/latest leaves out; github-nightly with nightly_tag_regex reads pre-releases" >&2
    else
      echo "Failed to fetch latest release for ${owner_repo}" >&2
    fi
    exit 1
  }
fi

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "No releases found for ${owner_repo}" >&2
  exit 1
fi

if [[ -n "$tag_version_regex" ]]; then
  extracted=$(tag_versions "$tag_version_regex" "$tag_version_replace" <<<"$version")
  if [[ -z "$extracted" ]]; then
    echo "tag_version_regex '${tag_version_regex}' did not match tag '${version}'" >&2
    exit 1
  fi
  echo "$extracted"
else
  echo "${version#v}"
fi
