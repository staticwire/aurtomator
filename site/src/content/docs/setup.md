---
title: Setup
---

## Prerequisites

Required:

- Arch Linux, or an Arch-based system with `makepkg` and `updpkgsums`
- `git`
- `yq`: the [Go version by mikefarah](https://github.com/mikefarah/yq), not the Python wrapper around `jq`
- `ssh-keygen` from `openssh`
- `curl`
- An AUR account at <https://aur.archlinux.org> with at least one package you maintain

Optional:

- `gh` (GitHub CLI) sets the GitHub Secrets for you. Without it, you set them in the web UI. Both paths are described below.
- A GPG key, to sign AUR commits. See [GPG signing](/gpg-signing/).
- `namcap`, to lint PKGBUILDs before pushing.

Install everything at once:

```bash
sudo pacman -S --needed git openssh go-yq curl pacman-contrib namcap github-cli gnupg
```

## After creating the repository

A repository created from the template [staticwire/aurtomator-seed](https://github.com/staticwire/aurtomator-seed) with "Use this template" holds the two [calling workflows](#the-calling-workflows), the script [`aurtomator.sh`](#the-aurtomatorsh-script), `.github/dependabot.yml`, a `.gitignore`, an empty `packages/` directory and a README with the markers that a run fills.

### Required

1. **Enable Issues**: Settings > General > Features > Issues. Failures, update alerts and newer aurtomator releases are reported as issues. With Issues off, a run prints a notice instead and opens none.
2. **Check Actions**: the Actions tab lists `Check AUR Package Updates` and `Validate packages`. A workflow shown as disabled there runs again once you open it and click "Enable workflow". In a fork, GitHub disables the workflows until they are enabled in its Actions tab. GitHub also disables a scheduled workflow of a public repository after 60 days without activity in it, and the workflow then needs "Enable workflow" again. Once `packages/` holds a package, the first run of each day commits the statistics card, see [Statistics](#statistics). Before the first package, a run commits nothing. A private repository keeps its schedule, and its runs use the Actions minutes of your account instead: GitHub counts each job in whole minutes, rounded up, from three jobs for a run that changes nothing, `image`, `check` and `status`, to six for a run with an update.
3. **Set the secrets**: `./aurtomator.sh setup`, run in a clone of your repository, sets `AUR_SSH_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` and, with GPG, `GPG_SIGNING_KEY`, as [Quick setup](#quick-setup-with-gh-cli) describes. The calling workflow passes them to aurtomator by name. `secrets: inherit` would pass none, since it works only between repositories of one organization or enterprise.

The schedule runs from the start, so runs can come before the secrets are set. Such a run needs no key while it pushes nothing to the AUR, and it can still commit the README. A run with a package to push stops in `publish` with `The secret AUR_SSH_KEY is empty`, and the `notify` job opens the issue `❌ Check AUR Package Updates failed`. The first run after `./aurtomator.sh setup secrets` in which no job fails closes that issue.

### Recommended

- **Dependabot version updates**: the `.github/dependabot.yml` of the template turns them on in a repository created from it. Dependabot then opens the pull request that moves the pin of the calling workflows to a new release of aurtomator, see [The calling workflows](#the-calling-workflows). A fork of the template needs the switch: Settings > Advanced Security, then Enable next to "Dependabot version updates".
- Set repository topics if your repository is public.

### Badges

`update-readme.sh` writes three badges between the `<!-- BADGES:START -->` and `<!-- BADGES:END -->` markers of the README: `Validate packages`, `Check AUR Package Updates` and `maintained with aurtomator`. A run of `Check AUR Package Updates` runs the script and commits the README when it changed. While `packages/` holds no package, the script writes nothing, so the setup steps of the template stay in the README until the first package.

The badge URLs name `validate.yml` and `check-updates.yml` in your repository, so the calling workflows keep those file names.

### Statistics

The first run with a package adds `stats/` to your repository: `events.csv`, the journal of every change of state of your packages, and `card.svg` and `card-dark.svg`, the card at the top of the package block of the README. The card shows the packages updated, the pushes to the AUR, the new packages and the failed checks of the last 7, 30 and 365 days, and the pushes of each day of the last year. The journal starts with that run, with one `tracked` row for each package, and holds nothing from before it. The first run of each day commits the card of the new day. See [Statistics](/features/statistics/) for the events of the journal and for reading it in Google Sheets or Grafana.

## The calling workflows

`.github/workflows/check-updates.yml` runs the update pipeline on a schedule, and its `notify` job opens an issue when the run fails:

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

The pin after `@` is the SHA of a release tag of aurtomator, and the comment after it names that release. All three `uses:` lines carry the same pin. A tag can be moved and a SHA cannot, so a run always gets the code of that release. `./aurtomator.sh pin vX.Y.Z` moves the pin of the three lines to a release, see [The aurtomator.sh script](#the-aurtomatorsh-script). To move it by hand, `git ls-remote https://github.com/staticwire/aurtomator refs/tags/vX.Y.Z` prints the SHA of a tag, and that SHA and the new `# vX.Y.Z` go into the three lines. Dependabot opens the pull request that moves the pin to a new release at its next check. To run that check at once, open Insights > Dependency graph > Dependabot, click "Recent update jobs" and then "Check for updates". The group `aurtomator` in `.github/dependabot.yml` puts the three `uses:` lines into that one pull request. The `cooldown` entry of the same file exempts them from the 3 days that Dependabot otherwise waits after a release. The `Validate packages` run of that pull request checks your packages with the validator of the new release before the merge. After the merge, [`./aurtomator.sh`](#the-aurtomatorsh-script) runs the scripts of the new release, and the first run of `check-updates.yml` on the new pin updates `aurtomator.sh` itself to that release.

A calling job sets the permissions of the token for the whole called workflow, and a job of the called workflow can lower them but cannot raise them. `check-updates` grants `contents: write` for the commit of the package versions, the README, `stats/` and `aurtomator.sh`, and `issues: write` for the issues it opens and closes. `notify` grants `actions: read` to list the failed jobs of the run, and `issues: write` to open its issue. `check-updates.yml` has no workflow-level `permissions`, so each job gets its own block and nothing more. `validate.yml` has one job, and its workflow-level `contents: read` covers that job. A calling job that grants less than this makes GitHub reject the file before any job starts, see [Invalid workflow file](/help/troubleshooting/#invalid-workflow-file-a-nested-job-requests-more-permissions).

## The aurtomator.sh script

The script `aurtomator.sh` in the root of your repository runs the scripts of aurtomator for that repository, at the commit the calling workflows pin. A local run then uses the strategies and the checks that a run in CI uses, and no clone of aurtomator is needed:

```bash
./aurtomator.sh setup                  # scripts/setup.sh
./aurtomator.sh draft <name>           # scripts/draft.sh <name>
./aurtomator.sh validate-pkg <name>    # scripts/validate-pkg.sh <name>
./aurtomator.sh check-update <name>    # scripts/check-update.sh <name>
./aurtomator.sh update-pkg <name> <version> --dry-run
./aurtomator.sh check-all              # scripts/check-all.sh
./aurtomator.sh sample                 # prints packages/example.yml.sample
./aurtomator.sh pin vX.Y.Z             # pins the calling workflows to a release
```

A command is `sample`, `pin` or the name of an executable script in `scripts/` of aurtomator without `.sh`, and the arguments after it go to that script. The script runs with your repository as `AURTOMATOR_DATA_DIR`, whatever directory you run it from. The commands above are the documented ones, and the list that the script prints for an unknown command holds these alone. Any other script of `scripts/`, such as `publish-pkg`, is a step of the CI jobs and runs after a warning.

The `uses:` line of `.github/workflows/check-updates.yml` that names `check-updates.yml` at a commit SHA gives the repository and the commit. The script stops when the file holds no such line or more than one, and it reads no comment, so an old pin kept in a comment changes nothing. GitHub reads the file as YAML, and the script reads it with `yq` too: it stops unless the jobs of the file call `check-updates.yml` once, at the pin of that line. A pin in quotes, on the line after `uses:` or through an alias stops it, and so does a `uses:` line inside a block of text, which GitHub reads as text. The first run of a pin fetches aurtomator at that commit into `~/.cache/aurtomator/<sha>`, or into `$XDG_CACHE_HOME/aurtomator/<sha>` when `XDG_CACHE_HOME` is set. Later runs use that copy, and the first run after a merge that moves the pin fetches the new release. That first run also removes the copies fetched more than 30 days ago, so a pin still in use is fetched again on its next run.

Before that fetch, the script warns when no tag of the repository points to the pinned commit. GitHub serves a commit of any fork of a repository under the name of that repository too, so a `uses:` line that names `staticwire/aurtomator` can pin a commit that is not in aurtomator. The warning shows only when the script runs. Before you merge a pull request that moves the pin, `git ls-remote --tags https://github.com/staticwire/aurtomator` lists the tags and their commits.

The script needs mikefarah/yq and stops with any other `yq`, such as the Python wrapper around `jq`. It also stops with a release of mikefarah/yq that has no `-r` or no `document_index`, and names the version. Before it reads a pin, it stops when `.github/workflows/check-updates.yml` holds more than one YAML document, a merge key `<<` or a key twice in one mapping, or when `yq` cannot read the file. `pin` checks `.github/workflows/validate.yml` the same way. The checks allow anchors and aliases.

`./aurtomator.sh pin vX.Y.Z` moves the pin to a release. It reads the commit of that tag with `git ls-remote`, puts it and `# vX.Y.Z` into every `uses:` line of the pinned repository in `.github/workflows/check-updates.yml` and `.github/workflows/validate.yml`, and prints those lines. Before it changes a file, it stops when the tag names no commit SHA, or when `yq` reads a pin of the repository in one of the two files that is on no such line, as a pin in quotes is. It fetches nothing. The next run of the script fetches the release, and CI takes it once the two files are committed and pushed.

In CI, the jobs check out your repository and then aurtomator into `aurtomator/` of that checkout, which deletes whatever that path holds. So the script is `aurtomator.sh`, and nothing in the root of your repository may be named `aurtomator`. The jobs also make the directories `upload`, `handoff`, `handoff-out`, `handoffs` and `statuses` in that root, so these names are taken as well. A tracked `upload`, `handoff-out` or `statuses` stops the step that makes the directory, and so does a tracked `handoff` in `verify`. The files of a tracked `handoff` reach the steps of `builder` in `check` and `publish` beside those of the run, and `verify` reads the files of a tracked `handoffs` as attempts of the run.

Your `aurtomator.sh` is a copy of the file `aurtomator.sh` in the root of aurtomator. Each run of `check-updates.yml` compares your copy with that file of the release the run uses. When they differ, the commit of the run replaces your copy with that file and makes it executable. So after a run, your copy is the script of the pinned release, and a local edit lasts until the next run. A repository without `aurtomator.sh` gets none, and a link of that name stays as it is.

The template holds the file `aurtomator.sh`. A repository created without the template takes that file of the release it pins and makes it executable, here for `vX.Y.Z`:

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

1. **identity**: your name and email for AUR git commits
2. **ssh**: an existing SSH key for the AUR. CI uses the key without a prompt, so the step refuses a key with a passphrase and prints the commands that make a copy without one.
3. **gpg**: optional GPG commit signing
4. **secrets**: pushes `AUR_SSH_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` and, with GPG, `GPG_SIGNING_KEY` to your GitHub repo. It checks the SSH key as the ssh step does, so a key that is missing or has a passphrase stops it before any secret is set.
5. **verify**: checks identity, SSH access to the AUR with the saved key alone, as CI has it, GPG signing, and the secrets, Issues and the two calling workflows of your GitHub repo

The setup works on the repository that holds `aurtomator.sh`, whatever directory you run it from, and the `identity` step prints it as `Data directory:`. The `secrets` step sets the secrets of the GitHub repo of its `origin` remote and prints that repo as `Target repo:`. It asks for `owner/repo` when `origin` is missing or is not a repository on github.com. The secrets hold the key that pushes all of your AUR packages, so an interactive run asks before it sets them. The setup saves your answers to `.aurtomator.conf` after each step. A step that fails stops the setup and keeps the answers of the steps before it. A `verify` that finds a problem keeps every answer of the run.

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
ssh -F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none -i ~/.ssh/aur_ed25519 aur@aur.archlinux.org
```

The options make ssh offer this key alone, as CI does: without them, another key in your SSH agent or in `~/.ssh/config` can answer for it. A "Welcome" message means it works. The connection then closes, which is expected.

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

That output works in CI only for a key without a passphrase. For a key with one, `./aurtomator.sh setup gpg secrets` prints a passphrase-free copy, see [Passphrase stripping](/gpg-signing/#passphrase-stripping-3-pinentry-dialogs).

### 5. Run verify

```bash
./aurtomator.sh setup verify --git-name "Jane Doe" --git-email "jane@example.com" --ssh-key ~/.ssh/aur_ed25519
```

The steps above write no `.aurtomator.conf`, so `verify` takes your name, your email and the key from these options and saves them for the next run. With GPG signing, add `--gpg-key <subkey-id>`. It checks identity, SSH access, and GPG signing when configured. With `gh` available, it also checks the GitHub repo of `origin`: its secrets, that Issues are on, and that `check-updates.yml` and `validate.yml` are active workflows, as [Required](#required) asks. An `origin` that is not a repository on github.com counts as a failed check. Two findings are warnings and count as no failure: an open `❌ Check AUR Package Updates failed` issue, which the next run without a failed job closes, and a pin to a version of aurtomator other than its latest release. When a check fails, the others still run, and `verify` then prints how many failed and exits with status 1.

## Setup script reference

```bash
./aurtomator.sh setup [step...] [options]
```

It runs `scripts/setup.sh` of aurtomator for the repository that holds `aurtomator.sh`, see [The aurtomator.sh script](#the-aurtomatorsh-script).

### Steps

Without a step, all of them run in order.

| Step       | Description                                      |
|------------|--------------------------------------------------|
| `identity` | Git author name and email for AUR commits        |
| `ssh`      | SSH key for AUR access                           |
| `gpg`      | GPG signing key (yes/no prompt)                  |
| `secrets`  | Push secrets to GitHub, or print manual instructions |
| `verify`   | Check identity, SSH, GPG, secrets, Issues and workflows |

Steps can be combined:

```bash
./aurtomator.sh setup identity ssh    # identity + SSH only
./aurtomator.sh setup verify          # just verify
```

### Options

| Option                 | Description                                           |
|------------------------|-------------------------------------------------------|
| `--git-name <name>`    | Git author name for AUR commits                       |
| `--git-email <email>`  | Git author email for AUR commits                      |
| `--gpg-key <id>`       | Use this GPG key ID, skip the GPG prompt              |
| `--ssh-key <path>`     | Use this SSH private key, skip the SSH prompt         |
| `--non-interactive`    | No prompts. The name and the email default to `user.name` and `user.email` of your global git config, and the SSH key to `~/.ssh/aur_ed25519`. A value without a default is an error, and GPG is skipped without `--gpg-key`. |
| `-h`, `--help`         | Print a usage summary                                 |

### Examples

```bash
# Full interactive setup
./aurtomator.sh setup

# Non-interactive with explicit values
./aurtomator.sh setup \
  --git-name "Jane Doe" --git-email "jane@example.com" \
  --ssh-key ~/.ssh/aur_ed25519 --gpg-key ABCDEF1234567890 \
  --non-interactive

# Re-run just secrets after rotating a key
./aurtomator.sh setup secrets

# Verify after manual changes
./aurtomator.sh setup verify
```

## Configuration file

Setup saves its state to `.aurtomator.conf` in the root of your repository, next to `packages/`. The scripts read it as data and never run it. Each line holds one of the four names below and a value in single quotes, as the setup writes it, so a `"`, `$` or backtick in a name stays part of the name. A file from an older version, with double quotes, still loads while its values hold no `$`, backtick or backslash. Empty lines and lines that start with `#` are skipped, and any other line stops the script with the number of that line.

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
| `AUR_SSH_KEY`      | Absolute path to the SSH private key for AUR. A relative path given to the setup is saved as an absolute one. |

A re-run of `./aurtomator.sh setup` loads this file first and does not ask again for the values it holds. A command line option overrides the saved value, and the new value is saved. The `.gitignore` of the template lists the file, because it holds local paths.

The scripts that read the file, `setup.sh`, `update-pkg.sh` and `publish-pkg.sh`, stop when git tracks `.aurtomator.conf`. A tracked file takes the place of the ignored one at a checkout or a merge, so a pull request that adds it would choose the key the `secrets` step uploads and the name and email of your AUR commits. Check the values of such a file, then `git rm --cached .aurtomator.conf` takes it out of the repository and keeps it on disk. Before the `secrets` step sets the secrets, it prints each value and the file of the SSH key.

## Pull requests to your repository

`Validate packages` runs `validate-pkg.sh --all` on a pull request, so it checks the YAMLs of `packages/` and no other file. A pull request that changes `aurtomator.sh` runs its code on your machine at the next `./aurtomator.sh` command after you check it out or merge it. One that changes a calling workflow changes what CI runs with your secrets after the merge: the `uses:` line of `check-updates.yml` names the workflow that gets `AUR_SSH_KEY` and `GPG_SIGNING_KEY`. Read these files in the diff before you merge, and check a new pin as [The aurtomator.sh script](#the-aurtomatorsh-script) describes. `setup.sh`, `update-pkg.sh` and `publish-pkg.sh` stop on a `.aurtomator.conf` that git tracks, see [Configuration file](#configuration-file).
