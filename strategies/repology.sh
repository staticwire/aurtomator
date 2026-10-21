#!/usr/bin/env bash
#
# repology - Detect latest version via Repology API
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string
#
# upstream.repology: project name on repology.org (e.g. "firefox")

set -euo pipefail

readonly NAME="${1:?Usage: repology.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib.sh
source "${SCRIPT_DIR}/../scripts/lib.sh"

pkg_file=$(pkg_file "$NAME")
repology_name=$(pkg_get "$pkg_file" '.upstream.repology // .name')

# Repology returns an array of package entries from various repos.
# Filter for "newest" status to get the latest upstream version.
version=$(http_get "https://repology.org/api/v1/project/${repology_name}" \
  -H "User-Agent: aurtomator/1.0" |
  yq -r '[.[] | select(.status == "newest")] | .[0].version') || {
  echo "Failed to fetch Repology info for ${repology_name}" >&2
  exit 1
}

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "No version found on Repology for ${repology_name}" >&2
  exit 1
fi

echo "$version"
