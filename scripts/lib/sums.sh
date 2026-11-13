#!/usr/bin/env bash
#
# sums.sh - Checksums of the sources of a prepared update, computed as makepkg computes them
#
# Sourced by lib.sh, after common.sh and prepared.sh.

# The byte limits of one download and of all the downloads of one package
SOURCE_FILE_MAX=$((600 * 1024 * 1024))
SOURCES_MAX=$((1024 * 1024 * 1024))

# Print the bytes a download may still take: what SOURCES_MAX leaves beside
# the downloads in directory $1, at most SOURCE_FILE_MAX
_download_left() {
  local used left
  used=$(du -sb -- "$1" | cut -f1) || return 1
  left=$((SOURCES_MAX - used))
  if ((left <= 0)); then
    log_err "The downloads of the package reach the budget of 1 GiB"
    return 1
  fi
  ((left < SOURCE_FILE_MAX)) || left=$SOURCE_FILE_MAX
  printf '%s\n' "$left"
}

# Print the path of the file makepkg hashes for a source, as get_protocol, get_filename and
# download_file of makepkg find it, and refuse a source makepkg would handle another way
# Args: $1=source entry of a .SRCINFO, $2=AUR repo, $3=download directory
_source_file() {
  local entry="$1" url="${1#*::}" name file left rc
  if [[ "$entry" == *::* ]]; then
    name="${entry%%::*}"
  else
    name="${entry##*/}"
  fi
  # makepkg reads lp: without :// as a bzr source. Over http or ftp the
  # network path would pick the file, and with it the checksum.
  if [[ -z "$name" || "$name" == */* || "$name" == . || "$name" == .. ]] ||
    [[ "$entry" == *://* && "${url%%://*}" != https ]] ||
    [[ "$entry" != *://* && "$entry" == *lp:* ]]; then
    log_err "Cannot check the checksum of $entry: only local files, https downloads and git sources over https are checked"
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
    if [[ ! -f "$file" ]]; then
      left=$(_download_left "$3") || return 1
      # Retried and with the cookie engine on, as makepkg does. The AUR copy
      # picks the URL, so redirects stay on https and size and stalls are bounded.
      rc=0
      curl -qgfsSL -b '' --retry 3 --retry-delay 3 --proto '=https' \
        --proto-redir '=https' --max-filesize "$left" --speed-limit 102400 \
        --speed-time 60 -o "$file" "$url" || rc=$?
      if ((rc != 0)); then
        rm -f "$file"
        if ((rc == 63 && left < SOURCE_FILE_MAX)); then
          log_err "The downloads of the package pass the budget of 1 GiB at $url"
        else
          log_err "Could not download $url"
        fi
        return 1
      fi
    fi
  fi
  printf '%s\n' "$file"
}

# Print the checksum makepkg computes for a git source at #tag= or #commit=: that of the tar
# archive of the ref, fetched alone, with export-subst and export-ignore off
# Args: $1=source entry of a .SRCINFO, $2=algorithm, $3=AUR repo, $4=download directory
_git_source_sum() {
  local entry="$1" url="${1#*::}" name fragment="" ref dir sum refspec left
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

  if [[ "${url%%://*}" != https ]]; then
    log_err "Cannot check the checksum of $entry: git sources are cloned over https only"
    return 1
  fi
  if [[ ! "${fragment%%=*}" =~ ^(tag|commit)$ || -z "$ref" || "$ref" == -* ]]; then
    log_err "Cannot check the checksum of $entry: makepkg hashes a git source only at a tag or commit"
    return 1
  fi
  # makepkg finds a short id in its full clone, and git fetch takes a full one only
  if [[ "${fragment%%=*}" == commit && ! "$ref" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
    log_err "Cannot check the checksum of $entry: git fetches a commit by its full id only"
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

  # The tar holds the tree and the commit, so one ref without its history
  # gives the checksum of a full clone
  dir="${4}/$(printf '%s#%s' "$url" "$fragment" | sha256sum | cut -d' ' -f1).git"
  if [[ ! -d "$dir" ]]; then
    left=$(_download_left "$4") || return 1
    refspec="$ref"
    [[ "${fragment%%=*}" != tag ]] || refspec="refs/tags/${ref}:refs/tags/${ref}"
    if ! git init -q --bare "$dir"; then
      rm -rf "$dir"
      log_err "Could not fetch ${fragment} of $url"
      return 1
    fi
    # The pack goes into one file under a size limit of the budget left, and a stall ends the
    # fetch as it ends a download; an ignored SIGXFSZ makes a write past the limit fail, no dump
    if ! (trap '' XFSZ && ulimit -f "$((left / 1024))" && GIT_ALLOW_PROTOCOL=https git -c fetch.unpackLimit=1 \
      -c http.lowSpeedLimit=102400 -c http.lowSpeedTime=60 -C "$dir" fetch -q --depth 1 --no-tags "$url" "$refspec"); then
      if (($(du -sb -- "$dir" | cut -f1) >= left / 1024 * 1024)); then
        log_err "The fetch of ${fragment} of $url passes the budget of 1 GiB of the package"
      else
        log_err "Could not fetch ${fragment} of $url"
      fi
      rm -rf "$dir"
      return 1
    fi
    if ! _download_left "$4" >/dev/null 2>&1; then
      log_err "The fetch of ${fragment} of $url passes the budget of 1 GiB of the package"
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
# Args: $1=source entry of a .SRCINFO, $2=algorithm, $3=AUR repo, $4=download directory
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

# Check each checksum of the prepared update against its source, since prepare computed them
# where PKGBUILD code runs; check_prepared_files ties the sources to the AUR copy first
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
