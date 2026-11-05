#!/usr/bin/env bash
#
# issue.sh - Text of the issues the update workflow opens, and the hosts
# whose failed checks share one
#
# Sourced by lib.sh.

# Body of the issue opened for a newer release of aurtomator
# Args: $1=_upstream in .status/, holding newer: and the release; $2=URL
#       of the run
upstream_issue_body() {
  local release
  release=$(<"$1")
  release="${release#newer: }"
  printf 'aurtomator %s is out, and this repository runs %s.\n\nTo update: Insights > Dependency graph > Dependabot > Check for updates. Dependabot opens the pull request that moves the pin.\n\nRelease notes: https://github.com/%s/releases/tag/v%s\nManual update: https://github.com/%s/blob/main/docs/SETUP.md#the-calling-workflows\nRun: %s\n\nAuto-created by update workflow. A run closes it once the pin of the calling workflows names this release, or once a newer release is out.\n' "$release" "$(aurtomator_version)" "$AURTOMATOR_UPSTREAM" "$release" "$AURTOMATOR_UPSTREAM" "$2"
}

# Body of the issue opened for an update an alert fired on: a held update,
# or a published one with a notice. The notes come from _alerts, which
# check-all.sh writes next to the status file, one line per fired alert:
# the package, hold or notice, and the note, split by tabs. The version is
# a checked pkgver, so a code span holds it.
# Args: $1=status file in .status/, named after the package, holding
#       held:, updated: or downgrade: and the version; $2=URL of the run
# The backticks are Markdown code
# shellcheck disable=SC2016
alert_issue_body() {
  local status package notes state=Published footer="Close it once the edit is done."
  status=$(<"$1")
  package="${1##*/}"
  notes=$(awk -F'\t' -v p="$package" '$1 == p { sub(/^[^\t]*\t[^\t]*\t/, ""); print "- " $0 }' "${1%/*}/_alerts" 2>/dev/null) || true
  if [[ "$status" == held:* ]]; then
    state=Held
    footer='Publish the version by hand after the edit and set `current` in the package YAML to it. The next run closes this issue.'
  fi
  printf 'Package: `%s`\n%s version: `%s`\nRun: %s\n\n%s\n\nAuto-created by update workflow. %s\n' "$package" "$state" "${status#*: }" "$2" "$notes" "$footer"
}

# Print text $1 as a code block, where links, images and mentions do not
# render. A longer text keeps its last $2 characters, 4000 by default.
_code_block() {
  local text="$1" fence='```' limit="${2:-4000}"
  # In the C locale of the job containers, bash counts bytes
  local LC_ALL=C.UTF-8
  if ((${#text} > limit)); then
    text="[first $((${#text} - limit)) characters cut]"$'\n'"${text:${#text}-limit}"
  fi
  # No run of backticks in the text can close a longer fence
  while [[ "$text" == *"$fence"* ]]; do
    fence+='`'
  done
  printf '%s\n%s\n%s\n' "$fence" "$text" "$fence"
}

# Body of the issue opened for a failed package. The error holds text from
# upstream, such as a rejected tag name, so it goes into a code block.
# Args: $1=status file in .status/, named after the package, holding
#       check_failed: ... or update_failed: ...; $2=URL of the run
failure_issue_body() {
  local status kind
  status=$(<"$1")
  kind="${status%%:*}"
  # The backticks are Markdown code around the package name
  # shellcheck disable=SC2016
  printf 'Package: `%s`\nStatus: %s\nRun: %s\n\n%s\n\nAuto-created by update workflow. A run closes it when the package recovers.\n' \
    "${1##*/}" "${kind//_/ }" "$2" "$(_code_block "${status#*: }")"
}

# Comment of an issue that a run closes. The status can hold the error of a
# failure, so it goes into a code block as that error does.
# Args: $1=status file in .status/, named after the package; $2=URL of the
#       run
close_comment() {
  local status
  status=$(<"$1")
  # The backticks are Markdown code around the package name
  # shellcheck disable=SC2016
  printf 'The status of `%s` in %s:\n\n%s\n' "${1##*/}" "$2" "$(_code_block "$status")"
}

# The packages of one host whose checks failed in a run share one issue
# from this count on
HOST_ISSUE_MIN=5

# Print the host, in lower case and without the port, of the first URL in
# check_failed status file $1: the URL that http_get or git failed on
failure_host() {
  local status
  status=$(<"$1")
  if [[ "$status" == check_failed:* && "$status" =~ https?://([A-Za-z0-9.-]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1],,}"
  fi
}

# Print each host with HOST_ISSUE_MIN or more failed checks in status
# directory $1, and its packages, on a line split by spaces
failed_hosts() {
  local file host list
  local -A packages=()
  for file in "$1"/*; do
    [[ -f "$file" ]] || continue
    host=$(failure_host "$file")
    [[ -z "$host" ]] || packages[$host]+=" ${file##*/}"
  done
  for host in "${!packages[@]}"; do
    read -ra list <<<"${packages[$host]}"
    if ((${#list[@]} >= HOST_ISSUE_MIN)); then
      printf '%s%s\n' "$host" "${packages[$host]}"
    fi
  done | LC_ALL=C sort
}

# Print the issue body for host $2, run URL $3 and packages $4... of status
# directory $1. Errors share 50000 of the 65536 characters GitHub accepts.
host_issue_body() {
  local dir="$1" host="$2" url="$3" package status limit
  shift 3
  limit=$((50000 / $#))
  ((limit <= 4000)) || limit=4000
  # The backticks are Markdown code around the host and the package names
  # shellcheck disable=SC2016
  printf 'Host: `%s`\nStatus: check failed\nRun: %s\n' "$host" "$url"
  for package in "$@"; do
    status=$(<"$dir/$package")
    # shellcheck disable=SC2016
    printf '\nPackage: `%s`\n\n%s\n' "$package" "$(_code_block "${status#*: }" "$limit")"
  done
  printf '\nAuto-created by update workflow. A run closes it when fewer than %s packages of the host fail to check.\n' "$HOST_ISSUE_MIN"
}

# Print the comment for host $1 and run URL $2 on a host issue a run closes
host_close_comment() {
  # The backticks are Markdown code around the host
  # shellcheck disable=SC2016
  printf 'Fewer than %s packages of `%s` failed to check in %s.\n' "$HOST_ISSUE_MIN" "$1" "$2"
}
