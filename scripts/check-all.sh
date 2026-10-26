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
#   runs publish-pkg.sh for each package that run found outdated, with the
#   version that run found and without running the strategies
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

# Pause, in seconds, before a package whose check failed is checked again
RECHECK_DELAY="${AURTOMATOR_RECHECK_DELAY:-60}"

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
      sed -n '3,20p' "$0"
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
# read here before anything else runs, and run no strategy: --prepare runs
# code from PKGBUILDs without GITHUB_TOKEN, and --publish holds the AUR and
# GPG keys.
declare -A CHECKED=()
if [[ "$MODE" == "prepare" || "$MODE" == "publish" ]] && [[ ! -L "$STATUS_DIR" ]]; then
  for status_file in "$STATUS_DIR"/*; do
    [[ -f "$status_file" && ! -L "$status_file" ]] || continue
    CHECKED["${status_file##*/}"]=$(<"$status_file")
  done
fi

rm -rf "$STATUS_DIR"
mkdir -p "$STATUS_DIR"

# The version of aurtomator, and in a mode that runs the strategies its
# latest release, for the README line and its issue. A failed request
# records nothing, so it closes no issue. --prepare and --publish carry the
# record of the check run.
AURTOMATOR_VERSION=$(aurtomator_version)
[[ -z "$AURTOMATOR_VERSION" ]] || log_info "aurtomator $AURTOMATOR_VERSION"
if [[ "$MODE" == "prepare" || "$MODE" == "publish" ]]; then
  if [[ "${CHECKED[_upstream]:-}" =~ ^(newer|current):\ [0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "${CHECKED[_upstream]}" >"${STATUS_DIR}/_upstream"
  fi
elif [[ -n "$AURTOMATOR_VERSION" ]]; then
  if UPSTREAM_STATUS=$(upstream_status); then
    printf '%s\n' "$UPSTREAM_STATUS" >"${STATUS_DIR}/_upstream"
    [[ "$UPSTREAM_STATUS" != newer:* ]] || log_warn "aurtomator ${UPSTREAM_STATUS#newer: } is out, this repository runs $AURTOMATOR_VERSION"
  else
    log_warn "Could not read the latest aurtomator release"
  fi
fi

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

# The version the check run found for a package, printed the way
# check-update.sh prints it: nothing when up to date, an error on failure.
# A rebuild prints the version it rebuilds. A skipped downgrade or version
# jump, a held update and a pending asset print their version, and the
# checks below skip, hold or keep it pending again.
checked_version() {
  local status="${CHECKED[$1]:-}"
  case "$status" in
    "new_version: "* | "available_downgrade: "* | "new_build: "* | "downgrade_skipped: "* | "jump_skipped: "* | "held: "* | "pending: "*)
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

# Appends the alerts that fired for a package to _alerts, where the issue
# steps read their notes: the package, a tab and a line of fired_alerts
# Args: $1=package name, $2=output of fired_alerts
record_alerts() {
  [[ -z "$2" ]] || awk -v p="$1" '{ print p "\t" $0 }' <<<"$2" >>"${STATUS_DIR}/_alerts"
}

# Sets ASSET_VALUE to the value that a release asset name holds for a
# version of a package with upstream.asset_regex, and records it in
# _assets: check-asset.sh finds it in a mode that runs the strategies,
# and --prepare and --publish take the one the check run recorded. A
# pending value and a failure get their status here, and return 1. A
# failure that comes fast goes on the list for the second pass, as a
# failed check does.
# Args: $1=package file, $2=package name, $3=version, $4=pass, 1 or 2
find_asset() {
  local rc=0 err_file err
  if [[ "$MODE" == "prepare" || "$MODE" == "publish" ]]; then
    if [[ "${CHECKED[$2]:-}" == "pending: "* ]]; then
      printf '%s\n' "${CHECKED[$2]}" >"${STATUS_DIR}/$2"
      return 1
    fi
    ASSET_VALUE=$(awk -F'\t' -v p="$2" '$1 == p { v = $2 } END { print v }' <<<"${CHECKED[_assets]:-}")
    if ! validate_asset_value "$ASSET_VALUE" 2>/dev/null; then
      echo "check_failed: no asset value from the check run" >"${STATUS_DIR}/$2"
      return 1
    fi
  else
    err_file=$(mktemp)
    ASSET_VALUE=$(bounded "$CHECK_TIMEOUT" "${AURTOMATOR_DIR}/scripts/check-asset.sh" "$2" "$3" 2>"$err_file") || rc=$?
    err=$(script_error "$rc" "$err_file" "$CHECK_TIMEOUT")
    rm -f "$err_file"
    if ((rc == 3)); then
      printf '%s\n' "$err" >&2
      echo "pending: $3" >"${STATUS_DIR}/$2"
      return 1
    fi
    if ((rc != 0)); then
      log_err "Failed to check $2: $err"
      echo "check_failed: ${err}" >"${STATUS_DIR}/$2"
      if ((rc != 124 && rc != 137 && $4 == 1)); then
        RECHECK+=("$1")
      fi
      return 1
    fi
  fi
  printf '%s\t%s\n' "$2" "$ASSET_VALUE" >>"${STATUS_DIR}/_assets"
}

# Checks one package, then updates, prepares or publishes it as the mode
# says, and writes its status. A check that fails fast in a mode that runs
# the strategies goes on the list for the second pass.
# Args: $1=package file, $2=pass, 1 or 2
run_package() {
  local pkg_file="$1" pass="$2"
  local pkg_name found check_cmd err_file check_rc latest check_err current asset_regex
  local is_downgrade cmp alerts fired line held action note available pushed cmd update_rc update_err
  pkg_name=$(pkg_get "$pkg_file" .name)
  # --publish keeps the status of the check run and publishes only a package
  # that run found outdated. Only package names from packages/ reach a path,
  # never a name from WORK_DIR.
  if [[ "$MODE" == "publish" ]]; then
    found="${CHECKED[$pkg_name]:-}"
    case "$found" in
      "new_version: "* | "available_downgrade: "* | "new_build: "*)
        if ! validate_pkgver "${found#*: }" 2>/dev/null; then
          echo "check_failed: invalid status from the check run" >"${STATUS_DIR}/${pkg_name}"
          return
        fi
        if [[ -L "${WORK_DIR}/prepared" || ! -d "${WORK_DIR}/prepared/${pkg_name}" ]]; then
          handed_failure "$pkg_name" >"${STATUS_DIR}/${pkg_name}"
          return
        fi
        ;;
      up_to_date | check_failed:* | "downgrade_skipped: "* | "jump_skipped: "* | "held: "* | "pending: "*)
        printf '%s\n' "$found" >"${STATUS_DIR}/${pkg_name}"
        # The issue of a held update lists the notes of its alerts
        [[ "$found" != "held: "* ]] || record_alerts "$pkg_name" "$(fired_alerts "$pkg_file" "$(pkg_get "$pkg_file" '.current // ""')" "${found#held: }" 2>/dev/null)"
        return
        ;;
      "")
        echo "check_failed: not checked before --publish" >"${STATUS_DIR}/${pkg_name}"
        return
        ;;
      *)
        echo "check_failed: invalid status from the check run" >"${STATUS_DIR}/${pkg_name}"
        return
        ;;
    esac
  fi
  ((pass == 2)) || ((checked++)) || true

  if [[ "$MODE" == "prepare" || "$MODE" == "publish" ]]; then
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
    if ((pass == 1)) && [[ "${check_cmd[0]}" == bounded ]] &&
      ((check_rc != 124 && check_rc != 137)); then
      RECHECK+=("$pkg_file")
    fi
    return
  fi
  rm -f "$err_file"

  # A package with asset_regex that is up to date checks the asset value of
  # its version as well: a value other than current_asset is a rebuild of
  # that version. --prepare and --publish get a rebuild as its version.
  current=$(pkg_get "$pkg_file" '.current // ""')
  asset_regex=$(pkg_get "$pkg_file" '.upstream.asset_regex // ""')
  ASSET_VALUE=""
  if [[ -z "$latest" && -n "$asset_regex" && "$MODE" != "prepare" && "$MODE" != "publish" ]]; then
    find_asset "$pkg_file" "$pkg_name" "$current" "$pass" || return 0
    [[ "$ASSET_VALUE" == "$(pkg_get "$pkg_file" '.current_asset // ""')" ]] || latest="$current"
  fi

  if [[ -z "$latest" ]]; then
    echo "up_to_date" >"${STATUS_DIR}/${pkg_name}"
    return
  fi

  # Detect downgrade: current from YAML is newer than latest from upstream.
  # vercmp prints -1/0/1 to stdout, always exits 0.
  is_downgrade=false
  if [[ -n "$current" ]]; then
    cmp=$(vercmp "$current" "$latest")
    if [[ "$cmp" -gt 0 ]]; then
      is_downgrade=true
    fi
  fi

  # A lower version reaches the AUR only for a package that allows it. The
  # latest release of a GitHub project can be a maintenance release of an
  # older line.
  if [[ "$is_downgrade" == "true" ]] &&
    [[ "$(pkg_get "$pkg_file" '.allow_downgrade // false')" != "true" ]]; then
    log_warn "$pkg_name: DOWNGRADE detected $current → $latest, skipped: allow_downgrade is not set"
    echo "downgrade_skipped: ${latest}" >"${STATUS_DIR}/${pkg_name}"
    return
  fi

  # A first number that grows by two digits or more is more often another
  # version scheme than a release: build tags next to release tags, or a
  # build number in place of 4.<build>. It reaches the AUR only for a
  # package that allows it.
  if version_jump "$current" "$latest" &&
    [[ "$(pkg_get "$pkg_file" '.allow_version_jump // false')" != "true" ]]; then
    log_warn "$pkg_name: version jump $current → $latest, skipped: allow_version_jump is not set"
    echo "jump_skipped: ${latest}" >"${STATUS_DIR}/${pkg_name}"
    return
  fi

  # An alert names a step of upstream that needs a hand edit. One with
  # hold: true keeps the update back until the maintainer publishes it.
  err_file=$(mktemp)
  check_rc=0
  alerts=$(fired_alerts "$pkg_file" "$current" "$latest" 2>"$err_file") || check_rc=$?
  check_err=$(<"$err_file")
  rm -f "$err_file"
  if ((check_rc != 0)); then
    log_err "Failed to check $pkg_name: $check_err"
    echo "check_failed: ${check_err}" >"${STATUS_DIR}/${pkg_name}"
    return
  fi
  record_alerts "$pkg_name" "$alerts"
  held=false
  mapfile -t fired <<<"$alerts"
  for line in "${fired[@]}"; do
    IFS=$'\t' read -r action note <<<"$line"
    case "$action" in
      hold)
        held=true
        log_warn "$pkg_name: update $current → $latest held: $note"
        ;;
      notice) log_warn "$pkg_name: update $current → $latest notice: $note" ;;
    esac
  done
  if [[ "$held" == true ]]; then
    echo "held: ${latest}" >"${STATUS_DIR}/${pkg_name}"
    return
  fi

  # The asset value of a new version, once no skip or hold stops it
  if [[ -n "$asset_regex" && -z "$ASSET_VALUE" ]]; then
    find_asset "$pkg_file" "$pkg_name" "$latest" "$pass" || return 0
  fi

  if [[ "$latest" == "$current" ]]; then
    available="new_build: ${latest}"
    pushed="rebuilt: ${latest}"
  elif [[ "$is_downgrade" == "true" ]]; then
    log_warn "$pkg_name: DOWNGRADE detected $current → $latest (mirroring upstream)"
    available="available_downgrade: ${latest}"
    pushed="downgrade: ${latest}"
  else
    available="new_version: ${latest}"
    pushed="updated: ${latest}"
  fi

  case "$MODE" in
    check)
      echo "$available" >"${STATUS_DIR}/${pkg_name}"
      return
      ;;
    update)
      log_info "Updating $pkg_name to $latest"
      cmd=("${AURTOMATOR_DIR}/scripts/update-pkg.sh" "$pkg_name" "$latest" ${ASSET_VALUE:+--asset} ${ASSET_VALUE:+"$ASSET_VALUE"} ${DRY_RUN:+"$DRY_RUN"})
      ;;
    prepare)
      log_info "Preparing $pkg_name $latest"
      cmd=("${AURTOMATOR_DIR}/scripts/update-pkg.sh" "$pkg_name" "$latest" ${ASSET_VALUE:+--asset} ${ASSET_VALUE:+"$ASSET_VALUE"} --prepare "${WORK_DIR}/prepared")
      ;;
    publish)
      log_info "Publishing $pkg_name $latest"
      cmd=("${AURTOMATOR_DIR}/scripts/publish-pkg.sh" "$pkg_name" "$latest" "${WORK_DIR}/prepared/${pkg_name}" ${ASSET_VALUE:+--asset} ${ASSET_VALUE:+"$ASSET_VALUE"} ${DRY_RUN:+"$DRY_RUN"})
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
      # The AUR moved after prepare; the next run prepares again
      echo "$available" >"${STATUS_DIR}/${pkg_name}"
      ;;
    *)
      log_err "Failed to update $pkg_name to $latest"
      echo "update_failed: ${update_err}" >"${STATUS_DIR}/${pkg_name}"
      ;;
  esac
}

RECHECK=()
for pkg_file in "${AURTOMATOR_DIR}"/packages/*.yml; do
  [[ -f "$pkg_file" ]] || continue
  run_package "$pkg_file" 1
done

# A check that failed fast gets a second try after a pause, by when a
# failure of the upstream host can be over. A check that ran out of its
# budget gets none, so a run without network stays within the time limit
# of its job.
if ((${#RECHECK[@]} > 0)); then
  log_info "Checking ${#RECHECK[@]} failed package(s) again in ${RECHECK_DELAY} s"
  sleep "$RECHECK_DELAY"
  for pkg_file in "${RECHECK[@]}"; do
    run_package "$pkg_file" 2
  done
fi

# Count the failures among the statuses written
errors=0
for status_file in "$STATUS_DIR"/*; do
  [[ -f "$status_file" ]] || continue
  case "$(<"$status_file")" in
    check_failed:* | update_failed:*) ((errors++)) || true ;;
  esac
done

echo ""
log_info "Checked: $checked, Updated: $updated, Errors: $errors"

# Write summary for downstream steps
echo "${errors}" >"${STATUS_DIR}/_error_count"

# Hand the statuses to the publish run
if [[ "$MODE" == "prepare" ]]; then
  mkdir -p "${WORK_DIR}/status"
  cp "${STATUS_DIR}"/* "${WORK_DIR}/status/"
fi
