#!/usr/bin/env bash
#
# pep440.sh - Versions of PEP 440: their parts, their order and the clauses of version specifiers
#
# Sourced by lib.sh and strategies/pypi.sh.

# Set the parts of version $1, or fail outside PEP 440: PV_EPOCH, PV_RELEASE (numbers joined by
# dots), PV_PRE_L (a, b, rc or empty), PV_PRE_N, PV_POST, PV_DEV and PV_LOCAL (dot-separated)
pep440_parse() {
  local LC_ALL=C v=${1,,} part release=""
  local re='^[[:blank:]]*v?(([0-9]+)!)?([0-9]+(\.[0-9]+)*)([-_.]?(alpha|beta|preview|pre|rc|a|b|c)[-_.]?([0-9]+)?)?((-([0-9]+))|([-_.]?(post|rev|r)[-_.]?([0-9]+)?))?([-_.]?(dev)[-_.]?([0-9]+)?)?(\+([a-z0-9]+([-_.][a-z0-9]+)*))?[[:blank:]]*$'
  [[ "$v" =~ $re ]] || return 1
  _pep440_int "${BASH_REMATCH[2]:-0}"
  PV_EPOCH=$PEP440_INT
  PV_PRE_L=${BASH_REMATCH[6]} PV_PRE_N="" PV_POST="" PV_DEV=""
  case $PV_PRE_L in
    alpha) PV_PRE_L=a ;;
    beta) PV_PRE_L=b ;;
    c | pre | preview) PV_PRE_L=rc ;;
  esac
  if [[ -n "$PV_PRE_L" ]]; then
    _pep440_int "${BASH_REMATCH[7]:-0}"
    PV_PRE_N=$PEP440_INT
  fi
  if [[ -n "${BASH_REMATCH[10]}" ]]; then
    _pep440_int "${BASH_REMATCH[10]}"
    PV_POST=$PEP440_INT
  elif [[ -n "${BASH_REMATCH[12]}" ]]; then
    _pep440_int "${BASH_REMATCH[13]:-0}"
    PV_POST=$PEP440_INT
  fi
  if [[ -n "${BASH_REMATCH[15]}" ]]; then
    _pep440_int "${BASH_REMATCH[16]:-0}"
    PV_DEV=$PEP440_INT
  fi
  PV_LOCAL=${BASH_REMATCH[18]//[-_]/.}
  local -a parts
  IFS=. read -ra parts <<<"${BASH_REMATCH[3]}"
  for part in "${parts[@]}"; do
    _pep440_int "$part"
    release+=".$PEP440_INT"
  done
  PV_RELEASE=${release#.}
}

# Set PEP440_ORDER to -1, 0 or 1 as version $1 sorts before, with or after version $2; fail when
# either is outside PEP 440
pep440_cmp() {
  pep440_parse "$1" || return 1
  _pep440_save _PEP440_A
  pep440_parse "$2" || return 1
  _pep440_save _PEP440_B
  _pep440_order _PEP440_A _PEP440_B
}

# Succeed when version $1 meets every comma-separated clause of specifier $2, without blanks;
# return 1 when a clause fails, listed in PEP440_FAILED, and 2 for text it cannot compare
pep440_holds() {
  local clause rc=0 one
  local -a clauses
  PEP440_FAILED=""
  [[ -n "$2" ]] || return 0
  [[ "$2" != *,,* && "$2" != ,* && "$2" != *, ]] || return 2
  pep440_parse "$1" || return 2
  _pep440_save _PEP440_V
  IFS=, read -ra clauses <<<"$2"
  for clause in "${clauses[@]}"; do
    one=0
    _pep440_clause "$1" "$clause" || one=$?
    if ((one == 2)); then
      return 2
    elif ((one == 1)); then
      rc=1
      PEP440_FAILED+="${PEP440_FAILED:+,}$clause"
    fi
  done
  return "$rc"
}

# Return 0, 1 or 2 as version $1, parsed into _PEP440_V, meets clause $2, fails it, or meets text
# it cannot compare. The rules follow the Specifier class of packaging, pre-releases allowed.
_pep440_clause() {
  local LC_ALL=C op x hit
  [[ "$2" =~ ^(===|==|!=|~=|<=|>=|<|>)(.+)$ ]] || return 2
  op=${BASH_REMATCH[1]} x=${BASH_REMATCH[2]}
  case $op in
    ===)
      [[ "$x" != *[[:space:]]* ]] || return 2
      [[ "${1,,}" == "${x,,}" ]]
      return
      ;;
    == | !=)
      if [[ "$x" == *.\* ]]; then
        [[ "$x" =~ ^[vV]?(([0-9]+)!)?([0-9]+(\.[0-9]+)*)\.\*$ ]] || return 2
        hit=0
        _pep440_prefix "${BASH_REMATCH[2]:-0}" "${BASH_REMATCH[3]}" || hit=1
      else
        pep440_parse "$x" || return 2
        _pep440_save _PEP440_X
        _PEP440_P=("${_PEP440_V[@]}")
        [[ -n "${_PEP440_X[6]}" ]] || _PEP440_P[6]=""
        _pep440_order _PEP440_P _PEP440_X
        hit=$((PEP440_ORDER == 0 ? 0 : 1))
      fi
      [[ "$op" == "==" ]] || hit=$((1 - hit))
      return "$hit"
      ;;
  esac
  pep440_parse "$x" || return 2
  [[ -z "$PV_LOCAL" ]] || return 2
  _pep440_save _PEP440_X
  _PEP440_P=("${_PEP440_V[@]}")
  _PEP440_P[6]=""
  case $op in
    "~=")
      [[ "${_PEP440_X[1]}" == *.* ]] || return 2
      _pep440_order _PEP440_P _PEP440_X
      ((PEP440_ORDER >= 0)) || return 1
      _pep440_prefix "${_PEP440_X[0]}" "${_PEP440_X[1]%.*}"
      ;;
    "<=")
      _pep440_order _PEP440_P _PEP440_X
      ((PEP440_ORDER <= 0))
      ;;
    ">=")
      _pep440_order _PEP440_P _PEP440_X
      ((PEP440_ORDER >= 0))
      ;;
    "<")
      _pep440_order _PEP440_V _PEP440_X
      ((PEP440_ORDER < 0)) || return 1
      # Pre-releases of the release of the clause are not lower, unless the clause is one too
      if [[ -z "${_PEP440_X[2]}${_PEP440_X[5]}" && -n "${_PEP440_V[2]}${_PEP440_V[5]}" ]] && _pep440_same_base; then
        return 1
      fi
      ;;
    ">")
      # Local versions compare by their public version, and >V leaves out the post-releases of V
      # unless V is a post or dev release
      _pep440_order _PEP440_P _PEP440_X
      ((PEP440_ORDER > 0)) || return 1
      if [[ -z "${_PEP440_X[4]}${_PEP440_X[5]}" ]] && _pep440_same_pre; then
        return 1
      fi
      ;;
  esac
}

# Succeed when the epoch of _PEP440_V is $1 and its release, padded with zeros, starts with release $2
_pep440_prefix() {
  local i
  local -a have want
  _pep440_num "${_PEP440_V[0]}" "$1"
  ((PEP440_ORDER == 0)) || return 1
  IFS=. read -ra have <<<"${_PEP440_V[1]}"
  IFS=. read -ra want <<<"$2"
  for i in "${!want[@]}"; do
    _pep440_num "${have[i]:-0}" "${want[i]}"
    ((PEP440_ORDER == 0)) || return 1
  done
}

# Succeed when _PEP440_V and _PEP440_X have the same epoch and release
_pep440_same_base() {
  _PEP440_P=("${_PEP440_V[0]}" "${_PEP440_V[1]}" "" "" "" "" "")
  _PEP440_Q=("${_PEP440_X[0]}" "${_PEP440_X[1]}" "" "" "" "" "")
  _pep440_order _PEP440_P _PEP440_Q
  ((PEP440_ORDER == 0))
}

# Succeed when _PEP440_P and _PEP440_X have the same epoch, release and pre-release
_pep440_same_pre() {
  _PEP440_R=("${_PEP440_P[0]}" "${_PEP440_P[1]}" "${_PEP440_P[2]}" "${_PEP440_P[3]}" "" "" "")
  _PEP440_Q=("${_PEP440_X[0]}" "${_PEP440_X[1]}" "${_PEP440_X[2]}" "${_PEP440_X[3]}" "" "" "")
  _pep440_order _PEP440_R _PEP440_Q
  ((PEP440_ORDER == 0))
}

# Store the parts that pep440_parse set in the array named $1
_pep440_save() {
  local -n _pep440_dst=$1
  _pep440_dst=("$PV_EPOCH" "$PV_RELEASE" "$PV_PRE_L" "$PV_PRE_N" "$PV_POST" "$PV_DEV" "$PV_LOCAL")
}

# Set PEP440_ORDER for the versions in the arrays named $1 and $2, each as _pep440_save stores them:
# epoch, release padded with zeros, pre-release, post-release, development release, local part
_pep440_order() {
  local -n _pep440_x=$1 _pep440_y=$2
  local LC_ALL=C i n xr yr
  local -a xs ys
  _pep440_num "${_pep440_x[0]}" "${_pep440_y[0]}"
  ((PEP440_ORDER == 0)) || return 0
  IFS=. read -ra xs <<<"${_pep440_x[1]}"
  IFS=. read -ra ys <<<"${_pep440_y[1]}"
  n=$((${#xs[@]} > ${#ys[@]} ? ${#xs[@]} : ${#ys[@]}))
  for ((i = 0; i < n; i++)); do
    _pep440_num "${xs[i]:-0}" "${ys[i]:-0}"
    ((PEP440_ORDER == 0)) || return 0
  done
  _pep440_pre_rank "${_pep440_x[@]}"
  xr=$PEP440_RANK
  _pep440_pre_rank "${_pep440_y[@]}"
  yr=$PEP440_RANK
  if ((xr != yr)); then
    PEP440_ORDER=$((xr < yr ? -1 : 1))
    return 0
  fi
  if ((xr >= 1 && xr <= 3)); then
    _pep440_num "${_pep440_x[3]}" "${_pep440_y[3]}"
    ((PEP440_ORDER == 0)) || return 0
  fi
  # No post-release sorts first, no development release last
  _pep440_optional "${_pep440_x[4]}" "${_pep440_y[4]}" -1
  ((PEP440_ORDER == 0)) || return 0
  _pep440_optional "${_pep440_x[5]}" "${_pep440_y[5]}" 1
  ((PEP440_ORDER == 0)) || return 0
  _pep440_local "${_pep440_x[6]}" "${_pep440_y[6]}"
}

# Set PEP440_RANK for the pre-release of the parts $1 to $7: 0 for a development release with no
# pre- or post-release, 1 to 3 for a, b and rc, 4 for none
_pep440_pre_rank() {
  case $3 in
    a) PEP440_RANK=1 ;;
    b) PEP440_RANK=2 ;;
    rc) PEP440_RANK=3 ;;
    *) PEP440_RANK=4 ;;
  esac
  if [[ -z "$3" && -z "$5" && -n "$6" ]]; then
    PEP440_RANK=0
  fi
}

# Set PEP440_ORDER for optional numbers $1 and $2, where a missing one sorts as $3 against a number
_pep440_optional() {
  if [[ -z "$1" && -z "$2" ]]; then
    PEP440_ORDER=0
  elif [[ -z "$1" ]]; then
    PEP440_ORDER=$3
  elif [[ -z "$2" ]]; then
    PEP440_ORDER=$((0 - $3))
  else
    _pep440_num "$1" "$2"
  fi
}

# Set PEP440_ORDER for local parts $1 and $2: none sorts first, numbers above text, by segment
_pep440_local() {
  local i n
  local -a xs ys
  if [[ -z "$1" || -z "$2" ]]; then
    _pep440_optional "${1:+0}" "${2:+0}" -1
    return 0
  fi
  IFS=. read -ra xs <<<"$1"
  IFS=. read -ra ys <<<"$2"
  n=$((${#xs[@]} < ${#ys[@]} ? ${#xs[@]} : ${#ys[@]}))
  for ((i = 0; i < n; i++)); do
    if [[ "${xs[i]}" =~ ^[0-9]+$ && "${ys[i]}" =~ ^[0-9]+$ ]]; then
      _pep440_num "${xs[i]}" "${ys[i]}"
    elif [[ "${xs[i]}" =~ ^[0-9]+$ ]]; then
      PEP440_ORDER=1
    elif [[ "${ys[i]}" =~ ^[0-9]+$ ]]; then
      PEP440_ORDER=-1
    elif [[ "${xs[i]}" < "${ys[i]}" ]]; then
      PEP440_ORDER=-1
    elif [[ "${xs[i]}" > "${ys[i]}" ]]; then
      PEP440_ORDER=1
    else
      PEP440_ORDER=0
    fi
    ((PEP440_ORDER == 0)) || return 0
  done
  PEP440_ORDER=$(((${#xs[@]} > ${#ys[@]}) - (${#xs[@]} < ${#ys[@]})))
}

# Set PEP440_ORDER for the numbers of digit strings $1 and $2, which can exceed bash integers
_pep440_num() {
  local LC_ALL=C a=${1#"${1%%[!0]*}"} b=${2#"${2%%[!0]*}"}
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

# Set PEP440_INT to digit string $1 without leading zeros
_pep440_int() {
  PEP440_INT=${1#"${1%%[!0]*}"}
  PEP440_INT=${PEP440_INT:-0}
}
