#!/usr/bin/env bash
# npm - Print the latest version of a package on npm, see
# https://aurtomator.dev/strategies/#npm

set -euo pipefail

readonly NAME="${1:?Usage: npm.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
registry=$(pkg_get "$pkg_file" .upstream.registry)

version=$(http_get_json "https://registry.npmjs.org/${registry}/latest" | yq -r '.version') || {
  echo "Failed to fetch npm info for ${registry}" >&2
  exit 1
}

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "No version found on npm for ${registry}" >&2
  exit 1
fi

echo "$version"
