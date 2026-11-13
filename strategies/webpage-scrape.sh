#!/usr/bin/env bash
# webpage-scrape - Print the newest version that a regex finds on a web page, see
# https://aurtomator.dev/strategies/#webpage-scrape

set -euo pipefail

readonly NAME="${1:?Usage: webpage-scrape.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

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
# A page is at most 5 MB, or upstream.max_answer_mb
page=$(http_get "$url" --max-redirs 5 --max-filesize "${MAX_ANSWER_MB:-5}M") || {
  echo "Failed to fetch $url" >&2
  exit 1
}

# The first capture group of every match
versions=$(echo "$page" | capture_matches "$pattern")

if [[ -z "$versions" ]]; then
  echo "No versions matched pattern '$pattern' at $url" >&2
  exit 1
fi

newest_version <<<"$versions"
