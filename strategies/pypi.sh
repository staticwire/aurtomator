#!/usr/bin/env bash
# pypi - Print the latest stable version of a package on PyPI, or the version that the newest
# release of upstream.pin_from pins it to, see https://aurtomator.dev/strategies/#pypi

set -euo pipefail

readonly NAME="${1:?Usage: pypi.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"
# shellcheck source=../scripts/lib/pep440.sh
source "${SCRIPT_DIR}/../scripts/lib/pep440.sh"
# shellcheck source=../scripts/lib/requires.sh
source "${SCRIPT_DIR}/../scripts/lib/requires.sh"

pkg_file=$(pkg_file "$NAME")
registry=$(pkg_get "$pkg_file" .upstream.registry)
pin_from=$(pkg_get "$pkg_file" '.upstream.pin_from // ""')

if [[ -n "$pin_from" ]]; then
  newest=$(http_get_json "https://pypi.org/pypi/${pin_from}/json" | yq -r '.info.version') || {
    echo "Failed to fetch PyPI info for ${pin_from}" >&2
    exit 1
  }
  if [[ ! "$newest" =~ ^[A-Za-z0-9._+!-]+$ ]]; then
    echo "No version found on PyPI for ${pin_from}" >&2
    exit 1
  fi
  headers=$(pypi_metadata "$pin_from" "$newest") || exit 1
  requires_pin "$headers" "$pin_from" "$registry"
  exit 0
fi

version=$(http_get_json "https://pypi.org/pypi/${registry}/json" | yq -r '.info.version') || {
  echo "Failed to fetch PyPI info for ${registry}" >&2
  exit 1
}

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "No version found on PyPI for ${registry}" >&2
  exit 1
fi

echo "$version"
