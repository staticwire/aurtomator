#!/usr/bin/env bash
# arch.sh - Versions without the archive of some arches, see https://aurtomator.dev/features/missing-arches/
# Sourced by lib.sh, after prepared.sh.

# Succeeds when package file $1 lets a version go out without some arches
missing_arch_allowed() {
  [[ "$(pkg_get "$1" '.allow_missing_arch')" != false && "$(pkgver_dash "$1")" != drop ]]
}

# Print the version of the value $1 of an arch_back or arch_added status, a
# version and arch names; fails for a value of another form
arch_status_version() {
  [[ "$1" == *" "* && "${1#* }" =~ ^[a-z0-9_]+( [a-z0-9_]+)*$ ]] || return 1
  validate_pkgver "${1%% *}" 2>/dev/null || return 1
  printf '%s\n' "${1%% *}"
}

# Succeeds for a list of arches that can be out: names separated by single
# spaces, or none, and never x86_64, which a version cannot go out without
arch_list_ok() {
  [[ -z "$1" || ("$1" =~ ^[a-z0-9_]+( [a-z0-9_]+)*$ && " $1 " != *" x86_64 "*) ]]
}

# Succeeds for the arches $1 and the start $2 of the wait of a line of _arches,
# each of which may be empty; a start after now would hold the wait for good
arch_record_ok() {
  arch_list_ok "$1" && { [[ -z "$2" ]] || { valid_time "$2" && [[ ! "$2" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]]; }; }
}

# Print the arches out of line $1 of _arches for version $2; fails for a line of
# another form or of another version
arch_record_out() {
  local record=$'^[^\t]*\t([^\t]*)\t([^\t]*)\t([^\t]*)(\t[0-9a-f]{40})?$' version first second
  [[ "$1" =~ $record ]] || return 1
  version=${BASH_REMATCH[1]}
  first=${BASH_REMATCH[2]}
  second=${BASH_REMATCH[3]}
  if [[ "$version" != "$2" ]] || ! arch_record_ok "$first" "$second"; then
    return 1
  fi
  printf '%s\n' "$first"
}

# Print the arches of the list $1 that the list $2 does not name
arch_minus() {
  local arch rest=""
  local -a arches
  read -ra arches <<<"$1"
  for arch in "${arches[@]}"; do
    [[ " $2 " == *" $arch "* ]] || rest+="${rest:+ }$arch"
  done
  printf '%s\n' "$rest"
}

# Write arch_wait of package file $1 for version $2 since $3, with the AUR commit $4 and the
# arches $5 it waits for when given, unless it holds that version and start already
set_arch_wait() {
  [[ "$(pkg_get "$1" '.arch_wait.version // ""')" != "$2" || "$(pkg_get "$1" '.arch_wait.since // ""')" != "$3" ]] || return 0
  if [[ -n "${4:-}" && -n "${5:-}" ]]; then
    VERSION="$2" SINCE="$3" COMMIT="$4" ARCHES="$5" \
      yq -i '.arch_wait = {"version": strenv(VERSION), "since": strenv(SINCE), "commit": strenv(COMMIT), "arches": strenv(ARCHES)}' "$1"
  else
    VERSION="$2" SINCE="$3" yq -i '.arch_wait = {"version": strenv(VERSION), "since": strenv(SINCE)}' "$1"
  fi
}

# Write the arch state of package file $1 after an update to the arch words $2
# that leaves out the arches $3 of AUR commit $4; a published version needs no wait
arch_state_after() {
  local arch
  local -a keys out_arches
  mapfile -t keys < <(pkg_get "$1" '.arch_out // {} | keys | .[]')
  for arch in "${keys[@]}"; do
    [[ -n "$arch" && " $2 " == *" $arch "* ]] || continue
    ARCH="$arch" yq -i 'del(.arch_out[strenv(ARCH)])' "$1"
  done
  read -ra out_arches <<<"$3"
  for arch in "${out_arches[@]}"; do
    ARCH="$arch" COMMIT="$4" yq -i '.arch_out[strenv(ARCH)] = strenv(COMMIT)' "$1"
  done
  if [[ "$(pkg_get "$1" 'has("arch_out") and (.arch_out | length) == 0')" == true ]]; then
    yq -i 'del(.arch_out)' "$1"
  fi
  if [[ "$(pkg_get "$1" 'has("arch_wait")')" == true ]]; then
    yq -i 'del(.arch_wait)' "$1"
  fi
}

# Print the arches of arch_out of package file $1 that the arches $2 do not
# name, separated by spaces
arches_back() {
  local arch back=""
  while IFS= read -r arch; do
    [[ -n "$arch" && " $2 " != *" $arch "* ]] || continue
    back+="${back:+ }$arch"
  done < <(pkg_get "$1" '.arch_out // {} | keys | .[]')
  printf '%s\n' "$back"
}

# Print the arch values of the pkgbase section of .SRCINFO $1, in order
srcinfo_arches() {
  awk '/^pkgname = /{exit} /^\tarch = /{print substr($0, 9)}' "$1"
}

# Print the arches of the list $2 that .SRCINFO $1 builds, as check-arch.sh
# needs of the commit of an arch in arch_out
srcinfo_built() {
  local arch built="" listed
  local -a arches
  listed=" $(srcinfo_arches "$1" | tr '\n' ' ') "
  read -ra arches <<<"$2"
  for arch in "${arches[@]}"; do
    [[ "$listed" != *" $arch "* ]] || built+="${built:+ }$arch"
  done
  printf '%s\n' "$built"
}

# Print the arches of arch_wait of package file $1 that HEAD of AUR clone $2 lacks, $3 holding
# the arches of HEAD, and that the commit of arch_wait builds, then that commit
wait_out() {
  local -x LC_ALL=C
  local commit arches out
  commit=$(pkg_get "$1" '.arch_wait.commit // ""')
  arches=$(pkg_get "$1" '.arch_wait.arches // ""')
  if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]] || ! arch_list_ok "$arches" ||
    ! git -C "$2" cat-file -e "${commit}^{commit}" 2>/dev/null; then
    return 0
  fi
  out=$(arch_minus "$arches" "$3 x86_64")
  out=$(srcinfo_built <(git -C "$2" show "${commit}:.SRCINFO") "$out")
  [[ -z "$out" ]] || printf '%s\n%s\n' "$out" "$commit"
}

# Print each line of .SRCINFO $1 that belongs to arch $2, after the header of its
# section and a tab: its arch line and every key that ends in _$2
srcinfo_arch_lines() {
  awk -v a="$2" '/^(pkgbase|pkgname) = / { section = $0 }
    $0 == "\tarch = " a || match($0, "^\t[a-z0-9]+_" a " = ") { print section "\t" $0 }' "$1"
}

# Print the pkgver of .SRCINFO $1
srcinfo_pkgver() {
  awk '/^\tpkgver = /{print substr($0, 11); exit}' "$1"
}

# Print the words of the one top-level arch=(...) line of PKGBUILD $1, one a
# line; fails for any other arch line or a word that is no plain arch name
pkgbuild_arch_words() {
  # Under a UTF-8 locale grep leaves out a line with a byte that is no UTF-8
  local -x LC_ALL=C
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

# Print the arches of arch_out of package file $3 that $2 and $4 do not name,
# and write the PKGBUILD and .SRCINFO of each commit in repo $1 to $5/<arch>/
arch_refs() {
  local arch commit back=""
  local -a out_arches
  read -ra out_arches <<<"$(arches_back "$3" "$4")"
  for arch in "${out_arches[@]}"; do
    [[ " $2 " != *" $arch "* ]] || continue
    commit=$(ARCH="$arch" yq -r '.arch_out[strenv(ARCH)]' "$3")
    if [[ ! "$arch" =~ ^[a-z0-9_]+$ ]] || [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]] || ! mkdir -p "$5/$arch" ||
      ! git -C "$1" cat-file blob "$commit:PKGBUILD" >"$5/$arch/PKGBUILD" 2>/dev/null ||
      ! git -C "$1" cat-file blob "$commit:.SRCINFO" >"$5/$arch/.SRCINFO" 2>/dev/null; then
      log_err "The commit of arch_out.$arch is not in the AUR repo: $commit"
      return 1
    fi
    back+="${back:+ }$arch"
  done
  printf '%s\n' "$back"
}

# Print the words $1 without the arches of list $2 that $3 does not keep, and
# with each arch of $4 back at the place its commit in $5/<arch>/ gives it
arch_update_words() {
  local arch words=""
  local -a old_words back_words
  read -ra old_words <<<"$1"
  read -ra back_words <<<"$4"
  for arch in "${old_words[@]}"; do
    [[ " $2 " == *" $arch "* && " $3 " != *" $arch "* ]] || words+="${words:+ }$arch"
  done
  for arch in "${back_words[@]}"; do
    words=$(arch_order "$words" "$arch" "$(srcinfo_arches "$5/$arch/.SRCINFO" | tr '\n' ' ')")
  done
  printf '%s\n' "$words"
}

# Print the arch words prepared PKGBUILD $3 must have with the arches out $5 of
# package file $4, if not those of $2 of AUR repo $1; arch_refs fills $6
prepared_arch_words() {
  # Under a UTF-8 locale grep leaves out a line with a byte that is no UTF-8
  local -x LC_ALL=C
  local text back kept="" arch words
  local -a aur_words new_words=()
  if ! text=$(pkgbuild_arch_words "$2"); then
    log_err "--arch-out needs one arch=(...) line of plain arch names in the PKGBUILD"
    return 1
  fi
  mapfile -t aur_words <<<"$text"
  back=$(arch_refs "$1" "${aur_words[*]}" "$4" "$5" "$6") || return 1
  if text=$(pkgbuild_arch_words "$3"); then
    mapfile -t new_words <<<"$text"
  fi
  # prepare keeps an arch of the list whose archives answer
  for arch in "${aur_words[@]}"; do
    [[ " $5 " != *" $arch "* || " ${new_words[*]} " != *" $arch "* ]] || kept+="${kept:+ }$arch"
  done
  words=$(arch_update_words "${aur_words[*]}" "$5" "$kept" "$back" "$6")
  [[ "$words" == "${aur_words[*]}" ]] || printf '%s\n' "$words"
}

# Check the arches $3 that come back in prepared dir $2 against their commits in
# $1/<arch>/; $4 to $8 are version, pkgver_dash, pkgver_format, asset_var, asset
check_arches_back() {
  local arch ref sums old_ver old_up="" new_up="" old_asset="" text i old new key old_val ok want
  local -a back_arches ref_lines new_lines
  read -ra back_arches <<<"$3"
  for arch in "${back_arches[@]}"; do
    ref="$1/$arch"
    sums=$(_arch_sum_arrays "$(_pkgbuild_parts "$ref/PKGBUILD")" "$arch" keep)
    if [[ "$(_arch_sum_arrays "$(_pkgbuild_parts "$2/PKGBUILD")" "$arch" keep)" != "$sums" ]]; then
      log_err "Prepared PKGBUILD puts $arch back with other checksum arrays than the commit of arch_out.$arch"
      return 1
    fi
    old_ver=$(srcinfo_pkgver "$ref/.SRCINFO")
    if [[ -n "${6:-}" ]]; then
      old_up=$(_unformat_version "$old_ver" "$6")
      new_up=$(_unformat_version "$4" "$6")
    fi
    [[ -z "${7:-}" ]] || old_asset=$(_plain_value "$ref/PKGBUILD" "$7")
    text=$(_pkgbuild_text "$ref/PKGBUILD" "${7:-}")
    mapfile -t ref_lines < <(srcinfo_arch_lines "$ref/.SRCINFO" "$arch")
    mapfile -t new_lines < <(srcinfo_arch_lines "$2/.SRCINFO" "$arch")
    if ((${#ref_lines[@]} != ${#new_lines[@]})); then
      log_err "Prepared .SRCINFO has ${#new_lines[@]} lines of $arch, the commit of arch_out.$arch has ${#ref_lines[@]}"
      return 1
    fi
    # Each line is that of the commit in its section, with the version replaced
    # as in any update
    for i in "${!ref_lines[@]}"; do
      old="${ref_lines[$i]#*$'\t'}"
      new="${new_lines[$i]#*$'\t'}"
      key="${old%% = *}"
      key="${key#$'\t'}"
      old_val="${old#* = }"
      ok=true
      want="$old"
      if [[ "$key" =~ ^(ck|md5|sha1|sha224|sha256|sha384|sha512|b2)sums_ ]]; then
        [[ "$old_val" == SKIP ]] || want="${old%% = *} = a checksum"
        if [[ "${new%% = *}" != "${old%% = *}" ]] || ! { [[ "${new#* = }" == SKIP && "$old_val" == SKIP ]] ||
          [[ "${new#* = }" =~ ^[0-9a-fA-F]+$ && "$old_val" != SKIP ]]; }; then
          ok=false
        fi
      elif [[ "$key" != source_* && "$text" == *"$old_val"* ]]; then
        [[ "$new" == "$old" ]] || ok=false
      else
        want=$(_bump_version "$old" "$old_ver" "$4" "$old_up" "$new_up")
        _bumped_line "$old" "$new" "$old_ver" "$4" "$old_up" "$new_up" "${5:-}" "$old_asset" "${8:-}" || ok=false
      fi
      [[ "${new_lines[$i]%%$'\t'*}" == "${ref_lines[$i]%%$'\t'*}" ]] || ok=false
      if [[ "$ok" == false ]]; then
        log_err "Prepared .SRCINFO puts $arch back with ${new#$'\t'} in ${new_lines[$i]%%$'\t'*}, expected ${want#$'\t'} in ${ref_lines[$i]%%$'\t'*}"
        return 1
      fi
    done
  done
  return 0
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
  request_begin "$1" || return 2
  response=$(curl -sIL -o /dev/null -w '%{http_code} %{content_type}' \
    --max-time 10 --max-redirs 5 "$1" 2>/dev/null) || {
    request_end
    return 2
  }
  request_end
  read -r code type <<<"$response"
  type="${type%%;*}"
  type="${type//[[:space:]]/}"
  # The server chooses the status line, and (( )) would run a subscript
  [[ "$code" =~ ^[1-5][0-9]{2}$ ]] || return 2
  if ((10#$code >= 400)) || [[ "${type,,}" == text/html ]]; then
    return 1
  fi
}
