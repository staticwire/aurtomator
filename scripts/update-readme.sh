#!/usr/bin/env bash
#
# update-readme.sh - Generate the badges and the package table of README.md
#
# Looks for two marker pairs in README.md:
#   <!-- BADGES:START --> / <!-- BADGES:END -->     - header badges
#   <!-- PACKAGES:START --> / <!-- PACKAGES:END --> - package table
#
# The badge block holds the badges of check-updates.yml and validate.yml,
# the two workflows a repository calls, and the badge of aurtomator. The
# workflow badges take the repo from the git origin. Without a GitHub origin
# the block holds the badge of aurtomator alone.
#
# The package block holds the packages badge, the table and the version
# line of aurtomator.
#
# Reads per-package status from .status/ directory (written by check-all.sh).
#
# Usage: ./scripts/update-readme.sh

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq

readonly README="${AURTOMATOR_DATA_DIR}/README.md"
readonly STATUS_DIR="${AURTOMATOR_DATA_DIR}/.status"

if [[ ! -f "$README" ]]; then
  log_err "README.md not found"
  exit 1
fi

readonly BADGES_START="<!-- BADGES:START -->"
readonly BADGES_END="<!-- BADGES:END -->"
readonly PKG_START="<!-- PACKAGES:START -->"
readonly PKG_END="<!-- PACKAGES:END -->"

# Each section is written up to its start marker and from its end marker,
# each a line of its own. A missing end marker would drop the rest of the
# README, and a second marker or an end marker above the start would copy
# the README into itself on every run. The badges are optional, and so is
# the table while there are no packages to show.
# Args: $1=start marker, $2=end marker
# Returns: 1 when the README does not hold each marker once, start first
check_markers() {
  local marker count
  for marker in "$1" "$2"; do
    count=$(grep -cxF -- "$marker" "$README" || true)
    if ((count == 0)); then
      log_err "No $marker marker found in README.md"
      return 1
    elif ((count > 1)); then
      log_err "README.md has the $marker line $count times, it needs it once"
      return 1
    fi
  done
  if (($(grep -nxF -- "$2" "$README" | cut -d: -f1) < $(grep -nxF -- "$1" "$README" | cut -d: -f1))); then
    log_err "README.md has $2 above $1"
    return 1
  fi
}

# The README of aurtomator itself has no table, and aurtomator has no packages
has_table=true
if ! compgen -G "${AURTOMATOR_DATA_DIR}/packages/*.yml" >/dev/null && ! grep -qxF -e "$PKG_START" -e "$PKG_END" "$README"; then
  has_table=false
else
  check_markers "$PKG_START" "$PKG_END" || exit 1
fi
has_badges=false
if grep -qxF -- "$BADGES_START" "$README"; then
  check_markers "$BADGES_START" "$BADGES_END" || exit 1
  has_badges=true
fi

# Only a GitHub origin names the repo, so the URL of another remote, or a
# local path, never reaches the README
repo_url=""
origin_url=$(git -C "$AURTOMATOR_DATA_DIR" remote get-url origin 2>/dev/null || true)
if [[ "$origin_url" =~ [/@]github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+) ]]; then
  repo_url="${BASH_REMATCH[1]%.git}"
fi

# =============================================================================
# BADGES SECTION
# =============================================================================

if [[ "$has_badges" == true ]]; then
  badges=""

  if [[ -n "$repo_url" ]]; then
    badges+="[![Check AUR Package Updates](https://github.com/${repo_url}/actions/workflows/check-updates.yml/badge.svg)](https://github.com/${repo_url}/actions/workflows/check-updates.yml) "
    badges+="[![Validate packages](https://github.com/${repo_url}/actions/workflows/validate.yml/badge.svg)](https://github.com/${repo_url}/actions/workflows/validate.yml) "
  fi

  # Names the project itself, so it does not follow AURTOMATOR_UPSTREAM
  badges+="[![maintained with aurtomator](https://img.shields.io/badge/maintained%20with-aurtomator-orange)](https://github.com/staticwire/aurtomator)"

  # Replace between badge markers
  {
    sed -n "0,/^${BADGES_START}\$/p" "$README"
    echo "$badges"
    sed -n "/^${BADGES_END}\$/,\$p" "$README"
  } >"${README}.tmp"
  mv "${README}.tmp" "$README"
  log_ok "Badges updated (repo: ${repo_url:-unknown})"
fi

if [[ "$has_table" == false ]]; then
  log_info "README.md has no package table and there are no packages to show"
  exit 0
fi

# =============================================================================
# PACKAGES SECTION
# =============================================================================

# The table is HTML, since a Markdown table cell takes no attributes. nowrap
# keeps Strategy, Updated and Status on one line, and the package name wraps.
table_row() {
  printf '\n<tr><td>%s</td><td>%s</td><td nowrap>%s</td><td nowrap>%s</td><td nowrap>%s</td></tr>' "$@"
}

# Badge and table header are assembled after the loop (need counts)
table_rows=""
table_header=$'<table>\n<tr><th>Package</th><th>Version</th><th>Strategy</th><th>Updated</th><th>Status</th></tr>'

pkg_count=0
pkg_ok=0
pkg_fail=0
for pkg_file in "${AURTOMATOR_DATA_DIR}"/packages/*.yml; do
  [[ -f "$pkg_file" ]] || continue

  name=$(pkg_get "$pkg_file" .name)
  current=$(pkg_get "$pkg_file" '.current // "-"')
  strategy=$(pkg_get "$pkg_file" .strategy)
  last_updated=$(pkg_get "$pkg_file" '.last_updated // "-"')

  # Determine status from .status/ dir or YAML
  status_file="${STATUS_DIR}/${name}"
  if [[ -f "$status_file" ]]; then
    run_status=$(cat "$status_file")
    case "$run_status" in
      up_to_date)
        status="✅ up to date"
        ((pkg_ok++)) || true
        ;;
      updated:*)
        status="📦 updated to ${run_status#updated: }"
        ((pkg_ok++)) || true
        ;;
      new_version:*)
        status="✨ ${run_status#new_version: } available"
        ((pkg_ok++)) || true
        ;;
      downgrade:*)
        status="🔻 downgraded to ${run_status#downgrade: }"
        ((pkg_ok++)) || true
        ;;
      available_downgrade:*)
        status="🔻 ${run_status#available_downgrade: } available (downgrade)"
        ((pkg_ok++)) || true
        ;;
      downgrade_skipped:*)
        status="🔻 ${run_status#downgrade_skipped: } skipped (downgrade)"
        ((pkg_ok++)) || true
        ;;
      jump_skipped:*)
        status="🔺 ${run_status#jump_skipped: } skipped (version jump)"
        ((pkg_ok++)) || true
        ;;
      held:*)
        status="✋ ${run_status#held: } held"
        ((pkg_ok++)) || true
        ;;
      new_build:*)
        status="🔨 ${run_status#new_build: } rebuild available"
        ((pkg_ok++)) || true
        ;;
      rebuilt:*)
        status="🔨 ${run_status#rebuilt: } rebuilt"
        ((pkg_ok++)) || true
        ;;
      pending:*)
        status="⏳ ${run_status#pending: } pending"
        ((pkg_ok++)) || true
        ;;
      check_failed:* | update_failed:*)
        status="❌ failed"
        ((pkg_fail++)) || true
        ;;
      *)
        status="✅ tracking"
        ((pkg_ok++)) || true
        ;;
    esac
  elif [[ "$current" == "-" || "$current" == "null" ]]; then
    status="✨ new"
    current="-"
    ((pkg_ok++)) || true
  else
    status="✅ tracking"
    ((pkg_ok++)) || true
  fi

  link="<a href=\"https://aur.archlinux.org/pkgbase/${name}\">${name}</a>"
  table_rows+=$(table_row "$link" "$current" "$strategy" "$last_updated" "$status")
  ((pkg_count++)) || true
done

# Build badge: green if all ok, red otherwise
if [[ "$pkg_count" -gt 0 ]]; then
  if [[ "$pkg_fail" -eq 0 ]]; then
    badge_color="brightgreen"
  else
    badge_color="red"
  fi
  badge_text="${pkg_ok}%2F${pkg_count}"
  pkg_badge="![packages](https://img.shields.io/badge/packages-${badge_text}-${badge_color})"
else
  pkg_badge=""
fi

# Assemble full table
table=""
if [[ -n "$pkg_badge" ]]; then
  table+="${pkg_badge}"$'\n\n'
fi
table+="$table_header"

if [[ "$pkg_count" -eq 0 ]]; then
  table+=$(table_row "<em>No packages configured</em>" - - - -)
else
  table+="$table_rows"
fi
table+=$'\n</table>'

# The version of aurtomator, and the newer release the check run found
version=$(aurtomator_version)
if [[ -n "$version" ]]; then
  upstream=""
  [[ ! -f "${STATUS_DIR}/_upstream" ]] || upstream=$(<"${STATUS_DIR}/_upstream")
  table+=$'\n\n'"aurtomator ${version}"
  if [[ "$upstream" =~ ^newer:\ ([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    table+=" ([${BASH_REMATCH[1]} available](https://github.com/${AURTOMATOR_UPSTREAM}/releases/tag/v${BASH_REMATCH[1]}))"
  fi
fi

# Replace between markers
{
  sed -n "0,/^${PKG_START}\$/p" "$README"
  echo "$table"
  sed -n "/^${PKG_END}\$/,\$p" "$README"
} >"${README}.tmp"

mv "${README}.tmp" "$README"
log_ok "README.md updated ($pkg_count packages)"
