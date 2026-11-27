#!/usr/bin/env bats

load helpers/setup.sh

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

# === Valid configs ===

@test "validate: github-release minimal config passes" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: github-tag with tag_version_regex passes" {
  create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
  tag_version_regex: '^v(1\\.[0-9.]+)$'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: gitlab-tag passes" {
  create_test_package "mypkg" "gitlab-tag" "upstream:
  host: gitlab.com
  project: group/project"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: gitea-tag passes" {
  create_test_package "mypkg" "gitea-tag" "upstream:
  host: codeberg.org
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: git-latest github type passes" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: git-latest gitlab type passes" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: gitlab
  host: invent.kde.org
  project: group/project"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: git-latest git type passes" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: git
  url: https://git.example.com/repo.git"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: git-latest passes with a current of the form r<count>.<hash>" {
  local current
  for current in r504.42cd4ac r2173.ef2e985d; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
current: '$current'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ]
  done
}

# vercmp reads 1.4.0.r47.g0bbf5ad, 1.2.3 and 0 as newer than every r<count>.<hash>, and
# r1234.g42cd4ac as older than r1234.42cd4ac of the same commit
@test "validate: git-latest fails on a current of another form" {
  local current
  for current in 1.4.0.r47.g0bbf5ad 1.2.3 r1234.g42cd4ac 0; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
current: '$current'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"current must be r<count>.<hash> for git-latest, the form the strategy prints: $current"* ]]
  done
}

@test "validate: fails on a current that is no version" {
  local current
  for current in '1.0$(touch x)' 1.0-1 'v 1' abc "$(printf 'a%.0s' {1..64})1"; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
current: '$current'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"current must hold a digit and at most 64 characters of A-Za-z0-9 . _ +: ${current@Q}"* ]]
  done
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
current: ''"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: git-latest branch passes" {
  local branch
  for branch in feature/x release-0.11; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
  branch: '$branch'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ]
  done
}

# git clone would read -x as an option
@test "validate: git-latest branch git refuses rejected" {
  local branch
  for branch in -x 'a b' a..b HEAD; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
  branch: '$branch'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream.branch is not a valid branch name: $branch"* ]]
  done
}

@test "validate: git-latest describe passes" {
  local describe
  for describe in tags annotated; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
  describe: $describe
  tag_prefix: release/
current: '1.2.0.rc1.r47.g0bbf5ad'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ]
  done
}

@test "validate: git-latest describe of another value rejected" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
  describe: 'yes'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.describe must be tags or annotated: yes"* ]]
}

@test "validate: describe for another strategy rejected" {
  create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
  describe: tags"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.describe applies to the git-latest strategy only"* ]]
}

@test "validate: git-latest tag_prefix without describe rejected" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
  tag_prefix: v"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.tag_prefix applies with upstream.describe only"* ]]
}

@test "validate: git-latest tag_prefix outside the characters of a tag rejected" {
  local prefix
  for prefix in 'a b' 'v*' ''; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
  describe: tags
  tag_prefix: '$prefix'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream.tag_prefix may hold A-Za-z0-9._+/- only: $prefix"* ]]
  done
}

# vercmp reads r504.42cd4ac as older than every 1.2.0.r47.g0bbf5ad
@test "validate: git-latest describe fails on a current of another form" {
  local current
  for current in r504.42cd4ac 1.2.0 1.2.0.r47.0bbf5ad; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
  describe: tags
current: '$current'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"current must be <tag>.r<count>.g<hash> for git-latest with upstream.describe, the form the strategy prints: $current"* ]]
  done
}

@test "validate: branch for another strategy rejected" {
  create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
  branch: main"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.branch applies to the git-latest strategy only"* ]]
}

@test "validate: upstream.host is a host name with a port or none" {
  local host
  for host in 'api.github.com@127.0.0.1:9' 'codeberg.org/x' 'a b' 'host:' 'host:123456'; do
    create_test_package "mypkg" "gitea-tag" "upstream:
  host: '$host'
  project: owner/repo"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"upstream.host must be a host name, with a port or none: '$host'"* ]] || {
      echo "taken: $host"
      return 1
    }
  done
  create_test_package "mypkg" "gitlab-tag" "upstream:
  host: git.example.com:8443
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

# Strategies put these fields into URL paths, where curl reads {} and [] as globs
@test "validate: upstream.project, registry, tag, nightly_tag, repology and archpkg take no glob, query or dot segment" {
  local entry strategy field value fields
  for entry in 'github-release|project|lab/demo{1,2}' 'github-release|project|lab/demo[1-2]' \
    'github-release|project|lab/../other' 'gitea-tag|project|./x' 'github-release|project|o/r?x=1' \
    'github-release|project|o/r#x' 'pypi|registry|pkg{a,b}' 'npm|registry|a/b/c' 'crates|registry|x[1]' \
    'github-asset|tag|v[1-9]' 'github-asset|tag|a b' 'github-asset|tag|v1..2' 'github-asset|tag|x@{1}' \
    'github-nightly|nightly_tag|n?x' 'repology|repology|firefox/../../robots.txt?x=[1-3]#' \
    'repology|repology|a b' 'archpkg|archpkg|linux&repo=Testing&q=../x y' 'archpkg|archpkg|-x' \
    'archpkg|archpkg|.x' 'repology|repology|:x' 'pypi|registry|..' 'crates|registry|.' 'npm|registry|@scope/..' \
    'npm|registry|@../pkg' 'npm|registry|@./pkg'; do
    IFS='|' read -r strategy field value <<<"$entry"
    case "$strategy" in
      gitea-tag) fields="  host: codeberg.org" ;;
      github-asset) fields=$'  project: owner/repo\n  assets:\n    - x.tar.gz' ;;
      github-nightly) fields="  project: owner/repo" ;;
      *) fields="" ;;
    esac
    create_test_package "mypkg" "$strategy" "upstream:
  $field: '$value'${fields:+$'\n'$fields}"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"upstream.$field must be "*": '$value'"* ]] || {
      echo "taken: $entry"
      echo "$output"
      return 1
    }
  done
}

@test "validate: upstream.project, registry, tag, repology and archpkg of real names pass" {
  local entry strategy field value fields
  for entry in 'github-release|project|owner/.github' 'gitlab-tag|project|group/sub/project_x-1.2' \
    'npm|registry|@scope/pkg.js' 'pypi|registry|zope.interface' 'github-asset|tag|release/1.2+b{1}' \
    'github-asset|tag|models#2026%1' 'repology|repology|ruby:rmagick' 'repology|repology|c++' \
    'archpkg|archpkg|qt6-base' 'archpkg|archpkg|libc++' 'archpkg|archpkg|python-zope.interface' \
    'kde-tarball|project|kdevelop-c++' 'kde-tarball|project|kde@x'; do
    IFS='|' read -r strategy field value <<<"$entry"
    case "$strategy" in
      gitlab-tag) fields="  host: gitlab.com" ;;
      github-asset) fields=$'  project: owner/repo\n  assets:\n    - x.tar.gz' ;;
      *) fields="" ;;
    esac
    create_test_package "mypkg" "$strategy" "upstream:
  $field: '$value'${fields:+$'\n'$fields}"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ] || {
      echo "refused: $entry"
      echo "$output"
      return 1
    }
  done
}

@test "validate: git-latest gitlab type checks upstream.host as a host name" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: gitlab
  host: gitlab.com@127.0.0.1
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.host must be a host name, with a port or none: 'gitlab.com@127.0.0.1'"* ]]
}

# Under en_US.UTF-8 a bracket range of bash takes the letters that sort between its ends
@test "validate: refuses a host outside ASCII under any locale" {
  locale -a | grep -qix 'en_US.utf8' || locale_needed "no en_US.UTF-8 locale"
  create_test_package "mypkg" "gitlab-tag" "upstream:
  host: gıtlab.com
  project: owner/repo"
  LC_ALL=en_US.UTF-8 run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a key or a value outside alerts[].note holds a character other than printable ASCII and tab"* ]]
}

@test "validate: no value holds a control character" {
  local value
  # YAML reads \x80 and \x9f as U+0080 and U+009F, the ends of the C1 controls
  for value in '"https://example.invalid/x\e]0;PWNED\ay"' '"main\rx"' '"https://example.invalid/\u009b2J"' \
    '"https://example.invalid/\x80x"' '"https://example.invalid/\x9fx"'; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: git
  url: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"packages/mypkg.yml: a key or a value holds a control character"* ]] || {
      echo "taken: $value"
      return 1
    }
    [[ "$output" != *$'\e'* && "$output" != *$'\r'* && "$output" != *$'\u009b'* ]]
  done
  create_test_package "mypkg" "git-latest" "upstream:
  type: git
  url: https://example.invalid/x
  branch: \"m\\e]0;PWNED\\an\""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a key or a value holds a control character"* && "$output" != *$'\e'* ]]
}

# yq -r prints the text of a key and of a scalar with any tag
@test "validate: no key and no tagged value holds a control character" {
  local yaml
  for yaml in 'name: !x "mypkg\e[31m"|strategy: github-tag|upstream:|  project: owner/repo' \
    'name: mypkg|strategy: github-tag|"key\e[31m": 1|upstream:|  project: owner/repo' \
    'name: mypkg|strategy: github-tag|upstream:|  project: owner/repo|  tag_version_regex: !x "^v(.*)\e]0;T\a$"' \
    'name: mypkg|strategy: github-tag|cooldown_days: !!int "1\e[31m"|upstream:|  project: owner/repo'; do
    tr '|' '\n' <<<"$yaml" >"$TEST_TMPDIR/packages/mypkg.yml"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"packages/mypkg.yml: a key or a value holds a control character"* ]] || {
      echo "taken: $yaml"
      return 1
    }
    [[ "$output" != *$'\e'* && "$output" != *$'\a'* ]]
  done
}

# yq ends a line at these characters and a diff does not, so a key can hide in what a
# review reads as a comment, and yq reads the last of two equal keys
@test "validate: refuses a line break that a diff does not show and a key twice in one mapping" {
  local sep
  for sep in $'\r' $'\xc2\x85' $'\xe2\x80\xa8' $'\xe2\x80\xa9'; do
    printf 'name: mypkg\nstrategy: github-tag\nupstream:\n  project: owner/repo # upstream%s  project: example/evil\n' "$sep" \
      >"$TEST_TMPDIR/packages/mypkg.yml"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"packages/mypkg.yml holds a carriage return inside a line, a NEL, a U+2028 or a U+2029, which yq reads as a line break"* ]] || {
      echo "taken: ${sep@Q}"
      return 1
    }
  done

  printf 'name: mypkg\nstrategy: github-tag\nupstream:\n  project: owner/repo\n  project: example/evil\n' >"$TEST_TMPDIR/packages/mypkg.yml"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/mypkg.yml holds a key twice in one mapping"* ]]

  # Files with CRLF line ends stay valid
  printf 'name: mypkg\r\nstrategy: github-tag\r\nupstream:\r\n  project: owner/repo\r\n' >"$TEST_TMPDIR/packages/mypkg.yml"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

# Diffs show no zero-width or bidi character, and holds whose match hides one never fire
@test "validate: a key or a value outside alerts[].note is printable ASCII or a tab" {
  local entry
  # U+200B in a match, U+202E and U+00E9 in a project, as UTF-8 bytes
  for entry in $'.alerts[0].match|^2\xe2\x80\x8b\\.' $'.upstream.project|p\xe2\x80\xaeq/repo' $'.upstream.project|caf\xc3\xa9/repo'; do
    create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
alerts:
  - hold: true
    match: '^3'"
    V="${entry#*|}" yq -i "${entry%%|*} = strenv(V)" "$TEST_TMPDIR/packages/mypkg.yml"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"packages/mypkg.yml: a key or a value outside alerts[].note holds a character other than printable ASCII and tab"* ]] || {
      echo "taken: ${entry@Q}"
      return 1
    }
  done
}

@test "validate: alerts[].note holds no format character and no space but U+0020" {
  local note
  for note in '"a\u200bb"' '"a\u202eb"' '"a\u00a0b"' '"a\u3000b"' '"a\u2028b"'; do
    create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
alerts:
  - hold: true
    match: '^3'
    note: $note"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"packages/mypkg.yml: alerts[].note holds a format character, a blank letter or mark, or a space other than U+0020"* ]] || {
      echo "taken: $note"
      return 1
    }
  done
  create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
alerts:
  - hold: true
    match: '^3'
    note: 'Qt 7 needs a rebuild of café'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

# Hangul fillers and the blank Braille pattern are letters and symbols that show nothing, and a
# combining mark after a space or at the start stands alone; YAML reads each escape of esc
@test "validate: alerts[].note holds no blank letter, symbol or mark" {
  local note
  esc() { printf '\\%s%s' "$1" "$2"; }
  for note in "a$(esc u 2029)b" "$(esc u 3164)" "a$(esc u 115f)b" "a$(esc u 1160)b" "a$(esc u ffa0)b" "a$(esc u 2800)b" \
    "a$(esc U 0001d159)b" "a$(esc u 034f)b" "a$(esc u fe0e)b" "a$(esc u fe0f)b" "a $(esc u 0301)b" "$(esc u 0301)b"; do
    create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
alerts:
  - hold: true
    match: '^3'
    note: \"$note\""
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"packages/mypkg.yml: alerts[].note holds a format character, a blank letter or mark, or a space other than U+0020"* ]] || {
      echo "taken: $note"
      return 1
    }
  done
  # Combining marks after letters, and the emoji form after symbols, stay
  for note in "cafe$(esc u 0301) au lait" "$(esc u 26a0)$(esc u fe0f) Qt 7"; do
    create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
alerts:
  - hold: true
    match: '^3'
    note: \"$note\""
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ] || {
      echo "refused: $note"
      return 1
    }
  done
}

# curl reads these as hosts that url_host cannot name, so the host memory cannot hold them
@test "validate: upstream.url names its host in ASCII letters, digits, dots and dashes" {
  local url strategy extra
  for strategy in git-tag git-latest webpage-scrape; do
    extra=""
    [[ "$strategy" != git-latest ]] || extra=$'\n  type: git'
    [[ "$strategy" != webpage-scrape ]] || extra=$'\n  pattern: v([0-9.]+)'
    for url in 'https:///example.com/x' 'https://api.git%68ub.com/x' 'https://git.example.com\/x' \
      'https://git_x.example.com/x' 'https://git example.com/x'; do
      create_test_package "mypkg" "$strategy" "upstream:$extra
  url: '$url'"
      run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
      [ "$status" -eq 1 ] && [[ "$output" == *"upstream.url must name its host after https:// in ASCII letters, digits, dots and dashes, with a port at most"* ]] || {
        echo "taken: $strategy $url"
        return 1
      }
    done
    for url in https://git.example.com:8443/repo.git https://git.example.com https://git.example.com?x; do
      create_test_package "mypkg" "$strategy" "upstream:$extra
  url: '$url'"
      run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
      [ "$status" -eq 0 ] || {
        echo "refused: $strategy $url"
        echo "$output"
        return 1
      }
    done
  done
}

# bash compiles a pattern again for each line it reads, and nested counted repeats
# multiply the size of a pattern
@test "validate: refuses a regex past 256 characters, 64 repeats or 128 parts" {
  local entry field regex expected
  local -a cases=(
    'pattern;v([0-9]{,65});repeats a part more than 64 times'
    'pattern;((a{1,80}){1,80}){1,80};repeats a part more than 64 times'
    'pattern;v([0-9]{1,65});repeats a part more than 64 times'
    "pattern;v([0-9]+)$(printf 'x%.0s' {1..250});holds more than 256 characters"
    'pattern;v(x{63}x{63}y);holds more than 128 parts'
    'pattern;(((a{1,32}){1,32}){1,32}){1,32};holds more than 128 parts'
    'pattern;v((((a{4}){4}){4}){4});holds more than 128 parts'
    'pattern;v((a{1,64}){1,64}){0}(x);holds more than 128 parts'
    'match;((a{1,80}){1,80}){1,80};repeats a part more than 64 times'
    'match;(a|b){32}x;holds more than 128 parts'
  )
  for entry in "${cases[@]}"; do
    IFS=';' read -r field regex expected <<<"$entry"
    if [[ "$field" == pattern ]]; then
      create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/download
  pattern: '$regex'"
    else
      create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
alerts:
  - hold: true
    match: '$regex'"
    fi
    SECONDS=0
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"$expected"* ]] && ((SECONDS < 5)) || {
      echo "taken: $entry in $SECONDS s"
      echo "$output"
      return 1
    }
  done
  for regex in 'v(x{63}x{63})' 'v([{999}])' 'v(\{999\})'; do
    create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/download
  pattern: '$regex'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ] || {
      echo "refused: $regex"
      echo "$output"
      return 1
    }
  done
}

@test "validate: refuses a loop after a group or a repeat and an anchor inside a regex" {
  local entry regex expected
  local -a cases=(
    'v((a?)*);puts *, + or {n,} after a group or a repeat'
    'v((x|y)+);puts *, + or {n,} after a group or a repeat'
    'v(a?{2,});puts *, + or {n,} after a group or a repeat'
    'v(\b[0-9]+);has an anchor other than ^ at its start or $ at its end'
    'v([0-9]+)^;has an anchor other than ^ at its start or $ at its end'
    'v(x$)y;has an anchor other than ^ at its start or $ at its end'
  )
  for entry in "${cases[@]}"; do
    IFS=';' read -r regex expected <<<"$entry"
    create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/download
  pattern: '$regex'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"$expected"* ]] || {
      echo "taken: $entry"
      echo "$output"
      return 1
    }
  done
  for regex in '^v([0-9.]+(-rc[0-9]+)?)$' '^([0-9a-f]{7,40})-(.*)$' 'v([\^$]+)' 'v(\^\$)' 'v([0-9]{2,}x*)'; do
    create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/download
  pattern: '$regex'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ] || {
      echo "refused: $regex"
      echo "$output"
      return 1
    }
  done
}

# Each anchor of glibc other than ^ and $, counts with leading zeros, repeats after bracket
# expressions, and the length limit at its edge
@test "validate: refuses each escape anchor, counts read in octal and long bracket repeats" {
  local entry regex expected long
  long=$(printf 'a%.0s' {1..250})
  local -a cases=(
    'v(\B[0-9]+);has an anchor other than ^ at its start or $ at its end'
    'v(\<[0-9]+);has an anchor other than ^ at its start or $ at its end'
    'v(\>[0-9]+);has an anchor other than ^ at its start or $ at its end'
    'v(\`[0-9]+);has an anchor other than ^ at its start or $ at its end'
    "v(\\''[0-9]+);has an anchor other than ^ at its start or \$ at its end"
    'v(a{077});repeats a part more than 64 times'
    'v([[:alpha:]]{100});repeats a part more than 64 times'
    'v([]a]{100});repeats a part more than 64 times'
    "v([${long}a]x);holds more than 256 characters"
  )
  for entry in "${cases[@]}"; do
    IFS=';' read -r regex expected <<<"$entry"
    create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/download
  pattern: '$regex'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"$expected"* ]] || {
      echo "taken: $entry"
      echo "$output"
      return 1
    }
  done
  # Bracket expressions end at neither a ] first in them nor the ] of a class
  for regex in 'v(a{064})' "v([${long}]x)" 'v([]{999}])' 'v([[:alpha:]{999}])'; do
    create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/download
  pattern: '$regex'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ] || {
      echo "refused: $regex"
      echo "$output"
      return 1
    }
  done
  create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  version_source: release_body
  version_pattern: 'v\K[0-9]+$(printf 'x%.0s' {1..250})'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"holds more than 256 characters"* ]]
}

# glibc matches a back reference by trying each split of the subject among the groups
@test "validate: refuses a back reference in a regex" {
  local field yaml
  for field in tag_version_regex asset_regex pattern match; do
    case "$field" in
      tag_version_regex) yaml=$'upstream:\n  project: owner/repo\n  tag_version_regex: \'^v([0-9]*)\\1$\'' ;;
      asset_regex) yaml=$'upstream:\n  project: owner/repo\n  asset_regex: \'^a-([0-9]*)\\1\\.deb$\'\n  asset_var: _deb' ;;
      pattern) yaml=$'upstream:\n  url: https://example.com/download\n  pattern: \'v([0-9]*)\\1x\'' ;;
      match) yaml=$'upstream:\n  project: owner/repo\nalerts:\n  - hold: true\n    match: \'(0*)\\1x\'' ;;
    esac
    if [[ "$field" == pattern ]]; then
      create_test_package "mypkg" "webpage-scrape" "$yaml"
    else
      create_test_package "mypkg" "github-tag" "$yaml"
    fi
    SECONDS=0
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *'The regex has a back reference, \1'* ]] && ((SECONDS < 5)) || {
      echo "taken: $field in $SECONDS s"
      echo "$output"
      return 1
    }
  done
}

@test "validate: refuses a PCRE version_pattern past 64 repeats" {
  local regex
  for regex in 'v\K[0-9]{,65}' '((a{1,80}){1,80}){1,80}'; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  version_source: release_body
  version_pattern: '$regex'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"repeats a part more than 64 times"* ]] || {
      echo "taken: $regex"
      echo "$output"
      return 1
    }
  done
}

@test "validate: upstream.url holds no user name" {
  local strategy extra
  for strategy in git-tag git-latest webpage-scrape; do
    extra=""
    [[ "$strategy" != git-latest ]] || extra=$'\n  type: git'
    [[ "$strategy" != webpage-scrape ]] || extra=$'\n  pattern: v([0-9.]+)'
    create_test_package "mypkg" "$strategy" "upstream:$extra
  url: https://api.github.com@127.0.0.1/repo"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"upstream.url must hold no user name: 'https://api.github.com@127.0.0.1/repo'"* ]] || {
      echo "taken by $strategy: $output"
      return 1
    }
  done
}

@test "validate: git-latest git type fails on a URL without HTTPS" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: git
  url: file:///srv/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.url must use HTTPS: file:///srv/repo"* ]]
}

@test "validate: git-latest git type fails on an HTTP URL" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: git
  url: http://git.example.com/repo.git"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.url must use HTTPS: http://git.example.com/repo.git"* ]]
}

@test "validate: pypi passes" {
  create_test_package "mypkg" "pypi" "upstream:
  registry: requests"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: npm passes" {
  create_test_package "mypkg" "npm" "upstream:
  registry: express"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: crates passes" {
  create_test_package "mypkg" "crates" "upstream:
  registry: serde"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: archpkg passes (no extra fields)" {
  create_test_package "mypkg" "archpkg" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
  [ "$output" = "✓ mypkg: valid" ]
}

@test "validate: archpkg with testing passes" {
  local value
  for value in true false; do
    create_test_package "mypkg" "archpkg" "upstream:
  testing: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ]
  done
}

@test "validate: testing for another strategy rejected" {
  create_test_package "mypkg" "repology" "upstream:
  testing: true"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.testing applies to the archpkg strategy only"* ]]
}

@test "validate: testing that is not a boolean rejected" {
  local value
  for value in yes '"true"' 1 '!!bool yes'; do
    create_test_package "mypkg" "archpkg" "upstream:
  testing: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream.testing must be true or false"* ]]
  done
}

@test "validate: repology passes (no extra fields)" {
  create_test_package "mypkg" "repology" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: kde-tarball passes (no extra fields)" {
  create_test_package "mypkg" "kde-tarball" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: kde-tarball project and path pass" {
  create_test_package "mypkg" "kde-tarball" "upstream:
  project: alkimia
  path: unstable/alkimia"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: kde-tarball project outside the characters of a name rejected" {
  local project
  for project in 'a/b' 'a b' '-a' "a'b"; do
    create_test_package "mypkg" "kde-tarball" "upstream:
  project: \"$project\""
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream.project must be a tarball name of A-Za-z0-9@._+-: $project"* ]]
  done
}

# The path ends up in https://download.kde.org/<path>/
@test "validate: kde-tarball path that is not a directory on the server rejected" {
  local path
  for path in ../etc stable/../x /stable/x stable//x 'stable/x?y' stable/x/ 'stable/a b'; do
    create_test_package "mypkg" "kde-tarball" "upstream:
  path: '$path'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream.path must be a directory on download.kde.org, such as unstable/alkimia: $path"* ]]
  done
}

@test "validate: webpage-scrape passes" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'pkg-([0-9.]+)\\.tar\\.gz'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: github-asset passes" {
  create_test_package "mypkg" "github-asset" "upstream:
  project: owner/repo
  tag: models
  assets:
    - voice-a.tar.bz2"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

# === Missing core fields ===

@test "validate: fails on missing name" {
  cat >"$TEST_TMPDIR/packages/bad.yml" <<'EOF'
strategy: github-release
upstream:
  project: owner/repo
EOF
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required field 'name'"* ]]
}

# check-all.sh finds a package by its name, so a file under another name
# is never checked
@test "validate: fails on a name other than the file name" {
  create_test_package a github-release "upstream:
  project: owner/repo"
  sed -i 's/^name: a$/name: b/' "$TEST_TMPDIR/packages/a.yml"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" a
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/a.yml: name 'b' must equal the file name 'a'"* ]]
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/a.yml: name 'b' must equal the file name 'a'"* ]]
}

# The runs check such a package and then drop its status; the AUR allows no such name
@test "validate: fails on a name outside the characters of an AUR package name" {
  local name shown file
  # Names beyond ASCII meet the check of every value first
  printf "name: 'fée'\nstrategy: github-release\nupstream:\n  project: owner/repo\n" >"$TEST_TMPDIR/packages/fée.yml"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/\$'f\\303\\251e.yml': a key or a value outside alerts[].note holds a character other than printable ASCII and tab"* ]]
  for name in "space name" -dash 'quo"te' _assets @demo +demo Demo de@mo; do
    rm -f "$TEST_TMPDIR"/packages/*.yml
    printf 'name: %s\nstrategy: github-release\nupstream:\n  project: owner/repo\n' "'$name'" >"$TEST_TMPDIR/packages/$name.yml"
    # validate-pkg.sh quotes the name and the file name in the C locale
    shown=$(
      LC_ALL=C
      printf '%s' "${name@Q}"
    )
    file=$(
      LC_ALL=C
      file="$name.yml"
      printf '%s' "${file@Q}"
    )
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"packages/$file: name $shown must start with a-z or 0-9 and hold only a-z, 0-9 and . _ + -"* ]] || {
      echo "taken: $name"
      return 1
    }
  done
}

# The AUR takes repository names of a-z, 0-9 and . _ + -, which start with a-z or 0-9
@test "validate: takes the names that the AUR takes, and refuses one that starts with ." {
  local name
  for name in 0ad g++ lib32-foo_bar.baz; do
    rm -f "$TEST_TMPDIR"/packages/*.yml
    printf 'name: %s\nstrategy: github-release\nupstream:\n  project: owner/repo\n' "'$name'" >"$TEST_TMPDIR/packages/$name.yml"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
    [ "$status" -eq 0 ] || {
      echo "refused: $name"
      echo "$output"
      return 1
    }
  done
  printf 'name: .demo\nstrategy: github-release\nupstream:\n  project: owner/repo\n' >"$TEST_TMPDIR/packages/.demo.yml"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" .demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"name '.demo' must start with a-z or 0-9 and hold only a-z, 0-9 and . _ + -"* ]]
}

# The runs read packages/<name>.yml alone
@test "validate --all: fails on a file of packages/ that no run reads" {
  local file
  create_test_package a github-release "upstream:
  project: owner/repo"
  for file in x.yaml .x.yml notes.txt xyml; do
    : >"$TEST_TMPDIR/packages/$file"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"packages/$file: no run reads it, as the runs read the regular files packages/<name>.yml alone"* ]] || {
      echo "taken: $file"
      return 1
    }
    rm "$TEST_TMPDIR/packages/$file"
  done
  # Terminals take control characters in file names as commands
  : >"$TEST_TMPDIR/packages/bad"$'\e'"name"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/\$'bad\\Ename': no run reads it"* && "$output" != *$'\e'* ]]
  rm "$TEST_TMPDIR/packages/bad"$'\e'"name"
  : >"$TEST_TMPDIR/packages/.gitkeep"
  cp "$PROJECT_DIR/packages/example.yml.sample" "$TEST_TMPDIR/packages/"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 0 ]
  # Files no run reads fail beside no package at all
  mv "$TEST_TMPDIR/packages/a.yml" "$TEST_TMPDIR/packages/a.yaml"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 1 ]
}

# Pull requests can name a file with a line break and a workflow command
@test "validate --all: quotes a file name outside the pattern of package names" {
  local name=$'x\n::notice title=forged::text.yml'
  printf 'name: [x\n' >"$TEST_TMPDIR/packages/$name"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid YAML syntax: packages/\$'x\\n::notice title=forged::text.yml'"* ]]
  [[ "$output" != *$'\n::notice'* ]]
  printf 'name: x\nstrategy: github-release\nupstream:\n  project: owner/repo\n' >"$TEST_TMPDIR/packages/$name"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/\$'x\\n::notice title=forged::text.yml': name 'x' must equal the file name \$'x\\n::notice title=forged::text'"* ]]
  [[ "$output" != *$'\n::notice'* ]]
}

# The runs read regular files alone, and the write-back of current takes no link
@test "validate --all: fails on a directory, a link or a FIFO named like a package" {
  local entry
  create_test_package a github-release "upstream:
  project: owner/repo"
  cp "$TEST_TMPDIR/packages/a.yml" "$TEST_TMPDIR/outside.yml"
  for entry in dir link fifo dirlink; do
    case "$entry" in
      dir) mkdir "$TEST_TMPDIR/packages/foo.yml" ;;
      link) ln -s "$TEST_TMPDIR/outside.yml" "$TEST_TMPDIR/packages/foo.yml" ;;
      fifo) mkfifo "$TEST_TMPDIR/packages/foo.yml" ;;
      dirlink) ln -s "$TEST_TMPDIR" "$TEST_TMPDIR/packages/foo.yml" ;;
    esac
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
    [ "$status" -eq 1 ] &&
      [[ "$output" == *"packages/foo.yml: no run reads it, as the runs read the regular files packages/<name>.yml alone"* ]] || {
      echo "taken: $entry"
      echo "$output"
      return 1
    }
    if [[ -L "$TEST_TMPDIR/packages/foo.yml" || ! -d "$TEST_TMPDIR/packages/foo.yml" ]]; then
      rm "$TEST_TMPDIR/packages/foo.yml"
    else
      rmdir "$TEST_TMPDIR/packages/foo.yml"
    fi
  done
}

@test "validate: fails on missing strategy" {
  cat >"$TEST_TMPDIR/packages/bad.yml" <<'EOF'
name: bad
upstream:
  project: owner/repo
EOF
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required field 'strategy'"* ]]
}

@test "validate: fails on unknown strategy" {
  create_test_package "mypkg" "nonexistent-strat" "upstream:
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown strategy"* ]]
}

@test "validate: accepts a strategy that has a script in strategies/" {
  printf '#!/usr/bin/env bash\necho 1.0.0\n' >"$TEST_TMPDIR/strategies/forgejo-release.sh"
  chmod +x "$TEST_TMPDIR/strategies/forgejo-release.sh"
  create_test_package "mypkg" "forgejo-release" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: fails on a strategy path outside strategies/" {
  create_test_package "mypkg" "../scripts/check-all" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown strategy '../scripts/check-all'"* ]]
}

# === Unknown keys ===

@test "validate: names every unknown top-level key in one error" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
allow_downgrades: true
pkgver_dashes: _"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/mypkg.yml: unknown key: allow_downgrades, pkgver_dashes"* ]]
}

# The data directory is the same for every file of a run, and in CI it is a
# path of the runner
@test "validate: names a file by packages/<name>.yml" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
tpyo: x
alerts:
  - when: minor
    note: New major"
  for args in mypkg --all; do
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "$args"
    [ "$status" -eq 1 ]
    [[ "$output" == *"packages/mypkg.yml: unknown key: tpyo"* ]]
    [[ "$output" == *"packages/mypkg.yml: alerts[0].when must be major, got minor"* ]]
    [[ "$output" != *"$TEST_TMPDIR"* ]]
  done
  echo "name: [" >"$TEST_TMPDIR/packages/mypkg.yml"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" mypkg
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid YAML syntax: packages/mypkg.yml"* ]]
}

@test "validate: a key made of two known names rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  \"project tag_version_regex\": x
\"name strategy\": x"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/mypkg.yml: unknown key: name strategy"* ]]
  [[ "$output" == *"mypkg.yml: upstream.project tag_version_regex is not a field of any strategy"* ]]
}

# The keys come from the reads of the scripts, so a key that a script
# starts to read cannot be refused
@test "validate: every top-level key a script reads passes" {
  local keys key extra=""
  keys=$(cd "$PROJECT_DIR" && grep -rhoE "pkg_(get|bool) [^ ]+ '?\"?\.[a-z_]+" scripts strategies | grep -oE '[a-z_]+$' | sort -u)
  [[ $'\n'"$keys"$'\n' == *$'\nallow_downgrade\n'* ]]
  for key in $keys; do
    case "$key" in
      name | strategy | upstream) ;;
      *) extra+=$'\n'"$key: x" ;;
    esac
  done
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo$extra"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  echo "$output"
  [[ "$output" != *"unknown key"* ]]
}

@test "validate: a YAML that is not a map rejected" {
  printf '%s\n' '- name: mypkg' '- strategy: github-release' >"$TEST_TMPDIR/packages/mypkg.yml"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mypkg.yml must be a map of fields"* ]]
  [[ "$output" != *"cannot index"* ]]
}

@test "validate: an upstream that is not a map rejected" {
  create_test_package "mypkg" "github-release" "upstream: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mypkg.yml: upstream must be a map"* ]]
  [[ "$output" != *"applies to"* ]]
}

@test "validate: rubygems takes registry and max_answer_mb" {
  create_test_package "mypkg" "rubygems" "upstream:
  registry: bashcov
  max_answer_mb: 10"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
  create_test_package "mypkg" "rubygems" "upstream:
  registry: bashcov
  prerelease: true"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.prerelease"* ]]
}

@test "validate: an upstream key of no strategy rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  projet: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mypkg.yml: upstream.projet is not a field of any strategy"* ]]
}

# Keys that a strategy script starts to read cannot be refused
@test "validate: every upstream key a strategy script reads passes with that strategy" {
  local file strategy key extra
  for file in "$PROJECT_DIR"/strategies/*.sh; do
    strategy=$(basename "$file" .sh)
    extra=""
    for key in $(grep -oE '\.upstream\.[a-z_]+' "$file" | sort -u); do
      extra+=$'\n'"  ${key#.upstream.}: x"
    done
    create_test_package "mypkg" "$strategy" "upstream:$extra"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    echo "$strategy: $output"
    [[ "$output" != *"strategy only"* && "$output" != *"strategies only"* ]]
    [[ "$output" != *"not a field of any strategy"* && "$output" != *"lists no upstream keys"* ]]
  done
}

@test "validate: a strategy without a line of upstream keys takes no upstream key" {
  printf '#!/usr/bin/env bash\n' >"$TEST_TMPDIR/strategies/forked.sh"
  create_test_package "mypkg" "forked" "upstream:
  url: https://example.com/"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mypkg.yml: validate-pkg.sh lists no upstream keys for the strategy forked"* ]]
  [[ "$output" != *"upstream.url applies to"* ]]

  create_test_package "mypkg" "forked" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

# === Strategy-specific field errors ===

@test "validate: github-release fails without upstream.project" {
  create_test_package "mypkg" "github-release" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.project'"* ]]
}

@test "validate: github-tag fails without upstream.project" {
  create_test_package "mypkg" "github-tag" "upstream:
  tag_version_regex: '^v(.+)$'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.project'"* ]]
}

@test "validate: github-asset fails without upstream.project" {
  create_test_package "mypkg" "github-asset" "upstream:
  tag: models
  assets:
    - voice-a.tar.bz2"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.project'"* ]]
}

@test "validate: github-asset fails without upstream.tag" {
  create_test_package "mypkg" "github-asset" "upstream:
  project: owner/repo
  assets:
    - voice-a.tar.bz2"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.tag'"* ]]
}

@test "validate: github-asset fails without upstream.assets" {
  create_test_package "mypkg" "github-asset" "upstream:
  project: owner/repo
  tag: models"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.assets'"* ]]
}

@test "validate: github-asset fails when upstream.assets is not a list" {
  create_test_package "mypkg" "github-asset" "upstream:
  project: owner/repo
  tag: models
  assets: voice-a.tar.bz2"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.assets'"* ]]
}

@test "validate: github-asset fails when upstream.assets is empty" {
  create_test_package "mypkg" "github-asset" "upstream:
  project: owner/repo
  tag: models
  assets: []"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.assets'"* ]]
}

@test "validate: gitlab-tag fails without upstream.host" {
  create_test_package "mypkg" "gitlab-tag" "upstream:
  project: group/project"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.host'"* ]]
}

@test "validate: gitlab-tag fails without upstream.project" {
  create_test_package "mypkg" "gitlab-tag" "upstream:
  host: gitlab.com"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.project'"* ]]
}

@test "validate: gitea-tag fails without upstream.host" {
  create_test_package "mypkg" "gitea-tag" "upstream:
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.host'"* ]]
}

@test "validate: gitea-release needs upstream.host and upstream.project" {
  create_test_package "mypkg" "gitea-release" "upstream:
  tag_version_regex: '^v(.+)$'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"strategy 'gitea-release' requires 'upstream.host'"* ]]
  [[ "$output" == *"strategy 'gitea-release' requires 'upstream.project'"* ]]

  create_test_package "mypkg" "gitea-release" "upstream:
  host: codeberg.org
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: git-tag passes" {
  create_test_package "mypkg" "git-tag" "upstream:
  url: https://git.example.org/~owner/repo
  tag_version_regex: '^release-(.+)$'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: git-tag fails without upstream.url" {
  create_test_package "mypkg" "git-tag" "upstream:
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"strategy 'git-tag' requires 'upstream.url'"* ]]
}

@test "validate: git-tag fails with a URL other than HTTPS" {
  create_test_package "mypkg" "git-tag" "upstream:
  url: http://git.example.org/~owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.url must use HTTPS: http://git.example.org/~owner/repo"* ]]
}

@test "validate: git-latest fails without upstream.type" {
  create_test_package "mypkg" "git-latest" "upstream:
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.type'"* ]]
}

@test "validate: git-latest github fails without project" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: github"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.project'"* ]]
}

@test "validate: git-latest gitlab fails without host" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: gitlab
  project: group/project"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.host'"* ]]
}

@test "validate: git-latest gitlab fails without project" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: gitlab
  host: gitlab.example.com"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"git-latest type 'gitlab' requires 'upstream.project'"* ]]
}

@test "validate: refuses a YAML file that does not parse" {
  printf '%s\n' 'name: mypkg' 'strategy: [github-release' >"$TEST_TMPDIR/packages/mypkg.yml"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid YAML syntax: "*"mypkg.yml"* ]]
}

@test "validate: git-latest git fails without url" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: git"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.url'"* ]]
}

@test "validate: git-latest fails on unknown type" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: bitbucket
  project: owner/repo"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown type 'bitbucket'"* ]]
}

@test "validate: git-latest fields that the type does not read rejected" {
  local entry type field message base
  for entry in "github|host: invent.kde.org|upstream.host applies to type gitlab only" \
    "github|url: https://git.example.com/repo.git|upstream.url applies to type git only" \
    "gitlab|url: https://git.example.com/repo.git|upstream.url applies to type git only" \
    "git|host: invent.kde.org|upstream.host applies to type gitlab only" \
    "git|project: owner/repo|upstream.project applies to types github and gitlab only"; do
    IFS='|' read -r type field message <<<"$entry"
    case "$type" in
      github) base="project: owner/repo" ;;
      gitlab) base="host: invent.kde.org
  project: group/project" ;;
      git) base="url: https://git.example.com/repo.git" ;;
    esac
    create_test_package "mypkg" "git-latest" "upstream:
  type: $type
  $base
  $field"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    echo "$entry: $output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"mypkg.yml: $message"* ]]
  done
}

# === github-nightly fields by version_source and pattern ===

@test "validate: the github-nightly patterns of the sample pass" {
  local pattern
  for pattern in "nightly_tag: nightly
  version_source: release_body
  version_pattern: 'NVIM v\\K\\S+'" "nightly_tag: nightly-
  version_source: tag_date" "nightly_tag_regex: '^[0-9]{4}-[0-9]{2}-[0-9]{2}\$'
  version_source: tag_date" "nightly_tag: latest" "channel: Nightly
  version_source: tag"; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  $pattern"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    echo "$pattern: $output"
    [ "$status" -eq 0 ]
  done
}

@test "validate: github-nightly version_source it does not know rejected" {
  create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  version_source: release_date"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mypkg.yml: upstream.version_source must be tag, release_body, tag_date or published_date: release_date"* ]]
}

@test "validate: github-nightly release_body without version_pattern rejected" {
  create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  version_source: release_body"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mypkg.yml: upstream.version_source release_body needs upstream.version_pattern"* ]]
}

# The strategy reads the release body with grep -P, and a pattern it cannot
# compile gives an empty version on every check
@test "validate: a version_pattern that grep -P cannot compile rejected" {
  create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  version_source: release_body
  version_pattern: 'NVIM v(?<x'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mypkg.yml: upstream.version_pattern is not valid PCRE regex: NVIM v(?<x"* ]]
  [[ "$output" != *"grep:"* ]]
}

# Pattern A reads one fixed tag, which has no dash and so no YYYY-MM-DD
@test "validate: tag_date with a fixed nightly tag rejected" {
  local tag
  for tag in nightly continuous; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  nightly_tag: $tag
  version_source: tag_date"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    echo "$tag: $output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"mypkg.yml: upstream.version_source tag_date reads the date in the tag name, and the fixed tag $tag has none"* ]]
  done
  create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  version_source: tag_date"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the fixed tag nightly has none"* ]]
}

# The tag of a separate nightly repo and that of a channel release move
@test "validate: tag_date with nightly_tag latest or a channel passes" {
  local pattern
  for pattern in "nightly_tag: latest" "channel: Nightly"; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  $pattern
  version_source: tag_date"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    echo "$pattern: $output"
    [ "$status" -eq 0 ]
  done
}

# Without version_source the strategy reads the tag
@test "validate: version_pattern with another version_source rejected" {
  local source
  for source in 'version_source: tag' 'version_source: tag_date' 'version_source: published_date' ''; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  $source
  version_pattern: 'v\\K\\S+'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    echo "$source: $output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"mypkg.yml: upstream.version_pattern applies to version_source release_body only"* ]]
  done
}

# nightly_tag: latest wins over channel, and channel over any other tag
@test "validate: nightly_tag next to channel rejected with the field that is read" {
  create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  nightly_tag: latest
  channel: Nightly"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mypkg.yml: upstream.nightly_tag latest takes the place of channel"* ]]
  create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  nightly_tag: nightly
  channel: Nightly"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mypkg.yml: upstream.channel takes the place of nightly_tag"* ]]
}

@test "validate: pypi fails without upstream.registry" {
  create_test_package "mypkg" "pypi" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.registry'"* ]]
}

@test "validate: upstream.pin_from takes a PyPI project name" {
  local value
  for value in zensical Zensical_UI zope.interface a 0; do
    create_test_package "mypkg" "pypi" "upstream:
  registry: zensical-ui
  pin_from: '$value'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ] || {
      echo "refused: $value"
      echo "$output"
      return 1
    }
  done
  for value in -x x- .x _x 'a b' zensical/ui 'pkg{a,b}' .. 'x?y'; do
    create_test_package "mypkg" "pypi" "upstream:
  registry: zensical-ui
  pin_from: '$value'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"upstream.pin_from must be a PyPI project name of A-Za-z0-9._- that starts and ends with a letter or digit: '$value'"* ]] || {
      echo "taken: $value"
      echo "$output"
      return 1
    }
  done
}

@test "validate: upstream.pin_from applies to the pypi strategy only" {
  create_test_package "mypkg" "npm" "upstream:
  registry: express
  pin_from: express"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mypkg.yml: upstream.pin_from applies to the pypi strategy only"* ]]
}

@test "validate: npm fails without upstream.registry" {
  create_test_package "mypkg" "npm" "upstream:
  foo: bar"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.registry'"* ]]
}

@test "validate: crates fails without upstream.registry" {
  create_test_package "mypkg" "crates" ""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.registry'"* ]]
}

@test "validate: webpage-scrape passes with upstream.user_agent" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'pkg-([0-9.]+)\\.tar\\.gz'
  user_agent: 'Example/2.0 (+https://example.com/bot)'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

# curl would send the text after a line break as a header of its own
@test "validate: webpage-scrape fails on a user_agent with a control character" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'pkg-([0-9.]+)\\.tar\\.gz'
  user_agent: \"Example/2.0\\r\\nX-Extra: 1\""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/mypkg.yml: a key or a value holds a control character"* ]]
}

@test "validate: webpage-scrape fails on a user_agent outside ASCII" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'pkg-([0-9.]+)\\.tar\\.gz'
  user_agent: 'Exämple/2.0'"
  run env LC_ALL=C.UTF-8 "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a key or a value outside alerts[].note holds a character other than printable ASCII and tab"* ]]
}

@test "validate: webpage-scrape fails without upstream.url" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  pattern: 'pkg-([0-9.]+)'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.url'"* ]]
}

@test "validate: webpage-scrape fails without upstream.pattern" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 'upstream.pattern'"* ]]
}

@test "validate: webpage-scrape fails on non-HTTPS url" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: http://example.com
  pattern: 'pkg-([0-9.]+)'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must use HTTPS"* ]]
}

# === --all mode ===

@test "validate --all: passes with all valid packages" {
  create_test_package "pkg-a" "github-release" "upstream:
  project: owner/repo"
  create_test_package "pkg-b" "pypi" "upstream:
  registry: requests"

  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 2 packages valid"* ]]
}

@test "validate --all: fails when any package invalid" {
  create_test_package "good" "github-release" "upstream:
  project: owner/repo"
  create_test_package "bad" "nonexistent-strat" ""

  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -ne 0 ]
  [[ "$output" == *"Validation failed"* ]]
}

@test "validate --all: handles empty packages dir" {
  rm -f "$TEST_TMPDIR/packages/"*.yml
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"No packages found"* ]]
}

# The data root holds the packages and no strategies/, so the strategy names
# have to come from the checkout
@test "validate-pkg: --all validates the packages of AURTOMATOR_DATA_DIR" {
  mkdir -p "$BATS_TEST_TMPDIR/data/packages"
  printf '%s\n' 'name: pkg-a' 'strategy: github-release' 'upstream:' '  project: owner/repo' >"$BATS_TEST_TMPDIR/data/packages/pkg-a.yml"
  printf '%s\n' 'name: pkg-b' 'strategy: pypi' 'upstream:' '  registry: requests' >"$BATS_TEST_TMPDIR/data/packages/pkg-b.yml"

  AURTOMATOR_DATA_DIR="$BATS_TEST_TMPDIR/data" run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 2 packages valid"* ]]
}

# Each yq is a process of its own, and validate.yml checks every package when the pins move
@test "validate --all: starts few yq processes for a package" {
  local real bin="$BATS_TEST_TMPDIR/bin" one
  real=$(command -v yq)
  mkdir -p "$bin"
  printf '#!/bin/sh\necho x >>"%s"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR/yq.log" "$real" >"$bin/yq"
  chmod +x "$bin/yq"
  create_test_package a github-release "upstream:
  project: owner/a
current: 1.0.0
last_updated: '2026-01-02'"
  PATH="$bin:$PATH" run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 0 ]
  one=$(wc -l <"$BATS_TEST_TMPDIR/yq.log")
  rm "$BATS_TEST_TMPDIR/yq.log"
  sed 's/^name: a$/name: b/; s#owner/a#owner/b#' "$TEST_TMPDIR/packages/a.yml" >"$TEST_TMPDIR/packages/b.yml"
  PATH="$bin:$PATH" run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 0 ]
  echo "per package: $(($(wc -l <"$BATS_TEST_TMPDIR/yq.log") - one))"
  (($(wc -l <"$BATS_TEST_TMPDIR/yq.log") - one <= 16))
}

# validate.yml checks every package when the pins move, so the packages spread over the cores
@test "validate --all: checks as many packages at once as nproc prints" {
  local real bin="$BATS_TEST_TMPDIR/bin" cores i
  real=$(command -v yq)
  mkdir -p "$bin" "$BATS_TEST_TMPDIR/running"
  # Each yq of a tag query waits, and logs how many yq run at that moment
  printf '#!/bin/bash
[[ "$*" == "-r tag "* ]] || exec "%s" "$@"
: >"%s/running/$$"
ls "%s/running" | wc -l >>"%s/at-once"
sleep 0.3
rm "%s/running/$$"
exec "%s" "$@"
' "$real" "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" "$real" >"$bin/yq"
  chmod +x "$bin/yq"
  for i in 1 2 3 4 5 6; do
    create_test_package "p$i" github-release "upstream:
  project: owner/p$i"
  done
  for cores in 1 3; do
    printf '#!/bin/sh\necho %s\n' "$cores" >"$bin/nproc"
    chmod +x "$bin/nproc"
    : >"$BATS_TEST_TMPDIR/at-once"
    PATH="$bin:$PATH" run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"All 6 packages valid"* ]]
    [ "$(sort -n "$BATS_TEST_TMPDIR/at-once" | tail -n 1)" = "$cores" ]
  done
}

# Each check runs in a subshell, and one that ends without its result fails the run
@test "validate --all: fails when a check gives no result" {
  local real bin="$BATS_TEST_TMPDIR/bin"
  real=$(command -v yq)
  mkdir -p "$bin" "$BATS_TEST_TMPDIR/tmp"
  printf '#!/bin/bash\n[[ "$*" != "-r tag "*/b.yml ]] || rm -rf "%s"/tmp/*\nexec "%s" "$@"\n' \
    "$BATS_TEST_TMPDIR" "$real" >"$bin/yq"
  printf '#!/bin/sh\necho 1\n' >"$bin/nproc"
  chmod +x "$bin/yq" "$bin/nproc"
  create_test_package a github-release "upstream:
  project: owner/a"
  create_test_package b github-release "upstream:
  project: owner/b"
  PATH="$bin:$PATH" TMPDIR="$BATS_TEST_TMPDIR/tmp" run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/b.yml: its check ended without a result"* ]]
  [[ "$output" != *"packages valid"* ]]
}

# The lines of one package stay together, and the packages keep the order of their files
@test "validate --all: prints the result of each package whole and in order" {
  local i expected=""
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    if ((10#$i % 3 == 0)); then
      create_test_package "p$i" github-release "upstream:
  project: owner/p$i
  tag_version_regex: '(x'
cooldown_days: -1"
      expected+="packages/p$i.yml: cooldown_days,packages/p$i.yml: upstream.tag_version_regex,"
    else
      create_test_package "p$i" github-release "upstream:
  project: owner/p$i"
    fi
  done
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 1 ]
  [ "$(grep -o 'packages/p[0-9]*\.yml: [a-z_.]*' <<<"$output" | tr '\n' ,)" = "$expected" ]
  [[ "${lines[-1]}" == *"Validation failed: 4/12 packages have errors" ]]
}

# Merge keys bring keys that the keys of a map do not list
@test "validate: reads the keys that a merge key brings" {
  create_test_package a github-release "upstream:
  <<: {tag_version_regex: '(x'}
  project: owner/a"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/a.yml: upstream.<< is not a field of any strategy"* ]]
  [[ "$output" == *"packages/a.yml: upstream.tag_version_regex must contain a capture group (): (x"* ]]
  create_test_package a github-release "<<: {current: 'x y'}
upstream:
  project: owner/a"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/a.yml: unknown key: <<"* ]]
  [[ "$output" == *"packages/a.yml: current must hold a digit and at most 64 characters of A-Za-z0-9 . _ +: 'x y'"* ]]
}

# validate.yml passes the files that git diff -z names for the push or the pull request
@test "validate --changed: checks the packages that the list names" {
  local list="$BATS_TEST_TMPDIR/changed"
  create_test_package a github-release "upstream:
  project: owner/a"
  create_test_package b nonexistent-strat ""
  create_test_package c pypi "upstream:
  registry: c"
  # Deleted files, files outside packages/ and files no run reads give no check
  printf '%s\0' packages/a.yml packages/c.yml packages/gone.yml README.md packages/sub/x.yml packages/.x.yml >"$list"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --changed "$list"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 2 changed packages valid"* ]]
  printf '%s\0' packages/b.yml packages/a.yml >"$list"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --changed "$list"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Validation failed: 1/2 packages have errors"* ]]
  : >"$list"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --changed "$list"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No package changed"* ]]
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --changed "$BATS_TEST_TMPDIR/none"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$BATS_TEST_TMPDIR/none: no list of changed files"* ]]
}

# Pull requests can name a file with a line break, and git diff -z ends each name with a NUL alone
@test "validate --changed: reads a name with a line break as one file" {
  local list="$BATS_TEST_TMPDIR/changed" name=$'b.yml\nc.yml'
  create_test_package b nonexistent-strat ""
  printf 'name: x\nstrategy: github-release\nupstream:\n  project: owner/repo\n' >"$TEST_TMPDIR/packages/$name"
  printf '%s\0' "packages/$name" >"$list"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --changed "$list"
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/\$'b.yml\\nc.yml': name 'x' must equal the file name"* ]]
  [[ "$output" != *"nonexistent-strat"* ]]
}

# The files of packages/ that no run reads fail on every run, since they cost no step per package
@test "validate --changed: fails on every file of packages/ that no run reads" {
  local list="$BATS_TEST_TMPDIR/changed"
  create_test_package a github-release "upstream:
  project: owner/a"
  printf '%s\0' packages/a.yml >"$list"
  ln -s "$TEST_TMPDIR/packages/a.yml" "$TEST_TMPDIR/packages/b.yml"
  : >"$TEST_TMPDIR/packages/notes.txt"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --changed "$list"
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/b.yml: no run reads it"* ]]
  [[ "$output" == *"packages/notes.txt: no run reads it"* ]]
  # A listed link is no package either
  printf '%s\0' packages/b.yml >"$list"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --changed "$list"
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/b.yml: no run reads it"* && "$output" != *"changed packages valid"* ]]
}

@test "validate: fails on nonexistent package" {
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "nonexistent"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Package not found: "*"/packages/nonexistent.yml"* ]]
}

# === Regex validation ===

@test "validate: webpage-scrape accepts valid regex pattern" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'pkg-([0-9]+\\.[0-9]+)\\.tar\\.gz'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: webpage-scrape accepts a pattern that starts with a dash" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: '-([0-9]+\\.[0-9]+)\\.tar\\.gz'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

# grep -E takes these and bash refuses them
@test "validate: webpage-scrape rejects a pattern that bash cannot compile" {
  local pattern
  for pattern in '(?:v)?pkg-([0-9.]+)' '*pkg-([0-9.]+)' 'pkg-([0-9]{1)'; do
    create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: '$pattern'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not valid ERE regex"* ]]
  done
}

# The strategy prints the first group of each match, and a pattern without
# one stopped it with BASH_REMATCH[1]: unbound variable
@test "validate: webpage-scrape rejects a pattern without a capture group" {
  local pattern
  for pattern in 'app-[0-9.]+\.tar\.gz' 'app-\(x\)[0-9.]+'; do
    create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: '$pattern'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"upstream.pattern must contain a capture group: $pattern"* ]]
  done
}

@test "validate: webpage-scrape accepts a pattern with a slash" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'download/pkg-([0-9.]+)\\.tar\\.gz'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: webpage-scrape rejects invalid regex pattern" {
  create_test_package "mypkg" "webpage-scrape" "upstream:
  url: https://example.com/releases
  pattern: 'pkg-([0-9+'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid ERE regex"* ]]
}

@test "validate: allow_downgrade true passes" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
allow_downgrade: true"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: allow_downgrade that is not a boolean rejected" {
  local value
  for value in yes '"true"' 1 '!!bool yes'; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
allow_downgrade: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"allow_downgrade must be true or false"* ]]
  done
}

@test "validate: allow_version_jump true passes" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
allow_version_jump: true"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: allow_version_jump that is not a boolean rejected" {
  local value
  for value in yes '"true"' 1 '!!bool yes'; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
allow_version_jump: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"allow_version_jump must be true or false"* ]]
  done
}

@test "validate: cooldown_days from 0 to 365 passes" {
  local value
  for value in 0 7 365; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
cooldown_days: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ] || {
      echo "refused: $value"
      return 1
    }
  done
}

@test "validate: upstream.max_answer_mb from 1 to 500 passes" {
  local value
  for value in 1 80 500; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  max_answer_mb: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ] || {
      echo "refused: $value"
      return 1
    }
  done
}

@test "validate: upstream.max_answer_mb that is not a whole number from 1 to 500 rejected" {
  local value
  for value in 0 501 1.5 "'80'" 080 10M abc; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  max_answer_mb: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"packages/mypkg.yml: upstream.max_answer_mb must be a whole number from 1 to 500"* ]] || {
      echo "taken: $value"
      return 1
    }
  done
}

# git-latest clones with limits of its own
@test "validate: upstream.max_answer_mb applies to the strategies that read answers" {
  create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
  max_answer_mb: 80"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.max_answer_mb applies to the "*" strategies only"* ]]
}

# The tag listing of git ls-remote takes the answer limit too
@test "validate: git-tag takes upstream.max_answer_mb" {
  create_test_package "mypkg" "git-tag" "upstream:
  url: https://example.com/repo.git
  max_answer_mb: 80"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: cooldown_days that is not a whole number from 0 to 365 rejected" {
  local value
  for value in -1 366 7.5 "'7'" 007 abc; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
cooldown_days: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"packages/mypkg.yml: cooldown_days must be a whole number from 0 to 365"* ]] || {
      echo "taken: $value"
      return 1
    }
  done
}

@test "validate: last_updated of today or before passes, quoted or not" {
  local value
  for value in "'$(date -u +%F)'" "$(date -u +%F)" 2026-11-05; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
last_updated: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ] || {
      echo "refused: $value"
      return 1
    }
  done
}

@test "validate: last_updated that is not a date or is later than today rejected" {
  local value
  for value in "'2026-02-30'" "'yesterday'" 20261106 2026-11-06T10:00:00Z; do
    create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
last_updated: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"packages/mypkg.yml: last_updated must be a date YYYY-MM-DD: '"* ]] || {
      echo "taken: $value"
      return 1
    }
  done
  create_test_package "mypkg" "git-latest" "upstream:
  type: github
  project: owner/repo
last_updated: '$(date -u -d '1 day' +%F)'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"packages/mypkg.yml: last_updated is later than today: $(date -u -d '1 day' +%F)"* ]]
}

@test "validate: allow_missing_arch true or false passes" {
  local value
  for value in true false; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
allow_missing_arch: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ] || {
      echo "refused: $value"
      return 1
    }
  done
}

@test "validate: allow_missing_arch that is not a boolean rejected" {
  local value
  for value in no yes '"false"' 0 '!!bool no'; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
allow_missing_arch: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"packages/mypkg.yml: allow_missing_arch must be true or false"* ]] || {
      echo "taken: $value"
      return 1
    }
  done
}

@test "validate: arch_out of arch names and commit ids passes" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
arch_out:
  aarch64: 3a5f6f12a7c9176a4c87bb402f1a3e938ec04011
  powerpc64le: '0123456789012345678901234567890123456789'
  x86_64_v3: \"abcdef0123456789abcdef0123456789abcdef01\""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: arch_out that is not a map of arch names to commit ids rejected" {
  local sha=3a5f6f12a7c9176a4c87bb402f1a3e938ec04011 entry expected
  local -a cases=(
    "  - aarch64|arch_out must be a map of arch names to commit ids"
    "  AArch64: $sha|arch_out: an arch name may hold a-z0-9_ only: 'AArch64'"
    "  'a b': $sha|arch_out: an arch name may hold a-z0-9_ only: 'a b'"
    "  aarch64: ${sha:1}|arch_out.aarch64 must be a commit id of 40 hex digits: '${sha:1}'"
    "  aarch64: ${sha^^}|arch_out.aarch64 must be a commit id of 40 hex digits: '${sha^^}'"
    "  aarch64: HEAD|arch_out.aarch64 must be a commit id of 40 hex digits: 'HEAD'"
  )
  for entry in "${cases[@]}"; do
    expected=${entry#*|}
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
arch_out:
${entry%%|*}"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"packages/mypkg.yml: $expected"* ]] || {
      echo "taken: ${entry%%|*}"
      echo "$output"
      return 1
    }
  done
}

@test "validate: arch_wait of a version and a UTC time passes, quoted or not" {
  local since
  for since in '"2026-11-06T11:17:00Z"' 2026-11-06T11:17:00Z; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
arch_wait:
  version: 28+23
  since: $since"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ] || {
      echo "refused: $since"
      return 1
    }
  done
}

@test "validate: arch_wait with the arches it waits for and the AUR commit that builds them" {
  local commit entry expected
  commit=$(printf 'c%.0s' {1..40})
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
arch_wait:
  version: 28+23
  since: 2026-11-06T11:17:00Z
  commit: $commit
  arches: aarch64 riscv64"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]

  local commit_value arches
  local -a cases=(
    "main|aarch64|arch_wait.commit must be a commit id of 40 hex digits: 'main'"
    "${commit}0|aarch64|arch_wait.commit must be a commit id of 40 hex digits: '${commit}0'"
    "x$commit|aarch64|arch_wait.commit must be a commit id of 40 hex digits: 'x$commit'"
    "$commit|x86_64|arch_wait.arches must name arches other than x86_64, separated by single spaces: 'x86_64'"
    "$commit||arch_wait.arches must name arches other than x86_64, separated by single spaces: ''"
  )
  for entry in "${cases[@]}"; do
    IFS='|' read -r commit_value arches expected <<<"$entry"
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
arch_wait:
  version: 28+23
  since: 2026-11-06T11:17:00Z
  commit: '$commit_value'
  arches: '$arches'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$expected"* ]] || {
      echo "taken: $entry"
      return 1
    }
  done
}

@test "validate: arch_wait without a version and a UTC time of the past rejected" {
  local later entry expected
  later=$(date -u -d '1 hour' +%Y-%m-%dT%H:%M:%SZ)
  local -a cases=(
    "arch_wait: 28+23|arch_wait must be a map with version and since, or version, since, commit and arches, and no other key"
    "arch_wait:
  version: 28+23|arch_wait must be a map with version and since, or version, since, commit and arches, and no other key"
    "arch_wait:
  version: 28+23
  since: 2026-11-06T11:17:00Z
  arches: aarch64|arch_wait must be a map with version and since, or version, since, commit and arches, and no other key"
    "arch_wait:
  version: '28 23'
  since: 2026-11-06T11:17:00Z|arch_wait.version must hold a digit and at most 64 characters of A-Za-z0-9 . _ +: '28 23'"
    "arch_wait:
  version: 28+23
  since: '2026-11-06'|arch_wait.since must be a UTC time YYYY-MM-DDTHH:MM:SSZ: '2026-11-06'"
    "arch_wait:
  version: 28+23
  since: '2026-02-30T11:17:00Z'|arch_wait.since must be a UTC time YYYY-MM-DDTHH:MM:SSZ: '2026-02-30T11:17:00Z'"
    "arch_wait:
  version: 28+23
  since: '$later'|arch_wait.since is later than now: $later"
  )
  for entry in "${cases[@]}"; do
    expected=${entry#*|}
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
${entry%%|*}"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"packages/mypkg.yml: $expected"* ]] || {
      echo "taken: ${entry%%|*}"
      echo "$output"
      return 1
    }
  done
}

@test "validate: alerts with when, from and match pass" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
alerts:
  - when: major
    note: Raise makedepends java-environment to the new major minus one
  - from: '0.4.0'
    hold: true
    note: License changes to Apache-2.0
  - match: '^29\\+'
    hold: false
    note: Check the boot JDK"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: alerts that is not a list rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
alerts:
  when: major
  note: New major"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"alerts must be a list"* ]]
}

@test "validate: an alert that is not a map rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
alerts:
  - major"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"alerts[0] must be a map with note and one of when, from, match"* ]]
}

@test "validate: an alert with an unknown key rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
alerts:
  - when: major
    note: New major
    notify: true"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"packages/mypkg.yml: alerts[0]: unknown key: notify"* ]]
}

@test "validate: an alert without one condition rejected" {
  local conditions
  for conditions in "" "when: major
    from: '1.0'" "from: '1.0'
    match: '^2'"; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
alerts:
  - note: New major
    $conditions"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"alerts[0] must hold exactly one of when, from, match"* ]]
  done
}

@test "validate: an alert when other than major rejected" {
  local value
  for value in minor "''" true "[major]"; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
alerts:
  - when: $value
    note: New major"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"alerts[0].when must be major, got "* ]]
  done
}

@test "validate: an alert from that is not a version rejected" {
  local value
  for value in "'1.0-rc1'" "''" "beta" "[1.0]" "$(printf 'a%.0s' {1..64})1"; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
alerts:
  - from: $value
    note: License change"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"alerts[0].from must be a version of at most 64 characters of A-Za-z0-9 . _ + with a digit"* ]]
  done
}

@test "validate: an alert from as a YAML number passes" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
alerts:
  - from: 2
    note: New line"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: an alert match that is not an ERE bash accepts rejected" {
  local value
  for value in "'(?:29)'" "'*29'" "''" "[29]"; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
alerts:
  - match: $value
    note: New line"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"alerts[0].match must be a non-empty ERE that bash accepts"* ]]
  done
}

@test "validate: an alert note that is not one line of text rejected" {
  local note
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
alerts:
  - when: major
    note: |
      First line
      Second line"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"packages/mypkg.yml: a key or a value holds a control character"* ]]
  for note in "" "note: ''" "note: [a, b]" "note: {text: x}"; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
alerts:
  - when: major
    $note"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"alerts[0].note must be one line of text"* ]]
    [[ "$output" != *"in quotes"* ]]
  done
}

# _alerts separates its fields with tabs
@test "validate: an alert note with a tab rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
alerts:
  - when: major
    hold: true
    note: \"Raise foo\\tto 2\""
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"alerts[0].note must be one line of text without tabs"* ]]
}

@test "validate: an alert note that YAML reads as a number, a boolean or a date asks for quotes" {
  local value
  for value in 2024 1.5 true 2024-10-30; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
alerts:
  - when: major
    note: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"alerts[0].note must be one line of text: put $value in quotes"* ]]
  done
}

@test "validate: an alert hold that is not a boolean rejected" {
  local value
  for value in yes '"true"' 1 '!!bool yes'; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
alerts:
  - when: major
    hold: $value
    note: New major"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"alerts[0].hold must be true or false"* ]]
  done
}

@test "validate: every flag takes true and false in any case" {
  local value
  for value in true True TRUE false False FALSE; do
    create_test_package "mypkg" "crates" "upstream:
  registry: pijul
  prerelease: $value
pkgver_dash: _
allow_downgrade: $value
allow_version_jump: $value
allow_missing_arch: $value
alerts:
  - when: major
    hold: $value
    note: New major"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ] || {
      echo "refused: $value"
      return 1
    }
    create_test_package "mypkg" "archpkg" "upstream:
  testing: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ] || {
      echo "refused testing: $value"
      return 1
    }
  done
}

@test "validate: names the alert at its index" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
alerts:
  - when: major
    note: New major
  - from: '1.0'
    hold: maybe
    note: License change"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"alerts[1].hold must be true or false"* ]]
  [[ "$output" != *"alerts[0]"* ]]
}

# The fixed text of 4.%s holds the first number of every version
@test "validate: an alert when major with pkgver_format rejected" {
  create_test_package "mypkg" "repology" "current: '4.4215'
pkgver_format: '4.%s'
alerts:
  - when: major
    note: New major"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"alerts[0]: when: major does not apply with pkgver_format"* ]]
}

@test "validate: an alert from or match with pkgver_format passes" {
  create_test_package "mypkg" "repology" "current: '4.4215'
pkgver_format: '4.%s'
alerts:
  - from: '4.5000'
    note: New build line
  - match: '^4\\.5'
    note: New build line"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: an alert requires: changed of pypi passes with or without note" {
  create_test_package "mypkg" "pypi" "upstream:
  registry: zensical
alerts:
  - requires: changed
    hold: true
  - from: '0.2'
    note: New minor"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
  create_test_package "mypkg" "pypi" "upstream:
  registry: zensical
alerts:
  - requires: changed
    note: Check the depends of the PKGBUILD"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: requires: changed and unmet pass side by side, unmet also with pkgver_format" {
  create_test_package "mypkg" "pypi" "upstream:
  registry: zensical
pkgver_format: '4.%s'
alerts:
  - requires: unmet
    hold: true"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
  create_test_package "mypkg" "pypi" "upstream:
  registry: zensical
alerts:
  - requires: changed
  - requires: unmet
    note: Check depends"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: requires: imports passes as a notice, and hold: true on it is refused" {
  create_test_package "mypkg" "pypi" "upstream:
  registry: zensical
python:
  skip: [tools, docs/api]
alerts:
  - requires: imports
    note: Check the imports
  - requires: unmet
    hold: true"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
  create_test_package "mypkg" "pypi" "upstream:
  registry: zensical
alerts:
  - requires: imports
    hold: true"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/mypkg.yml: alerts[0].hold does not apply to requires: imports"* ]]
}

@test "validate: ruby takes none or gem, and requires runs with ruby.gem" {
  local body
  for body in "ruby: none" $'ruby:\n  gem: simplecov-cobertura\nalerts:\n  - requires: unmet\n    hold: true'; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
$body"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ] || {
      echo "$body"
      echo "$output"
      return 1
    }
  done
  local entry strategy message
  for entry in "github-release|ruby: other|ruby must be none or a map" \
    "github-release|ruby: {gem: ../x}|ruby.gem must be a gem name of A-Za-z0-9._- that starts with a letter or digit: '../x'" \
    "rubygems|ruby: {gem: x}|ruby.gem does not apply to the rubygems strategy, which reads upstream.registry" \
    "github-release|ruby: none
alerts: [{requires: unmet}]|alerts[0]: requires needs strategy pypi or rubygems, python.pypi, python.pyproject or ruby.gem"; do
    strategy=${entry%%|*}
    body=${entry#*|}
    message=${body#*|}
    body=${body%|*}
    create_test_package "mypkg" "$strategy" "upstream:
  project: owner/repo
  registry: bashcov
$body"
    [[ "$strategy" == rubygems ]] || yq -i 'del(.upstream.registry)' "$TEST_TMPDIR/packages/mypkg.yml"
    [[ "$strategy" != rubygems ]] || yq -i 'del(.upstream.project)' "$TEST_TMPDIR/packages/mypkg.yml"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"packages/mypkg.yml: $message"* ]] || {
      echo "$entry"
      echo "$output"
      return 1
    }
  done
}

@test "validate: ruby takes map, skip and relax, and requires runs with strategy rubygems" {
  create_test_package "mypkg" "rubygems" "upstream:
  registry: bashcov
ruby:
  map:
    simplecov: ruby-simplecov
  skip: [win32ole, wdm]
  relax: True
alerts:
  - requires: unmet
    hold: true
  - requires: changed"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
  local entry body message
  for entry in "ruby: [x]|ruby must be none or a map" "ruby: {map: [a]}|ruby.map must be a map of gem names to package names" \
    "ruby: {map: {-x: ruby-x}}|ruby.map: '-x' is not a gem name" \
    "ruby: {map: {x: Ruby-X}}|ruby.map.x must be a package name of a-z, 0-9 and @ . _ + -: 'Ruby-X'" \
    "ruby: {skip: x}|ruby.skip must be a list of gem names" "ruby: {skip: [../x]}|ruby.skip: '../x' is not a gem name" \
    "ruby: {relax: maybe}|ruby.relax must be true or false" "ruby: {other: x}|ruby: unknown key: other"; do
    body=${entry%%|*}
    message=${entry#*|}
    create_test_package "mypkg" "rubygems" "upstream:
  registry: bashcov
$body"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"packages/mypkg.yml: $message"* ]] || {
      echo "$entry"
      echo "$output"
      return 1
    }
  done
}

@test "validate: python takes none or the sources pypi, release and pyproject" {
  local body
  for body in "python: none" $'python:\n  pypi: KubeDiagrams' $'python:\n  pypi: KubeDiagrams\n  release: newest' \
    $'python:\n  pyproject: pyproject.toml' $'python:\n  pyproject: python/pyproject.toml\n  skip: [docs]' \
    $'python:\n  pypi: KubeDiagrams\nalerts:\n  - requires: unmet\n    hold: true\n  - requires: changed' \
    $'python:\n  pyproject: pyproject.toml\nalerts:\n  - requires: imports'; do
    create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
$body"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ] || {
      echo "$body"
      echo "$output"
      return 1
    }
  done
}

@test "validate: python sources out of their forms rejected" {
  local entry strategy body message
  for entry in "github-release|python: [x]|python must be none or a map" \
    "github-release|python: other|python must be none or a map" \
    "github-release|python: {pypi: -x}|python.pypi must be a PyPI project name of A-Za-z0-9._- that starts and ends with a letter or digit: '-x'" \
    "github-release|python: {pypi: x, release: oldest}|python.release must be newest: 'oldest'" \
    "github-release|python: {release: newest}|python.release applies with python.pypi alone" \
    "github-release|python: {pyproject: ../pyproject.toml}|python.pyproject must be a relative path to a .toml file without ..: '../pyproject.toml'" \
    "github-release|python: {pyproject: /pyproject.toml}|python.pyproject must be a relative path to a .toml file without ..: '/pyproject.toml'" \
    "github-release|python: {pyproject: setup.cfg}|python.pyproject must be a relative path to a .toml file without ..: 'setup.cfg'" \
    "github-release|python: {pypi: x, pyproject: pyproject.toml}|python.pypi and python.pyproject exclude each other" \
    "pypi|python: {pypi: x}|python.pypi, python.release and python.pyproject do not apply to the pypi strategy, which reads upstream.registry" \
    "github-release|alerts: [{requires: unmet}]|alerts[0]: requires needs strategy pypi or rubygems, python.pypi, python.pyproject or ruby.gem" \
    "github-release|python: none
alerts: [{requires: imports}]|alerts[0]: requires needs strategy pypi or rubygems, python.pypi, python.pyproject or ruby.gem" \
    "github-release|python: {pypi: x, release: newest}
alerts: [{requires: changed}]|alerts[0]: requires: changed does not apply with python.release or python.pyproject" \
    "github-release|python: {pyproject: pyproject.toml}
alerts: [{requires: changed}]|alerts[0]: requires: changed does not apply with python.release or python.pyproject"; do
    strategy=${entry%%|*}
    body=${entry#*|}
    body=${body%|*}
    message=${entry##*|}
    create_test_package "mypkg" "$strategy" "upstream:
  project: owner/repo
  registry: zensical
$body"
    [[ "$strategy" == pypi ]] || yq -i 'del(.upstream.registry)' "$TEST_TMPDIR/packages/mypkg.yml"
    [[ "$strategy" != pypi ]] || yq -i 'del(.upstream.project)' "$TEST_TMPDIR/packages/mypkg.yml"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"packages/mypkg.yml: $message"* ]] || {
      echo "$entry"
      echo "$output"
      return 1
    }
  done
}

@test "validate: python.map maps PyPI names to package names" {
  create_test_package "mypkg" "pypi" "upstream:
  registry: graphviz2drawio
python:
  map:
    svg-path: python-svg.path
    opencv_python: python-opencv
    Foo.Bar: lib32-c++lib"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
  local entry body message
  for entry in "python: {map: [a]}|python.map must be a map of PyPI names to package names" \
    "python: {map: {-x: python-x}}|python.map: '-x' is not a PyPI name" \
    "python: {map: {x: Python-X}}|python.map.x must be a package name of a-z, 0-9 and @ . _ + -: 'Python-X'" \
    "python: {map: {x: [a]}}|python.map.x must be a package name of a-z, 0-9 and @ . _ + -: '[\"a\"]'" \
    "python: {source: x}|python: unknown key: source" "python: {skip: docs}|python.skip must be a list of relative paths" \
    "python: {skip: [../x]}|python.skip: '../x' must be a relative path without .." \
    "python: {skip: [/abs]}|python.skip: '/abs' must be a relative path without .." \
    "python: {skip: [a/../b]}|python.skip: 'a/../b' must be a relative path without .." \
    "python: {skip: ['']}|python.skip: '' must be a relative path without .."; do
    body=${entry%%|*}
    message=${entry#*|}
    create_test_package "mypkg" "pypi" "upstream:
  registry: graphviz2drawio
$body"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"packages/mypkg.yml: $message"* ]] || {
      echo "$entry"
      echo "$output"
      return 1
    }
  done
}

@test "validate: an alert requires outside changed, pypi and the spelling of PyPI rejected" {
  local entry strategy body message
  for entry in "pypi|  - requires: always|alerts[0].requires must be changed, unmet or imports, got always" \
    "npm|  - requires: changed|alerts[0]: requires needs strategy pypi or rubygems, python.pypi, python.pyproject or ruby.gem" \
    "pypi|  - requires: changed
    from: '1.0'|alerts[0] must hold exactly one of when, from, match, requires" \
    "pypi|  - requires: changed
  - requires: unmet
  - requires: changed
    hold: true|alerts[2].requires: changed is set twice" \
    "npm|  - requires: unmet|alerts[0]: requires needs strategy pypi or rubygems, python.pypi, python.pyproject or ruby.gem"; do
    strategy=${entry%%|*}
    body=${entry#*|}
    body=${body%|*}
    message=${entry##*|}
    create_test_package "mypkg" "$strategy" "upstream:
  registry: zensical
alerts:
$body"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"packages/mypkg.yml: $message"* ]] || {
      echo "$entry"
      echo "$output"
      return 1
    }
  done
  for entry in "pkgver_format: '4.%s'|pkgver_format" "pkgver_dash: _|pkgver_dash"; do
    create_test_package "mypkg" "pypi" "upstream:
  registry: zensical
${entry%|*}
alerts:
  - requires: changed"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ] && [[ "$output" == *"packages/mypkg.yml: alerts[0]: requires does not apply with ${entry#*|}"* ]] || {
      echo "$entry"
      echo "$output"
      return 1
    }
  done
}

@test "validate: pkgver_dash _, . or '' passes" {
  local value
  for value in _ . ""; do
    create_test_package "mypkg" "npm" "upstream:
  registry: cli-pride-flags
pkgver_dash: '$value'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ]
  done
}

@test "validate: pkgver_dash other than _, . or '' rejected" {
  local value
  for value in "'+'" "'-'" "'__'" "' '" "drop" 1; do
    create_test_package "mypkg" "npm" "upstream:
  registry: cli-pride-flags
pkgver_dash: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pkgver_dash must be _, . or ''"* ]]
  done
}

@test "validate: pkgver_format with %s once passes" {
  create_test_package "mypkg" "repology" "current: '4.4215'
pkgver_format: '4.%s'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: pkgver_format without %s once or with other characters rejected" {
  local value
  for value in "'4.'" "'%s.%s'" "'4-%s'" "'4 %s'" "'4:%s'" "''" 4; do
    create_test_package "mypkg" "repology" "pkgver_format: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pkgver_format must hold %s once, with only A-Za-z0-9 . _ + around it"* ]]
  done
}

@test "validate: current outside pkgver_format rejected" {
  create_test_package "mypkg" "repology" "current: '3.4215'
pkgver_format: '4.%s'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"current 3.4215 does not fit pkgver_format 4.%s"* ]]
}

# === crates prerelease validation ===

@test "validate: crates prerelease with pkgver_dash passes" {
  local value
  for value in . "''"; do
    create_test_package "mypkg" "crates" "upstream:
  registry: pijul
  prerelease: true
pkgver_dash: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ]
  done
}

# Semver pre-releases always hold a dash
@test "validate: crates prerelease without pkgver_dash rejected" {
  local value
  for value in true True TRUE; do
    create_test_package "mypkg" "crates" "upstream:
  registry: pijul
  prerelease: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"upstream.prerelease needs pkgver_dash"* ]] || {
      echo "taken: $value"
      return 1
    }
  done
}

@test "validate: crates prerelease false without pkgver_dash passes" {
  local value
  for value in false False FALSE; do
    create_test_package "mypkg" "crates" "upstream:
  registry: serde
  prerelease: $value"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ]
  done
}

@test "validate: prerelease for another strategy rejected" {
  create_test_package "mypkg" "npm" "upstream:
  registry: cli-pride-flags
  prerelease: true
pkgver_dash: _"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.prerelease applies to the crates strategy only"* ]]
}

@test "validate: prerelease that is not a boolean rejected" {
  local value
  for value in yes '"true"' 1 '!!bool yes'; do
    create_test_package "mypkg" "crates" "upstream:
  registry: pijul
  prerelease: $value
pkgver_dash: _"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"upstream.prerelease must be true or false"* ]]
  done
}

# === tag_version_regex validation ===

@test "validate: tag_version_regex valid with capture group passes" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: 'MeshLab-(.*)'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

# | ends the pattern of a sed s command
@test "validate: tag_version_regex may hold |" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: '^v?([0-9.]+)(-stable|)$'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: tag_version_regex invalid regex rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: '([invalid)'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid ERE regex"* ]]
}

# In a sed s command the field would close the pattern and add the e flag,
# which runs the pattern space as a command. bash reads it as an ERE.
@test "validate: tag_version_regex runs no command" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: '.*|touch $TEST_TMPDIR/pwned|e;s|(x)|y|;#'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/pwned" ]
}

@test "validate: tag_version_regex without capture group rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: 'MeshLab-.*'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"capture group"* ]]
}

# Strategies read the field when their script names it
@test "validate: tag_version_regex for a strategy that does not read it rejected" {
  local file strategy
  for file in "$PROJECT_DIR"/strategies/*.sh; do
    strategy=$(basename "$file" .sh)
    create_test_package "mypkg" "$strategy" "upstream:
  tag_version_regex: '^v(.+)$'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    echo "$strategy: $output"
    if grep -q 'tag_version_regex' "$file"; then
      [[ "$output" != *"upstream.tag_version_regex applies to"* ]]
    else
      [ "$status" -eq 1 ]
      [[ "$output" == *"upstream.tag_version_regex applies to the github-release, github-tag, github-nightly, gitlab-tag, gitea-tag, gitea-release and git-tag strategies only"* ]]
    fi
  done
}

# Without version_source github-nightly reads the tag
@test "validate: tag_version_regex for github-nightly with version_source tag passes" {
  local source
  for source in 'version_source: tag' ''; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  $source
  tag_version_regex: '^v(.+)$'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ]
  done
}

# Only github-nightly reads version_source
@test "validate: tag_version_regex for github-release with a version_source refuses the version_source only" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  version_source: release_body
  tag_version_regex: '^v(.+)$'
  tag_version_replace: '\\1'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.version_source applies to the github-nightly strategy only"* ]]
  [[ "$output" != *"tag_version_regex applies to version_source tag only"* ]]
  [[ "$output" != *"tag_version_replace applies to version_source tag only"* ]]
}

@test "validate: tag_version_regex for github-nightly with another version_source rejected" {
  local source
  for source in release_body tag_date published_date; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  version_source: $source
  version_pattern: 'v\\K\\S+'
  tag_version_regex: '^v(.+)$'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream.tag_version_regex applies to version_source tag only"* ]]
  done
}

# tag_version_regex there is refused as well, so asking for one would
# send the author in a circle
@test "validate: tag_version_replace for github-nightly with another version_source rejected" {
  local source
  for source in release_body tag_date published_date; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  version_source: $source
  version_pattern: 'v\\K\\S+'
  tag_version_replace: '\\1'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream.tag_version_replace applies to version_source tag only"* ]]
    [[ "$output" != *"needs upstream.tag_version_regex"* ]]
  done
}

# === tag_version_replace validation ===

@test "validate: tag_version_replace with the groups of the regex passes" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: '^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
  tag_version_replace: '\\1.\\2.\\3'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: tag_version_replace without tag_version_regex rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_replace: '\\1'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.tag_version_replace needs upstream.tag_version_regex"* ]]
}

@test "validate: tag_version_replace with a character a version lacks rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: '^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
  tag_version_replace: '\\1-\\2'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *'upstream.tag_version_replace may hold only A-Za-z0-9 . _ +, \1 to \9 and \p'* ]]
}

@test "validate: tag_version_replace naming a group the regex lacks rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: '^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
  tag_version_replace: '\\1.\\4'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.tag_version_replace names a group tag_version_regex does not have"* ]]
}

# Without version_source the strategy reads the tag
@test "validate: tag_version_replace with \\p and date_format passes for github-nightly" {
  local source
  for source in 'version_source: tag' ''; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  nightly_tag_regex: '^v[0-9.]+-dev\\.[0-9a-f]{12}$'
  $source
  tag_version_regex: '^v([0-9.]+)-dev\\.([0-9a-f]{12})$'
  tag_version_replace: '\\1dev\\p+\\2'
  date_format: '%Y%m%d%H%M%S'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ]
  done
}

@test "validate: tag_version_replace with \\p rejected for another strategy" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  tag_version_regex: '^v([0-9.]+)$'
  tag_version_replace: '\\1.\\p'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *'upstream.tag_version_replace holds \p, which only github-nightly fills'* ]]
}

# === nightly_tag_regex validation ===

@test "validate: nightly_tag_regex passes" {
  create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  nightly_tag_regex: '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  version_source: tag_date"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: nightly_tag_regex for another strategy rejected" {
  create_test_package "mypkg" "github-release" "upstream:
  project: owner/repo
  nightly_tag_regex: '^nightly-'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.nightly_tag_regex applies to the github-nightly strategy only"* ]]
}

@test "validate: nightly_tag_regex next to nightly_tag or channel rejected" {
  local field
  for field in 'nightly_tag: nightly-' 'channel: Nightly'; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  nightly_tag_regex: '^nightly-'
  $field"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream.nightly_tag_regex takes the place of nightly_tag and channel"* ]]
  done
}

@test "validate: nightly_tag_regex invalid regex rejected" {
  create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  nightly_tag_regex: '([0-9]'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upstream.nightly_tag_regex is not valid ERE regex: ([0-9]"* ]]
}

# === date_format validation ===

@test "validate: date_format with a date version_source passes" {
  local source
  for source in tag_date published_date; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  nightly_tag: nightly-
  version_source: $source
  date_format: '%Y%m%d'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -eq 0 ]
  done
}

# Without version_source the strategy reads the tag
@test "validate: date_format with another version_source rejected" {
  local source
  for source in 'version_source: tag' 'version_source: release_body' ''; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  $source
  version_pattern: 'v\\K\\S+'
  date_format: '%Y%m%d'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *'upstream.date_format applies to version_source tag_date and published_date and to \p in tag_version_replace'* ]]
  done
}

@test "validate: date_format that gives no valid version rejected" {
  create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  version_source: tag_date
  date_format: '%Y-%m-%d'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.date_format must give a valid version, it gives '2026-01-02'"* ]]
}

# date pads a field to any width, so 12 bytes of YAML could ask for megabytes
@test "validate: date_format with a field width or over 32 characters rejected before date runs" {
  local format
  for format in '%30000000d' '%_10d' '%+10d' '%Y%m%d%H%M%S%Y%m%d%H%M%S%Y%m%d%H%M'; do
    create_test_package "mypkg" "github-nightly" "upstream:
  project: owner/repo
  version_source: tag_date
  date_format: '$format'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"upstream.date_format must hold at most 32 characters and no field width such as %10d: '$format'"* ]]
    [[ "$output" != *"it gives"* ]]
  done
}

# === values from release asset names ===

# Helper: a package of the given strategy with the given asset keys
# Usage: asset_yaml <strategy> <lines under upstream:> [top-level lines]
asset_yaml() {
  create_test_package "mypkg" "$1" "upstream:
  project: owner/repo
$2
${3:-}"
}

@test "validate: asset_regex and asset_var of github-tag pass" {
  asset_yaml github-tag "  asset_regex: '^liquidsoap_([0-9.]+-debian-forky-ocaml5\\.[0-9.]+-[0-9]+)_amd64\\.deb\$'
  asset_var: _deb" "current_asset: 2.5.0-debian-forky-ocaml5.5.1-1"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: asset_regex and asset_var of github-release pass" {
  asset_yaml github-release "  asset_regex: '^app-(.+)-x86_64\\.tar\\.gz\$'
  asset_var: _build"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -eq 0 ]
}

@test "validate: asset_regex without asset_var rejected" {
  asset_yaml github-tag "  asset_regex: '^app-(.+)\\.tar\\.gz\$'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.asset_regex and upstream.asset_var go together"* ]]
}

@test "validate: asset_var without asset_regex rejected" {
  asset_yaml github-tag "  asset_var: _build"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.asset_regex and upstream.asset_var go together"* ]]
}

@test "validate: asset_regex of another strategy rejected" {
  asset_yaml github-nightly "  asset_regex: '^app-(.+)\\.tar\\.gz\$'
  asset_var: _build"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.asset_regex applies to the github-release and github-tag strategies only"* ]]
}

@test "validate: asset_regex without exactly one capture group rejected" {
  local regex
  for regex in '^app-.+\.tar\.gz$' '^app-(.+)-(x86_64)\.tar\.gz$'; do
    asset_yaml github-tag "  asset_regex: '$regex'
  asset_var: _build"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"upstream.asset_regex must be an ERE that bash accepts, with exactly one capture group: $regex"* ]]
  done
}

# bash refuses (?:x), which grep -E takes
@test "validate: asset_regex that bash does not accept rejected" {
  asset_yaml github-tag "  asset_regex: '(?:app)-(.+)'
  asset_var: _build"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.asset_regex must be an ERE that bash accepts, with exactly one capture group: (?:app)-(.+)"* ]]
  [[ "$output" != *"invalid regular expression"* ]]
}

# yq prints this map as x: (a), an ERE with one group
@test "validate: asset_regex that is not a string rejected" {
  asset_yaml github-tag "  asset_regex:
    x: (a)
  asset_var: _build"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream.asset_regex must be an ERE that bash accepts, with exactly one capture group"* ]]
}

# sed and awk read the name as part of a pattern
@test "validate: asset_var that is no name starting with _ rejected" {
  local var
  for var in build '_build;x' 'x;_build'; do
    asset_yaml github-tag "  asset_regex: '^app-(.+)\\.tar\\.gz\$'
  asset_var: '$var'"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"upstream.asset_var must be a name that starts with _: '$var'"* ]]
  done
}

@test "validate: current_asset that a PKGBUILD must not hold rejected" {
  asset_yaml github-tag "  asset_regex: '^app-(.+)\\.tar\\.gz\$'
  asset_var: _build" "current_asset: '~root'"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"current_asset must start with a letter or a digit and hold only A-Za-z0-9 . _ + ~ -: '~root'"* ]]
}

@test "validate: current_asset without asset_var rejected" {
  create_test_package "mypkg" "github-tag" "upstream:
  project: owner/repo
current_asset: 1.0-build7"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" "mypkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"current_asset needs upstream.asset_var"* ]]
}

# === Requirements that the requires rules read ===

# Helper: package demo of strategy github-release at current $1 with the YAML lines $2, whose AUR .SRCINFO
# has the depends after them
requires_package() {
  {
    printf 'pkgbase = demo\n\tpkgver = %s\n\tpkgrel = 1\n\tarch = any\n' "$1"
    printf '\tdepends = %s\n' "${@:3}"
    printf '\npkgname = demo\n'
  } >"$TEST_TMPDIR/demo.SRCINFO"
  rm -rf "$TEST_TMPDIR/aur-remote" "$TEST_TMPDIR"/aur-work-demo
  aur_srcinfo_remote demo "$TEST_TMPDIR/demo.SRCINFO"
  create_test_package "demo" "github-release" "upstream:
  project: o/demo
current: '$1'
$2"
}

# Packages added with Python or Ruby in depends would fail the check of their first new version
@test "validate: refuses a package whose AUR depends hold Python or Ruby without a source of requirements" {
  requires_package 1.1.0 "" bash python python-yaml
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/demo.yml: its depends hold Python packages, so set python.pypi, python.pyproject or python: none"* ]]
  requires_package 4.0.3 "" ruby ruby-simplecov
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/demo.yml: its depends hold Ruby packages, so set ruby.gem or ruby: none"* ]]
  requires_package 1.1.0 "python: none" bash python python-yaml
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" demo
  [ "$status" -eq 0 ]
  requires_package 1.1.0 "" bash glibc
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" demo
  [ "$status" -eq 0 ]
}

@test "validate: reads the requirements of the current release on PyPI and rubygems.org" {
  requires_package 1.1.0 $'python:\n  pypi: KubeDiagrams' bash python python-yaml
  pypi_fake KubeDiagrams 1.1.0 PyYAML
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" demo
  [ "$status" -eq 0 ]
  requires_package 1.2.0 $'python:\n  pypi: KubeDiagrams' bash python python-yaml
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"KubeDiagrams: PyPI has no release 1.2.0"* ]]
  pypi_fake_sdist KubeDiagrams 1.2.0 $'Metadata-Version: 2.1\nName: KubeDiagrams\nVersion: 1.2.0\n\n'
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"KubeDiagrams 1.2.0: PyPI holds no metadata that lists the requirements without running code"* ]]
  requires_package 4.0.3 $'ruby:\n  gem: bashcov' ruby ruby-simplecov
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" demo
  [ "$status" -eq 0 ]
  requires_package 9.9 $'ruby:\n  gem: bashcov' ruby ruby-simplecov
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"bashcov: rubygems.org has no release 9.9"* ]]
}

# --all checks every package of the repository, and a network failure is an error
@test "validate: --all reads nothing online, --all --online does, and a failure of the AUR is an error" {
  requires_package 1.1.0 "" bash python python-yaml
  export CURL_ARGS_LOG="$TEST_TMPDIR/curl-args"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all
  [ "$status" -eq 0 ]
  [ ! -e "$CURL_ARGS_LOG" ]
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --all --online
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/demo.yml: its depends hold Python packages, so set python.pypi, python.pyproject or python: none"* ]]
  [[ "$output" == *"Validation failed: 1/1 packages have errors"* ]]
  # The AUR serves an empty repository for a package it lacks, and git fails to clone this one
  rm -rf "$TEST_TMPDIR/aur-remote/demo.git"
  mkdir "$TEST_TMPDIR/aur-remote/demo.git"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" demo
  [ "$status" -eq 1 ]
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --online
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: validate-pkg.sh <package-name> | --all [--online] | --changed <list> | --requirements <names> [<results>]"* ]]
  local args
  for args in --changed "--changed $TEST_TMPDIR/a $TEST_TMPDIR/b" --requirements "--requirements a b c"; do
    # shellcheck disable=SC2086
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" $args
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage: validate-pkg.sh"* ]] || {
      echo "taken: $args"
      return 1
    }
  done
}

# validate.yml reads the requirements of every package when the pins move, and the AUR metadata
# file shows which packages have Python or Ruby in depends without a clone of each
@test "validate --requirements: checks the packages whose AUR depends hold Python or Ruby" {
  local names="$BATS_TEST_TMPDIR/names" meta
  requires_package 1.1.0 "" bash python python-yaml
  echo demo >"$names"
  # The .SRCINFO holds python, so a full check fails
  aur_meta '{"ID":1,"Name":"demo","PackageBaseID":7,"PackageBase":"demo","Depends":["bash","glibc>=2"]}'
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --requirements "$names"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Requirements of 1 packages read: 0 with Python or Ruby in AUR depends"* ]]
  for meta in '{"Name":"demo","PackageBase":"demo","Depends":["bash","python-yaml>=6"]}' \
    '{"Name":"demo","PackageBase":"demo","Depends":["python"]}' \
    '{"Name":"demo","PackageBase":"demo","Depends":["ruby"]}' \
    '{"Name":"demo","PackageBase":"demo"}'$'\n''{"Name":"demo-ruby","PackageBase":"demo","Depends":["ruby-rack"]}' \
    '{"Name":"other","PackageBase":"other","Depends":["bash"]}' \
    '{"Name":"demo","PackageBase":"demo","Depends":["a]b","python"]}' \
    '{"Name":"demo","PackageBase":"demo","Depends":["a\"],\"b","python"]}'; do
    aur_meta "$meta"
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" --requirements "$names"
    [ "$status" -eq 1 ] &&
      [[ "$output" == *"packages/demo.yml: its depends hold Python packages, so set python.pypi, python.pyproject or python: none"* ]] &&
      [[ "$output" == *"Requirements failed: 1/1 packages have errors"* ]] || {
      echo "screened out: $meta"
      echo "$output"
      return 1
    }
  done
  # validate.yml warns of the packages of a pin move that the push does not change, by the names in
  # the file of results
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --requirements "$names" "$BATS_TEST_TMPDIR/results"
  [ "$status" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/results")" = $'failed\tdemo' ]
  aur_meta '{"Name":"demo","PackageBase":"demo","Depends":["bash"]}'
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --requirements "$names" "$BATS_TEST_TMPDIR/results"
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/results" ]
}

# Without the metadata file each package gets the full check
@test "validate --requirements: checks every package when the AUR metadata file cannot be read" {
  local names="$BATS_TEST_TMPDIR/names" case
  requires_package 1.1.0 "" bash python python-yaml
  echo demo >"$names"
  for case in missing text cut; do
    case $case in
      missing) rm -f "$MOCK_FILES_DIR/packages-meta-ext-v1.json.gz" ;;
      text) echo '<html>' >"$MOCK_FILES_DIR/packages-meta-ext-v1.json.gz" ;;
      cut) printf '[\n{"Name":"demo","PackageBase":"demo","Depends":["bash"]},\n' | gzip >"$MOCK_FILES_DIR/packages-meta-ext-v1.json.gz" ;;
    esac
    run "$TEST_TMPDIR/scripts/validate-pkg.sh" --requirements "$names"
    [ "$status" -eq 1 ] &&
      [[ "$output" == *"https://aur.archlinux.org/packages-meta-ext-v1.json.gz could not be read, so every package gets the full check"* ]] &&
      [[ "$output" == *"packages/demo.yml: its depends hold Python packages"* ]] || {
      echo "taken: $case"
      echo "$output"
      return 1
    }
  done
}

# The step ends before timeout-minutes and names each package it did not check
@test "validate --requirements: names the packages left when its budget is used" {
  local names="$BATS_TEST_TMPDIR/names"
  requires_package 1.1.0 "python: none" bash python python-yaml
  create_test_package other github-release "upstream:
  project: o/other"
  printf '%s\n' demo other >"$names"
  aur_meta '{"Name":"demo","PackageBase":"demo","Depends":["python"]}' '{"Name":"other","PackageBase":"other","Depends":["ruby"]}'
  AURTOMATOR_VALIDATE_BUDGET=0 run "$TEST_TMPDIR/scripts/validate-pkg.sh" --requirements "$names"
  [ "$status" -eq 1 ]
  [[ "$output" == *"packages/demo.yml: not checked, as the check of requirements used its 0 s"* ]]
  [[ "$output" == *"packages/other.yml: not checked, as the check of requirements used its 0 s"* ]]
  [[ "$output" == *"Requirements failed: 0/2 packages have errors, and 2 were not checked"* ]]
  AURTOMATOR_VALIDATE_BUDGET=0 run "$TEST_TMPDIR/scripts/validate-pkg.sh" --requirements "$names" "$BATS_TEST_TMPDIR/results"
  [ "$status" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/results")" = $'unchecked\tdemo\nunchecked\tother' ]
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --requirements "$names"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Requirements of 2 packages read: 2 with Python or Ruby in AUR depends"* ]]
  printf '%s\n' demo ../demo >"$names"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --requirements "$names"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$names: '../demo' is no package name"* ]]
  # Pushes that change no package download nothing
  : >"$names"
  export CURL_ARGS_LOG="$BATS_TEST_TMPDIR/curl-args"
  run "$TEST_TMPDIR/scripts/validate-pkg.sh" --requirements "$names"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No package to check"* ]]
  [ ! -e "$CURL_ARGS_LOG" ]
}

# bash runs $(...) in an array subscript of (( )), so the budget matches a digit pattern first
@test "validate --requirements: refuses a budget from the environment that is no number of seconds" {
  local names="$BATS_TEST_TMPDIR/names" value
  printf 'demo\n' >"$names"
  for value in "BASH_VERSINFO[\$(touch $TEST_TMPDIR/pwned)]" 1.5 -1; do
    AURTOMATOR_VALIDATE_BUDGET=$value run "$TEST_TMPDIR/scripts/validate-pkg.sh" --requirements "$names"
    [ "$status" -eq 1 ]
    [[ "$output" == *"AURTOMATOR_VALIDATE_BUDGET must be a number of seconds: "* ]] || {
      echo "taken: $value"
      return 1
    }
  done
  [ ! -e "$TEST_TMPDIR/pwned" ]
}
