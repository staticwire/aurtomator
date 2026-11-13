#!/usr/bin/env bash
#
# check-update.sh - Check a single package for upstream updates
#
# Usage: ./scripts/check-update.sh <package-name>

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq
require_cmd vercmp

readonly PKG_NAME="${1:?Usage: check-update.sh <package-name>}"
PKG_FILE="$(pkg_file "$PKG_NAME")"
readonly PKG_FILE

strategy=$(pkg_get "$PKG_FILE" .strategy)
current=$(pkg_get "$PKG_FILE" '.current // ""')
dash=$(pkgver_dash "$PKG_FILE")
format=$(pkg_get "$PKG_FILE" '.pkgver_format // ""')
# The strategy runs in a process of its own and reads the limit from here
MAX_ANSWER_MB=$(max_answer_mb "$PKG_FILE") || exit 1
export MAX_ANSWER_MB

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

latest=$(to_pkgver "$latest" "$dash" "$format")
if ! validate_pkgver "$latest"; then
  # to_pkgver leaves a dash only without pkgver_dash
  if [[ "$latest" == *-* ]]; then
    log_err "The version holds a dash: set pkgver_dash, or tag_version_regex to leave such tags out"
  fi
  exit 1
fi

if [[ "$latest" == "$current" ]]; then
  log_ok "$PKG_NAME is up to date ($current)"
  exit 0
fi

if [[ -z "$current" ]]; then
  log_warn "$PKG_NAME: no current version set, latest is $latest"
else
  # vercmp prints -1, 0 or 1 and exits 0
  cmp=$(vercmp "$current" "$latest")
  if [[ "$cmp" -gt 0 ]]; then
    log_warn "$PKG_NAME: DOWNGRADE $current → $latest"
  else
    log_warn "$PKG_NAME: update available $current → $latest"
  fi
fi

# stdout holds the version alone
echo "$latest"
