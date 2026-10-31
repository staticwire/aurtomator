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

## After creating the repository

A repository created from the template [staticwire/aurtomator-seed](https://github.com/staticwire/aurtomator-seed) with "Use this template" holds the two [calling workflows](#the-calling-workflows), `.github/dependabot.yml`, a `.gitignore`, an empty `packages/` directory and a README with the markers that a run fills.

### Required

1. **Enable Issues**: Settings > General > Features > Issues. Failures, update alerts and newer aurtomator releases are reported as issues. With Issues off, a run prints a notice instead and opens none.
2. **Check Actions**: the Actions tab lists `Check AUR Package Updates` and `Validate packages`. A workflow shown as disabled there runs again once you open it and click "Enable workflow". In a fork, GitHub disables the workflows until they are enabled in its Actions tab. GitHub also disables a scheduled workflow of a public repository after 60 days without activity in it. The workflow commits only when a status or a version changes, so a repository whose packages stay the same that long loses its schedule and needs "Enable workflow" again.
3. **Set the secrets**: `~/src/aurtomator/scripts/setup.sh`, run from inside a clone of your repository, sets `AUR_SSH_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` and, with GPG, `GPG_SIGNING_KEY`, as [Quick setup](#quick-setup-with-gh-cli) describes. The calling workflow passes them to aurtomator by name.

### Recommended

- **Dependabot version updates**: the `.github/dependabot.yml` of the template turns them on in a repository created from it. Dependabot then opens the pull request that moves the pin of the calling workflows to a new release of aurtomator, see [The calling workflows](#the-calling-workflows). A fork of the template needs the switch: Settings > Advanced Security, then Enable next to "Dependabot version updates".
- Set repository topics if your repository is public.

### Badges

`update-readme.sh` writes three badges between the `<!-- BADGES:START -->` and `<!-- BADGES:END -->` markers of the README: `Check AUR Package Updates`, `Validate packages` and `maintained with aurtomator`. A run of `Check AUR Package Updates` runs the script and commits the README when it changed.

The badge URLs name `check-updates.yml` and `validate.yml` in your repository, so the calling workflows keep those file names.

## The calling workflows

`.github/workflows/check-updates.yml` runs the update pipeline at minute 17 of every hour, and its `notify` job opens an issue when the run fails:

```yaml
name: Check AUR Package Updates

on:
  schedule:
    - cron: "17 * * * *"
  workflow_dispatch:

concurrency:
  group: check-updates
  cancel-in-progress: false

jobs:
  check-updates:
    uses: staticwire/aurtomator/.github/workflows/check-updates.yml@<sha> # vX.Y.Z
    permissions:
      contents: write
      issues: write
    secrets:
      AUR_SSH_KEY: ${{ secrets.AUR_SSH_KEY }}
      GPG_SIGNING_KEY: ${{ secrets.GPG_SIGNING_KEY }}
      AUR_GIT_NAME: ${{ secrets.AUR_GIT_NAME }}
      AUR_GIT_EMAIL: ${{ secrets.AUR_GIT_EMAIL }}

  notify:
    needs: check-updates
    if: ${{ always() && needs.check-updates.result != 'success' }}
    uses: staticwire/aurtomator/.github/workflows/notify-failure.yml@<sha> # vX.Y.Z
    permissions:
      actions: read
      issues: write
```

`.github/workflows/validate.yml` runs `validate-pkg.sh --all` on every push to `main` and on pull requests:

```yaml
name: Validate packages

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  validate:
    uses: staticwire/aurtomator/.github/workflows/validate.yml@<sha> # vX.Y.Z
```

The pin after `@` is the SHA of a release tag of aurtomator, and the comment after it names that release. All three `uses:` lines carry the same pin. A tag can be moved and a SHA cannot, so a run always gets the code of that release. `git -C ~/src/aurtomator rev-parse 'vX.Y.Z^{commit}'` prints the SHA of a tag. Dependabot opens the pull request that moves the pin to a new release, and the `Validate packages` run of that pull request checks your packages with the validator of the new release before the merge. After the merge, `git -C ~/src/aurtomator fetch` and `git -C ~/src/aurtomator checkout` with the new tag move the clone to the same release.

A calling job sets the permissions of the token for the whole called workflow, and a job of the called workflow can lower them but cannot raise them. `check-updates` grants `contents: write` for the commit of the package versions and the README, and `issues: write` for the issues it opens and closes. `notify` grants `actions: read` to list the failed jobs of the run, and `issues: write` to open its issue. `check-updates.yml` has no workflow-level `permissions`, so each job gets its own block and nothing more. `validate.yml` has one job, and its workflow-level `contents: read` covers that job. A calling job that grants less than this makes GitHub reject the file before any job starts, see [Invalid workflow file](#invalid-workflow-file-a-nested-job-requests-more-permissions).

## Quick setup (with gh CLI)

With `gh` installed and authenticated (`gh auth login`), clone aurtomator for the scripts at the tag the calling workflows pin, then clone your repository and run `setup.sh` from inside it:

```bash
git clone https://github.com/staticwire/aurtomator ~/src/aurtomator
git -C ~/src/aurtomator checkout vX.Y.Z
git clone https://github.com/<you>/<repository>
cd <repository>
~/src/aurtomator/scripts/setup.sh
```

`vX.Y.Z` is the version in the `# vX.Y.Z` comment of the calling workflows. The script runs five steps in order:

1. **identity**: your name and email for AUR git commits
2. **ssh**: an existing SSH key for the AUR. CI uses the key without a prompt, so the step refuses a key with a passphrase and prints the commands that make a copy without one.
3. **gpg**: optional GPG commit signing
4. **secrets**: pushes `AUR_SSH_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` and, with GPG, `GPG_SIGNING_KEY` to your GitHub repo. It checks the SSH key as the ssh step does, so a key that is missing or has a passphrase stops it before any secret is set.
5. **verify**: checks identity, SSH access to the AUR, GPG signing and the secrets

The script works on the directory it runs in. The `identity` step prints that directory as `Data directory:`. The `secrets` step sets the secrets of the GitHub repo of its `origin` remote, prints that repo as `Target repo:`, and asks for `owner/repo` when there is no `origin`. A run from inside the clone of aurtomator prints `Target repo: staticwire/aurtomator` and writes `.aurtomator.conf` into the clone. The script saves your answers to `.aurtomator.conf` after each step, so a step that fails, and a `verify` that finds a problem, leave the answers given so far for the next run.

## Identity

The `identity` step sets the git author name and email of your AUR commits, as `git log` shows them in your AUR package repos. They are pushed to the GitHub Secrets of your repository as `AUR_GIT_NAME` and `AUR_GIT_EMAIL`, so CI commits under the same identity.

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

In your repository, open Settings > Secrets and variables > Actions > New repository secret, and create:

| Secret name      | Value                                                 |
|------------------|-------------------------------------------------------|
| `AUR_GIT_NAME`   | Your name (e.g., `Jane Doe`)                          |
| `AUR_GIT_EMAIL`  | Your email (e.g., `jane@example.com`)                 |
| `AUR_SSH_KEY`    | Full contents of `~/.ssh/aur_ed25519` (the **private** key) |

With GPG signing, also create:

| Secret name       | Value                                                      |
|-------------------|------------------------------------------------------------|
| `GPG_SIGNING_KEY` | Output of `gpg --export-secret-subkeys --armor '<subkey-id>!'` |

That output works in CI only for a key without a passphrase. For a key with one, `~/src/aurtomator/scripts/setup.sh gpg secrets` prints a passphrase-free copy, see [Passphrase stripping](#passphrase-stripping-3-pinentry-dialogs).

### 5. Run verify

From inside your repository:

```bash
~/src/aurtomator/scripts/setup.sh verify
```

It checks identity, SSH access, GPG signing when configured, and the secrets when `gh` is available. When a check fails, the others still run, and `verify` then prints how many failed and exits with status 1.

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

Pass the key ID, from inside your repository:

```bash
~/src/aurtomator/scripts/setup.sh --gpg-key <subkey-id>
```

Or run the GPG step and answer `y` to "Enable GPG commit signing? (y/N)":

```bash
~/src/aurtomator/scripts/setup.sh gpg
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

The copy exists only while the script runs, so the `gpg` and `secrets` steps have to run together: `~/src/aurtomator/scripts/setup.sh gpg secrets`. Run alone, `secrets` does not set `GPG_SIGNING_KEY` for a key with a passphrase and prints that command.

## Setup script reference

```bash
~/src/aurtomator/scripts/setup.sh [step...] [options]
```

Run it from inside your repository: the directory it runs in is the one it configures.

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
~/src/aurtomator/scripts/setup.sh identity ssh    # identity + SSH only
~/src/aurtomator/scripts/setup.sh verify          # just verify
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
~/src/aurtomator/scripts/setup.sh

# Non-interactive with explicit values
~/src/aurtomator/scripts/setup.sh \
  --git-name "Jane Doe" --git-email "jane@example.com" \
  --ssh-key ~/.ssh/aur_ed25519 --gpg-key ABCDEF1234567890 \
  --non-interactive

# Re-run just secrets after rotating a key
~/src/aurtomator/scripts/setup.sh secrets

# Verify after manual changes
~/src/aurtomator/scripts/setup.sh verify
```

## Configuration file

Setup saves its state to `.aurtomator.conf` in the root of your repository, next to `packages/`. The scripts source it as a shell file, so `setup.sh` writes every value shell-quoted, and a `"`, `$` or backtick in a name stays part of the name. A file from an older version, with double quotes, still loads.

```bash
GIT_AUTHOR_NAME='Jane Doe'
GIT_AUTHOR_EMAIL='jane@example.com'
GPG_KEY_ID='ABCDEF1234567890'
AUR_SSH_KEY='/home/<user>/.ssh/aur_ed25519'
```

| Variable           | Description                                                |
|--------------------|------------------------------------------------------------|
| `GIT_AUTHOR_NAME`  | Name used as git commit author for AUR pushes.             |
| `GIT_AUTHOR_EMAIL` | Email used as git commit author for AUR pushes.            |
| `GPG_KEY_ID`       | GPG key ID for commit signing. Empty string if not used.   |
| `AUR_SSH_KEY`      | Absolute path to the SSH private key for AUR.              |

A re-run of `setup.sh` loads this file first and does not ask again for the values it holds. A command line option overrides the saved value, and the new value is saved. The `.gitignore` of the template lists the file, because it holds local paths.

## Adding your first package

Every command below runs from inside your repository, with the scripts of the clone of aurtomator.

### 1. Copy the example

```bash
cp ~/src/aurtomator/packages/example.yml.sample packages/my-package.yml
```

### 2. Edit the YAML

```yaml
name: my-package
strategy: github-release
upstream:
  project: owner/repo
```

`name` is the `pkgbase` on the AUR, the name of its git repository. It is the package name, except for a split package: liblinear with `pkgname=(liblinear python-liblinear)` has the `name` `liblinear`, and `python-liblinear` has no YAML of its own.

[docs/WORKFLOW.md](WORKFLOW.md) has YAML examples for all 15 strategies.

### 3. Validate the config

```bash
~/src/aurtomator/scripts/validate-pkg.sh my-package
```

It checks the YAML syntax, the required fields and the fields each strategy needs.

### 4. Test the version check

```bash
~/src/aurtomator/scripts/check-update.sh my-package
```

It runs the strategy and prints the latest upstream version. Without a `current` field in the YAML, it also reports that no current version is set.

### 5. Test the update (dry run)

```bash
~/src/aurtomator/scripts/update-pkg.sh my-package 1.2.3 --dry-run
```

It clones the AUR repo, sets `pkgver`, regenerates checksums and `.SRCINFO`, runs `namcap` when it is installed, and shows the PKGBUILD diff **without pushing**.

### 6. Push and let CI take over

Commit the package YAML and push to your repository. The push to `main` runs `Validate packages`. `Check AUR Package Updates` runs every hour at minute 17, as set in `.github/workflows/check-updates.yml`, and can be started by hand through `workflow_dispatch`.

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

**Symptom:** The `publish` job fails in `Setup AUR SSH` with `The secret AUR_SSH_KEY is empty`, or with SSH key errors.

**Fixes:**

1. Open Settings > Secrets and variables > Actions in your repository. It lists `AUR_SSH_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` and, with GPG, `GPG_SIGNING_KEY`.
2. Run `~/src/aurtomator/scripts/setup.sh secrets` from inside your repository to push them again.
3. The `check-updates` job of `.github/workflows/check-updates.yml` passes each secret by name, as [The calling workflows](#the-calling-workflows) shows.

### Invalid workflow file: a nested job requests more permissions

**Symptom:** A run of a calling workflow fails before any job starts, with `Invalid workflow file` and a line of this form:

```text
The nested job '<job>' is requesting '<permissions>', but is only allowed '<permissions>'
```

**Cause:** The calling job grants less than a job of the called workflow requests. A called workflow can lower the permissions of the calling job but cannot raise them.

**Fix:** Give each job of the calling workflow the `permissions` block that [The calling workflows](#the-calling-workflows) shows: `contents: write` and `issues: write` for `check-updates`, `actions: read` and `issues: write` for `notify`, and `contents: read` in `validate.yml`.

### check-update.sh fails: "Strategy not found"

**Symptom:** `Strategy not found or not executable:` followed by the absolute path of `strategies/xxx.sh` in your clone of aurtomator

**Fixes:**

1. The `strategy` field in your package YAML must match a file in `strategies/` of the clone. `ls ~/src/aurtomator/strategies/` lists them.
2. The clone has the strategies of the tag it is at. `git -C ~/src/aurtomator checkout vX.Y.Z`, with the version the calling workflows pin, gives it the strategies a run uses.
3. Strategy scripts must be executable: `chmod +x ~/src/aurtomator/strategies/*.sh`
4. `~/src/aurtomator/scripts/validate-pkg.sh my-package`, run from inside your repository, catches config errors before a run.

### update-pkg.sh fails: "No PKGBUILD found"

**Symptom:** The clone succeeds, and the script reports `No PKGBUILD found in AUR repo`.

**Cause:** The package does not exist on the AUR yet. aurtomator updates **existing** AUR packages and does not create new ones. Push your first PKGBUILD to the AUR by hand.

### updpkgsums fails

**Symptom:** `Required command not found: updpkgsums`, or `updpkgsums failed` with a refusal to push.

**Causes:**

1. `updpkgsums` is not installed. Install it with `sudo pacman -S --needed pacman-contrib`.
2. A source URL in the PKGBUILD uses variables that do not resolve after the version bump. Check the `source=()` array.
