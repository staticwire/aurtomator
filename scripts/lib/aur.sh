#!/usr/bin/env bash
#
# aur.sh - Clone, export and push of the AUR git repo of a package
#
# Sourced by lib.sh, after common.sh.

# Clone an AUR repo, with 3 attempts. AURTOMATOR_CLONE_DELAY and
# AURTOMATOR_RETRY_DELAY set the pauses, in seconds.
# Args: $1=url, $2=destination, $3...=options for git clone
aur_clone() {
  local attempt delay="${AURTOMATOR_RETRY_DELAY:-5}"
  # Brief delay to reduce AUR SSH rate-limit pressure from GitHub Actions IP
  # pool. The anonymous HTTPS clones of prepare and verify do not use SSH.
  if [[ "$1" == ssh://* ]]; then
    sleep "${AURTOMATOR_CLONE_DELAY:-2}"
  fi
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
