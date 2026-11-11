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
check_shape "$workflow"
# The repository and the commit come from one uses: line, never a comment
uses='^[[:space:]]*uses:[[:space:]]+([[:alnum:]_.-]+/[[:alnum:]_.-]+)/\.github/workflows/check-updates\.yml@([0-9a-f]{40})([[:space:]]|$)'
mapfile -t pins < <(grep -E "$uses" "$root/$workflow" || true)
if [[ ${#pins[@]} -eq 0 ]]; then
  echo "No commit SHA pinned in $workflow" >&2
  exit 1
fi
if [[ ${#pins[@]} -gt 1 ]]; then
  echo "More than one uses: line pins check-updates.yml in $workflow" >&2
  exit 1
fi
[[ "${pins[0]}" =~ $uses ]]
repo="${BASH_REMATCH[1]}"
sha="${BASH_REMATCH[2]}"
# GitHub reads YAML, where a pin in quotes counts and a line in a text does
# not, so yq has to read the same one pin
read_out=$(yq -r 'explode(.) | .jobs[].uses | select(. != null) | select(test("/[.]github/workflows/check-updates[.]yml@"))' "$root/$workflow")
mapfile -t read_pins <<<"$read_out"
if [[ ${#read_pins[@]} -ne 1 || "${read_pins[0]}" != "$repo/.github/workflows/check-updates.yml@$sha" ]]; then
  echo "Write the pin of check-updates.yml in $workflow on one uses: line without quotes. GitHub reads:" >&2
  printf '  %s\n' "${read_pins[@]:-none}" >&2
  exit 1
fi

if [[ "${1:-}" == pin ]]; then
  if [[ $# -ne 2 || ! "$2" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 pin vX.Y.Z" >&2
    exit 1
  fi
  # An annotated tag names its commit on the line of <tag>^{}
  new=$(git ls-remote --tags "https://github.com/$repo" | awk -v ref="refs/tags/$2" '$2 == ref || $2 == ref "^{}" { sha = $1 } END { print sha }')
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
    mapfile -t on_lines < <(sed -nE "s|^[[:space:]]*uses:[[:space:]]+($repo/\.github/workflows/[a-z-]+\.yml@[0-9a-f]{40})([[:space:]].*)?$|\1|p" "$file" | sort)
    read_out=$(yq -r 'explode(.) | .jobs[].uses | select(. != null)' "$file")
    mapfile -t read_pins < <(grep -E "^$repo/\.github/workflows/[a-z-]+\.yml@[0-9a-f]{40}\$" <<<"$read_out" | sort)
    if [[ "${on_lines[*]}" != "${read_pins[*]}" ]]; then
      echo "Write each pin of $repo in $file on one uses: line without quotes. GitHub reads:" >&2
      printf '  %s\n' "${read_pins[@]:-none}" >&2
      exit 1
    fi
  done
  for file in "$workflow" .github/workflows/validate.yml; do
    [[ -f "$file" ]] || continue
    sed -i -E "s|^([[:space:]]*uses:[[:space:]]+$repo/\.github/workflows/[a-z-]+\.yml@)[0-9a-f]{40}([[:space:]].*)?$|\1$new # $2|" "$file"
    grep -nHE "^[[:space:]]*uses:[[:space:]]+$repo/\.github/workflows/[a-z-]+\.yml@$new # $2\$" "$file" || true
  done
  exit 0
fi

copy="${XDG_CACHE_HOME:-$HOME/.cache}/aurtomator/$sha"
if [[ ! -d "$copy" ]]; then
  # GitHub serves the commits of every fork under the name of its parent
  if [[ $'\n'"$(git ls-remote --tags "https://github.com/$repo")" != *$'\n'"$sha"* ]]; then
    echo "Warning: no tag of $repo points to $sha, check where the pin comes from" >&2
  fi
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
commands=(setup draft sample validate-pkg check-update update-pkg check-all pin)
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
