#!/usr/bin/env bash
#
# sums.sh - Checksums of the sources of a prepared update, computed the
# way makepkg computes them
#
# Sourced by lib.sh, after common.sh and prepared.sh.

# Print the path of the file makepkg hashes for a source, following
# get_protocol, get_filename and download_file of makepkg. A source that
# makepkg would handle another way is refused, never guessed at.
# Args: $1=source entry of a .SRCINFO, $2=AUR repo, $3=download directory
_source_file() {
  local entry="$1" url="${1#*::}" name file
  if [[ "$entry" == *::* ]]; then
    name="${entry%%::*}"
  else
    name="${entry##*/}"
  fi
  # makepkg reads lp: without :// as a bzr source
  if [[ -z "$name" || "$name" == */* || "$name" == . || "$name" == .. ]] ||
    [[ "$entry" == *://* && ! "${url%%://*}" =~ ^(http|https|ftp)$ ]] ||
    [[ "$entry" != *://* && "$entry" == *lp:* ]]; then
    log_err "Cannot check the checksum of $entry: only local files, http, https and ftp downloads and git sources are checked"
    return 1
  fi

  # makepkg takes a file of that name next to the PKGBUILD before it
  # downloads anything
  file="${2}/${name}"
  if [[ -e "$file" || -L "$file" ]]; then
    if [[ -L "$file" || ! -f "$file" ]]; then
      log_err "Source $entry is a symlink or not a regular file in the AUR repo"
      return 1
    fi
  elif [[ "$entry" != *://* ]]; then
    log_err "Local source $entry is missing from the AUR repo"
    return 1
  else
    file="${3}/$(printf '%s' "$url" | sha256sum | cut -d' ' -f1)"
    # Retried as makepkg does. Redirects may only lead to the protocols above.
    if [[ ! -f "$file" ]] &&
      ! curl -qgfsSL --retry 3 --retry-delay 3 --proto '=http,https,ftp' \
        --proto-redir '=http,https,ftp' -o "$file" "$url"; then
      rm -f "$file"
      log_err "Could not download $url"
      return 1
    fi
  fi
  printf '%s\n' "$file"
}

# Print the checksum makepkg computes for a git source, following
# download_git and calc_checksum_git of makepkg: the tar archive of the tag
# or commit, from a mirror clone with export-subst and export-ignore turned
# off. makepkg gives any other git source SKIP, so a checksum never matches.
# Args: $1=source entry of a .SRCINFO, $2=algorithm, $3=AUR repo,
#       $4=download directory
_git_source_sum() {
  local entry="$1" url="${1#*::}" name fragment="" ref dir sum
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/etc/makepkg.d/gitconfig
  url="${url#git+}"
  if [[ "$url" == *#* ]]; then
    fragment="${url#*#}"
    fragment="${fragment%\?*}"
  fi
  url="${url%%#*}"
  url="${url%%\?*}"
  ref="${fragment##*=}"
  if [[ "$entry" == *::* ]]; then
    name="${entry%%::*}"
  else
    name="${url%/}"
    name="${name##*/}"
    name="${name%%.git*}"
  fi

  if [[ ! "${url%%://*}" =~ ^(http|https)$ ]]; then
    log_err "Cannot check the checksum of $entry: git sources are cloned over https or http only"
    return 1
  fi
  if [[ ! "${fragment%%=*}" =~ ^(tag|commit)$ || -z "$ref" || "$ref" == -* ]]; then
    log_err "Cannot check the checksum of $entry: makepkg hashes a git source only at a tag or commit"
    return 1
  fi
  if [[ -z "$name" || "$name" == */* || "$name" == . || "$name" == .. ]]; then
    log_err "Cannot check the checksum of $entry"
    return 1
  fi
  if [[ -e "${3}/${name}" || -L "${3}/${name}" ]]; then
    log_err "Cannot check the checksum of $entry: ${name} in the AUR repo takes the place of the clone in makepkg"
    return 1
  fi

  dir="${4}/$(printf '%s' "$url" | sha256sum | cut -d' ' -f1).git"
  if [[ ! -d "$dir" ]]; then
    if ! GIT_ALLOW_PROTOCOL=http:https git clone -q --origin=origin --mirror "$url" "$dir"; then
      rm -rf "$dir"
      log_err "Could not clone $url"
      return 1
    fi
    mkdir -p "${dir}/info"
    echo "* -export-subst -export-ignore" >"${dir}/info/attributes"
  fi
  if ! sum=$(git -c core.abbrev=no -C "$dir" archive --format tar "$ref" | "${2}sum"); then
    log_err "Could not archive $ref of $url"
    return 1
  fi
  printf '%s\n' "${sum%% *}"
}

# Print the checksum makepkg computes for a source
# Args: $1=source entry of a .SRCINFO, $2=algorithm, $3=AUR repo,
#       $4=download directory
_source_sum() {
  local proto="${1#*::}" file sum
  proto="${proto%%://*}"
  if [[ "$1" == *://* && "${proto%%+*}" == git ]]; then
    _git_source_sum "$@"
    return
  fi
  file=$(_source_file "$1" "$3" "$4") || return 1
  sum=$("${2}sum" "$file")
  printf '%s\n' "${sum%% *}"
}

# check_prepared_pkgbuild lets checksum values change, and the code of one
# PKGBUILD runs where the updates of all packages are prepared. So each
# value must match its source, hashed the way makepkg does. The sources
# come from the prepared .SRCINFO, which check_prepared_srcinfo ties to the
# AUR copy. Run check_prepared_files first.
# Args: $1=AUR repo, $2=prepared dir, $3=empty directory for the downloads
# Returns: 0 when every checksum matches, 1 otherwise (reason on stderr)
verify_prepared_sums() {
  local aur_dir="$1" prepared="$2" downloads="$3"
  local -A srcinfo=() pkgbuild=()
  local -a lines=() keys=() sums=() sources=()
  local line key value algo i actual

  # mapfile, as check_prepared_srcinfo reads it: a last line without a
  # newline counts
  mapfile -t lines <"${prepared}/.SRCINFO"
  for line in "${lines[@]}"; do
    [[ "$line" == *" = "* ]] || continue
    key="${line%% = *}"
    key="${key#"${key%%[![:space:]]*}"}"
    if [[ "$key" =~ ^source(_[A-Za-z0-9_]+)?$ ||
      "$key" =~ ^(ck|md5|sha1|sha224|sha256|sha384|sha512|b2)sums(_[A-Za-z0-9_]+)?$ ]]; then
      srcinfo[$key]+="${line#* = }"$'\n'
    fi
  done

  while IFS=$'\t' read -r _ key value; do
    [[ -n "${pkgbuild[$key]+set}" ]] || keys+=("$key")
    pkgbuild[$key]+="${value}"$'\n'
  done < <(_pkgbuild_parts "${prepared}/PKGBUILD" | grep $'^SUMVAL\t')

  for key in "${!srcinfo[@]}"; do
    if [[ "$key" == *sums* && -z "${pkgbuild[$key]+set}" ]]; then
      log_err "Prepared .SRCINFO lists ${key}, the PKGBUILD does not"
      return 1
    fi
  done

  for key in "${keys[@]}"; do
    if [[ "${srcinfo[$key]:-}" != "${pkgbuild[$key]}" ]]; then
      log_err "Prepared PKGBUILD and .SRCINFO differ in ${key}"
      return 1
    fi
    algo="${key%%sums*}"
    mapfile -t sums < <(printf '%s' "${pkgbuild[$key]}")
    mapfile -t sources < <(printf '%s' "${srcinfo[source${key#*sums}]:-}")
    if [[ "${#sums[@]}" -ne "${#sources[@]}" ]]; then
      log_err "Prepared .SRCINFO has ${#sums[@]} ${key} for ${#sources[@]} sources"
      return 1
    fi
    for i in "${!sums[@]}"; do
      [[ "${sums[$i]}" != "SKIP" ]] || continue
      actual=$(_source_sum "${sources[$i]}" "$algo" "$aur_dir" "$downloads") || return 1
      if [[ "${sums[$i],,}" != "$actual" ]]; then
        log_err "${key} of ${sources[$i]} is ${sums[$i]}, the source has ${actual}"
        return 1
      fi
    done
  done
  return 0
}
