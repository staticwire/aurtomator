#!/usr/bin/env bash
#
# kde-tarball - Detect latest version from a directory on download.kde.org
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string (e.g., "1.0.1")
#
# The KDE download server lists tarballs as {project}-{version}.tar.xz.
# Plasma, Frameworks, Gear and krita keep a directory per version or per
# series instead, Gear with the tarballs under src/ in it: the strategy
# also reads the newest such directory and takes the highest version.
#
# upstream.project: tarball name (default: the package name)
# upstream.path:    directory on download.kde.org (default: stable/{project})

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

# Prints the listing of a directory, or exits with the URL
# Args: $1=directory URL
listing() {
  http_get "$1" || {
    echo "Failed to fetch $1" >&2
    exit 1
  }
}

# Prints the version of every {project}-{version}.tar.xz in a listing.
# \Q...\E makes a dot or a plus in the name match itself.
# Args: $1=listing
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
