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
CHECK_TIMEOUT=$(env_seconds AURTOMATOR_CHECK_TIMEOUT 120) || exit 1
UPDATE_TIMEOUT=$(env_seconds AURTOMATOR_UPDATE_TIMEOUT 300) || exit 1

# Time budget of the verify loop, in seconds: no package starts after it,
# so the verify job ends within its 30 minutes
VERIFY_BUDGET=$(env_seconds AURTOMATOR_VERIFY_BUDGET 1200) || exit 1

# Time budget of the loop of a check run, in seconds: no check and no step of a check starts
# after it, so the check job ends within its 30 minutes
CHECK_BUDGET=$(env_seconds AURTOMATOR_CHECK_BUDGET 1200) || exit 1

# Time budget of the publish loop, in seconds: no publish starts after it,
# so the publish job ends within its 30 minutes
PUBLISH_BUDGET=$(env_seconds AURTOMATOR_PUBLISH_BUDGET 1200) || exit 1

# Pause, in seconds, before a package whose check failed is checked again
RECHECK_DELAY=$(env_seconds AURTOMATOR_RECHECK_DELAY 60) || exit 1

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

# Prints fired_alerts of package file $1 from version $2 to $3 under the check timeout, since
# bash matches each alert in one call that no check of the time reaches
bounded_alerts() {
  # shellcheck disable=SC2016
  bounded "$CHECK_TIMEOUT" bash -c 'source "$1/scripts/lib.sh" && fired_alerts "${@:2}"' _ "$AURTOMATOR_DIR" "$@"
}

# Errors keep their last bytes, since a server writes the stderr of git. With the line that
# counts the bytes cut, a status fits the 4000 characters that an issue shows.
ERROR_MAX=3900

# Prints the error of a per-package script: its stderr, or the budget it ran out
# of and the URL $4 of a request in flight. $1=exit code, $2=stderr file, $3=budget
script_error() {
  case "$1" in
    124 | 137) echo "${4:+$4: }timed out after $3 s" ;;
    *) last_bytes "$2" ;;
  esac
}

# Prints file $1 whole, or the count of the bytes cut and its last ERROR_MAX bytes
last_bytes() {
  local size text cut LC_ALL=C
  size=$(wc -c <"$1")
  if ((size <= ERROR_MAX)); then
    cat -- "$1"
    return
  fi
  text=$(tail -c "$ERROR_MAX" -- "$1")
  cut=$((size - ERROR_MAX))
  # The cut can fall inside a character of UTF-8
  while [[ "$text" == [$'\x80'-$'\xbf']* ]]; do
    text=${text:1}
    cut=$((cut + 1))
  done
  printf '[first %s bytes cut]\n%s\n' "$cut" "$text"
}

# Prints status $1 with a space for each tab and control character but newlines, since
# the records of a run split their lines at tabs
status_text() {
  printf '%s\n' "$1" | shown_text
}

# Prints stdin with a space for each tab and control character but newlines: the errors and
# warnings of a check hold text of upstream and the AUR, which a terminal would act on
shown_text() {
  LC_ALL=C tr '\001-\011\013-\037\177' ' '
}

# Clears the requests of a check that exited with $1 and prints the URL of the one that failed. After a
# timeout that is the request in flight, and its host turns silent when a HEAD request of 10 s gets no status.
request_done() {
  local url="" check rc=0 code
  host_memory || return 0
  if [[ "$1" == 124 || "$1" == 137 ]] && { read -r url && read -r check; } <"$AURTOMATOR_HOSTS_DIR/request"; then
    code=$(curl --globoff -sI -o /dev/null --max-time 10 --proto '=https' -A "$USER_AGENT" -w '%{http_code}' "$check" 2>/dev/null) || rc=$?
    if ((rc == 28)) && [[ "$code" == 000 ]]; then
      remember_host "$url"
    fi
  elif [[ "$1" != 0 ]]; then
    read -r url <"$AURTOMATOR_HOSTS_DIR/failed" || url=""
  fi
  : >"$AURTOMATOR_HOSTS_DIR/request"
  : >"$AURTOMATOR_HOSTS_DIR/failed"
  [[ -z "$url" ]] || printf '%s\n' "$url"
}

# Succeeds when a check that failed with exit code $1 gets a second pass: none
# after a timeout, none when the host of its failed request $2 is silent
second_pass() {
  local host
  (($1 != 124 && $1 != 137)) || return 1
  host_memory && host=$(url_host "$2") || return 0
  ! grep -qxF -e "$host" "$AURTOMATOR_HOSTS_DIR/silent"
}

# Notes for _hosts the host of URL $2, the failed request of package $1, or no host
note_failed_host() {
  local host
  if host=$(url_host "$2"); then
    FAILED_HOSTS[$1]=$host
  else
    unset 'FAILED_HOSTS[$1]'
  fi
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
  : >"$AURTOMATOR_HOSTS_DIR/failed"
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

# Failed verifies, exit code 3 of a moved AUR repo included, take the update
# out with update_failed. Only package names from packages/ reach a path.
if [[ "$MODE" == "verify" ]]; then
  # Slow sources early in the list would take the budget of the same packages in every run, so each
  # run of the workflow starts the loop one package later, and runs by hand one package each hour
  verify_files=()
  for pkg_file in "${AURTOMATOR_DATA_DIR}"/packages/*.yml; do
    if [[ -f "$pkg_file" ]]; then
      verify_files+=("$pkg_file")
    fi
  done
  verify_start=0
  if ((${#verify_files[@]} > 0)) && (LC_ALL=C && [[ "${GITHUB_RUN_NUMBER:-}" =~ ^(0|[1-9][0-9]{0,8})$ ]]); then
    verify_start=$((GITHUB_RUN_NUMBER % ${#verify_files[@]}))
  elif ((${#verify_files[@]} > 0)); then
    verify_start=$(($(date -u +%s) / 3600 % ${#verify_files[@]}))
  fi
  # Packages on this list keep the status of the check run in publish, so only this loop writes it
  rm -f "${WORK_DIR}/status/_unverified"
  for pkg_file in "${verify_files[@]:verify_start}" "${verify_files[@]:0:verify_start}"; do
    pkg_name=$(package_name "$pkg_file") || continue
    prepared="${WORK_DIR}/prepared/${pkg_name}"
    if [[ -L "${WORK_DIR}/prepared" || ! -d "$prepared" ]]; then
      continue
    fi
    if ((SECONDS >= VERIFY_BUDGET)); then
      log_warn "$pkg_name: verify ran out of its $((VERIFY_BUDGET / 60)) minutes in this run"
      rm -rf "$prepared"
      mkdir -p "${WORK_DIR}/status"
      printf '%s\n' "$pkg_name" >>"${WORK_DIR}/status/_unverified"
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
    [[ -z "$asset_regex" ]] || asset=$(awk -F'\t' -v p="$pkg_name" '$1 "" == p "" { v = $2 } END { print v }' <<<"${CHECKED[_assets]:-}")
    arch_record=$(awk -F'\t' -v p="$pkg_name" '$1 "" == p "" { l = $0 } END { print l }' <<<"${CHECKED[_arches]:-}")
    arch_out=""
    verify_rc=0
    if ! validate_pkgver "$version" 2>/dev/null; then
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
        status_text "update_failed: ${verify_err}" >"${WORK_DIR}/status/${pkg_name}"
        ;;
    esac
  done
  exit 0
fi

rm -rf "$STATUS_DIR"
mkdir -p "$STATUS_DIR"

# Failed requests for the latest release record nothing, so they close no
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
    # PKGBUILD code of prepare can write this file
    if [[ "$(head -c 14 -- "$file")" == update_failed: ]]; then
      handed=$(last_bytes "$file")
      [[ "$handed" == update_failed:* ]] || handed="update_failed: $handed"
      status_text "$handed"
      return
    fi
  fi
  echo "update_failed: prepare and verify handed over no update"
}

# Succeeds when verify ran out of its time before package $1, as status/_unverified of the
# handoff lists, which the jobs take from verify alone
unverified() {
  local file="${WORK_DIR}/status/_unverified"
  [[ -d "${WORK_DIR}/status" && ! -L "${WORK_DIR}/status" && -f "$file" && ! -L "$file" ]] &&
    grep -qxF -e "$1" -- "$file"
}

updated=0
dry_runs=0
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
# --publish, and records it in _assets. Fast failures go on the second pass.
# Args: $1=package file, $2=package name, $3=version, $4=pass, 1 or 2
# Returns: 1 after writing the status of a pending value or a failure
find_asset() {
  local rc=0 err_file err in_flight
  if [[ "$MODE" == "prepare" || "$MODE" == "publish" ]]; then
    if [[ "${CHECKED[$2]:-}" == "pending: "* ]]; then
      printf '%s\n' "${CHECKED[$2]}" >"${STATUS_DIR}/$2"
      return 1
    fi
    ASSET_VALUE=$(awk -F'\t' -v p="$2" '$1 "" == p "" { v = $2 } END { print v }' <<<"${CHECKED[_assets]:-}")
    if ! validate_asset_value "$ASSET_VALUE" 2>/dev/null; then
      echo "check_failed: no asset value from the check run" >"${STATUS_DIR}/$2"
      return 1
    fi
  else
    step_time_left "$2" || return 1
    err_file=$(mktemp)
    ASSET_VALUE=$(bounded "$CHECK_TIMEOUT" "${AURTOMATOR_DIR}/scripts/check-asset.sh" "$2" "$3" 2>"$err_file") || rc=$?
    in_flight=$(request_done "$rc")
    err=$(script_error "$rc" "$err_file" "$CHECK_TIMEOUT" "$in_flight")
    rm -f "$err_file"
    note_failed_host "$2" "$in_flight"
    if ((rc == 3)); then
      status_text "$err" >&2
      echo "pending: $3" >"${STATUS_DIR}/$2"
      return 1
    fi
    if ((rc != 0)); then
      log_err "Failed to check $2: $(status_text "$err")"
      status_text "check_failed: ${err}" >"${STATUS_DIR}/$2"
      if (($4 == 1)) && second_pass "$rc" "$in_flight"; then
        RECHECK+=("$1")
      fi
      return 1
    fi
  fi
  printf '%s\t%s\n' "$2" "$ASSET_VALUE" >>"${STATUS_DIR}/_assets"
}

# Print the line of package $1 in _arches of the check run. awk compares two fields that look
# like numbers as numbers, so the comparisons of names add an empty string.
arch_record_line() {
  awk -F'\t' -v p="$1" '$1 "" == p "" { l = $0 } END { print l }' <<<"${CHECKED[_arches]:-}"
}

# --publish keeps the start of the wait of record line $2 for version $3 in
# arch_wait of package file $1, until publish-pkg.sh pushes the version
keep_arch_wait() {
  local record=$'^[^\t]*\t[^\t]*\t([^\t]*)\t([^\t]*)(\t([0-9a-f]{40}))?$'
  if [[ "$MODE" != publish || -z "$2" ]] || ! arch_record_out "$2" "$3" >/dev/null || [[ ! "$2" =~ $record ]]; then
    return 0
  fi
  # Wait lines add the arches they wait for and the AUR commit that builds them
  [[ -z "${BASH_REMATCH[2]}" ]] ||
    set_arch_wait "$1" "$3" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[4]:+${BASH_REMATCH[1]}}"
}

# Set ARCH_OUT to the arches out of an update of $2 (file $1) to version $3, from
# check-arch.sh or _arches of the check run; a wait or a failure sets the status
find_arches() {
  local rc=0 err_file err text first second line in_flight waited commit wait_re=$'^([^\n]+)\n([0-9a-f]{40})$'
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
  step_time_left "$2" || return 1
  err_file=$(mktemp)
  text=$(bounded "$CHECK_TIMEOUT" "${AURTOMATOR_DIR}/scripts/check-arch.sh" "$2" "$3" \
    ${ASSET_VALUE:+--asset} ${ASSET_VALUE:+"$ASSET_VALUE"} 2>"$err_file") || rc=$?
  in_flight=$(request_done "$rc")
  err=$(script_error "$rc" "$err_file" "$CHECK_TIMEOUT" "$in_flight")
  rm -f "$err_file"
  note_failed_host "$2" "$in_flight"
  first=${text%%$'\n'*}
  second=""
  [[ "$text" != *$'\n'* ]] || second=${text#*$'\n'}
  # Waits name their start, the arches they wait for and the AUR commit that builds them
  if ((rc == 3)) && [[ "$second" =~ $wait_re ]] && waited=${BASH_REMATCH[1]} commit=${BASH_REMATCH[2]} &&
    valid_time "$first" && arch_list_ok "$waited"; then
    status_text "$err" >&2
    echo "pending: $3" >"${STATUS_DIR}/$2"
    printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$waited" "$first" "$commit" >>"${STATUS_DIR}/_arches"
    return 1
  fi
  if ((rc == 0)) && arch_record_ok "$first" "$second"; then
    [[ -z "$err" ]] || status_text "$err" >&2
    ARCH_OUT=$first
    # Lines with no arch and no wait tell prepare to put back every arch of arch_out
    if [[ -n "$first$second" || -n "$(pkg_get "$1" '.arch_out // {} | keys | .[]')" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$first" "$second" >>"${STATUS_DIR}/_arches"
    fi
    return 0
  fi
  ((rc != 0 && rc != 3)) || err="check-arch.sh printed ${text@Q}"
  log_err "Failed to check $2: $(status_text "$err")"
  status_text "check_failed: ${err}" >"${STATUS_DIR}/$2"
  if (($4 == 1)) && second_pass "$rc" "$in_flight"; then
    RECHECK+=("$1")
  fi
  return 1
}

# Checks one package, then updates, prepares or publishes it by the mode and
# writes its status. Strategy checks that fail fast go on the second pass.
# Args: $1=package file, $2=pass, 1 or 2
run_package() {
  local pkg_file="$1" pass="$2"
  local pkg_name found check_cmd err_file check_rc latest check_err current asset_regex arches_read=false in_flight
  local is_downgrade cmp alerts fired line held action note push_day available pushed cmd update_rc update_err
  local stem yaml_name host
  # The write-back of current takes regular files alone, so a linked YAML keeps its old current
  if [[ -L "$pkg_file" ]]; then
    stem="${pkg_file##*/}"
    stem="${stem%.yml}"
    log_err "packages/${stem@Q}.yml is a link, and the runs read regular files alone"
    if [[ "$MODE" == check || "$MODE" == publish ]] && (LC_ALL=C && [[ "$stem" =~ ^[a-z0-9][a-z0-9.+_-]*$ ]]); then
      echo "check_failed: packages/${stem}.yml is a link, and the runs read regular files alone" >"${STATUS_DIR}/${stem}"
    fi
    return 0
  fi
  if ! pkg_name=$(package_name "$pkg_file"); then
    # Its status keeps the issues of the file name open, since its YAML is still there
    stem="${pkg_file##*/}"
    stem="${stem%.yml}"
    if [[ "$MODE" == check || "$MODE" == publish ]] && (LC_ALL=C && [[ "$stem" =~ ^[a-z0-9][a-z0-9.+_-]*$ ]]); then
      yaml_name=$(pkg_get "$pkg_file" .name 2>/dev/null) || yaml_name=""
      echo "check_failed: packages/${stem}.yml: name ${yaml_name@Q} must equal the file name" >"${STATUS_DIR}/${stem}"
    fi
    return 0
  fi
  unset 'FAILED_HOSTS[$pkg_name]'
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
          # The check run left it for a later run, past the 256 jobs of a run, or verify past its budget
          if grep -qxF -e "$pkg_name" <<<"${CHECKED[_deferred]:-}" || unverified "$pkg_name"; then
            printf '%s\n' "$found" >"${STATUS_DIR}/${pkg_name}"
          else
            handed_failure "$pkg_name" >"${STATUS_DIR}/${pkg_name}"
          fi
          return
        fi
        # Later runs find the version again, as for a package the check run deferred
        if ((SECONDS >= PUBLISH_BUDGET)); then
          log_warn "$pkg_name: publish ran out of its $((PUBLISH_BUDGET / 60)) minutes in this run"
          printf '%s\n' "$found" >"${STATUS_DIR}/${pkg_name}"
          return
        fi
        ;;
      up_to_date | check_failed:* | unchecked:*)
        printf '%s\n' "$found" >"${STATUS_DIR}/${pkg_name}"
        host=$(recorded_host "$pkg_name" <<<"${CHECKED[_hosts]:-}")
        if [[ "$found" == check_failed:* && -n "$host" ]]; then
          FAILED_HOSTS[$pkg_name]=$host
        fi
        return
        ;;
      "downgrade_skipped: "* | "jump_skipped: "* | "held: "* | "pending: "*)
        if ! validate_pkgver "${found#*: }" 2>/dev/null; then
          echo "check_failed: invalid status from the check run" >"${STATUS_DIR}/${pkg_name}"
          return
        fi
        printf '%s\n' "$found" >"${STATUS_DIR}/${pkg_name}"
        # The issue of a held update lists the notes of its alerts
        [[ "$found" != "held: "* ]] || record_alerts "$pkg_name" "$(bounded_alerts "$pkg_file" "$(pkg_get "$pkg_file" '.current // ""')" "${found#held: }" 2>/dev/null)"
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
    log_err "Failed to check $pkg_name: $(status_text "$check_err")"
    status_text "check_failed: ${check_err}" >"${STATUS_DIR}/${pkg_name}"
    note_failed_host "$pkg_name" "$in_flight"
    if ((pass == 1)) && [[ "${check_cmd[0]}" == bounded ]] && second_pass "$check_rc" "$in_flight"; then
      RECHECK+=("$pkg_file")
    fi
    return
  fi
  # CI shows the output of this script alone, so the warnings of a check that passed go there
  shown_text <"$err_file" >&2
  rm -f "$err_file"

  # Up-to-date packages with asset_regex get a rebuild when the asset value of
  # their version is not current_asset; --prepare and --publish read it as a version
  current=$(pkg_get "$pkg_file" '.current // ""')
  asset_regex=$(pkg_get "$pkg_file" '.upstream.asset_regex // ""')
  ASSET_VALUE=""
  if [[ -z "$latest" && -n "$asset_regex" && "$MODE" != "prepare" && "$MODE" != "publish" ]]; then
    find_asset "$pkg_file" "$pkg_name" "$current" "$pass" || return 0
    [[ "$ASSET_VALUE" == "$(pkg_get "$pkg_file" '.current_asset // ""')" ]] || latest="$current"
  fi

  # Arches out whose archive answers again come back at the AUR version;
  # --prepare and --publish take them from the status of the check run
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

  # First numbers that grow by two digits or more can be another version scheme,
  # such as build tags beside release tags, so they need allow_version_jump
  if version_jump "$current" "$latest" &&
    [[ "$(pkg_get "$pkg_file" '.allow_version_jump // false')" != "true" ]]; then
    log_warn "$pkg_name: version jump $current → $latest, skipped: allow_version_jump is not set"
    echo "jump_skipped: ${latest}" >"${STATUS_DIR}/${pkg_name}"
    return
  fi

  # Alerts name upstream steps that need a hand edit. Those with
  # hold: true keep the update back until the maintainer publishes it.
  step_time_left "$pkg_name" || return 0
  err_file=$(mktemp)
  check_rc=0
  alerts=$(bounded_alerts "$pkg_file" "$current" "$latest" 2>"$err_file") || check_rc=$?
  check_err=$(script_error "$check_rc" "$err_file" "$CHECK_TIMEOUT" alerts)
  rm -f "$err_file"
  if ((check_rc != 0)); then
    log_err "Failed to check $pkg_name: $(status_text "$check_err")"
    status_text "check_failed: ${check_err}" >"${STATUS_DIR}/${pkg_name}"
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
    log_err "Failed to check $pkg_name: $(status_text "$check_err")"
    status_text "check_failed: ${check_err}" >"${STATUS_DIR}/${pkg_name}"
    return
  fi
  # Arches that come back give no new version, so they do not wait
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
  shown_text <"$err_file" >&2
  rm -f "$err_file"

  case "$MODE:$update_rc" in
    prepare:0 | prepare:2)
      # Pushed or synced later by --publish
      echo "$available" >"${STATUS_DIR}/${pkg_name}"
      ;;
    *:0)
      if [[ -n "$DRY_RUN" ]]; then
        # Dry runs push nothing, so the version stays one to push
        echo "$available" >"${STATUS_DIR}/${pkg_name}"
        ((dry_runs++)) || true
      else
        echo "$pushed" >"${STATUS_DIR}/${pkg_name}"
        ((updated++)) || true
      fi
      ;;
    *:2)
      # AUR already at this version, YAML synced by update-pkg.sh or publish-pkg.sh
      echo "up_to_date" >"${STATUS_DIR}/${pkg_name}"
      ;;
    publish:4)
      # Exit code 4: an earlier attempt of the run pushed it, and notices open on the status of a push
      echo "$pushed" >"${STATUS_DIR}/${pkg_name}"
      ((updated++)) || true
      ;;
    # Exit code 3 of publish, an AUR repo that moved after the prepare, takes the update out
    # as in verify, and the next run prepares again
    *)
      log_err "Failed to update $pkg_name to $latest"
      status_text "update_failed: ${update_err}" >"${STATUS_DIR}/${pkg_name}"
      ;;
  esac
}

# Succeeds while a check run has time left for a check
check_time_left() {
  [[ "$MODE" != check ]] || (($(date -u +%s) < CHECK_END))
}

# Gives status unchecked to package $1, which the check run did not reach or did not finish.
# Such packages keep their issues and their journal row.
mark_unchecked() {
  log_warn "$1: the check ran out of its $((CHECK_BUDGET / 60)) minutes in this run"
  echo "unchecked: the check ran out of its $((CHECK_BUDGET / 60)) minutes in this run" >"${STATUS_DIR}/$1"
}

# Succeeds while a check run has time left for the next step of the check of package $1, and
# gives the package status unchecked otherwise
step_time_left() {
  check_time_left && return 0
  mark_unchecked "$1"
  return 1
}

check_files=()
# Links count wherever they lead, since the jobs hand builder each one as a link to itself
for pkg_file in "${AURTOMATOR_DATA_DIR}"/packages/*.yml; do
  [[ ! -f "$pkg_file" && ! -L "$pkg_file" ]] || check_files+=("$pkg_file")
done
# Slow hosts early in the list would take the budget of the same packages in
# every run, so each run of the workflow starts the loop one package later
check_start=0
if [[ "$MODE" == check && ${#check_files[@]} -gt 0 ]] && (LC_ALL=C && [[ "${GITHUB_RUN_NUMBER:-}" =~ ^(0|[1-9][0-9]{0,8})$ ]]); then
  check_start=$((GITHUB_RUN_NUMBER % ${#check_files[@]}))
fi
CHECK_END=$(($(date -u +%s) + CHECK_BUDGET))

RECHECK=()
declare -A FAILED_HOSTS=()
# Publish keeps the failed checks of the check run, so their hosts go to _hosts before the loop,
# for the host issues of a publish that its job stops
if [[ "$MODE" == publish ]]; then
  for pkg_file in "${check_files[@]}"; do
    [[ ! -L "$pkg_file" ]] || continue
    pkg_name=$(package_name "$pkg_file" 2>/dev/null) || continue
    [[ "${CHECKED[$pkg_name]:-}" == check_failed:* ]] || continue
    host=$(recorded_host "$pkg_name" <<<"${CHECKED[_hosts]:-}")
    [[ -z "$host" ]] || printf '%s\t%s\n' "$pkg_name" "$host"
  done | LC_ALL=C sort >"${STATUS_DIR}/_hosts"
  [[ -s "${STATUS_DIR}/_hosts" ]] || rm -f "${STATUS_DIR}/_hosts"
fi
for pkg_file in "${check_files[@]:check_start}" "${check_files[@]:0:check_start}"; do
  if check_time_left; then
    run_package "$pkg_file" 1
  elif pkg_name=$(package_name "$pkg_file"); then
    mark_unchecked "$pkg_name"
  fi
done

# Checks that failed fast run again after a pause. After a timeout or on a
# silent host they do not, so runs without network stay within their time limit
if ((${#RECHECK[@]} > 0)) && check_time_left; then
  log_info "Checking ${#RECHECK[@]} failed package(s) again in ${RECHECK_DELAY} s"
  sleep "$RECHECK_DELAY"
  for pkg_file in "${RECHECK[@]}"; do
    check_time_left || break
    run_package "$pkg_file" 2
  done
fi

# The issues step closes the issues of a name this list lacks, since a package
# without a YAML gets no check that would close them; a YAML of another name stays
for pkg_file in "${check_files[@]}"; do
  stem="${pkg_file##*/}"
  stem="${stem%.yml}"
  if (LC_ALL=C && [[ "$stem" =~ ^[a-z0-9][a-z0-9.+_-]*$ ]]); then
    printf '%s\n' "$stem"
  fi
done >"${STATUS_DIR}/_packages"

# The host of the request each failed check failed on, for the host issues
hosts=$(
  for pkg_name in "${!FAILED_HOSTS[@]}"; do
    if [[ -f "${STATUS_DIR}/${pkg_name}" && "$(<"${STATUS_DIR}/${pkg_name}")" == check_failed:* ]]; then
      printf '%s\t%s\n' "$pkg_name" "${FAILED_HOSTS[$pkg_name]}"
    fi
  done | LC_ALL=C sort
)
[[ -z "$hosts" ]] || printf '%s\n' "$hosts" >"${STATUS_DIR}/_hosts"

# The arches each package lacks after the run, for the issues of arches out. Files the check
# fails name no package, and an arch_out that is no map counts as none, as in the check.
if [[ "$MODE" == "publish" ]]; then
  : >"${STATUS_DIR}/_without"
  for pkg_file in "${check_files[@]}"; do
    [[ ! -L "$pkg_file" ]] || continue
    pkg_name=$(package_name "$pkg_file" 2>/dev/null) || continue
    arches_out=$(pkg_get "$pkg_file" '.arch_out // {} | keys | join(" ")' 2>/dev/null) || continue
    [[ -z "$arches_out" ]] || printf '%s\t%s\t%s\n' "$pkg_name" \
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
summary="Checked: $checked, Updated: $updated"
[[ -z "$DRY_RUN" ]] || summary+=", Dry runs: $dry_runs"
log_info "$summary, Errors: $errors"

# Hand the statuses to the publish run
if [[ "$MODE" == "prepare" ]]; then
  mkdir -p "${WORK_DIR}/status"
  cp "${STATUS_DIR}"/* "${WORK_DIR}/status/"
fi
