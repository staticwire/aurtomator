#!/usr/bin/env bash
# pypi - Print the latest stable version of a package on PyPI, see
# https://aurtomator.dev/strategies/#pypi

set -euo pipefail

readonly NAME="${1:?Usage: pypi.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
registry=$(pkg_get "$pkg_file" .upstream.registry)

version=$(http_get_json "https://pypi.org/pypi/${registry}/json" | yq -r '.info.version') || {
  echo "Failed to fetch PyPI info for ${registry}" >&2
  exit 1
}

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "No version found on PyPI for ${registry}" >&2
  exit 1
fi

echo "$version"
