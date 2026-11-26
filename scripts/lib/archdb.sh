#!/usr/bin/env bash
#
# archdb.sh - Packages of Arch and the AUR: .SRCINFO of the AUR, the files database, provides
#
# Sourced by lib.sh.

# check-all.sh keeps AURTOMATOR_RUN_CACHE for the run: aur/ holds AUR clones and their .SRCINFO,
# py-dists the distributions of the files database, repo-pkgs and aur-pkgs the packages read

# Make sure AURTOMATOR_RUN_CACHE names a directory; without one this process makes its own
archdb_cache() {
  if [[ -z "${AURTOMATOR_RUN_CACHE:-}" || ! -d "$AURTOMATOR_RUN_CACHE" ]]; then
    AURTOMATOR_RUN_CACHE=$(mktemp -d) || return 1
    export AURTOMATOR_RUN_CACHE
  fi
}

# Print the path of the .SRCINFO of HEAD of AUR package base $1, cloned once per run
# Returns: 0, 3 for a repository without commits, which the AUR serves for a new package, 1 otherwise
aur_srcinfo() {
  local LC_ALL=C dir srcinfo
  if [[ ! "$1" =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ ]]; then
    log_err "$1 is not an AUR package name"
    return 1
  fi
  archdb_cache || return 1
  dir="$AURTOMATOR_RUN_CACHE/aur/$1"
  srcinfo="$dir.SRCINFO"
  [[ ! -e "$dir.new" ]] || return 3
  if [[ ! -f "$srcinfo" ]]; then
    mkdir -p "$AURTOMATOR_RUN_CACHE/aur" || return 1
    rm -rf "$dir"
    # git warns of every empty repository, which the AUR serves for a new package
    if ! aur_clone "https://aur.archlinux.org/$1.git" "$dir" --depth 1 --no-checkout -q >"$dir.log" 2>&1; then
      cat "$dir.log" >&2
      return 1
    fi
    if ! git -C "$dir" rev-parse -q --verify HEAD >/dev/null; then
      : >"$dir.new"
      return 3
    fi
    if ! git -C "$dir" show HEAD:.SRCINFO >"$srcinfo.part"; then
      log_err "https://aur.archlinux.org/$1.git holds no .SRCINFO at HEAD"
      rm -f "$srcinfo.part"
      return 1
    fi
    mv "$srcinfo.part" "$srcinfo"
  fi
  printf '%s\n' "$srcinfo"
}

# Print the pkgnames of .SRCINFO $1 in order
srcinfo_pkgnames() {
  awk '/^pkgname = / { print substr($0, 11) }' "$1"
}

# Print the names in key $3, depends or optdepends, of pkgname $2 of .SRCINFO $1, then those of
# its x86_64 key: the values of the pkgname section when it sets the key, else those of pkgbase
srcinfo_depends() {
  local key
  for key in "$3" "$3_x86_64"; do
    awk -v pkg="$2" -v key="$key" '
      /^pkgbase = / { section = "base"; next }
      /^pkgname = / { section = (substr($0, 11) == pkg) ? "own" : "other"; next }
      index($0, "\t" key " = ") == 1 && section != "other" {
        value = substr($0, length(key) + 5)
        if (section == "own") { own_set = 1; if (value != "") own[++n_own] = value }
        else if (value != "") base[++n_base] = value
      }
      END {
        if (own_set) { for (i = 1; i <= n_own; i++) print own[i] }
        else { for (i = 1; i <= n_base; i++) print base[i] }
      }' "$1"
  done | sed -E 's/:.*$//; s/[<>=].*$//; s/[[:blank:]]+$//'
}

# Write the distributions of the files database to py-dists of the run cache once, lines of the
# PEP 503 name, the pkgname and the version, and set ARCHDB_FILES to files, or none without a database
# shellcheck disable=SC2034 # pyrules.sh reads ARCHDB_FILES
files_index_python() {
  local LC_ALL=C file pkg path dir dist version i
  # Packages built with setuptools ship <name>-<version>[-py3.<n>].egg-info, a directory or a file
  local re='^usr/lib/python3\.[0-9]+/site-packages/[^/]+\.(dist-info/METADATA|egg-info(/PKG-INFO)?)$'
  archdb_cache || return 1
  file="$AURTOMATOR_RUN_CACHE/py-dists"
  if [[ ! -f "$file" ]]; then
    {
      while IFS= read -r -d '' _ && IFS= read -r -d '' pkg && IFS= read -r -d '' _ && IFS= read -r path; do
        [[ "$path" =~ $re ]] || continue
        dir=${path%/PKG-INFO}
        dir=${dir%.dist-info/METADATA}
        dir=${dir%.egg-info}
        dir=${dir##*/}
        [[ ! "$dir" =~ -py3\.[0-9]+$ ]] || dir=${dir%-py3.*}
        # The version follows the last dash whose rest PEP 440 reads
        for ((i = ${#dir} - 1; i > 0; i--)); do
          [[ "${dir:i:1}" == - ]] || continue
          dist=${dir:0:i} version=${dir:i+1}
          if pep440_parse "$version" && _pypi_norm "$dist"; then
            printf '%s\t%s\t%s\n' "$PYPI_NORM" "$pkg" "$version"
            break
          fi
        done
      done < <(pacman -Fx --machinereadable "${re%\$}\$" 2>/dev/null)
    } | sort -u >"$file.part"
    [[ -s "$file.part" ]] || echo '#none' >"$file.part"
    mv "$file.part" "$file"
  fi
  # shellcheck disable=SC2034 # pyrules.sh reads it
  ARCHDB_FILES=files
  if [[ "$(head -c 5 "$file")" == '#none' ]]; then
    ARCHDB_FILES=none
  fi
}

# Print pkgname<TAB>path for each path of the files database that matches regex $1; fail when pacman
# fails, which exits 1 for no match as for an error and writes error: only for the latter
files_index_owner() {
  local LC_ALL=C pkg path out err rc=0
  out=$(mktemp) || return 1
  if ! err=$(mktemp); then
    rm -f "$out"
    return 1
  fi
  pacman -Fx --machinereadable "$1" >"$out" 2>"$err" || rc=$?
  if ((rc > 1)) || { ((rc == 1)) && grep -q '^error:' "$err"; }; then
    log_err "pacman -Fx exits $rc$(grep -m 1 '^error:' "$err" | sed 's/^/: /')"
    rm -f "$out" "$err"
    return 1
  fi
  while IFS= read -r -d '' _ && IFS= read -r -d '' pkg && IFS= read -r -d '' _ && IFS= read -r path; do
    printf '%s\t%s\n' "$pkg" "$path"
  done <"$out"
  rm -f "$out" "$err"
}

# Print the words $@ as alternations of a regex, one a line, each below 100,000 bytes, since
# Linux takes no argument past 128 KiB
files_index_alternations() {
  local word chunk=""
  for word in "$@"; do
    if ((${#chunk} + ${#word} >= 99000)) && [[ -n "$chunk" ]]; then
      printf '%s\n' "${chunk%|}"
      chunk=""
    fi
    chunk+="$word|"
  done
  [[ -z "$chunk" ]] || printf '%s\n' "${chunk%|}"
}

# Print the PEP 503 name and the version of each distribution of package $1 in py-dists
python_dists_of() {
  local name pkg version
  files_index_python || return 1
  while IFS=$'\t' read -r name pkg version; do
    [[ "$pkg" != "$1" ]] || printf '%s\t%s\n' "$name" "$version"
  done <"$AURTOMATOR_RUN_CACHE/py-dists"
}

# Set PKG_NAME, PKG_VERSION, the pkgver, and PKG_REPO of the repository package that name or provides
# $1 names, read once per run; fail when no repository has it
repo_package() {
  local LC_ALL=C file name pkg version repo answer
  [[ "$1" =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ ]] || return 1
  archdb_cache || return 1
  file="$AURTOMATOR_RUN_CACHE/repo-pkgs"
  if [[ -f "$file" ]]; then
    while IFS=$'\t' read -r name pkg version repo; do
      [[ "$name" == "$1" ]] || continue
      [[ "$pkg" != - ]] || return 1
      PKG_NAME=$pkg PKG_VERSION=$version PKG_REPO=$repo
      return 0
    done <"$file"
  fi
  if ! answer=$(pacman -Sddp --print-format '%n %v %r' -- "$1" 2>/dev/null) ||
    ! read -r pkg version repo <<<"$answer" || [[ -z "$repo" ]]; then
    printf '%s\t-\n' "$1" >>"$file"
    return 1
  fi
  version=${version#*:}
  PKG_NAME=$pkg PKG_VERSION=${version%-*} PKG_REPO=$repo
  printf '%s\t%s\t%s\t%s\n' "$1" "$PKG_NAME" "$PKG_VERSION" "$PKG_REPO" >>"$file"
}

# Read the AUR packages of names $@ that the run did not ask for yet into aur-pkgs, lines of the
# name, the version and the provides, joined by commas, through AUR RPC info in batches of 100
aur_packages() {
  local LC_ALL=C file name answer query count=0 version provides lines out
  local -A known=()
  local -a batch=()
  archdb_cache || return 1
  file="$AURTOMATOR_RUN_CACHE/aur-pkgs"
  if [[ -f "$file" ]]; then
    while IFS=$'\t' read -r name _; do
      known[$name]=1
    done <"$file"
  fi
  for name in "$@"; do
    [[ "$name" =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ && -z "${known[$name]:-}" ]] || continue
    known[$name]=1
    batch+=("$name")
  done
  while ((count < ${#batch[@]})); do
    query=""
    for name in "${batch[@]:count:100}"; do
      name=${name//+/%2B}
      query+="&arg[]=${name//@/%40}"
    done
    answer=$(http_get_json "https://aur.archlinux.org/rpc/v5/info?${query#&}") || return 1
    if [[ "$(yq -r '.type' <<<"$answer")" != multiinfo ]]; then
      log_err "https://aur.archlinux.org/rpc/v5/info: $(yq -r '.error // "the answer holds no packages"' <<<"$answer")"
      return 1
    fi
    lines=$(yq -r '.results[] | [.Name, .Version, ((.Provides // []) | map(sub("[<>=].*$"; "")) | join(","))] | join("\t")' <<<"$answer") ||
      return 1
    out=""
    while IFS=$'\t' read -r name version provides; do
      [[ "$name" =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ ]] || continue
      # The rules print the pkgver in their notes
      if [[ ! "$version" =~ ^([0-9]+:)?([^:-]+)-[0-9]+(\.[0-9]+)?$ ]] || ! validate_pkgver "${BASH_REMATCH[2]}" 2>/dev/null; then
        log_err "https://aur.archlinux.org/rpc/v5/info: $name has version ${version@Q}, not epoch:pkgver-pkgrel"
        return 1
      fi
      out+="$name"$'\t'"$version"$'\t'"$provides"$'\n'
    done <<<"$lines"
    # Names the AUR lacks get a line of their own, so the run asks for them once
    for name in "${batch[@]:count:100}"; do
      out+="$name"$'\t-\t\n'
    done
    printf '%s' "$out" >>"$file"
    count=$((count + 100))
  done
}

# Set PKG_NAME, PKG_VERSION, the pkgver, and PKG_REPO=aur for the AUR package that name or provides
# $1 names; fail when the AUR has none
aur_package() {
  local name version provides
  aur_packages "$1" || return 1
  while IFS=$'\t' read -r name version provides; do
    if [[ "$name" == "$1" && "$version" != - ]]; then
      version=${version#*:}
      PKG_NAME=$name PKG_VERSION=${version%-*} PKG_REPO=aur
      return 0
    fi
  done <"$AURTOMATOR_RUN_CACHE/aur-pkgs"
  while IFS=$'\t' read -r name version provides; do
    if [[ "$version" != - && ",$provides," == *",$1,"* ]]; then
      version=${version#*:}
      PKG_NAME=$name PKG_VERSION=${version%-*} PKG_REPO=aur
      return 0
    fi
  done <"$AURTOMATOR_RUN_CACHE/aur-pkgs"
  return 1
}

# Set PKG_NAME, PKG_VERSION and PKG_REPO for name or provides $1: the repositories first, then
# the AUR; fail when neither has it
arch_package() {
  repo_package "$1" || aur_package "$1"
}
