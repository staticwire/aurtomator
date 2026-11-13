---
title: Local testing
---

## Prerequisites

```bash
sudo pacman -S --needed git curl go-yq pacman-contrib namcap
# For tests and linting:
sudo pacman -S --needed bats jq openssh shellcheck shfmt actionlint
```

The commands of the next four sections and of [Draft a package](/add-a-package/#draft-a-package) run in your repository through `aurtomator.sh`, at the commit the calling workflows pin, so a local run uses the strategies and checks of CI, see [The aurtomator.sh script](/setup/#the-aurtomatorsh-script).

A script takes the packages, `.status/`, `.aurtomator.conf` and `README.md` from the working directory, or from `AURTOMATOR_DATA_DIR`, which `./aurtomator.sh` sets to your repository. `AURTOMATOR_RUNNER`, which `./aurtomator.sh` sets to its own path, starts the commands that `setup.sh` and `draft.sh` print, as in `./aurtomator.sh setup verify`.

## Check a single package

```bash
./aurtomator.sh check-update my-package
```

The log goes to stderr, and a new version to stdout:

```text
→ Checking my-package (strategy: github-release, current: 1.0.0)
! my-package: update available 1.0.0 → 2.0.0
2.0.0
```

An up-to-date package leaves stdout empty:

```text
→ Checking my-package (strategy: github-release, current: 2.0.0)
✓ my-package is up to date (2.0.0)
```

## Dry-run an update

```bash
./aurtomator.sh update-pkg my-package 2.0.0 --dry-run
```

It runs the steps of [Step-by-step](/internals/update-process/#step-by-step) up to the check of `PKGBUILD` and `.SRCINFO`, prints the diff of the PKGBUILD and pushes nothing. These steps run the PKGBUILD of the AUR on your machine, with your SSH key in reach of its code, so read the PKGBUILD first when someone else can push to the package.

## Push an update

```bash
./aurtomator.sh update-pkg my-package 2.0.0
```

It runs the whole update, `git push` to the AUR with your SSH key included.

## Check all packages

```bash
./aurtomator.sh check-all                      # check only
./aurtomator.sh check-all --update             # check and push updates
./aurtomator.sh check-all --update --dry-run   # check and dry-run updates
```

The last line counts the packages:

```text
→ Checked: 4, Updated: 2, Errors: 0
```

## Running BATS tests

The tests and the linters check aurtomator itself and run in the root of a clone of aurtomator:

```bash
bats tests/ --recursive --timing
bats tests/scripts.bats

# Coverage report in coverage/, as CI makes it
bashcov -- tests/helpers/bashcov-bats.sh tests/ --recursive
```

`tests/helpers/setup.sh` gives every test a temporary directory with links to the scripts and strategies and with `tests/helpers/mock-curl.sh` as the first `curl` in `PATH`. Tests that need `git`, `ssh` or `gh` add their own mocks there. The suite sends no request to the network and never touches a real AUR repository.

## Linting locally

```bash
shellcheck -x -S warning scripts/*.sh scripts/lib/*.sh strategies/*.sh tests/helpers/*.sh
shfmt -d -i 2 -ci scripts/*.sh scripts/lib/*.sh strategies/*.sh tests/*.bats tests/helpers/*.sh
actionlint
```

`shfmt -w` in place of `-d` fixes the formatting. CI also checks the `run:` blocks of `.github/actions/*/action.yml` and `aurtomator.sh`, see [Lint job](/develop/ci/#lint-job).
