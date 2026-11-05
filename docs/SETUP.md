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

A repository created from the template [staticwire/aurtomator-seed](https://github.com/staticwire/aurtomator-seed) with "Use this template" holds the two [calling workflows](#the-calling-workflows), the script [`aurtomator.sh`](#the-aurtomatorsh-script), `.github/dependabot.yml`, a `.gitignore`, an empty `packages/` directory and a README with the markers that a run fills.

### Required

1. **Enable Issues**: Settings > General > Features > Issues. Failures, update alerts and newer aurtomator releases are reported as issues. With Issues off, a run prints a notice instead and opens none.
2. **Check Actions**: the Actions tab lists `Check AUR Package Updates` and `Validate packages`. A workflow shown as disabled there runs again once you open it and click "Enable workflow". In a fork, GitHub disables the workflows until they are enabled in its Actions tab. GitHub also disables a scheduled workflow of a public repository after 60 days without activity in it. The workflow commits only when a status or a version changes, so a repository whose packages stay the same that long loses its schedule and needs "Enable workflow" again. A private repository keeps its schedule, and its runs use the Actions minutes of your account instead: GitHub counts each job in whole minutes, rounded up, from three jobs for a run that changes nothing, `image`, `check` and `issues`, to six for a run with an update.
3. **Set the secrets**: `./aurtomator.sh setup`, run in a clone of your repository, sets `AUR_SSH_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` and, with GPG, `GPG_SIGNING_KEY`, as [Quick setup](#quick-setup-with-gh-cli) describes. The calling workflow passes them to aurtomator by name. `secrets: inherit` would pass none, since it works only between repositories of one organization or enterprise.

The schedule runs from the start, so runs can come before the secrets are set. Such a run needs no key while it pushes nothing to the AUR, and it can still commit the README. A run with a package to push stops in `publish` with `The secret AUR_SSH_KEY is empty`, and the `notify` job opens the issue `❌ Check AUR Package Updates failed`. The first run after `setup secrets` in which no job fails closes that issue.

### Recommended

- **Dependabot version updates**: the `.github/dependabot.yml` of the template turns them on in a repository created from it. Dependabot then opens the pull request that moves the pin of the calling workflows to a new release of aurtomator, see [The calling workflows](#the-calling-workflows). A fork of the template needs the switch: Settings > Advanced Security, then Enable next to "Dependabot version updates".
- Set repository topics if your repository is public.

### Badges

`update-readme.sh` writes three badges between the `<!-- BADGES:START -->` and `<!-- BADGES:END -->` markers of the README: `Validate packages`, `Check AUR Package Updates` and `maintained with aurtomator`. A run of `Check AUR Package Updates` runs the script and commits the README when it changed. While `packages/` holds no package, the script writes nothing, so the setup steps of the template stay in the README until the first package.

The badge URLs name `validate.yml` and `check-updates.yml` in your repository, so the calling workflows keep those file names.

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

The pin after `@` is the SHA of a release tag of aurtomator, and the comment after it names that release. All three `uses:` lines carry the same pin. A tag can be moved and a SHA cannot, so a run always gets the code of that release. `./aurtomator.sh pin vX.Y.Z` moves the pin of the three lines to a release, see [The aurtomator.sh script](#the-aurtomatorsh-script). To move it by hand, `git ls-remote https://github.com/staticwire/aurtomator refs/tags/vX.Y.Z` prints the SHA of a tag, and that SHA and the new `# vX.Y.Z` go into the three lines. Dependabot opens the pull request that moves the pin to a new release at its next check. "Check for updates" under Insights > Dependency graph > Dependabot runs a check at once. The group `aurtomator` in `.github/dependabot.yml` puts the three `uses:` lines into that one pull request. The `cooldown` entry of the same file exempts them from the 3 days that Dependabot otherwise waits after a release. The `Validate packages` run of that pull request checks your packages with the validator of the new release before the merge. After the merge, [`./aurtomator.sh`](#the-aurtomatorsh-script) runs the scripts of the new release as well.

A calling job sets the permissions of the token for the whole called workflow, and a job of the called workflow can lower them but cannot raise them. `check-updates` grants `contents: write` for the commit of the package versions and the README, and `issues: write` for the issues it opens and closes. `notify` grants `actions: read` to list the failed jobs of the run, and `issues: write` to open its issue. `check-updates.yml` has no workflow-level `permissions`, so each job gets its own block and nothing more. `validate.yml` has one job, and its workflow-level `contents: read` covers that job. A calling job that grants less than this makes GitHub reject the file before any job starts, see [Invalid workflow file](#invalid-workflow-file-a-nested-job-requests-more-permissions).

## The aurtomator.sh script

The script `aurtomator.sh` in the root of your repository runs the scripts of aurtomator for that repository, at the commit the calling workflows pin. A local run then uses the strategies and the checks that a run in CI uses, and no clone of aurtomator is needed:

```bash
./aurtomator.sh setup                  # scripts/setup.sh
./aurtomator.sh validate-pkg <name>    # scripts/validate-pkg.sh <name>
./aurtomator.sh check-update <name>    # scripts/check-update.sh <name>
./aurtomator.sh update-pkg <name> <version> --dry-run
./aurtomator.sh check-all              # scripts/check-all.sh
./aurtomator.sh sample                 # prints packages/example.yml.sample
./aurtomator.sh pin vX.Y.Z             # pins the calling workflows to a release
```

A command is `sample`, `pin` or the name of an executable script in `scripts/` of aurtomator without `.sh`, and the arguments after it go to that script. The script runs with your repository as `AURTOMATOR_DATA_DIR`, whatever directory you run it from. The commands above are the documented ones, and the list that the script prints for an unknown command holds these alone. Any other script of `scripts/`, such as `publish-pkg`, is a step of the CI jobs and runs after a warning.

The `uses:` line of `.github/workflows/check-updates.yml` that names `check-updates.yml` at a commit SHA gives the repository and the commit. The script stops when the file holds no such line or more than one, and it reads no comment, so an old pin kept in a comment changes nothing. The first run of a pin fetches aurtomator at that commit into `~/.cache/aurtomator/<sha>`, or into `$XDG_CACHE_HOME/aurtomator/<sha>` when `XDG_CACHE_HOME` is set. Later runs use that copy, and the first run after a merge that moves the pin fetches the new release. That first run also removes the copies fetched more than 30 days ago, so a pin still in use is fetched again on its next run.

Before that fetch, the script warns when no tag of the repository points to the pinned commit. GitHub serves a commit of any fork of a repository under the name of that repository too, so a `uses:` line that names `staticwire/aurtomator` can pin a commit that is not in aurtomator. The warning shows only when the script runs. Before you merge a pull request that moves the pin, `git ls-remote --tags https://github.com/staticwire/aurtomator` lists the tags and their commits.

`./aurtomator.sh pin vX.Y.Z` moves the pin to a release. It reads the commit of that tag with `git ls-remote`, puts it and `# vX.Y.Z` into every `uses:` line of the pinned repository in `.github/workflows/check-updates.yml` and `.github/workflows/validate.yml`, and prints those lines. It fetches nothing. The next run of the script fetches the release, and CI takes it once the two files are committed and pushed.

In CI, the jobs check out your repository and then aurtomator into `aurtomator/` of that checkout, which deletes whatever that path holds. So the script is `aurtomator.sh`, and nothing in the root of your repository may be named `aurtomator`. The jobs also make the directories `upload`, `handoff` and `statuses` in that root, so these names are taken as well: a tracked `upload` or `statuses` stops the step that makes the directory, and the files of a tracked `handoff` change in the run, which the commit of the results refuses.

The template holds this block as the file `aurtomator.sh`. A repository created without the template needs it in its root, made executable with `chmod +x aurtomator.sh`:

```bash
#!/usr/bin/env bash
#
# Runs a script of aurtomator for this repository, at the commit that
# .github/workflows/check-updates.yml pins:
#
#   ./aurtomator.sh setup                 scripts/setup.sh
#   ./aurtomator.sh validate-pkg <name>   scripts/validate-pkg.sh <name>
#   ./aurtomator.sh check-update <name>   scripts/check-update.sh <name>
#   ./aurtomator.sh update-pkg <name> <version> --dry-run
#   ./aurtomator.sh check-all             scripts/check-all.sh
#   ./aurtomator.sh sample                prints packages/example.yml.sample
#   ./aurtomator.sh pin vX.Y.Z            pins the calling workflows to a release
#
# The first run of a pin fetches aurtomator at that commit into
# ~/.cache/aurtomator/<sha>, or $XDG_CACHE_HOME/aurtomator/<sha>.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflow=.github/workflows/check-updates.yml
if [[ ! -f "$root/$workflow" ]]; then
  echo "No $workflow in $root" >&2
  exit 1
fi
# The repository and the commit come from one uses: line, never a comment
uses='^[[:space:]]*uses:[[:space:]]+([[:alnum:]_.-]+/[[:alnum:]_.-]+)/\.github/workflows/check-updates\.yml@([0-9a-f]{40})([[:space:]]|$)'
mapfile -t pins < <(grep -E "$uses" "$root/$workflow" || true)
if [[ ${#pins[@]} -eq 0 ]]; then
  echo "No commit SHA pinned in $workflow" >&2
  exit 1
fi
if [[ ${#pins[@]} -gt 1 ]]; then
  echo "More than one uses: line pins check-updates.yml in $workflow" >&2
  exit 1
fi
[[ "${pins[0]}" =~ $uses ]]
repo="${BASH_REMATCH[1]}"
sha="${BASH_REMATCH[2]}"

if [[ "${1:-}" == pin ]]; then
  if [[ $# -ne 2 || ! "$2" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 pin vX.Y.Z" >&2
    exit 1
  fi
  # An annotated tag names its commit on the line of <tag>^{}
  new=$(git ls-remote --tags "https://github.com/$repo" | awk -v ref="refs/tags/$2" '$2 == ref || $2 == ref "^{}" { sha = $1 } END { print sha }')
  if [[ -z "$new" ]]; then
    echo "No tag $2 in $repo" >&2
    exit 1
  fi
  cd "$root"
  for file in "$workflow" .github/workflows/validate.yml; do
    [[ -f "$file" ]] || continue
    sed -i -E "s|^([[:space:]]*uses:[[:space:]]+$repo/\.github/workflows/[a-z-]+\.yml@)[0-9a-f]{40}([[:space:]].*)?$|\1$new # $2|" "$file"
    grep -nHE "^[[:space:]]*uses:[[:space:]]+$repo/\.github/workflows/[a-z-]+\.yml@$new # $2\$" "$file" || true
  done
  exit 0
fi

copy="${XDG_CACHE_HOME:-$HOME/.cache}/aurtomator/$sha"
if [[ ! -d "$copy" ]]; then
  # GitHub serves the commits of every fork under the name of its parent
  if [[ $'\n'"$(git ls-remote --tags "https://github.com/$repo")" != *$'\n'"$sha"* ]]; then
    echo "Warning: no tag of $repo points to $sha, check where the pin comes from" >&2
  fi
  mkdir -p "${copy%/*}"
  tmp="$(mktemp -d "$copy.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  git -C "$tmp" init -q
  git -C "$tmp" fetch -q --depth 1 "https://github.com/$repo" "$sha"
  git -C "$tmp" checkout -q FETCH_HEAD
  # A run that started at the same time can make the copy first
  mv -T "$tmp" "$copy" 2>/dev/null || rm -rf "$tmp"
  # A pin still in use after 30 days is fetched again on its next run. A
  # run at the same time can remove its own directory while find reads.
  find "${copy%/*}" -mindepth 1 -maxdepth 1 -regextype posix-extended -regex '.*/[0-9a-f]{40}' -mtime +30 -exec rm -rf -- {} + 2>/dev/null || true
fi

# The documented commands. Another script of scripts/ is a step of the CI
# jobs and runs after a warning.
commands=(setup sample validate-pkg check-update update-pkg check-all pin)
cmd="${1:-}"
if [[ "$cmd" == sample ]]; then
  exec cat "$copy/packages/example.yml.sample"
fi
if [[ ! "$cmd" =~ ^[a-z]+(-[a-z]+)*$ || ! -x "$copy/scripts/$cmd.sh" ]]; then
  echo "Usage: $0 <command> [argument...]" >&2
  echo "Commands: ${commands[*]}" >&2
  exit 1
fi
if [[ " ${commands[*]} " != *" $cmd "* ]]; then
  echo "Warning: $cmd is a step of the CI jobs, not a documented command" >&2
fi
shift
AURTOMATOR_DATA_DIR="$root" AURTOMATOR_RUNNER="$0" "$copy/scripts/$cmd.sh" "$@"
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

The setup works on the repository that holds `aurtomator.sh`, whatever directory you run it from, and the `identity` step prints it as `Data directory:`. The `secrets` step sets the secrets of the GitHub repo of its `origin` remote and prints that repo as `Target repo:`. It asks for `owner/repo` when `origin` is missing or is not a repository on github.com. The secrets hold the key that pushes all of your AUR packages, so an interactive run asks before it sets them. The setup saves your answers to `.aurtomator.conf` after each step, so a step that fails, and a `verify` that finds a problem, leave the answers given so far for the next run.

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

That output works in CI only for a key without a passphrase. For a key with one, `./aurtomator.sh setup gpg secrets` prints a passphrase-free copy, see [Passphrase stripping](#passphrase-stripping-3-pinentry-dialogs).

### 5. Run verify

```bash
./aurtomator.sh setup verify
```

It checks identity, SSH access, and GPG signing when configured. With `gh` available, it also checks the GitHub repo of `origin`: its secrets, that Issues are on, and that `check-updates.yml` and `validate.yml` are active workflows, as [Required](#required) asks. An `origin` that is not a repository on github.com counts as a failed check. Two findings are warnings and count as no failure: an open `❌ Check AUR Package Updates failed` issue, which the next run without a failed job closes, and a pin to a version of aurtomator other than its latest release. When a check fails, the others still run, and `verify` then prints how many failed and exits with status 1.

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
./aurtomator.sh setup --gpg-key <subkey-id>
```

Or run the GPG step and answer `y` to "Enable GPG commit signing? (y/N)":

```bash
./aurtomator.sh setup gpg
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

The copy exists only while the script runs, so the `gpg` and `secrets` steps have to run together: `./aurtomator.sh setup gpg secrets`. Run alone, `secrets` does not set `GPG_SIGNING_KEY` for a key with a passphrase and prints that command.

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
| `--non-interactive`    | No prompts. A missing required value is an error, and GPG is skipped without `--gpg-key`. |
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

## Adding your first package

### 1. Copy the example

```bash
./aurtomator.sh sample > packages/my-package.yml
```

### 2. Edit the YAML

```yaml
name: my-package
strategy: github-release
upstream:
  project: owner/repo
```

`name` is the `pkgbase` on the AUR, the name of its git repository. It is the package name, except for a split package: liblinear with `pkgname=(liblinear python-liblinear)` has the `name` `liblinear`, and `python-liblinear` has no YAML of its own.

[docs/WORKFLOW.md](WORKFLOW.md) has YAML examples for all 16 strategies.

### 3. Validate the config

```bash
./aurtomator.sh validate-pkg my-package
```

It checks the YAML syntax, the required fields and the fields each strategy needs.

### 4. Test the version check

```bash
./aurtomator.sh check-update my-package
```

It runs the strategy and prints the latest upstream version. Without a `current` field in the YAML, it also reports that no current version is set.

### 5. Test the update (dry run)

```bash
./aurtomator.sh update-pkg my-package 1.2.3 --dry-run
```

It clones the AUR repo, sets `pkgver`, regenerates checksums and `.SRCINFO`, runs `namcap` when it is installed, and shows the PKGBUILD diff **without pushing**.

The dry run runs the PKGBUILD of the AUR on your machine before it stops: the audit and `makepkg --printsrcinfo` source it, as `updpkgsums` and `makepkg --verifysource` do for a package with checksums, and your SSH key is in reach of that code. When someone else can push to the AUR package, read its PKGBUILD first.

### 6. Push and let CI take over

Commit the package YAML and push to your repository. The push to `main` runs `Validate packages`. `Check AUR Package Updates` runs on the schedule `17 * * * *` of `.github/workflows/check-updates.yml`, and GitHub starts only part of those runs: in October 2026 a repository with this schedule got about five a day, one every five hours. Actions > Check AUR Package Updates > Run workflow starts a run at once, through `workflow_dispatch`. A run started by hand from a branch other than the default one reads the package YAMLs of that branch, pushes their updates to the AUR, and commits its results to that branch. The schedule runs on the default branch only.

## Troubleshooting

### SSH: Permission denied (publickey)

**Symptom:** `ssh aur@aur.archlinux.org` returns `Permission denied`.

**Causes:**

1. The public key is not on your AUR account. Add it under My Account > SSH Public Key on <https://aur.archlinux.org>.
2. SSH picks the wrong key. Offer that key alone: `ssh -F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none -i ~/.ssh/aur_ed25519 aur@aur.archlinux.org`
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
2. Run `./aurtomator.sh setup secrets` to push them again.
3. The `check-updates` job of `.github/workflows/check-updates.yml` passes each secret by name, as [The calling workflows](#the-calling-workflows) shows. `secrets: inherit` passes none to aurtomator, see [Required](#required).

### Invalid workflow file: a nested job requests more permissions

**Symptom:** A run of a calling workflow fails before any job starts, with `Invalid workflow file` and a line of this form:

```text
The nested job '<job>' is requesting '<permissions>', but is only allowed '<permissions>'
```

**Cause:** The calling job grants less than a job of the called workflow requests. A called workflow can lower the permissions of the calling job but cannot raise them.

**Fix:** Give each job of the calling workflow the `permissions` block that [The calling workflows](#the-calling-workflows) shows: `contents: write` and `issues: write` for `check-updates`, `actions: read` and `issues: write` for `notify`, and `contents: read` in `validate.yml`.

### check-update.sh fails: "Strategy not found"

**Symptom:** `Strategy not found or not executable:` followed by the path of `strategies/<strategy>.sh` in aurtomator.

**Fixes:**

1. `./aurtomator.sh validate-pkg my-package` lists the strategies of the pinned release when the `strategy` field names none of them.
2. A strategy that a newer release of aurtomator adds needs the pin of that release, see [The calling workflows](#the-calling-workflows).

### update-pkg.sh fails: "No PKGBUILD found"

**Symptom:** The clone succeeds, and the script reports `No PKGBUILD found in AUR repo`.

**Cause:** The package does not exist on the AUR yet. aurtomator updates **existing** AUR packages and does not create new ones. Push your first PKGBUILD to the AUR by hand.

### updpkgsums fails

**Symptom:** `Required command not found: updpkgsums`, or `updpkgsums failed` with a refusal to push.

**Causes:**

1. `updpkgsums` is not installed. Install it with `sudo pacman -S --needed pacman-contrib`.
2. A source URL in the PKGBUILD uses variables that do not resolve after the version bump. Check the `source=()` array.
