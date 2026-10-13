#!/usr/bin/env bash
#
# lib.sh — Shared functions for aurtomator scripts
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Requires: yq (https://github.com/mikefarah/yq)

set -euo pipefail

# Resolve project root
AURTOMATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# =============================================================================
# DEPENDENCY CHECK
# =============================================================================

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    log_err "Required command not found: $cmd"
    exit 1
  fi
}

# =============================================================================
# YAML (via yq)
# =============================================================================

# Read any field from a YAML file
# Usage: pkg_get packages/my-package.yml .name
#        pkg_get packages/my-package.yml .upstream.type
pkg_get() {
  local file="$1" query="$2"
  yq -r "$query" "$file"
}

# Set a field in a YAML file
# Usage: pkg_set packages/my-package.yml .current '"24.12.3"'
pkg_set() {
  local file="$1" query="$2" value="$3"
  yq -i "${query} = ${value}" "$file"
}

# =============================================================================
# CONFIG
# =============================================================================

load_config() {
  local config="${AURTOMATOR_DIR}/.aurtomator.conf"
  if [[ -f "$config" ]]; then
    # shellcheck source=/dev/null
    source "$config"
  fi
}

# =============================================================================
# PACKAGE HELPERS
# =============================================================================

# Resolve package YAML file path from name
# Usage: pkg_file my-package
pkg_file() {
  local name="$1"
  local file="${AURTOMATOR_DIR}/packages/${name}.yml"
  if [[ ! -f "$file" ]]; then
    log_err "Package not found: $file"
    return 1
  fi
  echo "$file"
}

# Check if PKGBUILD has a # Maintainer: line, warn if missing
# Usage: warn_maintainer_line /path/to/PKGBUILD
warn_maintainer_line() {
  local pkgbuild="$1"
  if ! grep -q '^# Maintainer:' "$pkgbuild" 2>/dev/null; then
    log_warn "PKGBUILD is missing '# Maintainer:' line (AUR convention)"
  fi
}

# =============================================================================
# VERSION VALIDATION
# =============================================================================

# Reject a version string before it is written into a PKGBUILD.
# update-pkg.sh writes the value with sed and makepkg then sources the
# file, so a shell metacharacter in an upstream tag would execute in CI.
# The allowlist is narrower than makepkg's own pkgver check on purpose:
# makepkg only forbids whitespace, '/', ':', '-' and non-ASCII.
# Args: $1=version string
# Returns: 0=ok, 1=rejected (reason on stderr)
validate_pkgver() {
  local ver="$1"
  local LC_ALL=C
  if [[ -z "$ver" ]]; then
    log_err "Version string is empty"
    return 1
  fi
  if [[ ! "$ver" =~ ^[A-Za-z0-9._+]+$ ]]; then
    log_err "Version string rejected, only A-Za-z0-9 . _ + are allowed: ${ver@Q}"
    return 1
  fi
}

# =============================================================================
# PKGBUILD AUDIT
# =============================================================================

# Audit PKGBUILD for unsupported features before updating.
# Args: $1=pkgbuild path, $2=strategy name
# Returns: 0=ok, 1=fatal (block update), 2=warnings only
audit_pkgbuild() {
  local pkgbuild="$1"
  local strategy="${2:-}"
  local warnings=0
  local fatals=0

  # FATAL: Split packages (pkgname is array)
  if grep -qE '^pkgname=\(' "$pkgbuild"; then
    log_err "BLOCKED: Split package detected (pkgname is array). Not supported."
    fatals=$((fatals + 1))
  fi

  # FATAL: pkgver() with incompatible strategy (version mismatch)
  # git-latest and github-nightly are designed for packages with pkgver()
  if grep -qE '^pkgver\(\)' "$pkgbuild"; then
    if [[ "$strategy" != "git-latest" && "$strategy" != "github-nightly" ]]; then
      log_err "BLOCKED: pkgver() function detected with strategy '$strategy'."
      log_err "  pkgver() computes version at build time, sed replacement is meaningless."
      log_err "  Use strategy 'git-latest' or 'github-nightly' for these packages."
      fatals=$((fatals + 1))
    fi
  fi

  # FATAL: Mixed SKIP + real checksums for REMOTE sources.
  # updpkgsums is all-or-nothing: if we see SKIP, we skip it entirely.
  # Real hashes for remote sources would become stale on version bump.
  # Real hashes for local files (no ://) are fine — they live in the AUR
  # repo and don't change between versions.
  if grep -qE "(md5|sha[0-9]+|b2)sums=\('SKIP'" "$pkgbuild"; then
    local stale_remote
    stale_remote=$(bash -c '
      source "$1" 2>/dev/null
      # Check each main checksum array against corresponding source
      for arr_prefix in sha256 sha512 sha1 md5 b2; do
        arr="${arr_prefix}sums"
        declare -n sums_ref="$arr" 2>/dev/null || continue
        declare -n src_ref="source" 2>/dev/null || continue
        [[ ${#sums_ref[@]} -eq 0 ]] && continue
        for i in "${!sums_ref[@]}"; do
          hash="${sums_ref[$i]}"
          src="${src_ref[$i]:-}"
          url="${src##*::}"
          # Non-SKIP hash + remote URL = stale after version bump
          if [[ "$hash" != SKIP ]] && [[ "$url" == *://* ]]; then
            echo stale
            exit 0
          fi
        done
      done
    ' -- "$pkgbuild" 2>/dev/null || true)
    if [[ "$stale_remote" == "stale" ]]; then
      log_err "BLOCKED: SKIP checksums mixed with real hashes for remote sources."
      log_err "  updpkgsums is all-or-nothing: either all checksums update or none."
      log_err "  Remote source hashes would become stale on version bump."
      fatals=$((fatals + 1))
    fi
  fi

  # WARNING: Patches in source=()
  local source_entries
  source_entries=$(bash -c 'source "$1" 2>/dev/null; printf "%s\n" "${source[@]}"' -- "$pkgbuild" 2>/dev/null || true)
  if grep -qE '\.(patch|diff)$' <<<"$source_entries"; then
    log_warn "PKGBUILD has patches in source=(). May fail on new versions."
    warnings=$((warnings + 1))
  fi

  if [[ "$fatals" -gt 0 ]]; then
    return 1
  fi
  if [[ "$warnings" -gt 0 ]]; then
    return 2
  fi
  return 0
}

# Validate source URLs return expected content (not HTML error pages).
# Args: $1=pkgbuild path
# Returns: 0=ok, non-zero=errors found
validate_source_urls() {
  local pkgbuild="$1"
  local errors=0

  local urls
  urls=$(bash -c '
    source "$1" 2>/dev/null
    for s in "${source[@]}" "${source_x86_64[@]}" "${source_aarch64[@]}"; do
      url="${s##*::}"
      [[ "$url" == http* ]] && [[ "$url" != git+* ]] && echo "$url"
    done
  ' -- "$pkgbuild" 2>/dev/null || true)

  [[ -z "$urls" ]] && return 0

  while IFS= read -r url; do
    [[ -z "$url" ]] && continue

    local headers http_code content_type
    headers=$(curl -sIL --max-time 10 --max-redirs 5 "$url" 2>/dev/null) || {
      log_warn "Source URL unreachable: $url"
      errors=$((errors + 1))
      continue
    }

    http_code=$(grep -i "^HTTP/" <<<"$headers" | tail -1 | awk '{print $2}')
    content_type=$(grep -i "^content-type:" <<<"$headers" | tail -1 | sed 's/^[^:]*: *//' | cut -d';' -f1 | tr -d '[:space:]')

    if [[ "${http_code:-0}" -ge 400 ]]; then
      log_err "Source URL returned HTTP $http_code: $url"
      errors=$((errors + 1))
      continue
    fi

    if [[ "$content_type" == "text/html" ]]; then
      log_err "Source URL returns HTML instead of binary/archive: $url"
      errors=$((errors + 1))
    fi
  done <<<"$urls"

  if [[ "$errors" -gt 0 ]]; then
    return 1
  fi
  return 0
}

# =============================================================================
# LOGGING
# =============================================================================

if [[ -t 1 ]]; then
  _GREEN='\033[0;32m'
  _YELLOW='\033[0;33m'
  _RED='\033[0;31m'
  _BOLD='\033[1m'
  _RESET='\033[0m'
else
  _GREEN="" _YELLOW="" _RED="" _BOLD="" _RESET=""
fi

log_ok() { printf "${_GREEN}✓${_RESET} %s\n" "$*" >&2; }
log_warn() { printf "${_YELLOW}!${_RESET} %s\n" "$*" >&2; }
log_err() { printf "${_RED}✗${_RESET} %s\n" "$*" >&2; }
log_info() { printf "${_BOLD}→${_RESET} %s\n" "$*" >&2; }
