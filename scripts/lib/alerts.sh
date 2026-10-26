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

# The alerts of a package that fire on the step from current to the new
# version, one per line in file order: hold or notice, a tab and the note.
# Fails on a rule it cannot evaluate, which validate-pkg.sh refuses too.
# Args: $1=package file, $2=current, $3=new version
fired_alerts() {
  local file="$1" current="$2" latest="$3" count i kind value rc action
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
    rc=0
    alert_fires "$kind" "$value" "$current" "$latest" || rc=$?
    if ((rc == 2)); then
      log_err "alerts[$i].match must be a non-empty ERE that bash accepts: $value"
      return 1
    fi
    ((rc == 0)) || continue
    action=notice
    [[ $(pkg_get "$file" ".alerts[$i].hold") != true ]] || action=hold
    printf '%s\t%s\n' "$action" "$(pkg_get "$file" ".alerts[$i].note")"
  done
}
