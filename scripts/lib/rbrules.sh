#!/usr/bin/env bash
#
# rbrules.sh - The requires rules of gems: the requirements and requires of a gem release against Arch packages
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

# Print the package name that ruby.map of package file $1 gives gem $2; the name stays out of the yq
# expression, since require paths of the gem reach it
ruby_map() {
  local key value
  while IFS=$'\t' read -r key value; do
    if [[ "$key" == "$2" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done < <(pkg_get "$1" '.ruby.map // {} | select(tag == "!!map") | to_entries[] | select(.value | tag == "!!str") | [.key, .value] | join("\t")')
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

# Print the notes of rule imports for release $4 of gem $3, packaged by package file $1 with .SRCINFO $2:
# lines of notice, a tab and the note, for each pkgname with Ruby in depends
ruby_imports() {
  local pkgname any="" work rc=0 out
  local -a pkgnames
  mapfile -t pkgnames < <(srcinfo_pkgnames "$2")
  for pkgname in "${pkgnames[@]}"; do
    ! pkgname_has_ruby "$2" "$pkgname" || any=1
  done
  [[ -n "$any" ]] || return 0
  files_index_gems || return 1
  if [[ "$ARCHDB_GEMS" == none ]]; then
    printf 'notice\timports: pacman has no files database, not read\n'
    return 0
  fi
  archdb_cache || return 1
  work=$(mktemp -d "$AURTOMATOR_RUN_CACHE/rb-imports.XXXXXX") || return 1
  out=$(_ruby_imports_read "$1" "$2" "$3" "$4" "$work" "${pkgnames[@]}") || rc=$?
  rm -rf "$work"
  ((rc == 0)) || return 1
  [[ -z "$out" ]] || printf '%s\n' "$out" | LC_ALL=C sort -u
}

# Succeed when $1 is a relative path of parts of A-Za-z0-9._-, none of them .., so it stays in the tree
_ruby_tree_path() {
  local LC_ALL=C
  [[ "$1" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "/$1/" != */../* ]]
}

# Succeed when bsdtar error file $1 holds an error other than a pattern that matched nothing
_rb_bsdtar_failed() {
  grep -qv -e ': Not found in archive$' -e '^bsdtar: Error exit delayed from previous errors' "$1"
}

# ruby_imports for package file $1, .SRCINFO $2, gem $3, release $4, work directory $5 and the
# pkgnames after it: reads the files of the .gem and prints the notes of each pkgname
_ruby_imports_read() {
  local LC_ALL=C file=$1 srcinfo=$2 gem=$3 work=$5 name count size rc=0 helper bindir path pkgname
  local -a pkgnames=("${@:6}") paths=() tree_paths=() exes=() files=() include
  # shellcheck disable=SC2034 # _curl_get of common.sh reads it
  MAX_ANSWER_MB=$(max_answer_mb "$file") || return 1
  gem_release "$gem" "$4" || return 1
  name=${GEM_URI##*/}
  http_get "$GEM_URI" -o "$work/gem" || return 1
  if [[ "$(sha256sum "$work/gem")" != "$GEM_SHA "* ]]; then
    log_err "$name does not match its sha256"
    return 1
  fi
  # Each member takes at most MAX_ANSWER_MB, and an ignored SIGXFSZ makes a write past it fail
  if ! (trap '' XFSZ && ulimit -f $((${MAX_ANSWER_MB:-50} * 1024)) && bsdtar -xqOf "$work/gem" metadata.gz >"$work/metadata.gz" &&
    bsdtar -xqOf "$work/gem" data.tar.gz >"$work/data.tar.gz" && gzip -dc "$work/metadata.gz" >"$work/spec") 2>/dev/null; then
    printf 'notice\timports: %s holds no metadata.gz and data.tar.gz that bsdtar and gzip read, not read\n' "$name"
    return 0
  fi
  # yq refuses the !ruby/object tags of the spec, and the keys at column 0 hold what the rule reads
  bindir=$(awk '/^bindir: / { print $2; exit }' "$work/spec")
  mapfile -t exes < <(awk '/^[a-z_]+:/ { key = $1; next } key == "executables:" && /^- / { print $2 }' "$work/spec")
  mapfile -t paths < <(awk '/^[a-z_]+:/ { key = $1; next } key == "require_paths:" && /^- / { print $2 }' "$work/spec")
  ((${#paths[@]} > 0)) || paths=(lib)
  bindir=${bindir:-bin}
  for path in "${paths[@]}"; do
    _ruby_tree_path "$path" && tree_paths+=("$path")
  done
  paths=("${tree_paths[@]}")
  include=(--include '*.rb')
  if _ruby_tree_path "$bindir"; then
    include+=(--include "$bindir/*")
  else
    bindir="" exes=()
  fi
  # Owner names with spaces would shift the size column
  (trap '' XFSZ && ulimit -f 16384 && bsdtar -tvf "$work/data.tar.gz" --numeric-owner "${include[@]}" >"$work/list" 2>"$work/errors")
  if _rb_bsdtar_failed "$work/errors" || (($(stat -c %s "$work/list") >= 16384 * 1024)); then
    printf 'notice\timports: bsdtar cannot list the files of %s, not read\n' "$name"
    return 0
  fi
  read -r count size < <(awk '{ n++ } /^-/ { sum += $5 } END { printf "%d %d\n", n, sum }' "$work/list")
  if ((count > 20000)); then
    printf 'notice\timports: the release holds more than 20000 Ruby files and executables, not read\n'
    return 0
  fi
  if ((size > 20 * 1024 * 1024)); then
    printf 'notice\timports: the release holds more than 20 MB of Ruby files, not read\n'
    return 0
  fi
  mkdir "$work/tree" || return 1
  (trap '' XFSZ && ulimit -f $((20 * 1024)) && bsdtar -xf "$work/data.tar.gz" -C "$work/tree" --no-same-owner "${include[@]}" 2>"$work/errors")
  if _rb_bsdtar_failed "$work/errors"; then
    printf 'notice\timports: bsdtar cannot extract the files of %s, not read\n' "$name"
    return 0
  fi
  # Links of the archive could point at any file of the runner
  find "$work/tree" -type l -delete
  for path in "${paths[@]}"; do
    [[ -d "$work/tree/$path" ]] || continue
    while IFS= read -r -d '' name; do
      name=${name#"$work/tree/"}
      [[ "$name" != *$'\t'* ]] && ! has_control "$name" && files+=("$name")
    done < <(find "$work/tree/$path" -type f -name '*.rb' -print0 | sort -z)
  done
  for name in "${exes[@]}"; do
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ && -f "$work/tree/$bindir/$name" ]] && files+=("$bindir/$name")
  done
  ((${#files[@]} > 0)) || return 0
  helper="${BASH_SOURCE[0]%/*}/rb_requires.rb"
  timeout 60 ruby --disable-gems "$helper" "$work/tree" "${files[@]}" >"$work/requires" 2>/dev/null || rc=$?
  ((rc != 0)) || timeout 60 ruby --disable-gems "$helper" --builtin >"$work/builtin" 2>/dev/null || rc=$?
  case $rc in
    0) ;;
    124)
      printf 'notice\timports: not read within 60 s\n'
      return 0
      ;;
    127)
      printf 'notice\timports: ruby is not installed, not read\n'
      return 0
      ;;
    *)
      printf 'notice\timports: rb_requires.rb exits %s, not read\n' "$rc"
      return 0
      ;;
  esac
  _ruby_imports_classify "$work/tree" "$work/requires" "$work/builtin" "$gem" "$bindir" "${paths[@]}" || return 1
  _ruby_owners "${RB_REQUIRED[@]}" "${RB_OPTIONAL[@]}" >"$work/owners" || return 1
  for pkgname in "${pkgnames[@]}"; do
    pkgname_has_ruby "$srcinfo" "$pkgname" || continue
    _ruby_imports_notes "$file" "$srcinfo" "$pkgname" "${#pkgnames[@]}" "$work/owners" || return 1
  done
}

# Sort the requires of rb_requires.rb output $2 for gem $4 extracted in $1, with the builtin features of
# $3, bindir $5 and the require paths after it: RB_ERRORS, RB_REQUIRED and RB_OPTIONAL of other gems
_ruby_imports_classify() {
  local LC_ALL=C tree=$1 gem=$4 bindir=$5 kind path type req scope rp own line
  local -a rps=("${@:6}") queue=()
  local -A reached=() reqs=() required=() optional=() builtin=()
  RB_ERRORS=() RB_REQUIRED=() RB_OPTIONAL=()
  while IFS= read -r line; do
    [[ -z "$line" ]] || builtin[$line]=1
  done <"$3"
  for rp in "${rps[@]}"; do
    for path in "$rp/$gem.rb" "$rp/${gem//-//}.rb"; do
      [[ ! -f "$tree/$path" ]] || queue+=("$path")
    done
  done
  while IFS=$'\t' read -r kind path type req scope; do
    case $kind in
      error) RB_ERRORS+=("$path: $type") ;;
      require)
        # Other strings name no feature, and the lookups of owners and ruby.map take their text
        if [[ "$type" == relative || "$req" =~ ^[A-Za-z0-9_][A-Za-z0-9_/-]*(\.[A-Za-z0-9_-]+)*$ ]]; then
          reqs[$path]+="$scope"$'\t'"$type"$'\t'"$req"$'\n'
        fi
        ;;
    esac
    [[ "$path" != "$bindir"/* ]] || queue+=("$path")
  done <"$2"
  while ((${#queue[@]} > 0)); do
    path=${queue[0]}
    queue=("${queue[@]:1}")
    [[ -z "${reached[$path]:-}" ]] || continue
    reached[$path]=1
    while IFS=$'\t' read -r scope type req; do
      [[ "$scope" == module && -n "$req" ]] || continue
      own=$(_ruby_own_file "$tree" "$type" "$req" "${rps[@]}")
      [[ -z "$own" || -n "${reached[$own]:-}" ]] || queue+=("$own")
    done <<<"${reqs[$path]:-}"
  done
  for path in "${!reqs[@]}"; do
    while IFS=$'\t' read -r scope type req; do
      [[ -n "$req" && "$type" != relative ]] || continue
      [[ -z "$(_ruby_own_file "$tree" "$type" "$req" "${rps[@]}")" && -z "${builtin[${req%.rb}]:-}" ]] || continue
      if [[ -n "${reached[$path]:-}" && "$scope" == module ]]; then
        required[${req%.rb}]=1
      else
        optional[${req%.rb}]=1
      fi
    done <<<"${reqs[$path]}"
  done
  RB_REQUIRED=("${!required[@]}")
  for req in "${!optional[@]}"; do
    [[ -n "${required[$req]:-}" ]] || RB_OPTIONAL+=("$req")
  done
}

# Print the file of the gem in tree $1 that a require of kind $2 and path $3 loads, the require paths
# after them; nothing for a file of another gem
_ruby_own_file() {
  local rp
  if [[ "$2" == relative ]]; then
    [[ ! -f "$1/$3" ]] || printf '%s\n' "$3"
    return 0
  fi
  for rp in "${@:4}"; do
    if [[ -f "$1/$rp/${3%.rb}.rb" ]]; then
      printf '%s\n' "$rp/${3%.rb}.rb"
      return 0
    fi
  done
}

# Print require path<TAB>pkgname for each require path $@ that a file of the files database holds: a
# file of ruby, also below x86_64-linux, or the lib/ of an installed gem, as .rb or .so
_ruby_owners() {
  local LC_ALL=C req alternation=""
  for req in "$@"; do
    [[ "$req" =~ ^[A-Za-z0-9_][A-Za-z0-9_/-]*(\.[A-Za-z0-9_-]+)*$ ]] && alternation+="${alternation:+|}${req//./\\.}"
  done
  [[ -n "$alternation" ]] || return 0
  files_index_owner "^usr/lib/ruby/(3\\.[0-9]+\\.0/(x86_64-linux/)?|gems/[^/]+/gems/[^/]+/lib/)($alternation)\\.(rb|so)\$" |
    awk -F'\t' '{ p = $2; sub(/\.(rb|so)$/, "", p)
      sub(/^usr\/lib\/ruby\/(3\.[0-9]+\.0\/(x86_64-linux\/)?|gems\/[^\/]+\/gems\/[^\/]+\/lib\/)/, "", p); print p "\t" $1 }' | sort -u
}

# Print the notes of pkgname $3 of .SRCINFO $2 of package file $1, with RB_REQUIRED, RB_OPTIONAL and
# RB_ERRORS of the release and the owners of file $5; $4 is the number of pkgnames, more than one names it
_ruby_imports_notes() {
  local LC_ALL=C file=$1 srcinfo=$2 prefix="" req dep owner met entry first
  local -A in_depends=() in_opt=() noted=()
  local -a owners all=("${RB_REQUIRED[@]}" "${RB_OPTIONAL[@]}")
  (($4 < 2)) || prefix="$3: "
  while IFS= read -r dep; do
    in_depends[$dep]=1
    ! arch_package "$dep" 2>/dev/null || in_depends[$PKG_NAME]=1
  done < <(srcinfo_depends "$srcinfo" "$3" depends)
  while IFS= read -r dep; do
    in_opt[$dep]=1
    ! arch_package "$dep" 2>/dev/null || in_opt[$PKG_NAME]=1
  done < <(srcinfo_depends "$srcinfo" "$3" optdepends)
  while IFS= read -r dep; do
    in_depends[$dep]=1
  done < <(srcinfo_pkgnames "$srcinfo")
  in_depends[ruby]=1
  for entry in "${RB_ERRORS[@]}"; do
    printf 'notice\t%simports: %s does not parse: %s\n' "$prefix" "${entry%%: *}" "${entry#*: }"
  done
  for req in "${all[@]}"; do
    [[ -z "${noted[$req]:-}" ]] || continue
    noted[$req]=1
    mapfile -t owners < <(awk -F'\t' -v r="$req" '$1 == r { print $2 }' "$5")
    if ((${#owners[@]} == 0)); then
      first=${req%%/*}
      for dep in "${!in_depends[@]}" "${!in_opt[@]}"; do
        [[ "$dep" != "ruby-${first,,}" && "$dep" != "ruby-${first//_/-}" ]] || owners=("$dep")
      done
      if ((${#owners[@]} == 0)); then
        owner=$(ruby_map "$file" "$first")
        [[ -z "$owner" ]] || owners=("$owner")
      fi
    fi
    if ((${#owners[@]} == 0)); then
      _ruby_is_required "$req" && printf 'notice\t%srequire %s: no package owns it\n' "$prefix" "$req"
      continue
    fi
    met=""
    for owner in "${owners[@]}"; do
      [[ -z "${in_depends[$owner]:-}" ]] || met=1
    done
    [[ -z "$met" ]] || continue
    if _ruby_is_required "$req"; then
      printf 'notice\t%srequire %s: %s not in depends\n' "$prefix" "$req" "$(_python_join "${owners[@]}")"
      continue
    fi
    for owner in "${owners[@]}"; do
      [[ -z "${in_opt[$owner]:-}" ]] || met=1
    done
    [[ -n "$met" ]] ||
      printf 'notice\t%srequire %s (optional): %s in neither depends nor optdepends\n' "$prefix" "$req" "$(_python_join "${owners[@]}")"
  done
}

# Succeed when require path $1 is one of RB_REQUIRED
_ruby_is_required() {
  local req
  for req in "${RB_REQUIRED[@]}"; do
    [[ "$req" != "$1" ]] || return 0
  done
  return 1
}
