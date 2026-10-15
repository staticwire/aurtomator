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
# With --publish <dir>: keeps the statuses of the check run before it, and
#   runs publish-pkg.sh for each package that run found outdated
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

# Time budget of one package, in seconds: for its version check, and for
# its update, verify or publish
CHECK_TIMEOUT="${AURTOMATOR_CHECK_TIMEOUT:-120}"
UPDATE_TIMEOUT="${AURTOMATOR_UPDATE_TIMEOUT:-300}"

# Runs a per-package script within a budget. timeout runs it in a process
# group of its own and ends the whole group, makepkg, git and curl below it
# included. Such a group cannot read the terminal, where git and ssh may ask
# for a passphrase, so --update, which runs on a terminal, has no budget.
# Args: $1=budget in seconds, the command after it
bounded() {
  local budget="$1"
  shift
  if [[ "$MODE" == "update" ]]; then
    "$@"
  else
    timeout --kill-after=30 "$budget" "$@"
  fi
}

# Prints the error of a per-package script: the budget it ran out of, or
# its stderr. Args: $1=exit code, $2=stderr file, $3=budget in seconds
script_error() {
  case "$1" in
    124 | 137) echo "timed out after $3 s" ;;
    *) cat "$2" ;;
  esac
}

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

# --verify checks every update in <dir>/prepared with verify-pkg.sh and takes
# out an update that fails, with an update_failed status, so --publish skips
# it. An AUR repo that moved counts as a failure: the prepare run writes the
# base of every package, so a move looks the same as a wrong base. The next
# run prepares the package again. Only package names from packages/ reach a
# path.
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
    bounded "$UPDATE_TIMEOUT" "${AURTOMATOR_DIR}/scripts/verify-pkg.sh" "$pkg_name" "$prepared" 2>"$err_file" || verify_rc=$?
    verify_err=$(script_error "$verify_rc" "$err_file" "$UPDATE_TIMEOUT")
    rm -f "$err_file"
    [[ -z "$verify_err" ]] || printf '%s\n' "$verify_err" >&2

    case "$verify_rc" in
      0) ;;
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

# --prepare and --publish take the statuses of the check run before them,
# read here before anything else runs. --prepare runs code from PKGBUILDs,
# so the workflow gives it no GITHUB_TOKEN and it runs no strategy.
declare -A CHECKED=()
if [[ "$MODE" == "prepare" || "$MODE" == "publish" ]] && [[ ! -L "$STATUS_DIR" ]]; then
  for status_file in "$STATUS_DIR"/*; do
    [[ -f "$status_file" && ! -L "$status_file" ]] || continue
    CHECKED["${status_file##*/}"]=$(<"$status_file")
  done
fi

rm -rf "$STATUS_DIR"
mkdir -p "$STATUS_DIR"

# The update failure that the prepare or the verify run recorded for a
# package the check run found outdated. Both runs share one user with code
# from every PKGBUILD, so nothing else of theirs is taken, and a package
# they handed over nothing for fails as well.
handed_failure() {
  local status_dir="${WORK_DIR}/status"
  local file="${status_dir}/$1"
  if [[ -d "$status_dir" && ! -L "$status_dir" && -f "$file" && ! -L "$file" ]] &&
    ! _has_nul "$file"; then
    local handed
    handed=$(<"$file")
    if [[ "$handed" == update_failed:* ]]; then
      printf '%s\n' "$handed"
      return
    fi
  fi
  echo "update_failed: prepare and verify handed over no update"
}

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
  # --publish keeps the status of the check run and publishes only a package
  # that run found outdated. Only package names from packages/ reach a path,
  # never a name from WORK_DIR.
  if [[ "$MODE" == "publish" ]]; then
    found="${CHECKED[$pkg_name]:-}"
    case "$found" in
      "new_version: "* | "available_downgrade: "*)
        if ! validate_pkgver "${found#*: }" 2>/dev/null; then
          echo "check_failed: invalid status from the check run" >"${STATUS_DIR}/${pkg_name}"
          continue
        fi
        if [[ -L "${WORK_DIR}/prepared" || ! -d "${WORK_DIR}/prepared/${pkg_name}" ]]; then
          handed_failure "$pkg_name" >"${STATUS_DIR}/${pkg_name}"
          continue
        fi
        ;;
      up_to_date | check_failed:*)
        printf '%s\n' "$found" >"${STATUS_DIR}/${pkg_name}"
        continue
        ;;
      "")
        echo "check_failed: not checked before --publish" >"${STATUS_DIR}/${pkg_name}"
        continue
        ;;
      *)
        echo "check_failed: invalid status from the check run" >"${STATUS_DIR}/${pkg_name}"
        continue
        ;;
    esac
  fi
  ((checked++)) || true

  if [[ "$MODE" == "prepare" ]]; then
    check_cmd=(checked_version "$pkg_name")
  else
    check_cmd=(bounded "$CHECK_TIMEOUT" "${AURTOMATOR_DIR}/scripts/check-update.sh" "$pkg_name")
  fi

  # Capture stderr separately for error reporting
  err_file=$(mktemp)
  check_rc=0
  latest=$("${check_cmd[@]}" 2>"$err_file") || check_rc=$?
  if ((check_rc != 0)); then
    check_err=$(script_error "$check_rc" "$err_file" "$CHECK_TIMEOUT")
    rm -f "$err_file"
    log_err "Failed to check $pkg_name: $check_err"
    echo "check_failed: ${check_err}" >"${STATUS_DIR}/${pkg_name}"
    ((errors++)) || true
    continue
  fi
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
  bounded "$UPDATE_TIMEOUT" "${cmd[@]}" 2>"$err_file" || update_rc=$?
  update_err=$(script_error "$update_rc" "$err_file" "$UPDATE_TIMEOUT")
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

# --publish counts the failures among the statuses it wrote
if [[ "$MODE" == "publish" ]]; then
  errors=0
  for status_file in "$STATUS_DIR"/*; do
    [[ -f "$status_file" ]] || continue
    case "$(<"$status_file")" in
      check_failed:* | update_failed:*) ((errors++)) || true ;;
    esac
  done
fi

echo ""
log_info "Checked: $checked, Updated: $updated, Errors: $errors"

# Write summary for downstream steps
echo "${errors}" >"${STATUS_DIR}/_error_count"

# Hand the statuses to the publish run
if [[ "$MODE" == "prepare" ]]; then
  mkdir -p "${WORK_DIR}/status"
  cp "${STATUS_DIR}"/* "${WORK_DIR}/status/"
fi
