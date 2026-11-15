---
title: Setup
---

## Prerequisites

Required:

- Arch Linux, or Arch-based systems with `makepkg` and `updpkgsums`
- `git`, `curl`, and `ssh-keygen` from `openssh`
- `yq` 4.40.1 or newer, the [Go version by mikefarah](https://github.com/mikefarah/yq). The Python `yq` around `jq` does not work
- AUR account at <https://aur.archlinux.org> with at least one package you maintain

Optional:

- `gh` (GitHub CLI), which sets the GitHub Secrets for you. Without it, you set them in the web UI
- GPG key, to sign AUR commits, see [GPG signing](/gpg-signing/)
- `namcap`, to lint PKGBUILDs before a push

```bash
sudo pacman -S --needed git openssh go-yq curl pacman-contrib namcap github-cli gnupg
```

## After creating the repository

Repositories created from template [staticwire/aurtomator-seed](https://github.com/staticwire/aurtomator-seed) with "Use this template" hold the two [calling workflows](#the-calling-workflows), the script [`aurtomator.sh`](#the-aurtomatorsh-script), `.github/dependabot.yml`, `.gitignore`, an empty `packages/` directory and a README with the markers that runs fill.

### Required

1. Enable Issues: Settings > General > Features > Issues. Failures, update alerts and new aurtomator releases arrive as issues. With Issues off, runs print a notice and open none.
2. Check Actions: the Actions tab lists `Check AUR Package Updates` and `Validate packages`. Workflows shown as disabled run again after "Enable workflow". GitHub disables the workflows of forks until they are enabled there, and the scheduled workflow of public repositories after 60 days without activity. Private repositories use the Actions minutes of your account: GitHub rounds each job up to whole minutes, four jobs for runs that change nothing and seven for runs with an update.
3. Set the secrets: `./aurtomator.sh setup`, run in a clone of your repository, sets `AUR_SSH_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` and, with GPG, `GPG_SIGNING_KEY`, see [Quick setup](#quick-setup-with-gh-cli). The calling workflow passes them to aurtomator by name, since `secrets: inherit` works only between repositories of one organization or enterprise.

The schedule runs from the start, before the secrets exist. Runs without a package to push need no key. Runs with one stop in `publish` with `The secret AUR_SSH_KEY is empty` and open the issue `❌ Check AUR Package Updates failed`, which the first run without failed jobs closes.

### Recommended

- Dependabot version updates: `.github/dependabot.yml` of the template turns them on. Dependabot then opens pull requests that move the pin of the calling workflows to new aurtomator releases, see [The calling workflows](#the-calling-workflows). Forks of the template turn them on under Settings > Advanced Security, "Dependabot version updates".
- Topics, for public repositories.

### Badges

`update-readme.sh` writes three badges between `<!-- BADGES:START -->` and `<!-- BADGES:END -->` in the README: `Validate packages`, `Check AUR Package Updates` and `maintained with aurtomator`. Until `packages/` holds a package it writes nothing, so the setup steps of the template stay in the README. The badge URLs name `validate.yml` and `check-updates.yml`, so the calling workflows keep those file names.

### Statistics

The first run with a package adds `stats/` to your repository: the journal `events.csv` and the card at the top of the package table, which the first run of each day draws again. The journal starts with that run. See [Statistics](/features/statistics/).

## The calling workflows

`.github/workflows/check-updates.yml` runs updates on a schedule. Its job `pins` checks the pins first, and its job `notify` opens an issue when runs fail:

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
  pins:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - run: ./aurtomator.sh check-pins

  check-updates:
    needs: pins
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

`.github/workflows/validate.yml` runs `validate-pkg.sh --all` on every push to `main` and on pull requests, after the same job `pins`:

```yaml
name: Validate packages

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  pins:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - run: ./aurtomator.sh check-pins

  validate:
    needs: pins
    uses: staticwire/aurtomator/.github/workflows/validate.yml@<sha> # vX.Y.Z
```

The pin after `@` is the SHA of an aurtomator release tag, and the comment names the release. The three `uses:` lines of aurtomator carry the same pin. Tags can move and SHAs cannot, so runs always get the code of that release.

`./aurtomator.sh pin vX.Y.Z` moves the three pins to that release, see [The aurtomator.sh script](#the-aurtomatorsh-script). By hand, `git ls-remote https://github.com/staticwire/aurtomator refs/tags/vX.Y.Z` prints the tag SHA for the three lines. Dependabot opens one pull request for the three lines at its next weekly check: the template groups them as `aurtomator` and excludes them from the cooldown. Insights > Dependency graph > Dependabot > "Recent update jobs" > "Check for updates" runs the check at once. `Validate packages` checks your packages with the validator of the new release on that pull request. After the merge, `./aurtomator.sh` runs the scripts of the new release, and the first run on the new pin updates `aurtomator.sh` itself.

GitHub serves commits of any aurtomator fork under the name `staticwire/aurtomator` too, so pins can name code that no release holds, and the jobs on GitHub run that code with the secrets of your repository. Job `pins` runs `./aurtomator.sh check-pins`, see [The aurtomator.sh script](#the-aurtomatorsh-script), and fails when an aurtomator pin in the two files is not the commit of the release its comment names. `check-updates` and `validate` start only after `pins` passes. Pull requests with such a pin therefore fail their checks, and scheduled runs with one stop before any job gets the secrets. `notify` runs without the secrets and opens the issue of the failed run. `./aurtomator.sh` makes the same check before it fetches a pin.

Calling jobs set the token permissions for the whole called workflow, and called jobs can lower them but cannot raise them. `check-updates` grants `contents: write` for its commit and `issues: write` for its issues. `notify` grants `actions: read` to list the failed jobs and `issues: write` for its issue. Calling jobs that grant less make GitHub reject the file before any job starts, see [Invalid workflow file](/help/troubleshooting/#invalid-workflow-file-a-nested-job-requests-more-permissions).

## The aurtomator.sh script

`aurtomator.sh` in the root of your repository runs aurtomator scripts at the commit the calling workflows pin, so local runs use the strategies and checks of CI without an aurtomator clone:

```bash
./aurtomator.sh setup                  # scripts/setup.sh
./aurtomator.sh draft <name>           # scripts/draft.sh <name>
./aurtomator.sh validate-pkg <name>    # scripts/validate-pkg.sh <name>
./aurtomator.sh check-update <name>    # scripts/check-update.sh <name>
./aurtomator.sh update-pkg <name> <version> --dry-run
./aurtomator.sh check-all              # scripts/check-all.sh
./aurtomator.sh sample                 # prints packages/example.yml.sample
./aurtomator.sh pin vX.Y.Z             # pins the calling workflows to a release
./aurtomator.sh check-pins             # checks each pin against its release tag
```

Commands are `sample`, `pin`, `check-pins` or the name of a script of `scripts/` without `.sh`, and the arguments after them go to that script. The script runs with your repository as `AURTOMATOR_DATA_DIR`, from any directory. Scripts of the CI jobs, such as `publish-pkg`, run after a warning.

The pin comes from the one `uses:` line of `.github/workflows/check-updates.yml` that names `check-updates.yml` at a commit SHA, and pins in comments change nothing. The script also reads the file with `yq`, as GitHub does, and stops unless the jobs call `check-updates.yml` once, at the pin of that line: pins in quotes, on the next line or through an alias stop it, and so do `uses:` lines inside a block of text. It stops as well on files with two YAML documents, a merge key `<<` or a key twice in one mapping.

The first run of a pin fetches aurtomator at that commit into `~/.cache/aurtomator/<sha>`, or `$XDG_CACHE_HOME/aurtomator/<sha>`, and removes the copies fetched more than 30 days ago. Before the fetch it stops unless the pin is the commit of the release written after it, as in `@<sha> # vX.Y.Z`: GitHub serves commits of any fork under the name of the repository too. `git ls-remote --tags https://github.com/staticwire/aurtomator` lists the tags and their commits.

The script needs mikefarah/yq 4.40.1 or newer, and names the version of any other `yq` it finds.

`./aurtomator.sh pin vX.Y.Z` reads the tag commit with `git ls-remote`, writes it and `# vX.Y.Z` into every `uses:` line of aurtomator in `.github/workflows/check-updates.yml` and `.github/workflows/validate.yml`, and prints those lines. It stops before it changes any file when the tag names no commit or `yq` reads a pin outside such a line. The next run of the script fetches the release, and CI takes it once the two files are pushed.

`./aurtomator.sh check-pins` reads every `uses:` line of aurtomator in `.github/workflows/check-updates.yml` and `.github/workflows/validate.yml`, in jobs and steps and with the repository name in any case. It prints these lines when each pin is the commit of the release written after it. It stops at the first pin that is not the commit of its release, at aurtomator `uses:` lines without a commit SHA and, as `pin` does, when `yq` reads a pin outside such a line. It also stops at jobs that call a workflow neither local nor of aurtomator, written in any spelling, since GitHub passes such workflows the secrets the job names, at steps that name a workflow of another repository, at aurtomator pins written with an extra slash or a backslash, which GitHub drops when it reads the name, and at `uses:` values with a YAML tag. It fetches nothing.

`aurtomator.sh` names the aurtomator repository, `staticwire/aurtomator`, and takes no pin of another repository, so pull requests that move a pin to a fork or to a name that looks the same fail `pins`. Forks of aurtomator write their own name in their `aurtomator.sh`, and runs copy that file into the repositories that pin the fork.

In CI, the jobs check out your repository, then aurtomator into `aurtomator/` of that checkout, and create `upload`, `handoff`, `handoff-out`, `handoffs` and `statuses` there. Nothing in the root of your repository may take one of these names.

Each run of `check-updates.yml` compares your `aurtomator.sh` with that of the release it uses, and its commit replaces your copy when they differ. Local edits therefore last until the next run. Repositories without `aurtomator.sh` get none, and their job `pins` fails. Repositories created without the template take the file of the release they pin, here `vX.Y.Z`:

```bash
curl -fsSL -o aurtomator.sh https://raw.githubusercontent.com/staticwire/aurtomator/vX.Y.Z/aurtomator.sh
chmod +x aurtomator.sh
```

## Quick setup (with gh CLI)

With `gh` installed and authenticated (`gh auth login`), clone your repository and run the setup in it:

```bash
git clone https://github.com/<you>/<repository>
cd <repository>
./aurtomator.sh setup
```

It runs five steps in order:

1. `identity`: the git name and email of your AUR commits, which CI commits under too
2. `ssh`: existing SSH key for the AUR. CI uses the key without a prompt, so the step refuses keys with a passphrase and prints the commands that make a copy without one
3. `gpg`: optional commit signing, see [GPG signing](/gpg-signing/)
4. `secrets`: sets `AUR_SSH_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` and, with GPG, `GPG_SIGNING_KEY` in your GitHub repository. Missing keys, and keys with a passphrase, stop it before it sets any secret
5. `verify`: checks the identity, SSH access to the AUR with the saved key alone, as CI has it, GPG signing, the secrets, Issues and the two calling workflows

The setup works on the repository that holds `aurtomator.sh` and prints it as `Data directory:`. `secrets` sets the secrets of the `origin` repository and prints it as `Target repo:`, or asks for `owner/repo` when `origin` is no repository on github.com. The SSH key pushes all of your AUR packages, so interactive runs ask before they set the secrets. The setup saves your answers to `.aurtomator.conf` after each step, and failed steps keep the answers of the steps before them.

The `# Maintainer:` line of your PKGBUILD stays yours. aurtomator does not change it and warns when it is missing.

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
ssh -F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none -i ~/.ssh/aur_ed25519 aur@aur.archlinux.org
```

The options make ssh offer this key alone, as CI does, so no other key of your agent or of `~/.ssh/config` answers for it. The "Welcome" message means it works, and the connection then closes.

### 4. Set GitHub Secrets in the web UI

In your repository, open Settings > Secrets and variables > Actions > New repository secret, and create:

| Secret | Value |
|---|---|
| `AUR_GIT_NAME` | your name, as `Jane Doe` |
| `AUR_GIT_EMAIL` | your email, as `jane@example.com` |
| `AUR_SSH_KEY` | whole private key, `~/.ssh/aur_ed25519` |
| `GPG_SIGNING_KEY` | with GPG signing: the output of `gpg --export-secret-subkeys --armor '<subkey-id>!'` |

That GPG output works in CI only for keys without a passphrase. For keys with one, `./aurtomator.sh setup gpg secrets` prints a copy without it, see [Passphrase stripping](/gpg-signing/#passphrase-stripping-3-pinentry-dialogs).

### 5. Run verify

```bash
./aurtomator.sh setup verify --git-name "Jane Doe" --git-email "jane@example.com" --ssh-key ~/.ssh/aur_ed25519
```

The steps above write no `.aurtomator.conf`, so `verify` takes the values from the options and saves them. With GPG signing, add `--gpg-key <subkey-id>`. With `gh`, it also checks the `origin` repository: the secrets, Issues, and the two calling workflows, as [Required](#required) asks. Open `❌ Check AUR Package Updates failed` issues and pins older than the latest aurtomator release are warnings. Every check runs, and when one fails, `verify` prints how many failed and exits with status 1.

## Setup script reference

```bash
./aurtomator.sh setup [step...] [options]
```

Without a step, all steps run in order. Steps can be combined, as in `./aurtomator.sh setup identity ssh`.

| Step | Does |
|---|---|
| `identity` | git name and email of AUR commits |
| `ssh` | SSH key for the AUR |
| `gpg` | GPG signing key, after a yes or no prompt |
| `secrets` | sets the GitHub Secrets, or prints how to set them by hand |
| `verify` | checks identity, SSH, GPG, secrets, Issues and workflows |

| Option | Does |
|---|---|
| `--git-name <name>` | git name of AUR commits |
| `--git-email <email>` | git email of AUR commits |
| `--gpg-key <id>` | this GPG key, with no GPG prompt |
| `--ssh-key <path>` | this SSH private key, with no SSH prompt |
| `--non-interactive` | no prompts. The name and email default to `user.name` and `user.email` of your global git config, the SSH key to `~/.ssh/aur_ed25519`. Values without a default are errors, and GPG is skipped without `--gpg-key` |
| `-h`, `--help` | prints a usage summary |

```bash
# Without prompts
./aurtomator.sh setup \
  --git-name "Jane Doe" --git-email "jane@example.com" \
  --ssh-key ~/.ssh/aur_ed25519 --gpg-key ABCDEF1234567890 \
  --non-interactive

# The secrets again, after a new key
./aurtomator.sh setup secrets
```

## Configuration file

The setup saves its state to `.aurtomator.conf` in the root of your repository, which `.gitignore` of the template lists, since it holds local paths. Scripts read it as data and never run it. Each line holds one of the four names below and a value in single quotes, and the setup refuses values with control characters or bytes that are no UTF-8. Empty lines and lines that start with `#` are skipped, and any other line stops the script with its line number.

```bash
GIT_AUTHOR_NAME='Jane Doe'
GIT_AUTHOR_EMAIL='jane@example.com'
GPG_KEY_ID='ABCDEF1234567890'
AUR_SSH_KEY='/home/<user>/.ssh/aur_ed25519'
```

| Variable | Value |
|---|---|
| `GIT_AUTHOR_NAME` | git name of AUR commits |
| `GIT_AUTHOR_EMAIL` | git email of AUR commits |
| `GPG_KEY_ID` | GPG key ID, empty without signing |
| `AUR_SSH_KEY` | absolute path to the SSH private key; the setup saves relative paths as absolute ones |

New runs of the setup do not ask again for the values the file holds. Options override saved values and save the new one.

`setup.sh`, `update-pkg.sh` and `publish-pkg.sh` stop when git tracks `.aurtomator.conf`. Tracked files replace the ignored one at checkouts and merges, so pull requests that add one would choose the key that `secrets` uploads and the author of your AUR commits. Check its values, then `git rm --cached .aurtomator.conf` takes it out of the repository and keeps it on disk.

## Pull requests to your repository

`Validate packages` checks the YAMLs of `packages/` and no other file of pull requests. Changes to `aurtomator.sh` run on your machine at your next `./aurtomator.sh` command after the checkout or the merge. Changes to calling workflows change what CI runs with your secrets: the `uses:` line of `check-updates.yml` names the workflow that gets `AUR_SSH_KEY` and `GPG_SIGNING_KEY`. Read these files in the diff before you merge. Job `pins` checks new pins, but pull requests run it with their own `aurtomator.sh` and workflows, so changes to them can skip the check.
