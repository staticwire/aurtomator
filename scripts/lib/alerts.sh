#!/usr/bin/env bash
#
# alerts.sh - The alerts of a package YAML
#
# Sourced by lib.sh.

# Succeeds when one alert condition fires on the step from current to the
# new version: the new version meets it and current does not. Without
# current nothing fires. A broken condition fails with or without current.
# Args: $1=when, from or match, $2=its value, $3=current, $4=new version
# Returns: 0=fires, 1=does not, 2=no condition it knows, or a match that
#          is no ERE bash accepts
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

# Prints the note of an alert. Fails when the note is not one line of
# text: the note goes into one log line and one line of _alerts.
# Args: $1=package file, $2=index of the alert
alert_note() {
  local note
  note=$(pkg_get "$1" ".alerts[$2].note | select(tag == \"!!str\")")
  [[ -n "$note" && "$note" != *[$'\n\r']* ]] || return 1
  printf '%s\n' "$note"
}

# Prints the error for a note that alert_note refuses. YAML reads a bare
# number, boolean or date as another type than text.
# Args: $1=package file, $2=index of the alert
alert_note_error() {
  local value
  value=$(pkg_get "$1" ".alerts[$2].note | select(tag == \"!!int\" or tag == \"!!float\" or tag == \"!!bool\" or tag == \"!!timestamp\")")
  printf 'note must be one line of text%s\n' "${value:+: put $value in quotes}"
}

# The alerts of a package that fire on the step from current to the new
# version, one per line in file order: hold or notice, a tab and the note.
# Fails on a rule it cannot evaluate and on a note that is not one line
# of text, which validate-pkg.sh refuses too.
# Args: $1=package file, $2=current, $3=new version
fired_alerts() {
  local file="$1" current="$2" latest="$3" count i kind value rc action note
  count=$(pkg_get "$file" '.alerts | length')
  for ((i = 0; i < count; i++)); do
    kind=$(pkg_get "$file" ".alerts[$i] | [keys[] | select(. == \"when\" or . == \"from\" or . == \"match\")] | join(\" \")")
    if [[ ! "$kind" =~ ^(when|from|match)$ ]]; then
      log_err "alerts[$i] must hold exactly one of when, from, match"
      return 1
    fi
    value=$(pkg_get "$file" ".alerts[$i].$kind")
    if [[ "$kind" == when && "$value" != major ]]; then
      log_err "alerts[$i].when must be major: $value"
      return 1
    fi
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
    action=notice
    [[ $(pkg_get "$file" ".alerts[$i].hold") != true ]] || action=hold
    printf '%s\t%s\n' "$action" "$note"
  done
}
