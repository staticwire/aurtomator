#!/usr/bin/env bash
#
# update-pkg.sh - Update an existing AUR package to a new version
#
# Clones the AUR repo, updates pkgver in the existing PKGBUILD,
# regenerates checksums and .SRCINFO, commits and pushes.
#
# With --prepare <dir>: clones anonymously over HTTPS, stops before the
# commit and copies PKGBUILD, .SRCINFO and the AUR commit it started from
# to <dir>/<package-name>/ for publish-pkg.sh. Exit code 2 still means the
# AUR already has the version.
#
# With --asset <value>: writes the value from the name of a release asset
# to the line of upstream.asset_var. A new value of the version the AUR
# has is a rebuild, with the AUR pkgrel plus one.
#
# Usage: ./scripts/update-pkg.sh <package-name> <new-version> [--asset <value>] [--arch-out <arches>] [--dry-run] [--prepare <dir>]

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq

readonly PKG_NAME="${1:?Usage: update-pkg.sh <package-name> <new-version> [--asset <value>] [--arch-out <arches>] [--dry-run] [--prepare <dir>]}"
readonly NEW_VERSION="${2:?Usage: update-pkg.sh <package-name> <new-version> [--asset <value>] [--arch-out <arches>] [--dry-run] [--prepare <dir>]}"
shift 2
DRY_RUN=""
PREPARE_DIR=""
ASSET=""
ARCH_EDIT=""
ARCH_OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN="--dry-run"
      shift
      ;;
    --prepare)
      if [[ -z "${2:-}" ]]; then
        log_err "--prepare needs a directory"
        exit 1
      fi
      PREPARE_DIR="$2"
      shift 2
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
readonly DRY_RUN PREPARE_DIR ASSET ARCH_EDIT ARCH_OUT
validate_pkgver "$NEW_VERSION" || exit 1
if [[ -n "$ARCH_OUT" && ! "$ARCH_OUT" =~ ^[a-z0-9_]+( [a-z0-9_]+)*$ ]]; then
  log_err "--arch-out must name arches separated by single spaces: ${ARCH_OUT@Q}"
  exit 1
fi
# Only publish writes arch_out, which says what an update left out
if [[ -n "$ARCH_EDIT" && -z "$PREPARE_DIR" ]]; then
  log_err "--arch-out needs --prepare"
  exit 1
fi
PKG_FILE="$(pkg_file "$PKG_NAME")"
readonly PKG_FILE
ASSET_VAR=$(pkg_asset_var "$PKG_FILE") || exit 1
readonly ASSET_VAR
check_asset_option "$ASSET_VAR" "$ASSET" || exit 1

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
# The job that prepares an update holds no SSH key
if [[ -n "$PREPARE_DIR" ]]; then
  aur_url="https://aur.archlinux.org/${PKG_NAME}.git"
else
  aur_url="ssh://aur@aur.archlinux.org/${PKG_NAME}.git"
fi
log_info "Cloning AUR repo: $PKG_NAME"
aur_clone "$aur_url" "$aur_dir" || exit 1

if [[ ! -f "${aur_dir}/PKGBUILD" ]]; then
  log_err "No PKGBUILD found in AUR repo"
  exit 1
fi

aur_reanchor "$aur_dir"
aur_base=$(git -C "$aur_dir" rev-parse HEAD)

# Copy the result for publish-pkg.sh, with the AUR commit it starts from
hand_over() {
  local dest="${PREPARE_DIR}/${PKG_NAME}"
  mkdir -p "$dest"
  cp "${aur_dir}/PKGBUILD" "${aur_dir}/.SRCINFO" "$dest/"
  echo "$aur_base" >"$dest/base"
  log_ok "Prepared $PKG_NAME $NEW_VERSION in $dest"
}

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
pkgrel=$(_update_pkgrel "${aur_dir}/PKGBUILD" "$NEW_VERSION")
if [[ -n "$ASSET_VAR" ]]; then
  pkgrel=$(_asset_pkgrel "${aur_dir}/PKGBUILD" "$ASSET_VAR" "$NEW_VERSION" "$ASSET") || exit 1
fi

# --arch-out takes the arches of its list out of arch=() and puts back each
# arch of arch_out it does not name, at the place the commit of the arch gives
arch_words=()
new_words=()
if [[ -n "$ARCH_EDIT" ]]; then
  if ! arch_text=$(pkgbuild_arch_words "${aur_dir}/PKGBUILD"); then
    log_err "--arch-out needs one arch=(...) line of plain arch names in the PKGBUILD"
    exit 1
  fi
  mapfile -t arch_words <<<"$arch_text"
  for arch in "${arch_words[@]}"; do
    [[ " $ARCH_OUT " == *" $arch "* ]] || new_words+=("$arch")
  done
  while IFS= read -r arch; do
    [[ -n "$arch" && " $ARCH_OUT " != *" $arch "* && " ${new_words[*]} " != *" $arch "* ]] || continue
    commit=$(ARCH="$arch" yq -r '.arch_out[strenv(ARCH)]' "$PKG_FILE")
    if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]] || ! ref=$(git -C "$aur_dir" show "$commit:.SRCINFO" 2>/dev/null); then
      log_err "The commit of arch_out.$arch is not in the AUR repo: $commit"
      exit 1
    fi
    log_info "Putting $arch back in arch=()"
    read -ra new_words <<<"$(arch_order "${new_words[*]}" "$arch" "$(srcinfo_arches <(printf '%s\n' "$ref") | tr '\n' ' ')")"
  done < <(pkg_get "$PKG_FILE" '.arch_out // {} | keys | .[]')
fi

# The AUR has this version when pkgver and pkgrel hold the values of the
# update, as bash reads them; a new asset value raises pkgrel
if [[ "$(_plain_value "${aur_dir}/PKGBUILD" pkgver)" == "$NEW_VERSION" ]] &&
  [[ "$(_plain_value "${aur_dir}/PKGBUILD" pkgrel)" == "$pkgrel" ]] &&
  [[ "${new_words[*]}" == "${arch_words[*]}" ]]; then
  log_ok "$PKG_NAME already at $NEW_VERSION on AUR, nothing to do"
  if [[ -n "$PREPARE_DIR" ]]; then
    hand_over
  elif [[ -z "$DRY_RUN" ]]; then
    pkg_set_current "$PKG_FILE" "$NEW_VERSION" "$ASSET"
  fi
  exit 2
fi

if [[ -n "$ASSET_VAR" ]]; then
  sed -i "s/^${ASSET_VAR}=.*/${ASSET_VAR}=${ASSET}/" "${aur_dir}/PKGBUILD"
fi
sed -i "s/^pkgver=.*/pkgver=${NEW_VERSION}/" "${aur_dir}/PKGBUILD"
sed -i "s/^pkgrel=.*/pkgrel=${pkgrel}/" "${aur_dir}/PKGBUILD"

# An arch of the list whose archives answer, as the PKGBUILD builds their
# URLs, stays: the check asked other URLs
skip_arches=""
if [[ -n "$ARCH_EDIT" ]]; then
  read -ra listed <<<"$ARCH_OUT"
  for arch in "${listed[@]}"; do
    [[ " ${arch_words[*]} " == *" $arch "* ]] || continue
    if arch_answers "${aur_dir}/PKGBUILD" "$arch"; then
      log_info "The archives of $arch answer, so it stays in arch=()"
      read -ra new_words <<<"$(arch_order "${new_words[*]}" "$arch" "${arch_words[*]}")"
    fi
  done
  for arch in "${listed[@]}"; do
    [[ " ${new_words[*]} " == *" $arch "* ]] || skip_arches+="${skip_arches:+ }$arch"
  done
  if ((${#new_words[@]} == 0)); then
    log_err "--arch-out would leave no arch in arch=()"
    exit 1
  fi
  if [[ "${new_words[*]}" != "${arch_words[*]}" ]]; then
    NEW_LINE=$(arch_line "$(grep -m1 '^arch=(' "${aur_dir}/PKGBUILD")" "${new_words[@]}")
    NEW_LINE="$NEW_LINE" awk 'index($0, "arch=(") == 1 && !done { print ENVIRON["NEW_LINE"]; done = 1; next } { print }' \
      "${aur_dir}/PKGBUILD" >"${tmp_dir}/PKGBUILD.arch"
    cat "${tmp_dir}/PKGBUILD.arch" >"${aur_dir}/PKGBUILD"
    log_info "$PKG_NAME $NEW_VERSION builds for ${new_words[*]}"
  fi
fi

# =============================================================================
# UPDATE CHECKSUMS
# =============================================================================

# Validate source URLs before downloading. A download with a SKIP checksum
# is checked too: no later step fetches it, so a URL that answers 404 or an
# HTML page would reach the AUR.
if ! validate_source_urls "${aur_dir}/PKGBUILD" "$skip_arches"; then
  log_err "Source URL validation failed, aborting"
  exit 1
fi

# updpkgsums would put a real hash in place of the SKIP of a download, of a
# fossil clone, or of a git, hg or bzr source at a pin makepkg hashes, and
# the audit blocks such a SKIP next to a remote hash. Next to any other SKIP
# of a VCS source, updpkgsums runs only for a remote hash, since makepkg -g
# clones the repository.
if has_skip_checksums "${aur_dir}/PKGBUILD" && ! has_remote_hash "${aur_dir}/PKGBUILD"; then
  log_info "VCS package, skipping checksums"
else
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

if [[ -n "$PREPARE_DIR" ]]; then
  hand_over
  exit 0
fi

# =============================================================================
# CHECK THE UPDATE
# =============================================================================

# The checks that publish-pkg.sh runs, against the files of the clone's HEAD
aur_files="${tmp_dir}/aur-files"
aur_export "$aur_dir" "$aur_files" || exit 1
check_prepared_files "$aur_files" "$aur_dir" "$NEW_VERSION" "$(pkgver_dash "$PKG_FILE")" \
  "$(pkg_get "$PKG_FILE" '.pkgver_format // ""')" "$ASSET_VAR" "$ASSET" || exit 1

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

git -C "$aur_dir" add PKGBUILD .SRCINFO || exit 1
aur_commit_push "$aur_dir" "$NEW_VERSION" "$strategy" "$pkgrel" || exit 1
log_ok "Pushed $PKG_NAME $NEW_VERSION to AUR"

# =============================================================================
# UPDATE PACKAGE YAML
# =============================================================================

log_info "Updating package YAML"
pkg_set_current "$PKG_FILE" "$NEW_VERSION" "$ASSET"
pkg_set "$PKG_FILE" .last_updated "\"$(date -u +%Y-%m-%d)\""
log_ok "Updated $PKG_FILE with current: $NEW_VERSION"
