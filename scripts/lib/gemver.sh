#!/usr/bin/env bash
#
# gemver.sh - Versions and requirements of RubyGems, as Gem::Version and Gem::Requirement read them
#
# Sourced by lib.sh and strategies/rubygems.sh.

# Succeed when $1 is a version that Gem::Version reads
gem_version_valid() {
  local LC_ALL=C
  [[ "$1" =~ ^[0-9]+(\.[0-9a-zA-Z]+)*(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]
}

# Set GEM_SEG to the canonical segments of version $1: digits and letters apart, each - read as .pre.,
# and the zero numbers at the end of the numbers and of the rest dropped; fail outside gem_version_valid
gem_segments() {
  local LC_ALL=C rest=${1//-/.pre.} token i first=-1
  local -a segs=() head tail
  gem_version_valid "$1" || return 1
  while [[ "$rest" =~ ^[^0-9A-Za-z]*([0-9]+|[A-Za-z]+)(.*)$ ]]; do
    token=${BASH_REMATCH[1]} rest=${BASH_REMATCH[2]}
    if [[ "$token" =~ ^[0-9]+$ ]]; then
      token=${token#"${token%%[!0]*}"}
      token=${token:-0}
    elif ((first < 0)); then
      first=${#segs[@]}
    fi
    segs+=("$token")
  done
  ((first >= 0)) || first=${#segs[@]}
  head=("${segs[@]:0:first}") tail=("${segs[@]:first}")
  for ((i = ${#head[@]} - 1; i >= 0 && ${#head[@]} > 0; i--)); do
    [[ "${head[i]}" == 0 ]] || break
    unset 'head[i]'
  done
  for ((i = ${#tail[@]} - 1; i >= 0 && ${#tail[@]} > 0; i--)); do
    [[ "${tail[i]}" == 0 ]] || break
    unset 'tail[i]'
  done
  GEM_SEG=("${head[@]}" "${tail[@]}")
}

# Set GEM_ORDER to -1, 0 or 1 as version $1 sorts before, with or after version $2; fail when either
# is outside gem_version_valid. Letters sort before numbers, and missing segments are 0.
gem_cmp() {
  local LC_ALL=C i n x y
  local -a a b
  gem_segments "$1" || return 1
  a=("${GEM_SEG[@]}")
  gem_segments "$2" || return 1
  b=("${GEM_SEG[@]}")
  n=$((${#a[@]} > ${#b[@]} ? ${#a[@]} : ${#b[@]}))
  GEM_ORDER=0
  for ((i = 0; i < n; i++)); do
    x=${a[i]:-0} y=${b[i]:-0}
    [[ "$x" != "$y" ]] || continue
    if [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]]; then
      _gem_num "$x" "$y"
    elif [[ "$y" =~ ^[0-9]+$ ]]; then
      GEM_ORDER=-1
    elif [[ "$x" =~ ^[0-9]+$ ]]; then
      GEM_ORDER=1
    elif [[ "$x" < "$y" ]]; then
      GEM_ORDER=-1
    else
      GEM_ORDER=1
    fi
    return 0
  done
}

# Succeed when version $1 holds a letter, as Gem::Version#prerelease? reads it
gem_prerelease() {
  [[ "$1" == *[A-Za-z-]* ]]
}

# Print version $1 up to its first letter segment, as Gem::Version#release gives it
gem_release_part() {
  local LC_ALL=C rest=${1//-/.pre.} out="" token
  while [[ "$rest" =~ ^[^0-9A-Za-z]*([0-9]+|[A-Za-z]+)(.*)$ ]]; do
    token=${BASH_REMATCH[1]} rest=${BASH_REMATCH[2]}
    [[ "$token" =~ ^[0-9]+$ ]] || break
    out+="${out:+.}$token"
  done
  printf '%s\n' "$out"
}

# Print the upper bound of ~> $1, as Gem::Version#bump gives it: the numbers before the first letter
# segment, the last of them dropped while more than one stays, and the new last one raised by one
gem_bump() {
  local release last
  local -a parts
  release=$(gem_release_part "$1")
  IFS=. read -ra parts <<<"$release"
  ((${#parts[@]} < 2)) || unset 'parts[${#parts[@]}-1]'
  last=${parts[${#parts[@]} - 1]}
  parts[${#parts[@]} - 1]=$((10#$last + 1))
  (IFS=. && printf '%s\n' "${parts[*]}")
}

# Succeed when version $1 meets the requirements $2, as "~> 1.1, >= 1.2"; return 1 with the failed ones in
# GEM_FAILED, GEM_TILDE_UPPER set when each fails the upper bound of ~> alone, and 2 for unreadable text
# shellcheck disable=SC2034 # rbrules.sh reads GEM_FAILED and GEM_TILDE_UPPER
gem_holds() {
  local LC_ALL=C clause op x rc=0 upper_only=1 failed=""
  local -a clauses
  GEM_FAILED="" GEM_TILDE_UPPER=""
  [[ -n "${2//[[:blank:]]/}" ]] || return 0
  gem_version_valid "$1" || return 2
  [[ "$2" != *,,* && "$2" != ,* && "$2" != *, ]] || return 2
  IFS=, read -ra clauses <<<"$2"
  for clause in "${clauses[@]}"; do
    [[ "$clause" =~ ^[[:blank:]]*(=|!=|>|<|>=|<=|~>)?[[:blank:]]*([0-9][^[:blank:]]*)[[:blank:]]*$ ]] || return 2
    op=${BASH_REMATCH[1]:-=} x=${BASH_REMATCH[2]}
    gem_version_valid "$x" || return 2
    gem_cmp "$1" "$x" || return 2
    case $op in
      "=") ((GEM_ORDER == 0)) && continue ;;
      "!=") ((GEM_ORDER != 0)) && continue ;;
      ">") ((GEM_ORDER > 0)) && continue ;;
      "<") ((GEM_ORDER < 0)) && continue ;;
      ">=") ((GEM_ORDER >= 0)) && continue ;;
      "<=") ((GEM_ORDER <= 0)) && continue ;;
      "~>")
        if ((GEM_ORDER >= 0)); then
          gem_cmp "$(gem_release_part "$1")" "$(gem_bump "$x")" || return 2
          ((GEM_ORDER >= 0)) || continue
        else
          upper_only=""
        fi
        ;;
    esac
    [[ "$op" == "~>" ]] || upper_only=""
    rc=1
    failed+="${failed:+, }$op $x"
  done
  if ((rc == 1)); then
    GEM_FAILED=$failed GEM_TILDE_UPPER=$upper_only
  fi
  return "$rc"
}

# Set GEM_ORDER for the numbers of digit strings $1 and $2, which can exceed bash integers
_gem_num() {
  local LC_ALL=C x=${1#"${1%%[!0]*}"} y=${2#"${2%%[!0]*}"}
  if ((${#x} != ${#y})); then
    GEM_ORDER=$((${#x} < ${#y} ? -1 : 1))
  elif [[ "$x" < "$y" ]]; then
    GEM_ORDER=-1
  elif [[ "$x" > "$y" ]]; then
    GEM_ORDER=1
  else
    GEM_ORDER=0
  fi
}
