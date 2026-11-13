#!/usr/bin/env bash
#
# check-all.sh - Check all packages for updates, optionally update them
#
# Usage: ./scripts/check-all.sh [--update | --prepare <dir> | --verify <dir> | --publish <dir>] [--dry-run]
#
# Without a mode: only checks and reports
# With --update: runs update-pkg.sh for each outdated package
# With --prepare <dir>: runs update-pkg.sh --prepare <dir>/prepared for each
#   package the check run found outdated, and copies the statuses to <dir>/status
# With --verify <dir>: runs verify-pkg.sh for each package in <dir>/prepared
#   and removes the ones that fail
# With --publish <dir>: runs publish-pkg.sh for each package the check run
#   found outdated, with the version it found, and keeps its other statuses
# --prepare, --verify and --publish run no strategy.
# With --dry-run: runs update-pkg.sh or publish-pkg.sh with --dry-run
#
# Writes the status of each package to .status/ under AURTOMATOR_DATA_DIR,
# where update-readme.sh and the issue steps read it.

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

# Time budget of the verify loop, in seconds: no package starts after it,
# so the verify job ends within its 30 minutes
VERIFY_BUDGET="${AURTOMATOR_VERIFY_BUDGET:-1200}"

# Pause, in seconds, before a package whose check failed is checked again
RECHECK_DELAY="${AURTOMATOR_RECHECK_DELAY:-60}"

# The UTC day of the run, for the cooldown
TODAY=$(date -u +%F)

# Runs a command under timeout, which ends its children as well. --update runs
# it bare: under timeout git and ssh cannot read a passphrase from the terminal.
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

# Prints the error of a per-package script: its stderr, or the budget it ran out
# of and the URL $4 of a request in flight. $1=exit code, $2=stderr file, $3=budget
script_error() {
  case "$1" in
    124 | 137) echo "${4:+$4: }timed out after $3 s" ;;
    *) cat "$2" ;;
  esac
}

# Clears the request in flight of a check that exited with $1. After a timeout it
# prints the URL, and remembers the host when a HEAD request of 10 s gets no status
request_done() {
  local url check rc=0 code
  host_memory || return 0
  if [[ "$1" == 124 || "$1" == 137 ]] && { read -r url && read -r check; } <"$AURTOMATOR_HOSTS_DIR/request"; then
    printf '%s\n' "$url"
    code=$(curl -sI -o /dev/null --max-time 10 --proto '=https' -A "$USER_AGENT" -w '%{http_code}' "$check" 2>/dev/null) || rc=$?
    if ((rc == 28)) && [[ "$code" == 000 ]]; then
      remember_host "$url"
    fi
  fi
  : >"$AURTOMATOR_HOSTS_DIR/request"
}

# Succeeds when a check that failed with exit code $1 and error $2 gets a second
# pass: none after a timeout, none when the first URL of $2 is on a silent host
second_pass() {
  (($1 != 124 && $1 != 137)) || return 1
  host_memory || return 0
  [[ "$2" =~ https?://([A-Za-z0-9.-]+) ]] || return 0
  ! grep -qxF -e "${BASH_REMATCH[1],,}" "$AURTOMATOR_HOSTS_DIR/silent"
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

# The memory of the hosts that did not answer in this run, for the requests of
# the checks; the modes that run no strategy keep none
unset AURTOMATOR_HOSTS_DIR
if [[ "$MODE" == check || "$MODE" == update ]]; then
  AURTOMATOR_HOSTS_DIR=$(mktemp -d)
  export AURTOMATOR_HOSTS_DIR
  trap 'rm -rf "$AURTOMATOR_HOSTS_DIR"' EXIT
  : >"$AURTOMATOR_HOSTS_DIR/silent"
  : >"$AURTOMATOR_HOSTS_DIR/request"
fi

STATUS_DIR="${AURTOMATOR_DATA_DIR}/.status"

# --prepare, --verify and --publish run no strategy: they take the statuses of
# the check run, read here before the run clears .status/
declare -A CHECKED=()
if [[ "$MODE" == "prepare" || "$MODE" == "verify" || "$MODE" == "publish" ]] && [[ ! -L "$STATUS_DIR" ]]; then
  for status_file in "$STATUS_DIR"/*; do
    [[ -f "$status_file" && ! -L "$status_file" ]] || continue
    CHECKED["${status_file##*/}"]=$(<"$status_file")
  done
fi

# A failed verify, exit code 3 of a moved AUR repo included, takes the update
# out with update_failed. Only package names from packages/ reach a path.
if [[ "$MODE" == "verify" ]]; then
  # Slow sources early in the list would take the budget of the same packages in
  # every run, so the loop starts at another package each hour
  verify_files=()
  for pkg_file in "${AURTOMATOR_DATA_DIR}"/packages/*.yml; do
    if [[ -f "$pkg_file" ]]; then
      verify_files+=("$pkg_file")
    fi
  done
  verify_start=0
  ((${#verify_files[@]} == 0)) || verify_start=$(($(date -u +%s) / 3600 % ${#verify_files[@]}))
  for pkg_file in "${verify_files[@]:verify_start}" "${verify_files[@]:0:verify_start}"; do
    pkg_name=$(pkg_get "$pkg_file" .name)
    prepared="${WORK_DIR}/prepared/${pkg_name}"
    if [[ -L "${WORK_DIR}/prepared" || ! -d "$prepared" ]]; then
      continue
    fi

    # The version and the asset value come from the check run, as for
    # --publish, so the prepared files cannot pick what verify downloads
    found="${CHECKED[$pkg_name]:-}"
    version=""
    case "$found" in
      "new_version: "* | "available_downgrade: "* | "new_build: "*) version="${found#*: }" ;;
      "arch_back: "*) version=$(arch_status_version "${found#arch_back: }") || version="" ;;
    esac
    asset_regex=$(pkg_get "$pkg_file" '.upstream.asset_regex // ""')
    asset=""
    [[ -z "$asset_regex" ]] || asset=$(awk -F'\t' -v p="$pkg_name" '$1 == p { v = $2 } END { print v }' <<<"${CHECKED[_assets]:-}")
    arch_record=$(awk -F'\t' -v p="$pkg_name" '$1 == p { l = $0 } END { print l }' <<<"${CHECKED[_arches]:-}")
    arch_out=""
    verify_rc=0
    if ((SECONDS >= VERIFY_BUDGET)); then
      verify_rc=1
      verify_err="verify ran out of its $((VERIFY_BUDGET / 60)) minutes in this run"
    elif ! validate_pkgver "$version" 2>/dev/null; then
      verify_rc=1
      verify_err="no new version from the check run"
    elif [[ -n "$asset_regex" ]] && ! validate_asset_value "$asset" 2>/dev/null; then
      verify_rc=1
      verify_err="no asset value from the check run"
    elif [[ -n "$arch_record" ]] && ! arch_out=$(arch_record_out "$arch_record" "$version"); then
      verify_rc=1
      verify_err="invalid arch record from the check run"
    else
      err_file=$(mktemp)
      bounded "$UPDATE_TIMEOUT" "${AURTOMATOR_DIR}/scripts/verify-pkg.sh" "$pkg_name" "$version" "$prepared" \
        ${asset:+--asset} ${asset:+"$asset"} ${arch_record:+--arch-out} ${arch_record:+"$arch_out"} 2>"$err_file" || verify_rc=$?
      verify_err=$(script_error "$verify_rc" "$err_file" "$UPDATE_TIMEOUT")
      rm -f "$err_file"
    fi
    [[ -z "$verify_err" ]] || printf '%s\n' "$verify_err" >&2

    case "$verify_rc" in
      0) ;;
      *)
        log_err "Failed to verify $pkg_name"
        rm -rf "$prepared"
        mkdir -p "${WORK_DIR}/status"
        rm -f "${WORK_DIR}/status/${pkg_name}"
        echo "update_failed: ${verify_err}" >"${WORK_DIR}/status/${pkg_name}"
        ;;
    esac
  done
  exit 0
fi

rm -rf "$STATUS_DIR"
mkdir -p "$STATUS_DIR"

# A failed request for the latest release records nothing, so it closes no
# issue; --prepare and --publish carry the record of the check run
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

# Prints the update_failed status that prepare or verify wrote for package $1,
# or one of its own when there is none; it ignores any other status there
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

# Prints the version the check run found, as check-update.sh prints it; it prints
# a skipped, held or pending version too, and the checks below apply to it again
# Args: $1=package name
checked_version() {
  local status="${CHECKED[$1]:-}"
  case "$status" in
    "new_version: "* | "available_downgrade: "* | "new_build: "* | "downgrade_skipped: "* | "jump_skipped: "* | "held: "* | "pending: "*)
      if ! validate_pkgver "${status#*: }" 2>/dev/null; then
        echo "invalid status from the check run" >&2
        return 1
      fi
      echo "${status#*: }"
      ;;
    "arch_back: "*)
      if ! arch_status_version "${status#arch_back: }"; then
        echo "invalid status from the check run" >&2
        return 1
      fi
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

# Sets ASSET_VALUE from check-asset.sh, or from the check run in --prepare and
# --publish, and records it in _assets. A fast failure goes on the second pass.
# Args: $1=package file, $2=package name, $3=version, $4=pass, 1 or 2
# Returns: 1 after writing the status of a pending value or a failure
find_asset() {
  local rc=0 err_file err in_flight
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
    in_flight=$(request_done "$rc")
    err=$(script_error "$rc" "$err_file" "$CHECK_TIMEOUT" "$in_flight")
    rm -f "$err_file"
    if ((rc == 3)); then
      printf '%s\n' "$err" >&2
      echo "pending: $3" >"${STATUS_DIR}/$2"
      return 1
    fi
    if ((rc != 0)); then
      log_err "Failed to check $2: $err"
      echo "check_failed: ${err}" >"${STATUS_DIR}/$2"
      if (($4 == 1)) && second_pass "$rc" "$err"; then
        RECHECK+=("$1")
      fi
      return 1
    fi
  fi
  printf '%s\t%s\n' "$2" "$ASSET_VALUE" >>"${STATUS_DIR}/_assets"
}

# Print the line of package $1 in _arches of the check run
arch_record_line() {
  awk -F'\t' -v p="$1" '$1 == p { l = $0 } END { print l }' <<<"${CHECKED[_arches]:-}"
}

# --publish keeps the start of the wait of record line $2 for version $3 in
# arch_wait of package file $1, until publish-pkg.sh pushes the version
keep_arch_wait() {
  if [[ "$MODE" != publish || -z "$2" ]] || ! arch_record_out "$2" "$3" >/dev/null; then
    return 0
  fi
  [[ -z "${2##*$'\t'}" ]] || set_arch_wait "$1" "$3" "${2##*$'\t'}"
}

# Set ARCH_OUT to the arches out of an update of $2 (file $1) to version $3, from
# check-arch.sh or _arches of the check run; a wait or a failure sets the status
find_arches() {
  local rc=0 err_file err text first second line in_flight
  ARCH_OUT=""
  ARCH_RECORD=""
  if [[ "$MODE" == "prepare" || "$MODE" == "publish" ]]; then
    line=$(arch_record_line "$2")
    if [[ "${CHECKED[$2]:-}" == "pending: "* ]]; then
      printf '%s\n' "${CHECKED[$2]}" >"${STATUS_DIR}/$2"
      [[ -z "$line" ]] || printf '%s\n' "$line" >>"${STATUS_DIR}/_arches"
      return 1
    fi
    [[ -n "$line" ]] || return 0
    if ! first=$(arch_record_out "$line" "$3"); then
      echo "check_failed: invalid arch record from the check run" >"${STATUS_DIR}/$2"
      return 1
    fi
    ARCH_OUT=$first
    ARCH_RECORD=1
    printf '%s\n' "$line" >>"${STATUS_DIR}/_arches"
    keep_arch_wait "$1" "$line" "$3"
    return 0
  fi
  [[ "$MODE" == check ]] && missing_arch_allowed "$1" || return 0
  err_file=$(mktemp)
  text=$(bounded "$CHECK_TIMEOUT" "${AURTOMATOR_DIR}/scripts/check-arch.sh" "$2" "$3" \
    ${ASSET_VALUE:+--asset} ${ASSET_VALUE:+"$ASSET_VALUE"} 2>"$err_file") || rc=$?
  in_flight=$(request_done "$rc")
  err=$(script_error "$rc" "$err_file" "$CHECK_TIMEOUT" "$in_flight")
  rm -f "$err_file"
  first=${text%%$'\n'*}
  second=""
  [[ "$text" != *$'\n'* ]] || second=${text#*$'\n'}
  if ((rc == 3)) && valid_time "$text"; then
    printf '%s\n' "$err" >&2
    echo "pending: $3" >"${STATUS_DIR}/$2"
    printf '%s\t%s\t\t%s\n' "$2" "$3" "$text" >>"${STATUS_DIR}/_arches"
    return 1
  fi
  if ((rc == 0)) && arch_record_ok "$first" "$second"; then
    [[ -z "$err" ]] || printf '%s\n' "$err" >&2
    ARCH_OUT=$first
    # A line with no arch and no wait tells prepare to put back every arch of arch_out
    if [[ -n "$first$second" || -n "$(pkg_get "$1" '.arch_out // {} | keys | .[]')" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$first" "$second" >>"${STATUS_DIR}/_arches"
    fi
    return 0
  fi
  ((rc != 0 && rc != 3)) || err="check-arch.sh printed ${text@Q}"
  log_err "Failed to check $2: $err"
  echo "check_failed: ${err}" >"${STATUS_DIR}/$2"
  if (($4 == 1)) && second_pass "$rc" "$err"; then
    RECHECK+=("$1")
  fi
  return 1
}

# Checks one package, then updates, prepares or publishes it by the mode and
# writes its status. A strategy check that fails fast goes on the second pass.
# Args: $1=package file, $2=pass, 1 or 2
run_package() {
  local pkg_file="$1" pass="$2"
  local pkg_name found check_cmd err_file check_rc latest check_err current asset_regex arches_read=false in_flight
  local is_downgrade cmp alerts fired line held action note push_day available pushed cmd update_rc update_err
  pkg_name=$(pkg_get "$pkg_file" .name)
  # --prepare and --publish keep a wait for the cooldown from the check run
  if [[ "$MODE" == "prepare" || "$MODE" == "publish" ]] && [[ "${CHECKED[$pkg_name]:-}" == "cooldown: "* ]]; then
    if valid_date "${CHECKED[$pkg_name]#cooldown: }"; then
      printf '%s\n' "${CHECKED[$pkg_name]}" >"${STATUS_DIR}/${pkg_name}"
    else
      echo "check_failed: invalid status from the check run" >"${STATUS_DIR}/${pkg_name}"
    fi
    return
  fi
  # --publish keeps the status of the check run and publishes only what it found
  # outdated; only names from packages/ reach a path, never a name from WORK_DIR
  if [[ "$MODE" == "publish" ]]; then
    found="${CHECKED[$pkg_name]:-}"
    case "$found" in
      "new_version: "* | "available_downgrade: "* | "new_build: "* | "arch_back: "*)
        if ! checked_version "$pkg_name" >/dev/null 2>&1; then
          echo "check_failed: invalid status from the check run" >"${STATUS_DIR}/${pkg_name}"
          return
        fi
        if [[ -L "${WORK_DIR}/prepared" || ! -d "${WORK_DIR}/prepared/${pkg_name}" ]]; then
          # The check run left it for a later run, past the 256 jobs of a run
          if grep -qxF -e "$pkg_name" <<<"${CHECKED[_deferred]:-}"; then
            printf '%s\n' "$found" >"${STATUS_DIR}/${pkg_name}"
          else
            handed_failure "$pkg_name" >"${STATUS_DIR}/${pkg_name}"
          fi
          return
        fi
        ;;
      up_to_date | check_failed:*)
        printf '%s\n' "$found" >"${STATUS_DIR}/${pkg_name}"
        return
        ;;
      "downgrade_skipped: "* | "jump_skipped: "* | "held: "* | "pending: "*)
        if ! validate_pkgver "${found#*: }" 2>/dev/null; then
          echo "check_failed: invalid status from the check run" >"${STATUS_DIR}/${pkg_name}"
          return
        fi
        printf '%s\n' "$found" >"${STATUS_DIR}/${pkg_name}"
        # The issue of a held update lists the notes of its alerts
        [[ "$found" != "held: "* ]] || record_alerts "$pkg_name" "$(fired_alerts "$pkg_file" "$(pkg_get "$pkg_file" '.current // ""')" "${found#held: }" 2>/dev/null)"
        [[ "$found" != "pending: "* ]] || keep_arch_wait "$pkg_file" "$(arch_record_line "$pkg_name")" "${found#pending: }"
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

  err_file=$(mktemp)
  check_rc=0
  latest=$("${check_cmd[@]}" 2>"$err_file") || check_rc=$?
  in_flight=$(request_done "$check_rc")
  if ((check_rc != 0)); then
    check_err=$(script_error "$check_rc" "$err_file" "$CHECK_TIMEOUT" "$in_flight")
    rm -f "$err_file"
    log_err "Failed to check $pkg_name: $check_err"
    echo "check_failed: ${check_err}" >"${STATUS_DIR}/${pkg_name}"
    if ((pass == 1)) && [[ "${check_cmd[0]}" == bounded ]] && second_pass "$check_rc" "$check_err"; then
      RECHECK+=("$pkg_file")
    fi
    return
  fi
  rm -f "$err_file"

  # An up-to-date package with asset_regex gets a rebuild when the asset value of
  # its version is not current_asset; --prepare and --publish read it as a version
  current=$(pkg_get "$pkg_file" '.current // ""')
  asset_regex=$(pkg_get "$pkg_file" '.upstream.asset_regex // ""')
  ASSET_VALUE=""
  if [[ -z "$latest" && -n "$asset_regex" && "$MODE" != "prepare" && "$MODE" != "publish" ]]; then
    find_asset "$pkg_file" "$pkg_name" "$current" "$pass" || return 0
    [[ "$ASSET_VALUE" == "$(pkg_get "$pkg_file" '.current_asset // ""')" ]] || latest="$current"
  fi

  # An arch out whose archive answers again comes back at the version of the
  # AUR; --prepare and --publish take it from the status of the check run
  ARCH_BACK=""
  ARCH_OUT=""
  ARCH_RECORD=""
  if [[ -z "$latest" && "$MODE" == check && -n "$(pkg_get "$pkg_file" '.arch_out // {} | keys | .[]')" ]] &&
    missing_arch_allowed "$pkg_file"; then
    find_arches "$pkg_file" "$pkg_name" "$current" "$pass" || return 0
    arches_read=true
    ARCH_BACK=$(arches_back "$pkg_file" "$ARCH_OUT")
    [[ -z "$ARCH_BACK" ]] || latest="$current"
  elif [[ "$MODE" == "prepare" || "$MODE" == "publish" ]] && [[ "${CHECKED[$pkg_name]:-}" == "arch_back: "* ]]; then
    ARCH_BACK="${CHECKED[$pkg_name]#arch_back: }"
    ARCH_BACK="${ARCH_BACK#* }"
  fi

  if [[ -z "$latest" ]]; then
    echo "up_to_date" >"${STATUS_DIR}/${pkg_name}"
    return
  fi

  # vercmp prints -1, 0 or 1 and exits 0
  is_downgrade=false
  if [[ -n "$current" ]]; then
    cmp=$(vercmp "$current" "$latest")
    if [[ "$cmp" -gt 0 ]]; then
      is_downgrade=true
    fi
  fi

  # The latest release of a GitHub project can be a maintenance release of an
  # older line, so a lower version needs allow_downgrade
  if [[ "$is_downgrade" == "true" ]] &&
    [[ "$(pkg_get "$pkg_file" '.allow_downgrade // false')" != "true" ]]; then
    log_warn "$pkg_name: DOWNGRADE detected $current → $latest, skipped: allow_downgrade is not set"
    echo "downgrade_skipped: ${latest}" >"${STATUS_DIR}/${pkg_name}"
    return
  fi

  # A first number that grows by two digits or more can be another version scheme,
  # such as build tags beside release tags, so it needs allow_version_jump
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

  # cooldown_days holds every push back until that many days after the last one
  err_file=$(mktemp)
  check_rc=0
  push_day=$(cooldown_until "$pkg_file" 2>"$err_file") || check_rc=$?
  check_err=$(<"$err_file")
  rm -f "$err_file"
  if ((check_rc != 0)); then
    log_err "Failed to check $pkg_name: $check_err"
    echo "check_failed: ${check_err}" >"${STATUS_DIR}/${pkg_name}"
    return
  fi
  # An arch that comes back gives no new version, so it does not wait
  if [[ -n "$push_day" && "$TODAY" < "$push_day" && -z "$ARCH_BACK" ]]; then
    log_info "$pkg_name: ${current:-none} → $latest waits until $push_day"
    echo "cooldown: ${push_day}" >"${STATUS_DIR}/${pkg_name}"
    return
  fi

  # The asset value of a new version, once no skip or hold stops it
  if [[ -n "$asset_regex" && -z "$ASSET_VALUE" ]]; then
    find_asset "$pkg_file" "$pkg_name" "$latest" "$pass" || return 0
  fi
  if [[ "$arches_read" == false ]]; then
    find_arches "$pkg_file" "$pkg_name" "$latest" "$pass" || return 0
  fi

  if [[ -n "$ARCH_BACK" ]]; then
    available="arch_back: ${latest} ${ARCH_BACK}"
    pushed="arch_added: ${latest} ${ARCH_BACK}"
  elif [[ "$latest" == "$current" ]]; then
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
      cmd=("${AURTOMATOR_DIR}/scripts/update-pkg.sh" "$pkg_name" "$latest" ${ASSET_VALUE:+--asset} ${ASSET_VALUE:+"$ASSET_VALUE"}
        ${ARCH_RECORD:+--arch-out} ${ARCH_RECORD:+"$ARCH_OUT"} --prepare "${WORK_DIR}/prepared")
      ;;
    publish)
      log_info "Publishing $pkg_name $latest"
      cmd=("${AURTOMATOR_DIR}/scripts/publish-pkg.sh" "$pkg_name" "$latest" "${WORK_DIR}/prepared/${pkg_name}" ${ASSET_VALUE:+--asset} ${ASSET_VALUE:+"$ASSET_VALUE"}
        ${ARCH_RECORD:+--arch-out} ${ARCH_RECORD:+"$ARCH_OUT"} ${DRY_RUN:+"$DRY_RUN"})
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
for pkg_file in "${AURTOMATOR_DATA_DIR}"/packages/*.yml; do
  [[ -f "$pkg_file" ]] || continue
  run_package "$pkg_file" 1
done

# A check that failed fast runs again after a pause. After a timeout or on a
# silent host it does not, so a run without network stays within its time limit
if ((${#RECHECK[@]} > 0)); then
  log_info "Checking ${#RECHECK[@]} failed package(s) again in ${RECHECK_DELAY} s"
  sleep "$RECHECK_DELAY"
  for pkg_file in "${RECHECK[@]}"; do
    run_package "$pkg_file" 2
  done
fi

# The arches each package lacks after the run, for the issues of arches out
if [[ "$MODE" == "publish" ]]; then
  : >"${STATUS_DIR}/_without"
  for pkg_file in "${AURTOMATOR_DATA_DIR}"/packages/*.yml; do
    [[ -f "$pkg_file" ]] || continue
    arches_out=$(pkg_get "$pkg_file" '.arch_out // {} | keys | join(" ")')
    [[ -z "$arches_out" ]] || printf '%s\t%s\t%s\n' "$(pkg_get "$pkg_file" .name)" \
      "$(pkg_get "$pkg_file" '.current // ""')" "$arches_out" >>"${STATUS_DIR}/_without"
  done
fi

errors=0
for status_file in "$STATUS_DIR"/*; do
  [[ -f "$status_file" ]] || continue
  case "$(<"$status_file")" in
    check_failed:* | update_failed:*) ((errors++)) || true ;;
  esac
done

echo ""
log_info "Checked: $checked, Updated: $updated, Errors: $errors"

# Hand the statuses to the publish run
if [[ "$MODE" == "prepare" ]]; then
  mkdir -p "${WORK_DIR}/status"
  cp "${STATUS_DIR}"/* "${WORK_DIR}/status/"
fi
