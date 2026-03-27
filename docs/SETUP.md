# Setup Guide

Complete setup instructions for aurtomator. Covers identity, SSH keys, optional GPG signing, GitHub Secrets, and adding your first package.

---

## Prerequisites

**Required:**

- **Arch Linux** (or an Arch-based system with `makepkg` and `updpkgsums`)
- **git**
- **yq** -- the [Go version by mikefarah](https://github.com/mikefarah/yq), not the Python wrapper
- **ssh-keygen** (from `openssh`)
- **An AUR account** at <https://aur.archlinux.org> with at least one package you maintain
- **curl**

**Optional but recommended:**

- **gh** (GitHub CLI) -- automates GitHub Secrets setup. Without it, you set secrets manually via the web UI. Both paths are documented below.
- **GPG key** -- for signed commits on AUR. Optional; see [GPG signing](#gpg-signing-optional).
- **namcap** -- for linting PKGBUILDs before pushing

Install everything at once:

```bash
sudo pacman -S --needed git openssh go-yq curl namcap github-cli gnupg
```

---

## After forking

After forking aurtomator (or using it as a template), configure your repository:

### Required

1. **Enable GitHub Actions** -- go to your fork's Actions tab and enable workflows. GitHub disables Actions on forks by default.
2. **Enable Check AUR Package Updates workflow** -- after enabling Actions, go to the "Check AUR Package Updates" workflow and click "Enable workflow". Scheduled workflows require per-workflow activation on forks.
3. **Enable Issues** -- Settings → General → Features → Issues. Required for automatic failure notifications.
4. **Run setup** -- `./scripts/setup.sh` configures identity, SSH, GPG, and GitHub Secrets (see below).

### Recommended

- **Set repository topics** -- helps discoverability if your fork is public.

### Badges

README badges (CI, Codecov) auto-update to match your fork via `update-readme.sh`. Two things to know:

- **Public repos only** -- Codecov badge requires a public repository. Private forks show the upstream aurtomator badge instead.
- **Activate after first push** -- on a fresh fork, badges show "no status" / "unknown". They activate automatically after your first commit to main (e.g., adding a package). This is normal.

---

## Quick setup (with gh CLI)

If you have `gh` installed and authenticated (`gh auth login`), setup is a single command:

```bash
./scripts/setup.sh
```

This runs all five steps in order:

1. **identity** -- asks your name and email for AUR git commits
2. **ssh** -- prompts for an existing SSH key for AUR
3. **gpg** -- asks whether you want GPG commit signing (optional)
4. **secrets** -- pushes `AUR_SSH_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` (and optionally `GPG_SIGNING_KEY`) to your GitHub repo
5. **verify** -- tests identity, SSH connectivity to AUR, GPG signing, and secret presence

The script detects your GitHub repo from the `origin` remote. If detection fails, it prompts for `owner/repo`.

After setup completes, the script saves your choices to `.aurtomator.conf` so re-runs preserve your settings.

---

## Identity

The `identity` step sets your git author name and email for AUR commits. This is what appears in `git log` on your AUR package repos.

These are pushed to GitHub Secrets as `AUR_GIT_NAME` / `AUR_GIT_EMAIL` so CI uses the same identity.

**Note:** The `# Maintainer:` comment in your PKGBUILD is separate -- you manage it yourself when you first publish to AUR. aurtomator does not modify it, but warns if it is missing during updates.

If you enable **GPG signing**, your GPG key signs the AUR commits. AUR users can verify signatures with `git log --show-signature`.

---

## Manual setup (without gh CLI)

If you don't have `gh` or prefer not to use it, follow these steps.

### 1. Generate an SSH key for AUR

```bash
ssh-keygen -t ed25519 -f ~/.ssh/aur_ed25519 -C "aurtomator@aur"
```

Do not set a passphrase -- the key will be used non-interactively in CI.

### 2. Add the public key to your AUR account

Copy the public key:

```bash
cat ~/.ssh/aur_ed25519.pub
```

Go to <https://aur.archlinux.org> -> My Account -> SSH Public Key. Paste the key and save.

### 3. Test SSH access

```bash
ssh -i ~/.ssh/aur_ed25519 aur@aur.archlinux.org
```

You should see a "Welcome" message (the connection will close immediately -- this is normal).

### 4. Set GitHub Secrets via web UI

Go to your fork's GitHub page -> Settings -> Secrets and variables -> Actions -> New repository secret.

Create these secrets:

| Secret name      | Value                                                 |
|------------------|-------------------------------------------------------|
| `AUR_GIT_NAME`   | Your name (e.g., `Jane Doe`)                          |
| `AUR_GIT_EMAIL`  | Your email (e.g., `jane@example.com`)                 |
| `AUR_SSH_KEY`    | Full contents of `~/.ssh/aur_ed25519` (the **private** key) |

If you configured GPG signing, also create:

| Secret name       | Value                                                      |
|-------------------|------------------------------------------------------------|
| `GPG_SIGNING_KEY` | Output of `gpg --export-secret-subkeys --armor <key-id>`   |

### 5. Run verify

```bash
./scripts/setup.sh verify
```

This checks identity, SSH connectivity, GPG signing (if configured), and secret presence (if `gh` is available).

---

## GPG signing (optional)

GPG-signed commits on AUR provide verification that updates came from you and not from a compromised CI pipeline. This is **entirely optional** -- aurtomator works without it.

### Why bother

- AUR users running `git log --show-signature` on your package repo can verify authenticity
- Protects your packages if your GitHub account or CI secrets are compromised
- Some AUR helpers display signature status

### Create a dedicated signing subkey

Using a subkey (rather than your master key) limits exposure. If compromised, you revoke only the subkey.

```bash
# List your master key fingerprint
gpg --list-keys --keyid-format long your-email@example.com

# Add an ed25519 signing subkey, valid for 1 year
gpg --quick-add-key <master-key-fingerprint> ed25519 sign 1y

# Find the new subkey ID
gpg --list-keys --keyid-format long your-email@example.com
# Look for the line starting with "sub" with [S] capability
```

### Export for CI

The setup script handles this automatically with `gh`. To do it manually:

```bash
gpg --export-secret-subkeys --armor <subkey-id>
```

Paste the full output (including `-----BEGIN PGP PRIVATE KEY BLOCK-----` and `-----END PGP PRIVATE KEY BLOCK-----`) as the `GPG_SIGNING_KEY` GitHub secret.

### Configure in setup

Either pass it directly:

```bash
./scripts/setup.sh --gpg-key <subkey-id>
```

Or run the GPG step interactively:

```bash
./scripts/setup.sh gpg
```

The script asks "Enable GPG commit signing?" -- answer `y` and enter your key ID.

### Passphrase stripping (3 pinentry dialogs)

If your signing subkey has a passphrase, the setup script creates a passphrase-free copy for CI. This involves three pinentry dialogs that may look confusing -- here is what happens and why:

| Dialog | What to enter | Why |
|--------|--------------|-----|
| **1st** | Your current passphrase | Exports the signing subkey from your main keyring |
| **2nd** | Your current passphrase again | Unlocks the key in an isolated temporary keyring (separate GPG agent, no shared cache) |
| **3rd** | Leave empty, press OK | Sets the new passphrase to empty -- this is the CI-ready copy |

**Why enter the passphrase twice?** The script uses an isolated temporary keyring to avoid modifying your real keys. Each keyring has its own GPG agent with its own passphrase cache. The first agent (your main keyring) caches the passphrase for export, but the second agent (temporary keyring) has never seen it -- so it asks again.

**Why not pass the passphrase programmatically?** Security. Your passphrase never appears in shell variables, command arguments, environment variables, or pipe buffers. Every entry goes through pinentry (a dedicated secure input program). This is the same approach GPG itself uses internally.

**Your original key is not modified.** The passphrase is only removed from the copy in the temporary keyring. The copy is then exported and stored as the `GPG_SIGNING_KEY` GitHub secret. The temporary keyring is deleted immediately after.

---

## Setup script reference

```bash
./scripts/setup.sh [step...] [options]
```

### Steps

Run with no arguments to execute all steps in order.

| Step       | Description                                      |
|------------|--------------------------------------------------|
| `identity` | Configure git author name/email and PKGBUILD maintainer |
| `ssh`      | Configure SSH key for AUR access                 |
| `gpg`      | Configure GPG signing key (yes/no prompt)        |
| `secrets`  | Push secrets to GitHub (or print manual instructions) |
| `verify`   | Test identity, SSH, GPG, and secret configuration |

Steps can be combined:

```bash
./scripts/setup.sh identity ssh    # identity + SSH only
./scripts/setup.sh verify          # just verify
```

### Options

| Option                 | Description                                           |
|------------------------|-------------------------------------------------------|
| `--git-name <name>`    | Git author name for AUR commits                       |
| `--git-email <email>`  | Git author email for AUR commits                      |
| `--gpg-key <id>`       | Use this GPG key ID, skip the GPG prompt              |
| `--ssh-key <path>`     | Use this SSH private key path, skip the SSH prompt     |
| `--non-interactive`    | No prompts. Uses defaults or fails if a value is missing. Useful for CI. |
| `-h`, `--help`         | Print usage summary                                   |

### Examples

```bash
# Full interactive setup
./scripts/setup.sh

# Non-interactive with explicit values
./scripts/setup.sh \
  --git-name "Jane Doe" --git-email "jane@example.com" \
  --ssh-key ~/.ssh/aur_ed25519 --gpg-key ABCDEF1234567890 \
  --non-interactive

# Re-run just secrets after rotating a key
./scripts/setup.sh secrets

# Verify after manual changes
./scripts/setup.sh verify
```

---

## Configuration file

Setup saves its state to `.aurtomator.conf` in the project root. This is a plain shell file sourced by the scripts.

```bash
GIT_AUTHOR_NAME="Jane Doe"
GIT_AUTHOR_EMAIL="jane@example.com"
GPG_KEY_ID="ABCDEF1234567890"
AUR_SSH_KEY="/home/jane/.ssh/aur_ed25519"
```

| Variable           | Description                                                |
|--------------------|------------------------------------------------------------|
| `GIT_AUTHOR_NAME`  | Name used as git commit author for AUR pushes.             |
| `GIT_AUTHOR_EMAIL` | Email used as git commit author for AUR pushes.            |
| `GPG_KEY_ID`       | GPG key ID for commit signing. Empty string if not used.   |
| `AUR_SSH_KEY`      | Absolute path to the SSH private key for AUR.              |

**Re-runs:** when you run `setup.sh` again, it loads this file first. Any previously saved values become the defaults, so you only need to change what differs.

**Git:** this file is listed in `.gitignore`. It contains local paths and should not be committed.

---

## Adding your first package

### 1. Copy the example

```bash
cp packages/example.yml.sample packages/my-package.yml
```

### 2. Edit the YAML

```yaml
name: my-package
strategy: github-release
upstream:
  project: owner/repo
```

See [docs/WORKFLOW.md](WORKFLOW.md) for detailed YAML examples for all 13 strategies.

### 3. Validate the config

```bash
./scripts/validate-pkg.sh my-package
```

This checks YAML syntax, required fields, and strategy-specific field requirements.

### 4. Test the version check

```bash
./scripts/check-update.sh my-package
```

This runs the strategy and prints the latest upstream version. If the package YAML has no `current` field yet, it reports the latest version as a new find.

### 5. Test the update (dry run)

```bash
./scripts/update-pkg.sh my-package 1.2.3 --dry-run
```

This clones the AUR repo, patches `pkgver`, regenerates checksums and `.SRCINFO`, then shows the diff **without pushing**. Use this to verify everything looks correct before going live.

### 6. Push and let CI take over

Commit your new package YAML and push to your fork. The `check-updates` workflow runs hourly (configurable in `.github/workflows/check-updates.yml`) and can also be triggered manually via `workflow_dispatch`.

---

## Troubleshooting

### SSH: Permission denied (publickey)

**Symptom:** `ssh aur@aur.archlinux.org` returns `Permission denied`.

**Causes:**

1. Public key not added to AUR account. Go to <https://aur.archlinux.org> -> My Account -> SSH Public Key.
2. Wrong key being used. Specify explicitly: `ssh -i ~/.ssh/aur_ed25519 aur@aur.archlinux.org`
3. Key permissions too open. Fix with: `chmod 600 ~/.ssh/aur_ed25519`

### GPG: No secret key / unusable secret key

**Symptom:** `gpg --sign` fails with "No secret key" or "Unusable secret key".

**Causes:**

1. Key ID is wrong. List your keys: `gpg --list-secret-keys --keyid-format long`
2. Subkey expired. Check expiry: `gpg --list-keys <key-id>`. Extend if needed: `gpg --quick-set-expire <fpr> 1y`
3. Key not in the current keyring (e.g., different `GNUPGHOME`).

### gh: not logged in / authentication failed

**Symptom:** `gh auth status` fails or `gh secret set` returns 403.

**Fixes:**

1. Run `gh auth login` and complete the flow.
2. Ensure the token has `repo` scope. Check with: `gh auth status`
3. If using a fine-grained token, it needs "Secrets" write permission on the repository.

You can skip `gh` entirely and set secrets via the web UI -- see [Manual setup](#manual-setup-without-gh-cli).

### Secrets not set / workflow fails with missing secret

**Symptom:** CI fails with "secret not found" or SSH key errors in the workflow.

**Fixes:**

1. Verify secrets exist: go to your repo -> Settings -> Secrets and variables -> Actions. You should see `AUR_SSH_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` (and optionally `GPG_SIGNING_KEY`).
2. Re-run `./scripts/setup.sh secrets` to re-push them.
3. Secret names are case-sensitive.

### check-update.sh fails: "Strategy not found"

**Symptom:** `Strategy not found or not executable: strategies/xxx.sh`

**Fixes:**

1. Check that the `strategy` field in your package YAML matches one of the files in `strategies/`. Run `ls strategies/` to see available options.
2. Ensure strategy scripts are executable: `chmod +x strategies/*.sh`
3. Run `./scripts/validate-pkg.sh my-package` to catch config errors before runtime.

### update-pkg.sh fails: "No PKGBUILD found"

**Symptom:** Clone succeeds but the script reports no PKGBUILD.

**Cause:** The package does not exist on AUR yet. aurtomator updates **existing** AUR packages -- it does not create new ones. Push your initial PKGBUILD to AUR manually first.

### updpkgsums fails

**Symptom:** Warning about checksums needing manual update.

**Causes:**

1. `updpkgsums` not installed. Install with: `sudo pacman -S --needed pacman-contrib`
2. Source URL in PKGBUILD uses variables that don't resolve correctly after the version bump. Check the PKGBUILD's `source=()` array.
