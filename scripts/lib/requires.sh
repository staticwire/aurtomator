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

# Set REQ_NAME to the PEP 503 name of requirement $1, REQ_SPEC to its version clauses joined
# by commas without blanks, or @ for a URL, and REQ_MARKER to its marker; fail outside PEP 508
requirement_split() {
  local LC_ALL=C rest spec
  local head='^[[:blank:]]*([A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?)[[:blank:]]*(\[[^][]*\])?(.*)$'
  local url='^[[:blank:]]*@[[:blank:]]*[^[:blank:]]+([[:blank:]]+;[[:blank:]]*([^[:blank:]](.*[^[:blank:]])?))?[[:blank:]]*$'
  local clause='[[:blank:]]*(<=|<|!=|===|==|>=|>|~=)[[:blank:]]*[A-Za-z0-9._*+!-]+[[:blank:]]*'
  local parens='^[[:blank:]]*\((.*)\)[[:blank:]]*$' trimmed='^[[:blank:]]*([^[:blank:]](.*[^[:blank:]])?)[[:blank:]]*$'
  REQ_NAME="" REQ_SPEC="" REQ_MARKER=""
  [[ "$1" =~ $head ]] || return 1
  rest=${BASH_REMATCH[4]}
  _pypi_norm "${BASH_REMATCH[1]}" || return 1
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
    # The check asks for no extras, and the specification lets a tool reject extra !=
    extra) if [[ "$3" == "!=" ]]; then _MK_VAL='?'; else _MK_VAL=0; fi ;;
    *) _MK_VAL='?' ;;
  esac
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

# Set _MK_VAL for operator $1 between a version field of value $4 and constant $2, where $3 is
# set for a field right of the operator; in and not in are false, forms beyond the subset unknown
_marker_version() {
  local op=$1 const=$2 release
  local re_version='^[0-9]+(\.[0-9]+)*((a|b|rc)[0-9]+)?$' re_release='^[0-9]+(\.[0-9]+)*$'
  _MK_VAL='?'
  if [[ "$op" == in || "$op" == "not in" ]]; then
    _MK_VAL=0
    return 0
  fi
  [[ -n "$4" ]] || return 0
  if [[ "$op" == "===" ]]; then
    if [[ "${4,,}" == "${const,,}" ]]; then _MK_VAL=1; else _MK_VAL=0; fi
    return 0
  fi
  if [[ -n "$3" ]]; then
    case $op in
      "<") op=">" ;;
      ">") op="<" ;;
      "<=") op=">=" ;;
      ">=") op="<=" ;;
      "~=") return 0 ;;
    esac
    [[ "$const" != *".*" ]] || return 0
  fi
  [[ "$4" =~ $re_version ]] || return 0
  if [[ "$const" == *".*" ]]; then
    release=${const%".*"}
    if [[ "$op" != "==" && "$op" != "!=" ]] || [[ ! "$release" =~ $re_release ]]; then
      return 0
    fi
    if _pep440_prefix "$4" "$release"; then _MK_VAL=1; else _MK_VAL=0; fi
    [[ "$op" == "==" ]] || _MK_VAL=$((1 - _MK_VAL))
    return 0
  fi
  [[ "$const" =~ $re_version ]] || return 0
  release=${const%%[abr]*}
  [[ "$op" != "~=" || "$release" == *.* ]] || return 0
  if _version_holds "$op" "$4" "$const"; then _MK_VAL=1; else _MK_VAL=0; fi
}

# Succeed when version $2 stands in relation $1 to version $3, both of the subset of _pep440_cmp
_version_holds() {
  local release=${3%%[abr]*}
  _pep440_cmp "$2" "$3"
  case $1 in
    "==") ((PEP440_ORDER == 0)) ;;
    "!=") ((PEP440_ORDER != 0)) ;;
    "<") ((PEP440_ORDER < 0)) ;;
    "<=") ((PEP440_ORDER <= 0)) ;;
    ">") ((PEP440_ORDER > 0)) ;;
    ">=") ((PEP440_ORDER >= 0)) ;;
    *) ((PEP440_ORDER >= 0)) && _pep440_prefix "$2" "${release%.*}" ;;
  esac
}

# Set PEP440_ORDER to -1, 0 or 1 as version $1 sorts before, with or after version $2, both
# N(.N)* with an optional a, b or rc and a number. vercmp puts 3.14.0 after 3.14.
_pep440_cmp() {
  local LC_ALL=C left=${1%%[abr]*} right=${2%%[abr]*} i n
  local -a lparts rparts
  IFS=. read -ra lparts <<<"$left"
  IFS=. read -ra rparts <<<"$right"
  n=$((${#lparts[@]} > ${#rparts[@]} ? ${#lparts[@]} : ${#rparts[@]}))
  for ((i = 0; i < n; i++)); do
    _number_order "${lparts[i]:-0}" "${rparts[i]:-0}"
    ((PEP440_ORDER == 0)) || return 0
  done
  _pre_order "${1#"$left"}" "${2#"$right"}"
}

# Set PEP440_ORDER for the numbers of digit strings $1 and $2, which can exceed bash integers
_number_order() {
  local a=${1#"${1%%[!0]*}"} b=${2#"${2%%[!0]*}"}
  if ((${#a} != ${#b})); then
    PEP440_ORDER=$((${#a} < ${#b} ? -1 : 1))
  elif [[ "$a" < "$b" ]]; then
    PEP440_ORDER=-1
  elif [[ "$a" > "$b" ]]; then
    PEP440_ORDER=1
  else
    PEP440_ORDER=0
  fi
}

# Set PEP440_ORDER for pre-release parts $1 and $2: none sorts after rc, rc after b, b after a
_pre_order() {
  local part
  local -a rank=()
  for part in "$1" "$2"; do
    case $part in
      "") rank+=(4) ;;
      rc*) rank+=(3) ;;
      b*) rank+=(2) ;;
      *) rank+=(1) ;;
    esac
  done
  if ((rank[0] != rank[1])); then
    PEP440_ORDER=$((rank[0] < rank[1] ? -1 : 1))
  elif ((rank[0] == 4)); then
    PEP440_ORDER=0
  else
    _number_order "${1##*[a-z]}" "${2##*[a-z]}"
  fi
}

# Succeed when the release parts of version $1, padded with zeros, start with release $2
_pep440_prefix() {
  local LC_ALL=C i
  local -a vparts pparts
  IFS=. read -ra vparts <<<"${1%%[abr]*}"
  IFS=. read -ra pparts <<<"$2"
  for i in "${!pparts[@]}"; do
    _number_order "${vparts[i]:-0}" "${pparts[i]}"
    ((PEP440_ORDER == 0)) || return 1
  done
}

# Print the PEP 503 names of the requirements in PyPI answer $1 whose markers are not false on
# Arch, sorted; fail on requirements it cannot read, with errors that name release $2
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

# Print the version that PyPI answer $1 of project $2 pins its requirement on project $3 to
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

# Print how the requirement names that apply on Arch change from release $2 to release $3 of
# upstream.registry of package file $1, as adds a, b; drops c, and nothing when they match
requires_change() {
  local registry err old new name added dropped
  local -A in_old=() in_new=()
  local -a adds=() drops=()
  registry=$(pkg_get "$1" .upstream.registry) || return 1
  # shellcheck disable=SC2034 # _curl_get of common.sh reads it
  MAX_ANSWER_MB=$(max_answer_mb "$1") || return 1
  for name in "$2" "$3"; do
    if [[ ! "$name" =~ ^[A-Za-z0-9._+!-]+$ ]]; then
      log_err "PyPI versions hold A-Za-z0-9._+!- alone: ${name@Q}"
      return 1
    fi
  done
  # Only a publish moves current, so a release of current that PyPI lacks fires the rule
  err=$(mktemp) || return 1
  if ! old=$(http_get_json "https://pypi.org/pypi/${registry}/${2}/json" 2>"$err"); then
    if grep -q ': The requested URL returned error: 404$' "$err"; then
      rm -f "$err"
      printf 'PyPI has no release %s of %s to compare with\n' "$2" "$registry"
      return 0
    fi
    cat "$err" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  new=$(http_get_json "https://pypi.org/pypi/${registry}/${3}/json") || return 1
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

# Set REQUIRES_LIST to the items of info.requires_dist of PyPI answer $1, none for null; fail
# with an error that names release $2 unless that list holds lines of text
_requires_list() {
  local tag dist counts count other req
  REQUIRES_LIST=()
  tag=$(yq -r 'if (.info | tag) == "!!map" and (.info | has("requires_dist")) then (.info.requires_dist | tag) else "none" end' <<<"$1" 2>/dev/null) || tag=none
  case $tag in
    "!!null") return 0 ;;
    "!!seq") ;;
    none)
      log_err "$2: the PyPI answer holds no info.requires_dist"
      return 1
      ;;
    *)
      log_err "$2: info.requires_dist is $tag, not a list"
      return 1
      ;;
  esac
  dist=$(yq -o json -I0 '.info.requires_dist' <<<"$1") || return 1
  counts=$(yq -r '(length | tostring) + " " + ([.[] | select(tag != "!!str")] | length | tostring)' <<<"$dist") || return 1
  read -r count other <<<"$counts"
  if ((other > 0)); then
    log_err "$2: info.requires_dist holds an item that is not text: $(yq -o json -I0 '[.[] | select(tag != "!!str")][0]' <<<"$dist")"
    return 1
  fi
  ((count > 0)) || return 0
  mapfile -t REQUIRES_LIST < <(yq -r '.[]' <<<"$dist")
  if ((${#REQUIRES_LIST[@]} != count)); then
    log_err "$2: info.requires_dist holds an item with a line break"
    return 1
  fi
  for req in "${REQUIRES_LIST[@]}"; do
    if has_control "$req"; then
      log_err "$2: info.requires_dist holds a control character: ${req@Q}"
      return 1
    fi
  done
}
