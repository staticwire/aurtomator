#!/usr/bin/env bash
#
# stats.sh - The event journal of the packages, stats/events.csv
#
# Sourced by lib.sh.

# The first line of the journal, and the pattern of every line after it
STATS_HEADER='time,package,event,version,previous,run'
STATS_ROW_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z,[A-Za-z0-9@_+][A-Za-z0-9@._+-]*,(tracked|added|removed|updated|downgrade|rebuilt|held|jump_skipped|downgrade_skipped|pending|check_failed|update_failed|up_to_date),[A-Za-z0-9._+]*,[A-Za-z0-9._+]*,[0-9]*$'

# Print the rows of journal $1 without its header, and warn of each line
# that is not a row. Returns: 1 when the first line is not the header
stats_rows() {
  local file="$1" n
  if [[ "$(head -n 1 -- "$file" 2>/dev/null)" != "$STATS_HEADER" ]]; then
    log_warn "$file does not start with the line $STATS_HEADER"
    return 1
  fi
  while read -r n; do
    log_warn "line $n of $file is not a journal row"
  done < <(LC_ALL=C awk -v re="$STATS_ROW_RE" 'NR > 1 && $0 !~ re { print NR }' "$file")
  LC_ALL=C awk -v re="$STATS_ROW_RE" 'NR > 1 && $0 ~ re' "$file"
}

# Print the package, event and version of the last row of each package in
# journal $1, and the version of its last row that is not a wait, by name
stats_last_states() {
  stats_rows "$1" | LC_ALL=C awk -F, '
    { event[$2] = $3; version[$2] = $4 }
    $3 !~ /^(held|jump_skipped|downgrade_skipped|pending)$/ { current[$2] = $4 }
    END { for (p in event) print p "\t" event[p] "\t" version[p] "\t" current[p] }' | LC_ALL=C sort
}

# Print the class of event $1: ok, or the event itself for a wait, a
# failure and removed
stats_class() {
  case "$1" in
    tracked | added | up_to_date | updated | downgrade | rebuilt) echo ok ;;
    *) echo "$1" ;;
  esac
}

# Print the event and version of final status $1 of a package at version $2,
# nothing for a status a run publishes later. Returns: 1 for another status
stats_event() {
  local status="$1" current="$2" event version
  local LC_ALL=C
  [[ "$current" =~ ^[A-Za-z0-9._+]+$ ]] || current=""
  case "$status" in
    up_to_date) event=up_to_date version="$current" ;;
    check_failed:* | update_failed:*) event="${status%%:*}" version="$current" ;;
    "updated: "* | "downgrade: "* | "rebuilt: "* | "held: "* | "jump_skipped: "* | "downgrade_skipped: "* | "pending: "*)
      event="${status%%: *}" version="${status#*: }"
      [[ "$version" =~ ^[A-Za-z0-9._+]+$ ]] || return 1
      ;;
    "new_version: "* | "available_downgrade: "* | "new_build: "*) return 0 ;;
    *) return 1 ;;
  esac
  printf '%s\t%s\n' "$event" "$version"
}
