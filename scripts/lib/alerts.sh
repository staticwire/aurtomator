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

# Print the alerts of package file $1 that fire from current $2 to version $3 in file order, as hold or
# notice, a tab and the note; fail on a broken rule. $4 offline skips requires rules, held those without hold.
# The requires rules run for each package whose AUR depends hold Python, as notices unless the file lists them.
fired_alerts() {
  local rc=0
  if [[ -n "${AURTOMATOR_RUN_CACHE:-}" ]]; then
    _fired_alerts "$@"
    return
  fi
  local -x AURTOMATOR_RUN_CACHE
  AURTOMATOR_RUN_CACHE=$(mktemp -d) || return 1
  _fired_alerts "$@" || rc=$?
  rm -rf "$AURTOMATOR_RUN_CACHE"
  return "$rc"
}

_fired_alerts() {
  local file="$1" current="$2" latest="$3" offline="${4:-}" count i kind value rc action note change hold
  local -A listed=()
  PY_STATE=""
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
      if [[ "$value" != changed && "$value" != unmet && "$value" != imports ]]; then
        log_err "alerts[$i].requires must be changed, unmet or imports, got $value"
        return 1
      fi
      if [[ $(pkg_get "$file" .strategy) != pypi && -z "$(pkg_get "$file" '.python.pypi // .python.pyproject // ""' 2>/dev/null)" ]]; then
        log_err "alerts[$i].requires needs strategy pypi, python.pypi or python.pyproject"
        return 1
      fi
      note=""
      if [[ $(pkg_get "$file" ".alerts[$i] | has(\"note\")") == true ]] && ! note=$(alert_note "$file" "$i"); then
        log_err "alerts[$i].$(alert_note_error "$file" "$i")"
        return 1
      fi
      listed[$value]=1
      _fired_python "$value" "$hold" "$note" || return 1
      continue
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
    [[ "$hold" != true ]] || action=hold
    [[ "$offline" != held || "$action" == hold ]] || continue
    printf '%s\t%s\n' "$action" "$note"
  done
  for value in changed unmet imports; do
    [[ -n "${listed[$value]:-}" ]] || _fired_python "$value" "" "" || return 1
  done
}

# Print the line of requires rule $1, with hold $2 and note $3, for the call of _fired_alerts that
# runs it: changed reads current, so prepare runs it with hold alone; unmet and imports run in the check
_fired_python() {
  local value=$1 hold=$2 note=$3 change action joined
  [[ "$offline" != offline ]] || return 0
  [[ "$offline" != held || ("$value" == changed && "$hold" == true) ]] || return 0
  _python_state || return 1
  [[ "$PY_STATE" == ready ]] || return 0
  if [[ "$value" == changed ]]; then
    # changed compares the release of current, which pkgver_format, pkgver_dash and newest change
    [[ -n "$current" && "$PY_SOURCE" == pypi && -z "${PY_NEWEST:-}" ]] || return 0
    [[ -z "$(pkg_get "$file" '.pkgver_format // ""')" && -z "$(pkgver_dash "$file")" ]] || return 0
    change=$(requires_change "$file" "$current" "$latest" "$PY_PROJECT") || return 1
    [[ -n "$change" ]] || return 0
    action=notice
    [[ "$hold" != true ]] || action=hold
    printf '%s\t%s\n' "$action" "${note:+$note: }$change"
    return 0
  fi
  change=$("python_$value" "$file" "$PY_SRCINFO" "$PY_PROJECT" "$PY_VERSION") || return 1
  [[ -n "$change" ]] || return 0
  action=notice
  [[ "$hold" != true || $'\n'"$change" != *$'\nhold\t'* ]] || action=hold
  joined=""
  while IFS=$'\t' read -r _ change; do
    joined+="${joined:+; }$change"
  done <<<"$change"
  printf '%s\t%s\n' "$action" "${note:+$note: }$joined"
}

# Set PY_STATE once per call of _fired_alerts: ready when the AUR .SRCINFO, PY_SRCINFO, has a pkgname
# with Python in depends and python_source names a source, none otherwise; fail when it cannot tell
_python_state() {
  local name rc=0 pkgname format version
  [[ -z "$PY_STATE" ]] || return 0
  PY_STATE=none
  name=$(package_name "$file") || return 1
  PY_SRCINFO=$(aur_srcinfo "$name") || rc=$?
  ((rc != 3)) || return 0
  ((rc == 0)) || return 1
  while IFS= read -r pkgname; do
    if pkgname_has_python "$PY_SRCINFO" "$pkgname"; then
      # The check gives the version after pkgver_format, and the sources take the upstream version
      version=$latest
      format=$(pkg_get "$file" '.pkgver_format // ""')
      if [[ -n "$format" ]]; then
        version=$(_unformat_version "$latest" "$format")
        if [[ -z "$version" ]]; then
          log_err "packages/${file##*/}: version $latest does not fit pkgver_format $format"
          return 1
        fi
      fi
      python_source "$file" "$version" "$PY_SRCINFO" || return 1
      [[ "$PY_SOURCE" == none ]] || PY_STATE=ready
      return 0
    fi
  done < <(srcinfo_pkgnames "$PY_SRCINFO")
}
