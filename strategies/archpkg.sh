#!/usr/bin/env bash
#
# archpkg - Detect latest version from Arch official repositories
#
# Input: package name (reads upstream config from package YAML)
# Output: pkgver of the official package, without epoch and pkgrel
#
# For AUR packages that follow the pkgver of an official package. A
# rebuild in the official repos raises only pkgrel, so it gives no new
# version here.
# upstream.archpkg: package name in official repos (e.g. "qt6-base")
# upstream.testing: true also reads core-testing, extra-testing and
#   multilib-testing

set -euo pipefail

readonly NAME="${1:?Usage: archpkg.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
archpkg_name=$(pkg_get "$pkg_file" '.upstream.archpkg // .name')
repos=(core extra multilib)
if [[ $(pkg_get "$pkg_file" '.upstream.testing') == true ]]; then
  repos+=(core-testing extra-testing multilib-testing)
fi

# The server reads a + in the query as a space, so it goes as %2B
search_url="https://archlinux.org/packages/search/json/?name=${archpkg_name//+/%2B}"
# One line per entry: repo, epoch and pkgver
entries=$(http_get "$search_url" | yq -o csv '.results[] | [.repo, .epoch, .pkgver]') || {
  echo "Failed to fetch Arch package info for ${archpkg_name}" >&2
  exit 1
}

# The newest entry of those repos by vercmp, which reads the epoch. The
# API promises no order of the entries.
found=false newest="" version=""
while IFS=, read -r repo epoch pkgver; do
  [[ " ${repos[*]} " == *" ${repo} "* ]] || continue
  found=true
  if (($(vercmp "${epoch}:${pkgver}" "$newest") > 0)); then
    newest="${epoch}:${pkgver}"
    version="$pkgver"
  fi
done <<<"$entries"

if [[ "$found" == false ]]; then
  list="${repos[*]}"
  echo "Package not found in ${list// /, }: ${archpkg_name}" >&2
  exit 1
fi

if [[ -z "$version" ]]; then
  echo "No version found for ${archpkg_name}" >&2
  exit 1
fi

echo "$version"
