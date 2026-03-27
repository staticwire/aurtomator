#!/usr/bin/env bash
#
# check-all.sh — Check all packages for updates, optionally update them
#
# Usage: ./scripts/check-all.sh [--update] [--dry-run]
#
# Without --update: only checks and reports
# With --update: runs update-pkg.sh for each outdated package
# With --dry-run: runs update-pkg.sh in dry-run mode
#
# Writes per-package status to .status/ directory for README generation
# and auto-issue creation.

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq

UPDATE=false
DRY_RUN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update)
      UPDATE=true
      shift
      ;;
    --dry-run)
      DRY_RUN="--dry-run"
      shift
      ;;
    -h | --help)
      sed -n '3,9p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Status directory for per-package results
STATUS_DIR="${AURTOMATOR_DIR}/.status"
rm -rf "$STATUS_DIR"
mkdir -p "$STATUS_DIR"

updated=0
checked=0
errors=0

for pkg_file in $(printf '%s\n' "${AURTOMATOR_DIR}"/packages/*.yml | sort); do
  [[ -f "$pkg_file" ]] || continue

  pkg_name=$(pkg_get "$pkg_file" .name)
  ((checked++)) || true

  # Capture stderr separately for error reporting
  err_file=$(mktemp)
  latest=$("${AURTOMATOR_DIR}/scripts/check-update.sh" "$pkg_name" 2>"$err_file") || {
    check_err=$(cat "$err_file")
    rm -f "$err_file"
    log_err "Failed to check $pkg_name: $check_err"
    echo "check_failed: ${check_err}" >"${STATUS_DIR}/${pkg_name}"
    ((errors++)) || true
    continue
  }
  rm -f "$err_file"

  if [[ -z "$latest" ]]; then
    echo "up_to_date" >"${STATUS_DIR}/${pkg_name}"
    continue
  fi

  if [[ "$UPDATE" == "true" ]]; then
    log_info "Updating $pkg_name to $latest"
    err_file=$(mktemp)
    update_rc=0
    # shellcheck disable=SC2086
    "${AURTOMATOR_DIR}/scripts/update-pkg.sh" "$pkg_name" "$latest" $DRY_RUN 2>"$err_file" || update_rc=$?
    update_err=$(cat "$err_file")
    rm -f "$err_file"

    case "$update_rc" in
      0)
        echo "updated: ${latest}" >"${STATUS_DIR}/${pkg_name}"
        ((updated++)) || true
        ;;
      2)
        # AUR already at this version, YAML synced by update-pkg.sh
        echo "up_to_date" >"${STATUS_DIR}/${pkg_name}"
        ;;
      *)
        log_err "Failed to update $pkg_name to $latest"
        echo "update_failed: ${update_err}" >"${STATUS_DIR}/${pkg_name}"
        ((errors++)) || true
        ;;
    esac
  else
    echo "new_version: ${latest}" >"${STATUS_DIR}/${pkg_name}"
  fi
done

echo ""
log_info "Checked: $checked, Updated: $updated, Errors: $errors"

# Write summary for downstream steps
echo "${errors}" >"${STATUS_DIR}/_error_count"
