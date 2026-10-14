#!/usr/bin/env bash
#
# check-all.sh - Check all packages for updates, optionally update them
#
# Usage: ./scripts/check-all.sh [--update | --prepare <dir> | --publish <dir>] [--dry-run]
#
# Without a mode: only checks and reports
# With --update: runs update-pkg.sh for each outdated package
# With --prepare <dir>: runs update-pkg.sh --prepare <dir> instead
# With --publish <dir>: runs publish-pkg.sh for each package prepared in <dir>
# With --dry-run: runs update-pkg.sh or publish-pkg.sh in dry-run mode
#
# Writes per-package status to .status/ directory for README generation
# and auto-issue creation. --publish keeps the statuses of the packages it
# does not publish.

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq
require_cmd vercmp

MODE=check
WORK_DIR=""
DRY_RUN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update)
      MODE=update
      shift
      ;;
    --prepare | --publish)
      if [[ -z "${2:-}" ]]; then
        echo "$1 needs a directory" >&2
        exit 1
      fi
      MODE="${1#--}"
      WORK_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="--dry-run"
      shift
      ;;
    -h | --help)
      sed -n '3,15p' "$0"
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
if [[ "$MODE" != "publish" ]]; then
  rm -rf "$STATUS_DIR"
fi
mkdir -p "$STATUS_DIR"

# --publish keeps the statuses the prepare run wrote, and that run executes
# PKGBUILDs. Keep only statuses of known packages, in the forms that run
# writes, so that update-readme.sh and the issue step read nothing else.
if [[ "$MODE" == "publish" ]]; then
  known_names=$(for f in "${AURTOMATOR_DIR}"/packages/*.yml; do
    [[ -f "$f" ]] && pkg_get "$f" .name
  done)
  for status_file in "$STATUS_DIR"/*; do
    [[ -f "$status_file" ]] || continue
    name="${status_file##*/}"
    [[ "$name" == "_error_count" ]] && continue
    if [[ ! "$name" =~ ^[A-Za-z0-9@._+-]+$ ]] || ! grep -qxF -- "$name" <<<"$known_names"; then
      rm -f "$status_file"
      continue
    fi
    status=$(head -n 1 "$status_file")
    case "$status" in
      up_to_date | check_failed:* | update_failed:*) ;;
      "new_version: "* | "available_downgrade: "*)
        validate_pkgver "${status#*: }" 2>/dev/null ||
          echo "check_failed: invalid status from the prepare run" >"$status_file"
        ;;
      *)
        echo "check_failed: invalid status from the prepare run" >"$status_file"
        ;;
    esac
  done
fi

updated=0
checked=0
errors=0

for pkg_file in $(printf '%s\n' "${AURTOMATOR_DIR}"/packages/*.yml | sort); do
  [[ -f "$pkg_file" ]] || continue

  pkg_name=$(pkg_get "$pkg_file" .name)
  # Only package names from packages/ reach a path, never a name from WORK_DIR
  if [[ "$MODE" == "publish" && ! -d "${WORK_DIR}/${pkg_name}" ]]; then
    continue
  fi
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

  # Detect downgrade: current from YAML is newer than latest from upstream.
  # vercmp prints -1/0/1 to stdout, always exits 0.
  current=$(pkg_get "$pkg_file" '.current // ""')
  is_downgrade=false
  if [[ -n "$current" ]]; then
    cmp=$(vercmp "$current" "$latest")
    if [[ "$cmp" -gt 0 ]]; then
      is_downgrade=true
      log_warn "$pkg_name: DOWNGRADE detected $current → $latest (mirroring upstream)"
    fi
  fi

  if [[ "$is_downgrade" == "true" ]]; then
    available="available_downgrade: ${latest}"
    pushed="downgrade: ${latest}"
  else
    available="new_version: ${latest}"
    pushed="updated: ${latest}"
  fi

  case "$MODE" in
    check)
      echo "$available" >"${STATUS_DIR}/${pkg_name}"
      continue
      ;;
    update)
      log_info "Updating $pkg_name to $latest"
      cmd=("${AURTOMATOR_DIR}/scripts/update-pkg.sh" "$pkg_name" "$latest" ${DRY_RUN:+"$DRY_RUN"})
      ;;
    prepare)
      log_info "Preparing $pkg_name $latest"
      cmd=("${AURTOMATOR_DIR}/scripts/update-pkg.sh" "$pkg_name" "$latest" --prepare "$WORK_DIR")
      ;;
    publish)
      log_info "Publishing $pkg_name $latest"
      cmd=("${AURTOMATOR_DIR}/scripts/publish-pkg.sh" "$pkg_name" "$latest" "${WORK_DIR}/${pkg_name}" ${DRY_RUN:+"$DRY_RUN"})
      ;;
  esac

  err_file=$(mktemp)
  update_rc=0
  "${cmd[@]}" 2>"$err_file" || update_rc=$?
  update_err=$(cat "$err_file")
  rm -f "$err_file"

  case "$MODE:$update_rc" in
    prepare:0 | prepare:2)
      # Pushed or synced later by --publish
      echo "$available" >"${STATUS_DIR}/${pkg_name}"
      ;;
    *:0)
      echo "$pushed" >"${STATUS_DIR}/${pkg_name}"
      ((updated++)) || true
      ;;
    *:2)
      # AUR already at this version, YAML synced by update-pkg.sh or publish-pkg.sh
      echo "up_to_date" >"${STATUS_DIR}/${pkg_name}"
      ;;
    publish:3)
      # The AUR or upstream moved after prepare; the next run prepares again
      echo "$available" >"${STATUS_DIR}/${pkg_name}"
      ;;
    *)
      log_err "Failed to update $pkg_name to $latest"
      echo "update_failed: ${update_err}" >"${STATUS_DIR}/${pkg_name}"
      ((errors++)) || true
      ;;
  esac
done

echo ""
log_info "Checked: $checked, Updated: $updated, Errors: $errors"

# --publish adds its errors to those of the prepare run. The file comes from
# that run, so it is read only when it holds a plain number.
if [[ "$MODE" == "publish" && -f "${STATUS_DIR}/_error_count" ]]; then
  prepare_errors=$(<"${STATUS_DIR}/_error_count")
  if [[ "$prepare_errors" =~ ^[0-9]+$ ]]; then
    errors=$((errors + prepare_errors))
  fi
fi

# Write summary for downstream steps
echo "${errors}" >"${STATUS_DIR}/_error_count"
