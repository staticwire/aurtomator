#!/usr/bin/env bash
#
# validate-pkg.sh - Check the syntax, the keys and the strategy fields of a package YAML, and online
# that the requires rules can read the requirements of its current version
#
# Usage: ./scripts/validate-pkg.sh <package-name>
#        ./scripts/validate-pkg.sh --all [--online]
#        ./scripts/validate-pkg.sh --changed <list>
#
# --all checks the syntax of every package alone, and with --online the requirements too.
# --changed checks the syntax of the packages that <list> names, as git diff -z prints them.

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq

# Every script in strategies/ is a strategy
VALID_STRATEGIES=()
for strategy_file in "${AURTOMATOR_DIR}"/strategies/*.sh; do
  [[ -f "$strategy_file" ]] || continue
  strategy_file="${strategy_file##*/}"
  VALID_STRATEGIES+=("${strategy_file%.sh}")
done
readonly VALID_STRATEGIES

# The top-level keys that the scripts read
readonly PACKAGE_KEYS="name strategy current last_updated current_asset pkgver_dash pkgver_format allow_downgrade allow_version_jump allow_missing_arch arch_wait arch_out cooldown_days alerts upstream python ruby"

# The upstream keys that each strategy reads, in the order of the strategy
# table of README.md. One test compares them with the keys the scripts name.
readonly UPSTREAM_KEYS=(
  "github-release: project tag_version_regex tag_version_replace asset_regex asset_var max_answer_mb"
  "github-tag: project tag_version_regex tag_version_replace asset_regex asset_var max_answer_mb"
  "github-nightly: project nightly_tag nightly_tag_regex channel version_source version_pattern date_format tag_version_regex tag_version_replace max_answer_mb"
  "github-asset: project tag assets max_answer_mb"
  "gitlab-tag: host project tag_version_regex tag_version_replace max_answer_mb"
  "gitea-tag: host project tag_version_regex tag_version_replace max_answer_mb"
  "gitea-release: host project tag_version_regex tag_version_replace max_answer_mb"
  "git-tag: url tag_version_regex tag_version_replace max_answer_mb"
  "git-latest: type url host project branch describe tag_prefix"
  "pypi: registry pin_from max_answer_mb"
  "npm: registry max_answer_mb"
  "crates: registry prerelease max_answer_mb"
  "rubygems: registry max_answer_mb"
  "repology: repology max_answer_mb"
  "archpkg: archpkg testing max_answer_mb"
  "webpage-scrape: url pattern user_agent max_answer_mb"
  "kde-tarball: project path max_answer_mb"
)

# Succeeds when $1 is one of the words of $2, split by spaces; a substring match would pass a
# key such as "name strategy"
in_words() {
  local words word
  read -ra words <<<"$2"
  for word in "${words[@]}"; do
    [[ "$word" != "$1" ]] || return 0
  done
  return 1
}

# Succeeds when field $2 of package file $1 is missing or a boolean that pkg_bool reads
flag_ok() {
  pkg_bool "$1" "$2" >/dev/null 2>&1
}

# Print the upstream keys of strategy $1, or fail when UPSTREAM_KEYS has no line for it
upstream_keys() {
  local line
  for line in "${UPSTREAM_KEYS[@]}"; do
    if [[ "${line%%:*}" == "$1" ]]; then
      printf '%s\n' "${line#*: }"
      return 0
    fi
  done
  return 1
}

# Print the strategies that read upstream key $1, as "the git-latest strategy" or "the
# github-release and github-tag strategies", or fail when no strategy reads it
key_strategies() {
  local line names=() list i
  for line in "${UPSTREAM_KEYS[@]}"; do
    ! in_words "$1" "${line#*: }" || names+=("${line%%:*}")
  done
  case ${#names[@]} in
    0) return 1 ;;
    1) printf 'the %s strategy\n' "${names[0]}" ;;
    *)
      list="${names[0]}"
      for ((i = 1; i < ${#names[@]} - 1; i++)); do
        list+=", ${names[i]}"
      done
      printf 'the %s and %s strategies\n' "$list" "${names[-1]}"
      ;;
  esac
}

# Prints packages/ and the name of package file $1, quoted outside the pattern of package names, since
# a pull request can name a file with a line break and a workflow command
shown_file() {
  local LC_ALL=C name="${1##*/}"
  [[ "$name" =~ ^[a-z0-9][a-z0-9.+_-]*\.yml$ ]] || name=${name@Q}
  printf 'packages/%s\n' "$name"
}

# Check the python key of package file $1 of strategy $2: none, or a map of the source keys pypi,
# release and pyproject, map, from PyPI names to package names, and skip, paths that imports leaves out
validate_python() {
  local file="$1" shown errors=0 key value unknown path pypi pyproject
  shown=$(shown_file "$file")
  case $(pkg_get "$file" '.python | tag') in
    "!!null") return 0 ;;
    "!!map") ;;
    *)
      [[ "$(pkg_get "$file" '.python | select(tag == "!!str")')" != none ]] || return 0
      log_err "$shown: python must be none or a map"
      return 1
      ;;
  esac
  pypi=$(pkg_get "$file" '.python.pypi // ""')
  pyproject=$(pkg_get "$file" '.python.pyproject // ""')
  if [[ -n "$pypi" ]] && ! pypi_name "$pypi" >/dev/null; then
    log_err "$shown: python.pypi must be a PyPI project name of A-Za-z0-9._- that starts and ends with a letter or digit: ${pypi@Q}"
    errors=1
  fi
  value=$(pkg_get "$file" '.python.release // ""')
  if [[ -n "$value" && "$value" != newest ]]; then
    log_err "$shown: python.release must be newest: ${value@Q}"
    errors=1
  elif [[ -n "$value" && -z "$pypi" ]]; then
    log_err "$shown: python.release applies with python.pypi alone"
    errors=1
  fi
  if [[ -n "$pyproject" ]] && { ! (LC_ALL=C && [[ "$pyproject" =~ ^[A-Za-z0-9._/-]+\.toml$ ]]) ||
    [[ "$pyproject" == /* || "/$pyproject/" == */../* ]]; }; then
    log_err "$shown: python.pyproject must be a relative path to a .toml file without ..: ${pyproject@Q}"
    errors=1
  fi
  if [[ -n "$pypi" && -n "$pyproject" ]]; then
    log_err "$shown: python.pypi and python.pyproject exclude each other"
    errors=1
  fi
  if [[ "$2" == pypi && -n "$pypi$pyproject$value" ]]; then
    log_err "$shown: python.pypi, python.release and python.pyproject do not apply to the pypi strategy, which reads upstream.registry"
    errors=1
  fi
  unknown=$(pkg_get "$file" '.python | [keys[] | select(. != "map" and . != "skip" and . != "pypi" and . != "release" and . != "pyproject")] | join(", ")')
  if [[ -n "$unknown" ]]; then
    log_err "$shown: python: unknown key: $unknown"
    errors=1
  fi
  case $(pkg_get "$file" '.python.map | tag') in
    "!!null") ;;
    "!!map")
      while IFS=$'\t' read -r key value; do
        if ! pypi_name "$key" >/dev/null; then
          log_err "$shown: python.map: ${key@Q} is not a PyPI name"
          errors=1
        elif ! (LC_ALL=C && [[ "$value" =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ ]]); then
          log_err "$shown: python.map.$key must be a package name of a-z, 0-9 and @ . _ + -: ${value@Q}"
          errors=1
        fi
      done < <(pkg_get "$file" '.python.map | to_entries[] | [.key, ((.value | select(tag == "!!str")) // (.value | to_json(0)))] | join("\t")')
      ;;
    *)
      log_err "$shown: python.map must be a map of PyPI names to package names"
      errors=1
      ;;
  esac
  case $(pkg_get "$file" '.python.skip | tag') in
    "!!null") ;;
    "!!seq")
      while IFS= read -r path; do
        if [[ -z "$path" || "$path" == /* || "/$path/" == */../* ]]; then
          log_err "$shown: python.skip: ${path@Q} must be a relative path without .."
          errors=1
        fi
      done < <(pkg_get "$file" '.python.skip[] | (select(tag == "!!str") // to_json(0))')
      ;;
    *)
      log_err "$shown: python.skip must be a list of relative paths"
      errors=1
      ;;
  esac
  return "$errors"
}

# Check the ruby key of package file $1 of strategy $2: none, or a map of gem, the source of the
# requirements, map, skip and relax, true when the PKGBUILD turns ~> into >=
validate_ruby() {
  local file="$1" shown errors=0 key value unknown
  shown=$(shown_file "$file")
  case $(pkg_get "$file" '.ruby | tag') in
    "!!null") return 0 ;;
    "!!map") ;;
    *)
      [[ "$(pkg_get "$file" '.ruby | select(tag == "!!str")')" != none ]] || return 0
      log_err "$shown: ruby must be none or a map"
      return 1
      ;;
  esac
  value=$(pkg_get "$file" '.ruby.gem // ""')
  if [[ -n "$value" ]] && ! (LC_ALL=C && [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]); then
    log_err "$shown: ruby.gem must be a gem name of A-Za-z0-9._- that starts with a letter or digit: ${value@Q}"
    errors=1
  elif [[ -n "$value" && "$2" == rubygems ]]; then
    log_err "$shown: ruby.gem does not apply to the rubygems strategy, which reads upstream.registry"
    errors=1
  fi
  unknown=$(pkg_get "$file" '.ruby | [keys[] | select(. != "gem" and . != "map" and . != "skip" and . != "relax")] | join(", ")')
  if [[ -n "$unknown" ]]; then
    log_err "$shown: ruby: unknown key: $unknown"
    errors=1
  fi
  case $(pkg_get "$file" '.ruby.map | tag') in
    "!!null") ;;
    "!!map")
      while IFS=$'\t' read -r key value; do
        if ! (LC_ALL=C && [[ "$key" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]); then
          log_err "$shown: ruby.map: ${key@Q} is not a gem name"
          errors=1
        elif ! (LC_ALL=C && [[ "$value" =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ ]]); then
          log_err "$shown: ruby.map.$key must be a package name of a-z, 0-9 and @ . _ + -: ${value@Q}"
          errors=1
        fi
      done < <(pkg_get "$file" '.ruby.map | to_entries[] | [.key, ((.value | select(tag == "!!str")) // (.value | to_json(0)))] | join("\t")')
      ;;
    *)
      log_err "$shown: ruby.map must be a map of gem names to package names"
      errors=1
      ;;
  esac
  case $(pkg_get "$file" '.ruby.skip | tag') in
    "!!null") ;;
    "!!seq")
      while IFS= read -r value; do
        if ! (LC_ALL=C && [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]); then
          log_err "$shown: ruby.skip: ${value@Q} is not a gem name"
          errors=1
        fi
      done < <(pkg_get "$file" '.ruby.skip[] | (select(tag == "!!str") // to_json(0))')
      ;;
    *)
      log_err "$shown: ruby.skip must be a list of gem names"
      errors=1
      ;;
  esac
  if ! flag_ok "$file" .ruby.relax; then
    log_err "$shown: ruby.relax must be true or false"
    errors=1
  fi
  return "$errors"
}

# Check entry $2 of the alerts of package file $1, with pkgver_format $3 if any, strategy $4
# and pkgver_dash set when $5 is true; the errors go to stderr
validate_alert() {
  local file="$1" i="$2" format="$3" rule errors=0 unknown tag value requires
  rule="$(shown_file "$file"): alerts[$2]"
  if [[ $(pkg_get "$file" ".alerts[$i] | tag") != "!!map" ]]; then
    log_err "$rule must be a map with note and one of when, from, match, requires"
    return 1
  fi
  unknown=$(pkg_get "$file" ".alerts[$i] | [keys[] | select(. != \"when\" and . != \"from\" and . != \"match\" and . != \"requires\" and . != \"note\" and . != \"hold\")] | join(\", \")")
  if [[ -n "$unknown" ]]; then
    log_err "$rule: unknown key: $unknown"
    errors=1
  fi
  if [[ $(pkg_get "$file" ".alerts[$i] | [keys[] | select(. == \"when\" or . == \"from\" or . == \"match\" or . == \"requires\")] | length") != 1 ]]; then
    log_err "$rule must hold exactly one of when, from, match, requires"
    errors=1
  fi

  # changed compares the releases of current and the new version on PyPI, so current takes
  # the spelling of PyPI, which pkgver_format and pkgver_dash change
  tag=$(pkg_get "$file" ".alerts[$i].requires | tag")
  value=$(pkg_get "$file" ".alerts[$i].requires")
  requires=$value
  if [[ "$tag" != "!!null" && "$value" != changed && "$value" != unmet && "$value" != imports ]]; then
    log_err "$rule.requires must be changed, unmet or imports, got $value"
    errors=1
  elif [[ "$tag" != "!!null" && "$4" != pypi && "$4" != rubygems &&
    -z "$(pkg_get "$file" '(.python | select(tag == "!!map") | .pypi // .pyproject) // (.ruby | select(tag == "!!map") | .gem) // ""')" ]]; then
    log_err "$rule: requires needs strategy pypi or rubygems, python.pypi, python.pyproject or ruby.gem"
    errors=1
  elif [[ "$value" == changed && -n "$(pkg_get "$file" '.python | select(tag == "!!map") | .release // .pyproject // ""')" ]]; then
    log_err "$rule: requires: changed does not apply with python.release or python.pyproject"
    errors=1
  elif [[ "$value" == changed && -n "$format" ]]; then
    log_err "$rule: requires does not apply with pkgver_format"
    errors=1
  elif [[ "$value" == changed && "$5" == true ]]; then
    log_err "$rule: requires does not apply with pkgver_dash"
    errors=1
  fi

  tag=$(pkg_get "$file" ".alerts[$i].when | tag")
  value=$(pkg_get "$file" ".alerts[$i].when")
  if [[ "$tag" != "!!null" && "$value" != major ]]; then
    log_err "$rule.when must be major, got $value"
    errors=1
  # The fixed text of a format such as 4.%s holds the first number
  elif [[ "$tag" != "!!null" && -n "$format" ]]; then
    log_err "$rule: when: major does not apply with pkgver_format"
    errors=1
  fi

  tag=$(pkg_get "$file" ".alerts[$i].from | tag")
  value=$(pkg_get "$file" ".alerts[$i].from")
  if [[ "$tag" != "!!null" ]] && ! validate_pkgver "$value" 2>/dev/null; then
    log_err "$rule.from must be a version of at most 64 characters of A-Za-z0-9 . _ + with a digit: $value"
    errors=1
  fi

  tag=$(pkg_get "$file" ".alerts[$i].match | tag")
  value=$(pkg_get "$file" ".alerts[$i].match")
  if [[ "$tag" != "!!null" ]] && { [[ "$tag" != "!!str" || -z "$value" ]] || ! ere_valid "$value"; }; then
    log_err "$rule.match must be a non-empty ERE that bash accepts: $value"
    errors=1
  fi

  # requires rules note the change of the requirements, and a note of their own is optional
  if [[ $(pkg_get "$file" ".alerts[$i] | (has(\"note\") or (has(\"requires\") | not))") == true ]] &&
    ! alert_note "$file" "$i" >/dev/null; then
    log_err "$rule.$(alert_note_error "$file" "$i")"
    errors=1
  fi

  if ! flag_ok "$file" ".alerts[$i].hold"; then
    log_err "$rule.hold must be true or false"
    errors=1
  elif [[ "$requires" == imports && "$(pkg_bool "$file" ".alerts[$i].hold" 2>/dev/null)" == true ]]; then
    log_err "$rule.hold does not apply to requires: imports"
    errors=1
  fi

  return "$errors"
}

# Check one package YAML file; the errors go to stderr
validate_pkg() {
  # Bash bracket ranges take more than ASCII under UTF-8 locales other than C.UTF-8
  local -x LC_ALL=C
  local file="$1"
  local errors=0
  # The messages name the file in the data directory, as the user sees it
  local shown
  shown=$(shown_file "$file")

  # --- YAML syntax ---
  if ! yq '.' "$file" >/dev/null 2>&1; then
    log_err "Invalid YAML syntax: $shown"
    return 1
  fi
  if [[ $(pkg_get "$file" 'tag') != "!!map" ]]; then
    log_err "$shown must be a map of fields"
    return 1
  fi
  # yq ends a line at these characters and a diff does not, so a review can read a key
  # as part of a comment; a CR before a newline ends a line for both
  if grep -q -e $'\r.' -e $'\xc2\x85' -e $'\xe2\x80\xa8' -e $'\xe2\x80\xa9' "$file"; then
    log_err "$shown holds a carriage return inside a line, a NEL, a U+2028 or a U+2029, which yq reads as a line break"
    return 1
  fi
  # yq reads the last of two equal keys, and a review reads the first
  if [[ $(yq '[.. | select(tag == "!!map") | select((keys | length) != (keys | unique | length))] | length' "$file") != 0 ]]; then
    log_err "$shown holds a key twice in one mapping"
    return 1
  fi
  # The messages print keys and values, and a terminal takes a control character as a
  # command; yq -r prints the text of a scalar of any tag, so the check reads them as text
  if [[ $(CONTROL_RE='[\x00-\x08\x0a-\x1f\x7f\x{80}-\x{9f}]' yq \
    '[... | select(kind == "scalar") | (. tag = "!!str") | select(test(strenv(CONTROL_RE)))] | length' "$file") != 0 ]]; then
    log_err "$shown: a key or a value holds a control character"
    return 1
  fi
  # Diffs show no zero-width or bidi character, so values outside the notes for people are printable
  # ASCII or tabs, and notes hold no format character, blank letter, lone mark or space but U+0020
  local hidden note_path='^alerts[.][0-9]+[.]note$'
  hidden=$(NOTE_PATH="$note_path" ASCII_RE='[^\t -~]' yq -r '[... | select(kind == "scalar") | (. tag = "!!str")
    | select(path | join(".") | test(strenv(NOTE_PATH)) | not) | select(test(strenv(ASCII_RE)))] | length' "$file")
  if [[ "$hidden" != 0 ]]; then
    log_err "$shown: a key or a value outside alerts[].note holds a character other than printable ASCII and tab"
    return 1
  fi
  # Hangul fillers, the blank Braille pattern and variation selectors show nothing, and the emoji
  # form takes a symbol before it; combining marks after a space or at the start stand alone
  local blank='\x{115F}\x{1160}\x{3164}\x{FFA0}\x{2800}\x{1D159}\x{034F}\x{FE00}-\x{FE0E}\x{E0100}-\x{E01EF}'
  hidden=$(NOTE_PATH="$note_path" HIDDEN_RE="[\\p{Cf}\\p{Zl}\\p{Zp}$blank]|[^ \\P{Zs}]|(^|[^\\p{So}])\\x{FE0F}|(^|\\s)\\p{Mn}" yq -r '[... | select(kind == "scalar") | (. tag = "!!str")
    | select(path | join(".") | test(strenv(NOTE_PATH))) | select(test(strenv(HIDDEN_RE)))] | length' "$file")
  if [[ "$hidden" != 0 ]]; then
    log_err "$shown: alerts[].note holds a format character, a blank letter or mark, or a space other than U+0020"
    return 1
  fi

  local name strategy
  name=$(pkg_get "$file" '.name // ""')
  strategy=$(pkg_get "$file" '.strategy // ""')

  # --- Required core fields ---
  # check-all.sh finds a package by its name, never by its file
  local stem="${file##*/}"
  stem="${stem%.yml}"
  if [[ -z "$name" || "$name" == "null" ]]; then
    log_err "$shown: missing required field 'name'"
    ((errors++))
  elif [[ ! "$name" =~ ^[a-z0-9][a-z0-9.+_-]*$ ]]; then
    log_err "$shown: name ${name@Q} must start with a-z or 0-9 and hold only a-z, 0-9 and . _ + -"
    ((errors++))
  elif [[ "$name" != "$stem" ]]; then
    log_err "$shown: name ${name@Q} must equal the file name ${stem@Q}"
    ((errors++))
  fi

  if [[ -z "$strategy" || "$strategy" == "null" ]]; then
    log_err "$shown: missing required field 'strategy'"
    ((errors++))
    # Strategy-specific fields cannot be checked without a strategy
    return 1
  fi

  # --- Valid strategy name ---
  local valid=false
  for s in "${VALID_STRATEGIES[@]}"; do
    if [[ "$strategy" == "$s" ]]; then
      valid=true
      break
    fi
  done
  if [[ "$valid" == "false" ]]; then
    log_err "$shown: unknown strategy '$strategy' (valid: ${VALID_STRATEGIES[*]})"
    ((errors++))
    return 1
  fi

  # --- Keys that no script reads ---

  local keys key unknown=() list strategy_keys where
  mapfile -t keys < <(pkg_get "$file" 'keys | .[]')
  for key in "${keys[@]}"; do
    in_words "$key" "$PACKAGE_KEYS" || unknown+=("$key")
  done
  if ((${#unknown[@]} > 0)); then
    printf -v list '%s, ' "${unknown[@]}"
    log_err "$shown: unknown key: ${list%, }"
    ((errors++))
  fi

  if [[ $(pkg_get "$file" '.upstream | tag') =~ ^!!(null|map)$ ]]; then
    mapfile -t keys < <(pkg_get "$file" '.upstream // {} | keys | .[]')
  else
    log_err "$shown: upstream must be a map"
    return 1
  fi
  if ((${#keys[@]} > 0)) && ! strategy_keys=$(upstream_keys "$strategy"); then
    log_err "$shown: validate-pkg.sh lists no upstream keys for the strategy $strategy"
    ((errors++))
  elif ((${#keys[@]} > 0)); then
    for key in "${keys[@]}"; do
      ! in_words "$key" "$strategy_keys" || continue
      if where=$(key_strategies "$key"); then
        log_err "$shown: upstream.$key applies to $where only"
      else
        log_err "$shown: upstream.$key is not a field of any strategy"
      fi
      ((errors++))
    done
  fi

  # --- Optional fields ---

  local flag
  for flag in allow_downgrade allow_version_jump allow_missing_arch; do
    if ! flag_ok "$file" ".$flag"; then
      log_err "$shown: $flag must be true or false"
      ((errors++))
    fi
  done

  local answer_tag answer_mb
  answer_tag=$(pkg_get "$file" '.upstream.max_answer_mb | tag')
  if [[ "$answer_tag" != "!!null" ]]; then
    answer_mb=$(pkg_get "$file" '.upstream.max_answer_mb')
    if [[ "$answer_tag" != "!!int" || ! "$answer_mb" =~ ^[1-9][0-9]{0,2}$ ]] || ((answer_mb > 500)); then
      log_err "$shown: upstream.max_answer_mb must be a whole number from 1 to 500"
      ((errors++))
    fi
  fi

  local cooldown_tag cooldown_days
  cooldown_tag=$(pkg_get "$file" '.cooldown_days | tag')
  if [[ "$cooldown_tag" != "!!null" ]]; then
    cooldown_days=$(pkg_get "$file" '.cooldown_days')
    if [[ "$cooldown_tag" != "!!int" || ! "$cooldown_days" =~ ^(0|[1-9][0-9]{0,2})$ ]] || ((cooldown_days > 365)); then
      log_err "$shown: cooldown_days must be a whole number from 0 to 365"
      ((errors++))
    fi
  fi

  # '' drops the dash, so pkgver_dash counts as set when it is empty
  local pkgver_dash="" dash_set=false
  if [[ $(pkg_get "$file" '.pkgver_dash | tag') != "!!null" ]]; then
    dash_set=true
    pkgver_dash=$(pkg_get "$file" '.pkgver_dash')
    if [[ "$pkgver_dash" != "_" && "$pkgver_dash" != "." && -n "$pkgver_dash" ]]; then
      log_err "$shown: pkgver_dash must be _, . or ''"
      ((errors++))
    fi
  fi

  local current_value
  current_value=$(pkg_get "$file" '.current // ""')
  if [[ -n "$current_value" ]] && ! validate_pkgver "$current_value" 2>/dev/null; then
    log_err "$shown: current must hold a digit and at most 64 characters of A-Za-z0-9 . _ +: ${current_value@Q}"
    ((errors++))
  fi

  # Future dates hold the cooldown of the package until they pass
  local last_updated
  last_updated=$(pkg_get "$file" '.last_updated // ""')
  if [[ -n "$last_updated" ]] && ! valid_date "$last_updated"; then
    log_err "$shown: last_updated must be a date YYYY-MM-DD: ${last_updated@Q}"
    ((errors++))
  elif [[ "$last_updated" > "$(date -u +%F)" ]]; then
    log_err "$shown: last_updated is later than today: $last_updated"
    ((errors++))
  fi

  local out_tag arch commit
  out_tag=$(pkg_get "$file" '.arch_out | tag')
  if [[ "$out_tag" == "!!map" ]]; then
    mapfile -t keys < <(pkg_get "$file" '.arch_out | keys | .[]')
    for arch in "${keys[@]}"; do
      commit=$(ARCH="$arch" yq -r '.arch_out[strenv(ARCH)]' "$file")
      if [[ ! "$arch" =~ ^[a-z0-9_]+$ ]]; then
        log_err "$shown: arch_out: an arch name may hold a-z0-9_ only: ${arch@Q}"
        ((errors++))
      elif [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
        log_err "$shown: arch_out.$arch must be a commit id of 40 hex digits: ${commit@Q}"
        ((errors++))
      fi
    done
  elif [[ "$out_tag" != "!!null" ]]; then
    log_err "$shown: arch_out must be a map of arch names to commit ids"
    ((errors++))
  fi

  local wait_tag wait_keys wait_version since wait_commit wait_arches
  wait_tag=$(pkg_get "$file" '.arch_wait | tag')
  [[ "$wait_tag" != "!!map" ]] || wait_keys=$(pkg_get "$file" '.arch_wait | keys | sort | join(" ")')
  if [[ "$wait_tag" != "!!null" ]]; then
    if [[ "$wait_tag" != "!!map" || ("$wait_keys" != "since version" && "$wait_keys" != "arches commit since version") ]]; then
      log_err "$shown: arch_wait must be a map with version and since, or version, since, commit and arches, and no other key"
      ((errors++))
    else
      if [[ "$wait_keys" == "arches commit since version" ]]; then
        wait_commit=$(pkg_get "$file" '.arch_wait.commit')
        wait_arches=$(pkg_get "$file" '.arch_wait.arches')
        if [[ ! "$wait_commit" =~ ^[0-9a-f]{40}$ ]]; then
          log_err "$shown: arch_wait.commit must be a commit id of 40 hex digits: ${wait_commit@Q}"
          ((errors++))
        fi
        if [[ -z "$wait_arches" ]] || ! arch_list_ok "$wait_arches"; then
          log_err "$shown: arch_wait.arches must name arches other than x86_64, separated by single spaces: ${wait_arches@Q}"
          ((errors++))
        fi
      fi
      wait_version=$(pkg_get "$file" '.arch_wait.version')
      since=$(pkg_get "$file" '.arch_wait.since')
      if ! validate_pkgver "$wait_version" 2>/dev/null; then
        log_err "$shown: arch_wait.version must hold a digit and at most 64 characters of A-Za-z0-9 . _ +: ${wait_version@Q}"
        ((errors++))
      fi
      if ! valid_time "$since"; then
        log_err "$shown: arch_wait.since must be a UTC time YYYY-MM-DDTHH:MM:SSZ: ${since@Q}"
        ((errors++))
      elif [[ "$since" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]]; then
        log_err "$shown: arch_wait.since is later than now: $since"
        ((errors++))
      fi
    fi
  fi

  local pkgver_format="" formatted
  if [[ $(pkg_get "$file" '.pkgver_format | tag') != "!!null" ]]; then
    pkgver_format=$(pkg_get "$file" '.pkgver_format')
    formatted=$(pkg_get "$file" '.current // ""')
    if [[ ! "$pkgver_format" =~ ^[A-Za-z0-9._+]*%s[A-Za-z0-9._+]*$ ]]; then
      log_err "$shown: pkgver_format must hold %s once, with only A-Za-z0-9 . _ + around it"
      ((errors++))
    elif [[ -n "$formatted" && -z "$(_unformat_version "$formatted" "$pkgver_format")" ]]; then
      log_err "$shown: current $formatted does not fit pkgver_format $pkgver_format"
      ((errors++))
    fi
  fi

  local alerts_tag alert_count i
  alerts_tag=$(pkg_get "$file" '.alerts | tag')
  if [[ "$alerts_tag" == "!!seq" ]]; then
    alert_count=$(pkg_get "$file" '.alerts | length')
    for ((i = 0; i < alert_count; i++)); do
      validate_alert "$file" "$i" "$pkgver_format" "$strategy" "$dash_set" || ((errors++))
    done
    local -A requires_seen=()
    local value
    while IFS=$'\t' read -r i value; do
      [[ -n "$value" ]] || continue
      if [[ -n "${requires_seen[$value]:-}" ]]; then
        log_err "$shown: alerts[$i].requires: $value is set twice"
        ((errors++))
      fi
      requires_seen[$value]=1
    done < <(pkg_get "$file" '.alerts | to_entries[] | select((.value | tag) == "!!map" and (.value | has("requires")) and (.value.requires | tag) == "!!str") | [(.key | tostring), .value.requires] | join("\t")')
  elif [[ "$alerts_tag" != "!!null" ]]; then
    log_err "$shown: alerts must be a list"
    ((errors++))
  fi

  validate_python "$file" "$strategy" || ((errors++))
  validate_ruby "$file" "$strategy" || ((errors++))

  local branch
  if [[ $(pkg_get "$file" '.upstream.branch | tag') != "!!null" ]]; then
    branch=$(pkg_get "$file" '.upstream.branch')
    # git clone would read a name that starts with - as an option
    if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
      log_err "$shown: upstream.branch is not a valid branch name: $branch"
      ((errors++))
    fi
  fi

  local describe=""
  if [[ $(pkg_get "$file" '.upstream.describe | tag') != "!!null" ]]; then
    describe=$(pkg_get "$file" '.upstream.describe')
    if [[ "$describe" != tags && "$describe" != annotated ]]; then
      log_err "$shown: upstream.describe must be tags or annotated: $describe"
      ((errors++))
    fi
  fi

  local tag_prefix
  if [[ $(pkg_get "$file" '.upstream.tag_prefix | tag') != "!!null" ]]; then
    tag_prefix=$(pkg_get "$file" '.upstream.tag_prefix')
    if [[ -z "$describe" ]]; then
      log_err "$shown: upstream.tag_prefix applies with upstream.describe only"
      ((errors++))
    elif [[ ! "$tag_prefix" =~ ^[A-Za-z0-9._+/-]+$ ]]; then
      log_err "$shown: upstream.tag_prefix may hold A-Za-z0-9._+/- only: $tag_prefix"
      ((errors++))
    fi
  fi

  local nightly_tag_regex
  nightly_tag_regex=$(pkg_get "$file" '.upstream.nightly_tag_regex // ""')
  if [[ -n "$nightly_tag_regex" ]]; then
    if [[ $(pkg_get "$file" '.upstream | (has("nightly_tag") or has("channel"))') == true ]]; then
      log_err "$shown: upstream.nightly_tag_regex takes the place of nightly_tag and channel"
      ((errors++))
    elif ! ere_valid "$nightly_tag_regex"; then
      log_err "$shown: upstream.nightly_tag_regex is not valid ERE regex: $nightly_tag_regex"
      ((errors++))
    fi
  fi

  if ! flag_ok "$file" .upstream.prerelease; then
    log_err "$shown: upstream.prerelease must be true or false"
    ((errors++))
  # Semver pre-releases always hold a dash
  elif [[ $(pkg_bool "$file" .upstream.prerelease 2>/dev/null) == true && "$dash_set" == false ]]; then
    log_err "$shown: upstream.prerelease needs pkgver_dash"
    ((errors++))
  fi

  if ! flag_ok "$file" .upstream.testing; then
    log_err "$shown: upstream.testing must be true or false"
    ((errors++))
  fi

  # --- Strategy-specific fields ---

  # Validate optional tag_version_regex
  local tag_version_regex
  tag_version_regex=$(pkg_get "$file" '.upstream.tag_version_regex // ""')
  if [[ -n "$tag_version_regex" && "$tag_version_regex" != "null" ]]; then
    if [[ "$strategy" == "github-nightly" && $(pkg_get "$file" '.upstream.version_source // "tag"') != "tag" ]]; then
      log_err "$shown: upstream.tag_version_regex applies to version_source tag only"
      ((errors++))
    # The regex needs a capture group
    elif ! echo "$tag_version_regex" | grep -qE '\([^)]*\)'; then
      log_err "$shown: upstream.tag_version_regex must contain a capture group (): $tag_version_regex"
      ((errors++))
    # tag_versions needs a regex that bash compiles
    elif ! ere_valid "$tag_version_regex"; then
      log_err "$shown: upstream.tag_version_regex is not valid ERE regex: $tag_version_regex"
      ((errors++))
    fi
  fi

  local tag_version_replace
  tag_version_replace=$(pkg_get "$file" '.upstream.tag_version_replace // ""')
  if [[ -n "$tag_version_replace" ]]; then
    if [[ "$strategy" == "github-nightly" && $(pkg_get "$file" '.upstream.version_source // "tag"') != "tag" ]]; then
      log_err "$shown: upstream.tag_version_replace applies to version_source tag only"
      ((errors++))
    elif [[ -z "$tag_version_regex" ]]; then
      log_err "$shown: upstream.tag_version_replace needs upstream.tag_version_regex"
      ((errors++))
    elif [[ ! "$tag_version_replace" =~ ^([A-Za-z0-9._+]|\\[1-9p])+$ ]]; then
      log_err "$shown: upstream.tag_version_replace may hold only A-Za-z0-9 . _ +, \\1 to \\9 and \\p: $tag_version_replace"
      ((errors++))
    elif [[ "$strategy" != "github-nightly" && "$tag_version_replace" == *'\p'* ]]; then
      log_err "$shown: upstream.tag_version_replace holds \\p, which only github-nightly fills"
      ((errors++))
    # $regex|^ fills BASH_REMATCH with every group from the empty string and 0 stands for
    # the time of \p, so tag_version_fill finds a missing group as it does at run time
    elif ere_valid "$tag_version_regex" &&
      ! { [[ "" =~ $tag_version_regex|^ ]] && tag_version_fill "$tag_version_replace" 0 >/dev/null 2>&1; }; then
      log_err "$shown: upstream.tag_version_replace names a group tag_version_regex does not have: $tag_version_replace"
      ((errors++))
    fi
  fi

  # Value from a release asset name, see https://aurtomator.dev/features/asset-values/;
  # $regex|^ matches the empty string and fills BASH_REMATCH with every group of the regex
  local asset_regex_tag asset_var_tag asset_regex current_asset groups=0
  asset_regex_tag=$(pkg_get "$file" '.upstream.asset_regex | tag')
  asset_var_tag=$(pkg_get "$file" '.upstream.asset_var | tag')
  if [[ "$asset_regex_tag" != "!!null" || "$asset_var_tag" != "!!null" ]]; then
    asset_regex=$(pkg_get "$file" '.upstream.asset_regex')
    if [[ "$asset_regex_tag" == "!!str" ]] && ere_valid "$asset_regex" && [[ "" =~ $asset_regex|^ ]]; then
      groups=$((${#BASH_REMATCH[@]} - 1))
    fi
    if [[ "$asset_regex_tag" == "!!null" || "$asset_var_tag" == "!!null" ]]; then
      log_err "$shown: upstream.asset_regex and upstream.asset_var go together"
      ((errors++))
    elif ((groups != 1)); then
      log_err "$shown: upstream.asset_regex must be an ERE that bash accepts, with exactly one capture group: $asset_regex"
      ((errors++))
    fi
    pkg_asset_var "$file" >/dev/null || ((errors++))
  fi
  if [[ $(pkg_get "$file" '.current_asset | tag') != "!!null" ]]; then
    current_asset=$(pkg_get "$file" '.current_asset')
    if [[ "$asset_var_tag" == "!!null" ]]; then
      log_err "$shown: current_asset needs upstream.asset_var"
      ((errors++))
    elif ! validate_asset_value "$current_asset" 2>/dev/null; then
      log_err "$shown: current_asset must start with a letter or a digit and hold only A-Za-z0-9 . _ + ~ -: ${current_asset@Q}"
      ((errors++))
    fi
  fi

  local date_format version_source sample width_re='%[-_0^#+]*[1-9]'
  date_format=$(pkg_get "$file" '.upstream.date_format')
  # date pads a field to any width it is given
  if [[ "$date_format" != "null" ]] && { ((${#date_format} > 32)) || [[ "$date_format" =~ $width_re ]]; }; then
    log_err "$shown: upstream.date_format must hold at most 32 characters and no field width such as %10d: ${date_format@Q}"
    ((errors++))
  elif [[ "$date_format" != "null" ]]; then
    version_source=$(pkg_get "$file" '.upstream.version_source // "tag"')
    sample=$(date -u -d 2026-01-02 +"$date_format")
    if [[ "$version_source" != "tag_date" && "$version_source" != "published_date" &&
      ! ("$version_source" == "tag" && "$tag_version_replace" == *'\p'*) ]]; then
      log_err "$shown: upstream.date_format applies to version_source tag_date and published_date and to \\p in tag_version_replace"
      ((errors++))
    elif ! validate_pkgver "$sample" 2>/dev/null; then
      log_err "$shown: upstream.date_format must give a valid version, it gives ${sample@Q}"
      ((errors++))
    fi
  fi

  # Strategies put these fields into URL paths, where dot segments and characters such as
  # [ ? # change the request
  local field value bad_ref='[[:space:][:cntrl:]~^:?*[\]'
  for field in project registry pin_from tag nightly_tag repology archpkg; do
    value=$(pkg_get "$file" ".upstream.$field // \"\"")
    [[ -n "$value" && "$value" != "null" ]] || continue
    case "$field" in
      # kde-tarball takes tarball names, which its own rule below holds
      project)
        [[ "$strategy" != kde-tarball ]] || continue
        if [[ ! "$value" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ || "/$value/" == */./* || "/$value/" == */../* ]]; then
          log_err "$shown: upstream.project must be names of A-Za-z0-9._- joined by /, none of them . or ..: ${value@Q}"
          ((errors++))
        fi
        ;;
      registry)
        if [[ ! "$value" =~ ^(@[A-Za-z0-9._~-]+/)?[A-Za-z0-9._~-]+$ || "/${value#@}/" == */./* || "/${value#@}/" == */../* ]]; then
          log_err "$shown: upstream.registry must be a package name of A-Za-z0-9._~-, after an @scope/ at most, neither of them . or ..: ${value@Q}"
          ((errors++))
        fi
        ;;
      pin_from)
        if ! pypi_name "$value" >/dev/null; then
          log_err "$shown: upstream.pin_from must be a PyPI project name of A-Za-z0-9._- that starts and ends with a letter or digit: ${value@Q}"
          ((errors++))
        fi
        ;;
      # Repology names prefix some projects, as in ruby:rmagick
      repology)
        if [[ ! "$value" =~ ^[A-Za-z0-9@_+][A-Za-z0-9@._+:-]*$ ]]; then
          log_err "$shown: upstream.repology must be a Repology project name of A-Za-z0-9@._+:-, which starts with neither . nor - nor :: ${value@Q}"
          ((errors++))
        fi
        ;;
      archpkg)
        if [[ ! "$value" =~ ^[A-Za-z0-9@_+][A-Za-z0-9@._+-]*$ ]]; then
          log_err "$shown: upstream.archpkg must be an Arch package name of A-Za-z0-9@._+-, which starts with neither . nor -: ${value@Q}"
          ((errors++))
        fi
        ;;
      *)
        if [[ "$value" =~ $bad_ref || "$value" == *..* || "$value" == *@\{* ]]; then
          log_err "$shown: upstream.$field must be a git tag name, without spaces, control characters, ~ ^ : ? * [ \\, .. and @{: ${value@Q}"
          ((errors++))
        fi
        ;;
    esac
  done

  case "$strategy" in
    github-release | github-tag | github-nightly)
      local project
      project=$(pkg_get "$file" '.upstream.project // ""')
      if [[ -z "$project" || "$project" == "null" ]]; then
        log_err "$shown: strategy '$strategy' requires 'upstream.project'"
        ((errors++))
      fi
      if [[ "$strategy" == github-nightly ]]; then
        local nightly_source nightly_pattern
        nightly_source=$(pkg_get "$file" '.upstream.version_source // "tag"')
        nightly_pattern=$(pkg_get "$file" '.upstream.version_pattern // ""')
        if [[ ! "$nightly_source" =~ ^(tag|release_body|tag_date|published_date)$ ]]; then
          log_err "$shown: upstream.version_source must be tag, release_body, tag_date or published_date: $nightly_source"
          ((errors++))
        elif [[ "$nightly_source" == release_body && -z "$nightly_pattern" ]]; then
          log_err "$shown: upstream.version_source release_body needs upstream.version_pattern"
          ((errors++))
        elif [[ "$nightly_source" == release_body ]] && ! pcre_valid "$nightly_pattern"; then
          log_err "$shown: upstream.version_pattern is not valid PCRE regex: $nightly_pattern"
          ((errors++))
        fi
        if [[ "$nightly_source" != release_body && -n "$nightly_pattern" ]]; then
          log_err "$shown: upstream.version_pattern applies to version_source release_body only"
          ((errors++))
        fi
        # Pattern A reads one fixed tag, which has no dash and so no
        # YYYY-MM-DD date
        local nightly_tag nightly_channel
        nightly_tag=$(pkg_get "$file" '.upstream.nightly_tag // "nightly"')
        nightly_channel=$(pkg_get "$file" '.upstream.channel // ""')
        if [[ "$nightly_source" == tag_date && -z "$nightly_tag_regex" && -z "$nightly_channel" && "$nightly_tag" != latest && "$nightly_tag" != *-* ]]; then
          log_err "$shown: upstream.version_source tag_date reads the date in the tag name, and the fixed tag $nightly_tag has none; use published_date, or a nightly_tag prefix with a dash for dated tags"
          ((errors++))
        fi
        # nightly_tag: latest wins over channel, and channel over any other tag
        if [[ $(pkg_get "$file" '.upstream | (has("nightly_tag") and has("channel"))') == true ]]; then
          if [[ "$nightly_tag" == latest ]]; then
            log_err "$shown: upstream.nightly_tag latest takes the place of channel"
          else
            log_err "$shown: upstream.channel takes the place of nightly_tag"
          fi
          ((errors++))
        fi
      fi
      ;;
    github-asset)
      local project tag assets_type
      project=$(pkg_get "$file" '.upstream.project // ""')
      tag=$(pkg_get "$file" '.upstream.tag // ""')
      assets_type=$(pkg_get "$file" '.upstream.assets | tag')
      if [[ -z "$project" || "$project" == "null" ]]; then
        log_err "$shown: strategy 'github-asset' requires 'upstream.project'"
        ((errors++))
      fi
      if [[ -z "$tag" || "$tag" == "null" ]]; then
        log_err "$shown: strategy 'github-asset' requires 'upstream.tag'"
        ((errors++))
      fi
      if [[ "$assets_type" != "!!seq" || $(pkg_get "$file" '.upstream.assets | length') -eq 0 ]]; then
        log_err "$shown: strategy 'github-asset' requires 'upstream.assets' as a non-empty list"
        ((errors++))
      fi
      ;;
    gitlab-tag | gitea-tag | gitea-release)
      local host project
      host=$(pkg_get "$file" '.upstream.host // ""')
      project=$(pkg_get "$file" '.upstream.project // ""')
      if [[ -z "$host" || "$host" == "null" ]]; then
        log_err "$shown: strategy '$strategy' requires 'upstream.host'"
        ((errors++))
      elif [[ ! "$host" =~ ^[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]]; then
        log_err "$shown: upstream.host must be a host name, with a port or none: ${host@Q}"
        ((errors++))
      fi
      if [[ -z "$project" || "$project" == "null" ]]; then
        log_err "$shown: strategy '$strategy' requires 'upstream.project'"
        ((errors++))
      fi
      ;;
    git-tag)
      local url
      url=$(pkg_get "$file" '.upstream.url // ""')
      if [[ -z "$url" || "$url" == "null" ]]; then
        log_err "$shown: strategy 'git-tag' requires 'upstream.url'"
        ((errors++))
      elif [[ "$url" != https://* ]]; then
        log_err "$shown: upstream.url must use HTTPS: $url"
        ((errors++))
      elif [[ "$url" =~ ^https://[^/?#]*@ ]]; then
        log_err "$shown: upstream.url must hold no user name: ${url@Q}"
        ((errors++))
      elif [[ ! "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?([/?#]|$) ]]; then
        log_err "$shown: upstream.url must name its host after https:// in ASCII letters, digits, dots and dashes, with a port at most: ${url@Q}"
        ((errors++))
      fi
      ;;
    git-latest)
      local upstream_type
      upstream_type=$(pkg_get "$file" '.upstream.type // ""')
      if [[ -z "$upstream_type" || "$upstream_type" == "null" ]]; then
        log_err "$shown: strategy 'git-latest' requires 'upstream.type'"
        ((errors++))
      else
        case "$upstream_type" in
          github)
            local project
            project=$(pkg_get "$file" '.upstream.project // ""')
            if [[ -z "$project" || "$project" == "null" ]]; then
              log_err "$shown: git-latest type 'github' requires 'upstream.project'"
              ((errors++))
            fi
            ;;
          gitlab)
            local host project
            host=$(pkg_get "$file" '.upstream.host // ""')
            project=$(pkg_get "$file" '.upstream.project // ""')
            if [[ -z "$host" || "$host" == "null" ]]; then
              log_err "$shown: git-latest type 'gitlab' requires 'upstream.host'"
              ((errors++))
            elif [[ ! "$host" =~ ^[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]]; then
              log_err "$shown: upstream.host must be a host name, with a port or none: ${host@Q}"
              ((errors++))
            fi
            if [[ -z "$project" || "$project" == "null" ]]; then
              log_err "$shown: git-latest type 'gitlab' requires 'upstream.project'"
              ((errors++))
            fi
            ;;
          git)
            local url
            url=$(pkg_get "$file" '.upstream.url // ""')
            if [[ -z "$url" || "$url" == "null" ]]; then
              log_err "$shown: git-latest type 'git' requires 'upstream.url'"
              ((errors++))
            elif [[ "$url" != https://* ]]; then
              log_err "$shown: upstream.url must use HTTPS: $url"
              ((errors++))
            elif [[ "$url" =~ ^https://[^/?#]*@ ]]; then
              log_err "$shown: upstream.url must hold no user name: ${url@Q}"
              ((errors++))
            elif [[ ! "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?([/?#]|$) ]]; then
              log_err "$shown: upstream.url must name its host after https:// in ASCII letters, digits, dots and dashes, with a port at most: ${url@Q}"
              ((errors++))
            fi
            ;;
          *)
            log_err "$shown: git-latest unknown type '$upstream_type' (valid: github, gitlab, git)"
            ((errors++))
            ;;
        esac
        # Each type reads its own of host, project and url
        if [[ "$upstream_type" =~ ^(github|git)$ && $(pkg_get "$file" '.upstream | has("host")') == true ]]; then
          log_err "$shown: upstream.host applies to type gitlab only"
          ((errors++))
        fi
        if [[ "$upstream_type" == git && $(pkg_get "$file" '.upstream | has("project")') == true ]]; then
          log_err "$shown: upstream.project applies to types github and gitlab only"
          ((errors++))
        fi
        if [[ "$upstream_type" =~ ^(github|gitlab)$ && $(pkg_get "$file" '.upstream | has("url")') == true ]]; then
          log_err "$shown: upstream.url applies to type git only"
          ((errors++))
        fi
      fi
      # The strategy prints r<count>.<hash>, or <tag>.r<count>.g<hash> with upstream.describe,
      # which vercmp reads as newer, so a current of the other form breaks every check
      local current
      current=$(pkg_get "$file" '.current // ""')
      if [[ -n "$describe" ]]; then
        if [[ -n "$current" && ! "$current" =~ ^[A-Za-z0-9._+]+\.r[0-9]+\.g[0-9a-f]+$ ]]; then
          log_err "$shown: current must be <tag>.r<count>.g<hash> for git-latest with upstream.describe, the form the strategy prints: $current"
          ((errors++))
        fi
      elif [[ -n "$current" && ! "$current" =~ ^r[0-9]+\.[0-9a-f]+$ ]]; then
        log_err "$shown: current must be r<count>.<hash> for git-latest, the form the strategy prints: $current"
        ((errors++))
      fi
      ;;
    pypi | npm | crates)
      local registry
      registry=$(pkg_get "$file" '.upstream.registry // ""')
      if [[ -z "$registry" || "$registry" == "null" ]]; then
        log_err "$shown: strategy '$strategy' requires 'upstream.registry'"
        ((errors++))
      fi
      ;;
    webpage-scrape)
      local url pattern
      url=$(pkg_get "$file" '.upstream.url // ""')
      pattern=$(pkg_get "$file" '.upstream.pattern // ""')
      if [[ -z "$url" || "$url" == "null" ]]; then
        log_err "$shown: strategy 'webpage-scrape' requires 'upstream.url'"
        ((errors++))
      elif [[ "$url" != https://* ]]; then
        log_err "$shown: upstream.url must use HTTPS: $url"
        ((errors++))
      elif [[ "$url" =~ ^https://[^/?#]*@ ]]; then
        log_err "$shown: upstream.url must hold no user name: ${url@Q}"
        ((errors++))
      elif [[ ! "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?([/?#]|$) ]]; then
        log_err "$shown: upstream.url must name its host after https:// in ASCII letters, digits, dots and dashes, with a port at most: ${url@Q}"
        ((errors++))
      fi
      if [[ -z "$pattern" || "$pattern" == "null" ]]; then
        log_err "$shown: strategy 'webpage-scrape' requires 'upstream.pattern'"
        ((errors++))
      else
        # The strategy prints the first group of each match, and |^ makes the empty text
        # match, so BASH_REMATCH holds one entry per group
        if ! ere_valid "$pattern"; then
          log_err "$shown: upstream.pattern is not valid ERE regex: $pattern"
          ((errors++))
        elif [[ "" =~ $pattern|^ ]] && ((${#BASH_REMATCH[@]} < 2)); then
          log_err "$shown: upstream.pattern must contain a capture group: $pattern"
          ((errors++))
        fi
      fi
      # curl would send the text after a line break as a header of its own
      local user_agent
      user_agent=$(pkg_get "$file" '.upstream.user_agent // ""')
      if [[ -n "$user_agent" ]] && ! (LC_ALL=C && [[ "$user_agent" =~ ^[[:print:]]+$ ]]); then
        log_err "$shown: upstream.user_agent must hold printable ASCII only: ${user_agent@Q}"
        ((errors++))
      fi
      ;;
    archpkg | repology)
      # No required strategy-specific fields
      ;;
    kde-tarball)
      local project path
      project=$(pkg_get "$file" '.upstream.project // ""')
      path=$(pkg_get "$file" '.upstream.path // ""')
      if [[ -n "$project" && ! "$project" =~ ^[A-Za-z0-9][A-Za-z0-9@._+-]*$ ]]; then
        log_err "$shown: upstream.project must be a tarball name of A-Za-z0-9@._+-: $project"
        ((errors++))
      fi
      # The path ends up in https://download.kde.org/<path>/. Segments that
      # start with a dot would allow ..
      if [[ -n "$path" && ! "$path" =~ ^[A-Za-z0-9_+-][A-Za-z0-9._+-]*(/[A-Za-z0-9_+-][A-Za-z0-9._+-]*)*$ ]]; then
        log_err "$shown: upstream.path must be a directory on download.kde.org, such as unstable/alkimia: $path"
        ((errors++))
      fi
      ;;
  esac

  if [[ "$errors" -gt 0 ]]; then
    return 1
  fi
  return 0
}

# Succeed when the requires rules can read the requirements of package file $1, which the check of each
# new version reads: the AUR .SRCINFO, the python or ruby key and the release of the current version
requirements_ok() {
  requires_check "$1" && return 0
  log_err "$(shown_file "$1"): the requires rules cannot read its requirements, see https://aurtomator.dev/features/update-alerts/"
  return 1
}

# === MAIN ===

USAGE="Usage: validate-pkg.sh <package-name> | --all [--online] | --changed <list>"
if [[ "${1:-}" == --online || ("${1:-}" == --all && $# -gt 1 && "${2:-}" != --online) || $# -gt 2 ||
  ("${1:-}" == --changed && $# -ne 2) ]]; then
  echo "$USAGE" >&2
  exit 1
fi

if [[ "${1:-}" == --all || "${1:-}" == --changed ]]; then
  pkg_files=("${AURTOMATOR_DATA_DIR}"/packages/*.yml)
  what=packages
  if [[ "$1" == --changed ]]; then
    if [[ ! -f "$2" ]]; then
      log_err "$2: no list of changed files"
      exit 1
    fi
    pkg_files=()
    what="changed packages"
    # The list holds paths of the data directory, each ended by a NUL, as git diff -z prints them
    while IFS= read -r -d '' path; do
      [[ "$path" == packages/*.yml && "$path" != packages/*/* && "$path" != packages/.* ]] || continue
      pkg_files+=("${AURTOMATOR_DATA_DIR}/$path")
    done <"$2"
  fi
  total=0
  failed=0
  strays=0
  while IFS= read -r -d '' path; do
    entry="${path##*/}"
    [[ "$entry" == .gitkeep || "$entry" == example.yml.sample ]] && continue
    [[ "$entry" == *.yml && "$entry" != .* && -f "$path" && ! -L "$path" ]] && continue
    ! has_control "$entry" || entry=${entry@Q}
    log_err "packages/$entry: no run reads it, as the runs read the regular files packages/<name>.yml alone"
    ((strays++)) || true
  done < <(find "${AURTOMATOR_DATA_DIR}/packages" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  for pkg_file in "${pkg_files[@]}"; do
    [[ -f "$pkg_file" && ! -L "$pkg_file" ]] || continue
    ((total++)) || true
    if ! validate_pkg "$pkg_file" || { [[ "${2:-}" == --online ]] && ! requirements_ok "$pkg_file"; }; then
      ((failed++)) || true
    fi
  done
  if [[ "$total" -eq 0 && "$strays" -eq 0 ]]; then
    if [[ "$1" == --changed ]]; then
      log_ok "No package changed"
    else
      log_warn "No packages found in packages/"
    fi
    exit 0
  fi
  if [[ "$failed" -gt 0 ]]; then
    log_err "Validation failed: $failed/$total packages have errors"
    exit 1
  fi
  ((strays == 0)) || exit 1
  log_ok "All $total $what valid"
  exit 0
fi

readonly PKG_NAME="${1:?$USAGE}"
PKG_FILE="$(pkg_file "$PKG_NAME")"
readonly PKG_FILE

if validate_pkg "$PKG_FILE" && requirements_ok "$PKG_FILE"; then
  log_ok "$PKG_NAME: valid"
else
  exit 1
fi
