#!/usr/bin/env bash
#
# issue.sh - Text of the issues the update workflow opens
#
# Sourced by lib.sh.

# Body of the issue opened for a failed package. The error holds text from
# upstream, such as a rejected tag name, so it goes into a code block,
# where links, images and mentions do not render. The fence is longer than
# any run of backticks in the error, so the error cannot close it. The
# error is cut to its last 4000 characters, where the cause usually is.
# The job containers run in the C locale, where bash counts bytes, so the
# cut could split a character.
# Args: $1=status file in .status/, named after the package, holding
#       check_failed: ... or update_failed: ...; $2=URL of the run
failure_issue_body() {
  local status kind error fence='```' limit=4000
  local LC_ALL=C.UTF-8
  status=$(<"$1")
  kind="${status%%:*}"
  error="${status#*: }"
  if ((${#error} > limit)); then
    error="[first $((${#error} - limit)) characters cut]"$'\n'"${error:${#error}-limit}"
  fi
  while [[ "$error" == *"$fence"* ]]; do
    fence+='`'
  done
  # The backticks are Markdown code around the package name
  # shellcheck disable=SC2016
  printf 'Package: `%s`\nStatus: %s\nRun: %s\n\n%s\n%s\n%s\n\nAuto-created by update workflow. A run closes it when the package recovers.\n' \
    "${1##*/}" "${kind//_/ }" "$2" "$fence" "$error" "$fence"
}
