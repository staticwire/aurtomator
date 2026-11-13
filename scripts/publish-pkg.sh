#!/usr/bin/env bash
#
# publish-pkg.sh - Push an update that update-pkg.sh --prepare made, after checking the prepared
# files against the AUR copy; it never sources the PKGBUILD or runs makepkg
#
# Usage: ./scripts/publish-pkg.sh <package-name> <version> <prepared-dir> [--asset <value>] [--arch-out <arches>] [--dry-run]
# Exit codes: 0 pushed, 1 failed, 2 the AUR already has the version, 3 the AUR moved since the prepare

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq

readonly PKG_NAME="${1:?Usage: publish-pkg.sh <package-name> <version> <prepared-dir> [--asset <value>] [--arch-out <arches>] [--dry-run]}"
readonly VERSION="${2:?Usage: publish-pkg.sh <package-name> <version> <prepared-dir> [--asset <value>] [--arch-out <arches>] [--dry-run]}"
readonly PREPARED="${3:?Usage: publish-pkg.sh <package-name> <version> <prepared-dir> [--asset <value>] [--arch-out <arches>] [--dry-run]}"
shift 3
DRY_RUN=""
ASSET=""
ARCH_EDIT=""
ARCH_OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN="--dry-run"
      shift
      ;;
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
readonly DRY_RUN ASSET ARCH_EDIT ARCH_OUT
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

load_config

strategy=$(pkg_get "$PKG_FILE" .strategy)

base=$(prepared_base "$PREPARED") || exit 1

# === CLONE AUR REPO ===

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

aur_dir="${tmp_dir}/aur-${PKG_NAME}"
log_info "Cloning AUR repo: $PKG_NAME"
aur_clone "ssh://aur@aur.archlinux.org/${PKG_NAME}.git" "$aur_dir" --no-checkout || exit 1
aur_reanchor "$aur_dir" --no-checkout

head=$(git -C "$aur_dir" rev-parse HEAD)
if [[ "$head" != "$base" ]]; then
  log_warn "The AUR repo of $PKG_NAME moved from $base to $head since the update was prepared. The next run prepares it again."
  exit 3
fi

# === CHECK AND PUSH ===

aur_files="${tmp_dir}/aur-files"
aur_export "$aur_dir" "$aur_files" || exit 1

arch_words=""
if [[ -n "$ARCH_EDIT" ]]; then
  arch_words=$(prepared_arch_words "$aur_dir" "$aur_files/PKGBUILD" "$PREPARED/PKGBUILD" "$PKG_FILE" \
    "$ARCH_OUT" "${tmp_dir}/ref") || exit 1
fi

handed_rc=0
check_handed_aur_files "$aur_files" "$PREPARED" "$VERSION" "$ASSET_VAR" "$ASSET" "$arch_words" || handed_rc=$?
# The arches of the update, when arch=() is a line of plain names
final_words=$(pkgbuild_arch_words "${PREPARED}/PKGBUILD" | tr '\n' ' ') || final_words=""
if ((handed_rc == 0)); then
  log_ok "$PKG_NAME already at $VERSION on AUR, nothing to do"
  # The AUR got this version without a commit of this YAML, so the cooldown of the
  # next version starts today
  if [[ "$(pkg_get "$PKG_FILE" '.current // ""')" != "$VERSION" ]]; then
    pkg_set "$PKG_FILE" .last_updated "\"$(date -u +%Y-%m-%d)\""
  fi
  pkg_set_current "$PKG_FILE" "$VERSION" "$ASSET"
  # The arch_wait of this version stays when the YAML commit of the push that took arches
  # out was lost: the arches its parent has and this version lacks go to arch_out
  lost_out="" parent=""
  if [[ -n "$final_words" && "$(pkg_get "$PKG_FILE" '.arch_wait.version // ""')" == "$VERSION" ]] &&
    parent=$(git -C "$aur_dir" rev-parse -q --verify "${base}^") &&
    git -C "$aur_dir" show "${parent}:PKGBUILD" >"${tmp_dir}/parent-PKGBUILD" 2>/dev/null; then
    lost_out=$(arch_minus "$(pkgbuild_arch_words "${tmp_dir}/parent-PKGBUILD" | tr '\n' ' ')" "$final_words x86_64")
  fi
  arch_state_after "$PKG_FILE" "$final_words" "$lost_out" "$parent"
  exit 2
fi
((handed_rc == 2)) || exit 1

prepared_ver=$(sed -n 's/^pkgver=//p' "${PREPARED}/PKGBUILD" | head -1)
if [[ "$prepared_ver" != "$VERSION" ]]; then
  log_err "Prepared PKGBUILD has pkgver=${prepared_ver}, expected ${VERSION}"
  exit 1
fi
check_prepared_files "$aur_files" "$PREPARED" "$VERSION" "$(pkgver_dash "$PKG_FILE")" \
  "$(pkg_get "$PKG_FILE" '.pkgver_format // ""')" "$ASSET_VAR" "$ASSET" "$arch_words" "${tmp_dir}/ref" || exit 1

# The index takes the tree of HEAD, and the prepared files enter it byte for byte: git add would
# pass them through the attributes of the AUR repo, where UTF-7 turns a comment into code
git -C "$aur_dir" read-tree HEAD || exit 1
for file in PKGBUILD .SRCINFO; do
  blob=$(git -C "$aur_dir" hash-object -w --stdin --no-filters <"${PREPARED}/${file}") || exit 1
  git -C "$aur_dir" update-index --add --cacheinfo "100644,${blob},${file}" || exit 1
done

if [[ "$DRY_RUN" == "--dry-run" ]]; then
  log_warn "[DRY RUN] Would push $PKG_NAME $VERSION to AUR"
  log_info "PKGBUILD diff:"
  git -C "$aur_dir" diff --cached -- PKGBUILD || true
  exit 0
fi

taken_out=""
put_back=""
if [[ -n "$arch_words" ]]; then
  aur_arches=$(pkgbuild_arch_words "$aur_files/PKGBUILD" | tr '\n' ' ')
  taken_out=$(arch_minus "$aur_arches" "$arch_words")
  # Arches put back at the pkgver and pkgrel of the AUR make no new release
  aur_release="$(_plain_value "$aur_files/PKGBUILD" pkgver)-$(_plain_value "$aur_files/PKGBUILD" pkgrel)"
  if [[ "$aur_release" == "$VERSION-$(_plain_value "${PREPARED}/PKGBUILD" pkgrel)" ]]; then
    put_back=$(arch_minus "$arch_words" "$aur_arches")
  fi
fi

# The checks above hold pkgrel to 1, to the AUR pkgrel plus one for a rebuild,
# or to the AUR pkgrel for arches put back
aur_commit_push "$aur_dir" "$VERSION" "$strategy" "$(sed -n 's/^pkgrel=//p' "${PREPARED}/PKGBUILD" | head -1)" "$put_back" || exit 1
log_ok "Pushed $PKG_NAME $VERSION to AUR"

pkg_set_current "$PKG_FILE" "$VERSION" "$ASSET"
[[ -n "$put_back" ]] || pkg_set "$PKG_FILE" .last_updated "\"$(date -u +%Y-%m-%d)\""
arch_state_after "$PKG_FILE" "$final_words" "$taken_out" "$base"
log_ok "Updated $PKG_FILE with current: $VERSION"
