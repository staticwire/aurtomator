#!/usr/bin/env bash
#
# update-pkg.sh — Update an existing AUR package to a new version
#
# Clones the AUR repo, updates pkgver in the existing PKGBUILD,
# regenerates checksums and .SRCINFO, commits and pushes.
#
# Usage: ./scripts/update-pkg.sh <package-name> <new-version> [--dry-run]

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq

readonly PKG_NAME="${1:?Usage: update-pkg.sh <package-name> <new-version> [--dry-run]}"
readonly NEW_VERSION="${2:?Usage: update-pkg.sh <package-name> <new-version> [--dry-run]}"
readonly DRY_RUN="${3:-}"
PKG_FILE="$(pkg_file "$PKG_NAME")"
readonly PKG_FILE

load_config

strategy=$(pkg_get "$PKG_FILE" .strategy)

# =============================================================================
# TEMP DIR WITH CLEANUP
# =============================================================================

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# =============================================================================
# CLONE AUR REPO
# =============================================================================

aur_dir="${tmp_dir}/aur-${PKG_NAME}"
log_info "Cloning AUR repo: $PKG_NAME"
git clone "ssh://aur@aur.archlinux.org/${PKG_NAME}.git" "$aur_dir" || {
  log_err "Failed to clone AUR repo for $PKG_NAME"
  exit 1
}

if [[ ! -f "${aur_dir}/PKGBUILD" ]]; then
  log_err "No PKGBUILD found in AUR repo"
  exit 1
fi

warn_maintainer_line "${aur_dir}/PKGBUILD"

# =============================================================================
# UPDATE PKGVER
# =============================================================================

log_info "Updating pkgver to $NEW_VERSION"
sed -i "s/^pkgver=.*/pkgver=${NEW_VERSION}/" "${aur_dir}/PKGBUILD"
sed -i "s/^pkgrel=.*/pkgrel=1/" "${aur_dir}/PKGBUILD"

# Check if anything actually changed
if git -C "$aur_dir" diff --quiet PKGBUILD; then
  log_ok "$PKG_NAME already at $NEW_VERSION on AUR, nothing to do"
  pkg_set "$PKG_FILE" .current "\"${NEW_VERSION}\""
  exit 2
fi

# =============================================================================
# UPDATE CHECKSUMS
# =============================================================================

# Skip checksums for VCS packages (sha256sums=SKIP)
if grep -q "sha256sums=('SKIP')" "${aur_dir}/PKGBUILD"; then
  log_info "VCS package, skipping checksums"
else
  log_info "Updating checksums"
  (cd "$aur_dir" && updpkgsums 2>/dev/null) || {
    log_warn "updpkgsums failed or not available, checksums may need manual update"
  }
fi

# =============================================================================
# GENERATE .SRCINFO
# =============================================================================

log_info "Generating .SRCINFO"
(cd "$aur_dir" && makepkg --printsrcinfo >.SRCINFO) || {
  log_err "makepkg --printsrcinfo failed"
  exit 1
}
log_ok ".SRCINFO generated"

# =============================================================================
# DRY RUN CHECK
# =============================================================================

if [[ "$DRY_RUN" == "--dry-run" ]]; then
  log_warn "[DRY RUN] Would push $PKG_NAME $NEW_VERSION to AUR"
  log_info "PKGBUILD diff:"
  (cd "$aur_dir" && git diff PKGBUILD) || true
  exit 0
fi

# =============================================================================
# COMMIT & PUSH TO AUR
# =============================================================================

log_info "Pushing to AUR"
cd "$aur_dir"
git config user.name "${GIT_AUTHOR_NAME:-aurtomator}"
git config user.email "${GIT_AUTHOR_EMAIL:-aurtomator@users.noreply.github.com}"
git config commit.gpgsign false
git add PKGBUILD .SRCINFO
git commit -m "${NEW_VERSION} release from ${strategy}" || {
  log_err "git commit failed in $aur_dir"
  exit 1
}

# Sign if GPG key configured
if [[ -n "${GPG_KEY_ID:-}" ]]; then
  git -c user.signingkey="$GPG_KEY_ID" \
    -c commit.gpgsign=true \
    commit --amend --no-edit || {
    log_warn "GPG signing failed, pushing unsigned commit"
  }
fi

git push || {
  log_err "git push to AUR failed"
  exit 1
}
cd "$OLDPWD"

log_ok "Pushed $PKG_NAME $NEW_VERSION to AUR"

# =============================================================================
# UPDATE PACKAGE YAML
# =============================================================================

log_info "Updating package YAML"
pkg_set "$PKG_FILE" .current "\"${NEW_VERSION}\""
pkg_set "$PKG_FILE" .last_updated "\"$(date -u +%Y-%m-%d)\""
log_ok "Updated $PKG_FILE with current: $NEW_VERSION"
