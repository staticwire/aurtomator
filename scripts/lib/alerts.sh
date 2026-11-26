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

# Print the alerts of package file $1 from current $2 to version $3 in file order, as hold or notice, a tab and
# the note, or fail on a broken rule; $4 offline skips requires rules, held those without hold, requires the rest
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
    hold=$(pkg_bool "$file" ".alerts[$i].hold") || return 1
    if [[ "$kind" == when && "$value" != major ]]; then
      log_err "alerts[$i].when must be major, got $value"
      return 1
    fi
    if [[ "$kind" == requires ]]; then
      if [[ "$value" != changed && "$value" != unmet && "$value" != imports ]]; then
        log_err "alerts[$i].requires must be changed, unmet or imports, got $value"
        return 1
      fi
      if [[ ! $(pkg_get "$file" .strategy) =~ ^(pypi|rubygems)$ &&
      -z "$(pkg_get "$file" '(.python | select(tag == "!!map") | .pypi // .pyproject) // (.ruby | select(tag == "!!map") | .gem) // ""' 2>/dev/null)" ]]; then
        log_err "alerts[$i].requires needs strategy pypi or rubygems, python.pypi, python.pyproject or ruby.gem"
        return 1
      fi
      note=""
      if [[ $(pkg_get "$file" ".alerts[$i] | has(\"note\")") == true ]] && ! note=$(alert_note "$file" "$i"); then
        log_err "alerts[$i].$(alert_note_error "$file" "$i")"
        return 1
      fi
      listed[$value]=1
      _fired_requires "$value" "$hold" "$note" || return 1
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
    ((rc == 0)) && [[ "$offline" != requires ]] || continue
    action=notice
    [[ "$hold" != true ]] || action=hold
    [[ "$offline" != held || "$action" == hold ]] || continue
    printf '%s\t%s\n' "$action" "$note"
  done
  for value in changed unmet imports; do
    [[ -n "${listed[$value]:-}" ]] || _fired_requires "$value" "" "" || return 1
  done
}

# Print the line of requires rule $1, with hold $2 and note $3, for the call of _fired_alerts: prepare runs
# changed with hold alone, and unmet and imports run in the check
_fired_requires() {
  local value=$1 hold=$2 note=$3 lines="" part action joined line
  [[ "$offline" != offline ]] || return 0
  [[ "$offline" != held || ("$value" == changed && "$hold" == true) ]] || return 0
  _requires_state || return 1
  if [[ "$PY_STATE" == ready ]]; then
    part=$(_python_rule "$value") || return 1
    lines+="${part:+$part$'\n'}"
  fi
  if [[ "$RB_STATE" == ready ]]; then
    part=$(_ruby_rule "$value") || return 1
    lines+="${part:+$part$'\n'}"
  fi
  [[ -n "$lines" ]] || return 0
  action=notice
  [[ "$hold" != true || $'\n'"$lines" != *$'\nhold\t'* ]] || action=hold
  joined=""
  while IFS=$'\t' read -r _ line; do
    [[ -z "$line" ]] || joined+="${joined:+; }$line"
  done <<<"$lines"
  # Text of upstream and the AUR: a tab would split the line, and a terminal acts on control characters
  joined=$(printf '%s' "$joined" | LC_ALL=C sed 's/[\x01-\x1f\x7f]/ /g; s/\xc2[\x80-\x9f]/ /g')
  printf '%s\t%s\n' "$action" "${note:+$note: }$joined"
}

# Print the lines of hold or notice, a tab and the note, of requires rule $1 on the Python side; changed
# compares the release of current, which pkgver_format, pkgver_dash and newest change
_python_rule() {
  local change
  if [[ "$1" == changed ]]; then
    [[ -n "$current" && "$PY_SOURCE" == pypi && -z "${PY_NEWEST:-}" ]] || return 0
    [[ -z "$(pkg_get "$file" '.pkgver_format // ""')" && -z "$(pkgver_dash "$file")" ]] || return 0
    change=$(requires_change "$file" "$current" "$latest" "$PY_PROJECT") || return 1
    [[ -z "$change" ]] || printf 'hold\t%s\n' "$change"
    return 0
  fi
  "python_$1" "$file" "$REQ_SRCINFO" "$PY_PROJECT" "$PY_VERSION"
}

# Print the lines of requires rule $1 on the side of gems, as _python_rule does
_ruby_rule() {
  local change
  case $1 in
    changed)
      [[ -n "$current" ]] || return 0
      [[ -z "$(pkg_get "$file" '.pkgver_format // ""')" && -z "$(pkgver_dash "$file")" ]] || return 0
      change=$(ruby_change "$file" "$RB_GEM" "$current" "$latest") || return 1
      [[ -z "$change" ]] || printf 'hold\t%s\n' "$change"
      ;;
    unmet) ruby_unmet "$file" "$REQ_SRCINFO" "$RB_GEM" "$RB_VERSION" ;;
    imports) ruby_imports "$file" "$REQ_SRCINFO" "$RB_GEM" "$RB_VERSION" ;;
  esac
}

# Print yes when the requires rules run for package file $1, as a pkgname of its AUR .SRCINFO has Python
# or Ruby in depends that python: none or ruby: none does not turn off, and no otherwise; fail on the AUR
requires_needed() {
  local name srcinfo pkgname rc=0
  name=$(package_name "$1") || return 1
  srcinfo=$(aur_srcinfo "$name") || rc=$?
  if ((rc == 3)); then
    echo no
    return 0
  fi
  ((rc == 0)) || return 1
  while IFS= read -r pkgname; do
    if { pkgname_has_python "$srcinfo" "$pkgname" && ! _requires_off "$1" python; } ||
      { pkgname_has_ruby "$srcinfo" "$pkgname" && ! _requires_off "$1" ruby; }; then
      echo yes
      return 0
    fi
  done < <(srcinfo_pkgnames "$srcinfo")
  echo no
}

# Succeed when the requires rules can read the requirements of package file $1 at its current version, as
# the check of a new version reads them; fail with the message of that check otherwise
requires_check() {
  local rc=0
  if [[ -n "${AURTOMATOR_RUN_CACHE:-}" ]]; then
    _requires_check "$1"
    return
  fi
  local -x AURTOMATOR_RUN_CACHE
  AURTOMATOR_RUN_CACHE=$(mktemp -d) || return 1
  _requires_check "$1" || rc=$?
  rm -rf "$AURTOMATOR_RUN_CACHE"
  return "$rc"
}

_requires_check() {
  local file=$1 latest name srcinfo rc=0
  PY_STATE=""
  latest=$(pkg_get "$file" '.current // ""') || return 1
  if [[ -z "$latest" ]]; then
    name=$(package_name "$file") || return 1
    srcinfo=$(aur_srcinfo "$name") || rc=$?
    ((rc != 3)) || return 0
    ((rc == 0)) || return 1
    latest=$(srcinfo_pkgver "$srcinfo")
  fi
  _requires_state || return 1
  # python.pyproject reads the requirements in _requires_state
  if [[ "$PY_STATE" == ready && -z "$PY_HEADERS" ]]; then
    pypi_metadata "$PY_PROJECT" "$PY_VERSION" >/dev/null || return 1
  fi
  if [[ "$RB_STATE" == ready ]]; then
    gem_release "$RB_GEM" "$RB_VERSION" || return 1
  fi
}

# Succeed when key $2, python or ruby, of package file $1 is none
_requires_off() {
  [[ "$(pkg_get "$1" ".$2 | tag")" == "!!str" && "$(pkg_get "$1" ".$2")" == none ]]
}

# Set REQ_SRCINFO, PY_STATE and RB_STATE once per call of _fired_alerts: a state is ready when the AUR
# .SRCINFO has a pkgname with that language in depends and a source of requirements, none otherwise
_requires_state() {
  local name rc=0 pkgname python="" ruby="" format version
  [[ -z "$PY_STATE" ]] || return 0
  PY_STATE=none RB_STATE=none
  name=$(package_name "$file") || return 1
  REQ_SRCINFO=$(aur_srcinfo "$name") || rc=$?
  ((rc != 3)) || return 0
  ((rc == 0)) || return 1
  while IFS= read -r pkgname; do
    ! pkgname_has_python "$REQ_SRCINFO" "$pkgname" || python=1
    ! pkgname_has_ruby "$REQ_SRCINFO" "$pkgname" || ruby=1
  done < <(srcinfo_pkgnames "$REQ_SRCINFO")
  [[ -n "$python$ruby" ]] || return 0
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
  if [[ -n "$python" ]]; then
    python_source "$file" "$version" "$REQ_SRCINFO" || return 1
    [[ "$PY_SOURCE" == none ]] || PY_STATE=ready
  fi
  if [[ -n "$ruby" ]]; then
    ruby_source "$file" "$version" || return 1
    [[ "$RB_SOURCE" == none ]] || RB_STATE=ready
  fi
}
