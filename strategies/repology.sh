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

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
repology_name=$(pkg_get "$pkg_file" '.upstream.repology // .name')

# Repology returns an array of package entries from various repos, and
# an empty array for a project it does not know.
entries=$(http_get "https://repology.org/api/v1/project/${repology_name}") || {
  echo "Failed to fetch Repology info for ${repology_name}" >&2
  exit 1
}

if [[ $(yq -r 'length' <<<"$entries") == 0 ]]; then
  echo "Project ${repology_name} not found on Repology" >&2
  exit 1
fi

# The AUR entries are left out: for a package of ours, they hold our own
# version. Without a newest entry elsewhere, the AUR alone is ahead, and
# the highest outdated entry is what the other repositories have.
version=$(yq -r '[.[] | select(.repo != "aur" and .status == "newest")] | .[0].version' <<<"$entries")
if [[ "$version" == "null" ]]; then
  version=$(yq -r '.[] | select(.repo != "aur" and .status == "outdated") | .version' <<<"$entries" | newest_version)
fi

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "No version found on Repology for ${repology_name} outside the AUR" >&2
  exit 1
fi

echo "$version"
