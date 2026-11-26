#!/usr/bin/env bash
# crates - Print the latest version of a crate on crates.io, see
# https://aurtomator.dev/strategies/#crates

set -euo pipefail

readonly NAME="${1:?Usage: crates.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
registry=$(pkg_get "$pkg_file" .upstream.registry)
prerelease=$(pkg_bool "$pkg_file" .upstream.prerelease) || exit 1

# The sparse index states no rate limit, unlike the API with one request a second. Its path is the
# lower-case name under its first letters, as crates.io lays it out.
name=${registry,,}
case ${#name} in
  1 | 2) path="${#name}/$name" ;;
  3) path="3/${name:0:1}/$name" ;;
  *) path="${name:0:2}/${name:2:2}/$name" ;;
esac
answer=$(http_get "https://index.crates.io/$path" -w "\n%{url_effective}${HTTP_FAILURE}") || {
  echo "Failed to fetch crates.io info for ${registry}" >&2
  exit 1
}
url=${answer##*$'\n'}
answer=${answer%$'\n'*}
# Each line is the JSON of one version, and a bot check answers a page in its place
if [[ -n "$answer" && "${answer:0:1}" != "{" ]]; then
  printf '%s: the answer is not JSON\n' "$url" >&2
  request_failed "https://index.crates.io/$path"
  echo "Failed to fetch crates.io info for ${registry}" >&2
  exit 1
fi
version=$(awk 'match($0, /"vers":"[^"\\]*"/) && $0 !~ /"yanked":true/ { print substr($0, RSTART + 8, RLENGTH - 9) }' <<<"$answer" |
  semver_newest "$prerelease")

if [[ -z "$version" ]]; then
  echo "No version found on crates.io for ${registry}" >&2
  exit 1
fi

echo "$version"
