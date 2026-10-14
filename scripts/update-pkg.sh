#!/usr/bin/env bash
#
# update-pkg.sh - Update an existing AUR package to a new version
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
validate_pkgver "$NEW_VERSION" || exit 1
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
# Brief delay to reduce AUR SSH rate-limit pressure from GitHub Actions IP pool
sleep 2
for _attempt in 1 2 3; do
  if git clone "ssh://aur@aur.archlinux.org/${PKG_NAME}.git" "$aur_dir" 2>&1; then
    break
  fi
  if [[ "$_attempt" -eq 3 ]]; then
    log_err "Failed to clone AUR repo for $PKG_NAME after 3 attempts"
    exit 1
  fi
  log_warn "Clone attempt $_attempt failed, retrying in 5s..."
  rm -rf "$aur_dir"
  sleep 5
done

if [[ ! -f "${aur_dir}/PKGBUILD" ]]; then
  log_err "No PKGBUILD found in AUR repo"
  exit 1
fi

# The AUR can serve a HEAD that does not match refs/heads/master after two
# runs pushed at the same time. HEAD and master then point at different
# commits with the same content, and a clone lands on a detached HEAD.
#
# The AUR refuses non-fast-forward pushes, so the commit has to sit on
# origin/master and not on the detached HEAD. Anything unique to the
# detached commit is dropped. The workflow's concurrency group prevents
# the race; this stays as a safety net.
if ! git -C "$aur_dir" symbolic-ref -q HEAD >/dev/null; then
  log_warn "Detached HEAD after clone (remote HEAD != refs/heads/master)"
  log_info "Re-basing on origin/master to allow fast-forward push"
  git -C "$aur_dir" checkout -B master origin/master
fi

warn_maintainer_line "${aur_dir}/PKGBUILD"

# =============================================================================
# AUDIT PKGBUILD
# =============================================================================

audit_rc=0
audit_pkgbuild "${aur_dir}/PKGBUILD" "$strategy" || audit_rc=$?
if [[ "$audit_rc" -eq 1 ]]; then
  log_err "PKGBUILD audit failed, aborting update"
  exit 1
fi

# =============================================================================
# UPDATE PKGVER
# =============================================================================

log_info "Updating pkgver to $NEW_VERSION"
sed -i "s/^pkgver=.*/pkgver=${NEW_VERSION}/" "${aur_dir}/PKGBUILD"
sed -i "s/^pkgrel=.*/pkgrel=1/" "${aur_dir}/PKGBUILD"

# An unchanged PKGBUILD means the AUR already has this version
if git -C "$aur_dir" diff --quiet PKGBUILD; then
  log_ok "$PKG_NAME already at $NEW_VERSION on AUR, nothing to do"
  pkg_set "$PKG_FILE" .current "\"${NEW_VERSION}\""
  exit 2
fi

# =============================================================================
# UPDATE CHECKSUMS
# =============================================================================

# Skip checksums for VCS packages (any checksum type with SKIP)
if grep -qE "(md5|sha[0-9]+|b2)sums=\('SKIP'" "${aur_dir}/PKGBUILD"; then
  log_info "VCS package, skipping checksums"
else
  # Validate source URLs before downloading
  url_rc=0
  validate_source_urls "${aur_dir}/PKGBUILD" || url_rc=$?
  if [[ "$url_rc" -gt 0 ]]; then
    log_err "Source URL validation failed ($url_rc error(s)), aborting"
    exit 1
  fi

  require_cmd updpkgsums
  log_info "Updating checksums"
  (cd "$aur_dir" && updpkgsums) || {
    log_err "updpkgsums failed, refusing to push stale checksums"
    exit 1
  }
  # Verify checksums are correct before pushing
  log_info "Verifying checksums"
  (cd "$aur_dir" && makepkg --verifysource --skippgpcheck) || {
    log_err "Checksum verification failed, aborting"
    exit 1
  }
fi

# Lint PKGBUILD with namcap (non-fatal on warnings, fatal on errors)
if command -v namcap &>/dev/null; then
  log_info "Running namcap lint"
  namcap_out=$(namcap "${aur_dir}/PKGBUILD" 2>&1) || true
  if grep -q " E: " <<<"$namcap_out"; then
    log_err "namcap found errors:"
    grep " E: " <<<"$namcap_out" >&2
    exit 1
  fi
  if grep -q " W: " <<<"$namcap_out"; then
    log_warn "namcap warnings (non-fatal):"
    grep " W: " <<<"$namcap_out" >&2
  fi
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

for _attempt in 1 2 3; do
  if git push 2>&1; then
    break
  fi
  if [[ "$_attempt" -eq 3 ]]; then
    log_err "git push to AUR failed after 3 attempts"
    exit 1
  fi
  log_warn "Push attempt $_attempt failed, retrying in 5s..."
  sleep 5
done
cd "$OLDPWD"

log_ok "Pushed $PKG_NAME $NEW_VERSION to AUR"

# =============================================================================
# UPDATE PACKAGE YAML
# =============================================================================

log_info "Updating package YAML"
pkg_set "$PKG_FILE" .current "\"${NEW_VERSION}\""
pkg_set "$PKG_FILE" .last_updated "\"$(date -u +%Y-%m-%d)\""
log_ok "Updated $PKG_FILE with current: $NEW_VERSION"
