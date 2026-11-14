#!/usr/bin/env bash
#
# common.sh - YAML, HTTP, version and logging helpers for strategies and scripts
#
# Usage: source "${SCRIPT_DIR}/../scripts/lib/common.sh"

set -euo pipefail

# The root of this checkout. The scripts and lib/version.sh read it.
# shellcheck disable=SC2034
AURTOMATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# AURTOMATOR_DATA_DIR is the folder of packages/ and .status/. The function sets
# it last, so the error names the value the caller gave.
resolve_data_dir() {
  local dir
  if ! dir="$(cd -- "${AURTOMATOR_DATA_DIR:-.}" 2>/dev/null && pwd)"; then
    echo "AURTOMATOR_DATA_DIR is not a directory: ${AURTOMATOR_DATA_DIR}" >&2
    exit 1
  fi
  AURTOMATOR_DATA_DIR="$dir"
}
resolve_data_dir

# === DEPENDENCY CHECK ===

require_cmd() {
  local cmd="$1" version
  if ! command -v "$cmd" &>/dev/null; then
    log_err "Required command not found: $cmd"
    exit 1
  fi
  # The yq of Arch extra is a jq wrapper with another expression syntax
  if [[ "$cmd" == yq ]] && version=$(yq --version 2>&1 | head -n 1) && [[ "$version" != *mikefarah/yq* ]]; then
    log_err "yq must be mikefarah/yq, go-yq on Arch, and this one prints: $version"
    exit 1
  fi
  # Releases of mikefarah/yq before 4.40.1 lack -r, document_index or kind
  if [[ "$cmd" == yq && $(Y=x yq -N -r '(.a | test(strenv(Y))) and document_index == 0 and (.a | kind) == "scalar"' <<<'a: x' 2>/dev/null) != true ]]; then
    log_err "yq is older than the scripts need, and this one prints: $version"
    exit 1
  fi
}

# === YAML (via yq) ===

# Read a field of a YAML file
# Usage: pkg_get packages/my-package.yml .upstream.type
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

# Print the pkgver_dash of a package: _, ., drop for '', or nothing when unset
# Usage: pkgver_dash packages/my-package.yml
pkgver_dash() {
  local file="$1" dash
  [[ $(pkg_get "$file" '.pkgver_dash | tag') != "!!null" ]] || return 0
  dash=$(pkg_get "$file" '.pkgver_dash')
  printf '%s\n' "${dash:-drop}"
}

# The pkgver of upstream version $1: pkgver_dash $2 in place of each dash, none
# for drop, and the result in the %s of pkgver_format $3. Both may be empty.
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

# Print upstream.asset_var of package file $1, or fail for a name that does not
# match ^_[A-Za-z0-9_]+$. The name reaches a sed command and an awk program.
pkg_asset_var() {
  local var LC_ALL=C
  var=$(pkg_get "$1" '.upstream.asset_var // ""')
  if [[ -n "$var" && ! "$var" =~ ^_[A-Za-z0-9_]+$ ]]; then
    log_err "$1: upstream.asset_var must be a name that starts with _: ${var@Q}"
    return 1
  fi
  printf '%s\n' "$var"
}

# === PACKAGE HELPERS ===

# Print the YAML path of a package, or fail when the file does not exist
# Usage: pkg_file my-package
pkg_file() {
  local name="$1"
  local file="${AURTOMATOR_DATA_DIR}/packages/${name}.yml"
  if [[ ! -f "$file" ]]; then
    log_err "Package not found: $file"
    return 1
  fi
  echo "$file"
}

# === HTTP ===

# The User-Agent of every strategy request, which webpage-scrape.sh replaces with
# upstream.user_agent. SourceForge answers a bare Mozilla/5.0 with HTTP 403.
USER_AGENT="aurtomator/1.0"

# What curl writes to stderr on a failure: the URL of the last answer, the
# error, the status (000 without an answer) and the cf-mitigated header
HTTP_FAILURE='%{onerror}%{stderr}%{url_effective}\t%{errormsg}\t%{http_code}\t%header{cf-mitigated}'

# The size limit of one answer in megabytes: upstream.max_answer_mb, which
# check-update.sh exports, or 50
MAX_ANSWER_MB="${MAX_ANSWER_MB:-}"

# Prints upstream.max_answer_mb of package file $1, nothing without it, and
# fails for a value that is no whole number from 1 to 500
max_answer_mb() {
  local mb
  mb=$(pkg_get "$1" '.upstream.max_answer_mb // ""') || return 1
  [[ -n "$mb" ]] || return 0
  if [[ ! "$mb" =~ ^[1-9][0-9]{0,2}$ ]] || ((mb > 500)); then
    log_err "upstream.max_answer_mb must be a whole number from 1 to 500: $mb"
    return 1
  fi
  printf '%s\n' "$mb"
}

# check-all.sh keeps two files in AURTOMATOR_HOSTS_DIR: silent lists the hosts
# that did not answer in the run, and request holds the request in flight

# Succeeds in a run of check-all.sh that keeps these files
host_memory() {
  [[ -n "${AURTOMATOR_HOSTS_DIR:-}" && -d "$AURTOMATOR_HOSTS_DIR" ]]
}

# Succeeds when text $1 holds a control character other than a tab, C1 ones in UTF-8 included
has_control() {
  local re=$'[\x01-\x08\x0a-\x1f\x7f]|\xc2[\x80-\x9f]'
  (LC_ALL=C && [[ "$1" =~ $re ]])
}

# Print the host of https URL $1 in lower case. A URL with a user name or a
# port gives none, since curl contacts another host or port than the name
url_host() {
  # A UTF-8 locale other than C.UTF-8 lets [A-Za-z] take letters such as é
  local LC_ALL=C
  [[ "$1" =~ ^https://([A-Za-z0-9.-]+)([/?#]|$) ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1],,}"
}

# Start a request to URL $1, with URL $2 for the HEAD check after a kill. Fails
# for a host that did not answer earlier in the run, with the reason on stderr
request_begin() {
  local host authority="${1#*://}" beyond='[^ -~]'
  authority=${authority%%[/?#]*}
  # curl maps such a host to an ASCII host, which url_host and host memory would not see
  if (LC_ALL=C && [[ "$authority" =~ $beyond ]]); then
    printf '%s: the host holds a character beyond ASCII\n' "$1" >&2
    return 1
  fi
  if ! host_memory || ! host=$(url_host "$1"); then
    return 0
  fi
  if grep -qxF -e "$host" "$AURTOMATOR_HOSTS_DIR/silent"; then
    printf '%s: %s did not answer earlier in this run\n' "$1" "$host" >&2
    return 1
  fi
  printf '%s\n%s\n' "$1" "${2:-$1}" >"$AURTOMATOR_HOSTS_DIR/request"
}

# request_begin for git URL $1: the HEAD check asks the first URL that git asks
git_request_begin() {
  request_begin "$1" "${1%/}/info/refs?service=git-upload-pack"
}

# End the request that request_begin started
request_end() {
  if host_memory; then
    : >"$AURTOMATOR_HOSTS_DIR/request"
  fi
}

# Remember the host of URL $1 as one that did not answer in this run
remember_host() {
  local host
  if host_memory && host=$(url_host "$1"); then
    printf '%s\n' "$host" >>"$AURTOMATOR_HOSTS_DIR/silent"
  fi
}

# Args: $1=URL, the rest: curl options, which come after these and win
_curl_get() {
  curl -sfL --max-time 30 --retry 2 --retry-delay 5 --retry-connrefused \
    --proto '=https' --proto-redir '=https' --max-filesize "${MAX_ANSWER_MB:-50}M" \
    -A "$USER_AGENT" -w "$HTTP_FAILURE" "${@:2}" "$1"
}

# GET a URL for a strategy. A failure prints the URL of the last answer and the error.
# Usage: http_get <url> [curl option]...
http_get() {
  local failure rc=0 url error code mitigated
  request_begin "$1" || return 28
  # stdout goes out through fd 3, and stderr into failure
  { failure=$(_curl_get "$@" 2>&1 >&3 3>&-); } 3>&1 || rc=$?
  request_end
  if ((rc == 0)); then
    return 0
  fi
  if [[ "$failure" == *$'\t'* ]]; then
    IFS=$'\t' read -r url error code mitigated <<<"$failure"
    failure="${url}: ${error}"
    if [[ "$mitigated" == challenge ]]; then
      failure+=", a Cloudflare challenge, which only a browser passes"
    fi
    # Three attempts without any answer: the run asks this host nothing more
    if ((rc == 28)) && [[ "$code" == 000 ]]; then
      remember_host "$1"
    fi
  elif [[ -z "$failure" ]]; then
    failure="${1}: curl exit ${rc}"
  fi
  printf '%s\n' "$failure" >&2
  return "$rc"
}

# GET a URL that answers JSON. A bot check answers HTML with HTTP 200, so an answer
# other than a JSON object or array fails and names the URL it came from.
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

# GET a GitHub API URL with GITHUB_TOKEN when it is set. curl reads the header
# from stdin, since ps shows every argument to every local user.
github_api() {
  local auth=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth=(-H @-)
  fi
  http_get "$1" "${auth[@]}" <<<"Authorization: Bearer ${GITHUB_TOKEN:-}"
}

# Print published_at<TAB>tag of each release in JSON $1 that passes yq filter $3
# and whose tag matches ERE $2
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
# stdin: the one published last, or the one with the newest version
# Args: $1="version" to pick by version, $2=ERE, $3=tag_version_replace
_newest_release_tag() {
  if [[ "${1:-}" == version ]]; then
    cut -f2 | _newest_tag "$2" "${3:-}"
  else
    sort | tail -1 | cut -f2
  fi
}

# Print the tag on stdin, one per line, that gives the newest version
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

# Print as JSON the matching release published last, or the one with the newest
# version. The API sorts by commit date, so the choice spans every page read.
# Args: $1=API URL of the repository, $2=ERE, $3=most pages of 100 to read,
#       $4="stable" to skip pre-releases, $5="version", $6=tag_version_replace
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
  # A release created between two reads repeats the last release of a page on
  # the next one, so the loop looks the tag up in every page
  for json in "${pages[@]}"; do
    release=$(TAG="$tag" yq -r '[.[] | select(.tag_name == strenv(TAG))][0]' <<<"$json")
    if [[ "$release" != null ]]; then
      printf '%s\n' "$release"
      return 0
    fi
  done
}

# === VERSIONS AND TAGS ===

# The character limit of a version, for a README cell and the journal
PKGVER_MAX=64

# Reject version $1 before sed writes it into a PKGBUILD that makepkg sources,
# where a shell metacharacter of an upstream tag would run in CI
validate_pkgver() {
  local ver="$1"
  local LC_ALL=C
  if [[ -z "$ver" ]]; then
    log_err "Version string is empty"
    return 1
  fi
  if ((${#ver} > PKGVER_MAX)); then
    log_err "Version string rejected, it has ${#ver} characters and at most ${PKGVER_MAX} are allowed"
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

# Reject value $1 from a release asset name before it goes into a PKGBUILD. bash
# expands a leading ~ in an assignment, so the value starts with a letter or digit.
validate_asset_value() {
  local LC_ALL=C
  if [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]]; then
    log_err "Asset value rejected, it must start with a letter or a digit and hold only A-Za-z0-9 . _ + ~ -: ${1@Q}"
    return 1
  fi
}

# Check --asset value $2 against asset_var $1: a package with asset_var needs it,
# and any other package must not get it
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

# Succeeds when the first number of new version $2 has at least two digits more
# than the first number of current version $1, as from 13 to 2026102100
version_jump() {
  local old new
  [[ "$1" =~ [0-9]+ ]] || return 1
  old="${BASH_REMATCH[0]}"
  [[ "$2" =~ [0-9]+ ]] || return 1
  new="${BASH_REMATCH[0]}"
  ((${#new} >= ${#old} + 2))
}

# Succeeds when $1 is a real date in the form YYYY-MM-DD
valid_date() {
  [[ "$(date -u -d "$1" +%F 2>/dev/null)" == "$1" ]]
}

# Succeeds when $1 is a real UTC time in the form YYYY-MM-DDTHH:MM:SSZ
valid_time() {
  [[ "$(date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" == "$1" ]]
}

# Prints the first day, YYYY-MM-DD, on which package file $1 may be pushed
# again, or nothing without a cooldown. Returns 1 when a field is not valid.
cooldown_until() {
  local file="$1" days last
  days=$(pkg_get "$file" '.cooldown_days // ""')
  if [[ -z "$days" ]]; then
    days=0
    [[ "$(pkg_get "$file" .strategy)" != git-latest ]] || days=7
  fi
  # Only digits reach (( )): bash runs $(...) in an array subscript there
  if [[ ! "$days" =~ ^(0|[1-9][0-9]{0,2})$ ]] || ((days > 365)); then
    echo "cooldown_days must be a whole number from 0 to 365: $days" >&2
    return 1
  fi
  last=$(pkg_get "$file" '.last_updated // ""')
  if ((days == 0)) || [[ -z "$last" ]]; then
    return 0
  fi
  if ! valid_date "$last"; then
    echo "last_updated must be a date YYYY-MM-DD: $last" >&2
    return 1
  fi
  date -u -d "$last + $days days" +%F
}

# Print the tag names of the git repository at HTTPS URL $1, one per line
remote_tags() {
  local rc=0
  git_request_begin "$1" || return 1
  GIT_ALLOW_PROTOCOL=https GIT_TERMINAL_PROMPT=0 \
    git ls-remote --tags --refs "$1" | cut -f2 | sed 's|^refs/tags/||' || rc=$?
  request_end
  return "$rc"
}

# Print the tag names of GitHub repository $1, owner/repo, with GITHUB_TOKEN when
# it is set. git reads the token from the environment, since ps shows arguments.
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

# Print the newest version on stdin by vercmp, which splits off pkgrel at a dash.
# The comparison drops a dash before a letter and turns any other dash into a dot.
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

# The tags of the form v1.2.3 or 1.2.3 among tags $1, one per line. A tag strategy
# without tag_version_regex reads only these, so a pre-release is never the version.
release_tags() {
  grep -E '^v?[0-9]+(\.[0-9]+)*$' <<<"$1" || true
}

# Print tag_version_replace $1 with \1 to \9 filled from the groups in BASH_REMATCH.
# Fails when it names a group the regex does not have.
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

# The version in each tag on stdin, one per line: tag_version_replace filled from
# the groups of tag_version_regex, or with no regex the tag minus a leading v
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

# The highest version among the tags of a tag strategy. Without tag_version_regex
# only the tags of the form v1.2.3 or 1.2.3 count.
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

# Print the first capture group of every match of ERE $1 in stdin. bash takes the
# group, so no sed delimiter limits the pattern.
capture_matches() {
  local pattern="$1" match
  while IFS= read -r match; do
    if [[ "$match" =~ $pattern ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
  done < <(grep -oE -e "$pattern")
}

# Succeeds when bash accepts ERE $1, as capture_matches needs. bash refuses some
# patterns that grep -E takes, (?:x) and *x among them.
ere_valid() {
  local rc=0
  # [[ =~ ]] returns 2 for a pattern bash cannot compile
  # shellcheck disable=SC2319
  [[ "" =~ $1 ]] 2>/dev/null || rc=$?
  ((rc != 2))
}

# Succeeds when grep -P compiles Perl regex $1. github-nightly reads the version
# out of a release body with such a regex.
pcre_valid() {
  local rc=0
  # grep exits 2 for a pattern it cannot compile
  grep -qP -e "$1" </dev/null 2>/dev/null || rc=$?
  ((rc != 2))
}

# === LOGGING ===

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
