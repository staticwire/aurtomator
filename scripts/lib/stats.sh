#!/usr/bin/env bash
#
# stats.sh - The event journal of the packages, stats/events.csv
#
# Sourced by lib.sh.

# The first line of the journal, and the pattern of every line after it
STATS_HEADER='time,package,event,version,previous,run'
STATS_ROW_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z,[A-Za-z0-9@_+][A-Za-z0-9@._+-]*,(tracked|added|removed|updated|downgrade|rebuilt|arch_added|held|jump_skipped|downgrade_skipped|pending|check_failed|update_failed|up_to_date)'",[A-Za-z0-9._+]{0,$PKGVER_MAX},[A-Za-z0-9._+]{0,$PKGVER_MAX},[0-9]*\$"

# Fails, with the reason on stderr, when journal $1 or its directory is a
# link, or the journal is there and no regular file
stats_journal_ok() {
  local dir
  dir=$(dirname -- "$1")
  if [[ -L "$dir" || (-e "$dir" && ! -d "$dir") ]]; then
    log_err "$dir is a link or no directory, so it holds no journal"
    return 1
  fi
  if [[ -L "$1" || (-e "$1" && ! -f "$1") ]]; then
    log_err "$1 is a link or no regular file, so it is no journal"
    return 1
  fi
}

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

# Print package,event,version,current per package of journal $1, sorted:
# its last row, and the version of its last row that is not a wait
stats_last_states() {
  stats_rows "$1" | LC_ALL=C awk -F, '
    { event[$2] = $3; version[$2] = $4 }
    $3 !~ /^(held|jump_skipped|downgrade_skipped|pending)$/ { current[$2] = $4 }
    END { for (p in event) print p "," event[p] "," version[p] "," current[p] }' | LC_ALL=C sort
}

# Print the class of event $1: ok, or the event itself for a wait, a
# failure and removed
stats_class() {
  case "$1" in
    tracked | added | up_to_date | updated | downgrade | rebuilt | arch_added) echo ok ;;
    *) echo "$1" ;;
  esac
}

# Print event,version of final status $1 of a package at version $2, and
# nothing for a status a later run publishes. Returns: 1 for other statuses
stats_event() {
  local status="$1" current="$2" event version
  local LC_ALL=C
  [[ "$current" =~ ^[A-Za-z0-9._+]{1,$PKGVER_MAX}$ ]] || current=""
  case "$status" in
    up_to_date | "cooldown: "*) event=up_to_date version="$current" ;;
    check_failed:* | update_failed:*) event="${status%%:*}" version="$current" ;;
    "updated: "* | "downgrade: "* | "rebuilt: "* | "held: "* | "jump_skipped: "* | "downgrade_skipped: "* | "pending: "*)
      event="${status%%: *}" version="${status#*: }"
      [[ "$version" =~ ^[A-Za-z0-9._+]{1,$PKGVER_MAX}$ ]] || return 1
      ;;
    "arch_added: "*)
      event=arch_added
      version=$(arch_status_version "${status#arch_added: }") || return 1
      ;;
    "new_version: "* | "available_downgrade: "* | "new_build: "* | "arch_back: "*) return 0 ;;
    *) return 1 ;;
  esac
  printf '%s,%s\n' "$event" "$version"
}

# Print the numbers of the card from journal $1 on day $2, YYYY-MM-DD, by
# the days back from $2 that a row is dated: 0 for $2, rows after it unread
stats_numbers() {
  stats_rows "$1" | LC_ALL=C gawk -F, -v date="$2" '
    function day(d) { return mktime(substr(d, 1, 4) " " substr(d, 6, 2) " " substr(d, 9, 2) " 0 0 0", 1) / 86400 }
    function count(name, i) { for (i = 1; i <= 3; i++) if (age < window[i]) n[name, i]++ }
    BEGIN { today = day(date); split("7 30 365", window, " ") }
    {
      age = today - day($1)
      if (age < 0) next
      if (!(first > age)) first = age
      last[$2] = $3
      if ($3 ~ /^(updated|downgrade|rebuilt|arch_added)$/) {
        count("pushes")
        pushes[age]++
        for (i = 1; i <= 3; i++) if (age < window[i] && !((i, $2) in pushed)) { pushed[i, $2]; n["packages", i]++ }
      } else if ($3 == "added") count("added")
      else if ($3 ~ /_failed$/) count("failed")
    }
    END {
      split("pushes packages added failed", names, " ")
      for (j = 1; j <= 4; j++) printf "%s %d %d %d\n", names[j], n[names[j], 1], n[names[j], 2], n[names[j], 3]
      for (p in last) failing += last[p] ~ /_failed$/
      printf "failing %d\n", failing
      if (first != "") printf "first %d\n", first
      for (age = 0; age <= 370; age++) if (age in pushes) printf "day %d %d\n", age, pushes[age]
    }'
}
