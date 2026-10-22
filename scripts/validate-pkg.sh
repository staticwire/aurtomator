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

  local allow_downgrade
  allow_downgrade=$(pkg_get "$file" '.allow_downgrade | tag')
  if [[ "$allow_downgrade" != "!!null" && "$allow_downgrade" != "!!bool" ]]; then
    log_err "$file: allow_downgrade must be true or false"
    ((errors++))
  fi

  local pkgver_dash=""
  if [[ $(pkg_get "$file" '.pkgver_dash | tag') != "!!null" ]]; then
    pkgver_dash=$(pkg_get "$file" '.pkgver_dash')
    if [[ "$pkgver_dash" != "_" && "$pkgver_dash" != "." ]]; then
      log_err "$file: pkgver_dash must be _ or ."
      ((errors++))
    fi
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
    elif [[ $(pkg_get "$file" '.upstream.prerelease') == true && -z "$pkgver_dash" ]]; then
      log_err "$file: upstream.prerelease needs pkgver_dash"
      ((errors++))
    fi
  fi

  # --- Strategy-specific fields ---

  # Validate optional tag_version_regex (used by github-release, github-tag,
  # github-nightly, gitlab-tag and gitea-tag)
  local tag_version_regex
  tag_version_regex=$(pkg_get "$file" '.upstream.tag_version_regex // ""')
  if [[ -n "$tag_version_regex" && "$tag_version_regex" != "null" ]]; then
    # Check capture group first (must have parentheses)
    if ! echo "$tag_version_regex" | grep -qE '\([^)]*\)'; then
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
      # The strategy prints r<count>.<hash>. vercmp reads 1.4.0.r47.g0bbf5ad
      # of git describe as newer than any of those, so each check would be
      # a downgrade.
      local current
      current=$(pkg_get "$file" '.current // ""')
      if [[ -n "$current" && ! "$current" =~ ^r[0-9]+\.[0-9a-f]+$ ]]; then
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
        # The strategy runs the pattern through grep and bash
        if ! ere_valid "$pattern"; then
          log_err "$file: upstream.pattern is not valid ERE regex: $pattern"
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
