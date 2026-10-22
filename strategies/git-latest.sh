#!/usr/bin/env bash
#
# git-latest - Get latest commit info from a git repo
#
# Input: package name (reads upstream config from package YAML)
# Output: pkgver in standard -git format: r<count>.<shorthash>
#
# upstream.branch: the branch of a source pinned to #branch= (default: the
#                  default branch of the repository)

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
