#!/usr/bin/env bash
#
# validate-pkg.sh - Validate package YAML configuration
#
# Usage: ./scripts/validate-pkg.sh <package-name>
#        ./scripts/validate-pkg.sh --all
#
# Validates YAML syntax, required fields, strategy name,
# and strategy-specific field requirements.

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

# Validate one entry of alerts
# Args: $1=package file, $2=index of the entry, $3=pkgver_format, if any
# Returns 0 if valid, 1 if invalid (errors printed to stderr)
validate_alert() {
  local file="$1" i="$2" format="$3" rule="$1: alerts[$2]" errors=0 unknown tag value
  if [[ $(pkg_get "$file" ".alerts[$i] | tag") != "!!map" ]]; then
    log_err "$rule must be a map with note and one of when, from, match"
    return 1
  fi
  unknown=$(pkg_get "$file" ".alerts[$i] | [keys[] | select(. != \"when\" and . != \"from\" and . != \"match\" and . != \"note\" and . != \"hold\")] | join(\", \")")
  if [[ -n "$unknown" ]]; then
    log_err "$rule has an unknown key: $unknown"
    errors=1
  fi
  if [[ $(pkg_get "$file" ".alerts[$i] | [keys[] | select(. == \"when\" or . == \"from\" or . == \"match\")] | length") != 1 ]]; then
    log_err "$rule must hold exactly one of when, from, match"
    errors=1
  fi

  tag=$(pkg_get "$file" ".alerts[$i].when | tag")
  value=$(pkg_get "$file" ".alerts[$i].when")
  if [[ "$tag" != "!!null" && "$value" != major ]]; then
    log_err "$rule.when must be major: $value"
    errors=1
  # The fixed text of a format such as 4.%s holds the first number
  elif [[ "$tag" != "!!null" && -n "$format" ]]; then
    log_err "$rule: when: major does not apply with pkgver_format"
    errors=1
  fi

  tag=$(pkg_get "$file" ".alerts[$i].from | tag")
  value=$(pkg_get "$file" ".alerts[$i].from")
  if [[ "$tag" != "!!null" ]] && ! validate_pkgver "$value" 2>/dev/null; then
    log_err "$rule.from must be a version of A-Za-z0-9 . _ + with a digit: $value"
    errors=1
  fi

  tag=$(pkg_get "$file" ".alerts[$i].match | tag")
  value=$(pkg_get "$file" ".alerts[$i].match")
  if [[ "$tag" != "!!null" ]] && { [[ "$tag" != "!!str" || -z "$value" ]] || ! ere_valid "$value"; }; then
    log_err "$rule.match must be a non-empty ERE that bash accepts: $value"
    errors=1
  fi

  # The note goes into one log line
  tag=$(pkg_get "$file" ".alerts[$i].note | tag")
  value=$(pkg_get "$file" ".alerts[$i].note")
  if [[ "$tag" != "!!str" || -z "$value" || "$value" == *[$'\n\r']* ]]; then
    log_err "$rule.note must be one line of text"
    errors=1
  fi

  tag=$(pkg_get "$file" ".alerts[$i].hold | tag")
  if [[ "$tag" != "!!null" && "$tag" != "!!bool" ]]; then
    log_err "$rule.hold must be true or false"
    errors=1
  fi

  return "$errors"
}

# Validate a single package YAML file
# Returns 0 if valid, 1 if invalid (errors printed to stderr)
validate_pkg() {
  local file="$1"
  local errors=0

  # --- YAML syntax ---
  if ! yq '.' "$file" >/dev/null 2>&1; then
    log_err "Invalid YAML syntax: $file"
    return 1
  fi

  local name strategy
  name=$(pkg_get "$file" '.name // ""')
  strategy=$(pkg_get "$file" '.strategy // ""')

  # --- Required core fields ---
  if [[ -z "$name" || "$name" == "null" ]]; then
    log_err "$file: missing required field 'name'"
    ((errors++))
  fi

  if [[ -z "$strategy" || "$strategy" == "null" ]]; then
    log_err "$file: missing required field 'strategy'"
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
    log_err "$file: unknown strategy '$strategy' (valid: ${VALID_STRATEGIES[*]})"
    ((errors++))
    return 1
  fi

  # --- Optional fields ---

  local flag flag_tag
  for flag in allow_downgrade allow_version_jump; do
    flag_tag=$(pkg_get "$file" ".${flag} | tag")
    if [[ "$flag_tag" != "!!null" && "$flag_tag" != "!!bool" ]]; then
      log_err "$file: $flag must be true or false"
      ((errors++))
    fi
  done

  # '' drops the dash, so pkgver_dash counts as set when it is empty
  local pkgver_dash="" dash_set=false
  if [[ $(pkg_get "$file" '.pkgver_dash | tag') != "!!null" ]]; then
    dash_set=true
    pkgver_dash=$(pkg_get "$file" '.pkgver_dash')
    if [[ "$pkgver_dash" != "_" && "$pkgver_dash" != "." && -n "$pkgver_dash" ]]; then
      log_err "$file: pkgver_dash must be _, . or ''"
      ((errors++))
    fi
  fi

  local pkgver_format="" formatted
  if [[ $(pkg_get "$file" '.pkgver_format | tag') != "!!null" ]]; then
    pkgver_format=$(pkg_get "$file" '.pkgver_format')
    formatted=$(pkg_get "$file" '.current // ""')
    if [[ ! "$pkgver_format" =~ ^[A-Za-z0-9._+]*%s[A-Za-z0-9._+]*$ ]]; then
      log_err "$file: pkgver_format must hold %s once, with only A-Za-z0-9 . _ + around it"
      ((errors++))
    elif [[ -n "$formatted" && -z "$(_unformat_version "$formatted" "$pkgver_format")" ]]; then
      log_err "$file: current $formatted does not fit pkgver_format $pkgver_format"
      ((errors++))
    fi
  fi

  local alerts_tag alert_count i
  alerts_tag=$(pkg_get "$file" '.alerts | tag')
  if [[ "$alerts_tag" == "!!seq" ]]; then
    alert_count=$(pkg_get "$file" '.alerts | length')
    for ((i = 0; i < alert_count; i++)); do
      validate_alert "$file" "$i" "$pkgver_format" || ((errors++))
    done
  elif [[ "$alerts_tag" != "!!null" ]]; then
    log_err "$file: alerts must be a list"
    ((errors++))
  fi

  local branch
  if [[ $(pkg_get "$file" '.upstream.branch | tag') != "!!null" ]]; then
    branch=$(pkg_get "$file" '.upstream.branch')
    if [[ "$strategy" != "git-latest" ]]; then
      log_err "$file: upstream.branch applies to the git-latest strategy only"
      ((errors++))
    # git clone would read a name that starts with - as an option
    elif ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
      log_err "$file: upstream.branch is not a valid branch name: $branch"
      ((errors++))
    fi
  fi

  local describe=""
  if [[ $(pkg_get "$file" '.upstream.describe | tag') != "!!null" ]]; then
    describe=$(pkg_get "$file" '.upstream.describe')
    if [[ "$strategy" != "git-latest" ]]; then
      log_err "$file: upstream.describe applies to the git-latest strategy only"
      ((errors++))
    elif [[ "$describe" != tags && "$describe" != annotated ]]; then
      log_err "$file: upstream.describe must be tags or annotated: $describe"
      ((errors++))
    fi
  fi

  local tag_prefix
  if [[ $(pkg_get "$file" '.upstream.tag_prefix | tag') != "!!null" ]]; then
    tag_prefix=$(pkg_get "$file" '.upstream.tag_prefix')
    if [[ -z "$describe" ]]; then
      log_err "$file: upstream.tag_prefix applies with upstream.describe only"
      ((errors++))
    elif [[ ! "$tag_prefix" =~ ^[A-Za-z0-9._+/-]+$ ]]; then
      log_err "$file: upstream.tag_prefix may hold A-Za-z0-9._+/- only: $tag_prefix"
      ((errors++))
    fi
  fi

  local nightly_tag_regex
  nightly_tag_regex=$(pkg_get "$file" '.upstream.nightly_tag_regex // ""')
  if [[ -n "$nightly_tag_regex" ]]; then
    if [[ "$strategy" != "github-nightly" ]]; then
      log_err "$file: upstream.nightly_tag_regex applies to the github-nightly strategy only"
      ((errors++))
    elif [[ $(pkg_get "$file" '.upstream | (has("nightly_tag") or has("channel"))') == true ]]; then
      log_err "$file: upstream.nightly_tag_regex takes the place of nightly_tag and channel"
      ((errors++))
    elif ! ere_valid "$nightly_tag_regex"; then
      log_err "$file: upstream.nightly_tag_regex is not valid ERE regex: $nightly_tag_regex"
      ((errors++))
    fi
  fi

  local prerelease
  prerelease=$(pkg_get "$file" '.upstream.prerelease | tag')
  if [[ "$prerelease" != "!!null" ]]; then
    if [[ "$prerelease" != "!!bool" ]]; then
      log_err "$file: upstream.prerelease must be true or false"
      ((errors++))
    elif [[ "$strategy" != "crates" ]]; then
      log_err "$file: upstream.prerelease applies to the crates strategy only"
      ((errors++))
    # A semver pre-release always holds a dash
    elif [[ $(pkg_get "$file" '.upstream.prerelease') == true && "$dash_set" == false ]]; then
      log_err "$file: upstream.prerelease needs pkgver_dash"
      ((errors++))
    fi
  fi

  # --- Strategy-specific fields ---

  # Validate optional tag_version_regex
  local tag_version_regex
  tag_version_regex=$(pkg_get "$file" '.upstream.tag_version_regex // ""')
  if [[ -n "$tag_version_regex" && "$tag_version_regex" != "null" ]]; then
    if [[ ! "$strategy" =~ ^(github-release|github-tag|github-nightly|gitlab-tag|gitea-tag|git-tag)$ ]]; then
      log_err "$file: upstream.tag_version_regex applies to the github-release, github-tag, github-nightly, gitlab-tag, gitea-tag and git-tag strategies only"
      ((errors++))
    elif [[ "$strategy" == "github-nightly" && $(pkg_get "$file" '.upstream.version_source // "tag"') != "tag" ]]; then
      log_err "$file: upstream.tag_version_regex applies to version_source tag only"
      ((errors++))
    # Then check the capture group (must have parentheses)
    elif ! echo "$tag_version_regex" | grep -qE '\([^)]*\)'; then
      log_err "$file: upstream.tag_version_regex must contain a capture group (): $tag_version_regex"
      ((errors++))
    # Then check that bash compiles it, as tag_versions needs
    elif ! ere_valid "$tag_version_regex"; then
      log_err "$file: upstream.tag_version_regex is not valid ERE regex: $tag_version_regex"
      ((errors++))
    fi
  fi

  local tag_version_replace
  tag_version_replace=$(pkg_get "$file" '.upstream.tag_version_replace // ""')
  if [[ -n "$tag_version_replace" ]]; then
    if [[ -z "$tag_version_regex" ]]; then
      log_err "$file: upstream.tag_version_replace needs upstream.tag_version_regex"
      ((errors++))
    elif [[ ! "$tag_version_replace" =~ ^([A-Za-z0-9._+]|\\[1-9])+$ ]]; then
      log_err "$file: upstream.tag_version_replace may hold only A-Za-z0-9 . _ + and \\1 to \\9: $tag_version_replace"
      ((errors++))
    # $regex|^ matches the empty string and fills BASH_REMATCH with every
    # group of the regex, so tag_version_fill finds a missing group as it
    # does at run time
    elif ere_valid "$tag_version_regex" &&
      ! { [[ "" =~ $tag_version_regex|^ ]] && tag_version_fill "$tag_version_replace" >/dev/null 2>&1; }; then
      log_err "$file: upstream.tag_version_replace names a group tag_version_regex does not have: $tag_version_replace"
      ((errors++))
    fi
  fi

  # A value from the name of a release asset, see section 4.6 of
  # docs/WORKFLOW.md. $regex|^ matches the empty string and fills
  # BASH_REMATCH with every group of the regex.
  local asset_regex_tag asset_var_tag asset_regex current_asset groups=0
  asset_regex_tag=$(pkg_get "$file" '.upstream.asset_regex | tag')
  asset_var_tag=$(pkg_get "$file" '.upstream.asset_var | tag')
  if [[ "$asset_regex_tag" != "!!null" || "$asset_var_tag" != "!!null" ]]; then
    asset_regex=$(pkg_get "$file" '.upstream.asset_regex')
    if [[ "$asset_regex_tag" == "!!str" ]] && ere_valid "$asset_regex" && [[ "" =~ $asset_regex|^ ]]; then
      groups=$((${#BASH_REMATCH[@]} - 1))
    fi
    if [[ "$asset_regex_tag" == "!!null" || "$asset_var_tag" == "!!null" ]]; then
      log_err "$file: upstream.asset_regex and upstream.asset_var go together"
      ((errors++))
    elif [[ "$strategy" != "github-tag" && "$strategy" != "github-release" ]]; then
      log_err "$file: upstream.asset_regex applies to the github-tag and github-release strategies only"
      ((errors++))
    elif ((groups != 1)); then
      log_err "$file: upstream.asset_regex must be an ERE that bash accepts, with exactly one capture group: $asset_regex"
      ((errors++))
    fi
    pkg_asset_var "$file" >/dev/null || ((errors++))
  fi
  if [[ $(pkg_get "$file" '.current_asset | tag') != "!!null" ]]; then
    current_asset=$(pkg_get "$file" '.current_asset')
    if [[ "$asset_var_tag" == "!!null" ]]; then
      log_err "$file: current_asset needs upstream.asset_var"
      ((errors++))
    elif ! validate_asset_value "$current_asset" 2>/dev/null; then
      log_err "$file: current_asset must start with a letter or a digit and hold only A-Za-z0-9 . _ + ~ -: ${current_asset@Q}"
      ((errors++))
    fi
  fi

  local date_format version_source sample
  date_format=$(pkg_get "$file" '.upstream.date_format')
  if [[ "$date_format" != "null" ]]; then
    version_source=$(pkg_get "$file" '.upstream.version_source // "tag"')
    sample=$(date -u -d 2026-01-02 +"$date_format")
    if [[ "$version_source" != "tag_date" && "$version_source" != "published_date" ]]; then
      log_err "$file: upstream.date_format applies to version_source tag_date and published_date only"
      ((errors++))
    elif ! validate_pkgver "$sample" 2>/dev/null; then
      log_err "$file: upstream.date_format must give a valid version, it gives ${sample@Q}"
      ((errors++))
    fi
  fi

  case "$strategy" in
    github-release | github-tag | github-nightly)
      local project
      project=$(pkg_get "$file" '.upstream.project // ""')
      if [[ -z "$project" || "$project" == "null" ]]; then
        log_err "$file: strategy '$strategy' requires 'upstream.project'"
        ((errors++))
      fi
      ;;
    github-asset)
      local project tag assets_type
      project=$(pkg_get "$file" '.upstream.project // ""')
      tag=$(pkg_get "$file" '.upstream.tag // ""')
      assets_type=$(pkg_get "$file" '.upstream.assets | tag')
      if [[ -z "$project" || "$project" == "null" ]]; then
        log_err "$file: strategy 'github-asset' requires 'upstream.project'"
        ((errors++))
      fi
      if [[ -z "$tag" || "$tag" == "null" ]]; then
        log_err "$file: strategy 'github-asset' requires 'upstream.tag'"
        ((errors++))
      fi
      if [[ "$assets_type" != "!!seq" || $(pkg_get "$file" '.upstream.assets | length') -eq 0 ]]; then
        log_err "$file: strategy 'github-asset' requires 'upstream.assets' as a non-empty list"
        ((errors++))
      fi
      ;;
    gitlab-tag | gitea-tag)
      local host project
      host=$(pkg_get "$file" '.upstream.host // ""')
      project=$(pkg_get "$file" '.upstream.project // ""')
      if [[ -z "$host" || "$host" == "null" ]]; then
        log_err "$file: strategy '$strategy' requires 'upstream.host'"
        ((errors++))
      fi
      if [[ -z "$project" || "$project" == "null" ]]; then
        log_err "$file: strategy '$strategy' requires 'upstream.project'"
        ((errors++))
      fi
      ;;
    git-tag)
      local url
      url=$(pkg_get "$file" '.upstream.url // ""')
      if [[ -z "$url" || "$url" == "null" ]]; then
        log_err "$file: strategy 'git-tag' requires 'upstream.url'"
        ((errors++))
      elif [[ "$url" != https://* ]]; then
        log_err "$file: upstream.url must use HTTPS: $url"
        ((errors++))
      fi
      ;;
    git-latest)
      local upstream_type
      upstream_type=$(pkg_get "$file" '.upstream.type // ""')
      if [[ -z "$upstream_type" || "$upstream_type" == "null" ]]; then
        log_err "$file: strategy 'git-latest' requires 'upstream.type'"
        ((errors++))
      else
        case "$upstream_type" in
          github)
            local project
            project=$(pkg_get "$file" '.upstream.project // ""')
            if [[ -z "$project" || "$project" == "null" ]]; then
              log_err "$file: git-latest type 'github' requires 'upstream.project'"
              ((errors++))
            fi
            ;;
          gitlab)
            local host project
            host=$(pkg_get "$file" '.upstream.host // ""')
            project=$(pkg_get "$file" '.upstream.project // ""')
            if [[ -z "$host" || "$host" == "null" ]]; then
              log_err "$file: git-latest type 'gitlab' requires 'upstream.host'"
              ((errors++))
            fi
            if [[ -z "$project" || "$project" == "null" ]]; then
              log_err "$file: git-latest type 'gitlab' requires 'upstream.project'"
              ((errors++))
            fi
            ;;
          git)
            local url
            url=$(pkg_get "$file" '.upstream.url // ""')
            if [[ -z "$url" || "$url" == "null" ]]; then
              log_err "$file: git-latest type 'git' requires 'upstream.url'"
              ((errors++))
            elif [[ "$url" != https://* ]]; then
              log_err "$file: upstream.url must use HTTPS: $url"
              ((errors++))
            fi
            ;;
          *)
            log_err "$file: git-latest unknown type '$upstream_type' (valid: github, gitlab, git)"
            ((errors++))
            ;;
        esac
      fi
      # The strategy prints r<count>.<hash>, or with upstream.describe
      # <tag>.r<count>.g<hash>. vercmp reads 1.4.0.r47.g0bbf5ad as newer
      # than every r<count>.<hash>, so a current of the other form would
      # make each check a downgrade, or each check an update.
      local current
      current=$(pkg_get "$file" '.current // ""')
      if [[ -n "$describe" ]]; then
        if [[ -n "$current" && ! "$current" =~ ^[A-Za-z0-9._+]+\.r[0-9]+\.g[0-9a-f]+$ ]]; then
          log_err "$file: current must be <tag>.r<count>.g<hash> for git-latest with upstream.describe, the form the strategy prints: $current"
          ((errors++))
        fi
      elif [[ -n "$current" && ! "$current" =~ ^r[0-9]+\.[0-9a-f]+$ ]]; then
        log_err "$file: current must be r<count>.<hash> for git-latest, the form the strategy prints: $current"
        ((errors++))
      fi
      ;;
    pypi | npm | crates)
      local registry
      registry=$(pkg_get "$file" '.upstream.registry // ""')
      if [[ -z "$registry" || "$registry" == "null" ]]; then
        log_err "$file: strategy '$strategy' requires 'upstream.registry'"
        ((errors++))
      fi
      ;;
    webpage-scrape)
      local url pattern
      url=$(pkg_get "$file" '.upstream.url // ""')
      pattern=$(pkg_get "$file" '.upstream.pattern // ""')
      if [[ -z "$url" || "$url" == "null" ]]; then
        log_err "$file: strategy 'webpage-scrape' requires 'upstream.url'"
        ((errors++))
      elif [[ "$url" != https://* ]]; then
        log_err "$file: upstream.url must use HTTPS: $url"
        ((errors++))
      fi
      if [[ -z "$pattern" || "$pattern" == "null" ]]; then
        log_err "$file: strategy 'webpage-scrape' requires 'upstream.pattern'"
        ((errors++))
      else
        # The strategy runs the pattern through grep and bash, and prints the
        # first group of each match. |^ makes the empty text match, so
        # BASH_REMATCH holds one entry per group.
        if ! ere_valid "$pattern"; then
          log_err "$file: upstream.pattern is not valid ERE regex: $pattern"
          ((errors++))
        elif [[ "" =~ $pattern|^ ]] && ((${#BASH_REMATCH[@]} < 2)); then
          log_err "$file: upstream.pattern must contain a capture group: $pattern"
          ((errors++))
        fi
      fi
      # curl would send the text after a line break as a header of its own
      local user_agent
      user_agent=$(pkg_get "$file" '.upstream.user_agent // ""')
      if [[ -n "$user_agent" ]] && ! (LC_ALL=C && [[ "$user_agent" =~ ^[[:print:]]+$ ]]); then
        log_err "$file: upstream.user_agent must hold printable ASCII only: ${user_agent@Q}"
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
        log_err "$file: upstream.project must be a tarball name of A-Za-z0-9@._+-: $project"
        ((errors++))
      fi
      # The path ends up in https://download.kde.org/<path>/. A segment that
      # starts with a dot would allow ..
      if [[ -n "$path" && ! "$path" =~ ^[A-Za-z0-9_+-][A-Za-z0-9._+-]*(/[A-Za-z0-9_+-][A-Za-z0-9._+-]*)*$ ]]; then
        log_err "$file: upstream.path must be a directory on download.kde.org, such as unstable/alkimia: $path"
        ((errors++))
      fi
      ;;
  esac

  if [[ "$errors" -gt 0 ]]; then
    return 1
  fi
  return 0
}

# =============================================================================
# MAIN
# =============================================================================

if [[ "${1:-}" == "--all" ]]; then
  total=0
  failed=0
  for pkg_file in "${AURTOMATOR_DIR}"/packages/*.yml; do
    [[ -f "$pkg_file" ]] || continue
    ((total++)) || true
    if ! validate_pkg "$pkg_file"; then
      ((failed++)) || true
    fi
  done
  if [[ "$total" -eq 0 ]]; then
    log_warn "No packages found in packages/"
    exit 0
  fi
  if [[ "$failed" -gt 0 ]]; then
    log_err "Validation failed: $failed/$total packages have errors"
    exit 1
  fi
  log_ok "All $total packages valid"
  exit 0
fi

readonly PKG_NAME="${1:?Usage: validate-pkg.sh <package-name> | --all}"
PKG_FILE="$(pkg_file "$PKG_NAME")"
readonly PKG_FILE

if validate_pkg "$PKG_FILE"; then
  log_ok "$PKG_NAME: valid"
else
  exit 1
fi
