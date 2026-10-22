#!/usr/bin/env bash
#
# kde-tarball - Detect latest version from a directory on download.kde.org
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string (e.g., "1.0.1")
#
# The KDE download server lists tarballs as {project}-{version}.tar.xz.
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

page=$(http_get "$url") || {
  echo "Failed to fetch $url" >&2
  exit 1
}

# \Q...\E makes a dot or a plus in the name match itself
version=$(echo "$page" |
  grep -oP "\Q${project}\E-\K[0-9]+\.[0-9]+(\.[0-9]+)*(?=\.tar\.xz\")" |
  sort -Vu |
  tail -1 || true)

if [[ -z "$version" ]]; then
  echo "No versions found at $url" >&2
  exit 1
fi

echo "$version"
