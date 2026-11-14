#!/usr/bin/env bash
# Usage: check-arch.sh <package> <version> [--asset <value>], see https://aurtomator.dev/features/missing-arches/
# Prints the arches out after an update and the start of their wait; exit 3 waits
# and prints the start, the arches it waits for and the AUR commit that builds them

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq
# A UTF-8 locale widens [a-z], and grep leaves out a line with a byte that is no UTF-8
export LC_ALL=C

readonly USAGE="Usage: check-arch.sh <package> <version> [--asset <value>]"
readonly PKG_NAME="${1:?$USAGE}"
readonly VERSION="${2:?$USAGE}"
ASSET=""
if [[ "${3:-}" == --asset && $# -eq 4 ]]; then
  ASSET="$4"
elif (($# != 2)); then
  log_err "$USAGE"
  exit 1
fi
readonly ASSET
validate_pkgver "$VERSION" || exit 1
[[ -z "$ASSET" ]] || validate_asset_value "$ASSET" || exit 1
PKG_FILE="$(pkg_file "$PKG_NAME")"
readonly PKG_FILE

# How long a version waits for the archive of an arch, in seconds
readonly ARCH_WAIT=$((24 * 3600))

# Print the arches that stay out after the update and the start of the wait
finish() {
  printf '%s\n%s\n' "$1" "${2:-}"
  exit 0
}

missing_arch_allowed "$PKG_FILE" || finish ""
dash=$(pkgver_dash "$PKG_FILE")
format=$(pkg_get "$PKG_FILE" '.pkgver_format // ""')
asset_var=$(pkg_asset_var "$PKG_FILE") || exit 1

declare -A out_commit=()
mapfile -t out_keys < <(pkg_get "$PKG_FILE" '.arch_out // {} | keys | .[]')
for arch in "${out_keys[@]}"; do
  commit=$(ARCH="$arch" yq -r '.arch_out[strenv(ARCH)]' "$PKG_FILE")
  if [[ ! "$arch" =~ ^[a-z0-9_]+$ || ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    log_err "$PKG_NAME: arch_out must map arch names to commit ids of 40 hex digits"
    exit 1
  fi
  out_commit[$arch]=$commit
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
aur="$work/aur"
if ! aur_clone "https://aur.archlinux.org/${PKG_NAME}.git" "$aur" --no-checkout >&2; then
  log_warn "$PKG_NAME: no answer from the AUR, so the arches out stay out in this run"
  finish "${out_keys[*]}"
fi
aur_reanchor "$aur" --no-checkout >&2

# Write the PKGBUILD and .SRCINFO of commit $1 of the AUR repo to directory $2
aur_files_at() {
  mkdir -p "$2"
  git -C "$aur" show "$1:PKGBUILD" >"$2/PKGBUILD" 2>/dev/null &&
    git -C "$aur" show "$1:.SRCINFO" >"$2/.SRCINFO" 2>/dev/null
}

if ! aur_files_at HEAD "$work/HEAD"; then
  log_warn "$PKG_NAME: the AUR repo has no PKGBUILD or .SRCINFO, so the arches out stay out"
  finish "${out_keys[*]}"
fi
for arch in "${out_keys[@]}"; do
  if ! aur_files_at "${out_commit[$arch]}" "$work/$arch"; then
    log_err "$PKG_NAME: the commit ${out_commit[$arch]} of arch_out.$arch is not in the AUR repo"
    exit 1
  fi
  if ! srcinfo_arches "$work/$arch/.SRCINFO" | grep -qxF -e "$arch"; then
    log_err "$PKG_NAME: the commit ${out_commit[$arch]} of arch_out.$arch does not build $arch"
    exit 1
  fi
done

if ! arch_text=$(pkgbuild_arch_words "$work/HEAD/PKGBUILD"); then
  log_info "$PKG_NAME: the AUR PKGBUILD has no arch=(...) line of plain names alone, so an update cannot leave an arch out"
  finish "${out_keys[*]}"
fi
mapfile -t arches <<<"$arch_text"

# An arch of arch_out that arch=() names again was put back by hand
out_now=()
for arch in "${out_keys[@]}"; do
  if [[ " ${arches[*]} " == *" $arch "* ]]; then
    log_info "$PKG_NAME: $arch of arch_out is in arch=() of the AUR again"
  else
    out_now+=("$arch")
  fi
done

# At the version and asset value of the AUR only the arches out are asked
aur_asset=""
[[ -z "$asset_var" ]] || aur_asset=$(_plain_value "$work/HEAD/PKGBUILD" "$asset_var")
new_asset="${ASSET:-$aur_asset}"
ask=()
if [[ "$(srcinfo_pkgver "$work/HEAD/.SRCINFO")" != "$VERSION" || "$aur_asset" != "$new_asset" ]]; then
  ask=("${arches[@]}")
fi
ask+=("${out_now[@]}")

declare -A missing=()
for arch in "${ask[@]}"; do
  dir="$work/HEAD"
  [[ " ${out_now[*]} " != *" $arch "* ]] || dir="$work/$arch"
  old_ver=$(srcinfo_pkgver "$dir/.SRCINFO")
  old_asset=""
  [[ -z "$asset_var" ]] || old_asset=$(_plain_value "$dir/PKGBUILD" "$asset_var")
  old_up=""
  new_up=""
  if [[ -n "$format" ]]; then
    old_up=$(_unformat_version "$old_ver" "$format")
    new_up=$(_unformat_version "$VERSION" "$format")
  fi
  while IFS= read -r url; do
    rc=0
    probe_url "$url" || rc=$?
    if ((rc == 2)); then
      log_err "$PKG_NAME $VERSION: no answer from $url"
      exit 1
    elif ((rc == 1)); then
      log_warn "$PKG_NAME $VERSION: no archive for $arch at $url"
      missing[$arch]=1
    fi
  done < <(arch_urls "$dir/.SRCINFO" "$arch" "$old_ver" "$VERSION" "$old_up" "$new_up" "$dash" "$old_asset" "$new_asset")
done

leaving=()
staying=()
for arch in "${arches[@]}"; do
  [[ -z "${missing[$arch]:-}" ]] || leaving+=("$arch")
done
for arch in "${out_now[@]}"; do
  [[ -z "${missing[$arch]:-}" ]] || staying+=("$arch")
done
if ((${#leaving[@]} == 0)); then
  finish "${staying[*]}"
fi
if [[ " ${leaving[*]} " == *" x86_64 "* ]] || ((${#leaving[@]} == ${#arches[@]})); then
  log_warn "$PKG_NAME $VERSION: without x86_64 or without every arch there is no update"
  finish ""
fi

# The wait counts from the first run that saw the version without an arch
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start=$now
if [[ "$(pkg_get "$PKG_FILE" '.arch_wait.version // ""')" == "$VERSION" ]]; then
  since=$(pkg_get "$PKG_FILE" '.arch_wait.since // ""')
  ! valid_time "$since" || [[ "$since" > "$now" ]] || start=$since
fi
if (($(date -u -d "$now" +%s) - $(date -u -d "$start" +%s) < ARCH_WAIT)); then
  log_warn "$PKG_NAME $VERSION: no archive for ${leaving[*]}, pending for $((ARCH_WAIT / 3600)) h from $start"
  printf '%s\n%s\n%s\n' "$start" "${leaving[*]}" "$(git -C "$aur" rev-parse HEAD)"
  exit 3
fi
finish "${leaving[*]}${staying[*]:+ ${staying[*]}}" "$start"
