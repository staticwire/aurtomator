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
  # A pause before an SSH clone lowers the load of the shared GitHub Actions addresses on the
  # SSH rate limit of the AUR; the HTTPS clones of prepare and verify skip it
  if [[ "$1" == ssh://* ]]; then
    sleep "${AURTOMATOR_CLONE_DELAY:-2}"
  fi
  git_request_begin "$1" || return 1
  for attempt in 1 2 3; do
    if git clone "${@:3}" "$1" "$2" 2>&1; then
      request_end
      return 0
    fi
    if [[ "$attempt" -eq 3 ]]; then
      request_end
      log_err "Failed to clone AUR repo $1 after 3 attempts"
      return 1
    fi
    log_warn "Clone attempt $attempt failed, retrying in ${delay}s..."
    rm -rf "$2"
    sleep "$delay"
  done
}

# Put the clone back on origin/master when it lands on a detached HEAD, which the AUR can serve
# after two pushes at once, since the AUR refuses a push that is no fast-forward of master
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

# Write the top-level entries of HEAD of --no-checkout clone $1 to new directory $2 without git
# filters: a file with its content, a symlink as a link to nowhere, anything else as an empty dir
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

# Commit the index, signed when GPG_KEY_ID is set, and push with 3 attempts AURTOMATOR_RETRY_DELAY
# seconds apart; the caller stages PKGBUILD and .SRCINFO
# Args: $1=clone directory, $2=version, $3=strategy (for the commit message),
#       $4=pkgrel, 1 by default, $5=arches put back, for "Add <arches> to <version>"
aur_commit_push() {
  local dir="$1" version="$2" message attempt delay="${AURTOMATOR_RETRY_DELAY:-5}"
  [[ "${4:-1}" == 1 ]] || version+="-$4"
  message="$version release from $3"
  [[ -z "${5:-}" ]] || message="Add $5 to $version"
  log_info "Pushing to AUR"
  git -C "$dir" config user.name "${GIT_AUTHOR_NAME:-aurtomator}"
  git -C "$dir" config user.email "${GIT_AUTHOR_EMAIL:-aurtomator@users.noreply.github.com}"
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" commit -m "$message" || {
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
