#!/usr/bin/env bash
#
# prepared.sh - Checks of a prepared update against the AUR copy
#
# The job that executes a PKGBUILD holds no secrets, so the files it hands
# over are untrusted. The job that pushes accepts them only when they differ
# from the AUR copy in pkgver, pkgrel, the checksums as updpkgsums writes
# them and the value of the asset_var line. None of these checks sources the
# file.
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
#   SKEL<TAB>line          every line, with pkgver=, pkgrel=, the asset_var
#                          line and each top-level checksum array replaced
#                          by a placeholder
#   PKGVER|PKGREL|ASSET<TAB>val  the value of a pkgver=, pkgrel= or
#                          asset_var line
#   SUM<TAB>array<TAB>index<TAB>HASH|SKIP  one line per checksum
#   SUMVAL<TAB>array<TAB>value  the same checksum with its value
#   BAD<TAB>text           anything in a checksum array but a quoted
#                          checksum, a comment or a line continuation
# Args: $1=pkgbuild path, $2=asset_var of the package, if any
_pkgbuild_parts() {
  awk -v asset="${2:-}" '
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
    asset != "" && index($0, asset "=") == 1 {
      print "SKEL\tASSET"
      print "ASSET\t" substr($0, length(asset) + 2)
      next
    }
    { print "SKEL\t" $0 }
    END { if (in_sums) print "BAD\tunterminated " name }
  ' "$1"
}

# Print the SKEL lines among the parts in $2 with one SUMS line in place of
# the checksum arrays: one for each run of consecutive arrays with $1=runs,
# one for all of them at the place of the first with $1=all
_merged_skel() {
  awk -v mode="$1" '
    !/^SKEL\t/ { next }
    /^SKEL\tSUMS / { if (!merged) print "SKEL\tSUMS"; merged = 1; next }
    mode == "runs" { merged = 0 }
    { print }
  ' <<<"$2"
}

# Print the checksum arrays among the parts in $1 whatever their place: a
# line with the name of each array and a line per checksum, sorted by name,
# those of arrays of one name in file order
_sum_arrays() {
  grep -E $'^(SKEL\tSUMS |SUM\t)' <<<"$1" | sort -s -t $'\t' -k2,2
}

# Args: $1=AUR PKGBUILD, $2=prepared PKGBUILD, $3=expected version,
#       $4=expected pkgrel (default 1), $5=asset_var of the package, if
#       any, $6=expected asset value
# Returns: 0 when the prepared file changes only pkgver (to $3), pkgrel
#          (to $4), the checksums as updpkgsums writes them and the value of
#          its one asset_var line (to $6), 1 otherwise (reason on stderr)
check_prepared_pkgbuild() {
  local version="$3" rel="${4:-1}" asset_var="${5:-}" asset="${6:-}"
  local old_parts new_parts value
  local -a assets
  if ! old_parts=$(_pkgbuild_parts "$1" "$asset_var") || ! new_parts=$(_pkgbuild_parts "$2" "$asset_var"); then
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
  # updpkgsums writes all checksum arrays in one block at the place of the
  # first one, and a run without it leaves them where they stand
  if [[ "$(grep $'^SKEL\t' <<<"$old_parts")" != "$(grep $'^SKEL\t' <<<"$new_parts")" ]] &&
    [[ "$(_merged_skel all "$old_parts")" != "$(_merged_skel runs "$new_parts")" ]]; then
    log_err "Prepared PKGBUILD changes lines outside pkgver, pkgrel and checksums"
    return 1
  fi
  if [[ "$(_sum_arrays "$old_parts")" != "$(_sum_arrays "$new_parts")" ]]; then
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
    if [[ "$value" != "$rel" ]]; then
      log_err "Prepared PKGBUILD has pkgrel=${value}, expected ${rel}"
      return 1
    fi
  done < <(grep $'^PKGREL\t' <<<"$new_parts")
  [[ -n "$asset_var" ]] || return 0
  mapfile -t assets < <(grep $'^ASSET\t' <<<"$new_parts" | cut -f2-)
  if ((${#assets[@]} != 1)); then
    log_err "Prepared PKGBUILD needs one ${asset_var}= line, it has ${#assets[@]}"
    return 1
  fi
  if [[ "${assets[0]}" != "$asset" ]]; then
    log_err "Prepared PKGBUILD has ${asset_var}=${assets[0]}, expected ${asset}"
    return 1
  fi
}

# Print the value of the one asset_var line of a PKGBUILD
# Args: $1=PKGBUILD, $2=asset_var, $3=name of the file in messages
# Returns: 1 when the file has no such line or more than one, or when the
#          value is rejected (reason on stderr)
_asset_line_value() {
  local -a values
  mapfile -t values < <(sed -n "s/^$2=//p" "$1")
  if ((${#values[@]} != 1)); then
    log_err "$3 needs one $2= line, it has ${#values[@]}"
    return 1
  fi
  validate_asset_value "${values[0]}" || return 1
  printf '%s\n' "${values[0]}"
}

# Print the pkgrel of an update of a package with asset_var: 1 for a new
# version, the AUR pkgrel plus one for a rebuild, which is a new asset
# value of the same version, and the AUR pkgrel when the AUR already has
# the value
# Args: $1=AUR PKGBUILD, $2=asset_var, $3=version, $4=asset value
# Returns: 1 when the asset_var line of the AUR PKGBUILD is refused, or a
#          rebuild meets a pkgrel that is not an integer (reason on stderr)
_asset_pkgrel() {
  local old_asset old_rel
  old_asset=$(_asset_line_value "$1" "$2" "AUR PKGBUILD") || return 1
  if [[ "$3" != "$(sed -n 's/^pkgver=//p' "$1" | head -1)" ]]; then
    echo 1
    return 0
  fi
  old_rel=$(sed -n 's/^pkgrel=//p' "$1" | head -1)
  if [[ "$4" == "$old_asset" ]]; then
    printf '%s\n' "$old_rel"
    return 0
  fi
  if [[ ! "$old_rel" =~ ^[0-9]+$ ]]; then
    log_err "A rebuild needs an integer pkgrel in the AUR PKGBUILD, it has ${old_rel}"
    return 1
  fi
  echo "$((10#$old_rel + 1))"
}

# Replace the old version in a line with the new one, and also the forms a
# PKGBUILD derives from pkgver: dots and plus signs turned into
# underscores, the part before the first +, and the version without its
# last component, such as ${pkgver%.*} in the frameworks/6.19/ directory
# of KDE Frameworks. That last form counts only while it keeps a dot, as a
# lone major version is too common in other text. One pass from left to
# right, longest form first, so a replaced part is not matched again: with
# 5.1.0 -> 5.10.0 the 5.1 at the start of 5.10.0 stays. A form counts only
# where it does not continue another number, with no digit or dot before it
# and no digit after it, so the 0.1 inside 10.1 stays. With pkgver_format,
# the upstream version inside the version is the last form, as 4215 in
# 4.4215.
# Args: $1=line, $2=old version, $3=new version, $4=old upstream version,
#       $5=new upstream version
_bump_version() {
  local rest="$1" lead=" $1" old="$2" new="$3" out="" i matched
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

  # lead is the line after a space, so its character at the length of the
  # part already read is the one before rest
  while [[ -n "$rest" ]]; do
    matched=false
    for i in "${!olds[@]}"; do
      if [[ "${lead:${#1}-${#rest}:1}" != [0-9.] && "$rest" == "${olds[$i]}"* && "${rest:${#olds[$i]}:1}" != [0-9] ]]; then
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
# ${pkgver//_/-} writes 0.0.1-rc.20 for pkgver 0.0.1_rc.20. With drop, for
# pkgver_dash: '', a form with a dash between two characters counts, as
# ${pkgver/rc/-rc} writes 2.5.0-rc1 for pkgver 2.5.0rc1.
# Args: $1=line, $2=version, $3=pkgver_dash character or drop
_undash_version() {
  local rest="$1" version="$2" dash="$3" re="" out="" c i match
  for ((i = 0; i < ${#version}; i++)); do
    c="${version:i:1}"
    if [[ "$dash" == drop ]] && ((i > 0)); then
      re+="-?"
    fi
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
#       $5=pkgver_dash character or drop
# Returns: 0 when the prepared line is the AUR line with the version
#          replaced, once a dash in place of the pkgver_dash character in
#          either version counts as that character, or as nothing for drop
_bumped_with_dash() {
  [[ "$(_undash_version "$2" "$4" "$5")" == "$(_bump_version "$(_undash_version "$1" "$3" "$5")" "$3" "$4")" ]]
}

# Args: $1=AUR line, $2=prepared line, $3=old version, $4=new version,
#       $5=old upstream version, $6=new upstream version, $7=pkgver_dash
#       character or drop, $8=old asset value, $9=new asset value
# Returns: 0 when the prepared line is the AUR line with the version
#          replaced, by _bump_version or by _bumped_with_dash. For a
#          package with asset_var, each old asset value of the AUR line
#          stands for the new one in the prepared line, and the parts
#          between them are compared one by one, so a dash inside a value
#          is never taken for one of the version.
_bumped_line() {
  local old="$1" new="$2"
  if [[ -n "${8:-}" ]]; then
    while [[ "$old" == *"$8"* ]]; do
      if [[ "$new" != *"$9"* ]] || ! _bumped_line "${old%%"$8"*}" "${new%%"$9"*}" "${@:3:5}"; then
        return 1
      fi
      old="${old#*"$8"}"
      new="${new#*"$9"}"
    done
  fi
  [[ "$new" == "$(_bump_version "$old" "$3" "$4" "$5" "$6")" ]] || _bumped_with_dash "$old" "$new" "$3" "$4" "$7"
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
# revision, some source URL or checksum has to change too, for each
# architecture, the common sources and checksums counting for all of them:
# a pkgver built from another variable, a source URL without the version,
# a pin that stays, or a version only in the name a download is saved
# under, the part before ::, would otherwise label the old files with the
# new version. A download with a real checksum that gets a new name and
# keeps its URL and its checksum is refused on its own, whatever another
# source does. With
# pkgver_dash, a version with a dash in place of that character, as
# ${pkgver//_/-} writes it, counts as the version, and with pkgver_dash: ''
# a version with a dash between two characters. With pkgver_format, so
# does the upstream version inside it, as ${pkgver#4.} writes 4215. For a
# package with asset_var, the old asset value is replaced by the new one
# as well, and pkgrel is the one check_prepared_files works out. A new
# asset value has to change some source URL or checksum.
# Args: $1=AUR .SRCINFO, $2=prepared .SRCINFO, $3=expected version,
#       $4=pkgver_dash character of the package or drop, if any,
#       $5=pkgver_format of the package, if any, $6=expected pkgrel
#       (default 1), $7=old asset value, $8=new asset value
# Returns: 0 when that holds, 1 otherwise (reason on stderr)
check_prepared_srcinfo() {
  local version="$3" dash="${4:-}" format="${5:-}" rel="${6:-1}" old_asset="${7:-}" new_asset="${8:-}"
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

  # A group is the common sources and checksums, _, or those of one
  # architecture, _x86_64
  local -A arch_groups=() arches=() pinned_in=() changed_in=() sum_counts=() sum_moved=() renamed=()
  local i old new key kind old_val new_val n expected group arch has_arch=false changed=false
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
        [[ "$new_val" == "$rel" ]] || {
          log_err "Prepared .SRCINFO has pkgrel = ${new_val}, expected ${rel}"
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
        group="${key#*sums}"
        group="${group:-_}"
        arch_groups["$group"]=1
        n="${sum_counts[$key]:-0}"
        sum_counts[$key]=$((n + 1))
        if [[ "$new" != "$old" ]]; then
          changed=true
          changed_in["$group"]=1
          sum_moved["${key#*sums}:$n"]=1
        fi
        ;;
      source)
        n="${source_counts[$key]:-0}"
        source_counts[$key]=$((n + 1))
        expected=$(_bump_version "$old" "$old_ver" "$version" "$old_up" "$new_up")
        if ! _bumped_line "$old" "$new" "$old_ver" "$version" "$old_up" "$new_up" "$dash" "$old_asset" "$new_asset" &&
          ! { [[ -n "${skip_sources["${key#source}:$n"]:-}" ]] &&
            _name_differs_in_digits "$expected" "$new"; }; then
          log_err "Prepared .SRCINFO line $((i + 1)) is not the AUR source with the new version: ${new#"${new%%[![:space:]]*}"}, expected ${expected#"${expected%%[![:space:]]*}"}"
          return 1
        fi
        group="${key#source}"
        group="${group:-_}"
        arch_groups["$group"]=1
        if [[ "${new_val#*::}" != "${old_val#*::}" ]]; then
          changed=true
          changed_in["$group"]=1
        elif [[ "${new_val%%::*}" != "${old_val%%::*}" && -n "${hashed_sources["${key#source}:$n"]:-}" ]] &&
          _is_download "$old_val"; then
          renamed["${key#source}:$n"]="line $((i + 1)) saves the download of the old version under a new name: $new_val"
        fi
        if { [[ -n "${hashed_sources["${key#source}:$n"]:-}" ]] && _is_download "$old_val"; } ||
          _is_vcs_pin "$old_val"; then
          pinned_in["$group"]=1
        fi
        ;;
      *)
        [[ "$key" != arch ]] || arches["$new_val"]=1
        if [[ "$new" != "$old" ]] &&
          ! _bumped_line "$old" "$new" "$old_ver" "$version" "$old_up" "$new_up" "$dash" "$old_asset" "$new_asset"; then
          log_err "Prepared .SRCINFO line $((i + 1)) changes more than the version: $new"
          return 1
        fi
        ;;
    esac
  done
  for group in "${!arch_groups[@]}"; do
    [[ "$group" == _ ]] || has_arch=true
  done
  if [[ "$version" != "$old_ver" && "$has_arch" == false ]]; then
    if [[ -n "${pinned_in[_]:-}" && -z "${changed_in[_]:-}" ]]; then
      log_err "Prepared .SRCINFO changes no source URL and no checksum, so the new version would hold the files of the old one"
      return 1
    fi
  elif [[ "$version" != "$old_ver" ]]; then
    # The arch lines name every architecture, one that builds from the
    # common sources alone too
    for arch in "${!arches[@]}"; do
      if [[ -n "${pinned_in[_]:-}${pinned_in[_$arch]:-}" && -z "${changed_in[_]:-}${changed_in[_$arch]:-}" ]]; then
        log_err "Prepared .SRCINFO changes no source URL and no checksum for $arch, so the new version would hold the files of the old one"
        return 1
      fi
    done
  fi
  if [[ "$changed" == false && "$new_asset" != "$old_asset" ]]; then
    log_err "Prepared .SRCINFO changes no source URL and no checksum, so the new asset value reaches no source"
    return 1
  fi
  for key in "${!renamed[@]}"; do
    if [[ -z "${sum_moved[$key]:-}" ]]; then
      log_err "Prepared .SRCINFO ${renamed[$key]}"
      return 1
    fi
  done
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

# Check a prepared PKGBUILD and .SRCINFO against the AUR repo at their base.
# For a package with asset_var, the old asset value and the pkgrel come
# from the AUR PKGBUILD, see _asset_pkgrel.
# Args: $1=AUR repo, $2=prepared dir, $3=expected version,
#       $4=pkgver_dash character of the package or drop, if any,
#       $5=pkgver_format of the package, if any, $6=asset_var of the
#       package, if any, $7=expected asset value
# Returns: 0 when both files pass, 1 otherwise (reason on stderr)
check_prepared_files() {
  local f rel=1 old_asset=""
  # git keeps symlinks, and cp writes through one
  for f in PKGBUILD .SRCINFO; do
    if [[ -L "$1/$f" || ! -f "$1/$f" ]]; then
      log_err "$f in the AUR repo is missing, a symlink or not a regular file"
      return 1
    fi
  done
  if [[ -n "${6:-}" ]]; then
    rel=$(_asset_pkgrel "$1/PKGBUILD" "$6" "$3" "$7") || return 1
    old_asset=$(_asset_line_value "$1/PKGBUILD" "$6" "AUR PKGBUILD")
  fi
  check_prepared_pkgbuild "$1/PKGBUILD" "$2/PKGBUILD" "$3" "$rel" "${6:-}" "${7:-}" &&
    check_prepared_srcinfo "$1/.SRCINFO" "$2/.SRCINFO" "$3" "${4:-}" "${5:-}" "$rel" "$old_asset" "${7:-}"
}
