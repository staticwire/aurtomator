#!/usr/bin/env bash
#
# webpage-scrape - Detect latest version by scraping a webpage with a regex
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string
#
# YAML fields:
#   upstream.url      - page URL to scrape
#   upstream.pattern  - ERE whose first capture group is the version: 'package-([0-9.]+)\.tar\.gz'
#   upstream.user_agent - User-Agent in place of aurtomator/1.0 (optional)

set -euo pipefail

readonly NAME="${1:?Usage: webpage-scrape.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly MAX_SIZE=5242880 # 5MB

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"
require_cmd curl

pkg_file=$(pkg_file "$NAME")
url=$(pkg_get "$pkg_file" '.upstream.url // ""')
pattern=$(pkg_get "$pkg_file" '.upstream.pattern // ""')
user_agent=$(pkg_get "$pkg_file" '.upstream.user_agent // ""')

if [[ -z "$url" || -z "$pattern" ]]; then
  echo "Missing upstream.url or upstream.pattern in package YAML" >&2
  exit 1
fi

# Enforce HTTPS
if [[ "$url" != https://* ]]; then
  echo "Only HTTPS URLs supported: $url" >&2
  exit 1
fi

# Fetch page, with the agent of the YAML for a site with rules of its own
if [[ -n "$user_agent" ]]; then
  USER_AGENT=$user_agent
fi
page=$(http_get "$url" --max-redirs 5 --max-filesize "$MAX_SIZE") || {
  echo "Failed to fetch $url" >&2
  exit 1
}

# The first capture group of every match
versions=$(echo "$page" | capture_matches "$pattern" | sort -Vu)

if [[ -z "$versions" ]]; then
  echo "No versions matched pattern '$pattern' at $url" >&2
  exit 1
fi

# Latest version (last after sort -V)
echo "$versions" | tail -1
