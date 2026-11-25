#!/usr/bin/env bash
#
# requires.sh - The requirements of PyPI releases and their environment markers on Arch
#
# Sourced by lib.sh and strategies/pypi.sh.

# Print the PEP 503 form of PyPI project name $1, or fail for a name outside the name rule
pypi_name() {
  _pypi_norm "$1" || return 1
  printf '%s\n' "$PYPI_NORM"
}

# Set PYPI_NORM to the PEP 503 form of name $1: lowercase, each run of - _ . one dash
_pypi_norm() {
  local LC_ALL=C
  [[ "$1" =~ ^([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9])$ ]] || return 1
  PYPI_NORM=${1,,}
  PYPI_NORM=${PYPI_NORM//[_.]/-}
  while [[ "$PYPI_NORM" == *--* ]]; do
    PYPI_NORM=${PYPI_NORM//--/-}
  done
}

# Set REQUIRES_PY to X.Y and REQUIRES_PY_FULL to X.Y.Z of package python in the pacman
# databases, once per process. Without that answer both stay empty, which markers read as unknown.
_requires_python() {
  [[ -z "${REQUIRES_PY_READ:-}" ]] || return 0
  REQUIRES_PY_READ=1 REQUIRES_PY="" REQUIRES_PY_FULL=""
  local LC_ALL=C info line
  local re_version='^([0-9]+:)?(([0-9]+\.[0-9]+)\.[0-9]+)-[0-9]+(\.[0-9]+)?[[:blank:]]*$'
  info=$(LC_ALL=C pacman -Si python 2>/dev/null) || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^Version[[:blank:]]*:[[:blank:]]*(.*)$ ]] || continue
    if [[ "${BASH_REMATCH[1]}" =~ $re_version ]]; then
      REQUIRES_PY_FULL=${BASH_REMATCH[2]}
      REQUIRES_PY=${BASH_REMATCH[3]}
    fi
    return 0
  done <<<"$info"
}

# Set REQ_NAME to the PEP 503 name of requirement $1, REQ_EXTRAS to its extras in that form, joined by
# commas, REQ_SPEC to its clauses joined by commas without blanks, or @ for a URL, and REQ_MARKER
requirement_split() {
  local LC_ALL=C rest spec extras name extra
  local -a list
  local head='^[[:blank:]]*([A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?)[[:blank:]]*(\[[^][]*\])?(.*)$'
  local url='^[[:blank:]]*@[[:blank:]]*[^[:blank:]]+([[:blank:]]+;[[:blank:]]*([^[:blank:]](.*[^[:blank:]])?))?[[:blank:]]*$'
  local clause='[[:blank:]]*(<=|<|!=|===|==|>=|>|~=)[[:blank:]]*[A-Za-z0-9._*+!-]+[[:blank:]]*'
  local parens='^[[:blank:]]*\((.*)\)[[:blank:]]*$' trimmed='^[[:blank:]]*([^[:blank:]](.*[^[:blank:]])?)[[:blank:]]*$'
  REQ_NAME="" REQ_EXTRAS="" REQ_SPEC="" REQ_MARKER=""
  [[ "$1" =~ $head ]] || return 1
  rest=${BASH_REMATCH[4]} extras=${BASH_REMATCH[3]} name=${BASH_REMATCH[1]}
  extras=${extras#[}
  IFS=, read -ra list <<<"${extras%]}"
  for extra in "${list[@]}"; do
    [[ "$extra" =~ $trimmed ]] || continue
    _pypi_norm "${BASH_REMATCH[1]}" || return 1
    REQ_EXTRAS+="${REQ_EXTRAS:+,}$PYPI_NORM"
  done
  _pypi_norm "$name" || return 1
  if [[ "$rest" =~ ^[[:blank:]]*@ ]]; then
    [[ "$rest" =~ $url ]] || return 1
    REQ_NAME=$PYPI_NORM REQ_SPEC=@ REQ_MARKER=${BASH_REMATCH[2]}
    return 0
  fi
  spec=${rest%%;*}
  if [[ "$rest" == *\;* ]]; then
    [[ "${rest#*;}" =~ $trimmed ]] || return 1
    REQ_MARKER=${BASH_REMATCH[1]}
  fi
  if [[ "$spec" =~ $parens ]]; then
    spec=${BASH_REMATCH[1]}
    [[ "$spec" =~ ^${clause}(,${clause})*(,[[:blank:]]*)?$ ]] || return 1
  elif [[ "$spec" == *[![:blank:]]* ]]; then
    [[ "$spec" =~ ^${clause}(,${clause})*(,[[:blank:]]*)?$ ]] || return 1
  fi
  spec=${spec//[[:blank:]]/}
  REQ_NAME=$PYPI_NORM REQ_SPEC=${spec%,}
}

# Print 1, 0 or ? for environment marker $1 on Arch: true, false, or unknown for a field the
# check does not know and for text outside the grammar of PEP 508
marker_value() {
  _marker_eval "$1"
  printf '%s\n' "$MARKER_VALUE"
}

# Set MARKER_VALUE to what marker_value prints for marker $1
_marker_eval() {
  local LC_ALL=C beyond=$'[^\t -~]'
  MARKER_VALUE='?'
  if ((${#1} > 1024)) || [[ "$1" =~ $beyond ]]; then
    return 0
  fi
  _marker_tokens "$1" || return 0
  _MK_POS=0
  _marker_or 0 || return 0
  ((_MK_POS == ${#_MK_KIND[@]})) || return 0
  MARKER_VALUE=$_MK_VAL
}

# Split marker $1 into the kinds _MK_KIND, one of ( ) op str and or name, and the texts
# _MK_TEXT; fail on text that is no token
_marker_tokens() {
  local s=$1 pos=0 rest
  local re_blank='^[[:blank:]]+' re_op='^(<=|<|!=|===|==|>=|>|~=)' re_dq='^"([^"]*)"' re_sq="^'([^']*)'"
  local re_not_in='^(not[[:blank:]]+in)([^A-Za-z0-9_]|$)' re_word='^(and|or|in)([^A-Za-z0-9_]|$)'
  local re_name='^([a-z_]+)([^A-Za-z0-9_]|$)'
  _MK_KIND=() _MK_TEXT=()
  while ((pos < ${#s})); do
    rest=${s:pos}
    if [[ "$rest" =~ $re_blank ]]; then
      pos=$((pos + ${#BASH_REMATCH[0]}))
    elif [[ "$rest" == [\(\)]* ]]; then
      _MK_KIND+=("${rest:0:1}") _MK_TEXT+=("${rest:0:1}")
      pos=$((pos + 1))
    elif [[ "$rest" =~ $re_op ]]; then
      _MK_KIND+=(op) _MK_TEXT+=("${BASH_REMATCH[1]}")
      pos=$((pos + ${#BASH_REMATCH[1]}))
    elif [[ "$rest" =~ $re_dq || "$rest" =~ $re_sq ]]; then
      _MK_KIND+=(str) _MK_TEXT+=("${BASH_REMATCH[1]}")
      pos=$((pos + ${#BASH_REMATCH[0]}))
    elif [[ "$rest" =~ $re_not_in ]]; then
      _MK_KIND+=(op) _MK_TEXT+=("not in")
      pos=$((pos + ${#BASH_REMATCH[1]}))
    elif [[ "$rest" =~ $re_word ]]; then
      if [[ "${BASH_REMATCH[1]}" == in ]]; then _MK_KIND+=(op); else _MK_KIND+=("${BASH_REMATCH[1]}"); fi
      _MK_TEXT+=("${BASH_REMATCH[1]}")
      pos=$((pos + ${#BASH_REMATCH[1]}))
    elif [[ "$rest" =~ $re_name ]]; then
      _MK_KIND+=(name) _MK_TEXT+=("${BASH_REMATCH[1]}")
      pos=$((pos + ${#BASH_REMATCH[1]}))
    else
      return 1
    fi
  done
}

# The parser over the tokens from _MK_POS on: each function sets _MK_VAL to 1, 0 or ?, and
# fails on a token the grammar does not allow there. $1 is the depth of parentheses.
_marker_or() {
  local left
  _marker_and "$1" || return 1
  left=$_MK_VAL
  while [[ "${_MK_KIND[_MK_POS]-}" == or ]]; do
    _MK_POS=$((_MK_POS + 1))
    _marker_and "$1" || return 1
    if [[ "$left" == 1 || "$_MK_VAL" == 1 ]]; then
      left=1
    elif [[ "$left" != 0 || "$_MK_VAL" != 0 ]]; then
      left='?'
    fi
  done
  _MK_VAL=$left
}

_marker_and() {
  local left
  _marker_atom "$1" || return 1
  left=$_MK_VAL
  while [[ "${_MK_KIND[_MK_POS]-}" == and ]]; do
    _MK_POS=$((_MK_POS + 1))
    _marker_atom "$1" || return 1
    if [[ "$left" == 0 || "$_MK_VAL" == 0 ]]; then
      left=0
    elif [[ "$left" != 1 || "$_MK_VAL" != 1 ]]; then
      left='?'
    fi
  done
  _MK_VAL=$left
}

_marker_atom() {
  local i=$_MK_POS
  if [[ "${_MK_KIND[i]-}" == "(" ]]; then
    (($1 < 16)) || return 1
    _MK_POS=$((i + 1))
    _marker_or $(($1 + 1)) || return 1
    [[ "${_MK_KIND[_MK_POS]-}" == ")" ]] || return 1
    _MK_POS=$((_MK_POS + 1))
    return 0
  fi
  [[ "${_MK_KIND[i]-}" =~ ^(name|str)$ && "${_MK_KIND[i + 1]-}" == op && "${_MK_KIND[i + 2]-}" =~ ^(name|str)$ ]] || return 1
  _MK_POS=$((i + 3))
  _marker_compare "${_MK_KIND[i]}" "${_MK_TEXT[i]}" "${_MK_TEXT[i + 1]}" "${_MK_KIND[i + 2]}" "${_MK_TEXT[i + 2]}"
}

# Set _MK_VAL for the comparison of a token of kind $1 and text $2, operator $3, and a token of
# kind $4 and text $5. Each field takes its value on Arch, and an empty value is unknown.
_marker_compare() {
  local field const swapped=""
  if [[ "$1" == name && "$4" == str ]]; then
    field=$2 const=$5
  elif [[ "$1" == str && "$4" == name ]]; then
    field=$5 const=$2 swapped=1
  else
    _MK_VAL='?'
    return 0
  fi
  case $field in
    os_name) _marker_string "$3" "$const" "$swapped" posix ;;
    sys_platform) _marker_string "$3" "$const" "$swapped" linux ;;
    platform_system) _marker_string "$3" "$const" "$swapped" Linux ;;
    platform_python_implementation) _marker_string "$3" "$const" "$swapped" CPython ;;
    implementation_name) _marker_string "$3" "$const" "$swapped" cpython ;;
    # Packages can build for several arches, so the machine is unknown
    platform_machine) _marker_string "$3" "$const" "$swapped" "" ;;
    python_version)
      _requires_python
      _marker_version "$3" "$const" "$swapped" "$REQUIRES_PY"
      ;;
    python_full_version | implementation_version)
      _requires_python
      _marker_version "$3" "$const" "$swapped" "$REQUIRES_PY_FULL"
      ;;
    extra) _marker_extra "$3" "$const" ;;
    *) _MK_VAL='?' ;;
  esac
}

# Set _MK_VAL for operator $1 between field extra and constant $2: the check asks for the extras of
# MARKER_EXTRAS, none by default, and the specification lets a tool reject extra != without extras
_marker_extra() {
  local extra
  if [[ -z "${MARKER_EXTRAS:-}" || ("$1" != "==" && "$1" != "!=") ]]; then
    if [[ "$1" == "!=" ]]; then _MK_VAL='?'; else _MK_VAL=0; fi
    return 0
  fi
  _MK_VAL=0
  if _pypi_norm "$2"; then
    for extra in ${MARKER_EXTRAS//,/ }; do
      [[ "$extra" != "$PYPI_NORM" ]] || _MK_VAL=1
    done
  fi
  [[ "$1" == "==" ]] || _MK_VAL=$((1 - _MK_VAL))
}

# Set _MK_VAL for operator $1 between a string field of value $4 and constant $2, where $3 is
# set for a field right of the operator. > and < are false, and ~= === >= <= compare as ==.
_marker_string() {
  local hit=0
  if [[ "$1" == "<" || "$1" == ">" ]]; then
    _MK_VAL=0
    return 0
  fi
  if [[ -z "$4" ]]; then
    _MK_VAL='?'
    return 0
  fi
  case $1 in
    in | "not in")
      if [[ -n "$3" && "$4" == *"$2"* ]] || [[ -z "$3" && "$2" == *"$4"* ]]; then hit=1; fi
      [[ "$1" == in ]] || hit=$((1 - hit))
      ;;
    "!=") [[ "$4" == "$2" ]] || hit=1 ;;
    *) [[ "$4" != "$2" ]] || hit=1 ;;
  esac
  _MK_VAL=$hit
}

# Set _MK_VAL for operator $1 between a version field of value $4 and constant $2, $3 set for a field
# right of it: the left side meets the right as packaging tests markers, text outside PEP 440 is unknown
_marker_version() {
  local rc=0
  _MK_VAL='?'
  # packaging tests in and not in on the text of a version field, as on a string field
  if [[ "$1" == in || "$1" == "not in" ]]; then
    _marker_string "$@"
    return 0
  fi
  [[ -n "$4" ]] || return 0
  if [[ "$1" == "===" ]]; then
    if [[ "${4,,}" == "${2,,}" ]]; then _MK_VAL=1; else _MK_VAL=0; fi
    return 0
  fi
  [[ "$2" != *,* ]] || return 0
  if [[ -n "$3" ]]; then
    pep440_holds "$2" "$1$4" || rc=$?
  else
    pep440_holds "$4" "$1$2" || rc=$?
  fi
  case $rc in
    0) _MK_VAL=1 ;;
    1) _MK_VAL=0 ;;
  esac
}

# The simple pages of PyPI projects that this process read, by PEP 503 name
declare -gA _PYPI_SIMPLE

# Set PYPI_RELEASE to the version PyPI lists for release $2 of project $1 under PEP 440, PYPI_FILES to its
# files not yanked (name, URL, sha256, metadata sha256 or -, size); return 3 when PyPI lists no such release
pypi_release() {
  local LC_ALL=C norm page version found="" line name url sha core size stem
  local -a versions rows
  PYPI_RELEASE="" PYPI_FILES=""
  if ! _pypi_norm "$1"; then
    log_err "$1 is not a PyPI project name"
    return 1
  fi
  norm=$PYPI_NORM
  if [[ -z "${_PYPI_SIMPLE[$norm]+set}" ]]; then
    page=$(http_get_json "https://pypi.org/simple/$norm/" -H 'Accept: application/vnd.pypi.simple.v1+json') || return 1
    _PYPI_SIMPLE[$norm]=$page
  fi
  page=${_PYPI_SIMPLE[$norm]}
  if [[ "$(yq '.versions | tag' <<<"$page")" != '!!seq' ]]; then
    log_err "https://pypi.org/simple/$norm/: the answer lists no versions"
    return 1
  fi
  mapfile -t versions < <(yq -r '.versions[] | select(tag == "!!str")' <<<"$page")
  for version in "${versions[@]}"; do
    if [[ "$version" == "$2" ]]; then
      found=$version
      break
    fi
  done
  if [[ -z "$found" ]]; then
    for version in "${versions[@]}"; do
      if pep440_cmp "$version" "$2" && ((PEP440_ORDER == 0)); then
        found=$version
        break
      fi
    done
  fi
  if [[ -z "$found" ]]; then
    log_err "$1: PyPI has no release $2"
    return 3
  fi
  # shellcheck disable=SC2034 # callers read it
  PYPI_RELEASE=$found
  mapfile -t rows < <(yq -r '.files[] | select((.yanked // false) == false) | [.filename, .url, (.hashes.sha256 // "-"),
    ((."core-metadata" | select(tag == "!!map") | .sha256) // "-"), (.size // 0 | tostring)] | join("\t")' <<<"$page")
  for line in "${rows[@]}"; do
    IFS=$'\t' read -r name url sha core size <<<"$line"
    [[ "$name" =~ ^[A-Za-z0-9._+!-]+$ && "$url" =~ ^https://[!-~]+$ && "$sha" =~ ^[0-9a-f]{64}$ &&
      "$core" =~ ^([0-9a-f]{64}|-)$ && "$size" =~ ^[0-9]+$ ]] || continue
    case $name in
      *.whl) [[ "$name" == *"-$found-"* || "$name" == *"-${found//-/_}-"* ]] || continue ;;
      *.tar.gz | *.zip)
        stem=${name%.tar.gz}
        stem=${stem%.zip}
        [[ "$stem" == *"-$found" || "$stem" == *"-${found//-/_}" ]] || continue
        ;;
      *) continue ;;
    esac
    PYPI_FILES+="$name"$'\t'"$url"$'\t'"$sha"$'\t'"$core"$'\t'"$size"$'\n'
  done
  PYPI_FILES=${PYPI_FILES%$'\n'}
}

# Print the metadata headers of release $2 of project $1: .metadata of a wheel (none-any, linux x86_64, any),
# else PKG-INFO of the sdist; return 3 without the release, 4 without metadata that lists the requirements
pypi_metadata() {
  local LC_ALL=C name url sha core size pick="" tmp rc=0
  local -a linux=() other=() sdists=()
  pypi_release "$1" "$2" || return
  while IFS=$'\t' read -r name url sha core size; do
    case $name in
      "") ;;
      *.whl)
        [[ "$core" != - ]] || continue
        if [[ "$name" == *-none-any.whl ]]; then
          pick=${pick:-$name$'\t'$url.metadata$'\t'$core}
        elif [[ "$name" == *linux* && "$name" == *x86_64* ]]; then
          linux+=("$name.metadata"$'\t'"$url.metadata"$'\t'"$core")
        else
          other+=("$name.metadata"$'\t'"$url.metadata"$'\t'"$core")
        fi
        ;;
      *) sdists+=("$name"$'\t'"$url"$'\t'"$sha") ;;
    esac
  done <<<"$PYPI_FILES"
  if [[ -n "$pick" ]]; then
    pick=${pick/$'\t'/.metadata$'\t'}
  else
    pick=${linux[0]:-${other[0]:-${sdists[0]:-}}}
  fi
  if [[ -z "$pick" ]]; then
    log_err "$1 $2: PyPI holds no metadata that lists the requirements without running code"
    return 4
  fi
  IFS=$'\t' read -r name url sha <<<"$pick"
  tmp=$(mktemp) || return 1
  http_get "$url" -o "$tmp" || rc=1
  if ((rc == 0)) && [[ "$(sha256sum "$tmp")" != "$sha "* ]]; then
    log_err "$name does not match its sha256"
    rc=1
  fi
  if ((rc == 0)); then
    if [[ "$name" == *.metadata ]]; then
      _metadata_headers "$tmp" "$name" || rc=1
    else
      _sdist_headers "$tmp" "$name" "$1 $2" || rc=$?
    fi
  fi
  rm -f "$tmp"
  return "$rc"
}

# Print the headers of PKG-INFO in the top directory of sdist $1, named as file name $2 without
# its extension, when they list the requirements; return 4 with an error naming release $3 if not
_sdist_headers() {
  local LC_ALL=C member out headers="" version dynamic rc=0
  member=${2%.tar.gz}
  member="${member%.zip}/PKG-INFO"
  out=$(mktemp) || return 1
  # --fast-read stops at the first match, and an ignored SIGXFSZ makes a write past MAX_ANSWER_MB fail
  if (trap '' XFSZ && ulimit -f $((${MAX_ANSWER_MB:-50} * 1024)) && bsdtar -xqOf "$1" -- "$member" >"$out" 2>/dev/null); then
    headers=$(_metadata_headers "$out" "$2/$member") || rc=1
  else
    member=""
  fi
  rm -f "$out"
  ((rc == 0)) || return 1
  version=$(metadata_field "$headers" Metadata-Version)
  dynamic=$(metadata_field "$headers" Dynamic)
  if [[ -z "$member" ]] || ! pep440_cmp "${version:-0}" 2.2 2>/dev/null || ((PEP440_ORDER < 0)) ||
    [[ $'\n'"${dynamic,,}"$'\n' == *$'\nrequires-dist\n'* ]]; then
    log_err "$3: PyPI holds no metadata that lists the requirements without running code"
    return 4
  fi
  printf '%s\n' "$headers"
}

# Print the headers of metadata file $1, named $2 in errors, folded lines joined and CR dropped; fail on
# other control characters in a header that the rules read, and make those of License or others spaces
_metadata_headers() {
  local LC_ALL=C line out="" header=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    [[ -n "$line" ]] || break
    [[ "$line" == [[:blank:]]* && -n "$out" ]] || header=${line%%:*}
    if has_control "$line"; then
      case ${header,,} in
        metadata-version | name | version | requires-dist | requires-python | dynamic)
          log_err "$2 holds a control character in $header"
          return 1
          ;;
      esac
      line=${line//[[:cntrl:]]/ }
      line=${line//$'\xc2'[$'\x80'-$'\x9f']/ }
    fi
    if [[ "$line" == [[:blank:]]* && -n "$out" ]]; then
      out+=" ${line#"${line%%[![:blank:]]*}"}"
    else
      out+=$'\n'"$line"
    fi
  done <"$1"
  printf '%s\n' "${out#$'\n'}"
}

# Print the values of field $2 in metadata headers $1, one per line; field names match in any case
metadata_field() {
  local LC_ALL=C line name=${2,,}
  while IFS= read -r line; do
    [[ "${line,,}" == "$name:"* ]] || continue
    line=${line:${#name}+1}
    line=${line#"${line%%[![:blank:]]*}"}
    printf '%s\n' "${line%"${line##*[![:blank:]]}"}"
  done <<<"$1"
}

# Print the PEP 503 names of the requirements in metadata headers $1 whose markers are not false
# on Arch, sorted; fail on requirements it cannot read, with errors that name release $2
requires_names() {
  local req
  local -a names=()
  _requires_list "$1" "$2" || return 1
  for req in "${REQUIRES_LIST[@]}"; do
    _requirement_read "$req" "$2" || return 1
    [[ "$MARKER_VALUE" == 0 ]] || names+=("$REQ_NAME")
  done
  if ((${#names[@]} > 0)); then
    printf '%s\n' "${names[@]}" | LC_ALL=C sort -u
  fi
}

# Print the version that metadata headers $1 of project $2 pin its requirement on project $3 to
# with ==; fail unless the requirements on $3 that apply on Arch pin one version
requires_pin() {
  local req want joined
  local -a pins=()
  if ! _pypi_norm "$3"; then
    log_err "$3 is not a PyPI project name"
    return 1
  fi
  want=$PYPI_NORM
  _requires_list "$1" "$2" || return 1
  for req in "${REQUIRES_LIST[@]}"; do
    _requirement_read "$req" "$2" || return 1
    [[ "$REQ_NAME" == "$want" && "$MARKER_VALUE" != 0 ]] || continue
    if [[ ! "$REQ_SPEC" =~ ^==([A-Za-z0-9._+!-]+)$ ]]; then
      log_err "$2 requires ${req@Q}, which pins no single version of $3"
      return 1
    fi
    pins+=("${BASH_REMATCH[1]}")
  done
  if ((${#pins[@]} == 0)); then
    log_err "$2 lists no requirement on $3 that applies on Arch"
    return 1
  fi
  mapfile -t pins < <(printf '%s\n' "${pins[@]}" | LC_ALL=C sort -u)
  if ((${#pins[@]} > 1)); then
    printf -v joined '%s, ' "${pins[@]}"
    log_err "$2 pins $3 to more than one version: ${joined%, }"
    return 1
  fi
  printf '%s\n' "${pins[0]}"
}

# Print how the requirement names that apply on Arch change from release $2 to release $3 of PyPI
# project $4, upstream.registry of package file $1 by default, as adds a, b; drops c, or nothing
requires_change() {
  local registry err old new name added dropped rc=0
  local -A in_old=() in_new=()
  local -a adds=() drops=()
  registry=${4:-$(pkg_get "$1" .upstream.registry)} || return 1
  # shellcheck disable=SC2034 # _curl_get of common.sh reads it
  MAX_ANSWER_MB=$(max_answer_mb "$1") || return 1
  for name in "$2" "$3"; do
    if [[ ! "$name" =~ ^[A-Za-z0-9._+!-]+$ ]]; then
      log_err "PyPI versions hold A-Za-z0-9._+!- alone: ${name@Q}"
      return 1
    fi
  done
  # Reads the simple page once for both releases
  pypi_release "$registry" "$3" || return 1
  # Only a publish moves current, so a release of current that PyPI cannot read fires the rule
  err=$(mktemp) || return 1
  old=$(pypi_metadata "$registry" "$2" 2>"$err") || rc=$?
  case $rc in
    0) ;;
    3) printf 'PyPI has no release %s of %s to compare with\n' "$2" "$registry" ;;
    4) printf '%s %s: PyPI holds no metadata that lists the requirements without running code\n' "$registry" "$2" ;;
    *) cat "$err" >&2 ;;
  esac
  rm -f "$err"
  case $rc in
    0) ;;
    3 | 4) return 0 ;;
    *) return 1 ;;
  esac
  new=$(pypi_metadata "$registry" "$3") || return 1
  old=$(requires_names "$old" "$registry $2") || return 1
  new=$(requires_names "$new" "$registry $3") || return 1
  while IFS= read -r name; do
    [[ -z "$name" ]] || in_old[$name]=1
  done <<<"$old"
  while IFS= read -r name; do
    [[ -z "$name" ]] || in_new[$name]=1
    [[ -z "$name" || -n "${in_old[$name]:-}" ]] || adds+=("$name")
  done <<<"$new"
  while IFS= read -r name; do
    [[ -z "$name" || -n "${in_new[$name]:-}" ]] || drops+=("$name")
  done <<<"$old"
  printf -v added '%s, ' "${adds[@]}"
  printf -v dropped '%s, ' "${drops[@]}"
  if ((${#adds[@]} > 0 && ${#drops[@]} > 0)); then
    printf 'adds %s; drops %s\n' "${added%, }" "${dropped%, }"
  elif ((${#adds[@]} > 0)); then
    printf 'adds %s\n' "${added%, }"
  elif ((${#drops[@]} > 0)); then
    printf 'drops %s\n' "${dropped%, }"
  fi
}

# Run requirement_split on requirement $1 and set MARKER_VALUE for its marker, 1 without one;
# fail with an error that names release $2
_requirement_read() {
  if ! requirement_split "$1"; then
    log_err "$2: cannot read the requirement ${1@Q}"
    return 1
  fi
  MARKER_VALUE=1
  [[ -z "$REQ_MARKER" ]] || _marker_eval "$REQ_MARKER"
}

# Set REQUIRES_LIST to the Requires-Dist values of metadata headers $1 and REQUIRES_PYTHON to its
# Requires-Python; fail with an error that names release $2 on a control character
_requires_list() {
  local req
  local -a python
  mapfile -t REQUIRES_LIST < <(metadata_field "$1" Requires-Dist)
  mapfile -t python < <(metadata_field "$1" Requires-Python)
  # shellcheck disable=SC2034 # pyrules.sh reads it
  REQUIRES_PYTHON=${python[0]:-}
  for req in "${REQUIRES_LIST[@]}"; do
    if has_control "$req"; then
      log_err "$2: Requires-Dist holds a control character: ${req@Q}"
      return 1
    fi
  done
}
