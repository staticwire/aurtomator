#!/usr/bin/env bash
#
# pkgbuild.sh - Checks update-pkg.sh runs on a PKGBUILD. All but
# warn_maintainer_line source the file in a child bash.
#
# Sourced by lib.sh, after common.sh.

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
# Returns: 0 when a checksum is SKIP for a source other than a signature,
#          1 otherwise. makepkg itself gives SKIP to a source whose file
#          name ends in .sig, .sign or .asc, so updpkgsums keeps it.
has_skip_checksums() {
  pkgbuild_checksums "$1" | awk -F'\t' '
    { name = $2; sub(/::.*/, "", name) }
    $1 == "SKIP" && name !~ /\.(sig|sign|asc)$/ { found = 1 }
    END { exit !found }'
}

# Args: $1=pkgbuild path
# Returns: 0 when a checksum is SKIP for a source makepkg would give a real
#          hash, 1 otherwise. makepkg gives SKIP itself to a signature and to
#          a VCS source without a #commit=, #tag= or #revision= pin.
has_fixed_skip() {
  pkgbuild_checksums "$1" | awk -F'\t' '
    $1 != "SKIP" { next }
    { name = $2; sub(/::.*/, "", name) }
    name ~ /\.(sig|sign|asc)$/ { next }
    {
      url = $2
      sub(/^[^:]*::/, "", url)
      proto = url
      if (!sub(/:\/\/.*/, "", proto)) { found = 1; next }
      sub(/\+.*/, "", proto)
      if (proto !~ /^(bzr|fossil|git|hg|svn)$/) { found = 1; next }
      key = url
      if (!sub(/^[^#]*#/, "", key)) next
      sub(/=.*/, "", key)
      if (key ~ /^(commit|tag|revision)$/) found = 1
    }
    END { exit !found }'
}

# Args: $1=pkgbuild path
# Returns: 0 when a remote source, one with ://, has a real checksum
has_remote_hash() {
  pkgbuild_checksums "$1" | awk -F'\t' '
    $1 != "SKIP" && $2 ~ /:\/\// { found = 1 }
    END { exit !found }'
}

# =============================================================================
# PKGBUILD AUDIT
# =============================================================================

# bash prints a function in one layout: a header line, "{", one command a
# line with a ; at its end, and "}"
# Args: $1=pkgbuild path
# Returns: 0 when pkgver() holds only cd lines and one printf or echo of
#          $pkgver, ${pkgver} or ${pkgver//-/.}, as streamrip has it. pkgver
#          holds no dash, so each prints the pkgver that sed sets.
pkgver_prints_pkgver() {
  local body
  body=$(bash -c 'source "$1" 2>/dev/null; declare -f pkgver' -- "$1" 2>/dev/null) || return 1
  awk '
    NR <= 2 || /^}$/ { next }
    { sub(/^ +/, ""); sub(/;$/, "") }
    /^cd [^;&|]+( \|\| (return|exit))?$/ { next }
    /^(printf|echo) "?\$(pkgver|\{pkgver(\/\/?-\/[^}]*)?\})"?$/ { prints++; next }
    { other = 1 }
    END { exit !(prints == 1 && !other) }
  ' <<<"$body"
}

# Audit PKGBUILD for unsupported features before updating.
# Args: $1=pkgbuild path, $2=strategy name
# Returns: 0=ok, 1=fatal (block update), 2=warnings only
audit_pkgbuild() {
  local pkgbuild="$1"
  local strategy="${2:-}"
  local warnings=0
  local fatals=0

  # FATAL: pkgver() with incompatible strategy (version mismatch)
  # git-latest and github-nightly are designed for packages with pkgver(),
  # and a pkgver() that only prints pkgver keeps what sed sets
  if grep -qE '^pkgver\(\)' "$pkgbuild"; then
    if [[ "$strategy" != "git-latest" && "$strategy" != "github-nightly" ]] && ! pkgver_prints_pkgver "$pkgbuild"; then
      log_err "BLOCKED: pkgver() function detected with strategy '$strategy'."
      log_err "  pkgver() computes version at build time, sed replacement is meaningless."
      log_err "  Drop pkgver() so that sed sets pkgver, or use 'git-latest' for a package built from git."
      fatals=$((fatals + 1))
    fi
  fi

  # FATAL: SKIP mixed with real hashes for REMOTE sources.
  # A SKIP that makepkg would replace with a hash makes update-pkg.sh skip
  # updpkgsums, so a real hash for a remote source would go stale on the
  # version bump. Real hashes for local files (no ://) are fine: they live
  # in the AUR repo and do not change between versions.
  if has_fixed_skip "$pkgbuild" && has_remote_hash "$pkgbuild"; then
    log_err "BLOCKED: SKIP checksums mixed with real hashes for remote sources."
    log_err "  A SKIP other than that of a signature (.sig, .sign, .asc) or of a VCS source without a pin turns off updpkgsums."
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

  # makepkg sets CARCH from makepkg.conf, which on x86_64 and aarch64 is what
  # uname -m prints, and a PKGBUILD may build a URL from it
  local urls
  urls=$(CARCH="${CARCH:-$(uname -m)}" bash -c '
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

    # curl reports the status and type of the last response. The headers
    # are text the server chose, and bash evaluates an operand of -ge as
    # arithmetic, where an array subscript runs a command.
    local response http_code content_type
    response=$(curl -sIL -o /dev/null -w '%{http_code} %{content_type}' \
      --max-time 10 --max-redirs 5 "$url" 2>/dev/null) || {
      log_warn "Source URL unreachable: $url"
      errors=$((errors + 1))
      continue
    }
    read -r http_code content_type <<<"$response"
    content_type="${content_type%%;*}"
    content_type="${content_type//[[:space:]]/}"
    content_type="${content_type,,}"

    if [[ ! "$http_code" =~ ^[0-9]{3}$ ]]; then
      log_err "Source URL returned no HTTP status: $url"
      errors=$((errors + 1))
      continue
    fi

    if ((10#$http_code >= 400)); then
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

# Check if PKGBUILD has a # Maintainer: line, warn if missing
# Usage: warn_maintainer_line /path/to/PKGBUILD
warn_maintainer_line() {
  local pkgbuild="$1"
  if ! grep -q '^# Maintainer:' "$pkgbuild" 2>/dev/null; then
    log_warn "PKGBUILD is missing '# Maintainer:' line (AUR convention)"
  fi
}
