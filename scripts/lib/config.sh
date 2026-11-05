#!/usr/bin/env bash
#
# config.sh - .aurtomator.conf, the answers that setup.sh saves
#
# Sourced by lib.sh and by setup.sh.

# Print the value of a text that ${value@Q} wrote, or of one in double
# quotes without $, ` and \, as older versions of the setup wrote it
_config_value() {
  local single="^'[^']*('\\\\''[^']*)*'\$" double='^"([^"$`\]*)"$' body
  if [[ "$1" =~ $double ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$1" =~ $single ]]; then
    body="${1:1:${#1}-2}"
    printf '%s' "${body//"'\\''"/"'"}"
  else
    return 1
  fi
}

# Set the four values of the .aurtomator.conf of AURTOMATOR_DATA_DIR. The
# file is read as data, and a line of any other form stops the caller.
load_config() {
  local config="${AURTOMATOR_DATA_DIR}/.aurtomator.conf" line value n=0
  [[ -f "$config" ]] || return 0
  # git puts a tracked file in place of the ignored one at a checkout or a
  # merge, so its values can come from any commit
  if git -C "$AURTOMATOR_DATA_DIR" ls-files --error-unmatch -- .aurtomator.conf >/dev/null 2>&1; then
    echo "$config is tracked by git, so a commit can set its values. Check them, then take the file out of the repository: git rm --cached .aurtomator.conf" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ -n "$line" && "$line" != \#* ]] || continue
    if [[ "$line" =~ ^(GIT_AUTHOR_NAME|GIT_AUTHOR_EMAIL|GPG_KEY_ID|AUR_SSH_KEY)=(.*)$ ]] &&
      value=$(_config_value "${BASH_REMATCH[2]}"); then
      printf -v "${BASH_REMATCH[1]}" '%s' "$value"
      continue
    fi
    echo "$config: line $n is not NAME='value' for GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GPG_KEY_ID or AUR_SSH_KEY" >&2
    return 1
  done <"$config"
}
