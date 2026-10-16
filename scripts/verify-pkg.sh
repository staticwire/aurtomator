#!/usr/bin/env bash
#
# verify-pkg.sh - Check the checksums of an update that update-pkg.sh --prepare made
#
# Clones the AUR repo anonymously and checks the prepared PKGBUILD and
# .SRCINFO against it as publish-pkg.sh does. Then downloads the remote
# sources and compares every checksum with its source. Never sources the
# PKGBUILD and never runs makepkg: the prepared files are untrusted.
#
# Usage: ./scripts/verify-pkg.sh <package-name> <prepared-dir>
#
# Exit codes: 0 verified, 1 failed,
#             3 the AUR moved since the update was prepared

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq
require_cmd curl

readonly PKG_NAME="${1:?Usage: verify-pkg.sh <package-name> <prepared-dir>}"
readonly PREPARED="${2:?Usage: verify-pkg.sh <package-name> <prepared-dir>}"
pkg_file "$PKG_NAME" >/dev/null

base=$(prepared_base "$PREPARED") || exit 1
version=$(sed -n 's/^pkgver=//p' "${PREPARED}/PKGBUILD" | head -1)
validate_pkgver "$version" || exit 1

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

aur_dir="${tmp_dir}/aur-${PKG_NAME}"
log_info "Cloning AUR repo: $PKG_NAME"
aur_clone "https://aur.archlinux.org/${PKG_NAME}.git" "$aur_dir" --no-checkout || exit 1
aur_reanchor "$aur_dir" --no-checkout

head=$(git -C "$aur_dir" rev-parse HEAD)
if [[ "$head" != "$base" ]]; then
  log_warn "The AUR repo of $PKG_NAME moved from $base to $head since the update was prepared. The next run prepares it again."
  exit 3
fi

aur_files="${tmp_dir}/aur-files"
aur_export "$aur_dir" "$aur_files" || exit 1
check_prepared_files "$aur_files" "$PREPARED" "$version" || exit 1
mkdir "${tmp_dir}/downloads"
verify_prepared_sums "$aur_files" "$PREPARED" "${tmp_dir}/downloads" || exit 1
log_ok "Checksums of $PKG_NAME $version match the sources"
