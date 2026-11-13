#!/usr/bin/env bash
# github-nightly - Print the version of the latest nightly build on GitHub, see
# https://aurtomator.dev/strategies/#github-nightly

set -euo pipefail

readonly NAME="${1:?Usage: github-nightly.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
owner_repo=$(pkg_get "$pkg_file" .upstream.project)
nightly_tag=$(pkg_get "$pkg_file" '.upstream.nightly_tag // "nightly"')
version_source=$(pkg_get "$pkg_file" '.upstream.version_source // "tag"')
channel=$(pkg_get "$pkg_file" '.upstream.channel // ""')
version_pattern=$(pkg_get "$pkg_file" '.upstream.version_pattern // ""')
tag_version_regex=$(pkg_get "$pkg_file" '.upstream.tag_version_regex // ""')
tag_version_replace=$(pkg_get "$pkg_file" '.upstream.tag_version_replace // ""')
date_format=$(pkg_get "$pkg_file" '.upstream.date_format // "%Y.%m.%d"')
nightly_tag_regex=$(pkg_get "$pkg_file" '.upstream.nightly_tag_regex // ""')

api="https://api.github.com/repos/${owner_repo}"

# Prints date or timestamp $1 in date_format, and nothing for an empty or null $1. -u keeps
# the day of a UTC timestamp whatever the time zone of the machine.
format_date() {
  if [[ -n "$1" && "$1" != "null" ]]; then
    date -u -d "$1" +"$date_format"
  fi
}

# channel and nightly_tag reach yq through strenv, so a quote in them cannot break the expression
if [[ -n "$nightly_tag_regex" ]]; then
  # Pattern B with a regex
  release=$(github_release_matching "$api" "$nightly_tag_regex" 3) || {
    echo "Failed to fetch releases for ${owner_repo}" >&2
    exit 1
  }
  if [[ -z "$release" ]]; then
    # An empty list says nothing about the regex
    if [[ "$(github_api "${api}/releases?per_page=1" | yq 'length')" == 0 ]]; then
      echo "The release list of ${owner_repo} is empty" >&2
    else
      echo "No release among the newest 300 of ${owner_repo} has a tag that nightly_tag_regex '${nightly_tag_regex}' matches" >&2
    fi
    exit 1
  fi
elif [[ "$nightly_tag" == "latest" ]]; then
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
  release=$(echo "$releases_json" | CHANNEL="$channel" yq -r '[.[] | select(.name | contains(strenv(CHANNEL)))][0]')
elif [[ "$nightly_tag" == *"-"* && "$nightly_tag" != "nightly" ]]; then
  # Pattern B: dated tags with prefix (e.g. "nightly-")
  releases_json=$(github_api "${api}/releases?per_page=20") || {
    echo "Failed to fetch releases for ${owner_repo}" >&2
    exit 1
  }
  release=$(echo "$releases_json" | NIGHTLY_TAG="$nightly_tag" yq -r '[.[] | select(.tag_name | contains(strenv(NIGHTLY_TAG)))][0]')
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

case "$version_source" in
  tag)
    version=$(echo "$release" | yq -r '.tag_name')
    if [[ -n "$tag_version_regex" ]]; then
      extracted=$(tag_versions "$tag_version_regex" "$tag_version_replace" <<<"$version")
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
    date=$(echo "$tag" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
    if [[ "$date" == *$'\n'* ]]; then
      echo "Tag '${tag}' holds more than one date; version_source tag with tag_version_regex picks one" >&2
      exit 1
    fi
    version=$(format_date "$date")
    ;;
  release_body)
    if [[ -z "$version_pattern" ]]; then
      echo "version_pattern required for release_body source" >&2
      exit 1
    fi
    body=$(echo "$release" | yq -r '.body')
    version=$(echo "$body" | grep -oP -e "$version_pattern" | head -1 || true)
    # A pkgver cannot hold a dash
    version="${version//-/+}"
    ;;
  published_date)
    version=$(format_date "$(echo "$release" | yq -r '.published_at')")
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
