#!/usr/bin/env bash
#
# pyrules.sh - The requires rules unmet and imports: a Python release against Arch packages
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
      if [[ -n "${PY_HEADERS:-}" ]]; then
        headers=$PY_HEADERS
      else
        headers=$(pypi_metadata "$project" "$version") || return 1
      fi
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

# Print the notes of rule imports for release $4 of PyPI project $3, packaged by package file $1
# with .SRCINFO $2: lines of notice, a tab and the note, for each pkgname with Python
python_imports() {
  local pkgname any="" work rc=0 out
  local -a pkgnames
  mapfile -t pkgnames < <(srcinfo_pkgnames "$2")
  for pkgname in "${pkgnames[@]}"; do
    ! pkgname_has_python "$2" "$pkgname" || any=1
  done
  [[ -n "$any" ]] || return 0
  files_index_python || return 1
  if [[ "$ARCHDB_FILES" == none ]]; then
    printf 'notice\timports: pacman has no files database, not read\n'
    return 0
  fi
  archdb_cache || return 1
  work=$(mktemp -d "$AURTOMATOR_RUN_CACHE/imports.XXXXXX") || return 1
  out=$(_python_imports_read "$1" "$2" "$3" "$4" "$work" "${pkgnames[@]}") || rc=$?
  rm -rf "$work"
  ((rc == 0)) || return 1
  [[ -z "$out" ]] || printf '%s\n' "$out" | LC_ALL=C sort -u
}

# python_imports for package file $1, .SRCINFO $2, project $3, release $4, work directory $5 and
# the pkgnames after it: reads the files of the release and prints the notes of each pkgname
_python_imports_read() {
  local LC_ALL=C file=$1 srcinfo=$2 work=$5 name url sha kind top root size count rc=0 helper entry pkgname
  local -a pkgnames=("${@:6}") files skip
  local -a include=(--include '*.py' --include '*/scripts/*' --include 'scripts/*' --include '*/bin/*' --include 'bin/*'
    --include '*entry_points.txt')
  # python.pyproject reads the tree of the source archive that python_source fetched
  if [[ "${PY_SOURCE:-}" == pyproject ]]; then
    name=${PY_TREE_ARCHIVE##*/} kind=tree
    cp "$PY_TREE_ARCHIVE" "$work/archive" || return 1
  else
    _python_imports_archive "$3" "$4" || return 1
    if [[ -z "${PY_ARCHIVE:-}" ]]; then
      printf 'notice\timports: PyPI holds no wheel or sdist of %s %s, not read\n' "$3" "$4"
      return 0
    fi
    IFS=$'\t' read -r name url sha kind <<<"$PY_ARCHIVE"
    http_get "$url" -o "$work/archive" || return 1
    if [[ "$(sha256sum "$work/archive")" != "$sha "* ]]; then
      log_err "$name does not match its sha256"
      return 1
    fi
  fi
  # The listing takes the members that the extraction takes, within 16 MiB, where an ignored SIGXFSZ
  # makes a write past it fail; numeric owners keep names with spaces from shifting the size column
  (trap '' XFSZ && ulimit -f 16384 && bsdtar -tvf "$work/archive" --numeric-owner "${include[@]}" >"$work/list" 2>"$work/errors")
  if _bsdtar_failed "$work/errors" || (($(stat -c %s "$work/list") >= 16384 * 1024)); then
    printf 'notice\timports: bsdtar cannot list %s, not read\n' "$name"
    return 0
  fi
  read -r count size < <(awk '{ n++ } /^-/ { sum += $5 } END { printf "%d %d\n", n, sum }' "$work/list")
  if ((count > 20000)); then
    printf 'notice\timports: the release holds more than 20000 Python files and scripts, not read\n'
    return 0
  fi
  if ((size > 20 * 1024 * 1024)); then
    printf 'notice\timports: the release holds more than 20 MB of Python files, not read\n'
    return 0
  fi
  mkdir "$work/tree" || return 1
  (trap '' XFSZ && ulimit -f $((20 * 1024)) && bsdtar -xf "$work/archive" -C "$work/tree" --no-same-owner \
    "${include[@]}" 2>"$work/errors")
  if _bsdtar_failed "$work/errors"; then
    printf 'notice\timports: bsdtar cannot extract %s, not read\n' "$name"
    return 0
  fi
  # Links of the archive could point at any file of the runner
  find "$work/tree" -type l -delete
  top="$work/tree"
  if [[ "$kind" != wheel ]]; then
    top="$work/tree/${name%.tar.gz}"
    top=${top%.zip}
    [[ "$kind" != tree ]] || top="$work/tree/$PY_TREE_TOP"
    [[ -d "$top" ]] || return 0
    # Builds and test runners read the files at the root, and the build installs none of them
    for entry in tests test docs doc examples setup.py conftest.py noxfile.py tasks.py fabfile.py; do
      rm -rf "${top:?}/$entry"
    done
  fi
  mapfile -t skip < <(pkg_get "$file" '.python.skip // [] | .[] | select(tag == "!!str")')
  for entry in "${skip[@]}"; do
    [[ -n "$entry" && "$entry" != /* && "/$entry/" != */../* ]] || continue
    rm -rf "${top:?}/$entry"
  done
  root=$top
  [[ "$kind" == wheel || ! -d "$top/src" ]] || root="$top/src"
  _python_imports_files "$top" "$root" "$kind"
  files=("${PY_FILES[@]}")
  ((${#files[@]} > 0)) || return 0
  helper="${BASH_SOURCE[0]%/*}/py_imports.py"
  printf '%s\0' "${files[@]}" >"$work/names"
  timeout 60 python3 -I -S "$helper" "$root" <"$work/names" >"$work/imports" 2>/dev/null || rc=$?
  ((rc != 0)) || timeout 60 python3 -I -S "$helper" --stdlib >"$work/stdlib" 2>/dev/null || rc=$?
  case $rc in
    0) ;;
    124)
      printf 'notice\timports: not read within 60 s\n'
      return 0
      ;;
    127)
      printf 'notice\timports: python3 is not installed, not read\n'
      return 0
      ;;
    *)
      printf 'notice\timports: py_imports.py exits %s, not read\n' "$rc"
      return 0
      ;;
  esac
  _python_imports_classify "$top" "$root" "$work/imports" "$work/stdlib" || return 1
  for pkgname in "${pkgnames[@]}"; do
    pkgname_has_python "$srcinfo" "$pkgname" || continue
    _python_imports_notes "$file" "$srcinfo" "$pkgname" "${#pkgnames[@]}" || return 1
  done
}

# Succeed when bsdtar error file $1 holds an error other than a pattern that matched nothing
_bsdtar_failed() {
  grep -qv -e ': Not found in archive$' -e '^bsdtar: Error exit delayed from previous errors' "$1"
}

# Set PY_ARCHIVE to name, URL, sha256 and wheel or sdist of the file of release $2 of project $1
# that the rule reads: a wheel for any platform, then one for Linux on x86_64, any other wheel, the sdist
_python_imports_archive() {
  local name url sha
  local -a any=() linux=() other=() sdists=()
  PY_ARCHIVE=""
  pypi_release "$1" "$2" || return 1
  while IFS=$'\t' read -r name url sha _; do
    case $name in
      "") ;;
      *-none-any.whl) any+=("$name"$'\t'"$url"$'\t'"$sha"$'\twheel') ;;
      *linux*x86_64*.whl) linux+=("$name"$'\t'"$url"$'\t'"$sha"$'\twheel') ;;
      *.whl) other+=("$name"$'\t'"$url"$'\t'"$sha"$'\twheel') ;;
      *) sdists+=("$name"$'\t'"$url"$'\t'"$sha"$'\tsdist') ;;
    esac
  done <<<"$PYPI_FILES"
  PY_ARCHIVE=${any[0]:-${linux[0]:-${other[0]:-${sdists[0]:-}}}}
}

# Set PY_FILES to the files under $2, the root of the modules in tree $1 of a wheel or sdist ($3),
# that the rule parses: every .py file and the scripts whose first line names python, relative to $2
_python_imports_files() {
  local LC_ALL=C top=$1 root=$2 path line rel
  local -A seen=()
  PY_FILES=()
  while IFS= read -r -d '' path; do
    rel=${path#"$root"/}
    if [[ "$rel" == *$'\t'* ]] || has_control "$rel"; then
      continue
    fi
    seen[$rel]=1
    PY_FILES+=("$rel")
  done < <(find "$root" -type f -name '*.py' -print0 | sort -z)
  while IFS= read -r -d '' path; do
    line=""
    IFS= read -r line <"$path" || [[ -n "$line" ]] || continue
    [[ "$line" =~ ^#!.*python ]] || continue
    rel=${path#"$top"/}
    [[ "$root" == "$top" ]] || rel="../$rel"
    if [[ "$rel" == *$'\t'* || -n "${seen[$rel]:-}" ]] || has_control "$rel"; then
      continue
    fi
    PY_FILES+=("$rel")
  done < <(
    if [[ "$3" == wheel ]]; then
      find "$top" -mindepth 3 -maxdepth 3 -type f -path '*.data/scripts/*' -print0
    else
      find "$top/bin" "$top/scripts" -type f -print0 2>/dev/null
    fi | sort -z
  )
}

# Sort the imports of py_imports.py output $3 for the modules under $2 of tree $1, $4 listing the standard
# modules: PY_ERRORS gets the files that do not parse, PY_REQUIRED and PY_OPTIONAL the modules of other projects
_python_imports_classify() {
  local LC_ALL=C top=$1 root=$2 kind path module scope line name entry rel
  local -A own=() reached=() mods=() required=() optional=() stdlib=()
  local -a queue=()
  PY_ERRORS=() PY_REQUIRED=() PY_OPTIONAL=()
  for entry in "$root"/*; do
    name=${entry##*/}
    if [[ -f "$entry" && "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*\.py$ ]]; then
      own[${name%.py}]=1
      queue+=("$name")
    elif [[ -d "$entry" && "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && [[ -n "$(find "$entry" -name '*.py' -print -quit)" ]]; then
      own[$name]=1
      [[ ! -f "$entry/__init__.py" ]] || queue+=("$name/__init__.py")
    fi
  done
  while IFS=$'\t' read -r kind path module scope; do
    case $kind in
      error)
        rel=$path
        if [[ "$rel" == ../* ]]; then
          rel=${rel#../}
        elif [[ "$root" != "$top" ]]; then
          rel="${root#"$top"/}/$rel"
        fi
        PY_ERRORS+=("$rel: $module")
        ;;
      import)
        [[ "$scope" != typing && -n "$module" ]] || continue
        mods[$path]+="$scope"$'\t'"$module"$'\n'
        # Scripts are entry points of their own
        [[ "$path" == *.py ]] || queue+=("$path")
        ;;
    esac
  done <"$3"
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:blank:]]*[A-Za-z0-9_.-]+[[:blank:]]*=[[:blank:]]*([A-Za-z_][A-Za-z0-9_.]*) ]] || continue
    while IFS= read -r rel; do
      queue+=("$rel")
    done < <(_python_module_files "$root" "${BASH_REMATCH[1]}")
  done < <(find "$top" -maxdepth 3 -type f -name entry_points.txt -path '*.*-info/*' -exec awk '
    /^\[/ { keep = ($0 ~ /^\[(console|gui)_scripts\][[:blank:]]*$/); next } keep' {} +)
  while ((${#queue[@]} > 0)); do
    path=${queue[0]}
    queue=("${queue[@]:1}")
    [[ -z "${reached[$path]:-}" ]] || continue
    reached[$path]=1
    while IFS=$'\t' read -r scope module; do
      [[ "$scope" == module && -n "${own[${module%%.*}]:-}" ]] || continue
      while IFS= read -r rel; do
        [[ -n "${reached[$rel]:-}" ]] || queue+=("$rel")
      done < <(_python_module_files "$root" "$module")
    done <<<"${mods[$path]:-}"
  done
  while IFS= read -r name; do
    [[ -z "$name" ]] || stdlib[$name]=1
  done <"$4"
  for path in "${!mods[@]}"; do
    while IFS=$'\t' read -r scope module; do
      [[ -n "$module" && -z "${own[${module%%.*}]:-}" && -z "${stdlib[${module%%.*}]:-}" ]] || continue
      if [[ -n "${reached[$path]:-}" && "$scope" == module ]]; then
        required[$module]=1
      else
        optional[$module]=1
      fi
    done <<<"${mods[$path]}"
  done
  PY_REQUIRED=("${!required[@]}")
  for module in "${!optional[@]}"; do
    [[ -n "${required[$module]:-}" ]] || PY_OPTIONAL+=("$module")
  done
}

# Print the files under root $1 that importing dotted module $2 runs: the __init__.py of each
# package on the way, then the module file or the __init__.py of the package it names
_python_module_files() {
  local path="" part
  local -a parts
  IFS=. read -ra parts <<<"$2"
  for part in "${parts[@]}"; do
    path+="${path:+/}$part"
    if [[ -f "$1/$path/__init__.py" ]]; then
      printf '%s\n' "$path/__init__.py"
    elif [[ -f "$1/$path.py" ]]; then
      printf '%s\n' "$path.py"
      return 0
    else
      return 0
    fi
  done
}

# Write the owners of the top-level modules $@ that the run did not ask for yet to py-owners of the
# run cache: lines of the pkgname and the path under the directory of Python, site-packages left out
_python_owners_index() {
  local LC_ALL=C file="$AURTOMATOR_RUN_CACHE/py-owners" asked="$AURTOMATOR_RUN_CACHE/py-owners-asked" name
  local pkg path rel alternation top owners
  local -A known=()
  local -a names=() alternations
  touch "$file" "$asked" || return 1
  while IFS= read -r name; do
    known[$name]=1
  done <"$asked"
  for name in "$@"; do
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && -z "${known[$name]:-}" ]] || continue
    known[$name]=1
    names+=("$name")
  done
  ((${#names[@]} > 0)) || return 0
  mapfile -t alternations < <(files_index_alternations "${names[@]}")
  for alternation in "${alternations[@]}"; do
    owners=$(files_index_owner "^usr/lib/python3\\.[0-9]+/((site-packages|lib-dynload)/)?($alternation)(/|\\.py\$|\\.[^/]*\\.so\$)") ||
      return 1
    while IFS=$'\t' read -r pkg path; do
      [[ -n "$pkg" ]] || continue
      rel=${path#usr/lib/python3.*/}
      rel=${rel#site-packages/}
      rel=${rel#lib-dynload/}
      # pacman matches without regard to case, and module names keep theirs
      top=${rel%%/*}
      top=${top%%.*}
      [[ -n "${known[$top]:-}" ]] || continue
      printf '%s\t%s\n' "$pkg" "$rel"
    done <<<"$owners" >>"$file"
  done
  # Names that a failed query left out are asked again
  printf '%s\n' "${names[@]}" >>"$asked"
}

# Print the dotted prefix of module $1 that names its owners in py-owners, then the owners, one a
# line, for the longest prefix that some package owns; nothing when none does
_python_owners() {
  local LC_ALL=C prefix owners path n
  local -a parts
  IFS=. read -ra parts <<<"$1"
  for ((n = ${#parts[@]}; n > 0; n--)); do
    path=$(IFS=/ && printf '%s' "${parts[*]:0:n}")
    owners=$(awk -F'\t' -v p="$path" '$2 == p ".py" || index($2, p "/") == 1 ||
      (index($2, p ".") == 1 && $2 ~ /\.so$/ && index(substr($2, length(p) + 2), "/") == 0) { print $1 }' \
      "$AURTOMATOR_RUN_CACHE/py-owners" | sort -u)
    if [[ -n "$owners" ]]; then
      prefix=$(IFS=. && printf '%s' "${parts[*]:0:n}")
      printf '%s\n%s\n' "$prefix" "$owners"
      return 0
    fi
  done
}

# Print the notes of pkgname $3 of .SRCINFO $2 of package file $1, with PY_REQUIRED, PY_OPTIONAL
# and PY_ERRORS of the release; $4 is the number of pkgnames, and more than one names the pkgname
_python_imports_notes() {
  local file=$1 srcinfo=$2 pkgname=$3 prefix="" module dep key lower owner met entry
  local -a lines
  local -A in_depends=() in_opt=() noted=()
  local -a owners tops=()
  (($4 < 2)) || prefix="$pkgname: "
  while IFS= read -r dep; do
    in_depends[$dep]=1
    ! arch_package "$dep" 2>/dev/null || in_depends[$PKG_NAME]=1
  done < <(srcinfo_depends "$srcinfo" "$pkgname" depends)
  while IFS= read -r dep; do
    in_opt[$dep]=1
    ! arch_package "$dep" 2>/dev/null || in_opt[$PKG_NAME]=1
  done < <(srcinfo_depends "$srcinfo" "$pkgname" optdepends)
  while IFS= read -r dep; do
    in_depends[$dep]=1
  done < <(srcinfo_pkgnames "$srcinfo")
  in_depends[python]=1
  for entry in "${PY_ERRORS[@]}"; do
    printf 'notice\t%simports: %s does not parse: %s\n' "$prefix" "${entry%%: *}" "${entry#*: }"
  done
  for module in "${PY_REQUIRED[@]}" "${PY_OPTIONAL[@]}"; do
    tops+=("${module%%.*}")
  done
  _python_owners_index "${tops[@]}" || return 1
  for module in "${PY_REQUIRED[@]}" "${PY_OPTIONAL[@]}"; do
    owners=()
    mapfile -t lines < <(_python_owners "$module")
    key=${module%%.*}
    if ((${#lines[@]} > 0)); then
      owners=("${lines[@]:1}")
      # Namespace packages, as google, have owners that differ by sub-path
      [[ "$(_python_owners "$key" | wc -l)" -le 2 ]] || key=${lines[0]}
    else
      for dep in "${!in_depends[@]}" "${!in_opt[@]}"; do
        lower=${key,,}
        if [[ "$dep" == "python-$lower" || "$dep" == "python-${lower//_/-}" ]]; then
          owners=("$dep")
          break
        fi
      done
      if ((${#owners[@]} == 0)) && _pypi_norm "$key"; then
        owner=$(python_map "$file" "$PYPI_NORM")
        [[ -z "$owner" ]] || owners=("$owner")
      fi
    fi
    [[ -z "${noted[$key]:-}" ]] || continue
    noted[$key]=1
    if ((${#owners[@]} == 0)); then
      _python_is_required "$module" && printf 'notice\t%simport %s: no package owns it\n' "$prefix" "$key"
      continue
    fi
    met=""
    for owner in "${owners[@]}"; do
      [[ -z "${in_depends[$owner]:-}" ]] || met=1
    done
    [[ -z "$met" ]] || continue
    if _python_is_required "$module"; then
      printf 'notice\t%simport %s: %s not in depends\n' "$prefix" "$key" "$(_python_join "${owners[@]}")"
      continue
    fi
    for owner in "${owners[@]}"; do
      [[ -z "${in_opt[$owner]:-}" ]] || met=1
    done
    [[ -n "$met" ]] ||
      printf 'notice\t%simport %s (optional): %s in neither depends nor optdepends\n' "$prefix" "$key" "$(_python_join "${owners[@]}")"
  done
}

# Succeed when module $1 is one of PY_REQUIRED
_python_is_required() {
  local module
  for module in "${PY_REQUIRED[@]}"; do
    [[ "$module" != "$1" ]] || return 0
  done
  return 1
}

# Print the words $@ joined by " or "
_python_join() {
  local out
  printf -v out '%s or ' "$@"
  printf '%s\n' "${out% or }"
}

# Set the source of the requirements of version $2 of package file $1, whose AUR .SRCINFO is $3:
# PY_SOURCE (pypi, pyproject or none), PY_PROJECT, PY_VERSION, and PY_HEADERS for pyproject
python_source() {
  local tag value json
  PY_SOURCE="" PY_PROJECT="" PY_VERSION="" PY_HEADERS="" PY_NEWEST="" PY_TREE_ARCHIVE="" PY_TREE_TOP=""
  tag=$(pkg_get "$1" '.python | tag')
  if [[ "$tag" == "!!str" && "$(pkg_get "$1" .python)" == none ]]; then
    PY_SOURCE=none
    return 0
  fi
  if [[ "$(pkg_get "$1" .strategy)" == pypi ]]; then
    PY_SOURCE=pypi PY_PROJECT=$(pkg_get "$1" .upstream.registry) PY_VERSION=$2
    return 0
  fi
  if [[ "$tag" == "!!map" ]]; then
    value=$(pkg_get "$1" '.python.pypi // ""')
    if [[ -n "$value" ]]; then
      PY_SOURCE=pypi PY_PROJECT=$value PY_VERSION=$2
      [[ "$(pkg_get "$1" '.python.release // ""')" == newest ]] || return 0
      # shellcheck disable=SC2034 # fired_alerts reads it
      PY_NEWEST=1
      json=$(http_get_json "https://pypi.org/pypi/$value/json") || return 1
      PY_VERSION=$(yq -r '.info.version // ""' <<<"$json")
      if [[ ! "$PY_VERSION" =~ ^[A-Za-z0-9._+!-]+$ ]]; then
        log_err "https://pypi.org/pypi/$value/json names no version"
        return 1
      fi
      return 0
    fi
    value=$(pkg_get "$1" '.python.pyproject // ""')
    if [[ -n "$value" ]]; then
      _python_pyproject "$1" "$2" "$3" "$value"
      return
    fi
  fi
  log_err "packages/${1##*/}: its depends hold Python packages, so set python.pypi, python.pyproject or python: none"
  return 1
}

# python_source for python.pyproject $4 of package file $1 at version $2 with .SRCINFO $3: the
# [project] table of that file in the first https archive of the sources, at the new version
_python_pyproject() {
  local LC_ALL=C file=$1 path=$4 url="" line old new format dir top kind value name="" python="" has="" dynamic=""
  local fail="packages/${1##*/}: python.pyproject reads no static dependencies from $4"
  local -a deps=()
  # The rule removes directories below the one of the file, and runs read YAMLs that validate-pkg.sh did not
  if ! [[ "$path" =~ ^[A-Za-z0-9._/-]+\.toml$ ]] || [[ "$path" == /* || "/$path/" == */../* ]]; then
    log_err "packages/${1##*/}: python.pyproject must be a relative path to a .toml file without ..: ${path@Q}"
    return 1
  fi
  while IFS= read -r line; do
    line=${line#*::}
    if [[ "$line" == https://* && "$line" =~ \.(tar\.gz|tgz|tar\.xz|tar\.bz2|tar\.zst|zip)$ ]]; then
      url=$line
      break
    fi
  done < <(awk '/^\t(source|source_x86_64) = / { sub(/^\t[a-z0-9_]+ = /, ""); print }' "$3")
  if [[ -z "$url" ]]; then
    log_err "$fail: the .SRCINFO has no https archive among its sources"
    return 1
  fi
  old=$(srcinfo_pkgver "$3")
  format=$(pkg_get "$file" '.pkgver_format // ""')
  new=$(to_pkgver "$2" "$(pkgver_dash "$file")" "$format")
  url=$(_bump_version "$url" "$old" "$new" "$(_unformat_version "$old" "$format")" "$(_unformat_version "$new" "$format")" \
    "$(_srcinfo_arch_words "$3")")
  archdb_cache || return 1
  dir=$(mktemp -d "$AURTOMATOR_RUN_CACHE/pyproject.XXXXXX") || return 1
  # shellcheck disable=SC2034 # _curl_get of common.sh reads it
  MAX_ANSWER_MB=$(max_answer_mb "$file") || return 1
  http_get "$url" -o "$dir/archive" || return 1
  # The listing takes at most 16 MiB, and an ignored SIGXFSZ makes a write past it fail
  if ! (trap '' XFSZ && ulimit -f 16384 && bsdtar -tf "$dir/archive" >"$dir/list" 2>/dev/null) ||
    ! IFS= read -r top <"$dir/list"; then
    log_err "$fail: bsdtar cannot list $url"
    return 1
  fi
  top=${top%%/*}
  if [[ ! "$top" =~ ^[A-Za-z0-9._+-]+$ || "$top" == . || "$top" == .. ]]; then
    log_err "$fail: $url holds no top directory"
    return 1
  fi
  # pyproject.toml takes at most 256 KiB, and an ignored SIGXFSZ makes a write past it fail
  (trap '' XFSZ && ulimit -f 257 && bsdtar -xqOf "$dir/archive" -- "$top/$path" >"$dir/pyproject.toml" 2>/dev/null)
  if [[ ! -s "$dir/pyproject.toml" ]]; then
    log_err "$fail: $url holds no $top/$path"
    return 1
  fi
  if (($(stat -c %s "$dir/pyproject.toml") > 256 * 1024)); then
    log_err "$fail: $top/$path holds more than 256 KiB"
    return 1
  fi
  while IFS=$'\t' read -r kind value; do
    if [[ "$value" == *\\* ]] || has_control "$value"; then
      log_err "$fail: a value holds an escape or a control character: ${value@Q}"
      return 1
    fi
    case $kind in
      name) name=$value ;;
      python) python=$value ;;
      has) has=1 ;;
      dep) deps+=("$value") ;;
      dynamic) [[ "$value" != dependencies ]] || dynamic=1 ;;
      error)
        log_err "$fail: $value"
        return 1
        ;;
    esac
  done < <(_toml_project "$dir/pyproject.toml")
  if [[ -z "$has" || -n "$dynamic" ]]; then
    log_err "$fail"
    return 1
  fi
  PY_SOURCE=pyproject PY_PROJECT=${name:-$(package_name "$file")} PY_VERSION=$2
  PY_HEADERS="Name: $PY_PROJECT"
  [[ -z "$python" ]] || PY_HEADERS+=$'\n'"Requires-Python: $python"
  for value in "${deps[@]}"; do
    PY_HEADERS+=$'\n'"Requires-Dist: $value"
  done
  PY_TREE_ARCHIVE="$dir/archive"
  PY_TREE_TOP=$top
  [[ "$path" != */* ]] || PY_TREE_TOP+="/${path%/*}"
}

# Print the values of the [project] table of TOML file $1 that the rules read, lines of name,
# python, dep and dynamic, a tab and the value, has for a dependencies key, or error and the reason.
# The whole file is parsed, since strings and arrays can hold lines that look like a table header.
_toml_project() {
  LC_ALL=C awk '
    BEGIN { S = "\034" }
    function fail(m) { print "error\t" m; failed = 1; exit }
    function blank() { while (pos <= n && substr(t, pos, 1) ~ /[ \t]/) pos++ }
    function space(  c) {
      while (pos <= n) {
        c = substr(t, pos, 1)
        if (c ~ /[ \t\n]/) pos++
        else if (c == "#") { while (pos <= n && substr(t, pos, 1) != "\n") pos++ }
        else break
      }
    }
    # Escapes stay as written, and the caller refuses the values that hold one
    function text(  q, c, start, triple) {
      q = substr(t, pos, 1)
      triple = (substr(t, pos, 3) == q q q)
      pos += triple ? 3 : 1
      start = pos
      while (pos <= n) {
        c = substr(t, pos, 1)
        if (triple && substr(t, pos, 3) == q q q) { pos += 3; return substr(t, start, pos - 3 - start) }
        if (!triple && c == q) { pos++; return substr(t, start, pos - 1 - start) }
        if (!triple && c == "\n") fail("a string holds a line break")
        pos += (q == "\"" && c == "\\") ? 2 : 1
      }
      fail("a string has no end")
    }
    function part(  c, start) {
      c = substr(t, pos, 1)
      if (c == "\"" || c == "\047") return text()
      start = pos
      while (pos <= n && substr(t, pos, 1) ~ /[A-Za-z0-9_-]/) pos++
      if (pos == start) fail("a key holds an unknown character")
      return substr(t, start, pos - start)
    }
    # A dotted key, its parts joined by S
    function key(  k) {
      k = part(); blank()
      while (substr(t, pos, 1) == ".") { pos++; blank(); k = k S part(); blank() }
      return k
    }
    # The name that the caller reads for key path k, or nothing
    function field(k) {
      if (k == "project" S "dependencies") return "dep"
      if (k == "project" S "dynamic") return "dynamic"
      if (k == "project" S "name") return "name"
      if (k == "project" S "requires-python") return "python"
      return ""
    }
    function assign(k, depth) {
      if (k == "project" S "dependencies") print "has\t"
      value(k, field(k), depth)
    }
    function value(path, name, depth, inner,  c, s) {
      if (depth > 32) fail("values nest deeper than 32 levels")
      c = substr(t, pos, 1)
      if (c == "\"" || c == "\047") {
        s = text()
        if (name != "") print name "\t" s
        return
      }
      if ((name == "dep" || name == "dynamic") && (c == "{" || (c == "[" && inner)))
        fail("dependencies and dynamic hold strings alone")
      if (c == "[") {
        pos++
        for (;;) {
          space()
          if (substr(t, pos, 1) == "]") { pos++; return }
          value(path, name, depth + 1, 1)
          space()
          c = substr(t, pos, 1)
          if (c == ",") { pos++; continue }
          if (c == "]") { pos++; return }
          fail("an array holds an unknown character")
        }
      }
      if (c == "{") {
        pos++
        for (;;) {
          blank()
          if (substr(t, pos, 1) == "}") { pos++; return }
          s = key()
          if (substr(t, pos, 1) != "=") fail("an inline table holds a key without =")
          pos++; blank(); assign(path S s, depth + 1); blank()
          c = substr(t, pos, 1)
          if (c == ",") { pos++; continue }
          if (c == "}") { pos++; return }
          fail("an inline table holds an unknown character")
        }
      }
      if (name == "dep" || name == "dynamic") fail("dependencies and dynamic hold strings alone")
      while (pos <= n && substr(t, pos, 1) !~ /[,\]}\n#]/) pos++
    }
    # TOML ends lines with LF or CRLF
    { sub(/\r$/, ""); t = t $0 "\n" }
    END {
      n = length(t); pos = 1; table = ""
      for (;;) {
        space()
        if (pos > n) break
        if (substr(t, pos, 1) == "[") {
          if (substr(t, pos, 2) == "[[") {
            # Tables of an array of tables are never the [project] table
            pos += 2; blank(); table = "[[" S key()
            if (substr(t, pos, 2) != "]]") fail("a table header has no end")
            pos += 2
          } else {
            pos++; blank(); table = key()
            if (substr(t, pos, 1) != "]") fail("a table header has no end")
            pos++
          }
          continue
        }
        k = key()
        if (substr(t, pos, 1) != "=") fail("a line holds a key without =")
        pos++; blank()
        assign(table == "" ? k : table S k, 1)
      }
    }' "$1"
}
