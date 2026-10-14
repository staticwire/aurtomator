#!/usr/bin/env bash
#
# lib.sh - Shared functions for aurtomator scripts
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
# CHECKSUMS
# =============================================================================

# Print every checksum of a PKGBUILD as "<hash><TAB><source>": each array
# makepkg knows, with and without an arch suffix, paired with the entry at
# the same index of source or source_<arch>.
# Args: $1=pkgbuild path
pkgbuild_checksums() {
  bash -c '
    source "$1" 2>/dev/null
    for arr in $(compgen -A variable | grep -E "^(ck|md5|sha1|sha224|sha256|sha384|sha512|b2)sums(_.+)?$"); do
      declare -n sums_ref="$arr"
      declare -n src_ref="source${arr#*sums}"
      for i in "${!sums_ref[@]}"; do
        printf "%s\t%s\n" "${sums_ref[$i]}" "${src_ref[$i]:-}"
      done
    done
  ' -- "$1" 2>/dev/null || true
}

# Args: $1=pkgbuild path
# Returns: 0 when any checksum of the PKGBUILD is SKIP, 1 otherwise
has_skip_checksums() {
  pkgbuild_checksums "$1" | awk -F'\t' '$1 == "SKIP" { found = 1 } END { exit !found }'
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

  # FATAL: SKIP mixed with real hashes for REMOTE sources.
  # updpkgsums is all-or-nothing, and a SKIP array skips it entirely, so a
  # real hash for a remote source would go stale on the version bump.
  # Real hashes for local files (no ://) are fine: they live in the AUR
  # repo and do not change between versions.
  if pkgbuild_checksums "$pkgbuild" | awk -F'\t' '
    $1 == "SKIP" { skip = 1 }
    $1 != "SKIP" && $2 ~ /:\/\// { remote = 1 }
    END { exit !(skip && remote) }'; then
    log_err "BLOCKED: SKIP checksums mixed with real hashes for remote sources."
    log_err "  updpkgsums is all-or-nothing: either all checksums update or none."
    log_err "  Remote source hashes would become stale on version bump."
    fatals=$((fatals + 1))
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

# Check that source URLs return files and not HTML error pages.
# Covers source and every source_<arch> array the PKGBUILD defines.
# Args: $1=pkgbuild path
# Returns: 0=ok, non-zero=errors found
validate_source_urls() {
  local pkgbuild="$1"
  local errors=0

  local urls
  urls=$(bash -c '
    source "$1" 2>/dev/null
    for arr in source $(compgen -A variable | grep "^source_"); do
      declare -n ref="$arr"
      for s in "${ref[@]}"; do
        url="${s##*::}"
        [[ "$url" == http* ]] && [[ "$url" != git+* ]] && echo "$url"
      done
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
# AUR GIT
# =============================================================================

# Clone an AUR repo, with 3 attempts
# Args: $1=url, $2=destination
aur_clone() {
  local attempt
  # Brief delay to reduce AUR SSH rate-limit pressure from GitHub Actions IP pool
  sleep 2
  for attempt in 1 2 3; do
    if git clone "$1" "$2" 2>&1; then
      return 0
    fi
    if [[ "$attempt" -eq 3 ]]; then
      log_err "Failed to clone AUR repo $1 after 3 attempts"
      return 1
    fi
    log_warn "Clone attempt $attempt failed, retrying in 5s..."
    rm -rf "$2"
    sleep 5
  done
}

# The AUR can serve a HEAD that does not match refs/heads/master after two
# runs pushed at the same time. HEAD and master then point at different
# commits with the same content, and a clone lands on a detached HEAD.
#
# The AUR refuses non-fast-forward pushes, so the commit has to sit on
# origin/master and not on the detached HEAD. Anything unique to the
# detached commit is dropped. The workflow's concurrency group prevents
# the race; this stays as a safety net.
# Args: $1=clone directory
aur_reanchor() {
  if ! git -C "$1" symbolic-ref -q HEAD >/dev/null; then
    log_warn "Detached HEAD after clone (remote HEAD != refs/heads/master)"
    log_info "Re-basing on origin/master to allow fast-forward push"
    git -C "$1" checkout -B master origin/master
  fi
}

# Commit PKGBUILD and .SRCINFO, sign when GPG_KEY_ID is set, push with 3
# attempts.
# Args: $1=clone directory, $2=version, $3=strategy (for the commit message)
aur_commit_push() {
  local dir="$1" attempt
  log_info "Pushing to AUR"
  git -C "$dir" config user.name "${GIT_AUTHOR_NAME:-aurtomator}"
  git -C "$dir" config user.email "${GIT_AUTHOR_EMAIL:-aurtomator@users.noreply.github.com}"
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" add PKGBUILD .SRCINFO
  git -C "$dir" commit -m "$2 release from $3" || {
    log_err "git commit failed in $dir"
    return 1
  }

  if [[ -n "${GPG_KEY_ID:-}" ]]; then
    git -C "$dir" -c user.signingkey="$GPG_KEY_ID" \
      -c commit.gpgsign=true \
      commit --amend --no-edit || {
      log_warn "GPG signing failed, pushing unsigned commit"
    }
  fi

  for attempt in 1 2 3; do
    if git -C "$dir" push 2>&1; then
      return 0
    fi
    if [[ "$attempt" -eq 3 ]]; then
      log_err "git push to AUR failed after 3 attempts"
      return 1
    fi
    log_warn "Push attempt $attempt failed, retrying in 5s..."
    sleep 5
  done
}

# =============================================================================
# PREPARED UPDATE CHECKS
# =============================================================================

# The job that executes a PKGBUILD holds no secrets, so the files it hands
# over are untrusted. The job that pushes accepts them only when they differ
# from the AUR copy in pkgver, pkgrel and checksum values. None of these
# checks sources the file.

# awk keeps a NUL byte, $(...) drops it and mapfile cuts the line at it, so
# a file with one is compared as something it is not
# Args: $1=file
# Returns: 0 when the file holds a NUL byte
_has_nul() {
  [[ "$(tr -d '\000' <"$1" | wc -c)" -ne "$(wc -c <"$1")" ]]
}

# Split a PKGBUILD into lines of four kinds, without executing it:
#   SKEL<TAB>line          every line, with pkgver=, pkgrel= and each
#                          top-level checksum array replaced by a placeholder
#   PKGVER|PKGREL<TAB>val  the value of a pkgver= or pkgrel= line
#   SUM<TAB>array<TAB>index<TAB>HASH|SKIP  one line per checksum
#   BAD<TAB>text           anything in a checksum array but a quoted checksum
# Args: $1=pkgbuild path
_pkgbuild_parts() {
  awk '
    function tokens(text,   n, i, t, parts) {
      n = split(text, parts, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        t = parts[i]
        if (t == "") continue
        if (t !~ /^(\047([0-9a-fA-F]+|SKIP)\047|"([0-9a-fA-F]+|SKIP)")$/) {
          print "BAD\t" NR ": " t
          continue
        }
        print "SUM\t" name "\t" idx++ "\t" (t ~ /SKIP/ ? "SKIP" : "HASH")
      }
    }
    function body(text,   end) {
      end = index(text, ")")
      if (!end) {
        tokens(text)
        return 1
      }
      tokens(substr(text, 1, end - 1))
      if (substr(text, end + 1) !~ /^[ \t]*$/) print "BAD\t" NR ": " substr(text, end + 1)
      return 0
    }
    in_sums { in_sums = body($0); next }
    /^(ck|md5|sha1|sha224|sha256|sha384|sha512|b2)sums(_[A-Za-z0-9_]+)?=\(/ {
      name = substr($0, 1, index($0, "=") - 1)
      idx = 0
      print "SKEL\tSUMS " name
      in_sums = body(substr($0, index($0, "(") + 1))
      next
    }
    /^pkgver=/ { print "SKEL\tPKGVER"; print "PKGVER\t" substr($0, 8); next }
    /^pkgrel=/ { print "SKEL\tPKGREL"; print "PKGREL\t" substr($0, 8); next }
    { print "SKEL\t" $0 }
    END { if (in_sums) print "BAD\tunterminated " name }
  ' "$1"
}

# Args: $1=AUR PKGBUILD, $2=prepared PKGBUILD, $3=expected version
# Returns: 0 when the prepared file changes only pkgver (to $3), pkgrel
#          (to 1) and checksum values, 1 otherwise (reason on stderr)
check_prepared_pkgbuild() {
  local version="$3"
  local old_parts new_parts value
  if ! old_parts=$(_pkgbuild_parts "$1") || ! new_parts=$(_pkgbuild_parts "$2"); then
    log_err "Could not read the PKGBUILD to compare"
    return 1
  fi
  if _has_nul "$2"; then
    log_err "Prepared PKGBUILD holds a NUL byte"
    return 1
  fi

  if grep -q $'^BAD\t' <<<"$new_parts"; then
    log_err "Prepared PKGBUILD has more than quoted checksums in a checksum array:"
    grep $'^BAD\t' <<<"$new_parts" | cut -f2- >&2
    return 1
  fi
  if [[ "$(grep $'^SKEL\t' <<<"$old_parts")" != "$(grep $'^SKEL\t' <<<"$new_parts")" ]]; then
    log_err "Prepared PKGBUILD changes lines outside pkgver, pkgrel and checksums"
    return 1
  fi
  if [[ "$(grep $'^SUM\t' <<<"$old_parts")" != "$(grep $'^SUM\t' <<<"$new_parts")" ]]; then
    log_err "Prepared PKGBUILD changes the checksum arrays: their names, lengths or SKIP entries differ from the AUR"
    return 1
  fi
  while IFS=$'\t' read -r _ value; do
    if [[ "$value" != "$version" ]]; then
      log_err "Prepared PKGBUILD has pkgver=${value}, expected ${version}"
      return 1
    fi
  done < <(grep $'^PKGVER\t' <<<"$new_parts")
  while IFS=$'\t' read -r _ value; do
    if [[ "$value" != "1" ]]; then
      log_err "Prepared PKGBUILD has pkgrel=${value}, expected 1"
      return 1
    fi
  done < <(grep $'^PKGREL\t' <<<"$new_parts")
  return 0
}

# A .SRCINFO is generated, so line N of the prepared file must be line N of
# the AUR file with the old version replaced by the new one. pkgrel and the
# checksum values are the exceptions.
# Args: $1=AUR .SRCINFO, $2=prepared .SRCINFO, $3=expected version
# Returns: 0 when that holds, 1 otherwise (reason on stderr)
check_prepared_srcinfo() {
  local version="$3"
  if [[ ! -r "$1" || ! -r "$2" ]]; then
    log_err "Could not read the .SRCINFO to compare"
    return 1
  fi
  if _has_nul "$2"; then
    log_err "Prepared .SRCINFO holds a NUL byte"
    return 1
  fi
  local -a old_lines new_lines
  mapfile -t old_lines <"$1"
  mapfile -t new_lines <"$2"
  if [[ "${#old_lines[@]}" -ne "${#new_lines[@]}" ]]; then
    log_err "Prepared .SRCINFO adds or removes lines"
    return 1
  fi

  local old_ver
  old_ver=$(awk -F' = ' '$1 ~ /^[ \t]*pkgver$/ { print $2; exit }' "$1")

  local i old new key kind old_val new_val
  for i in "${!new_lines[@]}"; do
    old="${old_lines[$i]}"
    new="${new_lines[$i]}"
    key="${new%% = *}"
    key="${key#"${key%%[![:space:]]*}"}"
    new_val="${new#* = }"
    old_val="${old#* = }"
    if [[ "$key" == "pkgver" || "$key" == "pkgrel" ]]; then
      kind="$key"
    elif [[ "$key" =~ ^(ck|md5|sha1|sha224|sha256|sha384|sha512|b2)sums(_[A-Za-z0-9_]+)?$ ]]; then
      kind=sums
    else
      kind=other
    fi
    if [[ "$kind" != "other" && "${old%% = *}" != "${new%% = *}" ]]; then
      log_err "Prepared .SRCINFO line $((i + 1)) has another key than the AUR copy: $new"
      return 1
    fi
    case "$kind" in
      pkgver)
        [[ "$new_val" == "$version" ]] || {
          log_err "Prepared .SRCINFO has pkgver = ${new_val}, expected ${version}"
          return 1
        }
        ;;
      pkgrel)
        [[ "$new_val" == "1" ]] || {
          log_err "Prepared .SRCINFO has pkgrel = ${new_val}, expected 1"
          return 1
        }
        ;;
      sums)
        if [[ ! "$new_val" =~ ^([0-9a-fA-F]+|SKIP)$ ]] ||
          [[ "$new_val" == "SKIP" && "$old_val" != "SKIP" ]] ||
          [[ "$new_val" != "SKIP" && "$old_val" == "SKIP" ]]; then
          log_err "Prepared .SRCINFO line $((i + 1)) is not a checksum matching the AUR copy: $new"
          return 1
        fi
        ;;
      *)
        if [[ "$new" != "${old//"$old_ver"/"$version"}" ]]; then
          log_err "Prepared .SRCINFO line $((i + 1)) changes more than the version: $new"
          return 1
        fi
        ;;
    esac
  done
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
