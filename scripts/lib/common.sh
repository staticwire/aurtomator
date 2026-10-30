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

# Write current and, when an asset value is given, current_asset
# Usage: pkg_set_current packages/my-package.yml 2.5.0 [asset value]
pkg_set_current() {
  pkg_set "$1" .current "\"$2\""
  [[ -z "${3:-}" ]] || pkg_set "$1" .current_asset "\"$3\""
}

# The pkgver_dash of a package: _ or ., drop for '', which drops the dash,
# and nothing when the package does not set it
# Usage: pkgver_dash packages/my-package.yml
pkgver_dash() {
  local file="$1" dash
  [[ $(pkg_get "$file" '.pkgver_dash | tag') != "!!null" ]] || return 0
  dash=$(pkg_get "$file" '.pkgver_dash')
  printf '%s\n' "${dash:-drop}"
}

# The pkgver of an upstream version, as check-update.sh makes it from the
# version of a strategy. pkgver holds no dash. The PKGBUILD turns
# pkgver_dash back into a dash where a URL needs one, as in ${pkgver//_/-}.
# pkgver_dash: '' drops the dash, so 2.5.0-rc1 gives 2.5.0rc1, which vercmp
# puts below 2.5.0, and the PKGBUILD puts it back as in ${pkgver/rc/-rc}.
# pkgver is the upstream version with the text of pkgver_format around it,
# as 4.4215 for build 4215. The PKGBUILD cuts that text off where a URL
# needs the upstream version, as in ${pkgver#4.}.
# Args: $1=upstream version, $2=pkgver_dash character or drop, if any,
#       $3=pkgver_format, if any
to_pkgver() {
  local version="$1"
  if [[ "$2" == drop ]]; then
    version=${version//-/}
  elif [[ -n "$2" ]]; then
    version=${version//-/"$2"}
  fi
  if [[ -n "$3" ]]; then
    version=${3/"%s"/"$version"}
  fi
  printf '%s\n' "$version"
}

# The asset_var of a package, the PKGBUILD variable that holds a value from
# the name of a release asset, and nothing when the package does not set it.
# The name reaches a sed command and an awk program, so it has to be a
# variable name that starts with _.
# Usage: pkg_asset_var packages/my-package.yml
# Returns: 1 when the name is of another form (reason on stderr)
pkg_asset_var() {
  local var
  var=$(pkg_get "$1" '.upstream.asset_var // ""')
  if [[ -n "$var" && ! "$var" =~ ^_[A-Za-z0-9_]+$ ]]; then
    log_err "$1: upstream.asset_var must be a name that starts with _: ${var@Q}"
    return 1
  fi
  printf '%s\n' "$var"
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

# What curl writes to stderr on a failure: the URL of the last answer, the
# error and the cf-mitigated header, which Cloudflare sets to "challenge"
# on the page of its bot check
HTTP_FAILURE='%{onerror}%{stderr}%{url_effective}\t%{errormsg}\t%header{cf-mitigated}'

# Args: $1=URL, the rest: curl options
_curl_get() {
  curl -sfL --max-time 30 --retry 2 --retry-delay 5 --retry-connrefused \
    -A "$USER_AGENT" -w "$HTTP_FAILURE" "${@:2}" "$1"
}

# GET a URL for a strategy. curl tries a timeout, a refused connection and
# an HTTP 408, 429, 500, 502, 503, 504, 522 or 524 answer twice more. A
# failure prints the URL of the last answer after redirects and the error.
# Usage: http_get <url> [curl option]...
http_get() {
  local failure rc=0 url error mitigated
  # The answer goes out through fd 3, and stderr into failure
  { failure=$(_curl_get "$@" 2>&1 >&3 3>&-); } 3>&1 || rc=$?
  if ((rc == 0)); then
    return 0
  fi
  if [[ "$failure" == *$'\t'* ]]; then
    IFS=$'\t' read -r url error mitigated <<<"$failure"
    failure="${url}: ${error}"
    if [[ "$mitigated" == challenge ]]; then
      failure+=", a Cloudflare challenge, which only a browser passes"
    fi
  elif [[ -z "$failure" ]]; then
    failure="${1}: curl exit ${rc}"
  fi
  printf '%s\n' "$failure" >&2
  return "$rc"
}

# GET a URL that answers JSON and print the answer. The bot check of a
# site answers an HTML page with HTTP 200, often after a redirect, so an
# answer that is not a JSON object or array fails and names the URL it
# came from.
# Usage: http_get_json <url> [curl option]...
http_get_json() {
  local answer url
  answer=$(http_get "$@" -w "\n%{url_effective}${HTTP_FAILURE}") || return
  url=${answer##*$'\n'}
  answer=${answer%$'\n'*}
  if [[ ! "$(yq 'tag' <<<"$answer" 2>/dev/null)" =~ ^!!(map|seq)$ ]]; then
    printf '%s: the answer is not JSON\n' "$url" >&2
    return 1
  fi
  printf '%s\n' "$answer"
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

# Print published_at<TAB>tag of each release in the JSON that passes the yq
# filter and whose tag matches the ERE
# Args: $1=releases JSON, $2=ERE, $3=yq filter of the releases
_release_matches() {
  local rows row
  local -a lines
  rows=$(yq -r ".[] | $3 | [.published_at, .tag_name] | @tsv" <<<"$1") || return 1
  mapfile -t lines <<<"$rows"
  for row in "${lines[@]}"; do
    if [[ "${row#*$'\t'}" =~ $2 ]]; then printf '%s\n' "$row"; fi
  done
}

# Print the tag of the newest release among lines of published_at<TAB>tag on
# stdin: the one published last, or with $1=version the one with the newest
# version
# Args: $1="version" to pick by version, $2=ERE, $3=tag_version_replace
_newest_release_tag() {
  if [[ "${1:-}" == version ]]; then
    cut -f2 | _newest_tag "$2" "${3:-}"
  else
    sort | tail -1 | cut -f2
  fi
}

# The tag on stdin, one per line, that gives the newest version by
# newest_version
# Args: $1=tag_version_regex, $2=tag_version_replace
_newest_tag() {
  local tag version newest
  local -A tag_of=()
  while IFS= read -r tag; do
    version=$(tag_versions "$1" "$2" <<<"$tag") || return 1
    if [[ -n "$version" ]]; then
      tag_of[$version]=$tag
    fi
  done
  newest=$(printf '%s\n' "${!tag_of[@]}" | newest_version)
  if [[ -n "$newest" ]]; then
    printf '%s\n' "${tag_of[$newest]}"
  fi
}

# Print the release whose tag matches the ERE, as JSON, or nothing. Reads
# pages of 100 releases until a page holds fewer than 100, at most the given
# number of pages. Of the matches on all of them, the one published last
# wins, or with "version" the one with the newest version. The API lists
# releases by created_at, the date of the tagged commit, so neither the
# order of the list nor its pages decide anything. A draft holds no
# published_at.
# Args: $1=API URL of the repository, $2=ERE, $3=most pages to read,
#       $4="stable" to leave out pre-releases, $5="version" to pick by
#       version, $6=tag_version_replace
# Returns: 1 when a request fails
github_release_matching() {
  local filter='select(.published_at != null)' page json matches="" tag release
  local -a pages=()
  if [[ "${4:-}" == stable ]]; then
    filter+=' | select(.prerelease != true)'
  fi
  for ((page = 1; page <= $3; page++)); do
    json=$(github_api "$1/releases?per_page=100&page=${page}") || return 1
    pages+=("$json")
    matches+=$(_release_matches "$json" "$2" "$filter")$'\n' || return 1
    if (($(yq 'length' <<<"$json") < 100)); then
      break
    fi
  done
  tag=$(_newest_release_tag "${5:-}" "$2" "${6:-}" <<<"$matches") || return 1
  # A release created while the pages are read moves the last one of a page
  # to the next page as well
  for json in "${pages[@]}"; do
    release=$(TAG="$tag" yq -r '[.[] | select(.tag_name == strenv(TAG))][0]' <<<"$json")
    if [[ "$release" != null ]]; then
      printf '%s\n' "$release"
      return 0
    fi
  done
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

# Reject a value from the name of a release asset before it is written into
# a PKGBUILD, as validate_pkgver does for a version. bash expands a tilde at
# the start of an assignment, so the value starts with a letter or a digit.
# Args: $1=value
# Returns: 0=ok, 1=rejected (reason on stderr)
validate_asset_value() {
  local LC_ALL=C
  if [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]]; then
    log_err "Asset value rejected, it must start with a letter or a digit and hold only A-Za-z0-9 . _ + ~ -: ${1@Q}"
    return 1
  fi
}

# The --asset option of update-pkg.sh and publish-pkg.sh: a package with
# asset_var needs it, any other package must not get it
# Args: $1=asset_var of the package, $2=value of --asset
# Returns: 1 when one is set without the other or the value is rejected
check_asset_option() {
  if [[ -n "$1" && -z "$2" ]]; then
    log_err "upstream.asset_var is set, so --asset is needed"
    return 1
  fi
  if [[ -z "$1" && -n "$2" ]]; then
    log_err "--asset needs upstream.asset_var"
    return 1
  fi
  [[ -z "$2" ]] || validate_asset_value "$2"
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

# Print every tag name of a git repository, one per line, from git
# ls-remote over https only and without a terminal prompt
# Args: $1=HTTPS URL of the repository
remote_tags() {
  GIT_ALLOW_PROTOCOL=https GIT_TERMINAL_PROMPT=0 \
    git ls-remote --tags --refs "$1" | cut -f2 | sed 's|^refs/tags/||'
}

# Print every tag name of a GitHub repository, with GITHUB_TOKEN when it is
# set. The tags API answers 100 tags at most per page. git takes the token
# from the environment: as an argument, it is visible in ps to every local
# user.
# Args: $1=owner/repo
github_tags() {
  (
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraHeader
      GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)"
      export GIT_CONFIG_VALUE_0
    fi
    remote_tags "https://github.com/$1.git"
  )
}

# The newest of the versions on stdin, one per line, in the order of
# pacman: vercmp puts 2.1.0rc1 below 2.1.0, where sort -V puts it above.
# vercmp reads a dash as the pkgrel separator, so the comparison drops a
# dash before a letter, as pkgver_dash: '' does, and takes any other dash
# for a dot: 2.1.0-rc1 is below 2.1.0, and 2025-04-03 is 2025.04.03.
newest_version() {
  local version key newest="" newest_key=""
  while IFS= read -r version; do
    [[ -n "$version" ]] || continue
    key=$version
    while [[ "$key" =~ ^(.*)-([A-Za-z].*)$ ]]; do
      key=${BASH_REMATCH[1]}${BASH_REMATCH[2]}
    done
    key=${key//-/.}
    if [[ -z "$newest" ]] || (($(vercmp "$key" "$newest_key") > 0)); then
      newest=$version
      newest_key=$key
    fi
  done
  if [[ -n "$newest" ]]; then
    printf '%s\n' "$newest"
  fi
}

# The tags of the form v1.2.3 or 1.2.3, for a tag strategy without
# tag_version_regex. latest, 2.1.0-rc1 and 2.1.0rc1 are left out, so a
# pre-release is never the version.
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
  version=$(tag_versions "$regex" "$replace" <<<"$tags" | newest_version)
  if [[ -z "$version" ]]; then
    echo "No tag gives a version with upstream.tag_version_regex '$regex', tags read: $(grep -c . <<<"$1")" >&2
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

# Succeeds when grep -P compiles a Perl regex, as github-nightly reads the
# version out of a release body with it
# Args: $1=Perl regex
pcre_valid() {
  local rc=0
  # grep exits 2 for a pattern it cannot compile
  grep -qP -e "$1" </dev/null 2>/dev/null || rc=$?
  ((rc != 2))
}

# =============================================================================
# LOGGING
# =============================================================================

# The log functions write to stderr, so stderr decides the colors
if [[ -t 2 ]]; then
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
