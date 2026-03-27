#!/usr/bin/env bash
#
# npm — Detect latest version from npm registry
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string
#
# upstream.registry: npm package name (e.g. "express")

set -euo pipefail

readonly NAME="${1:?Usage: npm.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TIMEOUT=30

# shellcheck source=../scripts/lib.sh
source "${SCRIPT_DIR}/../scripts/lib.sh"

pkg_file=$(pkg_file "$NAME")
registry=$(pkg_get "$pkg_file" .upstream.registry)

version=$(curl -sfL --max-time "$TIMEOUT" \
  "https://registry.npmjs.org/${registry}/latest" |
  yq -r '.version') || {
  echo "Failed to fetch npm info for ${registry}" >&2
  exit 1
}

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "No version found on npm for ${registry}" >&2
  exit 1
fi

echo "$version"
