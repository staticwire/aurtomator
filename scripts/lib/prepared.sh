#!/usr/bin/env bash
#
# prepared.sh - Checks of a prepared update against the AUR copy
#
# The job that executes a PKGBUILD holds no secrets, so the files it hands
# over are untrusted. The job that pushes accepts them only when they differ
# from the AUR copy in pkgver, pkgrel and checksum values. None of these
# checks sources the file.
#
# Sourced by lib.sh, after common.sh.

# awk keeps a NUL byte, $(...) drops it and mapfile cuts the line at it, so
# a file with one is compared as something it is not
# Args: $1=file
# Returns: 0 when the file holds a NUL byte
_has_nul() {
  [[ "$(tr -d '\000' <"$1" | wc -c)" -ne "$(wc -c <"$1")" ]]
}

# Split a PKGBUILD into lines of five kinds, without executing it:
#   SKEL<TAB>line          every line, with pkgver=, pkgrel= and each
#                          top-level checksum array replaced by a placeholder
#   PKGVER|PKGREL<TAB>val  the value of a pkgver= or pkgrel= line
#   SUM<TAB>array<TAB>index<TAB>HASH|SKIP  one line per checksum
#   SUMVAL<TAB>array<TAB>value  the same checksum with its value
#   BAD<TAB>text           anything in a checksum array but a quoted
#                          checksum, a comment or a line continuation
# Args: $1=pkgbuild path
_pkgbuild_parts() {
  awk '
    function tokens(text,   n, i, t, parts) {
      n = split(text, parts, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        t = parts[i]
        if (t == "") continue
        if (t !~ /^(\047([0-9a-fA-F]+|SKIP)\047|"([0-9a-fA-F]+|SKIP)")$/) {
          print "BAD\t" NR ": " t
          continue
        }
        print "SUM\t" name "\t" idx++ "\t" (t ~ /SKIP/ ? "SKIP" : "HASH")
        print "SUMVAL\t" name "\t" substr(t, 2, length(t) - 2)
      }
    }
    # As bash does: a # that starts a word comments out the rest of the
    # line, and a backslash at the end of a line outside a comment joins
    # the next line, which inside the parentheses is only a separator
    function body(text,   raw, cont, end, rest) {
      raw = text
      sub(/(^|[ \t])#.*/, "", text)
      cont = text == raw && text ~ /(^|[ \t])\\$/
      if (cont) text = substr(text, 1, length(text) - 1)
      end = index(text, ")")
      if (!end) {
        tokens(text)
        return 1
      }
      tokens(substr(text, 1, end - 1))
      rest = substr(text, end + 1) (cont ? "\\" : "")
      if (rest !~ /^[ \t]*$/) print "BAD\t" NR ": " rest
      return 0
    }
    in_sums { in_sums = body($0); next }
    /^(ck|md5|sha1|sha224|sha256|sha384|sha512|b2)sums(_[A-Za-z0-9_]+)?=\(/ {
      name = substr($0, 1, index($0, "=") - 1)
      idx = 0
      print "SKEL\tSUMS " name
      in_sums = body(substr($0, index($0, "(") + 1))
      next
    }
    /^pkgver=/ { print "SKEL\tPKGVER"; print "PKGVER\t" substr($0, 8); next }
    /^pkgrel=/ { print "SKEL\tPKGREL"; print "PKGREL\t" substr($0, 8); next }
    { print "SKEL\t" $0 }
    END { if (in_sums) print "BAD\tunterminated " name }
  ' "$1"
}

# Args: $1=AUR PKGBUILD, $2=prepared PKGBUILD, $3=expected version
# Returns: 0 when the prepared file changes only pkgver (to $3), pkgrel
#          (to 1) and checksum values, 1 otherwise (reason on stderr)
check_prepared_pkgbuild() {
  local version="$3"
  local old_parts new_parts value
  if ! old_parts=$(_pkgbuild_parts "$1") || ! new_parts=$(_pkgbuild_parts "$2"); then
    log_err "Could not read the PKGBUILD to compare"
    return 1
  fi
  if _has_nul "$2"; then
    log_err "Prepared PKGBUILD holds a NUL byte"
    return 1
  fi

  if grep -q $'^BAD\t' <<<"$new_parts"; then
    log_err "Prepared PKGBUILD has more than quoted checksums, comments and line continuations in a checksum array:"
    grep $'^BAD\t' <<<"$new_parts" | cut -f2- >&2
    return 1
  fi
  if [[ "$(grep $'^SKEL\t' <<<"$old_parts")" != "$(grep $'^SKEL\t' <<<"$new_parts")" ]]; then
    log_err "Prepared PKGBUILD changes lines outside pkgver, pkgrel and checksums"
    return 1
  fi
  if [[ "$(grep $'^SUM\t' <<<"$old_parts")" != "$(grep $'^SUM\t' <<<"$new_parts")" ]]; then
    log_err "Prepared PKGBUILD changes the checksum arrays: their names, lengths or SKIP entries differ from the AUR"
    return 1
  fi
  while IFS=$'\t' read -r _ value; do
    if [[ "$value" != "$version" ]]; then
      log_err "Prepared PKGBUILD has pkgver=${value}, expected ${version}"
      return 1
    fi
  done < <(grep $'^PKGVER\t' <<<"$new_parts")
  while IFS=$'\t' read -r _ value; do
    if [[ "$value" != "1" ]]; then
      log_err "Prepared PKGBUILD has pkgrel=${value}, expected 1"
      return 1
    fi
  done < <(grep $'^PKGREL\t' <<<"$new_parts")
  return 0
}

# Replace the old version in a line with the new one, and also the forms a
# PKGBUILD derives from pkgver: dots and plus signs turned into
# underscores, the part before the first +, and the version without its
# last component, such as ${pkgver%.*} in the frameworks/6.19/ directory
# of KDE Frameworks. That last form counts only while it keeps a dot, as a
# lone major version is too common in other text. One pass from left to
# right, longest form first, so a replaced part is not matched again: with
# 5.1.0 -> 5.10.0 the 5.1 at the start of 5.10.0 stays. With
# pkgver_format, the upstream version inside the version is the last form,
# as 4215 in 4.4215.
# Args: $1=line, $2=old version, $3=new version, $4=old upstream version,
#       $5=new upstream version
_bump_version() {
  local rest="$1" old="$2" new="$3" out="" i matched
  if [[ -z "$old" ]]; then
    printf '%s\n' "$rest"
    return 0
  fi
  local -a olds=("$old") news=("$new")
  if [[ "$old" == *[.+]* ]]; then
    olds+=("${old//[.+]/_}")
    news+=("${new//[.+]/_}")
  fi
  if [[ "$old" == *+* ]]; then
    olds+=("${old%%+*}")
    news+=("${new%%+*}")
  fi
  old="${old%%+*}"
  new="${new%%+*}"
  if [[ "${old%.*}" == *.* ]]; then
    olds+=("${old%.*}")
    news+=("${new%.*}")
  fi
  # An empty form would match at every position and never move on
  if [[ -n "${4:-}" && -n "${5:-}" ]]; then
    olds+=("$4")
    news+=("$5")
  fi

  while [[ -n "$rest" ]]; do
    matched=false
    for i in "${!olds[@]}"; do
      if [[ "$rest" == "${olds[$i]}"* ]]; then
        out+="${news[$i]}"
        rest="${rest:${#olds[$i]}}"
        matched=true
        break
      fi
    done
    if [[ "$matched" == false ]]; then
      out+="${rest:0:1}"
      rest="${rest:1}"
    fi
  done
  printf '%s\n' "$out"
}

# Print the upstream version inside a version of pkgver_format, the part
# in place of %s, or nothing when the version does not fit the format
# Args: $1=version, $2=pkgver_format
_unformat_version() {
  local prefix="${2%%"%s"*}" suffix="${2#*"%s"}" version="$1"
  if [[ "$2" == *%s* && "$version" == "$prefix"*"$suffix" ]]; then
    version="${version#"$prefix"}"
    printf '%s\n' "${version%"$suffix"}"
  fi
}

# Print the line with each form of the version that has a dash in place of
# the pkgver_dash character turned back into the version, as
# ${pkgver//_/-} writes 0.0.1-rc.20 for pkgver 0.0.1_rc.20
# Args: $1=line, $2=version, $3=pkgver_dash character
_undash_version() {
  local rest="$1" version="$2" dash="$3" re="" out="" c i match
  for ((i = 0; i < ${#version}; i++)); do
    c="${version:i:1}"
    if [[ "$c" == "$dash" ]]; then
      re+="[$c-]"
    else
      re+="[$c]"
    fi
  done
  while [[ -n "$re" && "$rest" =~ $re ]]; do
    match="${BASH_REMATCH[0]}"
    out+="${rest%%"$match"*}${version}"
    rest="${rest#*"$match"}"
  done
  printf '%s\n' "$out$rest"
}

# Args: $1=AUR line, $2=prepared line, $3=old version, $4=new version,
#       $5=pkgver_dash character
# Returns: 0 when the prepared line is the AUR line with the version
#          replaced, once a dash in place of the pkgver_dash character in
#          either version counts as that character
_bumped_with_dash() {
  [[ "$(_undash_version "$2" "$4" "$5")" == "$(_bump_version "$(_undash_version "$1" "$3" "$5")" "$3" "$4")" ]]
}

# Print "SKIP <arch suffix>:<index>" for every source entry of a .SRCINFO
# that is SKIP in each checksum array with the same arch suffix, and
# "HASH <arch suffix>:<index>" for every other one
# Args: $1=.SRCINFO
_source_checksums() {
  awk -F' = ' '
    { key = $1; sub(/^[ \t]+/, "", key) }
    key ~ /^(ck|md5|sha1|sha224|sha256|sha384|sha512|b2)sums(_[A-Za-z0-9_]+)?$/ {
      entry = substr(key, index(key, "sums") + 4) ":" count[key]++
      listed[entry] = 1
      if ($2 != "SKIP") hashed[entry] = 1
    }
    END { for (entry in listed) print (entry in hashed ? "HASH " : "SKIP ") entry }
  ' "$1"
}

# Args: $1=source entry of a .SRCINFO
# Returns: 0 when makepkg downloads it over http, https or ftp, as
#          verify_prepared_sums does
_is_download() {
  local url="${1#*::}"
  [[ "$1" == *://* && "${url%%://*}" =~ ^(http|https|ftp)$ ]]
}

# Args: $1=source entry of a .SRCINFO
# Returns: 0 when makepkg checks it out with a VCS client at a fixed
#          commit, tag or revision
_is_vcs_pin() {
  local url="${1#*::}"
  [[ "$1" == *://* && "${url%%://*}" =~ ^(bzr|fossil|git|hg|svn)(\+.+)?$ && "$url" == *#* ]] || return 1
  local fragment="${url#*#}"
  [[ "${fragment%%=*}" =~ ^(commit|tag|revision)$ ]]
}

# Args: $1=expected source line, $2=prepared source line
# Returns: 0 when both save their file under a name before ::, have the same
#          URL after it, and their names differ in nothing but digits
_name_differs_in_digits() {
  [[ "$1" == *::* && "$2" == *::* && "${1#*::}" == "${2#*::}" ]] || return 1
  [[ "$(sed -E 's/[0-9]+/0/g' <<<"${1%%::*}")" == "$(sed -E 's/[0-9]+/0/g' <<<"${2%%::*}")" ]]
}

# Drop the empty lines at the end of an array. makepkg --printsrcinfo ends
# a .SRCINFO at its last line, while some AUR copies end in an empty line,
# as those mksrcinfo v8 wrote do.
# Args: $1=name of the array
_drop_trailing_blank() {
  local -n lines_ref="$1"
  while ((${#lines_ref[@]} > 0)) && [[ -z "${lines_ref[-1]}" ]]; do
    unset 'lines_ref[-1]'
  done
}

# A .SRCINFO is generated, so line N of the prepared file must be line N of
# the AUR file, with these changes: pkgver is the new version, pkgrel is 1,
# a checksum keeps its key and stays a SKIP or a hash, a source has the old
# version replaced by the new one (see _bump_version), and any other line
# either stays or has the version replaced in the same way. A license, a
# dependency or a pkgdesc can hold the old version without deriving it
# from pkgver. A source that is SKIP in every checksum array may also change
# the digits in the name of its file, as a nightly package names its
# download by the date: verify_prepared_sums never fetches it, and makepkg
# takes the sources from the PKGBUILD. When pkgver changes and a download
# has a real checksum, or a VCS source is pinned to a commit, a tag or a
# revision, some source URL or checksum has to change too: a pkgver built
# from another variable, a source URL without the version, a pin that
# stays, or a version only in the name a download is saved under, the part
# before ::, would otherwise label the old files with the new version. With
# pkgver_dash, a version with a dash in place of that character, as
# ${pkgver//_/-} writes it, counts as the version. With pkgver_format, so
# does the upstream version inside it, as ${pkgver#4.} writes 4215.
# Args: $1=AUR .SRCINFO, $2=prepared .SRCINFO, $3=expected version,
#       $4=pkgver_dash character of the package, if any,
#       $5=pkgver_format of the package, if any
# Returns: 0 when that holds, 1 otherwise (reason on stderr)
check_prepared_srcinfo() {
  local version="$3" dash="${4:-}" format="${5:-}"
  if [[ ! -r "$1" || ! -r "$2" ]]; then
    log_err "Could not read the .SRCINFO to compare"
    return 1
  fi
  if _has_nul "$2"; then
    log_err "Prepared .SRCINFO holds a NUL byte"
    return 1
  fi
  local -a old_lines new_lines
  mapfile -t old_lines <"$1"
  mapfile -t new_lines <"$2"
  _drop_trailing_blank old_lines
  _drop_trailing_blank new_lines
  if [[ "${#old_lines[@]}" -ne "${#new_lines[@]}" ]]; then
    log_err "Prepared .SRCINFO adds or removes lines"
    return 1
  fi

  local old_ver old_up="" new_up=""
  old_ver=$(awk -F' = ' '$1 ~ /^[ \t]*pkgver$/ { print $2; exit }' "$1")
  if [[ -n "$format" ]]; then
    old_up=$(_unformat_version "$old_ver" "$format")
    new_up=$(_unformat_version "$version" "$format")
  fi

  local -A skip_sources=() hashed_sources=() source_counts=()
  local checksum entry
  while read -r checksum entry; do
    if [[ "$checksum" == SKIP ]]; then
      skip_sources["$entry"]=1
    else
      hashed_sources["$entry"]=1
    fi
  done < <(_source_checksums "$1")

  local i old new key kind old_val new_val n expected pinned=false changed=false
  for i in "${!new_lines[@]}"; do
    old="${old_lines[$i]}"
    new="${new_lines[$i]}"
    key="${new%% = *}"
    key="${key#"${key%%[![:space:]]*}"}"
    new_val="${new#* = }"
    old_val="${old#* = }"
    if [[ "$key" == "pkgver" || "$key" == "pkgrel" ]]; then
      kind="$key"
    elif [[ "$key" =~ ^(ck|md5|sha1|sha224|sha256|sha384|sha512|b2)sums(_[A-Za-z0-9_]+)?$ ]]; then
      kind=sums
    elif [[ "$key" =~ ^source(_[A-Za-z0-9_]+)?$ ]]; then
      kind=source
    else
      kind=other
    fi
    if [[ "$kind" != "other" && "${old%% = *}" != "${new%% = *}" ]]; then
      log_err "Prepared .SRCINFO line $((i + 1)) has another key than the AUR copy: $new"
      return 1
    fi
    case "$kind" in
      pkgver)
        [[ "$new_val" == "$version" ]] || {
          log_err "Prepared .SRCINFO has pkgver = ${new_val}, expected ${version}"
          return 1
        }
        ;;
      pkgrel)
        [[ "$new_val" == "1" ]] || {
          log_err "Prepared .SRCINFO has pkgrel = ${new_val}, expected 1"
          return 1
        }
        ;;
      sums)
        if [[ ! "$new_val" =~ ^([0-9a-fA-F]+|SKIP)$ ]] ||
          [[ "$new_val" == "SKIP" && "$old_val" != "SKIP" ]] ||
          [[ "$new_val" != "SKIP" && "$old_val" == "SKIP" ]]; then
          log_err "Prepared .SRCINFO line $((i + 1)) is not a checksum matching the AUR copy: $new"
          return 1
        fi
        [[ "$new" == "$old" ]] || changed=true
        ;;
      source)
        n="${source_counts[$key]:-0}"
        source_counts[$key]=$((n + 1))
        expected=$(_bump_version "$old" "$old_ver" "$version" "$old_up" "$new_up")
        if [[ "$new" != "$expected" ]] &&
          ! _bumped_with_dash "$old" "$new" "$old_ver" "$version" "$dash" &&
          ! { [[ -n "${skip_sources["${key#source}:$n"]:-}" ]] &&
            _name_differs_in_digits "$expected" "$new"; }; then
          log_err "Prepared .SRCINFO line $((i + 1)) is not the AUR source with the new version: $new"
          return 1
        fi
        [[ "${new_val#*::}" == "${old_val#*::}" ]] || changed=true
        if { [[ -n "${hashed_sources["${key#source}:$n"]:-}" ]] && _is_download "$old_val"; } ||
          _is_vcs_pin "$old_val"; then
          pinned=true
        fi
        ;;
      *)
        if [[ "$new" != "$old" && "$new" != "$(_bump_version "$old" "$old_ver" "$version" "$old_up" "$new_up")" ]] &&
          ! _bumped_with_dash "$old" "$new" "$old_ver" "$version" "$dash"; then
          log_err "Prepared .SRCINFO line $((i + 1)) changes more than the version: $new"
          return 1
        fi
        ;;
    esac
  done
  if [[ "$pinned" == true && "$changed" == false && "$version" != "$old_ver" ]]; then
    log_err "Prepared .SRCINFO changes no source URL and no checksum, so the new version would hold the files of the old one"
    return 1
  fi
  return 0
}

# Check the layout of a prepared directory and print its base, the AUR
# commit the update was prepared from
# Args: $1=prepared dir
# Returns: 0 when the layout holds, 1 otherwise (reason on stderr)
prepared_base() {
  local f base
  if [[ -L "$1" || ! -d "$1" ]]; then
    log_err "Prepared directory is missing or a symlink: $1"
    return 1
  fi
  for f in PKGBUILD .SRCINFO base; do
    if [[ ! -f "$1/$f" || -L "$1/$f" ]]; then
      log_err "Prepared $f is missing or not a regular file"
      return 1
    fi
  done
  base=$(<"$1/base")
  if [[ ! "$base" =~ ^[0-9a-f]{40}$ ]]; then
    log_err "Prepared base is not a commit id"
    return 1
  fi
  echo "$base"
}

# Check a prepared PKGBUILD and .SRCINFO against the AUR repo at their base
# Args: $1=AUR repo, $2=prepared dir, $3=expected version,
#       $4=pkgver_dash character of the package, if any,
#       $5=pkgver_format of the package, if any
# Returns: 0 when both files pass, 1 otherwise (reason on stderr)
check_prepared_files() {
  local f
  # git keeps symlinks, and cp writes through one
  for f in PKGBUILD .SRCINFO; do
    if [[ -L "$1/$f" || ! -f "$1/$f" ]]; then
      log_err "$f in the AUR repo is missing, a symlink or not a regular file"
      return 1
    fi
  done
  check_prepared_pkgbuild "$1/PKGBUILD" "$2/PKGBUILD" "$3" &&
    check_prepared_srcinfo "$1/.SRCINFO" "$2/.SRCINFO" "$3" "${4:-}" "${5:-}"
}
