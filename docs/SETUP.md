# Setup Guide

## Prerequisites

Required:

- Arch Linux, or an Arch-based system with `makepkg` and `updpkgsums`
- `git`
- `yq`: the [Go version by mikefarah](https://github.com/mikefarah/yq), not the Python wrapper
- `ssh-keygen` from `openssh`
- `curl`
- An AUR account at <https://aur.archlinux.org> with at least one package you maintain

Optional:

- `gh` (GitHub CLI) sets the GitHub Secrets for you. Without it, you set them in the web UI. Both paths are described below.
- A GPG key, to sign AUR commits. See [GPG signing](#gpg-signing-optional).
- `namcap`, to lint PKGBUILDs before pushing.

Install everything at once:

```bash
sudo pacman -S --needed git openssh go-yq curl pacman-contrib namcap github-cli gnupg
```

## After forking

### Required

1. **Enable GitHub Actions**: open the Actions tab of your fork and enable workflows. GitHub disables Actions on forks by default.
2. **Enable the "Check AUR Package Updates" workflow**: open it in the Actions tab and click "Enable workflow". A fork needs this for every scheduled workflow.
3. **Enable Issues**: Settings > General > Features > Issues. Failures are reported as issues.
4. **Run setup**: `./scripts/setup.sh` configures identity, SSH, GPG and GitHub Secrets, as described below.

### Recommended

- Set repository topics if your fork is public.

### Badges

`update-readme.sh` points the README badges (CI, Codecov) at your fork.

- **Codecov needs a public repository.** A private fork shows the upstream aurtomator badge.
- **A fresh fork shows "no status".** The badges activate after your first commit to `main`, for example adding a package.

## Quick setup (with gh CLI)

With `gh` installed and authenticated (`gh auth login`), setup is one command:

```bash
./scripts/setup.sh
```

It runs five steps in order:

1. **identity**: your name and email for AUR git commits
2. **ssh**: an existing SSH key for the AUR
3. **gpg**: optional GPG commit signing
4. **secrets**: pushes `AUR_SSH_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` and, with GPG, `GPG_SIGNING_KEY` to your GitHub repo
5. **verify**: checks identity, SSH access to the AUR, GPG signing and the secrets

The script reads the GitHub repo from the `origin` remote and asks for `owner/repo` when that fails. It saves your answers to `.aurtomator.conf`.

## Identity

The `identity` step sets the git author name and email of your AUR commits, as `git log` shows them in your AUR package repos. They are pushed to GitHub Secrets as `AUR_GIT_NAME` and `AUR_GIT_EMAIL`, so CI commits under the same identity.

The `# Maintainer:` line in your PKGBUILD is yours to manage. aurtomator does not change it and warns during an update when it is missing.

With GPG signing enabled, your key signs the AUR commits, and AUR users can check them with `git log --show-signature`.

## Manual setup (without gh CLI)

### 1. Generate an SSH key for AUR

```bash
ssh-keygen -t ed25519 -f ~/.ssh/aur_ed25519 -C "aurtomator@aur"
```

Leave the passphrase empty: CI uses the key without a prompt.

### 2. Add the public key to your AUR account

```bash
cat ~/.ssh/aur_ed25519.pub
```

On <https://aur.archlinux.org>, open My Account > SSH Public Key, paste the key and save.

### 3. Test SSH access

```bash
ssh -i ~/.ssh/aur_ed25519 aur@aur.archlinux.org
```

A "Welcome" message means it works. The connection then closes, which is expected.

### 4. Set GitHub Secrets in the web UI

In your fork, open Settings > Secrets and variables > Actions > New repository secret, and create:

| Secret name      | Value                                                 |
|------------------|-------------------------------------------------------|
| `AUR_GIT_NAME`   | Your name (e.g., `Jane Doe`)                          |
| `AUR_GIT_EMAIL`  | Your email (e.g., `jane@example.com`)                 |
| `AUR_SSH_KEY`    | Full contents of `~/.ssh/aur_ed25519` (the **private** key) |

With GPG signing, also create:

| Secret name       | Value                                                      |
|-------------------|------------------------------------------------------------|
| `GPG_SIGNING_KEY` | Output of `gpg --export-secret-subkeys --armor '<subkey-id>!'` |

That output works in CI only for a key without a passphrase. For a key with one, `./scripts/setup.sh gpg secrets` prints a passphrase-free copy, see [Passphrase stripping](#passphrase-stripping-3-pinentry-dialogs).

### 5. Run verify

```bash
./scripts/setup.sh verify
```

It checks identity, SSH access, GPG signing when configured, and the secrets when `gh` is available.

## GPG signing (optional)

aurtomator works without GPG. With it, every AUR commit is signed with your key, and AUR users can check the signature with `git log --show-signature`. The signing key is stored as a CI secret, so a leak of the CI secrets exposes it as well. A dedicated subkey limits the damage: you revoke the subkey and keep your master key. The setup script accepts only a signing subkey and refuses a master key, which certifies the others and stays on your machine.

### Create a dedicated signing subkey

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

With `gh`, the setup script does this. By hand, for a key without a passphrase:

```bash
gpg --export-secret-subkeys --armor '<subkey-id>!'
```

The `!` exports that subkey alone. Without it, gpg exports every secret subkey of the key, an encryption subkey included.

Paste the full output, including the `-----BEGIN PGP PRIVATE KEY BLOCK-----` and `-----END PGP PRIVATE KEY BLOCK-----` lines, as the `GPG_SIGNING_KEY` secret.

### Configure in setup

Pass the key ID:

```bash
./scripts/setup.sh --gpg-key <subkey-id>
```

Or run the GPG step and answer `y` to "Enable GPG commit signing? (y/N)":

```bash
./scripts/setup.sh gpg
```

### Passphrase stripping (3 pinentry dialogs)

CI needs a key without a passphrase. When your subkey has one, the setup script makes a passphrase-free copy in a temporary keyring, and three pinentry dialogs open:

| Dialog | What to enter | Why |
|--------|--------------|-----|
| **1st** | Your current passphrase | Exports the signing subkey from your main keyring |
| **2nd** | Your current passphrase again | Unlocks the key in the temporary keyring |
| **3rd** | Leave empty, press OK | Sets an empty passphrase on the copy for CI |

The second dialog asks again because the temporary keyring runs its own GPG agent, and that agent has not cached the passphrase. The passphrase only goes through pinentry: it never appears in shell variables, command arguments, environment variables or pipes.

Your original key is not modified. With `gh`, the copy is stored as the `GPG_SIGNING_KEY` secret. Without `gh`, the script prints the copy for you to paste as that secret. The temporary keyring is deleted right after, and also when the script stops early: on an error, on `Ctrl-C` or when its terminal closes.

The copy exists only while the script runs, so the `gpg` and `secrets` steps have to run together: `./scripts/setup.sh gpg secrets`. Run alone, `secrets` does not set `GPG_SIGNING_KEY` for a key with a passphrase and prints that command.

## Setup script reference

```bash
./scripts/setup.sh [step...] [options]
```

### Steps

Without a step, all of them run in order.

| Step       | Description                                      |
|------------|--------------------------------------------------|
| `identity` | Git author name and email for AUR commits        |
| `ssh`      | SSH key for AUR access                           |
| `gpg`      | GPG signing key (yes/no prompt)                  |
| `secrets`  | Push secrets to GitHub, or print manual instructions |
| `verify`   | Check identity, SSH, GPG and secrets             |

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
| `--ssh-key <path>`     | Use this SSH private key, skip the SSH prompt         |
| `--non-interactive`    | No prompts. A missing required value is an error, and GPG is skipped without `--gpg-key`. |
| `-h`, `--help`         | Print a usage summary                                 |

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

## Configuration file

Setup saves its state to `.aurtomator.conf` in the project root. The scripts source it as a shell file.

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

A re-run of `setup.sh` loads this file first and does not ask again for the values it holds. A command line option overrides the saved value, and the new value is saved. The file is in `.gitignore` because it holds local paths.

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

[docs/WORKFLOW.md](WORKFLOW.md) has YAML examples for all 14 strategies.

### 3. Validate the config

```bash
./scripts/validate-pkg.sh my-package
```

It checks the YAML syntax, the required fields and the fields each strategy needs.

### 4. Test the version check

```bash
./scripts/check-update.sh my-package
```

It runs the strategy and prints the latest upstream version. Without a `current` field in the YAML, it also reports that no current version is set.

### 5. Test the update (dry run)

```bash
./scripts/update-pkg.sh my-package 1.2.3 --dry-run
```

It clones the AUR repo, sets `pkgver`, regenerates checksums and `.SRCINFO`, runs `namcap` when it is installed, and shows the PKGBUILD diff **without pushing**.

### 6. Push and let CI take over

Commit the package YAML and push to your fork. The `check-updates` workflow runs hourly, as set in `.github/workflows/check-updates.yml`, and can be started by hand through `workflow_dispatch`.

## Troubleshooting

### SSH: Permission denied (publickey)

**Symptom:** `ssh aur@aur.archlinux.org` returns `Permission denied`.

**Causes:**

1. The public key is not on your AUR account. Add it under My Account > SSH Public Key on <https://aur.archlinux.org>.
2. SSH picks the wrong key. Name it explicitly: `ssh -i ~/.ssh/aur_ed25519 aur@aur.archlinux.org`
3. The key file permissions are too open. Fix them with `chmod 600 ~/.ssh/aur_ed25519`.

### GPG: No secret key / unusable secret key

**Symptom:** `gpg --sign` fails with "No secret key" or "Unusable secret key".

**Causes:**

1. The key ID is wrong. List your keys: `gpg --list-secret-keys --keyid-format long`
2. The subkey expired. Check with `gpg --list-keys <key-id>` and extend with `gpg --quick-set-expire <fpr> 1y`.
3. The key is in another keyring, for example under a different `GNUPGHOME`.

### gh: not logged in / authentication failed

**Symptom:** `gh auth status` fails or `gh secret set` returns 403.

**Fixes:**

1. Run `gh auth login` and complete the flow.
2. Check that the token has the `repo` scope: `gh auth status`
3. A fine-grained token needs write access to "Secrets" on the repository.

Without `gh`, set the secrets in the web UI: see [Manual setup](#manual-setup-without-gh-cli).

### Secrets not set / workflow fails with missing secret

**Symptom:** CI fails with "secret not found" or with SSH key errors.

**Fixes:**

1. Open Settings > Secrets and variables > Actions in your repo. It lists `AUR_SSH_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` and, with GPG, `GPG_SIGNING_KEY`.
2. Run `./scripts/setup.sh secrets` to push them again.
3. Secret names are case-sensitive.

### check-update.sh fails: "Strategy not found"

**Symptom:** `Strategy not found or not executable: strategies/xxx.sh`

**Fixes:**

1. The `strategy` field in your package YAML must match a file in `strategies/`. `ls strategies/` lists them.
2. Strategy scripts must be executable: `chmod +x strategies/*.sh`
3. `./scripts/validate-pkg.sh my-package` catches config errors before a run.

### update-pkg.sh fails: "No PKGBUILD found"

**Symptom:** The clone succeeds, and the script reports `No PKGBUILD found in AUR repo`.

**Cause:** The package does not exist on the AUR yet. aurtomator updates **existing** AUR packages and does not create new ones. Push your first PKGBUILD to the AUR by hand.

### updpkgsums fails

**Symptom:** `Required command not found: updpkgsums`, or `updpkgsums failed` with a refusal to push.

**Causes:**

1. `updpkgsums` is not installed. Install it with `sudo pacman -S --needed pacman-contrib`.
2. A source URL in the PKGBUILD uses variables that do not resolve after the version bump. Check the `source=()` array.
