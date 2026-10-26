#!/usr/bin/env bash
#
# version.sh - The version of aurtomator in VERSION and its latest release
#
# Sourced by lib.sh.

# The repository whose releases VERSION counts. VERSION is the version of
# aurtomator in a fork, a fork of a fork and a template copy alike.
AURTOMATOR_UPSTREAM=staticwire/aurtomator

# Print the version in VERSION, or nothing when the file is missing
aurtomator_version() {
  local file="${AURTOMATOR_DIR}/VERSION"
  [[ -f "$file" ]] || return 0
  printf '%s\n' "$(<"$file")"
}

# Print the version of the latest release of aurtomator, its tag without the
# v. Fails on a failed request and on a tag other than vX.Y.Z, which goes
# into the README and an issue.
latest_aurtomator_release() {
  local tag
  tag=$(github_api "https://api.github.com/repos/${AURTOMATOR_UPSTREAM}/releases/latest" | yq -r '.tag_name // ""') || return 1
  if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_err "The latest aurtomator release has the tag ${tag@Q}, not vX.Y.Z"
    return 1
  fi
  printf '%s\n' "${tag#v}"
}

# Print newer: <release> when the latest release of aurtomator is newer
# than VERSION, and current: <release> otherwise. Fails without VERSION or
# a release.
upstream_status() {
  local version release
  version=$(aurtomator_version)
  [[ -n "$version" ]] || return 1
  release=$(latest_aurtomator_release) || return 1
  if (($(vercmp "$version" "$release") < 0)); then
    printf 'newer: %s\n' "$release"
  else
    printf 'current: %s\n' "$release"
  fi
}
