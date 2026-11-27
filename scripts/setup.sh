#!/usr/bin/env bash
#
# setup.sh - First-time aurtomator configuration
#
# Usage, in your packages repository:
#   ./aurtomator.sh setup              # full setup (all steps)
#   ./aurtomator.sh setup identity     # git author name/email only
#   ./aurtomator.sh setup ssh          # SSH key for AUR only
#   ./aurtomator.sh setup gpg          # GPG signing key only
#   ./aurtomator.sh setup secrets      # GitHub Secrets only
#   ./aurtomator.sh setup verify       # verify everything works
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
# shellcheck source=lib/version.sh
source "$SCRIPT_DIR/lib/version.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

# The printed commands start with this; aurtomator.sh of the template sets
# AURTOMATOR_RUNNER to the path it was run by
SETUP_CMD="$0"
if [[ -n "${AURTOMATOR_RUNNER:-}" ]]; then
  SETUP_CMD="$AURTOMATOR_RUNNER setup"
fi

# Resolves AURTOMATOR_DATA_DIR as lib/common.sh does, which this script does not
# source; it sets the variable last, so the error names the value as given
resolve_data_dir() {
  local dir
  if ! dir="$(cd -- "${AURTOMATOR_DATA_DIR:-.}" 2>/dev/null && pwd)"; then
    echo "AURTOMATOR_DATA_DIR is not a directory: ${AURTOMATOR_DATA_DIR}" >&2
    exit 1
  fi
  AURTOMATOR_DATA_DIR="$dir"
}
resolve_data_dir
CONFIG_FILE="${AURTOMATOR_DATA_DIR}/.aurtomator.conf"

GIT_AUTHOR_NAME=""
GIT_AUTHOR_EMAIL=""
GPG_KEY_ID=""
GPG_CLEAN_KEY=""
AUR_SSH_KEY=""
NON_INTERACTIVE=false
STEPS=()

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

# Prints the key path $1 with ~/ expanded and made absolute, so the saved
# path works from any directory. ~user/ stays as it is.
key_path() {
  local path="${1/#\~\//$HOME/}"
  [[ "$path" == /* || "$path" == \~* ]] || path="$PWD/$path"
  printf '%s\n' "$path"
}

# Prints owner/repo of the origin remote of the data directory when it is a
# repository on github.com, and nothing otherwise
origin_repo() {
  local url
  url=$(git -C "$AURTOMATOR_DATA_DIR" remote get-url origin 2>/dev/null) || return 0
  url="${url%/}"
  url="${url%.git}"
  if [[ "$url" =~ ^(https://|ssh://git@|git@)github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}

# load_config of lib/config.sh reads each value in this form
save_config() {
  local name value
  for name in GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GPG_KEY_ID AUR_SSH_KEY; do
    if [[ "${!name}" == *[[:cntrl:]]* ]]; then
      fail "$name holds a control character, which .aurtomator.conf cannot keep"
      return 1
    fi
    # load_config reads no line with a byte that is no UTF-8 under a UTF-8 locale
    if ! printf '%s' "${!name}" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
      fail "$name holds a byte that is no UTF-8, which .aurtomator.conf cannot keep"
      return 1
    fi
  done
  # Single quotes in every locale, since ${value@Q} writes $'...' for some values
  for name in GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GPG_KEY_ID AUR_SSH_KEY; do
    value="${!name}"
    printf "%s='%s'\n" "$name" "${value//\'/\'\\\'\'}"
  done >"$CONFIG_FILE"
}

setup_identity() {
  header "identity" "Who you are on AUR"
  printf "  Data directory: %s\n" "$AURTOMATOR_DATA_DIR"

  local default_name default_email
  default_name=$(git config --global user.name 2>/dev/null || true)
  default_email=$(git config --global user.email 2>/dev/null || true)

  # Saved values and flags skip the question, which offers git config as the default
  if [[ -z "$GIT_AUTHOR_NAME" ]]; then
    printf "  AUR git commits need an author name and email.\n"
    printf "  This appears in %sgit log%s on your AUR package repos.\n\n" "$BOLD" "$RESET"
    GIT_AUTHOR_NAME=$(ask "Git author name" "${default_name:-}")
  fi

  if [[ -z "$GIT_AUTHOR_EMAIL" ]]; then
    GIT_AUTHOR_EMAIL=$(ask "Git author email" "${default_email:-}")
  fi

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

  # ssh-keygen -y prints the public key only for a private key it opens without a passphrase.
  # Keys of the sk- types sign only with their security key, which CI does not have.
  local key_check key_rc=0
  key_check=$(ssh-keygen -y -f "$AUR_SSH_KEY" -P "" 2>&1) || key_rc=$?
  if ((key_rc == 0)) && [[ "$key_check" == sk-* ]]; then
    fail "SSH key needs a security key, which CI does not have: $AUR_SSH_KEY"
    return 1
  elif ((key_rc == 0)); then
    return 0
  elif echo "$key_check" | grep -qi "incorrect passphrase"; then
    fail "SSH key has a passphrase: $AUR_SSH_KEY"
    printf "\n  CI uses the key without a prompt. Remove the passphrase from a copy:\n"
    printf "    cp %s %s-ci\n" "$AUR_SSH_KEY" "$AUR_SSH_KEY"
    printf "    ssh-keygen -p -N '' -f %s-ci\n" "$AUR_SSH_KEY"
    printf "    %s ssh --ssh-key %s-ci\n\n" "$SETUP_CMD" "$AUR_SSH_KEY"
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
  AUR_SSH_KEY=$(key_path "$AUR_SSH_KEY")

  check_ssh_key || return 1
  ok "SSH key: $AUR_SSH_KEY"

  local pubkey="${AUR_SSH_KEY}.pub"
  if [[ -f "$pubkey" ]]; then
    printf "\n  Public key (ensure it is added to https://aur.archlinux.org → My Account → SSH Public Key):\n"
    printf "    %s\n" "$(cat "$pubkey")"
  fi
}

# Signs with subkey $1 alone, as ! asks, without pinentry and after a flush of the agent cache:
# signing fails when the subkey has a passphrase
gpg_key_has_passphrase() {
  gpgconf --kill gpg-agent 2>/dev/null || true
  ! echo "test" | gpg --batch --pinentry-mode error --sign --local-user "$1!" >/dev/null 2>&1
}

# Succeeds when the subkey of ID $1 can sign: gpg lists the whole key for the ID of any subkey, so
# the record of that subkey, found as in gpg_is_primary_key, has to hold the capability s
gpg_key_can_sign() {
  gpg --list-secret-keys --with-colons "$1" 2>/dev/null | awk -F: -v id="$1" '
    $1 == "sec" || $1 == "ssb" { caps = $12; key = 1; next }
    $1 == "fpr" && key {
      key = 0
      fpr = toupper($10)
      if (length(fpr) == 64) named = index(fpr, id) == 1
      else named = substr(fpr, length(fpr) - length(id) + 1) == id
      if (named && caps ~ /s/) found = 1
    }
    END { exit !found }'
}

# Succeeds when the export on stdin holds the secret of one subkey and no other secret: an export of
# subkeys holds the primary key as gnu-dummy, which is the key without its secret
gpg_export_is_subkey() {
  gpg --batch --list-packets 2>/dev/null | awk '
    function close_packet() {
      if (packet != "" && !dummy) secrets[packet]++
      packet = ""
      dummy = 0
    }
    /^:/ { close_packet() }
    /^:secret key packet:/ { packet = "key" }
    /^:secret sub key packet:/ { packet = "sub" }
    packet != "" && /gnu-dummy/ { dummy = 1 }
    END { close_packet(); exit !(secrets["sub"] == 1 && secrets["key"] == 0) }'
}

# Key IDs, long or short, and fingerprints name the primary key when the fingerprint of the
# primary key ends with them, or starts with them for v5 keys, whose fingerprints have 64 digits
# Args: $1=key id
gpg_is_primary_key() {
  local id="${1#0x}" fpr
  fpr=$(gpg --list-secret-keys --with-colons "$1" 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10; exit }')
  fpr=${fpr^^}
  id=${id^^}
  [[ -n "$fpr" ]] || return 1
  if ((${#fpr} == 64)); then
    [[ "$fpr" == "$id"* ]]
  else
    [[ "$fpr" == *"$id" ]]
  fi
}

# gpg also takes e-mail addresses, names and IDs with !, which can select the primary key
# Args: $1=key id. Prints its hex digits in upper case, without spaces and 0x
gpg_key_id() {
  local id="${1//[[:space:]]/}"
  id=${id#0[xX]}
  id=${id^^}
  [[ "$id" =~ ^([0-9A-F]{8}|[0-9A-F]{16}|[0-9A-F]{40}|[0-9A-F]{64})$ ]] || return 1
  printf '%s\n' "$id"
}

# The temporary keyring holds the signing subkey without a passphrase; setup_gpg
# sets this as the EXIT trap, so Ctrl-C or a closed terminal does not leave it
TMP_GNUPG=""
remove_tmp_gnupg() {
  [[ -n "$TMP_GNUPG" ]] || return 0
  gpgconf --homedir "$TMP_GNUPG" --kill gpg-agent 2>/dev/null || true
  rm -rf "$TMP_GNUPG"
  TMP_GNUPG=""
}

# Fails with a message unless GPG_KEY_ID names a signing subkey of the keyring, and writes the ID back
# in the form of gpg_key_id
check_gpg_key() {
  local key_id
  if ! key_id=$(gpg_key_id "$GPG_KEY_ID"); then
    fail "$GPG_KEY_ID is no key ID or fingerprint in hex"
    printf "\n  Pass the ID of the signing subkey, the ssb line with [S] in:\n"
    printf "    gpg --list-secret-keys --keyid-format long\n\n"
    return 1
  fi
  GPG_KEY_ID=$key_id

  if ! gpg --list-secret-keys "$GPG_KEY_ID" >/dev/null 2>&1; then
    fail "Key not found in keyring: $GPG_KEY_ID"
    return 1
  fi

  # CI gets the signing subkey alone. The primary key certifies the others
  # and never leaves this machine.
  if gpg_is_primary_key "$GPG_KEY_ID"; then
    fail "$GPG_KEY_ID is a primary key. CI signs with a signing subkey."
    printf "\n  Create a signing subkey and pass its ID:\n"
    printf "    gpg --quick-add-key <fingerprint> ed25519 sign 1y\n\n"
    return 1
  fi

  if ! gpg_key_can_sign "$GPG_KEY_ID"; then
    fail "$GPG_KEY_ID cannot sign: gpg lists no signing flag [S] for this subkey"
    printf "\n  Pass the ID of the signing subkey, the ssb line with [S] in:\n"
    printf "    gpg --list-secret-keys --keyid-format long\n\n"
    return 1
  fi
}

setup_gpg() {
  header "gpg" "Sign AUR commits with GPG (optional)"

  # Without a key from --gpg-key or the saved config, GPG signing is opt-in
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

  check_gpg_key || return 1

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

    # Passphrase removal runs in a temporary keyring with the signing subkey alone. Its agent asks
    # with the pinentry that gpg-agent.conf of the user names, as the first dialog does.
    TMP_GNUPG=$(mktemp -d)
    trap remove_tmp_gnupg EXIT
    chmod 700 "$TMP_GNUPG"
    local pinentry
    pinentry=$(awk '$1 == "pinentry-program" { sub(/^[ \t]*pinentry-program[ \t]+/, ""); p = $0 } END { print p }' \
      "${GNUPGHOME:-$HOME/.gnupg}/gpg-agent.conf" 2>/dev/null) || pinentry=""
    echo "pinentry-program ${pinentry:-/usr/bin/pinentry}" >"$TMP_GNUPG/gpg-agent.conf"

    # The ! suffix exports this subkey alone; pinentry asks for its passphrase
    local exported_key
    exported_key=$(gpg --export-secret-subkeys --armor "${GPG_KEY_ID}!" 2>/dev/null) || true
    if [[ -z "$exported_key" ]]; then
      fail "Failed to export key (wrong passphrase or cancelled)"
      remove_tmp_gnupg
      GPG_KEY_ID=""
      return 0
    fi

    if ! echo "$exported_key" | gpg --homedir "$TMP_GNUPG" --batch --import 2>/dev/null; then
      fail "Failed to import key into temporary keyring"
      remove_tmp_gnupg
      GPG_KEY_ID=""
      return 0
    fi

    # PASSWD of gpg-agent takes the keygrip of the signing subkey
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
    if ! gpg_export_is_subkey <<<"$GPG_CLEAN_KEY"; then
      fail "The passphrase-free copy is not the secret of subkey $GPG_KEY_ID alone"
      GPG_CLEAN_KEY=""
      GPG_KEY_ID=""
      return 0
    fi

    ok "GPG key: $GPG_KEY_ID (passphrase-free copy created for CI)"
  fi
}

setup_secrets() {
  header "secrets" "GitHub Secrets"

  # secrets can run without the ssh and gpg steps, so the saved keys are checked here too
  check_ssh_key || return 1
  if [[ -n "$GPG_KEY_ID" ]]; then
    check_gpg_key || return 1
  fi

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
      warn "Run $SETUP_CMD gpg secrets to make a passphrase-free copy"
    else
      gpg_source="key"
    fi
  fi

  if [[ "$has_gh" == "true" ]]; then
    local gh_repo
    gh_repo=$(origin_repo)
    if [[ -z "$gh_repo" ]]; then
      gh_repo=$(ask "GitHub repo (owner/name)")
    fi
    ok "Target repo: $gh_repo"
    [[ -z "$GIT_AUTHOR_NAME" ]] || printf "  AUR_GIT_NAME: %s\n" "$GIT_AUTHOR_NAME"
    [[ -z "$GIT_AUTHOR_EMAIL" ]] || printf "  AUR_GIT_EMAIL: %s\n" "$GIT_AUTHOR_EMAIL"
    printf "  AUR_SSH_KEY: the key in %s\n" "$(realpath -- "$AUR_SSH_KEY")"
    [[ -z "$gpg_source" ]] || printf "  GPG_SIGNING_KEY: GPG key %s\n" "$GPG_KEY_ID"

    # The secrets hold the key that pushes every package of the user
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
      local set_secrets
      set_secrets=$(ask "Set the secrets on $gh_repo? (Y/n)")
      if [[ "$set_secrets" == "n" || "$set_secrets" == "N" ]]; then
        fail "Secrets not set on $gh_repo"
        return 1
      fi
    fi

    printf "\n  Setting secrets on %s:\n" "$gh_repo"

    # gh prints a line for each secret on stdout and its errors on stderr
    local failed=false
    if [[ -n "$GIT_AUTHOR_NAME" ]]; then
      if echo "$GIT_AUTHOR_NAME" | gh secret set AUR_GIT_NAME -R "$gh_repo" >/dev/null; then
        ok "AUR_GIT_NAME"
      else
        fail "AUR_GIT_NAME"
        failed=true
      fi
    fi

    if [[ -n "$GIT_AUTHOR_EMAIL" ]]; then
      if echo "$GIT_AUTHOR_EMAIL" | gh secret set AUR_GIT_EMAIL -R "$gh_repo" >/dev/null; then
        ok "AUR_GIT_EMAIL"
      else
        fail "AUR_GIT_EMAIL"
        failed=true
      fi
    fi

    if gh secret set AUR_SSH_KEY -R "$gh_repo" <"$AUR_SSH_KEY" >/dev/null; then
      ok "AUR_SSH_KEY"
    else
      fail "AUR_SSH_KEY"
      failed=true
    fi

    if [[ "$gpg_source" == "copy" ]]; then
      if echo "$GPG_CLEAN_KEY" | gh secret set GPG_SIGNING_KEY -R "$gh_repo" >/dev/null; then
        ok "GPG_SIGNING_KEY (passphrase-free copy)"
      else
        fail "GPG_SIGNING_KEY"
        failed=true
      fi
    elif [[ "$gpg_source" == "key" ]]; then
      # "!" exports this subkey alone, without the other secret subkeys
      local signing_key
      signing_key=$(gpg --export-secret-subkeys --armor "${GPG_KEY_ID}!" 2>/dev/null) || signing_key=""
      if [[ -n "$signing_key" ]] && ! gpg_export_is_subkey <<<"$signing_key"; then
        fail "GPG_SIGNING_KEY: the export is not the secret of subkey $GPG_KEY_ID alone"
        failed=true
      elif [[ -n "$signing_key" ]] && echo "$signing_key" | gh secret set GPG_SIGNING_KEY -R "$gh_repo" >/dev/null; then
        ok "GPG_SIGNING_KEY"
      else
        fail "GPG_SIGNING_KEY"
        failed=true
      fi
    fi
    [[ "$failed" == false ]] || return 1
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

# Checks that repository $1 has Issues on, where the runs report failures and alerts
verify_issues() {
  local has_issues
  if ! has_issues=$(gh api "repos/$1" --jq .has_issues 2>/dev/null); then
    fail "Issues: cannot read the settings of $1"
    return 1
  fi
  if [[ "$has_issues" != true ]]; then
    fail "Issues: off, turn them on in Settings > General > Features"
    return 1
  fi
  ok "Issues: on"
}

# Checks that workflow $1 is active among the paths and states $2 that GitHub lists
verify_workflow() {
  local state
  state=$(awk -v path=".github/workflows/$1" '$1 == path { print $2 }' <<<"$2")
  case "$state" in
    active) ok "Workflow $1: active" ;;
    "")
      fail "Workflow $1: not in the repository"
      return 1
      ;;
    *)
      fail "Workflow $1: $state, click Enable workflow on its page in the Actions tab"
      return 1
      ;;
  esac
}

# Warns of an open issue of a failed run in repository $1, which the next run
# without a failed job closes
warn_run_issue() {
  local number
  # gh issue list --label searches, which stops at 1000 issues, and the REST list pages without a cap
  number=$(gh api "repos/$1/issues?labels=auto-update&state=open&per_page=100" --paginate --jq '.[] | select(.pull_request == null and .title == "❌ Check AUR Package Updates failed") | .number' 2>/dev/null) || true
  [[ -z "$number" ]] || warn "Run issue #${number%%$'\n'*} is open: a run without a failed job closes it"
}

# Compares the version of this aurtomator with its latest release
verify_release() {
  local version latest
  version=$(aurtomator_version)
  [[ -n "$version" ]] || return 0
  if ! latest=$(gh api "repos/$AURTOMATOR_UPSTREAM/releases/latest" --jq .tag_name 2>/dev/null); then
    warn "aurtomator: cannot read the latest release"
  elif [[ "$latest" == "v$version" ]]; then
    ok "aurtomator: $version, the latest release"
  else
    warn "aurtomator: $version, and the latest release is ${latest#v}"
  fi
}

# Succeeds when the lines of the secret list $1 name secret $2 in their first field: a name
# such as AUR_SSH_KEY_OLD holds the name of another secret
secret_listed() {
  awk -v name="$2" '$1 == name { found = 1 } END { exit !found }' <<<"$1"
}

verify_all() {
  header "verify" "Checking everything works"

  local errors=0

  if [[ -n "$GIT_AUTHOR_NAME" && -n "$GIT_AUTHOR_EMAIL" ]]; then
    ok "Identity: $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>"
  else
    fail "Identity: git author name/email not configured"
    errors=$((errors + 1))
  fi

  # The key alone, without the ssh config of this machine or an agent. AUR
  # returns exit 1 even on success, so check output for "Welcome".
  local ssh_out
  ssh_out=$(ssh -F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=5 -i "$AUR_SSH_KEY" aur@aur.archlinux.org 2>&1 || true)
  if echo "$ssh_out" | grep -qi "welcome"; then
    ok "SSH: aur.archlinux.org accessible"
  else
    fail "SSH: cannot connect to aur.archlinux.org"
    # The last line of ssh names the cause: a host key, the key or the network
    [[ -z "$ssh_out" ]] || printf "    %s\n" "$(tail -n 1 <<<"$ssh_out")"
    errors=$((errors + 1))
  fi

  if [[ -n "$GPG_KEY_ID" ]]; then
    if echo "test" | gpg --sign --armor --local-user "$GPG_KEY_ID!" >/dev/null 2>&1; then
      ok "GPG: signing works with $GPG_KEY_ID"
    else
      fail "GPG: cannot sign with $GPG_KEY_ID"
      errors=$((errors + 1))
    fi
  else
    ok "GPG: skipped (not configured)"
  fi

  # The repository on GitHub: its secrets, Issues and the two workflows
  if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    local gh_repo
    gh_repo=$(origin_repo)
    if [[ -z "$gh_repo" ]]; then
      fail "GitHub: the origin of $AURTOMATOR_DATA_DIR is not a github.com repository"
      errors=$((errors + 1))
    else
      local secret_list
      secret_list=$(gh secret list -R "$gh_repo" 2>/dev/null || true)
      local secret_count=0
      local secret_expected=3 # AUR_SSH_KEY + AUR_GIT_NAME + AUR_GIT_EMAIL
      secret_listed "$secret_list" AUR_SSH_KEY && ((secret_count++)) || true
      secret_listed "$secret_list" AUR_GIT_NAME && ((secret_count++)) || true
      secret_listed "$secret_list" AUR_GIT_EMAIL && ((secret_count++)) || true
      if [[ -n "$GPG_KEY_ID" ]]; then
        ((secret_expected++))
        secret_listed "$secret_list" GPG_SIGNING_KEY && ((secret_count++)) || true
      fi
      if [[ "$secret_count" -eq "$secret_expected" ]]; then
        ok "Secrets: ${secret_count}/${secret_expected} configured"
      else
        warn "Secrets: ${secret_count}/${secret_expected} configured"
        errors=$((errors + 1))
      fi

      verify_issues "$gh_repo" || errors=$((errors + 1))
      local workflows
      if workflows=$(gh api "repos/$gh_repo/actions/workflows" --jq '.workflows[] | "\(.path) \(.state)"' 2>/dev/null); then
        verify_workflow check-updates.yml "$workflows" || errors=$((errors + 1))
        verify_workflow validate.yml "$workflows" || errors=$((errors + 1))
      else
        fail "Workflows: cannot list the workflows of $gh_repo"
        errors=$((errors + 1))
      fi
      warn_run_issue "$gh_repo"
    fi
    verify_release
  else
    warn "Secrets: cannot verify (gh not available)"
  fi

  if [[ "$errors" -eq 0 ]]; then
    printf "\n  %s%sReady.%s Add your first package:\n" "$GREEN" "$BOLD" "$RESET"
    if [[ -n "${AURTOMATOR_RUNNER:-}" ]]; then
      printf "    %s draft <name>\n\n" "$AURTOMATOR_RUNNER"
    else
      printf "    AURTOMATOR_DATA_DIR=%s %s/scripts/draft.sh <name>\n\n" "$AURTOMATOR_DATA_DIR" "$AURTOMATOR_DIR"
    fi
  else
    printf "\n  %s%s%d issue(s) found.%s Fix and re-run:\n" "$YELLOW" "$BOLD" "$errors" "$RESET"
    printf "    %s verify\n\n" "$SETUP_CMD"
    return 1
  fi
}

# Saved values first, so that flags override them
load_config

while [[ $# -gt 0 ]]; do
  case "$1" in
    identity | ssh | gpg | secrets | verify)
      STEPS+=("$1")
      shift
      ;;
    --git-name | --git-email | --gpg-key | --ssh-key)
      if [[ $# -lt 2 ]]; then
        echo "$1 needs a value (see $SETUP_CMD --help)" >&2
        exit 1
      fi
      case "$1" in
        --git-name) GIT_AUTHOR_NAME="$2" ;;
        --git-email) GIT_AUTHOR_EMAIL="$2" ;;
        --gpg-key) GPG_KEY_ID="$2" ;;
        --ssh-key) AUR_SSH_KEY=$(key_path "$2") ;;
      esac
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
      echo "Unknown option: $1 (see $SETUP_CMD --help)" >&2
      exit 1
      ;;
  esac
done

if [[ ${#STEPS[@]} -eq 0 ]]; then
  STEPS=(identity ssh gpg secrets verify)
fi

printf "%saurtomator setup%s\n" "$BOLD" "$RESET"

# Saving after each step keeps the answers given before a failed step; a failed
# verify saves too, so the re-run it suggests has the values of this run
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
ok "Config saved to .aurtomator.conf in $AURTOMATOR_DATA_DIR"
exit "$EXIT_STATUS"
