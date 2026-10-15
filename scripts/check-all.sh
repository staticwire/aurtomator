#!/usr/bin/env bash
#
# check-all.sh - Check all packages for updates, optionally update them
#
# Usage: ./scripts/check-all.sh [--update | --prepare <dir> | --verify <dir> | --publish <dir>] [--dry-run]
#
# Without a mode: only checks and reports
# With --update: runs update-pkg.sh for each outdated package
# With --prepare <dir>: runs update-pkg.sh --prepare <dir>/prepared for each
#   package the check run before it found outdated, without running the
#   strategies, and copies the statuses to <dir>/status
# With --verify <dir>: runs verify-pkg.sh for each package in <dir>/prepared
#   and takes out the ones that fail, without running the strategies
# With --publish <dir>: runs publish-pkg.sh for each package in <dir>/prepared
#   and takes the other statuses from <dir>/status
# With --dry-run: runs update-pkg.sh or publish-pkg.sh in dry-run mode
#
# Writes per-package status to .status/ directory for README generation
# and auto-issue creation.

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
    --prepare | --verify | --publish)
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
      sed -n '3,19p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# --verify checks every update in <dir>/prepared with verify-pkg.sh. It takes
# out an update that fails, with an update_failed status, and one the AUR
# moved under, with its status kept, so --publish skips both. Only package
# names from packages/ reach a path.
if [[ "$MODE" == "verify" ]]; then
  failed=0
  for pkg_file in "${AURTOMATOR_DIR}"/packages/*.yml; do
    [[ -f "$pkg_file" ]] || continue
    pkg_name=$(pkg_get "$pkg_file" .name)
    prepared="${WORK_DIR}/prepared/${pkg_name}"
    if [[ -L "${WORK_DIR}/prepared" || ! -d "$prepared" ]]; then
      continue
    fi

    err_file=$(mktemp)
    verify_rc=0
    "${AURTOMATOR_DIR}/scripts/verify-pkg.sh" "$pkg_name" "$prepared" 2>"$err_file" || verify_rc=$?
    verify_err=$(<"$err_file")
    rm -f "$err_file"
    [[ -z "$verify_err" ]] || printf '%s\n' "$verify_err" >&2

    case "$verify_rc" in
      0) ;;
      3)
        rm -rf "$prepared"
        ;;
      *)
        log_err "Failed to verify $pkg_name"
        rm -rf "$prepared"
        mkdir -p "${WORK_DIR}/status"
        rm -f "${WORK_DIR}/status/${pkg_name}"
        echo "update_failed: ${verify_err}" >"${WORK_DIR}/status/${pkg_name}"
        ((failed++)) || true
        ;;
    esac
  done

  if ((failed > 0)); then
    count_file="${WORK_DIR}/status/_error_count"
    count=0
    if [[ -f "$count_file" && ! -L "$count_file" ]]; then
      count=$(<"$count_file")
    fi
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    rm -f "$count_file"
    echo "$((count + failed))" >"$count_file"
  fi
  exit 0
fi

# Status directory for per-package results
STATUS_DIR="${AURTOMATOR_DIR}/.status"

# --prepare runs code from PKGBUILDs, so the workflow gives it no
# GITHUB_TOKEN and it runs no strategy. It takes the versions from the
# statuses of the check run before it, read here before any PKGBUILD runs.
declare -A CHECKED=()
if [[ "$MODE" == "prepare" ]]; then
  for status_file in "$STATUS_DIR"/*; do
    [[ -f "$status_file" ]] || continue
    CHECKED["${status_file##*/}"]=$(<"$status_file")
  done
fi

rm -rf "$STATUS_DIR"
mkdir -p "$STATUS_DIR"

# --publish takes the statuses from the prepare run, which executed
# PKGBUILDs while it wrote them. Only statuses of known packages, in the
# forms that run writes, are copied. When this script stops early, .status/
# stays empty, so the steps after it read nothing from that run.
if [[ "$MODE" == "publish" && -d "${WORK_DIR}/status" && ! -L "${WORK_DIR}/status" ]]; then
  known_names=$(for f in "${AURTOMATOR_DIR}"/packages/*.yml; do
    [[ -f "$f" ]] && pkg_get "$f" .name
  done)
  for status_file in "${WORK_DIR}/status"/*; do
    [[ -f "$status_file" && ! -L "$status_file" ]] || continue
    name="${status_file##*/}"
    if [[ ! "$name" =~ ^[A-Za-z0-9@._+-]+$ ]] || ! grep -qxF -- "$name" <<<"$known_names"; then
      continue
    fi
    status="check_failed: invalid status from the prepare run"
    if ! _has_nul "$status_file"; then
      # The whole file, as update-readme.sh and the issue step read it
      handed_over=$(<"$status_file")
      case "$handed_over" in
        up_to_date | check_failed:* | update_failed:*)
          status="$handed_over"
          ;;
        "new_version: "* | "available_downgrade: "*)
          if validate_pkgver "${handed_over#*: }" 2>/dev/null; then
            status="$handed_over"
          fi
          ;;
      esac
    fi
    printf '%s\n' "$status" >"${STATUS_DIR}/${name}"
  done
fi

updated=0
checked=0
errors=0

# The version the check run found for a package, printed the way
# check-update.sh prints it: nothing when up to date, an error on failure
checked_version() {
  local status="${CHECKED[$1]:-}"
  case "$status" in
    "new_version: "* | "available_downgrade: "*)
      echo "${status#*: }"
      ;;
    up_to_date) ;;
    check_failed:*)
      echo "${status#check_failed: }" >&2
      return 1
      ;;
    *)
      echo "not checked before --prepare" >&2
      return 1
      ;;
  esac
}

for pkg_file in $(printf '%s\n' "${AURTOMATOR_DIR}"/packages/*.yml | sort); do
  [[ -f "$pkg_file" ]] || continue

  pkg_name=$(pkg_get "$pkg_file" .name)
  # Only package names from packages/ reach a path, never a name from WORK_DIR
  if [[ "$MODE" == "publish" ]] &&
    [[ -L "${WORK_DIR}/prepared" || ! -d "${WORK_DIR}/prepared/${pkg_name}" ]]; then
    continue
  fi
  ((checked++)) || true

  if [[ "$MODE" == "prepare" ]]; then
    check_cmd=(checked_version "$pkg_name")
  else
    check_cmd=("${AURTOMATOR_DIR}/scripts/check-update.sh" "$pkg_name")
  fi

  # Capture stderr separately for error reporting
  err_file=$(mktemp)
  latest=$("${check_cmd[@]}" 2>"$err_file") || {
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
      cmd=("${AURTOMATOR_DIR}/scripts/update-pkg.sh" "$pkg_name" "$latest" --prepare "${WORK_DIR}/prepared")
      ;;
    publish)
      log_info "Publishing $pkg_name $latest"
      cmd=("${AURTOMATOR_DIR}/scripts/publish-pkg.sh" "$pkg_name" "$latest" "${WORK_DIR}/prepared/${pkg_name}" ${DRY_RUN:+"$DRY_RUN"})
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
handed_count="${WORK_DIR}/status/_error_count"
if [[ "$MODE" == "publish" && -f "$handed_count" && ! -L "$handed_count" && ! -L "${WORK_DIR}/status" ]]; then
  prepare_errors=$(<"$handed_count")
  if [[ "$prepare_errors" =~ ^[0-9]+$ ]]; then
    errors=$((errors + prepare_errors))
  fi
fi

# Write summary for downstream steps
echo "${errors}" >"${STATUS_DIR}/_error_count"

# Hand the statuses to the publish run
if [[ "$MODE" == "prepare" ]]; then
  mkdir -p "${WORK_DIR}/status"
  cp "${STATUS_DIR}"/* "${WORK_DIR}/status/"
fi
