#!/usr/bin/env bash
#
# update-readme.sh - Generate badges and package status table in README.md
#
# Looks for two marker pairs in README.md:
#   <!-- BADGES:START --> / <!-- BADGES:END -->     - header badges
#   <!-- PACKAGES:START --> / <!-- PACKAGES:END --> - package status table
#
# Badges auto-detect the repo from git origin and adjust for forks.
# For public repos, Codecov badge uses tokenless URL.
# For private repos, Codecov badge links to the upstream aurtomator project.
#
# Reads per-package status from .status/ directory (written by check-all.sh).
#
# Usage: ./scripts/update-readme.sh

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq

readonly README="${AURTOMATOR_DIR}/README.md"
readonly STATUS_DIR="${AURTOMATOR_DIR}/.status"

if [[ ! -f "$README" ]]; then
  log_err "README.md not found"
  exit 1
fi

# Detect repo from git origin
repo_url=$(git -C "$AURTOMATOR_DIR" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||; s|\.git$||' || true)

# =============================================================================
# BADGES SECTION
# =============================================================================

readonly BADGES_START="<!-- BADGES:START -->"
readonly BADGES_END="<!-- BADGES:END -->"

if grep -q "$BADGES_START" "$README"; then
  badges=""

  if [[ -n "$repo_url" ]]; then
    # CI badge, always available
    badges+="[![Lint & Test](https://github.com/${repo_url}/actions/workflows/ci.yml/badge.svg)](https://github.com/${repo_url}/actions/workflows/ci.yml)"

    # Codecov badge: ask the GitHub API (unauthenticated) whether the repo is
    # public. yq prints true only for "private": false, and false for a
    # private repo, an error answer or no answer.
    is_public=$(curl -sfL --max-time 5 "https://api.github.com/repos/${repo_url}" 2>/dev/null |
      yq -r '.private == false' 2>/dev/null || true)

    if [[ "$is_public" == "true" ]]; then
      # Public repo: tokenless Codecov badge for this repo
      badges+=" [![codecov](https://codecov.io/github/${repo_url}/graph/badge.svg)](https://codecov.io/github/${repo_url})"
    else
      # Private repo or API failed: link to upstream aurtomator Codecov
      badges+=" [![codecov](https://codecov.io/github/${AURTOMATOR_UPSTREAM}/graph/badge.svg)](https://codecov.io/github/${AURTOMATOR_UPSTREAM})"
    fi
  fi

  # Static badges
  badges+=" [![Bash](https://img.shields.io/badge/bash-5%2B-green)](https://www.gnu.org/software/bash/)"
  badges+=" [![AUR](https://img.shields.io/badge/AUR-automation-orange)](https://aur.archlinux.org/)"
  badges+=" [![License](https://img.shields.io/badge/license-BSD--3--Clause-blue)](LICENSE)"

  # Replace between badge markers
  {
    sed -n "1,/${BADGES_START}/p" "$README"
    echo "$badges"
    sed -n "/${BADGES_END}/,\$p" "$README"
  } >"${README}.tmp"
  mv "${README}.tmp" "$README"
  log_ok "Badges updated (repo: ${repo_url:-unknown})"
fi

# =============================================================================
# PACKAGES SECTION
# =============================================================================

readonly PKG_START="<!-- PACKAGES:START -->"
readonly PKG_END="<!-- PACKAGES:END -->"

if ! grep -q "$PKG_START" "$README"; then
  log_err "No $PKG_START marker found in README.md"
  exit 1
fi

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
for pkg_file in "${AURTOMATOR_DIR}"/packages/*.yml; do
  [[ -f "$pkg_file" ]] || continue

  name=$(pkg_get "$pkg_file" .name)
  current=$(pkg_get "$pkg_file" '.current // "—"')
  strategy=$(pkg_get "$pkg_file" .strategy)
  last_updated=$(pkg_get "$pkg_file" '.last_updated // "—"')

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
        status="🔄 updated to ${run_status#updated: }"
        ((pkg_ok++)) || true
        ;;
      new_version:*)
        status="🆕 ${run_status#new_version: } available"
        ((pkg_ok++)) || true
        ;;
      downgrade:*)
        status="⬇️ downgraded to ${run_status#downgrade: }"
        ((pkg_ok++)) || true
        ;;
      available_downgrade:*)
        status="⬇️ ${run_status#available_downgrade: } available (downgrade)"
        ((pkg_ok++)) || true
        ;;
      downgrade_skipped:*)
        status="⬇️ ${run_status#downgrade_skipped: } skipped (downgrade)"
        ((pkg_ok++)) || true
        ;;
      jump_skipped:*)
        status="⬆️ ${run_status#jump_skipped: } skipped (version jump)"
        ((pkg_ok++)) || true
        ;;
      held:*)
        status="⏸️ ${run_status#held: } held"
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
  elif [[ "$current" == "—" || "$current" == "null" ]]; then
    status="🆕 new"
    current="—"
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
if [[ -n "$repo_url" ]]; then
  table+="![Check Updates](https://github.com/${repo_url}/actions/workflows/check-updates.yml/badge.svg)"
fi
if [[ -n "$pkg_badge" ]]; then
  table+=" ${pkg_badge}"
fi
table+="

${table_header}"

if [[ "$pkg_count" -eq 0 ]]; then
  table+=$(table_row "<em>No packages configured</em>" — — — —)
else
  table+="$table_rows"
fi
table+=$'\n</table>'

# The version of aurtomator, and the newer release the check run found. The
# release PR of aurtomator rewrites the version on the line that carries
# x-release-please-version, so the check run of the upstream repository
# finds nothing to commit to its protected main.
version=$(aurtomator_version)
if [[ -n "$version" ]]; then
  upstream=""
  [[ ! -f "${STATUS_DIR}/_upstream" ]] || upstream=$(<"${STATUS_DIR}/_upstream")
  table+=$'\n\n'"aurtomator ${version}"
  if [[ "$upstream" =~ ^newer:\ ([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    table+=" · [${BASH_REMATCH[1]} available](https://github.com/${AURTOMATOR_UPSTREAM}/releases/tag/v${BASH_REMATCH[1]})"
  fi
  table+=" <!-- x-release-please-version -->"
fi

# Replace between markers
{
  sed -n "1,/${PKG_START}/p" "$README"
  echo "$table"
  sed -n "/${PKG_END}/,\$p" "$README"
} >"${README}.tmp"

mv "${README}.tmp" "$README"
log_ok "README.md updated ($pkg_count packages)"
