#!/usr/bin/env bash
#
# gitea-release - Detect latest version from Gitea/Forgejo/Codeberg releases
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string
#
# Works with any Gitea/Forgejo instance (codeberg.org, etc.). With
# upstream.tag_version_regex it reads the release list, up to 10 pages of
# 50 releases, in place of /releases/latest.

set -euo pipefail

readonly NAME="${1:?Usage: gitea-release.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
host=$(pkg_get "$pkg_file" .upstream.host)
owner_repo=$(pkg_get "$pkg_file" .upstream.project)
tag_version_regex=$(pkg_get "$pkg_file" '.upstream.tag_version_regex // ""')
tag_version_replace=$(pkg_get "$pkg_file" '.upstream.tag_version_replace // ""')

project="${host}/${owner_repo}"
api="https://${host}/api/v1/repos/${owner_repo}"

if [[ -z "$tag_version_regex" ]]; then
  # The newest release by date that is neither a draft nor a pre-release.
  # Gitea answers 404 when there is none, and the list tells why.
  if ! release=$(http_get_json "${api}/releases/latest"); then
    if ! releases=$(http_get_json "${api}/releases?limit=1"); then
      echo "Failed to fetch the latest release of ${project}" >&2
    elif [[ "$(yq 'length' <<<"$releases")" == 0 ]]; then
      echo "${project} has no releases; gitea-tag reads its tags" >&2
    else
      echo "${project} has no release outside drafts and pre-releases" >&2
    fi
    exit 1
  fi
  tag=$(yq -r '.tag_name' <<<"$release")
  echo "${tag#v}"
  exit 0
fi

# A repository with several products: the regex picks among the releases,
# by version as gitea-tag does
tags=""
total=0
for page in {1..10}; do
  releases=$(http_get_json "${api}/releases?limit=50&page=${page}") || {
    echo "Failed to fetch the releases of ${project}" >&2
    exit 1
  }
  count=$(yq 'length' <<<"$releases")
  ((count > 0)) || break
  total=$((total + count))
  tags+=$(yq -r '.[] | select(.draft != true and .prerelease != true) | .tag_name' <<<"$releases")$'\n'
done

if ((total == 0)); then
  echo "The release list of ${project} is empty" >&2
  exit 1
fi
if [[ -z "${tags//$'\n'/}" ]]; then
  echo "${project} has no release outside drafts and pre-releases" >&2
  exit 1
fi
latest_tag_version "$tags" "$tag_version_regex" "$tag_version_replace"
