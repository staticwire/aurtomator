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
# GITHUB API
# =============================================================================

# GET a GitHub API URL, with GITHUB_TOKEN when it is set. curl reads the
# header from stdin: as an argument, the token is visible in ps to every
# local user.
# Usage: github_api https://api.github.com/repos/owner/repo/tags
github_api() {
  local auth=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth=(-H @-)
  fi
  curl -sfL --max-time 30 "${auth[@]}" "$1" <<<"Authorization: Bearer ${GITHUB_TOKEN:-}"
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

# =============================================================================
# AUR GIT
# =============================================================================

# Clone an AUR repo, with 3 attempts. AURTOMATOR_CLONE_DELAY and
# AURTOMATOR_RETRY_DELAY set the pauses, in seconds.
# Args: $1=url, $2=destination, $3...=options for git clone
aur_clone() {
  local attempt delay="${AURTOMATOR_RETRY_DELAY:-5}"
  # Brief delay to reduce AUR SSH rate-limit pressure from GitHub Actions IP pool
  sleep "${AURTOMATOR_CLONE_DELAY:-2}"
  for attempt in 1 2 3; do
    if git clone "${@:3}" "$1" "$2" 2>&1; then
      return 0
    fi
    if [[ "$attempt" -eq 3 ]]; then
      log_err "Failed to clone AUR repo $1 after 3 attempts"
      return 1
    fi
    log_warn "Clone attempt $attempt failed, retrying in ${delay}s..."
    rm -rf "$2"
    sleep "$delay"
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
# Args: $1=clone directory, $2=--no-checkout for a clone made without one
aur_reanchor() {
  if ! git -C "$1" symbolic-ref -q HEAD >/dev/null; then
    log_warn "Detached HEAD after clone (remote HEAD != refs/heads/master)"
    log_info "Re-basing on origin/master to allow fast-forward push"
    if [[ "${2:-}" == "--no-checkout" ]]; then
      git -C "$1" branch -f master origin/master &&
        git -C "$1" symbolic-ref HEAD refs/heads/master
    else
      git -C "$1" checkout -B master origin/master
    fi
  fi
}

# Write the top-level entries of HEAD of a clone made with --no-checkout
# into a directory, without a checkout, so git applies none of the links,
# attributes or filters of the repo: a regular file with its content, a
# symlink as a link to nowhere and anything else as an empty directory. The
# checks of the prepared update refuse those two where a PKGBUILD, a
# .SRCINFO or a source is expected, as they do in a checkout.
# Args: $1=clone directory, $2=destination directory, created here
aur_export() {
  local entry name mode sha
  mkdir "$2" || return 1
  while IFS= read -r -d '' entry; do
    name="${entry#*$'\t'}"
    [[ -n "$name" && "$name" != */* && "$name" != . && "$name" != .. ]] || continue
    read -r mode _ sha <<<"${entry%%$'\t'*}"
    case "$mode" in
      100*) git -C "$1" cat-file blob "$sha" >"$2/$name" || return 1 ;;
      120000) ln -s /nonexistent "$2/$name" || return 1 ;;
      *) mkdir "$2/$name" || return 1 ;;
    esac
  done < <(git -C "$1" ls-tree -z HEAD)
}

# Commit what the index holds, sign when GPG_KEY_ID is set, push with 3
# attempts, AURTOMATOR_RETRY_DELAY seconds apart. The caller stages
# PKGBUILD and .SRCINFO.
# Args: $1=clone directory, $2=version, $3=strategy (for the commit message)
aur_commit_push() {
  local dir="$1" attempt delay="${AURTOMATOR_RETRY_DELAY:-5}"
  log_info "Pushing to AUR"
  git -C "$dir" config user.name "${GIT_AUTHOR_NAME:-aurtomator}"
  git -C "$dir" config user.email "${GIT_AUTHOR_EMAIL:-aurtomator@users.noreply.github.com}"
  git -C "$dir" config commit.gpgsign false
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
    log_warn "Push attempt $attempt failed, retrying in ${delay}s..."
    sleep "$delay"
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

# Split a PKGBUILD into lines of five kinds, without executing it:
#   SKEL<TAB>line          every line, with pkgver=, pkgrel= and each
#                          top-level checksum array replaced by a placeholder
#   PKGVER|PKGREL<TAB>val  the value of a pkgver= or pkgrel= line
#   SUM<TAB>array<TAB>index<TAB>HASH|SKIP  one line per checksum
#   SUMVAL<TAB>array<TAB>value  the same checksum with its value
#   BAD<TAB>text           anything in a checksum array but a quoted
#                          checksum, a comment or a line continuation
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
        print "SUMVAL\t" name "\t" substr(t, 2, length(t) - 2)
      }
    }
    # As bash does: a # that starts a word comments out the rest of the
    # line, and a backslash at the end of a line outside a comment joins
    # the next line, which inside the parentheses is only a separator
    function body(text,   raw, cont, end, rest) {
      raw = text
      sub(/(^|[ \t])#.*/, "", text)
      cont = text == raw && text ~ /(^|[ \t])\\$/
      if (cont) text = substr(text, 1, length(text) - 1)
      end = index(text, ")")
      if (!end) {
        tokens(text)
        return 1
      }
      tokens(substr(text, 1, end - 1))
      rest = substr(text, end + 1) (cont ? "\\" : "")
      if (rest !~ /^[ \t]*$/) print "BAD\t" NR ": " rest
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
    log_err "Prepared PKGBUILD has more than quoted checksums, comments and line continuations in a checksum array:"
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

# Replace the old version in a line with the new one, and also the forms a
# PKGBUILD derives from pkgver: dots turned into underscores, the part
# before the first +, and the version without its last component, such as
# ${pkgver%.*} in the frameworks/6.19/ directory of KDE Frameworks. That
# last form counts only while it keeps a dot, as a lone major version is
# too common in other text. One pass from left to right, longest form
# first, so a replaced part is not matched again: with 5.1.0 -> 5.10.0 the
# 5.1 at the start of 5.10.0 stays.
# Args: $1=line, $2=old version, $3=new version
_bump_version() {
  local rest="$1" old="$2" new="$3" out="" i matched
  if [[ -z "$old" ]]; then
    printf '%s\n' "$rest"
    return 0
  fi
  local -a olds=("$old") news=("$new")
  if [[ "$old" == *.* ]]; then
    olds+=("${old//./_}")
    news+=("${new//./_}")
  fi
  if [[ "$old" == *+* ]]; then
    olds+=("${old%%+*}")
    news+=("${new%%+*}")
  fi
  old="${old%%+*}"
  new="${new%%+*}"
  if [[ "${old%.*}" == *.* ]]; then
    olds+=("${old%.*}")
    news+=("${new%.*}")
  fi

  while [[ -n "$rest" ]]; do
    matched=false
    for i in "${!olds[@]}"; do
      if [[ "$rest" == "${olds[$i]}"* ]]; then
        out+="${news[$i]}"
        rest="${rest:${#olds[$i]}}"
        matched=true
        break
      fi
    done
    if [[ "$matched" == false ]]; then
      out+="${rest:0:1}"
      rest="${rest:1}"
    fi
  done
  printf '%s\n' "$out"
}

# Print "<arch suffix>:<index>" for every source entry of a .SRCINFO that is
# SKIP in each checksum array with the same arch suffix
# Args: $1=.SRCINFO
_skip_sources() {
  awk -F' = ' '
    { key = $1; sub(/^[ \t]+/, "", key) }
    key ~ /^(ck|md5|sha1|sha224|sha256|sha384|sha512|b2)sums(_[A-Za-z0-9_]+)?$/ {
      entry = substr(key, index(key, "sums") + 4) ":" count[key]++
      listed[entry] = 1
      if ($2 != "SKIP") hashed[entry] = 1
    }
    END { for (entry in listed) if (!(entry in hashed)) print entry }
  ' "$1"
}

# Args: $1=expected source line, $2=prepared source line
# Returns: 0 when both save their file under a name before ::, have the same
#          URL after it, and their names differ in nothing but digits
_name_differs_in_digits() {
  [[ "$1" == *::* && "$2" == *::* && "${1#*::}" == "${2#*::}" ]] || return 1
  [[ "$(sed -E 's/[0-9]+/0/g' <<<"${1%%::*}")" == "$(sed -E 's/[0-9]+/0/g' <<<"${2%%::*}")" ]]
}

# A .SRCINFO is generated, so line N of the prepared file must be line N of
# the AUR file, with these changes: pkgver is the new version, pkgrel is 1,
# a checksum keeps its key and stays a SKIP or a hash, a source has the old
# version replaced by the new one (see _bump_version), and any other line
# either stays or has the version replaced in the same way. A license, a
# dependency or a pkgdesc can hold the old version without deriving it
# from pkgver. A source that is SKIP in every checksum array may also change
# the digits in the name of its file, as a nightly package names its
# download by the date: verify_prepared_sums never fetches it, and makepkg
# takes the sources from the PKGBUILD.
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

  local -A skip_sources=() source_counts=()
  local entry
  while read -r entry; do
    skip_sources["$entry"]=1
  done < <(_skip_sources "$1")

  local i old new key kind old_val new_val n expected
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
    elif [[ "$key" =~ ^source(_[A-Za-z0-9_]+)?$ ]]; then
      kind=source
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
      source)
        n="${source_counts[$key]:-0}"
        source_counts[$key]=$((n + 1))
        expected=$(_bump_version "$old" "$old_ver" "$version")
        if [[ "$new" != "$expected" ]] &&
          ! { [[ -n "${skip_sources["${key#source}:$n"]:-}" ]] &&
            _name_differs_in_digits "$expected" "$new"; }; then
          log_err "Prepared .SRCINFO line $((i + 1)) is not the AUR source with the new version: $new"
          return 1
        fi
        ;;
      *)
        if [[ "$new" != "$old" && "$new" != "$(_bump_version "$old" "$old_ver" "$version")" ]]; then
          log_err "Prepared .SRCINFO line $((i + 1)) changes more than the version: $new"
          return 1
        fi
        ;;
    esac
  done
  return 0
}

# Check the layout of a prepared directory and print its base, the AUR
# commit the update was prepared from
# Args: $1=prepared dir
# Returns: 0 when the layout holds, 1 otherwise (reason on stderr)
prepared_base() {
  local f base
  if [[ -L "$1" || ! -d "$1" ]]; then
    log_err "Prepared directory is missing or a symlink: $1"
    return 1
  fi
  for f in PKGBUILD .SRCINFO base; do
    if [[ ! -f "$1/$f" || -L "$1/$f" ]]; then
      log_err "Prepared $f is missing or not a regular file"
      return 1
    fi
  done
  base=$(<"$1/base")
  if [[ ! "$base" =~ ^[0-9a-f]{40}$ ]]; then
    log_err "Prepared base is not a commit id"
    return 1
  fi
  echo "$base"
}

# Check a prepared PKGBUILD and .SRCINFO against the AUR repo at their base
# Args: $1=AUR repo, $2=prepared dir, $3=expected version
# Returns: 0 when both files pass, 1 otherwise (reason on stderr)
check_prepared_files() {
  local f
  # git keeps symlinks, and cp writes through one
  for f in PKGBUILD .SRCINFO; do
    if [[ -L "$1/$f" || ! -f "$1/$f" ]]; then
      log_err "$f in the AUR repo is missing, a symlink or not a regular file"
      return 1
    fi
  done
  check_prepared_pkgbuild "$1/PKGBUILD" "$2/PKGBUILD" "$3" &&
    check_prepared_srcinfo "$1/.SRCINFO" "$2/.SRCINFO" "$3"
}

# =============================================================================
# SOURCE CHECKSUMS
# =============================================================================

# Print the path of the file makepkg hashes for a source, following
# get_protocol, get_filename and download_file of makepkg. A source that
# makepkg would handle another way is refused, never guessed at.
# Args: $1=source entry of a .SRCINFO, $2=AUR repo, $3=download directory
_source_file() {
  local entry="$1" url="${1#*::}" name file
  if [[ "$entry" == *::* ]]; then
    name="${entry%%::*}"
  else
    name="${entry##*/}"
  fi
  # makepkg reads lp: without :// as a bzr source
  if [[ -z "$name" || "$name" == */* || "$name" == . || "$name" == .. ]] ||
    [[ "$entry" == *://* && ! "${url%%://*}" =~ ^(http|https|ftp)$ ]] ||
    [[ "$entry" != *://* && "$entry" == *lp:* ]]; then
    log_err "Cannot check the checksum of $entry: only local files, http, https and ftp downloads and git sources are checked"
    return 1
  fi

  # makepkg takes a file of that name next to the PKGBUILD before it
  # downloads anything
  file="${2}/${name}"
  if [[ -e "$file" || -L "$file" ]]; then
    if [[ -L "$file" || ! -f "$file" ]]; then
      log_err "Source $entry is a symlink or not a regular file in the AUR repo"
      return 1
    fi
  elif [[ "$entry" != *://* ]]; then
    log_err "Local source $entry is missing from the AUR repo"
    return 1
  else
    file="${3}/$(printf '%s' "$url" | sha256sum | cut -d' ' -f1)"
    # Retried as makepkg does. Redirects may only lead to the protocols above.
    if [[ ! -f "$file" ]] &&
      ! curl -qgfsSL --retry 3 --retry-delay 3 --proto '=http,https,ftp' \
        --proto-redir '=http,https,ftp' -o "$file" "$url"; then
      rm -f "$file"
      log_err "Could not download $url"
      return 1
    fi
  fi
  printf '%s\n' "$file"
}

# Print the checksum makepkg computes for a git source, following
# download_git and calc_checksum_git of makepkg: the tar archive of the tag
# or commit, from a mirror clone with export-subst and export-ignore turned
# off. makepkg gives any other git source SKIP, so a checksum never matches.
# Args: $1=source entry of a .SRCINFO, $2=algorithm, $3=AUR repo,
#       $4=download directory
_git_source_sum() {
  local entry="$1" url="${1#*::}" name fragment="" ref dir sum
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/etc/makepkg.d/gitconfig
  url="${url#git+}"
  if [[ "$url" == *#* ]]; then
    fragment="${url#*#}"
    fragment="${fragment%\?*}"
  fi
  url="${url%%#*}"
  url="${url%%\?*}"
  ref="${fragment##*=}"
  if [[ "$entry" == *::* ]]; then
    name="${entry%%::*}"
  else
    name="${url%/}"
    name="${name##*/}"
    name="${name%%.git*}"
  fi

  if [[ ! "${url%%://*}" =~ ^(http|https)$ ]]; then
    log_err "Cannot check the checksum of $entry: git sources are cloned over https or http only"
    return 1
  fi
  if [[ ! "${fragment%%=*}" =~ ^(tag|commit)$ || -z "$ref" || "$ref" == -* ]]; then
    log_err "Cannot check the checksum of $entry: makepkg hashes a git source only at a tag or commit"
    return 1
  fi
  if [[ -z "$name" || "$name" == */* || "$name" == . || "$name" == .. ]]; then
    log_err "Cannot check the checksum of $entry"
    return 1
  fi
  if [[ -e "${3}/${name}" || -L "${3}/${name}" ]]; then
    log_err "Cannot check the checksum of $entry: ${name} in the AUR repo takes the place of the clone in makepkg"
    return 1
  fi

  dir="${4}/$(printf '%s' "$url" | sha256sum | cut -d' ' -f1).git"
  if [[ ! -d "$dir" ]]; then
    if ! GIT_ALLOW_PROTOCOL=http:https git clone -q --origin=origin --mirror "$url" "$dir"; then
      rm -rf "$dir"
      log_err "Could not clone $url"
      return 1
    fi
    mkdir -p "${dir}/info"
    echo "* -export-subst -export-ignore" >"${dir}/info/attributes"
  fi
  if ! sum=$(git -c core.abbrev=no -C "$dir" archive --format tar "$ref" | "${2}sum"); then
    log_err "Could not archive $ref of $url"
    return 1
  fi
  printf '%s\n' "${sum%% *}"
}

# Print the checksum makepkg computes for a source
# Args: $1=source entry of a .SRCINFO, $2=algorithm, $3=AUR repo,
#       $4=download directory
_source_sum() {
  local proto="${1#*::}" file sum
  proto="${proto%%://*}"
  if [[ "$1" == *://* && "${proto%%+*}" == git ]]; then
    _git_source_sum "$@"
    return
  fi
  file=$(_source_file "$1" "$3" "$4") || return 1
  sum=$("${2}sum" "$file")
  printf '%s\n' "${sum%% *}"
}

# check_prepared_pkgbuild lets checksum values change, and the code of one
# PKGBUILD runs where the updates of all packages are prepared. So each
# value must match its source, hashed the way makepkg does. The sources
# come from the prepared .SRCINFO, which check_prepared_srcinfo ties to the
# AUR copy. Run check_prepared_files first.
# Args: $1=AUR repo, $2=prepared dir, $3=empty directory for the downloads
# Returns: 0 when every checksum matches, 1 otherwise (reason on stderr)
verify_prepared_sums() {
  local aur_dir="$1" prepared="$2" downloads="$3"
  local -A srcinfo=() pkgbuild=()
  local -a lines=() keys=() sums=() sources=()
  local line key value algo i actual

  # mapfile, as check_prepared_srcinfo reads it: a last line without a
  # newline counts
  mapfile -t lines <"${prepared}/.SRCINFO"
  for line in "${lines[@]}"; do
    [[ "$line" == *" = "* ]] || continue
    key="${line%% = *}"
    key="${key#"${key%%[![:space:]]*}"}"
    if [[ "$key" =~ ^source(_[A-Za-z0-9_]+)?$ ||
      "$key" =~ ^(ck|md5|sha1|sha224|sha256|sha384|sha512|b2)sums(_[A-Za-z0-9_]+)?$ ]]; then
      srcinfo[$key]+="${line#* = }"$'\n'
    fi
  done

  while IFS=$'\t' read -r _ key value; do
    [[ -n "${pkgbuild[$key]+set}" ]] || keys+=("$key")
    pkgbuild[$key]+="${value}"$'\n'
  done < <(_pkgbuild_parts "${prepared}/PKGBUILD" | grep $'^SUMVAL\t')

  for key in "${!srcinfo[@]}"; do
    if [[ "$key" == *sums* && -z "${pkgbuild[$key]+set}" ]]; then
      log_err "Prepared .SRCINFO lists ${key}, the PKGBUILD does not"
      return 1
    fi
  done

  for key in "${keys[@]}"; do
    if [[ "${srcinfo[$key]:-}" != "${pkgbuild[$key]}" ]]; then
      log_err "Prepared PKGBUILD and .SRCINFO differ in ${key}"
      return 1
    fi
    algo="${key%%sums*}"
    mapfile -t sums < <(printf '%s' "${pkgbuild[$key]}")
    mapfile -t sources < <(printf '%s' "${srcinfo[source${key#*sums}]:-}")
    if [[ "${#sums[@]}" -ne "${#sources[@]}" ]]; then
      log_err "Prepared .SRCINFO has ${#sums[@]} ${key} for ${#sources[@]} sources"
      return 1
    fi
    for i in "${!sums[@]}"; do
      [[ "${sums[$i]}" != "SKIP" ]] || continue
      actual=$(_source_sum "${sources[$i]}" "$algo" "$aur_dir" "$downloads") || return 1
      if [[ "${sums[$i],,}" != "$actual" ]]; then
        log_err "${key} of ${sources[$i]} is ${sums[$i]}, the source has ${actual}"
        return 1
      fi
    done
  done
  return 0
}

# =============================================================================
# FAILURE ISSUES
# =============================================================================

# Body of the issue opened for a failed package. The error holds text from
# upstream, such as a rejected tag name, so it goes into a code block,
# where links, images and mentions do not render. The fence is longer than
# any run of backticks in the error, so the error cannot close it. The
# error is cut to its last 4000 characters, where the cause usually is.
# Args: $1=status file in .status/, named after the package, holding
#       check_failed: ... or update_failed: ...; $2=URL of the run
failure_issue_body() {
  local status kind error fence='```' limit=4000
  status=$(<"$1")
  kind="${status%%:*}"
  error="${status#*: }"
  if ((${#error} > limit)); then
    error="[first $((${#error} - limit)) characters cut]"$'\n'"${error:${#error}-limit}"
  fi
  while [[ "$error" == *"$fence"* ]]; do
    fence+='`'
  done
  # The backticks are Markdown code around the package name
  # shellcheck disable=SC2016
  printf 'Package: `%s`\nStatus: %s\nRun: %s\n\n%s\n%s\n%s\n\nAuto-created by update workflow. Close after fixing.\n' \
    "${1##*/}" "${kind//_/ }" "$2" "$fence" "$error" "$fence"
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
