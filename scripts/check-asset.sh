#!/usr/bin/env bash
#
# check-asset.sh - Find the value that a release asset name holds for a version
#
# For a package with upstream.asset_regex: finds the tag of the version
# among the tags of upstream.project, reads the GitHub release of that tag
# and matches the regex against the names of its assets. Exactly one name
# has to match, and its first capture group is the value.
#
# A tag shows before its release: upstream can keep the release a draft
# while it uploads the assets, and the API lists a draft only to users who
# can push. A missing asset is pending for a day after the release was
# published, and a missing release for a day after the date of the tagged
# commit.
#
# Usage: ./scripts/check-asset.sh <package-name> <pkgver>
#
# Exit codes: 0 the value is on stdout, 1 failed, 3 pending

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq

readonly PKG_NAME="${1:?Usage: check-asset.sh <package-name> <pkgver>}"
readonly PKGVER="${2:?Usage: check-asset.sh <package-name> <pkgver>}"
PKG_FILE="$(pkg_file "$PKG_NAME")"
readonly PKG_FILE

# How long a release or an asset may be missing, in seconds
readonly ASSET_WAIT=$((24 * 3600))

project=$(pkg_get "$PKG_FILE" '.upstream.project // ""')
regex=$(pkg_get "$PKG_FILE" '.upstream.tag_version_regex // ""')
replace=$(pkg_get "$PKG_FILE" '.upstream.tag_version_replace // ""')
asset_regex=$(pkg_get "$PKG_FILE" '.upstream.asset_regex // ""')
dash=$(pkgver_dash "$PKG_FILE")
format=$(pkg_get "$PKG_FILE" '.pkgver_format // ""')

if [[ -z "$asset_regex" ]]; then
  log_err "$PKG_NAME has no upstream.asset_regex"
  exit 1
fi

# Percent-encode a tag for the path of an API URL, byte by byte, keeping /
# Args: $1=tag
url_path() {
  local LC_ALL=C tag="$1" out="" c i
  for ((i = 0; i < ${#tag}; i++)); do
    c="${tag:i:1}"
    if [[ "$c" != [A-Za-z0-9._~/-] ]]; then
      printf -v c '%%%02X' "'$c"
    fi
    out+="$c"
  done
  printf '%s\n' "$out"
}

# Exit with 3 while a date of the GitHub API lies less than ASSET_WAIT back,
# and with 1 after that, with the reason on stderr
# Args: $1=date, as 2026-10-09T16:57:18Z, $2=what is missing
wait_or_fail() {
  if [[ ! "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    log_err "Unexpected date from the GitHub API: ${1@Q}"
    exit 1
  fi
  if (($(date -u +%s) - $(date -u -d "$1" +%s) < ASSET_WAIT)); then
    log_warn "$PKG_NAME $PKGVER: $2, pending for $((ASSET_WAIT / 3600)) h from $1"
    exit 3
  fi
  log_err "$PKG_NAME $PKGVER: $2, $((ASSET_WAIT / 3600)) h after $1"
  exit 1
}

# The tag of the version: the tags that the strategy reads, turned into a
# pkgver as check-update.sh turns the version of the strategy
tags=$(github_tags "$project") || {
  log_err "Failed to fetch tags for ${project}"
  exit 1
}
mapfile -t all_tags <<<"$tags"
found=()
for tag in "${all_tags[@]}"; do
  version=$(tag_versions "$regex" "$replace" <<<"$tag")
  if [[ "$(to_pkgver "$version" "$dash" "$format")" == "$PKGVER" ]]; then
    found+=("$tag")
  fi
done
if ((${#found[@]} == 0)); then
  log_err "No tag of ${project} gives version ${PKGVER}"
  exit 1
fi
if ((${#found[@]} > 1)); then
  log_err "Tags ${found[*]} of ${project} all give version ${PKGVER}"
  exit 1
fi
tag="${found[0]}"

api="https://api.github.com/repos/${project}"
err_file=$(mktemp)
trap 'rm -f "$err_file"' EXIT

# GitHub answers 404 for a tag without a release and for a draft
if ! release=$(github_api "${api}/releases/tags/$(url_path "$tag")" 2>"$err_file"); then
  if [[ "$(<"$err_file")" != *"returned error: 404" ]]; then
    cat "$err_file" >&2
    log_err "Failed to read the release of tag ${tag} of ${project}"
    exit 1
  fi
  commit=$(github_api "${api}/commits/$(url_path "$tag")") || {
    log_err "Failed to read the commit of tag ${tag} of ${project}"
    exit 1
  }
  wait_or_fail "$(yq -r '.commit.committer.date // ""' <<<"$commit")" "tag ${tag} has no release"
fi

published=$(yq -r '.published_at // ""' <<<"$release")
mapfile -t names < <(yq -r '.assets[].name' <<<"$release")
matches=()
values=()
for name in "${names[@]}"; do
  if [[ "$name" =~ $asset_regex ]]; then
    matches+=("$name")
    values+=("${BASH_REMATCH[1]}")
  fi
done
if ((${#matches[@]} > 1)); then
  log_err "${#matches[@]} assets of release ${tag} match upstream.asset_regex, expected one: ${matches[*]}"
  exit 1
fi
if ((${#matches[@]} == 0)); then
  wait_or_fail "$published" "no asset of release ${tag} matches upstream.asset_regex; its assets: ${names[*]}"
fi
validate_asset_value "${values[0]}" || exit 1
printf '%s\n' "${values[0]}"
