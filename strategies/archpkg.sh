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

set -euo pipefail

readonly NAME="${1:?Usage: archpkg.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
archpkg_name=$(pkg_get "$pkg_file" '.upstream.archpkg // .name')

result=$(http_get "https://archlinux.org/packages/search/json/?name=${archpkg_name}" |
  yq -r '.results[0]') || {
  echo "Failed to fetch Arch package info for ${archpkg_name}" >&2
  exit 1
}

if [[ -z "$result" || "$result" == "null" ]]; then
  echo "Package not found in Arch repos: ${archpkg_name}" >&2
  exit 1
fi

# Return pkgver, without epoch and pkgrel
version=$(echo "$result" | yq -r '.pkgver')

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "No version found for ${archpkg_name}" >&2
  exit 1
fi

echo "$version"
