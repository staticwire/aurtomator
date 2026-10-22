#!/usr/bin/env bash
#
# kde-tarball - Detect latest version from download.kde.org/stable/{name}/
#
# Input: package name
# Output: latest version string (e.g., "1.0.1")
#
# The KDE download server lists tarballs as {name}-{version}.tar.xz.

set -euo pipefail

readonly NAME="${1:?Usage: kde-tarball.sh <package-name>}"
readonly URL="https://download.kde.org/stable/${NAME}/"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

page=$(http_get "$URL") || {
  echo "Failed to fetch $URL" >&2
  exit 1
}

version=$(echo "$page" |
  grep -oP "${NAME}-\K[0-9]+\.[0-9]+(\.[0-9]+)*(?=\.tar\.xz\")" |
  sort -Vu |
  tail -1 || true)

if [[ -z "$version" ]]; then
  echo "No versions found at $URL" >&2
  exit 1
fi

echo "$version"
