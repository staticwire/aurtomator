#!/usr/bin/env bash
#
# validate-pkg.sh — Validate package YAML configuration
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

readonly VALID_STRATEGIES=(
  github-release github-tag github-nightly gitlab-tag gitea-tag git-latest
  pypi npm crates repology archpkg kde-tarball webpage-scrape
)

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
    # Can't validate strategy-specific fields without strategy
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

  # --- Strategy-specific fields ---

  # Validate optional tag_pattern as regex (used by *-tag strategies)
  local tag_pattern
  tag_pattern=$(pkg_get "$file" '.upstream.tag_pattern // ""')
  if [[ -n "$tag_pattern" && "$tag_pattern" != "null" ]]; then
    # Strategies convert glob to regex: ^${pattern//\*/.*}
    local tag_regex="^${tag_pattern//\*/.*}"
    local grep_rc=0
    echo "" | grep -qE "$tag_regex" 2>/dev/null || grep_rc=$?
    if [[ "$grep_rc" -eq 2 ]]; then
      log_err "$file: upstream.tag_pattern is not valid as regex: $tag_pattern"
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
            fi
            ;;
          *)
            log_err "$file: git-latest unknown type '$upstream_type' (valid: github, gitlab, git)"
            ((errors++))
            ;;
        esac
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
        # Validate regex syntax: grep exits 2 on invalid regex
        local grep_rc=0
        echo "" | grep -qE "$pattern" 2>/dev/null || grep_rc=$?
        if [[ "$grep_rc" -eq 2 ]]; then
          log_err "$file: upstream.pattern is not valid ERE regex: $pattern"
          ((errors++))
        fi
      fi
      ;;
    archpkg | repology | kde-tarball)
      # No required strategy-specific fields
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
