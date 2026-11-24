#!/usr/bin/env bash
#
# pyrules.sh - The requires rule unmet: Python requirements of a release against Arch packages
#
# Sourced by lib.sh.

# Succeed when depends of pkgname $2 of .SRCINFO $1 hold python or python-*
pkgname_has_python() {
  local dep
  while IFS= read -r dep; do
    [[ "$dep" != python && "$dep" != python-* ]] || return 0
  done < <(srcinfo_depends "$1" "$2" depends)
  return 1
}

# Print the package name that python.map of package file $1 gives PyPI name $2, in PEP 503 form
python_map() {
  local key value
  while IFS=$'\t' read -r key value; do
    if _pypi_norm "$key" && [[ "$PYPI_NORM" == "$2" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done < <(pkg_get "$1" '.python.map // {} | select(tag == "!!map") | to_entries[] | [.key, .value] | join("\t")')
}

# Set MATCH_PKG, MATCH_VERSION and MATCH_FROM, dist, pkgver or aur, for the entry of depends of
# pkgname $3 of .SRCINFO $2 that meets requirement name $4, written $5, of package file $1
python_match() {
  local dep name version mapped written=${5,,} candidate pkg pkg_version pkg_repo
  local -a candidates
  candidates=("python-$4" "python-${4//-/_}" "$4" "python-$written")
  mapped=$(python_map "$1" "$4")
  [[ -z "$mapped" ]] || candidates+=("$mapped")
  while IFS= read -r dep; do
    if ! arch_package "$dep"; then
      log_warn "$3: depends entry $dep is in neither the repositories nor the AUR"
      continue
    fi
    pkg=$PKG_NAME pkg_version=$PKG_VERSION pkg_repo=$PKG_REPO
    if [[ "$pkg_repo" != aur ]]; then
      while IFS=$'\t' read -r name version; do
        if [[ "$name" == "$4" ]]; then
          MATCH_PKG=$pkg MATCH_VERSION=$version MATCH_FROM=dist
          return 0
        fi
      done < <(python_dists_of "$pkg")
    fi
    for candidate in "${candidates[@]}"; do
      if [[ "$candidate" == "$dep" || "$candidate" == "$pkg" ]] || _python_provides "$candidate" "$pkg" "$pkg_repo"; then
        MATCH_PKG=$pkg MATCH_VERSION=$pkg_version MATCH_FROM=pkgver
        [[ "$pkg_repo" != aur ]] || MATCH_FROM=aur
        return 0
      fi
    done
  done < <(srcinfo_depends "$2" "$3" depends)
  return 1
}

# Succeed when name $1 is among the provides of package $2 of repository $3, aur for the AUR
_python_provides() {
  local name version provides
  if [[ "$3" != aur ]]; then
    repo_package "$1" && [[ "$PKG_NAME" == "$2" ]]
    return
  fi
  while IFS=$'\t' read -r name version provides; do
    if [[ "$name" == "$2" && ",$provides," == *",$1,"* ]]; then
      return 0
    fi
  done <"$AURTOMATOR_RUN_CACHE/aur-pkgs"
  return 1
}

# Print the pin that release headers $3 of project $2 give package $1 of the repository of package
# file $4 when its upstream.pin_from names that project, which the run publishes beside it
python_companion_pin() {
  local file want pin
  _pypi_norm "$2" || return 1
  want=$PYPI_NORM
  for file in "${4%/*}"/*.yml; do
    [[ -f "$file" && "${file##*/}" == "$1.yml" ]] || continue
    pin=$(pkg_get "$file" '.upstream.pin_from // ""') || return 1
    _pypi_norm "$pin" && [[ "$PYPI_NORM" == "$want" ]] || return 1
    requires_pin "$3" "$2" "$(pkg_get "$file" '.upstream.registry // ""')" 2>/dev/null
    return
  done
  return 1
}

# Print the notes of rule unmet for release $4 of PyPI project $3, packaged by package file $1
# with .SRCINFO $2: lines of hold or notice, a tab and the note, for each pkgname with Python
python_unmet() {
  local file=$1 srcinfo=$2 project=$3 version=$4 headers="" read="" pkgname prefix="" python="" dep out line
  local -a pkgnames reqs=() deps unknown
  mapfile -t pkgnames < <(srcinfo_pkgnames "$srcinfo")
  ((${#pkgnames[@]} < 2)) || prefix=1
  for pkgname in "${pkgnames[@]}"; do
    pkgname_has_python "$srcinfo" "$pkgname" || continue
    if [[ -z "$read" ]]; then
      read=1
      headers=$(pypi_metadata "$project" "$version") || return 1
      _requires_list "$headers" "$project $version" || return 1
      reqs=("${REQUIRES_LIST[@]}")
      python=${REQUIRES_PYTHON//[[:blank:]]/}
      files_index_python || return 1
    fi
    # The AUR answers the names that the repositories lack in one request
    mapfile -t deps < <(srcinfo_depends "$srcinfo" "$pkgname" depends)
    unknown=()
    for dep in "${deps[@]}"; do
      repo_package "$dep" || unknown+=("$dep")
    done
    aur_packages "${unknown[@]}" || return 1
    out=$(_python_unmet_one "$file" "$srcinfo" "$pkgname" "$project" "$headers" "$python" "${reqs[@]}") || return 1
    while IFS= read -r line; do
      [[ -z "$line" ]] || printf '%s\t%s%s\n' "${line%%$'\t'*}" "${prefix:+$pkgname: }" "${line#*$'\t'}"
    done <<<"$out"
  done
}

# Print the notes of python_unmet for pkgname $3 of .SRCINFO $2 of package file $1: project $4,
# release headers $5, Requires-Python $6 without blanks, and the requirements after them
_python_unmet_one() {
  local file=$1 srcinfo=$2 pkgname=$3 project=$4 headers=$5 python=$6 req name spec extras rc action pin
  local text
  if [[ -n "$python" ]]; then
    _requires_python
    rc=0
    [[ -z "$REQUIRES_PY_FULL" ]] || pep440_holds "$REQUIRES_PY_FULL" "$python" || rc=$?
    if [[ -z "$REQUIRES_PY_FULL" ]]; then
      printf 'notice\tRequires-Python %s: pacman gives no version of python\n' "$python"
    elif ((rc == 1)); then
      printf 'hold\tRequires-Python %s: python has %s\n' "$python" "$REQUIRES_PY_FULL"
    elif ((rc == 2)); then
      printf 'notice\tRequires-Python %s: python has %s, which PEP 440 cannot compare\n' "$python" "$REQUIRES_PY_FULL"
    fi
  fi
  for req in "${@:7}"; do
    _requirement_read "$req" "$project" || return 1
    [[ "$MARKER_VALUE" != 0 ]] || continue
    name=$REQ_NAME spec=$REQ_SPEC extras=$REQ_EXTRAS
    if [[ "$spec" == @ ]]; then
      printf 'notice\t%s @ URL: cannot compare\n' "$name"
      continue
    fi
    if ! python_match "$file" "$srcinfo" "$pkgname" "$name" "${req%%[[ (<>=!~;@]*}"; then
      printf 'hold\t%s: not in depends\n' "$name"
      continue
    fi
    if pin=$(python_companion_pin "$MATCH_PKG" "$project" "$headers" "$file"); then
      MATCH_VERSION=$pin MATCH_FROM=dist
    fi
    if [[ -n "$spec" ]]; then
      text="$name$spec: $MATCH_PKG has $MATCH_VERSION"
      case $MATCH_FROM in
        pkgver) text+=" (pkgver)" ;;
        aur) text+=" (AUR pkgver)" ;;
      esac
      rc=0
      pep440_holds "$MATCH_VERSION" "$spec" || rc=$?
      if ((rc == 2)); then
        printf 'notice\t%s: %s has %s, which PEP 440 cannot compare\n' "$name$spec" "$MATCH_PKG" "$MATCH_VERSION"
      elif ((rc == 1)); then
        # Upper caps that Arch exceeds give a notice: Arch ships such pairs, as sympy and mpmath
        action=notice
        [[ ",$PEP440_FAILED" != *,[\>=~]* ]] || action=hold
        printf '%s\t%s\n' "$action" "$text"
      fi
    fi
    [[ -z "$extras" ]] || _python_unmet_extras "$file" "$srcinfo" "$pkgname" "$name" "$extras" "$MATCH_VERSION"
  done
}

# Print the notes for extras $5, joined by commas, of requirement $4 that pkgname $3 of .SRCINFO
# $2 of package file $1 meets with version $6: requirements of an extra that depends lacks hold
_python_unmet_extras() {
  local headers extra req value
  local -a reqs
  if ! headers=$(pypi_metadata "$4" "$6" 2>/dev/null) || ! _requires_list "$headers" "$4 $6" 2>/dev/null; then
    printf 'notice\t%s[%s]: cannot read the metadata of %s %s\n' "$4" "$5" "$4" "$6"
    return 0
  fi
  reqs=("${REQUIRES_LIST[@]}")
  for extra in ${5//,/ }; do
    for req in "${reqs[@]}"; do
      MARKER_EXTRAS="" _requirement_read "$req" "$4 $6" 2>/dev/null || continue
      value=$MARKER_VALUE
      MARKER_EXTRAS=$extra _requirement_read "$req" "$4 $6" || continue
      [[ "$value" == 0 && "$MARKER_VALUE" != 0 ]] || continue
      python_match "$1" "$2" "$3" "$REQ_NAME" "${req%%[[ (<>=!~;@]*}" ||
        printf 'hold\t%s[%s]: %s not in depends\n' "$4" "$extra" "$REQ_NAME"
    done
  done
}
