#!/usr/bin/env bash
#
# status.sh - Status labels of the package table, and the run summary
#
# Sourced by lib.sh.

# Print the label of package status $1
status_label() {
  case "$1" in
    up_to_date) echo "✅ up to date" ;;
    updated:*) echo "📦 updated to ${1#updated: }" ;;
    new_version:*) echo "✨ ${1#new_version: } available" ;;
    downgrade:*) echo "🔻 downgraded to ${1#downgrade: }" ;;
    available_downgrade:*) echo "🔻 ${1#available_downgrade: } available (downgrade)" ;;
    downgrade_skipped:*) echo "🔻 ${1#downgrade_skipped: } skipped (downgrade)" ;;
    jump_skipped:*) echo "🔺 ${1#jump_skipped: } skipped (version jump)" ;;
    held:*) echo "✋ ${1#held: } held" ;;
    new_build:*) echo "🔨 ${1#new_build: } rebuild available" ;;
    rebuilt:*) echo "🔨 ${1#rebuilt: } rebuilt" ;;
    pending:*) echo "⏳ ${1#pending: } pending" ;;
    cooldown:*) echo "💤 next update ${1#cooldown: }" ;;
    check_failed:* | update_failed:*) echo "❌ failed" ;;
    *) echo "✅ tracking" ;;
  esac
}

# Check the statuses in directory $1 as --publish of check-all.sh does: a
# status it would refuse becomes a check failure, a refused _upstream goes
clean_statuses() {
  local file status
  for file in "$1"/*; do
    [[ -f "$file" ]] || continue
    status=$(<"$file")
    case "${file##*/}" in
      _upstream)
        [[ "$status" =~ ^(newer|current):\ [0-9]+\.[0-9]+\.[0-9]+$ ]] || rm -f -- "$file"
        continue
        ;;
      _*) continue ;;
    esac
    case "$status" in
      up_to_date | check_failed:* | update_failed:*) continue ;;
      "cooldown: "*) ! valid_date "${status#cooldown: }" || continue ;;
      "updated: "* | "downgrade: "* | "rebuilt: "* | "new_version: "* | "available_downgrade: "* | "new_build: "* | \
        "downgrade_skipped: "* | "jump_skipped: "* | "held: "* | "pending: "*)
        ! validate_pkgver "${status#*: }" 2>/dev/null || continue
        ;;
      "arch_back: "* | "arch_added: "*)
        ! arch_status_version "${status#*: }" >/dev/null || continue
        ;;
    esac
    echo "check_failed: invalid status from the check run" >"$file"
  done
}

# Print the Markdown summary of a run from status directory $1. An error
# holds text from upstream, so it goes into a code block, as in its issue.
run_summary() {
  local file name status kind total=0 current=0 rows="" errors="" noun=packages
  for file in "$1"/*; do
    [[ -f "$file" ]] || continue
    name="${file##*/}"
    [[ "$name" != _* ]] || continue
    status=$(<"$file")
    ((++total))
    if [[ "$status" == up_to_date ]]; then
      ((++current))
      continue
    fi
    rows+=$(printf "| \`%s\` | %s |" "$name" "$(status_label "$status")")$'\n'
    case "$status" in
      check_failed:* | update_failed:*)
        kind="${status%%:*}"
        errors+=$(printf "\n\`%s\`: %s\n\n%s" "$name" "${kind//_/ }" "$(_code_block "${status#*: }")")$'\n'
        ;;
    esac
  done
  ((total > 0)) || return 0
  ((total > 1)) || noun=package
  if ((current == total)); then
    printf '%s %s, all up to date.\n' "$total" "$noun"
    return 0
  fi
  printf '%s %s, %s up to date.\n\n| Package | Status |\n|---|---|\n%s%s' "$total" "$noun" "$current" "$rows" "$errors"
}
