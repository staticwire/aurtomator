#!/usr/bin/env bash
#
# common.sh - Config, YAML, HTTP, version and logging helpers. A strategy
# sources this file alone, a script sources it through lib.sh.
#
# Usage: source "${SCRIPT_DIR}/../scripts/lib/common.sh"
# Requires: yq (https://github.com/mikefarah/yq)

set -euo pipefail

# Resolve project root
AURTOMATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# =============================================================================
# DEPENDENCY CHECK
# =============================================================================

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    log_err "Required command not found: $cmd"
    exit 1
  fi
}

# =============================================================================
# YAML (via yq)
# =============================================================================

# Read any field from a YAML file
# Usage: pkg_get packages/my-package.yml .name
#        pkg_get packages/my-package.yml .upstream.type
pkg_get() {
  local file="$1" query="$2"
  yq -r "$query" "$file"
}

# Set a field in a YAML file
# Usage: pkg_set packages/my-package.yml .current '"24.12.3"'
pkg_set() {
  local file="$1" query="$2" value="$3"
  yq -i "${query} = ${value}" "$file"
}

# =============================================================================
# CONFIG
# =============================================================================

load_config() {
  local config="${AURTOMATOR_DIR}/.aurtomator.conf"
  if [[ -f "$config" ]]; then
    # shellcheck source=/dev/null
    source "$config"
  fi
}

# =============================================================================
# PACKAGE HELPERS
# =============================================================================

# Resolve package YAML file path from name
# Usage: pkg_file my-package
pkg_file() {
  local name="$1"
  local file="${AURTOMATOR_DIR}/packages/${name}.yml"
  if [[ ! -f "$file" ]]; then
    log_err "Package not found: $file"
    return 1
  fi
  echo "$file"
}

# =============================================================================
# HTTP
# =============================================================================

# The User-Agent of every strategy request. SourceForge answers a bare
# Mozilla/5.0 with HTTP 403. webpage-scrape.sh sets upstream.user_agent here.
USER_AGENT="aurtomator/1.0"

# GET a URL for a strategy. curl tries a timeout, a refused connection and
# an HTTP 408, 429, 500, 502, 503, 504, 522 or 524 answer twice more.
# Usage: http_get <url> [curl option]...
http_get() {
  curl -sfL --max-time 30 --retry 2 --retry-delay 5 --retry-connrefused \
    -A "$USER_AGENT" "${@:2}" "$1"
}

# GET a GitHub API URL, with GITHUB_TOKEN when it is set. curl reads the
# header from stdin: as an argument, the token is visible in ps to every
# local user.
# Usage: github_api https://api.github.com/repos/owner/repo/tags
github_api() {
  local auth=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth=(-H @-)
  fi
  http_get "$1" "${auth[@]}" <<<"Authorization: Bearer ${GITHUB_TOKEN:-}"
}

# =============================================================================
# VERSION VALIDATION
# =============================================================================

# Reject a version string before it is written into a PKGBUILD.
# update-pkg.sh writes the value with sed and makepkg then sources the
# file, so a shell metacharacter in an upstream tag would execute in CI.
# The allowlist is narrower than makepkg's own pkgver check on purpose:
# makepkg only forbids whitespace, '/', ':', '-' and non-ASCII. A word
# without a digit, such as latest, is no version.
# Args: $1=version string
# Returns: 0=ok, 1=rejected (reason on stderr)
validate_pkgver() {
  local ver="$1"
  local LC_ALL=C
  if [[ -z "$ver" ]]; then
    log_err "Version string is empty"
    return 1
  fi
  if [[ ! "$ver" =~ ^[A-Za-z0-9._+]+$ ]]; then
    log_err "Version string rejected, only A-Za-z0-9 . _ + are allowed: ${ver@Q}"
    return 1
  fi
  if [[ ! "$ver" =~ [0-9] ]]; then
    log_err "Version string rejected, it holds no digit: ${ver@Q}"
    return 1
  fi
}

# Args: $1=current version, $2=new version
# Returns: 0 when the first number in the new version has at least two
#          digits more than the first number in the current one, as in
#          13 → 2026102100 or 4.4215 → 4215, 1 otherwise
version_jump() {
  local old new
  [[ "$1" =~ [0-9]+ ]] || return 1
  old="${BASH_REMATCH[0]}"
  [[ "$2" =~ [0-9]+ ]] || return 1
  new="${BASH_REMATCH[0]}"
  ((${#new} >= ${#old} + 2))
}

# The tags of the form v1.2.3 or 1.2.3, for a tag strategy without
# tag_version_regex. sort -V puts latest, 2.1.0-rc1 and 2.1.0rc1 above
# 2.1.0, so they are left out.
# Args: $1=tags, one per line
release_tags() {
  grep -E '^v?[0-9]+(\.[0-9]+)*$' <<<"$1" || true
}

# The version a match of tag_version_regex gives: the template with \1 to
# \9 replaced by the groups in BASH_REMATCH and every other character kept.
# Args: $1=tag_version_replace
# Returns: 1 when the template names a group the regex does not have
tag_version_fill() {
  local template="$1" version="" i n
  for ((i = 0; i < ${#template}; i++)); do
    n=${template:i+1:1}
    if [[ "${template:i:1}" == "\\" && "$n" == [1-9] ]]; then
      if ((n >= ${#BASH_REMATCH[@]})); then
        echo "tag_version_replace names \\$n, a group tag_version_regex does not have" >&2
        return 1
      fi
      version+=${BASH_REMATCH[n]}
      i=$((i + 1))
    else
      version+=${template:i:1}
    fi
  done
  printf '%s\n' "$version"
}

# The version in each tag of stdin, one per line: tag_version_replace
# filled from the groups of tag_version_regex where it matches, or the tag
# without a leading v when the regex is empty. bash takes the groups, so
# the regex may hold |, which ends the pattern of a sed s command.
# Args: $1=tag_version_regex or empty, $2=tag_version_replace (default \1)
tag_versions() {
  local regex="$1" replace="${2:-\\1}" tag
  while IFS= read -r tag; do
    if [[ -z "$regex" ]]; then
      printf '%s\n' "${tag#v}"
    elif [[ "$tag" =~ $regex ]]; then
      tag_version_fill "$replace" || return 1
    fi
  done
}

# The highest version among the tags of a tag strategy. tag_version_regex
# keeps the tags it matches, and without it only the tags of the form
# v1.2.3 or 1.2.3 count.
# Args: $1=tags, one per line, $2=tag_version_regex, $3=tag_version_replace
# Returns: 1 with the reason on stderr when no tag gives a version
latest_tag_version() {
  local tags="$1" regex="$2" replace="${3:-}" version
  if [[ -z "$regex" ]]; then
    tags=$(release_tags "$tags")
    if [[ -z "$tags" ]]; then
      echo "No tag of the form v1.2.3 or 1.2.3; set upstream.tag_version_regex" >&2
      return 1
    fi
  fi
  version=$(tag_versions "$regex" "$replace" <<<"$tags" | sort -V | tail -1)
  if [[ -z "$version" ]]; then
    echo "No matching tags found" >&2
    return 1
  fi
  echo "$version"
}

# The first capture group of every match of an ERE in stdin, one per line.
# grep finds the matches and bash takes the group, so no delimiter of a sed
# command limits the pattern.
# Args: $1=ERE with a capture group
capture_matches() {
  local pattern="$1" match
  while IFS= read -r match; do
    if [[ "$match" =~ $pattern ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
  done < <(grep -oE -e "$pattern")
}

# Succeeds when bash accepts an ERE, as capture_matches needs. bash refuses
# some patterns that grep -E takes, (?:x) and *x among them.
# Args: $1=ERE
ere_valid() {
  local rc=0
  # [[ =~ ]] returns 2 for a pattern bash cannot compile
  # shellcheck disable=SC2319
  [[ "" =~ $1 ]] 2>/dev/null || rc=$?
  ((rc != 2))
}

# =============================================================================
# LOGGING
# =============================================================================

if [[ -t 1 ]]; then
  _GREEN='\033[0;32m'
  _YELLOW='\033[0;33m'
  _RED='\033[0;31m'
  _BOLD='\033[1m'
  _RESET='\033[0m'
else
  _GREEN="" _YELLOW="" _RED="" _BOLD="" _RESET=""
fi

log_ok() { printf "${_GREEN}✓${_RESET} %s\n" "$*" >&2; }
log_warn() { printf "${_YELLOW}!${_RESET} %s\n" "$*" >&2; }
log_err() { printf "${_RED}✗${_RESET} %s\n" "$*" >&2; }
log_info() { printf "${_BOLD}→${_RESET} %s\n" "$*" >&2; }
