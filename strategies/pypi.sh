#!/usr/bin/env bash
#
# pypi — Detect latest version from PyPI
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string
#
# upstream.registry: PyPI package name (e.g. "requests")

set -euo pipefail

readonly NAME="${1:?Usage: pypi.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TIMEOUT=30

# shellcheck source=../scripts/lib.sh
source "${SCRIPT_DIR}/../scripts/lib.sh"

pkg_file=$(pkg_file "$NAME")
registry=$(pkg_get "$pkg_file" .upstream.registry)

version=$(curl -sfL --max-time "$TIMEOUT" \
  "https://pypi.org/pypi/${registry}/json" |
  yq -r '.info.version') || {
  echo "Failed to fetch PyPI info for ${registry}" >&2
  exit 1
}

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "No version found on PyPI for ${registry}" >&2
  exit 1
fi

echo "$version"
