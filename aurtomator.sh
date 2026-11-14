#!/usr/bin/env bash
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

# Succeeds for a uses: value that names a reusable workflow of a repository,
# not one of the calling repository
names_workflow() {
  local path="${1//\\//}"
  [[ "$path" != ./* && "$path" == */.github/workflows/* ]]
}

check_shape "$workflow"
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

# Stop unless the pin $3 on the uses: line $2 of file $1 is the commit of the release written
# after it, since GitHub serves the commits of every fork under the name of its parent
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
  cd "$root"
  # sed moves a pin on a uses: line alone, so every pin GitHub reads in the
  # two files has to be on one before any file changes
  for file in "$workflow" .github/workflows/validate.yml; do
    [[ -f "$file" ]] || continue
    check_shape "$file"
    mapfile -t on_lines < <(sed -nE "s|^[[:space:]]*uses:[[:space:]]+($pin_repo/\.github/workflows/[a-z-]+\.yml@[0-9a-f]{40})([[:space:]].*)?$|\1|p" "$file" | sort)
    read_out=$(yq -r 'explode(.) | .jobs[].uses | select(. != null)' "$file")
    mapfile -t read_pins < <(grep -E "^$pin_repo/\.github/workflows/[a-z-]+\.yml@[0-9a-f]{40}\$" <<<"$read_out" | sort)
    if [[ "${on_lines[*]}" != "${read_pins[*]}" ]]; then
      echo "Write each pin of $repo in $file on one uses: line without quotes. GitHub reads:" >&2
      printf '  %s\n' "${read_pins[@]:-none}" >&2
      exit 1
    fi
  done
  for file in "$workflow" .github/workflows/validate.yml; do
    [[ -f "$file" ]] || continue
    sed -i -E "s|^([[:space:]]*uses:[[:space:]]+$pin_repo/\.github/workflows/[a-z-]+\.yml@)[0-9a-f]{40}([[:space:]].*)?$|\1$new # $2|" "$file"
    grep -nHE "^[[:space:]]*uses:[[:space:]]+$pin_repo/\.github/workflows/[a-z-]+\.yml@$new # $2\$" "$file" || true
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
  checked=()
  for file in "$workflow" .github/workflows/validate.yml; do
    [[ -f "$file" ]] || continue
    check_shape "$file"
    # A tagged value shows no plain uses: line, and GitHub runs no workflow with one today
    tags=$(yq -r 'explode(.) | [.jobs[] | (.uses, .steps[]?.uses) | select(. != null) | tag | select(. != "!!str")] | unique | join(" ")' "$file")
    if [[ -n "$tags" ]]; then
      echo "$file holds a uses: value with the tag $tags; write every uses: value as plain text" >&2
      exit 1
    fi
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
      check_release "$file" "${lines[i]}" "${BASH_REMATCH[1]}"
      checked+=("$file:${lines[i]}")
    done
  done
  printf '%s\n' "${checked[@]}"
  exit 0
fi

copy="${XDG_CACHE_HOME:-$HOME/.cache}/aurtomator/$sha"
if [[ ! -d "$copy" ]]; then
  check_release "$workflow" "${pins[0]}" "$sha"
  mkdir -p "${copy%/*}"
  tmp="$(mktemp -d "$copy.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  git -C "$tmp" init -q
  git -C "$tmp" fetch -q --depth 1 "https://github.com/$repo" "$sha"
  git -C "$tmp" checkout -q FETCH_HEAD
  # A run that started at the same time can make the copy first
  mv -T "$tmp" "$copy" 2>/dev/null || rm -rf "$tmp"
  # A pin still in use after 30 days is fetched again on its next run. A
  # run at the same time can remove its own directory while find reads.
  find "${copy%/*}" -mindepth 1 -maxdepth 1 -regextype posix-extended -regex '.*/[0-9a-f]{40}' -mtime +30 -exec rm -rf -- {} + 2>/dev/null || true
fi

# The documented commands. Another script of scripts/ is a step of the CI
# jobs and runs after a warning.
commands=(setup draft sample validate-pkg check-update update-pkg check-all pin check-pins)
cmd="${1:-}"
if [[ "$cmd" == sample ]]; then
  exec cat "$copy/packages/example.yml.sample"
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
