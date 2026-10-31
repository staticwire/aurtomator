#!/usr/bin/env bash
#
# issue.sh - Text of the issues the update workflow opens
#
# Sourced by lib.sh.

# Body of the issue opened for a newer release of aurtomator
# Args: $1=_upstream in .status/, holding newer: and the release; $2=URL
#       of the run
# The backticks are Markdown code
# shellcheck disable=SC2016
upstream_issue_body() {
  local release
  release=$(<"$1")
  release="${release#newer: }"
  printf 'aurtomator %s is out, and this repository runs %s.\n\nRelease notes: https://github.com/%s/releases/tag/v%s\nRun: %s\n\nAuto-created by update workflow. A run closes it once the pin of the calling workflows names this release, or once a newer release is out.\n' "$release" "$(aurtomator_version)" "$AURTOMATOR_UPSTREAM" "$release" "$2"
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

# Print a text as a code block, where links, images and mentions do not
# render. The fence is longer than any run of backticks in the text, so the
# text cannot close it. A text over 4000 characters keeps its last 4000,
# where the cause of an error usually is. The job containers run in the C
# locale, where bash counts bytes, so the cut could split a character.
# Args: $1=text
_code_block() {
  local text="$1" fence='```' limit=4000
  local LC_ALL=C.UTF-8
  if ((${#text} > limit)); then
    text="[first $((${#text} - limit)) characters cut]"$'\n'"${text:${#text}-limit}"
  fi
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
