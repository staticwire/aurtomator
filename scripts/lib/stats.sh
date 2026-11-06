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
