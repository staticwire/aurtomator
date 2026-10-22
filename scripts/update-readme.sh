#!/usr/bin/env bash
#
# update-readme.sh - Generate the badges in README.md and the package status
# in STATUS.md
#
# Rewrites the header badges between <!-- BADGES:START --> and
# <!-- BADGES:END --> in README.md, and writes STATUS.md as a whole when at
# least one package is configured. The template has no STATUS.md, so a merge
# from the template never touches the file that changes with every status.
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
readonly STATUS_MD="${AURTOMATOR_DIR}/STATUS.md"
readonly STATUS_DIR="${AURTOMATOR_DIR}/.status"
readonly UPSTREAM_REPO="staticwire/aurtomator"

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

    # Codecov badge: ask the GitHub API (unauthenticated) whether the repo is public
    is_public=$(curl -sfL --max-time 5 "https://api.github.com/repos/${repo_url}" 2>/dev/null |
      yq -r 'select(.private == false) | "true"' 2>/dev/null || true)

    if [[ "$is_public" == "true" ]]; then
      # Public repo: tokenless Codecov badge for this repo
      badges+=" [![codecov](https://codecov.io/github/${repo_url}/graph/badge.svg)](https://codecov.io/github/${repo_url})"
    else
      # Private repo or API failed: link to upstream aurtomator Codecov
      badges+=" [![codecov](https://codecov.io/github/${UPSTREAM_REPO}/graph/badge.svg)](https://codecov.io/github/${UPSTREAM_REPO})"
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
# STATUS.md
# =============================================================================

# Badge and table header are assembled after the loop (need counts)
table_rows=""
table_header="| Package | Version | Strategy | Updated | Status |
|---------|---------|----------|---------|--------|"

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
  else
    status="✅ tracking"
    ((pkg_ok++)) || true
  fi

  table_rows+="
| [${name}](https://aur.archlinux.org/packages/${name}) | ${current} | ${strategy} | ${last_updated} | ${status} |"
  ((pkg_count++)) || true
done

# The template has no package, and writes no STATUS.md
if [[ "$pkg_count" -eq 0 ]]; then
  log_info "No packages configured, STATUS.md not written"
  exit 0
fi

# Build badge: green if all ok, red otherwise
if [[ "$pkg_fail" -eq 0 ]]; then
  badge_color="brightgreen"
else
  badge_color="red"
fi
pkg_badge="![packages](https://img.shields.io/badge/packages-${pkg_ok}%2F${pkg_count}-${badge_color})"

table_badges="$pkg_badge"
if [[ -n "$repo_url" ]]; then
  table_badges="![Check Updates](https://github.com/${repo_url}/actions/workflows/check-updates.yml/badge.svg) ${pkg_badge}"
fi

printf '%s\n\n' "# Package status" "$table_badges" "${table_header}${table_rows}" >"$STATUS_MD"
echo "*Auto-generated by CI after each run.*" >>"$STATUS_MD"
log_ok "STATUS.md updated ($pkg_count packages)"
