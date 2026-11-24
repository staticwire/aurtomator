#!/usr/bin/env bash
# rubygems - Print the newest stable version of a gem on rubygems.org for the platform ruby, see
# https://aurtomator.dev/strategies/#rubygems

set -euo pipefail

readonly NAME="${1:?Usage: rubygems.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"
# shellcheck source=../scripts/lib/gemver.sh
source "${SCRIPT_DIR}/../scripts/lib/gemver.sh"

pkg_file=$(pkg_file "$NAME")
registry=$(pkg_get "$pkg_file" .upstream.registry)
if ! (LC_ALL=C && [[ "$registry" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]); then
  echo "upstream.registry must be a gem name of A-Za-z0-9._- that starts with a letter or digit: ${registry@Q}" >&2
  exit 1
fi

json=$(http_get_json "https://rubygems.org/api/v1/versions/${registry}.json") || {
  echo "Failed to fetch rubygems.org versions for ${registry}" >&2
  exit 1
}

# Gems list each release once per platform, and their pre-releases hold a letter
best=""
while IFS= read -r version; do
  gem_version_valid "$version" || continue
  if [[ -z "$best" ]] || { gem_cmp "$version" "$best" && ((GEM_ORDER > 0)); }; then
    best=$version
  fi
done < <(yq -r '.[] | select(.prerelease == false and .platform == "ruby") | .number | select(tag == "!!str")' <<<"$json")

if [[ -z "$best" ]]; then
  echo "No stable version of ${registry} on rubygems.org" >&2
  exit 1
fi

echo "$best"
