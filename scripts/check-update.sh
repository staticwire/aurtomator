#!/usr/bin/env bash
#
# check-update.sh - Check a single package for upstream updates
#
# Usage: ./scripts/check-update.sh <package-name>
#        ./scripts/check-update.sh my-package

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq
require_cmd vercmp

readonly PKG_NAME="${1:?Usage: check-update.sh <package-name>}"
PKG_FILE="$(pkg_file "$PKG_NAME")"
readonly PKG_FILE

# Read package config
strategy=$(pkg_get "$PKG_FILE" .strategy)
current=$(pkg_get "$PKG_FILE" '.current // ""')
dash=$(pkgver_dash "$PKG_FILE")
format=$(pkg_get "$PKG_FILE" '.pkgver_format // ""')

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

# pkgver holds no dash. The PKGBUILD turns pkgver_dash back into a dash
# where a URL needs one, as in ${pkgver//_/-}. pkgver_dash: '' drops the
# dash, so 2.5.0-rc1 gives 2.5.0rc1, which vercmp puts below 2.5.0, and the
# PKGBUILD puts it back as in ${pkgver/rc/-rc}.
if [[ "$dash" == drop ]]; then
  latest=${latest//-/}
elif [[ -n "$dash" ]]; then
  latest=${latest//-/"$dash"}
fi

# pkgver is the upstream version with the text of pkgver_format around it,
# as 4.4215 for build 4215. The PKGBUILD cuts that text off where a URL
# needs the upstream version, as in ${pkgver#4.}.
if [[ -n "$format" ]]; then
  latest=${format/"%s"/"$latest"}
fi

validate_pkgver "$latest" || exit 1

if [[ "$latest" == "$current" ]]; then
  log_ok "$PKG_NAME is up to date ($current)"
  exit 0
fi

if [[ -z "$current" ]]; then
  log_warn "$PKG_NAME: no current version set, latest is $latest"
else
  # vercmp prints -1/0/1 to stdout, always exits 0. Use stdout value.
  cmp=$(vercmp "$current" "$latest")
  if [[ "$cmp" -gt 0 ]]; then
    log_warn "$PKG_NAME: DOWNGRADE $current → $latest"
  else
    log_warn "$PKG_NAME: update available $current → $latest"
  fi
fi

# Output for scripting: print latest version on stdout
echo "$latest"
