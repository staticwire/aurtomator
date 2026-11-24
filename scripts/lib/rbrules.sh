#!/usr/bin/env bash
#
# rbrules.sh - The requires rules of gems: the requirements of a gem release against Arch packages
#
# Sourced by lib.sh.

# Write the gems of the files database to gems of the run cache once: lines of the gem name, the pkgname
# and the version, default gems included; set ARCHDB_GEMS to files, or none without a database
# shellcheck disable=SC2034 # the rules of gems read ARCHDB_GEMS
files_index_gems() {
  local LC_ALL=C file pkg path stem gem version i
  local re='^usr/lib/ruby/gems/[^/]+/specifications/(default/)?[^/]+\.gemspec$'
  archdb_cache || return 1
  file="$AURTOMATOR_RUN_CACHE/gems"
  if [[ ! -f "$file" ]]; then
    {
      while IFS= read -r -d '' _ && IFS= read -r -d '' pkg && IFS= read -r -d '' _ && IFS= read -r path; do
        [[ "$path" =~ $re ]] || continue
        stem=${path##*/}
        stem=${stem%.gemspec}
        # The version follows the last dash whose rest RubyGems reads as a version
        for ((i = ${#stem} - 1; i > 0; i--)); do
          [[ "${stem:i:1}" == - ]] || continue
          gem=${stem:0:i} version=${stem:i+1}
          if [[ "$version" == [0-9]* ]] && gem_version_valid "$version" && [[ "$gem" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            printf '%s\t%s\t%s\n' "$gem" "$pkg" "$version"
            break
          fi
        done
      done < <(pacman -Fx --machinereadable "${re%\$}\$" 2>/dev/null)
    } | sort -u >"$file.part"
    [[ -s "$file.part" ]] || echo '#none' >"$file.part"
    mv "$file.part" "$file"
  fi
  ARCHDB_GEMS=files
  if [[ "$(head -c 5 "$file")" == '#none' ]]; then
    ARCHDB_GEMS=none
  fi
}

# Print the name and the version of each gem of package $1 in the files database
gems_of() {
  files_index_gems || return 1
  awk -F'\t' -v p="$1" '$2 == p { print $1 "\t" $3 }' "$AURTOMATOR_RUN_CACHE/gems"
}

# Set RUBY_FULL to X.Y.Z of package ruby in the pacman databases, once per process, empty without it
ruby_version() {
  local LC_ALL=C line
  [[ -z "${RUBY_READ:-}" ]] || return 0
  RUBY_READ=1 RUBY_FULL=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^Version[[:blank:]]*:[[:blank:]]*([0-9]+:)?([0-9]+\.[0-9]+\.[0-9]+)-[0-9.]+[[:blank:]]*$ ]]; then
      RUBY_FULL=${BASH_REMATCH[2]}
    fi
  done < <(LC_ALL=C pacman -Si ruby 2>/dev/null)
}

# Set GEM_RUNTIME (lines of name and requirements), GEM_RUBY, GEM_SHA and GEM_URI of release $2 of gem $1
# from rubygems.org; return 3 when rubygems.org lists no such release
gem_release() {
  local LC_ALL=C json err name req
  GEM_RUNTIME="" GEM_RUBY="" GEM_SHA="" GEM_URI=""
  if [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || ! gem_version_valid "$2"; then
    log_err "rubygems.org names gems and versions of A-Za-z0-9._- alone: ${1@Q} ${2@Q}"
    return 1
  fi
  err=$(mktemp) || return 1
  if ! json=$(http_get_json "https://rubygems.org/api/v2/rubygems/$1/versions/$2.json" 2>"$err"); then
    if grep -q ': The requested URL returned error: 404$' "$err"; then
      rm -f "$err"
      log_err "$1: rubygems.org has no release $2"
      return 3
    fi
    cat "$err" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  if [[ "$(yq -r '.platform // ""' <<<"$json")" != ruby ]]; then
    log_err "https://rubygems.org/api/v2/rubygems/$1/versions/$2.json: the answer is not the release for the platform ruby"
    return 1
  fi
  while IFS=$'\t' read -r name req; do
    [[ -n "$name" ]] || continue
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || ! "$req" =~ ^[=!\<\>~\ 0-9A-Za-z.,-]+$ ]]; then
      log_err "$1 $2: rubygems.org lists a requirement it cannot read: ${name@Q} ${req@Q}"
      return 1
    fi
    GEM_RUNTIME+="$name"$'\t'"$req"$'\n'
  done < <(yq -r '.dependencies.runtime // [] | .[] | [.name, .requirements] | join("\t")' <<<"$json")
  GEM_RUNTIME=${GEM_RUNTIME%$'\n'}
  GEM_RUBY=$(yq -r '.ruby_version // ""' <<<"$json")
  GEM_SHA=$(yq -r '.sha // ""' <<<"$json")
  GEM_URI=$(yq -r '.gem_uri // ""' <<<"$json")
  if [[ ! "$GEM_RUBY" =~ ^[=!\<\>~\ 0-9A-Za-z.,-]*$ || ! "$GEM_SHA" =~ ^[0-9a-f]{64}$ ||
    "$GEM_URI" != "https://rubygems.org/gems/$1-$2.gem" ]]; then
    log_err "https://rubygems.org/api/v2/rubygems/$1/versions/$2.json: ruby_version, sha or gem_uri is not what RubyGems writes"
    return 1
  fi
}

# Succeed when depends of pkgname $2 of .SRCINFO $1 hold ruby or ruby-*
pkgname_has_ruby() {
  local dep
  while IFS= read -r dep; do
    [[ "$dep" != ruby && "$dep" != ruby-* ]] || return 0
  done < <(srcinfo_depends "$1" "$2" depends)
  return 1
}

# Print the package name that ruby.map of package file $1 gives gem $2
ruby_map() {
  pkg_get "$1" ".ruby.map // {} | select(tag == \"!!map\") | .[\"$2\"] // \"\" | select(tag == \"!!str\")"
}

# Set MATCH_PKG, MATCH_VERSION and MATCH_FROM, gem, pkgver or aur, for the entry of depends of pkgname
# $3 of .SRCINFO $2 that meets gem $4 of package file $1; fail when none does
ruby_match() {
  local dep name version mapped candidate pkg pkg_version pkg_repo
  local -a candidates=("ruby-$4" "ruby-${4//_/-}" "$4")
  mapped=$(ruby_map "$1" "$4")
  [[ -z "$mapped" ]] || candidates+=("$mapped")
  while IFS= read -r dep; do
    if ! arch_package "$dep"; then
      log_warn "$3: depends entry $dep is in neither the repositories nor the AUR"
      continue
    fi
    # shellcheck disable=SC2153 # arch_package of archdb.sh sets them
    pkg=$PKG_NAME pkg_version=$PKG_VERSION pkg_repo=$PKG_REPO
    if [[ "$4" == rubygems && "$pkg" == ruby ]]; then
      MATCH_PKG=ruby MATCH_VERSION="" MATCH_FROM=gem
      return 0
    fi
    if [[ "$pkg_repo" != aur ]]; then
      while IFS=$'\t' read -r name version; do
        if [[ "$name" == "$4" ]]; then
          MATCH_PKG=$pkg MATCH_VERSION=$version MATCH_FROM=gem
          return 0
        fi
      done < <(gems_of "$pkg")
    fi
    for candidate in "${candidates[@]}"; do
      if [[ "$candidate" == "$dep" || "$candidate" == "$pkg" ]] || _python_provides "$candidate" "$pkg" "$pkg_repo"; then
        MATCH_PKG=$pkg MATCH_VERSION=$pkg_version MATCH_FROM=pkgver
        [[ "$pkg_repo" != aur ]] || MATCH_FROM=aur
        return 0
      fi
    done
  done < <(srcinfo_depends "$2" "$3" depends)
  return 1
}

# Print how the names of the runtime requirements change from release $3 to release $4 of gem $2 of
# package file $1, as adds a, b; drops c, and nothing when they match
ruby_change() {
  local old new name added dropped rc=0
  local -A in_old=() in_new=()
  local -a adds=() drops=()
  # shellcheck disable=SC2034 # _curl_get of common.sh reads it
  MAX_ANSWER_MB=$(max_answer_mb "$1") || return 1
  gem_release "$2" "$4" || return 1
  new=$(cut -f1 <<<"$GEM_RUNTIME")
  gem_release "$2" "$3" 2>/dev/null || rc=$?
  if ((rc == 3)); then
    printf 'rubygems.org has no release %s of %s to compare with\n' "$3" "$2"
    return 0
  fi
  if ((rc != 0)); then
    gem_release "$2" "$3"
    return 1
  fi
  old=$(cut -f1 <<<"$GEM_RUNTIME")
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

# Print the notes of rule unmet for release $4 of gem $3, packaged by package file $1 with .SRCINFO $2:
# lines of hold or notice, a tab and the note, for each pkgname with Ruby in depends
ruby_unmet() {
  local file=$1 srcinfo=$2 gem=$3 version=$4 read="" pkgname prefix="" dep line out
  local -a pkgnames deps unknown
  mapfile -t pkgnames < <(srcinfo_pkgnames "$srcinfo")
  ((${#pkgnames[@]} < 2)) || prefix=1
  for pkgname in "${pkgnames[@]}"; do
    pkgname_has_ruby "$srcinfo" "$pkgname" || continue
    if [[ -z "$read" ]]; then
      read=1
      # shellcheck disable=SC2034 # _curl_get of common.sh reads it
      MAX_ANSWER_MB=$(max_answer_mb "$file") || return 1
      gem_release "$gem" "$version" || return 1
      files_index_gems || return 1
      ruby_version
    fi
    mapfile -t deps < <(srcinfo_depends "$srcinfo" "$pkgname" depends)
    unknown=()
    for dep in "${deps[@]}"; do
      repo_package "$dep" || unknown+=("$dep")
    done
    aur_packages "${unknown[@]}" || return 1
    out=$(_ruby_unmet_one "$file" "$srcinfo" "$pkgname") || return 1
    while IFS= read -r line; do
      [[ -z "$line" ]] || printf '%s\t%s%s\n' "${line%%$'\t'*}" "${prefix:+$pkgname: }" "${line#*$'\t'}"
    done <<<"$out"
  done
}

# Print the notes of ruby_unmet for pkgname $3 of .SRCINFO $2 of package file $1, from GEM_RUNTIME,
# GEM_RUBY and RUBY_FULL
_ruby_unmet_one() {
  local file=$1 srcinfo=$2 pkgname=$3 name req rc relax text skip
  relax=$(pkg_bool "$file" .ruby.relax)
  skip=" $(pkg_get "$file" '.ruby.skip // [] | .[] | select(tag == "!!str")' | tr '\n' ' ') "
  if [[ -n "$GEM_RUBY" && -n "$RUBY_FULL" ]]; then
    rc=0
    gem_holds "$RUBY_FULL" "$GEM_RUBY" || rc=$?
    ((rc != 1)) || printf 'hold\truby_version %s: ruby has %s\n' "$GEM_RUBY" "$RUBY_FULL"
  fi
  while IFS=$'\t' read -r name req; do
    [[ -n "$name" && "$skip" != *" $name "* ]] || continue
    if ! ruby_match "$file" "$srcinfo" "$pkgname" "$name"; then
      printf 'hold\t%s: not in depends\n' "$name"
      continue
    fi
    [[ -n "$MATCH_VERSION" ]] || continue
    text="$name $req: $MATCH_PKG has $MATCH_VERSION"
    case $MATCH_FROM in
      pkgver) text+=" (pkgver)" ;;
      aur) text+=" (AUR pkgver)" ;;
    esac
    rc=0
    gem_holds "$MATCH_VERSION" "$req" || rc=$?
    if ((rc == 2)); then
      printf 'notice\t%s: %s has %s, which RubyGems cannot compare\n' "$name" "$MATCH_PKG" "$MATCH_VERSION"
    elif ((rc == 1)); then
      # RubyGems checks every clause at start; a PKGBUILD that rewrites ~> sets ruby.relax
      if [[ "$relax" == true && -n "$GEM_TILDE_UPPER" ]]; then
        printf 'notice\t%s\n' "$text"
      else
        printf 'hold\t%s\n' "$text"
      fi
    fi
  done <<<"$GEM_RUNTIME"
}
