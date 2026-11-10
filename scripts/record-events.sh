#!/usr/bin/env bash
#
# record-events.sh - Write the event journal with a row for each state
# change of a package in the run, see Statistics in docs/WORKFLOW.md

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq
require_cmd vercmp
export LC_ALL=C

readonly USAGE="Usage: record-events.sh --journal <file> --statuses <dir> --before <dir> --after <dir> --out <file>"

declare -A ARG=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --journal | --statuses | --before | --after | --out)
      if [[ -z "${2:-}" ]]; then
        log_err "$1 needs a value"
        exit 1
      fi
      ARG[${1#--}]="$2"
      shift 2
      ;;
    *)
      log_err "Unknown option: $1"
      exit 1
      ;;
  esac
done
for key in journal statuses before after out; do
  if [[ -z "${ARG[$key]:-}" ]]; then
    log_err "$USAGE"
    exit 1
  fi
done

TIME="${AURTOMATOR_STATS_TIME:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
RUN="${GITHUB_RUN_ID:-}"
if [[ ! "$TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  log_err "AURTOMATOR_STATS_TIME is not of the form YYYY-MM-DDTHH:MM:SSZ: ${TIME@Q}"
  exit 1
fi
if [[ ! "$RUN" =~ ^[0-9]*$ ]]; then
  log_err "GITHUB_RUN_ID is not a number: ${RUN@Q}"
  exit 1
fi
if [[ ! -d "${ARG[before]}" ]]; then
  log_err "--before is not a directory: ${ARG[before]}"
  exit 1
fi

# The current version in package YAML $1, empty when it has none or one
# outside the version alphabet
current_of() {
  local value
  [[ -f "$1" ]] || return 0
  value=$(pkg_get "$1" '.current // ""' 2>/dev/null) || return 0
  [[ "$value" =~ ^[A-Za-z0-9._+]{1,$PKGVER_MAX}$ ]] || return 0
  printf '%s\n' "$value"
}

# The last state of each package in the journal
declare -A EVENT=() VERSION=() CURRENT=()
creating=true
if [[ -e "${ARG[journal]}" ]]; then
  creating=false
  states=$(stats_last_states "${ARG[journal]}") || exit 1
  while IFS=, read -r name event version current; do
    [[ -n "$name" ]] || continue
    EVENT[$name]="$event" VERSION[$name]="$version" CURRENT[$name]="$current"
  done <<<"$states"
fi

declare -A YAML=()
for file in "${ARG[before]}"/*.yml; do
  [[ -f "$file" ]] || continue
  name="${file##*/}"
  name="${name%.yml}"
  [[ "$name" =~ ^[A-Za-z0-9@_+][A-Za-z0-9@._+-]*$ ]] || continue
  YAML[$name]="$file"
done

rows=""
count=0
# Args: $1=package, $2=event, $3=version, $4=previous version
add_row() {
  rows+="${TIME},$1,$2,$3,$4,${RUN}"$'\n'
  ((++count))
}

# The rows of package $1 in the run. A push is always written, a move to
# another class or to another version is, and nothing else
record_package() {
  local name="$1" before after mapped event version last class
  before=$(current_of "${YAML[$name]}")
  after="$before"
  [[ ! -f "${ARG[after]}/$name.yml" ]] || after=$(current_of "${ARG[after]}/$name.yml")
  if [[ "${EVENT[$name]:-removed}" == removed ]]; then
    event=added
    [[ "$creating" == false ]] || event=tracked
    add_row "$name" "$event" "$before" ""
    EVENT[$name]="$event" VERSION[$name]="$before" CURRENT[$name]="$before"
  fi

  [[ -f "${ARG[statuses]}/$name" ]] || return 0
  if ! mapped=$(stats_event "$(<"${ARG[statuses]}/$name")" "$after"); then
    log_warn "The status of $name maps to no journal event"
    return 0
  fi
  [[ -n "$mapped" ]] || return 0
  IFS=, read -r event version <<<"$mapped"
  last=$(stats_class "${EVENT[$name]}")
  class=$(stats_class "$event")
  case "$event" in
    updated | downgrade | rebuilt)
      add_row "$name" "$event" "$version" "$before"
      ;;
    up_to_date)
      if [[ -n "$after" && -n "${CURRENT[$name]}" && "$after" != "${CURRENT[$name]}" ]]; then
        event=updated
        (($(vercmp "$after" "${CURRENT[$name]}") >= 0)) || event=downgrade
        add_row "$name" "$event" "$after" "${CURRENT[$name]}"
      elif [[ "$last" != ok || (-n "$after" && -z "${CURRENT[$name]}") ]]; then
        add_row "$name" up_to_date "$after" ""
      fi
      ;;
    held | jump_skipped | downgrade_skipped | pending)
      [[ "$class" == "$last" && "$version" == "${VERSION[$name]}" ]] || add_row "$name" "$event" "$version" ""
      ;;
    *)
      [[ "$class" == "$last" ]] || add_row "$name" "$event" "$version" ""
      ;;
  esac
}

mapfile -t names < <(printf '%s\n' "${!YAML[@]}" "${!EVENT[@]}" | sort -u)
for name in "${names[@]}"; do
  [[ -n "$name" ]] || continue
  if [[ -n "${YAML[$name]:-}" ]]; then
    record_package "$name"
  elif [[ "${EVENT[$name]}" != removed ]]; then
    add_row "$name" removed "${CURRENT[$name]}" ""
  fi
done

trap 'rm -f -- "${ARG[out]}.tmp"' EXIT
{
  if [[ "$creating" == true ]]; then
    printf '%s\n' "$STATS_HEADER"
  else
    cat -- "${ARG[journal]}"
    [[ -z "$(tail -c 1 -- "${ARG[journal]}")" ]] || echo
  fi
  printf '%s' "$rows"
} >"${ARG[out]}.tmp"
mv -f -- "${ARG[out]}.tmp" "${ARG[out]}"
log_ok "Recorded $count event(s) in ${ARG[out]}"
