#!/usr/bin/env bash
#
# alerts.sh - The alerts of a package YAML
#
# Sourced by lib.sh.

# Succeeds when one alert condition fires on the step from current to the new version: the new
# version meets it and current does not, and without current nothing fires
# Args: $1=when, from or match, $2=its value, $3=current, $4=new version
# Returns: 0=fires, 1=does not, 2=an unknown condition or a match bash cannot compile, with or
#          without current
alert_fires() {
  local kind="$1" value="$2" current="$3" latest="$4" old new
  [[ "$kind" =~ ^(when|from|match)$ ]] || return 2
  [[ "$kind" != match ]] || ere_valid "$value" || return 2
  [[ -n "$current" ]] || return 1
  case "$kind" in
    when)
      [[ "$current" =~ [0-9]+ ]] || return 1
      old="${BASH_REMATCH[0]}"
      [[ "$latest" =~ [0-9]+ ]] || return 1
      new="${BASH_REMATCH[0]}"
      (($(vercmp "$new" "$old") > 0))
      ;;
    from)
      (($(vercmp "$current" "$value") < 0 && $(vercmp "$latest" "$value") >= 0))
      ;;
    *) [[ "$latest" =~ $value && ! "$current" =~ $value ]] ;;
  esac
}

# Print the note of alert $2 of package file $1; fails when it is not one line of text without tabs,
# since it goes into one log line and one line of _alerts, whose fields tabs separate
alert_note() {
  local note
  note=$(pkg_get "$1" ".alerts[$2].note | select(tag == \"!!str\")")
  [[ -n "$note" && "$note" != *$'\t'* ]] && ! has_control "$note" || return 1
  printf '%s\n' "$note"
}

# Print the error for a note of alert $2 of package file $1 that alert_note refuses; YAML reads
# a bare number, boolean or date as another type than text
alert_note_error() {
  local value
  if [[ "$(pkg_get "$1" ".alerts[$2].note | select(tag == \"!!str\")")" == *$'\t'* ]]; then
    echo 'note must be one line of text without tabs'
    return
  fi
  value=$(pkg_get "$1" ".alerts[$2].note | select(tag == \"!!int\" or tag == \"!!float\" or tag == \"!!bool\" or tag == \"!!timestamp\")")
  printf 'note must be one line of text%s\n' "${value:+: put $value in quotes}"
}

# Print the notes of rule unmet for version $2 of package file $1, as python_unmet does, nothing for
# a package the AUR lacks; without a run cache, one of its own
alert_unmet() {
  local name srcinfo rc=0 out
  name=$(package_name "$1") || return 1
  if [[ -z "${AURTOMATOR_RUN_CACHE:-}" ]]; then
    local -x AURTOMATOR_RUN_CACHE
    AURTOMATOR_RUN_CACHE=$(mktemp -d) || return 1
    out=$(alert_unmet "$@") || rc=$?
    rm -rf "$AURTOMATOR_RUN_CACHE"
    [[ -z "$out" ]] || printf '%s\n' "$out"
    return "$rc"
  fi
  srcinfo=$(aur_srcinfo "$name") || rc=$?
  ((rc != 3)) || return 0
  ((rc == 0)) || return 1
  python_unmet "$1" "$srcinfo" "$(pkg_get "$1" .upstream.registry)" "$2"
}

# Print the alerts of package file $1 that fire from current $2 to version $3 in file order, as hold or
# notice, a tab and the note; fail on a broken rule. $4 offline skips requires rules, held those without hold
fired_alerts() {
  local file="$1" current="$2" latest="$3" offline="${4:-}" count i kind value rc action note change hold joined
  count=$(pkg_get "$file" '.alerts | length')
  for ((i = 0; i < count; i++)); do
    kind=$(pkg_get "$file" ".alerts[$i] | [keys[] | select(. == \"when\" or . == \"from\" or . == \"match\" or . == \"requires\")] | join(\" \")")
    if [[ ! "$kind" =~ ^(when|from|match|requires)$ ]]; then
      log_err "alerts[$i] must hold exactly one of when, from, match, requires"
      return 1
    fi
    value=$(pkg_get "$file" ".alerts[$i].$kind")
    hold=$(pkg_bool "$file" ".alerts[$i].hold")
    if [[ "$kind" == when && "$value" != major ]]; then
      log_err "alerts[$i].when must be major, got $value"
      return 1
    fi
    if [[ "$kind" == requires ]]; then
      if [[ "$value" != changed && "$value" != unmet ]]; then
        log_err "alerts[$i].requires must be changed or unmet, got $value"
        return 1
      fi
      if [[ $(pkg_get "$file" .strategy) != pypi ]]; then
        log_err "alerts[$i].requires applies to the pypi strategy only"
        return 1
      fi
      note=""
      if [[ $(pkg_get "$file" ".alerts[$i] | has(\"note\")") == true ]] && ! note=$(alert_note "$file" "$i"); then
        log_err "alerts[$i].$(alert_note_error "$file" "$i")"
        return 1
      fi
      # unmet reads no current, so prepare and publish take its lines from the check run
      if [[ "$value" == unmet ]]; then
        [[ -z "$offline" ]] || continue
        change=$(alert_unmet "$file" "$latest") || return 1
        [[ -n "$change" ]] || continue
        action=notice
        [[ "$hold" != true || $'\n'"$change" != *$'\nhold\t'* ]] || action=hold
        joined=""
        while IFS=$'\t' read -r _ change; do
          joined+="${joined:+; }$change"
        done <<<"$change"
        printf '%s\t%s\n' "$action" "${note:+$note: }$joined"
        continue
      fi
      [[ -n "$current" && "$offline" != offline ]] || continue
      [[ "$offline" != held || "$hold" == true ]] || continue
      change=$(requires_change "$file" "$current" "$latest") || return 1
      [[ -n "$change" ]] || continue
      note="${note:+$note: }$change"
    else
      if ! note=$(alert_note "$file" "$i"); then
        log_err "alerts[$i].$(alert_note_error "$file" "$i")"
        return 1
      fi
      rc=0
      alert_fires "$kind" "$value" "$current" "$latest" || rc=$?
      if ((rc == 2)); then
        log_err "alerts[$i].match must be a non-empty ERE that bash accepts: $value"
        return 1
      fi
      ((rc == 0)) || continue
    fi
    action=notice
    [[ "$hold" != true ]] || action=hold
    [[ "$offline" != held || "$action" == hold ]] || continue
    printf '%s\t%s\n' "$action" "$note"
  done
}
