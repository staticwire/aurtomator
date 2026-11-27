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
      _hosts)
        _clean_hosts "$file"
        continue
        ;;
      _requirements)
        _clean_requirements "$file"
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
  local line kept="" version arches re=$'^[a-z0-9][a-z0-9.+_-]*\t([^\t]+)\t([^\t]+)$'
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

# Keep the lines of _hosts file $1 that name a package and a host, split by a tab, as
# check-all.sh writes them
_clean_requirements() {
  local line kept="" LC_ALL=C re=$'^[a-z0-9][a-z0-9.+_-]*\t(python|ruby)$'
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ ! "$line" =~ $re ]] || kept+="$line"$'\n'
  done <"$1"
  printf '%s' "$kept" >"$1"
}
_clean_hosts() {
  local line kept="" LC_ALL=C re=$'^[a-z0-9][a-z0-9.+_-]*\t[a-z0-9.-]+$'
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ ! "$line" =~ $re ]] || kept+="$line"$'\n'
  done <"$1"
  printf '%s' "$kept" >"$1"
}

# Succeed when text $1 and $2 with the line of the errors left out fit in RUN_SUMMARY_MAX bytes;
# GitHub shows no summary of a step past 1 MiB
_summary_fits() {
  local LC_ALL=C
  ((${#1} + ${#2} + 100 <= ${RUN_SUMMARY_MAX:-1000000}))
}

# Print the Markdown summary of a run from status directory $1, with the errors that fit. Errors
# hold text from upstream, so they go into a code block, as in their issue.
run_summary() {
  local file name status kind total=0 current=0 rows="" blocks=() unchecked="" noun=packages head tail="" kept="" block left=0
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
        blocks+=("$(printf "\n\`%s\`: %s\n\n%s" "$name" "${kind//_/ }" "$(_code_block "${status#*: }")")"$'\n')
        ;;
    esac
  done
  ((total > 0)) || return 0
  ((total > 1)) || noun=package
  if ((current == total)); then
    printf '%s %s, all up to date.\n' "$total" "$noun"
    return 0
  fi
  head="$total $noun, $current up to date."$'\n'
  [[ -z "$rows" ]] || head+=$'\n| Package | Status |\n|---|---|\n'"$rows"
  [[ -z "$unchecked" ]] || tail=$'\n'"Not checked in this run: $unchecked."$'\n'
  for block in "${blocks[@]}"; do
    if _summary_fits "$head$kept$block" "$tail"; then
      kept+=$block
    else
      ((++left))
    fi
  done
  printf '%s%s' "$head" "$kept"
  if ((left == 1)); then
    printf '\nThe log of the step Write the run summary holds the error of 1 more package.\n'
  elif ((left > 1)); then
    printf '\nThe log of the step Write the run summary holds the errors of %s more packages.\n' "$left"
  fi
  printf '%s' "$tail"
}

# Print each whole error of the failed packages of status directory $1 to the log of the step; errors
# hold text from upstream, so workflow commands stop until a token that no upstream knows
log_errors() {
  local file status kind token=""
  for file in "$1"/*; do
    [[ -f "$file" && "${file##*/}" != _* ]] || continue
    status=$(<"$file")
    case "$status" in
      check_failed:* | update_failed:*)
        if [[ -z "$token" ]]; then
          token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
          echo "::stop-commands::$token"
        fi
        kind="${status%%:*}"
        printf '%s: %s\n%s\n\n' "${file##*/}" "${kind//_/ }" "${status#*: }"
        ;;
    esac
  done
  [[ -z "$token" ]] || echo "::$token::"
}
