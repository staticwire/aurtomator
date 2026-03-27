#!/usr/bin/env bash
#
# git-latest — Get latest commit info from a git repo
#
# Input: package name (reads upstream config from package YAML)
# Output: pkgver in standard -git format: r<count>.<shorthash>

set -euo pipefail

readonly NAME="${1:?Usage: git-latest.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib.sh
source "${SCRIPT_DIR}/../scripts/lib.sh"

pkg_file=$(pkg_file "$NAME")
host=$(pkg_get "$pkg_file" .upstream.host)
project=$(pkg_get "$pkg_file" .upstream.project)
upstream_type=$(pkg_get "$pkg_file" .upstream.type)

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

# Clone bare repo to get commit count + hash
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

git clone --bare --quiet "$repo_url" "$tmp_dir/repo" 2>/dev/null || {
  echo "Failed to clone $repo_url" >&2
  exit 1
}

count=$(git -C "$tmp_dir/repo" rev-list --count HEAD 2>/dev/null) || {
  echo "Failed to count commits" >&2
  exit 1
}

short_hash=$(git -C "$tmp_dir/repo" rev-parse --short=7 HEAD 2>/dev/null) || {
  echo "Failed to get HEAD hash" >&2
  exit 1
}

echo "r${count}.${short_hash}"
