#!/usr/bin/env bash
#
# status.sh - Status labels of the package table, and the run summary
#
# Sourced by lib.sh.

# Print the label of package status $1, with the arches out $2 of the package
# at its version $3
status_label() {
  local value="${1#*: }"
  case "$1" in
    up_to_date)
      if [[ -n "${2:-}" ]]; then
        echo "⚠️ ${3:-} without $2"
      else
        echo "✅ up to date"
      fi
      ;;
    updated:*) echo "📦 updated to ${1#updated: }${2:+ without $2}" ;;
    arch_back:*) echo "✨ ${value#* } for ${value%% *} available" ;;
    arch_added:*) echo "📦 ${value#* } added to ${value%% *}" ;;
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
    unchecked:*) echo "⌛ not checked in this run" ;;
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
      _without)
        _clean_without "$file"
        continue
        ;;
      _*) continue ;;
    esac
    case "$status" in
      up_to_date | check_failed:* | update_failed:* | unchecked:*) continue ;;
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

# Keep the lines of _without file $1 that name a package, a version and arches,
# split by tabs, as check-all.sh --publish writes them
_clean_without() {
  local line kept="" version arches re=$'^[A-Za-z0-9@_+][A-Za-z0-9@._+-]*\t([^\t]+)\t([^\t]+)$'
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ $re ]] || continue
    version=${BASH_REMATCH[1]}
    arches=${BASH_REMATCH[2]}
    if arch_list_ok "$arches" && validate_pkgver "$version" 2>/dev/null; then
      kept+="$line"$'\n'
    fi
  done <"$1"
  printf '%s' "$kept" >"$1"
}

# Print the Markdown summary of a run from status directory $1. An error
# holds text from upstream, so it goes into a code block, as in its issue.
run_summary() {
  local file name status kind total=0 current=0 rows="" errors="" unchecked="" noun=packages
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
    if [[ "$status" == unchecked:* ]]; then
      unchecked+="${unchecked:+, }\`$name\`"
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
  printf '%s %s, %s up to date.\n' "$total" "$noun" "$current"
  [[ -z "$rows" ]] || printf '\n| Package | Status |\n|---|---|\n%s%s' "$rows" "$errors"
  [[ -z "$unchecked" ]] || printf '\nNot checked in this run: %s.\n' "$unchecked"
}
