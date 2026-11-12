---
title: Local testing
---

## Prerequisites

```bash
sudo pacman -S --needed git curl go-yq pacman-contrib namcap
# For tests and linting:
sudo pacman -S --needed bats jq openssh shellcheck shfmt actionlint
```

The commands of the next four sections and of [Draft a package](/add-a-package/#draft-a-package) run in your repository through its script `aurtomator.sh`. It runs the scripts of aurtomator at the commit the calling workflows pin, so a local run uses the strategies and the checks of the version a run in CI uses, see [The aurtomator.sh script](/setup/#the-aurtomatorsh-script).

A script takes the packages, `.status/`, `.aurtomator.conf` and `README.md` from the working directory, or from `AURTOMATOR_DATA_DIR` when it is set, and stops with `AURTOMATOR_DATA_DIR is not a directory: <value>` when that names no directory. `./aurtomator.sh` sets `AURTOMATOR_DATA_DIR` to your repository and `AURTOMATOR_RUNNER` to the path it was run by. When `AURTOMATOR_RUNNER` is set, the commands that `setup.sh` and `draft.sh` print start with it, as `./aurtomator.sh setup verify` does.

## Check a single package

```bash
./aurtomator.sh check-update my-package
```

The log goes to stderr. When an update is available, the new version is printed on stdout:

```text
→ Checking my-package (strategy: github-release, current: 1.0.0)
! my-package: update available 1.0.0 → 2.0.0
2.0.0
```

When the package is up to date, stdout stays empty:

```text
→ Checking my-package (strategy: github-release, current: 2.0.0)
✓ my-package is up to date (2.0.0)
```

## Dry-run an update

```bash
./aurtomator.sh update-pkg my-package 2.0.0 --dry-run
```

It runs the steps of [Step-by-step](/internals/update-process/#step-by-step) up to the check of `PKGBUILD` and `.SRCINFO`, prints the PKGBUILD diff and does not push. Those steps run the PKGBUILD of the AUR on your machine, with your SSH key in reach of its code, so read the PKGBUILD first when someone else can push to the package.

## Push an update

```bash
./aurtomator.sh update-pkg my-package 2.0.0
```

It runs the full cycle, including `git push` to the AUR with your SSH key.

## Check all packages

```bash
# Check only
./aurtomator.sh check-all

# Check and push updates
./aurtomator.sh check-all --update

# Check and dry-run updates
./aurtomator.sh check-all --update --dry-run
```

The last line is a summary:

```text
→ Checked: 4, Updated: 2, Errors: 0
```

## Running BATS tests

The tests here and the linters of [Linting locally](#linting-locally) check aurtomator itself, and run in the root of a clone of aurtomator:

```bash
# Run all tests
bats tests/ --recursive --timing

# Run one file
bats tests/scripts.bats
bats tests/strategies.bats
bats tests/setup.bats

# Coverage report in coverage/, as CI makes it
bashcov -- tests/helpers/bashcov-bats.sh tests/ --recursive
```

`tests/helpers/setup.sh` gives every test a temporary project directory with symlinked scripts and strategies. It copies `tests/helpers/mock-curl.sh` there as `curl`, puts it first in `PATH`, and removes the directory afterwards, unless `AURTOMATOR_KEEP_TEST_DIRS` is set, as `bashcov-bats.sh` sets it (see [Test job](/develop/ci/#test-job)). Tests that need `git`, `ssh` or `gh` put their own mocks in the same place. The suite makes no network requests and never touches real AUR repos.

## Linting locally

```bash
# shellcheck
shellcheck -x -S warning scripts/*.sh scripts/lib/*.sh strategies/*.sh tests/helpers/*.sh

# shfmt (check mode)
shfmt -d -i 2 -ci scripts/*.sh scripts/lib/*.sh strategies/*.sh tests/*.bats tests/helpers/*.sh

# shfmt (auto-fix)
shfmt -w -i 2 -ci scripts/*.sh scripts/lib/*.sh strategies/*.sh tests/*.bats tests/helpers/*.sh

# actionlint (the workflows, with shellcheck on their run: blocks)
actionlint
```

CI also runs `shellcheck` on the `run:` blocks of `.github/actions/*/action.yml`, and `shellcheck` and `shfmt` on the runner script, see [Lint job](/develop/ci/#lint-job).
