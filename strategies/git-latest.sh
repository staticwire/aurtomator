#!/usr/bin/env bash
#
# git-latest - Get latest commit info from a git repo
#
# Input: package name (reads upstream config from package YAML)
# Output: pkgver in standard -git format: r<count>.<shorthash>, or with
#         upstream.describe <tag>.r<count>.g<shorthash>
#
# upstream.branch:     the branch of a source pinned to #branch= (default:
#                      the default branch of the repository)
# upstream.describe:   tags or annotated: the form of git describe that the
#                      Arch package guidelines give, from the newest tag of
#                      any kind or from the newest annotated tag
# upstream.tag_prefix: text cut from the start of the tag, as 's/^v//'

set -euo pipefail

readonly NAME="${1:?Usage: git-latest.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
host=$(pkg_get "$pkg_file" .upstream.host)
project=$(pkg_get "$pkg_file" .upstream.project)
upstream_type=$(pkg_get "$pkg_file" .upstream.type)
current=$(pkg_get "$pkg_file" '.current // ""')
branch=$(pkg_get "$pkg_file" '.upstream.branch // ""')
describe=$(pkg_get "$pkg_file" '.upstream.describe // ""')
tag_prefix=$(pkg_get "$pkg_file" '.upstream.tag_prefix // ""')

# Build repo URL based on type
case "$upstream_type" in
  gitlab)
    repo_url="https://${host}/${project}.git"
    ;;
  github)
    repo_url="https://github.com/${project}.git"
    ;;
  git)
    repo_url=$(pkg_get "$pkg_file" .upstream.url)
    ;;
  *)
    echo "Unknown upstream type: $upstream_type" >&2
    exit 1
    ;;
esac

# Clone bare repo to get commit count + hash. http and https only, so a URL
# from the YAML reaches no local repository and no ssh host.
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# With --branch, HEAD of the bare clone is that branch, as makepkg checks it
# out for #branch=.
clone_args=(--bare --quiet)
if [[ -n "$branch" ]]; then
  clone_args+=("--branch=$branch")
fi
GIT_ALLOW_PROTOCOL=http:https git clone "${clone_args[@]}" "$repo_url" "$tmp_dir/repo" || {
  echo "Failed to clone $repo_url" >&2
  exit 1
}

if [[ -n "$describe" ]]; then
  # The hash takes as many characters as the hash in current, as below
  abbrev=7
  if [[ "$current" =~ \.g([0-9a-f]+)$ ]]; then
    abbrev=${#BASH_REMATCH[1]}
  fi
  describe_args=(--long "--abbrev=$abbrev")
  if [[ "$describe" == tags ]]; then
    describe_args+=(--tags)
  fi
  described=$(git -C "$tmp_dir/repo" describe "${describe_args[@]}" HEAD 2>/dev/null) || {
    echo "git describe finds no tag reachable from HEAD of $repo_url" >&2
    exit 1
  }
  # 1.2.0-rc1-47-g0bbf5ad -> 1.2.0.rc1.r47.g0bbf5ad, as the sed of the
  # guidelines writes it
  sed 's/\([^-]*-g\)/r\1/;s/-/./g' <<<"${described#"$tag_prefix"}"
  exit 0
fi

count=$(git -C "$tmp_dir/repo" rev-list --count HEAD 2>/dev/null) || {
  echo "Failed to count commits" >&2
  exit 1
}

hash=$(git -C "$tmp_dir/repo" rev-parse HEAD 2>/dev/null) || {
  echo "Failed to get HEAD hash" >&2
  exit 1
}

# The hash takes as many characters as the hash in current. rev-parse
# --short in a PKGBUILD grows with the repository, and a shorter hash of the
# same commit reads as an older version.
hash_len=7
if [[ "$current" =~ ^r[0-9]+\.([0-9a-f]+)$ ]]; then
  hash_len=${#BASH_REMATCH[1]}
fi

echo "r${count}.${hash:0:hash_len}"
