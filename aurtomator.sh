#!/usr/bin/env bash
release=0.16.0 # x-release-please-version
#
# Runs a script of aurtomator for this repository, at the commit that
# .github/workflows/check-updates.yml pins:
#
#   ./aurtomator.sh setup                 scripts/setup.sh
#   ./aurtomator.sh draft <name>          scripts/draft.sh <name>
#   ./aurtomator.sh validate-pkg <name>   scripts/validate-pkg.sh <name>
#   ./aurtomator.sh check-update <name>   scripts/check-update.sh <name>
#   ./aurtomator.sh update-pkg <name> <version> --dry-run
#   ./aurtomator.sh check-all             scripts/check-all.sh
#   ./aurtomator.sh sample                prints packages/example.yml.sample
#   ./aurtomator.sh pin vX.Y.Z            pins the calling workflows to a release
#   ./aurtomator.sh check-pins            checks each pin against its release tag
#   ./aurtomator.sh version               prints the releases of this file and of the pin
#
# The first run of a pin fetches aurtomator at that commit into
# ~/.cache/aurtomator/<sha>, or $XDG_CACHE_HOME/aurtomator/<sha>.

set -euo pipefail

if ! command -v yq >/dev/null; then
  echo "$0 needs yq: https://github.com/mikefarah/yq" >&2
  exit 1
fi
# extra/yq of Arch is a jq wrapper and reads jq expressions
yq_version=$(yq --version 2>&1 || true)
if [[ "$yq_version" != *mikefarah/yq* ]]; then
  echo "$0 needs mikefarah/yq, go-yq on Arch, and this yq prints: ${yq_version%%$'\n'*}" >&2
  exit 1
fi
# Releases of mikefarah/yq before 4.40.1 lack -r, document_index or kind
if [[ $(Y=x yq -N -r '(.a | test(strenv(Y))) and document_index == 0 and (.a | kind) == "scalar"' <<<'a: x' 2>/dev/null) != true ]]; then
  echo "$0 needs a newer mikefarah/yq, and this yq prints: ${yq_version%%$'\n'*}" >&2
  exit 1
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflow=.github/workflows/check-updates.yml
if [[ ! -f "$root/$workflow" ]]; then
  echo "No $workflow in $root" >&2
  exit 1
fi
# yq takes the last of two equal keys, lets a merge key override a key and
# reads every document, so it can read a pin the uses: line does not show
check_shape() {
  local file="$root/$1" out count
  if ! out=$(yq -N 'document_index' "$file" 2>&1); then
    echo "yq cannot read $1:" >&2
    printf '  %s\n' "${out//$'\n'/$'\n  '}" >&2
    exit 1
  fi
  if [[ $(wc -l <<<"$out") -gt 1 ]]; then
    echo "$1 holds more than one YAML document" >&2
    exit 1
  fi
  count=$(yq -N '[.. | select(tag == "!!map") | keys | .[] | select(tag == "!!merge")] | length' "$file")
  if [[ "$count" != 0 ]]; then
    echo "$1 holds a merge key (<<)" >&2
    exit 1
  fi
  count=$(yq -N '[.. | select(tag == "!!map") | select((keys | length) != (keys | unique | length))] | length' "$file")
  if [[ "$count" != 0 ]]; then
    echo "$1 holds a key twice in one mapping" >&2
    exit 1
  fi
}
# Tagged values show no plain uses: line, and GitHub runs no workflow with one today
check_tags() {
  local tags
  tags=$(yq -r 'explode(.) | [.jobs[] | (.uses, .steps[]?.uses) | select(. != null) | tag | select(. != "!!str")] | unique | join(" ")' "$root/$1")
  if [[ -n "$tags" ]]; then
    echo "$1 holds a uses: value with the tag $tags; write every uses: value as plain text" >&2
    exit 1
  fi
}
# git for the copy of aurtomator, without the variables that hooks of the user repository set
cache_git() (
  # shellcheck disable=SC2046
  unset $(git rev-parse --local-env-vars)
  git "$@"
)
# The repository of aurtomator, which every pin of the calling workflows names; a
# fork writes its own here, and each run copies this file of the pinned commit
repo=staticwire/aurtomator

# Print in lower case the owner/name that GitHub reads from uses: value $1: the
# first two parts of its path, split on / and \ with the empty parts dropped
uses_repo() {
  local LC_ALL=C part path="${1%%@*}"
  local -a parts kept=()
  IFS=/ read -r -a parts <<<"${path//\\//}"
  for part in "${parts[@]}"; do
    [[ -z "$part" ]] || kept+=("${part,,}")
  done
  ((${#kept[@]} < 2)) || printf '%s/%s\n' "${kept[0]}" "${kept[1]}"
}

# Succeeds for a uses: value that GitHub reads as one of this repository
names_repo() {
  local LC_ALL=C
  [[ "$(uses_repo "$1")" == "${repo,,}" ]]
}

# Succeeds for a uses: value of this repository written as GitHub shows its name
plain_uses() {
  local LC_ALL=C
  [[ "${1,,}" == "${repo,,}"[/@]* && "$1" != *//* && "$1" != *\\* ]]
}

# Succeeds for a uses: value that names a reusable workflow of a repository, not one
# of the calling repository: its path holds .github/workflows in any case and spelling
names_workflow() {
  local LC_ALL=C part path=""
  local -a parts
  [[ "$1" != ./* ]] || return 1
  IFS=/ read -r -a parts <<<"${1//\\//}"
  for part in "${parts[@]}"; do
    [[ -z "$part" || "$part" == . ]] || path+="/${part,,}"
  done
  [[ "$path" == /*/.github/workflows/* ]]
}

check_shape "$workflow"
check_tags "$workflow"
# The pin comes from one uses: line, never a comment
uses='^[[:space:]]*uses:[[:space:]]+([[:alnum:]_.-]+/[[:alnum:]_.-]+)/\.github/workflows/check-updates\.yml@([0-9a-f]{40})([[:space:]]|$)'
mapfile -t pins < <(grep -E "$uses" "$root/$workflow" || true)
if [[ ${#pins[@]} -gt 1 ]]; then
  echo "More than one uses: line pins check-updates.yml in $workflow" >&2
  exit 1
fi
# GitHub reads YAML, where a pin in quotes counts and a line in a text does
# not, so yq has to read the same one pin
read_out=$(yq -r 'explode(.) | .jobs[].uses | select(. != null) | select(test("/[.]github/workflows/check-updates[.]yml@"))' "$root/$workflow")
if [[ ${#pins[@]} -eq 0 ]] && ! grep -qE '@[0-9a-f]{40}$' <<<"$read_out"; then
  echo "No commit SHA pinned in $workflow" >&2
  exit 1
fi
pin_repo="" sha=""
if [[ ${#pins[@]} -eq 1 && "${pins[0]}" =~ $uses ]]; then
  pin_repo="${BASH_REMATCH[1]}"
  sha="${BASH_REMATCH[2]}"
fi
mapfile -t read_pins <<<"$read_out"
if [[ ${#read_pins[@]} -ne 1 || "${read_pins[0]}" != "$pin_repo/.github/workflows/check-updates.yml@$sha" ]]; then
  echo "Write the pin of check-updates.yml in $workflow on one uses: line without quotes. GitHub reads:" >&2
  printf '  %s\n' "${read_pins[@]:-none}" >&2
  exit 1
fi
if ! names_repo "$pin_repo"; then
  echo "$workflow pins $pin_repo, and this aurtomator.sh runs the pins of $repo only" >&2
  exit 1
fi

# Print the commit of the tag $1 of the repository; an annotated tag names its
# commit on the line of <tag>^{}
tag_commit() {
  git ls-remote --tags "https://github.com/$repo" |
    awk -v ref="refs/tags/$1" '$2 == ref || $2 == ref "^{}" { sha = $1 } END { print sha }'
}

# Stop unless the tag $1 of the repository has a published release, immutable after v0.14.0:
# tags stand before their release is published, and stay when the release run stops
check_published() {
  local auth=() answer code body message
  [[ -z "${GITHUB_TOKEN:-}" ]] || auth=(-H @-)
  # curl reads the header from stdin, since ps shows every argument to every local user
  if ! answer=$(curl -qgsSL --proto '=https' --max-time 30 -w '\n%{http_code}' \
    -H 'Accept: application/vnd.github+json' "${auth[@]}" "https://api.github.com/repos/$repo/releases/tags/$1" \
    <<<"Authorization: Bearer ${GITHUB_TOKEN:-}"); then
    echo "Could not ask the GitHub API for the release $1 of $repo" >&2
    exit 1
  fi
  code=${answer##*$'\n'} body=${answer%$'\n'*}
  if [[ "$code" != 200 && "$code" != 404 ]]; then
    message=$(yq -p json -r '.message // ""' <<<"$body" 2>/dev/null) || message=""
    message="${message:+: ${message%%$'\n'*}}"
    # GitHub limits requests without a token by address, and answers 403 or 429 past the limit
    if [[ -z "${GITHUB_TOKEN:-}" && ("$code" == 403 || "$code" == 429) ]]; then
      message+="; set GITHUB_TOKEN to a GitHub token for a higher limit"
    fi
    echo "The GitHub API answered HTTP $code for the release $1 of $repo$message" >&2
    exit 1
  fi
  if [[ "$code" == 404 || "$(T="$1" yq -p json -r '.tag_name == strenv(T) and .draft == false' <<<"$body" 2>/dev/null)" != true ]]; then
    echo "No published release $1 of $repo; pins name the commit of a published release" >&2
    exit 1
  fi
  if [[ "$(printf '%s\n' v0.14.0 "$1" | sort -V | tail -n 1)" != v0.14.0 &&
  "$(yq -p json -r '.immutable == true' <<<"$body" 2>/dev/null)" != true ]]; then
    echo "GitHub shows the release $1 of $repo as mutable, and aurtomator publishes every release after v0.14.0 as immutable" >&2
    exit 1
  fi
}

# Stop unless the pin $3 on the uses: line $2 of file $1 is the commit of the release written after
# it, since GitHub serves the commits of every fork under the name of its parent; $4 tags skips the API
check_release() {
  local release_re="@${3}[[:space:]]+#[[:space:]]*(v[0-9]+[.][0-9]+[.][0-9]+)([[:space:]]|\$)" tag tagged
  if [[ ! "$2" =~ $release_re ]]; then
    echo "Write the release after the pin in $1, as ./aurtomator.sh pin vX.Y.Z does: @$3 # vX.Y.Z" >&2
    exit 1
  fi
  tag="${BASH_REMATCH[1]}"
  if ! tagged=$(tag_commit "$tag"); then
    echo "Could not list the tags of $repo" >&2
    exit 1
  fi
  if [[ "$tagged" != "$3" ]]; then
    echo "The pin $3 in $1 is not the commit of $tag of $repo; ./aurtomator.sh pin vX.Y.Z pins the commit of a release" >&2
    exit 1
  fi
  [[ "${4:-}" == tags ]] || check_published "$tag"
}

if [[ "${1:-}" == pin ]]; then
  if [[ $# -ne 2 || ! "$2" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 pin vX.Y.Z" >&2
    exit 1
  fi
  if ! new=$(tag_commit "$2"); then
    echo "Could not list the tags of $repo" >&2
    exit 1
  fi
  if [[ -z "$new" ]]; then
    echo "No tag $2 in $repo" >&2
    exit 1
  fi
  if [[ ! "$new" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Tag $2 of $repo names no commit SHA" >&2
    exit 1
  fi
  check_published "$2"
  cd "$root"
  # sed moves a pin on a uses: line alone, so every pin GitHub reads in the two files, of jobs
  # and of steps, has to be on one before any file changes. GitHub reads the repository in any case.
  pinned="$repo(/[^@[:space:]]*)?@"
  for file in "$workflow" .github/workflows/validate.yml; do
    [[ -f "$file" ]] || continue
    check_shape "$file"
    check_tags "$file"
    mapfile -t on_lines < <(sed -nE "s|^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+(${pinned}[0-9a-f]{40})([[:space:]].*)?$|\2|Ip" "$file" | sort)
    read_out=$(yq -r 'explode(.) | .jobs[] | (.uses, .steps[]?.uses) | select(. != null)' "$file")
    mapfile -t read_pins < <(grep -iE "^${pinned}[0-9a-f]{40}\$" <<<"$read_out" | sort)
    if [[ "${on_lines[*]}" != "${read_pins[*]}" ]]; then
      echo "Write each pin of $repo in $file on one uses: line without quotes. GitHub reads:" >&2
      printf '  %s\n' "${read_pins[@]:-none}" >&2
      exit 1
    fi
  done
  for file in "$workflow" .github/workflows/validate.yml; do
    [[ -f "$file" ]] || continue
    sed -i -E "s|^([[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+$pinned)[0-9a-f]{40}([[:space:]].*)?$|\1$new # $2|I" "$file"
    grep -nHiE "^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+$pinned$new # $2\$" "$file" || true
  done
  exit 0
fi

if [[ "${1:-}" == check-pins ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 check-pins" >&2
    exit 1
  fi
  cd "$root"
  use_re='^[0-9]+:[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+([^[:space:]]+)'
  release_re='#[[:space:]]*(v[0-9]+[.][0-9]+[.][0-9]+)'
  # The merge commit of a pull request has the base branch as its first parent, which a checkout
  # of one commit leaves out and GitHub serves by the SHA of the merge commit
  base=""
  if [[ "${GITHUB_EVENT_NAME:-}" == pull_request* ]] && ! base=$(git rev-parse --verify -q 'HEAD^1^{commit}' 2>/dev/null); then
    git fetch -q --no-tags --depth=2 origin "$(git rev-parse HEAD)" 2>/dev/null || true
    if ! base=$(git rev-parse --verify -q 'HEAD^1^{commit}' 2>/dev/null); then
      echo "The checkout holds no parent of the merge commit, and git could not fetch it, so check-pins cannot compare the pins with the base branch; add fetch-depth: 2 to the checkout of the job pins" >&2
      exit 1
    fi
  fi
  # Runners share the addresses that the GitHub API limits without a token, and the job image of
  # each workflow checks the release with the token of the run
  scope=api
  [[ -n "${GITHUB_TOKEN:-}" ]] || scope=tags
  checked=()
  for file in "$workflow" .github/workflows/validate.yml; do
    [[ -f "$file" ]] || continue
    # The newest release that the base branch pins in this file
    base_release=""
    if [[ -n "$base" ]]; then
      base_release=$(git show "$base:$file" 2>/dev/null |
        grep -oiE "^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+${repo}[^@[:space:]]*@[0-9a-f]{40}[[:space:]]+${release_re}" |
        grep -oE 'v[0-9]+[.][0-9]+[.][0-9]+$' | sort -V | tail -n 1) || base_release=""
    fi
    check_shape "$file"
    check_tags "$file"
    # Jobs run a workflow, local or of this repository, and pass it the secrets they name
    job_uses=$(yq -r 'explode(.) | .jobs[].uses | select(. != null)' "$file")
    while IFS= read -r value; do
      if [[ -n "$value" && "$value" != ./* ]] && ! names_repo "$value"; then
        echo "$file runs $value, a workflow of another repository than $repo" >&2
        exit 1
      fi
    done <<<"$job_uses"
    # The release comes from the uses: line, so every pin GitHub reads has to be on one
    read_out=$(yq -r 'explode(.) | .jobs[] | (.uses, .steps[]?.uses) | select(. != null)' "$file")
    read_pins=() values=() lines=()
    while IFS= read -r value; do
      if names_repo "$value"; then
        read_pins+=("$value")
      elif names_workflow "$value"; then
        echo "$file runs $value, a workflow of another repository than $repo" >&2
        exit 1
      fi
    done < <(sort <<<"$read_out")
    while IFS= read -r line; do
      if [[ "$line" =~ $use_re ]] && names_repo "${BASH_REMATCH[2]}"; then
        values+=("${BASH_REMATCH[2]}")
        lines+=("$line")
      fi
    done < <(grep -nE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]' "$file" || true)
    if [[ "$(printf '%s\n' "${values[@]}" | sort)" != "$(printf '%s\n' "${read_pins[@]}")" ]]; then
      echo "Write each pin of $repo in $file on one uses: line without quotes. GitHub reads:" >&2
      printf '  %s\n' "${read_pins[@]:-none}" >&2
      exit 1
    fi
    for i in "${!lines[@]}"; do
      if ! plain_uses "${values[i]}"; then
        echo "$file writes the pin ${values[i]} of $repo with an extra slash or a backslash; write it as $repo/<path>@<sha>" >&2
        exit 1
      fi
      if [[ ! "${values[i]}" =~ @([0-9a-f]{40})$ ]]; then
        echo "$file runs ${values[i]}, which names no commit SHA" >&2
        exit 1
      fi
      check_release "$file" "${lines[i]}" "${BASH_REMATCH[1]}" "$scope"
      # Older releases miss the fixes made since, and the jobs with the secrets would run them
      if [[ -n "$base_release" && "${lines[i]}" =~ $release_re ]] &&
        [[ "$(printf '%s\n' "${BASH_REMATCH[1]}" "$base_release" | sort -V | head -n 1)" != "$base_release" ]]; then
        echo "$file moves the pin of $repo from $base_release of the base branch back to ${BASH_REMATCH[1]}; pull requests move pins forward alone" >&2
        exit 1
      fi
      checked+=("$file:${lines[i]}")
    done
  done
  printf '%s\n' "${checked[@]}"
  exit 0
fi

# The XDG Base Directory Specification calls a relative path invalid, to be ignored
cache="${XDG_CACHE_HOME:-}"
[[ "$cache" == /* ]] || cache="$HOME/.cache"
# Links in the path could change between the checks and the run, so the run takes their target once
if [[ -d "$cache" ]]; then
  cache=$(cd -P -- "$cache" && pwd -P) || exit 1
fi
copy="$cache/aurtomator/$sha"
# User namespaces show the accounts they do not map, root of the host among them, with this uid
overflow_uid=$(cat /proc/sys/kernel/overflowuid 2>/dev/null) || overflow_uid=65534
# Namespaces that map no uid show this uid for every file, so each owner check would pass
if [[ "$(id -u)" == "$overflow_uid" ]]; then
  echo "Your uid is $overflow_uid, which a user namespace gives the accounts it does not map, so the script cannot tell whether another account could swap the copy of aurtomator; run the script outside the namespace, or in one that maps your uid" >&2
  exit 1
fi
home=""
if [[ "${HOME:-}" == /* ]]; then
  home=$(cd -P -- "$HOME" 2>/dev/null && pwd -P) || home=""
fi
# Succeeds for directory $1 that shows the overflow uid as its owner and gives group and others
# no write access, or has the sticky bit
unmapped_dir() {
  local owner mode
  read -r owner mode < <(stat -c '%u %a' -- "$1") || return 1
  mode=$((8#$mode))
  [[ "$owner" == "$overflow_uid" ]] && ((! (mode & 8#022) || mode & 8#1000))
}
# Whoever can rename what a directory above the home directory holds can swap the home directory
# and every file the shell runs, so such directories may show an unmapped owner
above_home() {
  [[ -n "$home" && ("$1" == / || "$home" == "$1"/*) ]]
}
# Succeeds when no other account can rename what directory $1 holds: it is no link, belongs to the user and
# gives group and others no write access; with $2=shared root may own it, and a sticky bit as on /tmp counts
private_dir() {
  local owner mode
  [[ -d "$1" && ! -L "$1" ]] && read -r owner mode < <(stat -c '%u %a' -- "$1") || return 1
  mode=$((8#$mode))
  if [[ "${2:-}" == shared ]]; then
    [[ "$owner" == "$(id -u)" || "$owner" == 0 ]] && ((! (mode & 8#022) || mode & 8#1000))
  else
    [[ "$owner" == "$(id -u)" ]] && ((! (mode & 8#022)))
  fi
}
# Accounts that can rename what these directories hold could swap the copy between its check and its run
check_cache_dirs() {
  local dir kind=shared
  for dir in "$cache" "${copy%/*}"; do
    if [[ -L "$dir" ]]; then
      echo "$dir is a link, which its owner could point elsewhere before the copy of aurtomator in it runs; make it a directory, or set XDG_CACHE_HOME to another directory" >&2
      exit 1
    fi
    if ! private_dir "$dir" "$kind"; then
      echo "$dir belongs to another account or lets group or others write it, and they could swap the copy of aurtomator in it before it runs; make it yours with no write access for group and others, or set XDG_CACHE_HOME to another directory" >&2
      exit 1
    fi
    kind=""
  done
  # The path of the cache holds no link here, and each directory above can rename the cache whole
  dir=$cache
  while [[ "$dir" == /?* ]]; do
    dir=${dir%/*}
    private_dir "${dir:-/}" shared && continue
    if unmapped_dir "${dir:-/}"; then
      above_home "${dir:-/}" && continue
      echo "${dir:-/} shows the owner $overflow_uid, which a user namespace gives the accounts it does not map, so the script cannot tell whether another account could swap the copy of aurtomator below it; set XDG_CACHE_HOME to a directory below your home directory, or run the script outside the namespace" >&2
      exit 1
    fi
    echo "${dir:-/} belongs to another account or lets group or others write it, and they could swap the copy of aurtomator below it before it runs; set XDG_CACHE_HOME to a directory with no such directory above it" >&2
    exit 1
  done
}
# Succeeds when the copy is the checkout of the pin as the fetch left it, which only the user can write.
# git status skips files under the assume-unchanged and skip-worktree bits, which ls-files -v shows.
copy_ok() {
  local status flagged
  [[ -d "$copy" && ! -L "$copy" && -O "$copy" && -z "$(find "$copy" ! -type l -perm /022 -print -quit 2>/dev/null)" ]] &&
    [[ "$(cache_git -C "$copy" rev-parse HEAD 2>/dev/null)" == "$sha" ]] &&
    status=$(GIT_OPTIONAL_LOCKS=0 cache_git -C "$copy" status --porcelain --untracked-files=all --ignored 2>/dev/null) &&
    [[ -z "$status" ]] &&
    flagged=$(cache_git -C "$copy" ls-files -v 2>/dev/null) &&
    [[ -z "$(sed '/^H /d' <<<"$flagged")" ]]
}
[[ ! -e "${copy%/*}" && ! -L "${copy%/*}" ]] || check_cache_dirs
if [[ -e "$copy" || -L "$copy" ]] && ! copy_ok; then
  if [[ -L "$copy" || ! -O "$copy" ]]; then
    echo "$copy is a link or belongs to another user; remove it, then run $0 again" >&2
    exit 1
  fi
  echo "The copy of aurtomator in $copy is damaged or writable by others, so it is fetched again" >&2
  rm -rf -- "$copy"
fi
if [[ ! -d "$copy" ]]; then
  check_release "$workflow" "${pins[0]}" "$sha"
  # Places that the check below refuses keep none of the directories this run makes, which rmdir
  # takes deepest first
  made=()
  dir=${copy%/*}
  while [[ ! -e "$dir" && ! -L "$dir" ]]; do
    made+=("$dir")
    dir=${dir%/*}
  done
  ((${#made[@]} == 0)) || trap 'rmdir -- "${made[@]}" 2>/dev/null' EXIT
  # The XDG Base Directory Specification asks for mode 0700, which a umask of 0002 would not give
  (umask 077 && mkdir -p "${copy%/*}")
  # New caches get their path at the target of links here, as existing ones did above
  cache=$(cd -P -- "$cache" && pwd -P) || exit 1
  copy="$cache/aurtomator/$sha"
  check_cache_dirs
  tmp="$(mktemp -d "$copy.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  cache_git -C "$tmp" init -q
  cache_git -C "$tmp" fetch -q --depth 1 "https://github.com/$repo" "$sha"
  cache_git -C "$tmp" -c core.autocrlf=false -c core.eol=lf checkout -q FETCH_HEAD
  chmod -R go-w "$tmp"
  # Runs that started at the same time can make the copy first, and so can other accounts
  # that write the cache
  mv -T "$tmp" "$copy" 2>/dev/null || rm -rf "$tmp"
  if ! copy_ok; then
    echo "$copy appeared during the fetch and is no checkout of $sha that only you can write; remove it, then run $0 again" >&2
    exit 1
  fi
  # Copies that no run used for 30 days go, and so do the fetch directories that SIGKILL leaves.
  # Runs at the same time can remove their own directory while find reads.
  find "${copy%/*}" -mindepth 1 -maxdepth 1 -regextype posix-extended -regex '.*/[0-9a-f]{40}([.][A-Za-z0-9]{6})?' -mtime +30 \
    -exec rm -rf -- {} + 2>/dev/null || true
fi
# Each run sets the time of its copy, since another repository on this cache can run a copy that
# it fetched long ago when a new pin cleans the cache
touch -c -- "$copy" 2>/dev/null || true

# The documented commands. Another script of scripts/ is a step of the CI
# jobs and runs after a warning.
commands=(setup draft sample validate-pkg check-update update-pkg check-all pin check-pins version)
cmd="${1:-}"
if [[ "$cmd" == sample ]]; then
  exec cat "$copy/packages/example.yml.sample"
fi
if [[ "$cmd" == version ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 version" >&2
    exit 1
  fi
  pinned=$(<"$copy/VERSION")
  printf 'aurtomator.sh %s\ncheck-updates.yml %s\n' "$release" "$pinned"
  exit 0
fi
if [[ ! "$cmd" =~ ^[a-z]+(-[a-z]+)*$ || ! -x "$copy/scripts/$cmd.sh" ]]; then
  echo "Usage: $0 <command> [argument...]" >&2
  echo "Commands: ${commands[*]}" >&2
  exit 1
fi
if [[ " ${commands[*]} " != *" $cmd "* ]]; then
  echo "Warning: $cmd is a step of the CI jobs, not a documented command" >&2
fi
shift
AURTOMATOR_DATA_DIR="$root" AURTOMATOR_RUNNER="$0" "$copy/scripts/$cmd.sh" "$@"
