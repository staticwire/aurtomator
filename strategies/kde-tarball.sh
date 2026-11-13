#!/usr/bin/env bash
# kde-tarball - Print the newest version of a tarball on download.kde.org, see
# https://aurtomator.dev/strategies/#kde-tarball

set -euo pipefail

readonly NAME="${1:?Usage: kde-tarball.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
project=$(pkg_get "$pkg_file" '.upstream.project // .name')
path=$(pkg_get "$pkg_file" '.upstream.path // ""')
url="https://download.kde.org/${path:-stable/${project}}/"

# Print the listing of directory URL $1, or exit with the URL
listing() {
  http_get "$1" || {
    echo "Failed to fetch $1" >&2
    exit 1
  }
}

# Print the version of every {project}-{version}.tar.xz in listing $1; \Q...\E makes a dot or
# a plus in the name match itself
tarball_versions() {
  grep -oP "\Q${project}\E-\K[0-9]+\.[0-9]+(\.[0-9]+)*(?=\.tar\.xz\")" <<<"$1" || true
}

page=$(listing "$url")
versions=$(tarball_versions "$page")

newest=$(grep -oP 'href="\K[0-9]+(\.[0-9]+)*(?=/")' <<<"$page" | sort -V | tail -1 || true)
if [[ -n "$newest" ]]; then
  dir="${url}${newest}/"
  inner=$(listing "$dir")
  if grep -q 'href="src/"' <<<"$inner"; then
    dir="${dir}src/"
    inner=$(listing "$dir")
  fi
  found=$(tarball_versions "$inner")
  if [[ -z "$found" ]]; then
    echo "No ${project}-<version>.tar.xz in the newest version directory $dir" >&2
    exit 1
  fi
  versions+=$'\n'"$found"
fi

version=$(grep . <<<"$versions" | sort -Vu | tail -1 || true)

if [[ -z "$version" ]]; then
  echo "No versions found at $url" >&2
  exit 1
fi

echo "$version"
