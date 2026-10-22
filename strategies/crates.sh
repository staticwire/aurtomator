#!/usr/bin/env bash
#
# crates - Detect latest version from crates.io
#
# Input: package name (reads upstream config from package YAML)
# Output: latest stable version string, or max_version with
#         upstream.prerelease, which counts pre-releases
#
# upstream.registry: crate name (e.g. "serde")
# upstream.prerelease: true to read max_version (default: false)

set -euo pipefail

readonly NAME="${1:?Usage: crates.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
registry=$(pkg_get "$pkg_file" .upstream.registry)
field=max_stable_version
if [[ $(pkg_get "$pkg_file" '.upstream.prerelease') == true ]]; then
  field=max_version
fi

version=$(http_get "https://crates.io/api/v1/crates/${registry}" |
  yq -r ".crate.${field}") || {
  echo "Failed to fetch crates.io info for ${registry}" >&2
  exit 1
}

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "No version found on crates.io for ${registry}" >&2
  exit 1
fi

echo "$version"
