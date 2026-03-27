#!/usr/bin/env bash
#
# crates — Detect latest version from crates.io
#
# Input: package name (reads upstream config from package YAML)
# Output: latest stable version string
#
# upstream.registry: crate name (e.g. "serde")

set -euo pipefail

readonly NAME="${1:?Usage: crates.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TIMEOUT=30

# shellcheck source=../scripts/lib.sh
source "${SCRIPT_DIR}/../scripts/lib.sh"

pkg_file=$(pkg_file "$NAME")
registry=$(pkg_get "$pkg_file" .upstream.registry)

version=$(curl -sfL --max-time "$TIMEOUT" \
  -H "User-Agent: aurtomator/1.0" \
  "https://crates.io/api/v1/crates/${registry}" |
  yq -r '.crate.max_stable_version') || {
  echo "Failed to fetch crates.io info for ${registry}" >&2
  exit 1
}

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "No version found on crates.io for ${registry}" >&2
  exit 1
fi

echo "$version"
