#!/usr/bin/env bash
#
# setup.sh - First-time aurtomator configuration
#
# Usage:
#   ./scripts/setup.sh              # full setup (all steps)
#   ./scripts/setup.sh identity     # git author name/email only
#   ./scripts/setup.sh ssh          # SSH key for AUR only
#   ./scripts/setup.sh gpg          # GPG signing key only
#   ./scripts/setup.sh secrets      # GitHub Secrets only
#   ./scripts/setup.sh verify       # verify everything works
#
# Options:
#   --git-name <name>         Git author name for AUR commits
#   --git-email <email>       Git author email for AUR commits
#   --gpg-key <id>            Use this GPG key (skip prompt)
#   --ssh-key <path>          Use this SSH key (skip prompt)
#   --non-interactive         No prompts, fail if missing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AURTOMATOR_DIR="${AURTOMATOR_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONFIG_FILE="${AURTOMATOR_DIR}/.aurtomator.conf"

# Defaults
GIT_AUTHOR_NAME=""
GIT_AUTHOR_EMAIL=""
GPG_KEY_ID=""
GPG_CLEAN_KEY=""
AUR_SSH_KEY=""
NON_INTERACTIVE=false
STEPS=()

# Colors (if terminal)
if [[ -t 1 ]]; then
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  RED=$'\033[0;31m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  GREEN="" YELLOW="" RED="" BOLD="" RESET=""
fi

ok() { printf "  %s✓%s %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "  %s!%s %s\n" "$YELLOW" "$RESET" "$*"; }
fail() { printf "  %s✗%s %s\n" "$RED" "$RESET" "$*"; }
header() { printf "\n%s[%s]%s %s\n\n" "$BOLD" "$1" "$RESET" "$2"; }

ask() {
  local prompt="$1"
  local has_default=false
  local default=""
  if [[ $# -ge 2 ]]; then
    has_default=true
    default="$2"
  fi
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ "$has_default" == "true" ]]; then
      echo "$default"
      return
    fi
    fail "No default for: $prompt (--non-interactive mode)" >&2
    exit 1
  fi
  local reply
  if [[ -n "$default" ]]; then
    read -rp "  $prompt [$default]: " reply
    echo "${reply:-$default}"
  else
    read -rp "  $prompt: " reply
    echo "$reply"
  fi
}

# =============================================================================
# LOAD / SAVE CONFIG
# =============================================================================

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi
}

# load_config sources the file, so each value is written shell-quoted
save_config() {
  {
    printf 'GIT_AUTHOR_NAME=%s\n' "${GIT_AUTHOR_NAME@Q}"
    printf 'GIT_AUTHOR_EMAIL=%s\n' "${GIT_AUTHOR_EMAIL@Q}"
    printf 'GPG_KEY_ID=%s\n' "${GPG_KEY_ID@Q}"
    printf 'AUR_SSH_KEY=%s\n' "${AUR_SSH_KEY@Q}"
  } >"$CONFIG_FILE"
}

# =============================================================================
# STEPS
# =============================================================================

setup_identity() {
  header "identity" "Who you are on AUR"

  # Detect defaults from git config
  local default_name default_email
  default_name=$(git config --global user.name 2>/dev/null || true)
  default_email=$(git config --global user.email 2>/dev/null || true)

  # Use saved values if available, otherwise detected defaults
  if [[ -z "$GIT_AUTHOR_NAME" ]]; then
    printf "  AUR git commits need an author name and email.\n"
    printf "  This appears in %sgit log%s on your AUR package repos.\n\n" "$BOLD" "$RESET"
    GIT_AUTHOR_NAME=$(ask "Git author name" "${default_name:-}")
  fi

  if [[ -z "$GIT_AUTHOR_EMAIL" ]]; then
    GIT_AUTHOR_EMAIL=$(ask "Git author email" "${default_email:-}")
  fi

  # Validate
  if [[ -z "$GIT_AUTHOR_NAME" ]]; then
    fail "Git author name is required"
    return 1
  fi
  if [[ -z "$GIT_AUTHOR_EMAIL" || "$GIT_AUTHOR_EMAIL" != *@* ]]; then
    fail "Valid email is required (must contain @)"
    return 1
  fi

  ok "Git author: $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>"
}

# Returns: 0 when AUR_SSH_KEY is a private key without a passphrase, which
#          CI can use, 1 otherwise, with the reason and the fix printed
check_ssh_key() {
  if [[ ! -f "$AUR_SSH_KEY" ]]; then
    fail "SSH key not found: $AUR_SSH_KEY"
    printf "\n  Generate one:\n"
    printf "    ssh-keygen -t ed25519 -f %s -C \"aurtomator@aur\"\n\n" "$AUR_SSH_KEY"
    return 1
  fi

  # Check that it is a private key
  local key_check
  key_check=$(ssh-keygen -y -f "$AUR_SSH_KEY" -P "" 2>&1) || true
  if [[ "$key_check" == ssh-* ]]; then
    return 0
  elif echo "$key_check" | grep -qi "incorrect passphrase"; then
    fail "SSH key has a passphrase: $AUR_SSH_KEY"
    printf "\n  CI uses the key without a prompt. Remove the passphrase from a copy:\n"
    printf "    cp %s %s-ci\n" "$AUR_SSH_KEY" "$AUR_SSH_KEY"
    printf "    ssh-keygen -p -N '' -f %s-ci\n" "$AUR_SSH_KEY"
    printf "    ./scripts/setup.sh ssh --ssh-key %s-ci\n\n" "$AUR_SSH_KEY"
    return 1
  else
    fail "Not a valid private key: $AUR_SSH_KEY"
    return 1
  fi
}

setup_ssh() {
  header "ssh" "SSH key for aur.archlinux.org"

  if [[ -z "$AUR_SSH_KEY" ]]; then
    AUR_SSH_KEY=$(ask "Path to SSH private key for AUR" "$HOME/.ssh/aur_ed25519")
  fi
  # Expand ~/ to the home dir. ~user/ stays as it is.
  AUR_SSH_KEY="${AUR_SSH_KEY/#\~\//$HOME/}"

  check_ssh_key || return 1
  ok "SSH key: $AUR_SSH_KEY"

  local pubkey="${AUR_SSH_KEY}.pub"
  if [[ -f "$pubkey" ]]; then
    printf "\n  Public key (ensure it is added to https://aur.archlinux.org → My Account → SSH Public Key):\n"
    printf "    %s\n" "$(cat "$pubkey")"
  fi
}

# Flush the agent cache, then sign without pinentry. Signing fails when the
# key has a passphrase.
# Args: $1=key id
gpg_key_has_passphrase() {
  gpgconf --kill gpg-agent 2>/dev/null || true
  ! echo "test" | gpg --batch --pinentry-mode error --sign --local-user "$1" >/dev/null 2>&1
}

# A key ID, long or short, or a fingerprint names the primary key when the
# fingerprint of the primary key ends with it
# Args: $1=key id
gpg_is_primary_key() {
  local id="${1#0x}" fpr
  fpr=$(gpg --list-secret-keys --with-colons "$1" 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10; exit }')
  [[ -n "$fpr" && "${fpr^^}" == *"${id^^}" ]]
}

# The temporary keyring of setup_gpg holds the signing subkey without a
# passphrase once gpg-agent has removed it. setup_gpg sets this function as
# the EXIT trap, so Ctrl-C or a closed terminal does not leave it on disk.
TMP_GNUPG=""
remove_tmp_gnupg() {
  [[ -n "$TMP_GNUPG" ]] || return 0
  gpgconf --homedir "$TMP_GNUPG" --kill gpg-agent 2>/dev/null || true
  rm -rf "$TMP_GNUPG"
  TMP_GNUPG=""
}

setup_gpg() {
  header "gpg" "Sign AUR commits with GPG (optional)"

  # Yes/no gate: skip unless the user wants GPG or passed --gpg-key
  if [[ -z "$GPG_KEY_ID" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      ok "GPG signing skipped (no --gpg-key provided)"
      return 0
    fi
    local enable_gpg
    enable_gpg=$(ask "Enable GPG commit signing? (y/N)")
    if [[ "$enable_gpg" != "y" && "$enable_gpg" != "Y" ]]; then
      ok "GPG signing skipped"
      return 0
    fi

    printf "\n  Recommended: use a dedicated signing subkey:\n"
    printf "    gpg --quick-add-key <fingerprint> ed25519 sign 1y\n\n"

    GPG_KEY_ID=$(ask "Enter GPG key ID")
  fi

  if [[ -z "$GPG_KEY_ID" ]]; then
    ok "GPG signing skipped"
    return 0
  fi

  # Validate key exists
  local key_info
  if ! key_info=$(gpg --list-secret-keys --keyid-format long "$GPG_KEY_ID" 2>/dev/null); then
    fail "Key not found in keyring: $GPG_KEY_ID"
    return 1
  fi

  if ! echo "$key_info" | grep -q '\[S'; then
    warn "Key may not have signing capability, verify manually"
  fi

  # CI gets the signing subkey alone. The primary key certifies the others
  # and never leaves this machine.
  if gpg_is_primary_key "$GPG_KEY_ID"; then
    fail "$GPG_KEY_ID is a primary key. CI signs with a signing subkey."
    printf "\n  Create a signing subkey and pass its ID:\n"
    printf "    gpg --quick-add-key <fingerprint> ed25519 sign 1y\n\n"
    return 1
  fi

  if ! gpg_key_has_passphrase "$GPG_KEY_ID"; then
    ok "GPG key: $GPG_KEY_ID (no passphrase, ready for CI)"
  else
    warn "This key has a passphrase. CI (GitHub Actions) requires a passphrase-free key."
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      warn "Cannot remove passphrase in non-interactive mode. Skipping GPG."
      GPG_KEY_ID=""
      return 0
    fi
    printf "\n  Create a passphrase-free copy for CI? Your original key stays unchanged.\n\n"
    printf "  Three pinentry dialogs will open:\n"
    printf "    %s1st%s: current passphrase (to export the key)\n" "$BOLD" "$RESET"
    printf "    %s2nd%s: current passphrase again (isolated copy, separate keyring)\n" "$BOLD" "$RESET"
    printf "    %s3rd%s: leave empty, press OK (set no passphrase for CI)\n\n" "$BOLD" "$RESET"
    local strip
    strip=$(ask "Proceed? (Y/n)")
    if [[ "$strip" == "n" || "$strip" == "N" ]]; then
      warn "GPG signing will fail in CI. Continuing without GPG."
      GPG_KEY_ID=""
      return 0
    fi

    # Strip passphrase via temp keyring (only the signing subkey, not all subkeys)
    TMP_GNUPG=$(mktemp -d)
    trap remove_tmp_gnupg EXIT
    chmod 700 "$TMP_GNUPG"
    echo "pinentry-program /usr/bin/pinentry" >"$TMP_GNUPG/gpg-agent.conf"

    # Export ONLY the signing subkey (! suffix = exact key) from real keyring
    # Pinentry will ask for passphrase once
    local exported_key
    exported_key=$(gpg --export-secret-subkeys --armor "${GPG_KEY_ID}!" 2>/dev/null) || true
    if [[ -z "$exported_key" ]]; then
      fail "Failed to export key (wrong passphrase or cancelled)"
      remove_tmp_gnupg
      GPG_KEY_ID=""
      return 0
    fi

    # Import into temp keyring
    if ! echo "$exported_key" | gpg --homedir "$TMP_GNUPG" --batch --import 2>/dev/null; then
      fail "Failed to import key into temporary keyring"
      remove_tmp_gnupg
      GPG_KEY_ID=""
      return 0
    fi

    # Remove passphrase via gpg-agent in isolated temp keyring
    local keygrip
    keygrip=$(gpg --homedir "$TMP_GNUPG" --list-secret-keys --with-keygrip 2>/dev/null |
      grep -A1 "\[S\]" | grep Keygrip | awk '{print $3}' || true)

    if [[ -z "$keygrip" ]]; then
      fail "Could not determine keygrip for signing subkey"
      remove_tmp_gnupg
      GPG_KEY_ID=""
      return 0
    fi

    local passwd_out passwd_rc=0
    passwd_out=$(gpg-connect-agent --homedir "$TMP_GNUPG" "PASSWD $keygrip" /bye 2>&1) || passwd_rc=$?
    if [[ "$passwd_rc" -ne 0 ]] || [[ "$passwd_out" == *"ERR"* ]]; then
      fail "Failed to remove passphrase (cancelled or timed out)"
      remove_tmp_gnupg
      GPG_KEY_ID=""
      return 0
    fi

    # Export the clean key for the secrets step
    GPG_CLEAN_KEY=$(gpg --homedir "$TMP_GNUPG" --batch --pinentry-mode loopback \
      --passphrase "" --export-secret-subkeys --armor "${GPG_KEY_ID}!" 2>/dev/null) || true
    remove_tmp_gnupg

    if [[ -z "$GPG_CLEAN_KEY" ]]; then
      fail "Failed to export passphrase-free key"
      GPG_KEY_ID=""
      return 0
    fi

    ok "GPG key: $GPG_KEY_ID (passphrase-free copy created for CI)"
  fi
}

setup_secrets() {
  header "secrets" "GitHub Secrets"

  # The ssh step is not run when secrets runs alone or with a saved config
  check_ssh_key || return 1

  local has_gh=false
  if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    has_gh=true
    local gh_user
    gh_user=$(gh api user --jq '.login' 2>/dev/null || echo "unknown")
    ok "gh CLI authenticated ($gh_user)"
  else
    warn "gh CLI not available or not authenticated"
    warn "Set the secrets manually"
  fi

  # GPG_SIGNING_KEY holds the passphrase-free copy made by the gpg step of
  # this run, or the key itself when it has no passphrase
  local gpg_source=""
  if [[ -n "$GPG_KEY_ID" ]]; then
    if [[ -n "$GPG_CLEAN_KEY" ]]; then
      gpg_source="copy"
    elif gpg_key_has_passphrase "$GPG_KEY_ID"; then
      warn "GPG key $GPG_KEY_ID has a passphrase, GPG_SIGNING_KEY not set"
      warn "Run ./scripts/setup.sh gpg secrets to make a passphrase-free copy"
    else
      gpg_source="key"
    fi
  fi

  if [[ "$has_gh" == "true" ]]; then
    # Detect repo from origin remote (not upstream)
    local gh_repo
    gh_repo=$(git -C "$AURTOMATOR_DIR" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||; s|\.git$||' || true)
    if [[ -z "$gh_repo" ]]; then
      gh_repo=$(ask "GitHub repo (owner/name)")
    fi
    ok "Target repo: $gh_repo"

    printf "\n  Setting secrets on %s:\n" "$gh_repo"

    # Identity secrets (for CI to use as AUR commit author)
    if [[ -n "$GIT_AUTHOR_NAME" ]]; then
      if echo "$GIT_AUTHOR_NAME" | gh secret set AUR_GIT_NAME -R "$gh_repo"; then
        ok "AUR_GIT_NAME"
      else
        fail "AUR_GIT_NAME"
      fi
    fi

    if [[ -n "$GIT_AUTHOR_EMAIL" ]]; then
      if echo "$GIT_AUTHOR_EMAIL" | gh secret set AUR_GIT_EMAIL -R "$gh_repo"; then
        ok "AUR_GIT_EMAIL"
      else
        fail "AUR_GIT_EMAIL"
      fi
    fi

    if gh secret set AUR_SSH_KEY -R "$gh_repo" <"$AUR_SSH_KEY"; then
      ok "AUR_SSH_KEY"
    else
      fail "AUR_SSH_KEY"
    fi

    if [[ "$gpg_source" == "copy" ]]; then
      if echo "$GPG_CLEAN_KEY" | gh secret set GPG_SIGNING_KEY -R "$gh_repo"; then
        ok "GPG_SIGNING_KEY (passphrase-free copy)"
      else
        fail "GPG_SIGNING_KEY"
      fi
    elif [[ "$gpg_source" == "key" ]]; then
      # "!" exports this subkey alone, without the other secret subkeys
      local signing_key
      signing_key=$(gpg --export-secret-subkeys --armor "${GPG_KEY_ID}!" 2>/dev/null) || signing_key=""
      if [[ -n "$signing_key" ]] && echo "$signing_key" | gh secret set GPG_SIGNING_KEY -R "$gh_repo"; then
        ok "GPG_SIGNING_KEY"
      else
        fail "GPG_SIGNING_KEY"
      fi
    fi
  else
    printf "\n  Set these secrets in GitHub → Settings → Secrets and variables → Actions:\n\n"

    printf "  %sAUR_GIT_NAME%s\n" "$BOLD" "$RESET"
    printf "    Value: %s\n\n" "$GIT_AUTHOR_NAME"

    printf "  %sAUR_GIT_EMAIL%s\n" "$BOLD" "$RESET"
    printf "    Value: %s\n\n" "$GIT_AUTHOR_EMAIL"

    printf "  %sAUR_SSH_KEY%s\n" "$BOLD" "$RESET"
    printf "    Contents of: %s\n\n" "$AUR_SSH_KEY"

    if [[ "$gpg_source" == "copy" ]]; then
      printf "  %sGPG_SIGNING_KEY%s\n" "$BOLD" "$RESET"
      printf "    Value, the passphrase-free copy, BEGIN and END lines included:\n\n"
      printf "%s\n\n" "$GPG_CLEAN_KEY"
    elif [[ "$gpg_source" == "key" ]]; then
      printf "  %sGPG_SIGNING_KEY%s\n" "$BOLD" "$RESET"
      printf "    Run: gpg --export-secret-subkeys --armor '%s!'\n\n" "$GPG_KEY_ID"
    fi
  fi
}

verify_all() {
  header "verify" "Checking everything works"

  local errors=0

  # Identity
  if [[ -n "$GIT_AUTHOR_NAME" && -n "$GIT_AUTHOR_EMAIL" ]]; then
    ok "Identity: $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>"
  else
    fail "Identity: git author name/email not configured"
    errors=$((errors + 1))
  fi

  # SSH (AUR returns exit 1 even on success, so check output for "Welcome")
  local ssh_out
  ssh_out=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -i "$AUR_SSH_KEY" aur@aur.archlinux.org 2>&1 || true)
  if echo "$ssh_out" | grep -qi "welcome"; then
    ok "SSH: aur.archlinux.org accessible"
  else
    fail "SSH: cannot connect to aur.archlinux.org"
    errors=$((errors + 1))
  fi

  # GPG (only if configured)
  if [[ -n "$GPG_KEY_ID" ]]; then
    if echo "test" | gpg --sign --armor --local-user "$GPG_KEY_ID" >/dev/null 2>&1; then
      ok "GPG: signing works with $GPG_KEY_ID"
    else
      fail "GPG: cannot sign with $GPG_KEY_ID"
      errors=$((errors + 1))
    fi
  else
    ok "GPG: skipped (not configured)"
  fi

  # Secrets
  if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    local gh_repo
    gh_repo=$(git -C "$AURTOMATOR_DIR" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||; s|\.git$||' || true)
    local secret_list
    secret_list=$(gh secret list -R "$gh_repo" 2>/dev/null || true)
    local secret_count=0
    local secret_expected=3 # AUR_SSH_KEY + AUR_GIT_NAME + AUR_GIT_EMAIL
    echo "$secret_list" | grep -q "AUR_SSH_KEY" && ((secret_count++)) || true
    echo "$secret_list" | grep -q "AUR_GIT_NAME" && ((secret_count++)) || true
    echo "$secret_list" | grep -q "AUR_GIT_EMAIL" && ((secret_count++)) || true
    if [[ -n "$GPG_KEY_ID" ]]; then
      ((secret_expected++))
      echo "$secret_list" | grep -q "GPG_SIGNING_KEY" && ((secret_count++)) || true
    fi
    if [[ "$secret_count" -eq "$secret_expected" ]]; then
      ok "Secrets: ${secret_count}/${secret_expected} configured"
    else
      warn "Secrets: ${secret_count}/${secret_expected} configured"
      errors=$((errors + 1))
    fi
  else
    warn "Secrets: cannot verify (gh not available)"
  fi

  if [[ "$errors" -eq 0 ]]; then
    printf "\n  %s%sReady.%s Add your first package:\n" "$GREEN" "$BOLD" "$RESET"
    printf "    cp packages/example.yml.sample packages/<name>.yml\n\n"
  else
    printf "\n  %s%s%d issue(s) found.%s Fix and re-run:\n" "$YELLOW" "$BOLD" "$errors" "$RESET"
    printf "    ./scripts/setup.sh verify\n\n"
    return 1
  fi
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

# Saved values first, so that flags override them
load_config

while [[ $# -gt 0 ]]; do
  case "$1" in
    identity | ssh | gpg | secrets | verify)
      STEPS+=("$1")
      shift
      ;;
    --git-name)
      GIT_AUTHOR_NAME="$2"
      shift 2
      ;;
    --git-email)
      GIT_AUTHOR_EMAIL="$2"
      shift 2
      ;;
    --gpg-key)
      GPG_KEY_ID="$2"
      shift 2
      ;;
    --ssh-key)
      AUR_SSH_KEY="$2"
      shift 2
      ;;
    --non-interactive)
      NON_INTERACTIVE=true
      shift
      ;;
    -h | --help)
      sed -n '3,18p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1 (see ./scripts/setup.sh --help)" >&2
      exit 1
      ;;
  esac
done

# Default: all steps
if [[ ${#STEPS[@]} -eq 0 ]]; then
  STEPS=(identity ssh gpg secrets verify)
fi

# =============================================================================
# MAIN
# =============================================================================

printf "%saurtomator setup%s\n" "$BOLD" "$RESET"

# Each step is saved as soon as it ends, so a step that fails keeps the
# answers given before it. A failed verify still saves the config, so the
# re-run it suggests has the values of this run.
EXIT_STATUS=0
for step in "${STEPS[@]}"; do
  case "$step" in
    identity) setup_identity ;;
    ssh) setup_ssh ;;
    gpg) setup_gpg ;;
    secrets) setup_secrets ;;
    verify) verify_all || EXIT_STATUS=1 ;;
  esac
  save_config
done
ok "Config saved to .aurtomator.conf"
exit "$EXIT_STATUS"
