#!/usr/bin/env bash
# repology - Print the newest version that Repology knows outside the AUR, see
# https://aurtomator.dev/strategies/#repology

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
entries=$(http_get_json "https://repology.org/api/v1/project/${repology_name}") || {
  echo "Failed to fetch Repology info for ${repology_name}" >&2
  exit 1
}

if [[ $(yq -r 'length' <<<"$entries") == 0 ]]; then
  echo "Project ${repology_name} not found on Repology" >&2
  exit 1
fi

# The AUR entries hold the version of this package, so they are left out; without a newest
# entry elsewhere, the highest outdated entry is what the other repositories have
version=$(yq -r '[.[] | select(.repo != "aur" and .status == "newest")] | .[0].version' <<<"$entries")
if [[ "$version" == "null" ]]; then
  version=$(yq -r '.[] | select(.repo != "aur" and .status == "outdated") | .version' <<<"$entries" | newest_version)
fi

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "No version found on Repology for ${repology_name} outside the AUR" >&2
  exit 1
fi

echo "$version"
