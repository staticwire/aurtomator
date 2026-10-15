#!/usr/bin/env bash
#
# github-asset - Detect re-uploaded assets on a fixed GitHub release tag
#
# For releases whose tag never moves while the assets behind it get
# replaced (model zoos, rolling download tags). The version is the newest
# assets[].updated_at among the listed assets, rendered as YYYYMMDD.
#
# YAML fields:
#   upstream.project - owner/repo (required)
#   upstream.tag     - release tag that carries the assets (required)
#   upstream.assets  - list of exact asset file names (required, non-empty)
#
# The release object lists only assets in state "uploaded", so one request
# covers every downloadable asset and no pagination is needed.

set -euo pipefail

readonly NAME="${1:?Usage: github-asset.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib.sh
source "${SCRIPT_DIR}/../scripts/lib.sh"

pkg_file=$(pkg_file "$NAME")
owner_repo=$(pkg_get "$pkg_file" .upstream.project)
tag=$(pkg_get "$pkg_file" '.upstream.tag // ""')
mapfile -t assets < <(pkg_get "$pkg_file" '.upstream.assets // [] | .[]')

if [[ -z "$tag" || "$tag" == "null" ]]; then
  echo "Missing upstream.tag in package YAML" >&2
  exit 1
fi

if [[ ${#assets[@]} -eq 0 ]]; then
  echo "Missing or empty upstream.assets in package YAML" >&2
  exit 1
fi

release=$(github_api "https://api.github.com/repos/${owner_repo}/releases/tags/${tag}") || {
  echo "Failed to fetch release tag '${tag}' for ${owner_repo}" >&2
  exit 1
}

if [[ $(echo "$release" | yq -r '.assets | tag') != "!!seq" ]]; then
  echo "No release found for tag '${tag}' in ${owner_repo}" >&2
  exit 1
fi

# The asset name reaches yq through the environment so that quotes in a
# name cannot break the expression.
newest=0
for asset in "${assets[@]}"; do
  updated=$(echo "$release" |
    ASSET="$asset" yq -r '.assets[] | select(.name == strenv(ASSET)) | .updated_at')
  if [[ -z "$updated" || "$updated" == "null" ]]; then
    echo "Asset '${asset}' not found in release '${tag}' of ${owner_repo}" >&2
    exit 1
  fi
  # 2025-12-02T06:55:38Z -> 20251202
  day="${updated%%T*}"
  day="${day//-/}"
  if [[ ! "$day" =~ ^[0-9]{8}$ ]]; then
    echo "Unexpected updated_at '${updated}' for asset '${asset}'" >&2
    exit 1
  fi
  if ((day > newest)); then
    newest="$day"
  fi
done

echo "$newest"
