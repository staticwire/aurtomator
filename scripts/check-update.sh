#!/usr/bin/env bash
#
# check-update.sh — Check a single package for upstream updates
#
# Usage: ./scripts/check-update.sh <package-name>
#        ./scripts/check-update.sh my-package

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq

readonly PKG_NAME="${1:?Usage: check-update.sh <package-name>}"
PKG_FILE="$(pkg_file "$PKG_NAME")"
readonly PKG_FILE

# Read package config
strategy=$(pkg_get "$PKG_FILE" .strategy)
current=$(pkg_get "$PKG_FILE" '.current // ""')

# Run strategy
strategy_script="${AURTOMATOR_DIR}/strategies/${strategy}.sh"
if [[ ! -x "$strategy_script" ]]; then
  log_err "Strategy not found or not executable: $strategy_script"
  exit 1
fi

log_info "Checking $PKG_NAME (strategy: $strategy, current: ${current:-none})"

latest=$("$strategy_script" "$PKG_NAME") || {
  log_err "Strategy failed for $PKG_NAME"
  exit 1
}

if [[ -z "$latest" ]]; then
  log_err "Strategy returned empty version"
  exit 1
fi

if [[ "$latest" == "$current" ]]; then
  log_ok "$PKG_NAME is up to date ($current)"
  exit 0
fi

if [[ -z "$current" ]]; then
  log_warn "$PKG_NAME: no current version set, latest is $latest"
else
  log_warn "$PKG_NAME: update available $current → $latest"
fi

# Output for scripting: print latest version on stdout
echo "$latest"
