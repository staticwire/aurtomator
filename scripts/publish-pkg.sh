#!/usr/bin/env bash
#
# publish-pkg.sh - Push an update that update-pkg.sh --prepare made
#
# Clones the AUR repo over SSH, checks the prepared PKGBUILD and .SRCINFO
# against it, then commits, signs and pushes them. Never sources the
# PKGBUILD and never runs makepkg: the prepared files are untrusted.
#
# Usage: ./scripts/publish-pkg.sh <package-name> <version> <prepared-dir> [--dry-run]
#
# Exit codes: 0 pushed, 1 failed, 2 the AUR already has the version,
#             3 the AUR or upstream moved since the update was prepared

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq

readonly PKG_NAME="${1:?Usage: publish-pkg.sh <package-name> <version> <prepared-dir> [--dry-run]}"
readonly VERSION="${2:?Usage: publish-pkg.sh <package-name> <version> <prepared-dir> [--dry-run]}"
readonly PREPARED="${3:?Usage: publish-pkg.sh <package-name> <version> <prepared-dir> [--dry-run]}"
readonly DRY_RUN="${4:-}"
validate_pkgver "$VERSION" || exit 1
PKG_FILE="$(pkg_file "$PKG_NAME")"
readonly PKG_FILE

load_config

strategy=$(pkg_get "$PKG_FILE" .strategy)

base=$(prepared_base "$PREPARED") || exit 1

prepared_ver=$(sed -n 's/^pkgver=//p' "${PREPARED}/PKGBUILD" | head -1)
if [[ "$prepared_ver" != "$VERSION" ]]; then
  log_warn "$PKG_NAME was prepared for $prepared_ver, upstream now has $VERSION. The next run prepares it again."
  exit 3
fi

# =============================================================================
# CLONE AUR REPO
# =============================================================================

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

aur_dir="${tmp_dir}/aur-${PKG_NAME}"
log_info "Cloning AUR repo: $PKG_NAME"
aur_clone "ssh://aur@aur.archlinux.org/${PKG_NAME}.git" "$aur_dir" || exit 1
aur_reanchor "$aur_dir"

head=$(git -C "$aur_dir" rev-parse HEAD)
if [[ "$head" != "$base" ]]; then
  log_warn "The AUR repo of $PKG_NAME moved from $base to $head since the update was prepared. The next run prepares it again."
  exit 3
fi

# =============================================================================
# CHECK AND PUSH
# =============================================================================

check_prepared_files "$aur_dir" "$PREPARED" "$VERSION" || exit 1
cp "${PREPARED}/PKGBUILD" "${PREPARED}/.SRCINFO" "$aur_dir/"

if git -C "$aur_dir" diff --quiet; then
  log_ok "$PKG_NAME already at $VERSION on AUR, nothing to do"
  pkg_set "$PKG_FILE" .current "\"${VERSION}\""
  exit 2
fi

if [[ "$DRY_RUN" == "--dry-run" ]]; then
  log_warn "[DRY RUN] Would push $PKG_NAME $VERSION to AUR"
  log_info "PKGBUILD diff:"
  git -C "$aur_dir" diff PKGBUILD || true
  exit 0
fi

aur_commit_push "$aur_dir" "$VERSION" "$strategy" || exit 1
log_ok "Pushed $PKG_NAME $VERSION to AUR"

pkg_set "$PKG_FILE" .current "\"${VERSION}\""
pkg_set "$PKG_FILE" .last_updated "\"$(date -u +%Y-%m-%d)\""
log_ok "Updated $PKG_FILE with current: $VERSION"
