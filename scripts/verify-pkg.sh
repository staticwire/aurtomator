#!/usr/bin/env bash
#
# verify-pkg.sh - Check the checksums of an update that update-pkg.sh --prepare made against its
# sources, after the checks of publish-pkg.sh; it never sources the PKGBUILD or runs makepkg
#
# Usage: ./scripts/verify-pkg.sh <package-name> <version> <prepared-dir> [--asset <value>] [--arch-out <arches>]
# Exit codes: 0 verified, 1 failed, 3 the AUR moved since the prepare

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq
require_cmd curl

readonly PKG_NAME="${1:?Usage: verify-pkg.sh <package-name> <version> <prepared-dir> [--asset <value>] [--arch-out <arches>]}"
readonly VERSION="${2:?Usage: verify-pkg.sh <package-name> <version> <prepared-dir> [--asset <value>] [--arch-out <arches>]}"
readonly PREPARED="${3:?Usage: verify-pkg.sh <package-name> <version> <prepared-dir> [--asset <value>] [--arch-out <arches>]}"
shift 3
ASSET=""
ARCH_EDIT=""
ARCH_OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --asset)
      if [[ -z "${2:-}" ]]; then
        log_err "--asset needs a value"
        exit 1
      fi
      ASSET="$2"
      shift 2
      ;;
    --arch-out)
      if [[ $# -lt 2 ]]; then
        log_err "--arch-out needs a list of arches, which may be empty"
        exit 1
      fi
      ARCH_EDIT=1
      ARCH_OUT="$2"
      shift 2
      ;;
    *)
      log_err "Unknown option: $1"
      exit 1
      ;;
  esac
done
readonly ASSET ARCH_EDIT ARCH_OUT
validate_pkgver "$VERSION" || exit 1
if ! arch_list_ok "$ARCH_OUT"; then
  log_err "--arch-out must name arches other than x86_64, separated by single spaces: ${ARCH_OUT@Q}"
  exit 1
fi
PKG_FILE="$(pkg_file "$PKG_NAME")"
readonly PKG_FILE
ASSET_VAR=$(pkg_asset_var "$PKG_FILE") || exit 1
readonly ASSET_VAR
check_asset_option "$ASSET_VAR" "$ASSET" || exit 1

base=$(prepared_base "$PREPARED") || exit 1

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

arch_words=""
if [[ -n "$ARCH_EDIT" ]]; then
  arch_words=$(prepared_arch_words "$aur_dir" "$aur_files/PKGBUILD" "$PREPARED/PKGBUILD" "$PKG_FILE" \
    "$ARCH_OUT" "${tmp_dir}/ref") || exit 1
fi

handed_rc=0
check_handed_aur_files "$aur_files" "$PREPARED" "$VERSION" "$ASSET_VAR" "$ASSET" "$arch_words" || handed_rc=$?
if ((handed_rc == 0)); then
  log_ok "The prepared files of $PKG_NAME are those of the AUR, nothing to verify"
  exit 0
fi
((handed_rc == 2)) || exit 1

check_prepared_files "$aur_files" "$PREPARED" "$VERSION" "$(pkgver_dash "$PKG_FILE")" \
  "$(pkg_get "$PKG_FILE" '.pkgver_format // ""')" "$ASSET_VAR" "$ASSET" "$arch_words" "${tmp_dir}/ref" || exit 1
mkdir "${tmp_dir}/downloads"
verify_prepared_sums "$aur_files" "$PREPARED" "${tmp_dir}/downloads" || exit 1
log_ok "Checksums of $PKG_NAME $VERSION match the sources"
