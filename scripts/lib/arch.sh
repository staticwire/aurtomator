#!/usr/bin/env bash
# arch.sh - Versions without the archive of some arches, docs/WORKFLOW.md 4.8.
# Sourced by lib.sh, after prepared.sh.

# Print the arch values of the pkgbase section of .SRCINFO $1, in order
srcinfo_arches() {
  awk '/^pkgname = /{exit} /^\tarch = /{print substr($0, 9)}' "$1"
}

# Print each line of .SRCINFO $1 that belongs to arch $2: its arch line and
# every key that ends in _$2, in every section
srcinfo_arch_lines() {
  awk -v a="$2" '$0 == "\tarch = " a || match($0, "^\t[a-z0-9]+_" a " = ")' "$1"
}

# Print the pkgver of .SRCINFO $1
srcinfo_pkgver() {
  awk '/^\tpkgver = /{print substr($0, 11); exit}' "$1"
}

# Print the words of the one top-level arch=(...) line of PKGBUILD $1, one a
# line; fails for any other arch line or a word that is no plain arch name
pkgbuild_arch_words() {
  local line_re='^arch=\(([^)]*)\)[[:space:]]*$' word_re="^'([a-z0-9_]+)'$|^\"([a-z0-9_]+)\"$|^([a-z0-9_]+)$"
  local word
  local -a arch_lines arch_tokens arch_names=()
  mapfile -t arch_lines < <(grep -E '^[[:space:]]*arch\+?=' "$1")
  if ((${#arch_lines[@]} != 1)) || [[ ! "${arch_lines[0]}" =~ $line_re ]]; then
    return 1
  fi
  read -ra arch_tokens <<<"${BASH_REMATCH[1]}"
  for word in "${arch_tokens[@]}"; do
    [[ "$word" =~ $word_re ]] || return 1
    arch_names+=("${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}")
  done
  ((${#arch_names[@]} > 0)) || return 1
  printf '%s\n' "${arch_names[@]}"
}

# Print an arch line of the words $2... in the quoting of the first word of
# arch line $1, which prepare writes and verify and publish expect
arch_line() {
  local quote="" out="" word
  case "${1#arch=(}" in
    \'*) quote="'" ;;
    \"*) quote='"' ;;
  esac
  for word in "${@:2}"; do
    out+="${out:+ }${quote}${word}${quote}"
  done
  printf 'arch=(%s)\n' "$out"
}

# Print the words $1 with arch $2 after the last of the words $3 that stands
# before it and is in $1, or first; words are separated by spaces
arch_order() {
  local before="" word
  local -a present reference ordered=()
  read -ra present <<<"$1"
  read -ra reference <<<"$3"
  if [[ " $1 " == *" $2 "* ]]; then
    printf '%s\n' "$1"
    return 0
  fi
  for word in "${reference[@]}"; do
    [[ "$word" != "$2" ]] || break
    [[ " $1 " != *" $word "* ]] || before=$word
  done
  [[ -n "$before" ]] || ordered=("$2")
  for word in "${present[@]}"; do
    ordered+=("$word")
    [[ "$word" != "$before" ]] || ordered+=("$2")
  done
  printf '%s\n' "${ordered[*]}"
}

# Print the https URLs of source_$2 of .SRCINFO $1 with version $3 replaced by
# $4; $5 to $9 are the upstream versions, pkgver_dash and asset values
arch_urls() {
  local key=$'\tsource_'"$2"' = ' old="$3" new="$4" dash="$7" url
  while IFS= read -r url; do
    url="${url#*::}"
    [[ "$url" == https://* ]] || continue
    [[ -z "$8" ]] || url="${url//"$8"/"$9"}"
    if [[ "$dash" == [_.] ]]; then
      url=$(_bump_version "$url" "${old//"$dash"/-}" "${new//"$dash"/-}")
    fi
    _bump_version "$url" "$old" "$new" "$5" "$6"
  done < <(awk -v k="$key" 'index($0, k) == 1 { print substr($0, length(k) + 1) }' "$1")
}

# Returns 0 when URL $1 answers a HEAD request with a file, 1 for a status of
# 400 or more or an HTML page, and 2 when it gives no status
probe_url() {
  local response code type
  response=$(curl -sIL -o /dev/null -w '%{http_code} %{content_type}' \
    --max-time 10 --max-redirs 5 "$1" 2>/dev/null) || return 2
  read -r code type <<<"$response"
  type="${type%%;*}"
  type="${type//[[:space:]]/}"
  # The server chooses the status line, and (( )) would run a subscript
  [[ "$code" =~ ^[1-5][0-9]{2}$ ]] || return 2
  if ((10#$code >= 400)) || [[ "${type,,}" == text/html ]]; then
    return 1
  fi
}
